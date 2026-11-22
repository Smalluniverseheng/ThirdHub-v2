// 桌面引擎客户端：配对、下单/看单、取货、落本地库。
//
// 边界（很重要，别在别处补功能把它搞乱）
// ---------------------------------------
// 这个文件**只做四件事**：说 hello、看清单、要一条下载链接、把文件下回来存好。
// 它**不解析网页、不拼图片地址、不跑任何站点规则** —— 那些行为全部留在桌面端。
// 于是「移动端不含抓取逻辑」不是靠自觉，而是靠这里根本没有相应代码。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../local_import.dart';

/// 桌面引擎交互失败。带 [hint] 是为了让 UI 能直接告诉用户下一步做什么，
/// 而不是把 `SocketException: Connection refused` 甩到脸上。
class HandoffException implements Exception {
  final String message;

  /// 下一步建议（可直接展示）。
  final String hint;

  /// true 表示「网络层面就没通」，UI 可以据此提示检查同一局域网。
  final bool offline;

  const HandoffException(this.message, {this.hint = '', this.offline = false});

  @override
  String toString() => message;
}

class Handoff {
  Handoff._();

  // ── 配对信息 ───────────────────────────────────────────────
  static const String kUrl = 'desk_url';
  static const String kToken = 'desk_token';

  /// 默认端口与容器一致（desktop/docker-compose.yml）。
  static const int defaultPort = 8421;

  static Future<String> url() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(kUrl) ?? '').trim();
  }

  static Future<String> token() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(kToken) ?? '').trim();
  }

  static Future<bool> ready() async =>
      (await url()).isNotEmpty && (await token()).isNotEmpty;

  /// 保存配对信息。地址容忍「只填了 IP」和「带不带斜杠」。
  static Future<void> pair({required String url, required String token}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kUrl, normalizeUrl(url));
    await p.setString(kToken, token.trim());
  }

  static Future<void> unpair() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(kUrl);
    await p.remove(kToken);
  }

  /// 用户输入容错：`192.168.1.10` → `http://192.168.1.10:8421`。
  ///
  /// 为什么容错而不报错：在手机上敲一个完整 URL 很烦，而「IP + 端口」
  /// 是唯一需要用户记的东西。少一次失败配对就少一轮来回。
  static String normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return s;
    if (u.hasPort && u.port != 0) {
      return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
    }
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: defaultPort,
      path: u.path,
    ).toString().replaceAll(RegExp(r'/$'), '');
  }

  // ── HTTP 底层 ──────────────────────────────────────────────
  static final http.Client _c = http.Client();
  static const Duration _t = Duration(seconds: 12);

  static Future<Map<String, dynamic>> _req(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    bool auth = true,
  }) async {
    final base = await url();
    final tk = await token();
    if (base.isEmpty) {
      throw const HandoffException('还没配对桌面引擎',
          hint: '在「我的 → 桌面引擎」里填入地址和令牌');
    }
    final uri = Uri.parse('$base$path');
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json; charset=utf-8',
      if (auth) 'x-th-token': tk,
    };
    try {
      final req = http.Request(method, uri);
      req.headers.addAll(headers);
      if (body != null) req.bodyBytes = utf8.encode(jsonEncode(body));
      final streamed = await _c.send(req).timeout(timeout ?? _t);
      final resp = await http.Response.fromStream(streamed);
      final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 401) {
        throw const HandoffException('令牌不对',
            hint: '打开桌面端的 data/token 重新复制一次');
      }
      if (resp.statusCode >= 400) {
        String msg = 'HTTP ${resp.statusCode}';
        try {
          final j = jsonDecode(text);
          if (j is Map && j['error'] != null) msg = '${j['error']}';
        } catch (_) {
          /* 非 JSON 错误体，保持状态码 */
        }
        throw HandoffException(msg, hint: '桌面端日志里能看到具体是哪一步失败');
      }
      if (text.isEmpty) return <String, dynamic>{};
      final j = jsonDecode(text);
      return j is Map<String, dynamic> ? j : <String, dynamic>{'data': j};
    } on HandoffException {
      rethrow;
    } on TimeoutException {
      throw const HandoffException('连接超时',
          hint: '确认手机和桌面端在同一个局域网，端口 8421 没被防火墙挡',
          offline: true);
    } on SocketException {
      throw const HandoffException('连不上桌面引擎',
          hint: '确认桌面端容器在跑：curl http://<地址>:8421/v1/health',
          offline: true);
    } catch (e) {
      throw HandoffException('$e');
    }
  }

  // ── 对外动作 ───────────────────────────────────────────────
  /// 探活。配对页「测试连接」用它；返回设备名、版本、队列与成品数。
  static Future<Map<String, dynamic>> health({String? urlText, String? tokenText}) async {
    if (urlText != null && tokenText != null) {
      await pair(url: urlText, token: tokenText);
    }
    return _req('GET', '/v1/health', auth: false);
  }

  static Future<List<Map<String, dynamic>>> lib() async {
    final j = await _req('GET', '/v1/lib');
    return ((j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  static Future<List<Map<String, dynamic>>> tasks() async {
    final j = await _req('GET', '/v1/tasks');
    return ((j['tasks'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  /// 下单。参数结构见 desktop/README.md。
  static Future<String> submit(Map<String, dynamic> body) async {
    final j = await _req('POST', '/v1/tasks', body: body);
    return '${j['id'] ?? ''}';
  }

  static Future<void> remove(String id) => _req('DELETE', '/v1/lib/$id');

  /// 取签名下载链接。
  static Future<String> handoffUrl(String id) async {
    final j = await _req('POST', '/v1/handoff/$id', timeout: const Duration(seconds: 20));
    return '${j['url'] ?? ''}';
  }

  /// 成品类型 → 本地库分类。
  ///
  /// 映射成 `novel/comic/music/video` 而不是自定义类目，是为了让收到的东西
  /// 直接出现在已有的书架 / 漫画 / 音乐 / 视频列表里 —— 用户不需要学一个新入口。
  static String localKind(String remoteKind) {
    switch (remoteKind) {
      case 'book':
        return 'novel';
      case 'comic':
        return 'comic';
      case 'audio':
        return 'music';
      case 'video':
        return 'video';
      default:
        return 'novel';
    }
  }

  /// 取货：要链接 → 流式下载 → 交本地库。
  ///
  /// 全程在内存里做流（不先写临时文件再拷），因为成品最大也就几十 MB，
  /// 而多一次拷贝就多一份「磁盘满了」的失败面。
  ///
  /// @return 落盘后的绝对路径
  static Future<String> receive(
    Map<String, dynamic> item, {
    void Function(int got, int total)? onProgress,
  }) async {
    final id = '${item['id'] ?? ''}';
    if (id.isEmpty) throw const HandoffException('成品编号缺失');
    final link = await handoffUrl(id);
    if (link.isEmpty) throw const HandoffException('桌面端没给出下载链接');

    final resp = await _c.send(http.Request('GET', Uri.parse(link)))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode >= 400) {
      throw HandoffException('下载失败（HTTP ${resp.statusCode}）',
          hint: '链接默认 10 分钟过期，回列表重新点一次');
    }
    final total = resp.contentLength ?? (item['bytes'] as int? ?? 0);
    final chunks = <int>[];
    var got = 0;
    await for (final c in resp.stream) {
      chunks.addAll(c);
      got += c.length;
      onProgress?.call(got, total);
    }

    final path = await LocalLib.acceptFile(
      kind: localKind('${item['kind'] ?? ''}'),
      name: '${item['file'] ?? item['title'] ?? 'download'}',
      bytes: chunks,
    );
    if (path == null) {
      final why = LocalLib.lastErrors.isEmpty ? '未知原因' : LocalLib.lastErrors.last;
      throw HandoffException('存到本地失败：$why');
    }
    return path;
  }

  /// 人类可读的体积。
  static String sizeText(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
