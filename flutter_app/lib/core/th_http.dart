// 放行自建 NAS 的自签名证书（只对可信目标）
//
// ★ 为什么单独成一个文件：
//   `X509Certificate` 这个名字在 webview_flutter（经 platform_interface）里
//   也有一份完全不同的类型。放在 main.dart 里写 `(X509Certificate cert, ...)`
//   时，编译器把参数解析成 webview 那份，于是报
//     · The getter 'issuer' isn't defined for the type 'X509Certificate'
//     · A value of type 'bool Function(X509Certificate/*1*/, ...)'
//       can't be assigned to 'bool Function(X509Certificate/*2*/, ...)'
//   本文件**只** import dart:io，环境里只有 dart:io 的 X509Certificate，不会有歧义。
//
// ★ 为什么需要这段：
//   NAS 后端走自签名 HTTPS（证书 subject/issuer 都是 CN=ThirdHub）。
//   Android 的 TLS 校验会直接拒绝（curl 侧表现为退出码 60 =
//   "SSL certificate problem: self signed certificate"）。Flutter 侧表现为
//   HandshakeException，于是 /v1/meta 探活全部失败 → 后端地址写不进本地
//   → 搜索永远空。表现就是「装了什么版本都没数据」。
//
// ★ 安全边界（两条放行条件，任一满足才信任）：
//   ① host 落在私网 / 回环 / 链路本地 / CGNAT 段；
//   ② 证书 DN 里带 CN=ThirdHub（自建后端标识，公网 IPv6 直连时也认）。
//   正规 CA 签发的证书（例如 Supabase）根本不会触发 badCertificateCallback，
//   因此不受影响；其它公网站点仍按系统规则严格校验。

import 'dart:io';

/// 全局 HTTP 覆盖：只对自建 NAS 放行自签名证书。
class ThirdHubHttpOverrides extends HttpOverrides {
  const ThirdHubHttpOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      if (isPrivateHost(host)) return true;
      final dn = '${cert.subject}|${cert.issuer}';
      if (dn.contains('CN=ThirdHub') || dn.contains('CN = ThirdHub')) return true;
      return false;
    };
    return client;
  }
}

/// 是否内网 / 回环 / 链路本地地址（自签名证书只在这些地方才可信）。
bool isPrivateHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;
  if (h.endsWith('.local') || h.endsWith('.lan')) return true;

  // IPv4
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
  if (m != null) {
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 127) return true; // 回环
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64/10
    return false;
  }

  // IPv6：链路本地 fe80::/10、唯一本地 fc00::/7
  if (h.startsWith('fe8') ||
      h.startsWith('fe9') ||
      h.startsWith('fea') ||
      h.startsWith('feb')) {
    return true;
  }
  if (h.startsWith('fc') || h.startsWith('fd')) return true;

  return false;
}
