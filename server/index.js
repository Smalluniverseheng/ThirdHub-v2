// ThirdHub v4 M1 家庭后端入口 :9527
// TLS 一层(自签+TOFU指纹) + 共享密钥鉴权(二层信封二期) + mDNS广播 + 书源API
const https = require('https');
const http = require('http');
const fs = require('fs'); const path = require('path');
const crypto = require('crypto');
const engine = require('./engine');
const drpy = require('./engine-drpy');
const tvbox = require('./engine-tvbox');
const lx = require('./engine-lx');
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

// ─── THP 通用引擎协议: UDP 19527 心跳发现(引擎匿名, 广播即连接) ───
// THP/1.0: HELLO <port> <instanceId> <role> <caps> [name] + BYE；兼容旧草稿 HELLO <port> <caps>
const dgram = require('dgram');
const THP_PORT = 19527;
const thp1 = require('./thp1');
try {
  const udp = dgram.createSocket('udp4');
  udp.on('message', (msg, rinfo) => {
    const s = String(msg);
    // 优雅下线
    const bye = s.match(/^THP\/1 BYE ([\w\-]+)$/);
    if (bye) {
      const i = devices.findIndex(x => x.instanceId === bye[1]);
      if (i >= 0) { devices.splice(i, 1); saveDevices(devices); }
      return;
    }
    // 新格式
    let m = s.match(/^THP\/1 HELLO (\d+) ([\w\-]+) (engine|library) ([\w:,\-]+)(?:\s+(.*))?$/);
    if (m) {
      const url = 'http://' + rinfo.address + ':' + m[1];
      const caps = m[4].split(',');
      const existing = devices.find(x => x.instanceId === m[2]);
      const now = Date.now();
      const rec = { device_url: url, device_type: 'thp', instanceId: m[2], role: m[3], caps,
        name: m[5] || '', last_seen: now };
      if (existing) { rec.interval = now - (existing.last_seen || now); Object.assign(existing, rec); }
      else { rec.paired_at = now; devices.push(rec); }
      return;
    }
    // 旧草稿格式（兼容期）
    m = s.match(/^THP\/1 HELLO (\d+) ([\w,\-]+)$/);
    if (!m) return;
    const url = 'http://' + rinfo.address + ':' + m[1];
    const caps = m[2].split(',');
    const existing = devices.find(x => x.device_url === url);
    if (existing) Object.assign(existing, { device_type: 'thp', caps, last_seen: Date.now() });
    else devices.push({ device_url: url, device_type: 'thp', caps, paired_at: Date.now(), last_seen: Date.now() });
  });
  udp.bind(THP_PORT, () => console.log('[thp] UDP :' + THP_PORT + ' 监听中'));
  // 资源库自身广播: THP/1.0 新格式（含 instanceId/role/caps）
  try {
    const bc = dgram.createSocket('udp4');
    bc.bind(() => {
      bc.setBroadcast(true);
      const hello = Buffer.from('THP/1 HELLO 9527 ' + thp1.INSTANCE_ID + ' library ' +
        'library,m:novel,m:comic,m:video,m:music,post-query,events,jobs ThirdHub资源库');
      setInterval(() => {
        bc.send(hello, THP_PORT, '255.255.255.255', () => {});
      }, 30000);
      bc.send(hello, THP_PORT, '255.255.255.255', () => {});
    });
  } catch (e) { console.log('[thp] 广播失败', e.message); }
} catch (e) { console.log('[thp] UDP 绑定失败', e.message); }

// mDNS（THP/1.0 §4.2 双通道互备，IPv6 环境必选）
try {
  const bonjour = new Bonjour();
  bonjour.publish({ name: 'ThirdHub资源库', type: 'thp', port: 9527, protocol: 'tcp',
    txt: { port: '9527', iid: thp1.INSTANCE_ID, role: 'library', caps: 'library,m:novel,m:comic,m:video,m:music', name: 'ThirdHub资源库' } });
  console.log('[thp] mDNS _thp._tcp 已发布');
} catch (e) { console.log('[thp] mDNS 发布失败', e.message); }

// THP 引擎调用(匿名HTTP)
async function thpCall(dev, path, params) {
  const qs = new URLSearchParams(params).toString();
  const r = await fetch(dev.device_url + path + (qs ? '?' + qs : ''), { signal: AbortSignal.timeout(12000) });
  return await r.json();
}
// ttl = 3 × 该 peer 观测到的广播间隔（默认 90s），见 THP/1.0 §4.1
const thpOnline = (cap) => devices.filter(d => {
  if (d.device_type !== 'thp') return false;
  if (d.instanceId && d.instanceId === thp1.INSTANCE_ID) return false; // 排除自广播
  const ttl = 3 * (d.interval || 30000);
  if ((Date.now() - (d.last_seen || 0)) >= Math.max(ttl, 30000)) return false;
  if (!cap) return true;
  const caps = d.caps || [];
  return caps.includes(cap) || caps.includes('m:' + cap) || (cap === 'library' && d.role === 'library');
});

// ─── 本地书库(后端=纯资源库: 书架书籍自动缓存 + 本地书籍导入) ───
const LIB_DIR = path.join(DATA, 'library');
fs.mkdirSync(LIB_DIR, { recursive: true });
const LIB_INDEX = path.join(DATA, 'library.json');
function loadLib() { try { return JSON.parse(fs.readFileSync(LIB_INDEX, 'utf8')); } catch (e) { return []; } }
function saveLib(d) { fs.writeFileSync(LIB_INDEX, JSON.stringify(d, null, 2)); }
let library = loadLib();

// ─── THP/1.0 资源库层（server/thp1.js）：统一信封 + 模块命名空间 + cursor分页 + blob/changes ───
// 本地检索：novel 走旧书库索引，其余模块走 THP 条目仓（data/store/{module}.json）
function searchLocal(module, q) {
  const out = [];
  const ql = String(q || '').toLowerCase();
  if (!ql) return out;
  if (module === 'novel') {
    for (const b of library) {
      if ((b.name + (b.author || '')).toLowerCase().includes(ql))
        out.push({ id: 'local:' + b.id, name: b.name, author: b.author || '', coverUrl: b.coverUrl || '', source: 'local' });
    }
  }
  try {
    const store = JSON.parse(fs.readFileSync(path.join(DATA, 'store', module + '.json'), 'utf8'));
    for (const it of store) {
      const s = ((it.name || '') + (it.title || '') + (it.author || '') + (it.tags || '')).toLowerCase();
      if (s.includes(ql)) out.push({ ...it, source: 'local' });
    }
  } catch (e) {}
  return out.slice(0, 50);
}
thp1.init({ thpOnline, searchLocal, library, saveLib, LIB_DIR });

// ─── 传输加密(可选, 默认不加密): AES-256-GCM, 密钥=配对secret ───
const ENC_KEY = crypto.createHash('sha256').update(SECRET).digest();
function encDecrypt(b64) {
  const raw = Buffer.from(b64, 'base64');
  const nonce = raw.subarray(0, 12), tag = raw.subarray(raw.length - 16), data = raw.subarray(12, raw.length - 16);
  const d = crypto.createDecipheriv('aes-256-gcm', ENC_KEY, nonce);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(data), d.final()]).toString('utf8');
}
function encEncrypt(text) {
  const nonce = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', ENC_KEY, nonce);
  const enc = Buffer.concat([c.update(text, 'utf8'), c.final()]);
  return Buffer.concat([nonce, enc, c.getAuthTag()]).toString('base64');
}

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
const contentCache = new Map(); // 正文缓存30分钟(重看同章不重复抓)
const aggCache = new Map();     // 聚合搜索缓存60s
const health = new Map();   // sourceId → {ok, fail, totalLatency}
function tocGet(k) { const e = tocCache.get(k); if (e && Date.now() - e.at < 600000) return e.data; return null; }
function healthHit(id, ok, latency) {
  const h = health.get(id) || { ok: 0, fail: 0, latency: 0 };
  ok ? h.ok++ : h.fail++; h.latency += latency || 0; health.set(id, h);
}

// ─── 路由模块(2026-09 拆分: index.js 保留骨架+接线) ───
const media = require('./routes-media');
const rtAdmin = require('./routes-admin');
const rtData = require('./routes-data');
const rtSources = require('./routes-sources');
const rtSearch = require('./routes-search');
const rtLibrary = require('./routes-library');
// 存储进程状态(原在文件尾, 上移供 adminCtx 引用)
const storageProcs = {}; const storageState = { cloudreve: 'absent', aria2: 'absent' };
// 共享上下文(引用传递, 与各路由模块互通)
const mediaCtx = { musicSources, saveMusic, comicSources, saveComic, drpySources, saveDrpy };
const adminCtx = { health, devices, sources, musicSources, comicSources, drpySources, storageState };
const dataCtx = { DATA, SECRET };
const sourcesCtx = { sources, saveSources, drpySources, saveDrpy, comicSources, saveComic, musicSources, saveMusic, devices, health, DATA };
const searchCtx = { aggCache, sources, engine, pool, comicSources, drpySources, musicSources, devices, thpOnline, thpCall, library, health, healthHit };
const libraryCtx = { sources, engine, devices, library, saveLib, LIB_DIR, tocCache, contentCache, tocGet, healthHit };

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

  // THP/1.0 端点：匿名可达(L0)，统一信封，优先于旧 /v1 路由
  if (p.startsWith('/thp') && await thp1.handle(req, res, body, u)) return;

  // Web控制台与静态文件(public/)
  if ((p === '/' || p === '/index.html') && req.method === 'GET') {
    const idx = path.join(PUB, 'index.html');
    if (fs.existsSync(idx)) { res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'}); return res.end(fs.readFileSync(idx)); }
  }
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
      else devices.push({ ...d, paired_at: Date.now() });
      saveDevices(devices);
      console.log(`[pair] ${d.device_type} @ ${d.device_url}`);
      return send(200, { object:'meta', data: { paired: true, total: devices.length }});
    } catch (e) { return send(400, { object:'error', data:{ type:'invalid_request', message: String(e.message) }}); }
  }
  // ── 媒体路由(音乐/漫画/影视): server/routes-media.js ──
  if (await media.handle(req, res, body, u, p, send, mediaCtx)) return;
  // ── 管理台(引擎总览/存储/下载任务): server/routes-admin.js ──
  if ((await rtAdmin.handle(req, res, body, u, p, send, adminCtx)) || res.writableEnded) return;
  // ── 数据服务(密钥库/进度/设置/相册): server/routes-data.js ──
  if ((await rtData.handle(req, res, body, u, p, send, dataCtx)) || res.writableEnded) return;
  // ── 源管理(/v1/src /v1/sources /v1/img /v1/status): server/routes-sources.js ──
  if ((await rtSources.handle(req, res, body, u, p, send, sourcesCtx)) || res.writableEnded) return;
  // 统一搜索路由: 前端只说"搜什么类型", 后端按引擎能力分发
  // (未来网络设备插件按caps广播: {novel:[search], comic:[search]...}, 路由表动态扩展)
  if (p.startsWith('/v1/search') && !p.startsWith('/v1/search/all')) {
    const type = u.searchParams.get('type') || 'novel';
    const q = u.searchParams.get('q');
    if (type === 'comic') { u.searchParams.set('type', ''); req.url = '/v1/comic/search?' + u.searchParams.toString(); return handle(req, res, body); }
    if (type === 'video') { req.url = '/v1/video/search?' + u.searchParams.toString(); return handle(req, res, body); }
    if (type === 'music') { req.url = '/v1/music/search?' + u.searchParams.toString(); return handle(req, res, body); }
    // type=novel 或无type: 继续走下方书源搜索
  }
  // ── 搜索(聚合/书源/THP): server/routes-search.js ──
  if ((await rtSearch.handle(req, res, body, u, p, send, searchCtx)) || res.writableEnded) return;
  // ── 书库(Legado/book/toc/content/书架): server/routes-library.js ──
  if ((await rtLibrary.handle(req, res, body, u, p, send, libraryCtx)) || res.writableEnded) return;
  return send(404, { object:'error', data:{ type:'not_found', message: p }});
}

const server = https.createServer({ key: fs.readFileSync(KEY), cert: fs.readFileSync(CERT) }, async (req, res) => {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    req.rawBody = Buffer.concat(chunks);          // 原始字节(THP blob 二进制分块用)
    let body = req.rawBody.toString('utf8');       // 文本视图(JSON 路由用)
    // 可选加密层: 默认不加密; X-TH-Enc: aes-gcm 时解密请求、加密响应
    if (req.headers['x-th-enc'] === 'aes-gcm' && body) {
      try { body = encDecrypt(body); } catch (e) {
        res.writeHead(400, {'Content-Type':'application/json'});
        return res.end(JSON.stringify({ object:'error', data:{ type:'invalid_request', message:'加密体解密失败' }}));
      }
      const origWrite = res.writeHead.bind(res);
      res.writeHead = (code, headers) => origWrite(code, { ...(headers || {}), 'X-TH-Enc': 'aes-gcm' });
      const origEnd = res.end.bind(res);
      res.end = (data) => origEnd(typeof data === 'string' ? encEncrypt(data) : data);
    }
    handle(req, res, body).catch(e => {
      res.writeHead(500, {'Content-Type':'application/json'});
      res.end(JSON.stringify({ object:'error', data:{ type:'server_error', message: String(e.message||e) }}));
    });
  });
});

// ─── 并发池(限流防封IP: 同时最多3个请求) ───
async function pool(items, n, fn) {
  const ret = new Array(items.length); let i = 0;
  const workers = Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) { const idx = i++; try { ret[idx] = await fn(items[idx], idx); } catch (e) { ret[idx] = { error: String(e.message || e) }; } }
  });
  await Promise.all(workers); return ret;
}

// ─── 存储服务: cloudreve(:5212) + aria2(:6800), vendor存在则spawn ───
const { spawn } = require('child_process');
// storageProcs/storageState 已上移至路由模块区(adminCtx 引用)
function startStorage() {
  const crDir = path.join(__dirname, 'vendor', 'cloudreve');
  const crBin = ['cloudreve', 'cloudreve.exe'].map(n => path.join(crDir, n)).find(fs.existsSync);
  if (crBin) {
    try { fs.chmodSync(crBin, 0o755);
      storageProcs.cloudreve = spawn(crBin, [], { cwd: crDir, env: { ...process.env, CR_PORT: '5212' } });
      storageState.cloudreve = 'running';
      storageProcs.cloudreve.on('exit', () => storageState.cloudreve = 'exited');
    } catch (e) { storageState.cloudreve = 'error: ' + e.message; }
  }
  const arDir = path.join(__dirname, 'vendor', 'aria2');
  const arBin = ['aria2c', 'aria2c.exe'].map(n => path.join(arDir, n)).find(fs.existsSync);
  if (arBin) {
    try { fs.chmodSync(arBin, 0o755);
      storageProcs.aria2 = spawn(arBin, ['--enable-rpc', '--rpc-listen-port=6800', '--rpc-allow-origin-all',
        '--dir=' + path.join(DATA, 'downloads'), '--seed-time=0', '--max-connection-per-server=16', '--split=16'],
        { cwd: arDir });
      storageState.aria2 = 'running';
      storageProcs.aria2.on('exit', () => storageState.aria2 = 'exited');
    } catch (e) { storageState.aria2 = 'error: ' + e.message; }
  }
  if (storageState.cloudreve === 'absent') console.log('[storage] cloudreve 未安装(放二进制到 vendor/cloudreve/, 官网 release 下载)');
  if (storageState.aria2 === 'absent') console.log('[storage] aria2 未安装(放二进制到 vendor/aria2/, 或 apt install aria2)');
}

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
startStorage();

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
