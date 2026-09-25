// ─────────────────────────────────────────────────────────────────────────────
// drpy-host.js — drpy 引擎**宿主侧**能力的 Node 实现
//
// 为什么必须有这个文件（这是"影视模块永远搜不到东西"的第二层根因）：
//   `drpy2.min.js` 里写着
//       const defaultParser = { pdfh: pdfh, pdfa: pdfa, pd: pd };
//   而 `pdfh` / `pdfa` / `pd` **在整份文件里从来没有被定义过**（只有
//   `var _pdfh; var _pdfa; var _pd;` 三个空声明）——
//   因为在原版 drpy 里，它们是**宿主 App 提供的原生 DOM 解析函数**
//   （海阔/hiker 那类容器的 JNI 能力）。同理 `print` / `log` 也是宿主注入的。
//
//   所以在 Node 里直接跑 drpy2 会在**加载那一行**就抛 `pdfh is not defined` ——
//   引擎根本起不来。这与前一个 import 剥离 bug 是两层独立的故障，
//   修掉任意一层都还是"影视搜不出东西"，只有两层都修通才真的能跑。
//
//   本文件就是把这三个函数按 drpy 的解析语法在 Node 里实现出来（基于 cheerio），
//   等价于"我们自己做那个宿主"。
//
// 解析语法（drpy / hiker 的 `pdfh` 家族，`&&` 是它的核心记号）：
//     pdfh(html, 'sel')                 → 首个匹配的 innerText
//     pdfh(html, 'sel&&Text')           → 同上（显式）
//     pdfh(html, 'sel&&Html')           → 首个匹配的 innerHTML
//     pdfh(html, 'sel&&OuterHtml')      → 首个匹配的 outerHTML
//     pdfh(html, 'sel&&href')           → 首个匹配的 href 属性
//     pdfa(html, 'sel')                 → **每个匹配元素的 outerHTML 数组**
//                                         （drpy 源码里的用法就是
//                                          `list = pdfa(html,'div.item');
//                                           list.forEach(it => pdfh(it,'h3&&Text'))`，
//                                          即返回的是"片段串"，好让下一步继续用 pdfh 解析）
//     pdfa(html, 'sel&&Text')           → 每个匹配的 innerText 数组
//     多个候选用 `;` 分隔：**依次尝试，取第一个非空结果**（源站改版时用得上）
//     多级 `&&`：前 n-1 段当选择器链（以空格拼成后代选择器），最后一段当属性名
//
// ★ 诚实声明：这是**行为近似**，不是原版原生函数的逐字节复刻。
//   原版有若干未文档化的边角行为（例如 `style` 里的 `url()` 取值、某些
//   非法选择器的容错），这里覆盖的是各源脚本里实际出现的用法。凡是近似之处，
//   都在下面标注出来，方便日后遇到"某个源解析结果不对"时快速定位。
'use strict';

let cheerio = null;
try { cheerio = require('cheerio'); } catch (_) { cheerio = null; }

/** 载入一段 HTML（含残缺标签容错）。cheerio 的 htmlparser2 对残缺 HTML 足够宽容。 */
function load(html) {
  if (!cheerio) throw new Error('cheerio 未安装（npm install）');
  return cheerio.load(String(html == null ? '' : html), null, false /* 不要自动补 html/body */);
}

/** 取一个元素的属性值 / 文本 / HTML。`attr` 缺省按 Text 处理（drpy 同此）。 */
function extract($, el, attr) {
  const a = String(attr || 'Text').trim();
  const $el = $(el);
  const low = a.toLowerCase();
  if (low === 'text' || low === 'innertext') return $el.text().trim();
  if (low === 'html' || low === 'innerhtml') return $el.html() || '';
  if (low === 'outerhtml') return cheerio ? (($el.toString && $el.toString()) || '') : '';
  if (low === 'ownhtml') return $el.html() || '';
  // 其余一律当属性名（href / src / data-original / style / title …）
  const v = $el.attr(a);
  if (v != null) return v;
  // 属性名大小写在 HTML 里不敏感，兜底再试一次小写
  const v2 = $el.attr(a.toLowerCase());
  if (v2 != null) return v2;
  return '';
}

/** 把 `a&&b&&Text` 这类串拆成 {sel, attr}。 */
function splitSeg(seg) {
  const parts = String(seg).split('&&').map(s => s.trim()).filter(s => s !== '');
  if (!parts.length) return { sel: '', attr: 'Text' };
  if (parts.length === 1) return { sel: parts[0], attr: 'Text' };
  const attr = parts[parts.length - 1];
  // 前面的段当选择器链：`div.list ul li` —— 用空格拼成后代选择器
  const sel = parts.slice(0, -1).join(' ');
  return { sel, attr };
}

/** 依次尝试 `;` 分隔的候选，返回第一个"有结果"的那次调用的值。 */
function firstHit(parse, fn) {
  const segs = String(parse == null ? '' : parse).split(';');
  for (const seg of segs) {
    const s = seg.trim();
    if (!s) continue;
    let v;
    try { v = fn(s); } catch (_) { continue; }
    const empty = v == null || v === '' || (Array.isArray(v) && v.length === 0);
    if (!empty) return v;
  }
  return null;
}

/**
 * `pdfh(html, parse)` → 单个字符串。对应 drpy2 里的 `defaultParser.pdfh`。
 * 注意：drpy2 的 `pdfh2()` 会拿它的返回值再做 `style/url()` 后处理，所以这里返回**原始值**。
 */
function pdfh(html, parse) {
  const $ = load(html);
  const r = firstHit(parse, (seg) => {
    const { sel, attr } = splitSeg(seg);
    if (!sel) return null;
    const els = $(sel);
    if (!els.length) return null;
    // 逐个元素试，取第一个非空 —— 列表首项常常是"广告/占位"空节点
    for (let i = 0; i < els.length; i++) {
      const v = extract($, els[i], attr);
      if (v !== '' && v != null) return String(v);
    }
    return null;
  });
  return r == null ? '' : String(r);
}

/**
 * `pdfa(html, parse)` → 数组。对应 drpy2 里的 `defaultParser.pdfa`。
 * 无 `&&attr` 时返回每个匹配元素的 **outerHTML**（drpy 源脚本惯用法，见文件头说明）；
 * 有 `&&attr` 时返回属性/文本数组。
 */
function pdfa(html, parse) {
  const $ = load(html);
  const r = firstHit(parse, (seg) => {
    const { sel, attr } = splitSeg(seg);
    if (!sel) return null;
    const els = $(sel);
    if (!els.length) return null;
    const hasAttr = /&&/.test(seg);
    if (!hasAttr) {
      // outerHTML 数组：下一步还能继续喂给 pdfh/pdfa
      return els.toArray().map(el => $.html(el) || '');
    }
    const out = els.toArray().map(el => extract($, el, attr)).filter(v => v !== '' && v != null);
    return out;
  });
  return Array.isArray(r) ? r : [];
}

/**
 * `pd(html, parse, uri)` → 取"地址"并把相对路径补全成绝对 URL。
 * drpy2 的 `pd2()` 自己会做 `urljoin(MY_URL, ret)`，所以 `defaultParser.pd`
 * 在正常调用链里其实用不到；这里给一个语义正确的实现，防止有源直接调它。
 */
function pd(html, parse, uri) {
  const raw = pdfh(html, parse);
  if (!raw) return '';
  if (/^(https?:|ftp:|magnet:|thunder:|ws:)/i.test(raw)) return raw;
  const base = uri || '';
  if (!base) return raw;
  try { return new URL(raw, base).href; } catch (_) { return raw; }
}

/**
 * `joinUrl(fromPath, nowPath)` → 绝对 URL。drpy2 里的 `urljoin()` 直接调它：
 *     function urljoin(fromPath, nowPath){ ... return joinUrl(fromPath, nowPath) }
 * 原版是宿主提供的，不在引擎文件里 → 不注入就报 `joinUrl is not defined`
 * （`init()` 里 `rule.homeUrl=urljoin(rule.host, rule.homeUrl)` 一路都会踩到，
 *  所以这同样属于"每个源都在 init 阶段就死"的一层）。
 *
 * 语义要点（按 drpy 实际行为）：
 *   · nowPath 是绝对地址（含 scheme 或 `//host`）→ 原样返回
 *   · nowPath 为空 → 返回 fromPath
 *   · fromPath 为空 → 返回 nowPath
 *   · nowPath 以 `/` 开头 → 换掉 fromPath 的 path，保留 origin
 *   · 其余 → 相对 fromPath 的目录解析
 */
function joinUrl(fromPath, nowPath) {
  const from = fromPath == null ? '' : String(fromPath);
  const to = nowPath == null ? '' : String(nowPath);
  if (!to) return from;
  if (/^\/\//.test(to)) {                          // 协议相对，继承 from 的 scheme
    const m = from.match(/^([a-z][a-z0-9+.-]*:)/i);
    return m ? m[1] + to : to;
  }
  if (/^[a-z][a-z0-9+.-]*:/i.test(to)) return to;  // 已是绝对地址
  if (!from) return to;
  try { return new URL(to, from).href; } catch (_) { /* 落到手拼 */ }
  const base = from.replace(/[?#].*$/, '');
  const schemeEnd = base.indexOf('://') >= 0 ? base.indexOf('://') + 3 : 0;
  const slash = base.indexOf('/', schemeEnd);
  const root = slash >= 0 ? base.slice(0, slash) : base;
  if (to.startsWith('/')) return root + to;
  const dir = base.slice(0, base.lastIndexOf('/') + 1) || root + '/';
  return dir + to;
}

/**
 * `jinja2(tpl, ctx)` —— drpy 把它挂在 **cheerio 对象上**用（`cheerio.jinja2(...)`），
 * 同样是宿主能力。引擎里两处关键调用：
 *   · `rule.homeUrl = cheerio.jinja2(rule.homeUrl, {rule: rule})`
 *   · `new_url = cheerio.jinja2(url, {fl: fl})`   ← 分类筛选参数填模板
 * 模板形如 `{{fl.area}}` / `{{rule.host}}/vodshow/{{fl.area}}`，
 * 也带 jinja 常见过滤器（`|default('')` / `|urlencode` / `|trim` 等）。
 *
 * 实现取"表达式求值 + 常用过滤器"这一层：足够覆盖源站模板，
 * 且不需要引入完整 jinja 实现（完整实现反而更难排查）。
 */
function jinja2(tpl, ctx) {
  if (typeof tpl !== 'string' || tpl.indexOf('{{') < 0) return tpl;
  const vars = (ctx && typeof ctx === 'object') ? ctx : {};
  return tpl.replace(/\{\{([\s\S]*?)\}\}/g, (_m, raw) => {
    const v = evalJinja(raw, vars);
    return v == null ? '' : String(v);
  });
}

function evalJinja(raw, vars) {
  let expr = String(raw).trim();
  // 拆过滤器链：`a.b | default('x') | trim`（只看「顶层」的 `|`，别切进括号里）
  const pipes = [];
  let depth = 0, cut = -1;
  for (let i = 0; i < expr.length; i++) {
    const c = expr[i];
    if (c === '(') depth++;
    else if (c === ')') depth--;
    else if (c === '|' && depth === 0 && expr[i - 1] !== '|' && expr[i + 1] !== '|') { cut = i; break; }
  }
  if (cut >= 0) {
    const rest = expr.slice(cut + 1);
    expr = expr.slice(0, cut).trim();
    const re = /([a-zA-Z_][a-zA-Z0-9_]*)\s*(?:\(([^)]*)\))?/g;
    let m;
    while ((m = re.exec(rest))) pipes.push({ name: m[1], arg: m[2] });
  }
  // jinja 的 `or`/`and`/`not`/`none` 映射到 JS 等价物
  const jsExpr = expr
    .replace(/\bNone\b/g, 'null')
    .replace(/\bnone\b/g, 'null')
    .replace(/\bor\b/g, '||').replace(/\band\b/g, '&&')
    .replace(/^\s*not\s+/, '!');
  let v;
  try {
    const names = Object.keys(vars).filter(k => /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(k));
    const fn = new Function(...names, 'return (' + jsExpr + ');');
    v = fn(...names.map(k => vars[k]));
  } catch (_) { v = undefined; }
  for (const p of pipes) v = applyFilter(p.name, p.arg, v);
  return v;
}

function applyFilter(name, argRaw, v) {
  const arg = argRaw == null ? null : argRaw.trim().replace(/^['"]|['"]$/g, '');
  switch (name) {
    case 'default': case 'd': return (v == null || v === '') ? (arg == null ? '' : arg) : v;
    case 'trim': return v == null ? '' : String(v).trim();
    case 'lower': return v == null ? '' : String(v).toLowerCase();
    case 'upper': return v == null ? '' : String(v).toUpperCase();
    case 'string': return v == null ? '' : String(v);
    case 'int': return parseInt(v, 10) || 0;
    case 'urlencode': return v == null ? '' : encodeURIComponent(String(v));
    case 'length': return v == null ? 0 : (Array.isArray(v) ? v.length : String(v).length);
    case 'replace': {
      const parts = String(argRaw || '').split(',')
        .map(s => s.trim().replace(/^['"]|['"]$/g, ''));
      return v == null ? '' : String(v).split(parts[0] == null ? '' : parts[0]).join(parts[1] == null ? '' : parts[1]);
    }
    default: return v;   // 未知过滤器：原样透传，别把值吃掉
  }
}

/**
 * `req(url, obj)` —— drpy 引擎的**同步** HTTP 入口。
 *
 * 引擎原文：`function request(url,obj){ ...; let res = req(url,obj); let html = res.content || ""; ... }`
 * 期望返回 `{ content: <响应体字符串>, headers: {...} }`。
 * 原版是宿主 App 的 JNI 阻塞调用，这里由 `drpy-http-sync.js`（Worker + Atomics）顶替。
 * 不注入的话报 `req is not defined` —— 每个需要联网的源都会在"取页面"这一步失败。
 *
 * 注意：调用方（drpy 引擎）**不会传 timeout**，所以这里必须自己有默认超时，
 * 否则一个不响应的站点会把整个子进程吊死。
 */
function makeReq(o = {}) {
  const { syncFetch } = require('./drpy-http-sync.js');
  const defaultTimeout = Number(o.httpTimeoutMs) || 12000;
  return function req(url, obj) {
    const opt = obj || {};
    let headers = opt.headers || {};
    // drpy 里 header 值可能是数组；Node fetch 需要字符串
    const h = {};
    for (const k of Object.keys(headers)) {
      const v = headers[k];
      h[k] = Array.isArray(v) ? v.join(', ') : String(v == null ? '' : v);
    }
    let body = opt.body;
    if (body != null && typeof body !== 'string' && !Buffer.isBuffer(body) && !(body instanceof URLSearchParams)) {
      body = body instanceof Object ? JSON.stringify(body) : String(body);
    }
    const method = String(opt.method || 'GET').toUpperCase();
    // ★ GET/HEAD **不能带 body**：drpy 引擎的 `request()` 会一路把 `obj` 透传下来，
    //   而 obj 里常常带着一个空字符串 `body:''`。undici 对此是硬报错
    //   `Request with GET/HEAD method cannot have body.` ——
    //   即**所有走 GET 的源都会在这里全军覆没**（这是实测抓到的真 bug）。
    if (method === 'GET' || method === 'HEAD') body = undefined;
    if (body !== undefined && !h['Content-Type'] && !h['content-type']) {
      h['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    const r = syncFetch(url, {
      method,
      headers: h,
      body,
      timeoutMs: Number(opt.timeout) || defaultTimeout,
    });
    if (r.error) {
      // 原版 req 失败时是抛异常（源的 try/catch 依赖它）。返回空 content 会让源
      // 把"取页面失败"当成"页面没有内容"，很难排查 —— 所以这里按原版行为抛。
      throw new Error('req 失败: ' + r.error);
    }
    return { content: r.body, headers: r.headers, status: r.status };
  };
}

/**
 * `local` —— drpy 的本地键值存储（原版是宿主的持久化 KV）。
 * 引擎用法：`local.set(RKEY, k, v)` / `local.get(RKEY, k)` / `local.delete(RKEY, k)`
 * （`RKEY` 是规则名，也就是"命名空间"）。
 * 不注入会报 `local is not defined`，而且**引擎会把搜索结果吞掉只返回 `{}`**
 * （`searchParse` 里 catch 住就 return "{}"）→ 表现为"源跑通了但 0 条"，
 * 极难和"源站改了"区分开。这就是本文件要把它实现出来的原因。
 *
 * 落在 `data/drpy-local.json`：cookie / 验证码缓存这类东西本来就该跨进程留存，
 * 否则每次搜一次就丢一次登录态。
 */
function makeLocal(o = {}) {
  const fsx = require('fs');
  const pathx = require('path');
  const file = o.localStorePath || pathx.join(__dirname, 'data', 'drpy-local.json');
  let store = {};
  try { store = JSON.parse(fsx.readFileSync(file, 'utf8')) || {}; } catch (_) { store = {}; }
  let dirty = false;
  const flush = () => {
    if (!dirty) return;
    try { fsx.mkdirSync(pathx.dirname(file), { recursive: true }); fsx.writeFileSync(file, JSON.stringify(store)); dirty = false; } catch (_) { }
  };
  const nsOf = (ns) => {
    const k = ns == null ? '_' : String(ns);
    if (!store[k] || typeof store[k] !== 'object') store[k] = {};
    return store[k];
  };
  const api = {
    get: (ns, k, dflt) => {
      const v = nsOf(ns)[k == null ? '' : String(k)];
      return v === undefined ? (dflt === undefined ? '' : dflt) : v;
    },
    set: (ns, k, v) => { nsOf(ns)[k == null ? '' : String(k)] = v; dirty = true; flush(); return true; },
    delete: (ns, k) => { delete nsOf(ns)[k == null ? '' : String(k)]; dirty = true; flush(); return true; },
    keys: (ns) => Object.keys(nsOf(ns)),
    clear: (ns) => { store[ns == null ? '_' : String(ns)] = {}; dirty = true; flush(); return true; },
    // 少数源直接用 localStorage 风格
    getItem: (k) => api.get('_', k),
    setItem: (k, v) => api.set('_', k, v),
    removeItem: (k) => api.delete('_', k),
    _flush: flush,
  };
  return api;
}


/**
 * `gbkTool()` —— drpy 的 GBK 编解码工具工厂。
 *
 * 引擎用法（注意是**先调用再取方法**）：
 *     const strTool = gbkTool(); input = strTool.encode(input);   // 搜索词 → GBK 百分号编码
 *     const strTool = gbkTool(); input = strTool.decode(input);   // GBK 字节 → 文本
 * 它来自被剥掉的那条 `import{gbkTool}from"./gbk.js"`。不注入就报
 * `gbkTool is not a function` —— 而凡是 `编码:'gbk'` 的老站源（有声小说吧、
 * 海洋听书、广播迷FM 这类）都会当场挂掉，实测 60 条里有 3 条直接卡这里。
 *
 * 实现直接用仓库里已 vendor 的 `gbk2.js`（cnwhy/GBK.js v0.3.0，MIT）。
 * 关键点：**在一个独立 vm 上下文里加载它**，而不是往主沙箱里塞 `module`/`exports` ——
 * 主沙箱多出这两个符号，会让一部分源脚本误判自己跑在 CommonJS 环境里而走错分支。
 */
let gbkModule = null;
function getGbkModule() {
  if (gbkModule) return gbkModule;
  const gbkPath = require('path').join(__dirname, 'vendor', 'drpy', 'gbk2.js');
  const src = require('fs').readFileSync(gbkPath, 'utf8');
  const vm = require('vm');
  const shim = { module: { exports: {} }, exports: {}, console };
  shim.globalThis = shim;
  vm.createContext(shim);
  vm.runInContext(src, shim, { timeout: 5000 });
  const ex = (shim.module.exports && Object.keys(shim.module.exports).length)
    ? shim.module.exports : shim.GBK;
  if (!ex || typeof ex.decode !== 'function') throw new Error('gbk2.js 未导出 decode()');
  gbkModule = ex;
  return ex;
}


/**
 * 构造注入沙箱的宿主能力对象。
 * @param {{log?:Function, httpTimeoutMs?:number, localStorePath?:string}} [o]
 *   log            把沙箱里的 print/log 转出来（默认丢进 console）
 *   httpTimeoutMs  源脚本发起 HTTP 的默认超时
 *   localStorePath `local` 的落盘位置（默认 server/data/drpy-local.json）
 */
function hostGlobals(o = {}) {
  const sink = o.log || ((...a) => console.log('[drpy]', ...a));
  // GBK 模块可能加载失败（缺 vendor 文件）；那种情况下不要连累其它能力，
  // 只是让 gbk 源在用到时报出清晰原因。
  let gbkFactory = null;
  try {
    const g = getGbkModule();
    gbkFactory = () => ({
      // ★ 必须返回**百分号编码串**，不能直接给 GBK 的字节数组。
      //   引擎里 `wd = strTool.encode(wd)` 的结果紧接着被
      //   `searchObj.searchUrl.replaceAll("**", wd)` 拼进 URL ——
      //   若返回数组 `[182,183,194,222]`，JS 会把它字符串化成 "182,183,194,222"，
      //   请求发出去看起来"成功"但永远搜不到东西（另一类静默失败）。
      encode: (s) => (g.URI && g.URI.encodeURI ? g.URI.encodeURI(String(s)) : g.encode(String(s))),
      // `decode` 容错：GBK.js 原生只吃字节数组，但源站响应经我们解成字符串后
      // 每个字符就是一个字节（latin1 语义），所以两种都收。
      decode: (v) => {
        if (typeof v === 'string') return g.decode(Array.from(Buffer.from(v, 'binary')));
        if (Buffer.isBuffer(v) || v instanceof Uint8Array) return g.decode(Array.from(v));
        return g.decode(v);
      },
      URI: g.URI, encodeBytes: g.encode, decodeBytes: g.decode,
    });
  } catch (e) {
    gbkFactory = () => { throw new Error('GBK 模块不可用: ' + String(e.message || e)); };
  }
  return {
    pdfh, pdfa, pd, joinUrl, jinja2,
    req: makeReq(o),
    local: makeLocal(o),
    gbkTool: gbkFactory,
    // drpy2 里 `var print; var log;` 是**无初始化的声明**，不会覆盖这里的注入值
    print: (...a) => sink(...a),
    log: (...a) => sink(...a),
  };
}

module.exports = {
  pdfh, pdfa, pd, joinUrl, jinja2, hostGlobals, load, extract, splitSeg,
  makeReq, makeLocal, getGbkModule, _cheerio: () => cheerio,
};
