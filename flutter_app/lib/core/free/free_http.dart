// 开放内容源的 HTTP 层。
//
// ★ 为什么单独一层，不复用 main.dart 的 `Api`：
//   `Api` 的语义是「跟自己的后端说话」——它读 `Api.base` / `Api.token`，
//   没配后端就抛「请到「我的 → 连接资源库」」。而本文件服务的恰恰是
//   **后端不在场**的场景（脱网 / NAS 关机 / 首次安装没连过）。
//   两者混用会让「后端没配」变成「开放源也用不了」，等于把要解决的问题写回来。
//
// ★ 安全口径（与「正规源」这个定位直接相关）：
//   这里访问的全部是公网正规站点的 HTTPS，用的是公信 CA 证书，
//   因此 **不做任何证书放行**。本项目另有 21 处
//   `badCertificateCallback = (_, __, ___) => true` 的历史遗留（见记忆里的 P0），
//   本文件绝不跟进 —— 那套放宽只是为了自签的后端。
//
// ★ 目标域之外一律不放行：
//   Player 拿到的地址、图片地址都来自这些源，不再二次拼接用户输入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一个「源不可用」的错误。跟网络错误区分开，UI 才能说人话：
/// 「这站连不上」 vs 「这站拒绝了」 vs 「这站没这东西」。
class FreeNetException implements Exception {
  /// 直接可展示的中文原因（不要塞英文栈给用户看）。
  final String message;

  /// true = 网络层面到不了（可能换网就好）；false = 源侧明确拒绝/格式不对。
  final bool offline;

  /// 该源本次失败是否应被判定为「整体不可达」（UI 会把它标灰）。
  final bool sourceDead;

  const FreeNetException(this.message,
      {this.offline = false, this.sourceDead = false});

  @override
  String toString() => message;
}

/// 取得一次响应的最小封装。只用 Dart SDK，不引任何三方包
/// （本项目历史上多次因为 pubspec 漏项/版本漂移把 CI 搞红，能不加就不加）。
class FreeHttp {
  FreeHttp._();

  /// 部分源（MangaDex 明确写了）不接受浏览器 UA，要求非浏览器 UA 带联系方式。
  /// 统一用一个诚实、可追溯的 UA，比伪装成 Chrome 更不容易被风控。
  static const String userAgent =
      'ThirdHub/4.81.77 (Android; +https://github.com/Smalluniverseheng/ThirdHub-v2)';

  /// 全局唯一连接池：**复用**而不是每请求 new。
  /// main.dart 的老 `Api.client()` 每请求 new 且从不 close，自签 TLS 每次重握手
  /// 200~600ms；这里从一开始就走复用的路子。
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 9)
    ..idleTimeout = const Duration(seconds: 20)
    ..userAgent = userAgent
    ..autoUncompress = true;

  static Map<String, String> _headers(Map<String, String>? extra) {
    final h = <String, String>{
      'User-Agent': userAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
    if (extra != null) h.addAll(extra);
    return h;
  }

  /// 发一次请求并读完全部字节。
  ///
  /// [timeout] 是**整轮**（连接 + 收完）的上限。超过就抛 [FreeNetException]：
  /// 宁可报「超时」也不要让界面永远转圈 —— 这是本项目 28 处无 timeout
  /// 网络调用的教训。
  static Future<List<int>> bytes(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 8 * 1024 * 1024,
    int redirects = 4,
  }) =>
      send(url,
          headers: headers,
          timeout: timeout,
          maxBytes: maxBytes,
          redirects: redirects);

  /// 通用请求：支持 GET / POST（用户导入的源里 POST 接口不少）。
  ///
  /// [body] 仅对非 GET 生效。**不做表单编码猜测** —— 源包里写什么就发什么，
  /// Content-Type 由源包自己在 headers 里声明（缺省按 JSON）。
  static Future<List<int>> send(
    String url, {
    String method = 'GET',
    String? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 8 * 1024 * 1024,
    int redirects = 4,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw FreeNetException('地址不成立：$url');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw FreeNetException('不支持的协议：${uri.scheme}');
    }
    final m = method.toUpperCase();

    Future<List<int>> once() async {
      final req = await _client.openUrl(m, uri);
      _headers(headers).forEach(req.headers.set);
      if (body != null && m != 'GET' && m != 'HEAD') {
        if (req.headers.value('content-type') == null) {
          req.headers.set('Content-Type', 'application/json; charset=utf-8');
        }
        final b = utf8.encode(body);
        req.contentLength = b.length;
        req.add(b);
      }
      final resp = await req.close();
      final code = resp.statusCode;

      // 3xx：源站偶尔不给 Location 的绝对地址，这里自己跟随，
      // 并且**只允许 http/https**（防 file:// 之类被塞进来）。
      if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
        final loc = resp.headers.value('location');
        await resp.drain<void>();
        if (loc == null || loc.isEmpty) {
          throw FreeNetException('跳转缺少目标地址（HTTP $code）', sourceDead: true);
        }
        if (redirects <= 0) {
          throw FreeNetException('跳转次数过多', sourceDead: true);
        }
        final next = uri.resolve(loc);
        // 303 一律降级为 GET；其余保持原方法（307/308 语义要求保方法）。
        return send(next.toString(),
            method: code == 303 ? 'GET' : m,
            body: code == 303 ? null : body,
            headers: headers,
            timeout: timeout,
            maxBytes: maxBytes,
            redirects: redirects - 1);
      }

      if (code >= 400) {
        // 读一点点错误体便于定位，但绝不把它抛给用户（那是英文 HTML）。
        final seg = <int>[];
        await for (final chunk in resp) {
          seg.addAll(chunk);
          if (seg.length > 2048) break;
        }
        throw FreeNetException('源站返回 HTTP $code',
            sourceDead: code >= 500 || code == 403 || code == 429);
      }

      final out = <int>[];
      await for (final chunk in resp) {
        out.addAll(chunk);
        if (out.length > maxBytes) break;
      }
      return out;
    }

    try {
      return await once().timeout(timeout);
    } on FreeNetException {
      rethrow;
    } on TimeoutException {
      throw FreeNetException('连接超时（${timeout.inSeconds}s）', offline: true);
    } on SocketException catch (e) {
      // 断网 / DNS 失败 / 对方拒连，全归到这里。
      throw FreeNetException('网络不可达（${_brief(e.message)}）',
          offline: true, sourceDead: true);
    } on HandshakeException {
      throw FreeNetException('HTTPS 证书校验未通过', sourceDead: true);
    } on HttpException catch (e) {
      throw FreeNetException('传输中断（${_brief(e.message)}）', offline: true);
    }
  }

  static String _brief(String s) {
    final t = s.replaceAll('\n', ' ').trim();
    return t.length > 40 ? '${t.substring(0, 40)}…' : t;
  }

  /// 取文本（按 UTF-8 解，失败退 latin1 —— 少数老站不声明编码）。
  static Future<String> text(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final b = await bytes(url,
        headers: headers, timeout: timeout, maxBytes: maxBytes);
    try {
      return utf8.decode(b, allowMalformed: true);
    } catch (_) {
      return latin1.decode(b, allowInvalid: true);
    }
  }

  /// 取 JSON。允许顶层是 Map 或 List —— 各源不统一，这里不强迫调用方分支。
  static Future<dynamic> jsonAny(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    Map<String, String>? query,
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    var u = url;
    if (query != null && query.isNotEmpty) {
      final sep = u.contains('?') ? '&' : '?';
      final qs = query.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      u = '$u$sep$qs';
    }
    final t = await text(u,
        headers: {...?headers, 'Accept': 'application/json'},
        timeout: timeout,
        maxBytes: maxBytes);
    if (t.trim().isEmpty) {
      throw FreeNetException('源站返回空响应');
    }
    try {
      return jsonDecode(t);
    } on FormatException {
      // 有些站点被拦截时会返回 HTML 登录页/风控页 —— 明确指出，别让上层猜。
      final head = t.trimLeft();
      if (head.startsWith('<')) {
        throw FreeNetException('源站返回了网页而不是 JSON（可能被风控拦截）');
      }
      throw FreeNetException('源站响应不是合法 JSON');
    }
  }

  static Future<Map<String, dynamic>> json(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    Map<String, String>? query,
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final d = await jsonAny(url,
        headers: headers,
        timeout: timeout,
        query: query,
        maxBytes: maxBytes);
    if (d is Map<String, dynamic>) return d;
    if (d is Map) return Map<String, dynamic>.from(d);
    throw FreeNetException('源站响应结构不符（期望对象）');
  }

  /// 只探活：拿 1 字节也算活。UI 用它决定「这个源现在能不能用」。
  static Future<bool> ping(String url, {Duration timeout = const Duration(seconds: 8)}) async {
    try {
      await bytes(url, timeout: timeout, maxBytes: 2048);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 一个小工具：从 HTML 里剥出纯文本。
///
/// 只用于 Wikisource / 古登堡这类**由我们指定页面**的正文提取，
/// 不做通用 HTML 解析（不做，也就不需要引 html 包引入新的解析面）。
String stripHtml(String html) {
  var s = html;
  // 先干掉整段脚本与样式（它们的文本不是正文）。
  s = s.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
  // 块级标签换行，避免整篇粘成一行。
  s = s.replaceAll(
      RegExp(r'</(p|div|br|h1|h2|h3|h4|h5|h6|li|tr|blockquote)>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  // 其余标签直接去掉。
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  // 实体（只处理最常见的几个，多了反而是隐患）。
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&mdash;', '—')
      .replaceAll('&ldquo;', '“')
      .replaceAll('&rdquo;', '”');
  // 压掉多余空白，但保留段落空行。
  s = s.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}
