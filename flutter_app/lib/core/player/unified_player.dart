// 统一播放器：一套控制层，按 MediaSpec.kind 自动适配「视频」或「音频」。
//
// 合并前的状况（这是本文件存在的理由）：
//   VideoPlayPage / LocalVideoPlayerPage / UrlVideoPlayer / _ShortPlayer /
//   _CinemaPlayer / _VideoPlayerPage / _MPlay  ——  7 套播放器各自实现
//   进度条、全屏、倍速、上下集、错误提示。同一件事写 7 遍，
//   于是"影视能拖进度、短剧不能""本地视频会记住进度、URL 视频不会"这种
//   不一致随处可见。
//
// 合并后：
//   • 影视 / 本地 / URL / 短视频 / 音乐 / 有声书  —— 全部走这一个页面
//   • 视频模式和音频模式共享进度、倍速、续播、队列逻辑
//   • 视频可一键「只听音频」，这就是生态互通的落点：
//     B 站上一首纯音乐视频，可以直接丢进音乐语境继续听，不必换播放器。
//
// 刻意**不**并入的东西：B 站专用播放器（core/bili_player.dart）。
// 它带着弹幕渲染、cid 拉取、清晰度切换等强 B 站语义，且已经实测可用；
// 强行合并会把通用播放器拖成"什么都懂一点"，得不偿失。后续以插槽方式接入。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../main.dart' show AppSettings;
import '../play_tag.dart';
import 'media_probe.dart';
import 'media_spec.dart';

/// 播放器内部用的一套常量。集中在此，避免又散出一批魔数。
class _T {
  static const double pad = 14;
  static const double radius = 12;
  static const Duration ctrlHide = Duration(seconds: 4);
}

/// 统一播放页。
///
/// 用法：
/// ```dart
/// UnifiedPlayer.open(context, MediaSpec(url: u, title: t));
/// ```
/// 调用方不需要知道它是视频还是音频 —— 传进来的 spec 自带答案。
class UnifiedPlayerPage extends StatefulWidget {
  final MediaSpec spec;

  /// 传 true 时进入页面立即开始播（用户点了就播，不要再点一次）。
  final bool autoPlay;

  const UnifiedPlayerPage({
    super.key,
    required this.spec,
    this.autoPlay = true,
  });

  @override
  State<UnifiedPlayerPage> createState() => _UnifiedPlayerPageState();
}

class _UnifiedPlayerPageState extends State<UnifiedPlayerPage> {
  late MediaSpec _spec;
  late MediaKind _kind;

  /// 视频通路
  VideoPlayerController? _vc;

  /// 音频通路
  AudioPlayer? _ap;
  StreamSubscription<PlayerState>? _apStateSub;
  StreamSubscription<Duration>? _apPosSub;
  StreamSubscription<Duration?>? _apDurSub;
  Duration _aPos = Duration.zero;
  Duration _aDur = Duration.zero;
  bool _aPlaying = false;
  bool _aBuffering = false;

  bool _loading = true;
  String _err = '';
  bool _ctrl = true;
  bool _fullscreen = false;
  Timer? _hideTimer;

  /// 续播定时器：每 3 秒落一次盘，与旧播放器（main.dart 的 _Uvp）行为一致，
  /// 保证换成统一播放器后"看到哪记到哪"没有退化。
  Timer? _posTimer;
  double _speed = 1.0;

  /// 用户手动切过「只听音频」后，即使 kind 判成 video 也走音频通路。
  bool _audioMode = false;

  /// 视频位置（拖动时用，避免频繁 seek）
  bool _dragging = false;
  Duration _dragPos = Duration.zero;

  @override
  void initState() {
    super.initState();
    _spec = widget.spec;
    _kind = _spec.kind;
    _audioMode = _kind == MediaKind.audio;
    _armHide();
    _startPosTimer();
    _openMedia(autoplay: widget.autoPlay);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _posTimer?.cancel();
    _savePos();
    _teardown();
    if (_fullscreen) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _teardown() {
    _vc?.removeListener(_vcTick);
    _vc?.dispose();
    _vc = null;
    _apStateSub?.cancel();
    _apPosSub?.cancel();
    _apDurSub?.cancel();
    _ap?.dispose();
    _ap = null;
  }

  // ── 打开媒体 ───────────────────────────────────────────────
  Future<void> _openMedia({required bool autoplay}) async {
    _teardown();
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      if (_audioMode) {
        await _openAudio(autoplay: autoplay);
      } else {
        await _openVideo(autoplay: autoplay);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '打不开这个地址：$e\n\n地址：${_spec.url}';
      });
    }
  }

  Future<void> _openVideo({required bool autoplay}) async {
    final c = VideoPlayerController.networkUrl(
      Uri.parse(_spec.url),
      httpHeaders: _spec.headers,
    );
    _vc = c;
    await c.initialize();
    c.addListener(_vcTick);
    final start = _resumeFrom(c.value.duration);
    if (start > Duration.zero) await c.seekTo(start);
    if (autoplay) await c.play();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _openAudio({required bool autoplay}) async {
    final p = AudioPlayer();
    _ap = p;
    // 统一走 play_tag：通知栏/锁屏媒体控制依赖 MediaItem 标签，
    // 裸调 setUrl 会导致后台播放没有控制组件（这是项目既定规矩）。
    await p.setAudioSource(tagUrl(
      _spec.url,
      title: _spec.title,
      album: _spec.album ?? 'ThirdHub',
    ));
    final start = _resumeFrom(p.duration ?? Duration.zero);
    if (start > Duration.zero) await p.seek(start);
    _apDurSub = p.durationStream.listen((d) {
      if (d != null && mounted) setState(() => _aDur = d);
    });
    _apPosSub = p.positionStream.listen((d) {
      if (mounted) setState(() => _aPos = d);
    });
    _apStateSub = p.playerStateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _aPlaying = s.playing;
        _aBuffering = s.processingState == ProcessingState.loading ||
            s.processingState == ProcessingState.buffering;
      });
      if (s.processingState == ProcessingState.completed) _onEnded();
    });
    if (autoplay) unawaited(p.play());
    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _vcTick() {
    if (!mounted) return;
    setState(() {});
  }

  /// 续播位置。优先级：spec 显式指定 > 本机上次看到的位置。
  /// 上次位置若已接近片尾（>95%），视为看完，从头开始 ——
  /// 否则用户重进一个已看完的视频会直接卡在黑屏结尾，以为坏了。
  Duration _resumeFrom(Duration total) {
    final explicit = _spec.startAt;
    if (explicit != null && explicit > Duration.zero) return explicit;
    final sec = AppSettings.p.getInt('vpos_${_spec.url}') ?? 0;
    if (sec <= 5) return Duration.zero;
    if (total.inSeconds > 60 && sec >= total.inSeconds * 0.95) {
      return Duration.zero;
    }
    return Duration(seconds: sec);
  }

  void _startPosTimer() {
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(seconds: 3), (_) => _savePos());
  }

  void _savePos() {
    final p = _pos.inSeconds;
    if (p > 5) unawaited(AppSettings.p.setInt('vpos_${_spec.url}', p));
  }

  // ── 控制层显隐 ─────────────────────────────────────────────
  void _armHide() {
    _hideTimer?.cancel();
    if (!_ctrl) return;
    _hideTimer = Timer(_T.ctrlHide, () {
      if (mounted) setState(() => _ctrl = false);
    });
  }

  void _toggleCtrl() {
    setState(() => _ctrl = !_ctrl);
    _armHide();
  }

  // ── 播放控制（视频/音频统一入口） ───────────────────────────
  bool get _playing {
    if (_audioMode) return _aPlaying;
    return _vc?.value.isPlaying ?? false;
  }

  Duration get _pos {
    if (_audioMode) return _aPos;
    return _vc?.value.position ?? Duration.zero;
  }

  Duration get _dur {
    if (_audioMode) return _aDur;
    return _vc?.value.duration ?? Duration.zero;
  }

  Future<void> _togglePlay() async {
    _armHide();
    if (_audioMode) {
      final p = _ap;
      if (p == null) return;
      if (p.playing) {
        await p.pause();
      } else {
        await p.play();
      }
      return;
    }
    final c = _vc;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    setState(() {});
  }

  Future<void> _seekTo(Duration d) async {
    if (_audioMode) {
      await _ap?.seek(d);
    } else {
      await _vc?.seekTo(d);
    }
    setState(() {});
  }

  Future<void> _seekBy(Duration delta) async {
    final target = _pos + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _dur ? _dur : target);
    await _seekTo(clamped);
  }

  void _onEnded() {
    final n = _spec.next;
    if (n != null) {
      setState(() {
        _spec = n;
        _kind = n.kind;
        _audioMode = n.kind == MediaKind.audio;
      });
      unawaited(_openMedia(autoplay: true));
    }
  }

  void _playNext() {
    final n = _spec.next;
    if (n == null) return;
    setState(() {
      _spec = n;
      _kind = n.kind;
      _audioMode = n.kind == MediaKind.audio;
    });
    unawaited(_openMedia(autoplay: true));
  }

  void _playPrev() {
    final p = _spec.prev;
    if (p == null) return;
    setState(() {
      _spec = p;
      _kind = p.kind;
      _audioMode = p.kind == MediaKind.audio;
    });
    unawaited(_openMedia(autoplay: true));
  }

  Future<void> _setSpeed(double s) async {
    setState(() => _speed = s);
    if (_audioMode) {
      await _ap?.setSpeed(s);
    } else {
      await _vc?.setPlaybackSpeed(s);
    }
  }

  /// 视频 ⇄ 音频 切换。生态互通的核心动作。
  Future<void> _toggleAudioMode() async {
    final toAudio = !_audioMode;
    final pos = _pos;
    setState(() {
      _audioMode = toAudio;
      _kind = toAudio ? MediaKind.audio : MediaKind.video;
      _loading = true;
    });
    _teardown();
    // 保留播放位置：切形态不该把用户扔回开头
    await _openMedia(autoplay: true);
    if (pos > Duration.zero) await _seekTo(pos);
  }

  Future<void> _toggleFullscreen() async {
    final toFs = !_fullscreen;
    setState(() {
      _fullscreen = toFs;
      _ctrl = true;
    });
    _armHide();
    if (toFs) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // ── 构建 ──────────────────────────────────────────────────
  @override
  Widget build(BuildContext c) {
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) unawaited(_toggleFullscreen());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: !_fullscreen,
          bottom: !_fullscreen,
          child: _err.isNotEmpty
              ? _errorView(c)
              : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_audioMode ? _audioView(c) : _videoView(c)),
        ),
      ),
    );
  }

  Widget _errorView(BuildContext c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(_T.pad * 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white54, size: 40),
              const SizedBox(height: 14),
              Text(_err,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 18),
              FilledButton.tonal(
                onPressed: () => _openMedia(autoplay: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );

  // ── 视频形态 ──────────────────────────────────────────────
  Widget _videoView(BuildContext c) {
    final vc = _vc!;
    final ar = vc.value.aspectRatio > 0 ? vc.value.aspectRatio : 16 / 9;

    return Stack(
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: ar,
            child: VideoPlayer(vc),
          ),
        ),
        // 手势层：单击显隐控制、双击播放暂停、横滑调进度
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleCtrl,
            onDoubleTap: _togglePlay,
            onHorizontalDragStart: (_) {
              _hideTimer?.cancel();
              setState(() => _dragging = true);
            },
            onHorizontalDragUpdate: (d) {
              final total = _dur.inMilliseconds;
              if (total <= 0) return;
              // 一屏宽 ≈ 全片的 1/4，手感接近主流播放器
              final dx = d.primaryDelta ?? 0;
              final deltaMs = (dx / 360 * total / 4).round();
              final next = _dragPos.inMilliseconds + deltaMs;
              setState(() => _dragPos = Duration(
                  milliseconds: next.clamp(0, total)));
            },
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              unawaited(_seekTo(_dragPos));
            },
          ),
        ),
        if (_dragging) _seekHud(),
        if (_ctrl) _videoTop(c),
        if (_ctrl) _videoBottom(c),
      ],
    );
  }

  Widget _seekHud() {
    final total = _dur.inMilliseconds;
    final pct = total <= 0 ? 0.0 : _dragPos.inMilliseconds / total;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(_T.radius),
        ),
        child: Text('${_fmt(_dragPos)} / ${_fmt(_dur)}  (${(pct * 100).round()}%)',
            style: const TextStyle(color: Colors.white, fontSize: 14)),
      ),
    );
  }

  Widget _videoTop(BuildContext c) => Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 0.62), Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () {
                  if (_fullscreen) {
                    unawaited(_toggleFullscreen());
                  } else {
                    Navigator.maybePop(c);
                  }
                },
              ),
              Expanded(
                child: Text(
                  _spec.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              // 只听音频：生态互通的入口
              if (_spec.allowAudioMode)
                IconButton(
                  tooltip: '只听音频（可继续在音乐里听）',
                  icon: const Icon(Icons.headphones, color: Colors.white),
                  onPressed: () {
                    _armHide();
                    unawaited(_toggleAudioMode());
                  },
                ),
              _speedBtn(),
              IconButton(
                icon: Icon(
                    _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    color: Colors.white),
                onPressed: () {
                  _armHide();
                  unawaited(_toggleFullscreen());
                },
              ),
            ],
          ),
        ),
      );

  Widget _speedBtn() => PopupMenuButton<double>(
        tooltip: '倍速',
        icon: const Icon(Icons.speed, color: Colors.white),
        initialValue: _speed,
        onSelected: (v) {
          _armHide();
          unawaited(_setSpeed(v));
        },
        itemBuilder: (_) => [
          for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
            PopupMenuItem(value: s, child: Text('${s}x')),
        ],
      );

  Widget _videoBottom(BuildContext c) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black.withValues(alpha: 0.68), Colors.transparent],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sliderRow(),
              Row(
                children: [
                  IconButton(
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                        color: Colors.white, size: 26),
                    onPressed: () => unawaited(_togglePlay()),
                  ),
                  if (_spec.prev != null)
                    IconButton(
                      icon: const Icon(Icons.skip_previous, color: Colors.white),
                      onPressed: _playPrev,
                    ),
                  if (_spec.next != null)
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      onPressed: _playNext,
                    ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text('${_fmt(_pos)} / ${_fmt(_dur)}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  /// 进度条：拖动时只更新 _dragPos，松手才 seek（避免拖一次发几十个请求）
  Widget _sliderRow() {
    final total = _dur.inMilliseconds;
    final cur = (_dragging ? _dragPos : _pos).inMilliseconds;
    return SizedBox(
      height: 26,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 2.5,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: Slider(
          min: 0,
          max: total <= 0 ? 1 : total.toDouble(),
          value: (total <= 0 ? 0 : cur).toDouble().clamp(
              0, total <= 0 ? 1 : total.toDouble()),
          onChanged: (v) => setState(
              () => _dragPos = Duration(milliseconds: v.round())),
          onChangeStart: (_) {
            _hideTimer?.cancel();
            setState(() {
              _dragging = true;
              _dragPos = _pos;
            });
          },
          onChangeEnd: (v) {
            setState(() => _dragging = false);
            unawaited(_seekTo(Duration(milliseconds: v.round())));
            _armHide();
          },
        ),
      ),
    );
  }

  // ── 音频形态 ──────────────────────────────────────────────
  Widget _audioView(BuildContext c) {
    final accent = Theme.of(c).colorScheme.primary;
    return GestureDetector(
      onTap: _toggleCtrl,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.alphaBlend(accent.withValues(alpha: 0.16), Colors.black),
              Colors.black,
            ],
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down,
                      color: Colors.white, size: 28),
                  onPressed: () => Navigator.maybePop(c),
                ),
                const Spacer(),
                if (_kind == MediaKind.video || _spec.kind == MediaKind.video)
                  TextButton.icon(
                    onPressed: () => unawaited(_toggleAudioMode()),
                    icon: const Icon(Icons.videocam_outlined,
                        color: Colors.white70, size: 18),
                    label: const Text('看画面',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
              ],
            ),
            const Spacer(),
            _coverBox(),
            const SizedBox(height: 26),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  Text(
                    _spec.title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600),
                  ),
                  if ((_spec.artist ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_spec.artist!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13)),
                  ],
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: _sliderRow(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: Row(
                children: [
                  Text(_fmt(_pos),
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 11)),
                  const Spacer(),
                  Text(_fmt(_dur),
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 34,
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                  onPressed: _spec.prev == null ? null : _playPrev,
                ),
                const SizedBox(width: 20),
                if (_aBuffering)
                  const SizedBox(
                    width: 54,
                    height: 54,
                    child: Padding(
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  )
                else
                  IconButton(
                    iconSize: 54,
                    icon: Icon(_aPlaying ? Icons.pause_circle : Icons.play_circle,
                        color: Colors.white),
                    onPressed: () => unawaited(_togglePlay()),
                  ),
                const SizedBox(width: 20),
                IconButton(
                  iconSize: 34,
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  onPressed: _spec.next == null ? null : _playNext,
                ),
              ],
            ),
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final s in const [0.75, 1.0, 1.25, 1.5, 2.0])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text('${s}x',
                            style: TextStyle(
                                fontSize: 11,
                                color: _speed == s
                                    ? Colors.black
                                    : Colors.white70)),
                        selected: _speed == s,
                        selectedColor: Colors.white,
                        backgroundColor: Colors.white10,
                        onSelected: (_) => unawaited(_setSpeed(s)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 26),
          ],
        ),
      ),
    );
  }

  Widget _coverBox() {
    final url = _spec.cover;
    final size = MediaQuery.of(context).size.shortestSide * 0.62;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white10,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: (url == null || url.isEmpty)
          ? const Icon(Icons.music_note, color: Colors.white24, size: 68)
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.music_note, color: Colors.white24, size: 68),
            ),
    );
  }

  // ── 工具 ──────────────────────────────────────────────────
  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// 对外入口。全局统一从这里开播。
class UnifiedPlayer {
  UnifiedPlayer._();

  /// 打开播放页。[autoPlay] 为 false 时进去先停着。
  static Future<void> open(
    BuildContext ctx,
    MediaSpec spec, {
    bool autoPlay = true,
  }) {
    return Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => UnifiedPlayerPage(spec: spec, autoPlay: autoPlay),
    ));
  }

  /// 便利方法：只给一个地址和标题。
  ///
  /// 会自动判断是视频还是音频 —— 调用方不必关心。
  static Future<void> url(
    BuildContext ctx,
    String url, {
    required String title,
    MediaKind? kind,
    String? cover,
    Map<String, String> headers = const {},
    String? artist,
    String? album,
    String sourceTag = '',
  }) =>
      open(
        ctx,
        MediaSpec(
          url: url,
          title: title,
          kindOverride: kind,
          cover: cover,
          headers: headers,
          artist: artist,
          album: album,
          sourceTag: sourceTag,
        ),
      );

  /// 把一条视频「当音乐播」。生态互通用：
  /// B 站纯音乐视频 → 音乐模块语境 → 只出声音。
  static Future<void> playAsAudio(BuildContext ctx, MediaSpec videoSpec) =>
      open(ctx, MediaProbe.asAudio(videoSpec));
}
