// ThirdHub v4 M1 家庭后端入口 :9527
// TLS 一层(自签+TOFU指纹) + 共享密钥鉴权(二层信封二期) + mDNS广播 + 书源API
const https = require('https');
const http = require('http');
const fs = require('fs'); const path = require('path');
const crypto = require('crypto');
const engine = require('./engine');
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

// ─── 内置演示书源(若空则提示导入; 不内置具体源, 见 sources/ 目录导入) ───

// ─── mDNS 广播 ───
try {
  const bonjour = new Bonjour();
  bonjour.publish({ name: 'thirdhub-' + crypto.randomBytes(3).toString('hex'), type: 'thirdhub-dev',
    port: 9527, txt: { type: 'backend', version: '4.0.0-m1', caps: 'novel' } });
} catch (e) { console.log('mDNS 广播跳过:', e.message); }

// ─── 极简静态(前端flutter build web产物可选挂载) ───
const PUB = path.join(__dirname, 'public');

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
  if (p === '/v1/devices') return send(200, { object:'list', data: devices });
  if (p === '/v1/status') return send(200, { object:'meta', data: {
    uptime: Math.floor(process.uptime()), version: '4.0.0-m1',
    sources: { total: sources.length, enabled: sources.filter(s => s.enabled !== false).length },
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
    // 成功源排前, 失败的排后但保留可见性
    results.sort((a, b) => (b.ok - a.ok) || (a.latency - b.latency));
    return send(200, { object:'list', data: results,
      meta: { total: results.length, ok: results.filter(r => r.ok).length } });
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
    try { return send(200, { object:'list', data: await engine.catalog(s, u.searchParams.get('url')) }); }
    catch (e) { return send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
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
