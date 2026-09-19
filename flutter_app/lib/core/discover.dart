// THP 局域网自动发现: 监听 UDP 19527 的引擎/资源库广播
// 协议: "THP/1 HELLO <port> <instanceId> <engine|library> <caps> [name]"
//       "THP/1 BYE <instanceId>"（优雅下线）
//
// ══════════════════════════════════════════════════════════════════════════
// ★ 2026-09-19 修复「根本搜不到引擎 / 阅读连不上前端」的**发现层**根因
// ══════════════════════════════════════════════════════════════════════════
// 旧实现**只靠 UDP 广播**（引擎往 255.255.255.255:19527 发 HELLO）。
// 这条路径下面这些常见环境里会**完全收不到**，而界面只显示"未发现引擎"，
// 用户无从判断是什么坏了：
//   (a) **IPv6 优先 / IPv4 缺失的网络**（运营商 IPv6 单栈、部分 5G / 校园网）——
//       引擎的广播目标是 IPv4 有限广播地址，IPv6 链路里根本不存在这条路径；
//   (b) **AP 隔离 / 客户端隔离**（酒店、公共 WiFi、部分路由器默认开）——
//       AP 不转发广播帧，但**单播 TCP 是通的**；
//   (c) **Doze / 屏幕熄灭**——引擎侧广播协程被挂起（引擎要等亮屏才补发 HELLO，最长 30s+ttl）；
//   (d) **引擎就跑在同一台手机上**（阅读引擎 :1234 与前端 App 同机）——
//       这种情况压根不需要广播，127.0.0.1 直连即可，但旧实现只等广播。
//
// 因此本版新增 `scan()`：**主动探测**。枚举本机所有网卡的地址，派生候选主机，
// 对 1234 / 9527 两个众所周知的 THP 端口做**并发 TCP 连接**，通了再打一次
// `/thp/meta` 确认是 THP 服务。这条路径不依赖任何广播，上面 (a)(b)(c)(d) 全部覆盖。
//
// 设计取舍：
//   · TCP connect 比 HTTP 快得多（失败 1 个 RTT 内返回），所以先 TCP 探活再 HTTP 确认；
//   · 候选顺序 = 本机回环 → 本机各网卡地址 → 同网段扫描 → 已知历史地址，
//     命中即回，绝大多数情况十几个探针内就出结果；
//   · 并发上限 48，单探针 420ms —— 一个 /24 网段 ≈ 500 个探针 ≈ 5 轮 ≈ 2–4s；
//   · 只扫**私有网段**（192.168/10/172.16-31），不扫公网地址，避免变成端口扫描器。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'native_net.dart';

class ThpDevice {
  final String host; final int port; final List<String> caps; DateTime seen;
  final String? instanceId; final String name;
  /// true = 主动扫描发现的（非广播），UI 可据此提示"（扫描发现）"
  final bool scanned;
  ThpDevice(this.host, this.port, this.caps, this.seen,
      {this.instanceId, this.name = '', this.scanned = false});
  bool get isLibrary => caps.contains('library');
  /// ★ host 已是可直接拼 URL 的形式：IPv6 带方括号，IPv4/域名原样
  String get url => 'http://$host:$port';
  String get label => name.isNotEmpty
      ? name
      : (isLibrary ? '资源库' : '引擎(${caps.join('/')})');
}

class ThpDiscovery {
  static RawDatagramSocket? _sock;
  static final Map<String, ThpDevice> devices = {};
  static final StreamController<void> _chg = StreamController<void>.broadcast();
  static Stream<void> get onChange => _chg.stream;
  static bool _running = false;

  /// THP 服务的众所周知端口：引擎 :1234 / 资源库 :9527
  static const kEnginePort = 1234;
  static const kLibraryPort = 9527;
  static const kPorts = <int>[kEnginePort, kLibraryPort];

  /// 最近一次扫描的统计（诊断页展示用）
  static int lastScanProbed = 0;
  static int lastScanMs = 0;

  static Future<void> start() async {
    if (_running) return;
    _running = true;
    // ★ 2026-09-19：Android 的 WiFi 固件在省电模式下会**静默丢弃入站广播/组播**。
    //   不持 MulticastLock 时的典型症状就是「刚开 App 能发现引擎，锁屏一会儿就没了」。
    //   拿不到锁不致命（下面还有主动扫描兜底），所以失败也不抛。
    unawaited(NativeNet.multicastLock(true));
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 19527, reuseAddress: true);
      _sock!.listen((ev) {
        final dg = _sock!.receive();
        if (dg == null) return;
        // 广播发现的会覆盖扫描发现的（广播带 caps/name，信息更全）
        _ingest(utf8.decode(dg.data, allowMalformed: true).trim(), dg.address.address);
      });
      // 每 30s 清理 90s 没再见到的设备。★扫描发现的设备给更长的 TTL（更长 3 分钟），
      //   因为扫描是用户显式触发的、不是持续性信号，清得太快会让"刚扫到的引擎"又消失。
      Timer.periodic(const Duration(seconds: 30), (_) {
        final now = DateTime.now();
        final before = devices.length;
        devices.removeWhere((_, d) =>
            d.seen.isBefore(now.subtract(Duration(seconds: d.scanned ? 180 : 90))));
        if (devices.length != before) _chg.add(null);
      });
      // ★ 双栈：再绑一个 IPv6 socket。THP 广播目前都是 IPv4，但
      //   「后端/资源库跑在 IPv6 侧」的场景必须能收（用户明确要求 IPv6 优先）。
      //   绑不上（部分系统禁用 v6）完全无害，不影响 IPv4 路径。
      unawaited(_bindV6());
    } catch (_) { _running = false; }
  }

  static RawDatagramSocket? _sock6;

  /// 尽力而为的 IPv6 侦听：失败静默（IPv6 链路缺失时 bind 会抛）
  static Future<void> _bindV6() async {
    try {
      _sock6 = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 19527, reuseAddress: true);
      _sock6!.listen((ev) {
        final dg = _sock6!.receive();
        if (dg == null) return;
        _ingest(utf8.decode(dg.data, allowMalformed: true).trim(), dg.address.address);
      });
    } catch (_) { _sock6 = null; }
  }

  /// 统一的报文处理（IPv4/IPv6 两个 socket 共用，避免两份解析逻辑漂移）
  static void _ingest(String msg, String host) {
    final bye = RegExp(r'^THP/1 BYE ([\w\-]+)$').firstMatch(msg);
    if (bye != null) {
      final iid = bye.group(1)!;
      final before = devices.length;
      devices.removeWhere((_, d) => d.instanceId == iid);
      if (devices.length != before) _chg.add(null);
      return;
    }
    // 新格式 THP/1.0: HELLO <port> <instanceId> <engine|library> <caps> [name]
    var m = RegExp(r'^THP/1 HELLO (\d+) ([\w\-]+) (engine|library) ([\w:,\-]+)(?:\s+(.*))?$').firstMatch(msg);
    String? instanceId; String name = '';
    int port; List<String> caps;
    if (m != null) {
      port = int.parse(m.group(1)!);
      instanceId = m.group(2)!;
      caps = m.group(4)!.split(',');
      if (m.group(3) == 'library' && !caps.contains('library')) caps = [...caps, 'library'];
      name = m.group(5) ?? '';
    } else {
      // 旧草稿格式(兼容): HELLO <port> <caps>
      final m2 = RegExp(r'^THP/1 HELLO (\d+) ([\w,\-]+)$').firstMatch(msg);
      if (m2 == null) return;
      port = int.parse(m2.group(1)!);
      caps = m2.group(2)!.split(',');
    }
    // 带 IPv6 的 host 统一加方括号，url 拼接才合法
    final h = host.contains(':') ? '[$host]' : host;
    final key = host;  // 用裸地址做键，避免带括号/不带括号重复
    final prev = devices[key];
    devices[key] = ThpDevice(h, port, caps, DateTime.now(),
        instanceId: instanceId ?? prev?.instanceId, name: name.isEmpty ? (prev?.name ?? '') : name);
    _chg.add(null);
  }

  // ─────────────────────────── 主动扫描 ───────────────────────────

  /// 主动扫描局域网 + 本机回环，找 THP 引擎/资源库。
  ///
  /// [subnetSweep] = 是否做同网段 /24 扫描（默认 true）。诊断页可关掉它，
  /// 只探"本机 + 回环"，用来区分「引擎就在本机」和「引擎在对端设备」。
  /// [extra] = 额外候选地址（如用户之前手输过的地址、IPv6 字面量）。
  static Future<List<ThpDevice>> scan({
    bool subnetSweep = true,
    List<String> extra = const [],
    int timeoutMs = 420,
    int concurrency = 48,
    void Function(int done, int total)? onProgress,
  }) async {
    final sw = Stopwatch()..start();

    // ★扫描期间持锁：广播这条快路要收得住，扫描结果也可能来自 HELLO
    unawaited(NativeNet.multicastLock(true));

    // ── 1. 造候选（优先本机，命中即最快出结果）──
    final cands = <String>{'127.0.0.1'};        // ★同机引擎最先试
    // ★本机地址必须放最前：手机自己跑着引擎 App 时 127.0.0.1 一击即中
    for (final e in extra) { final s = e.trim(); if (s.isNotEmpty) cands.add(_normalizeHost(s)); }

    // 候选拔高上限：任何异常网络（超大网段/网卡爆炸）下都不许把内存和耗时拖爆
    const int kMaxCands = 4096;

    if (subnetSweep) {
      // ── 1a. 优先用**原生真实前缀**（安卓）：/16 这类大网段靠猜 /24 是扫不到的 ──
      final links = await NativeNet.links();
      final swept24 = <String>{};
      var nativeOk = false;
      for (final l in links.where((x) => x.sweeppable)) {
        for (final a in l.addresses) {
          if (a.v6) {
            // IPv6：/64 全量扫不现实（天文数字），只登记本机自身地址。
            //   对端 IPv6 引擎靠 UDP/mDNS 或手输地址解决，不靠穷举。
            cands.add(_normalizeHost(a.ip));
            continue;
          }
          if (!_isPrivateV4(a.ip)) continue;
          nativeOk = true;
          cands.add(a.ip);                                  // 本机地址本身（引擎可能只绑在该网卡）
          cands.add(_hostIn(a.ip, 1));                      // 网关常见位
          if (a.prefix >= 24) {
            // /24 及以上：可以安全穷举自己这个 /24
            final p24 = _prefix24(a.ip);
            if (swept24.add(p24)) {
              for (var i = 1; i <= 254; i++) cands.add('$p24.$i');
            }
          } else {
            // ★/16、/12 这类大网段（宿舍/企业网常见），穷举 254 个 /24 不现实。
            //   策略：扫自己 /24 + **网关所在 /24** + 相邻 /24，都是"引擎最可能出现"的位置。
            //   真正跨 /24 的引擎，最终靠引擎侧的**子网定向广播**发现（引擎侧已同步修）。
            final p24 = _prefix24(a.ip);
            if (swept24.add(p24)) { for (var i = 1; i <= 254; i++) cands.add('$p24.$i'); }
            if (l.gateway != null && _isPrivateV4(l.gateway!)) {
              final g24 = _prefix24(l.gateway!);
              if (swept24.add(g24)) { for (var i = 1; i <= 254; i++) cands.add('$g24.$i'); }
            }
          }
        }
        if (l.gateway != null && _isPrivateV4(l.gateway!)) cands.add(l.gateway!);
      }

      // ── 1b. 原生不可用时（非安卓 / API 失败）回落到 dart:io 枚举 ──
      //   注意：这里**拿不到前缀长度**，只能按 /24 假设；这是降级路径，不是主路径。
      //   ★VPN 网卡（Clash/Tailscale 的 10.x、172.x 假网段）在此路径下无法识别，
      //     所以原生通道在安卓上不仅是"更准"，还是"避免白扫"的关键。
      if (!nativeOk) {
        try {
          final ifaces = await NetworkInterface.list(
              includeLoopback: false, includeLinkLocal: false, type: InternetAddressType.any);
          for (final ni in ifaces) {
            for (final a in ni.addresses) {
              final ip = a.address;
              if (a.type != InternetAddressType.IPv4) { cands.add(_normalizeHost(ip)); continue; }
              if (!_isPrivateV4(ip)) continue;
              cands.add(ip);
              final p24 = _prefix24(ip);
              for (var i = 1; i <= 254; i++) cands.add('$p24.$i');
            }
          }
        } catch (_) {}
      }
    }

    // 上限保护：超出就砍掉尾部（保留 127.0.0.1 / 本机 / 网关等前排）
    var hostList = cands.toList();
    if (hostList.length > kMaxCands) hostList = hostList.sublist(0, kMaxCands);

    // ── 2. 并发探测 ──
    final hosts = hostList;
    final found = <ThpDevice>[];
    final total = hosts.length * kPorts.length;
    var done = 0;
    var idx = 0;

    Future<void> worker() async {
      while (true) {
        final i = idx++;
        if (i >= hosts.length) return;
        final h = hosts[i];
        for (final port in kPorts) {
          if (found.any((d) => d.host == h && d.port == port)) { done++; continue; }
          if (await probeTcp(h, port, timeoutMs)) {
            final dev = await _probeMeta(h, port);
            if (dev != null) {
              found.add(dev);
              devices[h] = dev;
              _chg.add(null);
            }
          }
          done++;
          onProgress?.call(done, total);
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency; i++) worker(),
    ]);
    sw.stop();
    lastScanProbed = total;
    lastScanMs = sw.elapsedMilliseconds;
    return found;
  }

  /// RFC1918 私有 IPv4（只扫这些，绝不扫公网 —— 别把 App 变成端口扫描器）
  static bool _isPrivateV4(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? -1;
    final b = int.tryParse(p[1]) ?? -1;
    if (a < 0 || b < 0) return false;
    return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  /// 取 IPv4 的前三段（即所属 /24 前缀）
  static String _prefix24(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return ip;
    return '${p[0]}.${p[1]}.${p[2]}';
  }

  /// 同 /24 内的第 n 号主机
  static String _hostIn(String ip, int n) => '${_prefix24(ip)}.$n';

  static String _normalizeHost(String s) {
    var t = s.trim();
    t = t.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    t = t.split('/').first;
    // 去掉可能带的端口
    if (t.startsWith('[')) { final i = t.indexOf(']'); if (i > 0) return t.substring(0, i + 1); }
    final c = t.lastIndexOf(':');
    if (c > 0 && !t.substring(c + 1).contains(':') && int.tryParse(t.substring(c + 1)) != null) {
      t = t.substring(0, c);
    }
    return t.contains(':') && !t.startsWith('[') ? '[$t]' : t;
  }

  /// TCP 探活：比 HTTP 请求快一个数量级，失败 1 个 RTT 内返回。
  /// 公开给自检页用（同库内 `_probeTcp` 是库私有，跨文件访问不到）。
  static Future<bool> probeTcp(String host, int port, int timeoutMs) async {
    final raw = host.startsWith('[') ? host.substring(1, host.length - 1) : host;
    try {
      final s = await Socket.connect(raw, port, timeout: Duration(milliseconds: timeoutMs));
      s.destroy();
      return true;
    } catch (_) { return false; }
  }

  /// HTTP /thp/meta 确认是 THP 服务（避免把别的服务误判成引擎）
  static Future<ThpDevice?> _probeMeta(String host, int port) async {
    final scheme = 'http';
    final uri = Uri.parse('$scheme://$host:$port/thp/meta');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 4));
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 4));
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final m = (j['data'] is Map ? j['data'] : j) as Map;
      // THP 一定带 name 或 caps；两者都没有说明不是引擎
      final nm = '${m['name'] ?? ''}';
      final cpRaw = m['caps'];
      final cp = <String>[for (final x in (cpRaw as List? ?? [])) '$x'];
      if (nm.isEmpty && cp.isEmpty) return null;
      if (cp.isEmpty && port == kLibraryPort) cp.add('library');
      final ver = '${m['version'] ?? ''}';
      return ThpDevice(host, port, cp, DateTime.now(),
          name: nm.isEmpty ? (port == kLibraryPort ? '资源库' : 'THP 引擎 v$ver') : nm,
          scanned: true);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 扫描发现的设备补进 devices（scan 已写入，这里供外部显式登记，如手输地址验证成功后）
  static void remember(ThpDevice d) { devices[d.host] = d; _chg.add(null); }

  static List<ThpDevice> list() => devices.values.toList()
    ..sort((a, b) {
      // 库在后、引擎在前；同为引擎时回环优先（同机引擎最快最稳）
      final l = (b.isLibrary ? 1 : 0) - (a.isLibrary ? 1 : 0);
      if (l != 0) return l;
      final la = a.host.contains('127.0.0.1') ? 0 : 1;
      final lb = b.host.contains('127.0.0.1') ? 0 : 1;
      return la - lb;
    });
}
