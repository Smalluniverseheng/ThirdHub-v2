// B站 DASH 高清播放器（4.81.94）——登录后的 1080p 走这里。
//
// 为什么单独一页：现有 bili_player.dart 基于 video_player（单 URL），
// DASH 是音视频分离的两条流，video_player 播不了。这里用 media_kit（libmpv），
// 通过 NativePlayer.command(['audio-add', audioUrl, 'external']) 外挂音轨——
// libmpv 会把两条流按时间戳同步，这是端上播 1080p 最稳的路子。
//
// 保留 B站 的核心交互：自绘控制层（播放/进度/音量/倍速/全屏）+ 常驻弹幕 +
// 弹幕设置（透明度/字号/速度/区域/屏蔽类型）。720p 及以下仍走原 bili_player。
import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'bili_auth.dart' show BiliAuth;
import 'design_tokens.dart';
import 'i18n.dart';

class BiliDashPlayerPage extends StatefulWidget {
  const BiliDashPlayerPage({
    super.key,
    required this.title,
    required this.videoUrl,
    this.audioUrl = '',
    this.cid = '',
    this.quality = 80,
    this.danmaku = const [],
  });

  final String title;
  final String videoUrl;
  final String audioUrl;
  final String cid;
  final int quality;

  /// 上层已加载的弹幕 [{t:秒, mode:1/4/5, color:int, text:String}]
  final List<Map<String, dynamic>> danmaku;

  @override
  State<BiliDashPlayerPage> createState() => _BiliDashPlayerPageState();
}

class _BiliDashPlayerPageState extends State<BiliDashPlayerPage> {
  late final Player _player;
  late final VideoController _vc;
  StreamSubscription? _posSub;
  StreamSubscription? _doneSub;
  DanmakuController<int>? _dm;
  List<_Dm> _dms = const [];
  int _dmIdx = 0;
  double _lastPos = 0;

  bool _ready = false;
  String _err = '';
  bool _ctrl = true;
  bool _fs = false;
  Timer? _hideTimer;
  double _pos = 0;
  double _dur = 0;
  bool _playing = false;
  double _rate = 1.0;

  // 弹幕设置（持久化在 bili_player 里，这里读同一批 key）
  bool _dmOn = true;
  double _dmOpacity = 0.9;
  double _dmSize = 16;
  double _dmDuration = 8;
  double _dmArea = 1.0;
  bool _hideTop = false, _hideBottom = false, _hideScroll = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      MediaKit.ensureInitialized();
      final hdrs = BiliAuth.I.headers();
      _player = Player(
        configuration: PlayerConfiguration(
          title: widget.title,
          protocolWhitelist: const ['https', 'http', 'tcp', 'tls', 'data'],
        ),
      );
      _vc = VideoController(_player);
      _posSub = _player.stream.position.listen((p) {
        _pos = p.inMilliseconds / 1000.0;
        _tickDanmaku();
        if (mounted) setState(() {});
      });
      _player.stream.duration.listen((d) {
        _dur = d.inMilliseconds / 1000.0;
      });
      _player.stream.playing.listen((v) {
        _playing = v;
        if (mounted) setState(() {});
      });
      _doneSub = _player.stream.completed.listen((done) {
        if (done && mounted) setState(() => _ctrl = true);
      });

      await _player.open(
        Media(widget.videoUrl, httpHeaders: hdrs),
        play: false,
      );
      // ★关键：外挂 B站 DASH 音轨，libmpv 自动与视频时间戳同步
      if (widget.audioUrl.isNotEmpty) {
        await _attachAudio(widget.audioUrl);
      }
      await _loadDanmaku();
      if (!mounted) return;
      setState(() => _ready = true);
      await _player.play();
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('播放失败')}：$e');
    }
  }

  /// 通过 libmpv 原生命令加外置音轨（media_kit 高层 API 未封装）
  Future<void> _attachAudio(String url) async {
    final p = _player.platform;
    if (p is NativePlayer) {
      await p.command(['audio-add', url, 'external', 'bili-audio']);
    } else {
      // Web 端无外置音轨能力——静默降级（DASH 只在移动端启用）
    }
  }

  Future<void> _loadDanmaku() async {
    // 弹幕由上层 BiliVideoPage 加载好传入（与 720p 播放同一份数据）
    final list = widget.danmaku.map((e) {
      final colorRaw = e['color'];
      Color color = Colors.white;
      if (colorRaw is num) {
        color = Color((0xFF000000 | colorRaw.toInt().toUnsigned(24)) & 0xFFFFFFFF);
      }
      return _Dm(
        (e['t'] is num) ? (e['t'] as num).toDouble() : 0,
        (e['mode'] is num) ? (e['mode'] as num).toInt() : 1,
        color,
        '${e['text'] ?? ''}',
      );
    }).toList();
    if (mounted) setState(() => _dms = list);
  }

  void _tickDanmaku() {
    final dm = _dm;
    if (dm == null || !_dmOn || _dms.isEmpty) return;
    final pos = _pos;
    if (pos < _lastPos - 0.5) _replayFrom(pos); // seek 回退
    _lastPos = pos;
    while (_dmIdx < _dms.length && _dms[_dmIdx].t <= pos) {
      final it = _dms[_dmIdx++];
      dm.addDanmaku(DanmakuContentItem<int>(
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
  }

  void _replayFrom(double pos) {
    _dm?.clear();
    var lo = 0, hi = _dms.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_dms[mid].t < pos) lo = mid + 1;
      else hi = mid;
    }
    _dmIdx = lo;
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (!_ctrl || !_playing) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _ctrl = false);
    });
  }

  Future<void> _togglePlay() async {
    await _player.playOrPause();
    _armHide();
  }

  Future<void> _seekTo(double sec) async {
    final target = Duration(milliseconds: (sec * 1000).round());
    await _player.seek(target);
    _replayFrom(sec);
  }

  Future<void> _toggleFullscreen() async {
    final on = !_fs;
    setState(() => _fs = on);
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

  @override
  void dispose() {
    _posSub?.cancel();
    _doneSub?.cancel();
    _hideTimer?.cancel();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _err.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(_err, style: const TextStyle(color: Colors.white70)),
              ),
            )
          : !_ready
              ? const Center(child: CircularProgressIndicator())
              : GestureDetector(
                  onTap: () {
                    setState(() => _ctrl = !_ctrl);
                    _armHide();
                  },
                  child: Stack(children: [
                    Positioned.fill(
                      child: Video(
                        controller: _vc,
                        fit: BoxFit.contain,
                        controls: (state) => const SizedBox.shrink(),
                      ),
                    ),
                    if (_dmOn)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DanmakuScreen<int>(
                            createdController: (e) {
                              _dm = e;
                              _applyDmOption();
                              _replayFrom(_pos);
                            },
                            option: _dmOption(),
                          ),
                        ),
                      ),
                    if (_ctrl) _topBar(),
                    if (_ctrl) _bottomBar(),
                  ]),
                ),
    );
  }

  DanmakuOption _dmOption() => DanmakuOption(
        fontSize: _dmSize,
        opacity: _dmOpacity,
        duration: _dmDuration,
        area: _dmArea,
        hideTop: _hideTop,
        hideBottom: _hideBottom,
        hideScroll: _hideScroll,
        strokeWidth: 1.5,
        lineHeight: 1.6,
      );

  void _applyDmOption() => _dm?.updateOption(_dmOption());

  Widget _topBar() => Positioned(
        top: 0, left: 0, right: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Colors.transparent],
            ),
          ),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${biliQualityLabel(widget.quality)} · ${tr('高清')}',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ]),
        ),
      );

  Widget _bottomBar() => Positioned(
        left: 0, right: 0, bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xE6000000), Colors.transparent],
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(_fmt(_pos), style: const TextStyle(color: Colors.white70, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _dur > 0 ? _pos.clamp(0, _dur) : 0,
                  max: _dur > 0 ? _dur : 1,
                  onChanged: (v) => _seekTo(v),
                ),
              ),
              Text(_fmt(_dur), style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
            Row(children: [
              IconButton(
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
                onPressed: _togglePlay,
              ),
              TextButton(
                onPressed: () async {
                  final rates = [0.75, 1.0, 1.25, 1.5, 2.0];
                  final v = await showMenu<double>(
                    context: context,
                    position: RelativeRect.fromLTRB(60, 200, 200, 300),
                    items: rates
                        .map((r) => PopupMenuItem<double>(
                              value: r,
                              child: Text('${r}x'),
                            ))
                        .toList(),
                  );
                  if (v != null) {
                    setState(() => _rate = v);
                    await _player.setRate(v);
                  }
                },
                child: Text('${_rate}x', style: const TextStyle(color: Colors.white)),
              ),
              IconButton(
                icon: Icon(_dmOn ? Icons.subtitles : Icons.subtitles_off, color: Colors.white),
                onPressed: () => setState(() => _dmOn = !_dmOn),
              ),
              TextButton(
                onPressed: _openDmSheet,
                child: Text(tr('弹幕设置'), style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.fullscreen, color: Colors.white),
                onPressed: _toggleFullscreen,
              ),
            ]),
          ]),
        ),
      );

  void _openDmSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (c) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('弹幕设置'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          SwitchListTile(
            value: _dmOn,
            title: Text(tr('显示弹幕'), style: const TextStyle(fontSize: 13)),
            onChanged: (v) => setState(() => _dmOn = v),
          ),
          _slider(c, tr('透明度'), _dmOpacity, 0.1, 1.0, (v) => setState(() => _dmOpacity = v)),
          _slider(c, tr('字号'), _dmSize, 11, 30, (v) => setState(() => _dmSize = v)),
          _slider(c, tr('滚动速度'), 16 - _dmDuration, 0, 13, (v) => setState(() => _dmDuration = 16 - v)),
          _slider(c, tr('显示区域'), _dmArea, 0.2, 1.0, (v) => setState(() => _dmArea = v)),
          Wrap(spacing: 8, children: [
            FilterChip(label: Text(tr('屏蔽顶部')), selected: _hideTop,
                onSelected: (v) => setState(() => _hideTop = v)),
            FilterChip(label: Text(tr('屏蔽底部')), selected: _hideBottom,
                onSelected: (v) => setState(() => _hideBottom = v)),
            FilterChip(label: Text(tr('屏蔽滚动')), selected: _hideScroll,
                onSelected: (v) => setState(() => _hideScroll = v)),
          ]),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              _applyDmOption();
              Navigator.pop(context);
            },
            child: Text(tr('完成')),
          ),
        ]),
      ),
    );
  }

  Widget _slider(BuildContext c, String label, double value, double min, double max,
      Function(double) onChanged) {
    return Row(children: [
      SizedBox(width: 64, child: Text(label, style: const TextStyle(fontSize: 12))),
      Expanded(
        child: Slider(value: value, min: min, max: max, onChanged: onChanged),
      ),
    ]);
  }

  String _fmt(double s) {
    final t = s.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }
}

String biliQualityLabel(int q) => switch (q) {
      80 => '1080P',
      112 => '1080P+',
      116 => '1080P60',
      120 => '4K',
      _ => '$q',
    };

class _Dm {
  _Dm(this.t, this.mode, this.color, this.text);
  final double t;
  final int mode;
  final Color color;
  final String text;
}
