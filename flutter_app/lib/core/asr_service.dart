// 语音识别实现层（依赖 Flutter：录音 + http + 密钥库）
//
// 设计取舍：
//   · 音频先存临时文件再上传 —— Flutter 的 record 插件产出的是文件路径，
//     multipart 上传比把整段 base64 塞进 JSON 省内存（30 秒 wav ≈ 1MB）。
//   · Key 一律走统一密钥库（ApiKeyStore），用户在 AI / 语音朗读里填过的
//     同一家 Key 这里直接带出，不用重复输入。
//   · 401/403/429 分别给不同提示 —— 这是用户最常撞的三种失败。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_keys.dart';
import 'api_keys_store.dart';
import 'asr_vendors.dart';

/// 一次识别请求。
class AsrRequest {
  const AsrRequest({
    required this.filePath,
    this.language = 'zh',
    this.modelOverride = '',
  });

  final String filePath;
  final String language;
  final String modelOverride;
}

class AsrService {
  const AsrService._();

  /// 读厂商 Key。
  ///
  /// 回落顺序：asr 专用键 → 统一库（含旧 aikey_/tts_key_ 回落）。
  /// 后者让「用户在 AI 或语音朗读里填过的同一家 Key」直接生效，不用重复输入。
  static Future<String> keyOf(AsrVendor v) async {
    final p = await SharedPreferences.getInstance();
    final own = (p.getString('asrkey_${v.id}') ?? '').trim();
    if (own.isNotEmpty) return own;
    return ApiKeys.get(v.id);
  }

  /// 写入厂商 Key（语音识别可单独配一把，不影响 AI / 语音朗读）。
  static Future<void> setKey(AsrVendor v, String key) async {
    final p = await SharedPreferences.getInstance();
    final k = 'asrkey_${v.id}';
    final s = key.trim();
    if (s.isEmpty) {
      await p.remove(k);
    } else {
      await p.setString(k, s);
    }
  }

  /// 厂商是否已就绪（有 Key 或不需要 Key）。
  static Future<bool> readyFor(AsrVendor v) async {
    if (v.group == '自托管') return true;
    return (await keyOf(v)).isNotEmpty;
  }

  /// 缺 Key 时的提示（告诉用户去哪儿拿、填哪儿）。
  static String missingHint(AsrVendor v) {
    final names = KeyVendor.allNames(v.id);
    final alias = names.length > 1 ? '（也叫 ${names.skip(1).join(' / ')}）' : '';
    return '还没填「${v.name}」$alias 的 Key。\n'
        '到厂商控制台申请后，填到「我的 → 语音识别」里；'
        '如果 AI 或语音朗读里已经填过同一家，会自动带出。';
  }

  /// 真正的识别请求。
  ///
  /// 返回识别文本。失败一律抛 [AsrException]，消息里带厂商名与厂商返回的原话。
  static Future<String> transcribe(
    AsrVendor v,
    AsrRequest req, {
    String? keyOverride,
  }) async {
    final file = File(req.filePath);
    if (!file.existsSync()) {
      throw AsrException('录音文件不存在：${req.filePath}');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw AsrException('录音是空的，没录到声音。再点一次麦克风试试。');
    }

    final key = (keyOverride ?? '').isNotEmpty ? keyOverride! : await keyOf(v);
    if (v.group != '自托管' && key.isEmpty) {
      throw AsrException(missingHint(v));
    }

    final model =
        req.modelOverride.isNotEmpty ? req.modelOverride : v.model;
    final isMultipart = v.contentType.contains('multipart');
    final r = isMultipart ? await _postMultipart(v, key, model, req, bytes)
                          : await _postJson(v, key, model, req, bytes);

    // ── 错误分层：把厂商原话带出来，用户才知道是 Key 还是额度还是格式 ──
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw AsrException(
        '「${v.name}」拒绝了这把 Key（HTTP ${r.statusCode}）。\n'
        '厂商原话：${_brief(r.body)}\n'
        '检查：Key 是否填错、有没有过期、额度是否用完。',
      );
    }
    if (r.statusCode == 429) {
      throw AsrException(
        '「${v.name}」提示请求过于频繁（HTTP 429）。\n厂商原话：${_brief(r.body)}',
      );
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw AsrException(
        '「${v.name}」返回 HTTP ${r.statusCode}。\n厂商原话：${_brief(r.body)}',
      );
    }

    // ── 取文本 ──
    final text = _extractText(v, r.body);
    if (text == null || text.trim().isEmpty) {
      throw AsrException(
        '「${v.name}」没有返回识别文字。\n响应：${_brief(r.body)}',
      );
    }
    return text.trim();
  }

  static Future<http.Response> _postMultipart(
    AsrVendor v,
    String key,
    String model,
    AsrRequest req,
    List<int> bytes,
  ) async {
    final req2 = http.MultipartRequest('POST', Uri.parse(v.url))
      ..fields['model'] = model
      ..fields['language'] = req.language
      ..files.add(
        http.MultipartFile.fromBytes(v.audioField, bytes, filename: 'speech.wav'),
      );
    _applyAuth(req2.headers, v, key);
    final streamed = await req2.send().timeout(const Duration(seconds: 90));
    return http.Response.fromStream(streamed);
  }

  static Future<http.Response> _postJson(
    AsrVendor v,
    String key,
    String model,
    AsrRequest req,
    List<int> bytes,
  ) async {
    final body = v.bodyTpl
        .replaceAll('{model}', model)
        .replaceAll('{key}', key)
        .replaceAll('{language}', req.language)
        .replaceAll('{format}', 'wav')
        .replaceAll('{audio}', base64Encode(bytes));
    final headers = <String, String>{'Content-Type': v.contentType};
    _applyAuth(headers, v, key);
    return http
        .post(Uri.parse(v.url), headers: headers, body: body)
        .timeout(const Duration(seconds: 90));
  }

  static void _applyAuth(Map<String, String> headers, AsrVendor v, String key) {
    if (key.isEmpty) return;
    switch (v.auth) {
      case AsrAuth.bearer:
        headers['Authorization'] = 'Bearer $key';
      case AsrAuth.header:
        headers[v.authHeader.isEmpty ? 'api-key' : v.authHeader] = key;
      case AsrAuth.query:
        break; // query 已在 URL 里（调用方拼）
    }
  }

  /// 从响应里取识别文本。
  static String? _extractText(AsrVendor v, String body) {
    try {
      final j = jsonDecode(body);
      final direct = pickJsonPath(j, v.textPath);
      if (direct != null && direct.trim().isNotEmpty) return direct;
      // OpenAI 兼容：choices[0].text 或 choices[0].message.content
      final alt = pickJsonPath(j, 'choices.0.text') ??
          pickJsonPath(j, 'choices.0.message.content');
      return alt;
    } catch (_) {
      return body.trim().isEmpty ? null : body;
    }
  }

  /// 厂商返回的原文（截短，便于展示）。
  static String _brief(String body) {
    final s = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 220 ? '${s.substring(0, 220)}…' : s;
  }

  /// 连通性探测（不发音频，只打一次看端点是否活着）。
  static Future<String> probe(AsrVendor v, {String? keyOverride}) async {
    final key = (keyOverride ?? '').isNotEmpty ? keyOverride! : await keyOf(v);
    if (v.group != '自托管' && key.isEmpty) return missingHint(v);
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      _applyAuth(headers, v, key);
      final r = await http
          .post(
            Uri.parse(v.url),
            headers: headers,
            body: '{"probe":1}',
          )
          .timeout(const Duration(seconds: 15));
      // 400/422 说明端点是活的（只是 body 不对）——这正是我们要的
      if (r.statusCode == 400 || r.statusCode == 422 || r.statusCode == 401) {
        return '端点可达（HTTP ${r.statusCode}）· ${v.name}';
      }
      return 'HTTP ${r.statusCode} · ${v.name}';
    } catch (e) {
      return '连不上「${v.name}」：$e';
    }
  }
}