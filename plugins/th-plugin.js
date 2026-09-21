// ═══════════════════════════════════════════════════════════════════════════
// TH 插件 SDK —— 让一个局域网里的普通 Node 进程变成"ThirdHub 能用的一个端"。
//
// ★ 零依赖：只用 Node 内置模块。插件作者不需要 npm install 任何东西。
//
// 设计对齐 DSH/Cordis 的插件规范（这是刻意的，用户要求"学 DSH 怎么做"）：
//   ① 插件体是**具名导出**的 `apply(ctx)`，不用 `export default`。
//      DSH 的 loader 会把 default 折进 body 并**静默丢弃 inject 元数据** ——
//      于是依赖声明失效、加载顺序错乱，且不报错。所以这里也强制具名。
//   ② **无模块级副作用**：setInterval / 网络监听 / 全局变量一律进 apply，
//      并通过 `ctx.effect(fn)` 注册清理函数。否则热重载会累积幽灵定时器。
//   ③ 依赖用 `inject` 声明，不在 apply 里凭运气去取。
//   ④ 三种身份分清楚：Plugin(身份) / Package(不可变代码) / Run(本次激活)。
//      所以下面每个实例只用 `iid` 作为身份，代码里不存任何"上次运行"的状态。
//
// 一次典型用法（见 plugins/example-downloader/plugin.js）：
//
//   const { THPlugin } = require('./th-plugin');
//   THPlugin.run({ name: '下载插件', account: 'admin', password: '123456', port: 8801 },
//     async (ctx) => {
//       ctx.tool('dl.add', '加入下载', SCHEMA, async (a) => ({ added: a.magnet }));
//     });
//
// 生命周期：
//   广播(让后端发现) → 扫描/直连后端 → 用账号 join(接入) → 心跳 → 收消息/被调用
// ═══════════════════════════════════════════════════════════════════════════
'use strict';
const http = require('http');
const https = require('https');
const dgram = require('dgram');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const THP_PORT = 19527;          // 与后端/引擎共用同一个发现端口
const DEFAULT_HUB_PORT = 9527;   // 家庭后端默认端口
const BEAT_MS = 15000;           // 心跳间隔（后端 45s 判离线，容 3 次丢包）
const PULL_MS = 3000;            // 拉消息间隔。★刻意比心跳快得多：
                                 //   "一方输入，其他方都能用"如果绑在 15s 心跳上，
                                 //   用户在 App 里打的字要 15 秒才到插件，体感就是坏的。
const HELLO_MS = 30000;          // 广播间隔（与后端自身 30s 一致）
const STATE_DIR = path.join(os.homedir(), '.th-plugin');

// ─────────────────────────────────────────────────────────────────────────
// 极简 HTTP 客户端（同时支持 http/https，自签证书放行）
// ─────────────────────────────────────────────────────────────────────────
function request(method, url, body, timeoutMs = 9000, extraHeaders = null) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(url); } catch (e) { return resolve({ ok: false, error: '地址非法: ' + url }); }
    const isHttps = u.protocol === 'https:';
    const lib = isHttps ? https : http;
    const data = body === undefined || body === null ? '' : JSON.stringify(body);
    const req = lib.request({
      method, hostname: u.hostname, port: u.port || (isHttps ? 443 : 80),
      path: u.pathname + (u.search || ''),
      headers: Object.assign({ 'Content-Type': 'application/json; charset=utf-8' },
        data ? { 'Content-Length': Buffer.byteLength(data) } : {},
        extraHeaders || {}),
      // 家庭后端用自签证书；插件在局域网里跑，与 App 同样的放行策略。
      rejectUnauthorized: false,
      timeout: timeoutMs,
    }, (res) => {
      let t = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { t += c; });
      res.on('end', () => {
        let j = null;
        try { j = JSON.parse(t); } catch (_) {}
        resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, code: res.statusCode, text: t, json: j });
      });
    });
    req.on('timeout', () => { req.destroy(); resolve({ ok: false, error: '超时' }); });
    req.on('error', (e) => resolve({ ok: false, error: String((e && e.message) || e) }));
    if (data) req.write(data);
    req.end();
  });
}

// ─────────────────────────────────────────────────────────────────────────
// Context —— 插件能看到与能做的事。**唯一**的对外接口。
// ─────────────────────────────────────────────────────────────────────────
class Context {
  constructor(opts) {
    this.name = opts.name || '未命名插件';
    this.iid = opts.iid || crypto.randomUUID();
    this.caps = Array.isArray(opts.caps) ? opts.caps.slice() : [];
    this.version = opts.version || '1.0.0';
    this._tools = new Map();       // name → { description, inputSchema, handler }
    this._handlers = new Map();    // event → [fn]
    this._effects = [];            // () => void
    this._secrets = {};
    this._pendingSecrets = new Set();   // 接入前写的密钥，接入后补推
    this._log = opts.quiet ? () => {} : (...a) => console.log('[' + this.name + ']', ...a);
    this._stateFile = path.join(STATE_DIR, this.iid + '.json');
    this._state = {};
    this._hub = '';
    this._token = '';
    this._startedAt = Date.now();
  }

  // ── 注册能力 ──
  /** 注册一个工具。其他端就能通过 /agent/peer/invoke 调到它。 */
  tool(name, description, inputSchema, handler, opts = {}) {
    this._tools.set(String(name), {
      description: String(description || ''),
      inputSchema: inputSchema || { type: 'object', properties: {} },
      handler,
      // 声明这个工具属于哪个能力（供"这类活谁能干"的粗粒度筛选）
      cap: opts.cap || this.caps[0] || 'tool',
    });
    if (!this.caps.includes(opts.cap || this.caps[0] || 'tool')) this.caps.push(opts.cap || this.caps[0] || 'tool');
    return this;
  }

  /** 监听事件：'msg'（收到端间消息）/ 'joined' / 'lost'（与后端断开）/ 'call'（被调用） */
  on(event, fn) {
    const k = String(event);
    if (!this._handlers.has(k)) this._handlers.set(k, []);
    this._handlers.get(k).push(fn);
    return this;
  }

  _emit(event, payload) {
    for (const fn of (this._handlers.get(event) || [])) {
      try { fn(payload); } catch (e) { this._log('handler ' + event + ' 出错:', String((e && e.message) || e)); }
    }
  }

  /**
   * 注册一个清理函数（DSH 的 `ctx.effect(fn)` 同义）。
   * fn 可以直接返回 disposer，也可以自己就是 disposer。
   * ★ 所有定时器/监听器都必须走这里 —— 这是"无模块级副作用"的落地方式。
   */
  effect(fn) {
    try {
      const d = fn();
      if (typeof d === 'function') this._effects.push(d);
    } catch (e) {
      this._log('effect 注册出错:', String((e && e.message) || e));
    }
    return this;
  }

  log(...a) { this._log(...a); }

  // ── 运行时信息 ──
  get hub() { return this._hub; }
  get token() { return this._token; }
  get online() { return !!this._token && Date.now() - (this._lastBeat || 0) < BEAT_MS * 3; }
  get tools() { return [...this._tools.keys()]; }

  /** 读一条密钥（本地缓存；启动与心跳时从后端同步）。 */
  secret(name) {
    const e = this._secrets[name];
    return e === undefined ? '' : (typeof e === 'object' ? String(e.value || '') : String(e));
  }

  /**
   * 写一条密钥 —— 会推到后端，从而统一到所有端。
   * ★ 若此刻还没接入（比如在 apply() 里就写），会**记下来等接入后补推**，
   *   而不是静默丢掉。自测抓到过：apply 阶段写密钥时 pushSecrets 尚未就绪，
   *   直接 crash；修好绑定之后又发现"写进去了但没推出去"，于是加了待推队列。
   */
  async putSecret(name, value) {
    const k = String(name);
    this._secrets[k] = { value: String(value), rev: 0, updatedAt: Date.now(), from: this.iid };
    if (!this._token || !this._hub) { this._pendingSecrets.add(k); return this; }
    await pushSecrets(this, [k]);
    return this;
  }

  /** 手动广播一条消息给所有端。 */
  async relay(payload, topic = 'input') {
    if (!this._token || !this._hub) return false;
    const r = await request('POST', this._hub + '/agent/peer/relay', {
      peerToken: this._token, topic, payload,
    });
    return r.ok;
  }

  /** 调试用：把当前状态打成一段可读文本。 */
  diagnose() {
    return [
      '插件: ' + this.name + ' (' + this.iid + ')',
      '后端: ' + (this._hub || '(未找到)'),
      '已接入: ' + (this._token ? '是' : '否'),
      '工具: ' + (this._tools.size ? [...this._tools.keys()].join(', ') : '(无)'),
      '能力: ' + (this.caps.join(', ') || '(无)'),
      '外部地址: ' + (this._publicHint || '(未通告)'),
      '运行时长: ' + Math.round((Date.now() - this._startedAt) / 1000) + 's',
    ].join('\n');
  }

  _onTool(name, fn) { this._toolHandler = this._toolHandler || {}; this._toolHandler[name] = fn; }

  async _exec(tool, args) {
    const t = this._tools.get(String(tool));
    if (!t) return { ok: false, error: { code: 'UNSUPPORTED', message: '本插件没有工具: ' + tool } };
    try {
      const data = await t.handler(args || {});
      return { ok: true, data: data === undefined ? null : data };
    } catch (e) {
      return { ok: false, error: { code: 'UPSTREAM_FAIL', message: String((e && e.message) || e) } };
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 状态持久化（iid / 上次的后端地址）
// ─────────────────────────────────────────────────────────────────────────
function loadState(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return {}; }
}
function saveState(file, obj) {
  try { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(obj, null, 2)); } catch (_) {}
}

// ─────────────────────────────────────────────────────────────────────────
// 局域网扫描：没给 hub 时自己找后端
// ─────────────────────────────────────────────────────────────────────────
function localSubnets() {
  const out = [];
  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const a of (ifs[name] || [])) {
      if (a.family === 'IPv4' && !a.internal) {
        const p = a.address.split('.');
        out.push(p.slice(0, 3).join('.'));
      }
    }
  }
  return [...new Set(out)];
}

/**
 * 探测某个主机:端口是不是 ThirdHub 后端。
 * ★ 用 `/agent/peer/ping`，**不能用 `/v1/ping`** —— 后者在 401 鉴权闸门之后，
 *   插件手上还没有密钥，扫过去只会拿到 401，于是"永远找不到后端"。
 *   `/agent/peer/ping` 是专门为此开的匿名身份探针（只回名字/版本，不含端列表）。
 */
async function probe(host, port, timeoutMs = 1200) {
  for (const scheme of ['https', 'http']) {
    const r = await request('GET', scheme + '://' + host + ':' + port + '/agent/peer/ping', undefined, timeoutMs);
    if (r.ok && r.json && r.json.ok === true && r.json.data && r.json.data.object === 'peer-hub') {
      return { url: scheme + '://' + host + ':' + port, meta: r.json.data };
    }
  }
  return null;
}

/** 找后端：先本机、再各网段的常见地址，最后逐个扫 /24（有并发上限，别把网络打满）。 */
async function findHub(extraHosts = [], port = DEFAULT_HUB_PORT) {
  const cands = ['127.0.0.1', ...extraHosts];
  for (const s of localSubnets()) {
    for (let i = 1; i <= 254; i++) cands.push(s + '.' + i);
  }
  const CONC = 32;
  for (let i = 0; i < cands.length; i += CONC) {
    const batch = cands.slice(i, i + CONC);
    const rs = await Promise.all(batch.map((h) => probe(h, port)));
    const hit = rs.find((x) => x);
    if (hit) return hit;
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────
// run() —— 插件的唯一入口
// ─────────────────────────────────────────────────────────────────────────
/**
 * @param {object} opts
 *   name      插件显示名
 *   iid       固定身份（不填则随机并持久化到 ~/.th-plugin/<iid>.json）
 *   hub       后端地址。不填则自动扫描局域网（会慢，建议显式给）
 *   account   接入账号（必填，除非已有 token / 或给了后端密钥 token）
 *   password  账号口令（明文或 sha256 十六进制皆可）
 *   token     后端密钥（等价管理员身份；无人值守常驻插件可用，替代 account/password）
 *   port      本插件监听端口（默认 0 = 系统分配，但不建议：别的端要能连到你）
 *   caps      能力标签数组，如 ['download','files']
 *   ipv6      对外可达的 IPv6 地址（形如 [2001:db8::5]:8801）—— 无后端直连用
 *   tunnel    内网穿透地址（形如 https://xxx.trycloudflare.com）—— 无后端直连用
 *   quiet     不打印日志
 * @param {(ctx: Context) => any} apply  插件体（DSH 里就是 apply(ctx)）
 * @returns {Promise<Context>}
 */
async function run(opts, apply) {
  if (typeof apply !== 'function') throw new Error('THPlugin.run 需要 apply(ctx) 函数（具名导出风格）');
  if (opts && opts.inject && !Array.isArray(opts.inject)) throw new Error('inject 必须是数组');

  const ctx = new Context(opts || {});
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const st = loadState(ctx._stateFile);
  ctx._state = st;
  // iid 一旦定下就持久化 —— 它是"身份"，不是"本次运行"
  if (!st.iid) { st.iid = ctx.iid; }
  else { ctx.iid = st.iid; ctx._stateFile = path.join(STATE_DIR, ctx.iid + '.json'); }
  saveState(ctx._stateFile, st);
  ctx._token = st.token || '';
  ctx._execToken = st.execToken || crypto.randomBytes(16).toString('hex');
  st.execToken = ctx._execToken;
  saveState(ctx._stateFile, st);
  ctx._hub = st.hub || opts.hub || '';

  // ① 先让插件体把工具/监听注册好，再对外暴露 —— 否则第一次调用会打到空工具表。
  await apply(ctx);

  // ② 起 HTTP 服务：/peer/manifest（我是谁）+ /peer/exec（干活）
  const server = http.createServer((req, res) => {
    const send = (code, obj) => {
      res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(obj));
    };
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', async () => {
      let u;
      try { u = new URL(req.url, 'http://localhost'); } catch (_) { return send(400, { ok: false, error: { code: 'BAD_REQUEST', message: 'bad url' } }); }
      if (u.pathname === '/peer/manifest' && req.method === 'GET') {
        return send(200, {
          ok: true,
          data: {
            iid: ctx.iid, kind: 'plug', name: ctx.name, version: ctx.version,
            caps: ctx.caps,
            tools: [...ctx._tools.entries()].map(([n, t]) => ({ name: n, description: t.description, inputSchema: t.inputSchema })),
          },
        });
      }
      if (u.pathname === '/peer/exec' && req.method === 'POST') {
        // ★ 执行令牌闸门：只有"后端"（即持有我 join 时交出去的 execToken 的那一方）
        //   能指挥我干活。没有这道门，局域网里任何进程一条 POST 就能使唤插件，
        //   "插件需要登录账号才能被接入"就形同虚设。
        if (ctx._execToken) {
          const got = req.headers['x-th-peer-exec'] || '';
          if (got !== ctx._execToken) {
            ctx.log('拒绝一次未持令牌的调用（来自 ' + (req.socket && req.socket.remoteAddress) + '）');
            return send(403, { ok: false, error: { code: 'UNAUTHORIZED', message: '缺少执行令牌；本插件只接受已登录接入的中枢调用' } });
          }
        }
        let j = {};
        try { j = JSON.parse(body || '{}'); } catch (_) {}
        ctx._emit('call', j);
        const r = await ctx._exec(j.tool, j.args);
        return send(200, r);
      }
      if (u.pathname === '/health' && req.method === 'GET') {
        return send(200, { ok: true, data: { name: ctx.name, uptime: Math.round((Date.now() - ctx._startedAt) / 1000), tools: ctx._tools.size } });
      }
      return send(404, { ok: false, error: { code: 'NOT_FOUND', message: u.pathname } });
    });
  });
  const listenPort = parseInt(opts.port, 10) || 0;
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(listenPort, '0.0.0.0', resolve);
  });
  const realPort = server.address().port;
  ctx.port = realPort;
  ctx._publicHint = opts.tunnel || opts.ipv6 || ('http://<本机IP>:' + realPort);

  // ③ 广播自己的存在（让后端"发现"它）。发现 ≠ 接入，只是让它被看见。
  //    DSH 的"无模块级副作用"要求：socket 与定时器都必须在 effect 里登记清理。
  ctx.effect(() => {
    const sock = dgram.createSocket('udp4');
    const hello = Buffer.from('TH-PEER/1 HELLO ' + realPort + ' ' + ctx.iid + ' ' + ctx.caps.join(',') + ' ' + ctx.name);
    const t = setInterval(() => {
      try { sock.setBroadcast(true); } catch (_) {}
      for (const tgt of ['255.255.255.255', ...localSubnets().map((s) => s + '.255')]) {
        try { sock.send(hello, THP_PORT, tgt, () => {}); } catch (_) {}
      }
    }, HELLO_MS);
    try { sock.setBroadcast(true); sock.send(hello, THP_PORT, '255.255.255.255', () => {}); } catch (_) {}
    ctx.log('广播中（UDP :' + THP_PORT + '），等待后端发现');
    return () => { clearInterval(t); try { sock.close(); } catch (_) {} };
  });

  // ④ 找到后端 → join → 心跳 → 拉消息/密钥
  const ensureHub = async () => {
    if (ctx._hub) {
      const p = await probe(new URL(ctx._hub).hostname, new URL(ctx._hub).port || DEFAULT_HUB_PORT);
      if (p) return true;
      ctx.log('上次的后端 ' + ctx._hub + ' 不在了，重新扫描');
      ctx._hub = '';
    }
    ctx.log('扫描局域网找后端…');
    const hit = await findHub(opts.hosts || []);
    if (!hit) { ctx.log('没找到后端。插件仍在广播，后端上线后会自动发现它。'); return false; }
    ctx._hub = hit.url;
    ctx._state.hub = hit.url;
    saveState(ctx._stateFile, ctx._state);
    ctx.log('找到后端: ' + hit.url);
    return true;
  };

  const doJoin = async () => {
    if (!ctx._hub && !(await ensureHub())) return false;
    const body = {
      kind: 'plug', iid: ctx.iid, name: ctx.name,
      url: 'http://' + (opts.advertiseHost || firstIPv4() || '127.0.0.1') + ':' + realPort,
      ipv6: opts.ipv6 || '', tunnel: opts.tunnel || '',
      caps: ctx.caps,
      tools: [...ctx._tools.keys()],
    };
    if (ctx._token) body.peerToken = ctx._token;
    else { body.account = opts.account || ''; body.password = opts.password || ''; }
    // 也可以直接用后端密钥接入（等价于管理员身份；适合无人值守的常驻插件）
    if (opts.token && !ctx._token) body.token = opts.token;
    // 执行令牌：本插件自己生成、自己持久化，只交给后端 ⇒ 别的进程使唤不动我。
    body.execToken = ctx._execToken;
    if (!ctx._token && !body.account && !body.token) { ctx.log('★ 缺 account：请填账号口令（或复用 ~/.th-plugin 里的 token）'); return false; }
    const r = await request('POST', ctx._hub + '/agent/peer/join', body);
    if (!r.ok || !r.json || r.json.ok !== true) {
      const e = (r.json && r.json.error && (r.json.error.code + ': ' + r.json.error.message)) || r.error || ('HTTP ' + r.code);
      ctx.log('接入失败: ' + e);
      if (ctx._token) { ctx._token = ''; ctx._state.token = ''; saveState(ctx._stateFile, ctx._state); }
      return false;
    }
    const d = r.json.data || {};
    ctx._token = d.peerToken || ctx._token;
    ctx._state.token = ctx._token;
    saveState(ctx._stateFile, ctx._state);
    ctx.log('已接入 · 当前 ' + (d.online || 0) + ' 个端在线 · 工具 ' + ctx._tools.size + ' 个');
    // 接入前攒下的密钥在这里补推（否则"apply 阶段写的密钥"永远到不了其他端）
    if (ctx._pendingSecrets.size) {
      const names = [...ctx._pendingSecrets];
      ctx._pendingSecrets.clear();
      await pushSecrets(ctx, names);
    }
    ctx._emit('joined', d);
    return true;
  };

  const doBeat = async () => {
    if (!ctx._token || !ctx._hub) return doJoin();
    const r = await request('POST', ctx._hub + '/agent/peer/beat', { peerToken: ctx._token, caps: ctx.caps, tools: [...ctx._tools.keys()] }, 7000);
    if (!r.ok) {
      ctx.log('心跳失败（后端可能离线），转入重连');
      ctx._emit('lost', r.error);
      ctx._hub = '';
      return false;
    }
    ctx._lastBeat = Date.now();
    return true;
  };

  const doSync = async () => {
    if (!ctx._token || !ctx._hub) return;
    // 拉密钥（统一到所有端的落点）
    try {
      const r = await request('GET', ctx._hub + '/agent/peer/secrets?peerToken=' + ctx._token, undefined, 7000);
      if (r.ok && r.json && r.json.ok) ctx._secrets = Object.assign({}, r.json.data.secrets || {}, ctx._secrets);
    } catch (_) {}
    await doPullMsgs();
  };

  /** 只拉消息（比心跳快，见 PULL_MS 的说明）。 */
  const doPullMsgs = async () => {
    if (!ctx._token || !ctx._hub) return;
    try {
      const r = await request('GET', ctx._hub + '/agent/peer/pull?peerToken=' + ctx._token + '&since=' + (ctx._cursor || ''), undefined, 7000);
      if (r.ok && r.json && r.json.ok) {
        for (const m of (r.json.data.msgs || [])) {
          ctx._cursor = m.id;
          if (m.from !== ctx.iid) ctx._emit('msg', m);
        }
      }
    } catch (_) {}
  };

  const _pushSecrets = async (names) => { await pushSecrets(ctx, names); };
  ctx._pushSecrets = _pushSecrets;

  await doJoin();
  // 宿主/自测用的手动触发口：不必等定时器就能立即接入/心跳/同步
  ctx.syncNow = () => doSync();
  ctx.joinNow = () => doJoin();
  ctx.beatNow = () => doBeat();
  ctx.pullNow = () => doPullMsgs();
  // 心跳/密钥同步：15s 一次
  ctx.effect(() => {
    const t = setInterval(() => {
      if (!ctx.online) doJoin().catch(() => {});
      doBeat().catch(() => {});
      doSync().catch(() => {});
    }, BEAT_MS);
    doSync().catch(() => {});
    return () => clearInterval(t);
  });
  // 消息拉取：3s 一次（单独一个 effect，单独关停）
  ctx.effect(() => {
    const t = setInterval(() => { doPullMsgs().catch(() => {}); }, PULL_MS);
    return () => clearInterval(t);
  });

  // ⑤ 优雅下线：告诉后端别再把我列为在线，并把所有 effect 逆序清理干净。
  //    暴露成 ctx.dispose()：宿主（或自测）能主动关停，而不是只能 kill 进程。
  ctx.dispose = async () => {
    if (ctx._disposed) return true;
    ctx._disposed = true;
    if (ctx._token && ctx._hub) {
      try { await request('POST', ctx._hub + '/agent/peer/leave', { peerToken: ctx._token }); } catch (_) {}
    }
    // 逆序清理：后建的先拆（先停心跳再关 socket，符合依赖方向）
    for (const d of ctx._effects.slice().reverse()) { try { d(); } catch (_) {} }
    try { server.close(); } catch (_) {}
    ctx.log('已下线');
    return true;
  };
  ctx.effect(() => () => { try { server.close(); } catch (_) {} });

  ctx.log('就绪 · 端口 ' + realPort + ' · 工具 ' + ([...ctx._tools.keys()].join(', ') || '(无)'));
  return ctx;
}

async function pushSecrets(ctx, names) {
  if (!ctx._token || !ctx._hub) return;
  const set = {};
  for (const n of names) {
    const e = ctx._secrets[n];
    if (e !== undefined) set[n] = typeof e === 'object' ? e.value : e;
  }
  if (!Object.keys(set).length) return;
  await request('POST', ctx._hub + '/agent/peer/secrets', { peerToken: ctx._token, set });
}

function firstIPv4() {
  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const a of (ifs[name] || [])) {
      if (a.family === 'IPv4' && !a.internal) return a.address;
    }
  }
  return '';
}

module.exports = { THPlugin: { run, Context }, request, findHub, probe, localSubnets, THP_PORT, DEFAULT_HUB_PORT };
