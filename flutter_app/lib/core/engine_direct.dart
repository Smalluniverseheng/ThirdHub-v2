// 前端直连引擎(THP): 不经过后端, 直接向局域网引擎发起搜索/目录/内容请求
// 端点为 THP 旧草稿最小集(引擎 engine-v1.2.0 实际实现): /thp/meta · /thp/search · /thp/chapters · /thp/content · /thp/discover
// (docs/THP.md 的 /thp/m/{module}/... 规范路径是资源库侧接口; 资源库调引擎时自带"规范→旧草稿"三级回落)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'discover.dart';

class EngineDirect {
  static String url = ''; // 选中的直连引擎地址(空=未连接)
  static String name = '';
  static List<String> caps = [];
  static bool _autoConnecting = false;

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    url = p.getString('engine_direct_url') ?? '';
    name = p.getString('engine_direct_name') ?? '';
    caps = p.getStringList('engine_direct_caps') ?? [];
    // 启动 THP 发现监听(全局常驻, 模块页随时可读设备列表)
    unawaited(ThpDiscovery.start());
    if (connected) {
      // 后台校验上次连接是否还活着(引擎可能重启/换了IP), 死了就自动重连新发现的引擎
      unawaited(() async {
        try {
          await http.get(Uri.parse('$url/thp/meta')).timeout(const Duration(seconds: 5));
        } catch (_) {
          url = ''; name = '';
          await autoConnect();
        }
      }());
    } else {
      // 未连接: 自动连接局域网里发现的第一个引擎
      unawaited(autoConnect());
    }
  }

  // 自动连接: 已有发现设备直接连; 没有则监听广播 15s, 出现引擎即连
  static Future<void> autoConnect() async {
    if (connected || _autoConnecting) return;
    _autoConnecting = true;
    try {
      await ThpDiscovery.start();
      final devs = available();
      if (devs.isNotEmpty) {
        try { await connect(devs.first.url); } catch (_) {}
        return;
      }
      late final StreamSubscription sub;
      sub = ThpDiscovery.onChange.listen((_) async {
        if (connected) { await sub.cancel(); return; }
        final ds = available();
        if (ds.isNotEmpty) {
          try { await connect(ds.first.url); await sub.cancel(); } catch (_) {}
        }
      });
      Future.delayed(const Duration(seconds: 15), () => sub.cancel());
    } finally { _autoConnecting = false; }
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

  // 网络层错误(连接过期/引擎重启换IP) → 自动重连一次再重试
  static bool _isNetErr(Object e) => e is TimeoutException || e is SocketException || e is http.ClientException;

  static Future<Map<String, dynamic>> _get(String path, [bool retried = false]) async {
    try {
      final r = await http.get(Uri.parse('$url$path')).timeout(const Duration(seconds: 15));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['object'] == 'error') throw Exception('${j['data']?['message'] ?? '引擎错误'}');
      if (j is Map && j['error'] != null) throw Exception('${j['error']}');
      return (j is Map && j.containsKey('data') ? {'data': j['data'], 'meta': j['meta']} : {'data': j}) as Map<String, dynamic>;
    } catch (e) {
      if (retried || !_isNetErr(e)) rethrow;
      // 连接可能已过期: 清掉旧地址, 从发现列表自动重连, 成功则重试一次
      final old = url; url = '';
      await autoConnect();
      if (!connected || url == old) { url = old; rethrow; }
      return _get(path, true);
    }
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
