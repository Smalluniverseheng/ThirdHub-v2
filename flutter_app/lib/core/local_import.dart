// 本地媒体导入: 未连接后端时, 前端即纯本地播放器
// 小说(txt/epub等) · 视频(mp4等) · 音乐(mp3等) · 漫画(图片/zip/cbz)
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart' as cs;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_formats.dart';

class LocalLib {
  /// 上一次导入的逐文件失败原因（UI 直接展示，不再用"未导入"一句糊过去）。
  static final List<String> lastErrors = <String>[];

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
    invalidateNovel(path);
    try { await File(path).delete(); } catch (_) {}
  }

  // 编辑元数据(书名/作者/封面…): path 定位条目, patch 覆盖同名键; 值为 null 删除该键
  static Future<void> updateMeta(String kind, String path, Map<String, dynamic> patch) async {
    final items = await list(kind);
    final i = items.indexWhere((e) => e['path'] == path);
    if (i < 0) return;
    patch.forEach((k, v) { if (v == null) items[i].remove(k); else items[i][k] = v; });
    await _save(kind, items);
  }

  // ── 文本解码: UTF-8/UTF-16(BOM) → 严格UTF-8 → GBK(中文小说常见) → 容错UTF-8 ──
  // 网上下载的中文 txt 小说大量是 GBK/GB18030 编码, 直接 latin1 兜底会全文乱码("看不了")
  static String decodeText(List<int> bytes) {
    if (bytes.isEmpty) return '';
    // BOM 优先: UTF-8 / UTF-16LE / UTF-16BE
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      try { return utf8.decode(bytes.sublist(3)); } catch (_) {}
    }
    if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      try { return cs.utf16.decode(bytes); } catch (_) {} // charset 的 utf16 自动剥 BOM
    }
    // 严格 UTF-8 能过 → 就是 UTF-8
    try { return utf8.decode(bytes); } catch (_) {}
    // 高位字节占比高 → 大概率 GBK/GB18030(每个汉字 2 个高位字节, 中文书通常 >30%)
    var hi = 0;
    final probe = bytes.length > 65536 ? bytes.sublist(0, 65536) : bytes;
    for (final b in probe) { if (b >= 0x80) hi++; }
    if (hi > probe.length * 0.05) {
      try {
        final s = cs.gbk.decode(bytes);
        //  sanity: 解出 CJK 字符才算成功(否则可能是西欧 latin1 文本被误吞)
        if (RegExp(r'[一-鿿]').hasMatch(s.substring(0, s.length > 2000 ? 2000 : s.length))) return s;
      } catch (_) {}
    }
    // 最后兜底: 容错 UTF-8(坏字节变 , 至少不乱码) → latin1
    try { return utf8.decode(bytes, allowMalformed: true); } catch (_) {}
    return latin1.decode(bytes);
  }

  // ── 小说章节读取缓存: 翻章不再重复"读全文件+切章"(每章翻页原本要重读 3 次) ──
  static final Map<String, (int, List<String>)> _chapCache = {}; // path → (mtimeMs, chapters)
  static Future<List<String>> readNovelChapters(String path) async {
    final f = File(path);
    final mt = (await f.stat()).modified.millisecondsSinceEpoch;
    final hit = _chapCache[path];
    if (hit != null && hit.$1 == mt) return hit.$2;
    final text = decodeText(await f.readAsBytes());
    final chs = splitChapters(text);
    if (_chapCache.length >= 4) _chapCache.remove(_chapCache.keys.first); // 最多缓存 4 本
    _chapCache[path] = (mt, chs);
    return chs;
  }
  static void invalidateNovel(String path) => _chapCache.remove(path);

  // ── 小说: txt/md/umd 直接拷贝; epub 解出纯文本章节; fb2/html/xhtml/rtf 抽正文 ──
  //
  // 保真取舍：epub/fb2/html/rtf 一律**转成纯文本落盘**（同名 .txt），这样后续
  // 章节切分、阅读器、听书全部走同一条 txt 通路，不用为每种格式各写一套渲染。
  // 代价是丢原书排版——纯阅读场景可接受，也符合"本地导入即读书"的定位。
  static Future<int> importNovels() async {
    lastErrors.clear();
    final r = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: MediaFormats.novelExts, allowMultiple: true);
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
      final stem = name.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
      // 需要解析的格式 → 统一产出 .txt
      final needParse = const {'epub', 'fb2', 'html', 'htm', 'xhtml', 'rtf'}.contains(ext);
      if (needParse) {
        try {
          final bytes = await src.readAsBytes();
          final text = ext == 'epub' ? epubToText(bytes) : MediaFormats.bookToText(bytes, ext);
          if (text == null || text.trim().isEmpty) {
            lastErrors.add('$name: 没能解析出正文(文件可能损坏或加密)');
            continue;
          }
          final out = File('${dst.path}.txt');
          await out.writeAsString(text);
          items.add({'name': stem, 'path': out.path, 'format': ext, 'size': text.length});
          n++;
        } catch (e) {
          lastErrors.add('$name: 解析失败($e)');
        }
      } else {
        try {
          await src.copy(dst.path);
          items.add({'name': stem, 'path': dst.path, 'format': ext});
          n++;
        } catch (e) {
          lastErrors.add('$name: $e');
        }
      }
    }
    await _save('novel', items);
    return n;
  }

  // epub → 纯文本(zip → OPF spine → XHTML 去标签)
  static String epubToText(List<int> bytes) {
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

  // ── 视频 / 音乐: 直接拷贝; 视频额外把同目录同名的外挂字幕一起收进来 ──
  static Future<int> importMedia(String kind, List<String> exts, {bool withSubs = false}) async {
    lastErrors.clear();
    final r = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: exts, allowMultiple: true);
    if (r == null) return 0;
    final dir = await _dir(kind);
    final items = await list(kind);
    var n = 0;
    for (final f in r.files) {
      if (f.path == null) continue;
      try {
        final src = File(f.path!);
        final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
        final dst = File('${dir.path}/${stamp}_${f.name}');
        await src.copy(dst.path);
        final Map<String, dynamic> item = {'name': f.name, 'path': dst.path};
        if (withSubs) {
          // 常见的"片子和字幕同目录同名"：顺手把 srt/vtt/ass 一起搬过来，
          // 落到和视频同一前缀，播放时按前缀找字幕即可。
          final subs = await _siblings(src, dst, stamp);
          if (subs.isNotEmpty) item['subs'] = subs;
        }
        items.add(item);
        n++;
      } catch (e) {
        lastErrors.add('${f.name}: $e');
      }
    }
    await _save(kind, items);
    return n;
  }

  /// 把 [src] 同目录、同主文件名的字幕文件拷到 [dst] 旁边（同名前缀）。
  static Future<List<String>> _siblings(File src, File dst, String stamp) async {
    final out = <String>[];
    try {
      final parent = src.parent;
      final stem = src.path.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
      final lower = stem.toLowerCase();
      final outDir = dst.parent.path;
      await for (final e in parent.list()) {
        if (e is! File) continue;
        final fn = e.path.split(RegExp(r'[/\\]')).last;
        final dot = fn.lastIndexOf('.');
        if (dot <= 0) continue;
        final base = fn.substring(0, dot);
        final ext = fn.substring(dot + 1).toLowerCase();
        if (base.toLowerCase() != lower) continue;
        if (!MediaFormats.subExts.contains(ext)) continue;
        final target = '$outDir/${stamp}_$stem.$ext';
        await e.copy(target);
        out.add(target);
      }
    } catch (_) {}
    return out;
  }

  /// 播放前找字幕：同目录、同前缀、扩展名在 [MediaFormats.subExts] 里。
  ///
  /// 用前缀匹配而不是精确同名，是为了兼容导入时加了时间戳前缀的落盘命名。
  static Future<List<String>> findSubtitles(String videoPath) async {
    final out = <String>[];
    try {
      final f = File(videoPath);
      final fn = f.path.split(RegExp(r'[/\\]')).last;
      final dot = fn.lastIndexOf('.');
      final prefix = dot > 0 ? fn.substring(0, dot) : fn;
      await for (final e in f.parent.list()) {
        if (e is! File || e.path == videoPath) continue;
        final name = e.path.split(RegExp(r'[/\\]')).last;
        final d2 = name.lastIndexOf('.');
        if (d2 <= 0) continue;
        if (name.substring(0, d2) != prefix) continue;
        if (!MediaFormats.subExts.contains(name.substring(d2 + 1).toLowerCase())) continue;
        out.add(e.path);
      }
    } catch (_) {}
    // srt > ass > vtt > 其他，第一个作为默认字幕
    out.sort((a, b) => _subRank(a).compareTo(_subRank(b)));
    return out;
  }

  static int _subRank(String p) {
    switch (p.split('.').last.toLowerCase()) {
      case 'srt': return 0;
      case 'ass':
      case 'ssa': return 1;
      case 'vtt': return 2;
      default: return 3;
    }
  }

  static Future<int> importVideos() =>
      importMedia('video', MediaFormats.videoExts, withSubs: true);
  static Future<int> importAudios() => importMedia('music', MediaFormats.audioExts);

  // ── 漫画: 多选图片 或 zip/cbz 解包为图片序列 ──
  static Future<int> importComic() async {
    lastErrors.clear();
    final r = await FilePicker.platform.pickFiles(type: FileType.custom,
      allowedExtensions: MediaFormats.comicExts, allowMultiple: true);
    if (r == null) return 0;
    final items = await list('comic');
    var n = 0;
    bool isZip(String p) {
      final e = p.split('.').last.toLowerCase();
      return e == 'zip' || e == 'cbz';
    }
    final zips = r.files.where((f) => f.path != null && isZip(f.path!)).toList();
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
          if (ln.endsWith('.jpg') || ln.endsWith('.jpeg') || ln.endsWith('.png') || ln.endsWith('.webp') ||
              ln.endsWith('.gif') || ln.endsWith('.bmp') || ln.endsWith('.avif')) {
            final fn = '${out.path}/${pages.length.toString().padLeft(4, '0')}_${a.name.split('/').last}';
            await File(fn).writeAsBytes(a.content as List<int>);
            pages.add(fn);
          }
        }
        pages.sort();
        if (pages.isNotEmpty) {
          items.add({'name': name, 'path': out.path, 'pages': pages});
          n++;
        } else {
          lastErrors.add('${z.name}: 压缩包里没有图片');
          await out.delete(recursive: true);
        }
      } catch (e) {
        lastErrors.add('${z.name}: 解包失败($e)');
      }
    }
    if (imgs.isNotEmpty) {
      final dir = await _dir('comic');
      final out = Directory('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_导入图片');
      await out.create(recursive: true);
      final pages = <String>[];
      for (final f in imgs) {
        try {
          final fn = '${out.path}/${pages.length.toString().padLeft(4, '0')}_${f.name}';
          await File(f.path!).copy(fn);
          pages.add(fn);
        } catch (e) {
          lastErrors.add('${f.name}: $e');
        }
      }
      if (pages.isNotEmpty) {
        items.add({'name': '导入图片 ${DateTime.now().toString().substring(0, 16)}', 'path': out.path, 'pages': pages});
        n++;
      } else {
        await out.delete(recursive: true);
      }
    }
    await _save('comic', items);
    return n;
  }

  /// RAR/7z 这类本机解不了的漫画包：给出明确指引，而不是静默失败。
  static String unpackHint() =>
      'RAR / 7z 压缩包无法直接解包，请先解压成图片（或转存为 zip/cbz）再导入';

  // ══ 自动识别导入（D-05）：扫描常见目录，按扩展名归类 ══
  //
  // 合规与可靠性取舍：Android 11+ 全盘扫描需要 MANAGE_EXTERNAL_STORAGE（受限权限），
  // 所以默认只扫**应用可见的公共目录**（Download/Documents/Movies/Music/DCIM +
  // 应用私有目录），用户也可以**自己选一个目录**（SAF 授权）作为扫描根。
  // 扫描有深度/数量上限 + 进度回调，不会卡死。

  /// 自动识别的扫描根目录。返回 [(显示名, 路径)]。
  static Future<List<(String, String)>> scanRoots() async {
    final out = <(String, String)>[];
    void add(String n, String? p) {
      if (p != null && p.isNotEmpty && Directory(p).existsSync()) out.add((n, p));
    }
    try {
      final exts = await getExternalStorageDirectories();
      // getExternalStorageDirectories()[i].path ≈ /storage/emulated/0/Android/data/<pkg>/files
      // 公共根 = 往上四级
      if (exts != null && exts.isNotEmpty) {
        final base = exts.first.path.split('/Android/').first; // /storage/emulated/0
        add('下载', '$base/Download');
        add('文档', '$base/Documents');
        add('视频', '$base/Movies');
        add('音乐', '$base/Music');
        add('图片', '$base/DCIM');
        add('存储根目录', base);
      }
    } catch (_) {}
    try {
      final doc = await getApplicationDocumentsDirectory();
      add('应用目录', doc.path);
    } catch (_) {}
    return out;
  }

  /// 递归扫描 [root] 下扩展名属于 [exts] 的文件。
  /// [onProgress] 每发现一个就回调一次（已发现总数）。
  /// 上限：最深 6 层、最多 [maxFound] 个文件、最多访问 20000 个目录项 —— 防卡死。
  static Future<List<String>> scan(String root, List<String> exts,
      {void Function(int found)? onProgress, int maxFound = 2000}) async {
    final found = <String>[];
    final lower = exts.map((e) => e.toLowerCase()).toSet();
    var visited = 0;
    Future<void> walk(Directory d, int depth) async {
      if (depth > 6 || found.length >= maxFound || visited > 20000) return;
      List<FileSystemEntity> kids;
      try {
        kids = await d.list().toList();
      } catch (_) {
        return;
      }
      for (final e in kids) {
        visited++;
        if (found.length >= maxFound || visited > 20000) return;
        try {
          if (e is File) {
            final name = e.path.split(RegExp(r'[/\\]')).last;
            final dot = name.lastIndexOf('.');
            if (dot <= 0) continue;
            if (lower.contains(name.substring(dot + 1).toLowerCase())) {
              found.add(e.path);
              onProgress?.call(found.length);
            }
          } else if (e is Directory) {
            final dn = e.path.split(RegExp(r'[/\\]')).last;
            if (dn.startsWith('.')) continue; // 跳过隐藏目录
            await walk(e, depth + 1);
          }
        } catch (_) {}
      }
    }
    await walk(Directory(root), 0);
    found.sort();
    return found;
  }

  /// 按类型自动识别：kind = novel / video / music / comic。
  /// 返回 {扩展名: [路径…]} 的分组结果，供 UI 分组展示。
  static Future<Map<String, List<String>>> autoScan(String kind, String root,
      {void Function(int found)? onProgress}) async {
    final exts = switch (kind) {
      'novel' => MediaFormats.novelExts,
      'video' => MediaFormats.videoExts,
      'music' => MediaFormats.audioExts,
      'comic' => MediaFormats.comicExts,
      _ => MediaFormats.novelExts,
    };
    final paths = await scan(root, exts, onProgress: onProgress);
    final groups = <String, List<String>>{};
    for (final p in paths) {
      final ext = p.split('.').last.toLowerCase();
      (groups[ext] ??= []).add(p);
    }
    return groups;
  }

  /// 从给定路径导入小说（自动识别的结果走这里，与手动选择共用解析逻辑）。
  static Future<int> importNovelPaths(List<String> paths) async {
    lastErrors.clear();
    final dir = await _dir('novel');
    final items = await list('novel');
    var n = 0;
    for (final pth in paths) {
      final src = File(pth);
      if (!src.existsSync()) continue;
      final name = pth.split(RegExp(r'[/\\]')).last;
      final ext = name.split('.').last.toLowerCase();
      final stem = name.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
      final dst = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
      if (const {'epub', 'fb2', 'html', 'htm', 'xhtml', 'rtf'}.contains(ext)) {
        try {
          final bytes = await src.readAsBytes();
          final text = ext == 'epub' ? epubToText(bytes) : MediaFormats.bookToText(bytes, ext);
          if (text == null || text.trim().isEmpty) {
            lastErrors.add('$name: 没能解析出正文(文件可能损坏或加密)');
            continue;
          }
          final out = File('${dst.path}.txt');
          await out.writeAsString(text);
          items.add({'name': stem, 'path': out.path, 'format': ext, 'size': text.length});
          n++;
        } catch (e) {
          lastErrors.add('$name: 解析失败($e)');
        }
      } else {
        try {
          await src.copy(dst.path);
          items.add({'name': stem, 'path': dst.path, 'format': ext});
          n++;
        } catch (e) {
          lastErrors.add('$name: $e');
        }
      }
      await Future.delayed(const Duration(milliseconds: 1)); // 让出事件循环，别卡 UI
    }
    await _save('novel', items);
    return n;
  }

  /// 从给定路径导入媒体（视频/音乐），与手动选择共用拷贝逻辑。
  static Future<int> importMediaPaths(String kind, List<String> paths) async {
    lastErrors.clear();
    final dir = await _dir(kind);
    final items = await list(kind);
    var n = 0;
    for (final pth in paths) {
      try {
        final src = File(pth);
        if (!src.existsSync()) continue;
        final name = pth.split(RegExp(r'[/\\]')).last;
        final dst = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
        await src.copy(dst.path);
        items.add({'name': name, 'path': dst.path});
        n++;
      } catch (e) {
        lastErrors.add('$pth: $e');
      }
      await Future.delayed(const Duration(milliseconds: 1));
    }
    await _save(kind, items);
    return n;
  }
}
