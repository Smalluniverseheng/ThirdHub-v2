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
import 'package:shared_preferences/shared_preferences.dart';

import 'apple_gate.dart';
import 'dialog_kit.dart';
import 'download_queue.dart';
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
                        has ? '继续下载（缺 ${m.total - m.done} 章）' : '下载全书，离线也能读'),
                    subtitle: const Text('逐章抓取并存到本机，中途可取消、再点会接着下',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () => Navigator.pop(c2, actDownload)),
              // ★M4e：动作按使用频率排序 —— 下载 > 删除 > 导出 > 移出书架。
              if (canOffline && has)
                ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined,
                        color: Colors.orange),
                    title: const Text('删除离线内容'),
                    subtitle: const Text('书留在书架，只是不再占用本机空间',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () => Navigator.pop(c2, actDeleteOffline)),
              if (canOffline && has)
                ListTile(
                    leading:
                        const Icon(Icons.ios_share, color: Colors.teal),
                    title: const Text('导出为单个 txt'),
                    subtitle: const Text('合成一个文件，方便拷去电脑或别的阅读器',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    onTap: () => Navigator.pop(c2, actExport)),
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

  // ★M4c：传输测速（只服务"有字节进度"的模式：单文件 / HLS；
  //   漫画按"页"显示进度，不算速度）。指数平滑，避免数字跳动。
  DateTime _speedT0 = DateTime.now();
  int _speedBytes0 = 0;
  double _speedBps = 0;
  String _speedLabel = ''; // 例："1.2 MB/s"
  String _etaLabel = ''; // 例："剩约 3 分钟"

  void _tickSpeed(OfflineProgress x) {
    if (widget.pages != null) return; // 页模式不显示速度
    if (x.status != 'running') return;
    final now = DateTime.now();
    final dtMs = now.difference(_speedT0).inMilliseconds;
    if (dtMs < 400 || x.bytes < _speedBytes0) return;
    final inst = (x.bytes - _speedBytes0) * 1000 / dtMs;
    _speedBps = _speedBps <= 0 ? inst : (_speedBps * 0.6 + inst * 0.4);
    _speedT0 = now;
    _speedBytes0 = x.bytes;
    _speedLabel =
        _speedBps >= 32 * 1024 ? '${MediaOfflinePlan.bytesLabel(_speedBps.round())}/s' : '';
    if (x.totalBytes > 0 && x.bytes < x.totalBytes && _speedBps > 2048) {
      final secs = (x.totalBytes - x.bytes) / _speedBps;
      _etaLabel = secs < 45
          ? '很快就好'
          : secs < 90
              ? '剩约 1 分钟'
              : '剩约 ${(secs / 60).round()} 分钟';
    } else {
      _etaLabel = ''; // HLS 无总量（或还没测准）时不猜剩余时间
    }
  }

  @override
  void initState() {
    super.initState();
    final pages = widget.pages;
    // ★HLS 分流（规划册 H1）：m3u8 走「拉清单 → 逐片下载 → 合并成单文件」流程；
    //   直播/加密流在 IO 层被拒绝（判定口径在 HlsPlan，这里不做判定）。
    sub = (pages != null
            ? MediaOfflineStore.downloadPages(
                key: widget.itemKey,
                title: widget.title,
                pages: pages,
                subtitle: widget.subtitle,
                coverUrl: widget.coverUrl,
                headers: widget.headers)
            : HlsPlan.isHls(widget.url)
                ? MediaOfflineStore.downloadHls(
                    kind: widget.kind,
                    key: widget.itemKey,
                    title: widget.title,
                    url: widget.url,
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
      setState(() {
        p = x;
        _tickSpeed(x);
      });
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
                : (p.running && (_speedLabel.isNotEmpty || _etaLabel.isNotEmpty))
                    ? [
                        if (_speedLabel.isNotEmpty) _speedLabel,
                        if (_etaLabel.isNotEmpty) _etaLabel,
                      ].join(' · ')
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
  StreamSubscription<void>? _qsub;

  /// ★M3：离线存储上限（MB；0 = 不限）。默认 20GB。
  int _limitMb = 20480;

  /// ★L1（2026-10-12）：小说离线总占用（加载时扫目录算；书量少，代价可忽略）。
  int novelBytes = 0;

  // ★2026-10-12：多选批量删除模式。_sel 里是 'm:<key>'（媒体）/ 'n:<bookUrl>'（小说）——
  // 加前缀是因为两边的 key 都是裸字符串，可能撞车。
  bool _selectMode = false;
  final Set<String> _sel = {};

  @override
  void initState() {
    super.initState();
    _initLimit();
    _load();
    // ★M1：下载队列变化实时刷新本页（进行中/失败/完成都动）。
    _qsub = DownloadQueue.i.onChange.listen((_) {
      if (!mounted) return;
      setState(() {});
      // 队列清空时刷新离线列表（刚完成的任务已进离线库）+ 检查上限。
      if (DownloadQueue.i.active.isEmpty) {
        _load().then((_) => _maybeAutoCleanup());
      }
    });
  }

  Future<void> _initLimit() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _limitMb = p.getInt('offline_limit_mb') ?? 20480);
    await _maybeAutoCleanup();
  }

  @override
  void dispose() {
    _qsub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    books = await OfflineStore.list();
    media = await MediaOfflineStore.list();
    // ★L1：小说占用（单独 try——算不出不拖垮整页）。
    try {
      var n = 0;
      for (final b in books) {
        n += await OfflineStore.bytesOf(b.bookUrl, name: b.name);
      }
      novelBytes = n;
    } catch (_) {
      novelBytes = 0;
    }
    if (mounted) setState(() => loading = false);
  }

  /// ★L1（2026-10-12）：离线存储统计卡 —— 媒体（蓝）+ 小说（青）两段占比，
  /// 上限做分母；无内容时零高度。
  Widget _storageCard(BuildContext c) {
    final mediaBytes = media.fold<int>(0, (n, m) => n + m.bytes);
    final total = mediaBytes + novelBytes;
    if (total <= 0) return const SizedBox.shrink();
    final limit = _limitMb <= 0 ? 0 : _limitMb * 1024 * 1024;
    final mFlex = mediaBytes * 1000 ~/ total;
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.sd_storage_outlined, size: 15, color: Colors.grey),
            const SizedBox(width: 6),
            Text('离线占用 ${MediaOfflinePlan.bytesLabel(total)}',
                style: const TextStyle(fontSize: 12)),
            const Spacer(),
            Text(limit > 0 ? '上限 ${MediaOfflinePlan.bytesLabel(limit)}' : '不限制',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                  height: 6,
                  child: Row(children: [
                    if (mediaBytes > 0)
                      Expanded(
                          flex: mFlex < 1 ? 1 : mFlex,
                          child: Container(color: Colors.blueAccent)),
                    if (novelBytes > 0)
                      Expanded(
                          flex: (1000 - mFlex) < 1 ? 1 : 1000 - mFlex,
                          child: Container(color: Colors.teal)),
                  ]))),
          const SizedBox(height: 4),
          Text(
              '媒体 ${MediaOfflinePlan.bytesLabel(mediaBytes)} · '
              '小说 ${MediaOfflinePlan.bytesLabel(novelBytes)}'
              '${limit > 0 ? ' · 已用 ${(total * 100 / limit).clamp(0, 999).toStringAsFixed(0)}%' : ''}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]));
  }

  /// ★M1：下载任务段 —— 进行中（可取消）+ 最近失败（可重试）；无任务时零高度。
  Widget _queueSection(BuildContext c) {
    final q = DownloadQueue.i;
    final active = List<DlJob>.from(q.active);
    final failed = q.finished.where((j) => j.state == DlState.error).toList();
    if (active.isEmpty && failed.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            const Text('下载任务',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const Spacer(),
            if (q.finished.isNotEmpty)
              TextButton(
                  onPressed: () async {
                    final ok = await confirmDanger(context,
                        title: '清空完成记录？',
                        content: '只清任务列表里的记录，已下载的内容不受影响。',
                        okLabel: '清空');
                    if (ok) {
                      q.clearFinished();
                      setState(() {});
                    }
                  },
                  child: const Text('清记录', style: TextStyle(fontSize: 11))),
          ])),
      for (final j in active)
        ListTile(
          dense: true,
          leading: Icon(
              j.state == DlState.running
                  ? Icons.downloading
                  : Icons.schedule,
              color: j.state == DlState.running
                  ? Colors.blueAccent
                  : Colors.blueGrey),
          title: Text(j.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 3),
                LinearProgressIndicator(
                    value: j.total > 0 ? j.ratio : null, minHeight: 4),
                const SizedBox(height: 2),
                Text(
                    j.message.isEmpty
                        ? j.state.zh
                        : '${j.state.zh} · ${j.message}',
                    style: const TextStyle(fontSize: 11)),
              ]),
          trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: '取消',
              onPressed: () {
                q.cancel(j.id);
                setState(() {});
              }),
        ),
      for (final j in failed)
        ListTile(
          dense: true,
          leading: const Icon(Icons.error_outline, color: Colors.redAccent),
          title: Text(j.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('失败：${j.message}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)),
          trailing: IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: '重试',
              onPressed: () {
                q.retry(j.id);
                setState(() {});
              }),
        ),
      const Divider(height: 8),
    ]);
  }

  /// ★M3：离线存储上限设置（0 = 不限）。
  Future<void> _editLimit() async {
    final cur = _limitMb;
    final opts = <int>[0, 5120, 10240, 20480, 51200];
    const labels = <int, String>{
      0: '不限制',
      5120: '5 GB',
      10240: '10 GB',
      20480: '20 GB（推荐）',
      51200: '50 GB',
    };
    final totalNow = media.fold<int>(0, (n, m) => n + m.bytes);
    final pick = await showDialog<int>(
        context: context,
        builder: (c2) => SimpleDialog(
                title: const Text('离线存储上限'),
                children: [
                  for (final o in opts)
                    RadioListTile<int>(
                        value: o,
                        groupValue: cur,
                        title: Text(labels[o] ?? '$o MB'),
                        onChanged: (v) => Navigator.pop(c2, v)),
                  Padding(
                      padding: const EdgeInsets.fromLTRB(24, 2, 24, 10),
                      child: Text(
                          '超出上限时自动清理最早的离线内容（最早下载的优先删）。'
                          '当前媒体离线占用 ${MediaOfflinePlan.bytesLabel(totalNow)}。',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey))),
                ]));
    if (pick == null || !mounted) return;
    final p = await SharedPreferences.getInstance();
    await p.setInt('offline_limit_mb', pick);
    if (!mounted) return;
    setState(() => _limitMb = pick);
    await _maybeAutoCleanup();
  }

  /// ★M3：超上限则自动清理最旧的媒体离线记录（当前只统计"媒体"；小说离线后续纳入）。
  Future<void> _maybeAutoCleanup() async {
    if (_limitMb <= 0 || (media.isEmpty && books.isEmpty)) return;
    // ★L1（2026-10-12）：小说离线也纳入超限统计与清理（小说现算占用——只在检查时付代价）。
    final items = <({String key, int bytes, String at})>[
      for (final m in media) (key: 'm:${m.key}', bytes: m.bytes, at: m.at),
    ];
    for (final b in books) {
      try {
        items.add((
          key: 'n:${b.bookUrl}',
          bytes: await OfflineStore.bytesOf(b.bookUrl, name: b.name),
          at: b.at,
        ));
      } catch (_) {}
    }
    final plan = OfflinePlan.planCleanup(items, _limitMb * 1024 * 1024);
    if (plan.isEmpty) return;
    for (final k in plan) {
      if (k.startsWith('n:')) {
        final url = k.substring(2);
        final b =
            books.firstWhere((x) => x.bookUrl == url, orElse: () => books.first);
        await OfflineStore.remove(url, name: b.name);
      } else {
        final key = k.startsWith('m:') ? k.substring(2) : k;
        final t = media
            .firstWhere((x) => x.key == key, orElse: () => media.first)
            .title;
        await MediaOfflineStore.remove(key,
            title: t, permanent: true); // 自动清理不进回收站
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('离线空间超过上限，已自动清理 ${plan.length} 项（最早下载的优先）')));
    await _load();
  }

  // ───────── ★2026-10-12：多选批量 + 删除可撤销 ─────────

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  /// 删除成功后的「撤销」提示（5 秒窗口；撤销 = 从回收站搬回）。
  void _snackWithUndo(String text, String key, String title) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              final ok = await MediaOfflineStore.restore(key, title: title);
              if (!mounted) return;
              _snack(ok ? '已恢复' : '恢复失败（可能已过期或被清掉）');
              if (ok) await _load();
            })));
  }

  /// 批量撤销（SnackBar 一个「撤销」恢复全部媒体项）。
  void _snackWithUndoBatch(String text, List<(String, String)> keys) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              var ok = 0;
              for (final e in keys) {
                if (await MediaOfflineStore.restore(e.$1, title: e.$2)) ok++;
              }
              if (!mounted) return;
              _snack('已恢复 $ok/${keys.length} 项');
              await _load();
            })));
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _sel.clear();
    });
  }

  /// 单选删除：媒体软删（可撤销）；小说直接删（没有回收站）。
  Future<void> _deleteOne(String tag, String key, String title) async {
    if (tag.startsWith('m:')) {
      final ok = await MediaOfflineStore.remove(key, title: title);
      if (!ok) {
        _snack('删除失败，重试一下');
        return;
      }
      await _load();
      _snackWithUndo('已删除《$title》', key, title);
    } else {
      await OfflineStore.remove(key, name: title);
      await _load();
      _snack('已删除《$title》（小说离线没有回收站，不可撤销）');
    }
  }

  /// 多选删除（确认弹窗走统一危险规范）。
  Future<void> _deleteSelected() async {
    if (_sel.isEmpty) return;
    final mediaTags = _sel.where((t) => t.startsWith('m:')).toList();
    final novelTags = _sel.where((t) => t.startsWith('n:')).toList();
    final ok = await confirmDanger(
        context,
        title: '删除 ${_sel.length} 项？',
        content: mediaTags.isNotEmpty
            ? '媒体离线 ${mediaTags.length} 项先移入回收站（5 秒内可撤销）；'
                '小说离线 ${novelTags.length} 项直接删除、不可恢复。'
            : '小说离线共 ${novelTags.length} 项，直接删除、不可恢复。');
    if (!ok || !mounted) return;
    var n = 0;
    final restored = <(String, String)>[];
    for (final t in mediaTags) {
      final key = t.substring(2);
      final m = media.firstWhere((x) => x.key == key, orElse: () => media.first);
      if (await MediaOfflineStore.remove(key, title: m.title)) {
        n++;
        restored.add((key, m.title));
      }
    }
    for (final t in novelTags) {
      final url = t.substring(2);
      final b = books.firstWhere((x) => x.bookUrl == url, orElse: () => books.first);
      await OfflineStore.remove(url, name: b.name);
      n++;
    }
    await _load();
    _exitSelect();
    if (restored.isNotEmpty) {
      _snackWithUndoBatch('已删除 $n 项', restored);
    } else {
      _snack('已删除 $n 项（小说离线不可撤销）');
    }
  }

  /// 多选模式下的行（选中圈 + 高亮；点击/长按都切换选中）。
  Widget _selectTile(String tag, String title,
      {Widget? leadingIcon, Widget? subtitle}) {
    final on = _sel.contains(tag);
    return ListTile(
        selected: on,
        selectedTileColor:
            Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
        leading: Icon(
            on ? Icons.check_circle : Icons.radio_button_unchecked,
            color: on ? Theme.of(context).colorScheme.primary : Colors.grey),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle,
        onTap: () => _toggleSel(tag),
        onLongPress: () => _toggleSel(tag));
  }

  void _toggleSel(String tag) {
    setState(() {
      if (!_sel.add(tag)) _sel.remove(tag);
    });
  }

  /// 多选态的 AppBar（全选/反选 + 红色删除）。
  AppBar _selectAppBar() => AppBar(
      leading: IconButton(
          icon: const Icon(Icons.close), tooltip: '退出多选', onPressed: _exitSelect),
      title: Text('已选 ${_sel.length} 项'),
      actions: [
        IconButton(
            icon: const Icon(Icons.select_all),
            tooltip: '全选 / 全不选',
            onPressed: () {
              final all = <String>{
                for (final m in media) 'm:${m.key}',
                for (final b in books) 'n:${b.bookUrl}',
              };
              setState(() {
                if (_sel.length == all.length) {
                  _sel.clear();
                } else {
                  _sel.addAll(all);
                }
              });
            }),
        Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
                onPressed: _sel.isEmpty ? null : _deleteSelected)),
      ]);

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
        appBar: _selectMode
            ? _selectAppBar()
            : AppBar(
                title: const Text('离线内容'),
                actions: [
                  if (books.isNotEmpty || media.isNotEmpty) ...[
                    Center(
                        child: Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Text(
                                '${books.length + media.length} 项 · ${MediaOfflinePlan.bytesLabel(totalBytes)}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)))),
                    // ★2026-10-12：多选批量删除入口。
                    IconButton(
                        icon: const Icon(Icons.checklist, size: 20),
                        tooltip: '多选删除',
                        onPressed: () => setState(() => _selectMode = true)),
                  ],
                  // ★M3：离线存储上限（点开可调；超限自动清理最旧的）。
                  IconButton(
                      icon: const Icon(Icons.storage_outlined, size: 20),
                      tooltip: '离线存储上限',
                      onPressed: _editLimit),
                ]),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                _storageCard(c),
                _queueSection(c),
                Expanded(
                    child: (books.isEmpty && media.isEmpty)
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
                      _selectMode
                          ? _selectTile(
                              'm:${m.key}',
                              m.title,
                              leadingIcon: Icon(
                                  _kindIcon[m.kind] ?? Icons.folder_outlined),
                              subtitle: Text(MediaOfflinePlan.describe(m),
                                  style: const TextStyle(fontSize: 11)))
                          : ListTile(
                              leading: Icon(
                                  _kindIcon[m.kind] ?? Icons.folder_outlined),
                          title: Text(m.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(MediaOfflinePlan.describe(m),
                              style: const TextStyle(fontSize: 11)),
                          trailing: _selectMode
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.redAccent),
                                  tooltip: '删除（5 秒内可撤销）',
                                  onPressed: () => _deleteOne(
                                      'm:${m.key}', m.key, m.title))),
                    if (books.isNotEmpty)
                      const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('小说',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey))),
                    for (final b in books)
                      _selectMode
                          ? _selectTile(
                              'n:${b.bookUrl}',
                              b.name,
                              leadingIcon: const Icon(Icons.book_outlined),
                              subtitle: Text(OfflinePlan.describe(b),
                                  style: const TextStyle(fontSize: 11)))
                          : ListTile(
                              leading: const Icon(Icons.book_outlined),
                              title: Text(b.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(OfflinePlan.describe(b),
                                  style: const TextStyle(fontSize: 11)),
                          trailing: _selectMode
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.redAccent),
                                  tooltip: '删除（小说离线不可撤销）',
                                  onPressed: () => _deleteOne(
                                      'n:${b.bookUrl}', b.bookUrl, b.name))),
                  ])),
              ]));
  }
}
