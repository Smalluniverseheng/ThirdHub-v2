// 统一的「打开链接」入口。
//
// 规矩（★4.81.75 立）：**App 里任何要打开网页的地方都必须走这里，不要直接
// 调 launchUrl**。以前全库 16 处直接 `LaunchMode.externalApplication`，
// 结果是用户在 App 里点个链接就被踢到系统浏览器，回来还得重新找位置。
//
// 分流规则：
//   • http/https  → 内置浏览器 core/browser_page.dart（多标签、有历史、可返回）
//   • 明确的 OAuth / 支付回调等必须用系统浏览器的 → forceExternal: true
//   • tel: / mailto: / sms: / geo: 等非网页协议 → 系统处理（内置浏览器打不开）
//
// 为什么不由调用方自己判断：判断逻辑散落 16 处必然漂移，这正是本项目
// 「做对的没推广到全库」的老毛病。收口到一处，以后改规则只改这里。
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'browser_page.dart';

class InAppOpen {
  InAppOpen._();

  /// 这些 scheme 内置浏览器没法处理，只能交给系统。
  static const _systemSchemes = {
    'tel',
    'mailto',
    'sms',
    'geo',
    'market',
    'intent',
  };

  /// 打开一个链接。返回 true 表示已处理（内置或外部均可），false 表示失败。
  ///
  /// [ctx] 为 null 时（例如在无 context 的后台逻辑里）退化为外部浏览器。
  /// [title] 仅用于外部失败时的提示，可省。
  static Future<bool> url(
    BuildContext? ctx,
    String rawUrl, {
    bool forceExternal = false,
    String? title,
  }) async {
    final s = rawUrl.trim();
    if (s.isEmpty) return false;

    Uri uri;
    try {
      uri = Uri.parse(s);
    } catch (_) {
      return false;
    }

    // 无 scheme 的裸域名（用户填了 example.com）补成 https
    if (!uri.hasScheme) {
      try {
        uri = Uri.parse('https://$s');
      } catch (_) {
        return false;
      }
    }

    final scheme = uri.scheme.toLowerCase();
    final isWeb = scheme == 'http' || scheme == 'https';

    // 非网页协议 + 明确要求外部 → 系统浏览器
    if (!isWeb || forceExternal || ctx == null) {
      if (_systemSchemes.contains(scheme) || isWeb) {
        return _external(uri);
      }
      return false;
    }

    // 内网页：走内置浏览器
    try {
      await Navigator.of(ctx).push(
        MaterialPageRoute(builder: (_) => BrowserPage(initialUrl: uri.toString())),
      );
      return true;
    } catch (_) {
      // 内置浏览器起不来（极少见）时兜底，不要让用户点了个链接毫无反应
      return _external(uri);
    }
  }

  static Future<bool> _external(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// 判断一个字符串是否是可打开的网页链接（供富文本、聊天消息识别用）。
  static bool looksLikeUrl(String s) {
    final t = s.trim();
    if (t.isEmpty || t.contains(' ')) return false;
    return RegExp(r'^https?://[^\s]+$', caseSensitive: false).hasMatch(t);
  }
}
