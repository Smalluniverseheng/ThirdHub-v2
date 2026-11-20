// B 站直播 + 番剧时间表（2026-11-20 新增）
//
// 为什么单独一个文件：
//   bili_module_page.dart 已经 1200+ 行，塞进去会变成第二个 main.dart。
//   这里只放「B 站模块里新增的两个栏目」和直播播放器，复用 bili_module_page
//   的 BiliCtx / biliGet（Dart 允许循环 import）。
//
// 接口（后端 routes-bili.js 新增，2026-11-20 实测通过）：
//   GET /v1/bili/live?page=&ps=              直播推荐流（B 站旧 recommend 接口，免签名）
//   GET /v1/bili/live/play?room_id=          拉流：HLS(fmp4/ts) 优先，其次 FLV
//   GET /v1/bili/bangumi?before=&after=      番剧时间表
//
// 两个坑（踩过了，别再踩）：
//   1. B 站新版直播列表 /xlive/web-interface/v1/second/getList 要 wbi 签名，
//      不带签名一律 -352；旧版 /room/v1/room/get_user_recommend 仍免签名 → 用它。
//   2. HLS 的 m3u8 里分片是独立请求、同样校验 Referer，所以**不能**走 9528
//      单文件媒体代理（代理只转 playlist 本身）。必须客户端带 Referer 直连。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import 'bili_module_page.dart' show BiliCtx, biliGet;
import 'design_tokens.dart';
import 'i18n.dart';
import 'ui/app_image.dart';
import 'ui/app_skeleton.dart';

// ───────────────────────── 直播列表 ─────────────────────────

class BiliLiveTab extends StatefulWidget {
  const BiliLiveTab({super.key, required this.ctx});

  final BiliCtx ctx;

  @override
  State<BiliLiveTab> createState() => _BiliLiveTabState();
}

class _BiliLiveTabState extends State<BiliLiveTab>
    with AutomaticKeepAliveClientMixin {
  final _items = <BiliLiveItem>[];
  final _scroll = ScrollController();
  int _page = 1;
  bool _loading = false;
  bool _more = true;
  String _err = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
        unawaited(_load());
      }
    });
    unawaited(_load(refresh: true));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    if (!refresh && !_more) return;
    setState(() {
      _loading = true;
      if (refresh) {
        _page = 1;
        _more = true;
        _err = '';
      }
    });
    final p = refresh ? 1 : _page;
    try {
      final j = await biliGet(widget.ctx, '/v1/bili/live?page=$p&ps=20');
      if (!mounted) return;
      if (j == null || j['ok'] != true) {
        setState(() {
          _err = (j?['error'] ?? j?['message'] ?? tr('直播列表拉不到')).toString();
          _loading = false;
        });
        return;
      }
      final raw = (j['items'] as List?) ?? const [];
      final base = widget.ctx.base;
      final got = raw
          .whereType<Map>()
          .map((e) => BiliLiveItem.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.roomId > 0)
          // 后端给的是相对路径（/v1/bili/cover?u=…），这里补上 host
          .map((e) => e.cover.isEmpty || e.cover.startsWith('http')
              ? e
              : BiliLiveItem(
                  roomId: e.roomId,
                  title: e.title,
                  uname: e.uname,
                  cover: '$base${e.cover}',
                  watched: e.watched,
                ))
          .toList();
      setState(() {
        if (refresh) _items.clear();
        // 同一房间去重（翻页时 B 站会重复给）
        final seen = _items.map((e) => e.roomId).toSet();
        for (final it in got) {
          if (seen.add(it.roomId)) _items.add(it);
        }
        _page = p + 1;
        _more = got.isNotEmpty && j['hasMore'] == true;
        _loading = false;
        _err = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  void _open(BiliLiveItem it) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BiliLivePlayerPage(
        ctx: widget.ctx,
        roomId: it.roomId,
        title: it.title,
        uname: it.uname,
        watched: it.watched,
        cover: it.cover,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_items.isEmpty) {
      if (_loading) return const SkeletonGrid(count: 6, aspectRatio: 0.78);
      if (_err.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.wifi_off,
                  size: 34, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: Gap.md),
              Text(_err,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5, color: Theme.of(context).hintColor)),
              const SizedBox(height: Gap.md),
              FilledButton.tonal(
                  onPressed: () => _load(refresh: true),
                  child: Text(tr('重试'))),
            ]),
          ),
        );
      }
      return Center(
          child: Text(tr('这个时间点没有直播'),
              style: TextStyle(color: Theme.of(context).hintColor)));
    }
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.xl),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: Gap.sm,
          crossAxisSpacing: Gap.sm,
          childAspectRatio: 0.78,
        ),
        itemCount: _items.length + (_more ? 1 : 0),
        itemBuilder: (c, i) {
          if (i >= _items.length) {
            // 触底加载占位：不抢焦点，只是让滑到底有反馈
            unawaited(_load());
            return const SkeletonListTile();
          }
          final it = _items[i];
          return _LiveCard(
              item: it, headers: widget.ctx.h, onTap: () => _open(it));
        },
      ),
    );
  }
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({
    required this.item,
    required this.headers,
    required this.onTap,
  });

  final BiliLiveItem item;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.lgAll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: Radii.lgAll,
              child: Stack(fit: StackFit.expand, children: [
                AppImage(
                  item.cover,
                  headers: headers,
                  fit: BoxFit.cover,
                  radius: 0,
                  placeholderIcon: Icons.live_tv_outlined,
                  showRetryOnFail: false,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
                // 人气角标
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: Radii.pillAll,
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.remove_red_eye_outlined,
                          size: 11, color: Colors.white70),
                      const SizedBox(width: 3),
                      Text(
                        item.watched.isEmpty
                            ? tr('直播中')
                            : item.watched,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white, height: 1.1),
                      ),
                    ]),
                  ),
                ),
                // 直播中标记
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.error,
                      borderRadius: Radii.pillAll,
                    ),
                    child: Text(tr('直播中'),
                        style: const TextStyle(
                            fontSize: 9,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            height: 1.1)),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          Text(item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12.5, height: 1.3, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(children: [
            Icon(Icons.person_outline, size: 11, color: cs.outline),
            const SizedBox(width: 2),
            Expanded(
              child: Text(item.uname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: cs.outline)),
            ),
          ]),
        ],
      ),
    );
  }
}

/// 直播卡片数据（后端已归一化）
class BiliLiveItem {
  BiliLiveItem({
    required this.roomId,
    required this.title,
    required this.uname,
    required this.cover,
    required this.watched,
  });

  final int roomId;
  final String title;
  final String uname;
  final String cover;
  final String watched;

  static BiliLiveItem fromJson(Map<String, dynamic> j) => BiliLiveItem(
        roomId: (j['roomId'] as num?)?.toInt() ?? 0,
        title: '${j['title'] ?? ''}',
        uname: '${j['uname'] ?? ''}',
        cover: '${j['cover'] ?? ''}',
        watched: '${j['watched'] ?? ''}',
      );
}

// ───────────────────────── 直播间播放器 ─────────────────────────

class BiliLivePlayerPage extends StatefulWidget {
  const BiliLivePlayerPage({
    super.key,
    required this.ctx,
    required this.roomId,
    this.title = '',
    this.uname = '',
    this.watched = '',
    this.cover = '',
  });

  final BiliCtx ctx;
  final int roomId;
  final String title;
  final String uname;
  final String watched;
  final String cover;

  @override
  State<BiliLivePlayerPage> createState() => _BiliLivePlayerPageState();
}

class _BiliLivePlayerPageState extends State<BiliLivePlayerPage> {
  VideoPlayerController? _vp;
  bool _loading = true;
  String _err = '';
  List<BiliLiveLine> _lines = const [];
  int _lineIdx = 0;
  bool _full = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _vp?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      final j = await biliGet(widget.ctx, '/v1/bili/live/play?room_id=${widget.roomId}');
      if (!mounted) return;
      if (j == null || j['ok'] != true) {
        setState(() {
          _err = (j?['error'] ?? tr('拿不到直播地址')).toString();
          _loading = false;
        });
        return;
      }
      final opts = (j['options'] as List?) ?? const [];
      final lines = opts
          .whereType<Map>()
          .map((e) => BiliLiveLine(
                protocol: '${e['protocol'] ?? ''}',
                format: '${e['format'] ?? ''}',
                codec: '${e['codec'] ?? ''}',
                url: '${e['url'] ?? ''}',
              ))
          .where((e) => e.url.isNotEmpty)
          .toList();
      final one = BiliLiveLine(
        protocol: '${j['protocol'] ?? ''}',
        format: '${j['format'] ?? ''}',
        codec: '${j['codec'] ?? ''}',
        url: '${j['url'] ?? ''}',
      );
      final all = lines.isEmpty ? [if (one.url.isNotEmpty) one] : lines;
      if (all.isEmpty) {
        setState(() {
          _err = tr('这个直播间没有可用线路');
          _loading = false;
        });
        return;
      }
      setState(() {
        _lines = all;
        _lineIdx = 0;
        _loading = false;
      });
      await _attach(all[0]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  /// 直播流必须带 Referer 直连（m3u8 的分片也校验，所以不能走代理）
  Future<void> _attach(BiliLiveLine line) async {
    final old = _vp;
    if (old != null) await old.dispose();
    _vp = VideoPlayerController.networkUrl(
      Uri.parse(line.url),
      httpHeaders: const {
        'referer': 'https://live.bilibili.com/',
        'user-agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/120.0.0.0 Mobile Safari/537.36',
        'origin': 'https://live.bilibili.com',
      },
    );
    try {
      await _vp!.initialize();
      await _vp!.setLooping(false);
      await _vp!.play();
      if (mounted) setState(() => _err = '');
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('这条线路播不了')}：$e');
    }
    if (mounted) setState(() {});
  }

  String _lineName(BiliLiveLine l) {
    final f = l.format.isEmpty ? l.protocol : l.format;
    final c = l.codec.toUpperCase();
    return c.isEmpty ? f.toUpperCase() : '${f.toUpperCase()} · $c';
  }

  void _openLines() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg))),
      builder: (c) => SafeArea(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
                child: Text(tr('线路'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: Gap.xs),
              for (var i = 0; i < _lines.length; i++)
                ListTile(
                  dense: true,
                  leading: Icon(
                    i == _lineIdx
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: i == _lineIdx
                        ? Theme.of(c).colorScheme.primary
                        : Colors.grey,
                  ),
                  title: Text(_lineName(_lines[i]),
                      style: const TextStyle(fontSize: 13)),
                  onTap: () {
                    Navigator.pop(c);
                    setState(() => _lineIdx = i);
                    unawaited(_attach(_lines[i]));
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
                child: Text(
                  tr('播不动就换一条：不同线路走不同 CDN，卡的时候换一个往往就好了。'),
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: Theme.of(c).hintColor),
                ),
              ),
            ]),
      ),
    );
  }

  void _toggleFull() {
    setState(() => _full = !_full);
    if (_full) {
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vp = _vp;
    final ready = vp != null && vp.value.isInitialized;
    final ar = (ready && vp.value.aspectRatio > 0) ? vp.value.aspectRatio : 16 / 9;

    final screen = Stack(children: [
      Container(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: _full ? ar : (ar < 1 ? 16 / 9 : ar),
            child: ready
                ? VideoPlayer(vp)
                : Center(
                    child: _loading
                        ? const CircularProgressIndicator(color: Colors.white70)
                        : Padding(
                            padding: const EdgeInsets.all(Gap.lg),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_err.isEmpty ? tr('未能播放') : _err,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 12.5)),
                                  const SizedBox(height: Gap.md),
                                  FilledButton.tonal(
                                      onPressed: _boot,
                                      child: Text(tr('重试'))),
                                ]),
                          ),
                  ),
          ),
        ),
      ),
      // 控制层
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Container(
          padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 4,
              left: 4,
              right: 8,
              bottom: 8),
          decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent])),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Text(
                widget.title.isEmpty ? tr('直播间') : widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: tr('线路'),
              icon: const Icon(Icons.swap_horiz, color: Colors.white),
              onPressed: _lines.isEmpty ? null : _openLines,
            ),
            IconButton(
              tooltip: _full ? tr('退出全屏') : tr('全屏'),
              icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white),
              onPressed: _toggleFull,
            ),
          ]),
        ),
      ),
      if (!_full && !ready)
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _LiveBadge(),
        ),
    ]);

    if (_full) return Scaffold(backgroundColor: Colors.black, body: screen);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          AspectRatio(aspectRatio: 16 / 9, child: screen),
          Expanded(
            child: Container(
              color: Theme.of(context).colorScheme.surface,
              child: ListView(
                padding: const EdgeInsets.all(Gap.md),
                children: [
                  Row(children: [
                    const _LiveBadge(),
                    const SizedBox(width: 6),
                    Text(widget.watched,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline)),
                  ]),
                  const SizedBox(height: Gap.sm),
                  Text(widget.title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(widget.uname,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline)),
                  const SizedBox(height: Gap.md),
                  // 线路选择常驻在页面上，不用每次点右上角
                  if (_lines.length > 1)
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (var i = 0; i < _lines.length; i++)
                        ChoiceChip(
                          label: Text(_lineName(_lines[i]),
                              style: const TextStyle(fontSize: 11.5)),
                          selected: i == _lineIdx,
                          onSelected: (_) {
                            setState(() => _lineIdx = i);
                            unawaited(_attach(_lines[i]));
                          },
                        ),
                    ]),
                  const SizedBox(height: Gap.md),
                  Text(
                    tr('直播没有回放、不能拖动；想看之前的内容得等主播投稿。'),
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.error,
            borderRadius: Radii.pillAll),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
                color: Colors.white, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(tr('直播中'),
              style: const TextStyle(
                  fontSize: 9.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  height: 1.2)),
        ]),
      );
}

class BiliLiveLine {
  BiliLiveLine({
    required this.protocol,
    required this.format,
    required this.codec,
    required this.url,
  });

  final String protocol;
  final String format;
  final String codec;
  final String url;
}

// ───────────────────────── 番剧时间表 ─────────────────────────

class BiliBangumiTab extends StatefulWidget {
  const BiliBangumiTab({super.key, required this.ctx});

  final BiliCtx ctx;

  @override
  State<BiliBangumiTab> createState() => _BiliBangumiTabState();
}

class _BiliBangumiTabState extends State<BiliBangumiTab>
    with AutomaticKeepAliveClientMixin {
  List<BiliBangumiDay> _days = const [];
  bool _loading = true;
  String _err = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 后端给相对封面路径，补 host
  String _abs(String u) {
    if (u.isEmpty || u.startsWith('http')) return u;
    return '${widget.ctx.base}$u';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      final j = await biliGet(widget.ctx, '/v1/bili/bangumi?before=1&after=6');
      if (!mounted) return;
      if (j == null || j['ok'] != true) {
        setState(() {
          _err = (j?['error'] ?? tr('时间表拉不到')).toString();
          _loading = false;
        });
        return;
      }
      final days = ((j['days'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => BiliBangumiDay(
                date: '${e['date'] ?? ''}',
                items: ((e['items'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((x) => BiliBangumiItem(
                          title: '${x['title'] ?? ''}',
                          cover: _abs('${x['cover'] ?? ''}'),
                          ep: '${x['ep'] ?? ''}',
                          url: '${x['url'] ?? ''}',
                        ))
                    .toList(),
              ))
          .where((d) => d.items.isNotEmpty)
          .toList();
      setState(() {
        _days = days;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading && _days.isEmpty) return const SkeletonList(count: 6);
    if (_days.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.calendar_today_outlined,
                size: 34, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: Gap.md),
            Text(_err.isEmpty ? tr('这几天没有新番更新') : _err,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, color: Theme.of(context).hintColor)),
            const SizedBox(height: Gap.md),
            FilledButton.tonal(
                onPressed: _load, child: Text(tr('重试'))),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: Gap.xl),
        itemCount: _days.length,
        itemBuilder: (c, i) {
          final d = _days[i];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
                child: Text(d.date,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
              for (final it in d.items)
                ListTile(
                  dense: true,
                  leading: ClipRRect(
                    borderRadius: Radii.smAll,
                    child: SizedBox(
                      width: 40,
                      height: 54,
                      child: AppImage(
                        it.cover,
                        headers: widget.ctx.h,
                        fit: BoxFit.cover,
                        radius: 0,
                        placeholderIcon: Icons.movie_outlined,
                        showRetryOnFail: false,
                        backgroundColor:
                            Theme.of(c).colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  title: Text(it.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(it.ep,
                      style: TextStyle(
                          fontSize: 11, color: Theme.of(c).hintColor)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: Theme.of(c).colorScheme.outline),
                  onTap: () {
                    // 番剧播放要按 ep/ss 取流，属另一条链路（后端尚未接），
                    // 这里不假装能播 —— 说清楚比给个点了没反应的按钮好。
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(tr('番剧播放还没接上，先用作「什么时候更新」的日历')),
                    ));
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class BiliBangumiDay {
  BiliBangumiDay({required this.date, required this.items});
  final String date;
  final List<BiliBangumiItem> items;
}

class BiliBangumiItem {
  BiliBangumiItem({
    required this.title,
    required this.cover,
    required this.ep,
    required this.url,
  });
  final String title;
  final String cover;
  final String ep;
  final String url;
}
