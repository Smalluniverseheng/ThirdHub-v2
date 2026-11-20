// 网络调用的兜底超时（2026-11-20 / 4.81.78）
//
// ══ 为什么需要 ══
// `package:http` 的顶层 `get/post` **默认没有超时**。在弱网、DNS 污染、
// 或者服务器已经不通但 TCP 还没被判死的情况下，Future 会一直挂着 ——
// 用户看到的就是"点登录没反应 / 一直在转圈"，而且没有任何错误提示。
//
// 全库 `http.get/post` 有 70+ 处，只有不到一半手动加了 `.timeout`。
// 这里给一对薄包装，默认带上超时；需要更短/更长的传 `timeout:` 覆盖。
//
// 刻意做得极薄（不改 header、不改 body 编码、不包成 class）：
// 任何"智能"行为都会让排查变难，而这里要的只是"别无限等"。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// 账号 / 内容类请求的默认上限。
///
/// 为什么是 18 秒：国内 4G 弱网下一次登录请求偶尔要 8–12 秒才回，
/// 卡太紧会把正常用户判成失败；而超过 18 秒还没回，用户早就以为"坏了"。
const Duration kNetTimeout = Duration(seconds: 18);

Future<http.Response> thGet(
  Uri url, {
  Map<String, String>? headers,
  Duration? timeout,
}) =>
    http.get(url, headers: headers).timeout(timeout ?? kNetTimeout);

Future<http.Response> thPost(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) =>
    http
        .post(url, headers: headers, body: body, encoding: encoding)
        .timeout(timeout ?? kNetTimeout);

Future<http.Response> thDelete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) =>
    http
        .delete(url, headers: headers, body: body, encoding: encoding)
        .timeout(timeout ?? kNetTimeout);

Future<http.Response> thPatch(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  Duration? timeout,
}) =>
    http
        .patch(url, headers: headers, body: body, encoding: encoding)
        .timeout(timeout ?? kNetTimeout);
