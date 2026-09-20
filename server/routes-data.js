// ThirdHub v4 数据服务路由: 密钥库(AES-GCM) + 阅读进度 + 设置同步 + 相册同步
// 从 index.js 拆出(2026-09 模块化), 路由逻辑逐字保留。
// 约定: 命中路由后 send() 会 end 响应, 主路由以 res.writableEnded 判定"已处理"。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ctx: 共享状态注入(引用类型, 与 index.js 互通)
async function handle(req, res, body, u, p, send, ctx) {
  const { DATA, SECRET } = ctx;
  // ── 密钥库(AES-GCM加密存储, 值脱敏返回) ──
  if (p === '/v1/keyvault' && req.method === 'GET') {
    const f = path.join(DATA, 'keyvault.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    return send(200, { object:'list', data: list.map(k => ({ ...k, value: k.value ? '••••••' + String(k.value).slice(-4) : '' })) });
  }
  if (p === '/v1/keyvault' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.name || !d.value) return send(400, { object:'error', data:{ type:'invalid_request', message:'需name+value' }});
    const f = path.join(DATA, 'keyvault.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    const encKey = crypto.createHash('sha256').update(SECRET).digest();
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', encKey, iv);
    const enc = Buffer.concat([cipher.update(String(d.value), 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    const existing = list.findIndex(x => x.name === d.name);
    const rec = { name: d.name, value: Buffer.concat([iv, tag, enc]).toString('base64'), at: Date.now() };
    existing >= 0 ? list[existing] = rec : list.push(rec);
    fs.writeFileSync(f, JSON.stringify(list, null, 2));
    return send(200, { object:'meta', data: { saved: d.name }});
  }
  if (p.startsWith('/v1/keyvault/get')) {
    const name = u.searchParams.get('name');
    const f = path.join(DATA, 'keyvault.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    const rec = list.find(x => x.name === name);
    if (!rec) return send(404, { object:'error', data:{ type:'not_found', message:'不存在' }});
    const raw = Buffer.from(rec.value, 'base64');
    const encKey = crypto.createHash('sha256').update(SECRET).digest();
    try {
      const decipher = crypto.createDecipheriv('aes-256-gcm', encKey, raw.slice(0, 12));
      decipher.setAuthTag(raw.slice(12, 28));
      const val = Buffer.concat([decipher.update(raw.slice(28)), decipher.final()]).toString('utf8');
      return send(200, { object:'meta', data: { name, value: val }});
    } catch (e) { return send(500, { object:'error', data:{ type:'server_error', message:'解密失败' }}); }
  }
  if (p === '/v1/keyvault/delete' && req.method === 'POST') {
    const name = u.searchParams.get('name');
    const f = path.join(DATA, 'keyvault.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    list = list.filter(x => x.name !== name);
    fs.writeFileSync(f, JSON.stringify(list, null, 2));
    return send(200, { object:'meta', data: { deleted: name }});
  }
  // ── 阅读进度(存用户自己的后端) ──
  if (p === '/v1/reading-progress' && req.method === 'POST') {
    const f = path.join(DATA, 'reading-progress.json');
    let all = {}; try { all = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    const d = JSON.parse(body || '{}');
    if (d.bookUrl) { all[d.bookUrl] = { index: d.index ?? 0, chapter: d.chapter ?? '', at: Date.now() }; }
    fs.writeFileSync(f, JSON.stringify(all));
    return send(200, { object:'meta', data: { saved: !!d.bookUrl, total: Object.keys(all).length }});
  }
  if (p === '/v1/reading-progress') {
    const f = path.join(DATA, 'reading-progress.json');
    let all = {}; try { all = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    return send(200, { object:'meta', data: all });
  }
  // ── 设置同步(跨设备: 昵称/偏好等JSON) ──
  if (p === '/v1/settings' && req.method === 'GET') {
    const f = path.join(DATA, 'settings.json');
    let s = {}; try { s = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    return send(200, { object:'meta', data: s });
  }
  if (p === '/v1/settings' && req.method === 'POST') {
    // 每用户1MB配额: 头像<0.5MB, 其余给设置
    if (body.length > 900 * 1024) return send(413, { object:'error', data:{ type:'quota_exceeded', message:'超出云端配额(1MB/用户)' }});
    const f = path.join(DATA, 'settings.json');
    let s = {}; try { s = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
    const incoming = JSON.parse(body || '{}');
    Object.assign(s, incoming.data || incoming);
    fs.writeFileSync(f, JSON.stringify(s, null, 2));
    return send(200, { object:'meta', data: { saved: true, keys: Object.keys(s) }});
  }
  // ── 相册同步(手机相册→后端) ──
  if (p === '/v1/album/upload' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.filename || !d.data) return send(400, { object:'error', data:{ type:'invalid_request', message:'需filename+data(base64)' }});
    const buf = Buffer.from(d.data, 'base64');
    if (buf.length > 30 * 1048576) return send(413, { object:'error', data:{ type:'invalid_request', message:'单张不超过30MB' }});
    const id = crypto.randomBytes(8).toString('hex');
    const ext = path.extname(d.filename) || '.jpg';
    const fname = id + ext;
    const fdir = path.join(DATA, 'album'); fs.mkdirSync(fdir, { recursive: true });
    fs.writeFileSync(path.join(fdir, fname), buf);
    const manifest = path.join(fdir, 'manifest.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch (e) {}
    list.unshift({ id, filename: d.filename, size: buf.length, at: Date.now(), mime: d.mime || 'image/jpeg' });
    fs.writeFileSync(manifest, JSON.stringify(list.slice(0, 5000)));
    return send(200, { object:'meta', data: { id, size: buf.length, total: list.length }});
  }
  if (p === '/v1/album/photos') {
    const manifest = path.join(DATA, 'album', 'manifest.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch (e) {}
    return send(200, { object:'list', data: list, meta: { total: list.length }});
  }
  if (p.startsWith('/v1/album/file')) {
    const id = u.searchParams.get('id');
    const manifest = path.join(DATA, 'album', 'manifest.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch (e) {}
    const item = list.find(x => x.id === id);
    if (!item) return send(404, { object:'error', data:{ type:'not_found', message:'照片不存在' }});
    const fpath = path.join(DATA, 'album', item.id + path.extname(item.filename));
    if (!fs.existsSync(fpath)) return send(404, { object:'error', data:{ type:'not_found', message:'文件已删' }});
    res.writeHead(200, { 'Content-Type': item.mime, 'Cache-Control': 'public, max-age=86400' });
    return res.end(fs.readFileSync(fpath));
  }
  if (p.startsWith('/v1/album/delete') && req.method === 'POST') {
    const id = u.searchParams.get('id');
    const manifest = path.join(DATA, 'album', 'manifest.json');
    let list = []; try { list = JSON.parse(fs.readFileSync(manifest, 'utf8')); } catch (e) {}
    const item = list.find(x => x.id === id);
    if (item) { try { fs.unlinkSync(path.join(DATA, 'album', item.id + path.extname(item.filename))); } catch (e) {} }
    list = list.filter(x => x.id !== id);
    fs.writeFileSync(manifest, JSON.stringify(list));
    return send(200, { object:'meta', data: { deleted: id }});
  }
  // ── 听书 TTS 合成（D-04）：前端发文本 → 后端用本机引擎合成 → 返回音频 ──
  // 引擎检测（按优先级）：
  //   1. vendor/piper/piper(.exe) + vendor/piper/*.onnx 模型 → 纯离线开源 TTS
  //   2. 系统 PATH 里的 edge-tts（pip install edge-tts）→ 微软在线朗读，免费
  // 都没有则 503 并给出安装指引。结果按 内容哈希 落盘缓存 data/tts_cache/。
  if (p === '/v1/tts' && req.method === 'POST') {
    let d = {}; try { d = JSON.parse(body || '{}'); } catch (e) {}
    const text = String(d.text || '').slice(0, 5000).trim();
    if (!text) return send(400, { object:'error', data:{ type:'invalid_request', message:'text 不能为空' }});
    const engine = String(d.engine || 'auto');
    const voice = String(d.voice || 'zh-CN-XiaoxiaoNeural');
    const rate = String(d.rate || '+0%');
    const cacheDir = path.join(DATA, 'tts_cache');
    fs.mkdirSync(cacheDir, { recursive: true });
    const key = crypto.createHash('md5').update(engine + '|' + voice + '|' + rate + '|' + text).digest('hex');
    const mp3 = path.join(cacheDir, key + '.mp3');
    const wav = path.join(cacheDir, key + '.wav');
    const hit = [mp3, wav].find(fs.existsSync);
    if (hit) {
      res.writeHead(200, { 'Content-Type': hit.endsWith('.wav') ? 'audio/wav' : 'audio/mpeg', 'X-TH-TTS-Cache': 'hit' });
      return res.end(fs.readFileSync(hit));
    }
    const { spawn } = require('child_process');
    const piperBin = ['piper.exe', 'piper'].map(n => path.join(__dirname, 'vendor', 'piper', n)).find(fs.existsSync);
    let piperModel = null;
    try {
      piperModel = fs.readdirSync(path.join(__dirname, 'vendor', 'piper')).find(f => f.endsWith('.onnx'));
      if (piperModel) piperModel = path.join(__dirname, 'vendor', 'piper', piperModel);
    } catch (e) {}
    const usePiper = (engine === 'piper' || engine === 'auto') && piperBin && piperModel;

    if (usePiper) {
      // piper: 文本走 stdin，输出 wav
      const child = spawn(piperBin, ['-m', piperModel, '-f', wav, '-q'], { stdio: ['pipe', 'ignore', 'pipe'] });
      let err = '';
      child.stderr.on('data', c => err += c);
      child.on('close', (code) => {
        if (code === 0 && fs.existsSync(wav)) {
          res.writeHead(200, { 'Content-Type': 'audio/wav', 'X-TH-TTS-Engine': 'piper' });
          return res.end(fs.readFileSync(wav));
        }
        return send(502, { object:'error', data:{ type:'server_error', message:'piper 合成失败: ' + (err || code) }});
      });
      child.stdin.write(text); child.stdin.end();
      return;
    }
    // edge-tts 在线（需本机装有 edge-tts）
    if (engine === 'piper') {
      return send(503, { object:'error', data:{ type:'server_error',
        message:'未找到 piper。把 piper.exe 和 *.onnx 模型放进 server/vendor/piper/ 即可启用离线 TTS' }});
    }
    const child = spawn('edge-tts', ['--voice', voice, '--rate', rate, '--text', text, '--write-media', mp3], { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    child.on('error', () => send(503, { object:'error', data:{ type:'server_error',
      message:'后端未装 edge-tts。安装: pip install edge-tts（在线微软朗读，免费）；或把 piper 离线引擎放进 server/vendor/piper/' }}));
    child.stderr.on('data', c => err += c);
    child.on('close', (code) => {
      if (code === 0 && fs.existsSync(mp3)) {
        res.writeHead(200, { 'Content-Type': 'audio/mpeg', 'X-TH-TTS-Engine': 'edge' });
        return res.end(fs.readFileSync(mp3));
      }
      return send(502, { object:'error', data:{ type:'server_error', message:'edge-tts 合成失败: ' + (err || code) }});
    });
    return;
  }
  // TTS 能力探测：前端据此决定要不要显示"后端合成"选项
  if (p === '/v1/tts/cap') {
    let piper = false, edge = false, voices = [];
    try {
      const dir = path.join(__dirname, 'vendor', 'piper');
      const bin = ['piper.exe', 'piper'].map(n => path.join(dir, n)).find(fs.existsSync);
      const model = fs.readdirSync(dir).find(f => f.endsWith('.onnx'));
      piper = !!(bin && model);
    } catch (e) {}
    try { require('child_process').execSync('edge-tts --version', { stdio: 'pipe', timeout: 5000 }); edge = true; } catch (e) {}
    if (edge) voices = ['zh-CN-XiaoxiaoNeural', 'zh-CN-YunxiNeural', 'zh-CN-YunjianNeural', 'zh-CN-XiaoyiNeural', 'zh-CN-YunyangNeural'];
    return send(200, { object:'meta', data: { piper, edge, voices }});
  }
  // ── Python 执行(AI 智能体工具 run_python): 后端本机 python 跑代码片段 ──
  // 安全边界: 后端只服务局域网内持有配对密钥的设备(入口 401 闸门); 本端点再收紧:
  // 代码 ≤20KB, 跑 20s 强杀, stdout/stderr 各截 8KB, -I 隔离模式(不带当前目录/PYTHONPATH)。
  if (p === '/v1/py' && req.method === 'POST') {
    let d = {}; try { d = JSON.parse(body || '{}'); } catch (e) {}
    const code = String(d.code || '');
    if (!code.trim()) return send(400, { object:'error', data:{ type:'invalid_request', message:'code 不能为空' }});
    if (code.length > 20000) return send(413, { object:'error', data:{ type:'invalid_request', message:'代码过长(≤20000字符)' }});
    const { spawn } = require('child_process');
    const tmpDir = path.join(DATA, 'py_tmp');
    fs.mkdirSync(tmpDir, { recursive: true });
    const f = path.join(tmpDir, 'run_' + Date.now().toString(36) + '_' + crypto.randomBytes(3).toString('hex') + '.py');
    fs.writeFileSync(f, code, 'utf8');
    const bin = process.platform === 'win32' ? 'python' : 'python3';
    let child;
    try {
      child = spawn(bin, ['-I', f], { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      fs.unlinkSync(f);
      return send(503, { object:'error', data:{ type:'server_error', message:'后端本机没有 Python。安装 Python 3 并加入 PATH 即可启用' }});
    }
    let out = '', err = '', done = false;
    const cap = (s, c) => (s + c).length > 8192 ? (s + c).slice(0, 8192) : s + c;
    child.stdout.on('data', c2 => { out = cap(out, c2.toString('utf8')); });
    child.stderr.on('data', c2 => { err = cap(err, c2.toString('utf8')); });
    const killer = setTimeout(() => { if (!done) { try { child.kill('SIGKILL'); } catch (e) {} } }, 20000);
    child.on('error', () => {
      if (done) return; done = true; clearTimeout(killer);
      try { fs.unlinkSync(f); } catch (e) {}
      send(503, { object:'error', data:{ type:'server_error', message:'后端本机没有 Python。安装 Python 3 并加入 PATH 即可启用' }});
    });
    child.on('close', (code2, sig) => {
      if (done) return; done = true; clearTimeout(killer);
      try { fs.unlinkSync(f); } catch (e) {}
      if (sig) err = (err ? err + '\n' : '') + '(超时被终止)';
      send(200, { object:'meta', data: { stdout: out, stderr: err, code: code2 ?? -1 } });
    });
    return;
  }
  // ── 反馈中心(应用内反馈, 不再跳 GitHub): 文字+图片 → 落盘 data/feedback/ ──
  if (p === '/v1/feedback' && req.method === 'POST') {
    let d = {}; try { d = JSON.parse(body || '{}'); } catch (e) {}
    const text = String(d.text || '').trim();
    if (!text) return send(400, { object:'error', data:{ type:'invalid_request', message:'反馈内容不能为空' }});
    if (text.length > 8000) return send(413, { object:'error', data:{ type:'invalid_request', message:'内容过长(≤8000字)' }});
    const imgs = Array.isArray(d.images) ? d.images.slice(0, 6) : [];
    const dir = path.join(DATA, 'feedback');
    fs.mkdirSync(dir, { recursive: true });
    const id = 'fb_' + Date.now().toString(36) + crypto.randomBytes(3).toString('hex');
    const savedImgs = [];
    for (let i = 0; i < imgs.length; i++) {
      try {
        const buf = Buffer.from(String(imgs[i]), 'base64');
        if (buf.length > 5 * 1048576) continue; // 单图≤5MB
        const fn = id + '_' + i + '.jpg';
        fs.writeFileSync(path.join(dir, fn), buf);
        savedImgs.push(fn);
      } catch (e) {}
    }
    const rec = { id, text, contact: String(d.contact || ''), at: Date.now(),
      device: String(d.device || ''), version: String(d.version || ''), images: savedImgs };
    fs.writeFileSync(path.join(dir, id + '.json'), JSON.stringify(rec, null, 2));
    return send(200, { object:'meta', data: { id, saved: true, images: savedImgs.length }});
  }
  // 管理后台拉取反馈列表(需密钥)
  if (p === '/v1/feedback' && req.method === 'GET') {
    const dir = path.join(DATA, 'feedback');
    let list = [];
    try {
      list = fs.readdirSync(dir).filter(f => f.endsWith('.json')).map(f => {
        try { return JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); } catch (e) { return null; }
      }).filter(Boolean);
    } catch (e) {}
    list.sort((a, b) => b.at - a.at);
    return send(200, { object:'list', data: list.slice(0, 500), meta: { total: list.length }});
  }
  // 反馈图片
  if (p.startsWith('/v1/feedback/img')) {
    const fn = path.basename(String(u.searchParams.get('f') || ''));
    const fp = path.join(DATA, 'feedback', fn);
    if (!fn || !fs.existsSync(fp)) return send(404, { object:'error', data:{ type:'not_found', message:'图片不存在' }});
    res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'private, max-age=3600' });
    return res.end(fs.readFileSync(fp));
  }
  return false; // 未命中, 交回主路由
}

module.exports = { handle };
