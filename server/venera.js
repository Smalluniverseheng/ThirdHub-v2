// ThirdHub venera 引擎: 独立 THP 引擎 App 入口
// 匿名 · 无鉴权 · 局域网 THP/1.1 协议(docs/THP.md), 前端直连即搜即看
// 图源: venera JS 漫画源, 持久化在 data/venera-sources.json
const http = require('http');
const fs = require('fs');
const path = require('path');
const dgram = require('dgram');
const rt = require('./venera-runtime');

const PORT = parseInt(process.env.TH_PORT || '9530', 10);
const DATA = process.env.TH_DATA_DIR || path.join(__dirname, 'data');
fs.mkdirSync(DATA, { recursive: true });
rt.setDataDir(DATA);

const SRC_FILE = path.join(DATA, 'venera-sources.json');
function loadSrcMeta() { try { return JSON.parse(fs.readFileSync(SRC_FILE, 'utf8')); } catch (e) { return []; } }
function saveSrcMeta(list) { try { fs.writeFileSync(SRC_FILE, JSON.stringify(list, null, 1)); } catch (e) {} }

// 启动时恢复已保存的图源
let ready = false;
(async () => {
  const metas = loadSrcMeta();
  for (const m of metas) {
    try {
      if (m.code) rt.loadSource(m.code, m.key);
      else if (m.url) await rt.loadSourceFromUrl(m.url, m.key);
      console.log('[venera] 图源已恢复:', m.key);
    } catch (e) { console.warn('[venera] 图源恢复失败:', m.key, e.message); }
  }
  ready = true;
  console.log('[venera] 图源就绪, 共 ' + rt.listSources().length + ' 个');
})();

function persistSources() {
  // 只存元信息+代码(代码来自添加时的原文)
  const cur = loadSrcMeta();
  const live = rt.listSources();
  const out = live.map(s => {
    const old = cur.find(x => x.key === s.key) || {};
    return { key: s.key, name: s.name, url: old.url || s.url || '', code: old.code || '' };
  });
  saveSrcMeta(out);
}

// ─── THP/1.1: UDP 19527 广播发现(匿名) ───
const THP_PORT = 19527;
try {
  const bc = dgram.createSocket('udp4');
  bc.bind(() => {
    bc.setBroadcast(true);
    const hello = Buffer.from('THP/1 HELLO ' + PORT + ' engine,comic,venera');
    setInterval(() => bc.send(hello, THP_PORT, '255.255.255.255', () => {}), 5000);
    bc.send(hello, THP_PORT, '255.255.255.255', () => {});
  });
  // 同时监听其他引擎的 HELLO(共存日志用, 不响应)
} catch (e) { console.log('[thp] UDP 失败', e.message); }

function json(res, obj, code = 200) {
  const b = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*' });
  res.end(b);
}
function err(res, message, code = 400) { json(res, { object: 'error', data: { message: String(message) } }, code); }
function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); } catch (e) { resolve({}); } });
  });
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname;
  try {
    if (req.method === 'OPTIONS') return json(res, {});
    // ── 元信息 ──
    if (p === '/thp/meta' || p === '/v1/meta') {
      return json(res, { object: 'meta', data: {
        name: 'ThirdHub venera 引擎', engine: 'venera', version: '1.0.0', protocol: 'THP/1.1',
        types: ['comic'], caps: ['engine', 'comic', 'venera', 'search', 'discover', 'sources'],
        sources: rt.listSources().length, ready,
      } });
    }
    // ── 图源管理 ──
    if (p === '/thp/sources') {
      if (req.method === 'GET') return json(res, { object: 'list', data: { items: rt.listSources() } });
      if (req.method === 'POST') {
        const b = await readBody(req);
        if (!b.code && !b.url) return err(res, '需要 code 或 url');
        const src = b.code ? rt.loadSource(b.code, b.key) : await rt.loadSourceFromUrl(b.url, b.key);
        const metas = loadSrcMeta().filter(x => x.key !== src.key);
        metas.push({ key: src.key, name: src.name, url: b.url || '', code: b.code || '' });
        saveSrcMeta(metas);
        return json(res, { object: 'source', data: { key: src.key, name: src.name } });
      }
      if (req.method === 'DELETE') {
        const key = u.searchParams.get('key') || '';
        rt.unload(key);
        saveSrcMeta(loadSrcMeta().filter(x => x.key !== key));
        return json(res, { object: 'ok', data: { removed: key } });
      }
      return err(res, 'method not allowed', 405);
    }
    // ── 搜索 ──
    if (p === '/thp/search') {
      const q = u.searchParams.get('q') || '';
      const one = u.searchParams.get('source') || '';
      if (!q) return err(res, '缺少 q');
      const keys = one ? [one] : Object.keys(rt.sources);
      const items = [];
      for (const k of keys) {
        try { items.push(...await rt.search(k, q, {}, 1)); } catch (e) { console.warn('[搜索]', k, e.message); }
        if (items.length >= 60) break;
      }
      // id 带上图源键, chapters/content 时还原
      return json(res, { object: 'list', data: { items: items.map(c => ({ ...c, id: c.source + '::' + c.id })) } });
    }
    // ── 发现(探索页聚合) ──
    if (p === '/thp/discover') {
      const one = u.searchParams.get('source') || '';
      const keys = one ? [one] : Object.keys(rt.sources);
      const items = [];
      for (const k of keys) {
        try { items.push(...await rt.explore(k, 0, 1)); } catch (e) { /* 该源无探索页 */ }
        if (items.length >= 80) break;
      }
      if (!items.length) return err(res, '引擎暂不支持发现页', 404);
      return json(res, { object: 'list', data: { items: items.map(c => ({ ...c, id: c.source + '::' + c.id })) } });
    }
    // ── 目录 ──
    if (p === '/thp/chapters') {
      const raw = u.searchParams.get('id') || '';
      const i = raw.indexOf('::');
      if (i < 0) return err(res, 'id 格式: 图源键::漫画ID');
      const det = await rt.getComicDetails(raw.slice(0, i), raw.slice(i + 2));
      if (!det) return err(res, '详情为空', 404);
      return json(res, { object: 'list', data: {
        items: det.chapters,
        item: { id: raw, name: det.name, author: det.author, coverUrl: det.coverUrl, intro: det.intro, tags: det.tags },
      } });
    }
    // ── 内容(漫画图片) ──
    if (p === '/thp/content') {
      const raw = u.searchParams.get('id') || '';
      const i = raw.indexOf('::');
      if (i < 0) return err(res, 'id 格式: 图源键::漫画ID');
      const r = await rt.getImages(raw.slice(0, i), raw.slice(i + 2), u.searchParams.get('chapter') || '');
      return json(res, { object: 'content', data: { images: r.images, pages: r.images, headers: r.headers } });
    }
    // ── 健康 ──
    if (p === '/health' || p === '/') return json(res, { ok: true, name: 'thirdhub-venera', port: PORT });
    return err(res, 'not found: ' + p, 404);
  } catch (e) {
    console.error('[venera]', p, e.message);
    return err(res, e.message || '内部错误', 500);
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('venera引擎就绪 本机:' + PORT);
});
