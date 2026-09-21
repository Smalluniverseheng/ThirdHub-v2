// ═══════════════════════════════════════════════════════════════════════════
// 插件侧「真链路」端到端自测 —— 不是 mock，是真的 HTTP。
//
// 拉起的东西：
//   · 真 `server/peer-hub.js`（挂在一个薄 http 壳上，模拟 index.js 的挂载方式）
//   · 真 `plugins/th-plugin.js` 跑一个真插件实例
// 然后走完整生命周期：探针 → join（账号口令换 peerToken）→ 出现在端列表 →
//   被 invoke → 执行令牌闸门 → 密钥统一（双向）→ 消息中继 → dispose → 离线。
//
// 为什么必须有这一层：后端自测（selftest-peer-hub）是**进程内 mock req/res**，
// 它证明不了"两个真进程真的能对上话"；契约在真实 socket 上漂移过一次
// （probe 打 /v1/meta 而该端点根本不存在），mock 层完全看不见。
//
// 跑法：node plugins/selftest-plugin-e2e.js
// ═══════════════════════════════════════════════════════════════════════════
'use strict';
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

// ★ 必须"先改 HOME、再 require 插件 SDK"：STATE_DIR 是在模块加载时算出来的常量，
//   晚一步就写到用户真实的 ~/.th-plugin 里去了（会污染本机、且测试互相串状态）。
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'thplug-e2e-'));
process.env.USERPROFILE = TMP;
process.env.HOME = TMP;

const peerHub = require('../server/peer-hub');
const { THPlugin, request } = require('./th-plugin');

let pass = 0, fail = 0;
const fails = [];
function ok(c, m) { if (c) { pass++; console.log('  ✓ ' + m); } else { fail++; fails.push(m); console.log('  ✗ ' + m); } }
function eq(a, b, m) { ok(a === b, m + '（实际 ' + JSON.stringify(a) + '）'); }

/** 找一块空闲端口（给子进程插件用）。listen(0) 拿到后立刻释放，够用。 */
function freePort() {
  return new Promise((resolve) => {
    const s = http.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

const SECRET = 'thsec_E2E';

async function main() {
  // ─────────────────────────────────────────────────────────────────────
  // 0) 起「真后端」：真 peer-hub 代码 + 薄 http 壳
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n0) 起真后端（真 peer-hub 代码）');
  const reg = peerHub.init({ DATA: TMP, SECRET });
  ok(!!reg, 'peer-hub init 成功');
  ok(fs.existsSync(path.join(TMP, 'agent-peers.json')), '注册表落盘');

  const hubSrv = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', async () => {
      let u;
      try { u = new URL(req.url, 'http://localhost'); } catch (_) { res.writeHead(400); return res.end('{}'); }
      let hit = false;
      try { hit = await peerHub.handle(req, res, body, u); } catch (e) {
        if (!res.headersSent) { res.writeHead(500, { 'Content-Type': 'application/json' }); }
        return res.end(JSON.stringify({ ok: false, error: { code: 'HUB_CRASH', message: String(e && e.message) } }));
      }
      if (!hit && !res.writableEnded) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: { code: 'NOT_FOUND', message: u.pathname } }));
      }
    });
  });
  await new Promise((r) => hubSrv.listen(0, '127.0.0.1', r));
  const hubPort = hubSrv.address().port;
  const HUB = 'http://127.0.0.1:' + hubPort;
  ok(hubPort > 0, '后端监听 ' + HUB);

  // 后端密钥直连（模拟管理员/已登录端视角）。
  // ★ peer-hub 取 token 的顺序是 body.peerToken → ?peerToken= → 头部，三者任一均可。
  const hubReq = (method, p, body, ms) => request(method, HUB + p, body, ms || 8000);
  const hubPost = (p, body) => hubReq('POST', p, Object.assign({ peerToken: SECRET }, body), 15000);
  const hubGet = (p, ms) => hubReq('GET', p + (p.indexOf('?') >= 0 ? '&' : '?') + 'peerToken=' + SECRET, undefined, ms || 8000);

  // ─────────────────────────────────────────────────────────────────────
  // 1) ★身份探针：插件必须先能"认出"这台是 ThirdHub 后端
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n1) 匿名身份探针 /agent/peer/ping');
  const ping = await hubReq('GET', '/agent/peer/ping');
  eq(ping.code, 200, '★ping 无凭据返回 200（插件扫描靠它，401 就永远找不到后端）');
  eq(ping.json && ping.json.data && ping.json.data.object, 'peer-hub', 'ping 自证 object=peer-hub');
  // 探针也不能白送情报
  ok(ping.json.data.peers === undefined, '★ping 不含端列表（匿名端点不得泄露端网）');

  // 对比：插件上一版探的 /v1/meta 在这个壳上根本不存在
  const ghost = await hubReq('GET', '/v1/meta');
  eq(ghost.code, 404, '★/v1/meta 不存在 —— 这就是上一版插件永远找不到后端的原因');

  // ─────────────────────────────────────────────────────────────────────
  // 2) 起一个真插件实例
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n2) 起真插件（THPlugin.run）');
  const gotMsgs = [];
  let tickCount = 0;
  const ctx = await THPlugin.run({
    name: '下载插件', iid: 'e2e-plug', hub: HUB,
    account: 'admin', password: '123456',
    port: 0, advertiseHost: '127.0.0.1',
    caps: ['download'], version: '9.9.9', quiet: true,
  }, async (c) => {
    c.tool('dl.add', '加入下载任务',
      { type: 'object', properties: { magnet: { type: 'string' } } },
      async (a) => ({ added: String(a.magnet || ''), by: c.iid }));
    c.on('msg', (m) => gotMsgs.push(m));
    // ★ 无模块级副作用：定时器必须进 effect，否则 dispose 之后还在跑
    c.effect(() => {
      const t = setInterval(() => { tickCount++; }, 30);
      return () => clearInterval(t);
    });
  });
  ok(!!ctx, '插件已启动');
  ok(ctx.port > 0, '插件监听端口 ' + ctx.port);
  eq(ctx.iid, 'e2e-plug', 'iid 用了指定值（身份可复现）');
  ok(!!ctx.token, '★已用账号口令换到 peerToken（"登录账号后才能连接"的落点）');
  ok(!!ctx._execToken, '★插件生成了执行令牌');

  const PLUG = 'http://127.0.0.1:' + ctx.port;

  // ─────────────────────────────────────────────────────────────────────
  // 3) 插件已出现在后端端列表，且能力/工具可见
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n3) 端列表可见性');
  const list = await hubGet('/agent/peer/list');
  const mine = (list.json.data.peers || []).find((x) => x.iid === 'e2e-plug');
  ok(!!mine, '插件出现在 peers 里');
  eq(mine.online, true, '插件在线');
  eq(mine.kind, 'plug', 'kind=plug');
  eq(mine.name, '下载插件', '名字同步过来了');
  ok(mine.caps.includes('download'), 'caps 含 download');
  ok(mine.tools.includes('dl.add'), '★tools 里能看到具体工具名（"这类活谁能干"靠它）');
  ok((mine.direct || []).length > 0, 'direct 里带出可达地址（无后端时直连用）');
  // 执行令牌绝不能从端列表漏出去（它只属于后端 ↔ 插件之间）
  eq(mine.execToken, undefined, '★端列表不返回执行令牌');

  // ─────────────────────────────────────────────────────────────────────
  // 4) 后端转发调用插件
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n4) 经后端 invoke 插件');
  const inv = await hubPost('/agent/peer/invoke',
    { to: 'e2e-plug', tool: 'dl.add', args: { magnet: 'magnet:?xt=urn:btih:AA' } });
  eq(inv.code, 200, 'invoke 返回 200');
  eq(inv.json.ok, true, 'invoke ok=true');
  eq(inv.json.data.result.added, 'magnet:?xt=urn:btih:AA', '★插件真的执行了并把结果带回来了');
  eq(inv.json.data.result.by, 'e2e-plug', '执行现场能看见自己是谁（上下文没丢）');
  ok(!!inv.json.data.via, 'invoke 回报了实际走通的地址（排障用）');

  // 未注册的工具 → 插件报 UNSUPPORTED，后端原样带回（不能被网络错误盖掉）
  const invBad = await hubPost('/agent/peer/invoke',
    { to: 'e2e-plug', tool: 'no.such.tool', args: {} });
  eq(invBad.json.ok, false, '未知工具 → ok=false');
  eq(invBad.json.error.code, 'INVOKE_FAILED', '错误码 INVOKE_FAILED');
  ok(invBad.json.error.message.indexOf('UNSUPPORTED') >= 0 || invBad.json.error.message.indexOf('没有工具') >= 0,
    '★保留插件自报的原因：' + invBad.json.error.message);

  // 调用一个根本没登录的端 → 必须被拦
  console.log('\n4b) 反向：未登录端不可调用');
  peerHub.discover({ port: 12345, iid: 'LAN-GHOST', caps: ['download'], name: '地里冒出来的插件', addr: '10.9.9.9' });
  const invGhost = await hubPost('/agent/peer/invoke', { to: 'LAN-GHOST', tool: 'dl.add', args: {} });
  eq(invGhost.json.ok, false, '★拒绝调用未登录端');
  eq(invGhost.json.error.code, 'PEER_NOT_LOGGED_IN', '错误码 PEER_NOT_LOGGED_IN');
  const list2 = await hubGet('/agent/peer/list');
  ok(!(list2.json.data.peers || []).some((x) => x.iid === 'LAN-GHOST'),
    '★未登录端不出现在 peers 里（只在 discovered/pending 里）');

  // ─────────────────────────────────────────────────────────────────────
  // 5) ★执行令牌闸门：绕过后端直接打插件必须被拒
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n5) 执行令牌闸门（防局域网里任何人使唤插件）');
  const raw = await request('POST', PLUG + '/peer/exec', { tool: 'dl.add', args: { magnet: 'X' } }, 8000);
  eq(raw.code, 403, '★无令牌直连插件 → 403（否则"登录才能接入"形同虚设）');
  eq(raw.json.error.code, 'UNAUTHORIZED', '错误码 UNAUTHORIZED');
  const raw2 = await request('POST', PLUG + '/peer/exec', { tool: 'dl.add', args: { magnet: 'X' } }, 8000,
    { 'X-TH-Peer-Exec': 'wrong-token' });
  eq(raw2.code, 403, '★令牌不对 → 403');
  const raw3 = await request('POST', PLUG + '/peer/exec', { tool: 'dl.add', args: { magnet: 'OK' } }, 8000,
    { 'X-TH-Peer-Exec': ctx._execToken });
  eq(raw3.code, 200, '持正确令牌 → 200');
  eq(raw3.json.data.added, 'OK', '结果正确');
  // manifest 仍应匿名可读（前端要能预览"这插件能干什么"，但不给执行）
  const man = await request('GET', PLUG + '/peer/manifest', undefined, 8000);
  eq(man.code, 200, 'manifest 匿名可读（只读元信息，不暴露执行）');
  eq(man.json.data.iid, 'e2e-plug', 'manifest 自报 iid');
  eq(man.json.data.kind, 'plug', 'manifest 自报 kind=plug');
  eq((man.json.data.tools || []).length, 1, 'manifest 列出 1 个工具');
  eq(man.json.data.tools[0].name, 'dl.add', '工具名正确');
  ok(!!man.json.data.tools[0].inputSchema, '★带 inputSchema（前端/AI 才知道怎么填参数）');

  // ─────────────────────────────────────────────────────────────────────
  // 6) ★密钥统一：一端写入，所有端都能拿到
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n6) 密钥统一（跨端）');
  const put = await hubPost('/agent/peer/secrets', { set: { 'tmdb.key': 'K-123', 'proxy.url': 'http://p:7890' } });
  eq(put.json.ok, true, '后端侧写入密钥成功');
  await ctx.syncNow();
  eq(ctx.secret('tmdb.key'), 'K-123', '★插件立刻能读到前端/后端写下的密钥');
  eq(ctx.secret('proxy.url'), 'http://p:7890', '第二条也在');
  // 反向：插件写入 → 后端可见
  await ctx.putSecret('plug.only', 'P-777');
  const after = await hubGet('/agent/peer/secrets');
  eq(after.json.data.secrets['plug.only'] && after.json.data.secrets['plug.only'].value, 'P-777',
    '★插件写入的密钥已统一到后端（从而能下发给其他所有端）');
  // 冲突保护：旧 rev 写入不得覆盖新值
  const stale = await hubPost('/agent/peer/secrets', { set: { 'tmdb.key': 'OLD' }, ifRev: { 'tmdb.key': 0 } });
  ok(!!stale.json, 'ifRev 不匹配时返回结构化结果（不静默覆盖）');
  const still = await hubGet('/agent/peer/secrets');
  eq(still.json.data.secrets['tmdb.key'].value, 'K-123', '★旧 rev 不覆盖新值（乐观并发生效）');

  // ─────────────────────────────────────────────────────────────────────
  // 7) ★一方输入、其他方都能用：中继 + 拉取
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n7) 端间消息中继');
  const sent = await ctx.relay({ text: '这段文字是在插件里打的' }, 'input');
  eq(sent, true, '插件发出中继消息成功');
  const pulled = await hubGet('/agent/peer/pull');
  const msg = (pulled.json.data.msgs || []).find((m) => m.topic === 'input');
  ok(!!msg, '后端 pull 得到了这条消息');
  eq(msg.from, 'e2e-plug', '消息带 from 身份');
  eq(msg.fromName, '下载插件', '★消息带 fromName（前端直接显示人话，不用自己查表）');
  eq(msg.payload.text, '这段文字是在插件里打的', '★payload 原样透传（插件打的字，前端能直接用）');
  ok(!!pulled.json.data.cursor, 'pull 带回 cursor（下次从那之后拉，不重复）');

  // ─────────────────────────────────────────────────────────────────────
  // 8) 心跳与在线窗口
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n8) 心跳');
  await ctx.beatNow();
  const l3 = await hubGet('/agent/peer/list');
  const m3 = (l3.json.data.peers || []).find((x) => x.iid === 'e2e-plug');
  eq(m3.online, true, '心跳后仍在线');

  // ─────────────────────────────────────────────────────────────────────
  // 9) dispose：真下线 + effect 全清
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n9) 优雅下线（dispose）');
  // ★ 断言取样点：必须"先 dispose 完成、再取基准"。
  //   dispose 内部要 await 一次网络请求（leave），这期间定时器还在跑，
  //   在 dispose 之前取基准会把那次正常的 tick 算成"关停后还在跑"（假红）。
  await ctx.dispose();
  const before = tickCount;
  await new Promise((r) => setTimeout(r, 150));
  eq(tickCount, before, '★dispose 后定时器不再跑（"无模块级副作用"的验收）');
  const l4 = await hubGet('/agent/peer/list');
  ok(!(l4.json.data.peers || []).some((x) => x.iid === 'e2e-plug'),
    '★leave 之后端列表里没有了（不会留一个假在线的幽灵）');
  const rawAfter = await request('POST', PLUG + '/peer/exec',
    { tool: 'dl.add', args: { magnet: 'X' } }, 3000, { 'X-TH-Peer-Exec': ctx._execToken });
  eq(rawAfter.ok, false, '★下线后端口已关，外部打不进来');

  // ─────────────────────────────────────────────────────────────────────
  // 10) ★真跑示例插件（子进程）—— 让模板本身不会腐烂
  //     前面都是"测试里手工构造的插件"；这一节跑的是仓库里那份 example-downloader，
  //     它一旦被改坏（忘了 effect、工具名写错、启动即崩），这里就会红。
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n10) 真跑示例插件（子进程 example-downloader）');
  const ChildHome = path.join(TMP, 'child-home');
  fs.mkdirSync(ChildHome, { recursive: true });
  const exPort = await freePort();
  const child = spawn(process.execPath, [path.join(__dirname, 'example-downloader', 'plugin.js')], {
    env: Object.assign({}, process.env, {
      TH_HUB: HUB, TH_PORT: String(exPort), TH_ADVERTISE: '127.0.0.1',
      TH_ACCOUNT: 'admin', TH_PASSWORD: '123456',
      USERPROFILE: ChildHome, HOME: ChildHome,
    }),
    stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
  });
  let childOut = '';
  child.stdout.on('data', (c) => { childOut += c; });
  child.stderr.on('data', (c) => { childOut += c; });

  const waitPeer = async (iid, want, ms) => {
    const t0 = Date.now();
    while (Date.now() - t0 < (ms || 15000)) {
      const l = await hubGet('/agent/peer/list');
      const p = (l.json && l.json.data && l.json.data.peers || []).find((x) => x.iid === iid);
      if (want ? !!p : !p) return p || true;
      await new Promise((r) => setTimeout(r, 250));
    }
    return null;
  };

  const seenEx = await waitPeer('example-downloader', true, 20000);
  ok(!!seenEx, '★示例插件自己启动并接入了后端（模板可用）。日志：\n' + childOut.trim().split('\n').slice(-6).map((s) => '     ' + s).join('\n'));
  if (!seenEx) { console.log('子进程输出：\n' + childOut); }
  eq(seenEx && seenEx.online, true, '示例插件在线');
  eq(seenEx && seenEx.name, '示例下载器', '名字来自插件自己的配置');
  ok(seenEx && seenEx.tools.includes('dl.add'), '工具 dl.add 注册成功');
  ok(seenEx && seenEx.tools.includes('dl.list'), '工具 dl.list 注册成功');
  ok(seenEx && seenEx.tools.includes('dl.cancel'), '工具 dl.cancel 注册成功');
  ok(seenEx && seenEx.caps.includes('download'), 'caps 含 download');

  // 接活
  const exAdd = await hubPost('/agent/peer/invoke',
    { to: 'example-downloader', tool: 'dl.add', args: { link: 'magnet:?xt=urn:btih:BB' } });
  eq(exAdd.json.ok, true, '★示例插件真的接到了活');
  ok(exAdd.json.data.result.id === 't1', '返回任务 id（内部状态机在跑）');
  eq(exAdd.json.data.result.saveDir, '/sdcard/Download/ThirdHub',
    '★保存目录来自统一密钥（证明密钥跨端那一刻是通的）');

  const exList = await hubPost('/agent/peer/invoke', { to: 'example-downloader', tool: 'dl.list', args: {} });
  eq(exList.json.data.result.tasks.length, 1, 'dl.list 看到 1 个任务');
  const exBad = await hubPost('/agent/peer/invoke', { to: 'example-downloader', tool: 'dl.cancel', args: { id: 'nope' } });
  eq(exBad.json.ok, false, '取消不存在的任务 → 报错（不是静默成功）');
  const exCancel = await hubPost('/agent/peer/invoke', { to: 'example-downloader', tool: 'dl.cancel', args: { id: 't1' } });
  eq(exCancel.json.data.result.state, 'canceled', '取消成功');

  // 示例插件启动时写的那条统一密钥，其他端应能读到
  const sec = await hubGet('/agent/peer/secrets');
  eq(sec.json.data.secrets['dl.saveDir'] && sec.json.data.secrets['dl.saveDir'].value, '/sdcard/Download/ThirdHub',
    '★插件写下的统一密钥已到后端（可下发给所有端）');

  // 端间消息指挥插件（拉消息走 3s 的独立节奏，不必等 15s 心跳）
  await hubPost('/agent/peer/relay', { topic: 'download', payload: { link: 'magnet:?xt=urn:btih:CC' } });
  let exList2 = null;
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 500));
    exList2 = await hubPost('/agent/peer/invoke', { to: 'example-downloader', tool: 'dl.list', args: {} });
    if (exList2.json.ok && exList2.json.data.result.tasks.length >= 2) break;
  }
  ok(exList2.json.ok && exList2.json.data.result.tasks.length >= 2,
    '★在别处发一条消息，插件就照着建了任务（一方输入、其他方都能用）');

  // 优雅下线：优先用 IPC（跨平台可靠；Windows 的 SIGTERM 是硬终止，跑不到 handler）
  if (typeof child.send === 'function') child.send('shutdown');
  else child.kill('SIGTERM');
  const gone = await waitPeer('example-downloader', false, 10000);
  ok(!!gone, '★优雅下线后，端列表里不再有假在线的幽灵');
  ok(childOut.indexOf('已下线') >= 0, '★下线走的是 dispose（打印了「已下线」），不是被硬杀');
  try { child.kill('SIGKILL'); } catch (_) {}

  // ─────────────────────────────────────────────────────────────────────
  // 11) 断线重连：后端消失
  // ─────────────────────────────────────────────────────────────────────
  console.log('\n11) 后端消失 → 转入重连');
  const ctx2 = await THPlugin.run({
    name: '临时插件', iid: 'e2e-plug2', hub: HUB, account: 'admin', password: '123456',
    port: 0, advertiseHost: '127.0.0.1', caps: ['files'], quiet: true,
  }, async (c) => { c.tool('fs.ls', '列目录', { type: 'object', properties: {} }, async () => ({ items: [] })); });
  ok(!!ctx2.token, '第二实例也已接入');
  await hubSrv.close();
  const beat = await ctx2.beatNow();
  eq(beat, false, '★后端关掉后心跳返回 false');
  ok(!ctx2._hub, '连接信息被清掉，转入重连（下次 tick 会重新扫描）');
  await ctx2.dispose();

  // ─────────────────────────────────────────────────────────────────────
  console.log('\n────────────────────────────────────────');
  console.log('PASS ' + pass + '   FAIL ' + fail);
  if (fail) { console.log('\n失败项:'); fails.forEach((f) => console.log('  · ' + f)); }
  else console.log('\n✅ 全部通过');
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) {}
  try { hubSrv.close(); } catch (_) {}
  process.exit(fail ? 1 : 0);
}

main().catch((e) => {
  console.error('自测崩了:', e);
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) {}
  process.exit(2);
});
