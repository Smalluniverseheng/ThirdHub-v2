// ═══════════════════════════════════════════════════════════════════════════
// 局域网聊天 · 纯逻辑层（零 Flutter 依赖）
//
// 与 `docs/LANCHAT-PROTOCOL.md` 一一对应，可实现纯 Dart 自检：
//     dart run tool/chat_proto_selfcheck.dart
//
// 这里只放**不需要 UI 也能验证**的东西：协议常量、报文模型、去重、排序、
// 能力降级判定。socket 在 chat_transfer.dart，加解密在 chat_crypto.dart。
//
// 既有的 v1 报文（`lab_logic.dart` 的 lanEncode/lanDecode + LanPeer/LanMessage）
// 保持不变——**旧版设备还在网里，不能因为升版把它们踢掉**。
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';

/// 协议版本。写进每条报文的 `v`。
const int kLanChatVersion = 2;

/// 报文类型。
class ChatT {
  static const String hi = 'hi';
  static const String msg = 'msg';
  static const String file = 'file';
  static const String fileAck = 'file_ack';
  static const String typing = 'typing';
  static const String recall = 'recall';
  static const String bye = 'bye';
}

/// 消息种类。
class ChatKind {
  static const String text = 'text';
  static const String image = 'image';
  static const String file = 'file';
  static const String voice = 'voice';
  static const String video = 'video';

  /// 「戳一戳」：一条只有提示意义、不进阅读正文的消息。
  /// 复用 `msg` 报文而不新增报文类型——老版本收到它只是当作一句普通文本，
  /// 不会因为不认识而丢弃（协议只增不减的落地方式）。
  static const String poke = 'poke';
}

/// 加密方案标识。
class ChatEnc {
  /// 明文（区域频道，或对端不支持加密时的降级）
  static const String none = 'none';

  /// X25519 密钥协商 + AES-256-GCM
  static const String x25519AesGcm = 'x25519-aesgcm';
}

/// 能力声明：对端能不能收文件、能不能解密。
class ChatCaps {
  final bool text;
  final bool file;
  final bool enc;

  const ChatCaps({this.text = true, this.file = true, this.enc = true});

  List<String> toList() => [
        if (text) 'text',
        if (file) 'file',
        if (enc) 'enc',
      ];

  static ChatCaps parse(dynamic raw) {
    final l = raw is List ? raw.map((e) => '$e').toSet() : <String>{};
    // 缺 cap 字段的老设备：按"只会纯文本"处理，宁可少给能力也不误判
    if (l.isEmpty) return const ChatCaps(text: true, file: false, enc: false);
    return ChatCaps(
      text: l.contains('text'),
      file: l.contains('file'),
      enc: l.contains('enc'),
    );
  }
}

/// 一条局域网消息（v2）。
class LanMessage2 {
  final String mid; // 幂等键（与 from 组成复合唯一）
  final String from; // 发送方设备 id
  final String fromName;
  final String to; // 目标设备 id；'*' = 广播
  final bool toAll;
  final String kind;
  final String text; // 解密后的正文（未解密时为空）
  final String enc; // none | x25519-aesgcm
  final int ts;
  final bool mine;
  final bool delivered; // 是否已在局域网送达
  final bool pending; // 是否转入 CHAT/1 待同步队列
  final Map<String, dynamic>? file; // 附件元数据

  const LanMessage2({
    required this.mid,
    required this.from,
    required this.fromName,
    required this.to,
    required this.toAll,
    required this.kind,
    required this.text,
    required this.enc,
    required this.ts,
    this.mine = false,
    this.delivered = false,
    this.pending = false,
    this.file,
  });

  bool get encrypted => enc == ChatEnc.x25519AesGcm;
  bool get isBroadcast => toAll || to == '*';

  Map<String, dynamic> toJson() => {
        'mid': mid,
        'from': from,
        'fromName': fromName,
        'to': to,
        'toAll': toAll,
        'kind': kind,
        'text': text,
        'enc': enc,
        'ts': ts,
        'mine': mine,
        'delivered': delivered,
        'pending': pending,
        if (file != null) 'file': file,
      };

  factory LanMessage2.from(Map<String, dynamic> j) => LanMessage2(
        mid: '${j['mid'] ?? ''}',
        from: '${j['from'] ?? ''}',
        fromName: '${j['fromName'] ?? j['name'] ?? ''}',
        to: '${j['to'] ?? '*'}',
        toAll: j['toAll'] != false,
        kind: '${j['kind'] ?? ChatKind.text}',
        text: '${j['text'] ?? ''}',
        enc: '${j['enc'] ?? ChatEnc.none}',
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        mine: j['mine'] == true,
        delivered: j['delivered'] == true,
        pending: j['pending'] == true,
        file: j['file'] is Map ? Map<String, dynamic>.from(j['file']) : null,
      );
}

/// 生成消息 id。时间戳 base36 + 随机后缀，冲突概率可忽略。
String newMid([int? nowMs]) {
  final t = (nowMs ?? DateTime.now().millisecondsSinceEpoch).toRadixString(36);
  final r = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return '$t-${r.substring(r.length > 5 ? r.length - 5 : 0)}';
}

/// 去重：按 `(from, mid)` 复合键。**返回保持输入顺序**。
///
/// 为什么必须要它：局域网里一条消息常常会**同时**以广播与单播到达，
/// 不去重就会看到两条一模一样的消息——这是最容易让用户以为"程序坏了"的假象。
List<LanMessage2> dedupeMessages(Iterable<LanMessage2> input) {
  final seen = <String>{};
  final out = <LanMessage2>[];
  for (final m in input) {
    final k = '${m.from}\u0000${m.mid}';
    if (seen.add(k)) out.add(m);
  }
  return out;
}

/// 确定性排序：先 `ts`，相同则用 `mid` 字典序兜底。
///
/// ★ 兜底不能省。局域网设备时钟通常同源，但只要有一台慢了，
///   相等 ts 的两条消息顺序就会每次渲染都不同 → 列表肉眼可见地跳动。
int compareMessages(LanMessage2 a, LanMessage2 b) {
  final c = a.ts.compareTo(b.ts);
  if (c != 0) return c;
  return a.mid.compareTo(b.mid);
}

/// 排序 + 去重（列表渲染前的唯一入口）。
List<LanMessage2> normalizeMessages(Iterable<LanMessage2> input) {
  final l = dedupeMessages(input);
  l.sort(compareMessages);
  return l;
}

/// 单会话本地保留上限。
const int kLanMsgKeep = 500;

/// 截断到保留上限（丢最旧的，保留最新）。
List<LanMessage2> trimMessages(List<LanMessage2> sorted) =>
    sorted.length <= kLanMsgKeep
        ? sorted
        : sorted.sublist(sorted.length - kLanMsgKeep);

// ═══════════════════════════════════════════════════════════════════════════
// 好友
// ═══════════════════════════════════════════════════════════════════════════

/// 一个被保存为好友的设备。
///
/// `fp`（公钥指纹）是**独立于广播名字**的身份锚点：广播里的 `name` 谁都能改，
/// 指纹不能。UI 上核对指纹才是真正的"确认是这个人"。
class ChatFriend {
  final String id; // 设备 id
  String name;
  String host; // 最近一次看到的 IP
  String fp; // 公钥指纹（hex，前 8 字节）
  int lastSeen;
  bool blocked;

  ChatFriend({
    required this.id,
    required this.name,
    required this.host,
    this.fp = '',
    int? lastSeen,
    this.blocked = false,
  }) : lastSeen = lastSeen ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'fp': fp,
        'lastSeen': lastSeen,
        'blocked': blocked,
      };

  factory ChatFriend.from(Map<String, dynamic> j) => ChatFriend(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? '设备'}',
        host: '${j['host'] ?? ''}',
        fp: '${j['fp'] ?? ''}',
        lastSeen: (j['lastSeen'] as num?)?.toInt(),
        blocked: j['blocked'] == true,
      );
}

/// 好友可见性：被拉黑的设备不出现在列表里（但消息仍可收下用于报错提示）。
bool isFriendVisible(ChatFriend f, {required bool online}) =>
    !f.blocked && (online || f.lastSeen > 0);

// ═══════════════════════════════════════════════════════════════════════════
// 会话（好友会话 / 区域频道）
// ═══════════════════════════════════════════════════════════════════════════

/// 区域频道的固定会话 id。
const String kBroadcastSid = '__lan_broadcast__';

/// 好友私聊会话 id。
String friendSid(String peerId) => 'lan:$peerId';

// ═══════════════════════════════════════════════════════════════════════════
// 降级判定 —— 决定"这条消息到底加不加密"
// ═══════════════════════════════════════════════════════════════════════════

/// 本端打算怎么发这条消息。[reason] 用于 UI 说明（STYLE_GUIDE 第 2 条三段式）。
class SendPlan {
  final String enc; // ChatEnc.none | ChatEnc.x25519AesGcm
  final String? reason; // 降级原因（不降级时 null）

  const SendPlan(this.enc, [this.reason]);

  bool get encrypted => enc == ChatEnc.x25519AesGcm;
}

/// 依据「是否广播 / 对端能力 / 是否有对端公钥」决定加密方案。
///
/// 传播序（与协议 §4.3 一致）：
///   广播 → 一定明文（一对多没有群密钥，也不假装有）
///   已知对端 pk 且对端声明 enc → 端到端加密
///   其余 → 明文 + 说明原因（绝不静默降级）
SendPlan planSend({
  required bool broadcast,
  required bool peerSupportsEnc,
  required bool havePeerKey,
}) {
  if (broadcast) {
    return const SendPlan(ChatEnc.none, '区域频道为局域网广播，同网段设备均可看到，未加密');
  }
  if (!peerSupportsEnc) {
    return const SendPlan(ChatEnc.none, '对方版本较旧，不支持加密');
  }
  if (!havePeerKey) {
    return const SendPlan(ChatEnc.none, '尚未收到对方公钥（等一次设备发现即可）');
  }
  return const SendPlan(ChatEnc.x25519AesGcm);
}

// ═══════════════════════════════════════════════════════════════════════════
// 报文构造 / 解析（v2 信封）
// ═══════════════════════════════════════════════════════════════════════════

/// 编码一条 v2 报文（含 `app`/`v` 信封）。
String encodeV2(Map<String, dynamic> m) =>
    jsonEncode({...m, 'app': 'thirdhub', 'v': kLanChatVersion});

/// 解析 v2 报文。
///
/// 返回 null 的情形（与既有 `lanDecode` 同口径，**公网上什么包都有，不能崩**）：
///  - 不是本应用的包（`app != 'thirdhub'`）
///  - 坏 JSON
///  - 缺 `t`
///  - `v` 存在且 > 本端版本（不猜测未来格式，直接丢弃）
Map<String, dynamic>? decodeV2(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return null;
    final m = Map<String, dynamic>.from(j);
    if (m['app'] != 'thirdhub') return null;
    if (m['t'] == null) return null;
    final v = (m['v'] as num?)?.toInt();
    if (v != null && v > kLanChatVersion) return null; // 未来版本，不猜
    return m;
  } catch (_) {
    return null;
  }
}

/// 旧的 v1 报文（无 `v` 字段或 `v == 1`）—— 仍接受，走纯文本降级路径。
bool isLegacyEnvelope(Map<String, dynamic> m) {
  final v = (m['v'] as num?)?.toInt();
  return v == null || v < 2;
}

/// 文件传输上限：2 GB。超过走「文件互传」模块，聊天不是传输工具。
const int kChatFileMaxBytes = 2 * 1024 * 1024 * 1024;

/// 正文长度上限（防止一条消息把 SharedPreferences 撑爆）。
const int kChatTextMaxChars = 8000;

/// 截断超长正文，返回 (正文, 是否被截断)。
(String, bool) clampText(String t) {
  if (t.length <= kChatTextMaxChars) return (t, false);
  return (t.substring(0, kChatTextMaxChars), true);
}

/// 人类可读的文件大小。
String fmtBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
