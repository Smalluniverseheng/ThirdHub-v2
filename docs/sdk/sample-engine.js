#!/usr/bin/env node
/*
 * ThirdHub THP 示例引擎 —— 一份可以照着抄的最小实现（零依赖，node 直接跑）
 *
 *   node sample-engine.js                          # 默认 0.0.0.0:1234，每 30s UDP 广播
 *   node sample-engine.js --port 1234 --no-broadcast
 *   node sample-engine.js --name "我的引擎" --interval 30
 *   node sample-engine.js --quiet
 *
 * 配套自检：  node docs/sdk/selfcheck.cjs         （离线 42 项断言）
 *             node docs/sdk/selfcheck.cjs --udp   （额外验一次广播实收）
 *
 * ── 这个文件要回答的问题 ──────────────────────────────────────
 * "我想让自己的内容源接进 ThirdHub，最少要写什么？"
 * 答：一个 mDNS/UDP 广播 + 四个端点（meta/search/toc/content）。
 * 没有注册、没有审核、官方不分发、不引入任何依赖。
 *
 * 规范单一事实来源：docs/THP.md（THP/1.0）。本文档若与它冲突，以 THP.md 为准。
 * 面向人的上手手册：docs/THP-SDK.md。本文件是它的**可运行对照实现**。
 *
 * ── 六条最容易写错、写错就整片源不可用的规矩 ──────────────────
 * 1) **身份端点是 GET /thp/meta**，不是 /thp/hello 或 /thp/info。
 *    前端"手动添加引擎"时会先打它来确认对面是不是 THP 设备。
 * 2) **caps 是字符串数组**（`["m:novel","post-query"]`），不是数字位掩码。
 *    §11 caps 注册表只登记名字；模块能力一律写成 `m:<module>`。
 *    UDP 广播里的 caps 则是**同一个数组用逗号连成一个字段**——
 *    因为报文按空格切段，逗号不能变空格。
 * 3) **只有 error.code ∈ {UNSUPPORTED, NOT_FOUND} 才会让前端换下一个源**。
 *    其它任何 code（含你自己发明的）都会被当成"这个源坏了"从而整片跳过。
 *    所以"我这儿没有这本漫画"必须回 NOT_FOUND，不能回 EMPTY 之类。
 * 4) **HTTP 状态码要贴合语义**：资源/模块/端点不存在 → 404，上游挂了 → 502。
 *    回 200 再在 body 里写 error，会让调用方以为请求成功。
 * 5) **Content-Type 必须带 charset=utf-8**。少了它，各家 HTTP 库会按 US-ASCII
 *    去解码中文 → 变成一串 U+FFFD（不可逆），而 HTTP 状态码还是 200，
 *    排查起来极其费劲。
 * 6) **content 的形状按模块固定**，不能自由发挥（§6.1 模块注册表）：
 *    novel → `{text}`、comic → `{images:[]}`、music → `{url, variants}`、
 *    video → `{url, header, variants}`。
 *    前端只认这四种形状，多给字段会被忽略，少给字段会解析失败。
 *
 * ── 关于版权 ────────────────────────────────────────────────
 * 下面所有内容都是**程序生成的占位文本**，不是任何真实作品。
 * 官方不分发、不内置、不审核任何内容源，示例里也不该夹带。
 */
'use strict';

const http = require('http');
const dgram = require('dgram');
const os = require('os');
const crypto = require('crypto');

// ── 命令行 ──
const argv = process.argv.slice(2);
const argOf = (name, def) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
};
const PORT = Number(argOf('port', 1234));
const BIND = argOf('host', '0.0.0.0');
const NAME = argOf('name', '示例引擎');
const QUIET = argv.includes('--quiet');
const NO_BCAST = argv.includes('--no-broadcast');
/** §4.1: 广播周期 30s（可调范围 10–300s）。太慢前端要等，太快白耗电。 */
const HELLO_INTERVAL_SEC = Math.min(Math.max(Number(argOf('interval', 30)) || 30, 10), 300);

const VERSION = '1.0.0';
const PROTOCOL = 'THP/1.0';

/**
 * instanceId：**重启必须不变**（§4.1）。
 *
 * 真实引擎一般首次启动生成一个 UUID 存盘、此后一直读它。
 * 示例为了不往磁盘写文件，用 机器名+端口 派生一个稳定的 UUIDv4 形状的串。
 * 两种做法都满足规范的硬要求：① 形状是 UUID；② 同一实例重启后号不变。
 * 若用随机数且不持久化，前端会以为"多了一台新设备"。
 */
const IID = (() => {
  const h = crypto.createHash('sha1').update('thirdhub-sample-engine:' + os.hostname() + ':' + PORT).digest('hex');
  return [h.slice(0, 8), h.slice(8, 12), '4' + h.slice(13, 16), 'a' + h.slice(17, 20), h.slice(20, 32)].join('-');
})();

/**
 * §11 caps 注册表：模块能力写成 `m:<module>`，POST 支持靠 `post-query` 声明。
 * 本示例**故意声明 m:comic 但漫画正文不实现**——用来演示"模块级支持、操作级不支持"
 * 时该回什么（404 + UNSUPPORTED，让调用方换下一个源，而不是把我整个标记为故障）。
 * 故意**不声明 m:video**——调用方连试都不该试（§6.1 未知模块一律忽略）。
 */
const CAPS = ['m:novel', 'm:comic', 'm:music', 'post-query'];
/** UDP 广播里 caps 要压成一个字段：报文按空格切段，所以只能用逗号连。 */
const CAPS_FIELD = CAPS.join(',');

/** 本示例支持的模块 = caps 里的 m:* 去掉前缀。两处必须一致，否则能力声明与实际不符。 */
const MODULES = CAPS.filter((c) => c.startsWith('m:')).map((c) => c.slice(2));

const log = (...a) => { if (!QUIET) console.log('[engine]', ...a); };

// ═══════════════════════════════════════════════════════════════════
// 信封（§3）
// ═══════════════════════════════════════════════════════════════════

/** 降级白名单。**只有这两个 code 会让前端换到下一个源**（§3.2）。 */
const DEGRADABLE = new Set(['UNSUPPORTED', 'NOT_FOUND']);

// 故意在启动时自检一次：有人往这里加了新 code 而忘了它是"不可降级"的，早点发现。
log(`可降级 code 白名单: ${[...DEGRADABLE].join(' / ')} — 其它 code 一律视为"源损坏"`);

/**
 * 成功信封：`{ ok:true, data, meta }`。
 * search/toc 的 data 是**数组本身**；content 的 data 是对象。
 */
function ok(res, data, meta) {
  return json(res, 200, { ok: true, data: data, meta: Object.assign(baseMeta(), meta || {}) });
}

/**
 * 失败信封：`{ ok:false, error:{code,message}, meta }`。
 * @param {number} status HTTP 状态码——要和 code 语义一致（见文件头规矩 4）
 * @param {string} code   机器可判的短码；只有 DEGRADABLE 里的会触发降级
 */
function fail(res, status, code, message) {
  return json(res, status, { ok: false, error: { code: code, message: message }, meta: baseMeta() });
}

/** meta 里至少带 source（= instanceId），方便调用方在聚合结果里定位是哪台 peer 给的。 */
function baseMeta() {
  return { source: IID };
}

/** §8 分页三件套。本示例一轮返回全量，所以 cursor 空串、hasMore=false。 */
function pageMeta(total) {
  return { cursor: '', hasMore: false, total: total };
}

let CURRENT_REQ_ID = null;

/**
 * 统一的 JSON 出口。两个 header 是规范要求，不是可选项：
 *  ★ charset=utf-8 是必须的（见文件头规矩 5）
 *  ★ X-TH-Request-Id 必须原样回显（§3.1），调用方靠它串日志
 */
function json(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    // 前端可能从 WebView 里直连本机引擎，跨源是常态
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Cache-Control': 'no-store',
  };
  if (CURRENT_REQ_ID) headers['X-TH-Request-Id'] = CURRENT_REQ_ID;
  res.writeHead(status, headers);
  res.end(body);
  return true;
}

/**
 * ★ 读 POST 体必须自己按 UTF-8 解。
 * 很多轻量 HTTP 实现（含引擎侧历史用过的 NanoHTTPD）在没有 charset 时会按
 * US-ASCII 读体，中文直接变 U+FFFD 且不可逆。自己收字节、自己 utf8 解码，
 * 就不依赖对方实现得对不对。
 */
function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch (e) { resolve({ __raw: raw }); }
    });
    req.on('error', () => resolve({}));
  });
}

// ═══════════════════════════════════════════════════════════════════
// 演示数据（全部是生成的占位内容）
// ═══════════════════════════════════════════════════════════════════

const BOOKS = [
  { id: 'demo-1', name: '示例小说·甲', author: '占位作者', chapters: 6 },
  { id: 'demo-2', name: '示例小说·乙', author: '占位作者', chapters: 3 },
  { id: 'demo-3', name: 'A Demo Novel', author: 'placeholder', chapters: 2 },
];
/** 造一大堆书，用来演示 §8 的 limit 截断行为。 */
for (let i = 4; i <= 30; i++) {
  BOOKS.push({ id: 'demo-' + i, name: `示例小说·批量 ${i}`, author: '占位作者', chapters: 2 });
}

const COMICS = [
  { id: 'demo-c1', name: '示例漫画·壹', author: '占位作者', pages: 3 },
];

const SONGS = [
  { id: 'demo-m1', name: '示例曲目·一', artist: '占位歌手' },
  { id: 'demo-m2', name: '示例曲目·二', artist: '占位歌手' },
];

/** 造一段可读但明显是假的正文。真引擎这里应该去抓真实内容。 */
function fakeText(bookId, chapter) {
  const lines = [];
  for (let i = 1; i <= 12; i++) {
    lines.push(`这是 ${bookId} 第 ${chapter} 章的占位正文第 ${i} 段。`);
    lines.push('内容由示例引擎现场生成，用来演示 THP 的正文端点该怎么返回。');
  }
  return lines.join('\n');
}

/** 造一个极短的静音 WAV（44 字节头 + 若干静音采样），演示 music 的 url 形状。 */
function silentWav(seconds) {
  const rate = 8000;
  const n = rate * seconds;
  const data = Buffer.alloc(n * 2); // 16bit 单声道，全零＝静音
  const head = Buffer.alloc(44);
  head.write('RIFF', 0);
  head.writeUInt32LE(36 + data.length, 4);
  head.write('WAVE', 8);
  head.write('fmt ', 12);
  head.writeUInt32LE(16, 16);
  head.writeUInt16LE(1, 20);   // PCM
  head.writeUInt16LE(1, 22);   // 单声道
  head.writeUInt32LE(rate, 24);
  head.writeUInt32LE(rate * 2, 28);
  head.writeUInt16LE(2, 32);
  head.writeUInt16LE(16, 34);
  head.write('data', 36);
  head.writeUInt32LE(data.length, 40);
  return Buffer.concat([head, data]);
}

// ═══════════════════════════════════════════════════════════════════
// 四个 THP 端点
// ═══════════════════════════════════════════════════════════════════

/**
 * 身份自述（§7.2）。**这个端点是必选的**，前端靠它判断对面是不是 THP 设备、
 * 拿到 instanceId / caps / 是否有 POST 版。
 */
function doMeta(res) {
  return ok(res, {
    protocol: PROTOCOL,
    instanceId: IID,
    role: 'engine',
    name: NAME,
    version: VERSION,
    vendor: 'sample',
    // §11: 必须与 UDP 广播里的 caps 语义一致，否则"发现之前"和"连上之后"看到两套能力
    caps: CAPS.slice(),
    auth: ['none'],
    remote: false,
    endpoints: ['search', 'toc', 'content'],
    deprecated: [],
    ext: {},
  });
}

/**
 * search —— 关键字检索（§7.3）。
 * 契约：`data` 是**数组本身** `[{ id, name, author?, coverUrl?, intro?, ref? }]`，
 * 不是 `{items:[...]}`——旧草稿才是 items 形状，规范端点别用。
 * 搜不到不是错误，回空数组；只有"这个模块我根本不支持"才回 UNSUPPORTED。
 */
function doSearch(module, query, limit, res) {
  const q = String(query || '').trim().toLowerCase();
  if (module === 'novel') {
    const hit = BOOKS.filter((b) => !q || b.name.toLowerCase().includes(q) || b.id.includes(q));
    return ok(res, hit.slice(0, limit).map((b) => ({
      id: b.id, name: b.name, author: b.author, coverUrl: '', intro: '', ref: '',
    })), pageMeta(hit.length));
  }
  if (module === 'comic') {
    const hit = COMICS.filter((c) => !q || c.name.toLowerCase().includes(q) || c.id.includes(q));
    return ok(res, hit.slice(0, limit).map((c) => ({
      id: c.id, name: c.name, author: c.author, coverUrl: '', intro: '', ref: '',
    })), pageMeta(hit.length));
  }
  if (module === 'music') {
    const hit = SONGS.filter((s) => !q || s.name.toLowerCase().includes(q) || s.id.includes(q));
    return ok(res, hit.slice(0, limit).map((s) => ({
      id: s.id, name: s.name, author: s.artist, coverUrl: '', intro: '', ref: '',
    })), pageMeta(hit.length));
  }
  // 走到这里说明模块已在 MODULES 里但本函数没实现——属于开发期疏漏，
  // 回可降级 code 让调用方换下一个源，而不是 500 把整台引擎判死。
  return fail(res, 404, 'UNSUPPORTED', `本示例引擎不提供 ${module} 的检索`);
}

/**
 * toc —— 目录（§7.3）。
 * 契约：`data` 是数组 `[{ id, name, index }]`。
 * 书不存在 → 404 NOT_FOUND（可降级）。
 */
function doToc(module, id, res) {
  if (module === 'novel') {
    const b = BOOKS.find((x) => x.id === id);
    if (!b) return fail(res, 404, 'NOT_FOUND', `没有这本书: ${id}`);
    const items = Array.from({ length: b.chapters }, (_, i) => ({
      id: `${id}::${i + 1}`, name: `第 ${i + 1} 章`, index: i,
    }));
    return ok(res, items, pageMeta(items.length));
  }
  if (module === 'comic') {
    const c = COMICS.find((x) => x.id === id);
    if (!c) return fail(res, 404, 'NOT_FOUND', `没有这本漫画: ${id}`);
    const items = Array.from({ length: c.pages }, (_, i) => ({
      id: `${id}::${i + 1}`, name: `第 ${i + 1} 话`, index: i,
    }));
    return ok(res, items, pageMeta(items.length));
  }
  if (module === 'music') {
    const s = SONGS.find((x) => x.id === id);
    if (!s) return fail(res, 404, 'NOT_FOUND', `没有这首: ${id}`);
    return ok(res, [{ id: id, name: s.name, index: 0 }], pageMeta(1));
  }
  return fail(res, 404, 'UNSUPPORTED', `本示例引擎不提供 ${module} 的目录`);
}

/**
 * content —— 取内容（§7.3 + §6.1）。这是四个模块形状差异最大的端点，务必按模块给对：
 *   novel → { text }
 *   comic → { images: [url...] }
 *   music → { url, variants:[{quality,url}] }
 *   video → { url, header:{...}, variants:[{quality,url}] }
 * 参数：id + chapterId（规范用 chapterId，兼容旧名 chapter）。
 */
function doContent(module, id, chapterRef, res, origin) {
  if (module === 'novel') {
    // id 形如 demo-1::2（书::章）；也接受只给书 id + chapterId
    const parts = String(id || '').split('::');
    const bookId = parts[0];
    const b = BOOKS.find((x) => x.id === bookId);
    if (!b) return fail(res, 404, 'NOT_FOUND', `没有这本书: ${bookId}`);
    const raw = parts[1] || chapterRef || '1';
    const chap = Math.min(Math.max(Number(raw.replace(/^\D+/, '')) || 1, 1), b.chapters);
    return ok(res, { text: fakeText(b.id, chap), title: `第 ${chap} 章` });
  }
  if (module === 'comic') {
    const c = COMICS.find((x) => x.id === String(id || '').split('::')[0]);
    if (!c) return fail(res, 404, 'NOT_FOUND', `没有这本漫画: ${id}`);
    // 图片由本引擎自己伺服（现场生成一张 1x1 PNG），演示 images 形状
    const n = 3;
    const images = Array.from({ length: n }, (_, i) => `${origin}/demo/page.png?n=${i + 1}`);
    return ok(res, { images: images });
  }
  if (module === 'music') {
    const s = SONGS.find((x) => x.id === id);
    if (!s) return fail(res, 404, 'NOT_FOUND', `没有这首: ${id}`);
    // 音频由本引擎自己伺服一次，把 url 指回自己——这是"引擎自带内容"的最小演示
    const base = `${origin}/demo/audio.wav?id=${encodeURIComponent(id)}`;
    return ok(res, {
      url: base,
      variants: [
        { quality: '128k', url: base + '&q=128' },
        { quality: '320k', url: base + '&q=320' },
      ],
      name: s.name,
      artist: s.artist,
    });
  }
  return fail(res, 404, 'UNSUPPORTED', `本示例引擎不提供 ${module} 的正文`);
}

/** 现场生成一张 1x1 透明 PNG，免得示例还要带图片文件。 */
function tinyPng() {
  return Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    'base64');
}

// ═══════════════════════════════════════════════════════════════════
// HTTP 服务
// ═══════════════════════════════════════════════════════════════════

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const p = url.pathname;

  // §3.1: 调用方生成 X-TH-Request-Id，peer 原样回显。
  // 必须**无条件覆盖**，否则会把上一个请求的值带过来（并发下串号）。
  CURRENT_REQ_ID = req.headers['x-th-request-id'] || null;

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': '*',
      'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    });
    return res.end();
  }

  // 引擎自述。前端"手动添加引擎"时先打这个确认对面是 THP 设备（§7.2）
  if (p === '/thp/meta') return doMeta(res);

  // 演示媒体（不属于 THP，只是让 content 里的 url 有个真实目标可点）
  if (p === '/demo/audio.wav') {
    const buf = silentWav(2);
    res.writeHead(200, {
      'Content-Type': 'audio/wav',
      'Content-Length': buf.length,
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
    });
    return res.end(buf);
  }
  if (p === '/demo/page.png') {
    const buf = tinyPng();
    res.writeHead(200, {
      'Content-Type': 'image/png',
      'Content-Length': buf.length,
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
    });
    return res.end(buf);
  }

  // THP 主路由: /thp/m/{module}/{search|toc|content}
  const m = p.match(/^\/thp\/m\/([a-z]+)\/(search|toc|content)$/);
  if (m) {
    const module = m[1];
    const action = m[2];

    // ★ 顺序要紧：先判"这个模块是否在 caps 里注册过"，再判"这个操作实不实现"。
    //   两者回的都是 404，但 code 不同——NOT_FOUND 表示"我这儿没这东西，
    //   换别的源试试"；UNSUPPORTED 表示"这东西我这个模块不做"。
    if (!MODULES.includes(module)) {
      return fail(res, 404, 'NOT_FOUND', `未注册的模块: ${module}（caps 里没有 m:${module}）`);
    }

    // 规范允许 POST|GET 两种（§7.3）。GET 版参数走 query，POST 版走 body。
    let body = {};
    if (req.method === 'POST') body = await readBody(req);
    const q = url.searchParams;
    const pick = (k) => (body[k] !== undefined ? body[k] : q.get(k)) || '';
    const origin = `http://${req.headers.host || `127.0.0.1:${PORT}`}`;

    if (action === 'search') {
      const query = pick('q') || pick('key');   // q 是规范名，key 是历史兼容名
      if (!query.trim()) return fail(res, 400, 'INVALID_REQUEST', '缺参数 q');
      // §8: limit 默认 20、最大 100，超限**自动截断不报错**
      const limit = Math.min(Math.max(parseInt(pick('limit'), 10) || 20, 1), 100);
      return doSearch(module, query, limit, res);
    }
    if (action === 'toc') {
      const id = pick('id');
      if (!id) return fail(res, 400, 'INVALID_REQUEST', '缺参数 id');
      return doToc(module, id, res);
    }
    const id = pick('id');
    if (!id) return fail(res, 400, 'INVALID_REQUEST', '缺参数 id');
    return doContent(module, id, pick('chapterId') || pick('chapter'), res, origin);
  }

  return fail(res, 404, 'NOT_FOUND', `没有这个端点: ${p}`);
});

// 只有"直接被 node 跑起来"才开监听与广播。
// 被 require 时（比如自检脚本）只导出纯函数，不产生任何网络副作用——
// 否则谁 require 一下就会占住端口、往局域网发广播，很难排查。
if (require.main === module) {
  server.listen(PORT, BIND, () => {
    log(`THP 示例引擎已启动  http://${BIND}:${PORT}`);
    log(`  instanceId = ${IID}`);
    log(`  名         = ${NAME}`);
    log(`  caps       = ${CAPS.join(',')}   （模块: ${MODULES.join('/')}）`);
    log(`  身份       http://127.0.0.1:${PORT}/thp/meta`);
    log(`  试试       http://127.0.0.1:${PORT}/thp/m/novel/search?q=示例`);
    log(`  试试       http://127.0.0.1:${PORT}/thp/m/novel/toc?id=demo-1`);
    log(`  试试       http://127.0.0.1:${PORT}/thp/m/novel/content?id=demo-1::2`);
    if (!NO_BCAST) startBroadcast();
  });
}

// ═══════════════════════════════════════════════════════════════════
// UDP 广播（THP/1 HELLO，§4.1）
// ═══════════════════════════════════════════════════════════════════

const HELLO_PORT = 19527;

/**
 * 报文是**按空格切**的固定七段（§4.1）：
 *
 *   THP/1 HELLO <httpPort> <instanceId> <role> <caps> [name]
 *   例: THP/1 HELLO 1122 f47ac10b-...-e69b059e7f3c engine m:novel,m:comic 阅读引擎
 *
 * 两个必须注意的点：
 *  - caps 是**逗号连成的字符串**，不是数组、不是数字（数组没法塞进空格切分的段里）。
 *    这也是唯一一个"不能有空格"的字段——因为它后面紧跟 name。
 *  - name 允许带空格：前端真实正则末尾是 `(?:\s+(.*))?$`，会把剩余部分整段吃掉。
 *    但你的 name 若是空串就整段省略，前端同样认（规范里 name 是可选）。
 *    ⚠ 有些第三方解析器图省事用 `split(' ')` 硬切七段，遇到带空格的 name 会错位。
 *    前端不是这么写的，可放心用空格；要兼容这类实现就把空格换成下划线。
 *
 * 抽成纯函数是为了能离线自测——沙箱/公司网络常把 UDP 19527 拦掉，
 * 但"报文是不是合规、caps 是不是逗号串"这件事不该只有到真机上才能验。
 * 真机广播与自检调用的是同一个函数，验的就是真跑的那份。
 */
function buildHello(port, iid, role, capsField, name) {
  const head = `THP/1 HELLO ${port} ${iid} ${role} ${capsField}`;
  const safeName = String(name == null ? '' : name).trim();
  return safeName ? `${head} ${safeName}` : head;
}

/** 优雅下线报文（§4.1 必选）：让局域网前端立刻摘掉本引擎，不用等超时剔除。 */
function buildBye(iid) {
  return `THP/1 BYE ${iid}`;
}

/**
 * 解析广播报文——**前端侧要做的事**，这里给一份参照实现，方便你自查发出去的报文能被认。
 * 与前端真实正则对齐：^THP/1 HELLO (\d+) ([\w\-]+) (engine|library) ([\w:,\-]+)(?:\s+(.*))?$
 * 段数不足 6 或角色非法就返回 null —— 宁可不认，也不要拿半截报文去连接。
 */
function parseHello(text) {
  const s = String(text || '').trim();
  const bye = s.match(/^THP\/1 BYE ([\w\-]+)$/);
  if (bye) return { kind: 'bye', proto: 'THP/1', iid: bye[1] };
  const m = s.match(/^THP\/1 HELLO (\d+) ([\w\-]+) (engine|library) ([\w:,\-]+)(?:\s+(.*))?$/);
  if (!m) return null;
  const port = Number(m[1]);
  if (!Number.isFinite(port) || port <= 0 || port > 65535) return null;
  return {
    kind: 'hello',
    proto: 'THP/1',
    port: port,
    iid: m[2],
    role: m[3],
    caps: m[4].split(',').filter(Boolean),   // 字符串 → 数组
    name: m[5] || '',
  };
}

function broadcastAddrs() {
  const set = new Set(['255.255.255.255']);
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const a of ifaces[name] || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      const parts = a.address.split('.').map(Number);
      // 只按 /24 推定向广播地址。真实场景要看子网掩码，这里为示例从简。
      set.add(`${parts[0]}.${parts[1]}.${parts[2]}.255`);
    }
  }
  return [...set];
}

let BROADCAST_SOCK = null;

function startBroadcast() {
  const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  const packet = Buffer.from(buildHello(PORT, IID, 'engine', CAPS_FIELD, NAME), 'utf8');

  sock.on('error', (e) => log('广播出错(不影响 HTTP 服务): ' + e.message));
  sock.bind(() => {
    try { sock.setBroadcast(true); } catch (e) { log('不能开广播: ' + e.message); }
    const send = () => {
      for (const addr of broadcastAddrs()) {
        // 网卡会变（切 WiFi、插网线），所以每次重算地址，不要只在启动时算一次
        sock.send(packet, 0, packet.length, HELLO_PORT, addr, () => { /* 某些网段不可达，正常 */ });
      }
    };
    // 立即发一次，不等第一个周期——否则前端最长要等 30s 才发现你
    send();
    setInterval(send, HELLO_INTERVAL_SEC * 1000).unref();
    log(`广播中: 每 ${HELLO_INTERVAL_SEC}s 往 UDP ${HELLO_PORT} 发 "${packet.toString('utf8')}"`);
    BROADCAST_SOCK = sock;
  });
}

/** 优雅下线：发 BYE 再退出。漏了这步，前端要等 3×周期 才把你摘掉。 */
function shutdown(sig) {
  log(`收到 ${sig}，发 BYE 并退出`);
  try {
    if (BROADCAST_SOCK) {
      const bye = Buffer.from(buildBye(IID), 'utf8');
      for (const addr of broadcastAddrs()) {
        try { BROADCAST_SOCK.send(bye, 0, bye.length, HELLO_PORT, addr, () => {}); } catch (e) { /* 忽略 */ }
      }
    }
  } catch (e) { /* 退出路径上不抛异常 */ }
  // 让 Ctrl+C 时端口能被立刻复用，不然重跑会 EADDRINUSE
  setTimeout(() => process.exit(0), 200).unref();
  server.close(() => process.exit(0));
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

// 导出给自检脚本用（被 require 时不会启动服务，见上面的 require.main 守卫）。
module.exports = {
  buildHello, buildBye, parseHello,
  CAPS, CAPS_FIELD, MODULES, PROTOCOL, VERSION,
  DEGRADABLE, HELLO_PORT,
};
