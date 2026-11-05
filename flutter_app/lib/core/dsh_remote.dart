// ═══════════════════════════════════════════════════════════════════════════
// DSH 遥控 —— 电脑端 `dsh-remote-plugin` 网关（默认 8787）的客户端契约层
//
// 为什么单独一个文件：这一层是**规则**（地址怎么归一、粘贴串怎么拆、令牌怎么用、
// 探测怎么判），UI 只是把结果显示出来。规则层零 Flutter 依赖，可被
// `tool/dsh_remote_selfcheck.dart` 在纯 Dart VM 里逐条断言 —— 与
// `sync_contract.dart` / `api_keys.dart` / `calc_engine.dart` 同一套做法。
//
// ── 协议事实（2026-11-06 用本机真实网关核对，不是猜的）──────────────────
//   · `GET /health`                     → 200 JSON，无鉴权。含 service/status/version。
//                                         这是「地址填对没有」的唯一判据。
//   · `GET /api/ws-ticket` + Bearer     → 200 令牌有效 / 401 令牌无效。
//                                         这是「令牌填对没有」的判据（只发一个短票，
//                                         不改任何状态，比 /admin 安全）。
//   · `GET /?token=<令牌>`              → 手机控制台（会话 / 文件 / 更多）
//   · `GET /admin?token=<主令牌>`       → 电脑端管理页（网关设置 / 设备密钥）
//   · 令牌来源：电脑上 `~/.dsh-remote/token`（初次由插件生成），
//     或在管理页给每台手机单独发「设备密钥」—— 管理页只认主令牌。
//
//   ⚠️ 不要用 `/api/lan-pair`：那是 UDP 发现 + P-256 ECDH + AES-GCM 的扫码配对，
//      纯 Dart 手写一遍要引 crypto 曲线实现，收益为零（扫码入口在 DSH 自己的 App 里）。
//      本模块走「抄地址 + 抄令牌」这条确定能走通的路。
//
// ── 设计约束 ─────────────────────────────────────────────────────────────
//   · 任何失败都返回结果对象，**不抛异常**（同 `agent_dsh_client.dart`）：
//     填错地址不该让整页崩掉。
//   · 错误只给**码**（DshErr.*），中文在 UI 侧 tr() 取 —— 规则层不写文案，
//     这样 i18n 闸门只需看 UI 文件，规则层也不会因为翻译改动而变红。
//   · 令牌只写本机（AiStore → SharedPreferences），不上云、不进日志。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'kv.dart';

/// 探测 / 校验失败的原因码。UI 侧按码取 tr()，规则层不写中文。
class DshErr {
  static const String addrEmpty = 'ADDR_EMPTY';
  static const String addrBad = 'ADDR_BAD';
  static const String tokenEmpty = 'TOKEN_EMPTY';
  static const String unreachable = 'UNREACHABLE';
  static const String notGateway = 'NOT_GATEWAY';
  static const String badToken = 'BAD_TOKEN';
  static const String timeout = 'TIMEOUT';
  static const String unknown = 'UNKNOWN';

  /// 码 → 人话（中文原文即 i18n 的 key，UI 侧再走 tr()）。
  static String text(String code) {
    switch (code) {
      case addrEmpty:
        return '请先填电脑地址';
      case addrBad:
        return '地址格式不对，例：http://192.168.1.5:8787';
      case tokenEmpty:
        return '请填配对令牌';
      case unreachable:
        return '连不上电脑：确认同一 Wi-Fi、电脑端 DSH 开着、地址端口对';
      case notGateway:
        return '这个地址通了，但不是 DSH 遥控网关（端口可能填错）';
      case badToken:
        return '令牌不对，或已在电脑上被重置';
      case timeout:
        return '等太久没回应，检查电脑是否睡眠 / 防火墙';
      default:
        return '没成功，原因不明';
    }
  }
}

/// 一次探测的结果。
class DshProbe {
  const DshProbe({
    required this.reachable,
    required this.tokenOk,
    this.status = '',
    this.version = '',
    this.error = '',
  });

  /// `/health` 通了 —— 地址与端口没问题。
  final bool reachable;

  /// `/api/ws-ticket` 返回 200 —— 令牌没问题。
  final bool tokenOk;

  /// 网关自报状态：ready / degraded / offline。
  final String status;

  /// 网关版本，如 0.8.3。
  final String version;

  /// 失败码（DshErr.*）；全成功时为空串。
  final String error;

  bool get ok => reachable && tokenOk;

  static const DshProbe blank =
      DshProbe(reachable: false, tokenOk: false, error: DshErr.addrEmpty);

  @override
  String toString() =>
      'DshProbe(reachable: $reachable, tokenOk: $tokenOk, status: $status, '
      'version: $version, error: $error)';
}

class DshRemote {
  /// 插件默认端口（`DSH_REMOTE_GATEWAY_PORT` 可改，用户改了就在地址里写清楚）。
  static const int defaultPort = 8787;

  /// 本机保存的地址与令牌（App 启动时 load() 一次）。
  static String base = '';
  static String token = '';

  static const String _kBase = 'dsh_remote_base';
  static const String _kToken = 'dsh_remote_token';

  static bool get configured => base.isNotEmpty;

  // ── 地址归一化 ────────────────────────────────────────────────────────
  //
  // 用户会怎么填（都实测过）：
  //   `192.168.1.5`            → http://192.168.1.5:8787
  //   `192.168.1.5:8787`       → http://192.168.1.5:8787
  //   `http://192.168.1.5:8787/?token=abc` → http://192.168.1.5:8787
  //   `  http://192.168.1.5:8787/  ` → http://192.168.1.5:8787   （空格 / 尾斜杠）
  //   `[fe80::1]:8787`         → http://[fe80::1]:8787          （IPv6 要加方括号）
  //
  // 只保留 scheme://host:port，路径与查询串一律丢掉 —— 控制台是网关根路径，
  // 留着 `/?token=` 会让 URL 里出现两个 token。
  static String normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    // 去掉所有空白（含全角空格），粘贴时常带换行
    s = s.replaceAll(RegExp(r'[\s\u3000]+'), '');
    if (s.isEmpty) return '';
    if (!s.contains('://')) s = 'http://$s';
    // 先砍掉片段与查询，避免 Uri 把它们当路径带走
    final hash = s.indexOf('#');
    if (hash >= 0) s = s.substring(0, hash);
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    Uri u;
    try {
      u = Uri.parse(s);
    } catch (_) {
      return '';
    }
    if (u.host.isEmpty) return '';
    final scheme = u.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return '';
    final port = u.hasPort ? u.port : defaultPort;
    final host = u.host.contains(':') ? '[${u.host}]' : u.host;
    return '$scheme://$host:$port';
  }

  /// 粘贴一整条连接串（DSH 页面上给的那条）时，把地址与令牌拆开。
  ///
  /// 这是给「不懂技术的人」准备的：她只需要复制一次、点一次「贴上」，
  /// 不用自己去分辨哪段是地址、哪段是令牌。
  static ({String base, String token}) parsePasted(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return (base: '', token: '');
    var tok = '';
    final m = RegExp(r'[?&]token=([^&\s#]+)').firstMatch(s);
    if (m != null) {
      try {
        tok = Uri.decodeComponent(m.group(1)!);
      } catch (_) {
        tok = m.group(1)!;
      }
      s = (s.substring(0, m.start) + s.substring(m.end)).trim();
    }
    final hash = s.indexOf('#');
    if (hash >= 0) s = s.substring(0, hash);
    s = s.replaceAll(RegExp(r'[?&\s]+$'), '').trim();
    if (s.isEmpty) return (base: '', token: tok);
    // 只粘了令牌：令牌是 base64url（无点无冒号无斜杠，长度 ≥ 16）
    final looksBareToken = tok.isEmpty &&
        !s.contains('.') &&
        !s.contains(':') &&
        !s.contains('/') &&
        s.length >= 16;
    if (looksBareToken) return (base: '', token: s);
    return (base: normalizeBase(s), token: tok);
  }

  // ── 两个入口地址 ─────────────────────────────────────────────────────
  static String consoleUrl({String? at, String? tok}) {
    final b = normalizeBase(at ?? base);
    if (b.isEmpty) return '';
    final t = (tok ?? token).trim();
    return t.isEmpty ? '$b/' : '$b/?token=${Uri.encodeQueryComponent(t)}';
  }

  static String adminUrl({String? at, String? tok}) {
    final b = normalizeBase(at ?? base);
    if (b.isEmpty) return '';
    final t = (tok ?? token).trim();
    return t.isEmpty ? '$b/admin' : '$b/admin?token=${Uri.encodeQueryComponent(t)}';
  }

  /// 界面上显示令牌时只露尾巴 —— 截图 / 录屏不会把令牌带出去。
  static String maskToken(String t) {
    final s = t.trim();
    if (s.isEmpty) return '';
    if (s.length <= 6) return '****';
    return '****${s.substring(s.length - 4)}';
  }

  // ── 本机保存 ─────────────────────────────────────────────────────────
  static Future<void> load() async {
    try {
      base = normalizeBase(await aiStore.getString(_kBase) ?? '');
      token = (await aiStore.getString(_kToken) ?? '').trim();
    } catch (_) {
      base = '';
      token = '';
    }
  }

  static Future<void> save({String? at, String? tok}) async {
    if (at != null) base = normalizeBase(at);
    if (tok != null) token = tok.trim();
    try {
      await aiStore.setString(_kBase, base);
      await aiStore.setString(_kToken, token);
    } catch (_) {
      // 存不下不影响本次会话可用（内存里已经是新值）
    }
  }

  static Future<void> clear() async {
    base = '';
    token = '';
    try {
      await aiStore.remove(_kBase);
      await aiStore.remove(_kToken);
    } catch (_) {}
  }

  // ── 探测 ────────────────────────────────────────────────────────────
  static HttpClient _newClient(int timeoutMs) {
    final c = HttpClient();
    c.connectionTimeout = Duration(milliseconds: timeoutMs);
    // 局域网自签 HTTPS（用户自己反代时）也放行 —— 与 tts_presets 同款做法
    c.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    return c;
  }

  static Future<DshProbe> probe({
    String? at,
    String? tok,
    int timeoutMs = 6000,
  }) async {
    final b = normalizeBase(at ?? base);
    final t = (tok ?? token).trim();
    if (b.isEmpty) return DshProbe.blank;
    if (Uri.tryParse(b) == null) {
      return const DshProbe(reachable: false, tokenOk: false, error: DshErr.addrBad);
    }
    final c = _newClient(timeoutMs);
    try {
      final health = await _getJson(c, '$b/health', timeoutMs);
      if (health == null) {
        return const DshProbe(
            reachable: false, tokenOk: false, error: DshErr.unreachable);
      }
      final status = _str(health['status']);
      final version = _str(health['version']);
      // 通了一个 HTTP 服务，但不是这个插件 —— 端口填错是最常见原因
      if (_str(health['service']) != 'dsh-remote') {
        return DshProbe(
            reachable: true,
            tokenOk: false,
            status: status,
            version: version,
            error: DshErr.notGateway);
      }
      if (t.isEmpty) {
        return DshProbe(
            reachable: true,
            tokenOk: false,
            status: status,
            version: version,
            error: DshErr.tokenEmpty);
      }
      final code = await _getStatus(c, '$b/api/ws-ticket', t, timeoutMs);
      if (code == 200) {
        return DshProbe(
            reachable: true, tokenOk: true, status: status, version: version);
      }
      if (code == 401 || code == 403) {
        return DshProbe(
            reachable: true,
            tokenOk: false,
            status: status,
            version: version,
            error: DshErr.badToken);
      }
      return DshProbe(
          reachable: true,
          tokenOk: false,
          status: status,
          version: version,
          error: code == 0 ? DshErr.timeout : DshErr.unknown);
    } on TimeoutException {
      return const DshProbe(
          reachable: false, tokenOk: false, error: DshErr.timeout);
    } on SocketException {
      return const DshProbe(
          reachable: false, tokenOk: false, error: DshErr.unreachable);
    } catch (_) {
      return const DshProbe(
          reachable: false, tokenOk: false, error: DshErr.unknown);
    } finally {
      c.close(force: true);
    }
  }

  static String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

  static Future<Map<String, dynamic>?> _getJson(
      HttpClient c, String url, int timeoutMs) async {
    try {
      final req = await c
          .getUrl(Uri.parse(url))
          .timeout(Duration(milliseconds: timeoutMs));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(Duration(milliseconds: timeoutMs));
      final body =
          await resp.transform(utf8.decoder).join().timeout(Duration(milliseconds: timeoutMs));
      if (resp.statusCode != 200) return null;
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 只看状态码，不读 body（令牌校验只需要 200/401 这一个信息）。
  /// 返回 0 表示没拿到响应（超时 / 断连）。
  static Future<int> _getStatus(
      HttpClient c, String url, String tok, int timeoutMs) async {
    try {
      final req = await c
          .getUrl(Uri.parse(url))
          .timeout(Duration(milliseconds: timeoutMs));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $tok');
      final resp = await req.close().timeout(Duration(milliseconds: timeoutMs));
      // 必须把 body 读完再关，否则连接不会复用（keep-alive 池会攒僵尸连接）
      await resp.drain<void>().timeout(Duration(milliseconds: timeoutMs));
      return resp.statusCode;
    } catch (_) {
      return 0;
    }
  }
}
