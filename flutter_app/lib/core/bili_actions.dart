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

  /// 收藏（4.81.104 修）：以前写死 add_media_ids=1，那个 id 不一定存在，
  /// 收藏经常静默失败。现在先查自己的收藏夹列表，用真实的默认夹 id；
  /// 查不到再退回 1（B站 上多数账号确实有一个 id=1 的默认夹）。
  Future<BiliActionResult> favorite(String bvid, {bool cancel = false}) async {
    if (!_logged) return const BiliActionResult(false, '请先登录 B站');
    final fid = await _defaultFavId();
    return _post('/x/v3/fav/resource/deal', cancel
        ? {'rid': bvid, 'type': '2', 'add_media_ids': '', 'del_media_ids': '$fid'}
        : {'rid': bvid, 'type': '2', 'add_media_ids': '$fid', 'del_media_ids': ''});
  }

  /// 取默认收藏夹 id：接口按创建时间倒序，优先挑名字含「默认」的，否则第一个。
  Future<int> _defaultFavId() async {
    try {
      final mid = BiliAuth.I.mid;
      if (mid.isEmpty) return 1;
      final r = await http
          .get(
            Uri.parse('$_api/x/v3/fav/folder/created/list-all'
                '?up_mid=$mid&jsonp=jsonp'),
            headers: BiliAuth.I.headers(),
          )
          .timeout(const Duration(seconds: 12));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final list = ((j['data'] as Map?)?['list'] as List?) ?? const [];
      final folders = list.whereType<Map>().toList();
      for (final f in folders) {
        final name = '${f['title'] ?? ''}';
        if (name.contains('默认')) {
          return (f['id'] as num?)?.toInt() ?? 1;
        }
      }
      if (folders.isNotEmpty) {
        return (folders.first['id'] as num?)?.toInt() ?? 1;
      }
    } catch (_) {}
    return 1;
  }

  /// 这个视频我赞过/投过币/收藏过没有（登录后才有效）。
  /// 没登录时直接返回空，界面上按钮保持未选中态，点了会提示去登录。
  Future<Map<String, dynamic>> relation(String bvid) async {
    if (!_logged) return const {};
    try {
      final r = await http
          .get(Uri.parse('$_api/x/web-interface/archive/relation?bvid=$bvid'),
              headers: BiliAuth.I.headers())
          .timeout(const Duration(seconds: 12));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j['code'] != 0) return const {};
      return Map<String, dynamic>.from((j['data'] as Map?) ?? const {});
    } catch (_) {
      return const {};
    }
  }

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
