// 统一最近播放(规划 M-4): 音乐/视频/有声书 播什么记什么, 一处回看一处续播
// 存 SharedPreferences 'recent_play': [{kind,title,sub,target,at}], 按时间倒序, 上限 60
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class Recents {
  static const _key = 'recent_play';
  static const _max = 60;

  /// 记一条。kind: music/video/audiobook/live; target: 本地路径或可打开的标识
  static Future<void> add(String kind, String title, {String sub = '', String target = ''}) async {
    if (title.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final items = await list();
      items.removeWhere((e) => e['target'] == target && target.isNotEmpty && e['kind'] == kind);
      items.insert(0, {'kind': kind, 'title': title, 'sub': sub, 'target': target,
        'at': DateTime.now().toString().substring(0, 16)});
      await p.setString(_key, jsonEncode(items.take(_max).toList()));
    } catch (_) {}
  }

  static Future<List<Map<String, String>>> list() async {
    try {
      final p = await SharedPreferences.getInstance();
      return [ for (final e in jsonDecode(p.getString(_key) ?? '[]') as List) Map<String, String>.from(e as Map) ];
    } catch (_) { return []; }
  }

  static Future<void> remove(String kind, String target) async {
    try {
      final p = await SharedPreferences.getInstance();
      final items = await list();
      items.removeWhere((e) => e['kind'] == kind && e['target'] == target);
      await p.setString(_key, jsonEncode(items));
    } catch (_) {}
  }
}
