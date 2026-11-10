// server/services/adapters/qbittorrent.js — 下载器适配器（qBittorrent Web API v2）
//
// 用途：用户在前端搜到资源 → 点下载 → 后端调这里丢给 qBittorrent → 下到 Media/_下载。
// 探活特例：qB 未登录时 /api/v2/app/version 返回 403，
//   这**恰恰说明服务是活的**（只是还没设账号），所以 403 也判为在线，并标 needAuth。
'use strict';

const UA = 'ThirdHub/1.0';
const sidCache = new Map(); // svc.id -> { cookie, at }

function base(svc) {
  return String(svc.baseUrl || '').replace(/\/+$/, '');
}

async function login(svc, timeoutMs = 8000) {
  const auth = svc.auth || {};
  if (!auth.username || !auth.password) return '';
  const hit = sidCache.get(svc.id);
  if (hit && Date.now() - hit.at < 40 * 60 * 1000) return hit.cookie;
  const body = new URLSearchParams({ username: auth.username, password: auth.password });
  const r = await fetch(base(svc) + '/api/v2/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': UA, Referer: base(svc) },
    body: body.toString(),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const t = await r.text();
  if (!r.ok || !/ok/i.test(t)) throw new Error('登录被拒（检查账号密码）: ' + t.slice(0, 40));
  const raw = r.headers.getSetCookie ? r.headers.getSetCookie() : [];
  const cookie = (raw || []).map((c) => c.split(';')[0]).join('; ');
  if (cookie) sidCache.set(svc.id, { cookie, at: Date.now() });
  return cookie;
}

async function api(svc, path, opts = {}) {
  const cookie = await login(svc);
  if (!cookie) throw new Error('未配置下载器账号');
  const r = await fetch(base(svc) + path, {
    ...opts,
    headers: {
      'User-Agent': UA, Referer: base(svc), Cookie: cookie,
      ...(opts.headers || {}),
    },
    signal: AbortSignal.timeout(opts.timeoutMs || 10000),
  });
  return r;
}

module.exports = {
  async probe(svc, timeoutMs = 6000) {
    const t0 = Date.now();
    const r = await fetch(base(svc) + '/api/v2/app/version', {
      headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(timeoutMs),
    });
    const txt = (await r.text()).trim();
    if (r.ok) return { ok: true, ms: Date.now() - t0, info: { version: txt.slice(0, 20), auth: true } };
    if (r.status === 403) return { ok: true, ms: Date.now() - t0, info: { needAuth: true, http: 403 } };
    return { ok: false, ms: Date.now() - t0, error: 'HTTP ' + r.status };
  },

  /** 丢一个种子/磁力进去。返回 { ok, added } */
  async addTorrent(svc, url, opts = {}) {
    const form = new URLSearchParams({ urls: String(url) });
    if (opts.savePath) form.set('savepath', opts.savePath);
    if (opts.category) form.set('category', opts.category);
    const r = await api(svc, '/api/v2/torrents/add', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    });
    const t = (await r.text()).trim();
    return { ok: r.ok, added: /Ok/i.test(t), raw: t.slice(0, 60) };
  },

  /** 任务列表（前端"我的下载"用） */
  async list(svc) {
    const r = await api(svc, '/api/v2/torrents/info');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const arr = await r.json();
    return (arr || []).slice(0, 50).map((x) => ({
      id: x.hash, title: x.name, progress: x.progress,
      state: x.state, size: x.size, dlspeed: x.dlspeed,
      eta: x.eta, savePath: x.save_path, category: x.category,
    }));
  },
};
