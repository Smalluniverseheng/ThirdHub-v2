// 弹幕渲染层（4.81.71）
//
// 数据：后端 /v1/bili/danmaku（或直连）返回 [{t:秒, m:模式1滚/4底/5顶, c:颜色, s:字号, x:文本}]
// 渲染：跟随播放进度推进；滚动弹幕从右往左飞（8 秒穿屏），顶部/底部固定 4 秒。
// 性能：只保留在场弹幕（一般 20~40 条），RepaintBoundary 隔离重绘。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

class BiliDanmaku extends StatefulWidget {
  final VideoPlayerController? vp;
  final List<Map<String, dynamic>> items;
  final bool enabled;
  final double opacity;
  final double fontScale;

  const BiliDanmaku({
    super.key,
    required this.vp,
    required this.items,
    this.enabled = true,
    this.opacity = 0.9,
    this.fontScale = 1.0,
  });

  @override
  State<BiliDanmaku> createState() => _BiliDanmakuState();
}

class _Dm {
  _Dm(this.text, this.color, this.mode, this.born, this.lane, this.size);
  final String text;
  final Color color;
  final int mode; // 1 滚动 / 4 底部 / 5 顶部
  final double born; // 入场时的播放时间（秒）
  final int lane;
  final double size;
}

class _BiliDanmakuState extends State<BiliDanmaku>
    with SingleTickerProviderStateMixin {
  static const double _rollSec = 8.0; // 滚动穿屏耗时
  static const double _stillSec = 4.0; // 顶部/底部停留
  static const int _lanes = 11;

  late final Ticker _ticker;
  final List<_Dm> _active = [];
  final List<double> _laneFreeAt = List<double>.filled(_lanes, 0);
  int _cursor = 0;
  double _pos = -1;
  double _lastBuild = -1;

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

  double get _now {
    final v = widget.vp?.value;
    if (v == null || !v.isInitialized) return 0;
    return v.position.inMilliseconds / 1000.0;
  }

  void _onTick(Duration _) {
    if (!mounted || !widget.enabled || widget.items.isEmpty) return;
    final pos = _now;
    // 播放器回退（拖进度条）→ 重建游标
    if (pos < _pos - 0.5) {
      _active.clear();
      _cursor = 0;
      for (var i = 0; i < _laneFreeAt.length; i++) {
        _laneFreeAt[i] = 0;
      }
    }
    _pos = pos;
    if ((pos - _lastBuild).abs() < 0.05) return; // 约 20fps 足够顺滑且省电
    _lastBuild = pos;

    // 进场：把 t <= pos 且还没上屏的加进来
    var added = 0;
    while (_cursor < widget.items.length && added < 15) {
      final it = widget.items[_cursor];
      final t = (it['t'] is num) ? (it['t'] as num).toDouble() : 0.0;
      if (t > pos) break;
      _cursor++;
      // 只显示最近 12 秒内该出现的（从头开始播时不至于一次灌满）
      if (pos - t > 12) continue;
      _push(it, t);
      added++;
    }
    // 退场
    _active.removeWhere((d) {
      final life = d.mode == 1 ? _rollSec : _stillSec;
      return pos - d.born > life;
    });
    setState(() {});
  }

  void _push(Map<String, dynamic> it, double t) {
    final text = '${it['x'] ?? ''}'.trim();
    if (text.isEmpty) return;
    final mode = (it['m'] is num) ? (it['m'] as num).toInt() : 1;
    final c = (it['c'] is num) ? (it['c'] as num).toInt() : 0xFFFFFF;
    var lane = 0;
    // 选最早空出来的轨道
    var best = double.infinity;
    for (var i = 0; i < _lanes; i++) {
      if (_laneFreeAt[i] < best) {
        best = _laneFreeAt[i];
        lane = i;
      }
    }
    _laneFreeAt[lane] = t + (mode == 1 ? 1.6 : 1.2);
    _active.add(_Dm(
      text,
      Color(0xFF000000 | c),
      mode,
      t,
      lane,
      (it['s'] is num ? (it['s'] as num).toDouble() : 25) * widget.fontScale,
    ));
    if (_active.length > 60) _active.removeAt(0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.items.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(builder: (c, cons) {
          final w = cons.maxWidth, h = cons.maxHeight;
          final lineH = math.min(26.0, h / _lanes);
          return ClipRect(
            child: Stack(
              children: [
                for (final d in _active) _buildOne(d, w, h, lineH),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildOne(_Dm d, double w, double h, double lineH) {
    final age = (_pos - d.born).clamp(0.0, 99.0);
    final fs = (d.size * 0.62).clamp(11.0, 20.0);
    final style = TextStyle(
      fontSize: fs,
      color: d.color.withValues(alpha: widget.opacity),
      fontWeight: FontWeight.w500,
      shadows: const [
        Shadow(color: Color(0xCC000000), blurRadius: 2, offset: Offset(1, 1)),
      ],
    );
    if (d.mode == 1) {
      // 滚动：从右边缘到左边缘
      final progress = (age / _rollSec).clamp(0.0, 1.0);
      final x = w - (w + 240) * progress;
      final y = 4 + d.lane * lineH;
      return Positioned(
        left: x,
        top: y,
        child: Text(d.text, maxLines: 1, softWrap: false, style: style),
      );
    }
    // 顶部 / 底部：水平居中，限制 5 行避免盖住画面
    final lane = d.lane % 5;
    final y = d.mode == 5 ? 8 + lane * lineH : h - 40 - lane * lineH;
    return Positioned(
      left: 0,
      right: 0,
      top: y,
      child: Center(
        child: Text(d.text, maxLines: 1, softWrap: false, style: style),
      ),
    );
  }
}
