// 前端账号 → 后端授权（4.81.102）
//
// 产品口径：**前端是主体，后端只是可选增强**。
// 用户在 App 里扫码登录 B站之后，连上家庭后端时把登录态委托过去，
// 后端不再弹自己的二维码、不再要求第二次登录，直接复用这份 cookie。
// 没连后端时本文件整个静默跳过 —— 普通版用户完全感知不到后端存在。
//
// 传输：POST {base}/v1/auth/delegate，带已配对的 x-th-token；
// cookie 只发给用户自己配的后端，不上传云端、不进日志。
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'bili_auth.dart' show BiliAuth;

class AuthDelegate {
  AuthDelegate._();

  /// 从本机设置里读后端地址和令牌，把当前 B站登录态同步过去。
  /// 没配后端 / 没登录 B站 / 后端不可达，都静默返回 false。
  static Future<bool> syncFromPrefs() async {
    final p = await SharedPreferences.getInstance();
    final base = (p.getString('base') ?? '').trim();
    final token = (p.getString('token') ?? '').trim();
    if (base.isEmpty || token.isEmpty) return false;
    await BiliAuth.I.load();
    if (!BiliAuth.I.loggedIn) return false;
    return sync(base, token);
  }

  static Future<bool> sync(String base, String token) async {
    try {
      final r = await http.post(
        Uri.parse('$base/v1/auth/delegate'),
        headers: <String, String>{
          'content-type': 'application/json',
          'x-th-token': token,
        },
        body: jsonEncode(<String, dynamic>{
          'bili': <String, dynamic>{
            'cookie': BiliAuth.I.cookie,
            'mid': BiliAuth.I.mid,
            'name': BiliAuth.I.name,
          },
        }),
      ).timeout(const Duration(seconds: 12));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 前端退出 B站登录时同步撤销后端那份，避免留着失效 cookie。
  static Future<bool> revokeFromPrefs() async {
    final p = await SharedPreferences.getInstance();
    final base = (p.getString('base') ?? '').trim();
    final token = (p.getString('token') ?? '').trim();
    if (base.isEmpty || token.isEmpty) return false;
    try {
      final r = await http
          .delete(Uri.parse('$base/v1/auth/delegate'),
              headers: <String, String>{'x-th-token': token})
          .timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
