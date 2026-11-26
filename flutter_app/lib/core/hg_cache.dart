// 红果短剧离线缓存（4.81.98 建，4.81.108 加管理面）
//
// 为什么要这层：红果的请求/签名封在后端 openhongguo（Go WASM，Simon/SM3/AES-V3
// 私有签名族）里，端上无法复刻。但「后台拿过一次」的内容不该在断后端后全变空白 ——
// 搜索结果、剧集简介、分集列表都是只读元数据，缓存下来本地完全能用。
// 播放地址有时效，不缓存（已下载到本地的集数走 PlayResolver.media() 本地优先）。
//
// 策略：在线成功后 write；在线失败/离线时 read —— 即使 TTL 过期也返回最后一版，
// 让页面能标「离线缓存」而不是给个空白。TTL 只用来决定在线时是否需要刷新。
//
// ★4.81.108：本机缓存不再「只进不出」。索引里登记每一份已写过的资料缓存，
//   管理页据此列出条数/字节/时间，支持单条删与一键清空。索引只是键名清单，
//   数据本体仍在各自 key 下，老版本写进来的 'feed' 等键会被自动认领。
//   **播放地址永远不进这一层**：本文件没有任何 play 路径的写入口。
library;

import 'dart:convert';

import 'kv.dart' show aiStore;

/// 管理页用的一条资料缓存摘要（不是内容本身）。
class HgCacheEntry {
  final String key;

  /// feed / search / series / eps / other —— UI 据此选 6 语言文案。
  final String kind;

  /// 搜索词 / 剧集 id（动态部分，原文展示）。
  final String arg;

  /// JSON 落盘字节数（只算资料，不含已下载的视频文件）。
  final int bytes;

  /// 写入时刻（毫秒）。
  final int at;

  const HgCacheEntry({
    required this.key,
    required this.kind,
    this.arg = '',
    required this.bytes,
    required this.at,
  });
}

class HgCache {
  HgCache._();

  static const String _p = 'hg.cache.v1.';
  static const String _indexKey = '${_p}__index';

  /// 写入一份数据（把整包 JSON 结果存进去，读出来还是原结构）。
  static Future<void> write(String key, Map<String, dynamic> data) async {
    try {
      final env = <String, dynamic>{
        't': DateTime.now().millisecondsSinceEpoch,
        'd': data,
      };
      await aiStore.setString(_p + key, jsonEncode(env));
      await _index(key, add: true);
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
      await _index(key, add: false);
    } catch (_) {}
  }

  /// 清空全部资料缓存（**不碰**已下载的视频文件 —— 那是另一块存储）。
  static Future<void> clearAll() async {
    for (final e in await entries()) {
      await clear(e.key);
    }
    try {
      await aiStore.remove(_indexKey);
    } catch (_) {}
  }

  /// 列出所有资料缓存摘要，最近的排前面。
  static Future<List<HgCacheEntry>> entries() async {
    // 'feed' 是 4.81.98 起就有的固定键；老包没有索引，也要能扫到它。
    final keys = <String>{'feed', ...await _indexKeys()};
    final out = <HgCacheEntry>[];
    for (final k in keys) {
      final raw = await aiStore.getString(_p + k);
      if (raw == null || raw.isEmpty) continue;
      try {
        final env = jsonDecode(raw) as Map<String, dynamic>;
        if (env['d'] is! Map<String, dynamic>) continue;
        final i = k.indexOf(':');
        out.add(HgCacheEntry(
          key: k,
          kind: i < 0 ? 'feed' : k.substring(0, i),
          arg: i < 0 ? '' : k.substring(i + 1),
          bytes: utf8.encode(raw).length,
          at: (env['t'] as num?)?.toInt() ?? 0,
        ));
      } catch (_) {}
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  static Future<int> totalBytes() async =>
      (await entries()).fold<int>(0, (n, e) => n + e.bytes);

  // ─────────────────────────── 索引 ───────────────────────────

  static Future<List<String>> _indexKeys() async {
    try {
      final raw = await aiStore.getString(_indexKey);
      if (raw == null || raw.isEmpty) return const <String>[];
      final v = jsonDecode(raw);
      if (v is! List) return const <String>[];
      final all = <String>[for (final x in v) '$x'];
      return all.where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<void> _index(String key, {required bool add}) async {
    try {
      final keys = (await _indexKeys()).toSet();
      final changed = add ? keys.add(key) : keys.remove(key);
      if (!changed) return;
      await aiStore.setString(_indexKey, jsonEncode(keys.toList()));
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
