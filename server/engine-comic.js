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
  const Convert = {
    md5: (s) => crypto.createHash('md5').update(s).digest('hex'),
    sha1: (s) => crypto.createHash('sha1').update(s).digest('hex'),
    sha256: (s) => crypto.createHash('sha256').update(s).digest('hex'),
    base64encode: (s) => Buffer.from(s).toString('base64'),
    base64decode: (s) => Buffer.from(s, 'base64').toString(),
    aes: { encrypt: (t, k) => t, decrypt: (t, k) => t } // 占位: 需CryptoJS的源可后接
  };

  const UI = { showMessage: (m) => console.log('[图源]', m) };
  const Utils = { randomInt: (a, b) => Math.floor(Math.random() * (b - a + 1)) + a,
    createUuid: () => crypto.randomUUID() };

  // ── 基类: 构造时捕获实例与类名 ──
  box.ComicSource = class {
    constructor() { box.__instance = this; box.__className = this.constructor.name; }
  };
  box.HtmlDocument = HtmlDocument;
  box.Network = Network;
  box.Convert = Convert;
  box.UI = UI;
  box.Utils = Utils;
  box.fetch = async (url, headers) => Buffer.from(await (await rawFetch(url, { headers })).arrayBuffer());
  return box;
}

// 跑图源: method=search/comicInfo/comicPages/explore
async function runSource(sourceCode, method, args = []) {
  let code = String(sourceCode).replace(/export\s+default\s+/, '');
  const box = buildSandbox();
  vm.createContext(box);
  const entry = `
;(function(){
  try {
    let s = __instance;
    if (!s && __className) {
      try { const C = eval(__className); if (typeof C === 'function') s = new C(); } catch(e) {}
    }
    if (!s) { __result = { error: '图源未注册实例(需末尾new或export default class)' }; return; }
    __result = s[${JSON.stringify(method)}] ? s[${JSON.stringify(method)}].apply(s, ${JSON.stringify(args)}) : { error: '无此方法: ' + ${JSON.stringify(method)} };
  } catch (e) { __result = { error: String(e && e.message || e) }; }
})();`;
  try {
    vm.runInContext(code + entry, box, { timeout: 30000 });
  } catch (e) {
    return { error: '图源执行失败: ' + e.message };
  }
  try { return await Promise.resolve(box.__result); }
  catch (e) { return { error: '图源方法异常: ' + e.message }; }
}

// ── IR 归一 ──
function irComicList(r) {
  if (!r) return { items: [] };
  if (r.error) return { error: r.error };
  const list = r.comics || r.list || [];
  return { items: list.map(c => ({ id: c.url || c.id || '', title: c.title || c.name || '',
    coverUrl: c.cover || c.coverUrl || '', subTitle: c.subTitle || c.author || '' })),
    maxPage: r.maxPage || 1 };
}
function irComicInfo(r) {
  if (!r) return { error: '空结果' };
  if (r.error) return { error: r.error };
  return { id: r.id || r.url || '', title: r.title || r.name || '', coverUrl: r.cover || '',
    description: r.description || r.intro || '', tags: r.tags || [],
    chapters: (r.chapters || []).map((ch, i) => ({ title: ch.title || ch.name || ('第' + (i + 1) + '话'), id: ch.id || ch.url || String(i), time: ch.time || '' })) };
}
function irPages(r) {
  if (!r) return { images: [] };
  if (r.error) return { error: r.error };
  const urls = Array.isArray(r) ? r : (r.urls || r.images || r.pages || []);
  return { images: urls.map(u => (typeof u === 'string' ? u : (u.url || ''))).filter(Boolean),
    headers: r.headers || {} };
}

module.exports = { runSource, irComicList, irComicInfo, irPages };
