// 源健康：让「坏源」自己退场，而不是让用户在界面上读到一条诊断报告。
//
// ── 为什么要有这个文件 ────────────────────────────────────────────────
//   4.81.87 之前，页面在顶部列一行「今日诗词、一言、维基文库、古登堡
//   （澳洲站）当前不可达，可能被网络阻断」—— 而下面明明躺着诗词和古登堡
//   的书。三件事同时错了：
//     ① 判定来源是 ping 首页，站点不支持 HEAD 或慢一点就判死；
//     ② 判定结果只用来画横幅，**和取数完全脱钩**——死的照样参与搜索；
//     ③ 把四个源名堆在一句话里，视觉上等于告诉用户"这里全废了"。
//
//   正确的做法是让判定**驱动行为**：坏源进冷却期，搜索时直接跳过，
//   界面上什么都不说。用户看到的只有"有内容"或"真的没内容"两种状态。
//
// ── 什么叫"坏" ──────────────────────────────────────────────────────
//   · 请求异常（超时 / 连接被拒 / 5xx / 解析崩）→ 计一次失败
//   · 返回 0 条结果 → **正常**。空结果是合法答复，不算坏
//     （「火影」在 MangaDex 是「狐忍」，搜不到不代表源坏了）
//   · 连续 [failThreshold] 次失败 → 进冷却，[cooldown] 内不参与
//   · 冷却到期自动放行一次；成功即恢复，再失败继续冷却（指数拉长，上限 2 小时）
//
// ── 为什么落盘 ──────────────────────────────────────────────────────
//   不落盘的话每次冷启动都重新撞一遍坏源，首屏要多等一个超时。
//   落盘后重启也认得"这个源上次连挂 3 次"，直接跳过。
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 单个源的体检记录。
class SourceStat {
  /// 连续失败次数（成功一次即清零）。
  int fails;

  /// 冷却截止时间。null / 已过期 = 可用。
  DateTime? cooldownUntil;

  DateTime? lastOkAt;
  DateTime? lastFailAt;

  /// 最近一次成功的耗时与条数（给体检面板看趋势，不参与判定）。
  int lastMs;
  int lastCount;

  /// 最近一次失败的原因（仅面板展示）。
  String lastReason;

  SourceStat({
    this.fails = 0,
    this.cooldownUntil,
    this.lastOkAt,
    this.lastFailAt,
    this.lastMs = 0,
    this.lastCount = 0,
    this.lastReason = '',
  });

  Map<String, dynamic> toJson() => {
        'f': fails,
        'c': cooldownUntil?.millisecondsSinceEpoch,
        'o': lastOkAt?.millisecondsSinceEpoch,
        'x': lastFailAt?.millisecondsSinceEpoch,
        'm': lastMs,
        'n': lastCount,
        'r': lastReason,
      };

  static SourceStat fromJson(Map<String, dynamic> j) => SourceStat(
        fails: (j['f'] as num?)?.toInt() ?? 0,
        cooldownUntil: _dt(j['c']),
        lastOkAt: _dt(j['o']),
        lastFailAt: _dt(j['x']),
        lastMs: (j['m'] as num?)?.toInt() ?? 0,
        lastCount: (j['n'] as num?)?.toInt() ?? 0,
        lastReason: '${j['r'] ?? ''}',
      );

  static DateTime? _dt(dynamic v) {
    final n = (v as num?)?.toInt();
    if (n == null || n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(n);
  }
}

/// 源健康总账。全部静态方法，App 全局一份。
class SourceHealth {
  SourceHealth._();

  static const String _key = 'free_source_health_v1';

  /// 连续失败几次进冷却。2 次是「一次抖动」和「真挂了」的分界：
  /// 只挂 1 次就冷却会把临时抽风的源误杀，3 次又要白等两轮。
  static const int failThreshold = 2;

  /// 首次冷却时长。
  static const Duration cooldown = Duration(minutes: 10);

  /// 冷却上限。反复挂的源最终也不该被永久判死 —— 用户换网就好了。
  static const Duration maxCooldown = Duration(hours: 2);

  static final Map<String, SourceStat> _stats = {};

  static bool _loaded = false;
  static bool _dirty = false;
  static Timer? _flushTimer;

  /// 预热。幂等，可被任意入口重复调用。
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      m.forEach((k, v) {
        if (v is Map) {
          _stats['$k'] = SourceStat.fromJson(Map<String, dynamic>.from(v));
        }
      });
    } catch (_) {
      // 存档坏了就当没有 —— 体检数据不值得为它中断启动。
    }
  }

  /// 该源现在能不能用。
  ///
  /// 冷却中返回 false，这时调用方应当**直接跳过**，不要发请求。
  /// 冷却到期后自动放行，让他再试一次。
  static bool isUsable(String id) {
    final s = _stats[id];
    if (s == null) return true;
    final until = s.cooldownUntil;
    if (until == null) return true;
    return DateTime.now().isAfter(until);
  }

  /// 冷却剩余时间。null = 没在冷却。
  static Duration? cooldownLeft(String id) {
    final until = _stats[id]?.cooldownUntil;
    if (until == null) return null;
    final d = until.difference(DateTime.now());
    return d.isNegative ? null : d;
  }

  /// 一次成功（哪怕 0 条）。耗时与条数只做记录，不参与判定。
  static void reportOk(String id, {int ms = 0, int count = 0}) {
    final s = _stats.putIfAbsent(id, () => SourceStat());
    s.fails = 0;
    s.cooldownUntil = null;
    s.lastOkAt = DateTime.now();
    s.lastMs = ms;
    s.lastCount = count;
    s.lastReason = '';
    _markDirty();
  }

  /// 一次失败。[soft] 为 true 表示「源答复了，只是这份结果不合用」
  /// （例如解析不到字段，但 HTTP 是 200）—— 不计入冷却，只记一笔原因。
  static void reportFail(String id, String reason, {bool soft = false}) {
    final s = _stats.putIfAbsent(id, () => SourceStat());
    s.lastFailAt = DateTime.now();
    s.lastReason = reason;
    if (soft) {
      _markDirty();
      return;
    }
    s.fails += 1;
    if (s.fails >= failThreshold) {
      // 冷却时长随失败次数递增：2 次 10 分钟、3 次 20、4 次 40…上限 2 小时。
      final step = s.fails - failThreshold;
      final mult = 1 << (step > 4 ? 4 : step);
      var d = cooldown * mult;
      if (d > maxCooldown) d = maxCooldown;
      s.cooldownUntil = DateTime.now().add(d);
    }
    _markDirty();
  }

  /// 用户手动点「全部重检」时清账。
  static Future<void> reset([String? id]) async {
    if (id == null) {
      _stats.clear();
    } else {
      _stats.remove(id);
    }
    _dirty = true;
    await flush(force: true);
  }

  /// 体检快照（给「源体检」面板与自检脚本用）。
  static List<Map<String, dynamic>> snapshot() {
    final out = <Map<String, dynamic>>[];
    _stats.forEach((id, s) {
      out.add({
        'id': id,
        'fails': s.fails,
        'cooling': !isUsable(id),
        'cooldownMin': cooldownLeft(id)?.inMinutes,
        'lastOk': s.lastOkAt?.toIso8601String(),
        'lastFail': s.lastFailAt?.toIso8601String(),
        'lastMs': s.lastMs,
        'lastCount': s.lastCount,
        'reason': s.lastReason,
      });
    });
    out.sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
    return out;
  }

  /// 冷却中的源数量（给设置页一个角标用）。
  static int get coolingCount =>
      _stats.keys.where((id) => !isUsable(id)).length;

  /// 累计失败次数（用于「全都冷却了就先试最不坏的那个」）。
  static int failsOf(String id) => _stats[id]?.fails ?? 0;

  // ── 落盘 ────────────────────────────────────────────────────────
  // 每次搜索都会产生几十次 reportOk，逐次写盘会把主线程磨死。
  // 这里只在内存改，攒够 20 秒统一落一次。

  static void _markDirty() {
    _dirty = true;
    _flushTimer ??= Timer(const Duration(seconds: 20), () {
      _flushTimer = null;
      flush();
    });
  }

  static Future<void> flush({bool force = false}) async {
    if (!_dirty && !force) return;
    _dirty = false;
    try {
      final p = await SharedPreferences.getInstance();
      final m = <String, dynamic>{};
      _stats.forEach((k, v) => m[k] = v.toJson());
      await p.setString(_key, jsonEncode(m));
    } catch (_) {
      // 写不进去就算了，下次启动重新体检。
    }
  }
}
