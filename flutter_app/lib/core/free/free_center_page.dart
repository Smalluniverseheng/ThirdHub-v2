// 「开放源」聚合页 —— 完全直连公网站点，**不需要后端在线**。
//
// 为什么要有这个页面而不把源塞进现有五个板块：
//   现有板块的搜索/详情/播放全都挂在 `Api.base`（自家后端）上，后端一断就整片空白。
//   这里是一条独立的、与后端无关的内容通路。按用户的话：「既能用后端，也能脱离后端」。
//
// 页面结构：一个 tab 切板块，一个搜索框，一个列表；点条目按内容类型分派到
// 统一播放器 / 漫画阅读 / 文本阅读。源不可达时在顶部直说，不伪装成"没内容"。
import 'package:flutter/material.dart';

import '../i18n.dart';
import '../player/media_spec.dart';
import '../player/unified_player.dart';
import 'free_http.dart';
import 'free_models.dart';
import 'free_sources_media.dart';
import 'free_sources_read.dart';

/// 板块 → (中文名, 图标, 对应源)
const List<FreeKind> kFreeTabs = [
  FreeKind.music,
  FreeKind.radio,
  FreeKind.podcast,
  FreeKind.comic,
  FreeKind.video,
  FreeKind.book,
];

String freeKindName(FreeKind k) {
  switch (k) {
    case FreeKind.music:
      return '音乐';
    case FreeKind.radio:
      return '电台';
    case FreeKind.podcast:
      return '播客';
    case FreeKind.comic:
      return '漫画';
    case FreeKind.video:
      return '视频';
    case FreeKind.book:
      return '书';
    default:
      return '开放源';
  }
}

IconData freeKindIcon(FreeKind k) {
  switch (k) {
    case FreeKind.music:
      return Icons.music_note_outlined;
    case FreeKind.radio:
      return Icons.radio_outlined;
    case FreeKind.podcast:
      return Icons.podcasts_outlined;
    case FreeKind.comic:
      return Icons.auto_stories_outlined;
    case FreeKind.video:
      return Icons.play_circle_outline;
    case FreeKind.book:
      return Icons.menu_book_outlined;
    default:
      return Icons.public;
  }
}

/// 板块对应的源列表（用于可达性探测与说明）。
List<FreeSource> sourcesOf(FreeKind k) {
  switch (k) {
    case FreeKind.music:
      return [AudiusSource.source];
    case FreeKind.radio:
      return [RadioSource.source];
    case FreeKind.podcast:
      return [PodcastSource.source];
    case FreeKind.comic:
      return [MangaDexSource.source];
    case FreeKind.video:
      return [PeerTubeSource.source];
    case FreeKind.book:
      return [PoemSource.source, ...bookSources];
    default:
      return const [];
  }
}

class FreeSourcePage extends StatefulWidget {
  const FreeSourcePage({super.key, this.initialKind = FreeKind.music});

  final FreeKind initialKind;

  @override
  State<FreeSourcePage> createState() => _FreeSourcePageState();
}

class _FreeSourcePageState extends State<FreeSourcePage> {
  late FreeKind _kind = widget.initialKind;
  final TextEditingController _q = TextEditingController();

  bool _loading = false;
  String _err = '';
  List<FreeItem> _items = const [];

  /// 源 id → 是否可达。null = 还没探。
  Map<String, bool> _reach = const {};

  /// 古登堡的字母桶。
  String _bucket = 'A–M';

  /// 今日诗词（书板块顶部）。
  Map<String, String> _poem = const {};

  int _req = 0;

  @override
  void initState() {
    super.initState();
    _probe();
    _load();
    if (_kind == FreeKind.book) _loadPoem();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final all = <FreeSource>[];
    for (final k in kFreeTabs) {
      all.addAll(sourcesOf(k));
    }
    final r = await FreeReach.probeAll(all);
    if (!mounted) return;
    setState(() => _reach = r);
  }

  Future<void> _loadPoem() async {
    try {
      final p = await PoemSource.one();
      if (mounted) setState(() => _poem = p);
    } catch (_) {
      // 诗词是锦上添花，失败了不打扰用户。
    }
  }

  Future<void> _load() async {
    final gen = ++_req;
    setState(() {
      _loading = true;
      _err = '';
      _items = const [];
    });
    try {
      final list = await _fetch();
      if (!mounted || gen != _req) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted || gen != _req) return;
      FreeReach.mark(sourcesOf(_kind).first.id, false);
      setState(() {
        _loading = false;
        _err = e.message;
      });
    } catch (e) {
      if (!mounted || gen != _req) return;
      setState(() {
        _loading = false;
        _err = '加载失败：$e';
      });
    }
  }

  Future<List<FreeItem>> _fetch() async {
    final q = _q.text.trim();
    switch (_kind) {
      case FreeKind.music:
        return q.isEmpty
            ? AudiusSource.trending()
            : AudiusSource.search(q);
      case FreeKind.radio:
        return q.isEmpty ? RadioSource.top() : RadioSource.search(q);
      case FreeKind.podcast:
        // iTunes 必须有词，空搜索给一个能出结果的中性词。
        return PodcastSource.search(q.isEmpty ? '故事' : q);
      case FreeKind.comic:
        return q.isEmpty
            ? MangaDexSource.popularZh()
            : MangaDexSource.search(q);
      case FreeKind.video:
        return q.isEmpty
            ? PeerTubeSource.latest()
            : PeerTubeSource.search(q);
      case FreeKind.book:
        if (q.isNotEmpty) return WikisourceSource.search(q);
        return GutenbergAuSource.browse(bucket: _bucket);
      default:
        return const [];
    }
  }

  void _switchKind(FreeKind k) {
    if (k == _kind) return;
    setState(() {
      _kind = k;
      _items = const [];
      _err = '';
    });
    _load();
    if (k == FreeKind.book && _poem.isEmpty) _loadPoem();
  }

  // ── 点击分派 ──────────────────────────────────────────────
  Future<void> _open(FreeItem it) async {
    if (it.kind == FreeKind.comic) {
      if (it.drill) {
        _openComicChapters(it);
      } else {
        _openComicReader(it);
      }
      return;
    }
    if (it.kind == FreeKind.book) {
      if (it.drill) {
        _openBookToc(it);
      } else {
        _openBookReader(it);
      }
      return;
    }
    if (it.kind == FreeKind.podcast && it.drill) {
      _openPodcastEpisodes(it);
      return;
    }
    await _play(it);
  }

  Future<void> _play(FreeItem it) async {
    var url = it.playUrl;
    // 视频的直链要现取（PeerTube 列表接口不返回 files）。
    if (url.isEmpty && it.kind == FreeKind.video) {
      final host = '${it.raw['host'] ?? ''}';
      setState(() => _loading = true);
      try {
        url = await PeerTubeSource.playUrl(it.id,
            host: host.isEmpty ? null : host);
      } on FreeNetException catch (e) {
        if (!mounted) return;
        setState(() => _loading = false);
        _toast(e.message);
        return;
      }
      if (!mounted) return;
      setState(() => _loading = false);
    }
    if (url.isEmpty) {
      _toast('这一条没有可播地址');
      return;
    }
    final kind = it.kind == FreeKind.video ? MediaKind.video : MediaKind.audio;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => UnifiedPlayerPage(
        spec: MediaSpec(
          url: url,
          title: it.displayTitle,
          cover: it.cover.isEmpty ? null : it.cover,
          artist: it.kind == FreeKind.podcast ? it.subtitle : it.subtitle,
          kindOverride: kind,
          sourceTag: freeKindName(it.kind),
          allowAudioMode: it.kind != FreeKind.radio,
        ),
      ),
    ));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openPodcastEpisodes(FreeItem show) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _EpisodeListPage(show: show),
    ));
  }

  Future<void> _openComicChapters(FreeItem manga) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _ChapterListPage(manga: manga),
    ));
  }

  Future<void> _openComicReader(FreeItem chapter) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FreeComicReadPage(chapter: chapter),
    ));
  }

  Future<void> _openBookToc(FreeItem book) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _BookTocPage(book: book),
    ));
  }

  Future<void> _openBookReader(FreeItem page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FreeTextReadPage(
        title: page.displayTitle,
        loader: () async {
          if (page.source == WikisourceSource.id) {
            return WikisourceSource.read('${page.raw['pageTitle'] ?? page.id}');
          }
          return GutenbergAuSource.read('${page.raw['url'] ?? page.id}');
        },
      ),
    ));
  }

  // ── UI ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final dead = sourcesOf(_kind)
        .where((s) => _reach[s.id] == false)
        .map((s) => s.name)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('开放源')),
        actions: [
          IconButton(
            tooltip: tr('重新探测'),
            icon: const Icon(Icons.wifi_tethering),
            onPressed: () async {
              FreeReach.clear();
              await _probe();
              if (mounted) setState(() {});
              _load();
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final k in kFreeTabs)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          selected: _kind == k,
                          avatar: Icon(freeKindIcon(k), size: 16),
                          label: Text(tr(freeKindName(k))),
                          onSelected: (_) => _switchKind(k),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _q,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('搜索（留空看推荐）'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _q.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _q.clear();
                              _load();
                            },
                          ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (dead.isNotEmpty) _banner(dead),
          if (dead.isEmpty) _offlineNote(),
          if (_kind == FreeKind.book && _items.isNotEmpty && _poem.isNotEmpty)
            _poemCard(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _offlineNote() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Text(
          tr('这些源直连公网站点，不需要你的服务器在线'),
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      );

  Widget _banner(List<String> dead) => Container(
        width: double.infinity,
        color: Colors.orange.withValues(alpha: 0.14),
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(children: [
          const Icon(Icons.wifi_off, size: 16, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              trf('{n} 当前不可达，可能被网络阻断，换网或稍后重试', {'n': dead.join('、')}),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(onPressed: _load, child: Text(tr('重试'))),
        ]),
      );

  /// 「菩萨蛮 · 温庭筠」这种来源行，两段都可能为空。
  String _poemLine() =>
      [_poem['origin'] ?? '', _poem['author'] ?? '']
          .where((s) => s.isNotEmpty)
          .join(' · ');

  /// 是否需要显示字母桶切换条（只有古登堡的「浏览」状态需要）。
  int _showBucketBar() =>
      (_kind == FreeKind.book && _q.text.trim().isEmpty) ? 1 : 0;

  Widget _poemCard() => Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.02),
          ]),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_poem['content'] ?? '',
                style: const TextStyle(fontSize: 15, height: 1.5)),
            const SizedBox(height: 4),
            Text(
              _poemLine(),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      );

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_err.isNotEmpty && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_err, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: Text(tr('重试'))),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text(tr('没有结果')));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        // 字母桶只对「古登堡浏览」有意义；维基文库是搜索结果，不该出现切换条。
        itemCount: _items.length + _showBucketBar(),
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (c, i) {
          if (i == _items.length) {
            return _bucketSwitch();
          }
          return _tile(_items[i]);
        },
      ),
    );
  }

  /// 古登堡只有两个索引页，用一个切换条把 N–Z 也放出来。
  Widget _bucketSwitch() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final b in GutenbergAuSource.buckets.keys)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: OutlinedButton(
                  onPressed: _bucket == b
                      ? null
                      : () {
                          setState(() => _bucket = b);
                          _load();
                        },
                  child: Text(b),
                ),
              ),
          ],
        ),
      );

  Widget _tile(FreeItem it) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(it),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(it),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(it.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    if (it.displaySubtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(it.displaySubtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ],
                ),
              ),
              Icon(
                it.kind == FreeKind.comic || it.kind == FreeKind.book
                    ? (it.drill ? Icons.chevron_right : Icons.menu_book)
                    : Icons.play_arrow,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(FreeItem it) {
    final w = it.kind == FreeKind.comic ? 52.0 : 48.0;
    final h = it.kind == FreeKind.comic ? 70.0 : 48.0;
    final r = BorderRadius.circular(it.kind == FreeKind.comic ? 6 : 24);
    if (it.cover.isEmpty) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: r,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Icon(freeKindIcon(it.kind), size: 20, color: Colors.grey),
      );
    }
    return ClipRRect(
      borderRadius: r,
      child: Image.network(
        it.cover,
        width: w,
        height: h,
        fit: BoxFit.cover,
        headers: const {'User-Agent': FreeHttp.userAgent},
        errorBuilder: (_, __, ___) => Container(
          width: w,
          height: h,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(freeKindIcon(it.kind), size: 18, color: Colors.grey),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 播客单集
// ─────────────────────────────────────────────────────────────
class _EpisodeListPage extends StatefulWidget {
  const _EpisodeListPage({required this.show});
  final FreeItem show;

  @override
  State<_EpisodeListPage> createState() => _EpisodeListPageState();
}

class _EpisodeListPageState extends State<_EpisodeListPage> {
  bool _loading = true;
  String _err = '';
  List<FreeItem> _list = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final l = await PodcastSource.episodes(widget.show);
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.show.displayTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(child: Text(_err))
              : ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final e = _list[i];
                    return ListTile(
                      dense: true,
                      title: Text(e.displayTitle, maxLines: 2),
                      subtitle: Text(e.displaySubtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.play_circle_outline),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => UnifiedPlayerPage(
                              spec: MediaSpec(
                                url: e.playUrl,
                                title: e.displayTitle,
                                cover: e.cover.isEmpty ? null : e.cover,
                                kindOverride: MediaKind.audio,
                                sourceTag: '播客',
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 漫画章节
// ─────────────────────────────────────────────────────────────
class _ChapterListPage extends StatefulWidget {
  const _ChapterListPage({required this.manga});
  final FreeItem manga;

  @override
  State<_ChapterListPage> createState() => _ChapterListPageState();
}

class _ChapterListPageState extends State<_ChapterListPage> {
  bool _loading = true;
  String _err = '';
  List<FreeItem> _list = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final l = await MangaDexSource.chapters(widget.manga);
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.manga.displayTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(child: Text(_err))
              : _list.isEmpty
                  ? Center(child: Text(tr('这本还没有可看的章节')))
                  : ListView.builder(
                      itemCount: _list.length,
                      itemBuilder: (c, i) {
                        final ch = _list[i];
                        return ListTile(
                          dense: true,
                          title: Text(ch.displayTitle),
                          subtitle: Text(ch.displaySubtitle),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => FreeComicReadPage(chapter: ch),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 漫画阅读（纵向滚动 + 双指缩放）
// ─────────────────────────────────────────────────────────────
class FreeComicReadPage extends StatefulWidget {
  const FreeComicReadPage({super.key, required this.chapter});
  final FreeItem chapter;

  @override
  State<FreeComicReadPage> createState() => _FreeComicReadPageState();
}

class _FreeComicReadPageState extends State<FreeComicReadPage> {
  bool _loading = true;
  String _err = '';
  List<String> _pages = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final p = await MangaDexSource.pages(widget.chapter.id);
      if (!mounted) return;
      setState(() {
        _pages = p;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chapter.displayTitle,
            style: const TextStyle(fontSize: 15)),
        actions: [
          if (_pages.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(trf('{n} 页', {'n': _pages.length}),
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_err, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                            onPressed: _run, child: Text(tr('重试'))),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _pages.length,
                  itemBuilder: (c, i) {
                    return InteractiveViewer(
                      maxScale: 4,
                      child: Image.network(
                        _pages[i],
                        fit: BoxFit.fitWidth,
                        width: double.infinity,
                        headers: const {'User-Agent': FreeHttp.userAgent},
                        loadingBuilder: (c2, child, prog) {
                          if (prog == null) return child;
                          return SizedBox(
                            height: 240,
                            child: Center(
                              child: CircularProgressIndicator(
                                value: prog.expectedTotalBytes == null
                                    ? null
                                    : prog.cumulativeBytesLoaded /
                                        prog.expectedTotalBytes!,
                              ),
                            ),
                          );
                        },
                        errorBuilder: (_, __, ___) => Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(trf('第 {n} 页加载失败', {'n': i + 1}),
                              style: const TextStyle(color: Colors.grey)),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 书籍目录
// ─────────────────────────────────────────────────────────────
class _BookTocPage extends StatefulWidget {
  const _BookTocPage({required this.book});
  final FreeItem book;

  @override
  State<_BookTocPage> createState() => _BookTocPageState();
}

class _BookTocPageState extends State<_BookTocPage> {
  bool _loading = true;
  String _err = '';
  List<FreeItem> _list = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final l = await WikisourceSource.toc('${widget.book.raw['pageTitle'] ?? widget.book.id}');
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.book.displayTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(child: Text(_err))
              : ListView.builder(
                  itemCount: _list.length,
                  itemBuilder: (c, i) {
                    final ch = _list[i];
                    return ListTile(
                      dense: true,
                      title: Text(ch.displayTitle),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FreeTextReadPage(
                            title: ch.displayTitle,
                            loader: () => WikisourceSource.read(
                                '${ch.raw['pageTitle'] ?? ch.id}'),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 文本阅读（公版书正文；可调字号、护眼底色）
// ─────────────────────────────────────────────────────────────
class FreeTextReadPage extends StatefulWidget {
  const FreeTextReadPage({
    super.key,
    required this.title,
    required this.loader,
  });

  final String title;
  final Future<String> Function() loader;

  @override
  State<FreeTextReadPage> createState() => _FreeTextReadPageState();
}

class _FreeTextReadPageState extends State<FreeTextReadPage> {
  bool _loading = true;
  String _err = '';
  String _text = '';
  double _size = 17;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final t = await widget.loader();
      if (!mounted) return;
      setState(() {
        _text = t;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: const Icon(Icons.text_decrease),
            onPressed: _size <= 13
                ? null
                : () => setState(() => _size -= 1),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            onPressed: _size >= 28
                ? null
                : () => setState(() => _size += 1),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_err, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                            onPressed: _run, child: Text(tr('重试'))),
                      ],
                    ),
                  ),
                )
              : Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 48),
                    child: SelectableText(
                      _text,
                      style: TextStyle(fontSize: _size, height: 1.75),
                    ),
                  ),
                ),
    );
  }
}
