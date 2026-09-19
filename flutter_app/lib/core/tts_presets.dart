// 听书 TTS 厂商预设（D-04/D-C1）+ 后端合成通道（D-C2）。
//
// 三条路：
//  1. system —— 系统离线 TTS（flutter_tts），零配置零费用，音质一般；
//  2. 在线厂商 —— 走 OpenAI 兼容的 POST {base}/audio/speech（Authorization: Bearer key）；
//  3. backend —— 前端把文本发给自己的家庭后端 POST /v1/tts，后端用 piper(离线开源) 或
//     edge-tts(在线微软免费) 合成后返回音频。流量只到用户自己的后端。
//
// 预设表只收 **OpenAI 兼容 /audio/speech** 的厂商（能直接跑通）；讯飞/腾讯/百度是私有协议，
// 需要各自适配器，登记在 [kTtsNotes] 里说明接法，不假装支持。
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class TtsPreset {
  final String id, name, base, defaultModel;
  final List<String> voices;
  final String note;
  const TtsPreset(this.id, this.name, this.base, this.defaultModel, this.voices, this.note);
}

/// OpenAI 兼容 /audio/speech 的主流厂商预设。
const kTtsPresets = <TtsPreset>[
  TtsPreset('siliconflow', '硅基流动 SiliconFlow', 'https://api.siliconflow.cn/v1',
      'FunAudioLLM/CosyVoice2-0.5B',
      ['FunAudioLLM/CosyVoice2-0.5B:alex', 'FunAudioLLM/CosyVoice2-0.5B:anna', 'FunAudioLLM/CosyVoice2-0.5B:bella'],
      '国内可直连 · 托管 CosyVoice/Fish-Speech 等开源引擎 · 有免费额度'),
  TtsPreset('openai', 'OpenAI', 'https://api.openai.com/v1', 'tts-1',
      ['alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer'], '官方 · 需自备代理与付费 Key'),
  TtsPreset('minimax', 'MiniMax 海螺', 'https://api.minimaxi.com/v1', 'speech-02-hd',
      ['male-qn-qingse', 'female-shaonv', 'presenter_male', 'audiobook_male_1', 'audiobook_female_1'],
      '国内 · 有声书音色较全'),
  TtsPreset('qwen', '阿里百炼', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'cosyvoice-v2',
      ['longxiaochun', 'longwan', 'longhua'], '国内 · OpenAI 兼容模式'),
  TtsPreset('volc', '火山方舟', 'https://ark.cn-beijing.volces.com/api/v3', 'doubao-tts',
      ['zh_female_cancan_mars_bigtts', 'zh_male_shaonianzixin_mars_bigtts'], '国内 · 豆包语音'),
];

/// 私有协议厂商（需要适配器，当前版本登记说明，未直接支持）。
const kTtsNotes = <String>[
  '讯飞 / 腾讯 / 百度 TTS 是私有 WebSocket/签名协议，后续版本做适配器接入；',
  '开源离线引擎（piper / sherpa-onnx）：装到你自己的后端上即可用「后端合成」通道调用，见 我的→系统→资源库；',
  'edge-tts（微软在线朗读，免费）：后端 `pip install edge-tts` 即自动启用。',
];

/// 后端合成：文本 → 后端 /v1/tts → 音频字节。抛异常时由调用方降级。
class TtsBackend {
  static String base = '';   // 由 main.dart 在连上后端后写入 Api.base
  static String token = '';  // Api.token

  static bool get available => base.isNotEmpty;

  /// 探测后端 TTS 能力：{piper: bool, edge: bool, voices: [...]}。失败返回 null。
  static Future<Map<String, dynamic>?> cap() async {
    if (!available) return null;
    try {
      final c = HttpClient()..badCertificateCallback = (_, __, ___) => true;
      final req = await c.getUrl(Uri.parse('$base/v1/tts/cap'))
          .timeout(const Duration(seconds: 8));
      req.headers.set('X-TH-Token', token);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.expand((c2) => c2).toList();
      final j = jsonDecode(utf8.decode(body));
      if (j['object'] == 'meta' && j['data'] is Map) {
        return Map<String, dynamic>.from(j['data']);
      }
    } catch (_) {}
    return null;
  }

  /// 合成一段文本 → 音频文件路径（已写临时目录）。失败抛异常（调用方负责降级/提示）。
  static Future<String> synthesize(String text, {String engine = 'auto', String voice = 'zh-CN-XiaoxiaoNeural'}) async {
    if (!available) throw Exception('未连接后端');
    final c = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    final req = await c.postUrl(Uri.parse('$base/v1/tts')).timeout(const Duration(seconds: 10));
    req.headers.set('X-TH-Token', token);
    req.headers.set('Content-Type', 'application/json');
    req.write(jsonEncode({'text': text, 'engine': engine, 'voice': voice}));
    final resp = await req.close().timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      final body = await resp.expand((c2) => c2).toList();
      String msg = 'HTTP ${resp.statusCode}';
      try {
        final j = jsonDecode(utf8.decode(body));
        msg = j['data']?['message'] ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
    final bytes = await resp.expand((c2) => c2).toList();
    final ct = resp.headers.value('content-type') ?? 'audio/mpeg';
    final ext = ct.contains('wav') ? 'wav' : 'mp3';
    final dir = await Directory.systemTemp.createTemp('th_tts');
    final f = File('${dir.path}/seg_${DateTime.now().microsecondsSinceEpoch}.$ext');
    await f.writeAsBytes(bytes);
    return f.path;
  }
}
