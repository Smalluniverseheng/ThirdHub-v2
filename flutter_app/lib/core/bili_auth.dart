// B站端上登录（4.81.94）——纯客户端扫码，不依赖后端。
//
// 为什么必须做：实测无 cookie 时 B站 playurl 只给 480p DASH（音视频分离）或
// 720p MP4 单流；1080p 需要 SESSDATA。用户要求"授权账号才能播高清"，
// 端上扫码登录正好满足：App 自己生成二维码→轮询→拿 cookie→存本地→所有 B站
// 请求（含 playurl）统一带上。
//
// 接口（passport.bilibili.com，纯公开 Web 接口）：
//   GET /x/passport-login/web/qrcode/generate          → {url, qrcode_key}
//   GET /x/passport-login/web/qrcode/poll?qrcode_key=  → {code, message, url}
//        code=86101 未扫码 / 86090 已确认未授权 / 86038 已过期 / 0 成功(url 含 cookie)
//
// 安全：cookie 只存本机 SharedPreferences，不上传、不进日志、不进仓库。
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'bili_direct.dart' show biliUA, biliReferer;

const String _kCookieKey = 'bili_auth_cookie';
const String _kNameKey = 'bili_auth_name';
const String _kMidKey = 'bili_auth_mid';
const String _kGen =
    'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';
const String _kPoll =
    'https://passport.bilibili.com/x/passport-login/web/qrcode/poll';

/// 扫码结果
class BiliQr {
  final String url;
  final String key;
  const BiliQr({required this.url, required this.key});
}

/// 轮询状态
class BiliPoll {
  /// waiting / expired / confirmed / ok / error
  final String state;
  final String message;
  const BiliPoll(this.state, this.message);
}

class BiliAuth {
  BiliAuth._();
  static final BiliAuth I = BiliAuth._();

  String _cookie = '';
  String _name = '';
  String _mid = '';

  String get cookie => _cookie;
  String get name => _name;
  /// 已登录用户的 mid。收藏夹/个人主页直接用它，不再依赖 nav 接口
  /// （nav 被风控时返回空，会把已登录用户误判成未登录）。
  String get mid => _mid;
  bool get loggedIn => _cookie.contains('SESSDATA=');

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _cookie = p.getString(_kCookieKey) ?? '';
    _name = p.getString(_kNameKey) ?? '';
    _mid = p.getString(_kMidKey) ?? '';
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCookieKey, _cookie);
    await p.setString(_kNameKey, _name);
    await p.setString(_kMidKey, _mid);
  }

  Future<void> logout() async {
    _cookie = '';
    _name = '';
    _mid = '';
    await _save();
  }

  /// 生成二维码（返回扫码链接与 key）
  Future<BiliQr?> generate() async {
    try {
      final r = await http.get(Uri.parse(_kGen), headers: _headers()).timeout(
            const Duration(seconds: 15),
          );
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map || j['code'] != 0) return null;
      final d = (j['data'] as Map?) ?? const {};
      final key = '${d['qrcode_key'] ?? ''}';
      final url = '${d['url'] ?? ''}';
      if (key.isEmpty || url.isEmpty) return null;
      return BiliQr(url: url, key: key);
    } catch (_) {
      return null;
    }
  }

  /// 轮询扫码状态；成功时自动存 cookie 并拉取用户名
  Future<BiliPoll> poll(String key) async {
    try {
      final r = await http
          .get(Uri.parse('$_kPoll?qrcode_key=${Uri.encodeQueryComponent(key)}'),
              headers: _headers())
          .timeout(const Duration(seconds: 15));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map) return const BiliPoll('error', 'bad response');
      final d = (j['data'] as Map?) ?? const {};
      final code = d['code'];
      final msg = '${d['message'] ?? ''}';
      // 成功：code=0，url 是带 cookie 的重定向地址（Set-Cookie 也在响应头里）
      if (code == 0) {
        final setCookie = r.headers['set-cookie'] ?? '';
        final cb = _parseCookie('${d['url'] ?? ''}', setCookie);
        if (cb.isEmpty) return const BiliPoll('error', 'no cookie');
        _cookie = cb;
        await _save();
        await _fetchProfile();
        return const BiliPoll('ok', '');
      }
      if (code == 86038) return BiliPoll('expired', msg);
      if (code == 86090) return BiliPoll('confirmed', msg);
      return BiliPoll('waiting', msg);
    } catch (e) {
      return BiliPoll('error', '$e');
    }
  }

  /// 从回调 URL query 和 Set-Cookie 头拼出完整 cookie
  String _parseCookie(String cbUrl, String setCookie) {
    final parts = <String, String>{};
    try {
      final u = Uri.parse(cbUrl);
      u.queryParameters.forEach((k, v) {
        if (k == 'SESSDATA' ||
            k == 'bili_jct' ||
            k == 'DedeUserID' ||
            k == 'DedeUserID__ckMd5' ||
            k == 'sid') parts[k] = v;
      });
    } catch (_) {}
    // Set-Cookie 兜底（poll 的 302 响应头里带 SESSDATA）
    for (final m in RegExp(r'(SESSDATA|bili_jct|DedeUserID|sid)=([^;,]+)')
        .allMatches(setCookie)) {
      parts[m.group(1)!] = m.group(2)!;
    }
    if (!parts.containsKey('SESSDATA')) return '';
    final buf = StringBuffer();
    parts.forEach((k, v) {
      if (buf.isNotEmpty) buf.write('; ');
      buf.write('$k=$v');
    });
    return buf.toString();
  }

  Future<void> _fetchProfile() async {
    try {
      final r = await http.get(
        Uri.parse('https://api.bilibili.com/x/web-interface/nav'),
        headers: headers(),
      ).timeout(const Duration(seconds: 12));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final d = (j['data'] as Map?) ?? const {};
      if (j['code'] == 0 && d['isLogin'] == true) {
        _name = '${d['uname'] ?? ''}';
        _mid = '${d['mid'] ?? ''}';
        await _save();
      }
    } catch (_) {}
  }

  Map<String, String> _headers() => {
        'user-agent': biliUA,
        'referer': biliReferer,
        'accept': 'application/json,text/plain,*/*',
      };

  /// 所有 B站请求统一带 cookie（未登录时即原有 header）
  Map<String, String> headers({Map<String, String>? extra}) => <String, String>{
        'user-agent': biliUA,
        'referer': biliReferer,
        'accept': 'application/json,text/plain,*/*',
        'accept-language': 'zh-CN,zh;q=0.9',
        if (_cookie.isNotEmpty) 'cookie': _cookie,
        ...?extra,
      };
}
