// 听书: 系统离线TTS(flutter_tts) + 在线AI TTS(OpenAI兼容 /audio/speech)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai.dart';

enum TtsState { idle, playing, paused }

class TtsManager {
  static final _sys = FlutterTts();
  static final _player = AudioPlayer();
  static TtsState state = TtsState.idle;
  static final _stateC = StreamController<TtsState>.broadcast();
  static Stream<TtsState> get onState => _stateC.stream;
  static int chunkIdx = 0; static int chunkTotal = 0;
  static List<String> _chunks = [];
  static bool _stop = false;
  static int _session = 0;
  static Completer<void>? _chunkDone;
  static bool _inited = false;

  static Future<void> _init() async {
    if (_inited) return; _inited = true;
    await _sys.setLanguage('zh-CN');
    await _sys.setSpeechRate(0.5);
    _sys.setCompletionHandler(() { _chunkDone?.complete(); _chunkDone = null; });
    _sys.setCancelHandler(() { _chunkDone?.complete(); _chunkDone = null; });
  }

  // 当前引擎: system | 在线厂商id
  static Future<String> engine() async => (await SharedPreferences.getInstance()).getString('tts_engine') ?? 'system';
  static Future<void> setEngine(String v) async => (await SharedPreferences.getInstance()).setString('tts_engine', v);
  static Future<double> rate() async => (await SharedPreferences.getInstance()).getDouble('tts_rate') ?? 0.5;
  static Future<void> setRate(double v) async { (await SharedPreferences.getInstance()).setDouble('tts_rate', v); await _sys.setSpeechRate(v); }

  static void _set(TtsState s) { state = s; _stateC.add(s); }

  static List<String> split(String text, {int size = 400}) {
    final paras = text.split('\n').where((e) => e.trim().isNotEmpty).toList();
    final out = <String>[];
    for (final p in paras) {
      if (p.length <= size) { out.add(p.trim()); continue; }
      for (var i = 0; i < p.length; i += size) out.add(p.substring(i, (i + size).clamp(0, p.length)).trim());
    }
    return out;
  }

  static Future<void> speak(String text) async {
    await stop();
    await _init();
    _chunks = split(text); chunkTotal = _chunks.length; chunkIdx = 0; _stop = false;
    if (_chunks.isEmpty) return;
    _set(TtsState.playing);
    _session++;
    final eng = await engine();
    if (eng == 'system') { _speakSystem(_session); } else { _speakOnline(eng, _session); }
  }

  static Future<void> _speakSystem(int sess) async {
    await _sys.setSpeechRate(await rate());
    while (!_stop && sess == _session && chunkIdx < _chunks.length) {
      _chunkDone = Completer<void>();
      await _sys.speak(_chunks[chunkIdx]);
      await _chunkDone!.future.timeout(const Duration(minutes: 3), onTimeout: () {});
      if (state == TtsState.paused) return; // 暂停时退出循环, 恢复时从当前段重读
      chunkIdx++;
      _stateC.add(state); // 进度刷新
    }
    if (!_stop) _set(TtsState.idle);
  }

  static Future<void> _speakOnline(String providerId, int sess) async {
    final prov = AiRegistry.byId(providerId);
    if (prov == null) { _set(TtsState.idle); return; }
    final key = await AiRegistry.keyOf(providerId);
    if (key.isEmpty) { _set(TtsState.idle); return; }
    final model = (await SharedPreferences.getInstance()).getString('tts_model_$providerId') ??
        (prov.models.firstWhere((m) => m.contains('tts'), orElse: () => prov.models.isNotEmpty ? prov.models.first : 'tts-1'));
    final dir = await getTemporaryDirectory();
    while (!_stop && sess == _session && chunkIdx < _chunks.length) {
      try {
        final r = await http.post(Uri.parse('${prov.base}/audio/speech'),
          headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
          body: jsonEncode({'model': model, 'input': _chunks[chunkIdx], 'voice': 'alloy', 'response_format': 'mp3'}))
          .timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) { chunkIdx++; continue; }
        final f = File('${dir.path}/tts_$chunkIdx.mp3');
        await f.writeAsBytes(r.bodyBytes);
        await _player.setFilePath(f.path);
        await _player.play();
        await _player.playerStateStream.firstWhere((s) => s.processingState == ProcessingState.completed)
            .timeout(const Duration(minutes: 3), onTimeout: () => _player.playerState);
      } catch (_) {}
      if (state == TtsState.paused) return;
      chunkIdx++;
      _stateC.add(state);
    }
    if (!_stop) _set(TtsState.idle);
  }

  static Future<void> pause() async {
    if (state != TtsState.playing) return;
    _set(TtsState.paused);
    if (await engine() == 'system') { await _sys.stop(); _chunkDone?.complete(); _chunkDone = null; }
    else { await _player.pause(); }
  }

  static Future<void> resume() async {
    if (state != TtsState.paused) return;
    _set(TtsState.playing);
    if (await engine() == 'system') { /* 系统TTS从当前段重读 */ _speakSystem(_session); }
    else { await _player.play(); }
  }

  static Future<void> stop() async {
    _stop = true;
    try { await _sys.stop(); } catch (_) {}
    try { await _player.stop(); } catch (_) {}
    _chunkDone?.complete(); _chunkDone = null;
    if (state != TtsState.idle) _set(TtsState.idle);
  }

  static Future<void> nextChunk() async { if (chunkIdx < _chunks.length - 1) { await _skipTo(chunkIdx + 1); } }
  static Future<void> prevChunk() async { if (chunkIdx > 0) { await _skipTo(chunkIdx - 1); } }
  static Future<void> _skipTo(int i) async {
    final wasPlaying = state == TtsState.playing || state == TtsState.paused;
    if (!wasPlaying) return;
    try { await _sys.stop(); } catch (_) {}
    try { await _player.stop(); } catch (_) {}
    _chunkDone?.complete(); _chunkDone = null;
    chunkIdx = i;
    if (state == TtsState.paused) _set(TtsState.playing);
  }
}
