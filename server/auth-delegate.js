'use strict';
/**
 * 前端账号 → 后端授权（4.81.102）
 *
 * 产品口径：前端是主体，后端只是可选增强。用户在 App 里扫码登录 B站之后，
 * 连上家庭后端时把登录态**委托**给后端；后端不再弹自己的二维码、
 * 不再要求第二次登录，直接复用前端的 cookie 调 B站接口。
 *
 * 约定：
 *   POST   /v1/auth/delegate   { bili: { cookie, mid, name } }
 *   DELETE /v1/auth/delegate   撤销委托
 *   鉴权：x-th-token = 后端配对密钥（与其余 /v1/* 一致）
 *
 * 安全：cookie 只落在本机 data/delegated-auth.json（容器内），不进日志、
 * 不随公开接口返回；公开令牌不能调用本端点（只能主密钥）。
 */
const fs = require('fs');
const path = require('path');
const rtBili = require('./routes-bili');

const DATA = path.join(__dirname, 'data');
const FILE = path.join(DATA, 'delegated-auth.json');

function timingEqual(a, b) {
  a = String(a || '');
  b = String(b || '');
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function send(res, code, obj) {
  const s = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(s),
    'Cache-Control': 'no-store',
  });
  res.end(s);
}

/** 启动时恢复上次委托（容器重启后用户不用重新授权） */
function restore() {
  try {
    const j = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    const c = j && j.bili && j.bili.cookie;
    if (typeof c === 'string' && c.includes('SESSDATA=')) {
      rtBili.setDelegatedCookie(c, { mid: j.bili.mid, name: j.bili.name, at: j.at });
      console.log('[delegate] 已恢复前端委托的 B站登录态');
    }
  } catch (e) { /* 首次运行没有文件，正常 */ }
}

async function handle(req, res, body, secret) {
  if (req.method !== 'POST' && req.method !== 'DELETE') {
    send(res, 405, { ok: false, error: 'method not allowed' });
    return true;
  }
  if (!timingEqual(req.headers['x-th-token'] || '', secret || '')) {
    send(res, 401, { ok: false, error: '需要配对密钥' });
    return true;
  }

  if (req.method === 'DELETE') {
    rtBili.clearDelegatedCookie();
    try { fs.unlinkSync(FILE); } catch (e) { /* 本来就不存在 */ }
    send(res, 200, { ok: true, bili: false });
    return true;
  }

  // index.js 传进来的 body 是文本视图（JSON 字符串），不是已解析对象
  let data = body;
  if (typeof data === 'string') {
    try { data = JSON.parse(data || '{}'); } catch (e) { data = null; }
  }
  const b = (data && data.bili) || null;
  if (!b || typeof b.cookie !== 'string' || !b.cookie.includes('SESSDATA=')) {
    send(res, 400, { ok: false, error: '缺少 B站登录态（SESSDATA）' });
    return true;
  }
  // 只保留白名单字段，别把整个前端 cookie jar 原样落盘
  const clean = {
    cookie: b.cookie.slice(0, 4096),
    mid: String(b.mid || '').slice(0, 40),
    name: String(b.name || '').slice(0, 80),
  };
  rtBili.setDelegatedCookie(clean.cookie, clean);
  try {
    fs.mkdirSync(DATA, { recursive: true });
    fs.writeFileSync(FILE, JSON.stringify({ bili: clean, at: Date.now() }), { mode: 0o600 });
  } catch (e) {
    console.warn('[delegate] 落盘失败（本次会话仍可用）:' + e.message);
  }
  send(res, 200, { ok: true, bili: true, name: clean.name });
  return true;
}

module.exports = { handle, restore, FILE };
