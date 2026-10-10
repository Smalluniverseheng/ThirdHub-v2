'use strict';
/**
 * proxy-config.js —— 出站代理集中配置（阶段5「后端网关 + 立体互连」三件套之一）
 *
 * 解决什么问题：
 *   以前每个出站请求（引擎抓内容、AI 对话、下载）各自裸连，用户想走自己的代理
 *   （Clash / 自建 Squid / 公司网关）只能全局改系统环境变量，且后端重启后行为
 *   不明、各模块口径不一。这里是**一处配置、处处生效**的收口：
 *
 *     · 配置落 data/proxy.json（用户自己的代理地址，不出本机）
 *     · ssrf-guard.safeFetch 的所有出站 fetch 都从这里拿 dispatcher
 *     · 可按模块（ai / content / storage …）指定 直连 / 自有代理 / 自动
 *     · 管理端点 /v1/proxy 读写（读脱敏、写要鉴权）
 *
 * 安全边界：
 *   · 代理地址允许内网（用户自己的代理常在 192.168.x.x / 127.0.0.1），
 *     但**被代理的目标 URL 仍走 ssrf-guard 的逐跳准入**，不因走代理而放松。
 *   · 读接口对密码打码（只留 scheme://user:***@host:port），明文只存在 data/ 目录。
 *
 * 降级策略（"配置了但用不了"绝不静默）：
 *   · undici 不可用（极老 Node）→ 只存配置，fetch 走直连，fetchOutbound 报告 used:false
 *   · 代理地址非法 → resolve 抛错给调用方显式提示，不悄悄直连
 */

const fs = require('fs');
const path = require('path');

let DATA = path.join(__dirname, 'data');
let CFG_FILE = '';
let CFG = null;

// 模块路由键（与网页端 proxy-settings.js 的 PROXY_MODULES 对齐；
// 后端只认这几种用途，前端新增模块时这里要同步）
const MODULE_KEYS = ['ai_chat', 'ai_image', 'ai_video', 'ai_asr', 'content', 'storage'];
// 通道模式：direct=直连（默认） / custom=自有代理 / auto=失败自动降级直连
const MODES = ['direct', 'custom', 'auto'];

const DEFAULT_CFG = () => ({
  version: 1,
  enabled: false,          // 总开关：false 时一切直连（就算配了代理地址）
  mode: 'auto',            // 全局缺省通道
  http: '',                // http://user:pass@host:port
  https: '',               // 同上（通常与 http 同一个代理）
  socks5: '',              // socks5://host:port（经 undici 时按 http 代理语义不支持则降级）
  noProxy: ['127.0.0.1', 'localhost', '::1'],   // 这些目标不走代理（后端自己、本机引擎）
  modules: {},             // { ai_chat: 'direct' | 'custom' | 'auto' } 覆盖全局 mode
  updatedAt: 0,
});

function readJson(f, dflt) {
  try { const j = JSON.parse(fs.readFileSync(f, 'utf8')); return j && typeof j === 'object' ? j : dflt; } catch (_) { return dflt; }
}
function writeJson(f, v) {
  try { fs.writeFileSync(f, JSON.stringify(v, null, 2), 'utf8'); return true; } catch (_) { return false; }
}

function init(opts = {}) {
  if (opts.DATA) DATA = opts.DATA;
  CFG_FILE = path.join(DATA, 'proxy.json');
  try { fs.mkdirSync(DATA, { recursive: true }); } catch (_) {}
  CFG = Object.assign(DEFAULT_CFG(), readJson(CFG_FILE, {}));
  if (!Array.isArray(CFG.noProxy)) CFG.noProxy = DEFAULT_CFG().noProxy;
  if (!CFG.modules || typeof CFG.modules !== 'object') CFG.modules = {};
  return CFG;
}

function cfg() { if (!CFG) init(); return CFG; }
function save() { return writeJson(CFG_FILE, cfg()); }

/** 校验并规范化一条代理 URL。返回 {ok, url} 或 {ok:false, error}。 */
function normProxyUrl(raw, kinds) {
  const s = String(raw || '').trim();
  if (!s) return { ok: true, url: '' };
  let u;
  try { u = new URL(s); } catch (_) { return { ok: false, error: '代理地址不是合法 URL: ' + s }; }
  const scheme = String(u.protocol || '').replace(':', '');
  if (!kinds.includes(scheme)) {
    return { ok: false, error: '代理协议须为 ' + kinds.join('/') + '，收到: ' + scheme };
  }
  if (!u.hostname) return { ok: false, error: '代理地址缺 host' };
  return { ok: true, url: s };
}

/** 配置写入（合并式）。返回 {ok, cfg} 或 {ok:false, error}。 */
function update(patch = {}) {
  const c = cfg();
  const next = {};
  if (patch.enabled !== undefined) c.enabled = !!patch.enabled;
  if (patch.mode !== undefined) {
    if (!MODES.includes(String(patch.mode))) return { ok: false, error: 'mode 需为 ' + MODES.join('/') };
    c.mode = String(patch.mode);
  }
  for (const [k, kinds] of [['http', ['http', 'https']], ['https', ['http', 'https']], ['socks5', ['socks5']]]) {
    if (patch[k] !== undefined) {
      const r = normProxyUrl(patch[k], kinds);
      if (!r.ok) return r;
      c[k] = r.url;
    }
  }
  if (Array.isArray(patch.noProxy)) {
    c.noProxy = patch.noProxy.map((x) => String(x).trim()).filter(Boolean).slice(0, 64);
  }
  if (patch.modules && typeof patch.modules === 'object') {
    for (const [mk, mv] of Object.entries(patch.modules)) {
      if (!MODULE_KEYS.includes(mk)) return { ok: false, error: '未知模块键: ' + mk };
      if (!MODES.includes(String(mv))) return { ok: false, error: '模块 ' + mk + ' 的 mode 需为 ' + MODES.join('/') };
      c.modules[mk] = String(mv);
    }
  }
  c.updatedAt = Date.now();
  save();
  return { ok: true, cfg: c };
}

/** 读接口用：密码打码，明文永不出网。 */
function masked() {
  const c = cfg();
  const mask = (s) => {
    if (!s) return '';
    try {
      const u = new URL(s);
      if (u.password) u.password = '***';
      else if (u.username) u.username = u.username + ':***';
      return u.toString().replace(/:\*\*\*@/, ':***@').replace(/:\*\*\*$/, '');
    } catch (_) { return '(非法地址)'; }
  };
  return {
    enabled: c.enabled, mode: c.mode,
    http: mask(c.http), https: mask(c.https), socks5: mask(c.socks5),
    hasPassword: /:[^/@]+@/.test(c.http) || /:[^/@]+@/.test(c.https),
    noProxy: c.noProxy.slice(),
    modules: Object.assign({}, c.modules),
    moduleKeys: MODULE_KEYS.slice(),
    modes: MODES.slice(),
    updatedAt: c.updatedAt || 0,
  };
}

/** 该 host 是否命中 noProxy（后端自己 / 本机引擎永远直连）。 */
function isNoProxy(hostname) {
  const h = String(hostname || '').replace(/^\[|\]$/g, '').toLowerCase();
  if (!h) return true;
  for (const rule of cfg().noProxy) {
    const r = String(rule).toLowerCase().trim();
    if (!r) continue;
    if (r === h) return true;
    if (r.startsWith('.') && h.endsWith(r)) return true;
    if (r.startsWith('*') && h.endsWith(r.slice(1))) return true;
  }
  return false;
}

/**
 * 解析某个模块对某个目标 URL 该走什么通道。
 * @returns {{mode:string, proxyUrl:string, reason:string}}
 *   mode: 'direct' | 'custom' | 'auto'；proxyUrl 为空即直连。
 */
function resolve(targetUrl, moduleKey) {
  const c = cfg();
  const mode = MODES.includes(c.modules[moduleKey]) ? c.modules[moduleKey] : c.mode;
  // ★ mode 回的是**实际走的通道**（不是配置里的策略名）：没走代理就回 'direct'。
  //   否则诊断里会出现「mode=auto, used=false」这种自相矛盾的组合，误导排查。
  if (!c.enabled || mode === 'direct') return { mode: 'direct', proxyUrl: '', reason: c.enabled ? 'direct' : 'disabled' };
  let host = '';
  try { host = new URL(targetUrl).hostname; } catch (_) { return { mode: 'direct', proxyUrl: '', reason: 'bad_target' }; }
  if (isNoProxy(host)) return { mode: 'direct', proxyUrl: '', reason: 'no_proxy_rule' };
  const proxyUrl = c.https || c.http || c.socks5;
  if (!proxyUrl) return { mode: 'direct', proxyUrl: '', reason: 'no_proxy_configured' };
  // socks5 走 undici 的 http CONNECT 语义不对——诚实降级：只在没有 http 代理时
  // 才用 socks5（并由 fetchOutbound 标注 degraded），否则用 http 代理。
  if (proxyUrl.startsWith('socks5:') && (c.http || c.https)) return { mode, proxyUrl: c.http || c.https, reason: 'prefer_http_proxy' };
  return { mode, proxyUrl, reason: 'ok' };
}

// ─── undici 可选依赖：把「隐式传递依赖」显式化 ───
// server/node_modules 里本来就有 undici（cheerio 的传递依赖），但**传递依赖不能
// 当直接依赖用**（hoist 一变就消失）——所以 package.json 里显式声明，
// 这里再做运行时 try/catch：解析不到就退化直连并如实报告 used:false。
let _undici = null;
function undici() {
  if (_undici !== undefined && _undici !== null) return _undici;
  try { _undici = require('undici'); } catch (_) { _undici = false; }
  return _undici;
}

const _agents = new Map();   // proxyUrl → ProxyAgent（复用连接池）
function agentFor(proxyUrl) {
  const u = undici();
  if (!u || !proxyUrl) return null;
  if (_agents.has(proxyUrl)) return _agents.get(proxyUrl);
  let ag = null;
  try { ag = new u.ProxyAgent(proxyUrl); } catch (_) { ag = null; }
  if (ag) _agents.set(proxyUrl, ag);
  return ag;
}

/**
 * 出站 fetch 收口 —— safeFetch 与任何直接出站请求都从这里走。
 *
 * @returns {Promise<Response>} 与全局 fetch 同形；
 *   附加信息经 `lastInfo` 暴露（{ used, mode, proxyUrl, degraded }），
 *   供 /v1/proxy/diag 展示"这次到底走没走代理"——不靠猜。
 */
let lastInfo = { used: false, mode: 'direct', proxyUrl: '', degraded: false, undici: false };
async function fetchOutbound(targetUrl, init = {}, moduleKey = 'content') {
  const r = resolve(targetUrl, moduleKey);
  const u = undici();
  const ag = r.proxyUrl ? agentFor(r.proxyUrl) : null;
  lastInfo = {
    used: !!ag, mode: r.mode, proxyUrl: ag ? r.proxyUrl : '',
    degraded: !!r.proxyUrl && !ag, undici: !!u, reason: r.reason,
  };
  if (ag && u && typeof u.fetch === 'function') {
    return u.fetch(targetUrl, Object.assign({}, init, { dispatcher: ag }));
  }
  // 降级路径：无 undici / 无代理 → 全局 fetch 直连
  return fetch(targetUrl, init);
}

function getLastInfo() { return Object.assign({}, lastInfo); }

/** 诊断：一条命令看清代理配置与运行时能力。 */
function diag() {
  const u = undici();
  return {
    config: masked(),
    runtime: { undici: !!u, agents: _agents.size },
    last: getLastInfo(),
    hints: [
      !cfg().enabled ? '代理总开关未启用 —— 所有出站请求走直连' : '',
      cfg().enabled && !cfg().http && !cfg().https && !cfg().socks5 ? '已启用但未填代理地址 —— 实际仍直连' : '',
      cfg().enabled && !u ? '当前 Node 环境缺 undici —— 代理不可用（已降级直连）' : '',
    ].filter(Boolean),
  };
}

module.exports = {
  init, update, masked, resolve, isNoProxy, fetchOutbound, getLastInfo, diag,
  MODULE_KEYS, MODES,
  _test: {
    reset() {
      CFG = DEFAULT_CFG();
      _agents.clear();
      if (CFG_FILE) writeJson(CFG_FILE, CFG);
      lastInfo = { used: false, mode: 'direct', proxyUrl: '', degraded: false, undici: false };
    },
    cfg,
    set(obj) { Object.assign(cfg(), obj); save(); return cfg(); },
  },
};
