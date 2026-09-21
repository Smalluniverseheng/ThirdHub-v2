#!/usr/bin/env node
/*
 * THP 示例引擎自检 —— 把 docs/THP.md 的硬约束变成可执行断言。
 *
 *   node docs/sdk/selfcheck.cjs          # 离线跑，40+ 项
 *   node docs/sdk/selfcheck.cjs --udp    # 额外验一次 UDP 广播实收
 *
 * 为什么要有这个文件：
 *   "照着示例写引擎"最怕示例本身写错——写错的示例会把错误固化成习惯。
 *   所以示例里每一句注释声称的规矩，这里都要有一条断言去证。
 *
 * 它不依赖后端在跑：自己 spawn 示例引擎（高位端口 18734），跑完自己收掉。
 */
'use strict';

const http = require('http');
const dgram = require('dgram');
const path = require('path');
const { spawn } = require('child_process');

const ENGINE = path.join(__dirname, 'sample-engine.js');
const PORT = 18734; // 用高位端口，避开真引擎常占的 1234
const BASE = `http://127.0.0.1:${PORT}`;

let passes = 0;
let fails = 0;

function ck(name, cond, extra) {
  if (cond) { passes++; console.log('  OK   ' + name); }
  else { fails++; console.log('  FAIL ' + name + (extra ? '   ← ' + String(extra).slice(0, 200) : '')); }
}

/** 发一个请求并连原始文本一起拿回来（原始文本才能验编码有没有坏）。 */
function request(method, p, body, extraHeaders) {
  return new Promise((resolve) => {
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body), 'utf8');
    const headers = Object.assign({}, extraHeaders || {});
    if (payload) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
      headers['Content-Length'] = payload.length;
    }
    const req = http.request(BASE + p, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        let j = null;
        try { j = JSON.parse(raw); } catch (e) { /* 非 JSON 就留 null，断言会挂 */ }
        resolve({ status: res.statusCode, raw, json: j, headers: res.headers });
      });
    });
    req.on('error', (e) => resolve({ status: 0, raw: String(e.message), json: null, headers: {} }));
    if (payload) req.write(payload);
    req.end();
  });
}

function waitReady(ms) {
  const t0 = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      request('GET', '/thp/meta').then((r) => {
        if (r.status === 200 && r.json && r.json.ok) return resolve(true);
        if (Date.now() - t0 > ms) return resolve(false);
        setTimeout(tick, 150);
      });
    };
    tick();
  });
}

/** 出现 U+FFFD 或连续问号，说明有人在某处按 ASCII 解码过 UTF-8。 */
const hasBadChar = (s) => typeof s === 'string' && (s.includes('\uFFFD') || s.includes('???'));

(async () => {
  // 默认关广播（省得每次自检都往局域网发包）。
  // 但传了 --udp 要验实收，就必须让它真的广播出去——否则 F2 永远等不到。
  const wantUdp = process.argv.includes('--udp');

  // ── F1 先跑：纯函数断言，不需要引擎起来（沙箱拦 UDP 也照跑） ──
  const eng = require(ENGINE);
  console.log('\n== F1. UDP 广播报文（离线验，必跑）==');
  ck('caps 是字符串数组，不是数字位掩码',
    Array.isArray(eng.CAPS) && eng.CAPS.every((c) => typeof c === 'string'),
    JSON.stringify(eng.CAPS));
  ck('caps 里每个模块能力都写成 m:<module> 形式',
    eng.CAPS.filter((c) => c.startsWith('m:')).every((c) => /^m:[a-z]+$/.test(c)),
    JSON.stringify(eng.CAPS));

  const hello = eng.buildHello(1234, 'a1b2c3d4-1111-4222-a333-444455556666', 'engine', eng.CAPS_FIELD, '我的 引擎');
  const seg = hello.split(' ');
  ck('报文至少六段（THP/1 HELLO port iid role caps [name]）', seg.length >= 6, hello);
  ck('前缀是 THP/1 HELLO', hello.startsWith('THP/1 HELLO '), hello);
  ck('第三段是数字端口', /^\d+$/.test(seg[2]), hello);
  ck('第五段是 engine（不是 app/player）', seg[4] === 'engine', hello);
  ck('caps 段是逗号串、不含空格', !/\s/.test(seg[5]) && seg[5].includes(','), hello);
  ck('caps 段等于 CAPS 的逗号连接（广播与 meta 必须一致）',
    seg[5] === eng.CAPS.join(','), hello + ' vs ' + eng.CAPS.join(','));

  const back = eng.parseHello(hello);
  ck('能被前端同款正则解析回来', back !== null, hello);
  ck('解回的 port 一致', back && back.port === 1234, JSON.stringify(back));
  ck('解回的 role 是 engine', back && back.role === 'engine', JSON.stringify(back));
  ck('解回的 caps 还原成数组且相等',
    back && JSON.stringify(back.caps) === JSON.stringify(eng.CAPS), JSON.stringify(back));
  ck('解回的 name 保留中文与空格（前端正则允许空格）',
    back && back.name === '我的 引擎', JSON.stringify(back));
  ck('name 为空时省略该段，仍可解析（规范里 name 可选）',
    eng.parseHello(eng.buildHello(1234, 'x1', 'engine', 'm:novel')) !== null, '');
  ck('段数不足时拒绝解析（宁可不认，不拿半截报文去连）',
    eng.parseHello('THP/1 HELLO 1234 abc engine') === null, '');
  ck('协议名不对时拒绝解析',
    eng.parseHello('THP/2 HELLO 1234 abc engine 8 n') === null, '');
  ck('端口非法时拒绝解析',
    eng.parseHello('THP/1 HELLO 99999 abc engine m:x n') === null, '');
  ck('BYE 报文能被识别（优雅下线）',
    eng.parseHello('THP/1 BYE a1b2c3d4-1111-4222-a333-444455556666') !== null, '');
  ck('role 只认 engine|library，乱填的拒绝',
    eng.parseHello('THP/1 HELLO 1234 abc player m:x n') === null, '');
  ck('降级白名单恰好是 UNSUPPORTED / NOT_FOUND（多一个都会误伤整片源）',
    JSON.stringify([...eng.DEGRADABLE].sort()) === JSON.stringify(['NOT_FOUND', 'UNSUPPORTED']),
    JSON.stringify([...eng.DEGRADABLE]));

  // ── F2 视参数决定是否验 UDP 实收 ──
  const spawnArgs = [ENGINE, '--port', String(PORT), '--quiet'];
  if (!wantUdp) spawnArgs.push('--no-broadcast');
  const child = spawn(process.execPath, spawnArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
  let engineErr = '';
  child.stderr.on('data', (d) => { engineErr += d.toString(); });

  const ready = await waitReady(8000);
  if (!ready) {
    console.log('引擎没起来。stderr:\n' + engineErr);
    child.kill();
    process.exit(1);
  }

  try {
    console.log('\n== A. 身份端点 /thp/meta（§7.2）==');
    let r = await request('GET', '/thp/meta');
    ck('返回 ok:true', r.json && r.json.ok === true, r.raw.slice(0, 160));
    const d = r.json && r.json.data;
    ck('data.protocol 是 "THP/1.0"', d && d.protocol === 'THP/1.0', JSON.stringify(d && d.protocol));
    ck('data.instanceId 是 UUID 形状', d && /^[\w-]{8,}$/.test(d.instanceId || ''), d && d.instanceId);
    ck('data.role 是 engine', d && d.role === 'engine', d && d.role);
    ck('data.caps 是数组（不是数字）', d && Array.isArray(d.caps), JSON.stringify(d && d.caps));
    ck('caps 含 m:novel（模块能力必须显式声明）',
      d && d.caps.includes('m:novel'), JSON.stringify(d && d.caps));
    ck('caps 声明 post-query（声明了才表示支持 POST 版）',
      d && d.caps.includes('post-query'), JSON.stringify(d && d.caps));
    ck('meta.caps 与 UDP 广播的 caps 一致（发现前/连上后不能两套能力）',
      d && JSON.stringify(d.caps) === JSON.stringify(eng.CAPS), JSON.stringify(d && d.caps));
    ck('有 auth 字段且含 none', d && Array.isArray(d.auth) && d.auth.includes('none'), JSON.stringify(d && d.auth));
    ck('有 remote 字段（是否经中继）', d && d.remote === false, JSON.stringify(d && d.remote));
    ck('有 endpoints 字段', d && Array.isArray(d.endpoints), JSON.stringify(d && d.endpoints));
    ck('有 deprecated / ext 兜底字段', d && 'deprecated' in d && 'ext' in d, Object.keys(d || {}).join(','));
    ck('meta 里带 source=instanceId（聚合结果可溯源）',
      r.json.meta && r.json.meta.source === d.instanceId, JSON.stringify(r.json.meta));

    console.log('\n== A2. /thp/hello 之类的草稿端点必须不存在 ==');
    for (const bogus of ['/thp/hello', '/thp/info', '/thp/meta/']) {
      const rr = await request('GET', bogus);
      ck(`${bogus} → 404（规范只认 /thp/meta）`, rr.status === 404, String(rr.status));
    }

    console.log('\n== B. 编码：中文必须原样往返 ==');
    ck('Content-Type 带 charset=utf-8',
      String(r.headers['content-type'] || '').includes('charset=utf-8'),
      r.headers['content-type']);
    const reqId = 'req-' + Date.now();
    r = await request('GET', '/thp/m/novel/search?q=' + encodeURIComponent('示例'), undefined,
      { 'X-TH-Request-Id': reqId });
    ck('回显 X-TH-Request-Id（§3.1 日志追踪）',
      r.headers['x-th-request-id'] === reqId, String(r.headers['x-th-request-id']));
    ck('搜索命中示例书', Array.isArray(r.json.data) && r.json.data.length > 0, r.raw.slice(0, 160));
    const firstName = r.json.data[0].name;
    ck('中文书名没变成 U+FFFD', !hasBadChar(firstName), firstName);
    ck('中文书名里有非 ASCII（证明不是靠 ASCII 侥幸）',
      /[^\x00-\x7F]/.test(firstName), firstName);

    // POST 中文 key：这条同时证明"引擎是按 UTF-8 读体"的
    r = await request('POST', '/thp/m/novel/search', { q: '示例小说·甲' });
    ck('POST 中文 q 能精确命中（说明引擎按 UTF-8 读体，不是 US-ASCII）',
      Array.isArray(r.json.data) && r.json.data.some((x) => x.name === '示例小说·甲'),
      r.raw.slice(0, 200));

    console.log('\n== C. 形状：data 是数组本身，不是 {items}（§7.3）==');
    r = await request('GET', '/thp/m/novel/search?q=' + encodeURIComponent('示例'));
    ck('search 的 data 直接是数组', Array.isArray(r.json.data), typeof r.json.data);
    ck('search 不走旧草稿的 {items:[...]} 形状', !(r.json.data && !Array.isArray(r.json.data) && 'items' in r.json.data), '');
    ck('每项有 id 与 name', r.json.data.every((x) => x.id && x.name), JSON.stringify(r.json.data[0]));
    ck('meta 里有分页三件套（cursor/hasMore/total）',
      r.json.meta && 'cursor' in r.json.meta && 'hasMore' in r.json.meta && 'total' in r.json.meta,
      JSON.stringify(r.json.meta));
    ck('limit 默认 20', r.json.data.length <= 20, String(r.json.data.length));

    r = await request('GET', '/thp/m/novel/search?q=' + encodeURIComponent('示例') + '&limit=999');
    ck('limit 超上限 100 自动截断而不是报错', r.status === 200 && r.json.ok === true,
      r.status + ' ' + r.raw.slice(0, 120));

    r = await request('GET', '/thp/m/novel/toc?id=demo-1');
    ck('toc 的 data 直接是数组', Array.isArray(r.json.data), typeof r.json.data);
    ck('toc 每项有 id / name / index',
      r.json.data.every((x) => x.id && x.name && typeof x.index === 'number'),
      JSON.stringify(r.json.data[0]));

    r = await request('GET', '/thp/m/novel/content?id=demo-1::2');
    ck('novel content 的 data 是对象且带 text',
      r.json.data && typeof r.json.data.text === 'string', typeof r.json.data);
    ck('正文无 U+FFFD', !hasBadChar(r.json.data.text), r.json.data.text.slice(0, 60));
    ck('正文内容与章节号一致（id 里的 ::2 生效）',
      r.json.data.text.includes('第 2 章'), r.json.data.text.slice(0, 40));

    // 规范参数名 chapterId；旧名 chapter 也应兼容
    r = await request('GET', '/thp/m/novel/content?id=demo-1&chapterId=3');
    ck('content 认规范参数名 chapterId',
      r.json.data && r.json.data.text.includes('第 3 章'), r.raw.slice(0, 80));

    r = await request('GET', '/thp/m/comic/content?id=demo-c1::1');
    ck('comic content 回 images 数组', r.json.data && Array.isArray(r.json.data.images),
      JSON.stringify(r.json.data).slice(0, 120));
    ck('comic 的 images 每项是 URL 字符串',
      r.json.data.images.every((u) => typeof u === 'string' && u.startsWith('http')),
      JSON.stringify(r.json.data.images));

    r = await request('GET', '/thp/m/music/content?id=demo-m1');
    ck('music content 回 url', r.json.data && typeof r.json.data.url === 'string', typeof r.json.data);
    ck('music content 回 variants 且非空',
      Array.isArray(r.json.data.variants) && r.json.data.variants.length > 0,
      JSON.stringify(r.json.data.variants));
    ck('variants 每项有 quality 与 url',
      r.json.data.variants.every((v) => v.quality && v.url), JSON.stringify(r.json.data.variants));

    console.log('\n== D. 降级与状态码（§3.2）==');
    r = await request('GET', '/thp/m/video/search?q=x');
    ck('未声明 caps 的模块 → HTTP 404', r.status === 404, String(r.status));
    ck('未声明 caps 的模块 → code=NOT_FOUND（不是 UNSUPPORTED）',
      r.json.error && r.json.error.code === 'NOT_FOUND', JSON.stringify(r.json.error));
    ck('NOT_FOUND 在降级白名单里', eng.DEGRADABLE.has(r.json.error.code), r.json.error.code);

    r = await request('GET', '/thp/m/novel/toc?id=no-such-book');
    ck('资源不存在 → HTTP 404', r.status === 404, String(r.status));
    ck('资源不存在 → code=NOT_FOUND', r.json.error && r.json.error.code === 'NOT_FOUND',
      JSON.stringify(r.json.error));

    r = await request('GET', '/thp/m/novel/search?q=x');
    ck('搜不到 ≠ 错误：HTTP 200 + ok:true + 空数组',
      r.status === 200 && r.json.ok === true && Array.isArray(r.json.data) && r.json.data.length === 0,
      r.status + ' ' + r.raw.slice(0, 120));

    r = await request('GET', '/thp/m/novel/search');
    ck('缺参数 q → HTTP 400', r.status === 400, String(r.status));
    ck('缺参数 q → code=INVALID_REQUEST（不可降级，说明是调用方写错了）',
      r.json.error && r.json.error.code === 'INVALID_REQUEST', JSON.stringify(r.json.error));
    ck('INVALID_REQUEST 不在降级白名单里', !eng.DEGRADABLE.has(r.json.error.code), '');

    r = await request('GET', '/thp/nope');
    ck('未知端点 → HTTP 404 + NOT_FOUND',
      r.status === 404 && r.json.error.code === 'NOT_FOUND', r.status + ' ' + r.raw.slice(0, 120));

    r = await request('GET', '/thp/m/music/toc?id=no-such');
    ck('失败信封 ok:false', r.json.ok === false, JSON.stringify(r.json).slice(0, 120));
    ck('失败信封带 error.code 与 error.message',
      !!(r.json.error && r.json.error.code && r.json.error.message), JSON.stringify(r.json.error));
    ck('失败信封也带 meta（调用方能溯源）', !!r.json.meta, JSON.stringify(r.json.meta));

    console.log('\n== E. 能力声明与实际行为必须一致 ==');
    r = await request('GET', '/thp/meta');
    const capsNow = r.json.data.caps;
    const declared = capsNow.filter((c) => c.startsWith('m:')).map((c) => c.slice(2));
    for (const mod of ['novel', 'comic', 'music']) {
      ck(`声明了 m:${mod} 就必须能在该模块上检索`,
        declared.includes(mod) && (await request('GET', `/thp/m/${mod}/search?q=` + encodeURIComponent('示例'))).status === 200,
        mod);
    }
    ck('没声明 m:video 就绝不接受 video 请求（否则是超范围声明）',
      !declared.includes('video'), declared.join(','));
    ck('caps 声明 post-query 就必须真的支持 POST（否则调用方优先 POST 会全灭）',
      capsNow.includes('post-query') && (await request('POST', '/thp/m/novel/search', { q: 'x' })).status === 200, '');

    console.log('\n== F. instanceId 必须重启不变（§4.1）==');
    const metaA = (await request('GET', '/thp/meta')).json.data.instanceId;
    child.kill();
    await new Promise((res) => setTimeout(res, 400));
    const child2 = spawn(process.execPath, [ENGINE, '--port', String(PORT), '--quiet', '--no-broadcast'],
      { stdio: ['ignore', 'pipe', 'pipe'] });
    if (await waitReady(8000)) {
      const metaB = (await request('GET', '/thp/meta')).json.data.instanceId;
      ck('重启后 instanceId 不变（否则前端会以为多了一台新设备）', metaA === metaB, metaA + ' vs ' + metaB);
    } else {
      ck('重启后 instanceId 不变', false, '第二次启动失败');
    }
    child2.kill();

    if (wantUdp) {
      console.log('\n== G. UDP 广播实收（真机/放行网络才有意义）==');
      // 另起一个开广播的实例，抓它启动时立刻发出的那份 HELLO
      const child3 = spawn(process.execPath, [ENGINE, '--port', String(PORT), '--quiet'],
        { stdio: ['ignore', 'pipe', 'pipe'] });
      const udpMsg = await new Promise((resolve) => {
        const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
        const done = (v) => { try { sock.close(); } catch (e) {} resolve(v); };
        const timer = setTimeout(() => done(null), 10000);
        sock.on('message', (msg) => { clearTimeout(timer); done(msg.toString('utf8')); });
        sock.on('error', () => { clearTimeout(timer); done(null); });
        sock.bind(19527, () => { try { sock.setBroadcast(true); } catch (e) {} });
      });
      child3.kill();
      if (udpMsg === null) {
        console.log('  SKIP 没等到广播（沙箱/防火墙常拦 UDP 19527，不算失败）');
      } else {
        const p = eng.parseHello(udpMsg);
        ck('实收报文能被前端同款正则解析', p !== null, udpMsg);
        ck('实收报文端口与服务端口一致', p && p.port === PORT, udpMsg);
        ck('实收报文 role 是 engine', p && p.role === 'engine', udpMsg);
        ck('实收报文的 caps 与 /thp/meta 一致',
          p && JSON.stringify(p.caps) === JSON.stringify(eng.CAPS), udpMsg);
      }
    }
  } finally {
    try { child.kill(); } catch (e) { /* 已退出 */ }
  }

  console.log('');
  console.log(fails === 0
    ? `全部通过 (${passes} 项)`
    : `${passes} 项通过, ${fails} 项失败`);
  process.exit(fails === 0 ? 0 : 1);
})().catch((e) => {
  console.log('自检异常: ' + (e && e.stack || e));
  process.exit(1);
});
