// ThirdHub venera 运行时: Node vm 沙箱执行 venera 漫画图源 JS
// 图源格式兼容 https://github.com/venera-app/venera (GPL-3.0) 的 JS 图源 API
// 本文件为自研实现(基于同名 Web 移植版重写), 通过 THP 网络协议与前端解耦
const vm = require('vm');
const cheerio = require('cheerio');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';
const cookieJar = {}; // host -> cookie string

let DATA_DIR = path.join(__dirname, 'data');
function setDataDir(d) { DATA_DIR = d; fs.mkdirSync(d, { recursive: true }); }
function storeFile() { return path.join(DATA_DIR, 'venera-store.json'); }
function loadStore() { try { return JSON.parse(fs.readFileSync(storeFile(), 'utf8')); } catch (e) { return {}; } }
function saveStore(s) { try { fs.writeFileSync(storeFile(), JSON.stringify(s)); } catch (e) {} }

async function rawFetch(url, opts = {}) {
  const host = (() => { try { return new URL(url).host; } catch (e) { return ''; } })();
  const headers = { 'User-Agent': UA, ...(opts.headers || {}) };
  if (cookieJar[host] && !headers.Cookie && !headers.cookie) headers.Cookie = cookieJar[host];
  const r = await fetch(url, { redirect: 'follow', ...opts, headers, signal: AbortSignal.timeout(20000) });
  // 收集 Set-Cookie
  try {
    const sc = r.headers.getSetCookie ? r.headers.getSetCookie() : [];
    if (sc.length && host) {
      cookieJar[host] = sc.map(c => c.split(';')[0]).join('; ');
    }
  } catch (e) {}
  return r;
}

async function doFetch(method, url, headers, body, bytes) {
  const r = await rawFetch(url, { method, headers, body: body == null ? undefined : body });
  const buf = Buffer.from(await r.arrayBuffer());
  return { status: r.status, headers: Object.fromEntries(r.headers.entries()), body: bytes ? buf : buf.toString('utf8') };
}

// ── Html 代理层(cheerio 包 Venera Html API) ──
function wrapEl($, el) {
  const w = {
    _el: el,
    querySelector(sel) { const f = $(el).find(sel).first(); return f.length ? wrapEl($, f[0]) : null; },
    querySelectorAll(sel) { return $(el).find(sel).toArray().map(x => wrapEl($, x)); },
    getElementById(id) { const f = $(el).find('#' + id).first(); return f.length ? wrapEl($, f[0]) : null; },
    get text() { return $(el).text() || ''; },
    get innerText() { return ($(el).text() || '').trim(); },
    get attributes() { return { ...(el.attribs || {}) }; },
    get children() { return $(el).children().toArray().map(x => wrapEl($, x)); },
    get nodes() {
      return ($(el).contents().toArray()).map(n => ({
        get type() { return n.type === 'text' ? 'text' : (n.type === 'tag' ? 'element' : n.type); },
        toElement() { return n.type === 'tag' ? wrapEl($, n) : null; },
        get text() { return $(n).text() || ''; }
      }));
    },
    get parent() { const p = $(el).parent(); return p.length && p[0] && p[0].type === 'tag' ? wrapEl($, p[0]) : null; },
    get innerHtml() { return $(el).html() || ''; },
    get innerHTML() { return $(el).html() || ''; },
    get classNames() { return String(el.attribs && el.attribs['class'] || '').split(/\s+/).filter(Boolean); },
    get id() { return (el.attribs && el.attribs.id) || null; },
    get localName() { return el.tagName || el.name || ''; },
    get previousSibling() { const p = $(el).prev(); return p.length && p[0].type === 'tag' ? wrapEl($, p[0]) : null; },
    get nextSibling() { const n = $(el).next(); return n.length && n[0].type === 'tag' ? wrapEl($, n[0]) : null; },
    attr(n) { return $(el).attr(n); },
  };
  return w;
}

function makeHtmlDocumentClass() {
  return class HtmlDocument {
    constructor(html) { this._$ = cheerio.load(String(html)); }
    querySelector(sel) { const f = this._$(sel).first(); return f.length ? wrapEl(this._$, f[0]) : null; }
    querySelectorAll(sel) { return this._$(sel).toArray().map(x => wrapEl(this._$, x)); }
    getElementById(id) { const f = this._$('#' + id).first(); return f.length ? wrapEl(this._$, f[0]) : null; }
    get body() { const b = this._$('body'); return wrapEl(this._$, b.length ? b[0] : this._$.root()[0]); }
    dispose() { this._$ = null; }
  };
}

const Convert = {
  encodeUtf8(str) { return new Uint8Array(Buffer.from(String(str), 'utf8')).buffer; },
  decodeUtf8(buf) { return Buffer.from(buf).toString('utf8'); },
  encodeBase64(buf) { return Buffer.from(buf instanceof ArrayBuffer ? Buffer.from(buf) : String(buf)).toString('base64'); },
  decodeBase64(str) { const b = Buffer.from(String(str), 'base64'); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); },
  async md5(buf) { return crypto.createHash('md5').update(Buffer.from(buf)).digest().buffer.slice(0, 16); },
  async sha1(buf) { return abuf(crypto.createHash('sha1').update(Buffer.from(buf)).digest()); },
  async sha256(buf) { return abuf(crypto.createHash('sha256').update(Buffer.from(buf)).digest()); },
  async sha512(buf) { return abuf(crypto.createHash('sha512').update(Buffer.from(buf)).digest()); },
  async hmac(key, value, hash) {
    const h = String(hash).toLowerCase().replace('-', '');
    return abuf(crypto.createHmac(h, Buffer.from(key)).update(Buffer.from(value)).digest());
  },
  async hmacString(key, value, hash) { return Buffer.from(await this.hmac(key, value, hash)).toString('base64'); },
  async decryptAesEcb(value, key) {
    const d = crypto.createDecipheriv('aes-128-ecb', Buffer.from(key).subarray(0, 16), null);
    return abuf(Buffer.concat([d.update(Buffer.from(value)), d.final()]));
  },
  async decryptAesCbc(value, key, iv) {
    const k = Buffer.from(key); const d = crypto.createDecipheriv('aes-' + (k.length * 8) + '-cbc', k, Buffer.from(iv));
    return abuf(Buffer.concat([d.update(Buffer.from(value)), d.final()]));
  }
};
function abuf(b) { return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }

function createUuid() { return crypto.randomUUID(); }
function randomInt(min, max) { return Math.floor(Math.random() * (max - min + 1)) + min; }
function randomDouble(min, max) { return Math.random() * (max - min) + min; }

const sources = {}; // key -> source instance

function buildSandbox() {
  const HtmlDocument = makeHtmlDocumentClass();
  const box = {
    console, URL, URLSearchParams, TextEncoder, TextDecoder, JSON, Math, Date, RegExp, Error, Promise, Array, Object, String, Number, Boolean, Map, Set, Symbol, Intl, parseInt, parseFloat, isNaN, isFinite,
    atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
    btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
    setTimeout, clearTimeout, setInterval, clearInterval, queueMicrotask,
    Buffer: undefined, require: undefined, process: undefined,
    HtmlDocument,
    HtmlElement: class {}, HtmlNode: class {},
    Convert, createUuid, randomInt, randomDouble,
    Network: {
      async fetchBytes(method, url, headers, data) { const r = await doFetch(method, url, headers, data, true); return r.body.buffer.slice(r.body.byteOffset, r.body.byteOffset + r.body.byteLength); },
      async sendRequest(method, url, headers, data) { const r = await doFetch(method, url, headers, data, false); return r.body; },
      async get(url, headers) { return (await doFetch('GET', url, headers, null, false)).body; },
      async post(url, headers, data) { return (await doFetch('POST', url, headers, data, false)).body; },
      async put(url, headers, data) { return (await doFetch('PUT', url, headers, data, false)).body; },
      async delete(url, headers) { return (await doFetch('DELETE', url, headers, null, false)).body; },
      async patch(url, headers, data) { return (await doFetch('PATCH', url, headers, data, false)).body; },
      setCookies(url, cookies) {
        let host = ''; try { host = new URL(url).host; } catch (e) {}
        if (!host) return;
        cookieJar[host] = (cookies || []).map(c => (c.name !== undefined ? c.name + '=' + c.value : String(c))).join('; ');
      },
      getCookies(url) {
        let host = ''; try { host = new URL(url).host; } catch (e) { return []; }
        return String(cookieJar[host] || '').split(';').filter(Boolean).map(p => { const i = p.indexOf('='); return { name: p.slice(0, i).trim(), value: p.slice(i + 1).trim() }; });
      },
      deleteCookies(url) { try { delete cookieJar[new URL(url).host]; } catch (e) {} }
    },
    fetch: async (url, opts) => {
      const r = await doFetch((opts && opts.method) || 'GET', url, opts && opts.headers, opts && opts.body, false);
      return { ok: r.status >= 200 && r.status < 300, status: r.status, headers: { get: k => r.headers[String(k).toLowerCase()] }, text: async () => r.body, json: async () => JSON.parse(r.body), arrayBuffer: async () => Buffer.from(r.body).buffer };
    },
    UI: {
      showMessage(m) { console.log('[图源]', m); },
      showDialog() {}, launchUrl() {}, showLoading() { return 1; }, cancelLoading() {},
      showInputDialog() { return null; }, showSelectDialog() { return null; }
    },
    Cookie: class { constructor(o) { Object.assign(this, o || {}); } },
    Comic: class { constructor(o) { Object.assign(this, { id: '', title: '', cover: '', tags: [] }, o || {}); this.subtitle = this.subtitle || this.subTitle || ''; this.subTitle = this.subtitle; } },
    ComicDetails: class { constructor(o) { Object.assign(this, { title: '', cover: '' }, o || {}); this.subtitle = this.subtitle || this.subTitle || ''; this.subTitle = this.subtitle; } },
    Comment: class { constructor(o) { Object.assign(this, {}, o || {}); } },
    ImageLoadingConfig: class { constructor(o) { Object.assign(this, { url: '', method: 'GET' }, o || {}); } },
    __export: null,
  };
  // 数据存取(图源持久化)
  const store = loadStore();
  box.ComicSource = class ComicSource {
    constructor() { this.name = ''; this.key = ''; this.version = ''; this.minAppVersion = ''; this.url = ''; }
    loadData(dataKey) { const s = loadStore(); return s['d_' + this.key + '_' + dataKey] ?? null; }
    loadSetting(key) { const s = loadStore(); return s['s_' + this.key + '_' + key] ?? null; }
    saveData(dataKey, data) { const s = loadStore(); s['d_' + this.key + '_' + dataKey] = data; saveStore(s); }
    deleteData(dataKey) { const s = loadStore(); delete s['d_' + this.key + '_' + dataKey]; saveStore(s); }
    get isLogged() { const s = loadStore(); return !!s['a_' + this.key]; }
    init() {}
  };
  box.ComicSource.sources = sources;
  box.sendMessage = function (msg) {
    const s = loadStore();
    if (msg.method === 'load_data') return s['d_' + msg.key + '_' + msg.data_key] ?? null;
    if (msg.method === 'save_data') { s['d_' + msg.key + '_' + msg.data_key] = msg.data; saveStore(s); return null; }
    if (msg.method === 'delete_data') { delete s['d_' + msg.key + '_' + msg.data_key]; saveStore(s); return null; }
    if (msg.method === 'load_setting') return s['s_' + msg.key + '_' + msg.setting_key] ?? null;
    if (msg.method === 'isLogged') return !!s['a_' + msg.key];
    return null;
  };
  return box;
}

// 加载图源 JS 代码, 返回实例
function loadSource(jsCode, keyHint) {
  let code = String(jsCode).replace(/export\s+default\s+/g, '');
  const box = buildSandbox();
  vm.createContext(box);
  const m = code.match(/class\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource/);
  const tail = m ? '\n;__export = (typeof ' + m[1] + ' !== "undefined") ? ' + m[1] + ' : null;' : '';
  vm.runInContext(code + tail, box, { timeout: 15000 });
  let source = null;
  if (box.__export) { try { source = new box.__export(); } catch (e) { console.warn('图源实例化失败:', e.message); } }
  if (!source && box.ComicSource.sources) {
    const keys = Object.keys(box.ComicSource.sources);
    if (keys.length) source = box.ComicSource.sources[keys[keys.length - 1]];
  }
  if (!source) throw new Error('未找到继承 ComicSource 的类');
  if (!source.key) source.key = keyHint || source.name || 'src_' + Date.now();
  if (!source.name) source.name = source.key;
  sources[source.key] = source;
  if (typeof source.init === 'function') { try { source.init(); } catch (e) { console.warn('图源init失败:', e.message); } }
  return source;
}

async function loadSourceFromUrl(url, keyHint) {
  const r = await rawFetch(url);
  if (r.status >= 400) throw new Error('下载图源失败: HTTP ' + r.status);
  return loadSource(await r.text(), keyHint);
}

function unload(key) { delete sources[key]; }
function listSources() {
  return Object.values(sources).map(s => ({
    key: s.key, name: s.name, version: s.version || '', url: s.url || '',
    canSearch: !!(s.search && s.search.load), canExplore: !!(s.explore && s.explore.length),
  }));
}

async function search(sourceKey, keyword, options, page) {
  const src = sources[sourceKey];
  if (!src || !src.search || !src.search.load) throw new Error('图源不支持搜索');
  const res = await src.search.load(keyword, options || {}, page || 1);
  let list = [];
  if (Array.isArray(res)) list = res;
  else if (res && Array.isArray(res.comics)) list = res.comics;
  else if (res && typeof res === 'object') Object.keys(res).forEach(k => { if (Array.isArray(res[k])) list = list.concat(res[k]); });
  return list.map(c => ({
    id: c.id || '', name: c.title || '', author: c.subtitle || c.subTitle || '',
    coverUrl: c.cover || '', tags: c.tags || [], intro: c.description || '',
    source: sourceKey,
  })).filter(c => c.id && c.name);
}

async function explore(sourceKey, explorePage, page) {
  const src = sources[sourceKey];
  if (!src || !src.explore) throw new Error('图源不支持探索');
  const pageData = src.explore[explorePage || 0];
  if (!pageData || !pageData.load) throw new Error('探索页不存在');
  const res = await pageData.load(page || 1);
  let list = [];
  if (Array.isArray(res)) list = res;
  else if (res && Array.isArray(res.comics)) list = res.comics;
  else if (res && typeof res === 'object') Object.keys(res).forEach(k => { if (Array.isArray(res[k])) list = list.concat(res[k]); });
  return list.map(c => ({
    id: c.id || '', name: c.title || '', author: c.subtitle || c.subTitle || '',
    coverUrl: c.cover || '', tags: c.tags || [], intro: c.description || '',
    source: sourceKey,
  })).filter(c => c.id && c.name);
}

async function getComicDetails(sourceKey, comicId) {
  const src = sources[sourceKey];
  if (!src || !src.comic || !src.comic.loadInfo) throw new Error('图源不支持详情');
  const det = await src.comic.loadInfo(comicId);
  if (!det) return null;
  let chapters = [];
  if (det.chapters) {
    if (det.chapters instanceof Map) det.chapters.forEach((title, id) => chapters.push({ id: String(id), name: String(title), url: String(id) }));
    else if (Array.isArray(det.chapters)) det.chapters.forEach((ch, i) => chapters.push({ id: String(ch.id ?? ch.url ?? i), name: String(ch.title ?? ch.name ?? ('第' + (i + 1) + '话')), url: String(ch.url ?? ch.id ?? i) }));
    else if (typeof det.chapters === 'object') Object.entries(det.chapters).forEach(([id, title]) => chapters.push({ id: String(id), name: String(title), url: String(id) }));
  }
  return {
    id: comicId, name: det.title || '', author: det.subtitle || det.subTitle || '',
    coverUrl: det.cover || '', intro: det.description || '', tags: det.tags || [],
    chapters, source: sourceKey,
  };
}

async function getImages(sourceKey, comicId, epId) {
  const src = sources[sourceKey];
  if (!src || !src.comic || !src.comic.loadPages) throw new Error('图源不支持加载图片');
  const res = await src.comic.loadPages(comicId, epId);
  const urls = Array.isArray(res) ? res : (res.images || []);
  return {
    images: urls.map(u => (typeof u === 'string' ? u : (u && u.url) || '')).filter(Boolean),
    headers: (res && res.headers) || {},
  };
}

module.exports = { setDataDir, loadSource, loadSourceFromUrl, unload, listSources, search, explore, getComicDetails, getImages, sources };
