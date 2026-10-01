// 开源 TTS 引擎**直连客户端**（D-C3）—— 实现 `docs/TTS-PROTOCOL.md` 的 TTS/1。
//
// 与 `TtsBackend`（家庭后端通道）的区别：
//   · `TtsBackend` 走**你自己的家庭后端** `/v1/tts`，由后端决定用 piper 还是 edge；
//   · 本类走**你直接跑起来的那台开源引擎**（电脑/旧手机/NAS 上的 :5100 之类），
//     不经过家庭后端。两者并存，用户在听书设置里选。
//
// ★ 为什么自检要**真的合一句短句并落盘**，而不是只看 /health 过没过：
//   `/health` 通了只证明"HTTP 活着、声明像 TTS/1"；真正坏掉的是合成这一段
//   （模型没加载、显存不足、音色名不对）。历史上本项目在"连接测试通过、
//   实际用不了"上吃过不止一次亏（引擎 :1234 / 资源库 :9527 那次最典型）。
//   所以自检必须走到"拿到音频字节"为止。
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'tts_engines_logic.dart';

class TtsDirect {
  static const _probeTimeout = Duration(seconds: 4);
  static const _synthTimeout = Duration(seconds: 60);

  /// 自检用的短句。选它是因为**短**（省时间）且**含中文**（能暴露编码问题）。
  static const String sampleText = '连接成功。';

  static HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 4);

  /// 探一次 `/health`。永不抛异常 —— 全部收成 [TtsProbeResult]，
  /// 让 UI 只处理一种返回值（抛异常会逼每个调用点各写一遍 try）。
  static Future<TtsProbeResult> probe(String rawUrl) async {
    final u = normalizeTtsUrl(rawUrl);
    if (u == null) {
      return const TtsProbeResult(kind: TtsProbe.badUrl, detail: '空地址或无法解析');
    }
    final c = _client();
    try {
      final req = await c
          .getUrl(Uri.parse('$u/health'))
          .timeout(_probeTimeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(_probeTimeout);
      final bytes = await resp.expand((x) => x).toList();
      final body = utf8.decode(bytes, allowMalformed: true);
      final ct = '${resp.headers.contentType}';
      if (resp.statusCode != 200) {
        return TtsProbeResult(
          kind: TtsProbe.unhealthy,
          detail: 'HTTP ${resp.statusCode} —— $u/health',
          engine: '',
        );
      }
      // 拿 HTML 来解析 JSON 是最容易把"填错地址"误判成"引擎不健康"的地方，
      // 所以先用 Content-Type 挡一道，再交给纯函数判定。
      final isJson = ct.contains('json') || body.trimLeft().startsWith('{');
      return parseHealth(body, wasJson: isJson);
    } catch (e) {
      return TtsProbeResult(kind: TtsProbe.unreachable, detail: '$e');
    } finally {
      c.close(force: true);
    }
  }

  /// 合成一段文本 → 本地音频文件路径。失败抛异常（调用方降级/提示）。
  ///
  /// 返回的扩展名**按响应 Content-Type 决定**，不猜：
  /// 猜错的表现是"音频文件存下来了但播放器打不开"，而错误现场已经消失。
  static Future<String> synthesize(
    String baseUrl,
    String text, {
    String voice = '',
    String format = '',
    TtsProbeResult? caps,
  }) async {
    final u = normalizeTtsUrl(baseUrl);
    if (u == null) throw Exception('TTS 引擎地址无效');
    final v = voice.isNotEmpty
        ? voice
        : (caps?.defaultVoice.isNotEmpty == true ? caps!.defaultVoice : '');
    final f = format.isNotEmpty
        ? format
        : (caps?.formats.isNotEmpty == true ? caps!.formats.first : 'wav');

    final c = _client();
    try {
      final req =
          await c.postUrl(Uri.parse('$u/synthesize')).timeout(_probeTimeout);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'text': text,
        if (v.isNotEmpty) 'voice': v,
        if (f.isNotEmpty) 'format': f,
      }));
      final resp = await req.close().timeout(_synthTimeout);
      if (resp.statusCode != 200) {
        final bytes = await resp.expand((x) => x).toList();
        var msg = 'HTTP ${resp.statusCode}';
        try {
          final j = jsonDecode(utf8.decode(bytes, allowMalformed: true));
          msg = '${j['error']?['message'] ?? j['message'] ?? msg}';
        } catch (_) {}
        throw Exception(msg);
      }
      final bytes = await resp.expand((x) => x).toList();
      if (bytes.isEmpty) throw Exception('引擎返回了 0 字节音频');
      final ct = '${resp.headers.contentType}'.toLowerCase();
      final ext = ct.contains('wav')
          ? 'wav'
          : ct.contains('ogg')
              ? 'ogg'
              : ct.contains('mp4') || ct.contains('m4a')
                  ? 'm4a'
                  : 'mp3';
      final dir = await Directory.systemTemp.createTemp('th_tts_direct');
      final out = File(
          '${dir.path}/seg_${DateTime.now().microsecondsSinceEpoch}.$ext');
      await out.writeAsBytes(bytes);
      return out.path;
    } finally {
      c.close(force: true);
    }
  }

  /// 自检的**第二步**：合成 [sampleText] 并落盘，返回结论 + 落盘路径。
  ///
  /// 为什么要返回路径而不是布尔：让 UI 能顺手**播放它**——
  /// "听到声音"是唯一无法伪造的成功判据。
  static Future<({bool ok, String path, String detail})> verifySynth(
      String baseUrl, TtsProbeResult? caps) async {
    try {
      final p = await synthesize(baseUrl, sampleText, caps: caps);
      final size = await File(p).length();
      if (size < 256) {
        return (ok: false, path: '', detail: '合成的音频只有 $size 字节，不像是有效音频');
      }
      return (ok: true, path: p, detail: '');
    } catch (e) {
      return (ok: false, path: '', detail: '$e');
    }
  }

  /// 把"本机连上了一台开源 TTS 引擎"这件事写进日志（D-D2 的引擎类埋点）。
  /// 与 `EngineDirect` 的埋点同一口径：连上要记、失败要记原因。
  static Future<void> logProbe(String url, TtsProbeResult r) async {
    if (r.ok) {
      await AppLog.engine('已连接开源 TTS 引擎', d: {
        'url': url,
        'engine': r.engine,
        'sample_rate': r.sampleRate,
        'voices': r.voices.length,
      });
    } else {
      await AppLog.warn('engine', '开源 TTS 引擎连接失败', d: {
        'url': url,
        'kind': '${r.kind}',
        'detail': r.detail,
      });
    }
  }
}
