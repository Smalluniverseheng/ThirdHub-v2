// 原生网络信息桥（thirdhub/net）—— 只解决两件纯 Dart 做不到的事
//
// ══════════════════════════════════════════════════════════════════════════
// 为什么需要它（2026-09-19 定位「局域网引擎发现时好时坏」的根因）
// ══════════════════════════════════════════════════════════════════════════
// 1) **MulticastLock**
//    Android 的 WiFi 固件在省电状态下会**静默丢弃入站的广播/组播帧**。
//    引擎的发现报文(THP/1 HELLO)走的就是 UDP 广播 —— 不持有 MulticastLock 时，
//    典型症状是「刚打开 App 能发现引擎，锁屏放一会儿就没了」「有时能、有时不能」。
//    纯 Dart 没有任何 API 能拿到这把锁，必须走系统 WifiManager。
//
// 2) **真实子网掩码**
//    `dart:io` 的 NetworkInterface 只给 IP，**不给前缀长度**。旧扫描代码因此写死
//    「本机 IP 的前三段 + 1..254」＝假设 /24。但很多路由器发的是 /16
//    （如 10.0.0.0/16、172.20.0.0/16），此时「同一个网段」的引擎可能落在
//    10.0.**5**.7 这种别的 /24 里 —— 按 /24 扫永远扫不到。
//    另外，装了 Clash / Tailscale 之类会多出 VPN 网卡(10.x/172.x 假网段)，
//    盲目扫它会白跑几百个探针、把真网段的结果拖到很后面。
//
// 非安卓平台（Windows/macOS/Linux/iOS）调用会抛 MissingPluginException，
// 这里统一吞掉并返回 null/空，调用方自动降级回纯 Dart 逻辑 —— 不破坏跨平台。
import 'dart:io';

import 'package:flutter/services.dart';

/// 一条链路地址（ip + 前缀长度）
class NetAddr {
  final String ip;
  final int prefix;
  final bool v6;
  const NetAddr(this.ip, this.prefix, this.v6);

  /// /24 及以上（prefix >= 24）才能安全穷举该 /24
  bool get smallEnoughToSweep => !v6 && prefix >= 24;

  @override
  String toString() => '$ip/$prefix${v6 ? " (v6)" : ""}';
}

/// 一条网络链路（WiFi / 以太网 / 蜂窝 / VPN）
class NetLink {
  final String type; // wifi | ethernet | cellular | vpn | other
  final bool active;
  final List<NetAddr> addresses;
  final String? gateway;
  const NetLink({required this.type, required this.active,
    this.addresses = const [], this.gateway});

  /// ★ VPN 链路一律不参与局域网扫描：那是隧道对端的假网段，扫它没有意义。
  bool get usable => type != 'vpn';

  /// 只在有 IPv4 私网地址且不是 VPN 时才值得扫
  bool get sweeppable => usable && active;
}

class NativeNet {
  static const MethodChannel _ch = MethodChannel('thirdhub/net');

  /// 当前是否真的持有 WiFi 多播锁（诊断页展示用）
  static bool lockHeld = false;

  /// 最近一次原生调用的失败原因（诊断页展示用）
  static String lastError = '';

  /// 只在安卓上可用；其他平台自动降级
  static bool get supported => Platform.isAndroid;

  /// 申请/释放 WiFi 多播锁。返回"当前是否持有"。
  /// 失败不抛异常 —— 拿不到锁只意味着广播可能收不全，不该让发现流程直接挂掉。
  static Future<bool> multicastLock(bool enable) async {
    if (!supported) return false;
    try {
      final r = await _ch.invokeMethod<bool>('multicastLock', {'enable': enable});
      lockHeld = r ?? false;
      return lockHeld;
    } catch (e) {
      lastError = 'multicastLock: $e';
      lockHeld = false;
      return false;
    }
  }

  /// 读取所有网络链路（含真实前缀长度与网关）。非安卓返回空表。
  static Future<List<NetLink>> links() async {
    if (!supported) return const [];
    try {
      final raw = await _ch.invokeMethod<Map<Object?, Object?>>('networkInfo');
      if (raw == null) return const [];
      final list = raw['networks'];
      if (list is! List) return const [];
      final out = <NetLink>[];
      for (final e in list) {
        if (e is! Map) continue;
        final addrs = <NetAddr>[];
        final al = e['addresses'];
        if (al is List) {
          for (final a in al) {
            if (a is! Map) continue;
            final ip = '${a['ip'] ?? ''}';
            if (ip.isEmpty) continue;
            addrs.add(NetAddr(ip, (a['prefix'] as num?)?.toInt() ?? 32,
                a['v6'] == true));
          }
        }
        out.add(NetLink(
          type: '${e['type'] ?? 'other'}',
          active: e['active'] == true,
          addresses: addrs,
          gateway: e['gateway'] == null ? null : '${e['gateway']}',
        ));
      }
      return out;
    } catch (e) {
      lastError = 'networkInfo: $e';
      return const [];
    }
  }

  /// 诊断用的一句话摘要
  static Future<String> describe() async {
    if (!supported) return '非安卓平台(用系统网络栈)';
    final ls = await links();
    if (ls.isEmpty) return '原生网络信息不可用${lastError.isEmpty ? '' : ' · $lastError'}';
    final active = ls.where((l) => l.active).toList();
    final parts = <String>[];
    for (final l in (active.isEmpty ? ls : active)) {
      parts.add('${l.type}[${l.addresses.map((a) => a.toString()).join(' ')}]');
    }
    return '${parts.join(' · ')}${lockHeld ? ' · 多播锁已持' : ' · 多播锁未持'}';
  }
}
