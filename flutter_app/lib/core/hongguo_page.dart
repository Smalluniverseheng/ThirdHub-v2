// 红果短剧（短剧平台 · 4.81.79 新增 UI）
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么这个文件到现在才有
// ══════════════════════════════════════════════════════════════════════════════
// 后端 `server/routes-hongguo.js` 在 4.81.75 就写好了（搜索/详情/分集/取流/推荐
// 五个接口，实测「总裁」5 条、《总裁是我前女友》95 集、流是明文 mp4）。
// 但 App 端**一个入口都没接** —— 模块抽屉里既没有红果，视频板块也切不过去，
// 等于后端能力烂在服务端。本文件是它的客户端。
//
// 层级：HongguoPage（推荐 + 搜索）
//         → HongguoSeriesPage（简介 + 分集）
//           → 统一播放器（UnifiedPlayerPage，带懒解析队列连播）
//
// 纪律：
//   · 不新建播放器。竖屏/横屏、进度、倍速、续播一律交给 core/player 那一套
//     （本项目历史上 7 套播放器各写一遍进度条的教训在 unified_player.dart 顶部）；
//   · 播放地址**本地优先**：走 PlayResolver.media()，用户下载过的集数断网也能看；
//   · 后端没连时不要假装能搜 —— 给可操作的空态，不要"空白页 + 一个异常名"。
library;

import 'package:flutter/material.dart';

import '../main.dart' show Api;
import 'app_widgets.dart';
import 'hg_cache.dart';
import 'my_backend_page.dart' show MyBackendPage;
import 'haptic.dart';
import 'i18n.dart';
import 'play_resolver.dart';
import 'player/media_spec.dart';
import 'player/unified_player.dart';
import 'ui/app_image.dart';
import 'ui/app_skeleton.dart';
import 'ui_cover.dart';

/// 本页专用的"没有缓存也没有后端"异常（避免误用 main.dart 带引导文案的那个）。
class ApiOfflineErrorNoBase implements Exception {
  const ApiOfflineErrorNoBase();
  @override
  String toString() => 'offline_no_cache';
}

/// 离线缓存提示条（内容来自本机，不是刚从后端拉的）。
Widget hgOfflineBanner(BuildContext c) => Container(
      width: double.infinity,
      color: Theme.of(c).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.cached_outlined,
              size: 13, color: Theme.of(c).colorScheme.outline),
          const SizedBox(width: 6),
          Text(tr('离线缓存：连上后端后会更新'),
              style: TextStyle(
                  fontSize: 11, color: Theme.of(c).colorScheme.outline)),
        ],
      ),
    );

/// 后端优先；连不上时读本地缓存。__ageMs 存在表示来自缓存（可标注离线）。
Future<Map<String, dynamic>> hgGet(String path, String cacheKey) async {
  if (Api.base.isNotEmpty) {
    try {
      final r = await Api.get(path);
      await HgCache.write(cacheKey, r);
      return r;
    } catch (_) {
      final c = await HgCache.read(cacheKey);
      if (c != null) return c;
      rethrow;
    }
  }
  final c = await HgCache.read(cacheKey);
  if (c != null) return c;
  throw const ApiOfflineErrorNoBase();
}

/// 红果短剧的一个剧集条目（对应后端 seriesOut 的字段）。
class HgSeries {
  final String id;
  final String title;
  final String cover;
  final String intro;
  final int episodes;
  final int heat;

  const HgSeries({
    required this.id,
    required this.title,
    required this.cover,
    this.intro = '',
    this.episodes = 0,
    this.heat = 0,
  });

  static HgSeries from(Map m) => HgSeries(
        id: '${m['seriesId'] ?? m['id'] ?? ''}',
        title: '${m['name'] ?? m['title'] ?? ''}'.trim(),
        cover: '${m['coverUrl'] ?? ''}',
        intro: '${m['intro'] ?? ''}',
        episodes: (m['episodeCount'] as num?)?.toInt() ?? 0,
        heat: (m['heat'] as num?)?.toInt() ?? 0,
      );
}

/// 一集。
class HgEpisode {
  final String id;
  final String name;
  final int index;
  final bool playable;

  const HgEpisode({
    required this.id,
    required this.name,
    required this.index,
    this.playable = true,
  });

  static HgEpisode from(Map m) => HgEpisode(
        id: '${m['episodeId'] ?? m['id'] ?? ''}',
        name: '${m['name'] ?? ''}'.trim(),
        index: (m['index'] as num?)?.toInt() ?? 0,
        playable: m['playable'] != false,
      );
}

/// 红果板块根页。可被嵌进视频板块的平台横切页（`embedded: true`）。
class HongguoPage extends StatefulWidget {
  const HongguoPage({super.key, this.embedded = false});

  /// true = 不画自己的 AppBar/标题（外层已有平台切换条），只出内容。
  final bool embedded;

  @override
  State<HongguoPage> createState() => _HongguoPageState();
}

class _HongguoPageState extends State<HongguoPage> {
  final _q = TextEditingController();

  List<HgSeries> _items = const [];
  bool _loading = false;
  bool _searched = false; // true = 当前结果是搜索结果（空态文案不同）
  String _err = '';
  bool _offline = false; // 当前列表是否来自本地缓存

  @override
  void initState() {
    super.initState();
    _feed();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _say(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _feed() async {
    setState(() {
      _loading = true;
      _err = '';
      _searched = false;
    });
    try {
      final r = await hgGet('/v1/hongguo/feed?limit=18', HgCache.feedKey());
      final cached = r['__ageMs'] != null;
      final list = (r['data'] as List? ?? const [])
          .whereType<Map>()
          .map(HgSeries.from)
          .where((e) => e.id.isNotEmpty && e.title.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _items = list;
        _offline = cached;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e' == 'offline_no_cache'
            ? tr('还没连上后端，本机也没有保存过短剧内容')
            : _friendly(e);
        _offline = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _search([String? preset]) async {
    final kw = (preset ?? _q.text).trim();
    if (kw.isEmpty) return;
    Haptic.tap();
    setState(() {
      _loading = true;
      _err = '';
      _searched = true;
    });
    try {
      final r = await hgGet(
          '/v1/hongguo/search?q=${Uri.encodeComponent(kw)}&limit=30',
          HgCache.searchKey(kw));
      final cached = r['__ageMs'] != null;
      final list = (r['data'] as List? ?? const [])
          .whereType<Map>()
          .map(HgSeries.from)
          .where((e) => e.id.isNotEmpty && e.title.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _items = list;
        _offline = cached;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e' == 'offline_no_cache' ? tr('这部剧没缓存过，联网后才能搜') : _friendly(e);
        _offline = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 后端错误文案直给用户看会出现 `fetch failed` / `ClientException` 这类东西，
  /// 这里统一翻译成人话；原始信息不丢，留在日志里。
  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Failed host lookup') ||
        s.contains('Connection refused')) {
      return tr('连不上后端（检查手机和 NAS 是否在同一个局域网）');
    }
    if (s.contains('TimeoutException') || s.contains('超时')) {
      return tr('后端响应太慢，稍后再试');
    }
    if (s.contains('401') || s.contains('403')) {
      return tr('后端拒绝了这次请求（密钥可能过期，去「我的后端」重新连接）');
    }
    return s;
  }

  Future<void> _openSeries(HgSeries s) async {
    Haptic.tap();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HongguoSeriesPage(
          seriesId: s.id,
          title: s.title,
          cover: s.cover,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final body = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => _search(v),
              decoration: InputDecoration(
                isDense: true,
                hintText: tr('搜短剧名，如「总裁」'),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _q.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(_q.clear),
                      ),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _loading ? null : () => _search(),
            child: Text(tr('搜索')),
          ),
        ]),
      ),
      // 结果区标题：让"我在看推荐"和"我在看搜索结果"分得开
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
        child: Row(children: [
          Text(_searched ? tr('搜索结果') : tr('推荐给你'),
              style: Theme.of(c).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(c).colorScheme.onSurfaceVariant)),
          const Spacer(),
          if (!_loading)
            IconButton(
              tooltip: tr('刷新'),
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => _searched ? _search() : _feed(),
            ),
        ]),
      ),
      Expanded(child: _body(c)),
    ]);
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('红果短剧'))),
      body: body,
    );
  }

  Widget _body(BuildContext c) {
    if (_loading) return const SkeletonGrid(count: 9, aspectRatio: 0.62);
    if (_err.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined,
                size: 44, color: Theme.of(c).colorScheme.outline),
            const SizedBox(height: 12),
            Text(_err, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: () => _searched ? _search() : _feed(),
              child: Text(tr('重试')),
            ),
            // 红果的接口带专用签名，手机端无法直连 —— 这一栏必须给出路，
            // 否则普通版用户只能看到一个"连不上"的死胡同。
            TextButton(
              onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                  builder: (_) => const MyBackendPage())),
              child: Text(tr('去连接自己的服务器')),
            ),
          ]),
        ),
      );
    }
    if (_items.isEmpty) {
      return EmptyState(
        icon: Icons.theaters_outlined,
        title: _searched ? tr('没搜到，换个词试试') : tr('还没有推荐内容'),
        actionLabel: _searched ? null : tr('刷新'),
        onAction: _searched ? null : _feed,
      );
    }
    return Column(children: [
      if (_offline) hgOfflineBanner(c),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 10,
            childAspectRatio: 0.62,
          ),
          itemCount: _items.length,
          itemBuilder: (ctx, i) {
            final s = _items[i];
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _openSeries(s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Stack(fit: StackFit.expand, children: [
                      CoverImage(s.cover,
                          fallbackText: s.title,
                          fallbackIcon: Icons.theaters_outlined),
                      if (s.episodes > 0)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child:
                              _badge(c, trf('{n} 集', {'n': '${s.episodes}'})),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Text(s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(c).textTheme.bodySmall),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _badge(BuildContext c, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 10)),
      );
}

/// 剧集详情：简介 + 分集列表。点任意一集进入播放，支持连播（懒解析）。
class HongguoSeriesPage extends StatefulWidget {
  const HongguoSeriesPage({
    super.key,
    required this.seriesId,
    required this.title,
    this.cover = '',
  });

  final String seriesId;
  final String title;
  final String cover;

  @override
  State<HongguoSeriesPage> createState() => _HongguoSeriesPageState();
}

class _HongguoSeriesPageState extends State<HongguoSeriesPage> {
  HgSeries _s = const HgSeries(id: '', title: '', cover: '');
  List<HgEpisode> _eps = const [];
  bool _loading = true;
  String _err = '';
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      // 详情和分集并行拉：详情挂了不该拖累分集（很多剧的详情接口缺字段）
      final id = Uri.encodeComponent(widget.seriesId);
      final results = await Future.wait([
        hgGet('/v1/hongguo/series?id=$id', HgCache.seriesKey(widget.seriesId))
            .catchError((_) => <String, dynamic>{}),
        hgGet('/v1/hongguo/episodes?id=$id',
            HgCache.episodesKey(widget.seriesId)),
      ]);
      final det = results[0];
      final eps = results[1];
      final cached = det['__ageMs'] != null || eps['__ageMs'] != null;
      final s = (det['data'] is Map)
          ? HgSeries.from(det['data'] as Map)
          : HgSeries(
              id: widget.seriesId, title: widget.title, cover: widget.cover);
      final list = (eps['data'] as List? ?? const [])
          .whereType<Map>()
          .map(HgEpisode.from)
          .where((e) => e.id.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _s = s;
        _eps = list;
        _offline = cached;
        if (list.isEmpty) _err = tr('这部剧暂时没有可播的集');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 取第 i 集的播放地址（本地优先）。返回 null 表示这一集取不到/没得播。
  Future<MediaSpec?> _specOf(int i) async {
    if (i < 0 || i >= _eps.length) return null;
    final ep = _eps[i];
    if (!ep.playable) return null;
    final src = await PlayResolver.media(
      key: 'video:hongguo:${ep.id}',
      title: '${widget.title} ${ep.name}',
      online: () async {
        final r = await Api.get(
            '/v1/hongguo/play?episodeId=${Uri.encodeComponent(ep.id)}');
        final d = r['data'];
        if (d is! Map) return OnlineUrl('', hint: tr('红果没有返回播放信息'));
        final u = '${d['url'] ?? ''}';
        if (u.isEmpty) return OnlineUrl('', hint: tr('红果没给出可播地址（可能已下架）'));
        return OnlineUrl(u, origin: PlayOrigin.backend);
      },
    );
    if (src.localReady) {
      return MediaSpec(
        url: 'file://${src.file!.path}',
        title: '${widget.title} · ${ep.name}',
        cover: _s.cover,
        index: i,
        queue: const [],
        resolveAt: _specOf,
        total: _eps.length,
        sourceTag: 'hongguo',
        startAt: null,
      );
    }
    if (!src.remoteReady) {
      throw Exception(src.error ?? tr('这一集没有可播地址'));
    }
    return MediaSpec(
      url: src.url!,
      title: '${widget.title} · ${ep.name}',
      cover: _s.cover,
      index: i,
      queue: const [],
      resolveAt: _specOf,
      total: _eps.length,
      sourceTag: 'hongguo',
    );
  }

  Future<void> _play(int i) async {
    Haptic.tap();
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: AppLoading()),
    );
    MediaSpec? spec;
    try {
      spec = await _specOf(i);
    } catch (e) {
      spec = null;
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (spec == null || !mounted) return;
    await UnifiedPlayer.open(context, spec);
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const SkeletonList(count: 8)
          : _err.isNotEmpty && _eps.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_err, textAlign: TextAlign.center),
                      const SizedBox(height: 14),
                      FilledButton.tonal(
                          onPressed: _load, child: Text(tr('重试'))),
                    ]),
                  ),
                )
              : CustomScrollView(slivers: [
                  SliverToBoxAdapter(child: _header(c)),
                  if (_offline) SliverToBoxAdapter(child: hgOfflineBanner(c)),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 1.45,
                      ),
                      itemCount: _eps.length,
                      itemBuilder: (ctx, i) {
                        final ep = _eps[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: ep.playable ? () => _play(i) : null,
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: ep.playable
                                  ? Theme.of(c)
                                      .colorScheme
                                      .surfaceContainerHighest
                                  : Theme.of(c)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.4),
                            ),
                            child: Text(
                              '${ep.index > 0 ? ep.index : i + 1}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: ep.playable
                                    ? Theme.of(c).colorScheme.onSurface
                                    : Theme.of(c).colorScheme.outline,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ]),
    );
  }

  Widget _header(BuildContext c) {
    final cover = _s.cover.isNotEmpty ? _s.cover : widget.cover;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 92,
          height: 124,
          child: CoverImage(cover,
              fallbackText: widget.title,
              fallbackIcon: Icons.theaters_outlined),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(c)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (_eps.isNotEmpty)
              Text(trf('共 {n} 集', {'n': '${_eps.length}'}),
                  style: Theme.of(c).textTheme.bodySmall?.copyWith(
                      color: Theme.of(c).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (_s.intro.isNotEmpty)
              Text(_s.intro,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 10),
            if (_eps.isNotEmpty)
              FilledButton.icon(
                onPressed: () => _play(0),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(tr('从第 1 集开始')),
              ),
          ]),
        ),
      ]),
    );
  }
}
