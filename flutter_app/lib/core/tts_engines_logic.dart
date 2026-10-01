// 开源 TTS 引擎接入（D-C3）—— **纯数据与纯函数**层（零 Flutter 依赖）。
//
// 对应 `docs/TTS-PROTOCOL.md`（TTS/1）。分层理由同 `ui_icon_map.dart`：
// 纯 Dart VM 不能 import `package:flutter/material.dart`（它最终要 `dart:ui`），
// 而契约解析恰恰是**最需要被自检覆盖**的部分 —— 判错一项的表现是
// "界面写着已连接、点了没声音"，只在真机上复现。所以判定逻辑放这里，
// `tool/tts_engines_selfcheck.dart` 直接 import 它跑断言。
//
// `dart:convert` 是核心库、纯 Dart VM 可用（不像 `dart:ui` 只在引擎里存在），
// 所以这里直接 import —— 早先为"零依赖"绕了一层延迟加载，反而引出一个
// 不存在的符号。**零 Flutter 依赖 ≠ 不许用 dart: 核心库**。
import 'dart:convert';

/// 一个开源 TTS 引擎项目的登记项。
///
/// ★ `home` 是**项目主页 / 发布页**，不是直链下载地址。
///   本项目不分发任何模型；只把"去哪找"告诉用户。硬编码直链会随上游
///   版本失效，而失效的表现是"一键下载按钮点了 404"，比让用户自己去
///   发布页挑版本更糟。
class TtsEngineProject {
  final String id; // 内部标识
  final String name; // 展示名
  final String license; // 许可（用户要关心能不能商用）
  final String home; // 项目主页 / 发布页
  final String engineKey; // 期望它在 /health 里回的 engine 值
  final bool offline; // 是否可完全离线
  final String note; // 一句话说明
  final String hint; // 启动命令 / 部署提示（可复制）
  final int defaultPort; // 常见默认端口，用于"填入地址"时给个初值
  const TtsEngineProject({
    required this.id,
    required this.name,
    required this.license,
    required this.home,
    required this.engineKey,
    required this.offline,
    required this.note,
    required this.hint,
    required this.defaultPort,
  });
}

/// 登记的开源引擎。**只做登记与引导，不做内置与分发。**
const List<TtsEngineProject> kTtsEngineProjects = [
  TtsEngineProject(
    id: 'piper',
    name: 'Piper',
    license: 'MIT',
    home: 'https://github.com/rhasspy/piper',
    engineKey: 'piper',
    offline: true,
    note: '体积小、CPU 就能跑，中文音色可用；适合旧手机/低配设备',
    hint: 'python -m piper.http_server --model zh_CN-huayan-medium.onnx --port 5100',
    defaultPort: 5100,
  ),
  TtsEngineProject(
    id: 'sherpa',
    name: 'sherpa-onnx',
    license: 'Apache-2.0',
    home: 'https://github.com/k2-fsa/sherpa-onnx',
    engineKey: 'sherpa-onnx',
    offline: true,
    note: '多语言、含中文，官方有预编译二进制与模型包',
    hint: './sherpa-onnx-tts-server --vits-model=model.onnx --port 5101',
    defaultPort: 5101,
  ),
  TtsEngineProject(
    id: 'gpt-sovits',
    name: 'GPT-SoVITS',
    license: 'MIT',
    home: 'https://github.com/RVC-Boss/GPT-SoVITS',
    engineKey: 'gpt-sovits',
    offline: true,
    note: '音色克隆、质量高；需要显卡，自带 WebUI',
    hint: 'python api_v2.py -a 127.0.0.1 -p 5102',
    defaultPort: 5102,
  ),
  TtsEngineProject(
    id: 'chattts',
    name: 'ChatTTS',
    license: 'AGPL-3.0',
    home: 'https://github.com/2noise/ChatTTS',
    engineKey: 'chattts',
    offline: true,
    note: '口语化自然，中文效果好；AGPL，商用前请自行确认许可',
    hint: 'python -m chattts.server --port 5103',
    defaultPort: 5103,
  ),
  TtsEngineProject(
    id: 'kokoro',
    name: 'Kokoro',
    license: 'Apache-2.0',
    home: 'https://github.com/hexgrad/kokoro',
    engineKey: 'kokoro',
    offline: true,
    note: '轻量高自然度，英文最好、中文需自行找音色',
    hint: 'python -m kokoro.server --port 5104',
    defaultPort: 5104,
  ),
  TtsEngineProject(
    id: 'edge-tts',
    name: 'edge-tts',
    license: 'GPL-3.0',
    home: 'https://github.com/rany2/edge-tts',
    engineKey: 'edge-tts',
    offline: false,
    note: '无需模型、装完就能用；但**走微软在线服务**，不是离线',
    hint: 'python -m edge_tts_server --port 5105',
    defaultPort: 5105,
  ),
];

/// 契约要求的协议字面量。写成常量是为了**只在一处**定义 ——
/// 客户端判定与服务端文档各写一遍字面量，早晚会分叉（本项目的老毛病）。
const String kTtsProtocol = 'tts/1';

/// 判定结果分类。**分开报**是刻意的：
/// 用户看到"连接失败"时无法行动，看到"对面不是 TTS/1 引擎"才能去改地址。
enum TtsProbe {
  ok, // 全部合格
  badUrl, // 地址解析不出来
  unreachable, // 连不上（超时/拒绝/网络）
  notJson, // 连上了但回的不是 JSON（多半填成了网页）
  unhealthy, // ok != true —— 服务在，但自己说不健康（模型没加载完？）
  wrongProtocol, // ok == true 但没有 protocol:'tts/1' —— 填成别的服务了
  notObject, // 回的是 JSON 但不是对象（数组/字符串）
}

/// 探测结果的完整描述。`detail` 一定要带**具体是哪一项不合格**。
class TtsProbeResult {
  final TtsProbe kind;
  final String detail;
  final String engine;
  final String name;
  final int sampleRate;
  final List<String> voices;
  final String defaultVoice;
  final List<String> formats;
  const TtsProbeResult({
    required this.kind,
    required this.detail,
    this.engine = '',
    this.name = '',
    this.sampleRate = 0,
    this.voices = const [],
    this.defaultVoice = '',
    this.formats = const ['wav'],
  });
  bool get ok => kind == TtsProbe;
}

/// 给用户看的一句话结论（三段式：现象 / 原因 / 怎么办 —— 见 STYLE_GUIDE 第 2 条）。
String describeProbe(TtsProbeResult r) {
  switch (r.kind) {
    case TtsProbe.ok:
      return '已连接「${r.name.isEmpty ? r.engine : r.name}」'
          '${r.sampleRate > 0 ? ' · ${r.sampleRate} Hz' : ''}'
          '${r.voices.isEmpty ? '' : ' · ${r.voices.length} 个音色'}';
    case TtsProbe.badUrl:
      return '地址格式不对。${r.detail}\n'
          '要形如 http://192.168.1.5:5100 —— 缺端口时按引擎默认端口补齐。';
    case TtsProbe.unreachable:
      return '连不上这个地址。\n'
          '· 确认引擎已启动（在电脑上浏览器打开同地址 /health 能出 JSON）；\n'
          '· 手机与引擎要在同一局域网；\n'
          '· 引擎若只监听 127.0.0.1，要改成监听 0.0.0.0 才能被手机访问。\n'
          '原始错误：${r.detail}';
    case TtsProbe.notJson:
      return '这个地址回的不是 JSON（可能是网页或其它服务）。\n'
          '请确认填的是**引擎的 HTTP 端口**，不是它的 WebUI 页面地址。';
    case TtsProbe.notObject:
      return '这个地址回了 JSON，但不是对象（拿到的是数组或字符串）。\n'
          '多半不是 TTS/1 引擎。';
    case TtsProbe.unhealthy:
      return '服务在，但它自己报告不健康（ok 不为 true）。\n'
          '常见原因是模型还没加载完，等一会儿再点自检。'
          '${r.detail.isEmpty ? '' : '\n服务端说明：${r.detail}'}';
    case TtsProbe.wrongProtocol:
      return '这个地址不是 TTS/1 引擎。\n'
          '它回了 ok:true，但没有 protocol:"$kTtsProtocol" 这一项 —— 说明对面是另一个服务'
          '（例如阅读引擎的 :1234 或资源库的 :9527）。\n'
          '请填开源 TTS 引擎自己的端口。';
  }
}

/// 从 `/health` 的响应体解析出判定结果。**绝不抛异常**
/// （网络层已把字节拿到；这里只做判定，抛出去会让调用方多一层 try）。
///
/// `wasJson` 由调用方按响应的 `Content-Type` 传入 —— 拿一个 HTML 登录页
/// 来解析 JSON 是最容易把"填错地址"误判成"引擎不健康"的地方。
TtsProbeResult parseHealth(String body, {bool wasJson = true}) {
  if (!wasJson) {
    return TtsProbeResult(kind: TtsProbe.notJson, detail: 'Content-Type 不是 json');
  }
  dynamic j;
  try {
    j = jsonDecode(body);
  } catch (e) {
    return TtsProbeResult(kind: TtsProbe.notJson, detail: 'JSON 解析失败：$e');
  }
  if (j is! Map) {
    return TtsProbeResult(
        kind: TtsProbe.notObject, detail: '顶层类型是 ${j.runtimeType}，不是对象');
  }
  final okFlag = j['ok'] == true;
  final proto = '${j['protocol'] ?? ''}'.trim();
  if (!okFlag) {
    return TtsProbeResult(
      kind: TtsProbe.unhealthy,
      detail: '${j['error'] ?? j['message'] ?? ''}'.trim(),
      engine: '${j['engine'] ?? ''}',
      name: '${j['name'] ?? ''}',
    );
  }
  // ★ ok 为真之后**必须**再核 protocol。只看 ok 会把任何 REST 服务都当成引擎。
  if (proto != kTtsProtocol) {
    return TtsProbeResult(
      kind: TtsProbe.wrongProtocol,
      detail: proto.isEmpty ? '缺少 protocol 字段' : 'protocol="$proto"',
      engine: '${j['engine'] ?? ''}',
      name: '${j['name'] ?? ''}',
    );
  }
  final voices = <String>[
    for (final v in (j['voices'] as List? ?? const [])) '$v',
  ];
  final formats = <String>[
    for (final f in (j['formats'] as List? ?? const [])) '$f',
  ];
  final dv = '${j['default_voice'] ?? ''}'.trim();
  return TtsProbeResult(
    kind: TtsProbe.ok,
    detail: '',
    engine: '${j['engine'] ?? ''}',
    name: '${j['name'] ?? ''}',
    sampleRate: (j['sample_rate'] as num?)?.toInt() ?? 0,
    voices: voices,
    defaultVoice: dv.isEmpty ? (voices.isNotEmpty ? voices.first : '') : dv,
    formats: formats.isEmpty ? const ['wav'] : formats,
  );
}

/// 归一化用户输入的地址：补 scheme、补默认端口、去尾斜杠。
/// 返回 null 表示无法解析（调用方按 [TtsProbe.badUrl] 处理）。
///
/// ★ 两个踩过的坑（都由 `tool/tts_engines_selfcheck.dart` 抓出来）：
///   ① **不能只看 `hasPort`**。Dart 把「默认端口」视为"没写端口"：
///      `Uri.parse('https://x:443').hasPort == false`。照 hasPort 补端口的话，
///      `https://tts.example.com:443` 会被补成 `...:5100` —— 一个必然连不上的地址，
///      而用户看到的只是"连不上"，完全想不到是地址被 App 改过。
///   ② **不能手工拼字符串**。IPv6 的 `Uri.host` 是**不带方括号**的
///      （`http://[fe80::1]:5100` → host 是 `fe80::1`），拼回去会得到
///      `http://fe80::1:5100` 这种无法解析的东西。交给 `Uri.replace().toString()`
///      才能保住方括号。
///
/// query（可能带 Token）原样保留 —— 协议文档明确允许「在 URL 里带鉴权」。
String? normalizeTtsUrl(String input, {int fallbackPort = 5100}) {
  var t = input.trim();
  if (t.isEmpty) return null;
  if (!t.startsWith('http://') && !t.startsWith('https://')) t = 'http://$t';
  Uri u;
  try {
    u = Uri.parse(t);
  } catch (_) {
    return null;
  }
  if (u.host.isEmpty) return null;
  final int port;
  if (u.hasPort) {
    port = u.port;
  } else if (u.scheme == 'https') {
    port = 443; // 见坑 ①：https 的 443 要认，不许套 fallbackPort
  } else {
    port = fallbackPort;
  }
  final path = u.path == '/' ? '' : u.path;
  return u.replace(port: port, path: path).toString();
}

/// 找出最匹配 [engineKey] 的登记项（拿不到就返回 null，由 UI 显示原始值）。
TtsEngineProject? projectOf(String engineKey) {
  final k = engineKey.trim().toLowerCase();
  for (final p in kTtsEngineProjects) {
    if (p.engineKey.toLowerCase() == k) return p;
  }
  return null;
}
