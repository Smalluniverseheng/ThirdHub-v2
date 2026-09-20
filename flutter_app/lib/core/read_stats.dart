// 阅读统计(规划 R-1): 阅读时长 + 阅读字数, 按天累计, 书架页出周报
// 存 SharedPreferences 'read_stats': { 'YYYY-MM-DD': {'sec': n, 'chars': n} }
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ReadStats {
  static const _key = 'read_stats';
  static String _today() { final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}'; }

  /// 累加今天的阅读时长(秒)与字数。阅读器每 30 秒打一次点 + 每读完一章记字数。
  static Future<void> tick({int sec = 0, int chars = 0}) async {
    if (sec <= 0 && chars <= 0) return;
    try {
      final p = await SharedPreferences.getInstance();
      final m = await load();
      final d = m[_today()] ?? {'sec': 0, 'chars': 0};
      d['sec'] = (d['sec'] ?? 0) + sec;
      d['chars'] = (d['chars'] ?? 0) + chars;
      m[_today()] = d;
      await p.setString(_key, jsonEncode(m));
    } catch (_) {}
  }

  static Future<Map<String, Map<String, int>>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = jsonDecode(p.getString(_key) ?? '{}') as Map<String, dynamic>;
      return { for (final e in raw.entries) e.key: { 'sec': (e.value['sec'] ?? 0) as int, 'chars': (e.value['chars'] ?? 0) as int } };
    } catch (_) { return {}; }
  }

  /// (今日秒, 今日字数, 本周秒, 本周字数)
  static Future<(int, int, int, int)> summary() async {
    final m = await load();
    final today = m[_today()] ?? {'sec': 0, 'chars': 0};
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    var wSec = 0, wChars = 0;
    for (final e in m.entries) {
      try {
        final d = DateTime.parse(e.key);
        if (!d.isBefore(DateTime(weekStart.year, weekStart.month, weekStart.day))) {
          wSec += e.value['sec'] ?? 0; wChars += e.value['chars'] ?? 0;
        }
      } catch (_) {}
    }
    return (today['sec'] ?? 0, today['chars'] ?? 0, wSec, wChars);
  }
}
