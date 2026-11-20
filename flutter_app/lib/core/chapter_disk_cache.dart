// 「读过的章节」落盘缓存 —— 让在线书在断网后**还能往前翻**。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么需要（4.81.76）
// ══════════════════════════════════════════════════════════════════════════════
// 小说正文此前只有内存缓存（`novel_reader.dart` 的 `chapCache`）：
// 杀进程 / 系统回收 → 全丢。于是用户在 WiFi 下读了 50 章，出门断网想翻回去，
// 一章都读不到 —— 明明刚才还在屏幕上。
//
// 与「离线下载」（`OfflineStore`）的分工：
//   · 离线下载 = **用户明确要的整本**，有目录、有进度、用户能看见占了多少空间；
//   · 本缓存 = **顺手留的副本**，用户无感，只为「刚读过的还能再看」。
// 两者目录不同（`offline_books` vs `chapter_cache`），互不覆盖：
//   下载过的书走 OfflineStore，没下载的走这里，先查前者再查后者。
//
// 淘汰策略：按文件 mtime 从旧到新删，总量控制在 [maxMb] 内。
//   ★用 mtime 而不是「读到的次数」：这里只需要「最近看过的留着」，
//   统计次数要多存一份元数据、还要处理并发写，收益不值。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'offline_plan.dart';

class ChapterDiskCache {
  /// 总量上限。200MB 大约能装 2~5 万章正文（一章 3~10KB），对小说足够。
  static const int maxMb = 200;

  /// 每写这么多次才扫一遍目录做淘汰 —— 每章都扫会让翻页明显变卡。
  static const int _pruneEvery = 24;

  static int _writes = 0;
  static Directory? _root;
  static bool _pruning = false;

  static Future<Directory> _rootDir() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/chapter_cache');
    if (!await d.exists()) await d.create(recursive: true);
    _root = d;
    return d;
  }

  /// 一本书一个目录。key 用书 URL —— 与 `OfflinePlan.hashOf` 同口径，
  /// 换源后 URL 变了就是另一本书，不会把两本书的正文混在一起。
  static Future<Directory> _bookDir(String bookKey) async {
    final root = await _rootDir();
    final d = Directory('${root.path}/${OfflinePlan.hashOf(bookKey)}');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _fileName(int i) =>
      'c_${(i < 0 ? 0 : i).toString().padLeft(5, '0')}.json';

  /// 读缓存。没有 / 读坏 / 正文为空都返回 null（调用方走网络）。
  static Future<Map<String, dynamic>?> read(String bookKey, int idx) async {
    try {
      final d = await _bookDir(bookKey);
      final f = File('${d.path}/${_fileName(idx)}');
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      final map = Map<String, dynamic>.from(j);
      final text = '${map['t'] ?? ''}';
      final images = (map['i'] as List? ?? const []).map((e) => '$e').toList();
      // 空正文的缓存等于没缓存 —— 留着会让「重试」永远拿到同一份空数据。
      if (text.trim().isEmpty && images.isEmpty) return null;
      return <String, dynamic>{'text': text, 'content': text, 'images': images};
    } catch (_) {
      return null;
    }
  }

  /// 写缓存。失败不影响阅读（磁盘满/无权限都只是「这次没留副本」）。
  static Future<void> write(
      String bookKey, int idx, Map<String, dynamic> d) async {
    try {
      final text = '${d['text'] ?? d['content'] ?? ''}';
      final images =
          (d['images'] as List? ?? const []).map((e) => '$e').toList();
      if (text.trim().isEmpty && images.isEmpty) return;
      final dir = await _bookDir(bookKey);
      final f = File('${dir.path}/${_fileName(idx)}');
      await f.writeAsString(jsonEncode({'t': text, 'i': images}));
      // 顺手更新 mtime，淘汰时才知道"最近看的是哪本哪章"
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}

      if (++_writes >= _pruneEvery) {
        _writes = 0;
        // 不 await：淘汰是后台账，绝不挡翻页。
        unawaited(prune());
      }
    } catch (_) {}
  }

  /// 按 mtime 淘汰到 [limitMb] 以内。可反复调用（自己加锁防重入）。
  static Future<void> prune({int limitMb = maxMb}) async {
    if (_pruning) return;
    _pruning = true;
    try {
      final root = await _rootDir();
      final files = <File>[];
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.endsWith('.json')) files.add(e);
      }
      if (files.isEmpty) return;
      final stats = <MapEntry<File, (int, DateTime)>>[];
      var total = 0;
      for (final f in files) {
        try {
          final st = await f.stat();
          total += st.size;
          stats.add(MapEntry(f, (st.size, st.modified)));
        } catch (_) {}
      }
      final limit = limitMb * 1024 * 1024;
      if (total <= limit) return;
      stats.sort((a, b) => a.value.$2.compareTo(b.value.$2)); // 旧 → 新
      for (final e in stats) {
        if (total <= limit) break;
        try {
          await e.key.delete();
          total -= e.value.$1;
        } catch (_) {}
      }
      // 清掉已经空的书籍目录（否则一堆空壳目录越积越多）
      await for (final e in root.list(followLinks: false)) {
        if (e is Directory) {
          try {
            if (await e.list().isEmpty) await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
    } finally {
      _pruning = false;
    }
  }

  /// 缓存占用的字节数（「我的 → 数据」里可以显示）。
  static Future<int> bytes() async {
    try {
      final root = await _rootDir();
      var total = 0;
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += (await e.stat()).size;
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clear() async {
    try {
      final root = await _rootDir();
      if (await root.exists()) await root.delete(recursive: true);
      _root = null;
    } catch (_) {}
  }
}
