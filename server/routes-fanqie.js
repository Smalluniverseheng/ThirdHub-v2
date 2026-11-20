'use strict';
/**
 * 番茄小说源（★4.81.75 新增）
 *
 * 为什么自己接而不用现成的书源：
 *   番茄的接口要匿名设备档案 + 签名，通用书源引擎跑不动；而 openfanqie
 *   已经把签名和设备注册封装好了（纯 ESM、零第三方依赖），直接当引擎用最省事。
 *
 * 位置说明：node_modules 放在 /patch/node_modules（宿主挂载，容器内只读）。
 *   只读不影响 require/import —— 我们只读不写。这样不必把 5MB 依赖复制进
 *   /app，也避免每次容器重启 cp 一遍。
 *
 * 接口（全部需要 x-th-token，与其它内容接口一致）：
 *   GET /v1/fanqie/search?q=关键词&limit=20
 *   GET /v1/fanqie/book?id=书籍ID
 *   GET /v1/fanqie/toc?id=书籍ID
 *   GET /v1/fanqie/content?id=书籍ID&itemId=章节ID
 *
 * 实测（2026-11-20）：搜索「诡秘之主」10 条；《十日终焉》目录 1496 章；
 *   首章正文 2410 字，开头与正版一致。
 */

// ★可用环境变量覆盖：仓库里没有 node_modules（依赖装在补丁层/镜像内），
//   部署到别的机器时只需指一次路径，不必改代码。
const PKG = process.env.TH_FANQIE_PKG || '/patch/node_modules/openfanqie/src/index.js';
// 设备档案必须落在持久盘：/app/data 就是宿主的 /vol1/docker/thirdhub/data
const PROFILE = process.env.TH_DATA_DIR ? require('path').join(process.env.TH_DATA_DIR, 'fanqie-device.json') : '/app/data/fanqie-device.json';

let _client = null;
let _loading = null;

/** 懒加载客户端：首次调用时 import（ESM）并注册匿名设备，之后复用。 */
async function client() {
  if (_client) return _client;
  if (_loading) return _loading;
  _loading = (async () => {
    const mod = await import(PKG);
    const c = new mod.FanqieClient({ profilePath: PROFILE });
    _client = c;
    return c;
  })();
  try {
    return await _loading;
  } finally {
    _loading = null;
  }
}

// ── 小缓存：目录/正文重复请求很多，缓存能显著减少对源站的压力 ──
const _cache = new Map();
const CACHE_MAX = 400;

function cget(k) {
  const e = _cache.get(k);
  if (!e) return null;
  if (e.exp < Date.now()) {
    _cache.delete(k);
    return null;
  }
  return e.v;
}

function cset(k, v, ttlMs) {
  if (_cache.size > CACHE_MAX) {
    // 简单淘汰：删掉最早插入的一批，够用且不会因为排序拖慢请求
    const drop = Array.from(_cache.keys()).slice(0, 100);
    for (const key of drop) _cache.delete(key);
  }
  _cache.set(k, { v, exp: Date.now() + ttlMs });
}

/**
 * 给上游调用套一个超时。
 * 注意：Promise.race 不会取消底层请求 —— 这里只能保证「不把用户吊死」，
 * 底层会在源站响应后自然结束。超时值给得比源站常见的 3~5s 宽。
 */
function withTimeout(p, ms, label) {
  let t;
  return Promise.race([
    p.finally(() => clearTimeout(t)),
    new Promise((_, rej) => {
      t = setTimeout(() => rej(new Error(`${label} 超时（${ms}ms）`)), ms);
    }),
  ]);
}

function num(v, d = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}

/** 统一成 App 好认的字段名（与 /v1/search 的书条目尽量对齐）。 */
function bookOut(b) {
  return {
    name: b.title || '',
    author: b.author || '',
    bookUrl: String(b.bookId || ''),
    bookId: String(b.bookId || ''),
    coverUrl: b.coverUrl || b.coverUrlHd || '',
    intro: b.abstract || b.shortAbstract || '',
    wordCount: num(b.wordCount),
    chapterCount: num(b.contentChapterNumber),
    category: b.category || '',
    status: b.creationStatus || (b.isFinished ? '完结' : '连载'),
    score: num(b.score),
    sourceId: 'fanqie',
    sourceName: '番茄小说',
  };
}

async function handle(req, res, body, u, p) {
  if (!p.startsWith('/v1/fanqie')) return false;
  if (p !== '/v1/fanqie' && !p.startsWith('/v1/fanqie/')) return false;

  const send = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(obj));
  };

  const op = p.slice('/v1/fanqie'.length).replace(/^\//, '');
  const q = u.searchParams;

  try {
    if (op === '' || op === 'status') {
      send(200, { ok: true, source: 'fanqie', name: '番茄小说', ready: !!_client });
      return true;
    }

    if (op === 'search') {
      const kw = (q.get('q') || q.get('key') || '').trim();
      if (!kw) {
        send(400, { ok: false, error: '缺少 q 参数' });
        return true;
      }
      const key = `s:${kw}`;
      let hit = cget(key);
      if (!hit) {
        const c = await client();
        const r = await withTimeout(c.search(kw, { tab: 'book' }), 25000, '番茄搜索');
        hit = (r && r.books) || [];
        cset(key, hit, 10 * 60 * 1000);
      }
      const limit = Math.min(num(q.get('limit'), 20) || 20, 50);
      send(200, {
        ok: true,
        sourceId: 'fanqie',
        sourceName: '番茄小说',
        total: hit.length,
        data: hit.slice(0, limit).map(bookOut),
      });
      return true;
    }

    if (op === 'book') {
      const id = (q.get('id') || q.get('bookId') || '').trim();
      if (!id) {
        send(400, { ok: false, error: '缺少 id 参数' });
        return true;
      }
      const key = `b:${id}`;
      let hit = cget(key);
      if (!hit) {
        const c = await client();
        hit = await withTimeout(c.bookInfo(id), 20000, '番茄详情');
        cset(key, hit, 30 * 60 * 1000);
      }
      send(200, { ok: true, data: bookOut(hit || {}) });
      return true;
    }

    if (op === 'toc') {
      const id = (q.get('id') || q.get('bookId') || '').trim();
      if (!id) {
        send(400, { ok: false, error: '缺少 id 参数' });
        return true;
      }
      const key = `t:${id}`;
      let chs = cget(key);
      if (!chs) {
        const c = await client();
        const cat = await withTimeout(c.catalog(id), 35000, '番茄目录');
        const raw = (cat && cat.chapters) || [];
        chs = raw.map((x, i) => ({
          name: x.title || `第${i + 1}章`,
          // 用 itemId 当 url，和 App 里书源的"章节地址"语义一致
          url: String(x.itemId || ''),
          index: num(x.index, i),
          volume: x.volumeName || '',
          words: num(x.wordNumber),
        }));
        cset(key, chs, 60 * 60 * 1000);
      }
      send(200, {
        ok: true,
        bookId: id,
        total: chs.length,
        data: chs,
      });
      return true;
    }

    if (op === 'content') {
      const id = (q.get('id') || q.get('bookId') || '').trim();
      const itemId = (q.get('itemId') || q.get('url') || '').trim();
      if (!id || !itemId) {
        send(400, { ok: false, error: '缺少 id 或 itemId 参数' });
        return true;
      }
      const key = `c:${id}:${itemId}`;
      let text = cget(key);
      if (!text) {
        const c = await client();
        const ch = await withTimeout(c.chapter(id, itemId), 25000, '番茄正文');
        text = (ch && (ch.text || (Array.isArray(ch.paragraphs) ? ch.paragraphs.join('\n') : ''))) || '';
        // 空正文不缓存，否则一次抖动会把这个章节永久判死
        if (text) cset(key, text, 6 * 60 * 60 * 1000);
      }
      if (!text) {
        send(502, { ok: false, error: '正文为空，可能是付费章或源站限流' });
        return true;
      }
      send(200, {
        ok: true,
        data: {
          text,
          chars: text.length,
          paragraphs: text.split('\n').filter((s) => s.trim()).length,
        },
      });
      return true;
    }

    send(404, { ok: false, error: `未知操作: ${op}` });
    return true;
  } catch (e) {
    // 不吞异常：把原因原样回给 App，否则用户只看到"空白"不知道是源挂了还是限流
    send(502, {
      ok: false,
      error: `番茄源出错：${e && e.message ? e.message : String(e)}`,
      op,
    });
    return true;
  }
}

module.exports = { handle };
