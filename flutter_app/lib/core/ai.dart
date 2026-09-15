// AI 模块: 厂商/模型注册表(从 thirdhub.pages.dev 拉取, 快照兜底) + OpenAI 兼容对话
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_snapshot.dart';

class AiProvider {
  final String id, name, base, type;
  final List<String> models, image, video;
  AiProvider(this.id, this.name, this.base, this.type, this.models, this.image, this.video);
  factory AiProvider.from(Map<String, dynamic> j) => AiProvider(
    j['id'] ?? '', j['name'] ?? j['id'] ?? '', j['base'] ?? '', j['type'] ?? 'openai',
    List<String>.from(j['models'] ?? []), List<String>.from(j['image'] ?? []), List<String>.from(j['video'] ?? []));
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'base': base, 'type': type, 'models': models, 'image': image, 'video': video};
}

class AiRegistry {
  static List<AiProvider> providers = kAiSnapshot.map((e) => AiProvider.from(e)).toList();
  static DateTime? refreshedAt;
  static final _change = StreamController<void>.broadcast();
  static Stream<void> get onChange => _change.stream;

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final cache = p.getString('ai_providers_cache');
    if (cache != null) {
      try { providers = (jsonDecode(cache) as List).map((e) => AiProvider.from(Map<String, dynamic>.from(e))).toList(); } catch (_) {}
    }
    unawaited(refresh());
  }

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
      f(o, 'base') ?? '', f(o, 'type') ?? 'openai', lst(o, 'models'), lst(o, 'image'), lst(o, 'video')))
      .where((p) => p.id.isNotEmpty).toList();
  }

  static AiProvider? byId(String id) { for (final p in providers) { if (p.id == id) return p; } return null; }

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
  static Future<String> chat({required AiProvider provider, required String model,
      required List<Map<String, String>> messages, required void Function(String delta) onDelta}) async {
    final key = await AiRegistry.keyOf(provider.id);
    if (key.isEmpty) throw Exception('请先填写 ${provider.name} 的 API Key');
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
    final resp = await http.Client().send(req).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      final body = await resp.stream.bytesToString();
      throw Exception('HTTP ${resp.statusCode}: ${body.substring(0, body.length.clamp(0, 200))}');
    }
    final buf = StringBuffer(); var leftover = '';
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
    return buf.toString();
  }
}
