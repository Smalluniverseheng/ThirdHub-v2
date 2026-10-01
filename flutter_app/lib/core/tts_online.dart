// 在线 TTS 的**执行层**：读用户配置 → 组装请求 → 发出去 → 落成音频文件。
//
// 分层理由：`tts_vendors.dart` 是纯数据纯函数（可被自检逐字段断言），
// 这里才是真正碰网络、碰 SharedPreferences 的地方。混在一起的话，
// 自检就必须在纯 Dart VM 里起一个 HTTP 服务才能跑。
//
// ★ 三条"必须让用户看懂"的失败信息（照 STYLE_GUIDE 三段式：现象/原因/怎么办）：
//   ① 没填 Key        → 不是网络问题，是没配置，要说清楚去哪儿填；
//   ② 401/403         → Key 错或没权限，要把厂商返回的原文带出来；
//   ③ 字段/结构对不上 → 厂商改了接口，要把"期望什么、拿到什么"都写出来。
//   只抛一个 Exception('HTTP 401') 的话，用户在 App 里只能看到一串数字。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tts_vendors.dart';

/// 某一家厂商的用户配置。
class TtsConfig {
  final String key;
  final String voice;
  final String model;
  final String format;
  final String region;
  final String host;
  const TtsConfig({
    this.key = '',
    this.voice = '',
    this.model = '',
    this.format = '',
    this.region = '',
    this.host = '',
  });

  /// 这家是否已经配置到"能发一次请求"的程度。
  /// 自托管看 host；需要 Key 的看 key。
  bool readyFor(TtsVendor v) {
    if (v.needHost) return host.trim().isNotEmpty;
    if (v.auth == TtsAuth.none) return true;
    return key.trim().isNotEmpty;
  }
}

/// 这是自检里那句"没填 Key 要说清去哪儿填"的落地文案。
String missingConfigHint(TtsVendor v) {
  if (v.needHost) {
    return '「${v.name}」还没填服务地址。\n'
        '· 先把这套引擎跑在电脑或路由器上（见「开源引擎」页的启动命令）；\n'
        '· 再回到这里填它的地址，形如 192.168.1.5:8880。';
  }
  if (v.auth == TtsAuth.none) return '';
  return '「${v.name}」还没填 API Key。\n'
      '· 到 ${v.docUrl.isEmpty ? '该厂商官网' : v.docUrl} 申请一个 Key；\n'
      '· 粘贴到上面这一栏即可，本机保存、不上传。';
}

/// 全部厂商 = 内置 + 用户自定义。
class TtsOnline {
  static const kCustomKey = 'tts_custom_vendors';

  static String _k(String id, String field) => 'tts_${field}_$id';

  /// 自定义厂商列表（坏数据自动丢弃，不让设置页打不开）。
  static Future<List<TtsVendor>> customVendors() async {
    final p = await SharedPreferences.getInstance();
    return decodeVendorList(p.getString(kCustomKey) ?? '');
  }

  static Future<void> setCustomVendors(List<TtsVendor> vs) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kCustomKey, encodeVendorList(vs));
  }

  /// 内置在前、自定义在后。
  static Future<List<TtsVendor>> allVendors() async =>
      [...kTtsVendors, ...await customVendors()];

  static Future<TtsVendor?> vendorOf(String id) async {
    final v = ttsVendorOf(id);
    if (v != null) return v;
    for (final c in await customVendors()) {
      if (c.id == id) return c;
    }
    return null;
  }

  static Future<TtsConfig> configOf(String id) async {
    final p = await SharedPreferences.getInstance();
    return TtsConfig(
      key: p.getString(_k(id, 'key')) ?? '',
      voice: p.getString(_k(id, 'voice')) ?? '',
      model: p.getString(_k(id, 'model')) ?? '',
      format: p.getString(_k(id, 'format')) ?? '',
      region: p.getString(_k(id, 'region')) ?? '',
      host: p.getString(_k(id, 'host')) ?? '',
    );
  }

  static Future<void> saveConfig(
    String id, {
    String? key,
    String? voice,
    String? model,
    String? format,
    String? region,
    String? host,
  }) async {
    final p = await SharedPreferences.getInstance();
    if (key != null) await p.setString(_k(id, 'key'), key);
    if (voice != null) await p.setString(_k(id, 'voice'), voice);
    if (model != null) await p.setString(_k(id, 'model'), model);
    if (format != null) await p.setString(_k(id, 'format'), format);
    if (region != null) await p.setString(_k(id, 'region'), region);
    if (host != null) await p.setString(_k(id, 'host'), host);
  }

  /// 合成并把音频落成临时文件，返回路径。
  ///
  /// 失败一律抛 [TtsSynthException]，其 `message` 是**给人看的**（不是状态码），
  /// 由调用方直接展示。这样"点了没声音"能变成"Key 被拒绝：…"。
  static Future<String> synthesize(TtsVendor v, String text) async {
    final cfg = await configOf(v.id);
    if (!cfg.readyFor(v)) throw TtsSynthException(missingConfigHint(v));

    final vars = TtsVars(
      text: text,
      key: cfg.key,
      voice: cfg.voice,
      model: cfg.model,
      format: cfg.format,
      region: cfg.region,
      host: cfg.host,
    );

    // 百度这类要两步：先换 access_token。
    var token = '';
    final tokReq = planTokenRequest(v, vars);
    if (tokReq != null) {
      final r = await _send(tokReq, v, label: '换取 access_token');
      token = parseTokenResponse(utf8.decode(r, allowMalformed: true));
      if (token.isEmpty) {
        throw TtsSynthException('「${v.name}」换取 access_token 失败。\n'
            '· Key 栏要按「APIKey|SecretKey」两段填（中间一根竖线）；\n'
            '· 到 ${v.docUrl} 核对这两个值是否对应同一个应用。');
      }
    }

    final req = planTtsRequest(v, vars, token: token);
    final body = await _send(req, v, label: '合成');

    final out = extractTtsAudio(v, req.headers['Content-Type'] ?? '', body);
    Uint8List audio;
    if (out.bytes != null) {
      audio = out.bytes!;
    } else if (out.fetchUrl != null) {
      // 阿里百炼 / Murf 这类：返回的是一个下载地址，还要再取一次。
      final r = await http
          .get(Uri.parse(out.fetchUrl!))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) {
        throw TtsSynthException('「${v.name}」返回的音频地址取不到内容'
            '（HTTP ${r.statusCode}）。\n这多半是该地址已过期，重试即可。');
      }
      audio = r.bodyBytes;
    } else {
      throw TtsSynthException('「${v.name}」${out.error ?? '没有返回音频'}');
    }

    if (audio.isEmpty) {
      throw TtsSynthException('「${v.name}」返回了 0 字节音频。');
    }
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/tts_${v.id}_${DateTime.now().microsecondsSinceEpoch}'
        '.${_extOf(v, req)}');
    await f.writeAsBytes(audio);
    return f.path;
  }

  /// 试听：合成一句短句。返回文件路径，失败抛 [TtsSynthException]。
  static Future<String> preview(TtsVendor v) =>
      synthesize(v, v.id == 'baidu' ? '你好，这是一段试听。' : '你好，我是${v.name}的语音，这是一段试听。');

  static String _extOf(TtsVendor v, TtsRequest req) {
    final want = (req.headers['Content-Type'] ?? '') + v.format;
    if (want.contains('wav')) return 'wav';
    if (want.contains('ogg') || want.contains('opus')) return 'ogg';
    if (want.contains('aac')) return 'aac';
    if (want.contains('flac')) return 'flac';
    if (want.contains('pcm')) return 'pcm';
    return 'mp3';
  }

  /// 发一条请求；非 2xx 时把厂商返回的原文带进错误信息。
  static Future<Uint8List> _send(TtsRequest req, TtsVendor v,
      {required String label}) async {
    final uri = Uri.parse(req.url);
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw TtsSynthException('「${v.name}」的请求地址不完整：${req.url}\n'
          '${v.needHost ? '请检查服务地址是否填成了完整主机:端口。' : '这是内置配置的问题，请反馈。'}');
    }
    http.Response r;
    try {
      final h = req.headers;
      if (req.method == 'GET') {
        r = await http.get(uri, headers: h).timeout(const Duration(seconds: 45));
      } else {
        r = await http
            .post(uri, headers: h, body: req.body)
            .timeout(const Duration(seconds: 45));
      }
    } on SocketException catch (e) {
      throw TtsSynthException('连不上「${v.name}」。\n'
          '· 本机与外网是否通（自托管则确认手机与它同一局域网）；\n'
          '· 自托管引擎是否监听 0.0.0.0 而不是 127.0.0.1。\n'
          '原始错误：${e.message}');
    } catch (e) {
      throw TtsSynthException('请求「${v.name}」失败（$label 阶段）：$e');
    }

    if (r.statusCode == 401 || r.statusCode == 403) {
      throw TtsSynthException('「${v.name}」拒绝了这个 Key（HTTP ${r.statusCode}）。\n'
          '${_brief(r.bodyBytes)}\n'
          '· 核对 Key 是否复制完整、是否与所选区域匹配；\n'
          '· 到 ${v.docUrl} 看该 Key 是否已开通语音合成权限。');
    }
    if (r.statusCode == 429) {
      throw TtsSynthException('「${v.name}」提示请求过于频繁（HTTP 429）。\n'
          '等一下再试；免费额度用尽也会是这个提示。');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw TtsSynthException('「${v.name}」返回 HTTP ${r.statusCode}（$label 阶段）。\n'
          '${_brief(r.bodyBytes)}');
    }
    return r.bodyBytes;
  }

  static String _brief(Uint8List b) {
    final s = utf8.decode(b.take(300).toList(), allowMalformed: true)
        .replaceAll('\n', ' ')
        .trim();
    return s.isEmpty ? '（厂商没有返回说明）' : s;
  }
}

/// 能直接展示给用户看的合成失败。
class TtsSynthException implements Exception {
  final String message;
  const TtsSynthException(this.message);
  @override
  String toString() => message;
}
