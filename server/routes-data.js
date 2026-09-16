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
  return false; // 未命中, 交回主路由
}

module.exports = { handle };
