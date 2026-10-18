// API Key 厂商自动识别（2026-10-18 重写）
//
// ★用户诉求：
//   「有些厂商的 API 不仅能调模型，也能用来联网搜索。**用户只要输入这个 API，
//     它就自动配对是哪一个厂商**。这种所有 API 都要做**并行全量测试**。」
//
// 上一版（`AiKeyDetect.identify`）的问题，正好是"不是并行全量"：
//   · 它按 **8 家一批**串行跑，36 家要 5 轮，每轮 9 秒超时 → 最坏 45 秒；
//   · 它用 `/chat/completions` + `max_tokens:1` 做验证 —— **要花钱**，
//     而且一条一条等回包；
//   · 它只看得到 `AiRegistry` 里的厂商，识别不出表外的。
//
// 这一版的做法：
//   ① **全量并行**：23 个探测端点同时发，总预算 6 秒，到点带着已有结果返回；
//   ② **零成本**：只打 `GET /v1/models` —— 只读、不计费、不产生对话；
//   ③ **第二阶段兜底**：`/models` 全没命中时，用**故意写错模型名**的
//      `chat/completions` 再并行探一轮 —— Key 有效时厂商回的是
//      "model not found"（400）而不是 401，据此判定归属，同样不消耗 token；
//   ④ 命中后给出**可读结论**：厂商名、可用模型、是否也能用于联网搜索。
//
// ★安全：key 只在内存里用于这一次探测，不落盘、不进日志（日志里只写厂商名）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_keys.dart';

/// 一个厂商的探测方式。
class KeyProbe {
  const KeyProbe(
    this.id,
    this.name,
    this.url, {
    this.authHeader = 'Authorization',
    this.authPrefix = 'Bearer ',
    this.note = '',
    this.search = false,
    this.modelProbe = '',
  });

  final String id;
  final String name;
  final String url;

  /// 少数厂商不用 Authorization（如 Anthropic 用 `x-api-key`）。
  final String authHeader;
  final String authPrefix;
  final String note;

  /// 该厂商的 API 是否**也能用于联网搜索**（用户特别提到这一点）。
  final bool search;

  /// 第二阶段用的模型名（故意写错，只为触发"模型不存在"而不是"鉴权失败"）。
  final String modelProbe;
}

/// 探测结果。
class KeyHit {
  const KeyHit(
    this.providerId,
    this.providerName,
    this.ms,
    this.models, {
    this.note = '',
    this.search = false,
    this.viaModelProbe = false,
  });

  final String providerId;
  final String providerName;
  final int ms;
  final List<String> models;
  final String note;
  final bool search;

  /// true = 是第二阶段（错模型名）探出来的，说明该家没实现 `/models`。
  final bool viaModelProbe;
}

class KeyDetect {
  const KeyDetect._();

  /// 总预算：6 秒。超过就按"已知的返回"给结论（部分结果好过没有）。
  static const budgetMs = 6000;

  /// 内置探测表（**全量并行**）。
  ///
  /// 这些都是各家的 OpenAI 兼容入口 —— 国内厂商大多都提供 `/v1/models`
  /// （阿里叫 compatible-mode、火山叫 api/v3、智谱叫 api/paas/v4）。
  static const List<KeyProbe> probes = [
    KeyProbe('openai', 'OpenAI', 'https://api.openai.com/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('deepseek', 'DeepSeek', 'https://api.deepseek.com/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('moonshot', '月之暗面 Kimi', 'https://api.moonshot.cn/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('zhipu', '智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('dashscope', '阿里百炼（通义）',
        'https://dashscope.aliyuncs.com/compatible-mode/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('volc', '火山方舟（豆包）',
        'https://ark.cn-beijing.volces.com/api/v3/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('siliconflow', '硅基流动', 'https://api.siliconflow.cn/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('xiaomi', '小米 MiMo', 'https://api.xiaomimimo.com/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('minimax', 'MiniMax', 'https://api.minimax.chat/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('baichuan', '百川智能', 'https://api.baichuan-ai.com/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('stepfun', '阶跃星辰', 'https://api.stepfun.com/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('01ai', '零一万物', 'https://api.lingyiwanwu.com/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('baidu', '百度千帆', 'https://qianfan.baidubce.com/v2/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('hunyuan', '腾讯混元',
        'https://api.hunyuan.cloud.tencent.com/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('sensetime', '商汤日日新',
        'https://api.sensenova.cn/compatible-mode/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('modelscope', '魔搭 ModelScope',
        'https://api-inference.modelscope.cn/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('groq', 'Groq', 'https://api.groq.com/openai/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('together', 'Together AI', 'https://api.together.xyz/v1/models',
        modelProbe: 'thirdhubprobe'),
    KeyProbe('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('mistral', 'Mistral', 'https://api.mistral.ai/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('xai', 'xAI Grok', 'https://api.x.ai/v1/models',
        search: true, modelProbe: 'thirdhubprobe'),
    KeyProbe('anthropic', 'Anthropic Claude', 'https://api.anthropic.com/v1/models',
        authHeader: 'x-api-key', authPrefix: '', search: true),
    KeyProbe('gemini', 'Google Gemini',
        'https://generativelanguage.googleapis.com/v1beta/models',
        authHeader: 'x-goog-api-key', authPrefix: '', search: true),
  ];

  /// 第一阶段：并行打 `/models`，命中即归属。
  ///
  /// [onProgress] 用于 UI 显示"已试 N 家"。
  static Future<List<KeyHit>> detect(
    String key, {
    void Function(int done, int total)? onProgress,
    int budget = budgetMs,
  }) async {
    final hits = await _phase(key, probes, onProgress, budget);
    hits.sort((a, b) => a.ms.compareTo(b.ms));
    return hits;
  }

  /// 全量识别：先 `/models`，没命中再走"错模型名"的第二阶段。
  ///
  /// 返回按可信度排序的命中列表（通常只有 1 条）。
  static Future<List<KeyHit>> identify(
    String key, {
    void Function(int done, int total, String stage)? onProgress,
  }) async {
    final k = key.trim();
    if (k.isEmpty) return const [];

    final first = await detect(k, onProgress: (d, t) => onProgress?.call(d, t, 'models'));
    if (first.isNotEmpty) return first;

    // 第二阶段：只探有 modelProbe 的（Anthropic/Gemini 的 /models 已经够用）
    final second = probes.where((p) => p.modelProbe.isNotEmpty).toList();
    final hits = await _phase(
      k,
      second,
      (d, t) => onProgress?.call(d, t, 'chat'),
      budgetMs,
      builder: _chatProbe,
    );
    hits.sort((a, b) => a.ms.compareTo(b.ms));
    return hits;
  }

  /// 并行跑一批探测，带总预算。
  static Future<List<KeyHit>> _phase(
    String key,
    List<KeyProbe> list,
    void Function(int done, int total)? onProgress,
    int budget, {
    Future<KeyHit?> Function(KeyProbe, String)? builder,
  }) async {
    final hits = <KeyHit>[];
    var done = 0;
    final total = list.length;
    final b = builder ?? _probeModels;
    final futures = list.map((p) => b(p, key).then((h) {
          done++;
          onProgress?.call(done, total);
          if (h != null) hits.add(h);
          return h;
        }));
    try {
      await Future.wait(futures).timeout(
        Duration(milliseconds: budget),
        onTimeout: () => const <KeyHit?>[],
      );
    } catch (_) {
      // 单条探测的异常已在内部吞掉，这里只兜底
    }
    return hits;
  }

  /// 第一阶段：`GET /models`，2xx 即命中。
  static Future<KeyHit?> _probeModels(KeyProbe p, String key) async {
    final t0 = DateTime.now();
    HttpClient? cli;
    try {
      cli = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final req = await cli.getUrl(Uri.parse(p.url));
      final v = p.authPrefix.isEmpty ? key : '${p.authPrefix}$key';
      if (p.authHeader.isNotEmpty) req.headers.set(p.authHeader, v);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'ThirdHub/KeyDetect');
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      return KeyHit(p.id, p.name, ms, _parseModels(body),
          note: p.note, search: p.search);
    } catch (_) {
      return null;
    } finally {
      try {
        cli?.close(force: true);
      } catch (_) {}
    }
  }

  /// 第二阶段：故意用一个不存在的模型名。
  /// 厂商回 401/403 = 不是这家的 Key；回 400/404 且提到 model = **Key 有效**。
  /// 这样既不用花 token，也不依赖该家实现 `/models`。
  static Future<KeyHit?> _chatProbe(KeyProbe p, String key) async {
    final t0 = DateTime.now();
    HttpClient? cli;
    try {
      cli = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      // /models → /chat/completions（保持各自的 API 前缀）
      const tail = '/models';
      final chatUrl = Uri.parse(p.url.endsWith(tail)
          ? '${p.url.substring(0, p.url.length - tail.length)}/chat/completions'
          : p.url);
      final req = await cli.postUrl(chatUrl);
      final v = p.authPrefix.isEmpty ? key : '${p.authPrefix}$key';
      if (p.authHeader.isNotEmpty) req.headers.set(p.authHeader, v);
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'ThirdHub/KeyDetect');
      req.add(utf8.encode(jsonEncode({
        'model': p.modelProbe,
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
        'max_tokens': 1,
        'stream': false,
      })));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
      final ms = DateTime.now().difference(t0).inMilliseconds;

      if (res.statusCode == 401 || res.statusCode == 403) return null;
      // Key 有效：要么直接 200，要么抱怨"模型不存在 / 参数不对"
      final okAuth = res.statusCode == 200 ||
          (res.statusCode >= 400 &&
              res.statusCode < 500 &&
              RegExp(r'model|model_name|不支持|invalid', caseSensitive: false)
                  .hasMatch(body));
      if (!okAuth) return null;
      return KeyHit(p.id, p.name, ms, const [],
          note: '该厂商未提供模型清单接口，已通过鉴权探测确认',
          search: p.search, viaModelProbe: true);
    } catch (_) {
      return null;
    } finally {
      try {
        cli?.close(force: true);
      } catch (_) {}
    }
  }

  /// 解析模型清单：兼容 `{data:[{id}]}` / `{models:[{name}]}` / 纯数组。
  static List<String> _parseModels(String body) {
    final out = <String>[];
    try {
      final j = jsonDecode(body);
      final arr = (j is Map ? (j['data'] ?? j['models'] ?? j['result']) : j);
      if (arr is List) {
        for (final e in arr.take(120)) {
          if (e is Map) {
            final id = e['id'] ?? e['name'] ?? e['model'];
            if (id != null) out.add('$id');
          } else if (e is String) {
            out.add(e);
          }
        }
      }
    } catch (_) {}
    return out;
  }

  /// 把一个探测结果对到 `AiRegistry` 里的厂商 id。
  ///
  /// 三级匹配（越靠前越可信）：
  ///   ① 规范 id 相同（`dashscope` ↔ `aliyun` 这类别名由 KeyVendor 抹平）；
  ///   ② **域名相同**（`gemini`↔`google`、`01ai`↔`yi`、`sensetime`↔`sensechat`
  ///      这些名字完全不同但 base 同源的，靠域名才认得出）；
  ///   ③ 域名互相包含（`api.xxx.com` vs `xxx.com`）。
  static String? resolveProviderId(KeyHit hit, Map<String, String> idToBase) {
    final canon = KeyVendor.canonical(hit.providerId);
    for (final id in idToBase.keys) {
      if (KeyVendor.canonical(id) == canon) return id;
    }
    final probeHost = _hostOf(_probeUrl(hit.providerId));
    if (probeHost.isEmpty) return null;
    for (final e in idToBase.entries) {
      if (_hostOf(e.value) == probeHost) return e.key;
    }
    for (final e in idToBase.entries) {
      final h = _hostOf(e.value);
      if (h.isEmpty) continue;
      if (h.endsWith(probeHost) || probeHost.endsWith(h)) return e.key;
    }
    return null;
  }

  static String _probeUrl(String id) {
    for (final p in probes) {
      if (p.id == id) return p.url;
    }
    return '';
  }

  static String _hostOf(String url) {
    if (url.isEmpty) return '';
    try {
      return Uri.parse(url).host.toLowerCase();
    } catch (_) {
      return '';
    }
  }
}
