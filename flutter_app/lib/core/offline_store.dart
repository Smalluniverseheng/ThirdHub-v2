// 离线下载的 **IO 层**：照 `offline_plan.dart` 的规则读写文件、调引擎取正文。
//
// 分工：所有"算得出来对不对"的判断在 `offline_plan.dart`（纯 Dart，自检可断言）；
// 这一层只负责"碰磁盘、碰网络"，不许自己另想一套命名/状态规则。
//
// 落盘形态（一部书一个目录）：
//   <应用文档>/offline_books/<书名_哈希>/
//     meta.json          清单：书名/作者/封面/章节表/进度/状态
//     chapters/c_00000.txt  第 0 章正文（5 位补零，文件管理器排序 == 章节顺序）
//     chapters/c_00001.txt
//     ...
//
// ★ 为什么按章落盘而不是合成一个大 txt：见 offline_plan.dart 顶部注释
//   （断点续传 + 不双份存储 + 不会被 splitChapters 正则误切）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'engine_direct.dart';
import 'offline_plan.dart';

class OfflineStore {
  /// 离线库根目录。不存在就建。
  static Future<Directory> _root() async {
    final d = await getApplicationDocumentsDirectory();
    final r = Directory('${d.path}/${OfflinePlan.dirName}');
    if (!await r.exists()) await r.create(recursive: true);
    return r;
  }

  /// 找某本书的离线目录。
  ///
  /// 两级查找：① 用 `slugOf(bookUrl, name)` 精确算（书名没变过时一步命中）；
  /// ② 书名对不上（改过名/只记得 bookUrl）就按 `_$hash` 后缀扫一遍根目录。
  /// 第 ② 级只列目录不读文件，而目录数就是"下了几本书"的量级，代价可忽略。
  /// ★ 这条是"能查到"的兜底：只做 ① 的话，用户在书架上看到的书名与下载时
  ///   稍有出入（换设备同步、后端合并）就永远显示"未离线"，而文件其实在盘上。
  static Future<Directory?> findDir(String bookUrl, {String name = ''}) async {
    if (bookUrl.trim().isEmpty) return null;
    final root = await _root();
    final hash = OfflinePlan.hashOf(bookUrl);
    if (name.trim().isNotEmpty) {
      final d = Directory('${root.path}/${OfflinePlan.slugOf(bookUrl, name: name)}');
      if (await d.exists()) return d;
    }
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (n == hash || n.endsWith('_$hash')) return e;
    }
    return null;
  }

  static Future<Directory> _createDir(String bookUrl, String name) async {
    final root = await _root();
    final d = Directory('${root.path}/${OfflinePlan.slugOf(bookUrl, name: name)}');
    if (!await d.exists()) await d.create(recursive: true);
    final ch = Directory('${d.path}/chapters');
    if (!await ch.exists()) await ch.create(recursive: true);
    return d;
  }

  static Future<File> _metaFile(Directory dir) async =>
      File('${dir.path}/${OfflinePlan.metaFile}');

  static Future<void> _saveMeta(Directory dir, OfflineMeta m) async {
    try {
      // 用 dart:convert，不手写 JSON 拼接 —— 手写转义（引号/反斜杠/换行）
      // 迟早漏一种，而漏了的表现是"清单读不出来 = 明明下了却显示未离线"。
      await (await _metaFile(dir)).writeAsString(jsonEncode(m.toJson()), flush: true);
    } catch (_) {
      // 清单写不进去不致命：下一章还会重写。但绝不能让它把下载中断掉。
    }
  }

  /// 读清单。没有离线内容 / 清单坏了 → null（调用方按"未离线"处理，不抛）。
  static Future<OfflineMeta?> metaOf(String bookUrl, {String name = ''}) async {
    final dir = await findDir(bookUrl, name: name);
    if (dir == null) return null;
    final f = await _metaFile(dir);
    if (!await f.exists()) return null;
    try {
      final raw = await f.readAsString();
      final j = _decodeMap(raw);
      if (j == null) return null;
      return OfflineMeta.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// 极简 JSON 解码（清单是本模块自己写的、形状固定，不引 dart:convert 之外的东西）。
  static Map<String, dynamic>? _decodeMap(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// 这本书有没有可读的离线正文（清单在、而且至少下好一章）。
  static Future<bool> has(String bookUrl, {String name = ''}) async {
    final m = await metaOf(bookUrl, name: name);
    return m != null && m.done > 0;
  }

  /// 这本书是不是**完整**离线（缺章的书也是"有离线"，只是 `has` 与 `isDone` 不同）。
  static Future<bool> isComplete(String bookUrl, {String name = ''}) async {
    final m = await metaOf(bookUrl, name: name);
    return m != null && OfflinePlan.isDone(m);
  }

  /// 离线目录（章节名 + 章节引用）。阅读器离线打开时用它，不再打引擎。
  static Future<List<Map<String, String>>> toc(String bookUrl, {String name = ''}) async {
    final m = await metaOf(bookUrl, name: name);
    if (m == null) return const [];
    return m.chapters;
  }

  /// 取某一章正文。文件不在（那章下失败了）→ null，让调用方决定是报错还是回落引擎。
  static Future<String?> chapterText(String bookUrl, int index,
      {String name = ''}) async {
    final dir = await findDir(bookUrl, name: name);
    if (dir == null) return null;
    final f = File('${dir.path}/chapters/${OfflinePlan.chapterFileName(index)}');
    if (!await f.exists()) return null;
    try {
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 离线内容占用的字节数（书架上显示"已离线 320 章 · 12.4 MB"）。
  static Future<int> bytesOf(String bookUrl, {String name = ''}) async {
    final dir = await findDir(bookUrl, name: name);
    if (dir == null) return 0;
    var n = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) n += await e.length();
      }
    } catch (_) {}
    return n;
  }

  /// 删掉这本书的全部离线内容。目录一起删，不留空壳。
  static Future<void> remove(String bookUrl, {String name = ''}) async {
    final dir = await findDir(bookUrl, name: name);
    if (dir == null) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 中途取消后把清单状态收敛（`running` → `partial`），不要停在"下载中"。
  ///
  /// 为什么必须有这一步：取消时 Stream 直接没了，循环里那句收尾永远不会跑，
  /// 清单就一直写着 running —— 书架上会显示成"下载中"，而实际早停了。
  /// 磁盘上的章节文件不受影响，再点一次下载会接着下。
  static Future<void> finalizeMeta(String bookUrl, {String name = ''}) async {
    final m = await metaOf(bookUrl, name: name);
    if (m == null) return;
    final dir = await findDir(bookUrl, name: name);
    if (dir == null) return;
    await _saveMeta(
        dir,
        m.copyWith(
            status: OfflinePlan.statusOf(m.total, m.done, m.failed),
            at: OfflinePlan.stamp()));
  }

  /// 把所有离线书列出来（管理界面用）。
  static Future<List<OfflineMeta>> list() async {
    final root = await _root();
    final out = <OfflineMeta>[];
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final f = File('${e.path}/${OfflinePlan.metaFile}');
      if (!await f.exists()) continue;
      try {
        final j = _decodeMap(await f.readAsString());
        if (j != null) out.add(OfflineMeta.fromJson(j));
      } catch (_) {}
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// 导出成单个 txt（放到同目录 `全书.txt`），方便拷去别的阅读器/电脑。
  /// 存储形态仍然是逐章文件 —— 这个只是"要带走时才生成"。
  static Future<String?> exportTxt(String bookUrl, {String name = ''}) async {
    final dir = await findDir(bookUrl, name: name);
    final m = await metaOf(bookUrl, name: name);
    if (dir == null || m == null) return null;
    final texts = <String>[];
    for (var i = 0; i < m.total; i++) {
      final t = await chapterText(bookUrl, i, name: name);
      texts.add(t ?? '');
    }
    final out = File('${dir.path}/全书.txt');
    await out.writeAsString(
        OfflinePlan.mergeToText(texts, [for (final c in m.chapters) c['name'] ?? '']),
        flush: true);
    return out.path;
  }

  /// 下载一本书的全部章节。返回进度流，UI 直接 `await for` 画进度条。
  ///
  /// [book] 是 `Book.toJson()`（书名/作者/封面/地址都要，因为要写进清单，
  /// 否则离线后连书名都显示不出来）。
  ///
  /// 断点续传：每章落盘即写清单；重跑时跳过已存在的章节文件 —— 所以下载中途
  /// 退出/断网，再点一次就从缺的那章接着下，**不会整本重来**。
  ///
  /// 取不到正文的章节记为 failed 并**继续往下下**，不整轮 abort ——
  /// 源站缺一章是常事，为一章放弃整本书更糟。收尾时按磁盘实际状态定 done/partial。
  static Stream<OfflineProgress> download(Map<String, dynamic> book,
      {String kind = 'novel'}) async* {
    final bookUrl = '${book['bookUrl'] ?? ''}'.trim();
    final name = '${book['name'] ?? ''}'.trim();
    if (bookUrl.isEmpty) {
      yield const OfflineProgress(
          total: 0, done: 0, failed: 0, status: 'error', message: '这本书没有可下载的地址');
      return;
    }
    // 只有小说支持离线。漫画/音乐/视频的"正文"是图片与播放地址，落盘形态完全不同
    // （漫画要下图、音视频要下媒体文件），不能复用这套逐章 txt。
    if (kind != 'novel') {
      yield const OfflineProgress(
          total: 0,
          done: 0,
          failed: 0,
          status: 'error',
          message: '目前只有小说支持离线下载，其它类型请在有网时阅读');
      return;
    }

    yield const OfflineProgress(
        total: 0, done: 0, failed: 0, status: 'running', message: '正在取目录…');

    List<Map<String, String>> tocList;
    try {
      final raw = await EngineDirect.chapters('novel', bookUrl);
      tocList = [
        for (final c in raw)
          {
            'name': '${c['name'] ?? c['title'] ?? ''}',
            'url': '${c['url'] ?? c['id'] ?? ''}',
          }
      ];
    } catch (e) {
      yield OfflineProgress(
          total: 0,
          done: 0,
          failed: 0,
          status: 'error',
          message: '取目录失败：$e');
      return;
    }
    if (tocList.isEmpty) {
      yield const OfflineProgress(
          total: 0, done: 0, failed: 0, status: 'error', message: '这本书没有可下载的章节');
      return;
    }

    final dir = await _createDir(bookUrl, name);
    final chDir = Directory('${dir.path}/chapters');
    final total = tocList.length;

    Future<List<String>> names() async => [
          await for (final e in chDir.list(followLinks: false))
            e.uri.pathSegments.where((s) => s.isNotEmpty).last
        ];

    final namesNow = await names();
    // 断点续传从哪章接着下 —— 规则在 offline_plan.nextMissingIndex。
    // ★ 用"第一个缺失的下标"而不是"已完成数"：中间有缺章时前者才对，
    //   后者会永远跳过那几章（下完的书中间缺一章，翻到才发现）。
    final nextIdx = OfflinePlan.nextMissingIndex(namesNow, total);
    var done = OfflinePlan.countDone(namesNow, total);
    var failed = 0;
    var meta = OfflineMeta(
      bookUrl: bookUrl,
      name: name,
      author: '${book['author'] ?? ''}',
      coverUrl: '${book['coverUrl'] ?? ''}',
      intro: '${book['intro'] ?? ''}',
      sourceId: '${book['sourceId'] ?? 'engine'}',
      kind: kind,
      status: 'running',
      at: OfflinePlan.stamp(),
      total: total,
      done: done,
      failed: 0,
      chapters: tocList,
    );
    await _saveMeta(dir, meta);
    yield OfflineProgress(
        total: total,
        done: done,
        failed: 0,
        status: 'running',
        message: done > 0
            ? '共 $total 章，已有 $done 章，从第 ${(nextIdx ?? 0) + 1} 章接着下'
            : '共 $total 章');

    for (var i = 0; i < total; i++) {
      final f = File('${chDir.path}/${OfflinePlan.chapterFileName(i)}');
      var ok = false;
      if (await f.exists()) {
        try {
          ok = (await f.length()) > 0;
        } catch (_) {
          ok = false;
        }
      }
      if (ok) continue; // 断点续传：这章已经有了

      String? text;
      try {
        final d = await EngineDirect.content('novel', bookUrl, tocList[i]['url'] ?? '');
        text = '${d['text'] ?? d['content'] ?? ''}';
      } catch (_) {
        text = null;
      }
      if (text == null || text.trim().isEmpty) {
        failed++;
        meta = meta.copyWith(failed: failed, at: OfflinePlan.stamp());
        await _saveMeta(dir, meta);
        yield OfflineProgress(
            total: total,
            done: done,
            failed: failed,
            status: 'running',
            message: '第 ${i + 1}/$total 章取不到正文，已跳过');
        continue;
      }
      try {
        await f.writeAsString(text, flush: true);
        done++;
      } catch (_) {
        failed++;
      }
      meta = meta.copyWith(done: done, failed: failed, at: OfflinePlan.stamp());
      await _saveMeta(dir, meta);
      yield OfflineProgress(
          total: total,
          done: done,
          failed: failed,
          status: 'running',
          message: '正在下载 第 ${i + 1}/$total 章');
    }

    // 收尾一律以**磁盘实际状态**为准，不信任循环里自己数的 done ——
    // 写文件失败/被系统清理都会让两者不一致，而清单是下次续传的依据。
    done = OfflinePlan.countDone(await names(), total);
    final status = OfflinePlan.statusOf(total, done, failed);
    meta = meta.copyWith(
        done: done, failed: failed, status: status, at: OfflinePlan.stamp());
    await _saveMeta(dir, meta);
    yield OfflineProgress(
        total: total,
        done: done,
        failed: failed,
        status: status,
        message: status == 'done'
            ? '已离线 $total 章'
            : status == 'partial'
                ? '已离线 $done/$total 章（$failed 章没取到，可再点一次补）'
                : '离线失败，可再点一次重试');
  }
}
