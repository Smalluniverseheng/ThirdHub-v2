// 红果短剧离线缓存（4.81.98）
//
// 为什么要这层：红果的请求/签名封在后端 openhongguo（Go WASM，Simon/SM3/AES-V3
// 私有签名族）里，端上无法复刻。但「后台拿过一次」的内容不该在断后端后全变空白 ——
// 搜索结果、剧集简介、分集列表都是只读元数据，缓存下来本地完全能用。
// 播放地址有时效，不缓存（已下载到本地的集数走 PlayResolver.media() 本地优先）。
//
// 策略：在线成功后 write；在线失败/离线时 read —— 即使 TTL 过期也返回最后一版，
// 让页面能标「离线缓存」而不是给个空白。TTL 只用来决定在线时是否需要刷新。
library;

import 'dart:convert';

import 'kv.dart' show aiStore;

class HgCache {
  HgCache._();

  static const String _p = 'hg.cache.v1.';

  /// 写入一份数据（把整包 JSON 结果存进去，读出来还是原结构）。
  static Future<void> write(String key, Map<String, dynamic> data) async {
    try {
      final env = <String, dynamic>{
        't': DateTime.now().millisecondsSinceEpoch,
        'd': data,
      };
      await aiStore.setString(_p + key, jsonEncode(env));
    } catch (_) {}
  }

  /// 读缓存。返回 (data, ageMs)；没有则返回 null。
  static Future<Map<String, dynamic>?> read(String key) async {
    try {
      final s = await aiStore.getString(_p + key);
      if (s == null || s.isEmpty) return null;
      final env = jsonDecode(s) as Map<String, dynamic>;
      final t = (env['t'] as num?)?.toInt() ?? 0;
      final d = env['d'];
      if (d is! Map<String, dynamic>) return null;
      return <String, dynamic>{
        ...d,
        '__cachedAt': t,
        '__ageMs': DateTime.now().millisecondsSinceEpoch - t,
      };
    } catch (_) {
      return null;
    }
  }

  /// 缓存是否仍在有效期内（决定在线时要不要重新拉）。
  static bool fresh(Map<String, dynamic>? c, Duration ttl) {
    if (c == null) return false;
    final age = (c['__ageMs'] as num?)?.toInt() ?? 1 << 30;
    return age >= 0 && age < ttl.inMilliseconds;
  }

  static Future<void> clear(String key) async {
    try {
      await aiStore.remove(_p + key);
    } catch (_) {}
  }

  static String feedKey() => 'feed';
  static String searchKey(String kw) => 'search:' + kw.trim().toLowerCase();
  static String seriesKey(String id) => 'series:' + id;
  static String episodesKey(String id) => 'eps:' + id;

  /// 缓存多久算"旧"（在线时超过就刷新）。
  static const feedTtl = Duration(minutes: 30);
  static const searchTtl = Duration(hours: 2);
  static const detailTtl = Duration(hours: 12);
}
