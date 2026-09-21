// ═══════════════════════════════════════════════════════════════════════════
// PH/1 端间互通内核自检（纯 Dart，不需要 flutter_tester）
//
// 用法: dart --disable-dart-dev --packages=.dart_tool/package_config.json \
//            tool/peer_hub_selfcheck.dart
//
// 为什么需要它：peer_hub_logic.dart 决定"这活该谁干、怎么走"和"谁的密钥更新"。
// 它错了的表现是"插件明明在线却调不到""密钥被旧端顶掉"—— 这两类问题在手机上
// 只能看到一个模糊的失败提示。所以把判定矩阵全部在纯 Dart VM 里跑一遍，
// 特别是**反向用例**（后端离线时必须直连、rev 小者不许覆盖、自己发的不该回收）。
// ═══════════════════════════════════════════════════════════════════════════
import 'package:thirdhub_app/core/peer_hub_logic.dart';

int _pass = 0;
int _fail = 0;
final List<String> _fails = [];

void _ok(bool cond, String name, [String extra = '']) {
  if (cond) {
    _pass++;
  } else {
    _fail++;
    _fails.add(name + (extra.isEmpty ? '' : ' — $extra'));
  }
}

void _eq(dynamic a, dynamic b, String name) => _ok(a == b, name, 'got=$a want=$b');

void _sec(String s) => print('\n$s');

// ─── 测试数据 ───
const int T = 1700000000000; // 固定基准时刻，lastSeen 相对它算

PeerInfo _hub({bool online = true, List<String>? caps}) => PeerInfo(
      iid: kHubIid,
      kind: PeerKind.back,
      name: 'ThirdHub 后端',
      caps: caps ?? const ['hub', 'relay', 'secrets', 'files', 'agent', 'mcp'],
      online: online,
      lastSeen: T,
      vip: true,
    );

PeerInfo _plug({
  String iid = 'plug1',
  String name = '下载插件',
  String url = 'http://192.168.1.30:8801',
  String ipv6 = '',
  String tunnel = '',
  List<String> caps = const ['tool', 'download'],
  List<String> tools = const ['dl.add'],
  bool online = true,
  int lastSeen = T,
}) =>
    PeerInfo(
      iid: iid,
      kind: PeerKind.plug,
      name: name,
      url: url,
      ipv6: ipv6,
      tunnel: tunnel,
      caps: caps,
      tools: tools,
      online: online,
      lastSeen: lastSeen,
    );

PeerInfo _front({String iid = 'front1', bool online = true, int lastSeen = T}) => PeerInfo(
      iid: iid,
      kind: PeerKind.front,
      name: '我的手机',
      caps: const ['front'],
      online: online,
      lastSeen: lastSeen,
    );

void main() {
  // ═══ 1. PeerKind ═══
  _sec('1) kind 映射');
  _eq(peerKindOf('front').name, 'front', "peerKindOf('front')");
  _eq(peerKindOf('plug').name, 'plug', "peerKindOf('plug')");
  _eq(peerKindOf('dsa').name, 'dsa', "peerKindOf('dsa')");
  _eq(peerKindOf('back').name, 'back', "peerKindOf('back')");
  _eq(peerKindOf('').name, 'unknown', '空串 → unknown');
  _eq(peerKindOf('FRONT').name, 'unknown', '★大小写敏感（协议里是小写，别自作聪明归一）');
  _eq(peerKindOf(null.toString()).name, 'unknown', 'toString 后仍不认识的 → unknown');
  _eq(peerKindName(PeerKind.plug), '插件', '中文名 插件');
  _eq(peerKindName(PeerKind.back), '后端', '中文名 后端');
  _eq(peerKindName(PeerKind.unknown), '未知', '中文名 未知');

  // ═══ 2. PeerInfo 解析与容错 ═══
  _sec('2) PeerInfo.fromJson 容错');
  final p1 = PeerInfo.fromJson({
    'iid': 'p1', 'kind': 'plug', 'name': 'A', 'url': 'http://1.2.3.4:1',
    'ipv6': '[fe80::1]:1', 'tunnel': 'https://t.example.com',
    'caps': ['a', 'b'], 'tools': ['t1', 't2'], 'account': 'admin',
    'online': true, 'firstSeen': 1, 'lastSeen': 2, 'vip': true,
  });
  _eq(p1.iid, 'p1', 'iid');
  _eq(p1.kind, PeerKind.plug, 'kind');
  _eq(p1.caps.length, 2, 'caps');
  _eq(p1.tools.length, 2, 'tools');
  _eq(p1.online, true, 'online');
  _eq(p1.vip, true, 'vip');
  _eq(p1.routes.length, 3, '三条路由');

  final p2 = PeerInfo.fromJson({});
  _eq(p2.iid, '', '空 json → iid 空串（不崩）');
  _eq(p2.kind, PeerKind.unknown, '空 json → kind=unknown');
  _eq(p2.caps.length, 0, '空 json → caps 空');
  _eq(p2.routes.length, 0, '空 json → routes 空');

  final p3 = PeerInfo.fromJson({'caps': 'not-a-list', 'tools': null, 'lastSeen': 'abc'});
  _eq(p3.caps.length, 0, '★caps 非数组 → 空（不崩）');
  _eq(p3.tools.length, 0, '★tools 为 null → 空');
  _eq(p3.lastSeen, 0, '★lastSeen 非数字 → 0');

  final p4 = PeerInfo.fromJson({'caps': ['a', '', 'b']});
  _eq(p4.caps.length, 2, '★caps 里的空串被剔掉（空能力会污染 withCap 判定）');
  _eq(p4.caps.join(','), 'a,b', '保留顺序');

  _eq(p1.toJson()['iid'], 'p1', 'toJson 往返 iid');
  _eq(p1.toJson()['kind'], 'plug', 'toJson kind 是字符串');
  _ok(p3.toJson()['kind'] == '', '★unknown 的 kind 序列化成空串（不写 "unknown" 免得后端看不懂）');
  _eq(PeerInfo.fromJson(p1.toJson()).iid, 'p1', 'toJson→fromJson 往返');

  // ═══ 3. routes 优先级与 stamped ═══
  _sec('3) routes 优先级 / stamped');
  final p5 = PeerInfo(iid: 'x', kind: PeerKind.plug, url: 'U', tunnel: 'T', ipv6: 'I');
  _eq(p5.routes.join('|'), 'U|T|I', '★routes 顺序 = 局域网→穿透→IPv6');
  final p6 = PeerInfo(iid: 'x', kind: PeerKind.plug, tunnel: 'T', ipv6: 'I');
  _eq(p6.routes.join('|'), 'T|I', '无 url 时从 tunnel 起');
  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug).routes.length, 0, '都空 → 空列表');
  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug, url: '   ', tunnel: 'T').routes.join('|'), 'T',
      '★空白串不算路由（否则会拼出 "http://   /peer/exec"）');

  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug, lastSeen: T).stamped(T).online, true, '刚心跳 → 在线');
  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug, lastSeen: T - 44000).stamped(T).online, true,
      '44s → 仍在线（与后端 45s 窗口一致）');
  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug, lastSeen: T - 46000).stamped(T).online, false,
      '★46s → 离线');
  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug, lastSeen: T, online: true).stamped(T + 100000).online,
      false, '★后端说在线但时间戳已过期 → 本地判离线（离线直连时必须自己判，不能信缓存）');
  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug, lastSeen: T, online: false).stamped(T).online, true,
      '★反向：后端说离线但时间戳很新 → 本地判在线（心跳刚补上，后端缓存还没刷）');

  _ok(p5.can('dl.add') == false, 'can 查工具');
  _ok(_plug().can('dl.add'), 'can 命中工具');
  _ok(_plug().hasCap('download'), 'hasCap 命中能力');
  _ok(!_plug().hasCap('nope'), 'hasCap 不命中');
  _ok(_hub().isHub, 'back → isHub');

  // ═══ 4. PeerRegistry ═══
  _sec('4) PeerRegistry 查询');
  final reg = PeerRegistry([_hub(), _plug(), _front(), _plug(iid: 'p2', name: 'B', online: false, lastSeen: T - 99999)]);
  _eq(reg.peers.length, 4, '总数 4');
  _eq(reg.online.length, 3, '在线 3');
  _eq(reg.offline.length, 1, '离线 1');
  _ok(reg.hub != null, 'hub 命中');
  _ok(reg.hasHub, 'hasHub');
  _eq(reg.byIid('plug1')!.name, '下载插件', 'byIid 命中');
  _eq(reg.byIid('nope'), null, 'byIid 未命中 → null');

  // ★按名字寻址：用户和 AI 记名字比记 iid 容易，但名字**不唯一**，必须不猜。
  _eq(reg.byName('下载插件')!.iid, 'plug1', 'byName 命中唯一名字');
  _eq(reg.byName('  下载插件  ')!.iid, 'plug1', 'byName 容忍首尾空白');
  _eq(reg.byName('没有这个名字'), null, 'byName 未命中 → null');
  _eq(reg.byName(''), null, 'byName 空串 → null（不能把所有端都当命中）');
  _eq(reg.byName('   '), null, 'byName 全空白 → null');
  _eq(reg.resolve('plug1')!.name, '下载插件', 'resolve 先当 iid');
  _eq(reg.resolve('下载插件')!.iid, 'plug1', 'resolve 再当名字');
  _eq(reg.resolve('nope'), null, 'resolve 都没命中 → null');
  // 重名必须拒绝猜：随便挑一个"看起来对"的端，就是把用户的活派给了错误的机器。
  final dupReg = PeerRegistry(const [
    PeerInfo(iid: 'a1', kind: PeerKind.plug, name: '下载插件', online: true),
    PeerInfo(iid: 'a2', kind: PeerKind.plug, name: '下载插件', online: true),
  ]);
  _eq(dupReg.byName('下载插件'), null, '★重名 → 拒绝猜（返回 null，要求用 iid）');
  _eq(dupReg.resolve('a1')!.iid, 'a1', '★但重名时用 iid 依然能精确命中');
  // 名字只匹配到唯一一个时，即使还有别的名字不同也要正常命中
  final mixedReg = PeerRegistry(const [
    PeerInfo(iid: 'b1', kind: PeerKind.plug, name: '下载插件', online: true),
    PeerInfo(iid: 'b2', kind: PeerKind.plug, name: '转码插件', online: true),
  ]);
  _eq(mixedReg.byName('转码插件')!.iid, 'b2', '名字各有其主时不误判为歧义');

  _eq(reg.withCap('download').length, 1, 'withCap 只数在线的（离线的 p2 不算）');
  _eq(reg.withTool('dl.add').length, 1, 'withTool');
  _eq(reg.ofKind(PeerKind.plug).length, 1, 'ofKind 只数在线');
  _eq(reg.counts[PeerKind.plug], 1, 'counts[plug]=1');
  _eq(reg.counts[PeerKind.back], 1, 'counts[back]=1');
  _eq(reg.counts[PeerKind.front], 1, 'counts[front]=1');
  _eq(reg.counts[PeerKind.dsa], null, '★没该类端 → counts 里没有该键（不是 0）');

  final emptyReg = PeerRegistry.empty;
  _eq(emptyReg.peers.length, 0, 'empty 表');
  _eq(emptyReg.hub, null, 'empty 无 hub');
  _eq(emptyReg.hasHub, false, 'empty hasHub=false');
  _eq(emptyReg.counts.length, 0, 'empty counts 空');

  // merge
  final a = PeerRegistry([_plug(iid: 'k1', name: '旧')]);
  final b = PeerRegistry([_plug(iid: 'k1', name: '新'), _plug(iid: 'k2', name: '额外的')]);
  final m = a.merge(b);
  _eq(m.peers.length, 2, 'merge 按 iid 覆盖不重复');
  _eq(m.byIid('k1')!.name, '新', '★后表覆盖前表（远端最新优先）');

  // fromJson
  final regJ = PeerRegistry.fromJson({
    'peers': [
      {'iid': 'a', 'kind': 'plug', 'online': true},
      {'iid': 'b', 'kind': 'front', 'online': true},
    ],
    'stats': {'total': 2},
  });
  _eq(regJ.peers.length, 2, 'fromJson 读 peers');
  final regJ2 = PeerRegistry.fromJson({
    'all': [
      {'iid': 'a', 'kind': 'plug', 'online': false},
    ],
  });
  _eq(regJ2.peers.length, 1, '★只有 all（全部已登记）时也认');
  _eq(PeerRegistry.fromJson({}).peers.length, 0, '空对象 → 空表');
  _eq(PeerRegistry.fromJson({'peers': 'garbage'}).peers.length, 0, 'peers 非数组 → 空表不崩');

  // ═══ 5. PeerUrl.normalize ═══
  _sec('5) PeerUrl.normalize');
  _eq(PeerUrl.normalize('http://1.2.3.4:1'), 'http://1.2.3.4:1', '已带 scheme 原样');
  _eq(PeerUrl.normalize('https://x.com'), 'https://x.com', 'https 原样');
  _eq(PeerUrl.normalize('192.168.1.5:9527'), 'http://192.168.1.5:9527', '★补 scheme (host:port)');
  _eq(PeerUrl.normalize('example.com'), 'http://example.com', '补 scheme (域名)');
  _eq(PeerUrl.normalize('example.com:8443'), 'http://example.com:8443', '域名带端口');
  _eq(PeerUrl.normalize('[fe80::1]:8801'), 'http://[fe80::1]:8801', '★IPv6 已带方括号');
  _eq(PeerUrl.normalize('fe80::1'), 'http://[fe80::1]', '★裸 IPv6 → 补方括号（否则 URL 解析必炸）');
  _eq(PeerUrl.normalize('2001:db8::1'), 'http://[2001:db8::1]', '★裸全局 IPv6');
  _eq(PeerUrl.normalize('https://x/y/'), 'https://x/y', '去尾斜杠');
  _eq(PeerUrl.normalize('http://1.2.3.4///'), 'http://1.2.3.4', '去掉多个尾斜杠');
  _eq(PeerUrl.normalize('  http://x  '), 'http://x', '去首尾空白');
  _eq(PeerUrl.normalize(''), '', '空 → 空');
  _eq(PeerUrl.normalize('   '), '', '空白 → 空');
  _eq(PeerUrl.normalize('HTTP://X'), 'HTTP://X', '大写 scheme 保留原样（已合规）');

  // ═══ 6. PeerUrl.join ═══
  _sec('6) PeerUrl.join');
  _eq(PeerUrl.join('192.168.1.5:9527', '/agent/peer/list'),
      'http://192.168.1.5:9527/agent/peer/list', 'join 补 scheme');
  _eq(PeerUrl.join('http://x/', 'peer/exec'), 'http://x/peer/exec', '★path 无前导斜杠也拼对');
  _eq(PeerUrl.join('http://x', '/peer/exec'), 'http://x/peer/exec', 'path 有斜杠');
  _eq(PeerUrl.join('', '/peer/exec'), '', '空 base → 空（调用方据此跳过该路由）');

  // ═══ 7. PeerUrl.hostOf / looksLocal ═══
  _sec('7) PeerUrl.hostOf / looksLocal');
  _eq(PeerUrl.hostOf('http://192.168.1.30:8801'), '192.168.1.30', '★hostOf 去掉端口');
  _eq(PeerUrl.hostOf('http://[::1]:1'), '::1', '★hostOf 处理 IPv6 回环（正则交替会在这里出错）');
  _eq(PeerUrl.hostOf('http://[fe80::1]:8801'), 'fe80::1', '★hostOf 处理 IPv6 link-local');
  _eq(PeerUrl.hostOf('http://[2001:db8::5]'), '2001:db8::5', '★hostOf 处理无端口 IPv6');
  _eq(PeerUrl.hostOf('https://plug.trycloudflare.com/path'), 'plug.trycloudflare.com', '★截掉路径');
  _eq(PeerUrl.hostOf('http://x/?a=1'), 'x', '★截掉 query');
  _eq(PeerUrl.hostOf('localhost:9527'), 'localhost', '未带 scheme 也能处理');
  _eq(PeerUrl.hostOf(''), '', '空 → 空');
  _eq(PeerUrl.hostOf('fe80::1'), 'fe80::1', '★裸 IPv6 也能处理');

  for (final u in ['http://127.0.0.1:1', 'http://localhost:1', 'http://[::1]:1']) {
    _ok(PeerUrl.looksLocal(u), '回环 $u');
  }
  _ok(PeerUrl.looksLocal('http://192.168.1.30:8801'), '192.168 网段');
  _ok(PeerUrl.looksLocal('http://10.0.0.5:1'), '10 网段');
  _ok(PeerUrl.looksLocal('http://172.16.0.1:1'), '172.16 网段');
  _ok(PeerUrl.looksLocal('http://172.31.255.254:1'), '172.31 网段（上界内）');
  _ok(!PeerUrl.looksLocal('http://172.15.0.1:1'), '★172.15 不在私网段（下界外）');
  _ok(!PeerUrl.looksLocal('http://172.32.0.1:1'), '★172.32 不在私网段（上界外）');
  _ok(PeerUrl.looksLocal('http://169.254.1.1:1'), '169.254 link-local');
  _ok(PeerUrl.looksLocal('http://[fe80::1]:1'), '★IPv6 link-local');
  _ok(!PeerUrl.looksLocal('http://8.8.8.8:1'), '公网 IP → false');
  _ok(!PeerUrl.looksLocal('https://plug.trycloudflare.com'), '★穿透域名 → false（要走 fallback 分支）');
  _ok(!PeerUrl.looksLocal(''), '空 → false');
  _ok(PeerUrl.looksLocal('192.168.1.5:1'), '★未带 scheme 也能判');

  // ═══ 8. PeerUrl.bestRoute ═══
  _sec('8) PeerUrl.bestRoute 选路');
  _eq(PeerUrl.bestRoute(['https://plug.tyc.com', 'http://192.168.1.30:8801']),
      'http://192.168.1.30:8801', '★局域网上线优先于穿透（局域网更快）');
  _eq(PeerUrl.bestRoute(['https://plug.tyc.com']), 'https://plug.tyc.com', '只有穿透时用穿透');
  _eq(PeerUrl.bestRoute(['http://8.8.8.8:1', 'http://9.9.9.9:2']), 'http://8.8.8.8:1',
      '都不本机也不 https → 取第一条（稳定）');
  _eq(PeerUrl.bestRoute(['', 'http://192.168.1.1:1']), 'http://192.168.1.1:1', '★空串被跳过');
  _eq(PeerUrl.bestRoute([]), '', '空列表 → 空');
  _eq(PeerUrl.bestRoute(['   ']), '', '全空白 → 空');
  _eq(PeerUrl.bestRoute(['fe80::1']), 'http://[fe80::1]', '★单条裸 IPv6 也规整');

  // ═══ 9. PeerRouter.route —— 核心判定矩阵 ═══
  _sec('9) PeerRouter.route 判定矩阵');

  // ① 本地优先
  final rLocal = PeerRouter.route(
    PeerRegistry([_hub(), _plug()]),
    cap: 'local_calc',
    offlineTools: {'local_calc'},
    nowMs: T,
  );
  _eq(rLocal!.via, PeerVia.local, '★本地能干的永远优先本地（零往返）');
  _eq(rLocal.peer, null, 'local 无目标端');
  _ok(rLocal.ok, 'local 视为成功路由');
  _ok(!rLocal.needsNetwork, 'local 不需要网络');
  _ok(rLocal.reason.contains('离线'), 'reason 说明是离线能力');

  // ② 后端在线 → hub 转发
  final rHub = PeerRouter.route(PeerRegistry([_hub(), _plug()]), cap: 'download', nowMs: T);
  _eq(rHub!.via, PeerVia.hub, '★有后端 → 由后端转发（前端不用记插件地址）');
  _eq(rHub.peer!.iid, 'plug1', '目标是被转发的插件');
  _ok(rHub.reason.contains('后端在线'), 'reason 说明走后端');
  _ok(rHub.needsNetwork, 'hub 需要网络');

  // ③ 后端离线 → direct 直连
  final rDirect = PeerRouter.route(
    PeerRegistry([_plug(url: '', tunnel: 'https://p.tyc.com')]),
    cap: 'download',
    nowMs: T,
  );
  _eq(rDirect!.via, PeerVia.direct, '★★无后端 → 直连插件（"没有后端也能用插件"的落点）');
  _eq(rDirect.peer!.iid, 'plug1', '目标插件');
  _eq(rDirect.base, 'https://p.tyc.com', '★没有局域网地址时用插件自报的穿透地址');
  _ok(rDirect.reason.contains('无后端'), 'reason 明确是无后端模式');
  _ok(rDirect.ok, '直连视为有效路由');

  // ③b 后端离线 + 只有 url → 用 url
  final rDirect2 = PeerRouter.route(PeerRegistry([_plug()]), cap: 'download', nowMs: T);
  _eq(rDirect2!.base, 'http://192.168.1.30:8801', '直连优先局域网 url');

  // ③c 后端离线 + 插件没上报地址 → 明确告知原因
  final rNoAddr = PeerRouter.route(
    PeerRegistry([_plug(url: '', ipv6: '', tunnel: '')]),
    cap: 'download',
    nowMs: T,
  );
  _eq(rNoAddr!.via, PeerVia.direct, '仍是 direct 分支');
  _eq(rNoAddr.peer, null, '没地址 → 无目标');
  _ok(!rNoAddr.ok, '★无地址 → 路由不可用（不能假装成功）');
  _ok(rNoAddr.reason.contains('没上报'), '★reason 说清是"没上报地址"，便于用户去插件侧排查：${rNoAddr.reason}');

  // ④ 后端自身能力
  final rBack = PeerRouter.route(PeerRegistry([_hub()]), cap: 'files', nowMs: T);
  _eq(rBack!.via, PeerVia.hub, '后端自带能力 → hub');
  _eq(rBack.peer!.iid, kHubIid, '目标就是后端');
  _ok(rBack.reason.contains('后端执行'), 'reason 说明由后端执行');
  final rBack2 = PeerRouter.route(PeerRegistry([_hub(caps: [])]), cap: 'hub', nowMs: T);
  _eq(rBack2!.via, PeerVia.hub, "★cap='hub' 特判：即使 caps 里没列也能命中中枢");

  // ⑤ 什么都接不了
  final rNone = PeerRouter.route(PeerRegistry([_front()]), cap: 'download', nowMs: T);
  _eq(rNone, null, '★在线端都没有该能力 → null（调用方据此回落到本地/报"暂时用不了"）');
  _eq(PeerRouter.route(PeerRegistry.empty, cap: 'download', nowMs: T), null, '空表 → null');

  // ⑥ 离线端不算
  final rOffline = PeerRouter.route(
    PeerRegistry([_plug(online: false, lastSeen: T - 99999), _plug(iid: 'p9', name: '活的')]),
    cap: 'download',
    nowMs: T,
  );
  _eq(rOffline!.peer!.iid, 'p9', '★离线的同名能力端被跳过，选了在线那个');

  // ⑦ 多端排序稳定：plug 优先，其次 lastSeen
  final rMulti = PeerRouter.route(
    PeerRegistry([
      _plug(iid: 'z-plug', name: 'z', lastSeen: T - 5000),
      _plug(iid: 'a-plug', name: 'a', lastSeen: T - 1000),
      _front(iid: 'f1'),
      PeerInfo(iid: 'dsa1', kind: PeerKind.dsa, caps: const ['download'], online: true, lastSeen: T),
    ]),
    cap: 'download',
    nowMs: T,
  );
  _eq(rMulti!.peer!.iid, 'a-plug', '★同 kind 里挑最新心跳的（不用老端）');

  final rMulti2 = PeerRouter.route(
    PeerRegistry([
      PeerInfo(iid: 'dsa9', kind: PeerKind.dsa, caps: const ['download'], online: true, lastSeen: T),
      _plug(iid: 'plug-old', lastSeen: T - 30000),
    ]),
    cap: 'download',
    nowMs: T,
  );
  _eq(rMulti2!.peer!.iid, 'plug-old', '★插件优先于 DSA（专一性更高的先上）');

  final rStable = PeerRouter.route(
    PeerRegistry([
      _plug(iid: 'b', lastSeen: T),
      _plug(iid: 'a', lastSeen: T),
    ]),
    cap: 'download',
    nowMs: T,
  );
  _eq(rStable!.peer!.iid, 'a', '★心跳相同时按 iid 排序（避免每次调用换端，插件侧状态会乱）');

  // ⑧ preferIid 点对点
  final rPrefer = PeerRouter.route(
    PeerRegistry([_hub(), _plug(iid: 'pA', name: 'A'), _plug(iid: 'pB', name: 'B')]),
    cap: 'download',
    preferIid: 'pB',
    nowMs: T,
  );
  _eq(rPrefer!.peer!.iid, 'pB', '★preferIid 明确指定就只用它（不做能力挑选）');
  _eq(rPrefer.via, PeerVia.hub, '指定 + 后端在线 → 仍走后端转发');
  final rPreferDirect = PeerRouter.route(
    PeerRegistry([_plug(iid: 'pB', name: 'B', url: '', tunnel: 'https://b.tyc.com')]),
    cap: 'download',
    preferIid: 'pB',
    nowMs: T,
  );
  _eq(rPreferDirect!.via, PeerVia.direct, '指定 + 无后端 → 直连指定端');
  _eq(rPreferDirect.base, 'https://b.tyc.com', '用指定端的穿透地址');
  final rPreferOff = PeerRouter.route(
    PeerRegistry([_plug(iid: 'pB', online: false, lastSeen: T - 99999)]),
    cap: 'download',
    preferIid: 'pB',
    nowMs: T,
  );
  _eq(rPreferOff!.ok, false, '★指定端离线 → 不可用（不偷偷换成别的端）');
  _ok(rPreferOff.reason.contains('不在线'), 'reason 说明原因');
  final rPreferBack = PeerRouter.route(PeerRegistry([_hub()]), cap: 'files', preferIid: kHubIid, nowMs: T);
  _eq(rPreferBack!.via, PeerVia.hub, '★指定后端本身时不走 direct（后端没有 peer/exec 端点）');
  _eq(rPreferBack.base, '', '走 hub 不给 base');

  // ⑨ allowLocal=false 强制走远端
  final rForce = PeerRouter.route(
    PeerRegistry([_hub(), _plug()]),
    cap: 'local_calc',
    offlineTools: {'local_calc'},
    allowLocal: false,
    nowMs: T,
  );
  _eq(rForce, null, '★allowLocal=false 时本地能力不再短路（插件若能干同一件事可接管）');

  // ⑩ localCan
  _ok(PeerRouter.localCan('local_calc', {'local_calc'}), 'localCan 命中');
  _ok(!PeerRouter.localCan('dl.add', {'local_calc'}), 'localCan 不命中');
  _ok(!PeerRouter.localCan('x', {}), '空集 → 不命中');

  // ⑫ cap 与 tool 是两套标识，都必须认
  _sec('9b) cap / tool 双标识匹配');
  _ok(PeerRouter.canTake(_plug(), 'download'), 'canTake 认 caps');
  _ok(PeerRouter.canTake(_plug(), 'dl.add'), '★canTake 也认 tools（插件通常只报 tools 不报 caps）');
  _ok(!PeerRouter.canTake(_plug(), 'nope'), 'canTake 都不命中 → false');
  _ok(!PeerRouter.canTake(PeerInfo(iid: 'e', kind: PeerKind.plug), 'x'), '空端 → false');
  final rTool = PeerRouter.route(PeerRegistry([_hub(), _plug()]), cap: 'dl.add', nowMs: T);
  _eq(rTool!.via, PeerVia.hub, '★按 tools 里的具体工具名也能路由到插件');
  _eq(rTool.peer!.iid, 'plug1', '目标正确');
  final rToolDirect = PeerRouter.route(PeerRegistry([_plug()]), cap: 'dl.add', nowMs: T);
  _eq(rToolDirect!.via, PeerVia.direct, '★无后端时按工具名直连');
  _eq(rToolDirect.base, 'http://192.168.1.30:8801', '直连地址正确');

  // ⑪ summarize
  _sec('10) PeerRouter.summarize 状态条');
  _ok(PeerRouter.summarize(PeerRegistry([_hub(), _plug(), _front()]), nowMs: T).contains('已连接'),
      '有后端 → 已连接');
  final s1 = PeerRouter.summarize(PeerRegistry([_hub(), _plug(), _front()]), nowMs: T);
  _ok(s1.contains('后端在线'), '包含 后端在线');
  _ok(s1.contains('1 个插件'), '包含插件数');
  _ok(s1.contains('1 个前端'), '包含前端数');
  _ok(!s1.contains('DSA'), '★没有 DSA 时不显示 DSA（不出现 "0 个 DSA" 噪音）');
  final s2 = PeerRouter.summarize(PeerRegistry([_plug()]), nowMs: T);
  _ok(s2.contains('无后端直连模式'), '★无后端 → 明确标注直连模式');
  final s3 = PeerRouter.summarize(PeerRegistry.empty, nowMs: T);
  _ok(s3.contains('离线模式'), '全空 → 离线模式');
  _ok(s3.contains('本机'), '离线时强调仅本机能力');
  final s4 = PeerRouter.summarize(
    PeerRegistry([
      PeerInfo(iid: 'd', kind: PeerKind.dsa, caps: const ['llm'], online: true, lastSeen: T),
    ]),
    nowMs: T,
  );
  _ok(s4.contains('1 个 DSA'), '有 DSA 时显示');

  // ═══ 11. PeerMsg ═══
  _sec('11) PeerMsg 解析');
  final msg = PeerMsg.fromJson({
    'id': 'pm42', 'at': 123, 'from': 'front1', 'fromName': '我的手机',
    'to': '', 'topic': 'input', 'payload': {'text': '把这段存笔记'},
  });
  _eq(msg.id, 'pm42', 'id');
  _eq(msg.at, 123, 'at');
  _eq(msg.fromName, '我的手机', 'fromName');
  _eq(msg.seq, 42, '★seq 从 id 解析');
  _eq(msg.text(), '把这段存笔记', 'text() 取 payload.text');
  _eq(PeerMsg.fromJson({'id': 'abc'}).seq, -1, '★非 pm 形态 → seq=-1（调用方回落到时间戳比较）');
  _eq(PeerMsg.fromJson({}).id, '', '空 json → 空 id');
  _eq(PeerMsg.fromJson({'topic': null}).topic, 'input', '★topic 缺省 input');
  _eq(PeerMsg(id: 'pm1', at: 0, from: '', payload: 'pure-string').text(), 'pure-string',
      '★payload 是字符串也能取');
  _eq(PeerMsg(id: 'pm1', at: 0, from: '', payload: {'value': 'V'}).text(), 'V', 'payload.value');
  _eq(PeerMsg(id: 'pm1', at: 0, from: '', payload: {'q': 'Q'}).text(), 'Q', 'payload.q');
  _eq(PeerMsg(id: 'pm1', at: 0, from: '', payload: {'nope': 1}).text(), '', '取不到 → 空串');
  _eq(PeerMsg(id: 'pm1', at: 0, from: '', payload: null).text(), '', 'payload null → 空串');
  _eq(PeerMsg(id: 'pm1', at: 0, from: '').text(), '', 'payload 缺省 → 空串');

  // ═══ 12. PeerInbox ═══
  _sec('12) PeerInbox 收件判定');
  final bcast = PeerMsg(id: 'pm1', at: 1, from: 'front1', topic: 'input');
  final toMe = PeerMsg(id: 'pm2', at: 2, from: 'front1', to: 'me', topic: 'cmd');
  final toOther = PeerMsg(id: 'pm3', at: 3, from: 'front1', to: 'other', topic: 'cmd');
  final fromMe = PeerMsg(id: 'pm4', at: 4, from: 'me', topic: 'input');

  _ok(PeerInbox.accept(bcast, 'me'), '广播 → 收');
  _ok(PeerInbox.accept(toMe, 'me'), '点名叫我 → 收');
  _ok(!PeerInbox.accept(toOther, 'me'), '★点名别人 → 不收（定向消息不串端）');
  _ok(!PeerInbox.accept(fromMe, 'me'), '★自己发的 → 默认不收（否则前端把自己的输入再吃一遍）');
  _ok(PeerInbox.accept(fromMe, 'me', includeSelf: true), 'includeSelf → 收自己的');
  _ok(PeerInbox.accept(bcast, ''), '★myIid 为空（尚未 join）时仍收广播');

  final all = [bcast, toMe, toOther, fromMe];
  _eq(PeerInbox.filter(all, 'me').length, 2, 'filter 默认 → 广播+点名我的');
  _eq(PeerInbox.filter(all, 'me', includeSelf: true).length, 3, 'includeSelf → 3 条');
  _eq(PeerInbox.filter(all, 'me', topic: 'cmd').length, 1, 'topic 过滤');
  _eq(PeerInbox.filter(all, 'me', topic: 'nope').length, 0, 'topic 不命中 → 空');
  _eq(PeerInbox.filter(all, 'me', cursor: 'pm1').length, 1, '★cursor=pm1 → 只回 pm1 之后的（pm2）');
  _eq(PeerInbox.filter(all, 'me', cursor: 'pm2').length, 0, 'cursor=pm2 → 无更新');
  _eq(PeerInbox.filter(all, 'me', cursor: '9999999999999').length, 0, '★cursor 是时间戳形态也能用');
  _eq(PeerInbox.filter(all, 'me', cursor: 'garbage').length, 2, '★非法 cursor → 当作从头（全量），不崩');

  _eq(PeerInbox.nextCursor(all, 'pm0'), 'pm4', '★nextCursor = 最后一条 id');
  _eq(PeerInbox.nextCursor([], 'pm7'), 'pm7', '★★空列表时**保留**原 cursor（否则每次从头拉、重复处理）');

  final dup = PeerInbox.dedupe([
    bcast,
    PeerMsg(id: 'pm1', at: 1, from: 'front1'),
    toMe,
  ]);
  _eq(dup.length, 2, '★dedupe 按 id 去重（离线期间可能重复拉到）');
  _eq(PeerInbox.dedupe([PeerMsg(id: '', at: 0, from: ''), PeerMsg(id: '', at: 0, from: '')]).length, 2,
      '★空 id 不去重（宁可重复也不丢——丢消息比重复严重）');

  // ═══ 13. SecretMerge ═══
  _sec('13) SecretMerge 密钥统一');
  final local1 = <String, dynamic>{
    'a': {'value': 'A1', 'rev': 2, 'updatedAt': 100, 'from': 'front'},
    'b': {'value': 'B1', 'rev': 1, 'updatedAt': 50, 'from': 'front'},
    'c': {'value': 'C1', 'rev': 1, 'updatedAt': 10, 'from': 'front'},
  };
  final remote1 = <String, dynamic>{
    'a': {'value': 'A1', 'rev': 2, 'updatedAt': 100, 'from': 'front'},
    'b': {'value': 'B2', 'rev': 3, 'updatedAt': 80, 'from': 'plug'},
    'd': {'value': 'D1', 'rev': 1, 'updatedAt': 20, 'from': 'plug'},
  };
  final rep1 = SecretMerge.merge(local1, remote1);
  _eq(rep1.same.join(','), 'a', 'a 双方一致 → same');
  _ok(rep1.pull.contains('b'), '★b 远端 rev 更大 → pull');
  _ok(rep1.pull.contains('d'), 'd 本地没有 → pull');
  _ok(rep1.push.contains('c'), 'c 远端没有 → push');
  _eq(rep1.conflict.length, 0, '无冲突');
  _eq(rep1.total, 4, '总键数 4');
  _ok(rep1.dirty, 'dirty=true');
  _ok(rep1.clean, 'clean=true（无冲突）');

  // rev 相同 → 比 updatedAt
  final rep2 = SecretMerge.merge(
    {'x': {'value': 'L', 'rev': 1, 'updatedAt': 10}},
    {'x': {'value': 'R', 'rev': 1, 'updatedAt': 20}},
  );
  _eq(rep2.pull.join(','), 'x', '★rev 相同，远端 updatedAt 更大 → pull');
  final rep3 = SecretMerge.merge(
    {'x': {'value': 'L', 'rev': 1, 'updatedAt': 30}},
    {'x': {'value': 'R', 'rev': 1, 'updatedAt': 20}},
  );
  _eq(rep3.push.join(','), 'x', '★rev 相同，本地 updatedAt 更大 → push');

  // rev 与 updatedAt 都相同但值不同 → 冲突
  final rep4 = SecretMerge.merge(
    {'x': {'value': 'L', 'rev': 1, 'updatedAt': 10}},
    {'x': {'value': 'R', 'rev': 1, 'updatedAt': 10}},
  );
  _eq(rep4.conflict.join(','), 'x', '★★同 rev 同时间但值不同 → 冲突（绝不自动覆盖密钥）');
  _ok(!rep4.clean, '有冲突 → clean=false');
  _ok(!rep4.dirty, '只有冲突没有 pull/push → dirty=false');

  // 全空
  final rep5 = SecretMerge.merge({}, {});
  _eq(rep5.total, 0, '空对空 → 0');
  _ok(rep5.clean && !rep5.dirty, '空对空 → clean 且不 dirty');
  _eq(SecretMerge.merge({}, {'a': 1}).pull.join(','), 'a', '★远端的裸值（非对象）也能识别为 pull');
  _eq(SecretMerge.merge({'a': 1}, {}).push.join(','), 'a', '★本地的裸值也能识别为 push');

  // pushBody：只推 push，且带 ifRev
  final body = SecretMerge.pushBody(local1, rep1);
  _eq((body['set'] as Map).length, 1, '★只推 push 里的 1 个键，绝不整体覆盖');
  _eq((body['set'] as Map)['c'], 'C1', '推的是本地值');
  _eq((body['ifRev'] as Map)['c'], 1, '★带上本地 rev 做乐观并发（防把别人的新值顶掉）');
  _ok(!(body['set'] as Map).containsKey('b'), 'push 里没有 b（b 是要 pull 的）');

  // applyPull
  final merged = SecretMerge.applyPull(local1, remote1, ['b', 'd']);
  _eq((merged['b'] as Map)['value'], 'B2', '★applyPull 采纳远端 b');
  _ok(merged.containsKey('d'), '★applyPull 新增 d');
  _eq((merged['c'] as Map)['value'], 'C1', '★applyPull 不动没拉的键');
  _eq((local1['b'] as Map)['value'], 'B1', '★applyPull 不改原表（不可变）');
  _eq(SecretMerge.applyPull(local1, remote1, ['nonexistent'])['c'], local1['c'],
      '★拉不存在的键 → 原样返回不崩');

  // mask
  _eq(SecretMerge.mask('k', ''), '', '空值 → 空');
  _eq(SecretMerge.mask('k', 'abc'), '•••', '短值全掩码');
  _eq(SecretMerge.mask('k', 'abcdef'), '••••••', '6 位全掩码');
  final masked = SecretMerge.mask('k', 'sk-1234567890abcdef');
  _ok(masked.startsWith('sk-'), '长值保留前 3 位便于识别');
  _ok(masked.endsWith('ef'), '保留后 2 位');
  _ok(!masked.contains('1234567890'), '★中间部分不泄露');

  // canonKey
  _eq(SecretMerge.canonKey('OpenAI.Key'), 'openai.key', '★大写归一为小写');
  _eq(SecretMerge.canonKey('openai_key'), 'openai.key', '★下划线 → 点');
  _eq(SecretMerge.canonKey('openai-key'), 'openai.key', '★短横 → 点');
  _eq(SecretMerge.canonKey('a__b'), 'a.b', '★连续分隔符合并');
  _eq(SecretMerge.canonKey('.a.'), 'a', '★去首尾点');
  _eq(SecretMerge.canonKey('  X.Y  '), 'x.y', '去空白');
  _eq(SecretMerge.canonKey(''), '', '空 → 空');
  _eq(SecretMerge.canonAll({'A_B': 1, 'c-d': 2})['a.b'], 1, '★canonAll 归一 A_B');
  _eq(SecretMerge.canonAll({'A_B': 1, 'c-d': 2})['c.d'], 2, 'canonAll 归一 c-d');
  _eq(SecretMerge.canonAll({'': 1}).length, 0, '★空键被丢弃');

  // ═══ 14. PeerJson ═══
  _sec('14) PeerJson 工具');
  _eq(PeerJson.obj('{"a":1}')['a'], 1, 'obj 解析');
  _eq(PeerJson.obj('garbage').length, 0, '★非法 JSON → 空对象不崩');
  _eq(PeerJson.obj('[1,2]').length, 0, '★JSON 数组不是对象 → 空');
  _eq(PeerJson.obj('').length, 0, '空串 → 空');
  _eq(PeerJson.arr([{'a': 1}, {'b': 2}]).length, 2, 'arr 解析');
  _eq(PeerJson.arr('nope').length, 0, '★非数组 → 空');
  _eq(PeerJson.arr([1, 'x', {'a': 1}]).length, 1, '★只保留 Map 元素（别的元素会让 fromJson 崩）');
  _eq(PeerJson.unwrap('{"ok":true,"data":{"x":1}}')['x'], 1, 'unwrap 成功');
  _eq(PeerJson.unwrap('{"ok":false,"error":{"code":"X"}}'), null, '★失败信封 → null');
  _eq(PeerJson.unwrap('garbage'), null, '非法 → null');
  _eq(PeerJson.errOf('{"ok":false,"error":{"code":"PEER_OFFLINE","message":"目标端不在线"}}'),
      'PEER_OFFLINE: 目标端不在线', '★errOf 拼出可读错误（UI 直接显示）');
  _eq(PeerJson.errOf('{"ok":true}'), '', '成功响应 → 空错误');
  _eq(PeerJson.errOf('garbage'), '', '非法 → 空');
  _eq(PeerJson.errOf('{"error":{"message":"only-msg"}}'), 'only-msg', '★只有 message 时不留 ": " 前缀');
  _eq(PeerJson.errOf('{"error":"plain"}'), '', 'error 是字符串 → 空（不崩）');

  // ═══ 15. 端到端剧本 ═══
  _sec('15) 端到端剧本');
  // 剧本 A：只有手机，什么都没连
  final scenarioA = PeerRegistry.empty;
  _eq(PeerRouter.route(scenarioA, cap: 'local_calc', offlineTools: {'local_calc'}, nowMs: T)!.via,
      PeerVia.local, '剧本A：离线算数 → 本地');
  _eq(PeerRouter.route(scenarioA, cap: 'dl.add', nowMs: T), null, '剧本A：下载类活 → 无路由');
  _ok(PeerRouter.summarize(scenarioA, nowMs: T).contains('离线模式'), '剧本A：状态条说离线模式');

  // 剧本 B：手机 + 后端（没插件）
  final scenarioB = PeerRegistry([_hub()]);
  _eq(PeerRouter.route(scenarioB, cap: 'dl.add', nowMs: T), null, '剧本B：没有下载能力 → 无路由');
  _eq(PeerRouter.route(scenarioB, cap: 'files', nowMs: T)!.via, PeerVia.hub, '剧本B：文件类 → 后端');
  _ok(PeerRouter.summarize(scenarioB, nowMs: T).contains('后端在线'), '剧本B：状态条');

  // 剧本 C：手机 + 后端 + 插件
  final scenarioC = PeerRegistry([_hub(), _plug()]);
  _eq(PeerRouter.route(scenarioC, cap: 'dl.add', nowMs: T)!.via, PeerVia.hub, '剧本C：走后端转发');
  _ok(PeerRouter.summarize(scenarioC, nowMs: T).contains('1 个插件'), '剧本C：状态条含插件数');

  // 剧本 D：后端挂了，插件还在（局域网 / IPv6 直连）
  final scenarioD = PeerRegistry([_plug(ipv6: '[2001:db8::5]:8801')]);
  final rD = PeerRouter.route(scenarioD, cap: 'dl.add', nowMs: T)!;
  _eq(rD.via, PeerVia.direct, '剧本D：★后端挂了 still 能直连插件');
  _eq(rD.base, 'http://192.168.1.30:8801', '剧本D：优先局域网 url');
  final scenarioD2 = PeerRegistry([_plug(url: '', ipv6: '[2001:db8::5]:8801')]);
  _eq(PeerRouter.route(scenarioD2, cap: 'dl.add', nowMs: T)!.base, 'http://[2001:db8::5]:8801',
      '剧本D：只剩 IPv6 时也能连');
  _ok(PeerRouter.summarize(scenarioD, nowMs: T).contains('无后端直连模式'), '剧本D：状态条标注直连模式');

  // 剧本 E：密钥三方同步
  var phone = <String, dynamic>{'tts.voice': {'value': 'v1', 'rev': 1, 'updatedAt': 10}};
  var server = <String, dynamic>{};
  var plug = <String, dynamic>{};
  // 手机写 → 推给后端
  var r1 = SecretMerge.merge(phone, server);
  _eq(r1.push.join(','), 'tts.voice', '剧本E：手机上的密钥要推给后端');
  server = SecretMerge.applyPull(server, phone, phone.keys.toList());
  _eq((server['tts.voice'] as Map)['value'], 'v1', '剧本E：后端拿到');
  // 插件拉 → 拿到
  r1 = SecretMerge.merge(plug, server);
  _eq(r1.pull.join(','), 'tts.voice', '剧本E：插件要拉');
  plug = SecretMerge.applyPull(plug, server, r1.pull);
  _eq((plug['tts.voice'] as Map)['value'], 'v1', '★剧本E：密钥统一到第三方（插件的）');
  // 插件改 → 手机拉到新值
  plug['tts.voice'] = {'value': 'v2', 'rev': 2, 'updatedAt': 20};
  server = SecretMerge.applyPull(server, plug, ['tts.voice']);
  final rPhone = SecretMerge.merge(phone, server);
  _eq(rPhone.pull.join(','), 'tts.voice', '★剧本E：插件改的值反向传播回手机');
  phone = SecretMerge.applyPull(phone, server, rPhone.pull);
  _eq((phone['tts.voice'] as Map)['value'], 'v2', '★剧本E：三方最终一致');

  // 剧本 F：一方输入，其他方都能用
  //   frontA 发一条广播，frontB 与 plug1 都该收到；frontA 自己不该回收自己的。
  const frontA = 'frontA';
  const frontB = 'frontB';
  final msgsF = [
    PeerMsg(
      id: 'pm101', at: 100, from: frontA, fromName: 'A 手机',
      topic: 'input', payload: {'text': '把这段存进笔记'},
    ),
    PeerMsg(
      id: 'pm102', at: 101, from: 'hub', fromName: '后端',
      to: 'plug1', topic: 'cmd', payload: {'op': 'pause'},
    ),
  ];
  final boxB = PeerInbox.filter(msgsF, frontB);
  _eq(boxB.length, 1, '剧本F：★B 收到 A 的广播（一方输入，另一方也能用）');
  _eq(boxB[0].fromName, 'A 手机', '剧本F：B 知道是哪个端发的');
  _eq(boxB[0].text(), '把这段存进笔记', '剧本F：B 读到输入内容');
  _eq(PeerInbox.filter(msgsF, frontA).length, 0, '剧本F：★A 不会收回自己发的广播');
  _eq(PeerInbox.filter(msgsF, frontA, includeSelf: true).length, 1, '剧本F：显式要求时 A 才看到自己的');
  final boxPlug = PeerInbox.filter(msgsF, 'plug1');
  _eq(boxPlug.length, 2, '剧本F：插件收到广播 + 点名叫它的那条');
  _eq(PeerInbox.filter(msgsF, 'plug1', topic: 'cmd').length, 1, '剧本F：插件按 topic 筛出命令行');
  _eq(PeerInbox.filter(msgsF, 'plug1', topic: 'cmd')[0].text(), '', '剧本F：cmd 消息没有正文');
  _eq(PeerInbox.filter(msgsF, frontB, topic: 'cmd').length, 0, '剧本F：★定向给插件的命令不会串到 B');
  _eq(PeerInbox.filter(msgsF, frontB, cursor: 'pm101').length, 0, '剧本F：B 拉到 cursor 之后无更新');

  // ═══ 16. 局域网发现：发现 ≠ 接入 ═══
  _sec('16) 局域网发现：发现 ≠ 接入');
  final disc = PeerInfo.fromJson({
    'iid': 'lan1', 'kind': 'plug', 'name': '局域网插件', 'url': 'http://192.168.1.44:8801',
    'caps': ['download'], 'discovered': true, 'online': false, 'lastSeen': T,
  });
  _eq(disc.discovered, true, 'discovered 解析');
  _eq(disc.pendingLogin, true, '★pendingLogin（待登录）');
  _eq(disc.stamped(T).online, false, '★★发现的端恒为不在线（哪怕 lastSeen 很新）');
  _eq(disc.stamped(T).pendingLogin, true, 'stamped 后仍是待登录');
  _eq(disc.toJson()['discovered'], true, 'toJson 带 discovered');
  _eq(PeerInfo.fromJson(disc.toJson()).discovered, true, 'toJson→fromJson 保持 discovered');
  _eq(PeerInfo.fromJson({}).discovered, false, '缺省不是待登录');

  final joined = PeerInfo.fromJson({
    'iid': 'lan1', 'kind': 'plug', 'discovered': false, 'online': true, 'lastSeen': T,
  });
  _eq(joined.pendingLogin, false, '已登录端不是待登录');
  _eq(joined.stamped(T).online, true, '★已登录端按时间戳判在线');
  _eq(PeerInfo(iid: 'x', kind: PeerKind.plug, discovered: true, lastSeen: T - 999999).stamped(T).online,
      false, '老的发现端也不在线');

  // 路由绝不选待登录的端
  // 用一个**也具备 download 能力**的后端，才能证明"选中了后端而不是 lan1"。
  final regDisc = PeerRegistry([_hub(caps: const ['hub', 'download']), disc]);
  _eq(regDisc.online.where((p) => p.iid == 'lan1').length, 0, '待登录端不在 online 里');
  _eq(regDisc.pendingLogins.length, 1, 'pendingLogins 命中');
  _eq(regDisc.pendingLogins[0].iid, 'lan1', 'pendingLogins 内容正确');
  _eq(regDisc.offline.where((p) => p.iid == 'lan1').length, 1, '待登录端在 offline 分类里（UI 复用）');
  final rDisc = PeerRouter.route(regDisc, cap: 'download', nowMs: T);
  _eq(rDisc!.via, PeerVia.hub, '★有后端时不会选待登录的端（走后端）');
  _eq(rDisc.peer!.iid, kHubIid, '目标回落到后端（而不是待登录的 lan1）');
  final rDisc2 = PeerRouter.route(PeerRegistry([disc]), cap: 'download', nowMs: T);
  _eq(rDisc2, null, '★★只有待登录端（无后端）→ 无路由，绝不会误调它');

  // fromJson 同时吸收 peers 与 pending
  final regMix = PeerRegistry.fromJson({
    'peers': [
      {'iid': 'a', 'kind': 'plug', 'online': true, 'lastSeen': T},
    ],
    'pending': [
      {'iid': 'b', 'kind': 'plug', 'discovered': true, 'online': false},
    ],
  });
  _eq(regMix.peers.length, 2, '★fromJson 同时吸收 peers 与 pending');
  _eq(regMix.pendingLogins.length, 1, 'pending 项被识别为待登录');
  _eq(regMix.pendingLogins[0].iid, 'b', 'pending 项 iid 正确');
  _eq(PeerRegistry.fromJson({'pending': []}).peers.length, 0, '只有空 pending → 空表');
  _eq(PeerRegistry.fromJson({'pending': [{'iid': ''}]}).peers.length, 0, '★空 iid 的端被丢弃（否则 UI 出现无名的幽灵端）');

  // 状态条要把待登录说出来
  final sPend = PeerRouter.summarize(PeerRegistry([_hub(), _plug(), disc]), nowMs: T);
  _ok(sPend.contains('1 个待登录'), '★状态条提示"有待登录的端"（否则用户不知道局域网里已经有插件在等）');
  final sPend2 = PeerRouter.summarize(PeerRegistry([_plug()]), nowMs: T);
  _ok(!sPend2.contains('待登录'), '没有待登录端时不显示该字样（不制造噪音）');

  // ═══ 汇总 ═══
  print('\n────────────────────────────────────────');
  print('PASS $_pass   FAIL $_fail');
  if (_fail > 0) {
    print('\n失败项:');
    for (final f in _fails) {
      print('  · $f');
    }
  } else {
    print('\n✅ 全部通过');
  }
}
