// 端间互通内核（PH/1 的客户端纯逻辑）。
//
// ★ 本文件刻意**零依赖**（只用 dart:core / dart:convert），因此：
//   ① 可以用纯 Dart VM 跑自检（tool/peer_hub_selfcheck.dart）；
//   ② 可以在没有后端、没有网络、没有 DSH 的情况下依然 100% 可用。
//
// 它回答四个问题（对应四组类）：
//   1. 局域网里现在有谁？            → PeerInfo / PeerRegistry
//   2. 这件活该谁干、怎么走？          → PeerRoute / PeerRouter
//   3. 密钥谁的是新的？               → SecretMerge
//   4. 谁发的消息该给我？             → PeerInbox
//
// 与 peer_hub.dart 的分工：
//   · 本文件   = 纯逻辑（可自检、跨端复用；Node 端 peer-hub.js 是同一套语义的服务端实现）
//   · peer_hub.dart = 需要 dart:io 的网络与持久化

library;

import 'dart:convert';

/// 安全整数转换。
/// ★ 为什么需要：`(j['lastSeen'] as num?)` 在字段是字符串/别的类型时**直接抛**
///   （`as` 不做隐式转换），而端列表来自网络与第三方插件，字段类型完全不可信。
///   自测第 2 节 `lastSeen: 'abc'` 就是这个坑。所有数字字段都必须过这里。
int _intOf(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  if (v is bool) return v ? 1 : 0;
  return 0;
}

// ─────────────────────────────────────────────────────────────────────────
// 0. 端
// ─────────────────────────────────────────────────────────────────────────

/// 端的种类。与后端 peer-hub.js 的 kind 字段一一对应。
enum PeerKind { front, plug, dsa, back, unknown }

PeerKind peerKindOf(String s) {
  switch (s) {
    case 'front':
      return PeerKind.front;
    case 'plug':
      return PeerKind.plug;
    case 'dsa':
      return PeerKind.dsa;
    case 'back':
      return PeerKind.back;
    default:
      return PeerKind.unknown;
  }
}

String peerKindName(PeerKind k) {
  switch (k) {
    case PeerKind.front:
      return '前端';
    case PeerKind.plug:
      return '插件';
    case PeerKind.dsa:
      return 'DSA';
    case PeerKind.back:
      return '后端';
    case PeerKind.unknown:
      return '未知';
  }
}

/// 后端 hub 的固定 iid（peer-hub.js 里写死为 local-back）。
const String kHubIid = 'local-back';

/// 在线窗口：与后端 ONLINE_MS 保持一致（45s）。前端本地也要能自己判，
/// 因为"无后端直连"场景下没有后端替我们判在线。
const int kPeerOnlineMs = 45000;

/// 一个端。
class PeerInfo {
  final String iid;
  final PeerKind kind;
  final String name;
  final String url;
  final String ipv6;
  final String tunnel;
  final List<String> caps;
  final List<String> tools;
  final String account;
  final bool online;

  /// 只在局域网里被 UDP 发现、还没登录账号接入。
  ///
  /// ★ 这个标记必须存在，不能只靠 online=false：前端要把"待登录"和"离线"
  ///   显示成完全不同的两件事（前者要让用户去插件侧填账号，后者只需要等）。
  final bool discovered;
  final int firstSeen;
  final int lastSeen;
  final bool vip;

  const PeerInfo({
    required this.iid,
    required this.kind,
    this.name = '',
    this.url = '',
    this.ipv6 = '',
    this.tunnel = '',
    this.caps = const [],
    this.tools = const [],
    this.account = '',
    this.online = false,
    this.discovered = false,
    this.firstSeen = 0,
    this.lastSeen = 0,
    this.vip = false,
  });

  static String _s(dynamic v) => v == null ? '' : v.toString();
  static List<String> _ss(dynamic v) =>
      v is List ? v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList() : const [];

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
        iid: _s(j['iid']),
        kind: peerKindOf(_s(j['kind'])),
        name: _s(j['name']),
        url: _s(j['url']),
        ipv6: _s(j['ipv6']),
        tunnel: _s(j['tunnel']),
        caps: _ss(j['caps']),
        tools: _ss(j['tools']),
        account: _s(j['account']),
        online: j['online'] == true,
        discovered: j['discovered'] == true,
        firstSeen: _intOf(j['firstSeen']),
        lastSeen: _intOf(j['lastSeen']),
        vip: j['vip'] == true,
      );

  Map<String, dynamic> toJson() => {
        'iid': iid,
        'kind': kind.name == 'unknown' ? '' : kind.name,
        'name': name,
        'url': url,
        'ipv6': ipv6,
        'tunnel': tunnel,
        'caps': caps,
        'tools': tools,
        'account': account,
        'online': online,
        'discovered': discovered,
        'firstSeen': firstSeen,
        'lastSeen': lastSeen,
        'vip': vip,
      };

  bool get isHub => kind == PeerKind.back && (iid == kHubIid || iid.isNotEmpty);
  bool hasCap(String c) => caps.contains(c);
  bool can(String tool) => tools.contains(tool);

  /// 『无后端也能连』的落点：这三条地址按优先级排好。
  /// 局域网直连(url)最快 → 内网穿透(tunnel)跨网可用 → IPv6 兜底。
  ///
  /// ★ 必须 trim 判空：后端/插件自报的字段常见 ' '（例如 JSON 里写了空串或
  ///   用户输入后误删），若不 trim 会拼出 'http://   /peer/exec' —— 请求必然失败，
  ///   但错误信息是"连接被拒绝"，根本看不出是空白地址导致的。
  List<String> get routes => <String>[
        if (url.trim().isNotEmpty) url.trim(),
        if (tunnel.trim().isNotEmpty) tunnel.trim(),
        if (ipv6.trim().isNotEmpty) ipv6.trim(),
      ];

  /// 本地时间戳重判在线（后端给的 online 可能已经过期，尤其是离线直连场景）。
  ///
  /// ★ 被发现但没登录的端**恒为不在线** —— 与后端 view() 的判定一致。
  ///   否则 stamped 会用一个很新的 lastSeen 把它算成"在线"，路由就会去调它，
  ///   而它其实还没接入（在 UDP 无鉴权的局域网里，这等于免登录入口）。
  PeerInfo stamped(int nowMs) =>
      _copy(online: discovered ? false : (nowMs - lastSeen < kPeerOnlineMs));

  /// "待登录"：局域网里看到了，但还没接入。UI 该提示用户去插件侧填账号。
  bool get pendingLogin => discovered && !online;

  PeerInfo _copy({
    String? iid,
    PeerKind? kind,
    String? name,
    String? url,
    String? ipv6,
    String? tunnel,
    List<String>? caps,
    List<String>? tools,
    String? account,
    bool? online,
    bool? discovered,
    int? firstSeen,
    int? lastSeen,
    bool? vip,
  }) =>
      PeerInfo(
        iid: iid ?? this.iid,
        kind: kind ?? this.kind,
        name: name ?? this.name,
        url: url ?? this.url,
        ipv6: ipv6 ?? this.ipv6,
        tunnel: tunnel ?? this.tunnel,
        caps: caps ?? this.caps,
        tools: tools ?? this.tools,
        account: account ?? this.account,
        online: online ?? this.online,
        discovered: discovered ?? this.discovered,
        firstSeen: firstSeen ?? this.firstSeen,
        lastSeen: lastSeen ?? this.lastSeen,
        vip: vip ?? this.vip,
      );

  @override
  String toString() {
    final id = name.isEmpty ? iid : name;
    final b = StringBuffer('Peer(${kind.name}:$id');
    if (!online) b.write('·离线');
    if (caps.isNotEmpty) b.write(' caps=${caps.join("/")}');
    if (tools.isNotEmpty) b.write(' tools=${tools.length}');
    b.write(')');
    return b.toString();
  }
}

/// 端列表的容器 + 查询。**不可变**（copy-on-write），避免 UI 层拿着半更新的表渲染。
class PeerRegistry {
  final List<PeerInfo> peers;
  const PeerRegistry(this.peers);
  static const PeerRegistry empty = PeerRegistry(<PeerInfo>[]);

  factory PeerRegistry.fromJson(Map<String, dynamic> j) {
    final out = <String, PeerInfo>{};
    void absorb(dynamic v) {
      for (final e in PeerJson.arr(v)) {
        final p = PeerInfo.fromJson(e);
        if (p.iid.isNotEmpty) out[p.iid] = p;
      }
    }

    // ① 后端 list 的 shapes：peers(已接入且在线) + pending(局域网发现但没登录)
    //    两者都要，否则"发现了新插件但还没登录"这件事在 UI 上完全看不见。
    if (j['peers'] is List || j['pending'] is List) {
      absorb(j['peers']);
      absorb(j['pending']);
    } else {
      // ② 本地缓存 / 只有 all 的响应：退化为全量已登记端
      absorb(j['all']);
    }
    return PeerRegistry(out.values.toList());
  }

  PeerRegistry stamped(int nowMs) => PeerRegistry(peers.map((p) => p.stamped(nowMs)).toList());

  List<PeerInfo> get online => peers.where((p) => p.online).toList();
  List<PeerInfo> get offline => peers.where((p) => !p.online).toList();

  /// 后端（中枢）是否在线 —— 『无后端也能用』的分水岭就靠它。
  PeerInfo? get hub {
    for (final p in peers) {
      if (p.kind == PeerKind.back && p.online) return p;
    }
    return null;
  }

  bool get hasHub => hub != null;

  PeerInfo? byIid(String iid) {
    for (final p in peers) {
      if (p.iid == iid) return p;
    }
    return null;
  }

  /// 按**名字**找端。用户和 AI 记名字比记 iid 容易得多（"下载插件" vs "3f9a…"）。
  ///
  /// ★ 名字不唯一：同一份插件代码在局域网里跑两份，名字就一模一样。
  ///   所以这里**只回唯一命中**；命中多个时返回 null，让调用方去要求用户说清 iid ——
  ///   随便挑一个"看起来对"的端派活，是把用户的活派给了错误的机器。
  PeerInfo? byName(String name) {
    final n = name.trim();
    if (n.isEmpty) return null;
    PeerInfo? hit;
    for (final p in peers) {
      if (p.name == n) {
        if (hit != null) return null;   // 重名 → 拒绝猜
        hit = p;
      }
    }
    return hit;
  }

  /// 统一寻址：先当 iid 找，再当名字找。找不到 / 重名歧义都返回 null。
  PeerInfo? resolve(String key) {
    final k = key.trim();
    if (k.isEmpty) return null;
    return byIid(k) ?? byName(k);
  }

  List<PeerInfo> withCap(String cap) => online.where((p) => p.hasCap(cap)).toList();
  List<PeerInfo> withTool(String tool) => online.where((p) => p.can(tool)).toList();
  List<PeerInfo> ofKind(PeerKind k) => online.where((p) => p.kind == k).toList();

  /// 局域网里发现、但还没登录账号接入的端。
  /// UI 要把它与"离线"分开显示 —— 处理动作完全不同：
  ///   待登录 → 去插件侧填账号口令；离线 → 什么都不用做，等它回来。
  List<PeerInfo> get pendingLogins => peers.where((p) => p.pendingLogin).toList();

  /// 后端 peer-hub.js 的 stats 等价物（UI 直接渲染计数）。
  Map<PeerKind, int> get counts {
    final m = <PeerKind, int>{};
    for (final p in online) {
      m[p.kind] = (m[p.kind] ?? 0) + 1;
    }
    return m;
  }

  /// 合并（按 iid 覆盖），用于"本机缓存 + 后端最新"取并集。
  PeerRegistry merge(PeerRegistry other) {
    final m = <String, PeerInfo>{};
    for (final p in peers) {
      m[p.iid] = p;
    }
    for (final p in other.peers) {
      m[p.iid] = p;
    }
    return PeerRegistry(m.values.toList());
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 1. 地址规整
// ─────────────────────────────────────────────────────────────────────────
class PeerUrl {
  /// 规整成可直接 fetch 的 URL：
  ///   '192.168.1.5:9527'        → 'http://192.168.1.5:9527'
  ///   '[fe80::1]:8801'          → 'http://[fe80::1]:8801'   ★IPv6 必须带方括号
  ///   'fe80::1'                 → 'http://[fe80::1]'
  ///   'https://x/y/'            → 'https://x/y'             （去尾斜杠）
  static String normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(s)) return s;
    // 无 scheme：判断 host 部分是不是裸 IPv6（含 ':' 且不以 '[' 开头）
    final hostPart = s.split('/').first;
    if (!hostPart.startsWith('[') && hostPart.contains(':')) {
      final colons = ':'.allMatches(hostPart).length;
      // 一个 ':' 且冒号后全是数字 = host:port（IPv4/域名）；否则视为 IPv6
      final isHostPort = colons == 1 && RegExp(r'^\d+$').hasMatch(hostPart.split(':').last);
      if (!isHostPort) return 'http://[$s]';
    }
    return 'http://$s';
  }

  /// 从一条路由算终点路径。base 为空返回 ''。
  static String join(String base, String path) {
    final b = normalize(base);
    if (b.isEmpty) return '';
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }

  /// 取出 host（不带端口）。IPv6 去方括号。
  ///
  /// ★ 不要用正则 `^https?://([^/:]+|\[[^\]]+\])`：`[^/:]+` 里 '[' 是**允许**的字符，
  ///   交替分支会先命中它、把 host 取成单个 '['，于是 '[::1]'/'[fe80::1]' 全判不出来。
  ///   所以改为"剥 scheme → 截到第一个 / → 手工处理方括号与端口"。
  static String hostOf(String url) {
    var s = normalize(url);
    if (s.isEmpty) return '';
    s = s.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    s = s.split('?').first.split('/').first;
    if (s.startsWith('[')) {
      final i = s.indexOf(']');
      return i > 0 ? s.substring(1, i) : s;
    }
    final c = s.lastIndexOf(':');
    if (c > 0 && RegExp(r'^\d+$').hasMatch(s.substring(c + 1))) return s.substring(0, c);
    return s;
  }

  /// 判定是否"本机可达"（同网段/回环）—— 用于给用户排序：先给最快的。
  static bool looksLocal(String url) {
    final bare = hostOf(url);
    if (bare.isEmpty) return false;
    if (bare == 'localhost' || bare == '127.0.0.1' || bare == '::1') return true;
    if (RegExp(r'^192\.168\.').hasMatch(bare)) return true;
    if (RegExp(r'^10\.').hasMatch(bare)) return true;
    if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(bare)) return true;
    if (RegExp(r'^169\.254\.').hasMatch(bare)) return true; // link-local
    if (bare.toLowerCase().startsWith('fe80:')) return true; // IPv6 link-local
    return false;
  }

  /// 选一条最好的路由：本机可达优先，其次穿透，最后 IPv6。
  static String bestRoute(List<String> routes) {
    final norm = routes.map(normalize).where((e) => e.isNotEmpty).toList();
    if (norm.isEmpty) return '';
    for (final r in norm) {
      if (looksLocal(r)) return r;
    }
    for (final r in norm) {
      if (r.startsWith('https://')) return r; // 穿透多为 https
    }
    return norm.first;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 2. 路由：这活该谁干、怎么走
// ─────────────────────────────────────────────────────────────────────────

/// 走的哪条路。诊断时直接给用户看这个字符串。
enum PeerVia {
  /// 本地自己干（离线能力），不经任何端
  local,

  /// 由后端转发（后端在线，前端不必自己维护插件地址）
  hub,

  /// 直连目标端（后端不在线时，靠插件自报的 url/tunnel/ipv6）
  direct,
}

class PeerRoute {
  final PeerVia via;

  /// 目标端；via=local 时为 null
  final PeerInfo? peer;

  /// via=direct 时的实际地址（已 normalize）
  final String base;

  /// 人类可读的判定理由（直接进 UI 的提示条 / 进日志）
  final String reason;

  const PeerRoute(this.via, this.peer, this.base, this.reason);

  static const PeerRoute localRoute =
      PeerRoute(PeerVia.local, null, '', '本机离线能力，不需要任何端');

  bool get ok => via == PeerVia.local || peer != null;
  bool get needsNetwork => via != PeerVia.local;

  @override
  String toString() => 'Route(${via.name}${peer == null ? "" : "→${peer!.name}"}'
      '${base.isEmpty ? "" : " @$base"})';
}

/// 路由器 —— 『一方输入，其他方都能用』的调度核心。
///
/// 判定顺序（这个顺序本身就是产品逻辑，改动前先想清楚）：
///   1. 如果本地就能干（offlineTools 命中）→ local。**永远优先**，
///      因为一次本地调用比一次跨端往返快两个数量级，且不依赖网络。
///   2. 有在线端声明了该能力：
///      a. 后端在线 → hub 转发（前端不用知道插件地址，插件换地址也不影响）
///      b. 后端不在线 → direct 直连（这就是"没有后端也能用插件"）
///   3. 后端本身具备该能力（files/agent/mcp/hub/secrets）→ hub
///   4. 都不行 → null
class PeerRouter {
  /// 本机离线就能满足的能力标签（与 LocalTools 的工具名对齐）。
  /// 注意：这是"快速短路"，不是权限控制 —— 即使命中，调用方仍可强制走远端。
  static bool localCan(String capOrTool, Set<String> offlineTools) =>
      offlineTools.contains(capOrTool);

  /// 一个端能不能接这个活。
  /// ★ cap 与 tool 是**两套标识**，都必须认：
  ///   caps 是粗粒度能力（'download' / 'files' / 'llm'），供"这类活谁能干"用；
  ///   tools 是该端自报的具体工具名（'dl.add'），插件通常只报 tools。
  ///   只查 caps 会让只报 tools 的插件永远匹配不上（自测剧本 C 就是这么红的）。
  static bool canTake(PeerInfo p, String capOrTool) =>
      p.hasCap(capOrTool) || p.can(capOrTool);

  static PeerRoute? route(
    PeerRegistry reg, {
    required String cap,
    Set<String> offlineTools = const <String>{},
    bool allowLocal = true,
    String? preferIid,
    int nowMs = 0,
  }) {
    final now = nowMs == 0 ? DateTime.now().millisecondsSinceEpoch : nowMs;
    final view = reg.stamped(now);

    if (allowLocal && localCan(cap, offlineTools)) return PeerRoute.localRoute;

    // 指定了目标端就只用它（点对点派活的场景）
    if (preferIid != null && preferIid.isNotEmpty) {
      final t = view.byIid(preferIid);
      if (t == null || !t.online) {
        return PeerRoute(PeerVia.direct, null, '', '指定的端不在线: $preferIid');
      }
      // ★ 指定的就是中枢本身：必须走 hub 分支。
      //   后端**没有** /peer/exec 端点（它是转发方不是插件），直连必然 404。
      if (t.kind == PeerKind.back) {
        return PeerRoute(PeerVia.hub, t, '', '由后端执行');
      }
      final hub = view.hub;
      if (hub != null) {
        return PeerRoute(PeerVia.hub, t, '', '后端在线，转发给 ${t.name.isEmpty ? t.iid : t.name}');
      }
      final b = PeerUrl.bestRoute(t.routes);
      if (b.isEmpty) {
        return PeerRoute(PeerVia.direct, null, '', '${t.name.isEmpty ? t.iid : t.name} 未上报可达地址');
      }
      return PeerRoute(PeerVia.direct, t, b, '直连 ${t.name.isEmpty ? t.iid : t.name}');
    }

    final targets = view.online.where((p) => p.kind != PeerKind.back && canTake(p, cap)).toList();
    final hub = view.hub;

    if (targets.isNotEmpty) {
      // 挑一个：优先"能力声明更专一"的插件，其次最近心跳，最后 iid 稳定排序（避免每次调用换端）
      targets.sort((a, b) {
        final ka = a.kind == PeerKind.plug ? 0 : 1;
        final kb = b.kind == PeerKind.plug ? 0 : 1;
        if (ka != kb) return ka - kb;
        if (a.lastSeen != b.lastSeen) return b.lastSeen - a.lastSeen;
        return a.iid.compareTo(b.iid);
      });
      final t = targets.first;
      if (hub != null) {
        return PeerRoute(PeerVia.hub, t, '', '后端在线，转发给 ${t.name.isEmpty ? t.iid : t.name}');
      }
      // ★ 无后端：直连
      final b = PeerUrl.bestRoute(t.routes);
      if (b.isEmpty) {
        return PeerRoute(PeerVia.direct, null, '',
            '${t.name.isEmpty ? t.iid : t.name} 在线但没上报 url/ipv6/穿透地址，无法直连');
      }
      return PeerRoute(PeerVia.direct, t, b, '无后端，直连 ${t.name.isEmpty ? t.iid : t.name}');
    }

    // 后端自身具备该能力
    if (hub != null && (canTake(hub, cap) || cap == 'hub')) {
      return PeerRoute(PeerVia.hub, hub, '', '由后端执行');
    }
    return null;
  }

  /// 给人看的一句话总结：现在能用什么、缺什么。UI 顶部状态条直接用。
  static String summarize(PeerRegistry reg, {int nowMs = 0}) {
    final now = nowMs == 0 ? DateTime.now().millisecondsSinceEpoch : nowMs;
    final v = reg.stamped(now);
    final on = v.online;
    if (on.isEmpty) return '离线模式：仅本机能力可用';
    final hub = v.hub;
    final plugs = v.ofKind(PeerKind.plug).length;
    final fronts = v.ofKind(PeerKind.front).length;
    final dsas = v.ofKind(PeerKind.dsa).length;
    final pend = v.pendingLogins.length;
    final parts = <String>[];
    if (hub != null) parts.add('后端在线');
    if (plugs > 0) parts.add('$plugs 个插件');
    if (fronts > 0) parts.add('$fronts 个前端');
    if (dsas > 0) parts.add('$dsas 个 DSA');
    // 待登录的端要在状态条里露出 —— 否则用户只会看到"怎么还没连上"，
    // 完全不知道局域网里其实已经有插件在等他了。
    if (pend > 0) parts.add('$pend 个待登录');
    final head = hub == null ? '无后端直连模式' : '已连接';
    return '$head：${parts.isEmpty ? "只有本机" : parts.join(" · ")}';
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 3. 消息收发
// ─────────────────────────────────────────────────────────────────────────

/// 端间的即时消息。topic 是自由标签（input / clip / cmd / search …）。
class PeerMsg {
  final String id;
  final int at;
  final String from;
  final String fromName;
  final String to;
  final String topic;
  final dynamic payload;

  const PeerMsg({
    required this.id,
    required this.at,
    required this.from,
    this.fromName = '',
    this.to = '',
    this.topic = 'input',
    this.payload,
  });

  factory PeerMsg.fromJson(Map<String, dynamic> j) => PeerMsg(
        id: (j['id'] ?? '').toString(),
        at: _intOf(j['at']),
        from: (j['from'] ?? '').toString(),
        fromName: (j['fromName'] ?? '').toString(),
        to: (j['to'] ?? '').toString(),
        topic: (j['topic'] ?? 'input').toString(),
        payload: j['payload'],
      );

  /// 消息序号（'pm12' → 12）。非该形态返回 -1。
  int get seq {
    if (!id.startsWith('pm')) return -1;
    return int.tryParse(id.substring(2)) ?? -1;
  }

  /// payload 里取一个字符串字段（约定 payload 是对象）。
  String text() {
    final p = payload;
    if (p == null) return '';
    if (p is String) return p;
    if (p is Map) {
      for (final k in const ['text', 'value', 'content', 'q']) {
        final v = p[k];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
    }
    return '';
  }

  @override
  String toString() => 'Msg($id ${topic} ${from.isEmpty ? "?" : from}${to.isEmpty ? "→*" : "→$to"})';
}

class PeerInbox {
  /// 这条消息该不该给本端。
  /// 规则（与后端 pull 的过滤一致，前端需要自己做是因为离线直连时没有后端帮忙过滤）：
  ///   ① 点名叫我的（to == myIid）或广播（to 为空）
  ///   ② 默认不回放自己发的（否则前端会把自己的输入再吃一遍）
  ///   ③ includeSelf=true 时才回放自己发的
  static bool accept(PeerMsg m, String myIid, {bool includeSelf = false}) {
    final addressed = m.to.isEmpty || m.to == myIid;
    if (!addressed) return false;
    if (!includeSelf && m.from == myIid) return false;
    return true;
  }

  static List<PeerMsg> filter(
    List<PeerMsg> all,
    String myIid, {
    String topic = '',
    String cursor = '',
    bool includeSelf = false,
  }) {
    var out = all;
    if (topic.isNotEmpty) out = out.where((m) => m.topic == topic).toList();
    if (cursor.isNotEmpty) {
      final n = PeerMsg(id: cursor, at: 0, from: '').seq;
      if (n >= 0) {
        out = out.where((m) => m.seq > n).toList();
      } else {
        final t = int.tryParse(cursor) ?? 0;
        out = out.where((m) => m.at > t).toList();
      }
    }
    return out.where((m) => accept(m, myIid, includeSelf: includeSelf)).toList();
  }

  /// 下一步的 cursor：取最后一条的 id；空列表时**保留原 cursor**
  /// （否则会退化成"每次都从头发"，重复处理）。
  static String nextCursor(List<PeerMsg> msgs, String current) =>
      msgs.isEmpty ? current : msgs.last.id;

  /// 去重合并（离线期间可能重复拉到）。
  static List<PeerMsg> dedupe(List<PeerMsg> all) {
    final seen = <String>{};
    final out = <PeerMsg>[];
    for (final m in all) {
      if (m.id.isEmpty || seen.add(m.id)) out.add(m);
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 4. 密钥统一
// ─────────────────────────────────────────────────────────────────────────

/// 一条密钥的元数据（值不进这个类，避免在 UI 里到处流传明文）。
class SecretMeta {
  final String name;
  final int rev;
  final int updatedAt;
  final String from;
  const SecretMeta({required this.name, this.rev = 0, this.updatedAt = 0, this.from = ''});
}

/// 合并结果：本地该更新哪些、该把哪些推上去。
class SecretMergeReport {
  /// 需要采纳远端值的键（远端更新）
  final List<String> pull;

  /// 需要推给远端的键（本地更新）
  final List<String> push;

  /// 双方都有且值不同、且 rev 相同 → 无法自动判定，需人工（理论上不该出现）
  final List<String> conflict;

  /// 完全一致
  final List<String> same;

  const SecretMergeReport(this.pull, this.push, this.conflict, this.same);

  bool get clean => conflict.isEmpty;
  bool get dirty => pull.isNotEmpty || push.isNotEmpty;
  int get total => pull.length + push.length + conflict.length + same.length;

  @override
  String toString() =>
      'Merge(pull=${pull.length} push=${push.length} conflict=${conflict.length} same=${same.length})';
}

/// 密钥合并 —— 『所有密钥只要前端/后端/插件上有，都会统一到其他所有端』的判定。
///
/// rev 是唯一权威：rev 大者更新。rev 相同时比 updatedAt，再相同则值一致=同；
/// 值不同=冲突（不自动覆盖，交人决定 —— 密钥被悄悄顶掉是最糟糕的体验）。
class SecretMerge {
  /// local / remote 形状：{name: {value, rev, updatedAt, from}}
  static SecretMergeReport merge(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    final pull = <String>[];
    final push = <String>[];
    final conflict = <String>[];
    final same = <String>[];

    final keys = <String>{...local.keys, ...remote.keys};
    for (final k in keys) {
      final l = local[k];
      final r = remote[k];
      if (l == null) {
        pull.add(k);
        continue;
      }
      if (r == null) {
        push.add(k);
        continue;
      }
      final lr = _rev(l), rr = _rev(r);
      if (lr != rr) {
        if (rr > lr) {
          pull.add(k);
        } else {
          push.add(k);
        }
        continue;
      }
      final lt = _at(l), rt = _at(r);
      if (lt != rt) {
        if (rt > lt) {
          pull.add(k);
        } else {
          push.add(k);
        }
        continue;
      }
      if (_val(l) == _val(r)) {
        same.add(k);
      } else {
        conflict.add(k);
      }
    }
    pull.sort();
    push.sort();
    conflict.sort();
    same.sort();
    return SecretMergeReport(pull, push, conflict, same);
  }

  static int _rev(dynamic e) => e is Map ? _intOf(e['rev']) : 0;
  static int _at(dynamic e) => e is Map ? _intOf(e['updatedAt']) : 0;
  static String _val(dynamic e) => e is Map ? ((e['value'] ?? '').toString()) : '';

  /// 生成 POST 到 /agent/peer/secrets 的请求体。
  /// 只推 push 列出的键 → 绝不整体覆盖（防把别人的新值顶掉）。
  static Map<String, dynamic> pushBody(Map<String, dynamic> local, SecretMergeReport r) {
    final set = <String, dynamic>{};
    final ifRev = <String, dynamic>{};
    for (final k in r.push) {
      final e = local[k];
      if (e is Map && e['value'] != null) {
        set[k] = e['value'].toString();
        ifRev[k] = _rev(e);
      } else if (e is String) {
        set[k] = e;
      }
    }
    return {'set': set, 'ifRev': ifRev};
  }

  /// 采纳远端值到本地（返回新的本地表，不改原表）。
  static Map<String, dynamic> applyPull(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
    List<String> keys,
  ) {
    final out = <String, dynamic>{};
    local.forEach((k, v) => out[k] = v);
    for (final k in keys) {
      if (remote.containsKey(k)) out[k] = remote[k];
    }
    return out;
  }

  /// 掩码显示：密钥在 UI 里绝不明文（列表/日志都可能被截图）。
  static String mask(String name, String value) {
    if (value.isEmpty) return '';
    if (value.length <= 6) return '•' * value.length;
    return '${value.substring(0, 3)}${'•' * 6}${value.substring(value.length - 2)}';
  }

  /// 键名归一：插件/各端可能用不同写法指同一个密钥，统一到小写点分。
  /// 'OpenAI.Key' / 'openai_key' / 'openai-key' → 'openai.key'
  static String canonKey(String raw) {
    var s = raw.trim().toLowerCase();
    s = s.replaceAll('_', '.').replaceAll('-', '.');
    s = s.replaceAll(RegExp(r'\.{2,}'), '.');
    s = s.replaceAll(RegExp(r'^\.|\.$'), '');
    return s;
  }

  /// 把一张表里的键全部归一（冲突时后写的赢，但会把旧键删掉避免重复）。
  static Map<String, dynamic> canonAll(Map<String, dynamic> src) {
    final out = <String, dynamic>{};
    src.forEach((k, v) {
      final c = canonKey(k);
      if (c.isNotEmpty) out[c] = v;
    });
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 5. 编解码小工具（给 peer_hub.dart 和自检共用）
// ─────────────────────────────────────────────────────────────────────────
class PeerJson {
  static Map<String, dynamic> obj(String s) {
    try {
      final j = jsonDecode(s);
      return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static List<Map<String, dynamic>> arr(dynamic v) {
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// 统一信封拆包：{ok:true,data:...} / {ok:false,error:{code,message}}
  static dynamic unwrap(String body) {
    final j = obj(body);
    if (j.isEmpty) return null;
    if (j['ok'] == true) return j['data'];
    return null;
  }

  /// 错误信息（供 UI 显示"为什么连不上"）。
  static String errOf(String body) {
    final j = obj(body);
    final e = j['error'];
    if (e is Map) {
      final c = (e['code'] ?? '').toString();
      final m = (e['message'] ?? '').toString();
      return c.isEmpty ? m : '$c: $m';
    }
    return '';
  }
}
