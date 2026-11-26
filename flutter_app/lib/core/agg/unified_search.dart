// 全网搜索 —— 一个入口聚合五个板块（小说/漫画/视频/音乐/B站）。
//
// 为什么是独立模块而不是改 main.dart 里的 SearchSection：
//   · 那个页面是「我的资料库 / 局域网抓取」搜索，没连上就报"未连接本地资料库"，
//     既不含 B站，也不满足"脱离后端也能用"。两者语义不同，并列而非替换，
//     老搜索的深度续拉/流式/AI 深链一行都不动（零回归风险）。
//   · 这里纯前端聚合：四板块走 BoardFeed（资料库 / 局域网 / 本机源三路并发），
//     B站走端上直连（WBI 签名）。任一路挂了只是少一份结果，其余照常出。
//
// 「无阻塞式等待」的实现：五路各自 launch，哪一路先回来就先 setState 上屏，
// 绝不"等最慢的那一个"。每路独立 try/catch + 超时，一路抛错不影响其余。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bili_direct.dart' show biliDirect;
import '../bili_module_page.dart' show BiliCtx, openBiliVideo;
import '../free/free_board.dart' show FreeBoard, FreeItemTile;
import '../free/free_models.dart' show FreeItem;
import '../i18n.dart' show tr;
import '../ui_cover.dart' show CoverThumb;
import 'board_feed.dart' show BoardFeed, BoardFeedResult, BoardKind;
import '../../main.dart'
    show
        Api,
        Book,
        ComicDetailPage,
        EngineItemPage,
        MusicPlayPage,
        TocPage,
        VideoDetailPage;

/// 板块 key（与 BoardKind.name 对齐，bili 单列）。
const List<String> kUnifiedKinds = ['novel', 'comic', 'video', 'music', 'bili'];

/// 板块标签。用 getter 而非常量：切语言后要重新翻译。
List<String> get _kindLabels => [
      tr('小说'),
      tr('漫画'),
      tr('视频'),
      tr('音乐'),
      tr('B站'),
    ];

/// 单个板块的搜索桶：每一路独立维护 loading / 结果 / 错误。
class _Bucket {
  _Bucket(this.kind);

  final String kind;
  bool loading = false;
  bool done = false;
  String error = '';

  /// 四板块 = BoardFeed.groups；B站 = 单个 {ok, items} 组。
  List<Map> groups = const [];

  void reset() {
    loading = true;
    done = false;
    error = '';
    groups = const [];
  }

  int get count {
    var n = 0;
    for (final g in groups) {
      final v = g['items'] ?? g['books'];
      if (v is List) n += v.length;
    }
    return n;
  }
}

/// 全网搜索页。作为一级模块「全网搜」挂载（见 main.dart 的 kModules）。
class UnifiedSearchSection extends StatefulWidget {
  const UnifiedSearchSection({super.key});

  @override
  State<UnifiedSearchSection> createState() => _UnifiedSearchSectionState();
}

class _UnifiedSearchSectionState extends State<UnifiedSearchSection> {
  final _ctrl = TextEditingController();
  final Map<String, _Bucket> _buckets = {
    for (final k in kUnifiedKinds) k: _Bucket(k),
  };

  /// 0 = 「全部」分栏，1..5 = 对应板块单栏。
  int _tab = 0;
  int _seq = 0;
  String _query = '';
  BiliCtx? _biliCtx;

  @override
  void initState() {
    super.initState();
    _loadBiliCtx();
  }

  /// B站详情跳转要 BiliCtx；base 为空时 biliGet 自动走端上直连，仍能播。
  Future<void> _loadBiliCtx() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _biliCtx = BiliCtx(
        (sp.getString('base') ?? '').trim(),
        (sp.getString('token') ?? '').trim(),
      );
    } catch (_) {
      _biliCtx = BiliCtx('', '');
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> go() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    final mySeq = ++_seq;
    setState(() {
      _query = q;
      for (final b in _buckets.values) {
        b.reset();
      }
    });
    // 五路并发，每路自己负责 setState；这里只是把 launch 出来，不等它们。
    await Future.wait(
      [for (final k in kUnifiedKinds) _fetch(k, q, mySeq)],
    );
  }

  Future<void> _fetch(String kind, String q, int mySeq) async {
    final b = _buckets[kind]!;
    try {
      if (kind == 'bili') {
        final r = await biliDirect(
          '/v1/bili/search?q=${Uri.encodeQueryComponent(q)}&pn=1',
        ).timeout(const Duration(seconds: 20));
        if (!mounted || mySeq != _seq) return;
        final items = ((r?['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
        setState(() {
          b.groups = items.isEmpty
              ? const []
              : [
                  <String, dynamic>{'ok': true, 'items': items}
                ];
          b.loading = false;
          b.done = true;
        });
        return;
      }

      final BoardFeedResult r = await BoardFeed.search(
        BoardKind.values.firstWhere((e) => e.name == kind),
        q,
      );
      if (!mounted || mySeq != _seq) return;
      setState(() {
        b.groups = r.groups;
        b.loading = false;
        b.done = true;
      });
    } catch (e) {
      // 一路失败只记在自己桶里 —— 其余桶照常出结果。
      if (!mounted || mySeq != _seq) return;
      setState(() {
        b.error = '$e';
        b.loading = false;
        b.done = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = _kindLabels;
    final tabs = <String>[tr('全部'), ...labels];
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('全网搜索')),
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => go(),
                    decoration: InputDecoration(
                      hintText: tr('输入关键词，一次搜索五个板块'),
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: go,
                  child: Text(tr('搜索')),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: tabs.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(tabs[i]),
                  selected: _tab == i,
                  onSelected: (_) => setState(() => _tab = i),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _query.isEmpty
                ? _emptyPrompt()
                : (_tab == 0 ? _allView(labels) : _oneView(_tab - 1, labels)),
          ),
        ],
      ),
    );
  }

  Widget _emptyPrompt() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.travel_explore, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(
                tr('输入关键词，一次搜索五个板块'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );

  /// 「全部」：五个板块各一个分区，每区前 5 条 + 查看全部。
  Widget _allView(List<String> labels) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: kUnifiedKinds.length,
      itemBuilder: (_, i) {
        final kind = kUnifiedKinds[i];
        final b = _buckets[kind]!;
        final tiles = _tilesFor(kind);
        final shown = tiles.length > 5 ? tiles.sublist(0, 5) : tiles;
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_kindIcon(kind), size: 18, color: Colors.teal.shade700),
                  const SizedBox(width: 6),
                  Text(labels[i],
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  if (b.loading)
                    const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Text('${b.count}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _tab = i + 1),
                    child: Text(tr('查看更多')),
                  ),
                ],
              ),
              if (shown.isNotEmpty)
                ...shown
              else if (b.loading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(tr('正在搜索全部板块'),
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                )
              else if (b.error.isNotEmpty)
                _sectionNote(tr('该板块搜索失败'))
              else
                _sectionNote(tr('该板块暂无结果')),
            ],
          ),
        );
      },
    );
  }

  /// 单板块：该板块全部结果。
  Widget _oneView(int idx, List<String> labels) {
    final kind = kUnifiedKinds[idx];
    final b = _buckets[kind]!;
    final tiles = _tilesFor(kind);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: tiles.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Text(labels[idx],
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                if (b.loading)
                  const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Text('${b.count}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          );
        }
        return tiles[i - 1];
      },
    );
  }

  Widget _sectionNote(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      );

  IconData _kindIcon(String kind) => const {
        'novel': Icons.menu_book_outlined,
        'comic': Icons.auto_stories_outlined,
        'video': Icons.movie_outlined,
        'music': Icons.music_note_outlined,
        'bili': Icons.ondemand_video_outlined,
      }[kind] ??
      Icons.search;

  /// 把该板块的 groups 摊平成可点击的 ListTile。
  ///
  /// 三种来源形状必须分流（与 main.dart 各板块搜索结果一致）：
  ///   · 本机开放源：FreeItem → FreeItemTile（点击走 FreeOpen.open）
  ///   · 局域网抓取：{engine:true, items:[Map]} → EngineItemPage
  ///   · 资料库：{ok, sourceId, items|books:[Map]} → 各板块原生详情页
  List<Widget> _tilesFor(String kind) {
    final out = <Widget>[];
    final b = _buckets[kind]!;
    for (final g in b.groups) {
      if (FreeBoard.isFree(g)) {
        final items = g['items'] as List? ?? const [];
        for (final it in items) {
          if (it is FreeItem) out.add(FreeItemTile(item: it));
        }
        continue;
      }
      if (g['ok'] != true) continue;
      final raw = g['items'] ?? g['books'];
      if (raw is! List) continue;
      for (final e in raw) {
        if (e is! Map) continue;
        final it = Map<String, dynamic>.from(e);
        if (kind == 'bili') {
          out.add(_biliTile(it));
        } else {
          out.add(_resultTile(kind, g['engine'] == true,
              '${g['sourceId'] ?? ''}', it));
        }
      }
    }
    return out;
  }

  Widget _resultTile(String kind, bool engine, String sourceId,
      Map<String, dynamic> it) {
    final title = '${it['title'] ?? it['name'] ?? ''}';
    final sub = '${it['subTitle'] ?? it['author'] ?? it['artist'] ?? ''}';
    final cover = '${it['coverUrl'] ?? ''}';
    return ListTile(
      dense: true,
      leading: cover.isNotEmpty
          ? CoverThumb(
              engine ? cover : Api.img(cover),
              fallbackText: title,
            )
          : null,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle:
          sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _open(kind, engine, sourceId, it),
    );
  }

  void _open(String kind, bool engine, String sourceId, Map<String, dynamic> it) {
    if (engine) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EngineItemPage(
            type: kind,
            item: Map<String, dynamic>.from(it),
          ),
        ),
      );
      return;
    }
    final c = context;
    switch (kind) {
      case 'novel':
        Navigator.push(
            c,
            MaterialPageRoute(
                builder: (_) => TocPage(book: Book.from(it))));
        break;
      case 'comic':
        Navigator.push(
            c,
            MaterialPageRoute(
                builder: (_) => ComicDetailPage(
                    sourceId: sourceId,
                    comicId: '${it['id'] ?? ''}',
                    title: '${it['title'] ?? ''}')));
        break;
      case 'video':
        Navigator.push(
            c,
            MaterialPageRoute(
                builder: (_) => VideoDetailPage(
                    sourceId: sourceId,
                    vodId: '${it['id'] ?? ''}',
                    title: '${it['name'] ?? ''}')));
        break;
      case 'music':
        Navigator.push(
            c,
            MaterialPageRoute(
                builder: (_) => MusicPlayPage(
                    item: Map<String, dynamic>.from(it),
                    sourceId: sourceId)));
        break;
    }
  }

  Widget _biliTile(Map<String, dynamic> it) {
    final cover = '${it['cover'] ?? ''}';
    final title = '${it['title'] ?? ''}';
    return ListTile(
      dense: true,
      leading: cover.isNotEmpty
          ? CoverThumb(cover, fallbackText: title)
          : null,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${it['owner'] ?? ''}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => openBiliVideo(
        context,
        _biliCtx ?? BiliCtx('', ''),
        Map<String, dynamic>.from(it),
      ),
    );
  }
}
