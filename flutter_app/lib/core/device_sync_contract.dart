// 三端统一账号绑定与设备互通同步契约 v1（全盘升级任务 #202）
//
// 唯一真源：仓库根 contracts/unified_sync_v1.json。
// 本文件是它的**移动端镜像**；桌面端见 server/device_sync_contract.js，
// 网页端沿用 js/supabase.js 的 SYNC_TABLES / TBL_MAP。
// 三份字典逐键一致由 tool/device_sync_contract_selfcheck.dart 断言 ——
// 「改了一边忘了另一边」会当场红，这正是本轮要收口的老问题：
// 此前 6 张同步表在 App、网页端、后端各写一份，谁加一张表另外两端都不知道。
//
// 设计约束（与 core/sync_contract.dart 同一套规矩）：
//   · 零 import、零 Flutter、零 IO —— 本机 PUB_CACHE 是空的，
//     tool 里的自检必须能直接 import 并**真跑**这些函数，而不是只 grep 源码形状。
//   · 所有字符串字面量都是英文标识符：中文只出现在注释里，
//     否则 i18n_hardcoded 棘轮闸门与 branding 闸门会把数据表常量当成 UI 文案。
//   · 术语：前端 = 移动端，后端 = 桌面端，资料库 = 用户自装的资料服务。
//
// 「一个账号绑定后全端互通」的落地口径：
//   ① 账号隔离键 = user_id（归一化后），所有端读写同一命名空间；
//   ② 设备表 th_user_devices 记录账号下每台设备，设备发现走 th_devices，
//      配对走 th_device_pairs，会话走 th_chats；
//   ③ 同步表 6 张：书架 / 进度 / 历史 / 收藏 / 设置 / 设备；
//   ④ 官方云端（跨网）与设备直连（同网 / IPv6 / P2P）双通道，任一可用即同步；
//   ⑤ 冲突按 updated_at 后写胜出，同秒按设备优先级，再同按 device_id 定序；
//   ⑥ 删除走墓碑，不硬删（沿用 core/sync_contract.dart 的 tombKeyOf 口径）；
//   ⑦ 设置类表所有登录用户可同步，内容类表需会员或自托管（沿用 Cloud.canSyncTable）。

/// 契约标识。任何一端发现版本不一致就应拒绝合并，而不是猜着合。
const String kSyncSchema = 'thirdhub.unified_sync/1';
const String kSyncContractVersion = '1.0.0';

/// 一个账号绑定后，所有端共用的同步表。
/// 顺序与网页端 js/supabase.js 的 SYNC_TABLES 逐字一致，不要重排。
const List<String> kSyncTables = <String>[
  'th_bookshelf',
  'th_reading_progress',
  'th_history',
  'th_favorites',
  'th_settings',
  'th_user_devices',
];

/// 会话 / 设备发现 / 配对三张表：不进 6 张同步信封，各有自己的通道。
const String kSessionTable = 'th_chats';
const String kDeviceTable = 'th_user_devices';
const String kDiscoveryTable = 'th_devices';
const String kPairTable = 'th_device_pairs';

/// 设备类型：移动端 / 网页端 / 桌面端 EXE / NAS 容器。
const List<String> kDeviceKinds = <String>['mobile', 'web', 'exe', 'nas'];

/// 设备表行必备字段（与云端 th_user_devices.data 的载荷一致）。
const List<String> kDeviceRequiredFields = <String>[
  'device_id',
  'name',
  'kind',
  'capabilities',
  'last_seen',
  'user_id',
];

/// 同秒冲突时的设备优先级：NAS 常开 > 桌面端 EXE > 网页端 > 移动端。
const Map<String, int> kDevicePriority = <String, int>{
  'nas': 40,
  'exe': 30,
  'web': 20,
  'mobile': 10,
};

const List<String> kDeviceCapabilities = <String>[
  'sync',
  'direct',
  'relay',
  'notify',
];

/// 双通道：官方云端（跨网）+ 设备直连（同网 / IPv6 / P2P，低延迟）。
const List<String> kSyncChannels = <String>['official_cloud', 'device_direct'];
const List<String> kSyncTransports = <String>['lan', 'ipv6', 'p2p', 'relay'];

/// 设置类表所有登录用户都能同步；内容类表需会员或自托管。
const List<String> kSettingsTables = <String>[
  'th_settings',
  'th_user_devices',
];
const List<String> kContentTables = <String>[
  'th_bookshelf',
  'th_reading_progress',
  'th_history',
  'th_favorites',
];

const String kConflictStrategy = 'updated_at_lww';
const String kTieBreak = 'device_priority_then_device_id';
const String kDeleteRule = 'tombstone';

/// 账号隔离键：一个账号 = 一个命名空间，所有端读写同一空间。
/// 空账号一律返回空串，调用方必须据此拒绝 —— 拿空串去查云端会读到别人的行。
String accountScopeOf(String userId) => userId.trim().toLowerCase();

bool isValidAccountScope(String userId) => accountScopeOf(userId).isNotEmpty;

int _epochMsOf(Object? v) {
  if (v is int) return v < 0 ? 0 : v;
  if (v is num) {
    final int n = v.toInt();
    return n < 0 ? 0 : n;
  }
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

/// 设备行规范化。
///
/// 返回 null 表示**整行丢弃**，绝不「洗白」成合法值：
///   · 空账号 / 空 device_id / 超长 id 一律拒；
///   · id 里带路径分隔符或 `..` 一律拒（它会拿去拼存储路径，见 zip-slip 教训）；
///   · 类型不在 4 种之内一律拒，不悄悄回落成 mobile（回落会让 NAS 被当成手机）；
///   · 能力白名单外的值丢弃，一个都不剩就补 'sync'。
Map<String, dynamic>? normalizeDeviceRow(
  Map<String, dynamic> raw, {
  required String accountId,
}) {
  final String scope = accountScopeOf(accountId);
  if (scope.isEmpty) return null;
  final String id = '${raw['device_id'] ?? ''}'.trim();
  if (id.isEmpty || id.length > 128) return null;
  if (id.contains('/') || id.contains('\\') || id.contains('..')) return null;
  final String kind = '${raw['kind'] ?? ''}'.trim().toLowerCase();
  if (!kDeviceKinds.contains(kind)) return null;
  final List<String> caps = <String>[];
  final Object? capsRaw = raw['capabilities'];
  if (capsRaw is List) {
    for (final Object? c in capsRaw) {
      final String s = '$c'.trim().toLowerCase();
      if (kDeviceCapabilities.contains(s) && !caps.contains(s)) caps.add(s);
    }
  }
  if (caps.isEmpty) caps.add('sync');
  final String name = '${raw['name'] ?? ''}'.trim();
  return <String, dynamic>{
    'device_id': id,
    'name': name.isEmpty ? kind : name,
    'kind': kind,
    'capabilities': caps,
    'last_seen': _epochMsOf(raw['last_seen']),
    'user_id': scope,
  };
}

/// 冲突裁决：后写胜出；同一毫秒按设备优先级；仍相同按 device_id 字典序（确定性）。
/// 返回 'local' / 'cloud' / 'equal'。
String resolveConflict({
  required int localTs,
  required int cloudTs,
  required String localKind,
  required String cloudKind,
  required String localDeviceId,
  required String cloudDeviceId,
}) {
  if (localTs > cloudTs) return 'local';
  if (cloudTs > localTs) return 'cloud';
  final int lp = kDevicePriority[localKind] ?? 0;
  final int cp = kDevicePriority[cloudKind] ?? 0;
  if (lp > cp) return 'local';
  if (cp > lp) return 'cloud';
  final int c = localDeviceId.compareTo(cloudDeviceId);
  if (c > 0) return 'local';
  if (c < 0) return 'cloud';
  return 'equal';
}

/// 双通道选路：直连可用就走直连（低延迟），否则回落官方云端，都不通则离线排队。
String pickChannel({
  required bool directReachable,
  required bool cloudReachable,
}) {
  if (directReachable) return 'device_direct';
  if (cloudReachable) return 'official_cloud';
  return 'offline';
}

/// 表级权限：与 Cloud.canSyncTable 同一口径，服务端也要过这道闸门
/// （不是前端隐藏按钮 —— 合规分层要求服务端真校验）。
bool canSyncTable({
  required String table,
  required bool loggedIn,
  required bool isMember,
  required bool selfHosted,
}) {
  if (!loggedIn) return false;
  if (!kSyncTables.contains(table)) return false;
  if (kContentTables.contains(table)) return isMember || selfHosted;
  return true;
}

/// 墓碑键：与 core/sync_contract.dart 的 tombKeyOf 逐字一致。
/// 同一本书在书架和历史里是两行，必须按表隔离，否则删书架会连历史一起删。
String tombstoneKeyOf(String table, String rowId) => '$table:$rowId';

/// 多端设备列表合并：按 device_id 去重，同一台保留 last_seen 最新的那行。
/// 输出按 id 排序，保证三端算出的顺序一致（不然设备列表会来回跳）。
List<Map<String, dynamic>> mergeDevices(Iterable<Map<String, dynamic>> rows) {
  final Map<String, Map<String, dynamic>> byId = <String, Map<String, dynamic>>{};
  for (final Map<String, dynamic> r in rows) {
    final String id = '${r['device_id'] ?? ''}'.trim();
    if (id.isEmpty) continue;
    final Map<String, dynamic>? prev = byId[id];
    if (prev == null || _epochMsOf(r['last_seen']) >= _epochMsOf(prev['last_seen'])) {
      byId[id] = r;
    }
  }
  final List<String> ids = byId.keys.toList()..sort();
  return <Map<String, dynamic>>[for (final String id in ids) byId[id]!];
}

/// 会话合并：一个账号下所有端的会话按 id 去重、按时间戳倒序（最新在前）。
/// 沿用 core/dsh_hosts.dart 的 allSessions() 口径：会话跑在 Host 上，
/// 客户端只是把各端列表合成一个视图，不搬数据库。
List<Map<String, dynamic>> mergeSessions(Iterable<Map<String, dynamic>> rows) {
  final Map<String, Map<String, dynamic>> byId = <String, Map<String, dynamic>>{};
  for (final Map<String, dynamic> r in rows) {
    final String id = '${r['id'] ?? ''}'.trim();
    if (id.isEmpty) continue;
    final Map<String, dynamic>? prev = byId[id];
    if (prev == null || _epochMsOf(r['updated_at']) >= _epochMsOf(prev['updated_at'])) {
      byId[id] = r;
    }
  }
  final List<Map<String, dynamic>> out = byId.values.toList();
  out.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
    final int d = _epochMsOf(b['updated_at']) - _epochMsOf(a['updated_at']);
    return d != 0 ? d : '${a['id']}'.compareTo('${b['id']}');
  });
  return out;
}
