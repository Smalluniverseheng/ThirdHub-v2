#!/usr/bin/env node
/**
 * thp-check — THP/1.0 一致性测试工具（零依赖 Node.js ≥18）
 * 用法: node tools/thp-check.js <peer地址> [--role engine|library] [--module novel] [--verbose]
 * 例:   node tools/thp-check.js http://127.0.0.1:12001 --role engine --module novel
 *
 * 覆盖 THP.md §16 全部检查项。退出码 0=全部通过，1=有失败项。
 */
'use strict';

const args = process.argv.slice(2);
const base = (args[0] || '').replace(/\/$/, '');
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const ROLE = opt('--role', 'engine');
const MODULE = opt('--module', 'novel');
const VERBOSE = args.includes('--verbose');

if (!base) {
  console.error('用法: node tools/thp-check.js <peer地址> [--role engine|library] [--module novel]');
  process.exit(2);
}

let pass = 0, fail = 0, skip = 0;
const failures = [];
function ok(name, cond, detail = '') {
  if (cond) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; failures.push(name); console.log(`  ❌ ${name}${detail ? ' —— ' + detail : ''}`); }
}
function skipped(name, why) { skip++; console.log(`  ⏭️  ${name}（${why}）`); }

async function req(method, path, body, headers = {}) {
  const rid = 'thp-check-' + Math.random().toString(36).slice(2, 10);
  const h = { 'content-type': 'application/json', 'x-th-request-id': rid, ...headers };
  let res;
  try {
    res = await fetch(base + path, { method, headers: h, body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(15000) });
  } catch (e) {
    return { netErr: String(e), status: 0, json: null, headers: new Headers(), rid };
  }
  let json = null, text = '';
  try { text = await res.text(); json = JSON.parse(text); } catch { /* 非JSON */ }
  return { status: res.status, json, text, headers: res.headers, rid };
}

const isOkEnvelope = j => j && j.ok === true && 'data' in j;
const isErrEnvelope = j => j && j.ok === false && j.error && typeof j.error.code === 'string' && typeof j.error.message === 'string';
const isEnvelope = j => isOkEnvelope(j) || isErrEnvelope(j);

(async () => {
  console.log(`\nthp-check · ${base} · role=${ROLE} · module=${MODULE}\n`);

  // ── 1. GET /thp/meta ─────────────────────────────────────────
  console.log('【1】/thp/meta 身份端点');
  const meta = await req('GET', '/thp/meta');
  ok('meta 可访问', !meta.netErr, meta.netErr || `HTTP ${meta.status}`);
  ok('meta 返回合法信封', isOkEnvelope(meta.json));
  if (isOkEnvelope(meta.json)) {
    const d = meta.json.data || {};
    ok('protocol = THP/1.x', /^THP\/1(\.\d+)?$/.test(d.protocol || ''), `got "${d.protocol}"`);
    ok('instanceId 存在（UUID）', typeof d.instanceId === 'string' && d.instanceId.length >= 8);
    ok('role 合法（engine/library）', ['engine', 'library'].includes(d.role), `got "${d.role}"`);
    ok('caps 为数组', Array.isArray(d.caps));
    ok('auth 为数组且含 none', Array.isArray(d.auth) && d.auth.includes('none'), 'L0 匿名必须永远可用');
    if (ROLE === 'library') ok('library 角色 caps 含 library', (d.caps || []).includes('library'));
  }
  const caps = (meta.json?.data?.caps) || [];

  // ── 2. X-TH-Request-Id 回显 ──────────────────────────────────
  console.log('【2】X-TH-Request-Id 回显');
  ok('响应头回显 Request-Id', (meta.headers.get('x-th-request-id') || '') === meta.rid,
     `got "${meta.headers.get('x-th-request-id')}"`);

  // ── 3. 模块端点：search / toc / content ──────────────────────
  console.log(`【3】/thp/m/${MODULE}/search|toc|content`);
  const post = caps.includes('post-query');
  const s1 = post
    ? await req('POST', `/thp/m/${MODULE}/search`, { q: 'the', limit: 5, cursor: '' })
    : await req('GET', `/thp/m/${MODULE}/search?q=the&limit=5&cursor=`);
  ok('search 可访问', !s1.netErr && s1.status !== 404, s1.netErr || `HTTP ${s1.status}`);
  ok('search 返回信封', isEnvelope(s1.json));
  if (isOkEnvelope(s1.json)) {
    ok('search data 为数组', Array.isArray(s1.json.data));
    ok('search meta 含分页三件套', s1.json.meta && 'cursor' in s1.json.meta && 'hasMore' in s1.json.meta);
  }
  const first = isOkEnvelope(s1.json) && Array.isArray(s1.json.data) ? s1.json.data[0] : null;
  if (first && first.id) {
    ok('search 结果含不透明 id + ref 不放 ID 位', typeof first.id === 'string');
    const toc = post
      ? await req('POST', `/thp/m/${MODULE}/toc`, { id: first.id, cursor: '' })
      : await req('GET', `/thp/m/${MODULE}/toc?id=${encodeURIComponent(first.id)}&cursor=`);
    ok('toc 返回信封且 data 为数组', isOkEnvelope(toc.json) && Array.isArray(toc.json.data),
       isEnvelope(toc.json) ? '' : '非法信封');
    const ch = isOkEnvelope(toc.json) ? toc.json.data[0] : null;
    if (ch && ch.id) {
      const ct = post
        ? await req('POST', `/thp/m/${MODULE}/content`, { id: first.id, chapterId: ch.id })
        : await req('GET', `/thp/m/${MODULE}/content?id=${encodeURIComponent(first.id)}&chapterId=${encodeURIComponent(ch.id)}`);
      ok('content 返回信封', isEnvelope(ct.json));
      if (isOkEnvelope(ct.json)) ok('content data 为对象', typeof ct.json.data === 'object' && ct.json.data !== null);
    } else skipped('content 链路', 'toc 无可用章节');
  } else skipped('toc/content 链路', 'search 无结果（空库可接受，建议造数据后重测）');

  // ── 4. cursor 分页行为 ───────────────────────────────────────
  console.log('【4】cursor 分页');
  if (isOkEnvelope(s1.json) && s1.json.meta?.hasMore && s1.json.meta?.cursor) {
    const s2 = post
      ? await req('POST', `/thp/m/${MODULE}/search`, { q: 'the', limit: 5, cursor: s1.json.meta.cursor })
      : await req('GET', `/thp/m/${MODULE}/search?q=the&limit=5&cursor=${encodeURIComponent(s1.json.meta.cursor)}`);
    ok('第二轮分页返回信封', isOkEnvelope(s2.json));
    ok('cursor 单调不回退', isOkEnvelope(s2.json) && s2.json.meta?.cursor !== s1.json.meta?.cursor);
  } else skipped('cursor 分页第二轮', 'hasMore=false，单页已覆盖');
  const badCur = await req('GET', `/thp/m/${MODULE}/search?q=the&cursor=%E4%B9%B1%E7%A0%81${Date.now()}`);
  ok('非法 cursor → 400 或合法错误信封（不得 500）',
     badCur.status === 400 || isEnvelope(badCur.json), `HTTP ${badCur.status}`);

  // ── 5. 未知字段容忍（请求侧）────────────────────────────────
  console.log('【5】未知字段容忍');
  const uf = await req('POST', `/thp/m/${MODULE}/search`, { q: 'the', limit: 5, cursor: '', totallyUnknownField: { x: [1, 2] } });
  ok('请求注入未知字段不报错（忽略之）', isEnvelope(uf.json) && uf.status !== 500, `HTTP ${uf.status}`);

  // ── 6. 404 / 降级行为 ───────────────────────────────────────
  console.log('【6】404 与降级');
  const nf = await req('GET', '/thp/m/__nonexistent_module__/search?q=x');
  ok('未知模块 → HTTP 404', nf.status === 404, `HTTP ${nf.status}`);
  ok('未知模块仍返回错误信封', isErrEnvelope(nf.json) || nf.json === null ? (nf.status === 404) : false);
  const extra = await req('GET', `/thp/m/${MODULE}/extra?id=__x__&what=lyric`);
  ok('extra 可选端点：200 信封 或 404（不得 500）', extra.status === 404 || isEnvelope(extra.json), `HTTP ${extra.status}`);

  // ── 7. 角色约束 ─────────────────────────────────────────────
  console.log('【7】角色约束');
  if (ROLE === 'engine') {
    const w = await req('POST', `/thp/m/${MODULE}/items`, { name: 'x' });
    ok('engine 禁止写端点（404/405）', [404, 405].includes(w.status), `HTTP ${w.status}（法律防火墙机器可检项）`);
  } else {
    const chg = await req('GET', `/thp/changes?module=${MODULE}&cursor=&limit=1`);
    ok('library 必选 /thp/changes', isOkEnvelope(chg.json), `HTTP ${chg.status}`);
    if (isOkEnvelope(chg.json)) {
      ok('changes 条目含 op/ts', !chg.json.data.length || ('op' in chg.json.data[0] && 'ts' in chg.json.data[0]));
      ok('changes meta 含 cursor', chg.json.meta && 'cursor' in chg.json.meta);
    }
    const blobTry = await req('POST', '/thp/blob', { sha256: '0'.repeat(64), size: 1, mime: 'text/plain' });
    ok('library 必选 /thp/blob（信封响应）', isEnvelope(blobTry.json) || blobTry.status === 400, `HTTP ${blobTry.status}`);
  }

  // ── 8. 可选能力（按 caps 声明验证）───────────────────────────
  console.log('【8】可选能力验证');
  if (caps.includes('batch-content')) {
    const bc = await req('POST', `/thp/m/${MODULE}/content:batch`, { items: [{ id: first?.id || 'x', chapterId: '__bad__' }] });
    const ct = bc.headers.get('content-type') || '';
    // 声明了 batch-content 就必须真的是 NDJSON 流（防止单条 JSON 信封蒙混过关）
    ok('batch-content Content-Type 必须为 application/x-ndjson', ct.includes('x-ndjson'), `got "${ct}"`);
    if (ct.includes('x-ndjson')) {
      const lines = (bc.text || '').split('\n').filter(Boolean);
      ok('batch-content 每行都是合法信封', lines.length > 0 && lines.every(l => { try { return isEnvelope(JSON.parse(l)); } catch { return false; } }));
    }
  } else skipped('batch-content NDJSON', '未声明 caps');
  if (caps.includes('events')) {
    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 3000);
      const r = await fetch(base + '/thp/events', { signal: ctrl.signal });
      clearTimeout(t);
      ok('events SSE content-type', (r.headers.get('content-type') || '').includes('text/event-stream'));
    } catch { ok('events SSE 可连接', false, '连接失败'); }
  } else skipped('events SSE', '未声明 caps');
  if (caps.includes('jobs')) {
    const j = await req('POST', '/thp/jobs', { type: 'noop' });
    ok('jobs 创建返回信封', isEnvelope(j.json));
  } else skipped('jobs', '未声明 caps');
  if (caps.includes('tools')) {
    const tl = await req('GET', '/thp/tools');
    ok('tools 返回工具数组', isOkEnvelope(tl.json) && Array.isArray(tl.json.data));
    if (isOkEnvelope(tl.json) && tl.json.data[0])
      ok('工具含 name/description/params(JSON Schema)', !!(tl.json.data[0].name && tl.json.data[0].params));
  } else skipped('tools', '未声明 caps');

  // ── 9. blob 完整性回环（library 必选：声明 sha256 去重就要真校验）──
  if (ROLE === 'library') {
    console.log('【9】blob 完整性回环');
    const crypto = require('crypto');
    const payload = crypto.randomBytes(4096); // 单块小文件
    const sha = crypto.createHash('sha256').update(payload).digest('hex');
    const declare = await req('POST', '/thp/blob', { sha256: sha, size: payload.length, mime: 'application/octet-stream' });
    ok('blob 声明返回信封', isOkEnvelope(declare.json), `HTTP ${declare.status}`);
    if (isOkEnvelope(declare.json) && declare.json.data?.id) {
      const id = declare.json.data.id;
      if (!declare.json.data.dedup) {
        // 故意乱序/补传：先传 chunk0（单块场景即全部）
        const up = await fetch(base + `/thp/blob/${id}/chunks/0`, { method: 'POST',
          headers: { 'content-type': 'application/octet-stream' }, body: payload, signal: AbortSignal.timeout(15000) });
        let upj = null; try { upj = await up.json(); } catch {}
        ok('分块上传返回信封且 complete=true', isOkEnvelope(upj) && upj.data?.complete === true,
           `HTTP ${up.status}`);
        // 越界 chunk 必须 400
        const oob = await fetch(base + `/thp/blob/${id}/chunks/9`, { method: 'POST',
          headers: { 'content-type': 'application/octet-stream' }, body: payload, signal: AbortSignal.timeout(15000) });
        let oobj = null; try { oobj = await oob.json(); } catch {}
        ok('越界 chunk → 400 错误信封', oob.status === 400 && isErrEnvelope(oobj), `HTTP ${oob.status}`);
      }
      // 取回比对 sha256
      const dn = await fetch(base + `/thp/blob/${id}`, { signal: AbortSignal.timeout(15000) });
      const got = Buffer.from(await dn.arrayBuffer());
      ok('blob 取回内容 sha256 一致', dn.status === 200 &&
         crypto.createHash('sha256').update(got).digest('hex') === sha);
      // Range 合法/非法
      const rg = await fetch(base + `/thp/blob/${id}`, { headers: { Range: 'bytes=0-9' }, signal: AbortSignal.timeout(15000) });
      ok('Range 请求 → 206 且长度正确', rg.status === 206 && (await rg.arrayBuffer()).byteLength === 10, `HTTP ${rg.status}`);
      const rgBad = await fetch(base + `/thp/blob/${id}`, { headers: { Range: 'bytes=999999-' }, signal: AbortSignal.timeout(15000) });
      ok('越界 Range → 416', rgBad.status === 416, `HTTP ${rgBad.status}`);
      // 再次声明同 sha256 → 秒传
      const dedup = await req('POST', '/thp/blob', { sha256: sha, size: payload.length });
      ok('同 sha256 再声明 → dedup', isOkEnvelope(dedup.json) && dedup.json.data?.dedup === true);
      // 错误 sha256 必须被拒（脏数据不得入库）
      const badPayload = crypto.randomBytes(2048);
      const badDeclare = await req('POST', '/thp/blob', { sha256: 'f'.repeat(64), size: badPayload.length });
      if (isOkEnvelope(badDeclare.json) && badDeclare.json.data?.id) {
        const badId = badDeclare.json.data.id;
        await fetch(base + `/thp/blob/${badId}/chunks/0`, { method: 'POST',
          headers: { 'content-type': 'application/octet-stream' }, body: badPayload, signal: AbortSignal.timeout(15000) });
        const badGet = await fetch(base + `/thp/blob/${badId}`, { signal: AbortSignal.timeout(15000) });
        let badGetJ = null; try { badGetJ = await badGet.json(); } catch {}
        ok('sha256 不符 → 作废且不可取回', badGet.status === 404, `HTTP ${badGet.status} ${JSON.stringify(badGetJ || '')}`);
      }
    }
  }

  // ── 汇总 ────────────────────────────────────────────────────
  console.log(`\n结果：${pass} 通过 · ${fail} 失败 · ${skip} 跳过`);
  if (failures.length) { console.log('失败项：'); failures.forEach(f => console.log('  - ' + f)); }
  console.log(fail === 0 ? '🎉 通过 thp-check，可以发版。' : '⛔ 未通过，修复后重跑。');
  process.exit(fail === 0 ? 0 : 1);
})();
