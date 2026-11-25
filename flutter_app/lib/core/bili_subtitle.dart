// B站字幕渲染层（4.81.103）
//
// 解析逻辑在 bili_subtitle_parser.dart（纯 Dart，可自检）；本文件只做一件事：
// 跟随播放器进度，显示当前时间点命中的那条字幕。仿 BiliDanmaku 的 ticker 方案，
// 但字幕同一时刻最多一条，不做滚动/轨道，只做定位 + 描边 + 字号 + 上下位置。
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import 'bili_subtitle_parser.dart' show cueAt;

class BiliSubtitleLayer extends StatefulWidget {
  const BiliSubtitleLayer({
    super.key,
    required this.vp,
    required this.cues,
    this.enabled = true,
    this.top = false,
    this.fontSize = 18,
    this.color = Colors.white,
  });

  /// 普通 720p 播放器（video_player）。DASH 1080p 页用自己的 _pos ticker。
  final VideoPlayerController? vp;
  final List<Map<String, dynamic>> cues;
  final bool enabled;
  final bool top;
  final double fontSize;
  final Color color;

  @override
  State<BiliSubtitleLayer> createState() => _BiliSubtitleLayerState();
}

class _BiliSubtitleLayerState extends State<BiliSubtitleLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Map<String, dynamic>? _cur;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    if (!mounted) return;
    if (!widget.enabled || widget.cues.isEmpty) {
      if (_cur != null) setState(() => _cur = null);
      return;
    }
    final v = widget.vp?.value;
    if (v == null || !v.isInitialized) return;
    final pos = v.position.inMilliseconds / 1000.0;
    final c = cueAt(widget.cues, pos);
    final same = (c == null && _cur == null) ||
        (c != null &&
            _cur != null &&
            c['x'] == _cur!['x'] &&
            c['t0'] == _cur!['t0']);
    if (!same) setState(() => _cur = c);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _cur == null) return const SizedBox.shrink();
    final text = '${_cur!['x'] ?? ''}';
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: Align(
          alignment: widget.top ? Alignment.topCenter : Alignment.bottomCenter,
          child: Container(
            margin:
                EdgeInsets.fromLTRB(16, widget.top ? 10 : 0, 16, widget.top ? 0 : 14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xB3000000),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.color,
                fontSize: widget.fontSize,
                height: 1.25,
                shadows: const [
                  Shadow(color: Color(0xCC000000), blurRadius: 3, offset: Offset(1, 1)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// DASH 播放器字幕层：位置来自 media_kit 的 _pos（秒），不依赖 video_player。
class BiliDashSubtitleLayer extends StatefulWidget {
  const BiliDashSubtitleLayer({
    super.key,
    required this.position,
    required this.cues,
    this.enabled = true,
    this.top = false,
    this.fontSize = 18,
  });

  final double Function() position;
  final List<Map<String, dynamic>> cues;
  final bool enabled;
  final bool top;
  final double fontSize;

  @override
  State<BiliDashSubtitleLayer> createState() => _BiliDashSubtitleLayerState();
}

class _BiliDashSubtitleLayerState extends State<BiliDashSubtitleLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Map<String, dynamic>? _cur;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    if (!mounted) return;
    if (!widget.enabled || widget.cues.isEmpty) {
      if (_cur != null) setState(() => _cur = null);
      return;
    }
    final c = cueAt(widget.cues, widget.position());
    final same = (c == null && _cur == null) ||
        (c != null &&
            _cur != null &&
            c['x'] == _cur!['x'] &&
            c['t0'] == _cur!['t0']);
    if (!same) setState(() => _cur = c);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _cur == null) return const SizedBox.shrink();
    final text = '${_cur!['x'] ?? ''}';
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: Align(
          alignment: widget.top ? Alignment.topCenter : Alignment.bottomCenter,
          child: Container(
            margin:
                EdgeInsets.fromLTRB(16, widget.top ? 10 : 0, 16, widget.top ? 0 : 56),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xB3000000),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              text,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: widget.fontSize,
                height: 1.25,
                shadows: const [
                  Shadow(color: Color(0xCC000000), blurRadius: 3, offset: Offset(1, 1)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
