// ThirdHub v4 Venera 漫画引擎: Node vm 沙箱跑 Venera 图源JS → comic-IR
const vm = require('vm'); const cheerio = require('cheerio'); const crypto = require('crypto');
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';

const cookieJar = {};

async function rawFetch(url, opts = {}) {
  const r = await fetch(url, { ...opts, signal: AbortSignal.timeout(15000),
    headers: { 'User-Agent': UA, ...(opts.headers || {}) } });
  return r;
}

function buildSandbox() {
  const box = {
    console, URL, URLSearchParams, TextEncoder, TextDecoder, JSON, Math, Date, RegExp, Error, Promise,
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    setTimeout, clearTimeout,
    cookieJar,
    __instance: null, __className: '', __result: null
  };

  // ── Html 代理层(cheerio 包 Venera Html API) ──
  function wrapEl($, el) {
    return {
      text: () => $(el).text().trim(),
      get innerText() { return $(el).text().trim(); },
      attr: (n) => $(el).attr(n),
      get attributes() { return { ...($(el).attr() || {}) }; },
      querySelector(sel) { const f = $(el).find(sel).first(); return f.length ? wrapEl($, f) : null; },
      querySelectorAll(sel) { return $(el).find(sel).toArray().map(x => wrapEl($, x)); },
      get innerHTML() { return $(el).html() || ''; },
      get outerHTML() { return $.html(el) || ''; },
      get children() { return $(el).children().toArray().map(x => wrapEl($, x)); },
      get firstChild() { const c = $(el).contents().first(); return c.length && c[0].type === 'text' ? { text: c.text() } : null; }
    };
  }
  class HtmlDocument {
    constructor(html) { this.$root = cheerio.load(String(html)); }
    querySelector(sel) { const f = this.$root(sel).first(); return f.length ? wrapEl(this.$root, f) : null; }
    querySelectorAll(sel) { return this.$root(sel).toArray().map(x => wrapEl(this.$root, x)); }
    getElementById(id) { const f = this.$root('#' + id).first(); return f.length ? wrapEl(this.$root, f) : null; }
    get body() { return wrapEl(this.$root, this.$root('body').length ? this.$root('body') : this.$root.root()); }
  }

  // ── Network ──
  const Network = {
    get: async (url, headers) => {
      const r = await rawFetch(url, { headers: { Cookie: cookieJar[url] || '', ...(headers || {}) } });
      return { status: r.status, headers: Object.fromEntries(r.headers.entries()), body: await r.text() };
    },
    send: async (method, url, headers, body) => {
      const r = await rawFetch(url, { method, body, headers: { Cookie: cookieJar[url] || '', ...(headers || {}) } });
      return { status: r.status, headers: Object.fromEntries(r.headers.entries()), body: await r.text() };
    },
    post: async (url, headers, body) => Network.send('POST', url, headers, body),
    delete: async (url, headers) => Network.send('DELETE', url, headers),
    setCookies: (url, cookies) => { cookieJar[url] = typeof cookies === 'string' ? cookies : Object.entries(cookies).map(([k, v]) => k + '=' + v).join('; '); },
    getCookies: (url) => cookieJar[url] || ''
  };

  // ── Convert ──
  // ★2026-11-14：原来这里只有 base64encode/base64decode 四个自造函数，
  //   而 Venera 书源调的是 **Convert.decodeBase64 / encodeBase64 / decodeUtf8**
  //   （Venera 官方 API，返回 ArrayBuffer）。实测 32 个漫画源里 **7 个**直接死在
  //   `Convert.decodeBase64 is not a function`（拷贝漫画等大站全在内）。
  //   这里按 venera-runtime.js 补齐，并保留旧名字做兼容。
  const abuf = (b) => b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
  const Convert = {
    // —— Venera 官方 API（ArrayBuffer 语义）——
    encodeUtf8(str) { return new Uint8Array(Buffer.from(String(str), 'utf8')).buffer; },
    decodeUtf8(buf) { return Buffer.from(buf).toString('utf8'); },
    encodeBase64(buf) {
      return Buffer.from(buf instanceof ArrayBuffer ? Buffer.from(buf) : String(buf)).toString('base64');
    },
    decodeBase64(str) {
      const b = Buffer.from(String(str), 'base64');
      return abuf(b);
    },
    async md5(buf) { return abuf(crypto.createHash('md5').update(Buffer.from(buf)).digest()); },
    async sha1(buf) { return abuf(crypto.createHash('sha1').update(Buffer.from(buf)).digest()); },
    async sha256(buf) { return abuf(crypto.createHash('sha256').update(Buffer.from(buf)).digest()); },
    async sha512(buf) { return abuf(crypto.createHash('sha512').update(Buffer.from(buf)).digest()); },
    async hmac(key, value, hash) {
      const h = String(hash).toLowerCase().replace('-', '');
      return abuf(crypto.createHmac(h, Buffer.from(key)).update(Buffer.from(value)).digest());
    },
    async hmacString(key, value, hash) {
      return Buffer.from(await this.hmac(key, value, hash)).toString('base64');
    },
    async decryptAesEcb(value, key) {
      const d = crypto.createDecipheriv('aes-128-ecb', Buffer.from(key).subarray(0, 16), null);
      return abuf(Buffer.concat([d.update(Buffer.from(value)), d.final()]));
    },
    async decryptAesCbc(value, key, iv) {
      const k = Buffer.from(key);
      const d = crypto.createDecipheriv('aes-' + (k.length * 8) + '-cbc', k, Buffer.from(iv));
      return abuf(Buffer.concat([d.update(Buffer.from(value)), d.final()]));
    },
    // —— 旧名字/十六进制版（保持既有源不回归）——
    base64encode: (s) => Buffer.from(s).toString('base64'),
    base64decode: (s) => Buffer.from(s, 'base64').toString(),
    md5Hex: (s) => crypto.createHash('md5').update(String(s)).digest('hex'),
    sha1Hex: (s) => crypto.createHash('sha1').update(String(s)).digest('hex'),
    sha256Hex: (s) => crypto.createHash('sha256').update(String(s)).digest('hex'),
    aes: { encrypt: (t, k) => t, decrypt: (t, k) => t },
  };

  const UI = { showMessage: (m) => console.log('[来源]', m) };
  const Utils = { randomInt: (a, b) => Math.floor(Math.random() * (b - a + 1)) + a,
    createUuid: () => crypto.randomUUID() };

  // ── 基类: 构造时捕获实例与类名 ──
  // ★2026-11-08：补上 Venera 基类实际提供的东西。原来只有一个空壳构造器，于是源里
  //   一调 `this.loadData("token")` 就抛异常 → 整个源搜不出东西（comic_walker 就是这种）。
  box.ComicSource = class {
    constructor() {
      box.__instance = this;
      box.__className = this.constructor.name;
      if (!this.__kv) this.__kv = {};
      if (!this.__cfg) this.__cfg = {};
    }
    loadData(k) { return this.__kv[k]; }
    saveData(k, v) { this.__kv[k] = v; return v; }
    deleteData(k) { delete this.__kv[k]; }
    // 用户级设置（有些源靠它存语言/线路/画质偏好），缺了会直接抛 loadSetting is not a function
    loadSetting(k) { return this.__cfg[k]; }
    saveSetting(k, v) { this.__cfg[k] = v; return v; }
    deleteSetting(k) { delete this.__cfg[k]; }
    get settings() { return this.__cfg; }
  };
  // Venera 的数据类：源里会 `new Comic({...})` / `new ComicDetails({...})`
  box.Comic = class { constructor(o) { Object.assign(this, o || {}); } };
  box.ComicDetails = class { constructor(o) { Object.assign(this, o || {}); } };
  box.ComicPage = class { constructor(o) { Object.assign(this, o || {}); } };
  box.randomInt = (a, b) => Math.floor(Math.random() * (Math.abs(b - a) + 1)) + Math.min(a, b);
  // Venera 的 compute(script, arg)：跑一段"返回函数"的 JS 再调用它（图片解密用）
  box.compute = (script, arg) => {
    try {
      const f = vm.runInContext('(' + String(script) + ')', box, { timeout: 5000 });
      return typeof f === 'function' ? f(arg) : null;
    } catch (e) { return arg; }
  };
  box.HtmlDocument = HtmlDocument;
  box.Network = Network;
  box.Convert = Convert;
  box.UI = UI;
  box.Utils = Utils;
  box.__promise = null;
  box.fetch = async (url, headers) => Buffer.from(await (await rawFetch(url, { headers })).arrayBuffer());
  return box;
}

// 跑图源: method=search/comicInfo/comicPages/explore
//
// ★2026-11-08 重写调用层。起因：用户反馈「搜什么都搜不到」。
//   实测这批图源是 **Venera 的类写法**，方法不是平铺的，而是分组挂着：
//     search = { load: (keyword, filter, page) => ({comics, maxPage}) }
//     comic  = { loadInfo: (id) => ComicDetails, loadEp: (comicId, epId) => {url, headers, onResponse} }
//     explore = [ {title, load: (page)=>...} ]
//   旧代码一律 `s.search(q, page)` / `s.comicInfo(id)` 去调，于是：
//     · s.search 是个对象 → "s.search.apply is not a function"
//     · 根本没有 s.comicInfo   → "无此方法"
//   结果 32 个漫画源一个都出不来。这里补上 Venera 的真实调用约定，
//   同时保留 Mangayomi 的平铺写法做兜底（两种源都能跑）。
async function runSource(sourceCode, method, args = []) {
  let code = String(sourceCode).replace(/export\s+default\s+/, '');
  const box = buildSandbox();
  vm.createContext(box);
  const M = JSON.stringify(method);
  const A = JSON.stringify(args);
  const entry = `
;(function(){
  const __src = ${JSON.stringify(String(sourceCode))};
  __promise = (async function(){
    try {
      let s = __instance;
      if (!s && __className) {
        try { const C = eval(__className); if (typeof C === 'function') s = new C(); } catch(e) {}
      }
      // 兜底一：源只写 \`export default class Xxx extends ComicSource\` 而从不 \`new\`。
      // 扫源码里继承 ComicSource 的类名，逐个试实例化，谁注册上 __instance 就用谁。
      if (!s) {
        try {
          const re = /class\\s+([A-Za-z_$][\\w$]*)\\s+extends\\s+ComicSource/g;
          let m;
          while ((m = re.exec(__src))) {
            try { const C = eval(m[1]); if (typeof C === 'function') new C(); } catch (e) {}
            if (__instance) { s = __instance; break; }
          }
        } catch (e) {}
      }
      if (!s) return { error: '来源未注册实例(需末尾new或export default class)' };

      // 有些源要先 init()（拉版本号 / 换 token），失败不致命
      if (typeof s.init === 'function') {
        try { await s.init(); } catch (e) { console.log('[init失败]', e && e.message); }
      }

      const M = ${M};
      const A = ${A};
      let out;
      if (M === 'search') {
        if (s.search && typeof s.search.load === 'function') out = await s.search.load(A[0], A[1] == null ? null : A[1], A[2] || 1);
        else if (typeof s.search === 'function') out = await s.search.apply(s, A);
        else return { error: '该源没有 search / search.load' };
      } else if (M === 'comicInfo') {
        if (s.comic && typeof s.comic.loadInfo === 'function') out = await s.comic.loadInfo(A[0]);
        else if (typeof s.comicInfo === 'function') out = await s.comicInfo.apply(s, A);
        else return { error: '该源没有 comic.loadInfo' };
      } else if (M === 'comicPages') {
        if (s.comic && typeof s.comic.loadEp === 'function') out = await s.comic.loadEp(A[0], A[1]);
        else if (typeof s.comicPages === 'function') out = await s.comicPages.apply(s, A);
        else return { error: '该源没有 comic.loadEp' };
      } else if (M === 'explore') {
        if (Array.isArray(s.explore)) {
          const parts = [];
          for (const sec of s.explore) {
            if (!sec || typeof sec.load !== 'function') continue;
            try { parts.push({ title: sec.title || '', data: await sec.load(A[0] || 1) }); }
            catch (e) { parts.push({ title: sec.title || '', error: String(e && e.message || e) }); }
          }
          out = parts;
        } else if (typeof s.explore === 'function') out = await s.explore.apply(s, A);
        else return { error: '该源没有 explore' };
      } else {
        if (typeof s[M] === 'function') out = await s[M].apply(s, A);
        else return { error: '无此方法: ' + M };
      }
      return out;
    } catch (e) {
      return { error: String(e && e.message || e) };
    }
  })();
})();`;
  try {
    vm.runInContext(code + entry, box, { timeout: 30000 });
  } catch (e) {
    return { error: '来源执行失败: ' + e.message };
  }
  try {
    return await Promise.race([
      box.__promise,
      new Promise((_, rej) => setTimeout(() => rej(new Error('源执行超时(25s)')), 25000)),
    ]);
  } catch (e) {
    return { error: '来源方法异常: ' + (e && e.message || e) };
  }
}

// ── IR 归一 ──
// 注意：源在 vm 沙箱里跑，它造的 Map 属于**另一个 realm**，
// 所以不能用 `instanceof Map` 判断，只能按鸭子类型（有 entries/get）。
const isMapLike = (v) => !!v && typeof v === 'object' && typeof v.entries === 'function' && typeof v.get === 'function';

function irComicList(r) {
  if (!r) return { items: [] };
  if (r.error) return { error: r.error };
  const list = r.comics || r.list || (Array.isArray(r) ? r : []);
  return { items: list.map(c => ({ id: c.url || c.id || '', title: c.title || c.name || '',
    coverUrl: c.cover || c.coverUrl || '', subTitle: c.subTitle || c.author || '' })),
    maxPage: r.maxPage || 1 };
}
function irComicInfo(r) {
  if (!r) return { error: '空结果' };
  if (r.error) return { error: r.error };
  // chapters 在 Venera 里是 Map<id, title>；Mangayomi 里是数组。两种都认。
  let chapters = [];
  const chs = r.chapters;
  if (isMapLike(chs)) {
    // ★2026-11-14：Venera 的 chapters 真实结构是 **两层 Map**
    //   `Map<分组名, Map<章节id, ComicChapter>>`（优酷漫画就是 `连载列表 → 各话`）。
    //   原来只拍一层 → 得到 {id:'连载列表', title:'[object Map]'}，
    //   于是"目录只有 1 条、点进去取不到图"。这里按层展开。
    const out = [];
    for (const [k, v] of chs.entries()) {
      if (isMapLike(v)) {
        for (const [cid, cv] of v.entries()) {
          out.push({
            id: String(cid),
            title: String((cv && (cv.title || cv.name)) || cv || cid),
            group: String(k),
          });
        }
      } else if (v && typeof v === 'object') {
        out.push({
          id: String(v.id || v.url || k),
          title: String(v.title || v.name || k),
          group: String(k),
        });
      } else {
        out.push({ id: String(k), title: String(v) });
      }
    }
    chapters = out;
  } else if (Array.isArray(chs)) {
    chapters = chs.map((ch, i) => ({ title: ch.title || ch.name || ('第' + (i + 1) + '话'),
      id: ch.id || ch.url || String(i), time: ch.time || '' }));
  } else if (chs && typeof chs === 'object') {
    chapters = Object.entries(chs).map(([id, title]) => ({ id: String(id), title: String(title) }));
  }
  // tags 在 Venera 里是 Map<分组, 数组>，拍平成字符串数组即可
  let tags = [];
  if (isMapLike(r.tags)) {
    for (const [, v] of r.tags.entries()) {
      if (Array.isArray(v)) tags.push(...v.map(String));
      else if (v != null) tags.push(String(v));
    }
  } else if (Array.isArray(r.tags)) {
    tags = r.tags.map(String);
  }
  return { id: r.id || r.url || '', title: r.title || r.name || '', coverUrl: r.cover || '',
    description: r.description || r.intro || '', tags,
    chapters,
    subtitle: r.subtitle || '', updateTime: r.updateTime || '' };
}
function irPages(r) {
  if (!r) return { images: [] };
  if (r.error) return { error: r.error };
  // Venera 的 comic.loadEp 返回**单张图**的描述：{url, headers, onResponse}
  // Mangayomi 的 comicPages 返回数组或 {images|urls|pages}。两种都认。
  if (typeof r === 'object' && typeof r.url === 'string' && r.url) {
    return { images: [r.url], headers: r.headers || {} };
  }
  const urls = Array.isArray(r) ? r : (r.urls || r.images || r.pages || []);
  return { images: urls.map(u => (typeof u === 'string' ? u : (u.url || ''))).filter(Boolean),
    headers: r.headers || {} };
}

module.exports = { runSource, irComicList, irComicInfo, irPages };
