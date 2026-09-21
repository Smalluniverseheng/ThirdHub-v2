// ═══════════════════════════════════════════════════════════════════════════
// peer-hub.js — 端间互通中枢（协议 PH/1）
//
// 解决什么问题（用户原话拆解）：
//   · 「前端后端还是那个 dsa 随时插线，一方输入其他方都能用」
//     → 任一端上线即注册；其他端都能看见它、调用它、给它派活。
//   · 「没有后端也能够直接通过插件开始 IPv6/内网穿透连接到前端来使用」
//     → 插件自报 ipv6 / tunnel 地址；列表里带出来，前端离线也能直连。
//   · 「所有的密钥只要前端/后端/插件上有，都会统一到其他所有端」
//     → /agent/peer/secrets：任何一端写入，其他端按 rev 拉到。
//   · 「插件只需要登录对应的账号之后就可以连接」
//     → /agent/peer/join 支持 账号口令 / 后端密钥 两种凭据换 peerToken。
//
// 三类参与者（kind）：
//   front  手机/桌面前端 App
//   plug   插件（局域网内任意进程，实现 /peer/manifest + /peer/exec）
//   dsa    DSH/DSH-Agent 侧
//   back   后端自身（index.js 启动时自注册）
//
// 挂载：index.js 的 handle() 中 **鉴权闸门之前** 调用
//   if (p.startsWith('/agent/peer') && await peerHub.handle(...)) return;
// 未命中返回 false 交给后续路由。
//
// 为什么 join/beat/list 必须放在闸门之前：与 /v1/pair 同一个历史教训 ——
// 还没拿到密钥的端/插件如果被 401 挡死，"连接不上/没反应"会无法诊断。
// 安全性由 join 的凭据校验 + 后续请求的 peerToken 兜住，且 join 不回传 SECRET。
// ═══════════════════════════════════════════════════════════════════════════
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

let DATA = path.join(__dirname, 'data');
let SECRET = '';
let PEERS_FILE = '';
let MSG_FILE = '';
let SEC_FILE = '';

// ─── 在线窗口与容量上限 ───
const ONLINE_MS = 45000;     // 45s 内有心跳 = 在线（心跳 15s，容 3 次丢包）
const STALE_KEEP_MS = 7 * 864e5; // 离线端保留 7 天，超期清理
const MAX_MSGS = 500;        // 消息环形缓冲
const MAX_PEERS = 200;

// ─── 内存态 ───
let REG = null;              // { version, accounts:{user:{pass,role}}, peers:[] }
let MSGS = [];               // [{id, at, from, to, topic, payload}]
let SECRETS = {};            // { name: { value, rev, updatedAt, from } }
let me = null;               // 后端自身的 peer 记录（供 list 展示）
let msgSeq = 1;

// ─────────────────────────────────────────────────────────────────────────
// 存储层
// ─────────────────────────────────────────────────────────────────────────
function sha(s) { return crypto.createHash('sha256').update(String(s)).digest('hex'); }
function rid(n = 12) { return crypto.randomBytes(n).toString('hex'); }

function readJson(f, dflt) {
  try { const j = JSON.parse(fs.readFileSync(f, 'utf8')); return j === null || j === undefined ? dflt : j; } catch { return dflt; }
}
function writeJson(f, v) {
  try { fs.writeFileSync(f, JSON.stringify(v, null, 2), 'utf8'); return true; } catch { return false; }
}

function init(opts = {}) {
  if (opts.DATA) DATA = opts.DATA;
  if (opts.SECRET) SECRET = opts.SECRET;
  try { fs.mkdirSync(DATA, { recursive: true }); } catch (_) {}
  PEERS_FILE = path.join(DATA, 'agent-peers.json');
  MSG_FILE = path.join(DATA, 'agent-peer-msgs.json');
  SEC_FILE = path.join(DATA, 'agent-secrets.json');

  REG = readJson(PEERS_FILE, null);
  if (!REG || !Array.isArray(REG.peers)) {
    REG = {
      version: 1,
      // 默认账号：与官方仓库密码一致，便于记忆；上线后可在管理台改。
      accounts: { admin: { pass: sha('123456'), role: 'admin' } },
      peers: [],
    };
    writeJson(PEERS_FILE, REG);
  }
  if (!REG.accounts || typeof REG.accounts !== 'object') REG.accounts = { admin: { pass: sha('123456'), role: 'admin' } };
  MSGS = readJson(MSG_FILE, []);
  if (!Array.isArray(MSGS)) MSGS = [];
  SECRETS = readJson(SEC_FILE, {});
  if (!SECRETS || typeof SECRETS !== 'object' || Array.isArray(SECRETS)) SECRETS = {};

  // 后端把自己也注册进去 —— 否则前端看到的"端列表"里缺了中枢本身。
  me = REG.peers.find((x) => x.kind === 'back' && x.iid === 'local-back');
  if (!me) {
    me = {
      iid: 'local-back', kind: 'back', name: 'ThirdHub 后端',
      url: '', ipv6: '', tunnel: '', caps: ['hub', 'relay', 'secrets', 'files', 'agent', 'mcp'],
      tools: [], account: 'admin', tokenHash: '', firstSeen: Date.now(), lastSeen: Date.now(), vip: true,
    };
    REG.peers.push(me);
    writeJson(PEERS_FILE, REG);
  }
  me.lastSeen = Date.now();
  return REG;
}

function save() { writeJson(PEERS_FILE, REG); }
function saveMsgs() { writeJson(MSG_FILE, MSGS.slice(-MAX_MSGS)); }
function saveSecrets() { writeJson(SEC_FILE, SECRETS); }

// ─────────────────────────────────────────────────────────────────────────
// 凭据校验
// ─────────────────────────────────────────────────────────────────────────
/** 账号口令校验：支持 {user, pass} 或 {token}(=SECRET)。 */
function checkCred(d) {
  const tok = String(d.token || d.backendToken || '');
  if (SECRET && tok && tok === SECRET) return { ok: true, account: 'backend-key', role: 'admin' };
  const user = String(d.account || d.user || '').trim();
  const pass = String(d.password || d.pass || '');
  if (!user) return { ok: false, error: 'ACCOUNT_REQUIRED' };
  const rec = REG.accounts[user];
  if (!rec) return { ok: false, error: 'ACCOUNT_NOT_FOUND' };
  // 允许明文或 sha256 两种提交（sha256 便于插件不落地明文口令）
  if (rec.pass !== pass && rec.pass !== sha(pass)) return { ok: false, error: 'BAD_PASSWORD' };
  return { ok: true, account: user, role: rec.role || 'user' };
}

/** peerToken 校验 → 返回 peer 记录或 null。 */
function byToken(tok) {
  const t = String(tok || '');
  if (!t) return null;
  const h = sha(t);
  return REG.peers.find((x) => x.tokenHash && x.tokenHash === h) || null;
}

function isOnline(p) { return Date.now() - (p.lastSeen || 0) < ONLINE_MS; }

/// 这个端是否"已接入"（而非仅被局域网 UDP 发现）。
/// ★ 为什么必须区分：UDP 广播没有任何鉴权，任何人都能伪造一条 HELLO 让自己
///   出现在列表里。如果把"被发现"当成"在线"，就等于给了局域网里任意进程
///   一个免登录入口 —— 而用户的要求是「插件只需要登录对应的账号之后就可以连接」，
///   也就是**登录是接入的必要条件**。所以：发现 → 只是登记；登录 → 才算在线。
function isJoined(p) { return !!p.tokenHash || !!p.vip; }

/** 视角净化：tokenHash 绝不出网。 */
function view(p) {
  return {
    iid: p.iid, kind: p.kind, name: p.name, url: p.url || '', ipv6: p.ipv6 || '',
    tunnel: p.tunnel || '', caps: p.caps || [], tools: p.tools || [],
    account: p.account || '',
    online: isOnline(p) && isJoined(p),
    // 只被发现、还没登录 —— UI 据此显示"待登录"，而不是"离线"
    discovered: !isJoined(p),
    firstSeen: p.firstSeen || 0, lastSeen: p.lastSeen || 0,
    vip: !!p.vip,
    // 无后端直连提示：插件自报的 ipv6/tunnel 才是"没后端也能用"的落点。
    direct: [p.url, p.ipv6, p.tunnel].filter(Boolean),
  };
}

function prune() {
  const now = Date.now();
  const before = REG.peers.length;
  REG.peers = REG.peers.filter((p) => p.vip || (now - (p.lastSeen || 0)) < STALE_KEEP_MS);
  if (REG.peers.length !== before) save();
}

/**
 * 局域网 UDP 发现入账（由 index.js 的 19527 监听回调调用）。
 *
 * 只是"知道有这么个端"：登记 url/caps，但**不发放 token**，因此在 view() 里
 * 表现为 `discovered: true + online: false` —— 前端会显示"待登录"，
 * 而路由/调用都不会选它。插件自己带账号口令 POST /agent/peer/join 之后才真正接入。
 *
 * 这样既满足「插在局域网内，后端就能发现各端」，又不会因为 UDP 无鉴权
 * 而给局域网里任意进程一个免登录入口。
 */
function discover(info = {}) {
  if (!REG) init();
  const iid = String(info.iid || '').trim().slice(0, 64);
  const port = parseInt(info.port, 10);
  const addr = String(info.addr || '').replace(/^::ffff:/, '');
  if (!iid || iid === 'local-back') return null;
  if (!port || !addr) return null;
  const url = /^\[?[0-9a-fA-F:]+\]?$/.test(addr) ? 'http://[' + addr.replace(/[\[\]]/g, '') + ']:' + port
                                                     : 'http://' + addr + ':' + port;
  let p = REG.peers.find((x) => x.iid === iid);
  if (!p) {
    if (REG.peers.length >= MAX_PEERS) return null;
    p = {
      iid, kind: 'plug',
      name: String(info.name || '').slice(0, 64) || ('插件 ' + iid.slice(0, 6)),
      url, ipv6: '', tunnel: '',
      // ★ 新建分支也必须落 caps —— 自测抓到过一次：这里漏了，于是"局域网发现的
      //   插件"在 UI 里永远显示不出它能干什么（caps 空），用户没法判断要不要接入它。
      caps: Array.isArray(info.caps) ? info.caps.map((c) => String(c).slice(0, 32)).slice(0, 32) : [],
      tools: [],
      account: '', tokenHash: '', discovered: true,
      firstSeen: Date.now(), lastSeen: Date.now(), ip: addr,
    };
    REG.peers.push(p);
    console.log('[peer] discover plug ' + p.name + ' @ ' + url + '（待登录）');
    save();
    return p;
  }
  p.lastSeen = Date.now();
  if (p.tokenHash) {
    // 已登录的端：地址以它自己 join/beat 上报的为准，不拿 UDP 来源覆盖
    save();
    return p;
  }
  p.url = url;
  if (Array.isArray(info.caps) && info.caps.length) {
    p.caps = info.caps.map((c) => String(c).slice(0, 32)).slice(0, 32);
  }
  if (info.name) p.name = String(info.name).slice(0, 64);
  p.discovered = true;
  p.ip = addr;
  save();
  return p;
}

// ─────────────────────────────────────────────────────────────────────────
// 信封
//
// ★ 必须 return true —— 调用方是 `if (p.startsWith('/agent/peer') && await handle(...)) return;`
//   若返回 undefined，响应虽然已经发出去了，主路由却不会短路，会继续往下
//   匹配路由 → 二次 writeHead 抛 ERR_HTTP_HEADERS_SENT（或抢答 404）。
//   这条正是自测第 2 节「前缀命中」抓出来的：got=undefined want=true。
// ─────────────────────────────────────────────────────────────────────────
function json(res, code, obj, ridHdr) {
  const h = { 'Content-Type': 'application/json; charset=utf-8' };
  if (ridHdr) h['X-TH-Request-Id'] = ridHdr;
  res.writeHead(code, h);
  res.end(JSON.stringify(obj));
  return true;
}
function ok(res, data, meta, ridHdr) { return json(res, 200, { ok: true, data, meta: meta || {} }, ridHdr); }
function err(res, code, message, status = 200, ridHdr) {
  return json(res, status, { ok: false, error: { code, message } }, ridHdr);
}

// ─────────────────────────────────────────────────────────────────────────
// HTTP 客户端（转发到目标端）
// ─────────────────────────────────────────────────────────────────────────
async function postJson(url, payload, timeoutMs = 8000, headers = null) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' }, headers || {}),
      body: JSON.stringify(payload),
      signal: ctl.signal,
    });
    const text = await r.text();
    let j = null;
    try { j = JSON.parse(text); } catch (_) {}
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return j === null ? { ok: true, data: text } : j;
  } finally { clearTimeout(t); }
}

/** 把目标端的各种地址形态补全成可用 URL。 */
function asUrl(u) {
  let s = String(u || '').trim();
  if (!s) return '';
  if (!/^https?:\/\//i.test(s)) s = 'http://' + s;
  return s;
}

// ─────────────────────────────────────────────────────────────────────────
// 主路由
// ─────────────────────────────────────────────────────────────────────────
async function handle(req, res, body, u) {
  const p = u.pathname;
  if (!p.startsWith('/agent/peer')) return false;
  if (!REG) init();
  const ridHdr = req.headers['x-th-request-id'];
  let d = {};
  try { d = JSON.parse(body || '{}'); } catch (_) {}

  // ── POST /agent/peer/join —— 端/插件上线（匿名可达，凭据兜底）──
  // 插件用账号口令换 peerToken；同局域网已配对的前端直接用后端密钥换。
  if (p === '/agent/peer/join' && req.method === 'POST') {
    const kind = String(d.kind || 'plug').slice(0, 16);
    if (!['front', 'plug', 'dsa', 'back'].includes(kind)) return err(res, 'BAD_KIND', 'kind 需为 front/plug/dsa/back', 400, ridHdr);
    // 已持有 peerToken 的端直接续用（重启后免重新登录）
    let rec = byToken(d.peerToken);
    let cred = null;
    if (!rec) {
      cred = checkCred(d);
      if (!cred.ok) return err(res, 'UNAUTHORIZED', '需要账号口令或后端密钥: ' + cred.error, 401, ridHdr);
    }
    const iid = String(d.iid || (rec && rec.iid) || rid(8)).slice(0, 64);
    prune();
    if (!rec) rec = REG.peers.find((x) => x.iid === iid);
    const freshToken = rid(20);
    if (!rec) {
      if (REG.peers.length >= MAX_PEERS) return err(res, 'TOO_MANY_PEERS', '端数量已达上限', 200, ridHdr);
      rec = { iid, kind, tokenHash: '', firstSeen: Date.now() };
      REG.peers.push(rec);
    }
    // 更新可变字段（缺省不改，避免前端只发心跳字段时把 url 清空）
    rec.kind = kind;
    if (d.name !== undefined) rec.name = String(d.name || '').slice(0, 64) || rec.iid;
    if (d.url !== undefined) rec.url = String(d.url || '').slice(0, 512);
    if (d.ipv6 !== undefined) rec.ipv6 = String(d.ipv6 || '').slice(0, 512);
    if (d.tunnel !== undefined) rec.tunnel = String(d.tunnel || '').slice(0, 512);
    if (Array.isArray(d.caps)) rec.caps = d.caps.map((c) => String(c).slice(0, 32)).slice(0, 32);
    else if (!rec.caps) rec.caps = [];
    if (Array.isArray(d.tools)) rec.tools = d.tools.map((c) => String(c).slice(0, 64)).slice(0, 128);
    else if (!rec.tools) rec.tools = [];
    // ★ 执行令牌：插件自报，后端代它保管 → invoke 时必须带上，插件侧才认。
    //   与 tokenHash 同寿：每次 join 换发新 token 时一并轮换。
    if (d.execToken !== undefined) rec.execToken = String(d.execToken || '').slice(0, 128);
    rec.account = (cred && cred.account) || rec.account || '';
    rec.lastSeen = Date.now();
    rec.tokenHash = sha(freshToken);   // 每次 join 换发新 token（旧 token 立即失效）
    rec.ip = String(req.socket && req.socket.remoteAddress || '').replace(/^::ffff:/, '');
    save();
    console.log(`[peer] join ${kind} ${rec.name || iid} @ ${rec.ip} url=${rec.url || '-'}`);
    return ok(res, {
      joined: true, iid,
      peerToken: freshToken,
      // 提醒客户端：token 只在本次响应里出现，落盘后下次 join 用它续期。
      renew: '用 peerToken 重新 join 即续期，无需再输密码',
      hub: { iid: 'local-back', name: me.name, version: require('./package.json').version },
      online: REG.peers.filter(isOnline).length,
    }, {}, ridHdr);
  }

  // ── GET/POST /agent/peer/ping —— 身份探针（**匿名可达，且必须匿名可达**）──
  // 插件在局域网里扫描时，只知道"某台机器开了 9527"，需要一句话确认"你是不是
  // ThirdHub 后端"。用 /v1/ping 不行（它在 401 闸门之后），所以这里单独开一个：
  // 只回版本与名字，**不泄露任何端列表/密钥**，因此匿名安全。
  if ((p === '/agent/peer/ping') && (req.method === 'GET' || req.method === 'POST')) {
    return ok(res, {
      object: 'peer-hub', proto: 'PH/1',
      name: (me && me.name) || 'ThirdHub 后端', iid: 'local-back',
      version: require('./package.json').version,
      caps: (me && me.caps) || [],
    }, {}, ridHdr);
  }

  // ── 以下端点需要 peerToken（或后端密钥）──
  const tok = d.peerToken || u.searchParams.get('peerToken') || req.headers['x-th-peer'] || req.headers['x-th-token'];
  const self = byToken(tok);
  const isBackendKey = SECRET && String(tok || '') === SECRET;
  if (!self && !isBackendKey) {
    return err(res, 'UNAUTHORIZED', '需要 peerToken（先 POST /agent/peer/join）', 401, ridHdr);
  }
  if (self) { self.lastSeen = Date.now(); }

  // ── POST /agent/peer/beat —— 心跳 ──
  if (p === '/agent/peer/beat' && req.method === 'POST') {
    if (!self) return ok(res, { you: null, online: REG.peers.filter(isOnline).length });
    if (d.url !== undefined) self.url = String(d.url || '').slice(0, 512);
    if (d.ipv6 !== undefined) self.ipv6 = String(d.ipv6 || '').slice(0, 512);
    if (d.tunnel !== undefined) self.tunnel = String(d.tunnel || '').slice(0, 512);
    if (Array.isArray(d.caps)) self.caps = d.caps.map((c) => String(c).slice(0, 32)).slice(0, 32);
    if (Array.isArray(d.tools)) self.tools = d.tools.map((c) => String(c).slice(0, 64)).slice(0, 128);
    if (d.state && typeof d.state === 'object') self.state = d.state;
    save();
    return ok(res, { you: view(self), online: REG.peers.filter(isOnline).length });
  }

  // ── GET /agent/peer/list —— 端列表（这就是"一方输入其他方都能用"的目录）──
  if ((p === '/agent/peer/list' || p === '/agent/peer/self') && req.method === 'GET') {
    prune();
    const kindQ = u.searchParams.get('kind') || '';
    const capQ = u.searchParams.get('cap') || '';
    let all = REG.peers.map(view).filter((x) => x.online);
    if (kindQ) all = all.filter((x) => x.kind === kindQ);
    if (capQ) all = all.filter((x) => x.caps.includes(capQ));
    if (p === '/agent/peer/self') {
      return ok(res, { you: self ? view(self) : { iid: 'local-back', kind: 'back', name: me.name, caps: me.caps, online: true } }, {}, ridHdr);
    }
    return ok(res, {
      hub: { iid: 'local-back', name: me.name, online: true, caps: me.caps },
      peers: all,
      // 局域网里被发现、但还没登录的端 —— UI 提示"待登录"，不是"离线"
      pending: REG.peers.map(view).filter((x) => x.discovered),
      // k: 给 UI 直接渲染的分组计数
      stats: {
        total: all.length,
        front: all.filter((x) => x.kind === 'front').length,
        plug: all.filter((x) => x.kind === 'plug').length,
        dsa: all.filter((x) => x.kind === 'dsa').length,
      },
      // 全部已登记的端（含离线），UI 里显示"曾经连过"
      all: REG.peers.map(view),
    }, {}, ridHdr);
  }

  // ── POST /agent/peer/relay —— 一方输入，其他方都能拉到 ──
  // to 为空 = 广播；topic 是自由标签（'input' / 'clip' / 'search' / 'cmd' …）
  if (p === '/agent/peer/relay' && req.method === 'POST') {
    const from = (self && self.iid) || 'local-back';
    const to = String(d.to || '').slice(0, 64);
    const topic = String(d.topic || 'input').slice(0, 32);
    const m = {
      id: 'pm' + (msgSeq++),
      at: Date.now(),
      from, fromName: (self && self.name) || me.name,
      to, topic,
      payload: d.payload === undefined ? null : d.payload,
    };
    MSGS.push(m);
    if (MSGS.length > MAX_MSGS) MSGS = MSGS.slice(-MAX_MSGS);
    saveMsgs();
    return ok(res, { id: m.id, at: m.at, delivered: to ? 1 : REG.peers.filter(isOnline).length }, {}, ridHdr);
  }

  // ── GET /agent/peer/pull?since=<id|ts>&topic= ──
  if (p === '/agent/peer/pull' && req.method === 'GET') {
    const since = String(u.searchParams.get('since') || '');
    const topic = u.searchParams.get('topic') || '';
    const myIid = (self && self.iid) || 'local-back';
    let out = MSGS;
    if (topic) out = out.filter((m) => m.topic === topic);
    if (since) {
      // since 既支持消息 id（'pm12'）也支持毫秒时间戳
      const n = /^pm\d+$/.test(since) ? parseInt(since.slice(2), 10) : NaN;
      out = Number.isFinite(n) ? out.filter((m) => parseInt(m.id.slice(2), 10) > n)
                               : out.filter((m) => m.at > (parseInt(since, 10) || 0));
    }
    // 广播 + 点名给我的；不回放我自己发的（除非显式 includeSelf=1）
    const inc = u.searchParams.get('includeSelf') === '1';
    out = out.filter((m) => (m.to === '' || m.to === myIid) && (inc || m.from !== myIid));
    return ok(res, { msgs: out.slice(-100), cursor: (out[out.length - 1] || {}).id || '' }, {}, ridHdr);
  }

  // ── POST /agent/peer/invoke —— 跨端调用（后端代转发）──
  // 这是"端到端控制层"：前端在后端不在线时也可直接连插件（见 list 的 direct 字段），
  // 但只要后端在，就由后端转发，省去每个前端各自维护插件地址。
  if (p === '/agent/peer/invoke' && req.method === 'POST') {
    const to = String(d.to || '').trim();
    const tool = String(d.tool || '').trim();
    if (!to || !tool) return err(res, 'BAD_REQUEST', '需 to + tool', 400, ridHdr);
    const target = REG.peers.find((x) => x.iid === to && isOnline(x));
    if (!target) return err(res, 'PEER_OFFLINE', '目标端不在线: ' + to, 200, ridHdr);
    // ★ 只在局域网里被 UDP 发现、还没登录账号的端**不允许被调用**。
    //   否则「插件只需登录账号即可连接」就成了一纸空文：任何进程广播一条
    //   HELLO 就能被派活。用户的原话也是"登录对应的账号之后就可以连接"。
    if (!isJoined(target)) {
      return err(res, 'PEER_NOT_LOGGED_IN',
        '目标端「' + (target.name || to) + '」只是被局域网发现，还没登录账号接入', 200, ridHdr);
    }
    const bases = [target.url, target.tunnel, target.ipv6].map(asUrl).filter(Boolean);
    if (!bases.length) return err(res, 'PEER_NO_URL', '目标端未上报可达地址', 200, ridHdr);
    // ★ 执行令牌：插件 join 时自己生成并交给后端，后端调用它时必须出示。
    //   没有这道门的话，局域网里任何进程直接 POST http://<插件>:8801/peer/exec
    //   就能指挥插件干活 —— 那"插件要登录账号才能被接入"就形同虚设。
    const execHdr = target.execToken ? { 'X-TH-Peer-Exec': target.execToken } : null;
    let lastErr = 'no route';
    for (const b of bases) {
      try {
        const r = await postJson(b.replace(/\/+$/, '') + '/peer/exec', {
          tool, args: d.args || {}, from: (self && self.iid) || 'local-back', topic: d.topic || '',
        }, 15000, execHdr);
        if (r && r.ok === false) {
          // ★「连上了但业务失败」要**立刻返回**，不能继续试下一个地址。
          //   否则后面的网络层错误（tunnel DNS 不存在等）会把这个信息量最大的
          //   原因覆盖掉 —— 自测第 8 节就是靠这条抓到 lastErr 被覆盖的。
          //   多地址重试只对"连不上"有意义；业务失败换地址也一样失败。
          return err(res, 'INVOKE_FAILED', (r.error && r.error.message) || 'remote error', 200, ridHdr);
        }
        return ok(res, { via: b, result: (r && r.data !== undefined) ? r.data : r }, {}, ridHdr);
      } catch (e) { lastErr = String((e && e.message) || e); }
    }
    return err(res, 'INVOKE_FAILED', lastErr, 200, ridHdr);
  }

  // ── POST /agent/peer/leave ──
  if (p === '/agent/peer/leave' && req.method === 'POST') {
    if (self) {
      REG.peers = REG.peers.filter((x) => x.iid !== self.iid);
      save();
      console.log('[peer] leave ' + self.iid);
    }
    return ok(res, { left: true }, {}, ridHdr);
  }

  // ── 密钥统一（D5）──
  // GET  → 全量（值是明文；这是可信任端之间的同步，传输层已有 TLS + peerToken）
  // POST → {set:{name:value}, del:[name], ifRev:{...}} 局部覆盖
  //        只要任一端写入，其他端 GET 就能拿到；rev 单调递增用于冲突判定。
  if (p === '/agent/peer/secrets') {
    if (req.method === 'GET') {
      return ok(res, {
        secrets: SECRETS,
        count: Object.keys(SECRETS).length,
        // 时间戳给前端做"是否需要拉取"的快速判断
        updatedAt: Object.values(SECRETS).reduce((a, s) => Math.max(a, s.updatedAt || 0), 0),
      }, {}, ridHdr);
    }
    if (req.method === 'POST') {
      const from = (self && self.iid) || 'local-back';
      const conflicted = [];
      let changed = 0;
      if (d.set && typeof d.set === 'object') {
        for (const [k, v] of Object.entries(d.set)) {
          const name = String(k).slice(0, 96);
          if (!name || v === undefined || v === null) continue;
          const cur = SECRETS[name];
          // 乐观并发：客户端带了 ifRev 且与当前不符 → 不覆盖，回报冲突
          if (d.ifRev && d.ifRev[name] !== undefined && cur && cur.rev !== d.ifRev[name]) {
            conflicted.push({ name, mine: cur.rev, expect: d.ifRev[name] });
            continue;
          }
          SECRETS[name] = { value: String(v), rev: (cur ? cur.rev : 0) + 1, updatedAt: Date.now(), from };
          changed++;
        }
      }
      if (Array.isArray(d.del)) {
        for (const k of d.del) {
          const name = String(k).slice(0, 96);
          if (SECRETS[name]) { delete SECRETS[name]; changed++; }
        }
      }
      if (changed) saveSecrets();
      return ok(res, { changed, conflicted, count: Object.keys(SECRETS).length }, {}, ridHdr);
    }
  }

  // ── 账号管理（插件/端登录用的账号）──
  if (p === '/agent/peer/accounts') {
    // 只有后端密钥或 admin 角色可读/改
    const isAdmin = isBackendKey || (self && self.account === 'admin');
    if (!isAdmin) return err(res, 'FORBIDDEN', '仅管理员可管理账号', 403, ridHdr);
    if (req.method === 'GET') {
      return ok(res, { accounts: Object.entries(REG.accounts).map(([k, v]) => ({ account: k, role: v.role || 'user' })) }, {}, ridHdr);
    }
    if (req.method === 'POST') {
      const user = String(d.account || '').trim();
      const pass = String(d.password || '');
      if (!user || pass.length < 4) return err(res, 'BAD_REQUEST', '账号非空且口令≥4位', 400, ridHdr);
      // 也接受 "sha256:<hex>" 形式（插件不落明文）
      const stored = /^sha256:[0-9a-f]{64}$/i.test(pass) ? pass.slice(7).toLowerCase() : sha(pass);
      const exists = !!REG.accounts[user];
      REG.accounts[user] = { pass: stored, role: String(d.role || (REG.accounts[user] && REG.accounts[user].role) || 'user') };
      save();
      return ok(res, { account: user, created: !exists, role: REG.accounts[user].role }, {}, ridHdr);
    }
  }

  // ── 诊断：一条命令看清"现在有几端、各自能力、可达地址"──
  if (p === '/agent/peer/diag' && req.method === 'GET') {
    const all = REG.peers.map(view);
    return ok(res, {
      protocol: 'PH/1',
      hub: { iid: 'local-back', version: require('./package.json').version, uptime: Math.floor(process.uptime()) },
      peers: all,
      msgs: MSGS.length,
      secrets: Object.keys(SECRETS).length,
      accounts: Object.keys(REG.accounts).length,
      // 常见故障的即时判定
      hints: [
        all.length <= 1 ? '只有后端自己在线 —— 端/插件还没 join（POST /agent/peer/join）' : '',
        all.some((x) => x.kind === 'plug' && !x.online && !x.discovered) ? '有插件登记但已离线（心跳超 45s）' : '',
        all.some((x) => x.discovered) ? '局域网里发现 ' + all.filter((x) => x.discovered).length +
          ' 个端还没登录账号 —— 让它在插件侧填账号口令即可接入' : '',
        all.some((x) => x.kind === 'plug' && x.online && !x.direct.length) ? '有插件在线但未上报 url/ipv6/tunnel —— 无后端时将无法直连' : '',
      ].filter(Boolean),
    }, {}, ridHdr);
  }

  return err(res, 'NOT_FOUND', p, 404, ridHdr);
}

/** 供 index.js 的 THP 广播带上 peer 能力标记（前端 discover.dart 可据此识别）。 */
function peerCaps() { return ['peers', 'relay', 'secrets', 'invoke']; }

module.exports = {
  init, handle, peerCaps, view, isOnline, isJoined, discover,
  // 测试用
  _test: {
    join(d) {
      if (!REG) init();
      let rec = byToken(d.peerToken);
      if (!rec) {
        const c = checkCred(d);
        if (!c.ok) return { ok: false, error: c.error };
        const iid = String(d.iid || rid(8));
        rec = REG.peers.find((x) => x.iid === iid);
        if (!rec) { rec = { iid, kind: d.kind || 'plug', tokenHash: '', firstSeen: Date.now() }; REG.peers.push(rec); }
        rec.account = c.account;
        rec.kind = d.kind || rec.kind;
        if (d.url !== undefined) rec.url = d.url;
        if (d.ipv6 !== undefined) rec.ipv6 = d.ipv6;
      }
      if (d.name !== undefined) rec.name = d.name;
      if (Array.isArray(d.caps)) rec.caps = d.caps;
      if (Array.isArray(d.tools)) rec.tools = d.tools;
      rec.lastSeen = Date.now();
      const t = rid(20);
      rec.tokenHash = sha(t);
      save();
      return { ok: true, peerToken: t, iid: rec.iid };
    },
    list: () => REG.peers.map(view),
    setSecrets(obj) {
      if (!REG) init();
      for (const [k, v] of Object.entries(obj)) {
        SECRETS[k] = { value: String(v), rev: (SECRETS[k] ? SECRETS[k].rev : 0) + 1, updatedAt: Date.now(), from: 'test' };
      }
      saveSecrets();
      return SECRETS;
    },
    getSecrets: () => SECRETS,
    reset() {
      REG = { version: 1, accounts: { admin: { pass: sha('123456'), role: 'admin' } }, peers: [] };
      MSGS = []; SECRETS = {}; msgSeq = 1; me = null;
      // ★ 必须同时把磁盘刷成同一份状态。否则紧接着的 init() 会从磁盘
      //   readJson 把旧数据读回来，reset 等于没做 —— 自测第 16 节
      //   「批量登记 5 个插件 got=7」「setSecrets got=4 want=2」就是这个坑。
      if (PEERS_FILE) { writeJson(PEERS_FILE, REG); writeJson(MSG_FILE, MSGS); writeJson(SEC_FILE, SECRETS); }
    },
  },
};
