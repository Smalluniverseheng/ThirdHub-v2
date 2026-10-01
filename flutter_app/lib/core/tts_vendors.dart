// 在线 TTS 厂商注册表 + 请求构建 + 响应解析（**纯数据与纯函数，零 Flutter 依赖**）。
//
// 为什么单独一层：各家的接口差异**不在协议上，而在字段名和位置上** ——
// 同样是"合成一句话"，有的把文本叫 `input`、有的叫 `text`、有的叫 `transcript`、
// 有的叫 `data`；音色有的放 body、有的塞 URL 路径（ElevenLabs）、有的放请求头
// （Fish Audio）；鉴权有的 `Bearer`、有的 `Token`、有的裸 key、有的要两个头；
// 响应有的直接给音频、有的给 base64、有的给 hex、有的给一个 24 小时有效的下载地址。
//
// 这类"错一个字段名就静默没声音"的东西**必须能被自检覆盖**，而纯 Dart VM 不能
// import `package:flutter/material.dart` —— 所以照 `ui_icon_map.dart` /
// `tts_engines_logic.dart` 的老规矩：判定与构建逻辑放这一层，
// `tool/tts_vendors_selfcheck.dart` 直接 import 它跑断言。
//
// 数据来源：2026-10-01 逐家查官方文档核对（见各条 docUrl），
// 凡未在官方文档核实的项在 note 里写明，不假装确定。
import 'dart:convert';
import 'dart:typed_data';

/// 鉴权方式。
enum TtsAuth {
  none, // 自托管，无鉴权
  bearer, // Authorization: Bearer <key>
  header, // 自定义头名（xi-api-key / api-key / Ocp-Apim-Subscription-Key…）
  query, // 放在 URL 查询参数里
  baidu, // 两步：先用 AK|SK 换 access_token，再带 tok= 调合成
}

/// 请求体形态。
enum TtsBody { json, form, ssml }

/// 响应形态 —— **四种真实存在，必须靠配置区分**。
enum TtsResp {
  binary, // 响应体就是音频字节
  jsonBase64, // JSON 里某路径是 base64 音频
  jsonUrl, // JSON 里某路径是一个音频下载地址（要再下一次）
  jsonHex, // JSON 里某路径是 hex 编码音频（MiniMax）
  jsonChunks, // 分块/拼接的 JSON 流，音频是若干 base64 片段（火山 V3）
}

/// 接入难度分级。
///
/// ★ 这个分级是**给用户看的诚实标签**，不是装饰：
/// `ready` 才是"填个 Key 就能用"；`needSign` 的必须由客户端算签名/token，
/// 本轮**没有**实现，所以 UI 上要明确区分，绝不能让它看起来能用。
enum TtsTier {
  ready, // 填 Key（或服务地址）即用
  needSign, // 需要客户端签名/token 交换 —— 未实现
}

class TtsVendor {
  final String id;
  final String name;
  final String group; // 国内 / 海外 / 自托管
  final TtsTier tier;
  final String note;

  /// 完整 URL。支持占位符：`{host}` `{voice}` `{model}` `{region}`
  final String url;
  final String method;
  final TtsAuth auth;
  final String authHeader; // auth == header 时的头名
  final String authValue; // 值模板，`{key}` 会被替换
  final Map<String, String> extraHeaders; // 额外固定头

  final TtsBody body;
  final String bodyTpl; // 模板，支持 `{text}` `{voice}` `{model}` `{format}` `{speed}` `{key}`

  final TtsResp resp;
  final String audioPath; // JSON 取值路径，如 `data.audio` / `output.audio.url`
  final String encoding; // base64 | hex

  final List<String> voices;
  final List<String> models;
  final String voice; // 默认音色
  final String model; // 默认模型
  final String format; // 默认输出格式

  final bool needRegion; // region 拼进域名（Azure）
  final bool needHost; // 自托管：URL 里的 {host} 要用户填
  final String docUrl;

  const TtsVendor({
    required this.id,
    required this.name,
    required this.group,
    required this.note,
    this.tier = TtsTier.ready,
    required this.url,
    this.method = 'POST',
    this.auth = TtsAuth.bearer,
    this.authHeader = 'Authorization',
    this.authValue = 'Bearer {key}',
    this.extraHeaders = const {},
    this.body = TtsBody.json,
    required this.bodyTpl,
    this.resp = TtsResp.binary,
    this.audioPath = '',
    this.encoding = 'base64',
    this.voices = const [],
    this.models = const [],
    this.voice = '',
    this.model = '',
    this.format = 'mp3',
    this.needRegion = false,
    this.needHost = false,
    this.docUrl = '',
  });

  /// OpenAI 兼容系（body 就是 `{model,input,voice,response_format}`）。
  /// 抽出来是为了让自托管那一批不用每家重写一遍模板。
  bool get isOpenAiShape => bodyTpl.contains('"input": "{text}"');
}

const String _oaTpl =
    '{"model":"{model}","input":"{text}","voice":"{voice}","response_format":"{format}"}';

/// ── 内置厂商表 ──────────────────────────────────────────────────────────
///
/// 排序即 UI 顺序：国内 → 海外 → 自托管。同组内按"填 Key 后最可能一次跑通"排。
const List<TtsVendor> kTtsVendors = [
  // ══ 国内 ══════════════════════════════════════════════════════════════
  TtsVendor(
    id: 'siliconflow',
    name: '硅基流动 SiliconFlow',
    group: '国内',
    note: '完全 OpenAI 兼容 · 托管 CosyVoice/Fish-Speech 等开源引擎 · 有免费额度',
    url: 'https://api.siliconflow.cn/v1/audio/speech',
    bodyTpl: _oaTpl,
    voices: [
      'FunAudioLLM/CosyVoice2-0.5B:alex',
      'FunAudioLLM/CosyVoice2-0.5B:anna',
      'FunAudioLLM/CosyVoice2-0.5B:bella',
      'FunAudioLLM/CosyVoice2-0.5B:benjamin',
      'FunAudioLLM/CosyVoice2-0.5B:charles',
    ],
    voice: 'FunAudioLLM/CosyVoice2-0.5B:anna',
    model: 'FunAudioLLM/CosyVoice2-0.5B',
    models: ['FunAudioLLM/CosyVoice2-0.5B', 'fishaudio/fish-speech-1.5'],
    docUrl: 'https://docs.siliconflow.cn/cn/userguide/capabilities/text-to-speech',
  ),
  TtsVendor(
    id: 'zhipu',
    name: '智谱 GLM-TTS',
    group: '国内',
    note: 'OpenAI 风格路径与字段 · 国内直连',
    url: 'https://open.bigmodel.cn/api/paas/v4/audio/speech',
    bodyTpl:
        '{"model":"{model}","input":"{text}","voice":"{voice}","response_format":"{format}"}',
    voices: ['female', 'tongtong', 'male'],
    voice: 'tongtong',
    model: 'glm-tts',
    models: ['glm-tts'],
    format: 'wav',
    docUrl: 'https://docs.bigmodel.cn/cn/guide/models/sound-and-video/glm-tts',
  ),
  TtsVendor(
    id: 'stepfun',
    name: '阶跃星辰 Step-TTS',
    group: '国内',
    note: 'OpenAI 风格路径与字段 · 中文音色较多',
    url: 'https://api.stepfun.com/v1/audio/speech',
    bodyTpl:
        '{"model":"{model}","input":"{text}","voice":"{voice}","response_format":"{format}"}',
    voices: [
      'cixingnansheng',
      'wenrounansheng',
      'boyinnansheng',
      'shenchennanyin',
      'tianmeinvsheng',
      'qingchunshaonv',
      'elegantgentle-female',
      'ruyananshi',
    ],
    voice: 'boyinnansheng',
    model: 'step-tts-mini',
    models: ['step-tts-mini', 'step-tts-2', 'stepaudio-2.5-tts'],
    docUrl: 'https://platform.stepfun.com/docs/zh/guide/tts',
  ),
  TtsVendor(
    id: 'minimax',
    name: 'MiniMax 海螺',
    group: '国内',
    note: '有声书音色较全 · 返回 hex 编码音频（不是 base64，已按真实格式处理）',
    url: 'https://api.minimax.cn/v1/t2a_v2',
    bodyTpl:
        '{"model":"{model}","text":"{text}","stream":false,"voice_setting":{"voice_id":"{voice}","speed":1,"vol":1,"pitch":0},"audio_setting":{"sample_rate":32000,"bitrate":128000,"format":"{format}","channel":1},"output_format":"hex"}',
    resp: TtsResp.jsonHex,
    audioPath: 'data.audio',
    encoding: 'hex',
    voices: [
      'male-qn-qingse',
      'audiobook_male_1',
      'audiobook_female_1',
      'presenter_male',
      'female-shaonv',
      'female-tianmei',
    ],
    voice: 'audiobook_male_1',
    model: 'speech-2.6-hd',
    models: ['speech-2.6-hd', 'speech-2.6-turbo', 'speech-02-hd', 'speech-01-turbo'],
    docUrl: 'https://platform.minimax.cn/docs/api-reference/speech-t2a-http',
  ),
  TtsVendor(
    id: 'dashscope',
    name: '阿里云百炼 Qwen-TTS',
    group: '国内',
    note: '返回的是 24 小时有效的音频地址（不是二进制），已按真实格式处理',
    url:
        'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
    bodyTpl: '{"model":"{model}","input":{"text":"{text}","voice":"{voice}"}}',
    resp: TtsResp.jsonUrl,
    audioPath: 'output.audio.url',
    voices: ['Cherry', 'Serena', 'Ethan', 'Chelsie', 'Dylan', 'Luna'],
    voice: 'Cherry',
    model: 'qwen3-tts-flash',
    models: ['qwen3-tts-flash', 'qwen3-tts-instruct-flash'],
    docUrl: 'https://help.aliyun.com/zh/model-studio/cosyvoice-tts-http-api',
  ),
  TtsVendor(
    id: 'volc',
    name: '火山引擎 豆包语音',
    group: '国内',
    note: '用 V3 接口（只需一个 API Key）· 响应是分块 JSON 流，音频为多段 base64',
    url: 'https://openspeech.bytedance.com/api/v3/tts/unidirectional',
    auth: TtsAuth.header,
    authHeader: 'X-Api-Key',
    authValue: '{key}',
    extraHeaders: {
      'X-Api-Resource-Id': 'seed-tts-2.0',
      'X-Api-Connect-Id': 'thirdhub-tts',
    },
    bodyTpl:
        '{"user":{"uid":"thirdhub"},"req_params":{"text":"{text}","speaker":"{voice}","audio_params":{"format":"{format}","sample_rate":24000}}}',
    resp: TtsResp.jsonChunks,
    voices: [
      'zh_female_cancan_mars_bigtts',
      'zh_male_shaonianzixin_mars_bigtts',
      'zh_female_qingxin',
      'zh_male_suspsense',
    ],
    voice: 'zh_female_cancan_mars_bigtts',
    model: 'seed-tts-2.0',
    docUrl: 'https://www.volcengine.com/docs/82379/2516290',
  ),
  TtsVendor(
    id: 'baidu',
    name: '百度智能云 短文本合成',
    group: '国内',
    note: '要两步：先用 AK|SK 换 token 再合成。Key 栏请按 「APIKey|SecretKey」 填写',
    url: 'https://tsn.baidu.com/text2audio',
    auth: TtsAuth.baidu,
    body: TtsBody.form,
    bodyTpl:
        'tex={text}&lan=zh&cuid=thirdhub&ctp=1&aue=3&per={voice}&spd=5&pit=5&vol=5&tok={key}',
    voices: ['0', '1', '3', '4', '5003', '5118', '106', '4194'],
    voice: '0',
    docUrl: 'https://ai.baidu.com/ai-doc/SPEECH/mlbxh7xie',
  ),

  // ══ 海外 ══════════════════════════════════════════════════════════════
  TtsVendor(
    id: 'openai',
    name: 'OpenAI',
    group: '海外',
    note: '官方 · 需自备代理与付费 Key',
    url: 'https://api.openai.com/v1/audio/speech',
    bodyTpl: _oaTpl,
    voices: [
      'alloy',
      'ash',
      'ballad',
      'coral',
      'echo',
      'fable',
      'nova',
      'onyx',
      'sage',
      'shimmer',
      'verse',
      'marin',
      'cedar',
    ],
    voice: 'nova',
    model: 'gpt-4o-mini-tts',
    models: ['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'],
    docUrl: 'https://platform.openai.com/docs/api-reference/audio/createSpeech',
  ),
  TtsVendor(
    id: 'groq',
    name: 'Groq',
    group: '海外',
    note: 'OpenAI 兼容路径 · 速度极快 · 有免费额度',
    url: 'https://api.groq.com/openai/v1/audio/speech',
    bodyTpl: _oaTpl,
    voices: ['Fritz-PlayAI', 'Arista-PlayAI', 'Atlas-PlayAI', 'Basil-PlayAI'],
    voice: 'Fritz-PlayAI',
    model: 'playai-tts',
    models: ['playai-tts', 'playai-tts-arabic'],
    docUrl: 'https://console.groq.com/docs/text-to-speech',
  ),
  TtsVendor(
    id: 'openrouter',
    name: 'OpenRouter',
    group: '海外',
    note: 'OpenAI 兼容 · 一个 Key 可用多家语音模型',
    url: 'https://openrouter.ai/api/v1/audio/speech',
    bodyTpl: _oaTpl,
    voices: ['alloy', 'echo', 'fable', 'nova', 'onyx', 'shimmer'],
    voice: 'alloy',
    model: 'openai/gpt-4o-mini-tts',
    models: ['openai/gpt-4o-mini-tts'],
    docUrl: 'https://openrouter.ai/docs/features/multimodal/tts',
  ),
  TtsVendor(
    id: 'deepgram',
    name: 'Deepgram Aura',
    group: '海外',
    note: '音色（model）放在 URL 查询参数里 · 鉴权用 Token 前缀（不是 Bearer）',
    url: 'https://api.deepgram.com/v1/speak?model={voice}',
    auth: TtsAuth.header,
    authHeader: 'Authorization',
    authValue: 'Token {key}',
    bodyTpl: '{"text":"{text}"}',
    voices: [
      'aura-asteria-en',
      'aura-luna-en',
      'aura-stella-en',
      'aura-athena-en',
      'aura-2-thalia-en',
    ],
    voice: 'aura-asteria-en',
    docUrl: 'https://developers.deepgram.com/docs/text-to-speech',
  ),
  TtsVendor(
    id: 'elevenlabs',
    name: 'ElevenLabs',
    group: '海外',
    note: '音色 id 拼在 URL 路径里 · 头名是 xi-api-key · 免费层每月 10K 字符',
    url: 'https://api.elevenlabs.io/v1/text-to-speech/{voice}',
    auth: TtsAuth.header,
    authHeader: 'xi-api-key',
    authValue: '{key}',
    extraHeaders: {'Accept': 'audio/mpeg'},
    bodyTpl: '{"text":"{text}","model_id":"{model}"}',
    voices: [
      '21m00Tcm4TlvDq8ikWAM',
      'pNInz6obpgDQGcFmaJgB',
      'EXAVITQu4vr4xnSDxMaL',
      'ErXwobaYiN019PkySvjV',
      'JBFqnCBsd6RMkjVDRZzb',
    ],
    voice: '21m00Tcm4TlvDq8ikWAM',
    model: 'eleven_multilingual_v2',
    models: ['eleven_multilingual_v2', 'eleven_flash_v2_5', 'eleven_turbo_v2_5'],
    docUrl: 'https://elevenlabs.io/docs/api-reference/text-to-speech/convert',
  ),
  TtsVendor(
    id: 'cartesia',
    name: 'Cartesia Sonic',
    group: '海外',
    note: '文本字段叫 transcript（不是 input/text）· 必须带 Cartesia-Version 头',
    url: 'https://api.cartesia.ai/tts/bytes',
    extraHeaders: {'Cartesia-Version': '2025-04-16'},
    bodyTpl:
        '{"model_id":"{model}","transcript":"{text}","voice":{"mode":"id","id":"{voice}"},"output_format":{"container":"{format}","sample_rate":44100}}',
    voices: [
      '5c5ad5e7-1020-476b-8b91-fdcbe9cc313c',
      '15d0c2e2-8d29-44c3-be23-d585d5f154a1',
      '694f9389-aac1-45b6-b726-9d9369183238',
    ],
    voice: '5c5ad5e7-1020-476b-8b91-fdcbe9cc313c',
    model: 'sonic-2',
    models: ['sonic-2', 'sonic-3'],
    docUrl: 'https://docs.cartesia.ai/api-reference/tts/bytes',
  ),
  TtsVendor(
    id: 'fishaudio',
    name: 'Fish Audio 鱼声',
    group: '海外',
    note: '模型名放在请求头 model 里（不在 body）',
    url: 'https://api.fish.audio/v1/tts',
    extraHeaders: {'model': '{model}'},
    bodyTpl: '{"text":"{text}","reference_id":"{voice}","format":"{format}"}',
    voices: [
      '933563129e564b19a115bedd57b7406a',
      'ca3007f96ae7499ab87d27ea3599956a',
      '9a9cf47702da476aa4629e2506d4a857',
    ],
    voice: '933563129e564b19a115bedd57b7406a',
    model: 's2.1-pro',
    models: ['s2.1-pro', 's2-pro'],
    docUrl: 'https://docs.fish.audio/developer-guide/getting-started/quickstart',
  ),
  TtsVendor(
    id: 'azure',
    name: '微软 Azure 语音',
    group: '海外',
    note: '要填区域（region）· 请求体是 SSML 不是 JSON · 音色 400+ 种',
    url: 'https://{region}.tts.speech.microsoft.com/cognitiveservices/v1',
    auth: TtsAuth.header,
    authHeader: 'Ocp-Apim-Subscription-Key',
    authValue: '{key}',
    extraHeaders: {
      'Content-Type': 'application/ssml+xml',
      'X-Microsoft-OutputFormat': 'audio-16khz-128kbitrate-mono-mp3',
    },
    body: TtsBody.ssml,
    bodyTpl:
        "<speak version='1.0' xml:lang='zh-CN'><voice name='{voice}'>{text}</voice></speak>",
    needRegion: true,
    voices: [
      'zh-CN-XiaoxiaoNeural',
      'zh-CN-YunxiNeural',
      'zh-CN-YunjianNeural',
      'zh-CN-XiaoyiNeural',
      'zh-CN-liaoning-XiaobeiNeural',
      'en-US-AvaNeural',
      'en-US-AndrewNeural',
    ],
    voice: 'zh-CN-XiaoxiaoNeural',
    docUrl: 'https://learn.microsoft.com/azure/ai-services/speech-service/rest-text-to-speech',
  ),
  TtsVendor(
    id: 'resemble',
    name: 'Resemble AI',
    group: '海外',
    note: '鉴权是裸 Key（没有 Bearer 前缀）· 返回 JSON 里的 base64 音频',
    url: 'https://f.cluster.resemble.ai/synthesize',
    auth: TtsAuth.header,
    authHeader: 'Authorization',
    authValue: '{key}',
    bodyTpl:
        '{"voice_uuid":"{voice}","data":"{text}","sample_rate":48000,"output_format":"{format}"}',
    resp: TtsResp.jsonBase64,
    audioPath: 'audio_content',
    voices: ['55592656'],
    voice: '55592656',
    format: 'wav',
    docUrl: 'https://docs.resemble.ai/voice-generation/text-to-speech/synchronous',
  ),
  TtsVendor(
    id: 'speechify',
    name: 'Speechify',
    group: '海外',
    note: 'OpenAI 风格但音色字段名是 voice_id',
    url: 'https://api.sws.speechify.com/v1/audio/speech',
    bodyTpl: '{"input":"{text}","voice_id":"{voice}","audio_format":"{format}"}',
    resp: TtsResp.jsonBase64,
    audioPath: 'audio_data',
    voices: ['george', 'henry', 'carly', 'sophia'],
    voice: 'george',
    model: 'simba-multilingual',
    docUrl: 'https://docs.sws.speechify.com/',
  ),
  TtsVendor(
    id: 'murf',
    name: 'Murf',
    group: '海外',
    note: '头名是 api-key · 音色字段名 voiceId · 返回的是音频下载地址',
    url: 'https://api.murf.ai/v1/speech/generate',
    auth: TtsAuth.header,
    authHeader: 'api-key',
    authValue: '{key}',
    bodyTpl:
        '{"text":"{text}","voiceId":"{voice}","format":"MP3","sampleRate":44100,"encodeAsBase64":true}',
    resp: TtsResp.jsonBase64,
    audioPath: 'encodedAudio',
    voices: ['Natalie', 'en-US-natalie'],
    voice: 'Natalie',
    docUrl: 'https://murf.ai/api/docs/api-reference/text-to-speech/generate',
  ),

  // ══ 自托管（自己跑的开源引擎，填服务地址即用）══════════════════════
  TtsVendor(
    id: 'kokoro',
    name: 'Kokoro（Kokoro-FastAPI）',
    group: '自托管',
    note: 'OpenAI 兼容 · 轻量高自然度 · 默认端口 8880',
    url: 'http://{host}/v1/audio/speech',
    auth: TtsAuth.none,
    bodyTpl: _oaTpl,
    needHost: true,
    voices: ['af_heart', 'af_bella', 'af_sky', 'am_adam', 'am_michael', 'zf_xiaoxiao'],
    voice: 'af_heart',
    model: 'kokoro',
    models: ['kokoro'],
    docUrl: 'https://github.com/remsky/Kokoro-FastAPI',
  ),
  TtsVendor(
    id: 'gpt-sovits',
    name: 'GPT-SoVITS',
    group: '自托管',
    note: '音色克隆 · 默认端口 9880 · 用 /tts 端点（v2 接口）',
    url: 'http://{host}/tts',
    auth: TtsAuth.none,
    bodyTpl:
        '{"text":"{text}","text_lang":"zh","ref_audio_path":"{voice}","prompt_text":"","prompt_lang":"zh","speed_factor":1.0,"streaming_mode":false}',
    needHost: true,
    voices: ['examples/reference.wav'],
    voice: 'examples/reference.wav',
    format: 'wav',
    docUrl: 'https://github.com/RVC-Boss/GPT-SoVITS',
  ),
  TtsVendor(
    id: 'fish-speech',
    name: 'Fish-Speech（开源版）',
    group: '自托管',
    note: '默认端口 8080 · 默认无鉴权，启动时加 --api-key 才要 Bearer',
    url: 'http://{host}/v1/tts',
    auth: TtsAuth.none,
    bodyTpl: '{"text":"{text}","format":"{format}","references":[]}',
    needHost: true,
    format: 'wav',
    docUrl: 'https://github.com/fishaudio/fish-speech',
  ),
  TtsVendor(
    id: 'openai-edge-tts',
    name: 'openai-edge-tts（微软在线·免费）',
    group: '自托管',
    note: '免费且无需模型，但**走微软在线服务不是离线** · 默认端口 5050',
    url: 'http://{host}/v1/audio/speech',
    auth: TtsAuth.bearer,
    extraHeaders: {},
    bodyTpl: _oaTpl,
    needHost: true,
    voices: [
      'zh-CN-XiaoxiaoNeural',
      'zh-CN-YunxiNeural',
      'en-US-AriaNeural',
      'en-US-AndrewNeural',
    ],
    voice: 'zh-CN-XiaoxiaoNeural',
    model: 'tts-1',
    models: ['tts-1'],
    docUrl: 'https://github.com/travisvn/openai-edge-tts',
  ),
  TtsVendor(
    id: 'localai',
    name: 'LocalAI',
    group: '自托管',
    note: '多引擎统一网关 · 默认端口 8080 · 可选 pip/coqui/qwen3-tts 等后端',
    url: 'http://{host}/v1/audio/speech',
    auth: TtsAuth.none,
    bodyTpl: _oaTpl,
    needHost: true,
    voice: 'alloy',
    model: 'tts-1',
    models: ['tts-1'],
    docUrl: 'https://localai.io/features/sound-generation',
  ),
  TtsVendor(
    id: 'alltalk',
    name: 'AllTalk TTS',
    group: '自托管',
    note: 'OpenAI 兼容 · 默认端口 7851 · 音色名会重映射到本地引擎',
    url: 'http://{host}/v1/audio/speech',
    auth: TtsAuth.none,
    bodyTpl: _oaTpl,
    needHost: true,
    voices: ['alloy', 'echo', 'fable', 'nova', 'onyx', 'shimmer'],
    voice: 'alloy',
    model: 'tts-1',
    models: ['tts-1'],
    docUrl: 'https://github.com/erew123/alltalk_tts',
  ),
  TtsVendor(
    id: 'speaches',
    name: 'Speaches',
    group: '自托管',
    note: 'OpenAI 兼容 · 默认端口 8000 · 同时可做语音识别',
    url: 'http://{host}/v1/audio/speech',
    auth: TtsAuth.none,
    bodyTpl: _oaTpl,
    needHost: true,
    voice: 'alloy',
    model: 'tts-1',
    models: ['tts-1'],
    docUrl: 'https://speaches.ai',
  ),
  TtsVendor(
    id: 'piper',
    name: 'Piper（官方 HTTP 服务）',
    group: '自托管',
    note: '体积小、CPU 可跑 · 默认端口 5000 · 走 /synthesize（不是 OpenAI 形状）',
    url: 'http://{host}/synthesize',
    auth: TtsAuth.none,
    bodyTpl: '{"text":"{text}"}',
    needHost: true,
    format: 'wav',
    docUrl: 'https://github.com/rhasspy/piper',
  ),
  TtsVendor(
    id: 'chattts',
    name: 'ChatTTS（ChatTTS-ui）',
    group: '自托管',
    note: '口语化自然 · 默认端口 9966 · 返回 JSON 里的音频地址',
    url: 'http://{host}/tts',
    auth: TtsAuth.none,
    bodyTpl: '{"text":"{text}","voice":{voice},"is_split":true}',
    resp: TtsResp.jsonUrl,
    audioPath: 'audio_files.0.url',
    needHost: true,
    voice: '2222',
    voices: ['2222'],
    docUrl: 'https://github.com/ddong8/ChatTTS-ui',
  ),
];

/// 需要客户端签名/token 交换、**本轮尚未实现**的厂商。
///
/// ★ 单独列出来而不是混进 [kTtsVendors]，是为了让 UI 能把它们摆成
///   "还没做"的一栏 —— 混进去会让人以为填个 Key 就能用，点了没反应
///   比"直接说没做"更糟。
const List<Map<String, String>> kTtsPendingVendors = [
  {
    'name': '腾讯云 语音合成',
    'why': '要 TC3-HMAC-SHA256 签名',
    'url': 'https://tts.tencentcloudapi.com/',
  },
  {
    'name': '讯飞 在线语音合成',
    'why': '必须 WebSocket + HMAC-SHA256 鉴权 URL',
    'url': 'wss://tts-api.xfyun.cn/v2/tts',
  },
  {
    'name': '云知声',
    'why': '必须 WebSocket + SHA256 签名',
    'url': 'wss://ws-stts.hivoice.cn/v1/tts',
  },
  {
    'name': 'Google Cloud TTS',
    'why': '要 OAuth2 换 access_token',
    'url': 'https://texttospeech.googleapis.com/v1/text:synthesize',
  },
  {
    'name': 'Amazon Polly',
    'why': '要 AWS SigV4 签名',
    'url': 'https://polly.{region}.amazonaws.com/v1/speech',
  },
];

/// ── 请求构建 ────────────────────────────────────────────────────────────

/// 一次合成要用到的变量。
class TtsVars {
  final String text;
  final String key; // API Key；自托管可空；百度是 "AK|SK"
  final String voice;
  final String model;
  final String format;
  final String region; // Azure
  final String host; // 自托管服务地址（如 192.168.1.5:8880）
  const TtsVars({
    required this.text,
    this.key = '',
    this.voice = '',
    this.model = '',
    this.format = '',
    this.region = '',
    this.host = '',
  });
}

/// 构建好的请求。
class TtsRequest {
  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
  const TtsRequest(this.method, this.url, this.headers, this.body);
  @override
  String toString() => '$method $url';
}

/// JSON 字符串字面量内部的转义（不含外层引号）。
/// 模板里已经写好了引号，所以这里只负责把内容转义 ——
/// 不转义的话，正文里出现一个引号就会让整个请求体变成非法 JSON。
String jsonEscape(String s) {
  final enc = jsonEncode(s);
  return enc.substring(1, enc.length - 1);
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 按 body 类型选择正确的转义方式。
String escapeFor(TtsBody body, String s) {
  switch (body) {
    case TtsBody.json:
      return jsonEscape(s);
    case TtsBody.form:
      return Uri.encodeQueryComponent(s);
    case TtsBody.ssml:
      return _xmlEscape(s);
  }
}

String _fill(String tpl, Map<String, String> raw, Map<String, String> escaped) {
  var out = tpl;
  raw.forEach((k, v) {
    out = out.replaceAll('{$k}', v);
  });
  escaped.forEach((k, v) {
    out = out.replaceAll('{$k}', v);
  });
  return out;
}

/// 把一条厂商配置 + 变量，组装成一个可发出的 HTTP 请求。
///
/// ★ 纯函数：不发网络、不读 SharedPreferences —— 所以它能被自检逐字段断言。
TtsRequest planTtsRequest(TtsVendor v, TtsVars vars, {String token = ''}) {
  final fmt = vars.format.isEmpty ? v.format : vars.format;
  final voice = vars.voice.isEmpty ? v.voice : vars.voice;
  final model = vars.model.isEmpty ? v.model : vars.model;
  // 百度拿的是换来的 access_token，不是用户填的 AK|SK
  final authKey = v.auth == TtsAuth.baidu ? token : vars.key;

  final raw = <String, String>{
    'key': authKey,
    'voice': voice,
    'model': model,
    'format': fmt,
    'region': vars.region,
    'host': vars.host,
  };
  final escaped = <String, String>{
    'text': escapeFor(v.body, vars.text),
  };

  final url = _fill(v.url, raw, const {});
  final headers = <String, String>{};
  for (final e in v.extraHeaders.entries) {
    headers[e.key] = _fill(e.value, raw, const {});
  }
  if (v.auth == TtsAuth.bearer || v.auth == TtsAuth.header) {
    headers[v.authHeader] = _fill(v.authValue, raw, const {});
  }
  if (v.body == TtsBody.json && !headers.containsKey('Content-Type')) {
    headers['Content-Type'] = 'application/json';
  } else if (v.body == TtsBody.form && !headers.containsKey('Content-Type')) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  headers['Accept'] = headers['Accept'] ?? '*/*';

  final body = _fill(v.bodyTpl, raw, escaped);
  return TtsRequest(v.method, url, headers, body);
}

/// 百度这类需要先换 token 的：给出换 token 的请求。
/// 返回 null 表示这家不需要换 token。
TtsRequest? planTokenRequest(TtsVendor v, TtsVars vars) {
  if (v.auth != TtsAuth.baidu) return null;
  final parts = vars.key.split('|');
  final ak = parts.isNotEmpty ? parts[0].trim() : '';
  final sk = parts.length > 1 ? parts[1].trim() : '';
  return TtsRequest(
    'POST',
    'https://aip.baidubce.com/oauth/2.0/token',
    {'Content-Type': 'application/x-www-form-urlencoded'},
    'grant_type=client_credentials&client_id=${Uri.encodeQueryComponent(ak)}'
        '&client_secret=${Uri.encodeQueryComponent(sk)}',
  );
}

/// 从换 token 的响应里取 access_token。取不到返回空串。
String parseTokenResponse(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map) return '${j['access_token'] ?? ''}';
  } catch (_) {}
  return '';
}

/// ── 响应解析 ────────────────────────────────────────────────────────────

/// 合成结果：要么直接拿到音频字节，要么拿到一个还要再下载的地址。
class TtsAudioOut {
  final Uint8List? bytes;
  final String? fetchUrl;
  final String? error;
  const TtsAudioOut({this.bytes, this.fetchUrl, this.error});
  bool get ok => bytes != null || fetchUrl != null;
  @override
  String toString() =>
      ok ? 'ok(${bytes?.length ?? 'url:$fetchUrl'})' : 'error($error)';
}

/// 按点分路径取值，支持数字下标：`audio_files.0.url`。
dynamic pickPath(dynamic j, String path) {
  if (path.isEmpty) return null;
  dynamic cur = j;
  for (final seg in path.split('.')) {
    if (cur == null) return null;
    if (cur is Map) {
      cur = cur[seg];
    } else if (cur is List) {
      final i = int.tryParse(seg);
      if (i == null || i < 0 || i >= cur.length) return null;
      cur = cur[i];
    } else {
      return null;
    }
  }
  return cur;
}

/// hex 字符串 → 字节。非法 hex 返回 null（不抛）。
Uint8List? hexToBytes(String hex) {
  var h = hex.trim();
  if (h.isEmpty || h.length.isOdd) return null;
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}

/// base64 → 字节。容错：去空白、补 padding。失败返回 null。
Uint8List? b64ToBytes(String s) {
  var t = s.replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty) return null;
  final mod = t.length % 4;
  if (mod == 2) {
    t += '==';
  } else if (mod == 3) {
    t += '=';
  } else if (mod == 1) {
    return null;
  }
  try {
    return base64Decode(t);
  } catch (_) {
    return null;
  }
}

/// 从响应里取出音频。
///
/// [contentType] 用来兜底判断：有些厂商（如自建网关）即使配置写成 JSON，
/// 也可能直接回二进制。**先信配置、再信 Content-Type** 的顺序是故意的 ——
/// 反过来会让 "JSON 里带 base64" 的厂商被误判成二进制，存出一个听不了的"音频"。
TtsAudioOut extractTtsAudio(
  TtsVendor v,
  String contentType,
  Uint8List body,
) {
  if (body.isEmpty) {
    return const TtsAudioOut(error: '响应为空');
  }
  switch (v.resp) {
    case TtsResp.binary:
      // 配置说二进制的，仍要防"其实回了个 JSON 错误体"。
      if (contentType.contains('json')) {
        return TtsAudioOut(error: '期望音频，但拿到了 JSON：${_head(body)}');
      }
      return TtsAudioOut(bytes: body);

    case TtsResp.jsonBase64:
    case TtsResp.jsonHex:
    case TtsResp.jsonUrl:
      dynamic j;
      try {
        j = jsonDecode(utf8.decode(body, allowMalformed: true));
      } catch (e) {
        return TtsAudioOut(
          error: '响应不是合法 JSON（期望 ${v.resp.name}）：${_head(body)}',
        );
      }
      final val = pickPath(j, v.audioPath);
      if (val == null) {
        return TtsAudioOut(
          error: '在 JSON 里找不到 ${v.audioPath}（厂商返回结构可能变了）：${_head(body)}',
        );
      }
      final s = '$val';
      if (v.resp == TtsResp.jsonUrl) {
        if (s.isEmpty ||
            !(s.startsWith('http://') || s.startsWith('https://'))) {
          return TtsAudioOut(error: '${v.audioPath} 不是有效地址：$s');
        }
        return TtsAudioOut(fetchUrl: s);
      }
      final bytes =
          v.resp == TtsResp.jsonHex ? hexToBytes(s) : b64ToBytes(s);
      if (bytes == null || bytes.isEmpty) {
        return TtsAudioOut(
          error: v.resp == TtsResp.jsonHex
              ? '${v.audioPath} 不是合法 hex'
              : '${v.audioPath} 不是合法 base64',
        );
      }
      return TtsAudioOut(bytes: bytes);

    case TtsResp.jsonChunks:
      // 火山 V3：响应是若干 JSON 对象拼接/分块，音频散在多个 base64 片段里。
      // 用正则把 "data":"<b64>" 全部抽出来按顺序拼 —— 不做完整 JSON 解析，
      // 因为分块边界可能切开一个 JSON 对象，解析整体会直接失败。
      final text = utf8.decode(body, allowMalformed: true);
      final re = RegExp(r'"data"\s*:\s*"([A-Za-z0-9+/=]+)"');
      final buf = <int>[];
      for (final m in re.allMatches(text)) {
        final b = b64ToBytes(m.group(1)!);
        if (b != null) buf.addAll(b);
      }
      if (buf.isEmpty) {
        return TtsAudioOut(error: '分块响应里没找到音频数据：${_head(body)}');
      }
      return TtsAudioOut(bytes: Uint8List.fromList(buf));
  }
}

String _head(Uint8List b) {
  final s = utf8.decode(b.take(180).toList(), allowMalformed: true);
  return s.replaceAll('\n', ' ');
}

/// 按 id 找厂商。
TtsVendor? ttsVendorOf(String id) {
  for (final v in kTtsVendors) {
    if (v.id == id) return v;
  }
  return null;
}

/// 分组后的厂商（UI 用），保持组内原始顺序。
List<String> get ttsGroups {
  final seen = <String>[];
  for (final v in kTtsVendors) {
    if (!seen.contains(v.group)) seen.add(v.group);
  }
  return seen;
}

List<TtsVendor> vendorsInGroup(String g) =>
    [for (final v in kTtsVendors) if (v.group == g) v];

/// ── 自定义厂商的序列化 ───────────────────────────────────────────────────
///
/// 用户自己填的那家（内置表覆盖不到的长尾厂商）要能存进 SharedPreferences。
/// 放在这一层而不是 UI 层，是为了让"存进去再读出来还是同一条配置"这件事
/// 也能被自检断言 —— 序列化丢字段的表现是"填好了、重启就没了"。

Map<String, dynamic> vendorToJson(TtsVendor v) => {
      'id': v.id,
      'name': v.name,
      'group': v.group,
      'note': v.note,
      'url': v.url,
      'method': v.method,
      'auth': v.auth.name,
      'authHeader': v.authHeader,
      'authValue': v.authValue,
      'extraHeaders': v.extraHeaders,
      'body': v.body.name,
      'bodyTpl': v.bodyTpl,
      'resp': v.resp.name,
      'audioPath': v.audioPath,
      'encoding': v.encoding,
      'voices': v.voices,
      'models': v.models,
      'voice': v.voice,
      'model': v.model,
      'format': v.format,
      'needRegion': v.needRegion,
      'needHost': v.needHost,
      'docUrl': v.docUrl,
    };

T _enumOf<T extends Enum>(List<T> values, String name, T fallback) {
  for (final e in values) {
    if (e.name == name) return e;
  }
  return fallback;
}

/// 反序列化。**任何一项缺失都退回默认值，绝不抛异常** ——
/// 用户手改过存储、或跨版本升级时字段增减，都不该让整个设置页打不开。
TtsVendor? vendorFromJson(Map<String, dynamic> j) {
  final id = '${j['id'] ?? ''}'.trim();
  final url = '${j['url'] ?? ''}'.trim();
  final bodyTpl = '${j['bodyTpl'] ?? ''}'.trim();
  if (id.isEmpty || url.isEmpty || bodyTpl.isEmpty) return null;
  return TtsVendor(
    id: id,
    name: '${j['name'] ?? id}',
    group: '${j['group'] ?? '自定义'}',
    note: '${j['note'] ?? ''}',
    url: url,
    method: '${j['method'] ?? 'POST'}',
    auth: _enumOf(TtsAuth.values, '${j['auth'] ?? ''}', TtsAuth.bearer),
    authHeader: '${j['authHeader'] ?? 'Authorization'}',
    authValue: '${j['authValue'] ?? 'Bearer {key}'}',
    extraHeaders: {
      for (final e in ((j['extraHeaders'] as Map?) ?? const {}).entries)
        '${e.key}': '${e.value}',
    },
    body: _enumOf(TtsBody.values, '${j['body'] ?? ''}', TtsBody.json),
    bodyTpl: bodyTpl,
    resp: _enumOf(TtsResp.values, '${j['resp'] ?? ''}', TtsResp.binary),
    audioPath: '${j['audioPath'] ?? ''}',
    encoding: '${j['encoding'] ?? 'base64'}',
    voices: [for (final x in ((j['voices'] as List?) ?? const [])) '$x'],
    models: [for (final x in ((j['models'] as List?) ?? const [])) '$x'],
    voice: '${j['voice'] ?? ''}',
    model: '${j['model'] ?? ''}',
    format: '${j['format'] ?? 'mp3'}',
    needRegion: j['needRegion'] == true,
    needHost: j['needHost'] == true,
    docUrl: '${j['docUrl'] ?? ''}',
  );
}

/// 自定义厂商列表的编解码。
String encodeVendorList(List<TtsVendor> vs) =>
    jsonEncode([for (final v in vs) vendorToJson(v)]);

List<TtsVendor> decodeVendorList(String raw) {
  if (raw.trim().isEmpty) return const [];
  dynamic j;
  try {
    j = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (j is! List) return const [];
  final out = <TtsVendor>[];
  for (final e in j) {
    if (e is Map) {
      final v = vendorFromJson(Map<String, dynamic>.from(e));
      if (v != null) out.add(v);
    }
  }
  return out;
}

/// 把一份用户填的表单做成厂商配置。留空的可选项自动退回合理默认，
/// 免得用户必须把每个字段都填满才能保存。
TtsVendor buildCustomVendor({
  required String name,
  required String url,
  String method = 'POST',
  TtsAuth auth = TtsAuth.bearer,
  String authHeader = 'Authorization',
  String authValue = 'Bearer {key}',
  Map<String, String> extraHeaders = const {},
  TtsBody body = TtsBody.json,
  String bodyTpl = '{"model":"{model}","input":"{text}","voice":"{voice}","response_format":"{format}"}',
  TtsResp resp = TtsResp.binary,
  String audioPath = '',
  String voice = '',
  String model = '',
  String format = 'mp3',
  bool needRegion = false,
}) {
  final id = 'custom_${name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}'
      '_${url.hashCode.abs().toRadixString(36)}';
  return TtsVendor(
    id: id,
    name: name.trim().isEmpty ? '自定义' : name.trim(),
    group: '自定义',
    note: '用户自定义接口',
    url: url.trim(),
    method: method,
    auth: auth,
    authHeader: authHeader,
    authValue: authValue,
    extraHeaders: extraHeaders,
    body: body,
    bodyTpl: bodyTpl,
    resp: resp,
    audioPath: audioPath,
    voice: voice,
    model: model,
    format: format,
    needRegion: needRegion,
  );
}
