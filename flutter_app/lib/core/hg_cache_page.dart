// 红果离线缓存管理页（4.81.108）
//
// 和「我的 → 离线内容」通用页的区别：这里只管红果一个板块，把两类本机数据
// 摆在一起看 —— ① 已下载的视频（真能断网播的）；② 资料缓存（推荐/搜索/简介/
// 分集，断网能看但不含播放地址）。用户在同一个地方看占用、删单条、一键清空。
//
// 纪律：
//   · 本页不依赖主入口、不请求后端接口，否则断网时连管理页都打不开；
//   · 点已下载条目只走 PlayResolver.localFileOf（纯磁盘），命中 file:// 直接播；
//   · 播放地址属于有时效的数据，既不在 HgCache 里写，也不在本页落盘。
library;

import 'package:flutter/material.dart';

import 'app_widgets.dart';
import 'hg_cache.dart';
import 'haptic.dart';
import 'i18n.dart';
import 'offline_media_plan.dart';
import 'offline_media_store.dart';
import 'play_resolver.dart';
import 'player/media_spec.dart';
import 'player/unified_player.dart';
import 'ui/app_skeleton.dart' show AppLoading;

class HgCachePage extends StatefulWidget {
  const HgCachePage({super.key});

  @override
  State<HgCachePage> createState() => _HgCachePageState();
}

class _HgCachePageState extends State<HgCachePage> {
  List<MediaOfflineMeta> _videos = const [];
  List<HgCacheEntry> _entries = const [];
  final Map<String, int> _bytes = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await MediaOfflineStore.list();
      final vids = all
          .where((m) =>
              m.kind == 'video' &&
              (m.sourceId == 'hongguo' ||
                  m.key.startsWith('video:hongguo:')))
          .toList();
      final size = <String, int>{};
      for (final m in vids) {
        size[m.key] = await MediaOfflineStore.bytesOf(m.key, title: m.title);
      }
      final entries = await HgCache.entries();
      if (!mounted) return;
      setState(() {
        _videos = vids;
        _entries = entries;
        _bytes
          ..clear()
          ..addAll(size);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _videoBytes =>
      _videos.fold<int>(0, (n, m) => n + (_bytes[m.key] ?? m.bytes));
  int get _metaBytes =>
      _entries.fold<int>(0, (n, e) => n + e.bytes);

  void _say(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  /// 只查本机文件。网络不通时这里照样能播 —— 这是本页存在的意义。
  Future<void> _play(MediaOfflineMeta m) async {
    Haptic.tap();
    final f = await PlayResolver.localFileOf(m.key, title: m.title);
    if (f == null) {
      _say(tr('本机没找到这一集，可能已经删了'));
      return;
    }
    if (!mounted) return;
    await UnifiedPlayer.open(
      context,
      MediaSpec(
        url: 'file://${f.path}',
        title: '${m.title} ${m.subtitle}'.trim(),
        cover: m.coverUrl.isEmpty ? null : m.coverUrl,
        index: 0,
        queue: const [],
        sourceTag: 'hongguo',
      ),
    );
  }

  Future<bool> _confirm(String text) async => await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('请确认')),
          content: Text(text),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(tr('取消'))),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr('确定'))),
          ],
        ),
      ) ??
      false;

  Future<void> _deleteVideo(MediaOfflineMeta m) async {
    if (!await _confirm(tr('删掉后这一集要重新下载才能离线播，确定吗？'))) return;
    final ok = await MediaOfflineStore.remove(m.key, title: m.title);
    _say(ok ? tr('已删除') : tr('删除失败'));
    await _load();
  }

  Future<void> _deleteEntry(HgCacheEntry e) async {
    if (!await _confirm(tr('删掉后联网再看会自动重新保存，确定吗？'))) return;
    await HgCache.clear(e.key);
    _say(tr('已删除'));
    await _load();
  }

  Future<void> _clearAll() async {
    if (!await _confirm(tr('清掉后本机不再保存这些内容，联网看过才会重新存。已下载的视频也会一起删。'))) {
      return;
    }
    for (final m in _videos) {
      await MediaOfflineStore.remove(m.key, title: m.title);
    }
    await HgCache.clearAll();
    _say(tr('已清空'));
    await _load();
  }

  String _label(HgCacheEntry e) {
    final arg = e.arg.trim();
    switch (e.kind) {
      case 'feed':
        return tr('推荐列表');
      case 'search':
        return arg.isEmpty
            ? tr('搜索记录')
            : trf('搜索：{q}', {'q': arg});
      case 'series':
        return tr('剧集简介');
      case 'eps':
        return tr('分集列表');
      default:
        return e.key;
    }
  }

  String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('红果离线缓存')),
        actions: [
          IconButton(
            tooltip: tr('清空缓存'),
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _videos.isEmpty && _entries.isEmpty ? null : _clearAll,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: AppLoading())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                children: [
                  _summary(c),
                  _sectionTitle(c, tr('离线可播'), Icons.download_done_outlined),
                  if (_videos.isEmpty)
                    EmptyState(
                      icon: Icons.theaters_outlined,
                      title: tr('还没有已下载的短剧'),
                      hint: tr('在剧集页点下载后，这里会出现能断网播的集。'),
                    )
                  else
                    for (final m in _videos)
                      ListTile(
                        leading: const Icon(Icons.play_circle_outline),
                        title: Text('${m.title} ${m.subtitle}'.trim(),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(trf('已下载 · {size}', {
                          'size': MediaOfflinePlan
                              .bytesLabel(_bytes[m.key] ?? m.bytes)
                        })),
                        onTap: () => _play(m),
                        trailing: IconButton(
                          tooltip: tr('删除'),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _deleteVideo(m),
                        ),
                      ),
                  const SizedBox(height: 10),
                  _sectionTitle(c, tr('资料缓存'), Icons.cached_outlined),
                  if (_entries.isEmpty)
                    EmptyState(
                      icon: Icons.cached_outlined,
                      title: tr('还没有资料缓存'),
                      hint: tr('联网看过推荐或搜索后，这里会留下可离线查看的记录。'),
                    )
                  else
                    for (final e in _entries)
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(_label(e),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(trf('{size} · {when}', {
                          'size': MediaOfflinePlan.bytesLabel(e.bytes),
                          'when': _when(e.at),
                        })),
                        trailing: IconButton(
                          tooltip: tr('删除'),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _deleteEntry(e),
                        ),
                      ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      tr('播放地址不会保存在这里，点已下载的集只读取本机文件。'),
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(c).colorScheme.outline),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _summary(BuildContext c) {
    final total = _videoBytes + _metaBytes;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.storage_outlined,
                size: 16, color: Theme.of(c).colorScheme.primary),
            const SizedBox(width: 6),
            Text(trf('本机占用 {size}', {
              'size': MediaOfflinePlan.bytesLabel(total)
            }), style: Theme.of(c).textTheme.titleSmall),
          ]),
          const SizedBox(height: 6),
          Text(
            trf('已下载 {n} 集 · 资料缓存 {m} 条', {
              'n': '${_videos.length}',
              'm': '${_entries.length}',
            }),
            style: TextStyle(
                fontSize: 12, color: Theme.of(c).colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }

  Widget _sectionTitle(BuildContext c, String text, IconData icon) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Row(children: [
          Icon(icon, size: 15, color: Theme.of(c).colorScheme.outline),
          const SizedBox(width: 6),
          Text(text, style: Theme.of(c).textTheme.labelLarge),
        ]),
      );
}
