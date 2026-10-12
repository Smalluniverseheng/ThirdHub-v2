// 媒体离线下载的 **IO 层**：照 `offline_media_plan.dart` 的规则读写文件、拉网络。
//
// 分工：命名/状态/HLS 判定的规则全在 plan 层；这一层只负责"碰磁盘、碰网络"，
// 不许自己另想一套命名/状态规则。
//
// 两个下载入口：
//   [MediaOfflineStore.downloadFile]  —— 视频/音乐：整文件落盘（支持断点续传、可取消）
//   [MediaOfflineStore.downloadPages] —— 漫画：逐页图片落盘（缺页可补，可取消）
//
// ★ 断点续传：单文件先写 `media.<ext>.part`，下完才改名成正身 ——
//   正身存在 = 这条记录真的下完了；`.part` 存在 = 下到一半，重跑从头重下
//   （HTTP Range 续传只在服务器支持 206 时生效，不支持就整文件重来，不会写出坏文件）。
// ★ 取消：Stream 被 cancel 后立刻停写盘，`.part` 留着，再点一次继续。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'offline_media_plan.dart';
import 'offline_plan.dart';

/// 下载中被取消的内部信号（不外抛，调用方只看 Stream 的 cancel）。
class _Cancelled implements Exception {
  const _Cancelled();
}

class MediaOfflineStore {
  /// 离线库根目录。不存在就建。
  static Future<Directory> _root() async {
    final d = await getApplicationDocumentsDirectory();
    final r = Directory('${d.path}/${MediaOfflinePlan.dirName}');
    if (!await r.exists()) await r.create(recursive: true);
    return r;
  }

  static Future<Directory> _createDir(String key, String title) async {
    final root = await _root();
    final d =
        Directory('${root.path}/${MediaOfflinePlan.slugOf(key, name: title)}');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 找某条记录的目录。两级查找（精确 slug → 按哈希后缀扫），与 OfflineStore 同思路。
  static Future<Directory?> findDir(String key, {String title = ''}) async {
    if (key.trim().isEmpty) return null;
    final root = await _root();
    final hash = MediaOfflinePlan.hashOf(key);
    if (title.trim().isNotEmpty) {
      final d =
          Directory('${root.path}/${MediaOfflinePlan.slugOf(key, name: title)}');
      if (await d.exists()) return d;
    }
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (n == hash || n.endsWith('_$hash')) return e;
    }
    return null;
  }

  static Future<File> _metaFile(Directory dir) async =>
      File('${dir.path}/${MediaOfflinePlan.metaFile}');

  static Future<void> _saveMeta(Directory dir, MediaOfflineMeta m) async {
    try {
      await (await _metaFile(dir))
          .writeAsString(jsonEncode(m.toJson()), flush: true);
    } catch (_) {
      // 清单写不进去不致命，绝不能让它把下载中断掉。
    }
  }

  static Map<String, dynamic>? _decodeMap(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// 读清单。没有 / 清单坏了 → null（调用方按"未离线"处理，不抛）。
  static Future<MediaOfflineMeta?> metaOf(String key, {String title = ''}) async {
    final dir = await findDir(key, title: title);
    if (dir == null) return null;
    final f = await _metaFile(dir);
    if (!await f.exists()) return null;
    try {
      final j = _decodeMap(await f.readAsString());
      return j == null ? null : MediaOfflineMeta.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> has(String key, {String title = ''}) async {
    final m = await metaOf(key, title: title);
    return m != null && m.done > 0;
  }

  /// 视频/音乐：本地正身文件（没有就 null，调用方回落联网播放）。
  static Future<File?> localFileOf(String key, {String title = ''}) async {
    final dir = await findDir(key, title: title);
    final m = await metaOf(key, title: title);
    if (dir == null || m == null || m.files.isEmpty) return null;
    final f = File('${dir.path}/${m.files.first}');
    if (!await f.exists()) return null;
    try {
      return (await f.length()) > 0 ? f : null;
    } catch (_) {
      return null;
    }
  }

  /// 漫画：本地页文件列表（按阅读顺序；不全就返回空 —— 半套页显示出来是残书，
  /// 不如回落联网，下全了再走本地）。
  static Future<List<File>> localPagesOf(String key,
      {String title = ''}) async {
    final dir = await findDir(key, title: title);
    final m = await metaOf(key, title: title);
    if (dir == null || m == null || m.files.isEmpty) return const [];
    final out = <File>[];
    for (final name in m.files) {
      final f = File('${dir.path}/$name');
      if (!await f.exists()) return const [];
      out.add(f);
    }
    return out;
  }

  /// 把所有媒体离线记录列出来（管理界面用），最近下载的排前面。
  static Future<List<MediaOfflineMeta>> list() async {
    final root = await _root();
    final out = <MediaOfflineMeta>[];
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      // ★回收站不进列表（.trash 里的 meta 不该被当成"已离线"）。
      final dirName = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (dirName == MediaOfflinePlan.trashDirName) continue;
      final f = File('${e.path}/${MediaOfflinePlan.metaFile}');
      if (!await f.exists()) continue;
      try {
        final j = _decodeMap(await f.readAsString());
        if (j != null) out.add(MediaOfflineMeta.fromJson(j));
      } catch (_) {}
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// ★2026-10-12：**软删进回收站**（删除可撤销）—— 目录 rename 到 `.trash/<slug>__<时间>`。
  /// [restore] 可还原（搬回原位）；超过 7 天由 [cleanTrash] 自动清掉。
  /// rename 是原子操作：撤销只是搬回来，不会让用户重下几十 MB。
  static Future<bool> remove(String key,
      {String title = '', bool permanent = false}) async {
    final dir = await findDir(key, title: title);
    if (dir == null) return false;
    // permanent=true（超限自动清理用）：直接删、不进回收站——
    // 自动清理的东西堆回收站没意义（7 天后还是清）。
    if (permanent) {
      try {
        await dir.delete(recursive: true);
        return true;
      } catch (_) {
        return false;
      }
    }
    try {
      final root = await _root();
      final trash = Directory('${root.path}/${MediaOfflinePlan.trashDirName}');
      if (!await trash.exists()) await trash.create(recursive: true);
      final slug = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      await dir.rename(
          '${trash.path}/${MediaOfflinePlan.trashName(slug, DateTime.now())}');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 撤销删除：把该 key 最近一次进回收站的记录搬回原位。
  /// 记录还在（没删成功/删的不是它）→ 直接回 true；找不到 → false。
  static Future<bool> restore(String key, {String title = ''}) async {
    if (await findDir(key, title: title) != null) return true;
    final root = await _root();
    final trash = Directory('${root.path}/${MediaOfflinePlan.trashDirName}');
    if (!await trash.exists()) return false;
    final hash = MediaOfflinePlan.hashOf(key);
    String? newest;
    DateTime? newestAt;
    await for (final e in trash.list(followLinks: false)) {
      if (e is! Directory) continue;
      final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (n != hash && !n.endsWith('_$hash')) continue;
      final t = MediaOfflinePlan.trashTimeOf(n) ?? DateTime(2000);
      if (newestAt == null || t.isAfter(newestAt)) {
        newest = e.path;
        newestAt = t;
      }
    }
    if (newest == null) return false;
    try {
      await Directory(newest).rename(
          '${root.path}/${MediaOfflinePlan.trashSlugOf(newest.split('/').last)}');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清掉回收站里超过 [days] 天（默认 7 天）的项。返回清了几项。
  static Future<int> cleanTrash({int days = 7}) async {
    final root = await _root();
    final trash = Directory('${root.path}/${MediaOfflinePlan.trashDirName}');
    if (!await trash.exists()) return 0;
    var n = 0;
    try {
      await for (final e in trash.list(followLinks: false)) {
        if (e is! Directory) continue;
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!MediaOfflinePlan.trashExpired(name, days: days)) continue;
        try {
          await e.delete(recursive: true);
          n++;
        } catch (_) {}
      }
    } catch (_) {}
    return n;
  }

  /// 目录实际占用字节数（清单里的 bytes 可能过时，删文件后以这个为准）。
  static Future<int> bytesOf(String key, {String title = ''}) async {
    final dir = await findDir(key, title: title);
    if (dir == null) return 0;
    var n = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) n += await e.length();
      }
    } catch (_) {}
    return n;
  }

  // ─────────────────────────── 下载 ───────────────────────────

  /// 下载一个整文件（视频一集 / 音乐一首）。返回进度流。
  ///
  /// [key] 是稳定标识（集地址/歌地址），[url] 是**解析后的直链**。
  /// 直播/HLS（.m3u8）在入口就拒绝 —— 规则在 plan 层，这里只执行。
  static Stream<OfflineProgress> downloadFile({
    required String kind,
    required String key,
    required String title,
    required String url,
    String subtitle = '',
    String coverUrl = '',
    String sourceId = 'engine',
    Map<String, String> headers = const {},
  }) {
    final c = StreamController<OfflineProgress>();
    final cancel = _CancelFlag();
    c.onListen = () {
      unawaited(_runFile(
          c, cancel, kind, key, title, url, subtitle, coverUrl, sourceId,
          headers));
    };
    c.onCancel = () {
      cancel.cancelled = true;
    };
    return c.stream;
  }

  static Future<void> _runFile(
    StreamController<OfflineProgress> c,
    _CancelFlag cancel,
    String kind,
    String key,
    String title,
    String url,
    String subtitle,
    String coverUrl,
    String sourceId,
    Map<String, String> headers,
  ) async {
    void push(int total, int done, int failed, String status, String msg,
        {int bytes = 0, int totalBytes = 0}) {
      if (!c.isClosed) {
        c.add(OfflineProgress(
            total: total,
            done: done,
            failed: failed,
            status: status,
            message: msg,
            bytes: bytes,
            totalBytes: totalBytes));
      }
    }

    try {
      if (key.trim().isEmpty || url.trim().isEmpty) {
        push(0, 0, 0, 'error', '没有可下载的地址');
        await c.close();
        return;
      }
      if (MediaOfflinePlan.isStreamOnly(url)) {
        push(0, 0, 0, 'error',
            '这是直播/流媒体地址（m3u8 分片流），不是文件，没法整存。\n点播剧集请在剧集解析出直链后再试');
        await c.close();
        return;
      }

      final dir = await _createDir(key, title);
      final ext = MediaOfflinePlan.extOf(url,
          fallback: kind == 'music' ? 'mp3' : 'mp4');
      final fname = MediaOfflinePlan.mediaFileName(ext);
      final dest = File('${dir.path}/$fname');

      // 已经下过完整的？直接成功（幂等）。
      if (await _doneFile(dest)) {
        final bytes = await dest.length();
        await _saveMeta(
            dir,
            MediaOfflineMeta(
              key: key,
              kind: kind,
              title: title,
              subtitle: subtitle,
              coverUrl: coverUrl,
              sourceId: sourceId,
              status: 'done',
              at: MediaOfflinePlan.stamp(),
              total: 1,
              done: 1,
              failed: 0,
              bytes: bytes,
              files: [fname],
            ));
        push(1, 1, 0, 'done', '已经离线过了');
        await c.close();
        return;
      }

      push(100, 0, 0, 'running', '准备下载…');
      var meta = MediaOfflineMeta(
        key: key,
        kind: kind,
        title: title,
        subtitle: subtitle,
        coverUrl: coverUrl,
        sourceId: sourceId,
        status: 'running',
        at: MediaOfflinePlan.stamp(),
        total: 1,
        done: 0,
        failed: 0,
        files: [fname],
      );
      await _saveMeta(dir, meta);

      // 进度用「千分比」喂 OfflineProgress（total=1000），
      // 这样复用 OfflineProgress.ratio 的进度条不用改 UI 的值域。
      final sw = Stopwatch()..start();
      await _fetchToFile(url, dest, headers, cancel, (got, totalBytes) {
        if (sw.elapsedMilliseconds < 350) return;
        sw.reset();
        final permille = totalBytes > 0
            ? (got * 1000 ~/ totalBytes).clamp(0, 999)
            : 0;
        push(1000, permille, 0, 'running',
            '${MediaOfflinePlan.bytesLabel(got)} / ${totalBytes > 0 ? MediaOfflinePlan.bytesLabel(totalBytes) : '?'}',
            bytes: got, totalBytes: totalBytes);
      });

      final bytes = await dest.length();
      meta = meta.copyWith(
          status: 'done',
          done: 1,
          bytes: bytes,
          at: MediaOfflinePlan.stamp());
      await _saveMeta(dir, meta);
      push(1, 1, 0, 'done', '已保存到本机 · ${MediaOfflinePlan.bytesLabel(bytes)}');
    } on _Cancelled {
      // 取消：.part 留着续传，清单状态收敛（别停在 running）。
      final dir = await findDir(key, title: title);
      if (dir != null) {
        final m = await metaOf(key, title: title);
        if (m != null && m.status == 'running') {
          await _saveMeta(
              dir, m.copyWith(status: 'partial', at: MediaOfflinePlan.stamp()));
        }
      }
    } catch (e) {
      push(0, 0, 0, 'error', '下载失败：$e');
    } finally {
      if (!c.isClosed) await c.close();
    }
  }

  /// 下载漫画一话（逐页图片）。返回进度流，每页落盘即报进度。
  static Stream<OfflineProgress> downloadPages({
    required String key,
    required String title,
    required List<String> pages,
    String subtitle = '',
    String coverUrl = '',
    String sourceId = 'engine',
    Map<String, String> headers = const {},
  }) {
    final c = StreamController<OfflineProgress>();
    final cancel = _CancelFlag();
    c.onListen = () {
      unawaited(_runPages(
          c, cancel, key, title, pages, subtitle, coverUrl, sourceId, headers));
    };
    c.onCancel = () {
      cancel.cancelled = true;
    };
    return c.stream;
  }

  static Future<void> _runPages(
    StreamController<OfflineProgress> c,
    _CancelFlag cancel,
    String key,
    String title,
    List<String> pages,
    String subtitle,
    String coverUrl,
    String sourceId,
    Map<String, String> headers,
  ) async {
    void push(int total, int done, int failed, String status, String msg,
        {int bytes = 0, int totalBytes = 0}) {
      if (!c.isClosed) {
        c.add(OfflineProgress(
            total: total,
            done: done,
            failed: failed,
            status: status,
            message: msg,
            bytes: bytes,
            totalBytes: totalBytes));
      }
    }

    try {
      if (key.trim().isEmpty || pages.isEmpty) {
        push(0, 0, 0, 'error', '本话没有可下载的图片');
        await c.close();
        return;
      }
      final dir = await _createDir(key, title);
      final pgDir = Directory('${dir.path}/${MediaOfflinePlan.pageDirName}');
      if (!await pgDir.exists()) await pgDir.create(recursive: true);

      final total = pages.length;
      var done = 0;
      var failed = 0;
      var meta = MediaOfflineMeta(
        key: key,
        kind: 'comic',
        title: title,
        subtitle: subtitle,
        coverUrl: coverUrl,
        sourceId: sourceId,
        status: 'running',
        at: MediaOfflinePlan.stamp(),
        total: total,
        done: 0,
        failed: 0,
        files: [
          for (var i = 0; i < total; i++)
            '${MediaOfflinePlan.pageDirName}/${MediaOfflinePlan.pageFileName(i, MediaOfflinePlan.extOf(pages[i], fallback: 'jpg'))}'
        ],
      );
      await _saveMeta(dir, meta);
      push(total, 0, 0, 'running', '共 $total 页');

      for (var i = 0; i < total; i++) {
        if (cancel.cancelled) throw const _Cancelled();
        final name = meta.files[i];
        final f = File('${dir.path}/$name');
        if (await _doneFile(f)) {
          done++;
          continue; // 断点续传：这页已经有了
        }
        try {
          await _fetchToFile(pages[i], f, headers, cancel, (_, __) {});
          done++;
        } catch (_) {
          // 单页失败不整轮 abort（源站缺图是常事），记 failed 继续。
          failed++;
        }
        meta = meta.copyWith(
            done: done, failed: failed, at: MediaOfflinePlan.stamp());
        await _saveMeta(dir, meta);
        push(total, done, failed, 'running',
            failed > 0 ? '第 ${i + 1}/$total 页（$failed 页没取到）' : '正在下载 第 ${i + 1}/$total 页');
      }

      // 收尾以磁盘实际状态为准。
      var realDone = 0;
      var bytes = 0;
      for (final name in meta.files) {
        final f = File('${dir.path}/$name');
        if (await _doneFile(f)) {
          realDone++;
          try {
            bytes += await f.length();
          } catch (_) {}
        }
      }
      final status = MediaOfflinePlan.statusOf(total, realDone, failed);
      meta = meta.copyWith(
          done: realDone,
          failed: failed,
          status: status,
          bytes: bytes,
          at: MediaOfflinePlan.stamp());
      await _saveMeta(dir, meta);
      push(
          total,
          realDone,
          failed,
          status,
          status == 'done'
              ? '已保存 $total 页 · ${MediaOfflinePlan.bytesLabel(bytes)}'
              : status == 'partial'
                  ? '已保存 $realDone/$total 页（$failed 页没取到，可再点一次补）'
                  : '保存失败，可再点一次重试');
    } on _Cancelled {
      final dir = await findDir(key, title: title);
      if (dir != null) {
        final m = await metaOf(key, title: title);
        if (m != null && m.status == 'running') {
          await _saveMeta(
              dir, m.copyWith(status: 'partial', at: MediaOfflinePlan.stamp()));
        }
      }
    } catch (e) {
      push(0, 0, 0, 'error', '下载失败：$e');
    } finally {
      if (!c.isClosed) await c.close();
    }
  }

  /// 下载 HLS（m3u8 点播流）：拉清单 → 逐分片下载 → 边下边拼成单文件。返回进度流。
  ///
  /// ★ 直播拒绝：清单无 `#EXT-X-ENDLIST` → 报错退出（口径在 `HlsPlan`，这里只执行）。
  /// ★ 断点续传：`.part` 边上放一个 `.part.done` 记「已写进多少片」；重跑从断点继续
  ///   （每片先 flush 写盘、再记账 —— 中断最多重下一片，不会写出坏文件）。
  /// ★ 加密流拒绝：分片是密文，拼出来播不了。
  static Stream<OfflineProgress> downloadHls({
    required String kind,
    required String key,
    required String title,
    required String url,
    String subtitle = '',
    String coverUrl = '',
    String sourceId = 'engine',
    Map<String, String> headers = const {},
  }) {
    final c = StreamController<OfflineProgress>();
    final cancel = _CancelFlag();
    c.onListen = () {
      unawaited(_runHls(
          c, cancel, kind, key, title, url, subtitle, coverUrl, sourceId,
          headers));
    };
    c.onCancel = () {
      cancel.cancelled = true;
    };
    return c.stream;
  }

  static Future<void> _runHls(
    StreamController<OfflineProgress> c,
    _CancelFlag cancel,
    String kind,
    String key,
    String title,
    String url,
    String subtitle,
    String coverUrl,
    String sourceId,
    Map<String, String> headers,
  ) async {
    void push(int total, int done, int failed, String status, String msg,
        {int bytes = 0, int totalBytes = 0}) {
      if (!c.isClosed) {
        c.add(OfflineProgress(
            total: total,
            done: done,
            failed: failed,
            status: status,
            message: msg,
            bytes: bytes,
            totalBytes: totalBytes));
      }
    }

    try {
      if (key.trim().isEmpty || url.trim().isEmpty) {
        push(0, 0, 0, 'error', '没有可下载的地址');
        return;
      }
      push(0, 0, 0, 'running', '读取流清单…');

      // ① 拉清单（master → 最多再下一层）
      var base = url;
      var text = await _fetchText(base, headers, cancel);
      var man = HlsPlan.parse(text, base);
      if (man == null) {
        push(0, 0, 0, 'error', '这个地址不是可识别的 m3u8 清单');
        return;
      }
      if (man.isMaster) {
        if (man.childPlaylists.isEmpty) {
          push(0, 0, 0, 'error', '多码率清单里没有可用的子清单');
          return;
        }
        base = man.childPlaylists.first;
        text = await _fetchText(base, headers, cancel);
        final m2 = HlsPlan.parse(text, base);
        if (m2 == null || m2.isMaster) {
          push(0, 0, 0, 'error', '子清单解析失败');
          return;
        }
        man = m2;
      }
      if (man.encrypted) {
        push(0, 0, 0, 'error', '这是加密流（分片加密），没法直接保存');
        return;
      }
      if (!man.isVod) {
        push(0, 0, 0, 'error',
            '这是直播流：边播边生成、没有完整分片列表，没法整存。\n点播内容（有完整剧集/片长的）才能保存');
        return;
      }
      final segs = <String>[
        if (man.initSegment != null) man.initSegment!,
        ...man.segments,
      ];
      if (segs.isEmpty) {
        push(0, 0, 0, 'error', '清单里没有分片');
        return;
      }

      // ② 落盘路径与断点
      final dir = await _createDir(key, title);
      final fname = MediaOfflinePlan.mediaFileName(man.mergedExt);
      final dest = File('${dir.path}/$fname');
      final part = File('${dest.path}.part');
      final side = File('${dest.path}.part.done');

      if (await _doneFile(dest)) {
        final bytes = await dest.length();
        await _saveMeta(
            dir,
            MediaOfflineMeta(
              key: key,
              kind: kind,
              title: title,
              subtitle: subtitle,
              coverUrl: coverUrl,
              sourceId: sourceId,
              status: 'done',
              at: MediaOfflinePlan.stamp(),
              total: 1,
              done: 1,
              failed: 0,
              bytes: bytes,
              files: [fname],
            ));
        push(1, 1, 0, 'done', '已经离线过了');
        return;
      }

      var doneCount = 0;
      if (await part.exists()) {
        try {
          doneCount = int.tryParse((await side.readAsString()).trim()) ?? 0;
        } catch (_) {
          doneCount = 0;
        }
        if (doneCount < 0 || doneCount > segs.length) doneCount = 0;
      }

      var meta = MediaOfflineMeta(
        key: key,
        kind: kind,
        title: title,
        subtitle: subtitle,
        coverUrl: coverUrl,
        sourceId: sourceId,
        status: 'running',
        at: MediaOfflinePlan.stamp(),
        total: segs.length,
        done: doneCount,
        failed: 0,
        files: [fname],
      );
      await _saveMeta(dir, meta);
      push(segs.length, doneCount, 0, 'running',
          '共 ${segs.length} 片；下完会自动合并成一个文件');

      // ③ 逐片下载 → 追加写盘（先落盘再记账，中断最多重下一片）
      final sink = part.openWrite(
          mode: doneCount > 0 ? FileMode.append : FileMode.write);
      try {
        for (var i = doneCount; i < segs.length; i++) {
          if (cancel.cancelled) throw const _Cancelled();
          final buf = await _fetchBytes(segs[i], headers, cancel);
          sink.add(buf);
          await sink.flush(); // 先落盘
          await side.writeAsString('${i + 1}'); // 再记账
          doneCount = i + 1;
          meta = meta.copyWith(
              done: doneCount, at: MediaOfflinePlan.stamp());
          await _saveMeta(dir, meta);
          var got = 0;
          try {
            got = await part.length();
          } catch (_) {}
          push(segs.length, doneCount, 0, 'running',
              '已下 $doneCount/${segs.length} 片 · ${MediaOfflinePlan.bytesLabel(got)}',
              bytes: got);
        }
      } finally {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!await _doneFile(part)) throw Exception('下载到的内容是空的');
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      try {
        await side.delete();
      } catch (_) {}
      final bytes = await dest.length();
      meta = meta.copyWith(
          status: 'done',
          done: segs.length,
          bytes: bytes,
          at: MediaOfflinePlan.stamp());
      await _saveMeta(dir, meta);
      push(segs.length, segs.length, 0, 'done',
          '已保存到本机 · ${MediaOfflinePlan.bytesLabel(bytes)}（${segs.length} 片已合并）');
    } on _Cancelled {
      final dir = await findDir(key, title: title);
      if (dir != null) {
        final m = await metaOf(key, title: title);
        if (m != null && m.status == 'running') {
          await _saveMeta(
              dir, m.copyWith(status: 'partial', at: MediaOfflinePlan.stamp()));
        }
      }
    } catch (e) {
      push(0, 0, 0, 'error', '下载失败：$e');
    } finally {
      if (!c.isClosed) await c.close();
    }
  }

  /// 拉一段文本（m3u8 清单）。编码按 UTF-8（HLS 规范要求）。
  static Future<String> _fetchText(
      String url, Map<String, String> headers, _CancelFlag cancel) async {
    final b = await _fetchBytes(url, headers, cancel, maxBytes: 4 << 20);
    return utf8.decode(b, allowMalformed: true);
  }

  /// 拉一段二进制（一个分片/清单）。单片入内存（HLS 分片是独立编解码单元，尺寸可控）；
  /// [maxBytes] 防御性上限 —— 坏地址不会把内存拉爆。
  static Future<List<int>> _fetchBytes(
      String url, Map<String, String> headers, _CancelFlag cancel,
      {int maxBytes = 256 << 20}) async {
    final client =
        HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final rq = await client.getUrl(Uri.parse(url));
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'range') rq.headers.set(k, v);
      });
      rq.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final rs = await rq.close();
      if (rs.statusCode != 200) throw Exception('HTTP ${rs.statusCode}');
      final out = <int>[];
      await for (final chunk in rs) {
        if (cancel.cancelled) throw const _Cancelled();
        out.addAll(chunk);
        if (out.length > maxBytes) throw Exception('内容过大，已中止');
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  /// 文件存在且非空才算下完（0 字节文件 = 上次失败留下的残骸，重下）。
  static Future<bool> _doneFile(File f) async {
    try {
      return await f.exists() && (await f.length()) > 0;
    } catch (_) {
      return false;
    }
  }

  /// 拉一个 URL 落盘。带 Range 续传；服务器不认 Range（不回 206）就整文件重写。
  /// [onProgress] 每个网络块回调一次（节流是调用方的事）。
  static Future<void> _fetchToFile(
    String url,
    File dest,
    Map<String, String> headers,
    _CancelFlag cancel,
    void Function(int got, int totalBytes) onProgress,
  ) async {
    final part = File('${dest.path}.part');
    var start = 0;
    if (await part.exists()) {
      try {
        start = await part.length();
      } catch (_) {
        start = 0;
      }
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final rq = await client.getUrl(Uri.parse(url));
      // 通用请求头（漫画图站常见的 Referer/UA 防盗链）。
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'range') rq.headers.set(k, v);
      });
      rq.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (start > 0) rq.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      final rs = await rq.close();
      final code = rs.statusCode;
      if (code != 200 && code != 206) {
        throw Exception('HTTP $code');
      }
      final resuming = code == 206 && start > 0;
      if (!resuming) start = 0; // 服务器没给续传，旧 .part 作废
      final totalBytes =
          rs.contentLength >= 0 ? rs.contentLength + start : -1;
      sink = part.openWrite(
          mode: resuming ? FileMode.append : FileMode.write);
      var got = start;
      await for (final chunk in rs) {
        if (cancel.cancelled) throw const _Cancelled();
        sink.add(chunk);
        got += chunk.length;
        onProgress(got, totalBytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (!await _doneFile(part)) throw Exception('下载到的内容是空的');
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
    } catch (e) {
      // .part 保留（续传用），异常照抛给上层记状态。
      rethrow;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }
}

class _CancelFlag {
  bool cancelled = false;
  void cancel() => cancelled = true;
}
