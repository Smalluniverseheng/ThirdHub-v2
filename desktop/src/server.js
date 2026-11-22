'use strict';
// ThirdHub 桌面引擎 · HTTP 服务
//
// 定位（一句话）：**把「来源不确定的网页素材」变成「标准格式的本地文件」，
// 再交给手机端当成自有文件使用。**
//
// 它只跑在你自己的机器 / NAS 容器里，不上架、不对外网开放。
// 手机端（ThirdHub App）通过局域网向它下单、取货；取到的是 EPUB / CBZ / MP3 / MP4，
// 落到手机本地库后就是一份普通文件 —— 手机端不承担抓取行为，也不含抓取代码。
//
// 鉴权：所有 /v1/* 除 health 外都要 `x-th-token`。
// 交付：/h/<token> 用 HMAC 自包含令牌，默认 10 分钟过期，不需要登录态。
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const store = require('./store');
const { Signer } = require('./sign');
const { runTask } = require('./pipeline');

const VERSION = require('../package.json').version;
const PORT = parseInt(process.env.TH_PORT || '8421', 10);
const HOST = process.env.TH_BIND || '0.0.0.0';
const NAME = process.env.TH_DEVICE_NAME || 'ThirdHub 桌面引擎';

store.ensureDirs();

// ── 令牌引导 ─────────────────────────────────────────────────
function loadToken() {
  if (process.env.TH_DESKTOP_TOKEN) return process.env.TH_DESKTOP_TOKEN.trim();
  const f = path.join(store.DATA_DIR, 'token');
  try {
    const t = fs.readFileSync(f, 'utf8').trim();
    if (t) return t;
  } catch (_) {
    /* 首次启动 */
  }
  const t = crypto.randomBytes(18).toString('base64url');
  try {
    fs.writeFileSync(f, t, { mode: 0o600 });
  } catch (e) {
    log('警告：无法写令牌文件（' + e.message + '），本次使用临时令牌');
  }
  return t;
}

const TOKEN = loadToken();
const signer = Signer.fromEnvOrFile(store.DATA_DIR);

// ── 工具 ─────────────────────────────────────────────────────
function log(...a) {
  console.log(new Date().toISOString().slice(0, 19).replace('T', ' '), ...a);
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  });
  res.end(body);
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > (limit || 2 * 1024 * 1024)) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (_) {
        reject(new Error('请求体不是合法 JSON'));
      }
    });
    req.on('error', reject);
  });
}

function authed(req) {
  const got = String(req.headers['x-th-token'] || '');
  const a = Buffer.from(got);
  const b = Buffer.from(TOKEN);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function baseUrl(req) {
  // 反代场景优先用转发头；直连时退回 Host。
  const proto = String(req.headers['x-forwarded-proto'] || 'http').split(',')[0].trim();
  const host = String(req.headers['x-forwarded-host'] || req.headers.host || '127.0.0.1').split(',')[0].trim();
  return proto + '://' + host;
}

// ── 任务队列（串行） ─────────────────────────────────────────
const queue = [];
let busy = false;

function enqueue(task) {
  queue.push(task);
  pump();
}

async function pump() {
  if (busy) return;
  const task = queue.shift();
  if (!task) return;
  busy = true;
  log('任务开始', task.id, task.kind, '「' + (task.title || '') + '」');
  try {
    const meta = await runTask(task);
    if (meta) log('任务完成', task.id, '→', meta.format, meta.bytes, 'B');
    else log('任务失败', task.id, (store.tasksAll().tasks.find((t) => t.id === task.id) || {}).error);
  } catch (e) {
    log('任务异常', task.id, e.message);
  } finally {
    busy = false;
    if (queue.length) setImmediate(pump);
  }
}

// ── 服务 ─────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname.replace(/\/+$/, '') || '/';

  try {
    // ① 探活：不需要令牌（手机端配对前要先知道「这里有没有引擎」）
    if (p === '/v1/health' || p === '/health') {
      return json(res, 200, {
        ok: true,
        name: NAME,
        version: VERSION,
        audience: 'desktop',
        capabilities: ['book', 'comic', 'audio', 'video'],
        formats: ['EPUB', 'CBZ', 'ZIP(MP3)', 'MP4'],
        libCount: store.libList().length,
        queue: queue.length,
        busy,
        handoffTtlSec: signer.ttlSec,
      });
    }

    // ② 首页：给人在浏览器里看一眼的说明，不是必须的
    if (p === '/' || p === '/index.html') {
      const body = landingHtml(baseUrl(req));
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'content-length': Buffer.byteLength(body),
      });
      return res.end(body);
    }

    // ③ 交付链接：令牌自校验，不需要 x-th-token（手机扫码/点链接直接下）
    if (p.startsWith('/h/')) {
      const got = signer.verify(p.slice(3));
      if (!got) return json(res, 403, { error: '链接无效' });
      if (got.expired) return json(res, 410, { error: '链接已过期，请在 App 里重新发起接收' });
      const it = store.libGet(got.id);
      if (!it || !fs.existsSync(it.filePath)) return json(res, 404, { error: '成品不存在' });

      const stat = fs.statSync(it.filePath);
      const range = String(req.headers.range || '');
      if (range) {
        // 支持断点续传：手机端网络切换时不用从头再下一遍
        const m = /bytes=(\d*)-(\d*)/.exec(range);
        const start = m && m[1] ? parseInt(m[1], 10) : 0;
        const end = m && m[2] ? parseInt(m[2], 10) : stat.size - 1;
        if (start >= stat.size) {
          res.writeHead(416, { 'content-range': 'bytes */' + stat.size });
          return res.end();
        }
        res.writeHead(206, {
          'content-type': it.mime,
          'content-length': end - start + 1,
          'content-range': `bytes ${start}-${end}/${stat.size}`,
          'accept-ranges': 'bytes',
          'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(it.file)}`,
        });
        return fs.createReadStream(it.filePath, { start, end }).pipe(res);
      }

      res.writeHead(200, {
        'content-type': it.mime,
        'content-length': stat.size,
        'accept-ranges': 'bytes',
        'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(it.file)}`,
      });
      return fs.createReadStream(it.filePath).pipe(res);
    }

    // ④ 其余接口一律要令牌
    if (p.startsWith('/v1/') && !authed(req)) {
      return json(res, 401, { error: '需要 x-th-token', hint: '在容器的 /data/token 里查看，或在环境变量 TH_DESKTOP_TOKEN 指定' });
    }

    if (p === '/v1/lib' && req.method === 'GET') {
      const items = store.libList().map((x) => ({
        id: x.id, title: x.title, author: x.author, kind: x.kind, format: x.format,
        bytes: x.bytes, pages: x.pages, tracks: x.tracks, createdAt: x.createdAt, file: x.file,
      }));
      return json(res, 200, { items });
    }

    if (p.startsWith('/v1/lib/') && req.method === 'DELETE') {
      const id = p.slice('/v1/lib/'.length);
      return json(res, store.libRemove(id) ? 200 : 404, { ok: true });
    }

    if (p.startsWith('/v1/handoff/') && req.method === 'POST') {
      const id = p.slice('/v1/handoff/'.length);
      const it = store.libGet(id);
      if (!it) return json(res, 404, { error: '成品不存在' });
      const { token, expiresAt } = signer.issue(id);
      return json(res, 200, {
        url: baseUrl(req) + '/h/' + token,
        expiresAt,
        bytes: it.bytes,
        file: it.file,
        format: it.format,
      });
    }

    if (p === '/v1/tasks' && req.method === 'POST') {
      const body = await readBody(req);
      const kind = String(body.kind || '');
      if (!['book', 'comic', 'audio', 'video'].includes(kind)) {
        return json(res, 400, { error: 'kind 必须是 book / comic / audio / video' });
      }
      const id = store.newId('t');
      const task = {
        id, kind,
        title: String(body.title || '').slice(0, 200),
        author: String(body.author || '').slice(0, 120),
        language: String(body.language || 'zh-CN').slice(0, 16),
        cover: body.cover ? String(body.cover) : '',
        summary: String(body.summary || '').slice(0, 2000),
        referer: body.referer ? String(body.referer) : '',
        origin: String(body.origin || '').slice(0, 500),
        note: String(body.note || '').slice(0, 500),
        chapters: Array.isArray(body.chapters) ? body.chapters : [],
        pages: Array.isArray(body.pages) ? body.pages : [],
        tracks: Array.isArray(body.tracks) ? body.tracks : [],
        video: body.video ? String(body.video) : '',
      };
      const total = kind === 'book' ? task.chapters.length
        : kind === 'comic' ? task.pages.length
        : kind === 'audio' ? task.tracks.length : 1;
      store.taskAdd({ id, kind, title: task.title, state: 'queued', done: 0, total, createdAt: Date.now() });
      enqueue(task);
      return json(res, 202, { id, state: 'queued', total });
    }

    if (p === '/v1/tasks' && req.method === 'GET') {
      return json(res, 200, { tasks: store.tasksAll().tasks.slice(0, 60) });
    }

    return json(res, 404, { error: '没有这个接口：' + p });
  } catch (e) {
    log('请求出错', p, e.message);
    return json(res, 500, { error: e.message || String(e) });
  }
});

function landingHtml(base) {
  const items = store.libList().slice(0, 50);
  const rows = items.length
    ? items.map((x) =>
        `<tr><td>${escapeHtml(x.title)}</td><td>${x.format}</td><td>${(x.bytes / 1048576).toFixed(1)} MB</td><td>${new Date(x.createdAt).toLocaleString()}</td></tr>`,
      ).join('')
    : '<tr><td colspan="4" class="empty">还没有成品。在 App 里下单，或 POST /v1/tasks。</td></tr>';

  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(NAME)}</title>
<style>
:root{color-scheme:light dark}
body{font:15px/1.7 -apple-system,"Segoe UI",system-ui,"Noto Sans SC",sans-serif;max-width:820px;margin:0 auto;padding:32px 20px;color:#111}
@media(prefers-color-scheme:dark){body{background:#0e1116;color:#e6e8eb}table{color:#e6e8eb}th{color:#9aa4b2}}
h1{font-size:20px;margin:0 0 4px}
.sub{color:#6b7280;font-size:13px;margin-bottom:24px}
.card{border:1px solid #e5e7eb;border-radius:12px;padding:16px 18px;margin-bottom:16px}
@media(prefers-color-scheme:dark){.card{border-color:#232936}}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;font-weight:500;color:#6b7280;padding:6px 4px;border-bottom:1px solid #e5e7eb}
td{padding:7px 4px;border-bottom:1px solid #f1f2f4}
.empty{color:#9ca3af;text-align:center;padding:18px}
code{background:#f3f4f6;padding:1px 5px;border-radius:4px;font-size:12px}
@media(prefers-color-scheme:dark){code{background:#1b2130}}
</style></head><body>
<h1>${escapeHtml(NAME)}</h1>
<div class="sub">v${VERSION} · 桌面端形态 · 不上架、不对外网 · 只服务本机与局域网内的手机端</div>

<div class="card">
<b>它做什么</b><br>
把来源不确定的网页素材抓下来，转成标准格式（EPUB / CBZ / MP3 / MP4），
再以签名链接交给手机端当成本地文件使用。<b>手机端不含任何抓取逻辑。</b>
</div>

<div class="card">
<b>成品库</b>（${items.length} 件）
<table><thead><tr><th>标题</th><th>格式</th><th>大小</th><th>生成时间</th></tr></thead>
<tbody>${rows}</tbody></table>
</div>

<div class="card">
<b>接口</b><br>
<code>GET /v1/health</code> 探活（免令牌）<br>
<code>POST /v1/tasks</code> 下单<br>
<code>GET /v1/tasks</code> 进度<br>
<code>GET /v1/lib</code> 成品列表<br>
<code>POST /v1/handoff/:id</code> 取交付链接<br>
<code>GET /h/&lt;token&gt;</code> 下载（签名，默认 10 分钟）
</div>
</body></html>`;
}

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

server.listen(PORT, HOST, () => {
  log('──────────────────────────────────────────────');
  log(NAME + ' v' + VERSION + ' 已启动  http://' + HOST + ':' + PORT);
  log('令牌：' + TOKEN.slice(0, 6) + '…（完整值见 ' + path.join(store.DATA_DIR, 'token') + '）');
  log('成品目录：' + store.LIB_DIR);
  log('──────────────────────────────────────────────');
});

for (const s of ['SIGINT', 'SIGTERM']) {
  process.on(s, () => {
    log('收到 ' + s + '，关停');
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000);
  });
}
