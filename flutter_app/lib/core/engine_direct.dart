// 前端直连引擎(THP): 不经过后端, 直接向局域网引擎发起搜索/目录/内容/发现请求
// 端点(引擎 engine-v1.3.0 实际实现): /thp/meta · /thp/search · /thp/chapters · /thp/content · /thp/discover · /thp/explore
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
  // 注意: TimeoutException 不算连接死亡! 引擎搜索最长等25s, 超时只是"这次慢", 清连接会形成"超时→重连→再超时"死循环
  static bool _isNetErr(Object e) => e is SocketException || e is http.ClientException;

  // 超时分级: 引擎搜索/发现内部最长等25s(全书源并发), 前端必须等更久; 目录/正文也可能触发在线取详情
  static Future<Map<String, dynamic>> _get(String path, [bool retried = false, int timeoutSec = 30]) async {
    try {
      final r = await http.get(Uri.parse('$url$path')).timeout(Duration(seconds: timeoutSec));
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
      return _get(path, true, timeoutSec);
    }
  }

  // 搜索: type= novel/comic/video/music (引擎侧全书源并发, 最长约25s)
  static Future<List<Map<String, dynamic>>> search(String type, String q) async {
    final r = await _get('/thp/search?type=$type&q=${Uri.encodeComponent(q)}', false, 35);
    final items = r['data'] is Map ? (r['data']['items'] as List? ?? []) : (r['data'] as List? ?? []);
    return [ for (final e in items) Map<String, dynamic>.from(e) ];
  }
  // 目录/选集
  static Future<List<Map<String, dynamic>>> chapters(String type, String id) async {
    final r = await _get('/thp/chapters?type=$type&id=${Uri.encodeComponent(id)}', false, 30);
    final items = r['data'] is Map ? (r['data']['items'] as List? ?? []) : (r['data'] as List? ?? []);
    return [ for (final e in items) Map<String, dynamic>.from(e) ];
  }
  // 正文/图片/播放地址
  static Future<Map<String, dynamic>> content(String type, String id, String chapter) async {
    final r = await _get('/thp/content?type=$type&id=${Uri.encodeComponent(id)}&chapter=${Uri.encodeComponent(chapter)}', false, 30);
    return Map<String, dynamic>.from(r['data'] is Map ? r['data'] as Map : {'text': '${r['data']}'});
  }
  // 发现页结构(engine-v1.3.0+): 各书源的分类标签 [{source, sourceName, tags:[{name,url}]}]
  // 旧引擎(engine-v1.2.0)返回404 → 抛错, 前端回落热词搜索
  static Future<List<Map<String, dynamic>>> discover(String type) async {
    final r = await _get('/thp/discover?type=$type', false, 35);
    final items = r['data'] is Map ? (r['data']['items'] as List? ?? []) : (r['data'] as List? ?? []);
    return [ for (final e in items) Map<String, dynamic>.from(e) ];
  }
  // 发现列表(engine-v1.3.0+): 按 源+分类URL+页码 取书籍条目, 字段与 search 一致
  static Future<List<Map<String, dynamic>>> explore(String type, String source, String tagUrl, [int page = 1]) async {
    final r = await _get('/thp/explore?type=$type&source=${Uri.encodeComponent(source)}&url=${Uri.encodeComponent(tagUrl)}&page=$page', false, 35);
    final items = r['data'] is Map ? (r['data']['items'] as List? ?? []) : (r['data'] as List? ?? []);
    return [ for (final e in items) Map<String, dynamic>.from(e) ];
  }

  // 可直连的引擎列表(THP 发现的非资源库设备)
  static List<ThpDevice> available() => ThpDiscovery.list().where((d) => !d.isLibrary).toList();
}
