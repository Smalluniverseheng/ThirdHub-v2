// 离线下载的**界面层**：进度弹窗 + 书架长按菜单。
//
// 只吃 `Book.toJson()` 那样的 Map，**不 import main.dart** ——
// 免得和 main.dart 互相引用（Dart 允许循环 import，但纯 Dart 自检要能单独编译
// 规则层，一旦 UI 层把 main.dart 拽进来，自检就跟着编译整个 App，全废）。
//
// 三个入口：
//   · [OfflineUI.download]      —— 弹进度条把全书下完（可取消，取消会收敛状态）
//   · [OfflineUI.shelfMenu]     —— 书架长按菜单，返回让调用方做的动作
//   · [OfflineUI.progressLine]  —— 书架卡片下面那行小字（已离线 N 章 · 多少 MB）
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'apple_gate.dart';
import 'offline_media_plan.dart';
import 'offline_media_store.dart';
import 'offline_plan.dart';
import 'offline_store.dart';

class OfflineUI {
  /// 长按菜单返回的动作，调用方自己决定怎么落地。
  static const String actDownload = 'download'; // 下载/续传全书
  static const String actDeleteOffline = 'deleteOffline'; // 只删离线内容，书留在书架
  static const String actRemove = 'remove'; // 移出书架
  static const String actExport = 'export'; // 导出成单个 txt
  static const String actCancel = 'cancel';

  /// ★阶段6 平台门（Apple 过审 5.2.3）：iOS 不开放批量下载 —— 这里是**唯一收口**，
  ///   三个入口（书架长按 / 详情页按钮 / 加书架顺带下载）都走本文件，闸门放这里
  ///   不会漏判。单章缓存是阅读器正常行为，不受此闸约束。
  static bool get batchDownloadAllowed => currentGate().allowBatchDownload;

  /// 下载全书（带进度弹窗、可取消）。返回最终状态：done/partial/error/cancel。
  static Future<String> download(BuildContext c, Map<String, dynamic> book,
      {String kind = 'novel'}) async {
    if (!batchDownloadAllowed) return 'blocked';
    final s = await showDialog<String>(
        context: c,
        barrierDismissible: false,
        builder: (c2) => _DownloadDialog(book: book, kind: kind));
    if (s != null && s != 'cancel') return s;
    // 用户中途取消：把清单从 running 收敛掉，否则书架上一直显示"下载中"
    await OfflineStore.finalizeMeta('${book['bookUrl'] ?? ''}',
        name: '${book['name'] ?? ''}');
    return 'cancel';
  }

  /// 书架卡片长按菜单。返回 [actXxx] 之一；用户关掉返回 [actCancel]。
  ///
  /// [kind] 决定要不要给离线相关条目：目前只有小说支持离线下载，
  /// 视频/音乐点了只会弹一句"不支持"，不如一开始就不摆出来。
  static Future<String> shelfMenu(BuildContext c,
      {required String name,
      required String bookUrl,
      String kind = 'novel'}) async {
    final m = await OfflineStore.metaOf(bookUrl, name: name);
    final has = m != null && m.done > 0;
    final complete = m != null && OfflinePlan.isDone(m);
    final canOffline = kind == 'novel';
    if (!c.mounted) return actCancel;
    return await showModalBottomSheet<String>(
          context: c,
          builder: (c2) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text('《$name》',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600))),
              if (canOffline && m != null)
                Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                        m.status == 'running'
                            ? '正在下载…'
                            : OfflinePlan.describe(m),
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey))),
              if (canOffline && !complete && batchDownloadAllowed)
                ListTile(
                    leading: Icon(
                        has
                            ? Icons.downloading
                            : Icons.download_for_offline,
                        color: Colors.blueAccent),
                    title: Text(
                        has ? '继续下载（缺 ${m!.total - m.done} 章）' : '下载全书，离线也能读'),
                    subtitle: const Text('逐章抓取并存到本机，中途可取消、再点会接着下',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () => Navigator.pop(c2, actDownload)),
              if (canOffline && has)
                ListTile(
                    leading:
                        const Icon(Icons.ios_share, color: Colors.teal),
                    title: const Text('导出为单个 txt'),
                    subtitle: const Text('合成一个文件，方便拷去电脑或别的阅读器',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () => Navigator.pop(c2, actExport)),
              if (canOffline && has)
                ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined,
                        color: Colors.orange),
                    title: const Text('删除离线内容'),
                    subtitle: const Text('书留在书架，只是不再占用本机空间',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () => Navigator.pop(c2, actDeleteOffline)),
              ListTile(
                  leading:
                      const Icon(Icons.bookmark_remove, color: Colors.redAccent),
                  title: const Text('移出书架'),
                  onTap: () => Navigator.pop(c2, actRemove)),
              const Divider(height: 1),
              ListTile(
                  leading: const Icon(Icons.close),
                  title: const Text('取消'),
                  onTap: () => Navigator.pop(c2, actCancel)),
            ]),
          ),
        ) ??
        actCancel;
  }

  /// 书架卡片下那行小字。没离线内容时返回 null（调用方继续显示作者/进度）。
  static Future<String?> progressLine(String bookUrl, String name,
      {String kind = 'novel'}) async {
    final m = await OfflineStore.metaOf(bookUrl, name: name);
    if (m == null) return null;
    return OfflinePlan.describe(m);
  }

  /// 媒体保存到本机（视频一集 / 音乐一首 / 漫画一话）。返回 done/partial/error/cancel/blocked。
  ///
  /// [pages] 非空 = 漫画逐页模式；为空则按 [url] 整文件下载。
  /// 与小说同一道 iOS 平台门（Apple 5.2.3）：闸门在这，调用点不用再判。
  static Future<String> mediaDownload(
    BuildContext c, {
    required String kind,
    required String key,
    required String title,
    String url = '',
    List<String>? pages,
    String subtitle = '',
    String coverUrl = '',
    Map<String, String> headers = const {},
  }) async {
    if (!batchDownloadAllowed) return 'blocked';
    final s = await showDialog<String>(
        context: c,
        barrierDismissible: false,
        builder: (c2) => _MediaDownloadDialog(
            kind: kind,
            itemKey: key,
            title: title,
            url: url,
            pages: pages,
            subtitle: subtitle,
            coverUrl: coverUrl,
            headers: headers));
    return s ?? 'cancel';
  }
}

/// 进度弹窗：跑 [OfflineStore.download]，把进度画出来，跑完自动关。
class _DownloadDialog extends StatefulWidget {
  final Map<String, dynamic> book;
  final String kind;
  const _DownloadDialog({required this.book, required this.kind});
  @override
  State<_DownloadDialog> createState() => _DlState();
}

class _DlState extends State<_DownloadDialog> {
  OfflineProgress p = const OfflineProgress(
      total: 0, done: 0, failed: 0, status: 'running', message: '准备中…');
  StreamSubscription<OfflineProgress>? sub;
  String result = 'cancel';

  @override
  void initState() {
    super.initState();
    sub = OfflineStore.download(widget.book, kind: widget.kind).listen((x) {
      if (!mounted) return;
      setState(() => p = x);
      result = x.status;
      if (x.finished) {
        // 停一下再关：让用户看清"已离线 N 章"，不然弹窗一闪而过像没成功
        Future.delayed(const Duration(milliseconds: 700), () {
          if (mounted) Navigator.of(context).pop(x.status);
        });
      }
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() => p = OfflineProgress(
          total: p.total,
          done: p.done,
          failed: p.failed,
          status: 'error',
          message: '下载出错：$e'));
      result = 'error';
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.of(context).pop('error');
      });
    });
  }

  @override
  void dispose() {
    sub?.cancel(); // 离开页面/关弹窗都要掐断，否则后台继续打引擎、继续写盘
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final name = '${widget.book['name'] ?? '这本书'}';
    return AlertDialog(
      title: Text(p.finished ? '离线下载' : '正在离线《$name》'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: p.total > 0 ? p.ratio : null, minHeight: 6)),
        const SizedBox(height: 12),
        Text(p.message.isEmpty ? '准备中…' : p.message,
            style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 4),
        Text(
            p.total > 0
                ? '第 ${p.done + p.failed} / ${p.total} 章${p.failed > 0 ? '（${p.failed} 章没取到）' : ''}'
                : ' ',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      actions: [
        if (!p.finished)
          TextButton(
              onPressed: () {
                sub?.cancel();
                Navigator.of(c).pop('cancel');
              },
              child: const Text('取消')),
        if (p.finished)
          TextButton(onPressed: () => Navigator.of(c).pop(result), child: const Text('好')),
      ],
    );
  }
}

/// 媒体进度弹窗：跑 [MediaOfflineStore] 的下载流，跑完自动关。
/// 单文件模式按字节进度（"3.2 MB / 12.4 MB"），漫画模式按页进度（"第 8/20 页"）。
class _MediaDownloadDialog extends StatefulWidget {
  final String kind, itemKey, title, url, subtitle, coverUrl;
  final List<String>? pages;
  final Map<String, String> headers;
  const _MediaDownloadDialog({
    required this.kind,
    required this.itemKey,
    required this.title,
    required this.url,
    this.pages,
    this.subtitle = '',
    this.coverUrl = '',
    this.headers = const {},
  });
  @override
  State<_MediaDownloadDialog> createState() => _MdState();
}

class _MdState extends State<_MediaDownloadDialog> {
  OfflineProgress p = const OfflineProgress(
      total: 0, done: 0, failed: 0, status: 'running', message: '准备中…');
  StreamSubscription<OfflineProgress>? sub;
  String result = 'cancel';

  @override
  void initState() {
    super.initState();
    final pages = widget.pages;
    sub = (pages != null
            ? MediaOfflineStore.downloadPages(
                key: widget.itemKey,
                title: widget.title,
                pages: pages,
                subtitle: widget.subtitle,
                coverUrl: widget.coverUrl,
                headers: widget.headers)
            : MediaOfflineStore.downloadFile(
                kind: widget.kind,
                key: widget.itemKey,
                title: widget.title,
                url: widget.url,
                subtitle: widget.subtitle,
                coverUrl: widget.coverUrl,
                headers: widget.headers))
        .listen((x) {
      if (!mounted) return;
      setState(() => p = x);
      result = x.status;
      if (x.finished) {
        Future.delayed(const Duration(milliseconds: 700), () {
          if (mounted) Navigator.of(context).pop(x.status);
        });
      }
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() => p = OfflineProgress(
          total: p.total,
          done: p.done,
          failed: p.failed,
          status: 'error',
          message: '下载出错：$e'));
      result = 'error';
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.of(context).pop('error');
      });
    });
  }

  @override
  void dispose() {
    sub?.cancel(); // 关弹窗/离开页面都要掐断，否则后台继续下、继续写盘
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final isPages = widget.pages != null;
    return AlertDialog(
      title: Text(p.finished ? '保存到本机' : '正在保存《${widget.title}》'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: p.total > 0 ? p.ratio : null, minHeight: 6)),
        const SizedBox(height: 12),
        Text(p.message.isEmpty ? '准备中…' : p.message,
            style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 4),
        Text(
            isPages && p.total > 0
                ? '第 ${p.done + p.failed} / ${p.total} 页${p.failed > 0 ? '（${p.failed} 页没取到）' : ''}'
                : '下到本机后，断网也能看',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      actions: [
        if (!p.finished)
          TextButton(
              onPressed: () {
                sub?.cancel();
                Navigator.of(c).pop('cancel');
              },
              child: const Text('取消')),
        if (p.finished)
          TextButton(
              onPressed: () => Navigator.of(c).pop(result), child: const Text('好')),
      ],
    );
  }
}

/// 离线内容管理页：小说（offline_books）+ 媒体（offline_media）一处看、一处删。
/// 不 import main.dart（与 offline_ui 的纪律一致），用 Navigator.pop 回调即可。
class MediaOfflinePage extends StatefulWidget {
  const MediaOfflinePage({super.key});
  @override
  State<MediaOfflinePage> createState() => _MediaOfflinePageState();
}

class _MediaOfflinePageState extends State<MediaOfflinePage> {
  List<OfflineMeta> books = [];
  List<MediaOfflineMeta> media = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    books = await OfflineStore.list();
    media = await MediaOfflineStore.list();
    if (mounted) setState(() => loading = false);
  }

  static const _kindIcon = {
    'video': Icons.videocam_outlined,
    'music': Icons.music_note,
    'comic': Icons.menu_book_outlined,
    'novel': Icons.book_outlined,
  };

  @override
  Widget build(BuildContext c) {
    final totalBytes = media.fold<int>(0, (n, m) => n + m.bytes);
    return Scaffold(
        appBar: AppBar(
            title: const Text('离线内容'),
            actions: [
              if (books.isNotEmpty || media.isNotEmpty)
                Center(
                    child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(
                            '${books.length + media.length} 项 · ${MediaOfflinePlan.bytesLabel(totalBytes)}',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey))))
            ]),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : (books.isEmpty && media.isEmpty)
                ? const Center(
                    child: Text('还没有离线内容\n看书/看剧/听歌时点「保存到本机」，断网也能用',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)))
                : ListView(children: [
                    if (media.isNotEmpty)
                      const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('视频 / 音乐 / 漫画',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey))),
                    for (final m in media)
                      ListTile(
                          leading: Icon(_kindIcon[m.kind] ?? Icons.folder_outlined),
                          title: Text(m.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(MediaOfflinePlan.describe(m),
                              style: const TextStyle(fontSize: 11)),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.redAccent),
                              onPressed: () async {
                                await MediaOfflineStore.remove(m.key,
                                    title: m.title);
                                _load();
                              })),
                    if (books.isNotEmpty)
                      const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('小说',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey))),
                    for (final b in books)
                      ListTile(
                          leading: const Icon(Icons.book_outlined),
                          title: Text(b.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(OfflinePlan.describe(b),
                              style: const TextStyle(fontSize: 11)),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.redAccent),
                              onPressed: () async {
                                await OfflineStore.remove(b.bookUrl,
                                    name: b.name);
                                _load();
                              })),
                  ]));
  }
}
