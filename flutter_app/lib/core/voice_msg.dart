// 语音消息：按住说话 → 松手发出去 → 对方点一下就播。
//
// 用户需求(2026-10-01)：聊天要「能发送各种东西……语音」。
// 协议侧 `ChatKind.voice` 早就预留了，缺的是**录与播**这一段：
//   · 录：`record`（录音机模块 mini_modules2.dart 已在用，先例可循）
//   · 播：`just_audio`（全项目多处已在用）
//   · 传：走既有的文件传输链路，`sendFile(path, kind: ChatKind.voice)` ——
//     不另起一套，接收、进度、失败重试全部继承。
//
// ★ 实时语音通话**不是**这个文件的职责：那需要双向音频流 + 信令，
//   是与文字/文件并列的另一套子系统，单独排期。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'chat_logic.dart';
import 'play_tag.dart';

/// 语音录制器：一次录一条，录完给出文件路径与时长（秒）。
class VoiceRec {
  final AudioRecorder _rec = AudioRecorder();
  bool _on = false;
  DateTime? _t0;
  String? _path;

  bool get on => _on;

  /// 开始录音。没给麦克风权限返回 false —— 由调用方提示，不要在这里弹窗
  /// （UI 层才该弹窗，工具层只报告结果）。
  Future<bool> start() async {
    if (_on) return true;
    if (!await _rec.hasPermission()) return false;
    try {
      final dir = await getTemporaryDirectory();
      final d = Directory('${dir.path}/voice');
      if (!await d.exists()) await d.create(recursive: true);
      _path = '${d.path}/v-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(const RecordConfig(), path: _path!);
      _on = true;
      _t0 = DateTime.now();
      return true;
    } catch (_) {
      _on = false;
      _path = null;
      return false;
    }
  }

  /// 停止并返回 (路径, 秒数)。没在录或没产出文件则路径为 null。
  Future<(String?, int)> stop() async {
    if (!_on) return (null, 0);
    int secs = 0;
    try {
      final t = _t0;
      if (t != null) {
        secs = DateTime.now().difference(t).inSeconds;
      }
      final p = await _rec.stop();
      _on = false;
      final path = (p != null && p.isNotEmpty) ? p : _path;
      if (path == null || !await File(path).exists()) return (null, secs);
      return (path, secs);
    } catch (_) {
      _on = false;
      return (null, secs);
    }
  }

  /// 放弃这次录音（松手前取消）；文件会被删掉，不留垃圾。
  Future<void> cancel() async {
    if (!_on) return;
    try {
      await _rec.stop();
    } catch (_) {}
    _on = false;
    final p = _path;
    if (p != null) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _path = null;
  }

  void dispose() => _rec.dispose();
}

/// 语音气泡：点一下播放 / 再点停；显示时长。
///
/// 本地有文件就直接播；还没有（对方发来的、未下载）时走 [onFetch]，
/// 拿到本地路径后再播 —— 与文件消息共用同一条下载链路。
class VoiceBubble extends StatefulWidget {
  const VoiceBubble(
      {super.key, required this.msg, required this.mine, this.onFetch});

  final LanMessage2 msg;
  final bool mine;

  /// 需要先把语音拉到本地时调用，返回本地路径（null 表示没拿到）。
  final Future<String?> Function(LanMessage2)? onFetch;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  final _player = AudioPlayer();
  bool _playing = false;
  bool _busy = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  /// 时长的四种来源，按可靠度降序：消息自带的 secs → file 元数据 → 未知。
  int get _secs {
    final m = widget.msg.file;
    final s = m?['secs'];
    if (s is int) return s;
    if (s is num) return s.round();
    return 0;
  }

  Future<void> _toggle() async {
    if (_busy) return;
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    var path = '${widget.msg.file?['path'] ?? ''}';
    if (path.isEmpty || !await File(path).exists()) {
      if (widget.onFetch == null) return;
      setState(() => _busy = true);
      path = await widget.onFetch!(widget.msg) ?? '';
      if (!mounted) return;
      setState(() => _busy = false);
      if (path.isEmpty) return;
    }
    try {
      await _player.setAudioSource(
          tagFile(path, title: '语音消息', album: 'ThirdHub'));
      setState(() => _playing = true);
      await _player.play();
      _player.playerStateStream.firstWhere((s) => s.playing == false).then((_) {
        if (mounted) setState(() => _playing = false);
      });
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final col = Theme.of(c).colorScheme;
    final secs = _secs;
    return InkWell(
      onTap: _toggle,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_playing ? Icons.pause_circle_filled : Icons.play_arrow_rounded,
            size: 18, color: col.primary),
        const SizedBox(width: 6),
        // 一条随播放与否变化的小波形（纯装饰，不接真实波形 ——
        // 真实波形要额外解析音频，收益不抵复杂度）
        SizedBox(
          width: 54,
          height: 14,
          child: CustomPaint(
            painter: _WavePainter(_playing ? col.primary : col.onSurface
                .withValues(alpha: 0.45)),
          ),
        ),
        const SizedBox(width: 6),
        Text(_busy ? '接收中…' : (secs > 0 ? '${secs}"' : '语音'),
            style: const TextStyle(fontSize: 12)),
      ]),
    );
  }
}

/// 装饰性波形：五根竖条，高度错落。播放时染色。
class _WavePainter extends CustomPainter {
  _WavePainter(this.color);
  final Color color;

  static const List<double> _h = [0.35, 0.7, 1.0, 0.55, 0.8];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const n = 5;
    final w = size.width / (n * 2 - 1);
    for (var i = 0; i < n; i++) {
      final h = size.height * _h[i];
      final x = i * w * 2;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, (size.height - h) / 2, w, h),
              const Radius.circular(1.5)),
          paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.color != color;
}
