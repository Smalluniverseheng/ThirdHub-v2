// THP 兼容层 —— 让「NAS 后端」被 App 当成一台**资料库（引擎）**来用。
//
// 为什么要有这一层：
//   App 里小说/漫画/影视/音乐的搜索走的是 `/thp/search`（THP 是资料库协议），
//   连接对象是「资料库引擎」（局域网某台设备 1234 端口）。后端 9527 只提供
//   /v1/* 那套 REST，两边协议不通 → **各模块搜索永远碰不到 NAS**，
//   用户看到的就是「只能搜本地资料库，用不上后端」。
//
//   与其在每个模块页里改调用点（要动四五处 UI、还要兼容老版本引擎），
//   不如让后端**同时说 THP**：App 连上 NAS 就等于连上一台资料库，
//   而且这台资料库背后是 2000+ 书源 / 254 个已探活源，比手机本地引擎强得多。
//
// 协议要点（对齐 App 端 core/engine_direct.dart）：
//   GET /thp/meta                          → { ok, data:{ name, version, caps } }
//   GET /thp/search?type=&q=&page=&limit=&budget=
//         → { ok, data:{ items:[…] }, page, total, hasMore, truncated, budgetSec,
//             scannedSources, totalSources }
//         ★ App 从**响应顶层**读 page/total/hasMore/truncated（见 SearchPage.from），
//           所以这些字段必须和 data 平级，不能埋进 data 里。
//   GET /thp/chapters?url=&sourceId=       → { ok, data:{ items:[{name,url}], chapters:[…] } }
//   GET /thp/content?url=&sourceId=        → { ok, data:{ text, content } }
//   GET /thp/m/{module}/{op}               → 同 /thp/{op}（规范端点别名）
'use strict';

const fs = require('fs');
const path = require('path');

const DATA = path.join(__dirname, 'data');
const SRC_FILE = path.join(DATA, 'sources.json');
const URLMAP_FILE = path.join(DATA, 'thp-urlmap.json');

let engine = null;
try { engine = require('./engine.js'); } catch (e) { engine = null; }

// ─────────────────────────────────────────────────────────────
// 媒体反向代理（2026-11-14 加）
//
// 为什么必须有：源站的 m3u8 分片经常在**另一个域名**上，且不带浏览器 UA 就 403
// （实测 v6.ppqrrs.com 的清单 200，分片 v6.adfg8.vip/xxx.ts 裸请求 403、带 UA 200）。
// 而 ExoPlayer 发的是自己的 UA → 手机上一律 `Source error`。
// App 侧没法给每个分片加头（播放器只认一个入口 URL），所以在 NAS 侧做一层：
//   · App 只拿到 http://<nas>:9528/thp/stream?u=<原始地址>
//   · 清单里的每一行（含 EXT-X-KEY/MAP 的 URI）都改写成再走这层
//   · 分片透传，自动补 UA/Referer，支持 Range
// 用明文 HTTP 是因为 ExoPlayer 不走 Dart 的 HttpOverrides，不认我们的自签证书。
const MEDIA_PORT = parseInt(process.env.TH_MEDIA_PORT || '9528', 10);
const PROXY_UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

function lanHostOnly() {
  const s = (process.env.TH_LAN_URL || '').trim();
  try { if (s) return new URL(s).hostname; } catch (e) {}
  return '127.0.0.1';
}

function mediaBase() {
  return 'http://' + lanHostOnly() + ':' + MEDIA_PORT;
}

/** 把一个可播放地址包成走本机代理的地址 */
function wrapMedia(u, referer) {
  if (!u || !/^https?:\/\//i.test(u)) return u;
  let out = mediaBase() + '/thp/stream?u=' + encodeURIComponent(u);
  if (referer) out += '&r=' + encodeURIComponent(referer);
  return out;
}

function startMediaProxy() {
  const http = require('http');
  const srv = http.createServer(async (req, res) => {
    const cors = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Range,Content-Type',
      'Access-Control-Expose-Headers': 'Content-Length,Content-Range,Accept-Ranges',
    };
    if (req.method === 'OPTIONS') { res.writeHead(204, cors); res.end(); return; }
    let args;
    try { args = new URL(req.url, 'http://x'); } catch (e) { res.writeHead(400, cors); res.end('bad url'); return; }
    if (args.pathname !== '/thp/stream' && args.pathname !== '/stream') {
      res.writeHead(404, { ...cors, 'Content-Type': 'text/plain' }); res.end('not found'); return;
    }
    const target = args.searchParams.get('u') || '';
    const ref = args.searchParams.get('r') || '';
    if (!/^https?:\/\//i.test(target)) { res.writeHead(400, cors); res.end('bad target'); return; }

    const headers = { 'User-Agent': PROXY_UA, 'Accept': '*/*', 'Accept-Language': 'zh-CN,zh;q=0.9' };
    if (ref) headers['Referer'] = ref;
    if (req.headers.range) headers['Range'] = req.headers.range;

    let up;
    try {
      up = await fetch(target, { headers, signal: AbortSignal.timeout(30000), redirect: 'follow' });
    } catch (e) {
      res.writeHead(502, { ...cors, 'Content-Type': 'text/plain' }); res.end('upstream error: ' + String(e.message || e)); return;
    }

    const ctype = String(up.headers.get('content-type') || '');
    const isPlaylist = /mpegurl/i.test(ctype) || /\.m3u8(\?|$)/i.test(target);

    if (isPlaylist) {
      const text = await up.text();
      const baseUrl = target;             // 相对地址按清单自身位置解析
      const out = [];
      for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line) { out.push(''); continue; }
        if (line.startsWith('#')) {
          // EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA 里的 URI 也要过代理，否则密钥/init 片会 403
          const rewritten = line.replace(/URI="([^"]+)"/g, (m, uri) => {
            let abs = uri;
            try { abs = new URL(uri, baseUrl).toString(); } catch (e) {}
            return 'URI="' + wrapMedia(abs, ref) + '"';
          });
          out.push(rewritten);
          continue;
        }
        let abs = line;
        try { abs = new URL(line, baseUrl).toString(); } catch (e) {}
        out.push(wrapMedia(abs, ref));
      }
      const body = out.join('\n');
      // 清单是文本、且被我们重写过长度变了：一律 200 全量返回，别沿用上游的 206/Content-Range，
      // 否则播放器会以为拿到的是片段而反复重试。
      res.writeHead(200, {
        ...cors,
        'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
        'Cache-Control': 'no-store',
        'Content-Length': Buffer.byteLength(body),
      });
      res.end(body);
      return;
    }

    // 分片 / mp4：原样透传，保留 Range 语义
    const h = { ...cors, 'Content-Type': ctype || 'application/octet-stream', 'Accept-Ranges': 'bytes' };
    for (const k of ['content-length', 'content-range', 'etag', 'last-modified']) {
      const v = up.headers.get(k);
      if (v) h[k.replace(/(^|-)([a-z])/g, (m, a, b) => a + b.toUpperCase())] = v;
    }
    res.writeHead(up.status, h);
    if (!up.body) { res.end(); return; }
    const { Readable } = require('stream');
    Readable.fromWeb(up.body).on('error', () => {}).pipe(res);
  });
  srv.on('error', (e) => {
    if (e && e.code === 'EADDRINUSE') console.log('[thp] 媒体代理端口 ' + MEDIA_PORT + ' 已被占用');
    else console.log('[thp] 媒体代理启动失败:', String(e && e.message || e));
  });
  srv.listen(MEDIA_PORT, '0.0.0.0', () => {
    console.log('[thp] 媒体反向代理 http://0.0.0.0:' + MEDIA_PORT + '/thp/stream (补 UA/Referer + 清单改写)');
  });
}

try { startMediaProxy(); } catch (e) { console.log('[thp] 媒体代理未启动:', String(e && e.message || e)); }

// ─── 源清单（带缓存，避免每次搜索都读 2MB JSON）───
let _cache = { at: 0, list: [] };
function sources() {
  const now = Date.now();
  if (now - _cache.at < 60000 && _cache.list.length) return _cache.list;
  try {
    const all = JSON.parse(fs.readFileSync(SRC_FILE, 'utf8'));
    _cache = { at: now, list: Array.isArray(all) ? all : [] };
  } catch (e) {
    _cache = { at: now, list: [] };
  }
  return _cache.list;
}

// 分组可信度：`已探活`（实测能搜出结果）最高 —— 与 routes-search 的 grpScore 同口径
function gs(s) {
  const g = String((s && s.bookSourceGroup) || '');
  if (g.includes('已探活')) return 120;
  if (g.includes('校验可用')) return 100;
  if (g.includes('精选')) return 85;
  if (g.includes('优选')) return 80;
  if (g.includes('通常')) return 50;
  return 30;
}

// ─── book/chapter URL → 用哪个源的规则解析 ───
// 两个来源：① 搜索时记下的 url→sourceId 映射（最准）；② 按**域名**反查源
//   （书源的 bookSourceUrl 与目标 url 同域，基本可以确定是同一个站）。
// 有了域名兜底，即使 App 打开阅读页时没带 sourceId 也能解析 —— 这是整条链最脆弱的一环。
function loadUrlMap() {
  try { return JSON.parse(fs.readFileSync(URLMAP_FILE, 'utf8')); } catch (e) { return {}; }
}
let _mapCache = { at: 0, map: {} };
function urlMap() {
  const now = Date.now();
  if (now - _mapCache.at < 30000) return _mapCache.map;
  _mapCache = { at: now, map: loadUrlMap() };
  return _mapCache.map;
}
function remember(url, sourceUrl) {
  if (!url || !sourceUrl) return;
  const m = urlMap();
  if (m[url] === sourceUrl) return;
  m[url] = sourceUrl;
  // 只保留最近 5000 条，避免无限膨胀
  const keys = Object.keys(m);
  if (keys.length > 5000) for (const k of keys.slice(0, keys.length - 5000)) delete m[k];
  _mapCache = { at: Date.now(), map: m };
  try { fs.writeFileSync(URLMAP_FILE, JSON.stringify(m), 'utf8'); } catch (e) {}
}

function hostOf(u) {
  try { return new URL(String(u)).host.toLowerCase(); } catch (e) { return ''; }
}

function resolveSource(url, sourceId) {
  const list = sources();
  if (sourceId) {
    const hit = list.find((s) => String(s.bookSourceUrl || '') === String(sourceId));
    if (hit) return hit;
    // sourceId 有时带尾斜杠差异
    const n = String(sourceId).replace(/\/+$/, '');
    const hit2 = list.find((s) => String(s.bookSourceUrl || '').replace(/\/+$/, '') === n);
    if (hit2) return hit2;
  }
  const mapped = urlMap()[url];
  if (mapped) {
    const hit = list.find((s) => String(s.bookSourceUrl || '') === mapped);
    if (hit) return hit;
  }
  const h = hostOf(url);
  if (!h) return null;
  const cands = list.filter((s) => hostOf(s.bookSourceUrl) === h);
  if (!cands.length) return null;
  cands.sort((a, b) => gs(b) - gs(a));
  return cands[0];
}

// ─── 搜索 ───
// 与 routes-search 里的聚合不同：这里**按 THP 语义**做（一页 N 条、可翻页、
// 带 truncated/scannedSources），因为 App 的模块页就是按这个显示和翻页的。
async function searchBooks(type, q, page, limit, budgetMs) {
  if (!engine) return { items: [], scanned: 0, total: 0 };
  const list = sources().filter((s) => s.searchUrl && s.bookSourceUrl && s.enabled !== false);
  list.sort((a, b) => gs(b) - gs(a));
  const perPage = Math.max(8, Math.min(40, limit || 40));
  const takeN = 24;                        // 第一页扫 24 个最可信的源
  const pool = list.slice(0, takeN);

  const t0 = Date.now();
  const out = [];
  const seen = new Set();
  let scanned = 0;
  let truncated = false;
  let enough = false;

  // 垃圾条目过滤：实测有些源会返回整页导航/计数，书名是 "1"、"上一页" 之类。
  // 不滤掉的话列表第一屏全是废条目，用户会以为"搜索还是坏的"。
  const JUNK = /^(上一页|下一页|首页|末页|目录|阅读|下载|更多|登录|注册|\d+|\d+\/\d+)$/;
  const okName = (n) => {
    const s = String(n || '').replace(/\s+/g, ' ').trim();
    if (s.length < 2 || s.length > 60) return false;
    if (JUNK.test(s)) return false;
    if (/\d+\s*\/\s*\d+/.test(s)) return false;      // "1/11" 这种分页文本
    if (!/[\u4e00-\u9fa5A-Za-z]/.test(s)) return false;
    return true;
  };

  const CONC = 12;
  for (let i = 0; i < pool.length; i += CONC) {
    if (Date.now() - t0 > budgetMs) { truncated = true; break; }
    const batch = pool.slice(i, i + CONC);
    const remain = Math.max(3000, budgetMs - (Date.now() - t0));
    const per = Math.min(6000, remain);
    const rs = await Promise.all(batch.map(async (s) => {
      try {
        // 单源外加上限：引擎内部是 12s×2 次重试，串起来能把一页拖到 20s+。
        // 这里超时就当作这一源没结果，不再等它（它自己会在 TH_FETCH_TIMEOUT 内结束）。
        const books = await Promise.race([
          engine.search(s, q),
          new Promise((r) => setTimeout(() => r(null), per)),
        ]);
        scanned++;
        return { s, books: books || [] };
      } catch (e) { scanned++; return { s, books: [] }; }
    }));
    for (const { s, books } of rs) {
      for (const b of books) {
        if (!okName(b.name)) continue;
        const key = String(b.name || '').replace(/\s+/g, '') + '|' + String(b.author || '').replace(/\s+/g, '');
        if (seen.has(key)) continue;
        seen.add(key);
        const sourceUrl = String(s.bookSourceUrl || '');
        remember(b.bookUrl, sourceUrl);
        out.push({
          name: b.name,
          title: b.name,
          author: String(b.author || '').replace(/\s+/g, ' ').trim(),
          cover: b.coverUrl || '',
          coverUrl: b.coverUrl || '',
          intro: b.intro || '',
          kind: b.kind || '',
          lastChapter: b.lastChapter || '',
          url: b.bookUrl || '',
          bookUrl: b.bookUrl || '',
          sourceId: sourceUrl,
          source: sourceUrl,
          sourceName: String(s.bookSourceName || ''),
          type: type === 'comic' ? 'comic' : 'novel',
        });
      }
    }
    if (out.length >= perPage * page) { enough = true; break; }
  }

  out.sort((a, b) => {
    // 相关性优先：**书名里含关键词的排前面**，再按书名长度（短的更可能是正主）。
    // 实测不加这一步时，搜「斗罗大陆」第一条会是「圣邪之泪」——因为源返回的是
    // 模糊匹配（同站热门），直接按原顺序铺出去，用户第一眼就以为搜错了。
    const k = String(q).replace(/\s+/g, '');
    const ca = String(a.name).replace(/\s+/g, '').includes(k) ? 1 : 0;
    const cb = String(b.name).replace(/\s+/g, '').includes(k) ? 1 : 0;
    if (ca !== cb) return cb - ca;
    // 完全等于关键词的更靠前
    const ea = String(a.name).replace(/\s+/g, '') === k ? 1 : 0;
    const eb = String(b.name).replace(/\s+/g, '') === k ? 1 : 0;
    if (ea !== eb) return eb - ea;
    return String(a.name).length - String(b.name).length;
  });
  const from = (page - 1) * perPage;
  const items = out.slice(from, from + perPage);
  return { items, scanned, total: out.length, truncated };
}

// ─── 播放地址二次解析 ───
//
// CMS 采集源给回来的"播放地址"有三种形态（实测）：
//   · 直接是 m3u8          → 无尽资源。可以直接播
//   · /play/<id> 播放页     → 极速资源。页面里 `const vid='…/index.m3u8'`，能提取
//   · /share/<hash> 分享页  → 量子、非凡。页面靠 JS 生成，纯抓取拿不到
//
// 不处理的话，App 播放器拿到的是一张 HTML 页面 → **只出封面、播不出画面**
// （用户报的"只能加载出封面"就是这种）。
// 这里做通用解析：能解出来的换成真直链；解不出来的原样返回，
// 让 App 至少还能拿着它试（换一个源的结果就好了）。
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';

function fetchText(url, referer, timeoutMs = 8000) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(url); } catch (e) { return resolve(''); }
    const lib = u.protocol === 'https:' ? require('https') : require('http');
    const t = setTimeout(() => { try { req.destroy(); } catch (e) {} resolve(''); }, timeoutMs);
    const req = lib.request({
      hostname: u.hostname, port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search, method: 'GET',
      headers: {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        ...(referer ? { 'Referer': referer } : {}),
      },
      rejectUnauthorized: false,
    }, (r) => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
        clearTimeout(t);
        try { req.destroy(); } catch (e) {}
        return fetchText(new URL(r.headers.location, url).href, referer, timeoutMs).then(resolve);
      }
      const cs = []; let n = 0;
      r.on('data', (d) => { n += d.length; if (n < 400000) cs.push(d); });
      r.on('end', () => { clearTimeout(t); resolve(Buffer.concat(cs).toString('utf8')); });
    });
    req.on('error', () => { clearTimeout(t); resolve(''); });
    req.end();
  });
}

function looksPlayable(u) { return /\.(m3u8|mp4)(\?|#|$)/i.test(String(u || '')); }

async function resolveStream(rawUrl) {
  const url = String(rawUrl || '').trim();
  if (!url) return { url: '', header: {} };
  if (looksPlayable(url)) return { url, header: {} };

  // ① /play/<id> 这类：先按常见规律拼 index.m3u8（极速资源就是这种）
  if (/\/play\/[^/?#]+$/.test(url)) {
    try {
      const cand = url.replace(/\/+$/, '') + '/index.m3u8';
      const head = await fetchText(cand, url, 6000);
      if (head && head.includes('#EXTM3U')) {
        return { url: cand, header: { 'Referer': url, 'User-Agent': UA } };
      }
    } catch (e) {}
  }

  // ② 抓页面，从 HTML/JS 里挖 m3u8 / mp4（含 `const vid='…'`、`url: "…"` 这些写法）
  const html = await fetchText(url, url, 8000);
  if (html) {
    const cands = [];
    const re = /https?:\/\/[^\s'"\\<>()]+?\.(?:m3u8|mp4)(?:\?[^\s'"\\<>()]*)?/gi;
    let m;
    while ((m = re.exec(html)) && cands.length < 8) cands.push(m[0]);
    if (cands.length) {
      // 优先 m3u8
      const pick = cands.find((c) => /\.m3u8/i.test(c)) || cands[0];
      return { url: pick, header: { 'Referer': url, 'User-Agent': UA } };
    }
    // 有些站把地址放在 `var url = "/xxx/index.m3u8"` 这种相对路径里
    const rel = html.match(/["'](\/[^"'\s]*?\.m3u8)["']/i);
    if (rel) {
      try {
        const abs = new URL(rel[1], url).href;
        return { url: abs, header: { 'Referer': url, 'User-Agent': UA } };
      } catch (e) {}
    }
  }
  // ③ 解不出来：原样返回（至少不是空），并带上 Referer 让播放器有机会
  return { url, header: { 'Referer': url, 'User-Agent': UA } };
}

// ─── 目录 / 正文 ───
//
// ★★ 2026-11-14 关键修正：App 的真实参数是 `id` + `chapter`，不是 `url` + `sourceId`。
//   （core/engine_direct.dart: `/thp/chapters?type=$type&id=<bookUrl>`、
//     `/thp/content?type=novel&id=<bookUrl>&chapter=<章节url>`、
//     影视/漫画走规范端点 `/thp/m/{mod}/content?id=&chapter=`）
//   上一版只认 url/sourceId → 目录恒空 → **封面能搜出来、点进去什么都没有**。
//   现在两个参数名都收，按 type 分发到各自的取数实现。

function qOf(u, ...names) {
  for (const n of names) {
    const v = u.searchParams.get(n);
    if (v != null && String(v).trim() !== '') return String(v).trim();
  }
  return '';
}

// 本地自调用（转发到已有的 /v1/* 实现，带内部令牌）
async function localGet(pathAndQuery) {
  const https = require('https');
  const http = require('http');
  const port = process.env.PORT || 9527;
  const url = `https://127.0.0.1:${port}${pathAndQuery}`;
  const body = await new Promise((resolve) => {
    const req = https.request(url, {
      method: 'GET',
      rejectUnauthorized: false,
      headers: { 'x-th-token': internalToken(), 'user-agent': 'thp-bridge' },
      timeout: 25000,
    }, (r) => {
      const cs = []; r.on('data', (d) => cs.push(d));
      r.on('end', () => resolve(Buffer.concat(cs).toString('utf8')));
    });
    req.on('error', () => resolve(''));
    req.on('timeout', () => { try { req.destroy(); } catch (e) {} resolve(''); });
    req.end();
  });
  try { return JSON.parse(body); } catch (e) { return null; }
}

// 影视/音乐的 item.id 编码成 `v1|<sourceId>|<原始id>`：
// 因为 App 的 content 只把 id + chapter 传回来，没有 sourceId 的位置，
// 不编码就没法知道去哪个源取详情/播放地址。
function packId(kind, sourceId, id) { return kind + '|' + sourceId + '|' + id; }
function unpackId(v) {
  const s = String(v || '');
  const i = s.indexOf('|');
  const j = s.indexOf('|', i + 1);
  if (i < 0 || j < 0) return null;
  return { kind: s.slice(0, i), sourceId: s.slice(i + 1, j), id: s.slice(j + 1) };
}

async function chaptersOf(type, id, u) {
  const t = String(type || 'novel');

  // ── 影视：详情里的 episodes 就是剧集列表 ──
  if (t === 'video') {
    const pk = unpackId(id);
    let sourceId = pk ? pk.sourceId : qOf(u, 'sourceId', 'source');
    let vid = pk ? pk.id : id;
    if (!sourceId) return null;

    // ★B 站是"虚拟影视源"：用分P列表当剧集，不需要 CMS 的 detail 接口
    if (sourceId === 'bili') {
      const pg = await localGet('/v1/bili/pages?bvid=' + encodeURIComponent(vid));
      const pages = (pg && pg.pages) || [];
      const items = pages.map((p) => ({
        name: pages.length > 1 ? ('P' + p.page + ' ' + (p.part || '')) : '正片',
        title: p.part || ('P' + p.page),
        url: 'ep|bili|' + String(p.cid),
      }));
      if (!items.length) return null;
      return { items, chapters: items, sourceId, name: '' };
    }

    const d = await localGet(`/v1/video/detail?sourceId=${encodeURIComponent(sourceId)}&id=${encodeURIComponent(vid)}`);
    const data = (d && d.data) || {};
    const eps = data.episodes || data.chapters || [];
    const items = eps.map((e, i) => ({
      name: String(e.name || `第${i + 1}集`),
      title: String(e.name || `第${i + 1}集`),
      // chapter 回传时带 flag：播放要用它
      url: 'ep|' + String(e.flag || e.line || '') + '|' + String(e.url || ''),
    })).filter((x) => x.url.length > 4);
    return { items, chapters: items, sourceId, name: data.name || '' };
  }

  // ── 音乐：单曲没有目录，给一条占位 ──
  if (t === 'music') {
    const pk = unpackId(id);
    const items = [{ name: '播放', title: '播放', url: 'track|' + (pk ? pk.id : id) }];
    return { items, chapters: items, sourceId: pk ? pk.sourceId : '' };
  }

  // ── 漫画：交给已有的漫画注册表 ──
  if (t === 'comic') {
    const pk = unpackId(id);
    if (!pk) return null;
    const d = await localGet(`/v1/comic/info?sourceId=${encodeURIComponent(pk.sourceId)}&id=${encodeURIComponent(pk.id)}`);
    const data = (d && d.data) || {};
    const chs = data.chapters || data.episodes || [];
    const items = chs.map((ch, i) => ({
      name: String(ch.name || ch.title || `第${i + 1}话`),
      title: String(ch.name || ch.title || `第${i + 1}话`),
      url: String(ch.id || ch.url || ch.chapterId || ''),
    })).filter((x) => x.url);
    return { items, chapters: items, sourceId: pk.sourceId, name: data.name || '' };
  }

  // ── 小说（默认）：书源目录 ──
  const s = resolveSource(id, qOf(u, 'sourceId', 'source'));
  if (!s) return null;
  const arr = await engine.catalog(s, id);
  const items = (arr || []).map((c) => ({
    name: c.name || c.title || '',
    title: c.name || c.title || '',
    url: c.url || c.chapterUrl || '',
  })).filter((c) => c.url);
  for (const c of items) remember(c.url, String(s.bookSourceUrl || ''));
  return { items, chapters: items, sourceId: String(s.bookSourceUrl || '') };
}

async function contentOf(type, id, chapter, u) {
  const t = String(type || 'novel');

  // ── 影视：episode → /v1/video/play 换真实播放地址 ──
  if (t === 'video') {
    const pk = unpackId(id);
    const sourceId = pk ? pk.sourceId : qOf(u, 'sourceId', 'source');
    if (!sourceId) return null;

    // ★B 站虚拟源：章节目录是 'ep|bili|<cid>'，播放走 /v1/bili/playurl（直链已过媒体代理）
    if (sourceId === 'bili') {
      const chB = String(chapter || '');
      const cid = chB.startsWith('ep|bili|') ? chB.slice(8) : chB.replace(/^ep\|[^|]*\|/, '');
      const bvid = pk ? pk.id : String(id || '');
      if (!cid || !bvid) return null;
      const d = await localGet(`/v1/bili/playurl?bvid=${encodeURIComponent(bvid)}&cid=${encodeURIComponent(cid)}`);
      if (!d || !d.ok || !d.url) return { text: '', content: '', url: '', header: {}, error: (d && d.message) || '取 B 站播放地址失败' };
      return { text: '', content: '', url: d.url, header: {}, headers: {}, quality: d.quality || 0 };
    }

    let flag = '', epUrl = '';
    const ch = String(chapter || '');
    if (ch.startsWith('ep|')) {
      const rest = ch.slice(3);
      const k = rest.indexOf('|');
      flag = k < 0 ? '' : rest.slice(0, k);
      epUrl = k < 0 ? rest : rest.slice(k + 1);
    } else {
      epUrl = ch;
    }
    if (!epUrl) return null;
    const d = await localGet(`/v1/video/play?sourceId=${encodeURIComponent(sourceId)}`
      + `&flag=${encodeURIComponent(flag)}&id=${encodeURIComponent(epUrl)}`);
    const data = (d && d.data) || {};
    const raw = data.url || data.playUrl || '';
    if (!raw) return { text: '', content: '', url: '', header: {} };
    let header = data.header || data.headers || {};
    if (typeof header === 'string') { try { header = JSON.parse(header); } catch (e) { header = {}; } }
    // ★二次解析：CMS 源常把"分享页/播放页"当播放地址返回，直接丢给播放器只能出封面。
    const rs = await resolveStream(raw);
    const merged = Object.assign({}, header, rs.header || {});
    // ★再包一层本机媒体代理：播放器（ExoPlayer）默认 UA 会被源站 403，
    //   而且清单里的分片常跨域。走代理后 App 只需播一个地址，头由 NAS 补。
    const referer = merged.Referer || merged.referer || (rs.header && rs.header.Referer) || raw;
    const playUrl = wrapMedia(rs.url, referer);
    return { text: '', content: '', url: playUrl, header: {}, headers: {}, rawUrl: raw, origin: rs.url };
  }

  // ── 音乐：单曲直链 ──
  if (t === 'music') {
    const ch = String(chapter || '');
    const url = ch.startsWith('track|') ? ch.slice(6) : ch;
    // 同样过代理：不少音源 CDN 也挑 UA
    return { text: '', content: '', url: wrapMedia(url), header: {}, headers: {}, origin: url };
  }

  // ── 漫画：图片列表 ──
  if (t === 'comic') {
    const pk = unpackId(id);
    if (!pk) return null;
    const d = await localGet(`/v1/comic/pages?sourceId=${encodeURIComponent(pk.sourceId)}`
      + `&id=${encodeURIComponent(pk.id)}&chapterId=${encodeURIComponent(chapter)}`);
    const data = (d && d.data) || {};
    const imagess = (data.images || data.pages || []).map((u) => {
      const s = String(u || '');
      // ★Android 9+ 默认禁止明文 HTTP，漫画图直链很多是 http://
      //   （实测优酷漫画的图站会 301 到 https）。统一升级成 https，
      //   否则阅读器里全是"图片加载失败"，用户以为是没取到图。
      return s.startsWith('http://') ? 'https://' + s.slice(7) : s;
    }).filter(Boolean);
    let header = data.header || data.headers || {};
    if (typeof header === 'string') { try { header = JSON.parse(header); } catch (e) { header = {}; } }
    return { text: '', content: '', images: imagess, header, headers: header };
  }

  // ── 小说（默认）：章节正文 ──
  const s = resolveSource(chapter || id, qOf(u, 'sourceId', 'source'));
  if (!s) return null;
  const c = await engine.content(s, chapter || id);
  const text = String((c && (c.text || c.content)) || '');
  const images = (c && c.images) || [];
  return { text, content: text, images, sourceId: String(s.bookSourceUrl || '') };
}

// ─── 影视 / 音乐：转给已有的 REST 端点，保持模块不退化 ───
// 不重新实现一遍采集/音源逻辑（那套已经在 /v1/video/search、/v1/music/search 里跑通了），
// 只做「THP 形状 ↔ REST 形状」的搬砖。
// 内部转发的令牌：直接读后端自己的 secret 文件（和 /v1/* 用的是同一把钥匙），
// 不用环境变量 —— 少一个「部署时忘了配」的失败点。
function internalToken() {
  try { return fs.readFileSync(path.join(DATA, 'secret'), 'utf8').trim().split('\n').pop().trim(); }
  catch (e) { return process.env.TH_INTERNAL_TOKEN || ''; }
}

async function forwardSearch(type, q, limit) {
  const https = require('https');
  const port = process.env.PORT || 9527;
  const p = type === 'video' ? '/v1/video/search'
    : (type === 'comic' ? '/v1/comic/search' : '/v1/music/search');
  const url = `https://127.0.0.1:${port}${p}?q=${encodeURIComponent(q)}`;
  const body = await new Promise((resolve) => {
    const req = https.request(url, {
      method: 'GET',
      rejectUnauthorized: false,
      headers: { 'x-th-token': internalToken(), 'user-agent': 'thp-bridge' },
      timeout: 20000,
    }, (r) => {
      const cs = []; r.on('data', (d) => cs.push(d));
      r.on('end', () => resolve(Buffer.concat(cs).toString('utf8')));
    });
    req.on('error', () => resolve(''));
    req.on('timeout', () => { try { req.destroy(); } catch (e) {} resolve(''); });
    req.end();
  });
  let j = null;
  try { j = JSON.parse(body); } catch (e) { return { items: [], scanned: 0, total: 0 }; }
  const groups = (j && j.data) || [];
  const items = [];
  const kind = type === 'video' ? 'v1' : 'm1';
  for (const g of groups) {
    for (const it of (g.items || [])) {
      const sid = String(g.sourceId || g.serviceId || '');
      const rawId = (it.id != null ? it.id : (it.vid != null ? it.vid : ''));
      items.push(Object.assign({}, it, {
        // ★id 必须把 sourceId 编进去：App 取内容时只回传 id + chapter，
        //   没有地方放 sourceId，不编码就不知道该去哪个源取详情/播放地址。
        id: packId(kind, sid, rawId),
        vid: rawId,
        name: it.name || it.title || '',
        title: it.title || it.name || '',
        coverUrl: it.coverUrl || it.cover || it.pic || '',
        cover: it.cover || it.coverUrl || it.pic || '',
        sourceName: g.source || g.serviceName || '',
        sourceId: sid,
        url: it.url || it.playUrl || '',
        type,
      }));
    }
  }
  // ★把 B 站当成一个"影视源"：搜索结果最前面插一组
  //   这样 App 现有的影视模块（搜索→选集→播放）直接就能刷 B 站，不用改 App。
  if (type === 'video') {
    try {
      const bj = await localGet('/v1/bili/search?q=' + encodeURIComponent(q));
      const bitems = (bj && bj.items) || [];
      const lanBase = (process.env.TH_LAN_URL || '').replace(/\/+$/, '');
      const abs = (p) => (p && p.startsWith('/') ? lanBase + p : p);
      for (const b of bitems.slice(0, 12).reverse()) {
        items.unshift({
          id: packId('v1', 'bili', b.bvid),
          vid: b.bvid,
          name: b.title,
          title: b.title,
          coverUrl: abs(b.cover),
          cover: abs(b.cover),
          sourceName: 'B站',
          sourceId: 'bili',
          url: b.bvid,
          author: b.owner || '',
          intro: '',
          type: 'video',
        });
      }
    } catch (e) { /* B 站挂了不影响别的源 */ }
  }

  // ★影视源偏好排序（2026-11-14 实测结论，不是拍脑袋）：
  //   无尽资源 → 接口直接给 m3u8，最稳；
  //   极速资源 → /play/<id> 播放页里能提到 index.m3u8，也能播；
  //   量子资源 / 非凡资源 → 给的是 /share/<hash>，页面靠 JS 生成，纯抓取拿不到直链。
  //   App 的视频模块只会拿列表里第一条去播，所以把"能直出"的源排前面，
  //   用户点开就能看到画面，而不是黑屏只剩封面。
  if (type === 'video') {
    const pref = (n) => {
      const s = String(n || '');
      if (s.includes('无尽')) return 0;
      if (s.includes('极速')) return 1;
      if (s.includes('量子') || s.includes('非凡')) return 9;
      return 5;
    };
    items.sort((a, b) => pref(a.sourceName) - pref(b.sourceName));
  }
  return { items: items.slice(0, Math.max(20, limit || 40)), scanned: groups.length, total: items.length, truncated: false };
}

// ─── HTTP 入口 ───
async function handle(req, res, body, u, p, send) {
  if (!p.startsWith('/thp/')) return false;

  // 规范端点别名：/thp/m/{module}/{op} → /thp/{op}
  let op = p.slice(5);
  const mm = op.match(/^m\/[^/]+\/(.+)$/);
  if (mm) op = mm[1];

  // ★只接管「搜索 / 阅读 / 元信息」这几件，其余（blob、changes、events、jobs…）
  //   一律 return false 交回 thp1 —— 那部分是端间互通用的，我们没实现也不该拦。
  const MINE = ['', 'meta', 'search', 'chapters', 'toc', 'content', 'chapter', 'discover', 'explore'];
  if (!MINE.includes(op)) return false;

  if (op === 'discover' || op === 'explore') {
    // 分类/发现页需要逐源解析各自的 exploreUrl（每个源的结构都不一样），本轮没做。
    // ★但**不能**让它落到令牌闸门后面：那边会回 401「无效密钥」，
    //   用户看到的是「连不上」，而实际情况只是「这个功能没做」。
    //   所以这里回一个空列表 + 空分类，App 会显示「暂无内容」。
    send(200, {
      ok: true,
      object: 'thp-' + op,
      data: { items: [], groups: [], categories: [], tags: [] },
      page: 1, total: 0, hasMore: false, truncated: false, budgetSec: 0,
      scannedSources: 0, totalSources: sources().length,
    });
    return true;
  }

  if (op === 'meta' || op === '') {
    const caps = ['m:novel', 'paging', 'search-mode'];
    // 影视/音乐/漫画源存在才声明支持，否则模块页的类型闸门会打开却搜不到东西。
    // 注意：影视源落在 drpy-sources.json（没有独立的 video-sources.json）。
    const hasArr = (f) => {
      try {
        const v = JSON.parse(fs.readFileSync(path.join(DATA, f), 'utf8'));
        return Array.isArray(v) && v.length > 0;
      } catch (e) { return false; }
    };
    if (hasArr('drpy-sources.json')) caps.push('m:video');
    if (hasArr('music-sources.json')) caps.push('m:music');
    if (hasArr('comic-sources.json')) caps.push('m:comic');
    send(200, {
      ok: true,
      object: 'thp-meta',
      data: {
        name: 'ThirdHub · NAS',
        version: '1.99.0',           // 语义：高于本地引擎所有版本，App 会走「分页 + type=all」新路径
        caps,
        kinds: ['novel', 'video', 'music', 'comic'],
        backend: 'thirdhub',
      },
    });
    return true;
  }

  if (op === 'search') {
    const type = u.searchParams.get('type') || 'novel';
    const q = (u.searchParams.get('q') || '').trim();
    const page = Math.max(1, parseInt(u.searchParams.get('page') || '1', 10) || 1);
    const limit = Math.max(1, Math.min(60, parseInt(u.searchParams.get('limit') || '40', 10) || 40));
    const budgetSec = Math.max(3, Math.min(60, parseInt(u.searchParams.get('budget') || '25', 10) || 25));
    if (!q) {
      send(200, { ok: true, data: { items: [] }, page, total: 0, hasMore: false, truncated: false, budgetSec, scannedSources: 0, totalSources: 0 });
      return true;
    }
    const t0 = Date.now();
    let r;
    try {
      if (type === 'video' || type === 'music' || type === 'comic') r = await forwardSearch(type, q, limit);
      else r = await searchBooks(type, q, page, limit, budgetSec * 1000);
    } catch (e) {
      send(500, { ok: false, error: { code: 'search_failed', message: String(e && e.message || e) } });
      return true;
    }
    const items = r.items || [];
    send(200, {
      ok: true,
      object: 'thp-search',
      data: { items },
      page,
      total: r.total || items.length,
      hasMore: (r.total || 0) > page * limit || !!r.truncated,
      truncated: !!r.truncated,
      budgetSec,
      scannedSources: r.scanned || 0,
      totalSources: sources().length,
      costMs: Date.now() - t0,
    });
    return true;
  }

  if (op === 'chapters' || op === 'toc') {
    const type = qOf(u, 'type') || 'novel';
    const id = qOf(u, 'id', 'url');
    if (!id) { send(400, { ok: false, error: { code: 'bad_request', message: '缺少 id' } }); return true; }
    try {
      const r = await chaptersOf(type, id, u);
      if (!r) { send(404, { ok: false, error: { code: 'no_source', message: '这个条目找不到可用的来源规则' } }); return true; }
      send(200, { ok: true, object: 'thp-chapters', data: r });
    } catch (e) {
      send(500, { ok: false, error: { code: 'chapters_failed', message: String(e && e.message || e) } });
    }
    return true;
  }

  if (op === 'content' || op === 'chapter') {
    const type = qOf(u, 'type') || 'novel';
    const id = qOf(u, 'id', 'url');
    const chapter = qOf(u, 'chapter', 'chapterId', 'ep');
    if (!id) { send(400, { ok: false, error: { code: 'bad_request', message: '缺少 id' } }); return true; }
    try {
      const r = await contentOf(type, id, chapter, u);
      if (!r) { send(404, { ok: false, error: { code: 'no_source', message: '这一章找不到可用的来源规则' } }); return true; }
      send(200, { ok: true, object: 'thp-content', data: r });
    } catch (e) {
      send(500, { ok: false, error: { code: 'content_failed', message: String(e && e.message || e) } });
    }
    return true;
  }

  // 兜底：走到这里说明是未识别的子操作，交回 thp1 处理
  return false;
}

module.exports = { handle, resolveSource, sources };
