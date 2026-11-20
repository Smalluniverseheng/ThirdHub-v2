// 第三方聚合 · 播放器外壳 ThPlayer（4.81.81）
//
// ── 为什么自己写 ───────────────────────────────────────────────
// 原来在线影视页用的是 Chewie 的默认 UI：中间一个大播放键、底下一条进度条、
// 两个 ±10 秒圆钮。那是"能播"的最低标准，不是"用来看视频"的东西。
// 用户原话：「一点都不像是用来看视频的」「各种设置都没有」「各种清晰度的
// 切换也没有」——这次照 YouTube / B站 / Netflix 客户端的共同做法重做：
//
//   单击        显隐控制层（★不再是点一下就暂停）
//   双击左/右    后退 / 前进 N 秒，带圆形波纹 + 秒数角标
//   双击中间     播放 / 暂停
//   横滑        调进度：跟手预览、松手才 seek
//   竖滑        左半屏亮度 / 右半屏音量，带竖条 HUD
//   长按        临时加速（默认 2x），松手还原
//   锁定        防误触，屏幕只剩一个锁图标
//   全屏        横竖屏切换 + 沉浸式，退出时恢复系统 UI
//   进度条      缓冲段 + 可拖手柄 + 拖动时间气泡 + 快进键
//   底栏        上/下集、倍速、清晰度、选集、更多、锁定、全屏
//   更多        画面比例、循环、双击步长、自动连播、弹幕/字幕开关
//
// ── 边界 ─────────────────────────────────────────────────────
// 本文件**不取流、不管下载、不管进度记忆**。它只吃一个已初始化的
// VideoPlayerController，把"看"这件事做到位。取流/下载/续播仍在调用方。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';

import '../design_tokens.dart';
import '../haptic.dart';
import '../i18n.dart';
import 'th_player_panels.dart';
import 'th_player_types.dart';

class ThPlayer extends StatefulWidget {
  const ThPlayer({
    super.key,
    required this.controller,
    required this.title,
    this.subtitle = '',
    this.qualities = const [],
    this.qualityIndex = 0,
    this.onQuality,
    this.onPrev,
    this.onNext,
    this.onEpisodes,
    this.onDownload,
    this.onPip,
    this.extraActions = const [],
    this.moreExtras = const [],
    this.overlay,
    this.hasDanmaku = false,
    this.hasSubtitle = false,
    this.initialSpeed = 1.0,
    this.initialConfig = const ThMoreConfig(),
    this.onConfigChanged,
    this.onSpeedChanged,
    this.aspectOverride,
    this.showFullscreenBtn = true,
    this.autoHide = const Duration(seconds: 3),
  });

  final VideoPlayerController controller;
  final String title;
  final String subtitle;

  /// 可选清晰度。空列表 = 不显示清晰度按钮（别给个点了没用的假菜单）。
  final List<ThQuality> qualities;
  final int qualityIndex;
  final ValueChanged<int>? onQuality;

  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onEpisodes;
  final VoidCallback? onDownload;
  final VoidCallback? onPip;

  final List<Widget> extraActions;
  final List<ThMoreItem> moreExtras;

  /// 弹幕层（B 站用）。null = 没有弹幕，底栏也不显示弹幕开关。
  final Widget? overlay;
  final bool hasDanmaku;

  /// 是否有字幕可选（本地视频用）。
  final bool hasSubtitle;

  final double initialSpeed;
  final ThMoreConfig initialConfig;
  final ValueChanged<ThMoreConfig>? onConfigChanged;
  final ValueChanged<double>? onSpeedChanged;

  /// 强制画面比例（null = 用视频自带的）。
  final double? aspectOverride;
  final bool showFullscreenBtn;
  final Duration autoHide;

  @override
  State<ThPlayer> createState() => _ThPlayerState();
}

class _ThPlayerState extends State<ThPlayer> with TickerProviderStateMixin {
  // ── 控制层 ──
  bool _show = true;
  Timer? _hideTimer;

  // ── 锁定 ──
  bool _locked = false;

  // ── 播放参数 ──
  late double _speed = widget.initialSpeed;
  late ThMoreConfig _cfg = widget.initialConfig;
  late int _qi = widget.qualityIndex;
  bool _danmakuOn = true;

  // ── 拖动进度 ──
  bool _seeking = false;
  Duration _seekTarget = Duration.zero;

  // ── 竖滑 ──
  double? _brightness;
  double? _volume;
  bool _levelRight = true;
  bool _leveling = false;

  // ── 长按加速 ──
  bool _boosting = false;
  double _boostPrior = 1.0;

  // ── HUD ──
  String _hudText = '';
  IconData? _hudIcon;
  Timer? _hudTimer;
  double? _hudLevel;
  bool _hudLeft = false;

  // ── 双击波纹 ──
  late final AnimationController _ripple;
  int _tapSide = 0; // -1 左 / 0 中 / 1 右

  Timer? _tick;
  bool _initialized = false;

  VideoPlayerController get _vc => widget.controller;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 420));
    _initialized = _vc.value.isInitialized;
    _vc.addListener(_onTick);
    _armHide();
    if (_initialized && _speed != 1.0) {
      unawaited(_vc.setPlaybackSpeed(_speed));
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _tick?.cancel();
    _ripple.dispose();
    _vc.removeListener(_onTick);
    _restoreSystemUi();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    final v = _vc.value;
    if (v.isInitialized != _initialized) {
      setState(() => _initialized = v.isInitialized);
    } else {
      // 只重绘进度，不做整树重建
      setState(() {});
    }
  }

  // ══════════════════════════════ 控制层显隐 ══════════════════════════════

  void _armHide() {
    _hideTimer?.cancel();
    if (!_show) return;
    _hideTimer = Timer(widget.autoHide, () {
      if (!mounted) return;
      if (_seeking || _leveling || _locked) return;
      setState(() => _show = false);
    });
  }

  void _toggleControls() {
    if (_locked) {
      // 锁定时单击只闪一下锁图标，防止误操作
      _flashHud(Icons.lock_outline, tr('已锁定，先解锁'));
      return;
    }
    setState(() => _show = !_show);
    if (_show) _armHide();
    Haptic.tap();
  }

  void _flashHud(IconData icon, String text, {double? level, bool left = false}) {
    _hudTimer?.cancel();
    setState(() {
      _hudIcon = icon;
      _hudText = text;
      _hudLevel = level;
      _hudLeft = left;
    });
    _hudTimer = Timer(const Duration(milliseconds: 620), () {
      if (mounted) {
        setState(() {
          _hudText = '';
          _hudIcon = null;
          _hudLevel = null;
        });
      }
    });
  }

  // ══════════════════════════════ 播放操作 ══════════════════════════════

  Future<void> _togglePlay() async {
    if (!_vc.value.isInitialized) return;
    Haptic.tap();
    if (_vc.value.isPlaying) {
      await _vc.pause();
      _hideTimer?.cancel(); // 暂停时不自动隐藏控制层
      if (mounted) setState(() => _show = true);
    } else {
      await _vc.play();
      _armHide();
    }
    if (mounted) setState(() {});
  }

  void _seekBy(int seconds, {bool forward = true}) {
    if (!_vc.value.isInitialized) return;
    final total = _vc.value.duration;
    final t = _vc.value.position + Duration(seconds: forward ? seconds : -seconds);
    final clamped = t < Duration.zero
        ? Duration.zero
        : (t > total ? total : t);
    unawaited(_vc.seekTo(clamped));
    Haptic.tap();
    // 波纹 + 角标
    _tapSide = forward ? 1 : -1;
    _ripple.forward(from: 0);
    _flashHud(
        thSeekIcon(seconds, forward: forward),
        trf('{n} 秒', {'n': seconds}),
        left: !forward);
  }

  Future<void> _setSpeed(double s) async {
    _speed = s;
    if (_vc.value.isInitialized) await _vc.setPlaybackSpeed(s);
    widget.onSpeedChanged?.call(s);
    if (mounted) setState(() {});
  }

  void _openSpeedSheet() async {
    _hideTimer?.cancel();
    final s = await showThSpeedSheet(context, _speed);
    if (!mounted) return;
    if (s != null) await _setSpeed(s);
    _armHide();
  }

  void _openQualitySheet() async {
    if (widget.qualities.isEmpty) return;
    _hideTimer?.cancel();
    final i = await showThQualitySheet(context, widget.qualities, _qi);
    if (!mounted) return;
    if (i != null && i != _qi) {
      setState(() => _qi = i);
      widget.onQuality?.call(i);
    }
    _armHide();
  }

  Future<void> _openMore() async {
    _hideTimer?.cancel();
    await showThMoreSheet(
      context,
      cur: _cfg,
      hasDanmaku: widget.hasDanmaku,
      hasSubtitle: widget.hasSubtitle,
      extras: [
        if (widget.onEpisodes != null)
          ThMoreItem(
              icon: Icons.grid_view,
              label: tr('选集'),
              sub: tr('看整部片的集数'),
              onTap: widget.onEpisodes),
        if (widget.onDownload != null)
          ThMoreItem(
              icon: Icons.download_outlined,
              label: tr('下载本集'),
              sub: tr('下完断网也能看'),
              onTap: widget.onDownload),
        if (widget.onPip != null)
          ThMoreItem(
              icon: Icons.picture_in_picture_alt,
              label: tr('画中画'),
              sub: tr('切到后台也能接着看'),
              onTap: widget.onPip),
        ...widget.moreExtras,
      ],
      onChanged: (v) {
        setState(() {
          _cfg = v;
          _danmakuOn = v.danmaku;
        });
        widget.onConfigChanged?.call(v);
      },
    );
    if (mounted) _armHide();
  }

  // ══════════════════════════════ 全屏 ══════════════════════════════

  Future<void> _toggleFullscreen() async {
    Haptic.tap();
    final land = MediaQuery.of(context).orientation == Orientation.landscape;
    if (land) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (mounted) setState(() {});
    _armHide();
  }

  void _restoreSystemUi() {
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  // ══════════════════════════════ 亮度 / 音量 ══════════════════════════════

  Future<void> _loadLevels() async {
    if (_brightness == null) {
      try {
        _brightness = await ScreenBrightness.instance.application;
      } catch (_) {
        _brightness = 0.5;
      }
    }
    if (_volume == null) {
      try {
        _volume = await VolumeController.instance.getVolume();
      } catch (_) {
        _volume = 0.5;
      }
    }
  }

  Future<void> _applyLevel(double v, {required bool right}) async {
    final val = v.clamp(0.0, 1.0);
    if (right) {
      _volume = val;
      try {
        await VolumeController.instance.setVolume(val);
      } catch (_) {}
    } else {
      _brightness = val;
      try {
        await ScreenBrightness.instance.setApplicationScreenBrightness(val);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _hudLeft = !right;
      _hudLevel = val;
      _hudIcon = right
          ? (val <= 0
              ? Icons.volume_off
              : val < 0.5
                  ? Icons.volume_down
                  : Icons.volume_up)
          : (val < 0.5 ? Icons.brightness_low : Icons.brightness_high);
      _hudText = '${(val * 100).round()}%';
    });
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() {
          _hudText = '';
          _hudIcon = null;
          _hudLevel = null;
        });
      }
    });
  }

  // ══════════════════════════════ 手势 ══════════════════════════════

  Widget _gestureLayer() {
    final w = MediaQuery.of(context).size.width;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTapDown: (d) {
          _tapSide = d.localPosition.dx < w / 3
              ? -1
              : (d.localPosition.dx > w * 2 / 3 ? 1 : 0);
        },
        onDoubleTap: () {
          if (_locked) return;
          if (_tapSide == 0) {
            unawaited(_togglePlay());
          } else {
            _seekBy(_cfg.seekStep, forward: _tapSide > 0);
          }
        },
        onLongPressStart: (_) async {
          if (_locked || !_vc.value.isInitialized) return;
          _boostPrior = _speed;
          _boosting = true;
          await _vc.setPlaybackSpeed(2.0);
          if (!mounted) return;
          setState(() {});
          _flashHud(Icons.fast_forward, tr('2 倍速中，松手恢复'));
        },
        onLongPressEnd: (_) async {
          if (!_boosting) return;
          _boosting = false;
          await _vc.setPlaybackSpeed(_boostPrior);
          if (!mounted) return;
          setState(() {});
          _hudTimer?.cancel();
          setState(() {
            _hudText = '';
            _hudIcon = null;
          });
        },
        onHorizontalDragStart: (_) {
          if (_locked || !_vc.value.isInitialized) return;
          _hideTimer?.cancel();
          setState(() {
            _seeking = true;
            _seekTarget = _vc.value.position;
            _show = true;
          });
        },
        onHorizontalDragUpdate: (d) {
          if (!_seeking) return;
          final total = _vc.value.duration.inMilliseconds;
          if (total <= 0) return;
          // 半屏宽 ≈ 全片的 1/4，手感接近 B站
          final dx = d.primaryDelta ?? 0;
          final deltaMs = (dx / (w / 2) * total / 4).round();
          final next = _seekTarget.inMilliseconds + deltaMs;
          setState(() => _seekTarget =
              Duration(milliseconds: next.clamp(0, total)));
        },
        onHorizontalDragEnd: (_) {
          if (!_seeking) return;
          final t = _seekTarget;
          setState(() => _seeking = false);
          unawaited(_vc.seekTo(t));
          Haptic.tap();
          _armHide();
        },
        onVerticalDragStart: (d) async {
          if (_locked) return;
          final box = context.findRenderObject() as RenderBox?;
          _levelRight = box == null
              ? true
              : d.globalPosition.dx > box.size.width / 2;
          await _loadLevels();
          if (!mounted) return;
          _hideTimer?.cancel();
          setState(() => _leveling = true);
        },
        onVerticalDragUpdate: (d) {
          if (!_leveling) return;
          final h = MediaQuery.of(context).size.height;
          final dy = d.primaryDelta ?? 0;
          final cur = (_levelRight ? (_volume ?? 0.5) : (_brightness ?? 0.5)) -
              dy / (h * 0.7);
          unawaited(_applyLevel(cur, right: _levelRight));
        },
        onVerticalDragEnd: (_) {
          if (!_leveling) return;
          setState(() => _leveling = false);
          _armHide();
        },
      ),
    );
  }

  // ══════════════════════════════ 画面 ══════════════════════════════

  Widget _video() {
    final v = _vc.value;
    final w = v.size.width <= 0 ? 16.0 : v.size.width;
    final h = v.size.height <= 0 ? 9.0 : v.size.height;
    final fit = _cfg.fit.boxFit;
    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(
        child: FittedBox(
          fit: fit,
          alignment: Alignment.center,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: w,
            height: h,
            child: VideoPlayer(_vc),
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════ 顶栏 ══════════════════════════════

  Widget _topBar() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xB3000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  tooltip: tr('返回'),
                  onPressed: () {
                    _restoreSystemUi();
                    Navigator.maybePop(context);
                  },
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                      if (widget.subtitle.isNotEmpty)
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                ...widget.extraActions,
                IconButton(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  tooltip: tr('更多'),
                  onPressed: _openMore,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════ 中部三键 ══════════════════════════════

  Widget _centerButtons() {
    final playing = _vc.value.isPlaying;
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _roundBtn(
            icon: thSeekIcon(_cfg.seekStep, forward: false),
            label: '${_cfg.seekStep}',
            onTap: () => _seekBy(_cfg.seekStep, forward: false),
          ),
          const SizedBox(width: Gap.xl),
          // 中间大按钮：YouTube 的圆形半透明底
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.22), width: 1),
              ),
              child: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 38,
              ),
            ),
          ),
          const SizedBox(width: Gap.xl),
          _roundBtn(
            icon: thSeekIcon(_cfg.seekStep, forward: true),
            label: '${_cfg.seekStep}',
            onTap: () => _seekBy(_cfg.seekStep),
          ),
        ],
      ),
    );
  }

  Widget _roundBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        height: 52,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 30),
            // 圆环里的秒数由图标自带数字；自定义步长（如 55 秒）时图标不带数字，
            // 用角标补上，避免"两个尖括号不知道退多少"
            if (label != '5' && label != '10' && label != '30')
              Positioned(
                bottom: 6,
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700)),
              ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════ 底栏 ══════════════════════════════

  Widget _bottomBar() {
    final v = _vc.value;
    final pos = _seeking ? _seekTarget : v.position;
    final total = v.duration;
    final buffered = _buffered(v);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 26, Gap.sm, Gap.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 进度条 + 时间
                Row(
                  children: [
                    Text(thClock(pos),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontFeatures: [FontFeature.tabularFigures()])),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: _ProgressBar(
                        position: pos,
                        total: total,
                        buffered: buffered,
                        enabled: v.isInitialized,
                        onSeek: (d) => unawaited(_vc.seekTo(d)),
                        onDragStart: () {
                          _hideTimer?.cancel();
                          setState(() {
                            _seeking = true;
                            _seekTarget = v.position;
                          });
                        },
                        onDragUpdate: (d) =>
                            setState(() => _seekTarget = d),
                        onDragEnd: () {
                          final t = _seekTarget;
                          setState(() => _seeking = false);
                          unawaited(_vc.seekTo(t));
                          Haptic.tap();
                          _armHide();
                        },
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    Text(thClock(total),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11.5,
                            fontFeatures: [FontFeature.tabularFigures()])),
                    const SizedBox(width: Gap.xs),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                // 工具排
                Row(
                  children: [
                    if (widget.onPrev != null || widget.onNext != null) ...[
                      _toolBtn(
                        icon: Icons.skip_previous,
                        tip: tr('上一集'),
                        onTap: widget.onPrev,
                      ),
                      _toolBtn(
                        icon: Icons.skip_next,
                        tip: tr('下一集'),
                        onTap: widget.onNext,
                      ),
                    ],
                    _toolBtn(
                      icon: Icons.speed,
                      label: thSpeedLabel(_speed),
                      tip: tr('播放速度'),
                      onTap: _openSpeedSheet,
                    ),
                    if (widget.qualities.isNotEmpty)
                      _toolBtn(
                        icon: Icons.high_quality_outlined,
                        label: widget.qualities[
                                _qi.clamp(0, widget.qualities.length - 1)]
                            .label,
                        tip: tr('清晰度'),
                        onTap: _openQualitySheet,
                      ),
                    if (widget.onEpisodes != null)
                      _toolBtn(
                        icon: Icons.grid_view,
                        tip: tr('选集'),
                        onTap: widget.onEpisodes,
                      ),
                    if (widget.hasDanmaku)
                      _toolBtn(
                        icon: _danmakuOn
                            ? Icons.subtitles
                            : Icons.subtitles_off,
                        tip: _danmakuOn ? tr('关闭弹幕') : tr('打开弹幕'),
                        active: _danmakuOn,
                        onTap: () {
                          setState(() {
                            _danmakuOn = !_danmakuOn;
                            _cfg = _cfg.copyWith(danmaku: _danmakuOn);
                          });
                          widget.onConfigChanged?.call(_cfg);
                          Haptic.tap();
                        },
                      ),
                    _toolBtn(
                      icon: Icons.tune,
                      tip: tr('更多设置'),
                      onTap: _openMore,
                    ),
                    const Spacer(),
                    _toolBtn(
                      icon: _locked ? Icons.lock : Icons.lock_open,
                      tip: _locked ? tr('解锁') : tr('锁定画面'),
                      active: _locked,
                      onTap: () {
                        setState(() {
                          _locked = !_locked;
                          if (_locked) _show = false;
                        });
                        if (!_locked) _armHide();
                        Haptic.tap();
                      },
                    ),
                    if (widget.showFullscreenBtn)
                      _toolBtn(
                        icon: MediaQuery.of(context).orientation ==
                                Orientation.landscape
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        tip: tr('全屏'),
                        onTap: _toggleFullscreen,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Duration _buffered(VideoPlayerValue v) {
    if (v.buffered.isEmpty) return Duration.zero;
    var max = Duration.zero;
    for (final r in v.buffered) {
      if (r.end > max) max = r.end;
    }
    return max;
  }

  Widget _toolBtn({
    required IconData icon,
    String? label,
    required String tip,
    VoidCallback? onTap,
    bool active = false,
  }) {
    final w = label == null ? 40.0 : 58.0;
    return SizedBox(
      width: w,
      height: 36,
      child: Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onTap == null
              ? null
              : () {
                  Haptic.tap();
                  onTap();
                },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 19,
                  color: onTap == null
                      ? Colors.white24
                      : (active ? const Color(0xFF6EA8FF) : Colors.white)),
              if (label != null) ...[
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5,
                        color:
                            active ? const Color(0xFF6EA8FF) : Colors.white),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════ HUD ══════════════════════════════

  Widget _hud() {
    if (_hudText.isEmpty && _hudLevel == null) return const SizedBox.shrink();
    // 音量/亮度：贴着对应侧的竖条
    if (_hudLevel != null) {
      return Positioned.fill(
        child: IgnorePointer(
          child: Align(
            alignment: _hudLeft ? Alignment.centerLeft : Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 34),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_hudIcon, color: Colors.white, size: 22),
                  const SizedBox(height: 6),
                  // 竖条：下往上填
                  Container(
                    width: 6,
                    height: 110,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _hudLevel!.clamp(0.0, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(_hudText,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    // 快进/退：对应侧圆环
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Align(
              alignment: _hudLeft ? Alignment.centerLeft : Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: AnimatedBuilder(
                  animation: _ripple,
                  builder: (_, __) {
                    final t = Curves.easeOut.transform(_ripple.value);
                    return Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black
                            .withValues(alpha: 0.30 * (1 - _ripple.value)),
                        border: Border.all(
                          color: Colors.white
                              .withValues(alpha: 0.55 * (1 - t)),
                          width: 2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(_hudIcon, color: Colors.white, size: 26),
                          Text(_hudText,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 拖动进度时中央的时间气泡
  Widget _seekBubble() {
    if (!_seeking) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.74),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(thClock(_seekTarget),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()])),
                Text('/ ${thClock(_vc.value.duration)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════ build ══════════════════════════════

  @override
  Widget build(BuildContext context) {
    final ctrlVisible = _show && !_locked;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_initialized)
            const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: Colors.white70),
              ),
            )
          else
            _video(),

          // 弹幕 / 字幕层（不吃手势）
          if (widget.overlay != null && (!widget.hasDanmaku || _danmakuOn))
            Positioned.fill(
                child: IgnorePointer(child: widget.overlay!)),

          // 手势层必须在控制层之下，否则按钮点不到
          _gestureLayer(),

          // 控制层
          AnimatedOpacity(
            opacity: ctrlVisible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: IgnorePointer(
              ignoring: !ctrlVisible,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _topBar(),
                  _centerButtons(),
                  _bottomBar(),
                ],
              ),
            ),
          ),

          _seekBubble(),
          _hud(),

          // 锁定态：右下角留一个常驻的锁，点一下解锁
          if (_locked)
            Positioned(
              right: 14,
              bottom: 24,
              child: SafeArea(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _locked = false);
                    _armHide();
                    Haptic.tap();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Icon(Icons.lock,
                        color: Colors.white70, size: 19),
                  ),
                ),
              ),
            ),

          // 暂停时中间的播放按钮（控制层隐藏也能一点就播）
          if (_initialized && !_vc.value.isPlaying && !ctrlVisible)
            Center(
              child: GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.42),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow,
                      color: Colors.white, size: 36),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ══════════════════════════════ 进度条 ══════════════════════════════
//
// 不用 Slider：Slider 的拇指在深色视频上太抢眼，且没法画缓冲段。
// 自绘一条：轨道 + 缓冲 + 已播 + 手柄，拖动时变粗。
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.position,
    required this.total,
    required this.buffered,
    required this.enabled,
    required this.onSeek,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final Duration position;
  final Duration total;
  final Duration buffered;
  final bool enabled;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onDragStart;
  final ValueChanged<Duration> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  bool _dragging = false;

  double _frac(Duration d) {
    final t = widget.total.inMilliseconds;
    if (t <= 0) return 0;
    return (d.inMilliseconds / t).clamp(0.0, 1.0);
  }

  Duration _at(double dx, double width) {
    final t = widget.total.inMilliseconds;
    if (t <= 0 || width <= 0) return Duration.zero;
    return Duration(milliseconds: (dx / width * t).round().clamp(0, t));
  }

  @override
  Widget build(BuildContext context) {
    final played = _frac(widget.position);
    final buf = _frac(widget.buffered);
    return LayoutBuilder(
      builder: (c, box) {
        final w = box.maxWidth;
        final h = _dragging ? 26.0 : 18.0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.enabled
              ? (d) {
                  final t = _at(d.localPosition.dx, w);
                  widget.onSeek(t);
                  Haptic.tap();
                }
              : null,
          onHorizontalDragStart: widget.enabled
              ? (d) {
                  setState(() => _dragging = true);
                  widget.onDragStart();
                  widget.onDragUpdate(_at(d.localPosition.dx, w));
                }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (d) => widget.onDragUpdate(_at(d.localPosition.dx, w))
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  setState(() => _dragging = false);
                  widget.onDragEnd();
                }
              : null,
          child: SizedBox(
            height: h,
            child: Center(
              child: SizedBox(
                height: _dragging ? 6 : 3.5,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 轨道
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    // 缓冲
                    FractionallySizedBox(
                      widthFactor: buf,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white38,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    // 已播
                    FractionallySizedBox(
                      widthFactor: played,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF4D4F),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    // 手柄
                    Positioned(
                      left: (played * w - (_dragging ? 9 : 6)).clamp(0.0, w),
                      top: _dragging ? -1.5 : -2.5,
                      child: Container(
                        width: _dragging ? 18 : 12,
                        height: _dragging ? 9 : 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF4D4F),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
