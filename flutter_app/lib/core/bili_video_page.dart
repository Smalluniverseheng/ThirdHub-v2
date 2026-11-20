// B 站样式视频详情页（4.81.70）
//
// 顶部播放器 → 标题/UP主/统计（播放·弹幕·点赞·投币·收藏·分享）→ 简介 →
// 评论区（热门/最新，可翻页，带子回复展开）→ 相关推荐。
//
// 数据来自后端 /v1/bili/view、/v1/bili/replies、/v1/bili/related。
// 点赞/投币/收藏是**展示**：写操作需要 B 站登录态与 wbi 签名，点击会跳到 B 站原页。
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'bili_module_page.dart'
    show BiliCtx, biliGet, biliPost, biliCover, biliDur, biliPlays, pickBiliTarget,
    biliHeaders;
import 'bili_danmaku_layer.dart';
import 'design_tokens.dart';
import 'i18n.dart';

class BiliVideoPage extends StatefulWidget {
  final BiliCtx ctx;
  final Map<String, dynamic> item;

  const BiliVideoPage({super.key, required this.ctx, required this.item});

  @override
  State<BiliVideoPage> createState() => _BiliVideoPageState();
}

class _BiliVideoPageState extends State<BiliVideoPage> {
  Map<String, dynamic>? _view;
  List<Map<String, dynamic>> _pages = const [];
  int _pageIdx = 0;

  VideoPlayerController? _vp;
  ChewieController? _chewie;
  bool _playing = false;
  String _playErr = '';

  // 弹幕
  List<Map<String, dynamic>> _dm = const [];
  bool _dmOn = true;
  String _dmCid = '';

  final List<Map<String, dynamic>> _replies = [];
  int _replyPage = 1;
  int _replyTotal = 0;
  String _replySort = '2';
  bool _replyLoading = false;
  bool _replyNomore = false;
  String _replyErr = '';

  List<Map<String, dynamic>> _related = const [];
  bool _descOpen = false;

  String get _bvid => '${widget.item['bvid'] ?? ''}';

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
        widget.ctx, '/v1/bili/view?bvid=${Uri.encodeQueryComponent(_bvid)}');
    if (!mounted) return;
    if (j != null && j['ok'] == true) {
      final pages = ((j['pages'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      setState(() {
        _view = j;
        _pages = pages;
      });
      await _play(0);
    } else {
      setState(() => _playErr =
          (j == null || '${j['error'] ?? ''}'.trim().isEmpty) ? tr('失败') : '${j['error']}');
    }
    _loadReplies(reset: true);
    _loadRelated();
  }

  Future<void> _play(int idx) async {
    final pages = _pages;
    final cid = pages.isEmpty
        ? null
        : pages[idx.clamp(0, pages.length - 1)]['cid'];
    final oldVp = _vp, oldChewie = _chewie;
    setState(() {
      _playing = false;
      _playErr = '';
      _vp = null;
      _chewie = null;
      _pageIdx = idx;
    });
    oldChewie?.dispose();
    oldVp?.dispose();
    final q = StringBuffer('/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(_bvid)}');
    if (cid != null) q.write('&cid=$cid');
    final j = await biliGet(widget.ctx, q.toString());
    if (!mounted) return;
    final url = (j == null) ? '' : '${j['url'] ?? ''}';
    if (url.isEmpty) {
      setState(() => _playErr = tr('播放失败'));
      return;
    }
    try {
      final vp = VideoPlayerController.networkUrl(Uri.parse(url),
          httpHeaders: biliHeaders(widget.ctx));
      await vp.initialize();
      if (!mounted) {
        vp.dispose();
        return;
      }
      final chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: true,
        allowFullScreen: true,
        looping: false,
      );
      setState(() {
        _vp = vp;
        _chewie = chewie;
        _playing = true;
      });
      if (cid != null) _loadDanmaku('$cid');
    } catch (e) {
      if (mounted) setState(() => _playErr = '${tr('播放失败')}：$e');
    }
  }

  Future<void> _loadReplies({required bool reset}) async {
    if (_replyLoading) return;
    if (!reset && _replyNomore) return;
    setState(() {
      _replyLoading = true;
      if (reset) {
        _replyErr = '';
        _replyPage = 1;
        _replyNomore = false;
      }
    });
    final pn = reset ? 1 : _replyPage + 1;
    final j = await biliGet(
        widget.ctx,
        '/v1/bili/replies?bvid=${Uri.encodeQueryComponent(_bvid)}'
        '&pn=$pn&ps=20&sort=$_replySort');
    if (!mounted) return;
    final items = ((j == null ? null : j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() {
      _replyLoading = false;
      if (reset) {
        _replies
          ..clear()
          ..addAll(items);
        _replyPage = 1;
        _replyTotal = (j == null || j['total'] is! num) ? 0 : (j['total'] as num).toInt();
      } else if (items.isEmpty) {
        _replyNomore = true;
      } else {
        _replyPage = pn;
        _replies.addAll(items);
      }
      if (j == null || j['ok'] != true) {
        _replyErr = (j == null || '${j['error'] ?? ''}'.trim().isEmpty)
            ? tr('失败')
            : '${j['error']}';
      }
    });
  }

  Future<void> _loadDanmaku(String cid) async {
    if (_dmCid == cid && _dm.isNotEmpty) return;
    _dmCid = cid;
    final j = await biliGet(
        widget.ctx, '/v1/bili/danmaku?cid=${Uri.encodeQueryComponent(cid)}');
    if (!mounted) return;
    final items = ((j == null ? null : j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() => _dm = items);
  }

  Future<void> _loadRelated() async {
    final j = await biliGet(widget.ctx,
        '/v1/bili/related?bvid=${Uri.encodeQueryComponent(_bvid)}');
    if (!mounted) return;
    setState(() {
      _related = ((j == null ? null : j['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    });
  }

  Future<void> _download({required bool all}) async {
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null || !mounted) return;
    final pages = _pages;
    final pn = pages.isEmpty
        ? 1
        : (pages[_pageIdx]['page'] is num
            ? (pages[_pageIdx]['page'] as num).toInt()
            : 1);
    final Map<String, dynamic>? j = all && pages.length > 1
        ? await biliPost(widget.ctx, '/v1/bili/addall',
            {'bvid': _bvid, 'folder': target}, sec: 240)
        : await biliPost(widget.ctx, '/v1/bili/add', {
            'url': 'https://www.bilibili.com/video/$_bvid/?p=$pn',
            'folder': target,
          });
    if (!mounted) return;
    final ok = j != null && j['ok'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? (all ? trf('共{n}个任务加入下载', {'n': (j['added'] is num ? (j['added'] as num).toInt() : 0)}) : tr('已加入下载队列'))
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
  }

  void _openInBili() {
    launchUrl(Uri.parse('https://www.bilibili.com/video/$_bvid'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = _view ?? const <String, dynamic>{};
    final stat = (v['stat'] as Map?) ?? const {};
    final owner = (v['owner'] as Map?) ?? const {};
    final title = '${v['title'] ?? widget.item['title'] ?? ''}';
    final desc = '${v['desc'] ?? ''}';
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: tr('弹幕'),
            icon: Icon(_dmOn ? Icons.subtitles : Icons.subtitles_off_outlined),
            onPressed: () => setState(() => _dmOn = !_dmOn),
          ),
          IconButton(
            tooltip: tr('下载'),
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _download(all: false),
          ),
          if (_pages.length > 1)
            IconButton(
              tooltip: tr('整季下载'),
              icon: const Icon(Icons.download_for_offline_outlined),
              onPressed: () => _download(all: true),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // 播放器
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: _chewie != null && _vp != null
                  ? Stack(fit: StackFit.expand, children: [
                      Chewie(controller: _chewie!),
                      BiliDanmaku(
                        vp: _vp,
                        items: _dm,
                        enabled: _dmOn,
                      ),
                    ])
                  : Center(
                      child: _playErr.isNotEmpty
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_playErr,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                const SizedBox(height: 8),
                                OutlinedButton(
                                  onPressed: () => _play(_pageIdx),
                                  child: Text(tr('重试')),
                                ),
                              ],
                            )
                          : const CircularProgressIndicator(),
                    ),
            ),
          ),
          // 标题 + 统计
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600, height: 1.3)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _kv(Icons.play_arrow_rounded, _fmtNum(stat['view'])),
                    const SizedBox(width: 12),
                    _kv(Icons.subtitles_outlined, _fmtNum(stat['danmaku'])),
                    const SizedBox(width: 12),
                    Text('${v['pubdate'] is num ? _dateOf((v['pubdate'] as num).toInt()) : ''}',
                        style: TextStyle(fontSize: 11, color: cs.outline)),
                  ],
                ),
                const SizedBox(height: 10),
                // 统计按钮行（展示 + 跳转）
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _statBtn(Icons.thumb_up_outlined, _fmtNum(stat['like']), _openInBili),
                    _statBtn(Icons.monetization_on_outlined, _fmtNum(stat['coin']), _openInBili),
                    _statBtn(Icons.star_border_rounded, _fmtNum(stat['favorite']), _openInBili),
                    _statBtn(Icons.share_outlined, _fmtNum(stat['share']), _openInBili),
                    _statBtn(Icons.chat_bubble_outline, _fmtNum(stat['reply']),
                        _openInBili),
                  ],
                ),
                const SizedBox(height: 10),
                // UP 主
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: cs.surfaceContainerHighest,
                      child: (owner['face'] ?? '').toString().isEmpty
                          ? Icon(Icons.person, size: 16, color: cs.outline)
                          : ClipOval(
                              child: biliCover(context, widget.ctx,
                                  '${owner['face']}', radius: 0)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${owner['name'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                    OutlinedButton(
                      onPressed: _openInBili,
                      style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 14)),
                      child: Text(tr('打开原页'), style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                // 简介
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () => setState(() => _descOpen = !_descOpen),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Text(
                        desc,
                        maxLines: _descOpen ? null : 2,
                        overflow: _descOpen ? null : TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, height: 1.45),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 分P
          if (_pages.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 12, Gap.md, 0),
              child: SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pages.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (c, i) {
                    final n = _pages[i]['page'] is num
                        ? (_pages[i]['page'] as num).toInt()
                        : i + 1;
                    final active = i == _pageIdx;
                    return ChoiceChip(
                      label: Text(trf('第{n}集', {'n': n}),
                          style: const TextStyle(fontSize: 12)),
                      selected: active,
                      onSelected: (_) => _play(i),
                    );
                  },
                ),
              ),
            ),
          // 分割
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 16, Gap.md, 0),
            child: Row(
              children: [
                Text('${tr('评论')} $_replyTotal'.trim(),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                _sortChip(tr('热门'), '2'),
                const SizedBox(width: 6),
                _sortChip(tr('最新'), '0'),
              ],
            ),
          ),
          if (_replyErr.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_replyErr,
                  style: TextStyle(fontSize: 12, color: cs.error)),
            ),
          // 评论列表
          for (final r in _replies) _ReplyTile(item: r),
          if (_replyLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                  child: SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (_replies.isNotEmpty && !_replyNomore)
            Center(
              child: TextButton(
                onPressed: () => _loadReplies(reset: false),
                child: Text(tr('加载更多')),
              ),
            ),
          // 相关推荐
          if (_related.isNotEmpty) ...[
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 8),
              child: Text(tr('相关推荐'),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            for (final it in _related.take(8)) _RelatedTile(ctx: widget.ctx, item: it),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _kv(IconData icon, String text) {
    final cs = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: cs.outline),
      const SizedBox(width: 2),
      Text(text, style: TextStyle(fontSize: 11, color: cs.outline)),
    ]);
  }

  Widget _statBtn(IconData icon, String text, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _sortChip(String label, String sort) {
    final active = _replySort == sort;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        if (_replySort == sort) return;
        setState(() => _replySort = sort);
        _loadReplies(reset: true);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: active ? cs.onPrimaryContainer : cs.outline)),
      ),
    );
  }

  String _fmtNum(Object? n) {
    if (n is! num) return '0';
    final v = n.toDouble();
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    return v.toInt().toString();
  }

  String _dateOf(int sec) {
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

String _initial(String s) {
  final t = s.trim();
  if (t.isEmpty) return '?';
  return t.substring(0, 1);
}

class _ReplyTile extends StatefulWidget {
  final Map<String, dynamic> item;

  const _ReplyTile({required this.item});

  @override
  State<_ReplyTile> createState() => _ReplyTileState();
}

class _ReplyTileState extends State<_ReplyTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = widget.item;
    final subs = ((r['replies'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 8, Gap.md, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: cs.surfaceContainerHighest,
            child: Text(_initial('${r['uname'] ?? ''}'),
                style: TextStyle(fontSize: 11, color: cs.outline)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text('${r['uname'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: cs.outline)),
                    ),
                    if ((r['level'] as num? ?? 0) > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('Lv${r['level']}',
                            style: TextStyle(
                                fontSize: 9, color: cs.primary)),
                      ),
                    ],
                    const Spacer(),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.thumb_up_outlined,
                          size: 12, color: cs.outline),
                      const SizedBox(width: 2),
                      Text('${r['like'] ?? 0}',
                          style:
                              TextStyle(fontSize: 10, color: cs.outline)),
                    ]),
                  ],
                ),
                const SizedBox(height: 3),
                Text('${r['message'] ?? ''}',
                    style: const TextStyle(fontSize: 13, height: 1.45)),
                if (subs.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () => setState(() => _open = !_open),
                    child: Text(
                      _open
                          ? tr('收起回复')
                          : '${tr('展开')} ${r['rcount'] ?? subs.length} ${tr('条回复')}',
                      style: TextStyle(fontSize: 11, color: cs.primary),
                    ),
                  ),
                  if (_open)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final s in subs)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: RichText(
                                text: TextSpan(
                                  style: TextStyle(
                                      fontSize: 12,
                                      height: 1.4,
                                      color: cs.onSurface),
                                  children: [
                                    TextSpan(
                                        text: '${s['uname'] ?? ''}：',
                                        style:
                                            TextStyle(color: cs.primary)),
                                    TextSpan(text: '${s['message'] ?? ''}'),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RelatedTile extends StatelessWidget {
  final BiliCtx ctx;
  final Map<String, dynamic> item;

  const _RelatedTile({required this.ctx, required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dur = biliDur(item['duration'] is num ? item['duration'] as num : null);
    final play = biliPlays(item['play'] is num ? item['play'] as num : null);
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BiliVideoPage(ctx: ctx, item: item),
      )),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 6, Gap.md, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: SizedBox(
                width: 132,
                height: 74,
                child: Stack(
                  children: [
                    Positioned.fill(
                        child: biliCover(context, ctx, '${item['cover'] ?? ''}',
                            radius: 0)),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Text(dur,
                          style: const TextStyle(
                              fontSize: 10, color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${item['title'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, height: 1.3)),
                  const SizedBox(height: 4),
                  Text('${item['owner'] ?? ''} · $play',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: cs.outline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
