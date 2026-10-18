// 语音识别厂商 —— 规则层（纯 Dart，可自检）
//
// ★ 2026-10-18 重写：上一版把「所有厂商」都当成 OpenAI 的
//   `/v1/audio/transcriptions` multipart 端点，**其中小米与百炼根本不存在这个端点**。
//   逐家对照官方文档后确认，市面上的语音识别实际只有三种形态：
//
//   ① [AsrShape.openaiMultipart]  POST /v1/audio/transcriptions，multipart 传文件
//      · OpenAI / Groq / 硅基流动 / 自托管 faster-whisper
//      · 返回 `{"text": "..."}`
//
//   ② [AsrShape.chatAudio]        POST /v1/chat/completions，音频以
//      `content:[{type:'input_audio',input_audio:{data:'data:audio/wav;base64,...'}}]`
//      塞进对话消息（**没有 multipart、也没有 /audio/transcriptions**）
//      · 小米 MiMo-V2.5-ASR（mimo.mi.com 官方示例就是 chat.completions + extra_body.asr_options）
//      · 阿里百炼 qwen3-asr-flash（compatible-mode 同样走 chat/completions）
//      · 返回文本在 `choices[0].message.content`
//      · 音频只收 base64 Data URL，**单条上限 10MB**
//
//   ③ [AsrShape.rawJson]          各家私有 JSON + 私有头
//      · 火山「豆包语音」录音文件识别极速版：openspeech.bytedance.com，
//        头要 `X-Api-Key`(UUID) + `X-Api-Resource-Id` + `X-Api-Request-Id`，
//        返回 `body.result.text`
//      · 百度短语音：先 `aip.baidubce.com/oauth/2.0/token` 换 access_token，
//        再 POST `vop.baidu.com/server_api?token=...`，body 里 `speech` 是 base64，
//        **`len` 必须是原始音频字节数**（填 0 必失败）
//
// 复用统一密钥库（api_keys.dart）：用户在 AI / 语音朗读里填过的同一家 Key，
// 这里直接带出，不用重复输入 —— 阿里 AI 叫 aliyun、这里叫 dashscope，
// KeyVendor 归一化已覆盖。
library;

import 'api_keys.dart';

/// 鉴权方式。
enum AsrAuth {
  bearer, // Authorization: Bearer <key>
  header, // 自定义头（api-key / x-api-key / X-Api-Key）
  query, // 放 URL 查询串
  none, // 自托管不需要
}

/// 请求形态 —— 见文件头注释。
enum AsrShape {
  openaiMultipart,
  chatAudio,
  rawJson,
}

/// 语音识别厂商定义。
class AsrVendor {
  const AsrVendor({
    required this.id,
    required this.name,
    required this.group,
    required this.url,
    required this.shape,
    required this.textPath,
    this.auth = AsrAuth.bearer,
    this.authHeader = '',
    this.model = '',
    this.models = const [],
    this.bodyTpl = '',
    this.audioField = 'file',
    this.extraHeaders = const {},
    this.tokenUrl = '',
    this.asrOptions = false,
    this.note = '',
    this.languages = const ['zh', 'en'],
    this.maxSeconds = 60,
    this.maxBytes = 10 * 1024 * 1024,
  });

  final String id;
  final String name;
  final String group;

  /// 请求地址（完整 URL）。自托管用 `{host}` 占位。
  final String url;
  final AsrShape shape;

  /// 从响应里取识别文本的路径（点号分隔）。
  final String textPath;

  final AsrAuth auth;
  final String authHeader;

  /// 默认模型。
  final String model;
  final List<String> models;

  /// `rawJson` 用的请求体模板。
  /// 占位符：`{model} {key} {language} {format} {audio} {len} {token}`
  final String bodyTpl;
  final String audioField;

  /// 额外请求头（`rawJson` 用）。值里可用 `{key}`。
  final Map<String, String> extraHeaders;

  /// 需要先换 token 时的换取地址（百度）。空 = 不需要。
  final String tokenUrl;

  /// 是否接受 `asr_options` 字段（小米 / 百炼）。
  final bool asrOptions;

  final String note;
  final List<String> languages;
  final int maxSeconds;

  /// 单次音频体积上限（字节）。小米官方为 base64 后 10MB。
  final int maxBytes;

  bool get needsKey => auth != AsrAuth.none;

  /// 该形态只收 base64（要提前把文件读进内存）。
  bool get needsBase64 => shape != AsrShape.openaiMultipart;
}

/// 厂商表。排序即 UI 顺序：国内 → 海外 → 自托管。
class AsrVendors {
  const AsrVendors._();

  static const List<AsrVendor> all = [
    // ══ 国内 ══════════════════════════════════════════════
    AsrVendor(
      id: 'xiaomi',
      name: '小米 MiMo 语音识别',
      group: '国内',
      // ★官方示例：OpenAI SDK base_url=.../v1 + chat.completions + extra_body.asr_options
      url: 'https://api.xiaomimimo.com/v1/chat/completions',
      shape: AsrShape.chatAudio,
      textPath: 'choices.0.message.content',
      asrOptions: true,
      models: ['mimo-v2.5-asr'],
      model: 'mimo-v2.5-asr',
      note: '只收 wav / mp3，base64 后上限 10MB；与语音朗读共用同一把 Key',
    ),
    AsrVendor(
      id: 'dashscope',
      name: '阿里百炼 · 通义千问 ASR',
      group: '国内',
      url: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
      shape: AsrShape.chatAudio,
      textPath: 'choices.0.message.content',
      asrOptions: true,
      models: ['qwen3-asr-flash'],
      model: 'qwen3-asr-flash',
      note: '与 AI 里的阿里 Key 同源，不用重复填',
    ),
    AsrVendor(
      id: 'siliconflow',
      name: '硅基流动 · SenseVoice',
      group: '国内',
      url: 'https://api.siliconflow.cn/v1/audio/transcriptions',
      shape: AsrShape.openaiMultipart,
      textPath: 'text',
      models: ['FunAudioLLM/SenseVoiceSmall', 'TeleAI/TeleSpeechASR'],
      model: 'FunAudioLLM/SenseVoiceSmall',
      note: '中文效果好；与 AI 里的硅基流动 Key 同源',
    ),
    AsrVendor(
      id: 'volc',
      name: '火山 · 豆包语音识别',
      group: '国内',
      url: 'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
      shape: AsrShape.rawJson,
      textPath: 'body.result.text',
      auth: AsrAuth.header,
      authHeader: 'X-Api-Key',
      extraHeaders: {
        'X-Api-Resource-Id': 'volc.bigasr.auc_turbo',
        'X-Api-Request-Id': '{reqid}',
        'X-Api-Sequence': '-1',
      },
      bodyTpl: '{"user":{"uid":"thirdhub"},'
          '"audio":{"data":"{audio}","format":"{format}","rate":16000,"bits":16,"channel":1},'
          '"request":{"model_name":"bigmodel","enable_itn":true,"enable_punc":true}}',
      model: 'bigmodel',
      note: 'Key 要填「豆包语音」控制台（console.volcengine.com/speech/new）的 UUID，'
          '不是方舟的 sk- Key',
    ),
    AsrVendor(
      id: 'baidu',
      name: '百度语音识别',
      group: '国内',
      url: 'https://vop.baidu.com/server_api?dev_pid=1537&cuid=thirdhub&token={token}',
      shape: AsrShape.rawJson,
      textPath: 'result.0',
      auth: AsrAuth.none, // token 走 URL
      tokenUrl: 'https://aip.baidubce.com/oauth/2.0/token',
      bodyTpl: '{"format":"{format}","rate":16000,"channel":1,"cuid":"thirdhub",'
          '"token":"{token}","len":{len},"speech":"{audio}"}',
      model: '1537',
      note: 'Key 要按「APIKey|SecretKey」两段填（中间一根竖线）；'
          '百度「文心」与「语音技术」是两套应用，Key 需单独申请',
    ),

    // ══ 海外 ══════════════════════════════════════════════
    AsrVendor(
      id: 'openai',
      name: 'OpenAI · Whisper',
      group: '海外',
      url: 'https://api.openai.com/v1/audio/transcriptions',
      shape: AsrShape.openaiMultipart,
      textPath: 'text',
      models: ['gpt-4o-mini-transcribe', 'whisper-1'],
      model: 'gpt-4o-mini-transcribe',
      note: '与 AI 里的 OpenAI Key 同源',
    ),
    AsrVendor(
      id: 'groq',
      name: 'Groq · Whisper',
      group: '海外',
      url: 'https://api.groq.com/openai/v1/audio/transcriptions',
      shape: AsrShape.openaiMultipart,
      textPath: 'text',
      models: ['whisper-large-v3-turbo', 'whisper-large-v3'],
      model: 'whisper-large-v3-turbo',
      note: '速度极快，免费额度足够日常用',
    ),

    // ══ 自托管 ════════════════════════════════════════════
    AsrVendor(
      id: 'selfhost',
      name: '自托管 · Whisper 兼容端点',
      group: '自托管',
      url: '{host}/v1/audio/transcriptions',
      shape: AsrShape.openaiMultipart,
      textPath: 'text',
      auth: AsrAuth.none,
      models: ['whisper-1'],
      model: 'whisper-1',
      languages: ['auto', 'zh', 'en', 'ja', 'ko'],
      maxSeconds: 3600,
      maxBytes: 200 * 1024 * 1024,
      note: '本机 / 局域网自建的 faster-whisper、FunASR、whisper.cpp server，'
          '填服务地址即可（形如 http://192.168.1.5:8000）',
    ),
  ];

  static AsrVendor? byId(String id) {
    for (final v in all) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// 按统一密钥库归一化找厂商（AI 叫 aliyun → 这里 dashscope）。
  static AsrVendor? byAnyName(String id) {
    if (KeyVendor.same(id, 'dashscope')) return byId('dashscope');
    if (KeyVendor.same(id, 'volc')) return byId('volc');
    return byId(KeyVendor.canonical(id));
  }

  /// 该厂商收哪些音频扩展名（用于选录音编码）。
  ///
  /// 小米只收 wav/mp3 —— 若按默认 `record` 的 m4a 录，会直接被拒。
  static List<String> acceptedExts(AsrVendor v) {
    if (v.id == 'xiaomi') return const ['wav', 'mp3'];
    return const ['wav', 'mp3', 'm4a', 'ogg', 'flac', 'webm'];
  }
}

/// 识别结果异常（带厂商名与厂商原话，便于用户自查 Key/额度）。
class AsrException implements Exception {
  AsrException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 响应解析：按点号路径取值。
String? pickJsonPath(dynamic j, String path) {
  dynamic cur = j;
  for (final seg in path.split('.')) {
    if (cur is Map && cur.containsKey(seg)) {
      cur = cur[seg];
    } else if (cur is List && int.tryParse(seg) != null) {
      final i = int.tryParse(seg)!;
      if (i < cur.length) {
        cur = cur[i];
      } else {
        return null;
      }
    } else {
      return null;
    }
  }
  return cur?.toString();
}

/// 音频 MIME 类型（小米 / 百炼的 Data URL 必须要对，写错会被拒）。
String audioMime(String ext) {
  switch (ext.toLowerCase()) {
    case 'wav':
      return 'audio/wav';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'ogg':
    case 'opus':
      return 'audio/ogg';
    case 'flac':
      return 'audio/flac';
    case 'webm':
      return 'audio/webm';
  }
  return 'audio/wav';
}
