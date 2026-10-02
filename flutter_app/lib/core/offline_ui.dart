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

import 'offline_plan.dart';
import 'offline_store.dart';

class OfflineUI {
  /// 长按菜单返回的动作，调用方自己决定怎么落地。
  static const String actDownload = 'download'; // 下载/续传全书
  static const String actDeleteOffline = 'deleteOffline'; // 只删离线内容，书留在书架
  static const String actRemove = 'remove'; // 移出书架
  static const String actExport = 'export'; // 导出成单个 txt
  static const String actCancel = 'cancel';

  /// 下载全书（带进度弹窗、可取消）。返回最终状态：done/partial/error/cancel。
  static Future<String> download(BuildContext c, Map<String, dynamic> book,
      {String kind = 'novel'}) async {
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
              if (canOffline && !complete)
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
