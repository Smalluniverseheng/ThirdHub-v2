// 语音识别实现层（依赖 Flutter：录音 + http + 密钥库）
//
// 上层只有一句话：**给我一段录音，还我一段文字**。
// 下层按 `AsrShape` 分三条路走（形态差异见 asr_vendors.dart 文件头）：
//
//   · openaiMultipart → multipart 传文件，字段小写 `file`
//   · chatAudio       → JSON 里塞 base64 Data URL，走 chat/completions
//   · rawJson         → 厂商私有模板；百度那种先换 access_token 再发
//
// ★ 三条必须让用户看懂的失败信息（STYLE_GUIDE 三段式：现象/原因/怎么办）：
//   ① 没填 Key        → 不是网络问题，是没配置，要说清楚去哪儿填；
//   ② 401/403         → Key 错或没权限，把厂商原话带出来；
//   ③ 格式/体积不对   → 说清"本厂商只收什么、这段录音是什么"。
//
// ★ 录音格式是这里的隐形坑：`record` 默认出 m4a（AAC），而小米 MiMo
//   官方只收 wav / mp3 —— 所以录音必须显式指定 wav 16k 单声道，
//   见 `AsrRec`（asr_rec.dart）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    this.host = '',
  });

  final String filePath;
  final String language;
  final String modelOverride;

  /// 自托管时的服务地址（形如 http://192.168.1.5:8000）。
  final String host;

  /// 音频扩展名（决定 MIME 与 multipart 文件名）。
  String get ext => extOfPath(filePath);
}

/// 从路径取扩展名，取不到就按 wav 算。
String extOfPath(String p) {
  final i = p.lastIndexOf('.');
  if (i < 0 || i == p.length - 1) return 'wav';
  final e = p.substring(i + 1).toLowerCase();
  return const ['wav', 'mp3', 'm4a', 'ogg', 'opus', 'flac', 'webm', 'aac', 'pcm']
          .contains(e)
      ? e
      : 'wav';
}

class AsrService {
  const AsrService._();

  static const _kHost = 'asr_host_selfhost';

  /// 自托管服务地址。
  static Future<String> selfHost() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_kHost) ?? '').trim();
  }

  static Future<void> setSelfHost(String host) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kHost, host.trim());
  }

  /// 读厂商 Key。
  ///
  /// 回落顺序：asr 专用键 → 统一库（含旧 aikey_/tts_key_ 回落）。
  static Future<String> keyOf(AsrVendor v) async {
    final p = await SharedPreferences.getInstance();
    final own = (p.getString('asrkey_${v.id}') ?? '').trim();
    if (own.isNotEmpty) return own;
    if (v.id == 'selfhost') return ApiKeys.get(v.id);
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

  /// 厂商是否已就绪。
  ///
  /// ★ 不能只看 `needsKey`：百度的鉴权是「先换 token 再拼到 URL」，
  ///   它没有 Authorization 头（`auth: none`），但**仍然必须有 Key**。
  ///   按 `needsKey` 判会让百度在没填 Key 时被判成"就绪"，
  ///   然后被选成默认引擎，一按麦克风就失败。
  static Future<bool> readyFor(AsrVendor v) async {
    if (v.id == 'selfhost') return (await selfHost()).isNotEmpty;
    return (await keyOf(v)).isNotEmpty;
  }

  /// 当前默认用哪家做语音输入（用户在设置里选的；没选过就用第一家已就绪的）。
  static Future<AsrVendor?> defaultVendor() async {
    final p = await SharedPreferences.getInstance();
    final id = (p.getString('asr_engine') ?? '').trim();
    if (id.isNotEmpty) {
      final v = AsrVendors.byId(id);
      if (v != null) return v;
    }
    for (final v in AsrVendors.all) {
      if (await readyFor(v)) return v;
    }
    return null;
  }

  /// 缺 Key 时的提示（告诉用户去哪儿拿、填哪儿）。
  static String missingHint(AsrVendor v) {
    if (v.id == 'selfhost') {
      return '还没填自建语音服务的地址。\n'
          '· 先在电脑或局域网机器上跑 faster-whisper / FunASR（OpenAI 兼容端点）；\n'
          '· 回到「我的 → 语音识别」把地址填上，形如 http://192.168.1.5:8000。';
    }
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
    if (bytes.length > v.maxBytes) {
      final mb = (bytes.length / 1024 / 1024).toStringAsFixed(1);
      throw AsrException('这段录音 ${mb}MB，超过「${v.name}」的上限'
          '（${(v.maxBytes / 1024 / 1024).round()}MB）。\n'
          '说短一点，或到语音设置里换一家支持长音频的厂商。');
    }

    final key = (keyOverride ?? '').isNotEmpty ? keyOverride! : await keyOf(v);
    if (v.id == 'selfhost') {
      if (req.host.trim().isEmpty) throw AsrException(missingHint(v));
    } else if (key.isEmpty) {
      throw AsrException(missingHint(v));
    }

    final model = req.modelOverride.isNotEmpty ? req.modelOverride : v.model;

    http.Response r;
    switch (v.shape) {
      case AsrShape.openaiMultipart:
        r = await _postMultipart(v, key, model, req, bytes);
      case AsrShape.chatAudio:
        r = await _postChatAudio(v, key, model, req, bytes);
      case AsrShape.rawJson:
        r = await _postRaw(v, key, model, req, bytes);
    }

    _throwIfBad(v, r);

    final text = _extractText(v, r.body);
    if (text == null || text.trim().isEmpty) {
      throw AsrException(
        '「${v.name}」没有返回识别文字。\n响应：${_brief(r.body)}\n'
        '如果录音里确实没人说话，换个说法再试一次。',
      );
    }
    return text.trim();
  }

  // ── ① OpenAI 兼容 multipart ─────────────────────────────
  static Future<http.Response> _postMultipart(
    AsrVendor v,
    String key,
    String model,
    AsrRequest req,
    List<int> bytes,
  ) async {
    final m = http.MultipartRequest('POST', Uri.parse(_urlOf(v, req, '')))
      ..fields['model'] = model
      ..fields['response_format'] = 'json';
    // 语言：OpenAI 用 ISO-639-1，传 zh/en；auto 时不传。
    if (req.language.isNotEmpty && req.language != 'auto') {
      m.fields['language'] = req.language;
    }
    m.files.add(http.MultipartFile.fromBytes(
      v.audioField,
      bytes,
      filename: 'speech.${req.ext}',
    ));
    _applyAuth(m.headers, v, key);
    final streamed = await m.send().timeout(const Duration(seconds: 120));
    return http.Response.fromStream(streamed);
  }

  // ── ② chat/completions + input_audio ───────────────────
  static Future<http.Response> _postChatAudio(
    AsrVendor v,
    String key,
    String model,
    AsrRequest req,
    List<int> bytes,
  ) async {
    final dataUrl = 'data:${audioMime(req.ext)};base64,${base64Encode(bytes)}';
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'input_audio',
              'input_audio': {'data': dataUrl},
            }
          ],
        }
      ],
      'stream': false,
    };
    if (v.asrOptions) {
      body['asr_options'] = {
        if (req.language.isNotEmpty) 'language': req.language,
        'enable_itn': false,
      };
    }
    final headers = <String, String>{'Content-Type': 'application/json'};
    _applyAuth(headers, v, key);
    return http
        .post(Uri.parse(_urlOf(v, req, '')),
            headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 120));
  }

  // ── ③ 私有 JSON（火山 / 百度）─────────────────────────
  static Future<http.Response> _postRaw(
    AsrVendor v,
    String key,
    String model,
    AsrRequest req,
    List<int> bytes,
  ) async {
    // 百度这类要两步：先用 APIKey|SecretKey 换 access_token。
    var token = '';
    if (v.tokenUrl.isNotEmpty) {
      token = await _exchangeToken(v, key);
    }
    final vars = <String, String>{
      'model': model,
      'key': key,
      'token': token,
      'language': req.language,
      'format': req.ext == 'mp3' ? 'mp3' : 'wav',
      'audio': base64Encode(bytes),
      // ★百度要求 len = **原始音频字节数**，不是 base64 长度。
      'len': '${bytes.length}',
    };
    var bodyText = v.bodyTpl;
    vars.forEach((k, val) => bodyText = bodyText.replaceAll('{$k}', val));

    final headers = <String, String>{'Content-Type': 'application/json'};
    _applyAuth(headers, v, key);
    v.extraHeaders.forEach((k, tpl) {
      var val = tpl.replaceAll('{key}', key);
      if (val.contains('{reqid}')) val = val.replaceAll('{reqid}', _uuid());
      headers[k] = val;
    });

    return http
        .post(Uri.parse(_urlOf(v, req, token)),
            headers: headers, body: bodyText)
        .timeout(const Duration(seconds: 120));
  }

  /// 百度 OAuth：Key 形如 `APIKey|SecretKey`。
  static Future<String> _exchangeToken(AsrVendor v, String key) async {
    final parts = key.split('|');
    if (parts.length < 2 || parts[0].trim().isEmpty || parts[1].trim().isEmpty) {
      throw AsrException('「${v.name}」的 Key 格式不对。\n'
          '这一家要填两段：「APIKey|SecretKey」，中间用一根竖线隔开。\n'
          '· APIKey / SecretKey 都在百度智能云「语音技术」应用详情页；\n'
          '· 注意不是「文心一言」的 Key —— 那是另一个应用。');
    }
    final url = Uri.parse(v.tokenUrl).replace(queryParameters: {
      'grant_type': 'client_credentials',
      'client_id': parts[0].trim(),
      'client_secret': parts[1].trim(),
    });
    final r = await http.post(url).timeout(const Duration(seconds: 20));
    final tok = _tokenFrom(r.body);
    if (tok.isEmpty) {
      throw AsrException('「${v.name}」换取 access_token 失败（HTTP ${r.statusCode}）。\n'
          '厂商原话：${_brief(r.body)}\n'
          '核对 APIKey 与 SecretKey 是否属于同一个应用。');
    }
    return tok;
  }

  static String _tokenFrom(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final t = j['access_token'] ?? j['accessToken'] ?? j['token'];
        if (t is String) return t;
      }
    } catch (_) {}
    return '';
  }

  // ── 公共 ──────────────────────────────────────────────
  static String _urlOf(AsrVendor v, AsrRequest req, String token) {
    var u = v.url;
    if (u.contains('{host}')) {
      var h = req.host.trim();
      if (h.isEmpty) h = '';
      if (h.endsWith('/')) h = h.substring(0, h.length - 1);
      if (h.isNotEmpty && !h.startsWith('http')) h = 'http://$h';
      u = u.replaceAll('{host}', h);
    }
    if (u.contains('{token}')) u = u.replaceAll('{token}', token);
    return u;
  }

  static void _applyAuth(Map<String, String> headers, AsrVendor v, String key) {
    if (key.isEmpty || !v.needsKey) return;
    switch (v.auth) {
      case AsrAuth.bearer:
        headers['Authorization'] = 'Bearer $key';
      case AsrAuth.header:
        headers[v.authHeader.isEmpty ? 'api-key' : v.authHeader] = key;
      case AsrAuth.query:
      case AsrAuth.none:
        break;
    }
  }

  static void _throwIfBad(AsrVendor v, http.Response r) {
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw AsrException(
        '「${v.name}」拒绝了这把 Key（HTTP ${r.statusCode}）。\n'
        '厂商原话：${_brief(r.body)}\n'
        '检查：Key 是否填错、有没有过期、额度是否用完、'
        '该 Key 有没有开通语音识别权限。',
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
  }

  /// 从响应里取识别文本。
  static String? _extractText(AsrVendor v, String body) {
    try {
      final j = jsonDecode(body);
      final direct = pickJsonPath(j, v.textPath);
      if (direct != null && direct.trim().isNotEmpty) return direct;
      // 兜底：各家兼容格式
      for (final p in const [
        'text',
        'result.0',
        'choices.0.message.content',
        'choices.0.text',
        'data.text',
        'body.result.text',
        'resp.text',
      ]) {
        final t = pickJsonPath(j, p);
        if (t != null && t.trim().isNotEmpty) return t;
      }
      return null;
    } catch (_) {
      return body.trim().isEmpty ? null : body;
    }
  }

  /// 厂商返回的原文（截短，便于展示）。
  static String _brief(String body) {
    final s = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 220 ? '${s.substring(0, 220)}…' : s;
  }

  static final _rnd = Random();

  /// 简易请求 id（火山要求每个请求唯一，UUID 格式最佳）。
  static String _uuid() {
    String hex(int n) {
      final b = StringBuffer();
      for (var i = 0; i < n; i++) {
        b.write(_rnd.nextInt(16).toRadixString(16));
      }
      return b.toString();
    }

    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  /// 连通性探测（不发音频，只打一次看端点是否活着）。
  static Future<String> probe(AsrVendor v, {String? keyOverride}) async {
    final key = (keyOverride ?? '').isNotEmpty ? keyOverride! : await keyOf(v);
    if (v.id != 'selfhost' && key.isEmpty) return missingHint(v);
    final host = await selfHost();
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      _applyAuth(headers, v, key);
      final r = await http
          .post(Uri.parse(_urlOf(v, AsrRequest(filePath: 'x.wav', host: host), '')),
              headers: headers, body: '{"probe":1}')
          .timeout(const Duration(seconds: 15));
      // 400/422 说明端点是活的（只是 body 不对）——这正是我们要的
      if (r.statusCode == 400 || r.statusCode == 422) {
        return '端点可达（HTTP ${r.statusCode}）· ${v.name}';
      }
      if (r.statusCode == 200) return '端点可达 · ${v.name}';
      if (r.statusCode == 401 || r.statusCode == 403) {
        return '端点可达，但 Key 被拒（HTTP ${r.statusCode}）· ${v.name}';
      }
      if (r.statusCode == 404) {
        return '端点不存在（HTTP 404）—— 该厂商可能改了接口地址 · ${v.name}';
      }
      return 'HTTP ${r.statusCode} · ${v.name}';
    } catch (e) {
      return '连不上「${v.name}」：$e';
    }
  }
}
