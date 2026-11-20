'use strict';
/**
 * 安装包分发（2026-11-20 升级：拉取记录 + 版本包要求登录）
 *
 * 路由：
 *   GET /v1/dl/app               清单（公开）
 *   GET /v1/dl/app/latest.apk    最新包（放行，兼容老客户端自动更新；记录来源）
 *   GET /v1/dl/app/<ver>.apk     指定版本（要求登录，未登录 401）
 *   GET /v1/dl/log               最近拉取记录（只读，管理员）
 *
 * 记录：/app/data/download-log.jsonl 每行 {at,name,ip,ua,logged,email}
 */
const fs = require('fs');
const path = require('path');

const APK_DIR = process.env.TH_APK_DIR || path.join(__dirname, 'data', 'apk');
const LOG_FILE = path.join(path.dirname(APK_DIR), 'download-log.jsonl');
const NAME_RE = /^thirdhub-app(-[0-9.]+)?\.apk$/;
const SB = (process.env.SUPABASE2_URL || '').replace(/\/$/, '');
const SB_KEY = process.env.SUPABASE2_SERVICE_ROLE_KEY || '';

function send(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length });
  res.end(body);
}

function listApks() {
  let names = [];
  try { names = fs.readdirSync(APK_DIR); } catch (e) { return []; }
  return names.filter((n) => NAME_RE.test(n)).map((n) => {
    const st = fs.statSync(path.join(APK_DIR, n));
    return { name: n, size: st.size, mtime: st.mtimeMs };
  }).sort((a, b) => b.mtime - a.mtime);
}

function latestName() {
  const all = listApks();
  if (!all.length) return '';
  const alias = all.find((x) => x.name === 'thirdhub-app.apk');
  return alias ? alias.name : all[0].name;
}

async function emailOf(token) {
  if (!token || !SB || !SB_KEY) return '';
  try {
    const r = await fetch(SB + '/auth/v1/user', {
      headers: { apikey: SB_KEY, Authorization: 'Bearer ' + token },
      signal: AbortSignal.timeout(5000),
    });
    if (!r.ok) return '';
    const j = await r.json();
    return j.email || '';
  } catch (e) { return ''; }
}

function appendLog(rec) {
  try { fs.appendFileSync(LOG_FILE, JSON.stringify(rec) + '\n'); } catch (e) {}
}

function streamFile(req, res, file, name) {
  let st;
  try { st = fs.statSync(file); } catch (e) { send(res, 404, { ok: false, error: '没有这个安装包' }); return; }

  const auth = String(req.headers.authorization || '');
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const ip = String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
  const ua = String(req.headers['user-agent'] || '').slice(0, 160);
  const rec = { at: new Date().toISOString(), name, ip, ua, logged: !!token, email: '' };
  if (token) {
    emailOf(token).then((em) => { if (em) appendLog(Object.assign({}, rec, { email: em, resolved: true })); });
  }
  appendLog(rec);

  const range = req.headers.range;
  const headers = {
    'content-type': 'application/vnd.android.package-archive',
    'accept-ranges': 'bytes',
    'cache-control': 'no-store',
  };
  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    if (m) {
      const start = m[1] ? parseInt(m[1], 10) : 0;
      const end = m[2] ? Math.min(parseInt(m[2], 10), st.size - 1) : st.size - 1;
      if (start >= st.size || end < start) { res.writeHead(416, { 'content-range': 'bytes */' + st.size }); res.end(); return; }
      headers['content-range'] = 'bytes ' + start + '-' + end + '/' + st.size;
      headers['content-length'] = end - start + 1;
      res.writeHead(206, headers);
      fs.createReadStream(file, { start, end }).pipe(res);
      return;
    }
  }
  headers['content-length'] = st.size;
  res.writeHead(200, headers);
  fs.createReadStream(file).pipe(res);
}

function handle(req, res, u, p) {
  if (p === '/v1/dl/app' || p === '/v1/dl/app/') {
    send(res, 200, { ok: true, latest: latestName(), items: listApks(), dir: APK_DIR });
    return true;
  }
  if (p.startsWith('/v1/dl/app/')) {
    const name = decodeURIComponent(p.slice('/v1/dl/app/'.length));
    if (name === 'latest.apk') { streamFile(req, res, path.join(APK_DIR, latestName()), 'latest.apk'); return true; }
    if (!NAME_RE.test(name)) { send(res, 400, { ok: false, error: '文件名不合法' }); return true; }
    const auth = String(req.headers.authorization || '');
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!token) { send(res, 401, { ok: false, error: '需要先登录', needLogin: true }); return true; }
    streamFile(req, res, path.join(APK_DIR, name), name);
    return true;
  }
  if (p === '/v1/dl/log') {
    let lines = [];
    try {
      const raw = fs.readFileSync(LOG_FILE, 'utf8').trim().split('\n');
      lines = raw.slice(-200).map((l) => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean);
    } catch (e) {}
    send(res, 200, { ok: true, count: lines.length, items: lines.reverse() });
    return true;
  }
  send(res, 404, { ok: false, error: '未知操作' });
  return true;
}

module.exports = { handle, APK_DIR, listApks, latestName };
