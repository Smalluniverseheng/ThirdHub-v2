// ThirdHub v4.40.0 · M 组 影音深化(PLAN-v3 §3.2)
//   M-5 投屏 DLNA(SSDP 发现 + AVTransport 控制, 纯 Dart 无第三方依赖)
//   M-6 下载归一(所有模块的下载/离线都进同一个下载中心列表)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'pro_kit.dart';

// ══════════════════════════════════════════════════════════════
// M-5 投屏: DLNA/UPnP MediaRenderer
// 只做"控制点"(发现 + 发指令), 不做任何内容解析或源分发。
// ══════════════════════════════════════════════════════════════
class DlnaDevice {
  String name;
  final String location;
  final String udn;
  String control = ''; // AVTransport controlURL(绝对地址)
  DlnaDevice({required this.name, required this.location, this.udn = ''});

  @override
  String toString() => name;
}

class Dlna {
  static HttpClient _hc() =>
      HttpClient()..badCertificateCallback = (_, __, ___) => true;

  /// SSDP 发现(默认 4 秒)。局域网没有响应就返回空表, 不抛异常。
  static Future<List<DlnaDevice>> discover(
      {Duration timeout = const Duration(seconds: 4)}) async {
    final found = <String, DlnaDevice>{};
    RawDatagramSocket? sock;
    StreamSubscription<RawSocketEvent>? sub;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final search = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
      void fire() {
        try {
          sock!.send(utf8.encode(search), InternetAddress('239.255.255.250'), 1900);
        } catch (_) {}
      }

      fire();
      sub = sock!.listen((e) {
        if (e != RawSocketEvent.read) return;
        final dg = sock!.receive();
        if (dg == null) return;
        final txt = String.fromCharCodes(dg.data);
        final loc = RegExp(r'^location:\s*(.+)$',
                caseSensitive: false, multiLine: true)
            .firstMatch(txt)
            ?.group(1)
            ?.trim();
        if (loc == null || loc.isEmpty) return;
        final usn = RegExp(r'^usn:\s*(.+)$',
                caseSensitive: false, multiLine: true)
            .firstMatch(txt)
            ?.group(1)
            ?.trim() ??
            loc;
        found.putIfAbsent(
            usn, () => DlnaDevice(name: _hostName(loc), location: loc, udn: usn));
      });
      // 补一轮(部分设备对首次多播不响应)
      await Future<void>.delayed(const Duration(milliseconds: 700));
      fire();
      await Future<void>.delayed(timeout);
    } catch (_) {
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        sock?.close();
      } catch (_) {}
    }

    final list = found.values.take(10).toList();
    // 逐个取设备描述(拿 friendlyName + AVTransport 控制地址)
    for (final d in list) {
      await _describe(d);
    }
    return list;
  }

  static String _hostName(String loc) {
    try {
      final u = Uri.parse(loc);
      return u.host;
    } catch (_) {
      return loc;
    }
  }

  static Future<void> _describe(DlnaDevice d) async {
    try {
      final req = await _hc().getUrl(Uri.parse(d.location));
      req.headers.set('User-Agent', 'ThirdHub/4.40 UPnP/1.0');
      final res = await req.close().timeout(const Duration(seconds: 4));
      final xml = await res.transform(utf8.decoder).join();
      final friendly = RegExp(r'<friendlyName>(.*?)</friendlyName>', dotAll: true)
          .firstMatch(xml)
          ?.group(1)
          ?.trim();
      if (friendly != null && friendly.isNotEmpty) {
        d.name = friendly;
      }
      // 只在 AVTransport 服务块里找 controlURL
      final blocks = RegExp(r'<service>(.*?)</service>', dotAll: true).allMatches(xml);
      for (final b in blocks) {
        final s = b.group(1) ?? '';
        if (!s.contains('AVTransport')) continue;
        final c = RegExp(r'<controlURL>(.*?)</controlURL>', dotAll: true)
            .firstMatch(s)
            ?.group(1)
            ?.trim();
        if (c != null && c.isNotEmpty) {
          d.control = c.startsWith('http')
              ? c
              : Uri.parse(d.location).resolve(c).toString();
        }
      }
    } catch (_) {}
  }

  static const _svc = 'urn:schemas-upnp-org:service:AVTransport:1';

  static Future<String> _soap(String controlUrl, String action, String inner) async {
    final env = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$_svc">$inner</u:$action></s:Body></s:Envelope>';
    try {
      final req = await _hc().postUrl(Uri.parse(controlUrl));
      req.headers
        ..set('Content-Type', 'text/xml; charset="utf-8"')
        ..set('SOAPACTION', '"$_svc#$action"')
        ..set('User-Agent', 'ThirdHub/4.40 UPnP/1.0');
      req.write(env);
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) {
        final err = RegExp(r'<errorDescription>(.*?)</errorDescription>', dotAll: true)
            .firstMatch(body)
            ?.group(1);
        return err == null ? 'HTTP ${res.statusCode}' : err;
      }
      return '';
    } catch (e) {
      return '$e';
    }
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// 推送一个媒体地址到电视(标题用于电视上显示)
  static Future<String> play(DlnaDevice d, String url,
      {String title = 'ThirdHub', String mime = ''}) async {
    if (d.control.isEmpty) return '该设备没有 AVTransport 控制地址, 无法投屏';
    final mt = mime.isEmpty ? _guessMime(url) : mime;
    final didl = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${_escape(title)}</dc:title>'
        '<upnp:class>object.item.${mt.startsWith('audio') ? 'audioItem' : 'videoItem'}</upnp:class>'
        '<res protocolInfo="http-get:*:$mt:*">${_escape(url)}</res>'
        '</item></DIDL-Lite>';
    final e1 = await _soap(
        d.control,
        'SetAVTransportURI',
        '<InstanceID>0</InstanceID><CurrentURI>${_escape(url)}</CurrentURI>'
            '<CurrentURIMetaData>${_escape(didl)}</CurrentURIMetaData>');
    if (e1.isNotEmpty) return '设置地址失败: $e1';
    final e2 = await _soap(d.control, 'Play',
        '<InstanceID>0</InstanceID><Speed>1</Speed>');
    return e2.isEmpty ? '' : '播放失败: $e2';
  }

  static Future<String> control(DlnaDevice d, String action) async {
    if (d.control.isEmpty) return '设备不支持控制';
    final inner = action == 'Play'
        ? '<InstanceID>0</InstanceID><Speed>1</Speed>'
        : '<InstanceID>0</InstanceID>';
    return await _soap(d.control, action, inner);
  }

  static String _guessMime(String url) {
    final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (p.endsWith('.mp3')) return 'audio/mpeg';
    if (p.endsWith('.flac')) return 'audio/flac';
    if (p.endsWith('.m4a') || p.endsWith('.aac')) return 'audio/mp4';
    if (p.endsWith('.mkv')) return 'video/x-matroska';
    if (p.endsWith('.webm')) return 'video/webm';
    return 'video/mp4';
  }
}

// ══════════════════════════════════════════════════════════════
// M-6 下载归一: 任何模块点"下载"都进这一张表(下载中心)
// ══════════════════════════════════════════════════════════════
class DownloadHub {
  static const _key = 'download_hub_v1';

  static Future<List<Map<String, String>>> all() => ProKit.listOf(_key);

  static Future<void> add({
    required String title,
    required String url,
    String kind = 'file',
    String sub = '',
  }) async {
    if (url.trim().isEmpty) return;
    await ProKit.push(_key, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'title': title.isEmpty ? url.split('/').last : title,
      'url': url,
      'kind': kind,
      'sub': sub,
      'state': 'queued',
      'at': ProKit.now(),
    });
    // 后端在线时同时排进后端下载任务(aria2), 离线只留本地清单
    await ProKit.postJson('/v1/dl/add', {'url': url, 'name': title});
  }

  static Future<void> setState(String id, String state) async {
    final l = await all();
    for (final e in l) {
      if (e['id'] == id) e['state'] = state;
    }
    await ProKit.saveList(_key, l);
  }

  static Future<void> remove(String id) async {
    final l = await all();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(_key, l);
  }

  static Future<void> clearFinished() async {
    final l = await all();
    l.removeWhere((e) => e['state'] == 'done');
    await ProKit.saveList(_key, l);
  }

  /// 从后端拉真实任务列表并合并状态(后端不在线时静默跳过)
  static Future<int> refreshFromBackend() async {
    final r = await ProKit.getJson('/v1/dl/list');
    final d = r['data'];
    if (d is! List) return 0;
    final local = await all();
    var merged = 0;
    for (final e in d) {
      if (e is! Map) continue;
      final name = '${e['name'] ?? e['title'] ?? ''}';
      for (final l in local) {
        if (l['title'] == name || l['url'] == '${e['url'] ?? ''}') {
          l['state'] = '${e['status'] ?? e['state'] ?? l['state']}';
          merged++;
        }
      }
    }
    await ProKit.saveList(_key, local);
    return merged;
  }
}

// ══════════════════════════════════════════════════════════════
// 影音进阶页: 投屏 + 下载归一
// ══════════════════════════════════════════════════════════════
class MediaProPage extends ProPage {
  const MediaProPage({super.key});
  @override
  State<MediaProPage> createState() => _MediaPro();
}

class _MediaPro extends ProPageState<MediaProPage> {
  List<DlnaDevice> devices = [];
  DlnaDevice? last;
  List<Map<String, String>> downloads = [];
  String state = '';

  @override
  String get titleText => '影音进阶';

  @override
  Future<void> load() async {
    downloads = await DownloadHub.all();
    last = await ProKit.mapOf('dlna_last').then((m) {
      if (m['location'] == null || m['location']!.isEmpty) return null;
      final d = DlnaDevice(name: m['name'] ?? '上次的设备', location: m['location']!);
      d.control = m['control'] ?? '';
      return d;
    });
  }

  @override
  List<Widget> buildBody(BuildContext c) {
    return [
      ProUI.card('M-5 投屏 (DLNA)', [
        ProUI.row(Icons.cast, '搜索局域网电视/盒子',
            value: state.isEmpty ? '点一下开始' : state,
            sub: 'SSDP 多播发现, 需要与电视同一 WiFi',
            onTap: () => _scan(c)),
        if (last != null)
          ProUI.row(Icons.history, '上次: ${last!.name}',
              sub: '可直接复用, 不必重新搜索',
              onTap: () => _deviceSheet(c, [last!])),
        for (final d in devices)
          ProUI.row(Icons.tv, d.name,
              value: d.control.isEmpty ? '仅发现' : '可控',
              sub: d.location,
              onTap: d.control.isEmpty
                  ? null
                  : () => _push(c, d)),
      ],
          sub: '把当前播放的地址推给电视; 本机不做转码',
          trailing: ProUI.chip('${devices.length} 台')),

      ProUI.card('M-6 下载归一', [
        ProUI.row(Icons.playlist_add, '手动添加下载',
            sub: '粘贴直链/磁力/种子地址', onTap: () => _addDownload(c)),
        ProUI.row(Icons.cloud_sync, '与后端任务对齐',
            sub: '后端在线时把 aria2 任务状态同步回本表', onTap: () async {
          final n = await DownloadHub.refreshFromBackend();
          await refresh();
          ProUI.toast(c, n > 0 ? '已对齐 $n 条' : '后端无对应任务或未连接');
        }),
        ProUI.row(Icons.cleaning_services_outlined, '清除已完成',
            onTap: () async {
          await DownloadHub.clearFinished();
          await refresh();
        }),
        for (final d in downloads.take(40))
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(_icon(d['kind'] ?? ''), size: 20),
            title: Text(d['title'] ?? '',
                style: const TextStyle(fontSize: 13.5),
                overflow: TextOverflow.ellipsis),
            subtitle: Text('${d['kind']} · ${d['at']}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              ProUI.chip(_stateText(d['state'] ?? ''),
                  color: (d['state'] == 'done') ? Colors.green : Colors.blueGrey),
              IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () async {
                    await DownloadHub.remove(d['id'] ?? '');
                    await refresh();
                  }),
            ]),
          ),
        if (downloads.isEmpty)
          ProUI.note('还没有下载记录。在任意模块点「下载」都会汇总到这里。'),
      ],
          sub: '小说/漫画/视频/音乐/文件 的下载统一入口',
          trailing: ProUI.chip('${downloads.length} 条')),
    ];
  }

  IconData _icon(String kind) => switch (kind) {
        'novel' => Icons.menu_book,
        'comic' => Icons.photo_library,
        'video' => Icons.play_circle,
        'music' => Icons.music_note,
        _ => Icons.download_outlined,
      };

  String _stateText(String s) => switch (s) {
        'done' => '完成',
        'active' => '下载中',
        'paused' => '暂停',
        'error' => '出错',
        _ => '排队中',
      };

  Future<void> _scan(BuildContext c) async {
    touch(() => state = '搜索中…');
    final r = await Dlna.discover();
    touch(() {
      devices = r;
      state = r.isEmpty ? '未发现设备' : '发现 ${r.length} 台';
    });
    if (r.isEmpty) {
      ProUI.toast(c, '没有发现 DLNA 设备, 确认电视与本机在同一局域网');
    }
  }

  Future<void> _deviceSheet(BuildContext c, List<DlnaDevice> list) async {
    await showModalBottomSheet<void>(
      context: c,
      builder: (c2) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final d in list)
              ListTile(
                leading: const Icon(Icons.tv),
                title: Text(d.name),
                subtitle: Text(d.location, style: const TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(c2);
                  _push(c, d);
                },
              ),
          ]),
    );
  }

  Future<void> _push(BuildContext c, DlnaDevice d) async {
    final url = await ProKit.prompt(c, '投屏地址', hint: 'http://… 媒体直链', init: '');
    if (url == null) return;
    final title = await ProKit.prompt(c, '标题(电视上显示)', init: 'ThirdHub 投屏');
    await ProKit.saveMap('dlna_last',
        {'name': d.name, 'location': d.location, 'control': d.control});
    touch(() => last = d);
    ProUI.toast(c, '正在投屏到 ${d.name}…');
    final err = await Dlna.play(d, url, title: title ?? 'ThirdHub');
    ProUI.toast(c, err.isEmpty ? '已发送到电视, 若没反应请检查电视是否允许投屏' : err);
  }

  Future<void> _addDownload(BuildContext c) async {
    final url = await ProKit.prompt(c, '下载地址', hint: 'http:// 或 magnet:');
    if (url == null) return;
    final title = await ProKit.prompt(c, '名称', init: url.split('/').last);
    await DownloadHub.add(title: title ?? '', url: url, kind: 'file');
    await refresh();
    ProUI.toast(c, '已加入下载中心');
  }
}
