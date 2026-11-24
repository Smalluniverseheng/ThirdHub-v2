// B站 Web 接口底座（4.81.97）
//
// 为什么有这个文件：4.81.96 之前 B站板块"看着有界面、点进去啥都没有"，
// 根因不是 UI，是**接口层**——
//   1) 搜索/推荐/空间/收藏等接口 2023 起全部要 WBI 签名（w_rid+wts），
//      不带签名直接 -352/-412（风控），端上表现为空白列表；
//   2) 弹幕 /x/v1/dm/list.so 返回的是 **raw deflate 压缩二进制**，
//      之前直接 utf8 解码 → 乱码 → 正则匹配 0 条 → 弹幕层永远空的；
//   3) 匿名请求缺 buvid3/buvid4，风控命中率更高。
//
// 本文件做三件事：WBI 签名、buvid 注入、弹幕解压。其它业务接口都建在它上面。
import 'dart:convert';
import 'dart:io' show ZLibDecoder;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'bili_auth.dart' show BiliAuth;

/// WBI 混淆表（B站前端固定常量，公开算法）
const List<int> _mixinTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
  36, 20, 34, 44, 52,
];

/// WBI 参数编码（★必须剔除 !'()* 这 6 个字符，否则 w_rid 校验不过）
String _enc(Object? v) =>
    Uri.encodeComponent('${v ?? ''}').replaceAll(RegExp(r"[!'()*]"), '');

class BiliWbi {
  BiliWbi._();
  static final BiliWbi I = BiliWbi._();

  String _mixinKey = '';
  int _mixAt = 0;
  String _buvid = '';

  static const String _api = 'https://api.bilibili.com';

  /// 匿名指纹（buvid3/buvid4），一次会话内复用
  Future<void> ensureBuvid() async {
    if (_buvid.isNotEmpty) return;
    try {
      final r = await http
          .get(Uri.parse('$_api/x/frontend/finger/spi'), headers: _hdr())
          .timeout(const Duration(seconds: 12));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final d = (j is Map) ? ((j['data'] as Map?) ?? const {}) : const {};
      final b3 = '${d['b_3'] ?? ''}';
      final b4 = '${d['b_4'] ?? ''}';
      if (b3.isNotEmpty) {
        _buvid = 'buvid3=$b3${b4.isNotEmpty ? '; buvid4=$b4' : ''}';
      }
    } catch (_) {}
  }

  Map<String, String> _hdr() => BiliAuth.I.headers(
        extra: {if (_buvid.isNotEmpty) 'cookie': _mergeCookie(_buvid)},
      );

  /// 登录 cookie + 匿名指纹合并（同 key 以登录态为准）
  String _mergeCookie(String extra) {
    final base = BiliAuth.I.cookie;
    if (base.isEmpty) return extra;
    final keys = <String>{};
    final out = <String>[];
    for (final kv in [...base.split(';'), ...extra.split(';')]) {
      final t = kv.trim();
      if (t.isEmpty) continue;
      final k = t.split('=').first;
      if (keys.contains(k)) continue;
      keys.add(k);
      out.add(t);
    }
    return out.join('; ');
  }

  Future<String> _key() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_mixinKey.isNotEmpty && now - _mixAt < 6 * 3600) return _mixinKey;
    try {
      final j = await getJson('/x/web-interface/nav');
      final wbi = ((j['data'] as Map?)?['wbi_img'] as Map?) ?? const {};
      String pick(Object? u) {
        final s = '${u ?? ''}';
        if (s.isEmpty) return '';
        return s.split('/').last.split('.').first;
      }

      final raw = pick(wbi['img_url']) + pick(wbi['sub_url']);
      if (raw.length < 64) return '';
      _mixinKey = _mixinTab.map((i) => raw[i]).join().substring(0, 32);
      _mixAt = now;
    } catch (_) {}
    return _mixinKey;
  }

  /// 普通请求（不需签名）
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, Object?>? query,
    Duration timeout = const Duration(seconds: 18),
  }) async {
    final q = <String, Object?>{...?query};
    final qs = q.isEmpty
        ? ''
        : '?${q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value ?? ''}')}').join('&')}';
    return _rawJson('$path$qs', timeout);
  }

  /// WBI 签名请求
  Future<Map<String, dynamic>> getWbi(
    String path, {
    Map<String, Object?>? query,
    Duration timeout = const Duration(seconds: 18),
  }) async {
    final mixin = await _key();
    final p = <String, Object?>{...?query, 'wts': DateTime.now().millisecondsSinceEpoch ~/ 1000};
    final sorted = p.keys.toList()..sort();
    final qs = sorted.map((k) => '$k=${_enc(p[k])}').join('&');
    if (mixin.isEmpty) return _rawJson('$path?$qs', timeout);
    final rid = md5.convert(utf8.encode(qs + mixin)).toString();
    return _rawJson('$path?$qs&w_rid=$rid', timeout);
  }

  Future<Map<String, dynamic>> _rawJson(String rel, Duration timeout) async {
    try {
      final r = await http
          .get(Uri.parse('$_api$rel'), headers: _hdr())
          .timeout(timeout);
      final j = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// 取二进制（弹幕）
  Future<List<int>> getBytes(String path, {Map<String, Object?>? query}) async {
    final qs = (query == null || query.isEmpty)
        ? ''
        : '?${query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value ?? ''}')}').join('&')}';
    try {
      final r = await http
          .get(Uri.parse('$_api$path$qs'), headers: _hdr())
          .timeout(const Duration(seconds: 20));
      return r.bodyBytes;
    } catch (_) {
      return const [];
    }
  }

  /// 弹幕 XML。
  /// ★ B站 /x/v1/dm/list.so 现在返回 **raw deflate**（不声明 Content-Encoding），
  ///   必须先 inflate 再按 XML 解析；直接 utf8 解码只会得到乱码。
  Future<String> danmakuXml(int cid) async {
    final bytes = await getBytes('/x/v1/dm/list.so', query: {'oid': cid});
    return decompressText(bytes);
  }

  /// 兼容三种情况：已明文 / gzip / raw deflate
  static String decompressText(List<int> bytes) {
    if (bytes.isEmpty) return '';
    // 明文 XML（早期接口 / 某些 CDN 节点会直接给明文）
    if (bytes.length > 5 && bytes[0] == 0x3C /* < */) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    for (final raw in [true, false]) {
      try {
        final out = ZLibDecoder(raw: raw).convert(bytes);
        final s = utf8.decode(out, allowMalformed: true);
        if (s.contains('<')) return s;
      } catch (_) {}
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
