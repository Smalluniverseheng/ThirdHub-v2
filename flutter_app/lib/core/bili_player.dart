// B 站播放器（4.81.74 重做）—— 自绘控制层 + 常驻弹幕 + 清晰度面板
//
// ── 为什么另起一个文件，而不是改原来的 BiliPlayerPage ──
//   原实现是一层 Chewie。Chewie 的全屏是**另建一条路由**（内部再包一个 Scaffold），
//   弹幕层叠在外层根本进不去全屏 —— 而「弹幕」和「全屏」恰恰是 B 站场景的两个核心诉求。
//   这里改用 video_player 自绘控制层：全屏 = 转横屏 + 隐藏系统栏，
//   播放器实例和弹幕层都不重建，进度与弹幕位置天然连续。
//
// ── 弹幕 ──
//   渲染用 canvas_danmaku（CustomPainter 直绘，组件树里不产生成百上千个 Widget）。
//   数据来自后端 GET /v1/bili/danmaku?cid=（后端已做 XML→JSON、deflate 兜底、10 分钟缓存）。
//   App 端只负责：按播放进度投放、暂停/续播联动、seek 后重排。
//
// ── 清晰度 ──
//   后端 playurl 用 fnval=1 走 durl 单文件，只能拿到 360P（有音有画、支持拖动）。
//   1080P 必须走 DASH（音视频分离，播放器要同时喂两条流并保持同步），是独立一块工程。
//   所以这里**如实呈现**：把 accept_quality 全列出来，当前可播的高亮，
//   ★2026-11-20 起「能切」是真的能切：点哪档就按 qn 重新取流（后端 fnval=0
//   免登录到 720P，登录后更高），进度保留。以前的「需 DASH」提示是过度保守。
import 'dart:async';
import 'dart:convert';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'app_log.dart';
import 'bili_direct.dart';
import 'design_tokens.dart';
import 'i18n.dart';
import 'pip.dart';
import 'player/th_player.dart';
import 'player/th_player_types.dart';

/// 清晰度码 → 人话（与后端 / bili_down_page 的 FORMAT_LABEL 对齐）
String biliQualityLabel(int q) => switch (q) {
      6 => '240P',
      16 => '360P',
      32 => '480P',
      64 => '720P',
      74 => '720P60',
      80 => '1080P',
      112 => '1080P+',
      116 => '1080P60',
      120 => '4K',
      125 => 'HDR',
      126 => '杜比视界',
      _ => q > 0 ? '${q}P' : '自动',
    };

class BiliPlayerPage extends StatefulWidget {
  const BiliPlayerPage({
    super.key,
    required this.title,
    required this.url,
    required this.apiBase,
    this.token = '',
    this.bvid = '',
    this.cid = '',
    this.quality = 0,
    this.acceptQuality = const <int>[],
  });

  final String title;

  /// 播放直链（后端已包过媒体代理，带 Referer）
  final String url;

  /// 后端地址；为空则不拉弹幕（播放仍可继续）
  final String apiBase;
  final String token;
  final String bvid;

  /// 弹幕按 cid 取
  final String cid;

  /// 当前实际拿到的清晰度码
  final int quality;

  /// 该视频可选的清晰度码（后端 accept_quality）
  final List<int> acceptQuality;

  @override
  State<BiliPlayerPage> createState() => _BiliPlayerPageState();
}

class _BiliPlayerPageState extends State<BiliPlayerPage> {
  VideoPlayerController? _vp;
  DanmakuController<int>? _dm;
  String _err = '';

  /// 当前播放地址 / 清晰度 / 可选档位。
  /// ★2026-11-20：以前直接读 widget.url / widget.quality，等于「打开时定死」，
  ///   面板里点别的档位只能弹一句「需 DASH」—— 用户说的「想选都没法选」就是这个。
  ///   现在改成可变状态，点哪档就真的换哪档。
  late String _url = widget.url;
  late int _quality = widget.quality;
  late List<int> _accept = widget.acceptQuality;
  bool _switching = false;
  Map<String, String> _hdrs = const {};

  /// 弹幕拉取失败的原因。空串 = 正常（或还没拉）。
  /// 以前这里 `catch (_) {}` 静默吞掉，弹幕不出来用户完全不知道是没拉到还是关着。
  String _dmErr = '';

  // ── 弹幕数据与投放 ──
  List<_DmItem> _dmList = const [];
  int _dmIdx = 0;
  double _lastPos = 0;
  bool _dmRunning = true;
  int _dmCount = 0; // 总条数（面板上显示）

  // ── 弹幕外观设置（持久化）──
  bool _dmOn = true;
  double _dmOpacity = 0.9;
  double _dmFontSize = 16;
  double _dmDuration = 8;
  double _dmArea = 1.0;
  bool _hideTop = false;
  bool _hideBottom = false;
  bool _hideScroll = false;

  // ── 控制层 ──
  bool _ctrl = true;
  bool _fullscreen = false;
  Timer? _ctrlTimer;

  // ── 画中画（与本地/在线播放器同一套 Pip 桥）──
  bool _pipOk = false;
  bool _pipLastPlaying = false;
  int _pipGen = 0;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _init();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dmOn = p.getBool('bili_dm_on') ?? true;
      _dmOpacity = (p.getDouble('bili_dm_opacity') ?? 0.9).clamp(0.1, 1.0);
      _dmFontSize = (p.getDouble('bili_dm_font') ?? 16).clamp(11, 30);
      _dmDuration = (p.getDouble('bili_dm_dur') ?? 8).clamp(3, 16);
      _dmArea = (p.getDouble('bili_dm_area') ?? 1.0).clamp(0.2, 1.0);
      _hideTop = p.getBool('bili_dm_hide_top') ?? false;
      _hideBottom = p.getBool('bili_dm_hide_bottom') ?? false;
      _hideScroll = p.getBool('bili_dm_hide_scroll') ?? false;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('bili_dm_on', _dmOn);
    await p.setDouble('bili_dm_opacity', _dmOpacity);
    await p.setDouble('bili_dm_font', _dmFontSize);
    await p.setDouble('bili_dm_dur', _dmDuration);
    await p.setDouble('bili_dm_area', _dmArea);
    await p.setBool('bili_dm_hide_top', _hideTop);
    await p.setBool('bili_dm_hide_bottom', _hideBottom);
    await p.setBool('bili_dm_hide_scroll', _hideScroll);
  }

  /// 后端优先、失败直连 B 站（4.81.111）：普通版用户没连 NAS 也能换清晰度/看弹幕。
  /// 返回后端同款 JSON；两端都拿不到时返回 null。
  Future<Map<String, dynamic>?> _biliJson(String path) async {
    final base = widget.apiBase.trim();
    if (base.isNotEmpty) {
      try {
        final r = await http
            .get(Uri.parse('$base$path'), headers: _hdrs)
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          if (j is Map && j['ok'] == true) return Map<String, dynamic>.from(j);
        }
      } catch (_) {}
    }
    // 后端不可用（普通版/断网）→ 端上直连
    try {
      return await biliDirect(path);
    } catch (_) {
      return null;
    }
  }

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final tok = (p.getString('token') ?? '').trim();
      _hdrs = <String, String>{
        if (tok.isNotEmpty) 'x-th-token': tok,
        if (widget.token.isNotEmpty) 'x-th-token': widget.token,
      };
      await _attach(_url);
      unawaited(_loadDanmaku());
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('播放失败')}: $e');
    }
  }

  /// 换地址重挂播放器（首次播放、切清晰度都走这里）
  Future<void> _attach(String url, {Duration? startAt}) async {
    final old = _vp;
    if (old != null) {
      old.removeListener(_tick);
      await old.dispose();
    }
    _vp = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: _hdrs,
    );
    await _vp!.initialize();
    if (startAt != null && startAt > Duration.zero) {
      final total = _vp!.value.duration;
      // 超出新时长就不 seek（不同档位时长偶尔差几十毫秒）
      if (total <= Duration.zero || startAt < total) {
        await _vp!.seekTo(startAt);
      }
    }
    _vp!.addListener(_tick);
    await _vp!.play();
    if (mounted) setState(() => _err = '');
    unawaited(_setupPip());
  }

  /// 声明「正在放视频」并接上画中画小窗里的播放/暂停按钮（4.81.110）。
  /// 缩窗由 MainActivity 做，这里只声明状态、接回调、刷按钮图标。
  Future<void> _setupPip() async {
    _pipOk = await Pip.supported();
    Pip.onToggle = () {
      final v = _vp;
      if (v == null || !v.value.isInitialized) return;
      v.value.isPlaying ? v.pause() : v.play();
    };
    _vp?.addListener(_onPipTick);
    if (!mounted) return;
    setState(() {});
    if (!_pipOk) return;
    _pipGen = await Pip.claimAuto(
        aspect: _aspect, playing: _vp?.value.isPlaying ?? false);
  }

  void _onPipTick() {
    final v = _vp;
    if (v == null || !v.value.isInitialized) return;
    if (v.value.isPlaying == _pipLastPlaying) return;
    _pipLastPlaying = v.value.isPlaying;
    Pip.updatePlaying(_pipLastPlaying);
  }

  double get _aspect {
    final v = _vp;
    if (v == null || !v.value.isInitialized) return 16 / 9;
    final a = v.value.aspectRatio;
    return a > 0 ? a : 16 / 9;
  }

  /// 真切一档清晰度：向后台按 qn 重新取流，成功才换源。
  Future<void> _switchQuality(int qn) async {
    if (_switching) return;
    if (widget.bvid.isEmpty || widget.cid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('这个视频拿不到分集信息，换不了清晰度'))));
      return;
    }
    if (qn == _quality) return;
    final keep = _vp?.value.position ?? Duration.zero;
    final wasPlaying = _vp?.value.isPlaying ?? true;
    setState(() => _switching = true);
    try {
      final j = await _biliJson('/v1/bili/playurl'
          '?bvid=${Uri.encodeQueryComponent(widget.bvid)}'
          '&cid=${Uri.encodeQueryComponent(widget.cid)}'
          '&qn=$qn');
      final u = (j != null) ? '${j['url'] ?? ''}' : '';
      if (u.isEmpty) {
        final msg = j != null ? '${j['error'] ?? ''}' : '';
        throw Exception(msg.isEmpty ? tr('这个清晰度拿不到地址') : msg);
      }
      if (!mounted) return;
      final aq = j?['acceptQuality'];
      setState(() {
        _url = u;
        _quality = (j != null ? (j['quality'] as num?)?.toInt() : null) ?? qn;
        if (aq is List && aq.isNotEmpty) {
          _accept = aq.whereType<num>().map((e) => e.toInt()).toList();
        }
      });
      await _attach(u, startAt: keep);
      if (!wasPlaying) await _vp?.pause();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(trf('已切到 {q}', {'q': biliQualityLabel(_quality)})),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${tr('切换清晰度失败')}：$e')));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 拉弹幕。失败**不阻断播放** —— 弹幕是增强，不是前提。
  Future<void> _loadDanmaku() async {
    final cid = widget.cid.trim();
    if (cid.isEmpty) return;
    try {
      final j = await _biliJson(
          '/v1/bili/danmaku?cid=${Uri.encodeComponent(cid)}');
      if (j == null || j['ok'] != true) {
        final m = j != null ? '${j['error'] ?? ''}' : '';
        AppLog.add('bili', 'warn', '弹幕为空 cid=$cid err=$m');
        if (mounted) {
          setState(() => _dmErr = m.isEmpty ? tr('这个视频没有弹幕') : m);
          _toastDm();
        }
        return;
      }
      final raw = (j['items'] as List?) ?? const [];
      final list = <_DmItem>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final t = (e['t'] as num?)?.toDouble() ?? 0;
        final mode = (e['m'] as num?)?.toInt() ?? 1;
        final color = (e['c'] as num?)?.toInt() ?? 0xFFFFFF;
        final text = '${e['x'] ?? ''}';
        if (text.isEmpty) continue;
        // 7/8 是高级弹幕与代码弹幕（带定位与脚本），本播放器不执行，直接跳过
        if (mode == 7 || mode == 8) continue;
        list.add(_DmItem(t, mode, Color(0xFF000000 | (color & 0xFFFFFF)), text));
      }
      if (!mounted) return;
      setState(() {
        _dmList = list;
        _dmCount = list.length;
        _dmIdx = 0;
        _dmErr = list.isEmpty ? tr('这个视频没有弹幕') : '';
      });
      _replayFrom(_currentPos());
    } catch (e) {
      // 弹幕失败不阻断播放，但要让用户知道为什么没有弹幕
      AppLog.add('bili', 'warn', '弹幕拉取异常 cid=$cid e=$e');
      if (mounted) {
        setState(() => _dmErr = trf('弹幕拉取失败：{e}', {'e': '$e'}));
        _toastDm();
      }
    }
  }

  /// 弹幕没出来时说一句话（带重试）。
  ///
  /// ★4.81.119：原因原来只写在「弹幕设置」面板里 —— 用户不点开那个面板就只看到
  ///   "屏幕上一条弹幕都没有"，等于没有提示。弹幕是 B 站播放器的核心功能，
  ///   失败必须当场可见且一键可重试。
  void _toastDm() {
    if (!mounted) return;
    final msg = _dmErr.isEmpty ? tr('这个视频没有弹幕') : _dmErr;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
          label: tr('重试'),
          onPressed: () {
            setState(() => _dmErr = '');
            unawaited(_loadDanmaku());
          }),
    ));
  }

  double _currentPos() =>
      (_vp?.value.position.inMilliseconds ?? 0) / 1000.0;

  /// 从指定秒数重新铺弹幕（seek 后调用）
  void _replayFrom(double pos) {
    _dm?.clear();
    // 二分找到第一个 t >= pos 的条目
    var lo = 0, hi = _dmList.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_dmList[mid].t < pos) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _dmIdx = lo;
  }

  void _emit(_DmItem it) {
    final ctl = _dm;
    if (ctl == null) return;
    ctl.addDanmaku(DanmakuContentItem<int>(
      it.text,
      color: it.color,
      type: switch (it.mode) {
        4 => DanmakuItemType.bottom,
        5 => DanmakuItemType.top,
        _ => DanmakuItemType.scroll,
      },
      extra: it.mode,
    ));
  }

  /// 播放器每帧回调：驱动弹幕投放 + 暂停联动 + seek 检测
  void _tick() {
    final vp = _vp;
    if (vp == null || !vp.value.isInitialized) return;
    final v = vp.value;
    final pos = v.position.inMilliseconds / 1000.0;

    // 播放/暂停联动弹幕动画
    if (v.isPlaying != _dmRunning) {
      _dmRunning = v.isPlaying;
      if (v.isPlaying) {
        _dm?.resume();
      } else {
        _dm?.pause();
      }
    }

    // 后退超过 1 秒 → 视为 seek，重排弹幕
    if (pos < _lastPos - 1.0) _replayFrom(pos);

    if (_dmOn) {
      // 提前 0.3s 投放，让弹幕从右侧滑入而不是"突然出现"
      while (_dmIdx < _dmList.length && _dmList[_dmIdx].t <= pos + 0.3) {
        final it = _dmList[_dmIdx++];
        // 跳过已经离屏太久的（快进时）
        if (it.t >= pos - 1.5) _emit(it);
      }
    } else if (_dmIdx < _dmList.length) {
      // 关闭弹幕时只推进游标，不绘制
      while (_dmIdx < _dmList.length && _dmList[_dmIdx].t <= pos) {
        _dmIdx++;
      }
    }
    _lastPos = pos;
  }

  // ── 控制层显示 ──
  void _toggleCtrl() {
    setState(() => _ctrl = !_ctrl);
    if (_ctrl) _armHide();
  }

  void _armHide() {
    _ctrlTimer?.cancel();
    if (!_ctrl || !(_vp?.value.isPlaying ?? false)) return;
    _ctrlTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _ctrl = false);
    });
  }

  Future<void> _togglePlay() async {
    final vp = _vp;
    if (vp == null) return;
    if (vp.value.isPlaying) {
      await vp.pause();
    } else {
      await vp.play();
    }
    _armHide();
  }

  Future<void> _seekTo(double sec) async {
    final vp = _vp;
    if (vp == null) return;
    final d = vp.value.duration;
    final target = Duration(milliseconds: (sec * 1000).round());
    await vp.seekTo(target > d ? d : target);
    _replayFrom(sec);
  }

  Future<void> _toggleFullscreen() async {
    final on = !_fullscreen;
    setState(() => _fullscreen = on);
    if (on) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _armHide();
  }

  void _applyDmOption() {
    _dm?.updateOption(DanmakuOption(
      fontSize: _dmFontSize,
      opacity: _dmOpacity,
      duration: _dmDuration,
      area: _dmArea,
      hideTop: _hideTop,
      hideBottom: _hideBottom,
      hideScroll: _hideScroll,
      strokeWidth: 1.5,
      lineHeight: 1.6,
    ));
  }

  @override
  void dispose() {
    _ctrlTimer?.cancel();
    _dm = null; // 弹幕控制器随 DanmakuScreen 一起销毁，先断开引用
    Pip.releaseAuto(_pipGen);
    Pip.onToggle = null;
    Pip.inPip.value = false;
    _vp?.removeListener(_tick);
    _vp?.removeListener(_onPipTick);
    _vp?.dispose();
    // 恢复屏幕方向与系统栏，避免退出播放器后整个 App 停在横屏
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: Pip.inPip,
        builder: (c, pip, _) {
          // 画中画里只留视频画面，别把弹幕设置/选集等整页 UI 缩成小方块（4.81.110）。
          if (pip) {
            final v = _vp;
            return Scaffold(
                backgroundColor: Colors.black,
                body: Center(
                    child: v == null || !v.value.isInitialized
                        ? const SizedBox.shrink()
                        : AspectRatio(
                            aspectRatio: _aspect, child: VideoPlayer(v))));
          }
          return _buildFull(c);
        },
      );

  Widget _buildFull(BuildContext context) {
    final vp = _vp;

    // 不用 PopScope：它的回调签名在 Flutter 3.22 / 3.24 之间改过名
    // （onPopInvoked → onPopInvokedWithResult），写哪个都可能在另一版编译不过。
    // 退出时恢复横竖屏/系统栏已由 dispose() 兜住，覆盖返回键、手势返回、
    // 以及外部 push 覆盖等所有销毁路径。
    return Scaffold(
      backgroundColor: Colors.black,
      body: _err.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child:
                    Text(_err, style: const TextStyle(color: Colors.white70)),
              ),
            )
          : (vp == null || !vp.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              // ★4.81.84 换成 ThPlayer：B 站那套手势（双击暂停、长按 2 倍速、
              //   左右滑快进、左半屏竖滑亮度、右半屏竖滑音量）+ 倍速面板 +
              //   横屏全屏。原来的自绘控制层只有单击/双击，连倍速都没有。
              : ThPlayer(
                  controller: vp,
                  title: widget.title,
                  qualities: _accept
                      .map((q) => ThQuality(biliQualityLabel(q), tag: '$q'))
                      .toList(growable: false),
                  qualityIndex: _accept.indexOf(_quality) < 0
                      ? 0
                      : _accept.indexOf(_quality),
                  onQuality: (i) {
                    if (i >= 0 && i < _accept.length) _switchQuality(_accept[i]);
                  },
                  // 画中画（4.81.110）：设备支持才显示按钮，复用本地播放器同一套 Pip 桥。
                  onPip: _pipOk
                      ? () async {
                          final ok = await Pip.enter(
                              aspect: _aspect,
                              playing: vp.value.isPlaying);
                          if (!ok && mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(tr('当前状态进不了画中画'))));
                        }
                      : null,
                  hasDanmaku: true,
                  overlay: IgnorePointer(
                    child: DanmakuScreen<int>(
                      createdController: (e) {
                        _dm = e;
                        _applyDmOption();
                        _replayFrom(_currentPos());
                      },
                      option: DanmakuOption(
                        fontSize: _dmFontSize,
                        opacity: _dmOpacity,
                        duration: _dmDuration,
                        area: _dmArea,
                        hideTop: _hideTop,
                        hideBottom: _hideBottom,
                        hideScroll: _hideScroll,
                        strokeWidth: 1.5,
                        lineHeight: 1.6,
                      ),
                    ),
                  ),
                  moreExtras: [
                    ThMoreItem(
                      icon: Icons.tune,
                      label: tr('弹幕设置'),
                      sub: _dmCount > 0 ? '$_dmCount' : '',
                      onTap: _openDanmakuSheet,
                    ),
                  ],
                )),
    );
  }

  Widget _topBar() => Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: SafeArea(
          bottom: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            color: Colors.black.withValues(alpha: 0.35),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: tr('返回'),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ]),
          ),
        ),
      );

  Widget _bottomBar() {
    final vp = _vp!;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm,
            Gap.sm + MediaQuery.of(context).padding.bottom),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: 0.72),
            ],
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── 进度条 ──
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: vp,
            builder: (_, v, __) {
              final total = v.duration.inMilliseconds.toDouble();
              final cur = v.position.inMilliseconds.toDouble();
              return Row(children: [
                Text(_mmss(v.position),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11)),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 5),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: total <= 0 ? 0 : cur.clamp(0, total),
                      max: total <= 0 ? 1 : total,
                      onChanged: (x) => _seekTo(x / 1000),
                    ),
                  ),
                ),
                Text(_mmss(v.duration),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11)),
              ]);
            },
          ),
          // ── 按钮行 ──
          Row(children: [
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: vp,
              builder: (_, v, __) => IconButton(
                icon: Icon(
                    v.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white),
                iconSize: 30,
                onPressed: _togglePlay,
              ),
            ),
            // 弹幕开关
            _pill(
              icon: _dmOn
                  ? Icons.subtitles
                  : Icons.subtitles_off_outlined,
              label: _dmOn ? tr('弹幕开') : tr('弹幕关'),
              on: _dmOn,
              onTap: () {
                setState(() {
                  _dmOn = !_dmOn;
                  // 关闭时 DanmakuScreen 会被移除、它的 State 随之销毁，
                  // 手里的 controller 立刻失效 —— 必须置空，否则下一次
                  // _replayFrom() 的 clear() 会打在已销毁的对象上。
                  if (!_dmOn) _dm = null;
                });
                _savePrefs();
                if (_dmOn) _replayFrom(_currentPos());
                _armHide();
              },
            ),
            // 弹幕设置
            _pill(
              icon: Icons.tune,
              label: tr('弹幕设置'),
              on: false,
              onTap: _openDanmakuSheet,
            ),
            const Spacer(),
            // 清晰度
            _pill(
              icon: Icons.high_quality_outlined,
              label: biliQualityLabel(_quality),
              on: false,
              onTap: _openQualitySheet,
            ),
            IconButton(
              icon: Icon(
                  _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white),
              onPressed: _toggleFullscreen,
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _pill({
    required IconData icon,
    required String label,
    required bool on,
    required VoidCallback onTap,
  }) =>
      InkWell(
        borderRadius: Radii.smAll,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 16,
                color: on ? Theme.of(context).colorScheme.primary : Colors.white70),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color:
                        on ? Theme.of(context).colorScheme.primary : Colors.white70)),
          ]),
        ),
      );

  static String _mmss(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ── 弹幕设置 ──
  void _openDanmakuSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg))),
      builder: (c) => StatefulBuilder(builder: (c, setSheet) {
        void upd(VoidCallback fn) {
          setSheet(fn);
          setState(fn);
          _applyDmOption();
          _savePrefs();
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md,
                Gap.md + MediaQuery.of(c).viewInsets.bottom),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: Gap.md),
                        decoration: BoxDecoration(
                            color: Theme.of(c).dividerColor,
                            borderRadius: Radii.pillAll)),
                  ),
                  Row(children: [
                    Text(tr('弹幕设置'),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text(_dmErr.isEmpty ? trf('共 {n} 条', {'n': _dmCount}) : _dmErr,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 11,
                            color: _dmErr.isEmpty
                                ? Colors.grey
                                : Theme.of(c).colorScheme.error)),
                  ]),
                  const SizedBox(height: Gap.sm),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('显示弹幕'), style: const TextStyle(fontSize: 13)),
                    value: _dmOn,
                    onChanged: (v) {
                      upd(() {
                        _dmOn = v;
                        if (!v) _dm = null; // 同上：弹幕层移除后控制器即失效
                      });
                      if (v) _replayFrom(_currentPos());
                    },
                  ),
                  _sliderRow(c, '透明度', _dmOpacity, 0.1, 1.0, (v) {
                    upd(() => _dmOpacity = v);
                  }, _dmOpacity.toStringAsFixed(1)),
                  _sliderRow(c, '字号', _dmFontSize, 11, 30, (v) {
                    upd(() => _dmFontSize = v);
                  }, _dmFontSize.round().toString()),
                  _sliderRow(c, '滚动速度', 16 - _dmDuration, 0, 13, (v) {
                    // 面板上"数值越大越快"，内部 duration 越小越快
                    upd(() => _dmDuration = 16 - v);
                  }, (16 - _dmDuration).round().toString()),
                  _sliderRow(c, '显示区域', _dmArea, 0.2, 1.0, (v) {
                    upd(() => _dmArea = v);
                  }, '${(_dmArea * 100).round()}%'),
                  const Divider(height: Gap.lg),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    FilterChip(
                      label: Text(tr('屏蔽顶部'), style: const TextStyle(fontSize: 12)),
                      selected: _hideTop,
                      onSelected: (v) => upd(() => _hideTop = v),
                    ),
                    FilterChip(
                      label: Text(tr('屏蔽底部'), style: const TextStyle(fontSize: 12)),
                      selected: _hideBottom,
                      onSelected: (v) => upd(() => _hideBottom = v),
                    ),
                    FilterChip(
                      label: Text(tr('屏蔽滚动'), style: const TextStyle(fontSize: 12)),
                      selected: _hideScroll,
                      onSelected: (v) => upd(() => _hideScroll = v),
                    ),
                  ]),
                  const SizedBox(height: Gap.md),
                ]),
          ),
        );
      }),
    );
  }

  Widget _sliderRow(BuildContext c, String label, double value, double min,
          double max, ValueChanged<double> onChanged, String shown) =>
      Row(children: [
        SizedBox(
            width: 64,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.grey))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
            width: 44,
            child: Text(shown,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12))),
      ]);

  // ── 清晰度 ──
  void _openQualitySheet() {
    final list = _accept.isEmpty
        ? <int>[if (_quality > 0) _quality]
        : _accept;
    final sorted = [...list]..sort((a, b) => b.compareTo(a));
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('清晰度'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                for (final q in sorted)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      q == _quality
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: q == _quality
                          ? Theme.of(c).colorScheme.primary
                          : Colors.grey,
                    ),
                    title: Text(biliQualityLabel(q),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: q == _quality
                                ? FontWeight.w700
                                : FontWeight.w400)),
                    subtitle: q == _quality
                        ? Text(tr('当前播放'),
                            style: const TextStyle(
                                fontSize: 10.5, color: Colors.grey))
                        : null,
                    trailing: (q != _quality && _switching)
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                    onTap: () {
                      Navigator.pop(c);
                      if (q != _quality) unawaited(_switchQuality(q));
                    },
                  ),
                const SizedBox(height: Gap.sm),
                Text(
                  tr('档位由 B 站按当前登录态给出：没登录通常到 720P，登录后更多。切档会重新取流，进度保留。'),
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: Theme.of(c).hintColor),
                ),
              ]),
        ),
      ),
    );
  }
}

class _DmItem {
  _DmItem(this.t, this.mode, this.color, this.text);
  final double t; // 秒
  final int mode; // B 站弹幕模式：1/2/3 滚动，4 底部，5 顶部
  final Color color;
  final String text;
}
