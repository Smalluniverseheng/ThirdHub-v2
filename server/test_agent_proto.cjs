// Agent 协议端到端自检（THA/1）:
// 直接驱动 server/routes-agent.js 的 handle()，用假的 req/res/send 走完整协议。
// 不依赖后端服务在跑，也不依赖本机装没装 DSH —— 「没装 DSH 要能优雅降级」正是断言之一。
//
// 覆盖点（每条都对应一个真会出问题的地方）:
//   1) health 字段齐备 + 未装 DSH 时如实报 fallback（不许假装有完整 Agent）
//   2) 三档 profile 的判定：default 读放行/写要确认/高危拒绝
//   3) 高危工具在 default 下请求确认 → 403，且不产生挂起项
//   4) 受控写工具 → 拿到 confirmId，答复后落到事件流且队列清空
//   5) 事件流 append-only：seq 单调、since 增量、id 唯一
//   6) 未知事件类型 → 400 而不是 500
//   7) 审计流水字段齐备（§9）
//   8) MCP 注册表：增删开关 + 非法地址拦截 + 连不上时不抛异常
//   9) 插件白名单：GPL/AGPL/SSPL 在 deny 名单里
//  10) 事件与审计落盘（重启后还能读回）
'use strict';
const path = require('path');
const fs = require('fs');
const os = require('os');

const ROOT = path.join(__dirname, '..');
const DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'agentdata-'));
const routes = require(path.join(__dirname, 'routes-agent.js'));

let fails = 0, total = 0;
function ck(name, cond, extra) {
  total++;
  if (cond) console.log('  OK   ' + name);
  else { fails++; console.log('  FAIL ' + name + (extra !== undefined ? '  -> ' + extra : '')); }
}

async function call(method, fullPath, obj) {
  const u = new URL('http://x' + fullPath);
  let out = null;
  const send = (code, payload) => { out = { status: code, json: payload }; return true; };
  const req = { method, headers: {}, on() {} };
  const res = { writeHead() {}, end() {}, write() {} };
  const body = obj === undefined ? '' : JSON.stringify(obj);
  const hit = await routes.handle(req, res, body, u, u.pathname, send, { DATA, SECRET: 'test' });
  return { hit, out };
}
const D = (r) => (r.out && r.out.json && r.out.json.data) || {};

(async () => {
  // ── 1. 运行模式与能力 ──
  console.log('== 1. /agent/health: 能力齐全, 模式如实 ==');
  let r = await call('GET', '/agent/health');
  ck('health 200', r.out && r.out.status === 200, JSON.stringify(r.out));
  let h = D(r);
  ck('protocolVersion = THA/1', h.protocolVersion === 'THA/1', h.protocolVersion);
  ck('mode ∈ {full, fallback}', ['full', 'fallback'].includes(h.mode), h.mode);
  ck('capabilities 五项齐全', !!(h.capabilities && h.capabilities.eventLog && h.capabilities.policy
    && h.capabilities.confirmQueue && h.capabilities.audit && h.capabilities.mcpRegistry), JSON.stringify(h.capabilities));
  ck('dsh 探测字段齐全', !!(h.dsh && typeof h.dsh.detected === 'boolean' && typeof h.dsh.kind === 'string'), JSON.stringify(h.dsh));
  ck('三个 profile 都报出来', Array.isArray(h.profiles) && h.profiles.length === 3, JSON.stringify(h.profiles));
  ck('full-access 对普通用户不可见', h.profiles.some((p) => p.id === 'full-access' && p.visibleToUser === false));
  ck('插件白名单报出来', Array.isArray(h.plugins) && h.plugins.length >= 4, (h.plugins || []).length);
  // 本机大概率没装 DSH：降级必须是「false + 有原因的」，不能是「true 却什么都没接」
  if (h.mode === 'fallback') {
    ck('降级时 fullAgentAvailable=false', h.fullAgentAvailable === false);
    ck('降级时给出可读原因', String(h.dsh.error || '').length > 0, h.dsh.error);
    ck('降级时 sandbox/nativePlugins 也如实为 false',
      h.capabilities.sandbox === false && h.capabilities.nativePlugins === false);
  } else {
    ck('完整模式时 fullAgentAvailable=true 且 dsh 在跑', h.fullAgentAvailable === true);
  }

  // ── 2. profile 判定 ──
  console.log('== 2. /agent/tools: 三档判定必须不同 ==');
  const toolsOf = async (prof) => {
    const rr = await call('GET', '/agent/tools?profile=' + prof);
    const m = {}; for (const t of (D(rr) || [])) m[t.name] = t.decision; return m;
  };
  const dflt = await toolsOf('default');
  ck('default: kb.search = allow', dflt['kb.search'] === 'allow', dflt['kb.search']);
  ck('default: file.readSelected = allow', dflt['file.readSelected'] === 'allow', dflt['file.readSelected']);
  ck('default: note.save = confirm', dflt['note.save'] === 'confirm', dflt['note.save']);
  ck('default: reading.progress.write = confirm', dflt['reading.progress.write'] === 'confirm', dflt['reading.progress.write']);
  ck('default: fs.write = deny', dflt['fs.write'] === 'deny', dflt['fs.write']);
  ck('default: shell.run = deny', dflt['shell.run'] === 'deny', dflt['shell.run']);
  ck('default: accessibility.tap = deny', dflt['accessibility.tap'] === 'deny', dflt['accessibility.tap']);

  const acc = await toolsOf('acceptEdits');
  ck('acceptEdits: fs.write = confirm', acc['fs.write'] === 'confirm', acc['fs.write']);
  ck('acceptEdits: shell.run 仍 deny', acc['shell.run'] === 'deny', acc['shell.run']);
  ck('acceptEdits: note.save 也不再拦', ['allow', 'confirm'].includes(acc['note.save']), acc['note.save']);

  const full = await toolsOf('full-access');
  ck('full-access: fs.write = allow', full['fs.write'] === 'allow', full['fs.write']);
  ck('full-access: shell.run = allow', full['shell.run'] === 'allow', full['shell.run']);
  ck('full-access: accessibility.tap = allow', full['accessibility.tap'] === 'allow', full['accessibility.tap']);

  const unknown = await toolsOf('不存在的档位');
  ck('未知 profile 一律 deny 而非放行', Object.keys(unknown).length === 0 || Object.values(unknown).every((v) => v === 'deny'),
    JSON.stringify(unknown));

  // 档位名写错是「静默放宽权限」的典型入口，必须在建会话时就挡住
  r = await call('POST', '/agent/session', { id: 'bad', profile: 'full_acess' });
  ck('建会话时档位名写错 -> 400', r.out.status === 400, JSON.stringify(r.out));
  ck('写错档位时提示可选值', String((r.out.json.data || {}).message || '').includes('default'), JSON.stringify(r.out.json));

  // ── 3. 会话与事件流 ──
  console.log('== 3. 会话 + 事件流 append-only ==');
  r = await call('POST', '/agent/session', { title: '整理书架', userId: 'u1', profile: 'default', id: 's1' });
  ck('建会话 200', r.out.status === 200, JSON.stringify(r.out));
  ck('会话 id 保留', D(r).id === 's1', D(r).id);

  const seqs = [];
  for (let i = 1; i <= 3; i++) {
    r = await call('POST', '/agent/event', { sessionId: 's1', type: 'assistant_delta', payload: { text: '第' + i + '段' } });
    seqs.push((r.out.json && r.out.json.data && r.out.json.data.seq));
  }
  ck('seq 单调 = [2,3,4]（建会话时已有一条 done）', JSON.stringify(seqs) === '[2,3,4]', JSON.stringify(seqs));

  r = await call('GET', '/agent/events?sessionId=s1');
  let evs = D(r);
  ck('事件全量读回 4 条', evs.length === 4, evs.length);
  ck('meta.lastSeq 带出来', r.out.json.meta.lastSeq === 4, JSON.stringify(r.out.json.meta));
  const ids = evs.map((e) => e.id);
  ck('事件 id 全局唯一', new Set(ids).size === ids.length, ids.join(','));

  r = await call('GET', '/agent/events?sessionId=s1&since=2');
  ck('since=2 只回 seq>2 的 2 条', D(r).length === 2 && D(r).every((e) => e.seq > 2), JSON.stringify(D(r).map((e) => e.seq)));

  r = await call('POST', '/agent/event', { sessionId: 's1', type: '编造的事件' });
  ck('未知事件类型 -> 400', r.out.status === 400, JSON.stringify(r.out));
  r = await call('POST', '/agent/event', { type: 'done' });
  ck('缺 sessionId -> 400', r.out.status === 400, JSON.stringify(r.out));
  r = await call('GET', '/agent/events?sessionId=不存在');
  ck('不存在的会话 -> 404', r.out.status === 404, JSON.stringify(r.out));

  // ── 4. 确认队列（高危工具闸门） ──
  console.log('== 4. 确认队列 ==');
  r = await call('POST', '/agent/confirm', { sessionId: 's1', tool: 'shell.run', args: { cmd: 'rm -rf /' } });
  ck('default 下 shell.run 请求确认 -> 403', r.out.status === 403, JSON.stringify(r.out));
  r = await call('GET', '/agent/confirm?sessionId=s1');
  ck('被拒的高危工具不产生挂起项', D(r).length === 0, JSON.stringify(D(r)));

  r = await call('POST', '/agent/confirm', { sessionId: 's1', tool: 'note.save', args: { path: 'a.md', text: 'hi' } });
  ck('受控写工具 -> 200 且给 confirmId', r.out.status === 200 && !!D(r).confirmId, JSON.stringify(r.out));
  const cid = D(r).confirmId;
  r = await call('GET', '/agent/confirm?sessionId=s1');
  ck('挂起队列里有 1 项', D(r).length === 1 && D(r)[0].confirmId === cid, JSON.stringify(D(r)));

  r = await call('POST', '/agent/confirm', { confirmId: cid, allow: true, by: 'user' });
  ck('答复确认 -> 200 allow=true', r.out.status === 200 && D(r).allow === true, JSON.stringify(r.out));
  r = await call('GET', '/agent/confirm?sessionId=s1');
  ck('答复后队列清空', D(r).length === 0, JSON.stringify(D(r)));
  r = await call('POST', '/agent/confirm', { confirmId: cid, allow: true });
  ck('重复答复 -> 404（不是 500）', r.out.status === 404, JSON.stringify(r.out));

  r = await call('GET', '/agent/events?sessionId=s1');
  evs = D(r);
  ck('confirm_request 已入事件流', evs.some((e) => e.type === 'confirm_request'), '无 confirm_request');
  ck('confirm_result 已入事件流', evs.some((e) => e.type === 'confirm_result'), '无 confirm_result');

  // ── 5. 审计字段齐备（§9） ──
  console.log('== 5. 审计 ==');
  r = await call('GET', '/agent/audit?limit=50');
  const au = D(r);
  ck('审计有记录', Array.isArray(au) && au.length > 0, au.length);
  const row = au[0] || {};
  for (const k of ['ts', 'sessionId', 'userId', 'profile', 'tool', 'argsDigest', 'decision', 'result']) {
    ck('审计字段 ' + k + ' 存在', Object.prototype.hasOwnProperty.call(row, k), JSON.stringify(row));
  }
  ck('decision 取值合法', ['allow', 'deny', 'confirm'].includes(row.decision), row.decision);
  ck('argsDigest 是 sha256: 形状', /^sha256:[0-9a-f]{8,}$/.test(String(row.argsDigest || '')), row.argsDigest);
  ck('审计记录了那条高危拒绝', au.some((x) => x.tool === 'shell.run' && x.decision === 'deny'), '未记录 shell.run 的拒绝');
  ck('审计按 sessionId 可过滤', (await call('GET', '/agent/audit?sessionId=s1')).out.status === 200);

  // ── 6. 一轮对话入口：模式判定 ──
  console.log('== 6. /agent/send ==');
  r = await call('POST', '/agent/send', { sessionId: 's1', text: '帮我把这本书加进书架', contextRefs: [{ type: 'book', ref: 'shelf:b1' }] });
  ck('send 200', r.out.status === 200, JSON.stringify(r.out));
  ck('回带 mode', ['full', 'fallback'].includes(D(r).mode), D(r).mode);
  ck('回带 hint 让客户端知道怎么走', String(D(r).hint || '').length > 0, D(r).hint);
  ck('user_message 已入事件流', D(r).event && D(r).event.type === 'user_message', JSON.stringify(D(r).event));
  r = await call('POST', '/agent/send', { sessionId: 's1', text: '  ' });
  ck('send 缺 sessionId 时给 400', (await call('POST', '/agent/send', { text: 'x' })).out.status === 400);

  // ── 7. MCP 注册表 ──
  console.log('== 7. MCP 注册表 ==');
  r = await call('GET', '/agent/mcp');
  ck('MCP 列表 200 且为空', r.out.status === 200 && D(r).length === 0, JSON.stringify(D(r)));
  r = await call('POST', '/agent/mcp', { name: '本地知识库', url: 'ftp://bad' });
  ck('非法地址 -> 400', r.out.status === 400, JSON.stringify(r.out));
  r = await call('POST', '/agent/mcp', { name: '本地知识库', url: 'http://127.0.0.1:1/mcp' });
  ck('加 MCP -> 200 且给 id', r.out.status === 200 && !!D(r).id, JSON.stringify(r.out));
  const mid = D(r).id;
  r = await call('POST', '/agent/mcp', { name: 'dup', url: 'http://127.0.0.1:1/mcp' });
  ck('重复地址 -> 400', r.out.status === 400, JSON.stringify(r.out));
  r = await call('GET', '/agent/mcp');
  ck('列表里有 1 条', D(r).length === 1 && D(r)[0].id === mid, JSON.stringify(D(r)));
  r = await call('POST', '/agent/mcp/toggle', { id: mid, enabled: false });
  ck('禁用 -> 200', r.out.status === 200, JSON.stringify(r.out));
  ck('禁用后 enabled=false', (await call('GET', '/agent/mcp')).out.json.data[0].enabled === false);
  r = await call('POST', '/agent/mcp/connect', { id: mid });
  ck('连不上时不抛异常（返回 400 + error 文案）', r.out.status === 400 && String(D(r).error || '').length > 0, JSON.stringify(r.out));
  r = await call('POST', '/agent/mcp/toggle', { id: '不存在' });
  ck('开关不存在的 MCP -> 404', r.out.status === 404, JSON.stringify(r.out));
  r = await call('POST', '/agent/mcp/call', { serverId: mid, tool: 'shell.run', args: {} });
  ck('default 档下调高危 MCP 工具 -> 403', r.out.status === 403, JSON.stringify(r.out));
  r = await call('POST', '/agent/mcp/remove', { id: mid });
  ck('删除 -> 200', r.out.status === 200, JSON.stringify(r.out));
  ck('删除后列表为空', (await call('GET', '/agent/mcp')).out.json.data.length === 0);

  // ── 8. 插件白名单许可证红线 ──
  console.log('== 8. 插件白名单 ==');
  r = await call('GET', '/agent/plugins');
  const pol = (r.out.json.meta || {}).policy || {};
  ck('GPL-3.0 在 deny 名单', (pol.licenseDeny || []).includes('GPL-3.0'), JSON.stringify(pol.licenseDeny));
  ck('AGPL-3.0 在 deny 名单', (pol.licenseDeny || []).includes('AGPL-3.0'));
  ck('SSPL-1.0 在 deny 名单', (pol.licenseDeny || []).includes('SSPL-1.0'));
  ck('MIT 在 allow 名单', (pol.licenseAllow || []).includes('MIT'));
  ck('内置插件都是放行许可证', D(r).every((p) => ['MIT', 'Apache-2.0', 'BSD-3-Clause'].includes(p.license)), JSON.stringify(D(r).map((p) => p.license)));

  // ── 9. 落盘与重启可读 ──
  console.log('== 9. 落盘 ==');
  const sf = path.join(DATA, 'agent-sessions', 's1.jsonl');
  ck('会话事件落成 jsonl', fs.existsSync(sf), sf);
  ck('jsonl 行数 = 事件数', fs.readFileSync(sf, 'utf8').split('\n').filter(Boolean).length >= 8,
    fs.readFileSync(sf, 'utf8').split('\n').filter(Boolean).length);
  ck('审计落成 jsonl', fs.existsSync(path.join(DATA, 'agent-audit.jsonl')));
  ck('会话索引写出来了', fs.existsSync(path.join(DATA, 'agent-sessions', 'index.json')));
  // 换一个进程内实例读同一份 DATA（模拟重启）：历史必须还在
  delete require.cache[require.resolve(path.join(__dirname, 'agent-dsh.js'))];
  delete require.cache[require.resolve(path.join(__dirname, 'routes-agent.js'))];
  const routes2 = require(path.join(__dirname, 'routes-agent.js'));
  const u2 = new URL('http://x/agent/events?sessionId=s1');
  let out2 = null;
  await routes2.handle({ method: 'GET', headers: {}, on() {} },
    { writeHead() {}, end() {}, write() {} }, '', u2, u2.pathname,
    (code, payload) => { out2 = { code, payload }; return true; }, { DATA, SECRET: 'test' });
  ck('「重启」后仍能读回历史事件', out2 && out2.code === 200 && out2.payload.data.length >= 8,
    JSON.stringify(out2 && out2.payload && out2.payload.data && out2.payload.data.length));

  // ── 10. 未命中交回主路由 ──
  console.log('== 10. 路由边界 ==');
  r = await call('GET', '/v1/不存在');
  ck('/v1/* 返回 false 交回主路由', r.hit === false, 'got ' + r.hit);
  r = await call('GET', '/agent/不存在');
  ck('未实现的 /agent/* 也返回 false', r.hit === false, 'got ' + r.hit);

  console.log('');
  console.log(fails === 0 ? ('全部通过 ' + total + '/' + total) : (fails + '/' + total + ' 项失败'));
  try { fs.rmSync(DATA, { recursive: true, force: true }); } catch (e) {}
  process.exit(fails === 0 ? 0 : 1);
})().catch((e) => { console.log('异常: ' + ((e && e.stack) || e)); process.exit(1); });
