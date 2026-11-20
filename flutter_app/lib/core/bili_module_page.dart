// B 站独立模块（4.81.67）
//
// 定位：影视模块里的一个完整 B 站客户端 —— 推荐 / 热门 / 排行榜 / 分区 / 搜索
//       五个栏目，视频详情里可以逐集播放、逐集下载、一键整季下载，
//       下载走 NAS 上的 bilidown（落盘 /vol1/1000/Media/影视/B站），
//       管理入口在右上角（跳 bili_down_page.dart）。
//
// 为什么不复用 bili_feed_page.dart：那个页面是 4.81.66 的「热门+搜索」最小版，
//       本页是它的完整替代（多栏目 + 分页 + 下载），保留旧页只为不碰坏我的后端入口。
//
// 接口全部走 NAS 主后端 /v1/bili/*（App 不直连 B 站，与 bili_feed_page 同一约定）：
//   GET  /v1/bili/feed?type=popular|recommend&ps=&pn=   热门/推荐
//   GET  /v1/bili/rank?rid=                            排行榜（partitions 取频道表）
//   GET  /v1/bili/region?rid=&ps=&pn=                  分区最新（B 站 newlist）
//   GET  /v1/bili/partitions                           频道常量表
//   GET  /v1/bili/search?q=&pn=                        搜索
//   GET  /v1/bili/pages?bvid=                          分P
//   GET  /v1/bili/playurl?bvid=&cid=                   播放直链（已过媒体代理）
//   GET  /v1/bili/parse?url=                           解析（拿可选清晰度）
//   POST /v1/bili/add        {url, format}             单集下载（url 里带 ?p=N）
//   POST /v1/bili/addall     {bvid, format}            整季/全 P 批量下载
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'bili_down_page.dart';
import 'bili_player.dart';
import 'bili_swipe_page.dart';
import 'bili_direct.dart';
import 'design_tokens.dart';
import 'i18n.dart';

/// 模块内共享的后端连接（base/token），各栏目 Tab 只读。
class BiliCtx {
  BiliCtx(this.base, this.token);

  final String base;
  final String token;

  Map<String, String> get h =>
      token.isEmpty ? const {} : {'x-th-token': token};
}

class BiliModulePage extends StatefulWidget {
  const BiliModulePage({super.key});

  @override
  State<BiliModulePage> createState() => _BiliModulePageState();
}

class _BiliModulePageState extends State<BiliModulePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  String _base = '';
  String _token = '';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 5, vsync: this);
    _boot();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _base = (p.getString('base') ?? '').trim();
      _token = (p.getString('token') ?? '').trim();
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_base.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('哔哩哔哩'))),
        body: Center(child: Text(tr('还没连上后端，请先到「我的后端」完成连接'))),
      );
    }
    final ctx = BiliCtx(_base, _token);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('哔哩哔哩')),
        actions: [
          IconButton(
            tooltip: tr('链接下载'),
            icon: const Icon(Icons.link),
            onPressed: () => openBiliLinkSheet(context, ctx, ''),
          ),
          IconButton(
            tooltip: tr('下载管理'),
            icon: const Icon(Icons.download_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BiliDownPage()),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: [
            Tab(text: tr('推荐')),
            Tab(text: tr('热门')),
            Tab(text: tr('排行榜')),
            Tab(text: tr('分区')),
            Tab(text: tr('搜索')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _BiliGridTab(
            ctx: ctx,
            pathBuilder: (pn) => '/v1/bili/feed?type=recommend&ps=20&pn=$pn',
          ),
          _BiliGridTab(
            ctx: ctx,
            pathBuilder: (pn) => '/v1/bili/feed?type=popular&ps=20&pn=$pn',
          ),
          _BiliChipsTab(
            ctx: ctx,
            chipsPath: '/v1/bili/partitions',
            pathBuilder: (rid, pn) => '/v1/bili/rank?rid=$rid',
            rankBadge: true,
          ),
          _BiliChipsTab(
            ctx: ctx,
            chipsPath: '/v1/bili/partitions',
            pathBuilder: (rid, pn) =>
                '/v1/bili/region?rid=$rid&ps=20&pn=$pn',
          ),
          _BiliSearchTab(ctx: ctx),
        ],
      ),
    );
  }
}

// ───────────────────────── 通用请求 ─────────────────────────

/// 通用 GET：**先走后端，后端不可达（或明确失败）就直连 B 站**。
/// 这样 NAS 关机/断网时，浏览、搜索、详情、评论、弹幕全都还能用（下载除外）。
Future<Map<String, dynamic>?> biliGet(BiliCtx ctx, String path,
    {int sec = 30}) async {
  if (ctx.base.isNotEmpty) {
    try {
      final r = await http
          .get(Uri.parse('${ctx.base}$path'), headers: ctx.h)
          .timeout(Duration(seconds: sec));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) {
        final m = Map<String, dynamic>.from(j);
        if (m['ok'] == true) return m;
      }
    } catch (_) {}
  }
  return biliDirect(path);
}

/// 播放/图片请求统一头：B 站 CDN 与图床都校验 Referer
Map<String, String> biliHeaders(BiliCtx ctx) => <String, String>{
      ...ctx.h,
      'referer': biliReferer,
      'user-agent': biliUA,
    };

Future<Map<String, dynamic>?> biliPost(
    BiliCtx ctx, String path, Map<String, dynamic> body,
    {int sec = 30}) async {
  try {
    final r = await http
        .post(
          Uri.parse('${ctx.base}$path'),
          headers: {...ctx.h, 'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(Duration(seconds: sec));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map) return Map<String, dynamic>.from(j);
  } catch (_) {}
  return null;
}

String biliDur(num? s) {
  final t = (s ?? 0).toInt();
  if (t <= 0) return '';
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final sec = t % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

String biliPlays(num? n) {
  final v = (n ?? 0).toInt();
  if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}w';
  return '$v';
}

List<Map<String, dynamic>> biliItems(Map<String, dynamic> j) =>
    ((j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);

/// 封面：B 站图床有防盗链，走后端 /v1/bili/cover 代理
/// 从「后端代理地址」里解出真实图床地址。
/// 为什么这么做：Image.network 走 9527 时，自签证书 + 自定义 header 容易失败，
/// 表现为「所有封面都是破图」。B 站图床直连不需要任何 header（实测 200），
/// 所以优先直连，失败再由 errorBuilder 回落到后端代理。
String biliRealCover(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  if (s.contains('/v1/bili/cover?u=')) {
    try {
      final i = s.indexOf('u=');
      s = Uri.decodeComponent(s.substring(i + 2));
    } catch (_) {}
  }
  if (s.startsWith('http://')) s = s.replaceFirst('http://', 'https://');
  return s;
}

Widget biliCover(BuildContext context, BiliCtx ctx, String raw,
    {required double radius}) {
  final u = biliRealCover(raw);
  if (u.isEmpty) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest),
    );
  }
  final full = u.startsWith('http')
      ? u
      : '${ctx.base}/v1/bili/cover?u=${Uri.encodeQueryComponent(u)}';
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: Image.network(
      full,
      headers: full.startsWith('http') && !full.contains('/v1/bili/cover')
          ? const <String, String>{}
          : biliHeaders(ctx),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Image.network(
        '${ctx.base}/v1/bili/cover?u=${Uri.encodeQueryComponent(u)}',
        headers: biliHeaders(ctx),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(Icons.broken_image_outlined,
              color: Theme.of(context).colorScheme.outline),
        ),
      ),
    ),
  );
}

/// 选择下载位置（媒体库目标：影视 / 音乐）。返回目标 id，取消返回 null。
Future<String?> pickBiliTarget(BuildContext context, BiliCtx ctx) async {
  final j = await biliGet(ctx, '/v1/bili/folders');
  final targets = ((j == null ? null : j['targets'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
  if (!context.mounted) return null;
  if (targets.isEmpty) return 'video';
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
            child: Text(tr('选择下载位置'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          for (final tg in targets)
            ListTile(
              leading: Icon('${tg['id']}' == 'music'
                  ? Icons.music_note_outlined
                  : Icons.movie_outlined),
              title: Text(tr('${tg['name']}')),
              subtitle: Text('${tg['id']}' == 'music'
                  ? tr('放进去之后在「音乐」里能听')
                  : tr('放进去之后在「影视」里能看')),
              onTap: () => Navigator.of(c).pop('${tg['id']}'),
            ),
        ],
      ),
    ),
  );
}

// ───────────────────────── 网格 Tab（推荐/热门/搜索复用） ─────────────────────────

typedef BiliPathBuilder = String Function(int pn);

class _BiliGridTab extends StatefulWidget {
  final BiliCtx ctx;
  final BiliPathBuilder pathBuilder;

  /// 排行榜模式：封面左上角显示名次
  final bool rankBadge;

  const _BiliGridTab(
      {super.key, required this.ctx, required this.pathBuilder, this.rankBadge = false});

  @override
  State<_BiliGridTab> createState() => _BiliGridTabState();
}

class _BiliGridTabState extends State<_BiliGridTab>
    with AutomaticKeepAliveClientMixin {
  final _sc = ScrollController();
  final List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  int _pn = 0;
  bool _loading = false;
  bool _nomore = false;
  String _err = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
    _refresh();
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_sc.hasClients || _loading || _nomore || _err.isNotEmpty) return;
    if (_sc.position.pixels > _sc.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _err = '';
      _nomore = false;
    });
    final j = await biliGet(widget.ctx, widget.pathBuilder(1));
    if (!mounted) return;
    if (j == null) {
      setState(() => _err = tr('失败'));
      return;
    }
    if (j['ok'] != true) {
      setState(() => _err =
          '${j['message'] ?? ''}'.trim().isEmpty ? tr('失败') : '${j['message']}');
      return;
    }
    final list = biliItems(j);
    setState(() {
      _items
        ..clear()
        ..addAll(list);
      _pn = 1;
      _nomore = list.length < 20;
    });
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    _loading = true;
    final j = await biliGet(widget.ctx, widget.pathBuilder(_pn + 1));
    _loading = false;
    if (!mounted || j == null || j['ok'] != true) return;
    final list = biliItems(j);
    setState(() {
      if (list.isEmpty) {
        _nomore = true;
      } else {
        _items.addAll(list);
        _pn++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    if (_err.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_err, style: TextStyle(color: cs.error)),
            const SizedBox(height: Gap.sm),
            OutlinedButton(onPressed: _refresh, child: Text(tr('重试'))),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text(tr('没搜到，换个词试试')));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: GridView.builder(
        controller: _sc,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(Gap.md),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: Gap.md,
          crossAxisSpacing: Gap.md,
          childAspectRatio: 0.78,
        ),
        itemCount: _items.length + (_nomore ? 0 : 1),
        itemBuilder: (c, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(
                child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            );
          }
          final it = _items[i];
          final title = '${it['title'] ?? ''}';
          final owner = '${it['owner'] ?? ''}';
          final dur = biliDur(it['duration'] is num ? it['duration'] as num : null);
          final play = biliPlays(it['play'] is num ? it['play'] as num : null);
          return InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => BiliSwipePage(
                      ctx: widget.ctx,
                      items: List<Map<String, dynamic>>.from(_items),
                      initialIndex: i),
                )),
            onLongPress: () => openBiliVideo(context, widget.ctx, it),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      biliCover(c, widget.ctx,
                          '${it['coverRaw'] ?? it['cover'] ?? ''}',
                          radius: Radii.md),
                      if (widget.rankBadge)
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: i < 3 ? cs.primary : Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('${i + 1}',
                                style: TextStyle(
                                    color: i < 3 ? cs.onPrimary : Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ),
                      if (dur.isNotEmpty)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(dur,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11)),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.25),
                ),
                const SizedBox(height: 2),
                Text(
                  play.isEmpty ? owner : '$owner · $play',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────── 频道 Tab（排行榜/分区共用：横向频道条 + 网格） ─────────────────────────

typedef BiliRidPathBuilder = String Function(int rid, int pn);

class _BiliChipsTab extends StatefulWidget {
  final BiliCtx ctx;
  final String chipsPath;
  final BiliRidPathBuilder pathBuilder;
  final bool rankBadge;

  const _BiliChipsTab({
    super.key,
    required this.ctx,
    required this.chipsPath,
    required this.pathBuilder,
    this.rankBadge = false,
  });

  @override
  State<_BiliChipsTab> createState() => _BiliChipsTabState();
}

class _BiliChipsTabState extends State<_BiliChipsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _parts = const [];
  int _rid = 0;
  bool _loaded = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadParts();
  }

  Future<void> _loadParts() async {
    final j = await biliGet(widget.ctx, widget.chipsPath);
    if (!mounted || j == null || j['ok'] != true) return;
    final list = ((j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() {
      _parts = list;
      _rid = list.isEmpty ? 0 : (list.first['rid'] is num ? (list.first['rid'] as num).toInt() : 0);
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_parts.isEmpty) return Center(child: Text(tr('失败')));
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            itemCount: _parts.length,
            itemBuilder: (c, i) {
              final p = _parts[i];
              final rid = p['rid'] is num ? (p['rid'] as num).toInt() : 0;
              final name = '${p['name'] ?? ''}';
              return Padding(
                padding: const EdgeInsets.only(right: Gap.sm),
                child: ChoiceChip(
                  label: Text(name),
                  selected: rid == _rid,
                  onSelected: (_) => setState(() => _rid = rid),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: _BiliGridTab(
            key: ValueKey('rid-$_rid'),
            ctx: widget.ctx,
            pathBuilder: (pn) => widget.pathBuilder(_rid, pn),
            rankBadge: widget.rankBadge,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── 搜索 Tab ─────────────────────────

class _BiliSearchTab extends StatefulWidget {
  final BiliCtx ctx;
  const _BiliSearchTab({super.key, required this.ctx});

  @override
  State<_BiliSearchTab> createState() => _BiliSearchTabState();
}

class _BiliSearchTabState extends State<_BiliSearchTab>
    with AutomaticKeepAliveClientMixin {
  final _q = TextEditingController();
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
          child: TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: tr('搜索'),
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md)),
            ),
            onSubmitted: (v) {
              final s = v.trim();
              if (s.isEmpty) return;
              if (RegExp(r'(bilibili\.com|b23\.tv|BV1[a-zA-Z0-9]{9,})').hasMatch(s)) {
                openBiliLinkSheet(context, widget.ctx, s);
                return;
              }
              setState(() => _query = s);
            },
          ),
        ),
        Expanded(
          child: _query.isEmpty
              ? Center(child: Text(tr('搜索')))
              : _BiliGridTab(
                  key: ValueKey('q-$_query'),
                  ctx: widget.ctx,
                  pathBuilder: (pn) =>
                      '/v1/bili/search?q=${Uri.encodeQueryComponent(_query)}&pn=$pn',
                ),
        ),
      ],
    );
  }
}

// ───────────────────────── 视频详情 + 下载 ─────────────────────────

/// 点开一个视频：底部弹详情 —— 逐集播放 / 逐集下载 / 一键整季下载。
Future<void> openBiliVideo(
    BuildContext context, BiliCtx ctx, Map<String, dynamic> it) async {
  final bvid = '${it['bvid'] ?? ''}';
  if (bvid.isEmpty) return;
  final title = '${it['title'] ?? ''}';
  final messenger = ScaffoldMessenger.of(context);

  final j = await biliGet(ctx, '/v1/bili/pages?bvid=${Uri.encodeQueryComponent(bvid)}');
  if (j == null || j['ok'] != true) {
    messenger.showSnackBar(SnackBar(content: Text(tr('失败'))));
    return;
  }
  final pages = ((j['pages'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
  if (pages.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(tr('失败'))));
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _BiliDetailSheet(
      ctx: ctx,
      bvid: bvid,
      title: title,
      owner: '${it['owner'] ?? ''}',
      coverRaw: '${it['coverRaw'] ?? it['cover'] ?? ''}',
      pages: pages,
    ),
  );
}

class _BiliDetailSheet extends StatefulWidget {
  final BiliCtx ctx;
  final String bvid;
  final String title;
  final String owner;
  final String coverRaw;
  final List<Map<String, dynamic>> pages;

  const _BiliDetailSheet({
    required this.ctx,
    required this.bvid,
    required this.title,
    required this.owner,
    required this.coverRaw,
    required this.pages,
  });

  @override
  State<_BiliDetailSheet> createState() => _BiliDetailSheetState();
}

class _BiliDetailSheetState extends State<_BiliDetailSheet> {
  bool _busy = false;

  Future<void> _play(Map<String, dynamic> p) async {
    final nav = Navigator.of(context);
    final cid = '${p['cid'] ?? ''}';
    final j = await biliGet(
        widget.ctx,
        '/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(widget.bvid)}'
        '&cid=${Uri.encodeQueryComponent(cid)}');
    if (!mounted) return;
    final url = (j == null) ? '' : '${j['url'] ?? ''}';
    if (url.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('播放失败'))));
      return;
    }
    // ★4.81.74：换用 core/bili_player.dart 的新播放器（常驻弹幕 + 清晰度面板）。
    //   带上 cid，播放页才能按 cid 拉弹幕。
    await nav.push(MaterialPageRoute(
      builder: (_) => BiliPlayerPage(
        title: widget.title,
        url: url,
        apiBase: widget.ctx.base,
        token: widget.ctx.token,
        bvid: widget.bvid,
        cid: cid,
        quality: (j?['quality'] as num?)?.toInt() ?? 0,
        acceptQuality: ((j?['acceptQuality'] as List?) ?? const [])
            .whereType<num>()
            .map((e) => e.toInt())
            .toList(),
      ),
    ));
  }

  /// 单集下载：走 /v1/bili/add，url 里带 ?p=N，默认 1080P（后端自动回退）
  Future<void> _downloadOne(int index) async {
    if (_busy) return;
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null) return;
    setState(() => _busy = true);
    final j = await biliPost(widget.ctx, '/v1/bili/add', {
      'url': 'https://www.bilibili.com/video/${widget.bvid}/?p=${index + 1}',
      'folder': target,
    });
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = j != null && j['ok'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? tr('已加入下载队列')
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
  }

  /// 整季下载：先取清晰度列表（用第一P解析），让用户挑，然后 addall 一次提交
  Future<void> _downloadAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    final parse = await biliGet(
        widget.ctx,
        '/v1/bili/parse?url=${Uri.encodeQueryComponent('https://www.bilibili.com/video/${widget.bvid}/')}');
    if (!mounted) return;
    setState(() => _busy = false);
    final formats = ((parse == null) ? null : (parse['formats'] as List?)) ?? const [];
    final opts = formats
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    int fmt = 0;
    if (opts.isNotEmpty) {
      if (!context.mounted) return;
      final picked = await showDialog<int>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(tr('选择清晰度')),
          children: [
            for (final o in opts)
              SimpleDialogOption(
                onPressed: () => Navigator.of(c).pop(o['id'] is num ? (o['id'] as num).toInt() : 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${o['label'] ?? o['id']}'),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(0),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(tr('自动')),
              ),
            ),
          ],
        ),
      );
      if (picked == null || !context.mounted) return;
      fmt = picked;
    }
    setState(() => _busy = true);
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null || !context.mounted) return;
    final j = await biliPost(
        widget.ctx,
        '/v1/bili/addall',
        {'bvid': widget.bvid, 'format': fmt, 'folder': target},
        sec: 240);
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = j != null && j['ok'] == true;
    final added = (j == null || j['added'] is! num) ? 0 : (j['added'] as num).toInt();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? trf('共{n}个任务加入下载', {'n': added})
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pages = widget.pages;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    height: 60,
                    child: biliCover(context, widget.ctx, widget.coverRaw,
                        radius: Radii.sm),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        if (widget.owner.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(widget.owner,
                                style: TextStyle(
                                    fontSize: 12, color: cs.outline)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Row(
                children: [
                  if (pages.length > 1)
                    FilledButton.icon(
                      onPressed: _busy ? null : _downloadAll,
                      icon: const Icon(Icons.download_for_offline_outlined,
                          size: 18),
                      label: Text('${tr('全部下载')} (${pages.length})'),
                    ),
                  if (pages.length > 1) const SizedBox(width: Gap.sm),
                  if (_busy)
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
            const SizedBox(height: Gap.sm),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: pages.length,
                itemBuilder: (c, i) {
                  final p = pages[i];
                  final part = '${p['part'] ?? ''}';
                  final dur = biliDur(
                      p['duration'] is num ? p['duration'] as num : null);
                  return ListTile(
                    dense: true,
                    leading: IconButton(
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: _busy ? null : () => _play(p),
                    ),
                    title: Text(
                      trf('第{n}集', {'n': (p['page'] is num) ? (p['page'] as num).toInt() : i + 1}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: part.isEmpty
                        ? (dur.isEmpty ? null : Text(dur))
                        : Text(
                            dur.isEmpty ? part : '$part · $dur',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: IconButton(
                      tooltip: tr('下载本集'),
                      icon: const Icon(Icons.download_outlined),
                      onPressed: _busy ? null : () => _downloadOne(i),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 链接下载（粘贴即下，不用跳页面） ─────────────────────────

/// 粘贴 B 站链接 / BV 号直接下载。initial 为空时弹输入框。
Future<void> openBiliLinkSheet(BuildContext context, BiliCtx ctx,
    [String initial = '']) async {
  final input = initial.trim().isEmpty
      ? await showDialog<String>(
          context: context,
          builder: (c) {
            final ctrl = TextEditingController();
            return AlertDialog(
              title: Text(tr('链接下载')),
              content: TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: tr('粘贴 B 站链接或 BV 号'),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md)),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(c).pop(),
                    child: Text(tr('取消'))),
                FilledButton(
                    onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
                    child: Text(tr('解析'))),
              ],
            );
          },
        )
      : initial;
  if (input == null || input.trim().isEmpty || !context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _BiliLinkSheet(ctx: ctx, input: input.trim()),
  );
}

class _BiliLinkSheet extends StatefulWidget {
  final BiliCtx ctx;
  final String input;
  const _BiliLinkSheet({required this.ctx, required this.input});

  @override
  State<_BiliLinkSheet> createState() => _BiliLinkSheetState();
}

class _BiliLinkSheetState extends State<_BiliLinkSheet> {
  Map<String, dynamic>? _info;
  String _err = '';
  bool _busy = true;
  bool _doing = false;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  Future<void> _parse() async {
    setState(() {
      _busy = true;
      _err = '';
    });
    final j = await biliGet(widget.ctx,
        '/v1/bili/parse?url=${Uri.encodeQueryComponent(widget.input)}');
    if (!mounted) return;
    if (j == null || j['ok'] != true) {
      setState(() {
        _busy = false;
        _err = (j == null || '${j['error'] ?? ''}'.trim().isEmpty)
            ? tr('失败')
            : '${j['error']}';
      });
      return;
    }
    setState(() {
      _info = j;
      _busy = false;
    });
  }

  Future<void> _download({required bool all}) async {
    final info = _info;
    if (info == null || _doing) return;
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null || !mounted) return;
    setState(() => _doing = true);
    final pages = (info['pages'] as List?)?.length ?? 1;
    final Map<String, dynamic>? j = all && pages > 1
        ? await biliPost(widget.ctx, '/v1/bili/addall',
            {'bvid': '${info['bvid']}', 'folder': target},
            sec: 240)
        : await biliPost(widget.ctx, '/v1/bili/add', {
            'url': widget.input,
            'folder': target,
          });
    if (!mounted) return;
    setState(() => _doing = false);
    final ok = j != null && j['ok'] == true;
    final added = all && pages > 1
        ? ((j == null || j['added'] is! num) ? 0 : (j['added'] as num).toInt())
        : 1;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? (all && pages > 1
                ? trf('共{n}个任务加入下载', {'n': added})
                : tr('已加入下载队列'))
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = _info;
    final pages = (info == null ? null : info['pages'] as List?) ?? const [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.md),
                child: Text(_err, style: TextStyle(color: cs.error)),
              ),
            if (info != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    height: 60,
                    child: biliCover(
                        context, widget.ctx, '${info['cover'] ?? ''}',
                        radius: Radii.sm),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${info['title'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if ('${info['owner'] ?? ''}'.isNotEmpty)
                              '${info['owner']}',
                            if (pages.length > 1)
                              trf('共{n}集', {'n': pages.length}),
                          ].join(' · '),
                          style: TextStyle(fontSize: 12, color: cs.outline),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.md),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _doing ? null : () => _download(all: false),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(pages.length > 1
                          ? tr('下载本集')
                          : tr('下载')),
                    ),
                  ),
                  if (pages.length > 1) ...[
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _doing ? null : () => _download(all: true),
                        icon: const Icon(Icons.download_for_offline_outlined,
                            size: 18),
                        label: Text(tr('整季下载')),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }
}
