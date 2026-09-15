// 阅读字体管理: 内置系统字体 + 在线下载开源阅读字体(霞鹜文楷屏幕阅读版)
// 屏幕阅读版专为长时间手机屏幕阅读优化(字重加粗到Regular, 参照Roboto度量)
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReaderFont {
  final String id, name;
  final String? family;    // 系统字体族(null=默认)
  final String? url;       // 可下载字体
  final String? dlName;    // 下载后注册的family名
  const ReaderFont(this.id, this.name, {this.family, this.url, this.dlName});
  bool get downloadable => url != null;
}

class FontManager {
  static const fonts = <ReaderFont>[
    ReaderFont('default', '系统默认'),
    ReaderFont('serif', '宋体(衬线)', family: 'serif'),
    ReaderFont('sans', '黑体(无衬线)', family: 'sans-serif'),
    ReaderFont('mono', '等宽', family: 'monospace'),
    ReaderFont('wenkai', '霞鹜文楷·屏幕阅读版',
      url: 'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai-Screen@main/fonts/TTF/LXGWWenKaiScreen.ttf',
      dlName: 'LxgwWenKaiScreen'),
    ReaderFont('wenkai-lite', '霞鹜文楷·轻便版',
      url: 'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai-Lite@main/fonts/TTF/LXGWWenKaiLite-Regular.ttf',
      dlName: 'LxgwWenKaiLite'),
  ];

  static final Set<String> _loaded = {};
  static final Map<String, double> downloading = {}; // id → 进度(0-1), 出错为-1
  static final StreamController<void> _chg = StreamController<void>.broadcast();
  static Stream<void> get onChange => _chg.stream;

  static ReaderFont byId(String id) => fonts.firstWhere((f) => f.id == id, orElse: () => fonts.first);

  static Future<File> _file(ReaderFont f) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/fonts/${f.dlName}.ttf');
  }

  static Future<bool> isDownloaded(ReaderFont f) async {
    if (!f.downloadable) return true;
    if (_loaded.contains(f.dlName)) return true;
    try { return await (await _file(f)).exists(); } catch (_) { return false; }
  }

  /// 确保字体可用: 已下载则注册; 未下载返回false(调用方触发download)
  static Future<bool> ensure(ReaderFont f) async {
    if (!f.downloadable) return true;
    if (_loaded.contains(f.dlName)) return true;
    final file = await _file(f);
    if (!await file.exists()) return false;
    try {
      final loader = FontLoader(f.dlName!);
      loader.addFont(Future.value(ByteData.view((await file.readAsBytes()).buffer)));
      await loader.load();
      _loaded.add(f.dlName!);
      return true;
    } catch (_) { return false; }
  }

  /// 后台下载并注册(带进度)
  static Future<bool> download(ReaderFont f) async {
    if (downloading.containsKey(f.id) && downloading[f.id]! >= 0) return false;
    downloading[f.id] = 0; _chg.add(null);
    try {
      final file = await _file(f);
      await file.parent.create(recursive: true);
      final req = http.Request('GET', Uri.parse(f.url!));
      final resp = await http.Client().send(req).timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final total = resp.contentLength ?? 0;
      final sink = file.openWrite();
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk); got += chunk.length;
        if (total > 0) { downloading[f.id] = got / total; _chg.add(null); }
      }
      await sink.close();
      final ok = await ensure(f);
      downloading[f.id] = ok ? 1 : -1;
      _chg.add(null);
      return ok;
    } catch (_) {
      downloading[f.id] = -1; _chg.add(null);
      try { await (await _file(f)).delete(); } catch (_) {}
      return false;
    }
  }

  /// 当前阅读字体family(供TextStyle使用)
  static Future<String?> currentFamily() async {
    final p = await SharedPreferences.getInstance();
    final f = byId(p.getString('reader_font') ?? 'default');
    if (f.family != null) return f.family;
    if (f.downloadable && await ensure(f)) return f.dlName;
    return null;
  }
}
