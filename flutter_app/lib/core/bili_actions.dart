// B站互动操作（4.81.94）——点赞/投币/收藏/三连/分享/评论/稍后再看。
//
// 全部走 B站 Web 接口，需要端上扫码登录的 cookie（BiliAuth）。
// 接口用 form-urlencoded + csrf（从 cookie 里的 bili_jct 提取），
// 实测未登录返回 code=-101，登录后即可用。
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'bili_auth.dart' show BiliAuth;

const String _api = 'https://api.bilibili.com';

/// 从 cookie 串里取 bili_jct（csrf token）
String _csrf(String cookie) {
  final m = RegExp(r'(?:^|;\s*)bili_jct=([^;]+)').firstMatch(cookie);
  return m?.group(1) ?? '';
}

class BiliActionResult {
  final bool ok;
  final String message;
  const BiliActionResult(this.ok, this.message);
}

class BiliActions {
  BiliActions._();
  static final BiliActions I = BiliActions._();

  bool get _logged => BiliAuth.I.loggedIn;

  Future<BiliActionResult> _post(String path, Map<String, String> body) async {
    if (!_logged) {
      return BiliActionResult(false, '请先登录 B站');
    }
    final cookie = BiliAuth.I.cookie;
    final csrf = _csrf(cookie);
    if (csrf.isEmpty) {
      return BiliActionResult(false, '登录态不完整，请重新登录');
    }
    try {
      final r = await http.post(
        Uri.parse('$_api$path'),
        headers: BiliAuth.I.headers(extra: {
          'content-type': 'application/x-www-form-urlencoded',
          'origin': 'https://www.bilibili.com',
        }),
        body: {...body, 'csrf': csrf},
      ).timeout(const Duration(seconds: 15));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final code = j['code'];
      final msg = '${j['message'] ?? ''}';
      return BiliActionResult(code == 0, code == 0 ? '' : (msg.isEmpty ? '操作失败($code)' : msg));
    } catch (e) {
      return BiliActionResult(false, '$e');
    }
  }

  /// 点赞 / 取消（like=1 赞，2 取消）
  Future<BiliActionResult> like(String bvid, {bool cancel = false}) => _post(
        '/x/web-interface/archive/like',
        {'bvid': bvid, 'like': cancel ? '2' : '1'},
      );

  /// 投币（multiply=1 或 2）
  Future<BiliActionResult> coin(String bvid, {int multiply = 1}) => _post(
        '/x/web-interface/coin/add',
        {'bvid': bvid, 'multiply': '$multiply'},
      );

  /// 收藏到默认收藏夹（fid 需要查，先用 1=稍后再看之外默认夹；简化为收藏接口）
  Future<BiliActionResult> favorite(String bvid) => _post(
        '/x/v3/fav/resource/deal',
        {'rid': bvid, 'type': '2', 'add_media_ids': '1', 'del_media_ids': ''},
      );

  /// 一键三连（点赞 + 投币 + 收藏）
  Future<BiliActionResult> triple(String bvid) async {
    final a = await like(bvid);
    if (!a.ok) return a;
    final b = await coin(bvid);
    if (!b.ok) return b;
    final c = await favorite(bvid);
    return c;
  }

  /// 发表评论（oid=aid 或 cid，type=1 视频）
  Future<BiliActionResult> comment(String oid, String text) => _post(
        '/x/v2/reply/add',
        {'oid': oid, 'type': '1', 'message': text, 'plat': '1'},
      );

  /// 评论点赞（opp=1 赞 / 2 取消）
  Future<BiliActionResult> likeReply(String oid, String rpid, {bool cancel = false}) => _post(
        '/x/v2/reply/action',
        {'oid': oid, 'rpid': rpid, 'type': '1', 'action': cancel ? '2' : '1'},
      );

  // ── 稍后再看（本机 prefs，不需要 B站 账号）──
  static const _kWatchLater = 'bili_watch_later';

  Future<List<String>> watchLater() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_kWatchLater) ?? const [];
  }

  Future<void> addWatchLater(String bvid) async {
    final p = await SharedPreferences.getInstance();
    final list = await watchLater();
    if (!list.contains(bvid)) {
      await p.setStringList(_kWatchLater, [bvid, ...list]);
    }
  }

  Future<void> removeWatchLater(String bvid) async {
    final p = await SharedPreferences.getInstance();
    final list = await watchLater();
    await p.setStringList(_kWatchLater, list.where((e) => e != bvid).toList());
  }

  Future<bool> isWatchLater(String bvid) async =>
      (await watchLater()).contains(bvid);
}
