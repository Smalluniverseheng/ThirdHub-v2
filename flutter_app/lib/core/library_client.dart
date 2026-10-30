// 资源库取数层（App 侧）—— 2026-10-30
// 一个入口，两种后端（后台「远端配置」的 library.backend 决定，可随时切）：
//   cloud → Supabase th_library_items（后台「资源库」页维护，按用户×模块授权）
//   nas   → 用户自己的 NAS 资源库后端（library-server/），家人用只读 token 读
// 调用方只写 LibraryClient.list()，不关心后端在哪。
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'cloud.dart';
import 'remote_config.dart';

class LibraryClient {
  /// 取目录。返回 (ok, backend, items, error)
  static Future<({bool ok, String backend, List<Map<String, dynamic>> items, String error})> list({
    required String module,
    String q = '',
    int limit = 60,
    int offset = 0,
    String uid = '',
  }) async {
    final be = RemoteConfig.libraryBackend();

    if (be.mode == 'nas' && be.url.isNotEmpty) {
      try {
        final u = Uri.parse(be.url.replaceAll(RegExp(r'/+$'), '') + '/lib/items').replace(queryParameters: {
          'module': module,
          if (q.isNotEmpty) 'q': q,
          'limit': '$limit',
          'offset': '$offset',
        });
        final r = await http
            .get(u, headers: {if (be.token.isNotEmpty) 'X-Lib-Token': be.token})
            .timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          final data = (j is Map && j['data'] is List) ? (j['data'] as List) : const [];
          return (
            ok: true,
            backend: 'nas',
            items: data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
            error: '',
          );
        }
        return (ok: false, backend: 'nas', items: <Map<String, dynamic>>[], error: 'HTTP ${r.statusCode}');
      } catch (e) {
        return (ok: false, backend: 'nas', items: <Map<String, dynamic>>[], error: e.toString());
      }
    }

    // 云端
    try {
      final r = await http
          .post(Uri.parse('${Cloud.base}/rest/v1/rpc/th_library_list'),
              headers: {
                'apikey': Cloud.anonKey,
                'Authorization': 'Bearer ${Cloud.loggedIn ? Cloud.accessToken : Cloud.anonKey}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'p_uid': uid, 'p_module': module, 'p_q': q, 'p_limit': limit, 'p_offset': offset}))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        return (ok: false, backend: 'cloud', items: <Map<String, dynamic>>[], error: 'HTTP ${r.statusCode}');
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['ok'] == false) {
        final e = j['error'];
        final code = (e is Map ? e['code'] : '$e') ?? 'no_grant';
        return (ok: false, backend: 'cloud', items: <Map<String, dynamic>>[], error: '$code');
      }
      final data = (j is Map && j['data'] is List) ? (j['data'] as List) : const [];
      return (
        ok: true,
        backend: 'cloud',
        items: data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
        error: '',
      );
    } catch (e) {
      return (ok: false, backend: 'cloud', items: <Map<String, dynamic>>[], error: e.toString());
    }
  }

  /// 我开通了哪些模块（决定「书城/歌单」入口是否出现）
  static Future<List<String>> myModules({String uid = ''}) async {
    final be = RemoteConfig.libraryBackend();
    if (be.mode == 'nas' && be.url.isNotEmpty) {
      try {
        final r = await http
            .get(Uri.parse(be.url.replaceAll(RegExp(r'/+$'), '') + '/lib/health'))
            .timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          if (j is Map && j['modules'] is List) {
            return (j['modules'] as List).map((e) => '$e').toList();
          }
        }
      } catch (_) {}
      return const [];
    }
    if (uid.isEmpty) return const [];
    try {
      final r = await http
          .post(Uri.parse('${Cloud.base}/rest/v1/rpc/th_library_my_grants'),
              headers: {'apikey': Cloud.anonKey, 'Authorization': 'Bearer ${Cloud.anonKey}', 'Content-Type': 'application/json'},
              body: jsonEncode({'p_uid': uid}))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['data'] is List) return (j['data'] as List).map((e) => '$e').toList();
      }
    } catch (_) {}
    return const [];
  }

  /// 测试 NAS 连接（设置页「测试连接」用）
  static Future<({bool ok, String info})> testNas(String url, String token) async {
    try {
      final r = await http
          .get(Uri.parse(url.replaceAll(RegExp(r'/+$'), '') + '/lib/health'),
              headers: {if (token.isNotEmpty) 'X-Lib-Token': token})
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        final n = (j is Map) ? j['items'] : 0;
        return (ok: true, info: '连接成功 · 现有 $n 条');
      }
      return (ok: false, info: 'HTTP ${r.statusCode}');
    } catch (e) {
      return (ok: false, info: e.toString());
    }
  }
}
