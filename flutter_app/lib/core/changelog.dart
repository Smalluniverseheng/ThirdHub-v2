// 更新历史：按需从云端拉取，不随安装包下发。
//
// 为什么这样做：四代累计的更新记录体量很大（数千行），全部塞进安装包会让
// 包体膨胀、启动变慢；用户绝大多数时候并不看历史。所以改成——点开
// 「更新历史」时才拉一次，平时只留一份本地缓存兜底。
//
// 分级可见由**服务端 RLS** 强制（表 `th_changelog` 两行：`changelog-public`
// 人人可读、`changelog-admin` 仅管理员可读）。这里的前端判断只是用来决定
// 要不要展示「全部历史」入口，不承担权限职责——非管理员即使伪造请求也拿不到数据。

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud.dart';

/// 单条版本记录。
class ClogEntry {
  const ClogEntry({
    required this.v,
    required this.date,
    required this.tag,
    required this.items,
  });

  final String v;
  final String date;
  final String tag;
  final List<String> items;

  factory ClogEntry.fromJson(Map<String, dynamic> j) => ClogEntry(
        v: '${j['v'] ?? ''}',
        date: '${j['date'] ?? ''}',
        tag: '${j['tag'] ?? ''}',
        items: <String>[for (final Object? e in (j['items'] as List<dynamic>? ?? <dynamic>[])) '$e'],
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': v,
        'date': date,
        'tag': tag,
        'items': items,
      };
}

/// 一整份更新历史。
class ClogDoc {
  const ClogDoc({
    required this.latest,
    required this.note,
    required this.updated,
    required this.schema,
    required this.entries,
  });

  final String latest;
  final String note;
  final String updated;
  final int schema;
  final List<ClogEntry> entries;

  factory ClogDoc.fromJson(Map<String, dynamic> j) => ClogDoc(
        latest: '${j['latest'] ?? ''}',
        note: '${j['note'] ?? ''}',
        updated: '${j['updated'] ?? ''}',
        schema: (j['schema'] as num?)?.toInt() ?? 1,
        entries: <ClogEntry>[
          for (final Object? e in (j['entries'] as List<dynamic>? ?? <dynamic>[]))
            if (e is Map) ClogEntry.fromJson(Map<String, dynamic>.from(e)),
        ],
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': schema,
        'updated': updated,
        'latest': latest,
        'note': note,
        'entries': <Map<String, dynamic>>[for (final ClogEntry e in entries) e.toJson()],
      };
}

/// 一次加载的结果：拿到什么、是不是缓存、错了什么。
class ClogResult {
  const ClogResult({this.doc, this.fromCache = false, this.error = ''});

  final ClogDoc? doc;
  final bool fromCache;
  final String error;

  bool get ok => doc != null && doc!.entries.isNotEmpty;
}

class ChangelogStore {
  ChangelogStore._();

  static const String _pubId = 'changelog-public';
  static const String _admId = 'changelog-admin';
  static const String _pubCacheKey = 'clog_public_v1';
  static const String _admCacheKey = 'clog_admin_v1';

  /// 当前账号是否管理员。
  ///
  /// 只用于 UI 上是否显示「全部历史」这一档；真正的权限在服务端 RLS。
  static bool get isAdmin {
    final Map<String, dynamic> p = Cloud.profileData;
    return p['role'] == 'admin' || p['is_admin'] == true;
  }

  static String _cacheKey(bool admin) => admin ? _admCacheKey : _pubCacheKey;

  /// 本地缓存（离线也能看）。
  static Future<ClogDoc?> cached({required bool admin}) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String? raw = p.getString(_cacheKey(admin));
    if (raw == null || raw.isEmpty) return null;
    try {
      return ClogDoc.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCache() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(_pubCacheKey);
    await p.remove(_admCacheKey);
  }

  /// 从云端拉一份。
  ///
  /// 未登录时不带 Authorization，即以 anon 身份请求——只能拿到公开那一行，
  /// 这正是我们想要的默认行为。
  static Future<ClogDoc?> _remote({required bool admin}) async {
    final String id = admin ? _admId : _pubId;
    final Uri uri = Uri.parse(
      '${Cloud.base}/rest/v1/th_changelog?id=eq.$id&select=payload',
    );
    final Map<String, String> headers = <String, String>{
      'apikey': Cloud.anonKey,
      'Content-Type': 'application/json',
      if (Cloud.accessToken.isNotEmpty) 'Authorization': 'Bearer ${Cloud.accessToken}',
    };
    final http.Response r = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception('HTTP ${r.statusCode}');
    }
    final Object? body = jsonDecode(utf8.decode(r.bodyBytes));
    if (body is! List || body.isEmpty) return null;
    final Object? first = body.first;
    if (first is! Map) return null;
    final Object? payload = first['payload'];
    if (payload is String) {
      return ClogDoc.fromJson(jsonDecode(payload) as Map<String, dynamic>);
    }
    if (payload is Map) return ClogDoc.fromJson(Map<String, dynamic>.from(payload));
    return null;
  }

  /// 加载：先给缓存（有就立即返回），[force] 时强制走网络并刷新缓存。
  ///
  /// 网络失败时回落到缓存并把错误原因带出去，UI 自己决定怎么提示。
  /// [onRemote]：非 force 且命中缓存时，后台静默拉到新数据后回调（让 UI 当次就更新，
  /// 而不是下次打开才看到——"刷新不出新版本"的另一半原因就在这）。
  static Future<ClogResult> load({required bool admin, bool force = false, void Function(ClogDoc doc)? onRemote}) async {
    if (!force) {
      final ClogDoc? c = await cached(admin: admin);
      if (c != null) {
        // 后台静默刷新，失败不打扰；拉到新的就通知 UI 当场更新
        _refreshInBackground(admin: admin, onRemote: onRemote);
        return ClogResult(doc: c, fromCache: true);
      }
    }
    try {
      final ClogDoc? d = await _remote(admin: admin);
      if (d == null) {
        final ClogDoc? c = await cached(admin: admin);
        return ClogResult(doc: c, fromCache: c != null, error: admin ? '该账号暂无全部历史记录' : '云端暂无更新记录');
      }
      await _save(admin: admin, doc: d);
      return ClogResult(doc: d);
    } catch (e) {
      final ClogDoc? c = await cached(admin: admin);
      return ClogResult(doc: c, fromCache: c != null, error: '拉取失败：$e');
    }
  }

  static Future<void> _save({required bool admin, required ClogDoc doc}) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(_cacheKey(admin), jsonEncode(doc.toJson()));
  }

  static void _refreshInBackground({required bool admin, void Function(ClogDoc doc)? onRemote}) {
    // 不 await：拿到就用新数据覆盖缓存并回调 UI，失败静默
    _remote(admin: admin)
        .then((ClogDoc? d) async {
          if (d != null) {
            await _save(admin: admin, doc: d);
            if (onRemote != null) onRemote(d);
          }
        })
        .catchError((Object _) {});
  }
}
