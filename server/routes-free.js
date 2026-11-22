// 端上声明式源包（FreeSourceBundle）的下发接口。
//
// ── 它和已有的 /v1/sources、/v1/src/* 有什么不同 ─────────────────
// 那两套服务的是**后端引擎**：legado 风格的源（bookSourceUrl + 选择器/脚本），
// 只能在 NAS 上跑，App 拿不到也跑不了。
//
// 这里发放的是 App **端上直接执行**的声明式源（schema 见 docs/FREE-SOURCE-SPEC.md）：
//   · 纯数据（URL 模板 + 取值路径），没有脚本，App 侧不需要 eval；
//   · 一份 JSON 就是一个源包，App 「我的源 → 从后端同步」整包拉走；
//   · 不随 APK 发布 —— 这份文件只存在于 NAS 上，谁登录谁知道。
//
// ── 文件位置 ────────────────────────────────────────────────────
// `DATA/free-sources.json`（默认 /data/free-sources.json，容器内挂卷）。
// 不存在时返回空包而不是 404：App 侧「同步 0 个源」是正常状态，
// 不该让用户看到一条红色错误。
//
// ── 写接口为什么留着 ────────────────────────────────────────────
// 维护源包不该只有「上 NAS 改文件」一条路。PUT 让管理员能从 App 或网页端
// 直接覆盖，省一次 SSH。鉴权走 index.js 的 authGate（x-th-token），
// 这里只额外挡两件事：体积上限、schema 必须对。
'use strict';

const fs = require('fs');
const path = require('path');

// 单个源包大小上限。合法的包按 50 个源算约 60~80KB，
// 给到 2MB 足够宽松，同时挡掉「把整个书库塞进来」这种误用。
const MAX_BYTES = 2 * 1024 * 1024;
const SCHEMA_MAX = 1;

function fileOf(ctx) {
  const data = (ctx && ctx.DATA) || path.join(__dirname, 'data');
  return path.join(data, 'free-sources.json');
}

function emptyBundle() {
  return { schema: 1, name: '空源包', sources: [] };
}

function readBundle(ctx) {
  const f = fileOf(ctx);
  try {
    const raw = fs.readFileSync(f, 'utf8');
    const d = JSON.parse(raw);
    if (!d || typeof d !== 'object' || !Array.isArray(d.sources)) {
      return { bundle: emptyBundle(), broken: '文件结构不对（缺 sources 数组）' };
    }
    return { bundle: d, broken: '' };
  } catch (e) {
    if (e.code === 'ENOENT') return { bundle: emptyBundle(), broken: '' };
    return { bundle: emptyBundle(), broken: '文件解析失败：' + e.message };
  }
}

/// 只做「能不能跑」的粗校验，语义校验在 App 侧（FreeSourceSpec.validate）。
/// 后端不做深度校验的理由：校验规则会随 App 版本演进，
/// 把老规则钉在服务端会让「新 App + 旧后端」出现莫名其妙的拒绝。
function shapeErrors(d) {
  const errs = [];
  if (!d || typeof d !== 'object') return ['顶层必须是对象'];
  if (d.schema != null && (typeof d.schema !== 'number' || d.schema > SCHEMA_MAX)) {
    errs.push('schema 必须 ≤ ' + SCHEMA_MAX);
  }
  if (!Array.isArray(d.sources)) {
    errs.push('sources 必须是数组');
    return errs;
  }
  if (d.sources.length > 300) errs.push('单包源数量不能超过 300');
  const ids = new Set();
  d.sources.forEach((s, i) => {
    if (!s || typeof s !== 'object') { errs.push('第 ' + (i + 1) + ' 个源不是对象'); return; }
    if (typeof s.id !== 'string' || !/^[a-z0-9_]{2,32}$/.test(s.id)) {
      errs.push('第 ' + (i + 1) + ' 个源的 id 不合法');
    } else if (ids.has(s.id)) {
      errs.push('源 id 重复：' + s.id);
    } else {
      ids.add(s.id);
    }
    if (!s.search || typeof s.search !== 'object' || !s.search.path) {
      errs.push('源 ' + (s.id || i + 1) + ' 缺 search.path');
    }
  });
  return errs;
}

async function handle(req, res, body, u, p, send, ctx) {
  // 前缀匹配要卡边界：`/v1/free/sourcesX` 不该被这里接走。
  const inScope = p === '/v1/free/sources' ||
    p === '/v1/free/sources/' ||
    p === '/v1/free/sources/status';
  if (!inScope) return false;

  const file = fileOf(ctx);

  if (req.method === 'GET' && (p === '/v1/free/sources' || p === '/v1/free/sources/')) {
    const { bundle, broken } = readBundle(ctx);
    let updated = 0;
    try { updated = fs.statSync(file).mtimeMs; } catch (_) { /* 文件不存在 */ }
    // ★ 直接返回包本体（不是 {object,data} 信封）：
    //   App 侧 FreeSourceBundle.parse 吃的是包 JSON 本身，
    //   多包一层会让它「解析不出 sources」。
    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-TH-Sources-Count': String((bundle.sources || []).length),
      // ★不要 `| 0`：mtimeMs 是 1.7e12 量级，按 32 位截会变成负数。
      'X-TH-Sources-Updated': String(Math.floor(updated)),
    });
    res.end(JSON.stringify(bundle));
    return true;
  }

  if (req.method === 'GET' && p === '/v1/free/sources/status') {
    const { bundle, broken } = readBundle(ctx);
    let updated = 0;
    let bytes = 0;
    try {
      const st = fs.statSync(file);
      updated = st.mtimeMs;
      bytes = st.size;
    } catch (_) { /* 文件不存在 */ }
    send(200, {
      object: 'meta',
      data: {
        count: (bundle.sources || []).length,
        name: bundle.name || '',
        version: bundle.version || '',
        bytes,
        updated,
        exists: updated > 0,
        broken,
      },
    });
    return true;
  }

  if (req.method === 'PUT' && (p === '/v1/free/sources' || p === '/v1/free/sources/')) {
    const raw = typeof body === 'string' ? body : '';
    if (!raw) {
      send(400, { object: 'error', data: { type: 'invalid_request', message: '请求体为空' } });
      return true;
    }
    if (Buffer.byteLength(raw, 'utf8') > MAX_BYTES) {
      send(413, { object: 'error', data: { type: 'too_large', message: '源包超过 2MB' } });
      return true;
    }
    let d;
    try {
      d = JSON.parse(raw);
    } catch (e) {
      send(400, { object: 'error', data: { type: 'invalid_json', message: '不是合法 JSON' } });
      return true;
    }
    const errs = shapeErrors(d);
    if (errs.length) {
      send(400, { object: 'error', data: { type: 'invalid_bundle', message: errs[0], errors: errs } });
      return true;
    }
    // 先写临时文件再 rename：避免半个包被读到（App 可能正好在同步）。
    const tmp = file + '.tmp';
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(d, null, 2), 'utf8');
    fs.renameSync(tmp, file);
    send(200, {
      object: 'meta',
      data: { count: d.sources.length, saved: true },
    });
    return true;
  }

  return false;
}

module.exports = { handle, fileOf, shapeErrors, MAX_BYTES };
