'use strict';
/**
 * 红果短剧源（★4.81.75 新增）
 *
 * 上游：openhongguo（Go 内核编译成 WASM，npm 包里自带，零第三方依赖）。
 *   node_modules 放 /patch/node_modules（宿主挂载，容器内只读，读不影响 import）。
 *
 * 为什么直接给 App 用而不是再套一层解密：
 *   实测（2026-11-20）红果返回的流虽然标 `protected: true` 并附 contentKey，
 *   但 CDN 实际返回的是**标准明文 MP4**（文件头 0000001c 66747970 = ftypisom），
 *   Range 请求 206 正常。所以不需要解密代理，直接把地址交给统一播放器即可。
 *   若将来平台真的开始加密，这里会先表现为"文件头不是 ftyp"，
 *   路由会如实报错，不会静默放黑屏。
 *
 * 接口（需要 x-th-token）：
 *   GET /v1/hongguo/search?q=关键词&limit=12
 *   GET /v1/hongguo/series?id=剧集ID
 *   GET /v1/hongguo/episodes?id=剧集ID
 *   GET /v1/hongguo/play?episodeId=分集ID
 *   GET /v1/hongguo/feed?limit=12        （发现页推荐）
 *
 * 实测：搜索「总裁」5 条；《总裁是我前女友》95 集；
 *   第 1 集 77 秒 / 360p / 1.8MB，URL 为明文 mp4。
 */

// ★可用环境变量覆盖：仓库里没有 node_modules（依赖装在补丁层/镜像内），
//   部署到别的机器时只需指一次路径，不必改代码。
const PKG = process.env.TH_HONGGU_PKG || '/patch/node_modules/openhongguo/index.js';
const PROFILE = process.env.TH_DATA_DIR ? require('path').join(process.env.TH_DATA_DIR, 'hongguo-device.json') : '/app/data/hongguo-device.json';

let _client = null;
let _loading = null;

async function client() {
  if (_client) return _client;
  if (_loading) return _loading;
  _loading = (async () => {
    const mod = await import(PKG);
    const c = await mod.createClient({
      profile: PROFILE,
      timeoutMs: 25000,
    });
    _client = c;
    return c;
  })();
  try {
    return await _loading;
  } finally {
    _loading = null;
  }
}

const _cache = new Map();
const CACHE_MAX = 300;

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
    for (const key of Array.from(_cache.keys()).slice(0, 80)) _cache.delete(key);
  }
  _cache.set(k, { v, exp: Date.now() + ttlMs });
}

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

/** 剧集条目 → App 的条目格式（尽量贴近 /v1/video/search 的字段）。 */
function seriesOut(s) {
  return {
    name: s.title || '',
    seriesId: String(s.id || ''),
    // 视频板块习惯用 vodId / id 这类字段，这里都给一份，减少前端适配分支
    id: String(s.id || ''),
    vodId: String(s.id || ''),
    coverUrl: s.cover_url || s.coverUrl || '',
    intro: s.description || '',
    episodeCount: num(s.episode_count ?? s.episodeCount),
    heat: num(s.heat),
    playCount: num(s.play_count),
    subtitle: s.subtitle || '',
    sourceId: 'hongguo',
    sourceName: '红果短剧',
  };
}

async function handle(req, res, body, u, p) {
  if (!p.startsWith('/v1/hongguo')) return false;
  if (p !== '/v1/hongguo' && !p.startsWith('/v1/hongguo/')) return false;

  const send = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(obj));
  };

  const op = p.slice('/v1/hongguo'.length).replace(/^\//, '');
  const q = u.searchParams;

  try {
    if (op === '' || op === 'status') {
      send(200, { ok: true, source: 'hongguo', name: '红果短剧', ready: !!_client });
      return true;
    }

    if (op === 'search') {
      const kw = (q.get('q') || q.get('key') || '').trim();
      if (!kw) {
        send(400, { ok: false, error: '缺少 q 参数' });
        return true;
      }
      const key = `s:${kw}`;
      let items = cget(key);
      if (!items) {
        const c = await client();
        const r = await withTimeout(c.search(kw, { pageSize: 20 }), 25000, '红果搜索');
        items = (r && r.items) || [];
        cset(key, items, 10 * 60 * 1000);
      }
      const limit = Math.min(num(q.get('limit'), 12) || 12, 30);
      send(200, {
        ok: true,
        sourceId: 'hongguo',
        sourceName: '红果短剧',
        total: items.length,
        data: items.slice(0, limit).map(seriesOut),
      });
      return true;
    }

    if (op === 'feed') {
      const key = 'feed';
      let items = cget(key);
      if (!items) {
        const c = await client();
        const r = await withTimeout(c.discover({ pageSize: 20 }), 25000, '红果推荐');
        items = (r && r.items) || [];
        cset(key, items, 8 * 60 * 1000);
      }
      const limit = Math.min(num(q.get('limit'), 12) || 12, 30);
      send(200, {
        ok: true,
        sourceId: 'hongguo',
        data: items.slice(0, limit).map(seriesOut),
      });
      return true;
    }

    if (op === 'series') {
      const id = (q.get('id') || q.get('seriesId') || '').trim();
      if (!id) {
        send(400, { ok: false, error: '缺少 id 参数' });
        return true;
      }
      const key = `d:${id}`;
      let s = cget(key);
      if (!s) {
        const c = await client();
        s = await withTimeout(c.getSeries(id), 20000, '红果详情');
        cset(key, s, 30 * 60 * 1000);
      }
      send(200, { ok: true, data: seriesOut(s || {}) });
      return true;
    }

    if (op === 'episodes') {
      const id = (q.get('id') || q.get('seriesId') || '').trim();
      if (!id) {
        send(400, { ok: false, error: '缺少 id 参数' });
        return true;
      }
      const key = `e:${id}`;
      let eps = cget(key);
      if (!eps) {
        const c = await client();
        // 红果短剧普遍 60~120 集，一次拉全（pageSize 上限内），
        // 否则 App 分页拉会把 95 集拆成好几次请求，体验反而差
        const page = await withTimeout(
          c.listEpisodes(id, { pageSize: 200 }),
          30000,
          '红果分集',
        );
        eps = ((page && page.items) || []).map((e) => ({
          name: e.title || `第${num(e.number)}集`,
          episodeId: String(e.id || ''),
          url: String(e.id || ''),
          index: num(e.number),
          playable: e.playable !== false,
          coverUrl: e.cover_url || '',
          vertical: !!e.vertical,
        }));
        cset(key, eps, 30 * 60 * 1000);
      }
      send(200, { ok: true, seriesId: id, total: eps.length, data: eps });
      return true;
    }

    if (op === 'play') {
      const eid = (q.get('episodeId') || q.get('id') || q.get('url') || '').trim();
      if (!eid) {
        send(400, { ok: false, error: '缺少 episodeId 参数' });
        return true;
      }
      const c = await client();
      const pb = await withTimeout(c.resolvePlayback(eid), 25000, '红果取播放地址');
      const playback = (pb && pb.playback) || {};
      const streams = playback.streams || [];
      if (!streams.length) {
        send(502, { ok: false, error: '红果没返回可播流（可能已下架）' });
        return true;
      }
      // 选最高清晰度：短剧清晰度档位少，用户更在意清楚而不是省流量
      const best = streams
        .slice()
        .sort((a, b) => num(b.height) - num(a.height) || num(b.bitrate) - num(a.bitrate))[0];
      send(200, {
        ok: true,
        data: {
          url: best.url || '',
          quality: best.definition || '',
          width: num(best.width),
          height: num(best.height),
          bitrate: num(best.bitrate),
          size: num(best.size),
          duration: num(playback.duration_seconds),
          // 如实告诉客户端：标记为 protected，但实测是明文 mp4。
          // 保留这个字段，将来平台真加密时前端能据此提示而不是黑屏。
          protectedFlag: !!playback.protected,
          streams: streams.map((s) => ({
            definition: s.definition || '',
            height: num(s.height),
            url: s.url || '',
          })),
        },
      });
      return true;
    }

    send(404, { ok: false, error: `未知操作: ${op}` });
    return true;
  } catch (e) {
    send(502, {
      ok: false,
      error: `红果源出错：${e && e.message ? e.message : String(e)}`,
      code: (e && e.code) || '',
      op,
    });
    return true;
  }
}

module.exports = { handle };
