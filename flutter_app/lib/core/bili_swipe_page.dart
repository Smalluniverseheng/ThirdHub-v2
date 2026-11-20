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

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'bili_module_page.dart'
    show BiliCtx, biliGet, biliPost, biliCover, biliDur, biliPlays, pickBiliTarget,
    biliHeaders;
import 'design_tokens.dart';
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
  ChewieController? _chewie;
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
    _chewie?.dispose();
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
    final oldChewie = _chewie;
    setState(() {
      _loading = true;
      _err = '';
      _vp = null;
      _chewie = null;
      _pageIdx = idx;
    });
    oldChewie?.dispose();
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
      final chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: true,
        looping: false,
        allowFullScreen: false,
        materialProgressColors: ChewieProgressColors(
          playedColor: Theme.of(context).colorScheme.primary,
          handleColor: Theme.of(context).colorScheme.primary,
        ),
      );
      setState(() {
        _vp = vp;
        _chewie = chewie;
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
    final cs = Theme.of(context).colorScheme;
    final it = widget.item;
    final owner = '${it['owner'] ?? ''}';
    final play = biliPlays(it['play'] is num ? it['play'] as num : null);
    final dur = biliDur(it['duration'] is num ? it['duration'] as num : null);
    return Stack(
      fit: StackFit.expand,
      children: [
        // 播放器（chewie 自带点按控件）
        if (_chewie != null && _vp != null)
          Center(
            child: AspectRatio(
              aspectRatio:
                  _vp!.value.aspectRatio == 0 ? 16 / 9 : _vp!.value.aspectRatio,
              child: Chewie(controller: _chewie!),
            ),
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

        // 右侧操作列
        Positioned(
          right: Gap.sm,
          bottom: 120,
          child: Column(
            children: [
              _RoundBtn(
                icon: Icons.download_outlined,
                label: tr('下载'),
                onTap: _downloadOne,
              ),
              if (_pages.length > 1) ...[
                const SizedBox(height: Gap.md),
                _RoundBtn(
                  icon: Icons.playlist_play_outlined,
                  label: tr('选集'),
                  onTap: _pickPage,
                ),
                const SizedBox(height: Gap.md),
                _RoundBtn(
                  icon: Icons.download_for_offline_outlined,
                  label: tr('整季下载'),
                  onTap: _downloadAll,
                ),
              ],
            ],
          ),
        ),

        // 底部信息条
        Positioned(
          left: Gap.md,
          right: 76,
          bottom: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 6)]),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (owner.isNotEmpty) owner,
                  if (play.isNotEmpty) play,
                  if (dur.isNotEmpty) dur,
                  if (_pages.length > 1)
                    trf('第{n}集', {'n': _pageNo}),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _RoundBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
