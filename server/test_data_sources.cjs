// 数据源分层自检（全盘升级 #208/#209）
// 跑法：node server/test_data_sources.cjs（退出码非 0 = 有断言失败）
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert/strict');

const m = require('./routes-data-sources');

let pass = 0, fail = 0;
function ok(cond, what) {
  if (cond) pass++;
  else { fail++; console.log('FAIL  ' + what); }
}
function mkSend() {
  const hit = { code: 0, body: null };
  const send = (code, obj) => { hit.code = code; hit.body = obj; return undefined; };
  return { hit, send };
}

(async () => {
  console.log('== 1. 公开端点（移动端 / 公开网页端） ==');
  {
    const { hit, send } = mkSend();
    const r = await m.handlePublic({ method: 'GET' }, {}, '/v1/public-sources', send);
    ok(r === true, 'handler 返回 true（index.js 靠它判定已处理）');
    ok(hit.code === 200, '匿名 GET 返回 200');
    ok(hit.body.scope === 'public', 'scope=public');
    ok(hit.body.count === m.PUBLIC.length, 'count 与实际条目一致');
    const blob = JSON.stringify(hit.body).toLowerCase();
    for (const t of m.BANNED) ok(!blob.includes(t.toLowerCase()), '公开清单不含 ' + t);
    ok(m.isPublicClean(), '准入闸门判定清单干净');
  }
  {
    const { hit, send } = mkSend();
    const r = await m.handlePublic({ method: 'GET' }, {}, '/v1/admin/source-registry', send);
    ok(r === false && hit.code === 0, '公开端点不处理 admin 路径');
  }
  {
    const { hit, send } = mkSend();
    const r = await m.handlePublic({ method: 'POST' }, {}, '/v1/public-sources', send);
    ok(r === false && hit.code === 0, '公开端点只读，POST 不响应');
  }

  console.log('== 2. 管理后台端点（需配对 token，挂在鉴权之后） ==');
  const DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'th-src-'));
  {
    const { hit, send } = mkSend();
    const r = await m.handleAdmin({ method: 'GET' }, {}, '', '/v1/admin/source-registry', send, { DATA });
    ok(r === true && hit.code === 200, '注册表返回 200');
    ok(hit.body.scope === 'admin', 'scope=admin');
    ok(hit.body.data.length === m.ADMIN_REGISTRY.length, '注册表条目齐全');
    ok(Array.isArray(hit.body.grantedAccounts), '带出授权账号列表');
    const blob = JSON.stringify(hit.body.data);
    ok(!blob.includes('copy_manga') && !blob.includes('baozi'),
        '注册信息只有元信息，不含具体第三方源标识');
  }
  {
    const { hit, send } = mkSend();
    const body = JSON.stringify({ account: 'friend@example.com' });
    const r = await m.handleAdmin({ method: 'POST' }, {}, body, '/v1/admin/source-grants', send, { DATA });
    ok(r === true && hit.code === 200, '授权账号成功');
    ok(m.readGrants(DATA).includes('friend@example.com'), '授权已落盘');
  }
  {
    const { hit, send } = mkSend();
    const body = JSON.stringify({ account: 'friend@example.com', revoke: true });
    await m.handleAdmin({ method: 'POST' }, {}, body, '/v1/admin/source-grants', send, { DATA });
    ok(!m.readGrants(DATA).includes('friend@example.com'), '撤销授权生效');
  }
  {
    const { hit, send } = mkSend();
    await m.handleAdmin({ method: 'POST' }, {}, '{}', '/v1/admin/source-grants', send, { DATA });
    ok(hit.code === 400, '空账号被拒');
  }
  {
    const { hit, send } = mkSend();
    const r = await m.handleAdmin({ method: 'GET' }, {}, '', '/v1/public-sources', send, { DATA });
    ok(r === false, '管理端点不抢公开路径');
  }

  console.log('== 3. 两端契约对齐（Dart 表 ⇄ Node 表） ==');
  const dart = fs.readFileSync(path.join(__dirname, '../flutter_app/lib/core/public_data_sources.dart'), 'utf8');
  const dartIds = [...dart.matchAll(/^\s*id:\s*'([a-z0-9_]+)',/gm)].map(x => x[1]);
  const nodeIds = m.PUBLIC.map(x => x.id);
  ok(dartIds.length === nodeIds.length,
      '条目数一致 Dart=' + dartIds.length + ' Node=' + nodeIds.length);
  for (const id of dartIds) ok(nodeIds.includes(id), 'Node 侧有 ' + id);
  for (const id of nodeIds) ok(dartIds.includes(id), 'Dart 侧有 ' + id);

  console.log('== 4. 接线（防「只写了一半」） ==');
  const idx = fs.readFileSync(path.join(__dirname, 'index.js'), 'utf8');
  const iPublic = idx.indexOf('rtDataSources.handlePublic');
  const iGate = idx.indexOf('// 其余全需鉴权');
  const iAdmin = idx.indexOf('rtDataSources.handleAdmin');
  ok(iPublic > 0 && iPublic < iGate, '公开端点挂在鉴权闸门之前');
  ok(iAdmin > iGate, '管理端点挂在鉴权闸门之后');
  ok(idx.includes("timingEqual(req.headers['x-th-token'], SECRET)"), '全局 token 闸门仍在');
  ok(require('./package.json').version === '0.8.8', '后端版本已 bump 到 0.8.8');

  fs.rmSync(DATA, { recursive: true, force: true });
  console.log('\n' + pass + ' 通过 / ' + fail + ' 失败');
  if (fail > 0) process.exit(1);
})().catch(e => { console.error('FATAL', e); process.exit(1); });
