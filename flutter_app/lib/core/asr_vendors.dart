// 语音识别厂商 —— 规则层（纯 Dart，可自检）
//
// 为什么单独一层：协议形态差异极大（各家鉴权头、请求体、返回字段都不同），
// 与 tts_vendors.dart 同一手法 —— 规则层零依赖、实现层依赖 Flutter。
//
// 复用统一密钥库（api_keys.dart）：用户在 AI / 语音朗读里填过的同一家的 Key
// 这里直接带出，不用重复输入 —— 阿里 AI 叫 aliyun、这里叫 dashscope，KeyVendor
// 归一化已覆盖。
library;

import 'api_keys.dart';

/// 鉴权方式。
enum AsrAuth {
  bearer, // Authorization: Bearer <key>
  header, // 自定义头（api-key / x-api-key）
  query, // 放 URL 查询串
}

/// 返回形态。
enum AsrResp {
  jsonText, // JSON 某路径是文本（OpenAI 兼容转写 / 通义 / 小米）
  jsonDataUrl, // JSON 某路径是 data:audio/…;base64 音频（讯飞部分接口）
}

/// 语音识别厂商定义。
class AsrVendor {
  const AsrVendor({
    required this.id,
    required this.name,
    required this.group,
    required this.url,
    required this.auth,
    required this.bodyTpl,
    required this.textPath,
    required this.audioField,
    this.authHeader = '',
    this.contentType = 'application/json',
    this.models = const [],
    this.model = '',
    this.note = '',
    this.languages = const ['zh'],
    this.maxSeconds = 60,
  });

  final String id;
  final String name;
  final String group;

  /// 合成/识别地址（完整 URL）。
  final String url;
  final AsrAuth auth;

  /// 请求体模板。占位符：{model} {key} {audio} {language} {format}
  final String bodyTpl;

  /// 从响应里取识别文本的路径（点号分隔，如 `choices.0.message.content`）。
  final String textPath;

  /// 音频字段名（multipart 用 `file`，JSON base64 用 `audio`）。
  final String audioField;

  /// auth=header 时的头名。
  final String authHeader;
  final String contentType;

  /// 可选模型（为空表示该厂商只有一个模型）。
  final List<String> models;
  final String model;
  final String note;

  /// 支持的语言代码。
  final List<String> languages;

  /// 单次最长音频（秒）——超了要分段。
  final int maxSeconds;

  bool get needsKey => auth != AsrAuth.bearer || true;
}

/// 厂商表。
///
/// 排序即 UI 顺序：国内 → 海外 → 自托管。
class AsrVendors {
  const AsrVendors._();

  static const List<AsrVendor> all = [
    // ══ 国内 ══════════════════════════════════════════════
    AsrVendor(
      id: 'xiaomi',
      name: '小米 MiMo 语音识别',
      group: '国内',
      url: 'https://api.xiaomimimo.com/v1/audio/transcriptions',
      auth: AsrAuth.bearer,
      audioField: 'file',
      contentType: 'multipart/form-data',
      bodyTpl: '{"model":"{model}","language":"{language}","audio":"{audio}"}',
      textPath: 'text',
      models: ['mimo-v2.5-asr'],
      model: 'mimo-v2.5-asr',
      note: '与语音朗读共用同一把 Key（小米 MiMo 控制台申请）',
    ),
    AsrVendor(
      id: 'dashscope',
      name: '阿里百炼 · 通义听悟',
      group: '国内',
      url: 'https://dashscope.aliyuncs.com/compatible-mode/v1/audio/transcriptions',
      auth: AsrAuth.bearer,
      audioField: 'file',
      contentType: 'multipart/form-data',
      bodyTpl: '{"model":"{model}","language":"{language}","audio":"{audio}"}',
      textPath: 'text',
      models: ['paraformer-realtime-v2', 'qwen3-asr-flash'],
      model: 'paraformer-realtime-v2',
      note: '与 AI 里的阿里 Key 同源，不用重复填',
    ),
    AsrVendor(
      id: 'volc',
      name: '火山方舟 · 豆包语音',
      group: '国内',
      url: 'https://ark.cn-beijing.volces.com/api/v3/audio/transcriptions',
      auth: AsrAuth.bearer,
      audioField: 'file',
      contentType: 'multipart/form-data',
      bodyTpl: '{"model":"{model}","language":"{language}","audio":"{audio}"}',
      textPath: 'text',
      models: ['doubao-asr'],
      model: 'doubao-asr',
      note: '与 AI 里的火山 Key 同源',
    ),
    AsrVendor(
      id: 'silero',
      name: '自托管 · Whisper 兼容端点',
      group: '自托管',
      url: 'http://127.0.0.1:8000/v1/audio/transcriptions',
      auth: AsrAuth.bearer,
      audioField: 'file',
      contentType: 'multipart/form-data',
      bodyTpl: '{"model":"{model}","language":"{language}","audio":"{audio}"}',
      textPath: 'text',
      models: ['whisper-1'],
      model: 'whisper-1',
      note: '本机 / 局域网自建的 Whisper、faster-whisper、FunASR 等，填服务地址即可',
    ),
    AsrVendor(
      id: 'baidu',
      name: '百度语音识别',
      group: '国内',
      url: 'https://vop.baidu.com/server_api',
      auth: AsrAuth.bearer,
      audioField: 'audio',
      bodyTpl: '{"format":"pcm","rate":16000,"channel":1,"cuid":"thirdhub","token":"{key}","len":0,"speech":"{audio}"}',
      textPath: 'result',
      models: ['dev_pid:1537'],
      model: 'dev_pid:1537',
      note: '百度「文心」与「语音技术」是两套应用，Key 需要单独申请',
      languages: ['zh', 'en'],
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