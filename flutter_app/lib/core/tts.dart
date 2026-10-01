// 听书四条通道：
//   system     —— 系统离线 TTS(flutter_tts)，零配置
//   online:<id> —— 在线 AI TTS(OpenAI 兼容 /audio/speech)
//   backend    —— 家庭后端合成(/v1/tts，后端决定 piper / edge)
//   opensource —— **用户自己跑的开源引擎**直连（TTS/1 协议，D-C3）
import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'tts_presets.dart';
import 'tts_direct.dart';
import 'tts_online.dart';
import 'tts_vendors.dart';
import 'play_tag.dart';

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

  // 当前引擎: system | backend | opensource | 在线厂商id
  static Future<String> engine() async => (await SharedPreferences.getInstance()).getString('tts_engine') ?? 'system';
  static Future<void> setEngine(String v) async => (await SharedPreferences.getInstance()).setString('tts_engine', v);

  /// 给界面看的引擎显示名。
  /// ★ 不能把内部 id 直接摆给用户 —— `siliconflow` / `opensource` 这种字符串
  ///   在界面上等于没说，用户无从判断"现在到底用哪个在念"。
  static Future<String> engineLabel() async {
    final e = await engine();
    if (e == 'system') return '系统离线朗读';
    if (e == 'backend') return '家庭后端合成';
    if (e == 'opensource') return '开源引擎直连';
    final v = await TtsOnline.vendorOf(e);
    return v?.name ?? '未配置（$e）';
  }

  /// 自动朗读 AI 回复的开关（AI 对话里用）。
  static Future<bool> autoRead() async =>
      (await SharedPreferences.getInstance()).getBool('tts_auto_read') ?? false;
  static Future<void> setAutoRead(bool v) async =>
      (await SharedPreferences.getInstance()).setBool('tts_auto_read', v);

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
    if (eng == 'system') { _speakSystem(_session); }
    else if (eng == 'backend') { _speakBackend(_session); }
    else if (eng == 'opensource') { _speakOpenSource(_session); }
    else { _speakOnline(eng, _session); }
  }

  // 后端合成（D-C2）：文本发给用户自己的家庭后端，piper(离线)/edge-tts(在线) 合成后返回音频。
  // 失败时逐段降级提示，最后统一回退系统 TTS，绝不让"听书点了没反应"。
  static String backendError = '';
  static Future<void> _speakBackend(int sess) async {
    backendError = '';
    while (!_stop && sess == _session && chunkIdx < _chunks.length) {
      try {
        final f = await TtsBackend.synthesize(_chunks[chunkIdx]);
        await _player.setAudioSource(tagFile(f, title: '听书 · 第 ${chunkIdx + 1}/$chunkTotal 段', album: 'ThirdHub 听书'));
        await _player.play();
        await _player.playerStateStream.firstWhere((s) => s.processingState == ProcessingState.completed)
            .timeout(const Duration(minutes: 3), onTimeout: () => _player.playerState);
      } catch (e) {
        backendError = '$e';
        // 后端合成失败 → 从当前段降级到系统 TTS，保证"点了就有声音"
        await setEngine('system');
        _speakSystem(sess);
        return;
      }
      if (state == TtsState.paused) return;
      chunkIdx++;
      _stateC.add(state);
    }
    if (!_stop) _set(TtsState.idle);
  }

  // 开源引擎直连（D-C3，TTS/1 协议）：文本 → 用户自己跑的那台引擎 → 音频字节。
  // 与 _speakBackend 同构：失败就逐段降级到系统 TTS，绝不让"点了没反应"。
  //
  // 与 backend 通道的关键差异：**地址由用户在「开源 TTS 引擎」页里自己填**
  // （存 `tts_os_url`），不依赖家庭后端是否在线。
  static String openSourceError = '';
  static Future<void> _speakOpenSource(int sess) async {
    openSourceError = '';
    final p = await SharedPreferences.getInstance();
    final url = p.getString('tts_os_url') ?? '';
    if (url.isEmpty) {
      // 没填地址却选了这条通道，是配置问题而不是网络问题 —— 直接降级并说明，
      // 不静默什么都不做（静默的话用户只会觉得"听书坏了"）。
      openSourceError = '还没配置开源 TTS 引擎地址';
      await setEngine('system');
      _speakSystem(sess);
      return;
    }
    while (!_stop && sess == _session && chunkIdx < _chunks.length) {
      try {
        final f = await TtsDirect.synthesize(url, _chunks[chunkIdx]);
        await _player.setAudioSource(tagFile(f,
            title: '听书 · 第 ${chunkIdx + 1}/$chunkTotal 段',
            album: 'ThirdHub 听书'));
        await _player.play();
        await _player.playerStateStream
            .firstWhere((s) => s.processingState == ProcessingState.completed)
            .timeout(const Duration(minutes: 3),
                onTimeout: () => _player.playerState);
      } catch (e) {
        openSourceError = '$e';
        await setEngine('system');
        _speakSystem(sess);
        return;
      }
      if (state == TtsState.paused) return;
      chunkIdx++;
      _stateC.add(state);
    }
    if (!_stop) _set(TtsState.idle);
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

  // 在线厂商（D-C1，走 `tts_vendors.dart` 注册表 + `tts_online.dart` 执行层）。
  //
  // ★ 与旧实现的差别（这是"填了 Key 却没声音"的根因）：
  //   过去这里是从 **AI 厂商注册表** 取 base_url 与 key，再自行拼上
  //   `/audio/speech` —— 后果有两个：
  //     ① 想用某个 TTS 厂商，必须先去「AI 模块」把它当成一个 AI 厂商配进去，
  //        配的地方与用的地方不在一处，用户根本找不到；
  //     ② 只能接 OpenAI 兼容的那一小撮，MiniMax 的 hex、阿里的"返回音频地址"、
  //        火山的 base64 分块、百度要换 token 的表单，一个都接不了。
  //   现在 TTS 有自己的厂商表、自己的 Key 存储、自己的请求构造。
  static String onlineError = '';
  static Future<void> _speakOnline(String vendorId, int sess) async {
    onlineError = '';
    final vendor = await TtsOnline.vendorOf(vendorId);
    if (vendor == null) {
      onlineError = '找不到这个语音厂商（配置可能已被删除）';
      await setEngine('system');
      _speakSystem(sess);
      return;
    }
    while (!_stop && sess == _session && chunkIdx < _chunks.length) {
      try {
        final f = await TtsOnline.synthesize(vendor, _chunks[chunkIdx]);
        await _player.setAudioSource(tagFile(f,
            title: '听书 · 第 ${chunkIdx + 1}/$chunkTotal 段',
            album: 'ThirdHub 听书'));
        await _player.play();
        await _player.playerStateStream
            .firstWhere((s) => s.processingState == ProcessingState.completed)
            .timeout(const Duration(minutes: 3),
                onTimeout: () => _player.playerState);
      } catch (e) {
        // 失败逐段降级到系统朗读，并把**原因**留给界面显示 ——
        // 静默降级的话用户只会觉得"听书坏了"，永远不知道该去改 Key。
        onlineError = '$e';
        await setEngine('system');
        _speakSystem(sess);
        return;
      }
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
