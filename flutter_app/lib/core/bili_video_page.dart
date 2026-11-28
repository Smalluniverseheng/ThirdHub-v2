// B 站样式视频详情页（4.81.70）
//
// 顶部播放器 → 标题/UP主/统计（播放·弹幕·点赞·投币·收藏·分享）→ 简介 →
// 评论区（热门/最新，可翻页，带子回复展开）→ 相关推荐。
//
// 数据来自后端 /v1/bili/view、/v1/bili/replies、/v1/bili/related。
// 点赞/投币/收藏是**展示**：写操作需要 B 站登录态与 wbi 签名，点击会跳到 B 站原页。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'bili_module_page.dart'
    show BiliCtx, biliGet, biliPost, biliPlayRace, biliCover, biliDur, biliPlays,
    pickBiliTarget, biliHeaders;
import 'bili_actions.dart' show BiliActionResult, BiliActions;
import 'bili_auth.dart' show BiliAuth;
import 'bili_auth_page.dart' show BiliAuthPage;
import 'bili_danmaku_layer.dart';
import 'bili_subtitle.dart';
import 'bili_subtitle_parser.dart' show SubTrack;
import 'bili_dash_player.dart';
import 'bili_space_page.dart' show BiliSpacePage;
import 'design_tokens.dart';
import 'download_queue.dart' show DlJob, DownloadQueue;
import 'i18n.dart';
import 'player/th_player.dart';
import 'player/th_player_types.dart';

class BiliVideoPage extends StatefulWidget {
  final BiliCtx ctx;
  final Map<String, dynamic> item;

  const BiliVideoPage({super.key, required this.ctx, required this.item});

  /// ★4.81.121 预取：列表长按卡片就把播放地址取回来，点进去直接播。
  ///
  /// 用户原话「没有预加载，每次点击视频都要等半天」—— 那半天就是在等
  /// 详情页 loadView + playurl 两次往返。这里在列表页提前把最慢的那次做完，
  /// 缓存 2 分钟（太老的地址会过期），命中后详情页跳过 playurl 请求。
  static final Map<String, ({Map<String, dynamic> data, int at})> _prefetch =
      <String, ({Map<String, dynamic> data, int at})>{};

  static bool hasPrefetched(String bvid) {
    final e = _prefetch[bvid];
    return e != null &&
        DateTime.now().millisecondsSinceEpoch - e.at <
            const Duration(minutes: 2).inMilliseconds;
  }

  static void prefetch(BiliCtx ctx, Map<String, dynamic> item) {
    final bv = '${item['bvid'] ?? ''}';
    if (bv.isEmpty || hasPrefetched(bv)) return;
    unawaited(biliPlayRace(
            ctx, '/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(bv)}')
        .then((j) {
      if (j != null && j['url'] is String && '${j['url']}'.isNotEmpty) {
        _prefetch[bv] = (
          data: j,
          at: DateTime.now().millisecondsSinceEpoch
        );
      }
    }).catchError((_) {}));
  }

  @override
  State<BiliVideoPage> createState() => _BiliVideoPageState();
}

class _BiliVideoPageState extends State<BiliVideoPage> {
  Map<String, dynamic>? _view;
  List<Map<String, dynamic>> _pages = const [];
  int _pageIdx = 0;

  VideoPlayerController? _vp;
  // ★4.81.84 不再用 Chewie：它的控制层没有长按倍速、没有左右滑快进、
  //   没有上下滑亮度/音量，全屏还是另起路由（弹幕层直接丢失）。换成自家的
  //   ThPlayer（B 站那套手势 + 倍速面板 + 弹幕常驻）。
  String _playErr = '';

  // 弹幕
  List<Map<String, dynamic>> _dm = const [];
  bool _dmOn = true;
  String _dmCid = '';
  String _dmNote = ''; // 弹幕为空时的原因（别让用户以为功能没做）

  // 字幕（4.81.103）
  List<SubTrack> _subTracks = const [];
  int _subIdx = 0; // 当前轨；-1 表示关闭
  String _subCid = '';
  String _subNote = ''; // 无字幕原因
  bool _subTop = false;
  double _subFont = 18;

  final List<Map<String, dynamic>> _replies = [];
  int _replyPage = 1;
  int _replyTotal = 0;
  String _replySort = '2';
  bool _replyLoading = false;
  bool _replyNomore = false;
  String _replyErr = '';

  List<Map<String, dynamic>> _related = const [];
  bool _inWatchLater = false;
  // 我有没有赞过/投过币/收藏过（4.81.104：以前按钮永远是灰的，投完了也看不出来）
  bool _liked = false;
  bool _coined = false;
  bool _faved = false;
  final TextEditingController _commentCtrl = TextEditingController();
  bool _postingComment = false;
  bool _descOpen = false;

  String get _bvid => '${widget.item['bvid'] ?? ''}';

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
      // 互动状态在播放之后拉：先出画面，别让一个状态请求挡住播不了
      unawaited(_loadRelation());
    } else {
      setState(() => _playErr =
          (j == null || '${j['error'] ?? ''}'.trim().isEmpty) ? tr('失败') : '${j['error']}');
    }
    _loadReplies(reset: true);
    _loadRelated();
    BiliActions.I.isWatchLater(_bvid).then((v) {
      if (mounted) setState(() => _inWatchLater = v);
    });
  }

  /// 统一互动：未登录先提示，登录后执行并 toast 结果
  Future<void> _doAction(Future<BiliActionResult> Function() act,
      {VoidCallback? onOk}) async {
    await BiliAuth.I.load();
    if (!BiliAuth.I.loggedIn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('请先登录 B站')),
            action: SnackBarAction(label: tr('去登录'), onPressed: () {
              Navigator.push(context,
                MaterialPageRoute(builder: (_) => const BiliAuthPage()));
            })),
        );
      }
      return;
    }
    final r = await act();
    if (!mounted) return;
    if (r.ok) onOk?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r.ok ? tr('操作成功') : r.message)),
    );
  }

  /// 拉一次"我的互动状态"，让按钮能高亮。没登录就跳过（不发无谓请求）。
  Future<void> _loadRelation() async {
    await BiliAuth.I.load();
    if (!BiliAuth.I.loggedIn) return;
    final rel = await BiliActions.I.relation(_bvid);
    if (!mounted || rel.isEmpty) return;
    setState(() {
      _liked = rel['like'] == 1 || rel['like'] == true;
      _coined = ((rel['coin'] as num?)?.toInt() ?? 0) > 0;
      _faved = rel['favorite'] == true || rel['favorite'] == 1;
    });
  }

  /// 投币：B站 允许 1 或 2 枚，默认 2（和网页端一致），让用户自己选。
  Future<void> _pickCoin() async {
    final n = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(children: [
              const Icon(Icons.monetization_on_outlined, size: 18),
              const SizedBox(width: 8),
              Text(tr('投币支持一下'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
          ListTile(
            leading: const Icon(Icons.looks_one_outlined),
            title: Text(tr('投 1 枚')),
            onTap: () => Navigator.pop(c, 1),
          ),
          ListTile(
            leading: const Icon(Icons.looks_two_outlined),
            title: Text(tr('投 2 枚')),
            onTap: () => Navigator.pop(c, 2),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (n == null) return;
    await _doAction(() => BiliActions.I.coin(_bvid, multiply: n),
        onOk: () => setState(() => _coined = true));
  }

  /// 发表评论（oid 用 aid；从 item 里取，没有则用 cid）
  Future<void> _postComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    await BiliAuth.I.load();
    if (!BiliAuth.I.loggedIn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('请先登录 B站'))),
        );
      }
      return;
    }
    setState(() => _postingComment = true);
    // ★ 评论接口的 oid 是 aid，不是 cid；列表条目没有 aid，必须从详情里取
    final oid = '${_view?['aid'] ?? widget.item['aid'] ?? ''}';
    if (oid.isEmpty) {
      setState(() => _postingComment = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('视频信息还没加载好，稍后再试'))),
        );
      }
      return;
    }
    final r = await BiliActions.I.comment(oid, text);
    if (mounted) {
      setState(() => _postingComment = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r.ok ? tr('发布成功') : r.message)),
      );
      if (r.ok) {
        _commentCtrl.clear();
        _loadReplies(reset: true);
      }
    }
  }

  Future<void> _play(int idx, {int qn = 0}) async {
    final pages = _pages;
    final cid = pages.isEmpty
        ? null
        : pages[idx.clamp(0, pages.length - 1)]['cid'];
    final oldVp = _vp;
    setState(() {
      _playErr = '';
      _vp = null;
      _pageIdx = idx;
    });
    oldVp?.dispose();
    final q = StringBuffer('/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(_bvid)}');
    if (cid != null) q.write('&cid=$cid');
    // ★4.81.121：播放器里切清晰度把 qn 带回来，重新取流即可（无需退出详情页）
    if (qn > 0) q.write('&qn=$qn');
    // 命中列表页长按预取：省掉一次 playurl 往返（2 分钟有效期）
    final cached = qn == 0 ? _prefetch[_bvid] : null;
    final j = (cached != null &&
            DateTime.now().millisecondsSinceEpoch - cached.at <
                const Duration(minutes: 2).inMilliseconds)
        ? cached.data
        : await biliPlayRace(widget.ctx, q.toString());
    if (!mounted) return;
    final url = (j == null) ? '' : '${j['url'] ?? ''}';
    if (url.isEmpty) {
      setState(() => _playErr = tr('播放失败'));
      return;
    }

    // ★4.81.94 1080p DASH：音视频分离，交给 media_kit 播放器（外挂音轨同步）
    final isDash = j?['dash'] == true;
    if (isDash) {
      // 先拉弹幕+字幕再跳（与 720p 共用同一份数据）
      if (cid != null && (_dmCid != '$cid' || _dm.isEmpty)) {
        await _loadDanmaku('$cid');
      }
      if (cid != null && _subCid != '$cid') {
        await _loadSubtitle('$cid');
      }
      if (!mounted) return;
      final curQ = (j?['quality'] is num)
          ? (j?['quality'] as num).toInt()
          : 80;
      final accept = <int>[
        for (final x in (j?['acceptQuality'] as List? ?? const []))
          if (x is num) x.toInt()
      ];
      if (accept.isEmpty) accept.add(curQ);
      final picked = await Navigator.push<int>(
        context,
        MaterialPageRoute(
          builder: (_) => BiliDashPlayerPage(
            title: '${widget.item['title'] ?? ''}',
            videoUrl: url,
            audioUrl: '${j?['audioUrl'] ?? ''}',
            cid: '$cid',
            quality: curQ,
            acceptQuality: accept,
            danmaku: _dm,
            subtitleTracks: _subTracks,
          ),
        ),
      );
      // 用户在播放器里选了别的清晰度 → 带 qn 回来重开这一集
      if (picked != null && picked != curQ && mounted) {
        await _play(idx, qn: picked);
      }
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
      unawaited(vp.play());
      setState(() {
        _vp = vp;
      });
      if (cid != null) {
        _loadDanmaku('$cid');
        _loadSubtitle('$cid');
      }
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
    final errRaw = '${j == null ? '' : (j['error'] ?? '')}'.trim();
    setState(() {
      _dm = items;
      _dmNote = items.isNotEmpty
          ? ''
          : (errRaw.isEmpty ? tr('这条视频还没人发弹幕，或弹幕接口暂时不可用') : errRaw);
    });
  }

  Future<void> _loadSubtitle(String cid) async {
    if (_subCid == cid && _subTracks.isNotEmpty) return;
    _subCid = cid;
    final j = await biliGet(
      widget.ctx,
      '/v1/bili/subtitle?bvid=${Uri.encodeQueryComponent(_bvid)}'
      '&cid=${Uri.encodeQueryComponent(cid)}',
    );
    if (!mounted) return;
    final raw = ((j == null ? null : j['tracks'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => SubTrack(
              lan: '${e['lan'] ?? ''}',
              label: '${e['label'] ?? e['lan'] ?? ''}',
              url: '${e['url'] ?? ''}',
              cues: ((e['cues'] as List?) ?? const [])
                  .whereType<Map>()
                  .map((c) => Map<String, dynamic>.from(c))
                  .toList(),
            ))
        .where((t) => t.cues.isNotEmpty)
        .toList(growable: false);
    final errRaw = '${j == null ? '' : (j['error'] ?? '')}'.trim();
    setState(() {
      _subTracks = raw;
      _subIdx = raw.isEmpty ? -1 : 0;
      _subNote = raw.isEmpty
          ? (errRaw.isEmpty ? tr('这条视频没有可用字幕') : errRaw)
          : '';
    });
  }

  /// 字幕设置面板：选轨 / 字号 / 位置 / 关闭。
  Future<void> _openSubtitleSheet() async {
    if (_subTracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_subNote.isEmpty ? tr('这条视频没有可用字幕') : _subNote)),
      );
      return;
    }
    int pick = _subIdx;
    var top = _subTop;
    var font = _subFont;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c2) => StatefulBuilder(builder: (c2, setSheet) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.closed_caption_off),
                  title: Text(tr('关闭字幕')),
                  trailing: pick < 0 ? const Icon(Icons.check, size: 18) : null,
                  onTap: () => setSheet(() => pick = -1),
                ),
                for (var i = 0; i < _subTracks.length; i++)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.closed_caption),
                    title: Text(_subTracks[i].label.isEmpty
                        ? tr('字幕')
                        : _subTracks[i].label),
                    trailing: pick == i ? const Icon(Icons.check, size: 18) : null,
                    onTap: () => setSheet(() => pick = i),
                  ),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.format_size),
                  title: Text(tr('字号')),
                  trailing: Text('${font.round()}'),
                ),
                Slider(
                  value: font,
                  min: 12,
                  max: 30,
                  divisions: 18,
                  onChanged: (v) => setSheet(() => font = v),
                ),
                SwitchListTile(
                  dense: true,
                  title: Text(tr('字幕显示在顶部')),
                  value: top,
                  onChanged: (v) => setSheet(() => top = v),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(c2),
                      child: Text(tr('完成')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
    if (!mounted) return;
    setState(() {
      _subIdx = pick;
      _subTop = top;
      _subFont = font;
    });
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

  /// 选择下载落点：本机（端上直连，普通版可用）/ 后端 NAS（进阶，需自建后端）。
  Future<bool?> _pickDownloadDestination() => showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(tr('下载到哪里'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
              ListTile(
                leading: const Icon(Icons.smartphone_outlined),
                title: Text(tr('存到本机')),
                subtitle: Text(tr('离线可看，不用连接服务器')),
                onTap: () => Navigator.pop(c, true),
              ),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(tr('存到后端 NAS')),
                subtitle: Text(tr('需自建后端，用来管理服务器上的文件')),
                onTap: () => Navigator.pop(c, false),
              ),
            ],
          ),
        ),
      );

  /// 本机下载：用端上直连拿到的播放 URL + Referer，交给离线下载队列。
  Future<int> _downloadLocal({required bool all}) async {
    final pages = _pages;
    final list = all && pages.length > 1
        ? List<int>.generate(pages.length, (i) => i)
        : <int>[_pageIdx.clamp(0, pages.length - 1 < 0 ? 0 : pages.length - 1)];
    final headers = biliHeaders(widget.ctx);
    var ok = 0;
    for (final idx in list) {
      final p = pages[idx];
      final cid = '${p['cid'] ?? ''}';
      if (cid.isEmpty) continue;
      final r = await biliPlayRace(widget.ctx,
          '/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(_bvid)}&cid=${Uri.encodeQueryComponent(cid)}&qn=64');
      final url = '${r?['url'] ?? ''}';
      if (url.isEmpty) continue;
      final page = (p['page'] is num) ? (p['page'] as num).toInt() : idx + 1;
      final part = '${p['part'] ?? ''}'.trim();
      final title = part.isEmpty ? '$_bvid P$page' : '$_bvid P$page $part';
      DownloadQueue.i.submit(DlJob(
        id: DownloadQueue.i.newId(),
        kind: 'video',
        key: 'video:bili:$_bvid:$cid',
        title: title,
        payload: {
          'directUrl': url,
          'headers': headers,
          'subtitle': tr('B站'),
          'sourceId': 'bili',
        },
      ));
      ok++;
    }
    return ok;
  }

  Future<void> _download({required bool all}) async {
    final local = await _pickDownloadDestination();
    if (local == null || !mounted) return;
    if (local) {
      final n = await _downloadLocal(all: all);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(n > 0 ? trf('已加入下载队列（{n} 集）', {'n': n}) : tr('下载失败'))));
      return;
    }
    // 后端 NAS：进阶功能，走自建后端的下载服务。
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

  /// 播放器里的「选集」。页面下方那条横向列表要滚下去才看得见，
  /// 全屏时更是完全看不见 —— 播放器自己得有个入口（B 站就是这个位置）。
  Future<void> _pickPage() async {
    if (_pages.length <= 1) return;
    final i = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c2) => SafeArea(
        child: ListView.builder(
          itemCount: _pages.length,
          itemBuilder: (_, i) {
            final p = _pages[i];
            final no = p['page'] is num ? (p['page'] as num).toInt() : i + 1;
            final part = '${p['part'] ?? ''}'.trim();
            return ListTile(
              dense: true,
              leading: Text('$no', style: const TextStyle(fontSize: 12)),
              title: Text(part.isEmpty ? 'P$no' : part,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing:
                  i == _pageIdx ? const Icon(Icons.play_arrow, size: 18) : null,
              onTap: () => Navigator.pop(c2, i),
            );
          },
        ),
      ),
    );
    if (i != null && i != _pageIdx) await _play(i);
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
            tooltip: tr('字幕'),
            icon: const Icon(Icons.closed_caption_outlined),
            onPressed: _openSubtitleSheet,
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
          // 播放器（4.81.84 起用 ThPlayer：双击暂停 / 长按倍速 / 左右滑快进 /
          // 左半屏竖滑调亮度 / 右半屏竖滑调音量 / 倍速面板 / 横屏全屏，
          // 弹幕作为 overlay 常驻，全屏时不重建）
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: _vp != null
                  ? ThPlayer(
                      controller: _vp!,
                      title: title,
                      subtitle: '${owner['name'] ?? ''}',
                      overlay: Stack(
                        children: [
                          BiliDanmaku(
                            vp: _vp!,
                            items: _dm,
                            enabled: _dmOn,
                          ),
                          if (_subIdx >= 0 && _subIdx < _subTracks.length)
                            BiliSubtitleLayer(
                              vp: _vp!,
                              cues: _subTracks[_subIdx].cues,
                              top: _subTop,
                              fontSize: _subFont,
                            ),
                        ],
                      ),
                      hasDanmaku: true,
                      hasSubtitle: _subIdx >= 0,
                      onDownload: () => _download(all: false),
                      onEpisodes:
                          _pages.length > 1 ? () => _pickPage() : null,
                      moreExtras: [
                        if (_pages.length > 1)
                          ThMoreItem(
                            icon: Icons.playlist_play,
                            label: tr('选集'),
                            sub: '${_pageIdx + 1}/${_pages.length}',
                            onTap: _pickPage,
                          ),
                      ],
                    )
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
          // 弹幕拿不到时明确说一句（沉默会让人以为功能没实现）
          if (_dmNote.isNotEmpty)
            Container(
              width: double.infinity,
              color: cs.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 13, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_dmNote,
                        style: TextStyle(fontSize: 11, color: cs.outline)),
                  ),
                ],
              ),
            ),
          // 字幕拿不到时明确说一句（未登录会提示登录，不静默）
          if (_subNote.isNotEmpty)
            Container(
              width: double.infinity,
              color: cs.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.closed_caption_off, size: 13, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_subNote,
                        style: TextStyle(fontSize: 11, color: cs.outline)),
                  ),
                ],
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
                    _statBtn(
                        _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                        _fmtNum(stat['like']),
                        () => _doAction(
                            () => BiliActions.I.like(_bvid, cancel: _liked),
                            onOk: () => setState(() => _liked = !_liked)),
                        active: _liked),
                    _statBtn(
                        _coined
                            ? Icons.monetization_on
                            : Icons.monetization_on_outlined,
                        _fmtNum(stat['coin']),
                        _coined ? () {} : _pickCoin,
                        active: _coined),
                    _statBtn(
                        _faved ? Icons.star_rounded : Icons.star_border_rounded,
                        _fmtNum(stat['favorite']),
                        () => _doAction(
                            () => BiliActions.I.favorite(_bvid, cancel: _faved),
                            onOk: () => setState(() => _faved = !_faved)),
                        active: _faved),
                    // 一键三连：点赞 + 投 1 币 + 收藏，省得点三次
                    _statBtn(Icons.favorite, tr('一键三连'), () async {
                      await _doAction(() => BiliActions.I.triple(_bvid),
                          onOk: () => setState(() {
                                _liked = true;
                                _coined = true;
                                _faved = true;
                              }));
                    }, active: _liked && _coined && _faved),
                    _statBtn(Icons.share_outlined, _fmtNum(stat['share']), _openInBili),
                    _statBtn(Icons.chat_bubble_outline, _fmtNum(stat['reply']),
                        _openInBili),
                    // 稍后再看（本机，不需登录）
                    _statBtn(
                      _inWatchLater ? Icons.watch_later : Icons.watch_later_outlined,
                      tr('稍后再看'),
                      () async {
                        if (_inWatchLater) {
                          await BiliActions.I.removeWatchLater(_bvid);
                        } else {
                          await BiliActions.I.addWatchLater(_bvid);
                        }
                        if (mounted) setState(() => _inWatchLater = !_inWatchLater);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // UP 主（4.81.100：点头像/名字进 UP 主页，看资料与全部投稿）
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(Radii.sm),
                        onTap: () {
                          final mid = '${owner['mid'] ?? ''}';
                          if (mid.isEmpty || mid == 'null') {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(tr('该 UP 主暂不可查看'))));
                            return;
                          }
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => BiliSpacePage(
                                  ctx: widget.ctx, mid: mid)));
                        },
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: cs.surfaceContainerHighest,
                              child: (owner['face'] ?? '').toString().isEmpty
                                  ? Icon(Icons.person,
                                      size: 16, color: cs.outline)
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
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500)),
                            ),
                            Icon(Icons.chevron_right,
                                size: 16, color: cs.outline),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
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
          // 发表评论（登录后可用）
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 10, Gap.md, 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _commentCtrl,
                  decoration: InputDecoration(
                    hintText: tr('说点什么…'),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 8),
              _postingComment
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : FilledButton(
                      onPressed: _postComment,
                      child: Text(tr('发布')),
                    ),
            ]),
          ),
          if (_replyErr.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_replyErr,
                  style: TextStyle(fontSize: 12, color: cs.error)),
            ),
          // 评论列表
          for (final r in _replies)
            _ReplyTile(
              item: r,
              aid: '${_view?['aid'] ?? ''}',
              ctx: widget.ctx,
            ),
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

  Widget _statBtn(IconData icon, String text, VoidCallback onTap,
      {bool active = false}) {
    final cs = Theme.of(context).colorScheme;
    final fg = active ? cs.primary : cs.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? cs.primary.withValues(alpha: 0.14)
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 11, color: fg)),
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
  final String aid;
  final BiliCtx ctx;

  const _ReplyTile({required this.item, required this.aid, required this.ctx});

  @override
  State<_ReplyTile> createState() => _ReplyTileState();
}

class _ReplyTileState extends State<_ReplyTile> {
  bool _open = false;
  bool _loadingMore = false;
  List<Map<String, dynamic>> _more = const [];

  /// 展开回复：本地只带了 3 条，超过就去拉整串（B站 的 rcount 才是真实总数）
  Future<void> _toggle() async {
    final r = widget.item;
    final rcount = (r['rcount'] as num?)?.toInt() ?? 0;
    final local = ((r['replies'] as List?) ?? const []).length;
    setState(() => _open = !_open);
    if (!_open || _more.isNotEmpty || _loadingMore) return;
    if (rcount <= local || widget.aid.isEmpty) return;
    setState(() => _loadingMore = true);
    final j = await biliGet(
      widget.ctx,
      '/v1/bili/reply/reply?aid=${widget.aid}'
      '&root=${Uri.encodeQueryComponent('${r['id'] ?? ''}')}&pn=1',
    );
    if (!mounted) return;
    setState(() {
      _more = ((j == null ? null : j['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      _loadingMore = false;
    });
  }

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
                    onTap: _toggle,
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
                          if (_loadingMore)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(tr('加载中'),
                                  style: TextStyle(
                                      fontSize: 11, color: cs.outline)),
                            ),
                          for (final s in (_more.isEmpty ? subs : _more))
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
