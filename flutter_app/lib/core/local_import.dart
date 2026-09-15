// 本地媒体导入: 未连接后端时, 前端即纯本地播放器
// 小说(txt/epub等) · 视频(mp4等) · 音乐(mp3等) · 漫画(图片/zip/cbz)
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalLib {
  static Future<Directory> _dir(String kind) async {
    final doc = await getApplicationDocumentsDirectory();
    final d = Directory('${doc.path}/local_$kind');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<List<Map<String, dynamic>>> list(String kind) async {
    final p = await SharedPreferences.getInstance();
    try { return (jsonDecode(p.getString('local_$kind') ?? '[]') as List).cast<Map<String, dynamic>>(); }
    catch (_) { return []; }
  }

  static Future<void> _save(String kind, List<Map<String, dynamic>> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('local_$kind', jsonEncode(items));
  }

  static Future<void> remove(String kind, String path) async {
    final items = await list(kind);
    items.removeWhere((e) => e['path'] == path);
    await _save(kind, items);
    try { await File(path).delete(); } catch (_) {}
  }

  // ── 小说: txt 直接拷贝; epub 解出纯文本章节 ──
  static Future<int> importNovels() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom,
      allowedExtensions: ['txt', 'epub', 'umd', 'md'], allowMultiple: true);
    if (r == null) return 0;
    final dir = await _dir('novel');
    final items = await list('novel');
    var n = 0;
    for (final f in r.files) {
      if (f.path == null) continue;
      final src = File(f.path!);
      final name = f.name;
      final ext = name.split('.').last.toLowerCase();
      final dst = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
      if (ext == 'epub') {
        try {
          final text = _epubToText(await src.readAsBytes());
          final out = File('${dst.path}.txt');
          await out.writeAsString(text);
          items.add({'name': name.replaceAll(RegExp(r'\.epub$', caseSensitive: false), ''), 'path': out.path, 'format': 'epub'});
          n++;
        } catch (_) {}
      } else {
        await src.copy(dst.path);
        items.add({'name': name.replaceAll(RegExp(r'\.(txt|umd|md)$', caseSensitive: false), ''), 'path': dst.path, 'format': ext});
        n++;
      }
    }
    await _save('novel', items);
    return n;
  }

  // epub → 纯文本(zip → OPF spine → XHTML 去标签)
  static String _epubToText(List<int> bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    String? opfPath;
    for (final a in zip.files) {
      if (a.name.endsWith('.opf')) { opfPath = a.name; break; }
    }
    final buf = StringBuffer();
    final files = <String>[];
    if (opfPath != null) {
      final opf = utf8.decode(zip.findFile(opfPath)!.content as List<int>, allowMalformed: true);
      final base = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
      final idrefs = RegExp(r'<itemref[^>]*idref="([^"]+)"').allMatches(opf).map((m) => m.group(1)!).toList();
      final manifest = <String, String>{};
      for (final m in RegExp(r'<item[^>]*id="([^"]+)"[^>]*href="([^"]+)"').allMatches(opf)) {
        manifest[m.group(1)!] = m.group(2)!;
      }
      for (final m in RegExp(r'<item[^>]*href="([^"]+)"[^>]*id="([^"]+)"').allMatches(opf)) {
        manifest[m.group(2)!] = m.group(1)!;
      }
      for (final id in idrefs) { final h = manifest[id]; if (h != null) files.add(base + h); }
    }
    if (files.isEmpty) {
      for (final a in zip.files) {
        if (a.name.endsWith('.html') || a.name.endsWith('.xhtml') || a.name.endsWith('.htm')) files.add(a.name);
      }
      files.sort();
    }
    for (final f in files) {
      final a = zip.findFile(f);
      if (a == null || a.content == null) continue;
      var html = utf8.decode(a.content as List<int>, allowMalformed: true);
      html = html.replaceAll(RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false), '');
      html = html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
      html = html.replaceAll(RegExp(r'</p>|</div>|</h[1-6]>', caseSensitive: false), '\n');
      html = html.replaceAll(RegExp(r'<[^>]+>'), '');
      html = html.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"');
      final t = html.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
      if (t.isNotEmpty) { buf.writeln(t); buf.writeln(); }
    }
    return buf.toString();
  }

  // txt 章节切分
  static List<String> splitChapters(String text) {
    final re = RegExp(r'^\s*(第[0-9零一二三四五六七八九十百千万两]+[章节卷回部篇集].{0,40}|序章|楔子|序|番外.{0,20}|Chapter\s+\d+.{0,40})\s*$', multiLine: true);
    final matches = re.allMatches(text).toList();
    if (matches.isEmpty) return [text];
    final chapters = <String>[];
    if (matches.first.start > 0) chapters.add(text.substring(0, matches.first.start));
    for (var i = 0; i < matches.length; i++) {
      final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
      chapters.add(text.substring(matches[i].start, end));
    }
    return chapters;
  }

  // ── 视频 / 音乐: 直接拷贝 ──
  static Future<int> importMedia(String kind, List<String> exts) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: exts, allowMultiple: true);
    if (r == null) return 0;
    final dir = await _dir(kind);
    final items = await list(kind);
    var n = 0;
    for (final f in r.files) {
      if (f.path == null) continue;
      final dst = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_${f.name}');
      await File(f.path!).copy(dst.path);
      items.add({'name': f.name, 'path': dst.path});
      n++;
    }
    await _save(kind, items);
    return n;
  }

  static Future<int> importVideos() => importMedia('video', ['mp4', 'mkv', 'avi', 'mov', 'flv', 'wmv', 'webm', 'ts', 'm3u8']);
  static Future<int> importAudios() => importMedia('music', ['mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'wma', 'ape']);

  // ── 漫画: 多选图片 或 zip/cbz 解包为图片序列 ──
  static Future<int> importComic() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom,
      allowedExtensions: ['zip', 'cbz', 'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'], allowMultiple: true);
    if (r == null) return 0;
    final items = await list('comic');
    var n = 0;
    final zips = r.files.where((f) => f.path != null && (f.name.toLowerCase().endsWith('.zip') || f.name.toLowerCase().endsWith('.cbz'))).toList();
    final imgs = r.files.where((f) => f.path != null && !zips.contains(f)).toList();
    for (final z in zips) {
      try {
        final dir = await _dir('comic');
        final name = z.name.replaceAll(RegExp(r'\.(zip|cbz)$', caseSensitive: false), '');
        final out = Directory('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
        await out.create(recursive: true);
        final zip = ZipDecoder().decodeBytes(await File(z.path!).readAsBytes());
        final pages = <String>[];
        for (final a in zip.files) {
          if (!a.isFile) continue;
          final ln = a.name.toLowerCase();
          if (ln.endsWith('.jpg') || ln.endsWith('.jpeg') || ln.endsWith('.png') || ln.endsWith('.webp') || ln.endsWith('.gif')) {
            final fn = '${out.path}/${pages.length.toString().padLeft(4, '0')}_${a.name.split('/').last}';
            await File(fn).writeAsBytes(a.content as List<int>);
            pages.add(fn);
          }
        }
        pages.sort();
        if (pages.isNotEmpty) { items.add({'name': name, 'path': out.path, 'pages': pages}); n++; }
      } catch (_) {}
    }
    if (imgs.isNotEmpty) {
      final dir = await _dir('comic');
      final out = Directory('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_导入图片');
      await out.create(recursive: true);
      final pages = <String>[];
      for (final f in imgs) {
        final fn = '${out.path}/${pages.length.toString().padLeft(4, '0')}_${f.name}';
        await File(f.path!).copy(fn);
        pages.add(fn);
      }
      items.add({'name': '导入图片 ${DateTime.now().toString().substring(0, 16)}', 'path': out.path, 'pages': pages});
      n++;
    }
    await _save('comic', items);
    return n;
  }
}
