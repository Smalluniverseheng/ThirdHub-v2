'use strict';
/**
 * 邮箱验证码（2026-11-20）
 *
 * 为什么不用 Supabase 自带邮件：实测 /auth/v1/recover 返回 504（内置 SMTP 超时），
 * 所以自己发信，注册/找回都走后端这条通道。
 *
 * 路由：
 *   POST /v1/auth/send-code   {email}        → 发 6 位码（60 秒 1 次 / 每小时 10 次）
 *   POST /v1/auth/verify-code {email, code}  → 通过返回 ticket（5 分钟有效，一次性）
 *   POST /v1/auth/check-ticket {ticket}      → 校验 ticket（注册前调用）
 *
 * 存储：/app/data/email-codes.json（进程内 Map + 文件持久化，重启不丢）
 */
const fs = require('fs');
const path = require('path');
const tls = require('tls');
const crypto = require('crypto');

const DATA = path.join(__dirname, 'data');
const STORE = path.join(DATA, 'email-codes.json');
const SMTP_HOST = process.env.SMTP163_HOST || 'smtp.163.com';
const SMTP_PORT = parseInt(process.env.SMTP163_PORT || '465', 10);
const SMTP_USER = process.env.SMTP163_USER || '';
const SMTP_PASS = process.env.SMTP163_PASS || '';

let store = { codes: {}, tickets: {}, sent: {} };
try { store = Object.assign(store, JSON.parse(fs.readFileSync(STORE, 'utf8'))); } catch (e) {}
let saveTimer = null;
function save() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      const now = Date.now();
      for (const k of Object.keys(store.codes)) if (store.codes[k].exp < now) delete store.codes[k];
      for (const k of Object.keys(store.tickets)) if (store.tickets[k].exp < now) delete store.tickets[k];
      fs.mkdirSync(DATA, { recursive: true });
      fs.writeFileSync(STORE, JSON.stringify(store));
    } catch (e) {}
  }, 200);
}

function send(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': body.length });
  res.end(body);
}

// nodemailer 装在 /app/data/node_modules（持久卷，容器重建不丢）；没有就退回到手写实现
let nodemailer = null;
try { nodemailer = require('/app/data/node_modules/nodemailer'); } catch (e) {
  try { nodemailer = require('nodemailer'); } catch (e2) { nodemailer = null; }
}

async function smtpSend(to, subject, html, text) {
  if (!SMTP_USER || !SMTP_PASS) throw new Error('未配置发件邮箱');
  if (nodemailer) {
    const tr = nodemailer.createTransport({
      host: SMTP_HOST,
      port: SMTP_PORT,
      secure: SMTP_PORT === 465,
      auth: { user: SMTP_USER, pass: SMTP_PASS },
      connectionTimeout: 20000,
      greetingTimeout: 20000,
      socketTimeout: 25000,
    });
    await tr.sendMail({
      from: '"ThirdHub 第三方聚合" <' + SMTP_USER + '>',
      to,
      subject,
      html,
      text: text || html.replace(/<[^>]+>/g, ''),
    });
    return true;
  }
  return smtpSendRaw(to, subject, html);
}

/** 兜底：最小 SMTP over TLS 客户端 */
function smtpSendRaw(to, subject, html) {
  return new Promise((resolve, reject) => {
    if (!SMTP_USER || !SMTP_PASS) return reject(new Error('未配置发件邮箱'));
    const sock = tls.connect({ host: SMTP_HOST, port: SMTP_PORT, servername: SMTP_HOST, timeout: 20000 }, () => {});
    let buf = '';
    let step = 0;
    const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');
    const msgId = '<' + crypto.randomBytes(12).toString('hex') + '@' + SMTP_HOST + '>';
    const body = [
      'From: "ThirdHub" <' + SMTP_USER + '>',
      'To: <' + to + '>',
      'Subject: =?UTF-8?B?' + b64(subject) + '?=',
      'MIME-Version: 1.0',
      'Content-Type: text/html; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      'Message-ID: ' + msgId,
      'Date: ' + new Date().toUTCString(),
      '',
      b64(html),
    ].join('\\r\\n');

    const write = (s) => sock.write(s + '\\r\\n');
    const done = (err) => {
      try { write('QUIT'); } catch (e) {}
      try { sock.destroy(); } catch (e) {}
      err ? reject(err) : resolve(true);
    };

    sock.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      // 等一个完整响应（多行以 "250-" 续行，"250 " 结束）
      const lines = buf.split('\\r\\n').filter(Boolean);
      const last = lines[lines.length - 1] || '';
      if (!/^\\d{3}[ ]/.test(last)) return;
      const code = parseInt(last.slice(0, 3), 10);
      buf = '';
      if (code >= 400) return done(new Error('SMTP ' + code + ' ' + last.slice(4)));
      switch (step++) {
        case 0: write('EHLO thirdhub'); break;
        case 1: write('AUTH LOGIN'); break;
        case 2: write(b64(SMTP_USER)); break;
        case 3: write(b64(SMTP_PASS)); break;
        case 4: write('MAIL FROM:<' + SMTP_USER + '>'); break;
        case 5: write('RCPT TO:<' + to + '>'); break;
        case 6: write('DATA'); break;
        case 7:
          sock.write(body + '\\r\\n.\\r\\n');
          break;
        default: done(null); break;
      }
    });
    sock.on('error', (e) => done(e));
    sock.on('timeout', () => done(new Error('SMTP 超时')));
  });
}

function bodyOf(b) {
  if (!b) return {};
  if (typeof b === 'object') return b;
  try { return JSON.parse(String(b)); } catch (e) { return {}; }
}

function normEmail(s) {
  return String(s || '').trim().toLowerCase();
}
function validEmail(s) {
  return /^[^@\s]{2,64}@[^@\s]{2,}\.[A-Za-z]{2,}$/.test(s);
}

async function handle(req, res, rawBody, u, p) {
  // index.js 的分发点上 body 可能还没赋值，优先从 req.rawBody 取
  let body = bodyOf(rawBody);
  if (!body || Object.keys(body).length === 0) {
    if (req && req.rawBody) body = bodyOf(req.rawBody.toString('utf8'));
    else if (req && req.body) body = bodyOf(req.body);
  }
  // 发验证码
  if (p === '/v1/auth/send-code' && req.method === 'POST') {
    const email = normEmail(body && body.email);
    if (!validEmail(email)) { send(res, 400, { ok: false, error: '邮箱格式不对' }); return true; }
    const now = Date.now();
    const last = store.sent[email] || 0;
    if (now - last < 60000) {
      send(res, 429, { ok: false, error: '请求太频繁，请 ' + Math.ceil((60000 - (now - last)) / 1000) + ' 秒后再试' });
      return true;
    }
    // 同一 IP 每小时 10 次
    const ip = String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
    const ipKey = 'ip:' + ip;
    const ipRec = store.sent[ipKey] || { n: 0, t: now };
    if (now - ipRec.t > 3600000) { ipRec.n = 0; ipRec.t = now; }
    if (ipRec.n >= 10) { send(res, 429, { ok: false, error: '该网络请求过多，请稍后再试' }); return true; }
    ipRec.n++; store.sent[ipKey] = ipRec;

    const code = String(Math.floor(100000 + Math.random() * 900000));
    store.codes[email] = { code, exp: now + 10 * 60000, tries: 0 };
    store.sent[email] = now;
    save();

    const html = '<div style="font:15px/1.7 -apple-system,Segoe UI,sans-serif;color:#222">'
      + '<p>你的验证码是</p>'
      + '<p style="font-size:30px;font-weight:700;letter-spacing:6px;color:#3b5bfd">' + code + '</p>'
      + '<p style="color:#666">10 分钟内有效。如果不是你本人操作，忽略这封邮件即可。</p>'
      + '<p style="color:#999;font-size:12px">ThirdHub 第三方聚合 · 此邮件由系统自动发送</p></div>';
    try {
      await smtpSend(email, 'ThirdHub 验证码 ' + code, html);
      send(res, 200, { ok: true, sent: true, expiresIn: 600 });
    } catch (e) {
      send(res, 502, { ok: false, error: '邮件发送失败：' + e.message });
    }
    return true;
  }

  // 校验验证码 → 发票据
  if (p === '/v1/auth/verify-code' && req.method === 'POST') {
    const email = normEmail(body && body.email);
    const code = String((body && body.code) || '').trim();
    const rec = store.codes[email];
    if (!rec) { send(res, 400, { ok: false, error: '请先获取验证码' }); return true; }
    if (rec.exp < Date.now()) { delete store.codes[email]; save(); send(res, 400, { ok: false, error: '验证码已过期，请重新获取' }); return true; }
    if (rec.tries >= 6) { delete store.codes[email]; save(); send(res, 429, { ok: false, error: '试错次数过多，请重新获取验证码' }); return true; }
    if (rec.code !== code) {
      rec.tries++; save();
      send(res, 400, { ok: false, error: '验证码不对' });
      return true;
    }
    const ticket = crypto.randomBytes(16).toString('hex');
    store.tickets[ticket] = { email, exp: Date.now() + 5 * 60000 };
    delete store.codes[email];
    save();
    send(res, 200, { ok: true, ticket, email });
    return true;
  }

  // 校验票据（注册前）
  if (p === '/v1/auth/check-ticket' && req.method === 'POST') {
    const tk = String((body && body.ticket) || '');
    const rec = store.tickets[tk];
    if (!rec || rec.exp < Date.now()) { send(res, 400, { ok: false, error: '验证已失效，请重新验证邮箱' }); return true; }
    send(res, 200, { ok: true, email: rec.email });
    return true;
  }

  return false;
}

module.exports = { handle, smtpSend };
