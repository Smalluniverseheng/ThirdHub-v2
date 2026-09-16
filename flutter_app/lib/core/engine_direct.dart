// 前端直连引擎(THP): 不经过后端, 直接向局域网引擎发起搜索/目录/内容请求
// 协议见 docs/THP.md: /thp/meta · /thp/search · /thp/chapters · /thp/content · /thp/discover
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'discover.dart';

class EngineDirect {
  static String url = ''; // 选中的直连引擎地址(空=未连接)
  static String name = '';
  static List<String> caps = [];

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    url = p.getString('engine_direct_url') ?? '';
    name = p.getString('engine_direct_name') ?? '';
    caps = p.getStringList('engine_direct_caps') ?? [];
  }
  static Future<void> connect(String u) async {
    // 校验 /thp/meta
    final r = await http.get(Uri.parse('$u/thp/meta')).timeout(const Duration(seconds: 8));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final m = (j['data'] is Map ? j['data'] : j) as Map;
    final p = await SharedPreferences.getInstance();
    url = u; name = '${m['name'] ?? 'THP 引擎'}';
    caps = [ for (final x in (m['caps'] as List? ?? [])) '$x' ];
    await p.setString('engine_direct_url', url);
    await p.setString('engine_direct_name', name);
    await p.setStringList('engine_direct_caps', caps);
  }
  static Future<void> disconnect() async {
    url = ''; name = ''; caps = [];
    final p = await SharedPreferences.getInstance();
    await p.remove('engine_direct_url'); await p.remove('engine_direct_name'); await p.remove('engine_direct_caps');
  }
  static bool get connected => url.isNotEmpty;

  static Future<Map<String, dynamic>> _get(String path) async {
    final r = await http.get(Uri.parse('$url$path')).timeout(const Duration(seconds: 15));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map && j['object'] == 'error') throw Exception('${j['data']?['message'] ?? '引擎错误'}');
    if (j is Map && j['error'] != null) throw Exception('${j['error']}');
    return (j is Map && j.containsKey('data') ? {'data': j['data'], 'meta': j['meta']} : {'data': j}) as Map<String, dynamic>;
  }

  // 搜索: type= novel/comic/video/music
  static Future<List<Map<String, dynamic>>> search(String type, String q) async {
    final r = await _get('/thp/search?type=$type&q=${Uri.encodeComponent(q)}');
    final items = r['data'] is Map ? (r['data']['items'] as List? ?? []) : (r['data'] as List? ?? []);
    return [ for (final e in items) Map<String, dynamic>.from(e) ];
  }
  // 目录/选集
  static Future<List<Map<String, dynamic>>> chapters(String type, String id) async {
    final r = await _get('/thp/chapters?type=$type&id=${Uri.encodeComponent(id)}');
    final items = r['data'] is Map ? (r['data']['items'] as List? ?? []) : (r['data'] as List? ?? []);
    return [ for (final e in items) Map<String, dynamic>.from(e) ];
  }
  // 正文/图片/播放地址
  static Future<Map<String, dynamic>> content(String type, String id, String chapter) async {
    final r = await _get('/thp/content?type=$type&id=${Uri.encodeComponent(id)}&chapter=${Uri.encodeComponent(chapter)}');
    return Map<String, dynamic>.from(r['data'] is Map ? r['data'] as Map : {'text': '${r['data']}'});
  }
  // 发现页(引擎推荐/榜单, THP v1.1; 引擎不支持时抛错, 前端回落到搜索热词)
  static Future<List<Map<String, dynamic>>> discover(String type) async {
    final r = await _get('/thp/discover?type=$type');
    final items = r['data'] is Map ? (r['data']['items'] as List? ?? []) : (r['data'] as List? ?? []);
    return [ for (final e in items) Map<String, dynamic>.from(e) ];
  }

  // 可直连的引擎列表(THP 发现的非资源库设备)
  static List<ThpDevice> available() => ThpDiscovery.list().where((d) => !d.isLibrary).toList();
}
