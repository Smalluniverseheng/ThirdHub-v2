// 语音识别的专用录音器。
//
// ★为什么不能复用 `VoiceRec`（voice_msg.dart）：
//   那个是给「聊天里的语音消息」用的，走 `record` 的默认配置 → **m4a / AAC**。
//   而语音识别这边，小米 MiMo 官方明确「只支持 wav 和 mp3」，
//   百炼 / 硅基流动虽然宽容，但 wav 16k 单声道是**所有厂商都收**的交集。
//   拿 m4a 去发，用户看到的是"识别失败"，根因却在录音编码上 ——
//   这种错最难自查，所以在这里显式钉死参数。
//
// 另一件事：识别要的是"一段完整的话"，不是"来电振铃"。
//   所以开启回声消除与噪声抑制（部分机型不支持，失败就退回默认）。

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 识别用录音器：一次录一条，产出 **wav 16kHz 单声道**。
class AsrRec {
  final AudioRecorder _rec = AudioRecorder();
  bool _on = false;
  DateTime? _t0;
  String? _path;

  bool get on => _on;

  /// 记录一句话的最长时间（秒）——防止用户忘了松手把内存吃满。
  static const int maxSeconds = 120;

  /// 开始录音。没给麦克风权限返回 false（由 UI 层提示，不在这里弹窗）。
  Future<bool> start() async {
    if (_on) return true;
    if (!await _rec.hasPermission()) return false;
    try {
      final dir = await getTemporaryDirectory();
      final d = Directory('${dir.path}/asr');
      if (!await d.exists()) await d.create(recursive: true);
      _path = '${d.path}/a-${DateTime.now().millisecondsSinceEpoch}.wav';
      const cfg = RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        // 识别场景要人声清晰：降噪 + 回声消除（不支持的机型会被忽略）
        noiseSuppress: true,
        echoCancel: true,
        autoGain: true,
      );
      await _rec.start(cfg, path: _path!);
      _on = true;
      _t0 = DateTime.now();
      return true;
    } catch (_) {
      // 部分机型不支持上面几个开关 → 退回最保守的配置再试一次
      try {
        final dir = await getTemporaryDirectory();
        _path ??= '${dir.path}/a-${DateTime.now().millisecondsSinceEpoch}.wav';
        await _rec.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: _path!,
        );
        _on = true;
        _t0 = DateTime.now();
        return true;
      } catch (_) {
        _on = false;
        _path = null;
        return false;
      }
    }
  }

  /// 停止并返回 (路径, 秒数)。没在录或没产出文件则路径为 null。
  Future<(String?, int)> stop() async {
    if (!_on) return (null, 0);
    int secs = 0;
    try {
      final t = _t0;
      if (t != null) secs = DateTime.now().difference(t).inSeconds;
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

  /// 放弃这次录音；文件会被删掉，不留垃圾。
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

  Future<void> dispose() async {
    try {
      await _rec.dispose();
    } catch (_) {}
  }
}
