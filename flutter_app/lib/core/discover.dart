// THP 局域网自动发现: 监听 UDP 19527 的引擎/资源库广播
// 协议: "THP/1 HELLO <port> <caps>" (caps 逗号分隔, 含 library=资源库, 其余=引擎能力)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ThpDevice {
  final String host; final int port; final List<String> caps; DateTime seen;
  final String? instanceId; final String name;
  ThpDevice(this.host, this.port, this.caps, this.seen, {this.instanceId, this.name = ''});
  bool get isLibrary => caps.contains('library');
  String get url => 'http://$host:$port';
  String get label => name.isNotEmpty ? name : (isLibrary ? '资源库' : '引擎(${caps.join('/')})');
}

class ThpDiscovery {
  static RawDatagramSocket? _sock;
  static final Map<String, ThpDevice> devices = {};
  static final StreamController<void> _chg = StreamController<void>.broadcast();
  static Stream<void> get onChange => _chg.stream;
  static bool _running = false;

  static Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 19527, reuseAddress: true);
      _sock!.listen((ev) {
        final dg = _sock!.receive();
        if (dg == null) return;
        final msg = utf8.decode(dg.data, allowMalformed: true).trim();
        final host = dg.address.address;
        // 优雅下线: THP/1 BYE <instanceId>
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
        final key = instanceId != null ? 'iid:$instanceId' : '$host:$port';
        devices[key] = ThpDevice(host, port, caps, DateTime.now(), instanceId: instanceId, name: name);
        _chg.add(null);
      });
      // 每 30s 清理 90s 没再见到的设备
      Timer.periodic(const Duration(seconds: 30), (_) {
        final cut = DateTime.now().subtract(const Duration(seconds: 90));
        final before = devices.length;
        devices.removeWhere((_, d) => d.seen.isBefore(cut));
        if (devices.length != before) _chg.add(null);
      });
    } catch (_) { _running = false; }
  }

  static List<ThpDevice> list() => devices.values.toList()
    ..sort((a, b) => (b.isLibrary ? 1 : 0) - (a.isLibrary ? 1 : 0));
}
