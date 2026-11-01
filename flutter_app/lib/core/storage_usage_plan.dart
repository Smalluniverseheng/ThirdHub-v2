// ═══════════════════════════════════════════════════════════════════════════
// 存储明细的**规则层**（纯 Dart，零 Flutter 依赖）
//
// 为什么要有这一层（2026-11-02，待办清单第 2 项）：
//   旧版「云存储」页只有一个数字 —— `AppSettings.localUsageKB`，算法是
//   **5 个 prefs 键的字符串长度之和**（avatar_b64 / nickname / fontSize /
//   readerTheme / pageMode）。那个数既不含落盘文件、也不含会话消息、更不含
//   云端那几张表。于是用户在系统设置里看到"本应用占 300MB"，回到这里看到
//   "12.3KB / 10MB"，两个数字互相矛盾，谁也解释不了 —— 而"一个说不清的数字"
//   的实际价值是零：它不告诉你下一步该删什么。
//
//   这里把「存了什么」拆成 **文件 / 会话 / 设置** 三组，每组给出**条数 + 占用**。
//
// 分工（照 offline_media_plan / offline_media_store 的既有做法）：
//   · 本文件：只算，不碰磁盘、不碰平台通道 → `dart run tool/storage_usage_selfcheck.dart`
//     能用合成数据把它跑一遍（本机 PUB_CACHE 为空，flutter test 跑不起来）。
//   · storage_usage.dart：IO 层，负责读 prefs、扫目录，然后调用这里的 compute()。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';

/// 一行明细：一个具体的东西（某类文件 / 某类会话 / 设置项）。
///
/// [label] 是**中文原文即 i18n key**，UI 层再 `tr(label)`；
/// [unit] 同理（数量单位：项 / 个 / 条）。
class UsageRow {
  final String label;
  final String unit;
  final int count;
  final int bytes;

  const UsageRow(this.label, this.count, this.bytes, {this.unit = '项'});
}

/// 一组明细（文件 / 会话 / 设置 / 云端）。
class UsageGroup {
  final String title;
  final List<UsageRow> rows;

  const UsageGroup(this.title, this.rows);

  int get count => rows.fold(0, (a, r) => a + r.count);
  int get bytes => rows.fold(0, (a, r) => a + r.bytes);
}

/// 一个目录的扫描结果（IO 层填，规则层只读）。
class DirStat {
  final String label;
  final int files;
  final int bytes;

  const DirStat(this.label, this.files, this.bytes);
}

/// 存储明细快照。
class StorageUsage {
  /// 分组，顺序固定：文件 → 会话 → 设置（UI 直接按这个顺序渲染）。
  final List<UsageGroup> groups;

  const StorageUsage(this.groups);

  int get totalBytes => groups.fold(0, (a, g) => a + g.bytes);
  int get totalItems => groups.fold(0, (a, g) => a + g.count);

  /// 设置组（"设置项 N 项"那一组）—— 单列出来是因为它才是**计入云配额**的部分。
  UsageGroup get settingsGroup =>
      groups.firstWhere((g) => g.title == '设置', orElse: () => const UsageGroup('设置', []));

  // ── prefs 键的分类口径 ──
  //
  // 只按**键名**分类，不看值：会话/消息/待发箱是 ChatStore（chat.dart）的固定键，
  // 其余一律算设置。这样不必维护一张"设置键白名单"——白名单一定会漏，
  // 漏掉的新键会被算成"其他地方"，用户就更看不懂了。
  static const String kSessionsKey = 'chat_sessions';
  static const String kOutboxKey = 'chat_outbox';
  static const String kMsgPrefix = 'chat_msgs_';

  /// 纯计算：给定 prefs 快照与目录扫描结果，产出明细。
  ///
  /// [prefs] 必须是把 SharedPreferences 全部键读出来的普通 Map（见 scan()）。
  /// [dirs] 由 IO 层按固定顺序给出（日志 / 接收文件 / 离线媒体 / 离线书 /
  /// 本地导入 / 任务产物 / 其他）。
  static StorageUsage compute({
    required Map<String, dynamic> prefs,
    required List<DirStat> dirs,
  }) {
    var settingKeys = 0, settingBytes = 0;
    var sessCount = 0, sessBytes = 0;
    var msgCount = 0, msgBytes = 0;
    var outCount = 0, outBytes = 0;

    prefs.forEach((k, v) {
      final int b = _prefsBytes(k, v);
      if (k == kSessionsKey) {
        sessCount += _itemCount(v);
        sessBytes += b;
      } else if (k == kOutboxKey) {
        outCount += _itemCount(v);
        outBytes += b;
      } else if (k.startsWith(kMsgPrefix)) {
        msgCount += _itemCount(v);
        msgBytes += b;
      } else {
        settingKeys++;
        settingBytes += b;
      }
    });

    final files = <UsageRow>[
      for (final d in dirs) UsageRow(d.label, d.files, d.bytes, unit: '个'),
    ];

    final sessions = <UsageRow>[
      UsageRow('聊天会话', sessCount, sessBytes, unit: '个'),
      UsageRow('消息记录', msgCount, msgBytes, unit: '条'),
      UsageRow('待发消息', outCount, outBytes, unit: '条'),
    ];

    final settings = <UsageRow>[
      UsageRow('本机设置项', settingKeys, settingBytes),
    ];

    return StorageUsage(<UsageGroup>[
      UsageGroup('文件', files),
      UsageGroup('会话', sessions),
      UsageGroup('设置', settings),
    ]);
  }

  /// 一个 prefs 条目的大致占用（字节）。
  ///
  /// 口径：`utf8(键名) + utf8(值)`。这个数**不等于** SharedPreferences 在
  /// 磁盘上的真实占用（可能是 XML/JSON + 压缩），但对"谁大谁小"这个用途足够，
  /// 且与云端行载荷的口径可比。UI 上标 `≈` 而不是 `=`。
  static int _prefsBytes(String k, Object? v) {
    final int kb = utf8.encode(k).length;
    if (v == null) return kb;
    if (v is String) return kb + utf8.encode(v).length;
    if (v is List) {
      var n = kb;
      for (final e in v) {
        n += utf8.encode('$e').length;
      }
      return n;
    }
    return kb + utf8.encode('$v').length;
  }

  static int _itemCount(Object? v) => v is List ? v.length : (v == null ? 0 : 1);

  /// 人类可读的大小（B / KB / MB / GB）。
  ///
  /// 刻意不用 intl：这个函数要在纯 Dart 自检里跑，不能拉 Flutter/本地化依赖。
  /// 小数位按量级收敛，避免出现 `1023.99 KB` 这种看着像 bug 的数。
  static String formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    final double kb = bytes / 1024;
    if (kb < 1024) return '${_trim(kb)} KB';
    final double mb = kb / 1024;
    if (mb < 1024) return '${_trim(mb)} MB';
    return '${_trim(mb / 1024)} GB';
  }

  /// 1 位小数；整数不补 `.0`。≥100 直接取整（100.4MB 写 100MB 更干净）。
  static String _trim(double v) {
    if (v >= 100) return v.round().toString();
    final String s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}
