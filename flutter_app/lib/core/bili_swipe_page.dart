// 沉浸式刷视频（4.81.68）
//
// 定位：像刷短视频一样刷 B 站 —— 上下滑切换、全屏播放、边刷边下载。
// 列表来自模块页各栏目（推荐/热门/排行/分区/搜索）当前已加载的条目，
// 从第几张卡点进来就从第几条开始刷。
//
// 下载按钮就在播放页右侧：单集一条命令下到所选媒体库（影视/音乐），
// 多 P 视频另有「选集」「整季下载」。不用退回列表页。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'bili_module_page.dart'
    show BiliCtx, biliGet, biliPost, biliCover, biliDur, biliPlays, pickBiliTarget,
    biliHeaders;
import 'design_tokens.dart';
import 'player/th_player.dart';
import 'player/th_player_types.dart';
import 'i18n.dart';

class BiliSwipePage extends StatefulWidget {
  final BiliCtx ctx;
  final List<Map<String, dynamic>> items;
  final int initialIndex;

  const BiliSwipePage({
    super.key,
    required this.ctx,
    required this.items,
    this.initialIndex = 0,
  });

  @override
  State<BiliSwipePage> createState() => _BiliSwipePageState();
}

class _BiliSwipePageState extends State<BiliSwipePage> {
  late final PageController _pc;

  @override
  void initState() {
    super.initState();
    _pc = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pc,
        scrollDirection: Axis.vertical,
        itemCount: widget.items.length,
        itemBuilder: (c, i) => _SwipeVideoCard(
          key: ValueKey('swipe-$i'),
          ctx: widget.ctx,
          item: widget.items[i],
        ),
      ),
    );
  }
}

class _SwipeVideoCard extends StatefulWidget {
  final BiliCtx ctx;
  final Map<String, dynamic> item;

  const _SwipeVideoCard({super.key, required this.ctx, required this.item});

  @override
  State<_SwipeVideoCard> createState() => _SwipeVideoCardState();
}

class _SwipeVideoCardState extends State<_SwipeVideoCard>
    with AutomaticKeepAliveClientMixin {
  VideoPlayerController? _vp;
  List<Map<String, dynamic>> _pages = const [];
  int _pageIdx = 0;
  String _err = '';
  bool _loading = true;

  String get _bvid => '${widget.item['bvid'] ?? ''}';
  String get _title => '${widget.item['title'] ?? ''}';
  int get _pageNo => (_pages.isEmpty)
      ? 1
      : (_pages[_pageIdx]['page'] is num
          ? (_pages[_pageIdx]['page'] as num).toInt()
          : _pageIdx + 1);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _vp?.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final j = await biliGet(
        widget.ctx, '/v1/bili/pages?bvid=${Uri.encodeQueryComponent(_bvid)}');
    if (!mounted) return;
    final pages = ((j == null ? null : j['pages'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    if (pages.isEmpty) {
      setState(() {
        _loading = false;
        _err = tr('失败');
      });
      return;
    }
    setState(() => _pages = pages);
    await _playIdx(0);
  }

  Future<void> _playIdx(int idx) async {
    if (idx < 0 || idx >= _pages.length) return;
    final cid = '${_pages[idx]['cid'] ?? ''}';
    final oldVp = _vp;
    setState(() {
      _loading = true;
      _err = '';
      _vp = null;
      _pageIdx = idx;
    });
    oldVp?.dispose();
    final j = await biliGet(
        widget.ctx,
        '/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(_bvid)}'
        '&cid=${Uri.encodeQueryComponent(cid)}');
    if (!mounted) return;
    final url = (j == null) ? '' : '${j['url'] ?? ''}';
    if (url.isEmpty) {
      setState(() {
        _loading = false;
        _err = tr('播放失败');
      });
      return;
    }
    try {
      final vp = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: biliHeaders(widget.ctx),
      );
      await vp.initialize();
      if (!mounted) {
        vp.dispose();
        return;
      }
      // ★4.81.84：不再套 Chewie。控件换成本仓的 VideoSurface（B 站手机端那套：
      //   双击暂停/横滑调进度/竖滑调亮度音量/长按 3 倍速/真·横屏全屏）。
      await vp.setLooping(false);
      await vp.play();
      if (!mounted) {
        vp.dispose();
        return;
      }
      setState(() {
        _vp = vp;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('播放失败')}：$e');
    }
  }

  /// 单集下载：弹出媒体库目标选择后提交
  Future<void> _downloadOne() async {
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null || !mounted) return;
    final j = await biliPost(widget.ctx, '/v1/bili/add', {
      'url':
          'https://www.bilibili.com/video/$_bvid/?p=$_pageNo',
      'folder': target,
    });
    if (!mounted) return;
    final ok = j != null && j['ok'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? tr('已加入下载队列')
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
  }

  /// 整季下载
  Future<void> _downloadAll() async {
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null || !mounted) return;
    final j = await biliPost(
        widget.ctx, '/v1/bili/addall', {'bvid': _bvid, 'folder': target},
        sec: 240);
    if (!mounted) return;
    final ok = j != null && j['ok'] == true;
    final added =
        (j == null || j['added'] is! num) ? 0 : (j['added'] as num).toInt();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? trf('共{n}个任务加入下载', {'n': added})
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
  }

  /// 选集（多 P）
  Future<void> _pickPage() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _pages.length,
          itemBuilder: (c, i) {
            final p = _pages[i];
            final n = (p['page'] is num) ? (p['page'] as num).toInt() : i + 1;
            final part = '${p['part'] ?? ''}';
            return ListTile(
              leading: Icon(n == _pageNo ? Icons.play_circle : Icons.circle_outlined),
              title: Text(trf('第{n}集', {'n': n})),
              subtitle: part.isEmpty ? null : Text(part, maxLines: 1),
              onTap: () => Navigator.of(c).pop(i),
            );
          },
        ),
      ),
    );
    if (picked == null) return;
    await _playIdx(picked);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final it = widget.item;
    final owner = '${it['owner'] ?? ''}';
    final play = biliPlays(it['play'] is num ? it['play'] as num : null);
    final dur = biliDur(it['duration'] is num ? it['duration'] as num : null);
    final sub = [
      if (owner.isNotEmpty) owner,
      if (play.isNotEmpty) play,
      if (dur.isNotEmpty) dur,
      if (_pages.length > 1) trf('第{n}集', {'n': _pageNo}),
    ].join(' · ');

    // ★4.81.84：这里原来是 Chewie。Chewie 的手机端体验跟 B 站差一截
    //   （竖屏不给全屏、没有双击暂停/横滑调进度/长按倍速、菜单还写死英文），
    //   而本仓**早就有**自绘的 ThPlayer（影视页在用，4.81.81 写的）——
    //   问题只是没推广到这个页面。现在统一成 ThPlayer：
    //   下载/选集/整季走它自带的底栏按钮，标题作者信息走 title/subtitle。
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_vp != null)
          ThPlayer(
            controller: _vp!,
            title: _title,
            subtitle: sub,
            onDownload: _downloadOne,
            onEpisodes: _pages.length > 1 ? _pickPage : null,
            moreExtras: [
              if (_pages.length > 1)
                ThMoreItem(
                  icon: Icons.download_for_offline_outlined,
                  label: tr('整季下载'),
                  onTap: _downloadAll,
                ),
            ],
          )
        else if (_err.isNotEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_err, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: Gap.sm),
                  OutlinedButton(
                      onPressed: () => _playIdx(_pageIdx),
                      child: Text(tr('重试'))),
                ],
              ),
            ),
          )
        else
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
