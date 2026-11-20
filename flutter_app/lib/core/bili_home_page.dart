// B 站样式首页（4.81.70）
//
// 参照 B 站客户端首页：顶部搜索 + 频道横滑 + 双列卡片（封面 / 时长 / 播放量 / 弹幕数 / 标题 / UP 主）。
// 点卡片进 BiliVideoPage（详情 + 评论区 + 相关推荐）。
//
// 说明：底部导航仍由 App 自带，本页只负责模块内部。
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bili_module_page.dart'
    show BiliCtx, biliGet, biliCover, biliDur, biliPlays, biliItems;
import 'bili_down_page.dart';
import 'bili_video_page.dart';
import 'design_tokens.dart';
import 'i18n.dart';

/// 频道定义：live=直播占位 / recommend=推荐 / popular=热门 / rid:X=分区
const List<List<String>> _channels = [
  ['直播', 'live'],
  ['推荐', 'recommend'],
  ['热门', 'popular'],
  ['动画', 'rid:1'],
  ['番剧', 'rid:13'],
  ['影视', 'rid:181'],
  ['游戏', 'rid:4'],
  ['知识', 'rid:36'],
  ['科技', 'rid:188'],
  ['音乐', 'rid:3'],
  ['鬼畜', 'rid:119'],
  ['生活', 'rid:160'],
  ['美食', 'rid:211'],
];

class BiliHomePage extends StatefulWidget {
  const BiliHomePage({super.key});

  @override
  State<BiliHomePage> createState() => _BiliHomePageState();
}

class _BiliHomePageState extends State<BiliHomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tc;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  late BiliCtx _ctx;
  bool _ready = false;

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _ctx = BiliCtx((p.getString('base') ?? '').trim(),
          (p.getString('token') ?? '').trim());
      _ready = true;
    });
  }

  @override
  void initState() {
    super.initState();
    _boot();
    _tc = TabController(initialIndex: 1, length: _channels.length, vsync: this);
    _tc.addListener(() {
      if (!_tc.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tc.dispose();
    _search.dispose();
    super.dispose();
  }

  void _submitSearch() {
    final s = _search.text.trim();
    if (s.isEmpty) return;
    // 粘链接 → 直接下（复用原模块页的链接下载能力在 video 页入口里，这里走搜索）
    setState(() => _query = s);
    _tc.animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(104),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // ── 顶部：搜索框 ──
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, 6, Gap.md, 4),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: cs.primaryContainer,
                      child: Icon(Icons.person_outline,
                          size: 18, color: cs.onPrimaryContainer),
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _search,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _submitSearch(),
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                            hintText: tr('搜索'),
                            hintStyle: TextStyle(fontSize: 13, color: cs.outline),
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            prefixIcon:
                                Icon(Icons.search, size: 18, color: cs.outline),
                            filled: true,
                            fillColor: cs.surfaceContainerHighest,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.download_outlined, size: 20),
                      tooltip: tr('下载管理'),
                      onPressed: () => openBiliDownloads(context, _ctx),
                    ),
                  ],
                ),
              ),
              // ── 频道横滑 ──
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  itemCount: _channels.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 18),
                  itemBuilder: (c, i) {
                    final active = i == _tc.index;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _query = '');
                        _tc.animateTo(i);
                      },
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tr(_channels[i][0]),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight:
                                    active ? FontWeight.w600 : FontWeight.normal,
                                color: active ? cs.onSurface : cs.outline,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              width: active ? 18 : 0,
                              height: 3,
                              decoration: BoxDecoration(
                                color: cs.primary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tc,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final ch in _channels)
            _ChannelGrid(
              key: ValueKey(ch[1] + _query),
              ctx: _ctx,
              channel: ch[1],
              query: _query,
            ),
        ],
      ),
    );
  }
}

/// 下载管理入口（复用 B 站下载页）
Future<void> openBiliDownloads(BuildContext context, BiliCtx ctx) async {
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const BiliDownPage()));
}

class _ChannelGrid extends StatefulWidget {
  final BiliCtx ctx;
  final String channel;
  final String query;

  const _ChannelGrid({
    super.key,
    required this.ctx,
    required this.channel,
    required this.query,
  });

  @override
  State<_ChannelGrid> createState() => _ChannelGridState();
}

class _ChannelGridState extends State<_ChannelGrid>
    with AutomaticKeepAliveClientMixin {
  final List<Map<String, dynamic>> _items = [];
  int _pn = 1;
  bool _loading = false;
  bool _nomore = false;
  String _err = '';
  final ScrollController _sc = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sc.addListener(() {
      if (_sc.position.pixels > _sc.position.maxScrollExtent - 600) _loadMore();
    });
    _refresh();
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  String _path(int pn) {
    final ch = widget.channel;
    if (widget.query.isNotEmpty) {
      return '/v1/bili/search?q=${Uri.encodeQueryComponent(widget.query)}'
          '&ps=20&pn=$pn';
    }
    if (ch == 'live') return '';
    if (ch == 'recommend') return '/v1/bili/feed?type=recommend&ps=20&pn=$pn';
    if (ch == 'popular') return '/v1/bili/feed?type=popular&ps=20&pn=$pn';
    final rid = ch.startsWith('rid:') ? ch.substring(4) : '1';
    return '/v1/bili/region?rid=$rid&ps=20&pn=$pn';
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _err = '';
      _pn = 1;
      _nomore = false;
    });
    final path = _path(1);
    if (path.isEmpty) {
      setState(() {
        _loading = false;
        _items.clear();
      });
      return;
    }
    final j = await biliGet(_ctx, path);
    if (!mounted) return;
    final list = (j == null) ? <Map<String, dynamic>>[] : biliItems(j);
    setState(() {
      _loading = false;
      _items
        ..clear()
        ..addAll(list);
      _nomore = list.length < 8;
      _err = (j == null || j['ok'] != true) ? tr('失败') : '';
    });
  }

  Future<void> _loadMore() async {
    if (_loading || _nomore) return;
    setState(() => _loading = true);
    final next = _pn + 1;
    final j = await biliGet(_ctx, _path(next));
    if (!mounted) return;
    final list = (j == null) ? <Map<String, dynamic>>[] : biliItems(j);
    setState(() {
      _loading = false;
      if (list.isEmpty) {
        _nomore = true;
      } else {
        _pn = next;
        _items.addAll(list);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    if (widget.channel == 'live') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.live_tv_outlined, size: 42, color: cs.outline),
              const SizedBox(height: Gap.md),
              Text(tr('直播区暂未开放'),
                  style: TextStyle(color: cs.outline, fontSize: 13)),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty && !_loading) {
      return Center(
        child: Text(_err.isEmpty ? tr('没搜到，换个词试试') : _err,
            style: TextStyle(color: cs.outline, fontSize: 13)),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(builder: (c, cons) {
        final w = (cons.maxWidth - Gap.sm * 3) / 2;
        final extent = w * 9 / 16 + 74;
        return GridView.builder(
          controller: _sc,
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: Gap.sm,
            mainAxisSpacing: Gap.md,
            mainAxisExtent: extent,
          ),
          itemCount: _items.length + (_nomore ? 0 : 1),
          itemBuilder: (c, i) {
            if (i >= _items.length) {
              return Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)));
            }
            final it = _items[i];
            return _VideoCard(
              ctx: _ctx,
              item: it,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => BiliVideoPage(ctx: _ctx, item: it),
              )),
            );
          },
        );
      }),
    );
  }
}

/// 双列卡片：封面 + 时长 + 播放/弹幕 + 标题 + UP 主
class _VideoCard extends StatelessWidget {
  final BiliCtx ctx;
  final Map<String, dynamic> item;
  final VoidCallback onTap;

  const _VideoCard({
    required this.ctx,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dur = biliDur(item['duration'] is num ? item['duration'] as num : null);
    final play = biliPlays(item['play'] is num ? item['play'] as num : null);
    final danmakuRaw = item['danmaku'] ?? item['video_review'];
    final danmaku =
        biliPlays(danmakuRaw is num ? danmakuRaw : null);
    final owner = '${item['owner'] ?? ''}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: Stack(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: biliCover(context, ctx, '${item['cover'] ?? ''}',
                      radius: 0),
                ),
                // 左下：播放量 + 弹幕数
                Positioned(
                  left: 4,
                  bottom: 4,
                  right: 4,
                  child: Row(
                    children: [
                      _badge(Icons.play_arrow_rounded, play),
                      const SizedBox(width: 6),
                      _badge(Icons.subtitles_outlined, danmaku),
                      const Spacer(),
                      if (dur.isNotEmpty) _text(dur),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 标题
          Text(
            '${item['title'] ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13, height: 1.25, color: cs.onSurface),
          ),
          const SizedBox(height: 4),
          // UP 主
          Row(
            children: [
              Icon(Icons.account_circle_outlined, size: 13, color: cs.outline),
              const SizedBox(width: 3),
              Expanded(
                child: Text(
                  owner,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String text) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: Colors.white),
      if (text.isNotEmpty) ...[
        const SizedBox(width: 1),
        _text(text),
      ],
    ]);
  }

  Widget _text(String s) => Text(
        s,
        style: const TextStyle(
            fontSize: 10,
            color: Colors.white,
            shadows: [Shadow(color: Colors.black54, blurRadius: 3)]),
      );
}
