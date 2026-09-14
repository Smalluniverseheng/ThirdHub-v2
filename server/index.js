// ThirdHub v4 M1 家庭后端入口 :9527
// TLS 一层(自签+TOFU指纹) + 共享密钥鉴权(二层信封二期) + mDNS广播 + 书源API
const https = require('https');
const http = require('http');
const fs = require('fs'); const path = require('path');
const crypto = require('crypto');
const engine = require('./engine');
const drpy = require('./engine-drpy');
const comic = require('./engine-comic');
const music = require('./engine-music');
const { Bonjour } = require('bonjour-service');

const DATA = path.join(__dirname, 'data');
fs.mkdirSync(DATA, { recursive: true });

// ─── 共享密钥(首启生成) ───
const SECRET_FILE = path.join(DATA, 'secret');
let SECRET;
if (fs.existsSync(SECRET_FILE)) SECRET = fs.readFileSync(SECRET_FILE, 'utf8').trim();
else { SECRET = 'thsec_' + crypto.randomBytes(24).toString('hex'); fs.writeFileSync(SECRET_FILE, SECRET); }

// ─── 证书(无则生成) ───
const KEY = path.join(DATA, 'key.pem'), CERT = path.join(DATA, 'cert.pem');
if (!fs.existsSync(KEY) || !fs.existsSync(CERT)) {
  require('child_process').execSync('node ' + path.join(__dirname, 'scripts', 'gencert.js'), { stdio: 'inherit' });
}
const fingerprint = crypto.createHash('sha256')
  .update(fs.readFileSync(CERT)).digest('hex').match(/.{4}/g).join(':');

// ─── 设备存储(网络插件: Legado等局域网设备) ───
const DEVICES_FILE = path.join(DATA, 'devices.json');
function loadDevices() { try { return JSON.parse(fs.readFileSync(DEVICES_FILE, 'utf8')); } catch (e) { return []; } }
function saveDevices(d) { fs.writeFileSync(DEVICES_FILE, JSON.stringify(d, null, 2)); }
let devices = loadDevices();

// ─── 书源存储 ───
const SOURCES_FILE = path.join(DATA, 'sources.json');
function loadSources() { try { return JSON.parse(fs.readFileSync(SOURCES_FILE, 'utf8')); } catch (e) { return []; } }
function saveSources(s) { fs.writeFileSync(SOURCES_FILE, JSON.stringify(s, null, 2)); }
let sources = loadSources();

// 首启自动导入预置书源包(server/sources-preset/*.json, CI/手动放入)
(function importPreset() {
  const presetDir = path.join(__dirname, 'sources-preset');
  if (!fs.existsSync(presetDir) || sources.length > 0) return;
  try {
    const files = fs.readdirSync(presetDir).filter(f => f.endsWith('.json'));
    for (const f of files) {
      const arr = JSON.parse(fs.readFileSync(path.join(presetDir, f), 'utf8'));
      for (const item of (Array.isArray(arr) ? arr : [])) {
        if (item.bookSourceUrl && item.bookSourceName && !sources.some(x => x.bookSourceUrl === item.bookSourceUrl)) {
          sources.push({ ...item, enabled: true });
        }
      }
    }
    if (sources.length) { saveSources(sources); console.log(`[preset] 预置书源导入: ${sources.length} 条`); }
  } catch (e) { console.log('[preset] 导入跳过:', e.message); }
})();

// ─── 内置演示书源(若空则提示导入; 不内置具体源, 见 sources/ 目录导入) ───

// ─── mDNS 广播 ───
try {
  const bonjour = new Bonjour();
  bonjour.publish({ name: 'thirdhub-' + crypto.randomBytes(3).toString('hex'), type: 'thirdhub-dev',
    port: 9527, txt: { type: 'backend', version: '4.0.0-m1', caps: 'novel' } });
} catch (e) { console.log('mDNS 广播跳过:', e.message); }

// ─── 极简静态(前端flutter build web产物可选挂载) ───
const PUB = path.join(__dirname, 'public');

// ─── 音源存储(MusicFree格式) ───
const MUSIC_FILE = path.join(DATA, 'music-sources.json');
function loadMusic() { try { return JSON.parse(fs.readFileSync(MUSIC_FILE, 'utf8')); } catch (e) { return []; } }
function saveMusic(d) { fs.writeFileSync(MUSIC_FILE, JSON.stringify(d, null, 2)); }
let musicSources = loadMusic();

// ─── 漫画图源存储(Venera格式) ───
const COMIC_FILE = path.join(DATA, 'comic-sources.json');
function loadComic() { try { return JSON.parse(fs.readFileSync(COMIC_FILE, 'utf8')); } catch (e) { return []; } }
function saveComic(d) { fs.writeFileSync(COMIC_FILE, JSON.stringify(d, null, 2)); }
let comicSources = loadComic();

// ─── drpy影视源存储 ───
const DRPY_FILE = path.join(DATA, 'drpy-sources.json');
function loadDrpy() { try { return JSON.parse(fs.readFileSync(DRPY_FILE, 'utf8')); } catch (e) { return []; } }
function saveDrpy(d) { fs.writeFileSync(DRPY_FILE, JSON.stringify(d, null, 2)); }
let drpySources = loadDrpy();

// ─── TOC缓存+书源健康分 ───
const tocCache = new Map(); // key: sourceId|url → {at, data}
const health = new Map();   // sourceId → {ok, fail, totalLatency}
function tocGet(k) { const e = tocCache.get(k); if (e && Date.now() - e.at < 600000) return e.data; return null; }
function healthHit(id, ok, latency) {
  const h = health.get(id) || { ok: 0, fail: 0, latency: 0 };
  ok ? h.ok++ : h.fail++; h.latency += latency || 0; health.set(id, h);
}

// ─── API ───
async function handle(req, res, body) {
  const u = new URL(req.url, 'https://localhost');
  const p = u.pathname;
  // CORS: 局域网工具, 放行所有源(正式版收紧)
  res.setHeader('Access-Control-Allow-Origin', req.headers.origin || '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-TH-Token');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  const send = (code, obj) => { res.writeHead(code, {'Content-Type':'application/json; charset=utf-8'}); res.end(JSON.stringify(obj)); };

  // 健康+指纹(免鉴权, 供前端TOFU)
  if (p === '/v1/meta') return send(200, { v: 1, object: 'meta', data: {
    name: 'ThirdHub', version: '4.0.0-m1', fingerprint,
    capabilities: { novel: sources.length > 0, sources: sources.length, devices: devices.length },
    encrypted: true, time: Date.now()
  }});

  // 其余全需鉴权
  if (req.headers['x-th-token'] !== SECRET) return send(401, { object:'error', data:{ type:'authentication_error', message:'无效密钥' }});

  if (p === '/v1/pair' && req.method === 'POST') {
    // 设备自注册(免鉴权, 凭设备token校验在调用设备API时进行)
    try {
      const d = JSON.parse(body || '{}');
      if (!d.device_url || !d.device_type) return send(400, { object:'error', data:{ type:'invalid_request', message:'缺device_url/type' }});
      const existing = devices.find(x => x.device_url === d.device_url);
      if (existing) Object.assign(existing, d, { last_seen: Date.now() });
      else devices.push({ ...d, paired_at: Date.now(), last_seen: Date.now() });
      saveDevices(devices);
      console.log(`[pair] ${d.device_type} @ ${d.device_url}`);
      return send(200, { object:'meta', data: { paired: true, total: devices.length }});
    } catch (e) { return send(400, { object:'error', data:{ type:'invalid_request', message: String(e.message) }}); }
  }
  // ── 音乐(MusicFree音源) ──
  if (p === '/v1/music/sources' && req.method === 'GET')
    return send(200, { object:'list', data: musicSources.map(s => ({ id: s.id, name: s.name, platform: s.platform })) });
  if (p === '/v1/music/sources' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.code || !d.name) return send(400, { object:'error', data:{ type:'invalid_request', message:'需name+code' }});
    const id = d.id || 'music_' + crypto.randomBytes(4).toString('hex');
    const i = musicSources.findIndex(x => x.id === id);
    i >= 0 ? musicSources[i] = { id, name: d.name, platform: d.platform || d.name, code: d.code } : musicSources.push({ id, name: d.name, platform: d.platform || d.name, code: d.code });
    saveMusic(musicSources);
    return send(200, { object:'meta', data: { id, total: musicSources.length }});
  }
  if (p.startsWith('/v1/music/search')) {
    const q = u.searchParams.get('q');
    const pool = musicSources.filter(s => !u.searchParams.get('sourceId') || s.id === u.searchParams.get('sourceId'));
    const results = await Promise.all(pool.slice(0, 3).map(async (s) => {
      const t0 = Date.now();
      const r = music.irSearch(await music.runPlugin(s.code, 'search', [q, 1, 'music']));
      return { source: s.name, sourceId: s.id, ok: !r.error, latency: Date.now() - t0,
        ...(r.error ? { error: r.error } : { items: r.items.slice(0, 10) }) };
    }));
    results.sort((a, b) => (b.ok - a.ok) || (a.latency - b.latency));
    return send(200, { object:'list', data: results });
  }
  if (p.startsWith('/v1/music/url')) {
    const s = musicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'音源不存在' }});
    let item = {}; try { item = JSON.parse(u.searchParams.get('item') || '{}'); } catch (e) {}
    const r = music.irUrl(await music.runPlugin(s.code, 'getMediaSource', [item, 'standard']));
    if (r.error) return send(500, { object:'error', data:{ type:'source_error', message: r.error }});
    return send(200, { object:'music-url', data: r });
  }
  if (p.startsWith('/v1/music/lyric')) {
    const s = musicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'音源不存在' }});
    let item = {}; try { item = JSON.parse(u.searchParams.get('item') || '{}'); } catch (e) {}
    const r = music.irLyric(await music.runPlugin(s.code, 'getLyric', [item]));
    return send(200, { object:'music-lyric', data: r });
  }
  // ── 漫画(Venera图源) ──
  if (p === '/v1/comic/sources' && req.method === 'GET')
    return send(200, { object:'list', data: comicSources.map(s => ({ id: s.id, name: s.name })) });
  if (p === '/v1/comic/sources' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.code || !d.name) return send(400, { object:'error', data:{ type:'invalid_request', message:'需name+code' }});
    const id = d.id || 'comic_' + crypto.randomBytes(4).toString('hex');
    const i = comicSources.findIndex(x => x.id === id);
    i >= 0 ? comicSources[i] = { id, name: d.name, code: d.code } : comicSources.push({ id, name: d.name, code: d.code });
    saveComic(comicSources);
    return send(200, { object:'meta', data: { id, total: comicSources.length }});
  }
  if (p.startsWith('/v1/comic/search')) {
    const q = u.searchParams.get('q');
    const pool = comicSources.filter(s => !u.searchParams.get('sourceId') || s.id === u.searchParams.get('sourceId'));
    const results = await Promise.all(pool.slice(0, 3).map(async (s) => {
      const t0 = Date.now();
      const r = comic.irComicList(await comic.runSource(s.code, 'search', [q, 1]));
      return { source: s.name, sourceId: s.id, ok: !r.error, latency: Date.now() - t0,
        ...(r.error ? { error: r.error } : { items: r.items, maxPage: r.maxPage }) };
    }));
    results.sort((a, b) => (b.ok - a.ok) || (a.latency - b.latency));
    return send(200, { object:'list', data: results });
  }
  if (p.startsWith('/v1/comic/info')) {
    const s = comicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'图源不存在, 请先POST /v1/comic/sources导入' }});
    const r = comic.irComicInfo(await comic.runSource(s.code, 'comicInfo', [u.searchParams.get('id')]));
    if (r.error) return send(500, { object:'error', data:{ type:'source_error', message: r.error }});
    return send(200, { object:'comic', data: { ...r, sourceId: s.id } });
  }
  if (p.startsWith('/v1/comic/pages')) {
    const s = comicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'图源不存在' }});
    const chapId = u.searchParams.get('chapterId') || '';
    const r = comic.irPages(await comic.runSource(s.code, 'comicPages', [chapId]));
    if (r.error) return send(500, { object:'error', data:{ type:'source_error', message: r.error }});
    return send(200, { object:'comic-pages', data: r });
  }
  // ── drpy 影视 ──
  if (p === '/v1/video/sources' && req.method === 'GET')
    return send(200, { object:'list', data: drpySources.map(s => ({ id: s.id, name: s.name })) });
  if (p === '/v1/video/sources' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.code || !d.name) return send(400, { object:'error', data:{ type:'invalid_request', message:'需name+code' }});
    const id = d.id || 'drpy_' + crypto.randomBytes(4).toString('hex');
    const i = drpySources.findIndex(x => x.id === id);
    i >= 0 ? drpySources[i] = { id, name: d.name, code: d.code } : drpySources.push({ id, name: d.name, code: d.code });
    saveDrpy(drpySources);
    return send(200, { object:'meta', data: { id, total: drpySources.length }});
  }
  if (p.startsWith('/v1/video/search')) {
    const q = u.searchParams.get('q');
    const pool = drpySources.filter(s => !u.searchParams.get('sourceId') || s.id === u.searchParams.get('sourceId'));
    const results = await Promise.all(pool.slice(0, 3).map(async (s) => {
      const t0 = Date.now();
      const r = drpy.irSearch(await drpy.runSource(s.code, 'search', [q]));
      return { source: s.name, sourceId: s.id, ok: !r.error, latency: Date.now() - t0, ...(r.error ? { error: r.error } : { items: r.items }) };
    }));
    results.sort((a, b) => (b.ok - a.ok) || (a.latency - b.latency));
    return send(200, { object:'list', data: results });
  }
  if (p.startsWith('/v1/video/detail')) {
    const s = drpySources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'源不存在, 请先POST /v1/video/sources导入' }});
    const r = drpy.irDetail(await drpy.runSource(s.code, 'detail', [u.searchParams.get('id')]));
    if (r.error) return send(500, { object:'error', data:{ type:'source_error', message: r.error }});
    return send(200, { object:'video', data: { ...r, sourceId: s.id } });
  }
  if (p.startsWith('/v1/video/play')) {
    const s = drpySources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'源不存在' }});
    const r = drpy.irPlay(await drpy.runSource(s.code, 'play', [u.searchParams.get('flag') || '', u.searchParams.get('id') || '']));
    if (r.error) return send(500, { object:'error', data:{ type:'source_error', message: r.error }});
    return send(200, { object:'video-play', data: r });
  }
  if (p === '/v1/sources/export') return send(200, { object:'list', data: sources, meta: { exported_at: Date.now(), count: sources.length } });
  if (p === '/v1/devices') return send(200, { object:'list', data: devices });
  if (p.startsWith('/v1/img')) {
    // 图片代理: 前端走自签HTTPS证书问题+图床防盗链, 统一走后端转发
    const imgUrl = u.searchParams.get('url'); const referer = u.searchParams.get('referer') || '';
    if (!imgUrl || !/^https?:/.test(imgUrl)) return send(400, { object:'error', data:{ type:'invalid_request', message:'无效图片地址' }});
    // 磁盘缓存(24h): key=md5(url), 命中直接返
    const CACHE_DIR = path.join(DATA, 'imgcache'); fs.mkdirSync(CACHE_DIR, { recursive: true });
    const ckey = crypto.createHash('md5').update(imgUrl).digest('hex');
    const cpath = path.join(CACHE_DIR, ckey);
    try {
      const st = fs.statSync(cpath);
      if (Date.now() - st.mtimeMs < 86400000) {
        res.writeHead(200, { 'Content-Type': 'image/jpeg', 'X-TH-Cache': 'hit' });
        return res.end(fs.readFileSync(cpath));
      }
    } catch (e) {}
    try {
      const r2 = await fetch(imgUrl, { headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36',
        'Referer': referer || new URL(imgUrl).origin
      }, signal: AbortSignal.timeout(10000) });
      if (!r2.ok) return send(502, { object:'error', data:{ type:'source_error', message:'上游' + r2.status }});
      const buf = Buffer.from(await r2.arrayBuffer());
      try { fs.writeFileSync(cpath, buf); } catch (e) {}
      res.writeHead(200, { 'Content-Type': r2.headers.get('content-type') || 'image/jpeg',
        'Cache-Control': 'public, max-age=86400', 'X-TH-Cache': 'miss' });
      return res.end(buf);
    } catch (e) { return send(502, { object:'error', data:{ type:'source_error', message: String(e.message) }}); }
  }
  if (p === '/v1/status') return send(200, { object:'meta', data: {
    uptime: Math.floor(process.uptime()), version: '4.0.0-m1',
    sources: { total: sources.length, enabled: sources.filter(s => s.enabled !== false).length },
    health: Object.fromEntries([...health.entries()].map(([k, v]) => [k, { ...v, rate: v.ok + v.fail ? Math.round(v.ok / (v.ok + v.fail) * 100) + '%' : '-' }])),
    memory: Math.round(process.memoryUsage().rss / 1048576) + 'MB' }});
  if (p === '/v1/sources' && req.method === 'GET') return send(200, { object:'list', data: sources.map(s => ({ id: s.bookSourceUrl, name: s.bookSourceName, enabled: s.enabled !== false })) });
  if (p.startsWith('/v1/sources/toggle') && req.method === 'POST') {
    const id = u.searchParams.get('id');
    const s = sources.find(x => x.bookSourceUrl === id);
    if (!s) return send(404, { object:'error', data:{ type:'not_found', message:'书源不存在' }});
    s.enabled = s.enabled === false ? true : false; saveSources(sources);
    return send(200, { object:'meta', data: { id, enabled: s.enabled }});
  }
  if (p === '/v1/sources' && req.method === 'POST') {
    const arr = JSON.parse(body || '[]');
    const added = [];
    for (const s of arr) {
      if (!s.bookSourceUrl || sources.some(x => x.bookSourceUrl === s.bookSourceUrl)) continue;
      sources.push(s); added.push(s.bookSourceName || s.bookSourceUrl);
    }
    saveSources(sources);
    return send(200, { object:'meta', data:{ added, total: sources.length }});
  }
  if (p.startsWith('/v1/search/all')) {
    // 聚合搜索: 书+漫画+视频 并行, 统一返回三分组
    const q = u.searchParams.get('q');
    const [books, comics, videos] = await Promise.all([
      (async () => {
        const pool = sources.filter(s => s.enabled !== false);
        const rs = await Promise.all(pool.slice(0, 3).map(async (s) => {
          try { return { source: s.bookSourceName, sourceId: s.bookSourceUrl, ok: true,
            books: (await engine.search(s, q)).slice(0, 5) }; }
          catch (e) { return { source: s.bookSourceName, ok: false }; }
        }));
        return rs.filter(r => r.ok);
      })(),
      (async () => {
        const rs = await Promise.all(comicSources.slice(0, 2).map(async (s) => {
          const t0 = Date.now();
          const r = comic.irComicList(await comic.runSource(s.code, 'search', [q, 1]));
          return { source: s.name, sourceId: s.id, ok: !r.error, ...(r.error ? {} : { items: r.items.slice(0, 5) }) };
        }));
        return rs.filter(r => r.ok);
      })(),
      (async () => {
        const rs = await Promise.all(drpySources.slice(0, 2).map(async (s) => {
          const r = drpy.irSearch(await drpy.runSource(s.code, 'search', [q]));
          return { source: s.name, sourceId: s.id, ok: !r.error, ...(r.error ? {} : { items: r.items.slice(0, 5) }) };
        }));
        return rs.filter(r => r.ok);
      })(),
    ]);
    return send(200, { object:'meta', data: { q, books, comics, videos,
      stats: { bookSources: sources.length, comicSources: comicSources.length, videoSources: drpySources.length } }});
  }
  if (p.startsWith('/v1/search')) {
    const q = u.searchParams.get('q'); const sid = u.searchParams.get('sourceId');
    const pool = sources.filter(s => s.enabled !== false && (!sid || s.bookSourceUrl === sid));
    // 并行搜索(每源独立超时, 全源并发, 不分批)
    const results = await Promise.all(pool.map(async (s) => {
      const t0 = Date.now();
      try {
        const books = await engine.search(s, q);
        return { source: s.bookSourceName, sourceId: s.bookSourceUrl, ok: true,
                 latency: Date.now() - t0, books: books.slice(0, 10) };
      } catch (e) {
        return { source: s.bookSourceName, sourceId: s.bookSourceUrl, ok: false,
                 latency: Date.now() - t0, error: String(e.message || e).slice(0, 120) };
      }
    }));
    // 健康度优先(成功率差>30%时健康排前), 然后成功优先, 然后延迟
    const rate = (id) => { const h = health.get(id); return h && (h.ok + h.fail) >= 3 ? h.ok / (h.ok + h.fail) : 1; };
    results.sort((a, b) => {
      const d = rate(b.sourceId) - rate(a.sourceId);
      if (Math.abs(d) > 0.3) return d;
      return (b.ok - a.ok) || (a.latency - b.latency);
    });
    // 跨源去重(书名+作者), 同书记录多源可用性
    const seen = new Map();
    for (const g of results) {
      if (!g.ok) continue;
      g.books = g.books.filter(b => {
        const k = ((b.name || '') + '|' + (b.author || '')).toLowerCase().replace(/\s+/g, '');
        if (seen.has(k)) { seen.get(k).push(g.source); return false; }
        seen.set(k, [g.source]); return true;
      });
    }
    return send(200, { object:'list', data: results,
      meta: { total: results.length, ok: results.filter(r => r.ok).length, deduped: true } });
  }
  if (p.startsWith('/v1/book')) {
    const s = sources.find(x => x.bookSourceUrl === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'书源不存在' }});
    try { return send(200, { object:'novel', data: await engine.detail(s, u.searchParams.get('url')) }); }
    catch (e) { return send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
  }
  if (p.startsWith('/v1/toc')) {
    const s = sources.find(x => x.bookSourceUrl === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'书源不存在' }});
    const ck = s.bookSourceUrl + '|' + u.searchParams.get('url');
    const cached = tocGet(ck); if (cached) return send(200, { object:'list', data: cached, meta: { cached: true }});
    const t0 = Date.now();
    try {
      const data = await engine.catalog(s, u.searchParams.get('url'));
      tocCache.set(ck, { at: Date.now(), data });
      healthHit(s.bookSourceUrl, true, Date.now() - t0);
      return send(200, { object:'list', data });
    } catch (e) { healthHit(s.bookSourceUrl, false, Date.now() - t0);
      return send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
  }
  if (p.startsWith('/v1/content')) {
    const s = sources.find(x => x.bookSourceUrl === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'书源不存在' }});
    try { return send(200, { object:'novel-content', data: await engine.content(s, u.searchParams.get('url')) }); }
    catch (e) { return send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
  }
  return send(404, { object:'error', data:{ type:'not_found', message: p }});
}

const server = https.createServer({ key: fs.readFileSync(KEY), cert: fs.readFileSync(CERT) }, async (req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => handle(req, res, body).catch(e => {
    res.writeHead(500, {'Content-Type':'application/json'});
    res.end(JSON.stringify({ object:'error', data:{ type:'server_error', message: String(e.message||e) }}));
  }));
});

// ─── 启动自检 ───
(function selfcheck() {
  const checks = [];
  checks.push(['Node版本', process.version >= 'v20' ? 'ok' : 'warn: 建议v20+']);
  checks.push(['证书', fs.existsSync(CERT) ? 'ok' : 'fail: 运行 npm run gencert']);
  checks.push(['依赖cheerio', (() => { try { require('cheerio'); return 'ok'; } catch (e) { return 'fail: npm install'; } })()]);
  try { require('bonjour-service'); checks.push(['依赖bonjour', 'ok']); } catch (e) { checks.push(['依赖bonjour', 'warn: mDNS不可用']); }
  checks.push(['drpy引擎', fs.existsSync(path.join(__dirname, 'vendor/drpy/drpy2.min.js')) ? 'ok' : 'warn: 缺vendor']);
  checks.push(['书源', sources.length + '条']);
  checks.push(['漫画源', comicSources.length + '条']);
  checks.push(['影视源', drpySources.length + '条']);
  console.log('─── 自检 ───');
  for (const [k, v] of checks) console.log(`  ${k}: ${v}`);
  const fails = checks.filter(c => String(c[1]).startsWith('fail'));
  if (fails.length) console.log('⚠️ 存在失败项, 功能可能不完整:', fails.map(f => f[0]).join(', '));
})();

server.listen(9527, '0.0.0.0', () => {
  const os = require('os');
  const nets = Object.values(os.networkInterfaces()).flat().filter(n => n && n.family === 'IPv4' && !n.internal);
  console.log('════════════════════════════════════');
  console.log('ThirdHub v4.0.0-m1 后端就绪');
  console.log('监听: https://0.0.0.0:9527');
  nets.forEach(n => console.log('  本机: https://' + n.address + ':9527'));
  console.log('SHA256 指纹(前端首次连接确认):');
  console.log('  ' + fingerprint);
  console.log('访问密钥(前端配置用): ' + SECRET);
  console.log('════════════════════════════════════');
});
