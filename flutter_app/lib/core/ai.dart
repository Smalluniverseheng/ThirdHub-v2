// AI 模块: 厂商/模型注册表(从 thirdhub.pages.dev 拉取, 快照兜底) + OpenAI 兼容对话
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_snapshot.dart';

class AiProvider {
  final String id, name, base, type;
  final List<String> models, image, video, deprecated;
  AiProvider(this.id, this.name, this.base, this.type, this.models, this.image, this.video, [this.deprecated = const []]);
  factory AiProvider.from(Map<String, dynamic> j) => AiProvider(
    j['id'] ?? '', j['name'] ?? j['id'] ?? '', j['base'] ?? '', j['type'] ?? 'openai',
    List<String>.from(j['models'] ?? []), List<String>.from(j['image'] ?? []), List<String>.from(j['video'] ?? []),
    List<String>.from(j['deprecated'] ?? []));
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'base': base, 'type': type, 'models': models, 'image': image, 'video': video, 'deprecated': deprecated};
}

class AiRegistry {
  static List<AiProvider> providers = kAiSnapshot.map((e) => AiProvider.from(e)).toList();
  static List<AiProvider> _custom = [];
  // 内置厂商 + 用户自定义(中转站)厂商, 自定义排最前
  static List<AiProvider> get all => [..._custom, ...providers];
  static DateTime? refreshedAt;
  static final _change = StreamController<void>.broadcast();
  static Stream<void> get onChange => _change.stream;

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final cache = p.getString('ai_providers_cache');
    if (cache != null) {
      try { providers = (jsonDecode(cache) as List).map((e) => AiProvider.from(Map<String, dynamic>.from(e))).toList(); } catch (_) {}
    }
    await loadCustom();
    unawaited(refresh());
  }

  // ── 自定义厂商(中转站): name+base+key+models 全部自定义 ──
  static Future<void> loadCustom() async {
    final p = await SharedPreferences.getInstance();
    try {
      _custom = (jsonDecode(p.getString('ai_custom_providers') ?? '[]') as List)
          .map((e) => AiProvider.from(Map<String, dynamic>.from(e))).toList();
    } catch (_) { _custom = []; }
  }
  static Future<void> _saveCustom() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ai_custom_providers', jsonEncode(_custom.map((e) => e.toJson()).toList()));
    _change.add(null);
  }
  static Future<void> saveCustomProvider(AiProvider cp) async {
    final i = _custom.indexWhere((x) => x.id == cp.id);
    if (i >= 0) { _custom[i] = cp; } else { _custom.insert(0, cp); }
    await _saveCustom();
  }
  static Future<void> removeCustomProvider(String id) async {
    _custom.removeWhere((x) => x.id == id);
    await _saveCustom();
  }
  static bool isCustom(String id) => _custom.any((x) => x.id == id);

  // 从网站实时拉取 ai-models.js 并解析(失败则保留缓存/快照)
  static Future<bool> refresh() async {
    try {
      final r = await http.get(Uri.parse('https://thirdhub.pages.dev/js/ai/ai-models.js')).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return false;
      final list = _parse(r.body);
      if (list.isEmpty) return false;
      providers = list; refreshedAt = DateTime.now();
      final p = await SharedPreferences.getInstance();
      await p.setString('ai_providers_cache', jsonEncode(list.map((e) => e.toJson()).toList()));
      _change.add(null);
      return true;
    } catch (_) { return false; }
  }

  // 容错解析 PROVIDERS 数组(顶层对象切分 + 字段正则)
  static List<AiProvider> _parse(String src) {
    final marker = 'export const PROVIDERS = [';
    final si = src.indexOf(marker);
    if (si < 0) return [];
    var depth = 0; var cur = ''; final objs = <String>[];
    final body = src.substring(si + marker.length - 1);
    for (var k = 1; k < body.length; k++) {
      final ch = body[k];
      if (ch == '{') { depth++; if (depth == 1) cur = ''; }
      if (depth >= 1) cur += ch;
      if (ch == '}') { depth--; if (depth == 0) objs.add(cur); }
      if (depth == 0 && ch == ']' && objs.isNotEmpty && cur.isEmpty) break;
    }
    String? f(String s, String key) {
      final m = RegExp("$key\\s*:\\s*'([^']*)'").firstMatch(s);
      return m?.group(1);
    }
    List<String> lst(String s, String key) {
      final m = RegExp('$key\\s*:\\s*\\[').firstMatch(s);
      if (m == null) return [];
      var d = 0; final buf = StringBuffer();
      for (var k = m.end; k < s.length; k++) {
        final ch = s[k];
        if (ch == '[') d++;
        if (ch == ']') { d--; if (d < 0) break; }
        buf.write(ch);
      }
      final raw = RegExp("'([^']+)'").allMatches(buf.toString()).map((e) => e.group(1)!).toList();
      final seen = <String>{}; return raw.where((e) => seen.add(e)).toList();
    }
    return objs.map((o) => AiProvider(f(o, 'id') ?? '', f(o, 'name') ?? f(o, 'id') ?? '',
      f(o, 'base') ?? '', f(o, 'type') ?? 'openai', lst(o, 'models'), lst(o, 'image'), lst(o, 'video'), lst(o, 'deprecated')))
      .where((p) => p.id.isNotEmpty).toList();
  }

  static AiProvider? byId(String id) { for (final p in all) { if (p.id == id) return p; } return null; }

  // API key 管理(本机存储)
  static Future<String> keyOf(String providerId) async =>
      (await SharedPreferences.getInstance()).getString('aikey_$providerId') ?? '';
  static Future<void> setKey(String providerId, String key) async =>
      (await SharedPreferences.getInstance()).setString('aikey_$providerId', key);

  // 最近使用的模型
  static Future<(String, String)> lastModel() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString('ai_last_provider') ?? 'deepseek', p.getString('ai_last_model') ?? 'deepseek-chat');
  }
  static Future<void> setLastModel(String providerId, String model) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ai_last_provider', providerId); await p.setString('ai_last_model', model);
  }
}

// OpenAI 兼容流式对话(anthropic 类型走 /messages 非流式)
class AiChat {
  // onDelta: 增量文本; 返回完整文本
  // mcpTools: 注入的 MCP 工具(OpenAI function-calling); onToolCall(name): 工具调用进度提示
  static Future<String> chat({required AiProvider provider, required String model,
      required List<Map<String, String>> messages, required void Function(String delta) onDelta,
      List<Map<String, dynamic>>? mcpTools, void Function(String toolName)? onToolCall}) async {
    final key = await AiRegistry.keyOf(provider.id);
    if (key.isEmpty) throw Exception('请先填写 ${provider.name} 的 API Key');
    // MCP 工具链: 非流式请求带 tools → 有 tool_calls 就执行并追问(最多3轮) → 最终走流式回答
    if (mcpTools != null && mcpTools.isNotEmpty && provider.type != 'anthropic') {
      final msgs = messages.map((m) => Map<String, dynamic>.from(m)).toList();
      final tools = [ for (final t in mcpTools) {'type': 'function', 'function': {
        'name': t['name'], 'description': t['description'] ?? '',
        'parameters': t['inputSchema'] ?? {'type': 'object', 'properties': {}}}} ];
      for (var round = 0; round < 3; round++) {
        final r = await http.post(Uri.parse('${provider.base}/chat/completions'),
          headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
          body: jsonEncode({'model': model, 'messages': msgs, 'tools': tools, 'stream': false}))
          .timeout(const Duration(seconds: 60));
        if (r.statusCode != 200) break; // 不支持 tools 的厂商: 直接放弃工具, 走普通流式
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        final msg = j['choices']?[0]?['message'];
        if (msg == null) break;
        final calls = (msg['tool_calls'] as List? ?? []);
        if (calls.isEmpty) break; // 模型不需要工具
        msgs.add({'role': 'assistant', 'content': msg['content'] ?? '', 'tool_calls': calls});
        for (final call in calls) {
          final fn = call['function'] ?? {};
          final name = '${fn['name'] ?? ''}';
          onToolCall?.call(name);
          final tool = mcpTools.firstWhere((t) => t['name'] == name, orElse: () => {});
          String out;
          try {
            Map<String, dynamic> args = {};
            try { args = Map<String, dynamic>.from(jsonDecode('${fn['arguments'] ?? '{}'}')); } catch (_) {}
            final result = await Mcp.callTool('${tool['serverId']}', name, args);
            // MCP 返回 content: [{type:'text', text:...}]
            out = [ for (final c in (result['content'] as List? ?? [])) '${c['text'] ?? c}' ].join('\n');
            if (out.isEmpty) out = jsonEncode(result);
          } catch (e) { out = '工具调用失败: $e'; }
          msgs.add({'role': 'tool', 'tool_call_id': '${call['id'] ?? ''}', 'content': out});
        }
      }
    }
    if (provider.type == 'anthropic') {
      final r = await http.post(Uri.parse('${provider.base}/messages'),
        headers: {'x-api-key': key, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json'},
        body: jsonEncode({'model': model, 'max_tokens': 4096,
          'messages': messages.where((m) => m['role'] != 'system').toList(),
          if (messages.any((m) => m['role'] == 'system'))
            'system': messages.firstWhere((m) => m['role'] == 'system')['content']}));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}: ${r.body.substring(0, r.body.length.clamp(0, 200))}');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final text = ((j['content'] as List?)?.map((e) => e['text'] ?? '').join() ?? '');
      onDelta(text); return text;
    }
    final req = http.Request('POST', Uri.parse('${provider.base}/chat/completions'));
    req.headers.addAll({'Authorization': 'Bearer $key', 'Content-Type': 'application/json'});
    req.body = jsonEncode({'model': model, 'messages': messages, 'stream': true});
    http.StreamedResponse resp;
    try { resp = await http.Client().send(req).timeout(const Duration(seconds: 30)); }
    catch (_) { return _nonStream(provider, key, model, messages, onDelta); }
    if (resp.statusCode != 200) {
      final body = await resp.stream.bytesToString();
      throw Exception('HTTP ${resp.statusCode}: ${body.substring(0, body.length.clamp(0, 200))}');
    }
    final buf = StringBuffer(); var leftover = ''; bool streamBroken = false;
    await for (final chunk in resp.stream.transform(utf8.decoder)) {
      final data = leftover + chunk;
      final lines = data.split('\n');
      leftover = lines.removeLast();
      for (var line in lines) {
        line = line.trim();
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') break;
        try {
          final delta = jsonDecode(payload)['choices']?[0]?['delta']?['content'];
          if (delta is String && delta.isNotEmpty) { buf.write(delta); onDelta(delta); }
        } catch (_) {}
      }
    }
    // 流式没吐出任何内容(部分厂商不支持 stream) → 自动回退非流式
    if (buf.isEmpty) return _nonStream(provider, key, model, messages, onDelta);
    return buf.toString();
  }

  static Future<String> _nonStream(AiProvider provider, String key, String model,
      List<Map<String, String>> messages, void Function(String) onDelta) async {
    final r = await http.post(Uri.parse('${provider.base}/chat/completions'),
      headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
      body: jsonEncode({'model': model, 'messages': messages, 'stream': false})).timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}: ${r.body.substring(0, r.body.length.clamp(0, 200))}');
    final text = jsonDecode(utf8.decode(r.bodyBytes))['choices']?[0]?['message']?['content'] ?? '';
    if (text.isEmpty) throw Exception('模型没有返回内容');
    onDelta(text); return text;
  }
}


// ═══ Key 验证与自动识别(与网站一致: 真实对话请求才算匹配, 前缀仅作优先提示) ═══
class AiKeyDetect {
  // 对指定厂商做一次最小对话验证
  static Future<AiProvider?> testKey(AiProvider p, String key, {int timeoutMs = 9000}) async {
    if (p.models.isEmpty || p.base.isEmpty) return null;
    final model = p.models.first;
    final base = p.base.replaceAll(RegExp(r'/$'), '');
    try {
      http.Response r;
      if (p.type == 'anthropic') {
        r = await http.post(Uri.parse('$base/messages'),
          headers: {'Content-Type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01'},
          body: jsonEncode({'model': model, 'max_tokens': 1, 'messages': [{'role': 'user', 'content': 'hi'}]}))
          .timeout(Duration(milliseconds: timeoutMs));
      } else {
        r = await http.post(Uri.parse('$base/chat/completions'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $key'},
          body: jsonEncode({'model': model, 'messages': [{'role': 'user', 'content': 'hi'}], 'max_tokens': 1, 'stream': false}))
          .timeout(Duration(milliseconds: timeoutMs));
      }
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final ok = p.type == 'anthropic' ? j['content'] != null : j['choices'] != null;
      return ok ? p : null;
    } catch (_) { return null; }
  }

  // 自动识别 Key 属于哪家厂商: 前缀命中优先, 其余每批8家并行, 任一成功即返回
  static Future<AiProvider?> identify(String key, {void Function(String)? onProgress}) async {
    final usable = AiRegistry.all.where((p) =>
      p.base.isNotEmpty && p.models.isNotEmpty && (p.type == 'openai' || p.type == 'anthropic')).toList();
    const hints = [
      ['sk-ant-', 'anthropic'], ['sk-or-', 'openrouter'], ['xai-', 'xai'], ['gsk_', 'groq'],
      ['AIza', 'google'], ['pplx-', 'perplexity'], ['nvapi-', 'nvidia'], ['sk-proj-', 'openai'], ['tp-', 'xiaomi'],
    ];
    final tried = <String>{};
    for (final h in hints) {
      if (key.toLowerCase().startsWith(h[0].toLowerCase())) {
        AiProvider? p;
        for (final x in usable) { if (x.id == h[1]) { p = x; break; } }
        if (p != null) {
          onProgress?.call('优先验证 ${p.name}…');
          final hit = await testKey(p, key);
          if (hit != null) return hit;
          tried.add(p.id);
        }
      }
    }
    final rest = usable.where((p) => !tried.contains(p.id)).toList();
    for (var i = 0; i < rest.length; i += 8) {
      final batch = rest.sublist(i, (i + 8).clamp(0, rest.length));
      onProgress?.call('正在验证 ${batch.map((e) => e.name).join(' / ')}…');
      final results = await Future.wait(batch.map((p) => testKey(p, key)));
      for (final r in results) { if (r != null) return r; }
    }
    return null;
  }

  // 探测是否中转站通用 Key: 并行请求3个品牌, 成功≥2家判定为中转站密钥
  static Future<bool> probeRelay(String key) async {
    const probes = [
      ('openai', 'gpt-4o-mini', 'https://api.openai.com/v1'),
      ('deepseek', 'deepseek-chat', 'https://api.deepseek.com/v1'),
      ('zhipu', 'glm-4-flash', 'https://open.bigmodel.cn/api/paas/v4'),
    ];
    var ok = 0;
    await Future.wait(probes.map((pr) async {
      try {
        final r = await http.post(Uri.parse('${pr.$3}/chat/completions'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $key'},
          body: jsonEncode({'model': pr.$2, 'messages': [{'role': 'user', 'content': 'hi'}], 'max_tokens': 1}))
          .timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) ok++;
        else { final b = r.body; if (RegExp(r'invalid.*model|model.*not', caseSensitive: false).hasMatch(b)) ok++; }
      } catch (_) {}
    }));
    return ok >= 2;
  }

  // 保存中转密钥: 自动填到所有未配置 Key 的 openai 型厂商
  static Future<int> saveRelayKey(String key) async {
    var n = 0;
    for (final p in AiRegistry.all) {
      if (p.type != 'openai') continue;
      if ((await AiRegistry.keyOf(p.id)).isEmpty) { await AiRegistry.setKey(p.id, key); n++; }
    }
    return n;
  }
}

// ═══ 联网搜索(与网站 web-search.js 一致: tavily/brave/serpapi/searxng) ═══
class WebSearchService {
  final String id, name, keyHint, desc;
  final bool needUrl;
  const WebSearchService(this.id, this.name, this.keyHint, this.desc, this.needUrl);
}

class WebSearch {
  static const services = [
    WebSearchService('tavily', 'Tavily', 'tvly-...', '专为 AI 设计的搜索 API, 每月有免费额度', false),
    WebSearchService('brave', 'Brave Search', 'BSA...', 'Brave 搜索引擎 API, 免费额度 2000 次/月', false),
    WebSearchService('serpapi', 'SerpAPI(Google)', '一串十六进制 Key', 'Google 搜索结果 API', false),
    WebSearchService('searxng', 'SearXNG(自建)', '可留空', '自建搜索聚合引擎, 填实例地址即可', true),
  ];
  static WebSearchService? serviceOf(String id) {
    for (final s in services) { if (s.id == id) return s; } return null;
  }

  static Future<Map<String, String>> config() async {
    final p = await SharedPreferences.getInstance();
    return {'service': p.getString('websearch_service') ?? '',
      'key': p.getString('websearch_key') ?? '', 'url': p.getString('websearch_url') ?? ''};
  }
  static Future<void> setConfig(String service, String key, String url) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('websearch_service', service);
    await p.setString('websearch_key', key.trim());
    await p.setString('websearch_url', url.trim());
  }
  static Future<bool> configured() async {
    final c = await config();
    return c['service']!.isNotEmpty && (c['key']!.isNotEmpty || (c['service'] == 'searxng' && c['url']!.isNotEmpty));
  }

  // 统一搜索入口: 返回 [{title,url,snippet}]
  static Future<List<Map<String, String>>> search(String query, {int limit = 5}) async {
    final c = await config();
    final svc = c['service']!;
    if (svc.isEmpty) throw Exception('未配置联网搜索服务, 请到 AI 设置里配置');
    List<Map<String, String>> items = [];
    Future<List> getJson(Uri u, [Map<String, String>? h]) async {
      final r = await http.get(u, headers: h).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      return jsonDecode(utf8.decode(r.bodyBytes)) as List;
    }
    if (svc == 'tavily') {
      final r = await http.post(Uri.parse('https://api.tavily.com/search'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'api_key': c['key'], 'query': query, 'max_results': limit, 'search_depth': 'basic'}))
        .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('Tavily HTTP ${r.statusCode}');
      items = [ for (final x in (jsonDecode(utf8.decode(r.bodyBytes))['results'] as List? ?? []))
        {'title': '${x['title'] ?? ''}', 'url': '${x['url'] ?? ''}', 'snippet': '${x['content'] ?? ''}'} ];
    } else if (svc == 'brave') {
      final d = jsonDecode(utf8.decode((await http.get(Uri.parse('https://api.search.brave.com/res/v1/web/search?q=${Uri.encodeComponent(query)}&count=$limit'),
        headers: {'X-Subscription-Token': c['key']!, 'Accept': 'application/json'}).timeout(const Duration(seconds: 12))).bodyBytes));
      items = [ for (final x in (d['web']?['results'] as List? ?? []))
        {'title': '${x['title'] ?? ''}', 'url': '${x['url'] ?? ''}', 'snippet': '${x['description'] ?? ''}'} ];
    } else if (svc == 'serpapi') {
      final d = jsonDecode(utf8.decode((await http.get(Uri.parse('https://serpapi.com/search.json?engine=google&api_key=${Uri.encodeComponent(c['key']!)}&q=${Uri.encodeComponent(query)}'))
        .timeout(const Duration(seconds: 12))).bodyBytes));
      items = [ for (final x in (d['organic_results'] as List? ?? []))
        {'title': '${x['title'] ?? ''}', 'url': '${x['link'] ?? ''}', 'snippet': '${x['snippet'] ?? ''}'} ];
    } else if (svc == 'searxng') {
      final base = c['url']!.replaceAll(RegExp(r'/$'), '');
      if (base.isEmpty) throw Exception('请填写 SearXNG 实例地址');
      final r = await http.get(Uri.parse('$base/search?format=json&q=${Uri.encodeComponent(query)}'),
        headers: c['key']!.isNotEmpty ? {'Authorization': 'Bearer ${c['key']}'} : null).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('SearXNG HTTP ${r.statusCode}');
      items = [ for (final x in (jsonDecode(utf8.decode(r.bodyBytes))['results'] as List? ?? []))
        {'title': '${x['title'] ?? ''}', 'url': '${x['url'] ?? ''}', 'snippet': '${x['content'] ?? ''}'} ];
    }
    return items.take(limit).where((x) => x['title']!.isNotEmpty || x['snippet']!.isNotEmpty).toList();
  }

  // 搜索结果 → 注入模型的上下文(与网站一致)
  static String toContext(String query, List<Map<String, String>> items) {
    final lines = [ for (var i = 0; i < items.length; i++) '[${i + 1}] ${items[i]['title']}\n${items[i]['snippet']}\n来源: ${items[i]['url']}' ];
    return '以下是针对「$query」的联网搜索结果, 请结合搜索结果回答, 并在引用处标注来源编号:\n\n${lines.join('\n\n')}';
  }
}

// ═══ MCP 客户端(与网站 mcp-client.js 一致: JSON-RPC over Streamable HTTP) ═══
class McpServer {
  String id, name, url, status; bool enabled; String error;
  List<Map<String, dynamic>> tools;
  McpServer({required this.id, required this.name, required this.url,
    this.enabled = true, this.status = 'disconnected', this.error = '', this.tools = const []});
  factory McpServer.from(Map<String, dynamic> j) => McpServer(
    id: j['id'] ?? '', name: j['name'] ?? '', url: j['url'] ?? '',
    enabled: j['enabled'] ?? true, tools: [ for (final t in (j['tools'] as List? ?? [])) Map<String, dynamic>.from(t) ]);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'enabled': enabled, 'tools': tools};
}

class Mcp {
  static List<McpServer> servers = [];
  static int _nextId = 1;
  static final _change = StreamController<void>.broadcast();
  static Stream<void> get onChange => _change.stream;

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    try { servers = [ for (final e in jsonDecode(p.getString('mcp_servers') ?? '[]') as List) McpServer.from(Map<String, dynamic>.from(e)) ]; } catch (_) {}
  }
  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('mcp_servers', jsonEncode(servers.map((e) => e.toJson()).toList()));
    _change.add(null);
  }
  static Future<McpServer> add(String name, String url) async {
    final s = McpServer(id: 'mcp-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}', name: name, url: url);
    servers.add(s); await _save(); return s;
  }
  static Future<void> remove(String id) async { servers.removeWhere((s) => s.id == id); await _save(); }
  static Future<void> toggle(String id, bool enabled) async {
    final s = servers.firstWhere((x) => x.id == id);
    s.enabled = enabled;
    if (!enabled) { s.status = 'disconnected'; s.tools = []; }
    await _save();
  }

  static Future<Map<String, dynamic>> _rpc(String url, String method, Map<String, dynamic> params) async {
    final r = await http.post(Uri.parse(url),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'},
      body: jsonEncode({'jsonrpc': '2.0', 'id': _nextId++, 'method': method, 'params': params}))
      .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final body = utf8.decode(r.bodyBytes);
    Map<String, dynamic> j;
    if ((r.headers['content-type'] ?? '').contains('text/event-stream')) {
      final line = body.split('\n').firstWhere((l) => l.startsWith('data:'), orElse: () => '');
      if (line.isEmpty) throw Exception('SSE 响应为空');
      j = jsonDecode(line.substring(5).trim());
    } else { j = jsonDecode(body); }
    if (j['error'] != null) throw Exception('${j['error']['message'] ?? j['error']}');
    return Map<String, dynamic>.from(j['result'] ?? {});
  }

  static Future<bool> connect(String id) async {
    final s = servers.firstWhere((x) => x.id == id);
    s.status = 'connecting'; _change.add(null);
    try {
      await _rpc(s.url, 'initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
        'clientInfo': {'name': 'ThirdHub', 'version': '4.8.0'}});
      final result = await _rpc(s.url, 'tools/list', {});
      s.tools = [ for (final t in (result['tools'] as List? ?? [])) Map<String, dynamic>.from(t) ];
      s.status = 'connected'; s.error = '';
    } catch (e) { s.status = 'error'; s.error = '$e'; }
    _change.add(null); unawaited(_save());
    return s.status == 'connected';
  }

  static Future<Map<String, dynamic>> callTool(String serverId, String toolName, Map<String, dynamic> args) async {
    final s = servers.firstWhere((x) => x.id == serverId);
    if (s.status != 'connected') throw Exception('MCP 服务未连接');
    return _rpc(s.url, 'tools/call', {'name': toolName, 'arguments': args});
  }

  // 汇总所有已连接且启用服务的工具(供对话注入)
  static List<Map<String, dynamic>> allTools() => [
    for (final s in servers) if (s.enabled && s.status == 'connected')
      for (final t in s.tools) {'serverId': s.id, 'serverName': s.name, ...t} ];
}
