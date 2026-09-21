// ═══════════════════════════════════════════════════════════════════════════
// PH/1 端间互通中枢自测（纯 Node，不需要起服务器）
//
// 用法: node scripts/selftest-peer-hub.js
//
// 为什么要有它：peer-hub.js 是"前端/后端/插件/DSA 任意组合互相插线"的唯一
// 契约实现面。它错了，表现是"插件连不上/一方输入其他方收不到"，而这类问题
// 在真机上极难定位（要两台设备 + 局域网）。所以这里用 mock 的 req/res 把
// 全部端点跑一遍，包括**反向用例**（错口令必须被拒、旧 token 必须失效）。
// ═══════════════════════════════════════════════════════════════════════════
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const hub = require('../peer-hub');

const TMP = path.join(os.tmpdir(), 'th-peer-test-' + Date.now());
fs.mkdirSync(TMP, { recursive: true });

let pass = 0, fail = 0;
const fails = [];
function ok(cond, name, extra) {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; fails.push(name + (extra ? ' — ' + extra : '')); console.log('  ✗ ' + name + (extra ? ' — ' + extra : '')); }
}
function eq(a, b, name) { ok(a === b, name, 'got=' + JSON.stringify(a) + ' want=' + JSON.stringify(b)); }

// ─── mock req/res ───
function mkRes() {
  const r = { code: 0, body: null, headers: {} };
  r.writeHead = (c, h) => { r.code = c; Object.assign(r.headers, h || {}); };
  r.end = (d) => { try { r.body = JSON.parse(d); } catch (_) { r.body = d; } };
  return r;
}
function mkReq(method, url, extra) {
  return Object.assign({
    method, url,
    headers: {},
    socket: { remoteAddress: '127.0.0.1' },
  }, extra || {});
}
async function call(method, url, bodyObj, headers) {
  const res = mkRes();
  const req = mkReq(method, url, { headers: headers || {} });
  const u = new URL(url, 'https://localhost');
  const body = bodyObj === undefined ? '' : JSON.stringify(bodyObj);
  const hit = await hub.handle(req, res, body, u);
  return { hit, code: res.code, body: res.body };
}

async function main() {
  console.log('\n0) init');
  const reg = hub.init({ DATA: TMP, SECRET: 'thsec_TESTKEY' });
  ok(!!reg, 'init 返回注册表');
  ok(!!reg.accounts.admin, 'init 建出默认账号 admin');
  ok(reg.accounts.admin.pass !== '123456', '口令不以明文存储(存 sha256)');
  eq(reg.accounts.admin.pass, require('crypto').createHash('sha256').update('123456').digest('hex'), '默认口令 = sha256(123456)');
  ok(fs.existsSync(path.join(TMP, 'agent-peers.json')), '注册表已落盘 agent-peers.json');
  const backPeers = hub._test.list().filter((p) => p.kind === 'back');
  eq(backPeers.length, 1, '后端把自己登记为 kind=back（端列表里不该缺中枢）');
  eq(backPeers[0].iid, 'local-back', '后端 iid = local-back');

  // ── 路由前缀 ──
  console.log('\n1) 路由前缀匹配');
  const notMine = await call('GET', '/v1/ping');
  eq(notMine.hit, false, '非 /agent/peer 前缀 → 返回 false（交回主路由）');
  const thpNotMine = await call('GET', '/thp/meta');
  eq(thpNotMine.hit, false, '/thp 不受影响');

  // ── ★身份探针：插件靠它在局域网里认出"这台是 ThirdHub 后端" ──
  //    必须**匿名可达**（否则插件扫到端口也认证不过去，只能一律放弃）……
  const ping = await call('GET', '/agent/peer/ping');
  eq(ping.hit, true, 'ping 命中 /agent/peer 前缀');
  eq(ping.code, 200, '★ping 无 token 也返回 200（否则插件扫不出后端）');
  eq(ping.body.ok, true, 'ping ok=true');
  eq(ping.body.data.object, 'peer-hub', '★ping 用 object 字段自证身份（插件据此排除其他 9527 服务）');
  eq(ping.body.data.proto, 'PH/1', 'ping 带协议名 PH/1');
  //     ……但也不能白送情报：不泄露端列表、密钥、账号。
  const pingKeys = Object.keys(ping.body.data).sort().join(',');
  eq(pingKeys, 'caps,iid,name,object,proto,version', '★ping 只回身份字段，不含 peers/secrets（匿名端点不得泄露端网情报）');
  eq(ping.body.data.peers, undefined, 'ping 不返回端列表');
  eq(ping.body.data.secrets, undefined, 'ping 不返回密钥');

  // ── join 的凭据校验（★ 反向用例）──
  console.log('\n2) /agent/peer/join 凭据校验');
  const noCred = await call('POST', '/agent/peer/join', { kind: 'plug', name: 'x' });
  eq(noCred.hit, true, '前缀命中');
  eq(noCred.code, 401, '★无凭据 join → 401（不能裸奔进网）');
  eq(noCred.body.error.code, 'UNAUTHORIZED', '错误码 UNAUTHORIZED');

  const badPass = await call('POST', '/agent/peer/join', { kind: 'plug', account: 'admin', password: 'wrong' });
  eq(badPass.code, 401, '★口令错误 → 401');
  eq(badPass.body.error.code, 'UNAUTHORIZED', '错误码 UNAUTHORIZED');

  const badUser = await call('POST', '/agent/peer/join', { kind: 'plug', account: 'nobody', password: '123456' });
  eq(badUser.code, 401, '★账号不存在 → 401');

  const badKind = await call('POST', '/agent/peer/join', { kind: 'hacker', account: 'admin', password: '123456' });
  eq(badKind.code, 400, '未知 kind → 400');
  eq(badKind.body.error.code, 'BAD_KIND', '错误码 BAD_KIND');

  const okJoin = await call('POST', '/agent/peer/join', {
    kind: 'plug', name: '下载插件', account: 'admin', password: '123456',
    url: 'http://192.168.1.30:8801', ipv6: '[fe80::1]:8801', tunnel: 'https://plug.example.trycloudflare.com',
    caps: ['tool', 'download'], tools: ['dl.add', 'dl.status'],
  });
  eq(okJoin.code, 200, '正确账号口令 → 200');
  eq(okJoin.body.data.joined, true, 'joined=true');
  ok(/^[0-9a-f]{40}$/.test(okJoin.body.data.peerToken), '发下 40 位 hex peerToken');
  ok(!!okJoin.body.data.hub, '回传 hub 信息（插件可确认连的是哪个后端）');
  eq(okJoin.body.data.hub.iid, 'local-back', 'hub.iid=local-back');
  const tok1 = okJoin.body.data.peerToken;
  const plugIid = okJoin.body.data.iid;
  ok(!!plugIid, '回传 iid');

  // 用后端密钥 join（同局域网已配对的前端走这条路，不用记账号口令）
  const okKey = await call('POST', '/agent/peer/join', { kind: 'front', name: '我的手机', token: 'thsec_TESTKEY' });
  eq(okKey.code, 200, '用后端密钥 join → 200');
  const frontTok = okKey.body.data.peerToken;
  const frontIid = okKey.body.data.iid;

  // ── 续期 + 旧 token 失效 ──
  console.log('\n3) peerToken 续期与失效');
  const renew = await call('POST', '/agent/peer/join', { kind: 'plug', iid: plugIid, peerToken: tok1, name: '下载插件' });
  eq(renew.code, 200, '带 peerToken 续期 → 200（重启后免重新输密码）');
  eq(renew.body.data.iid, plugIid, '续期保持同一 iid（不new建重复端）');
  const tok2 = renew.body.data.peerToken;
  ok(tok2 !== tok1, '续期换发新 token');

  const oldTok = await call('GET', '/agent/peer/list?peerToken=' + tok1);
  eq(oldTok.code, 401, '★旧 token 立即失效 → 401（换发即吊销，防重放）');
  const newTok = await call('GET', '/agent/peer/list?peerToken=' + tok2);
  eq(newTok.code, 200, '新 token 可用');

  // 后端密钥可直接用于所有端点
  const bySecret = await call('GET', '/agent/peer/list', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  eq(bySecret.code, 200, '后端密钥可直接访问端点（管理台用）');

  // ── list ──
  console.log('\n4) /agent/peer/list 目录');
  const list = await call('GET', '/agent/peer/list?peerToken=' + frontTok);
  eq(list.code, 200, 'list 200');
  const peers = list.body.data.peers;
  ok(peers.length >= 3, '在线端 ≥3（back + plug + front），got=' + peers.length);
  const plug = peers.find((p) => p.iid === plugIid);
  ok(!!plug, '插件出现在列表');
  eq(plug.kind, 'plug', 'kind=plug');
  eq(plug.online, true, 'online=true');
  eq(plug.tools.length, 2, '插件工具数=2（其他端据此知道"它能干什么"）');
  assert.deepStrictEqual(plug.caps, ['tool', 'download']);
  eq(plug.direct.length, 3, '★direct 带出 url/ipv6/tunnel 三条直连路径（无后端时用）');
  ok(plug.direct.some((x) => x.includes('fe80::1')), 'direct 含 IPv6');
  ok(plug.direct.some((x) => x.includes('trycloudflare')), 'direct 含内网穿透地址');
  ok(!('tokenHash' in plug), '★tokenHash 绝不出网');
  ok(!JSON.stringify(list.body).includes(tok2), '★响应体里不含任何 peerToken');
  eq(list.body.data.stats.plug, 1, 'stats.plug=1');
  eq(list.body.data.stats.front, 1, 'stats.front=1');
  ok(list.body.data.hub.online, 'hub 自报在线');
  ok(list.body.data.all.length >= 3, 'all 含全部已登记端（含离线）');

  const byCap = await call('GET', '/agent/peer/list?peerToken=' + frontTok + '&cap=download');
  eq(byCap.body.data.peers.length, 1, 'cap=download 过滤出 1 个');
  const byKind = await call('GET', '/agent/peer/list?peerToken=' + frontTok + '&kind=front');
  eq(byKind.body.data.peers.length, 1, 'kind=front 过滤出 1 个');
  const byKind2 = await call('GET', '/agent/peer/list?peerToken=' + frontTok + '&cap=nonexistent');
  eq(byKind2.body.data.peers.length, 0, 'cap 不存在 → 空');

  // ── self ──
  console.log('\n5) /agent/peer/self 我是谁');
  const self = await call('GET', '/agent/peer/self?peerToken=' + frontTok);
  eq(self.code, 200, 'self 200');
  eq(self.body.data.you.iid, frontIid, 'you.iid 正确');

  // ── beat ──
  console.log('\n6) /agent/peer/beat 心跳');
  const beat = await call('POST', '/agent/peer/beat', { peerToken: frontTok, url: 'http://192.168.1.9:9528', caps: ['front', 'tts'] });
  eq(beat.code, 200, 'beat 200');
  ok(beat.body.data.you.caps.includes('tts'), '心跳可增量更新 caps（能力变了不用重新 join）');
  eq(beat.body.data.you.url, 'http://192.168.1.9:9528', '心跳更新 url');
  ok(!('name' in beat.body.data.you) || beat.body.data.you.name !== '', '心跳不清空未提交字段');
  ok(beat.body.data.online >= 3, 'online 计数');

  // ── relay / pull：一方输入，其他方都能用 ──
  console.log('\n7) relay + pull（一方输入 → 其他方拉到）');
  const relay = await call('POST', '/agent/peer/relay', {
    peerToken: frontTok, topic: 'input', payload: { text: '帮我把这段加到笔记' },
  });
  eq(relay.code, 200, 'relay 200');
  ok(!!relay.body.data.id, 'relay 返回消息 id');
  ok(relay.body.data.delivered >= 3, '广播送达数 ≥3');

  const pullPlug = await call('GET', '/agent/peer/pull?peerToken=' + tok2);
  eq(pullPlug.code, 200, '插件 pull 200');
  const got = pullPlug.body.data.msgs.find((m) => m.topic === 'input');
  ok(!!got, '★插件拉到了前端输入的消息（这就是"一方输入其他方都能用"）');
  eq(got.payload.text, '帮我把这段加到笔记', 'payload 原样送达');
  eq(got.fromName, '我的手机', '带来源名（UI 可直接显示谁发的）');

  const pullSelf = await call('GET', '/agent/peer/pull?peerToken=' + frontTok);
  ok(!pullSelf.body.data.msgs.some((m) => m.payload && m.payload.text === '帮我把这段加到笔记'),
    '★自己发的默认不拉回来（避免前端把自己的输入再吃一遍）');
  const pullSelfInc = await call('GET', '/agent/peer/pull?peerToken=' + frontTok + '&includeSelf=1');
  ok(pullSelfInc.body.data.msgs.some((m) => m.payload && m.payload.text === '帮我把这段加到笔记'),
    'includeSelf=1 时才回放自己发的');

  // 定向：只给插件的消息，前端拉不到
  await call('POST', '/agent/peer/relay', { peerToken: frontTok, to: plugIid, topic: 'cmd', payload: { op: 'pause' } });
  const pullFront2 = await call('GET', '/agent/peer/pull?peerToken=' + frontTok + '&topic=cmd');
  eq(pullFront2.body.data.msgs.length, 0, '★定向消息不会串给别的端');
  const pullPlug2 = await call('GET', '/agent/peer/pull?peerToken=' + tok2 + '&topic=cmd');
  eq(pullPlug2.body.data.msgs.length, 1, '定向消息只给目标端');

  // 增量拉取（cursor）
  const all1 = await call('GET', '/agent/peer/pull?peerToken=' + tok2);
  const cur = all1.body.data.cursor;
  ok(/^pm\d+$/.test(cur), 'cursor 是消息 id 形态');
  await call('POST', '/agent/peer/relay', { peerToken: frontTok, topic: 'input', payload: { text: 'B' } });
  const incr = await call('GET', '/agent/peer/pull?peerToken=' + tok2 + '&since=' + cur);
  eq(incr.body.data.msgs.length, 1, 'since=cursor 只回增量');
  eq(incr.body.data.msgs[0].payload.text, 'B', '增量内容正确');

  const sinceTs = await call('GET', '/agent/peer/pull?peerToken=' + tok2 + '&since=' + Date.now());
  eq(sinceTs.body.data.msgs.length, 0, 'since=未来时间戳 → 空');
  const badSince = await call('GET', '/agent/peer/pull?peerToken=' + tok2 + '&since=garbage');
  eq(badSince.code, 200, '非法 since 不炸（回落为 0 → 全量）');

  // ── invoke ──
  console.log('\n8) /agent/peer/invoke 跨端调用');
  const noTo = await call('POST', '/agent/peer/invoke', { peerToken: frontTok, tool: 'x' });
  eq(noTo.code, 400, '缺 to → 400');
  const offIid = await call('POST', '/agent/peer/invoke', { peerToken: frontTok, to: 'nope', tool: 'x' });
  eq(offIid.code, 200, 'PEER_OFFLINE 走 200 信封');
  eq(offIid.body.error.code, 'PEER_OFFLINE', '★目标端不在线 → PEER_OFFLINE（不是 500）');

  // 真实转发：起一个本地假插件 HTTP 服务
  const http = require('http');
  const plugSrv = http.createServer((rq, rs) => {
    let b = '';
    rq.on('data', (c) => { b += c; });
    rq.on('end', () => {
      const j = (() => { try { return JSON.parse(b || '{}'); } catch (_) { return {}; } })();
      rs.writeHead(200, { 'Content-Type': 'application/json' });
      rs.end(JSON.stringify({ ok: true, data: { echoed: j.tool, from: j.from, args: j.args } }));
    });
  });
  await new Promise((r) => plugSrv.listen(0, '127.0.0.1', r));
  const plugPort = plugSrv.address().port;
  // 让插件把 url 改成这个真实端口
  await call('POST', '/agent/peer/beat', { peerToken: tok2, url: 'http://127.0.0.1:' + plugPort });
  const inv = await call('POST', '/agent/peer/invoke', {
    peerToken: frontTok, to: plugIid, tool: 'dl.add', args: { magnet: 'magnet:?xt=urn:btih:abc' },
  });
  eq(inv.code, 200, 'invoke 200');
  eq(inv.body.data.result.echoed, 'dl.add', '★前端调用插件成功（工具名原样送达）');
  eq(inv.body.data.result.from, frontIid, '插件看到 from = 调用方 iid（知道是谁派的活）');
  eq(inv.body.data.result.args.magnet, 'magnet:?xt=urn:btih:abc', 'args 原样送达');
  ok(inv.body.data.via.includes('127.0.0.1:' + plugPort), '回传 via（走了哪条路，便于诊断）');

  // 插件返回错误 → 视为失败
  const plugSrv2 = http.createServer((rq, rs) => {
    let b = ''; rq.on('data', (c) => { b += c; });
    rq.on('end', () => { rs.writeHead(200, { 'Content-Type': 'application/json' }); rs.end(JSON.stringify({ ok: false, error: { message: '插件内部错误' } })); });
  });
  await new Promise((r) => plugSrv2.listen(0, '127.0.0.1', r));
  await call('POST', '/agent/peer/beat', { peerToken: tok2, url: 'http://127.0.0.1:' + plugSrv2.address().port });
  const inv2 = await call('POST', '/agent/peer/invoke', { peerToken: frontTok, to: plugIid, tool: 'dl.add' });
  eq(inv2.body.error.code, 'INVOKE_FAILED', '★插件返回 ok:false → INVOKE_FAILED，不会假装成功');
  ok(String(inv2.body.error.message).includes('插件内部错误'), '错误信息透传（含插件自报原因）');
  plugSrv.close(); plugSrv2.close();

  // ── 密钥统一（D5）──
  console.log('\n9) /agent/peer/secrets 密钥统一');
  const empty = await call('GET', '/agent/peer/secrets', undefined, { 'x-th-peer': frontTok });
  eq(empty.code, 200, 'secrets GET 200');
  eq(empty.body.data.count, 0, '初始 0 条');

  // 前端写入
  const w1 = await call('POST', '/agent/peer/secrets', {
    peerToken: frontTok, set: { 'openai.key': 'sk-front-1', 'tts.voice': 'zh-CN-Yunxi' },
  });
  eq(w1.code, 200, '写入 200');
  eq(w1.body.data.changed, 2, '写入 2 条');
  eq(w1.body.data.count, 2, '总数 2');

  // 插件读 —— 这就是"只要一端有，就统一到所有端"
  const r1 = await call('GET', '/agent/peer/secrets', undefined, { 'x-th-peer': tok2 });
  eq(r1.body.data.secrets['openai.key'].value, 'sk-front-1', '★插件读到前端写入的密钥');
  eq(r1.body.data.secrets['openai.key'].rev, 1, 'rev 从 1 起');
  eq(r1.body.data.secrets['openai.key'].from, frontIid, '记录是哪个端写的');
  ok(r1.body.data.updatedAt > 0, 'updatedAt 供快速判"要不要拉"');

  // 插件覆盖 → rev 递增
  const w2 = await call('POST', '/agent/peer/secrets', { peerToken: tok2, set: { 'openai.key': 'sk-plug-2' } });
  eq(w2.body.data.changed, 1, '覆盖 1 条');
  const r2 = await call('GET', '/agent/peer/secrets', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  eq(r2.body.data.secrets['openai.key'].value, 'sk-plug-2', '★后写的生效（插件覆盖前端）');
  eq(r2.body.data.secrets['openai.key'].rev, 2, 'rev 递增到 2');

  // ifRev 冲突保护
  const w3 = await call('POST', '/agent/peer/secrets', {
    peerToken: frontTok, set: { 'openai.key': 'sk-stale' }, ifRev: { 'openai.key': 1 },
  });
  eq(w3.body.data.changed, 0, '★ifRev 过期 → 不覆盖（防旧端把新值顶掉）');
  eq(w3.body.data.conflicted.length, 1, '冲突被报出');
  eq(w3.body.data.conflicted[0].mine, 2, '冲突回报当前 rev=2');
  const r3 = await call('GET', '/agent/peer/secrets', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  eq(r3.body.data.secrets['openai.key'].value, 'sk-plug-2', '冲突时值不变');

  // 正常 ifRev 可写
  const w4 = await call('POST', '/agent/peer/secrets', {
    peerToken: frontTok, set: { 'openai.key': 'sk-front-3' }, ifRev: { 'openai.key': 2 },
  });
  eq(w4.body.data.changed, 1, 'ifRev 匹配 → 允许写');

  // 删除
  const w5 = await call('POST', '/agent/peer/secrets', { peerToken: frontTok, del: ['tts.voice'] });
  eq(w5.body.data.changed, 1, '删除 1 条');
  eq(w5.body.data.count, 1, '剩余 1 条（未删的保留）');

  // 非法输入不炸
  const wBad = await call('POST', '/agent/peer/secrets', { peerToken: frontTok, set: { x: null, y: undefined } });
  eq(wBad.code, 200, 'set 值为 null/undefined → 跳过不炸');
  const wBad2 = await call('POST', '/agent/peer/secrets', { peerToken: frontTok, del: 'not-array' });
  eq(wBad2.code, 200, 'del 非数组 → 忽略不炸');
  ok(fs.existsSync(path.join(TMP, 'agent-secrets.json')), '密钥库已落盘 agent-secrets.json');

  // ── 账号管理 ──
  console.log('\n10) /agent/peer/accounts 账号管理');
  const accByPlug = await call('GET', '/agent/peer/accounts', undefined, { 'x-th-peer': tok2 });
  // tok2 是用 admin/123456 join 的插件 → account=admin → 属于管理员端，可以读。
  // （非管理员的 403 由第 11 节 subAcc 覆盖）
  eq(accByPlug.code, 200, 'admin 账号的端可读账号列表');
  const accByKey = await call('GET', '/agent/peer/accounts', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  eq(accByKey.code, 200, '后端密钥可读');
  const accList = accByKey.body.data.accounts;
  ok(accList.some((a) => a.account === 'admin' && a.role === 'admin'), '列出 admin');
  ok(!JSON.stringify(accList).includes('pass'), '★账号列表不含口令哈希');

  const mk = await call('POST', '/agent/peer/accounts', { account: 'family', password: 'abcd1234' }, { 'x-th-token': 'thsec_TESTKEY' });
  eq(mk.code, 200, '建账号 200');
  eq(mk.body.data.created, true, 'created=true');
  const shortPass = await call('POST', '/agent/peer/accounts', { account: 'x', password: '12' }, { 'x-th-token': 'thsec_TESTKEY' });
  eq(shortPass.code, 400, '口令 <4 位 → 400');
  const shaForm = await call('POST', '/agent/peer/accounts', {
    account: 'shaUser', password: 'sha256:' + require('crypto').createHash('sha256').update('pw123456').digest('hex'),
  }, { 'x-th-token': 'thsec_TESTKEY' });
  eq(shaForm.code, 200, '支持 sha256: 形式提交（插件不落明文）');
  const shaLogin = await call('POST', '/agent/peer/join', { kind: 'plug', account: 'shaUser', password: 'pw123456' });
  eq(shaLogin.code, 200, '★sha 形式建的账号可用明文口令登录');
  const newLogin = await call('POST', '/agent/peer/join', { kind: 'plug', account: 'family', password: 'abcd1234' });
  eq(newLogin.code, 200, '★新建账号可登录（插件只需登录账号即可连接）');

  // ── 子账号登录后能干什么 ──
  console.log('\n11) 子账号权限');
  const subTok = newLogin.body.data.peerToken;
  const subList = await call('GET', '/agent/peer/list', undefined, { 'x-th-peer': subTok });
  eq(subList.code, 200, '子账号可读端列表');
  const subSec = await call('POST', '/agent/peer/secrets', { peerToken: subTok, set: { 'k': 'v' } });
  eq(subSec.code, 200, '子账号可同步密钥（同一家庭的端之间互通）');
  const subAcc = await call('GET', '/agent/peer/accounts', undefined, { 'x-th-peer': subTok });
  eq(subAcc.code, 403, '★子账号不能改账号');

  // ── leave ──
  console.log('\n12) /agent/peer/leave 下线');
  const leave = await call('POST', '/agent/peer/leave', { peerToken: subTok });
  eq(leave.body.data.left, true, 'leave 成功');
  const afterLeave = await call('GET', '/agent/peer/list', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  ok(!afterLeave.body.data.peers.some((p) => p.iid === newLogin.body.data.iid), '★下线后不再出现在在线列表');
  ok(afterLeave.body.data.all.some((p) => p.iid === newLogin.body.data.iid) === false, '下线即从登记表移除');

  // ── 在线窗口 ──
  console.log('\n13) 在线判定窗口(45s)');
  eq(hub.isOnline({ lastSeen: Date.now() }), true, '刚心跳 → 在线');
  eq(hub.isOnline({ lastSeen: Date.now() - 44000 }), true, '44s 前 → 仍在线(容 3 次丢包)');
  eq(hub.isOnline({ lastSeen: Date.now() - 46000 }), false, '★46s 前 → 离线');

  // ── diag ──
  console.log('\n14) /agent/peer/diag 体检');
  const diag = await call('GET', '/agent/peer/diag', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  eq(diag.code, 200, 'diag 200');
  eq(diag.body.data.protocol, 'PH/1', 'protocol=PH/1');
  ok(typeof diag.body.data.hub.uptime === 'number', '有 uptime');
  ok(Array.isArray(diag.body.data.peers), 'peers 数组');
  ok(diag.body.data.peers.length >= 3, '能看到各端');
  ok(Array.isArray(diag.body.data.hints) && diag.body.data.hints.length >= 1,
    '★hints 给出即时判定建议（"只有后端自己在线"等）');
  ok(diag.body.data.peers.some((p) => p.kind === 'plug') && diag.body.data.peers.some((p) => p.kind === 'front'),
    '前端与插件都在 peers 里');

  // ── 404 兜底 ──
  console.log('\n15) 未实现端点');
  const nf = await call('GET', '/agent/peer/nope', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  eq(nf.code, 404, '未知 /agent/peer/* → 404');
  eq(nf.body.error.code, 'NOT_FOUND', '错误码 NOT_FOUND');

  // ── 上限保护 ──
  console.log('\n16) 容量与清理');
  hub._test.reset();
  hub.init({ DATA: TMP, SECRET: 'thsec_TESTKEY' });
  for (let i = 0; i < 5; i++) hub._test.join({ kind: 'plug', account: 'admin', password: '123456', iid: 'p' + i, name: 'P' + i });
  eq(hub._test.list().filter((p) => p.kind === 'plug').length, 5, '批量登记 5 个插件');
  hub._test.setSecrets({ a: '1', b: '2' });
  eq(Object.keys(hub._test.getSecrets()).length, 2, 'setSecrets 测试钩子可用');
  eq(hub._test.getSecrets().a.rev, 1, '测试钩子 rev 从 1 起');

  // ── 局域网 UDP 发现：发现 ≠ 接入 ──
  console.log('\n17) 局域网 UDP 发现（发现 ≠ 接入）');
  hub._test.reset();
  hub.init({ DATA: TMP, SECRET: 'thsec_TESTKEY' });
  const tokA = (await call('POST', '/agent/peer/join',
    { kind: 'front', account: 'admin', password: '123456', name: '测试前端' })).body.data.peerToken;
  ok(/^[0-9a-f]{40}$/.test(tokA), '拿到请求方 token');

  const d1 = hub.discover({ port: 8801, iid: 'LAN-PLUG-1', caps: ['download'], name: '局域网插件', addr: '192.168.1.44' });
  ok(!!d1, 'discover 返回记录');
  const listed = hub._test.list().find((x) => x.iid === 'LAN-PLUG-1');
  ok(!!listed, '发现的插件出现在列表（"插上就能被后端发现"）');
  eq(listed.online, false, '★★发现的端 online=false —— 发现不等于在线');
  eq(listed.discovered, true, 'discovered=true（UI 显示"待登录"而不是"离线"）');
  eq(listed.url, 'http://192.168.1.44:8801', 'url 由 UDP 来源地址 + 广播端口拼出');
  eq(listed.name, '局域网插件', '名字被记录');
  eq(listed.caps.join(','), 'download', 'caps 被记录（UI 能看到它能干什么）');
  eq(listed.direct.length, 1, 'direct 带出 url（前端离线时仍可直连）');
  eq(listed.account, '', '没有账号 —— 因为没有登录');
  eq(listed.tools.length, 0, '没有工具 —— UDP 广播只报 caps，工具要登录后才拉得到');
  ok(hub.isJoined({ tokenHash: '' }) === false, 'isJoined: 无 token → false');
  ok(hub.isJoined({ tokenHash: 'x' }) === true, 'isJoined: 有 token → true');
  ok(hub.isJoined({ vip: true }) === true, '★isJoined: 中枢自身（vip）视为已接入');

  const invNL = await call('POST', '/agent/peer/invoke', { peerToken: tokA, to: 'LAN-PLUG-1', tool: 'dl.add' });
  eq(invNL.body.error.code, 'PEER_NOT_LOGGED_IN', '★★未登录的发现端**不能被调用**（否则 UDP 无鉴权 = 免登录入口）');
  ok(String(invNL.body.error.message).includes('还没登录账号'), '错误信息指导用户去登录');

  const listWithPending = await call('GET', '/agent/peer/list', undefined, { 'x-th-peer': tokA });
  const pend = listWithPending.body.data.pending;
  ok(Array.isArray(pend) && pend.some((p) => p.iid === 'LAN-PLUG-1'), '★list 的 pending 里带出待登录端（UI 据此提示）');
  ok(!listWithPending.body.data.peers.some((p) => p.iid === 'LAN-PLUG-1'), 'pending 端不出现在 peers（peers 只含已接入且在线）');

  const diagD = await call('GET', '/agent/peer/diag', undefined, { 'x-th-token': 'thsec_TESTKEY' });
  ok(diagD.body.data.hints.some((h) => h.includes('还没登录账号')), '★diag 主动提示"有端还没登录账号"');

  const j1 = hub._test.join({
    kind: 'plug', iid: 'LAN-PLUG-1', account: 'admin', password: '123456',
    url: 'http://192.168.1.44:8801', tools: ['dl.add'], caps: ['download'], name: '局域网插件',
  });
  eq(j1.ok, true, '★发现的插件用账号登录 → 成功（"登录对应的账号之后就可以连接"）');
  const after = hub._test.list().find((x) => x.iid === 'LAN-PLUG-1');
  eq(after.online, true, '★登录后 online=true');
  eq(after.discovered, false, 'discovered 标记清除');
  eq(after.account, 'admin', '记录了登录用的账号');
  eq(after.tools.length, 1, '登录后拿到工具清单');

  // IPv6 来源地址的拼法
  hub.discover({ port: 9000, iid: 'LAN6', addr: 'fe80::aa:bb' });
  eq(hub._test.list().find((x) => x.iid === 'LAN6').url, 'http://[fe80::aa:bb]:9000',
    '★IPv6 来源要加方括号（否则拼出的 URL 无法解析）');
  hub.discover({ port: 9000, iid: 'LAN4', addr: '::ffff:192.168.1.7' });
  eq(hub._test.list().find((x) => x.iid === 'LAN4').url, 'http://192.168.1.7:9000',
    '★IPv4-mapped IPv6 前缀要剥掉（NAT/双栈环境常见）');

  // 无效输入
  eq(hub.discover({ port: 0, iid: 'x', addr: '1.2.3.4' }), null, '端口 0 → 忽略');
  eq(hub.discover({ port: 80, iid: '', addr: '1.2.3.4' }), null, '空 iid → 忽略');
  eq(hub.discover({ port: 80, iid: 'local-back', addr: '1.2.3.4' }), null, '★拒绝发现 local-back（防伪造中枢）');
  eq(hub.discover({ port: 80, iid: 'y', addr: '' }), null, '空 addr → 忽略');

  // 已登录端的地址不被 UDP 覆盖
  hub._test.join({ kind: 'plug', iid: 'KEEPME', account: 'admin', password: '123456', url: 'http://192.168.1.99:1' });
  hub.discover({ port: 9999, iid: 'KEEPME', addr: '10.0.0.1' });
  eq(hub._test.list().find((x) => x.iid === 'KEEPME').url, 'http://192.168.1.99:1',
    '★已登录端的地址不被 UDP 来源覆盖（防被局域网里伪造的广播顶掉真实地址）');
  eq(hub._test.list().find((x) => x.iid === 'KEEPME').online, true, '已登录端仍在线');

  console.log('\n────────────────────────────────────────');
  console.log('PASS ' + pass + '   FAIL ' + fail);
  if (fail) { console.log('\n失败项:'); fails.forEach((f) => console.log('  · ' + f)); }
  else console.log('\n✅ 全部通过');
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) {}
  process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error('自测崩了:', e); try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) {} process.exit(2); });
