// thp1.js — THP/1.0 正式规范实现层（资源库 library 角色）
// 挂载到 index.js 的 handle() 前置；未命中返回 false 交给旧路由（兼容期）。
// 规范单一事实来源: docs/THP.md
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA = path.join(__dirname, 'data');
const STORE_DIR = path.join(DATA, 'store');      // 每模块条目库
const CHANGE_DIR = path.join(DATA, 'changes');   // 每模块变更日志(JSONL)
const BLOB_DIR = path.join(DATA, 'blobs');       // blob 文件
for (const d of [STORE_DIR, CHANGE_DIR, BLOB_DIR]) fs.mkdirSync(d, { recursive: true });

// ─── instanceId（重启不变）───
const IID_FILE = path.join(DATA, 'instance-id');
let INSTANCE_ID;
if (fs.existsSync(IID_FILE)) INSTANCE_ID = fs.readFileSync(IID_FILE, 'utf8').trim();
else { INSTANCE_ID = crypto.randomUUID(); fs.writeFileSync(IID_FILE, INSTANCE_ID); }

// ─── 模块注册表（THP.md §6.1，只增不减）───
const ENGINE_MODULES = ['novel', 'comic', 'video', 'music', 'live', 'audiobook', 'podcast', 'article', 'shortplay'];
const LIBRARY_MODULES = ['album', 'file', 'note', 'todo', 'bookmark', 'feed'];
const ALL_MODULES = [...ENGINE_MODULES, ...LIBRARY_MODULES];

const CAPS = [
  ...ALL_MODULES.map(m => 'm:' + m),
  'library', 'post-query', 'jobs', 'events', 'batch-content',
];

// ─── 统一信封 ───
function sendOk(res, data, meta = {}, rid) {
  const h = { 'Content-Type': 'application/json; charset=utf-8' };
  if (rid) h['X-TH-Request-Id'] = rid;
  res.writeHead(200, h);
  res.end(JSON.stringify({ ok: true, data, meta }));
}
function sendErr(res, code, message, status = 200, rid, upstream) {
  const h = { 'Content-Type': 'application/json; charset=utf-8' };
  if (rid) h['X-TH-Request-Id'] = rid;
  res.writeHead(status, h);
  res.end(JSON.stringify({ ok: false, error: { code, message, ...(upstream ? { upstream } : {}) } }));
}

// ─── cursor 分页（不透明 = base64 offset）───
const encCursor = off => Buffer.from(String(off)).toString('base64url');
const decCursor = c => { if (!c) return 0; const n = parseInt(Buffer.from(String(c), 'base64url').toString(), 10); return Number.isFinite(n) && n >= 0 ? n : -1; };
function page(arr, limit, cursor) {
  const off = decCursor(cursor);
  if (off < 0) return { error: 'BAD_CURSOR' };
  const lim = Math.min(Math.max(parseInt(limit) || 20, 1), 100);
  const slice = arr.slice(off, off + lim);
  const next = off + lim;
  return { data: slice, meta: { cursor: next < arr.length ? encCursor(next) : '', hasMore: next < arr.length, total: arr.length } };
}

// ─── 条目存储（library 模块）+ 变更日志（tombstone）───
const storeFile = m => path.join(STORE_DIR, m + '.json');
const changeFile = m => path.join(CHANGE_DIR, m + '.jsonl');
function loadStore(m) { try { return JSON.parse(fs.readFileSync(storeFile(m), 'utf8')); } catch { return []; } }
function saveStore(m, arr) { fs.writeFileSync(storeFile(m), JSON.stringify(arr)); }
function nowISO() { return new Date().toISOString(); }
function hashItem(o) { return crypto.createHash('sha256').update(JSON.stringify(o)).digest('hex'); }
function logChange(m, entry) {
  fs.appendFileSync(changeFile(m), JSON.stringify({ ...entry, ts: nowISO() }) + '\n');
  sseEmit('sync.cursor', { module: m, cursor: nowISO() });
}
function readChanges(m, cursor, limit) {
  let lines = [];
  try { lines = fs.readFileSync(changeFile(m), 'utf8').split('\n').filter(Boolean).map(JSON.parse); } catch {}
  // cursor 不透明：base64(offset)
  const off = decCursor(cursor);
  if (off < 0) return { error: 'BAD_CURSOR' };
  const lim = Math.min(parseInt(limit) || 500, 500);
  const slice = lines.slice(off, off + lim);
  const next = off + lim;
  return { data: slice, meta: { cursor: next < lines.length ? encCursor(next) : encCursor(lines.length), hasMore: next < lines.length } };
}

// ─── SSE events（/thp/events）───
const sseClients = new Set();
function sseEmit(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of sseClients) { try { res.write(msg); } catch { sseClients.delete(res); } }
}

// ─── blob 传输（秒传/分块/Range）───
const blobMetaFile = id => path.join(BLOB_DIR, id + '.json');
const blobDataFile = id => path.join(BLOB_DIR, id + '.bin');
function blobId(sha256) { return 'b_' + String(sha256).slice(0, 32); }

// ─── jobs（最小异步任务）───
const jobs = new Map();
function newJob(type, payload) {
  const j = { jobId: 'j_' + crypto.randomBytes(8).toString('hex'), type, status: 'queued', progress: 0, result: null, payload, createdAt: nowISO() };
  jobs.set(j.jobId, j);
  return j;
}

// ─── 外部依赖注入（由 index.js 提供）───
let DEPS = {};
function init(deps) { DEPS = deps; } // { thpOnline, thpCallV1, library, saveLib, LIB_DIR, searchLocal }

class UpstreamErr extends Error {} // 上游业务错误：不回落, 直接抛给调用方

// 调引擎（§7.3 降级链：POST → 404/UNSUPPORTED 回落 GET 新版 → 再回落旧草稿）
async function engineCall(dev, module, op, params) {
  const t0 = Date.now();
  const p1 = `/thp/m/${module}/${op}`;
  const qs = new URLSearchParams(Object.fromEntries(
    Object.entries(params).map(([k, v]) => [k, String(v ?? '')]))).toString();
  for (const attempt of ['post', 'get']) {
    try {
      const r = attempt === 'post'
        ? await fetch(dev.device_url + p1, { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(params), signal: AbortSignal.timeout(8000) })
        : await fetch(dev.device_url + p1 + '?' + qs, { signal: AbortSignal.timeout(8000) });
      if (r.status === 404) continue; // 该形态不存在, 试下一形态
      const j = await r.json();
      if (j && j.ok === true) return { data: j.data, meta: { ...(j.meta || {}), latency: Date.now() - t0 } };
      if (j && j.ok === false) {
        if (j.error && (j.error.code === 'UNSUPPORTED' || j.error.code === 'NOT_FOUND')) continue;
        throw new UpstreamErr(j.error.message || j.error.code || 'upstream error'); // 业务错误不回落
      }
    } catch (e) { if (e instanceof UpstreamErr) throw e; /* 网络/解析错误: 回落下一形态 */ }
  }
  // 旧草稿端点（兼容期）
  const legacyPath = { search: '/thp/search', toc: '/thp/chapters', content: '/thp/content' }[op];
  const lqs = new URLSearchParams({ type: module, ...params }).toString();
  const r = await fetch(dev.device_url + legacyPath + '?' + lqs, { signal: AbortSignal.timeout(8000) });
  const j = await r.json();
  if (j && j.object === 'error') throw new Error(j.data?.message || 'upstream error');
  // 旧格式归一：{items:[...]} / {object:list,data} / 裸 content
  if (op === 'search') return { data: j.items || j.data || [], meta: { latency: Date.now() - t0 } };
  if (op === 'toc') return { data: (j.items || j.data || []).map((c, i) => ({ id: c.url || c.id || String(i), name: c.name || c.title, index: c.index ?? i })), meta: { latency: Date.now() - t0 } };
  return { data: j.data || j, meta: { latency: Date.now() - t0 } };
}

// ─── 主路由 ───
// 返回 true = 已处理；false = 交给旧路由
async function handle(req, res, body, u) {
  const p = u.pathname;
  const rid = req.headers['x-th-request-id'];
  if (!p.startsWith('/thp')) return false;
  const parseBody = () => { try { return JSON.parse(body || '{}'); } catch { return {}; } };

  // ── /thp/meta ──
  if (p === '/thp/meta' && req.method === 'GET') {
    sendOk(res, {
      protocol: 'THP/1.0', instanceId: INSTANCE_ID, role: 'library',
      name: 'ThirdHub 资源库', version: '1.0.0', vendor: 'thirdhub',
      caps: CAPS, auth: ['none', 'tls'], remote: false,
      endpoints: ['search', 'toc', 'content', 'extra', 'items', 'blob', 'changes', 'events', 'jobs'],
      deprecated: [], ext: {},
    }, { source: 'library' }, rid);
    return true;
  }

  // ── /thp/events（SSE）──
  if (p === '/thp/events' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive', ...(rid ? { 'X-TH-Request-Id': rid } : {}) });
    res.write(`event: hello\ndata: {"instanceId":"${INSTANCE_ID}","role":"library"}\n\n`);
    sseClients.add(res);
    req.on('close', () => sseClients.delete(res));
    return true;
  }

  // ── /thp/changes ──
  if (p === '/thp/changes' && req.method === 'GET') {
    const m = u.searchParams.get('module') || '';
    if (!ALL_MODULES.includes(m)) return sendErr(res, 'NOT_FOUND', '未知模块: ' + m, 404, rid), true;
    const r = readChanges(m, u.searchParams.get('cursor') || '', u.searchParams.get('limit'));
    if (r.error) return sendErr(res, 'BAD_REQUEST', 'cursor 非法', 400, rid), true;
    sendOk(res, r.data, { ...r.meta, source: 'library' }, rid);
    return true;
  }

  // ── /thp/blob ──
  const CHUNK_SIZE = 8 * 1024 * 1024;
  if (p === '/thp/blob' && req.method === 'POST') {
    const d = parseBody();
    if (!d.sha256 || !/^[0-9a-f]{64}$/i.test(String(d.sha256))) return sendErr(res, 'BAD_REQUEST', 'sha256 非法', 400, rid), true;
    if (!Number.isFinite(d.size) || d.size <= 0) return sendErr(res, 'BAD_REQUEST', 'size 非法', 400, rid), true;
    const id = blobId(d.sha256);
    if (fs.existsSync(blobDataFile(id)) && fs.existsSync(blobMetaFile(id))
        && JSON.parse(fs.readFileSync(blobMetaFile(id), 'utf8')).complete) {
      sendOk(res, { id, dedup: true }, { source: 'library' }, rid); // 秒传
    } else {
      fs.writeFileSync(blobMetaFile(id), JSON.stringify({ id, sha256: d.sha256.toLowerCase(), size: d.size, mime: d.mime || 'application/octet-stream', received: [], complete: false, createdAt: nowISO() }));
      fs.writeFileSync(blobDataFile(id), Buffer.alloc(0)); // 预创建, 供 r+ 随机写
      sendOk(res, { id, chunks: Math.ceil(d.size / CHUNK_SIZE), chunkSize: CHUNK_SIZE }, { source: 'library' }, rid);
    }
    return true;
  }
  let mb = p.match(/^\/thp\/blob\/([\w-]+)(?:\/chunks\/(\d+))?$/);
  if (mb) {
    const id = mb[1], chunkN = mb[2];
    if (chunkN !== undefined && req.method === 'POST') {
      if (!fs.existsSync(blobMetaFile(id))) return sendErr(res, 'NOT_FOUND', 'blob 未声明（先 POST /thp/blob）', 404, rid), true;
      const meta = JSON.parse(fs.readFileSync(blobMetaFile(id), 'utf8'));
      const idx = parseInt(chunkN);
      const total = Math.ceil(meta.size / CHUNK_SIZE);
      if (idx < 0 || idx >= total) return sendErr(res, 'BAD_REQUEST', `chunk 越界（0..${total - 1}）`, 400, rid), true;
      const bin = req.rawBody && req.rawBody.length ? req.rawBody : Buffer.from(body, 'binary');
      if (!bin.length) return sendErr(res, 'BAD_REQUEST', '空块', 400, rid), true;
      const fd = fs.openSync(blobDataFile(id), 'r+'); // 随机写: a+ 在 Linux 下忽略 offset, 会乱序损坏
      fs.writeSync(fd, bin, 0, bin.length, idx * CHUNK_SIZE);
      fs.closeSync(fd);
      if (!meta.received.includes(idx)) meta.received.push(idx);
      if (meta.received.length === total) {
        // 全部到齐 → 校验 sha256, 不符即作废
        const sum = crypto.createHash('sha256').update(fs.readFileSync(blobDataFile(id))).digest('hex');
        if (sum !== meta.sha256) {
          fs.rmSync(blobDataFile(id), { force: true }); fs.rmSync(blobMetaFile(id), { force: true });
          return sendErr(res, 'CHECKSUM_MISMATCH', 'sha256 校验失败, 已作废', 400, rid), true;
        }
        meta.complete = true; meta.completedAt = nowISO();
        sseEmit('blob.complete', { id });
      }
      fs.writeFileSync(blobMetaFile(id), JSON.stringify(meta));
      sendOk(res, { id, chunk: idx, received: meta.received.length, complete: !!meta.complete }, { source: 'library' }, rid);
      return true;
    }
    if (req.method === 'GET') {
      const f = blobDataFile(id);
      if (!fs.existsSync(f) || !fs.existsSync(blobMetaFile(id))) return sendErr(res, 'NOT_FOUND', 'blob 不存在', 404, rid), true;
      const meta = JSON.parse(fs.readFileSync(blobMetaFile(id), 'utf8'));
      if (!meta.complete) return sendErr(res, 'BLOB_INCOMPLETE', `blob 未传完（${meta.received.length}/${Math.ceil(meta.size / CHUNK_SIZE)}）`, 409, rid), true;
      const size = fs.statSync(f).size;
      const rh = { 'Accept-Ranges': 'bytes', ...(rid ? { 'X-TH-Request-Id': rid } : {}) };
      const range = req.headers.range;
      if (range) {
        const m2 = range.match(/^bytes=(\d+)-(\d*)$/);
        if (!m2) { res.writeHead(416, { ...rh, 'Content-Range': `bytes */${size}` }); res.end(); return true; }
        const start = parseInt(m2[1]);
        const end = m2[2] ? parseInt(m2[2]) : size - 1;
        if (start >= size || end < start) { res.writeHead(416, { ...rh, 'Content-Range': `bytes */${size}` }); res.end(); return true; }
        const e2 = Math.min(end, size - 1);
        res.writeHead(206, { 'Content-Type': meta.mime || 'application/octet-stream', 'Content-Range': `bytes ${start}-${e2}/${size}`, 'Content-Length': e2 - start + 1, ...rh });
        fs.createReadStream(f, { start, end: e2 }).pipe(res);
      } else {
        res.writeHead(200, { 'Content-Type': meta.mime || 'application/octet-stream', 'Content-Length': size, ...rh });
        fs.createReadStream(f).pipe(res);
      }
      return true;
    }
  }

  // ── /thp/jobs ──
  if (p === '/thp/jobs' && req.method === 'POST') {
    const d = parseBody();
    const j = newJob(d.type || 'generic', d);
    sendOk(res, { jobId: j.jobId, status: j.status }, { source: 'library' }, rid);
    return true;
  }
  const mj = p.match(/^\/thp\/jobs\/([\w-]+)$/);
  if (mj) {
    const j = jobs.get(mj[1]);
    if (!j) return sendErr(res, 'NOT_FOUND', 'job 不存在', 404, rid), true;
    if (req.method === 'DELETE') { j.status = 'canceled'; sendOk(res, { jobId: j.jobId, status: j.status }, { source: 'library' }, rid); return true; }
    sendOk(res, { jobId: j.jobId, status: j.status, progress: j.progress, result: j.result }, { source: 'library' }, rid);
    return true;
  }

  // ── /thp/m/{module}/... ──
  const mm = p.match(/^\/thp\/m\/([\w-]+)\/(search|toc|content|extra|items)(?:\/([\w\-:]+))?(:(\w+))?$/);
  if (!mm) return false; // 非模块路径，交旧路由（兼容期）
  const [, module, op, itemId, , batchOp] = mm;
  if (!ALL_MODULES.includes(module)) return sendErr(res, 'NOT_FOUND', '未知模块: ' + module, 404, rid), true;
  const isPost = req.method === 'POST';
  const params = isPost ? parseBody() : Object.fromEntries(u.searchParams);

  // items 写路径（library 专属）
  if (op === 'items') {
    if (!LIBRARY_MODULES.concat(ENGINE_MODULES).includes(module)) return sendErr(res, 'NOT_FOUND', '模块不支持条目', 404, rid), true;
    const store = loadStore(module);
    if (req.method === 'POST' && !itemId) {
      const d = parseBody();
      const id = 'i_' + crypto.randomBytes(8).toString('hex');
      const item = { ...d, id, hash: hashItem(d), ts: nowISO() };
      store.push(item); saveStore(module, store);
      logChange(module, { op: 'upsert', id, item, hash: item.hash });
      sendOk(res, item, { source: 'library' }, rid);
      return true;
    }
    const idx = store.findIndex(x => x.id === itemId);
    if (req.method === 'GET' && itemId) {
      if (idx < 0) return sendErr(res, 'NOT_FOUND', '条目不存在', 404, rid), true;
      sendOk(res, store[idx], { source: 'library' }, rid); return true;
    }
    if (req.method === 'PUT' && itemId) {
      if (idx < 0) return sendErr(res, 'NOT_FOUND', '条目不存在', 404, rid), true;
      const d = parseBody();
      store[idx] = { ...store[idx], ...d, id: itemId, hash: hashItem(d), ts: nowISO() };
      saveStore(module, store);
      logChange(module, { op: 'upsert', id: itemId, item: store[idx], hash: store[idx].hash });
      sendOk(res, store[idx], { source: 'library' }, rid); return true;
    }
    if (req.method === 'DELETE' && itemId) {
      if (idx < 0) return sendErr(res, 'NOT_FOUND', '条目不存在', 404, rid), true;
      const [removed] = store.splice(idx, 1); saveStore(module, store);
      logChange(module, { op: 'delete', id: itemId });  // tombstone
      sendOk(res, { id: itemId, deleted: true }, { source: 'library' }, rid); return true;
    }
    if (req.method === 'GET' && !itemId) {
      const r = page(store, params.limit, params.cursor || '');
      if (r.error) return sendErr(res, 'BAD_REQUEST', 'cursor 非法', 400, rid), true;
      sendOk(res, r.data, { ...r.meta, source: 'library' }, rid); return true;
    }
    return sendErr(res, 'METHOD_NOT_ALLOWED', '方法不允许', 405, rid), true;
  }

  // search：本地库 ∪ 在线引擎（并发≤8，单引擎≤8s）
  if (op === 'search') {
    const q = params.q || '';
    const engines = (DEPS.thpOnline ? DEPS.thpOnline(module) : []).slice(0, 8);
    let local = [];
    try { local = (DEPS.searchLocal ? await DEPS.searchLocal(module, q) : []) || []; } catch {}
    const perEngine = await Promise.all(engines.map(async dev => {
      try {
        const r = await engineCall(dev, module, 'search', { q, limit: params.limit || 20, cursor: '' });
        return (Array.isArray(r.data) ? r.data : []).map(b => ({ ...b, peer: dev.instanceId || dev.device_url }));
      } catch { return []; }
    }));
    const merged = [...local, ...perEngine.flat()];
    const r = page(merged, params.limit, params.cursor || '');
    if (r.error) return sendErr(res, 'BAD_REQUEST', 'cursor 非法', 400, rid), true;
    sendOk(res, r.data, { ...r.meta, source: 'library', ext: { engines: engines.length } }, rid);
    return true;
  }

  // content:batch（NDJSON 流, 每行一个信封, 1MB/行, ≤200 条/次）
  if (op === 'content' && batchOp === 'batch') {
    if (!isPost) return sendErr(res, 'METHOD_NOT_ALLOWED', 'content:batch 仅支持 POST', 405, rid), true;
    const list = Array.isArray(params.items) ? params.items.slice(0, 200) : [];
    if (!list.length) return sendErr(res, 'BAD_REQUEST', 'items 为空或缺省', 400, rid), true;
    const engines = DEPS.thpOnline ? DEPS.thpOnline(module) : [];
    const LINE_CAP = 1024 * 1024;
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson; charset=utf-8', 'Cache-Control': 'no-cache', ...(rid ? { 'X-TH-Request-Id': rid } : {}) });
    for (const it of list) {
      let line;
      try {
        const iid = String(it.id || '');
        const peerRef = it.peer || (iid.includes('@') ? iid.split('@').pop() : null);
        const dev = peerRef ? engines.find(d => (d.instanceId || d.device_url) === peerRef) : engines[0];
        if (!dev) { const e = new Error('无在线引擎'); e.code = 'UPSTREAM_FAIL'; throw e; }
        const r = await engineCall(dev, module, 'content', { id: iid, chapterId: it.chapterId || '' });
        line = JSON.stringify({ ok: true, data: { id: iid, chapterId: it.chapterId || '', content: r.data } });
      } catch (e) {
        line = JSON.stringify({ ok: false, error: { code: e.code || 'UPSTREAM_FAIL', message: String(e.message || e) }, item: { id: it.id || '', chapterId: it.chapterId || '' } });
      }
      if (line.length > LINE_CAP) line = JSON.stringify({ ok: false, error: { code: 'TOO_LARGE', message: '条目超过 1MB 行上限' }, item: { id: it.id || '', chapterId: it.chapterId || '' } });
      res.write(line + '\n');
    }
    res.end();
    return true;
  }

  // toc / content：本地条目优先，否则按 peer 转发到所属引擎
  if (op === 'toc' || op === 'content') {
    const id = params.id || '';
    const peerRef = params.peer || (id.includes('@') ? id.split('@').pop() : null);
    const engines = DEPS.thpOnline ? DEPS.thpOnline(module) : [];
    const dev = peerRef ? engines.find(d => (d.instanceId || d.device_url) === peerRef) : engines[0];
    if (!dev) return sendErr(res, 'UPSTREAM_FAIL', '无在线引擎且本地未缓存', 200, rid), true;
    try {
      const fwd = op === 'toc' ? { id, cursor: params.cursor || '' } : { id, chapterId: params.chapterId || params.chapter || '' };
      const r = await engineCall(dev, module, op, fwd);
      if (op === 'toc') {
        const pg = page(Array.isArray(r.data) ? r.data : [], params.limit, params.cursor || '');
        sendOk(res, pg.data || r.data, { ...(pg.meta || {}), source: dev.instanceId || dev.device_url }, rid);
      } else {
        sendOk(res, r.data, { source: dev.instanceId || dev.device_url, latency: r.meta?.latency }, rid);
      }
    } catch (e) {
      sendErr(res, 'UPSTREAM_FAIL', String(e.message || e), 200, rid);
    }
    return true;
  }

  // extra：歌词/字幕（可选）
  if (op === 'extra') {
    const engines = DEPS.thpOnline ? DEPS.thpOnline(module) : [];
    for (const dev of engines) {
      try {
        const qs = new URLSearchParams({ id: params.id || '', what: params.what || '', lang: params.lang || '' }).toString();
        const r = await fetch(dev.device_url + `/thp/m/${module}/extra?` + qs, { signal: AbortSignal.timeout(8000) });
        if (r.status === 404) continue;
        const j = await r.json();
        if (j && j.ok === true) { sendOk(res, j.data, { source: dev.instanceId || dev.device_url }, rid); return true; }
      } catch { /* 下一个 */ }
    }
    return sendErr(res, 'UNSUPPORTED', '无引擎提供 extra', 404, rid), true;
  }

  return false;
}

module.exports = { init, handle, INSTANCE_ID, CAPS, ALL_MODULES, sseEmit, newJob };
