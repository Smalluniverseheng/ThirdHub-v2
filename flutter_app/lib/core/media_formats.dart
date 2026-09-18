// 本地媒体的格式支持层：字幕解析 + 电子书文本提取 + 各类型可导扩展名。
//
// 为什么自己写而不用第三方包：
//  * 字幕库（subtitle_wrapper 之类）大多年久失修、和新版 Flutter 的构建链打架，
//    而 srt/vtt/ass 的解析本身只有百来行，自己写反而可控、能按需容错；
//  * fb2 本来就是 XML、rtf 的正文也只是控制字 + 文本，剥离规则简单。
// 零新依赖 = 构建链不会因某个包停更而炸。

import 'dart:convert';

/// 一条字幕。
class Cue {
  const Cue({required this.start, required this.end, required this.text});

  final Duration start;
  final Duration end;
  final String text;

  bool covers(Duration d) => d >= start && d < end;

  @override
  String toString() => 'Cue(${start.inMilliseconds}->${end.inMilliseconds}) $text';
}

class MediaFormats {
  MediaFormats._();

  // ── 可导入扩展名（集中一处，方便两端复用） ──
  static const List<String> novelExts = <String>[
    'txt', 'epub', 'umd', 'md', 'markdown',
    'fb2', 'html', 'htm', 'xhtml', 'rtf', 'text',
  ];
  static const List<String> videoExts = <String>[
    'mp4', 'mkv', 'avi', 'mov', 'flv', 'wmv', 'webm', 'ts', 'm2ts', 'mts',
    'm3u8', 'mpg', 'mpeg', 'vob', 'rmvb', 'rm', '3gp', 'ogv', 'divx', 'f4v',
  ];
  static const List<String> audioExts = <String>[
    'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'oga', 'opus', 'wma', 'ape',
    'alac', 'aiff', 'aif', 'amr', 'mka', 'mid', 'midi', 'ac3', 'dts',
  ];
  /// 漫画：图片格式 + ZIP 系压缩包。
  ///
  /// 刻意不含 cbr/rar/7z —— 本机压缩库解不了 RAR/7z，列进去只会让用户
  /// 选完文件再失败。这类包请先解压成图片，[comicNeedUnpackExts] 用于给出提示。
  static const List<String> comicExts = <String>[
    'zip', 'cbz',
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif', 'heic',
  ];

  /// 能被识别但不支持直接解包的压缩包（给出可读的失败原因）。
  static const List<String> comicNeedUnpackExts = <String>['cbr', 'rar', '7z', 'tar'];
  static const List<String> subExts = <String>[
    'srt', 'vtt', 'ass', 'ssa', 'sub', 'smi', 'lrc', 'txt',
  ];

  // ── 字幕 ──

  /// 按扩展名分派解析。识别不了就返回空表（播放器按"无字幕"处理，不报错）。
  static List<Cue> parseSubtitle(String content, String ext) {
    final String e = ext.toLowerCase();
    switch (e) {
      case 'ass':
      case 'ssa':
        return parseAss(content);
      case 'vtt':
        return parseVtt(content);
      case 'srt':
      case 'sub':
      case 'smi':
        return parseSrt(content);
      default:
        // 内容嗅探兜底
        if (content.contains('WEBVTT')) return parseVtt(content);
        if (content.contains('[Events]') || content.contains('Dialogue:')) {
          return parseAss(content);
        }
        return parseSrt(content);
    }
  }

  /// SRT：块之间空行分隔，第二行是 `HH:MM:SS,mmm --> HH:MM:SS,mmm`。
  static List<Cue> parseSrt(String src) {
    final List<Cue> out = <Cue>[];
    final String text = src.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (final String block in text.split(RegExp(r'\n\s*\n'))) {
      final List<String> lines = block
          .split('\n')
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;
      // 找时间行（有些字幕首行是序号，有些没有）
      int ti = -1;
      for (int i = 0; i < lines.length && i < 3; i++) {
        if (lines[i].contains('-->')) {
          ti = i;
          break;
        }
      }
      if (ti < 0) continue;
      final List<String> times = lines[ti].split('-->');
      if (times.length < 2) continue;
      final Duration? a = _time(times[0]);
      // 必须先去空格再切：`--> 00:00:02,000` 里箭头后有个空格，
      // 直接 split(RegExp(r'\s')).first 会拿到空串，整条字幕就被丢掉了。
      final Duration? b = _time(times[1].trim().split(RegExp(r'\s+')).first);
      if (a == null || b == null) continue;
      final String body = lines.sublist(ti + 1).join('\n');
      if (body.isEmpty) continue;
      out.add(Cue(start: a, end: b, text: body));
    }
    out.sort((Cue x, Cue y) => x.start.compareTo(y.start));
    return out;
  }

  /// VTT：带 `WEBVTT` 头、时间用 `.` 分隔毫秒、可能带 cue 设置与 NOTE 块。
  static List<Cue> parseVtt(String src) {
    final List<Cue> out = <Cue>[];
    String text = src.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.startsWith('\u{FEFF}')) text = text.substring(1);
    for (final String block in text.split(RegExp(r'\n\s*\n'))) {
      final List<String> lines = block
          .split('\n')
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;
      // 没有时间轴的行（WEBVTT 头、NOTE/STYLE/REGION 块、纯序号）一律跳过
      final int ti = lines.indexWhere((String l) => l.contains('-->'));
      if (ti < 0) continue;
      final List<String> times = lines[ti].split('-->');
      if (times.length < 2) continue;
      final Duration? a = _time(times[0]);
      // 同 srt：VTT 时间行后面还可能跟 align:/position: 等 cue 设置
      final Duration? b = _time(times[1].trim().split(RegExp(r'\s+')).first);
      if (a == null || b == null) continue;
      final String body = lines
          .sublist(ti + 1)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]+>'), '') // 去 <c>/<v> 等内联标签
          .trim();
      if (body.isEmpty) continue;
      out.add(Cue(start: a, end: b, text: body));
    }
    out.sort((Cue x, Cue y) => x.start.compareTo(y.start));
    return out;
  }

  /// ASS/SSA：只取 `[Events]` 里的 `Dialogue:`，按 `Format:` 声明的字段顺序取值。
  static List<Cue> parseAss(String src) {
    final List<Cue> out = <Cue>[];
    final String text = src.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    bool inEvents = false;
    List<String> fields = <String>[];
    for (final String raw in text.split('\n')) {
      final String line = raw.trim();
      if (line.startsWith('[')) {
        inEvents = line.toLowerCase() == '[events]';
        continue;
      }
      if (!inEvents) continue;
      if (line.toLowerCase().startsWith('format:')) {
        fields = line
            .substring(line.indexOf(':') + 1)
            .split(',')
            .map((String s) => s.trim().toLowerCase())
            .toList();
        continue;
      }
      if (!line.toLowerCase().startsWith('dialogue:')) continue;
      // Dialogue: 后面的内容按逗号切，但第 10 个字段（Text）里可能含逗号
      final String payload = line.substring(line.indexOf(':') + 1);
      final int textIdx = fields.indexOf('text');
      final List<String> parts = payload.split(',');
      final int keep = textIdx >= 0 ? textIdx : 9;
      if (parts.length <= keep) continue;
      final List<String> head = parts.sublist(0, keep);
      final String body = parts.sublist(keep).join(',');
      String get(String name) {
        final int i = fields.indexOf(name);
        return (i >= 0 && i < head.length) ? head[i].trim() : '';
      }
      final Duration? a = _time(fields.isEmpty ? head[1] : get('start'));
      final Duration? b = _time(fields.isEmpty ? head[2] : get('end'));
      if (a == null || b == null) continue;
      final String clean = _stripAssTags(body);
      if (clean.isEmpty) continue;
      out.add(Cue(start: a, end: b, text: clean));
    }
    out.sort((Cue x, Cue y) => x.start.compareTo(y.start));
    return out;
  }

  /// 去 ASS 的 `{...}` 覆写标签，并把 `\N` `\n` 变成换行。
  static String _stripAssTags(String s) => s
      .replaceAll(RegExp(r'\{[^}]*\}'), '')
      .replaceAll(RegExp(r'\\[Nn]'), '\n')
      .replaceAll(RegExp(r'\\h'), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .trim();

  /// 宽松时间解析：支持 `00:00:01,000` / `00:00:01.000` / `0:00:01.00` / `00:01.000`。
  static Duration? _time(String raw) {
    String s = raw.trim();
    if (s.isEmpty) return null;
    s = s.replaceAll(',', '.');
    final List<String> seg = s.split(':');
    if (seg.length > 3) return null;
    double sec = 0;
    if (seg.length == 3) {
      final int? h = int.tryParse(seg[0].trim());
      final int? m = int.tryParse(seg[1].trim());
      final double? ss = double.tryParse(seg[2].trim());
      if (h == null || m == null || ss == null) return null;
      sec = h * 3600 + m * 60 + ss;
    } else if (seg.length == 2) {
      final int? m = int.tryParse(seg[0].trim());
      final double? ss = double.tryParse(seg[1].trim());
      if (m == null || ss == null) return null;
      sec = m * 60 + ss;
    } else {
      final double? ss = double.tryParse(seg[0].trim());
      if (ss == null) return null;
      sec = ss;
    }
    if (sec.isNaN || sec.isInfinite) return null;
    return Duration(milliseconds: (sec * 1000).round());
  }

  // ── 电子书文本提取 ──

  /// 把非纯文本格式的电子书正文抽成纯文本。识别不了返回 null。
  static String? bookToText(List<int> bytes, String ext) {
    final String e = ext.toLowerCase();
    try {
      switch (e) {
        case 'fb2':
          return fb2ToText(decodeBook(bytes));
        case 'html':
        case 'htm':
        case 'xhtml':
          return htmlToText(decodeBook(bytes));
        case 'rtf':
          return rtfToText(decodeBook(bytes));
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// 电子书文本解码：优先 UTF-8，失败退到 latin1（html/fb2/rtf 多为 UTF-8）。
  static String decodeBook(List<int> bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      try {
        return utf8.decode(bytes.sublist(3));
      } catch (_) {}
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {}
    // 按声明编码兜底：XML/HTML 头里常写 charset
    final String head = latin1.decode(bytes.length > 2048 ? bytes.sublist(0, 2048) : bytes);
    final RegExpMatch? m = RegExp(r'encoding="([\w-]+)"', caseSensitive: false).firstMatch(head);
    final String enc = (m?.group(1) ?? '').toLowerCase();
    if (enc.contains('1251') || enc.contains('koi8')) {
      // 西里尔文：latin1 至少不会崩，中文书极少遇到
      return latin1.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// HTML/XHTML → 纯文本：按块级标签断行，去脚本样式，解实体。
  static String htmlToText(String html) {
    String s = html
        .replaceAll(RegExp(r'<(script|style|head)[\s\S]*?</\1>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(
        RegExp(r'</(p|div|h[1-6]|li|tr|section|article|blockquote|pre)\s*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    return _tidy(_entities(s));
  }

  /// FB2（XML）→ 纯文本：取 `<body>` 内的段落与标题，跳过 `<binary>` 里的 base64 图片。
  static String fb2ToText(String xml) {
    final StringBuffer buf = StringBuffer();
    final RegExp bodyRe = RegExp(r'<body[\s\S]*?</body>', caseSensitive: false);
    final Match? body = bodyRe.firstMatch(xml);
    String src = body?.group(0) ?? xml;
    // <binary> 是封面 base64，必须整块删掉，否则会被当成正文塞进来
    src = src.replaceAll(RegExp(r'<binary[\s\S]*?</binary>', caseSensitive: false), '');
    // 标题/段落逐个取出，保留段落边界
    final RegExp blk = RegExp(
      r'<(title|p|subtitle|epigraph|poem|stanza|v|empty-line)[^>]*>([\s\S]*?)</\1>',
      caseSensitive: false,
    );
    for (final RegExpMatch m in blk.allMatches(src)) {
      final String tag = (m.group(1) ?? '').toLowerCase();
      final String inner = m.group(2) ?? '';
      final String text = _tidy(_entities(inner.replaceAll(RegExp(r'<[^>]+>'), ' ')));
      if (text.isEmpty) continue;
      if (tag == 'empty-line') {
        buf.writeln();
      } else {
        buf.writeln(text);
        buf.writeln();
      }
    }
    if (buf.isEmpty) {
      // 结构不规范时退回"全去标签"
      return htmlToText(src);
    }
    return buf.toString();
  }

  /// RTF → 纯文本：删组、解 `\'xx` 转义、丢控制字、把 `\par` 换成换行。
  static String rtfToText(String rtf) {
    String s = rtf;
    // 丢掉目标/字体/颜色/样式等元数据组（含嵌套）
    s = s.replaceAll(RegExp(r'\{\\\*[\s\S]*?\}'), '');
    s = s.replaceAll(RegExp(r'\{\\(fonttbl|colortbl|stylesheet|info|pict|header|footer)[\s\S]*?\}'), '');
    // \uN? → 对应码点
    s = s.replaceAllMapped(RegExp(r"\\u(-?\d+)\s?\??"), (Match m) {
      final int? n = int.tryParse(m.group(1)!);
      if (n == null) return '';
      final int cp = n < 0 ? n + 65536 : n;
      return String.fromCharCode(cp);
    });
    // \'xx → 该字节（按 cp1252 近似；中文 RTF 一般走 \uN，这里够用）
    s = s.replaceAllMapped(RegExp(r"\\'([0-9a-fA-F]{2})"), (Match m) {
      final int b = int.parse(m.group(1)!, radix: 16);
      return String.fromCharCode(b);
    });
    s = s.replaceAll(RegExp(r'\\par[d]?\b'), '\n');
    s = s.replaceAll(RegExp(r'\\line\b'), '\n');
    s = s.replaceAll(RegExp(r'\\tab\b'), '    ');
    s = s.replaceAll(RegExp(r'\\[a-zA-Z]+-?\d*\s?'), '');
    s = s.replaceAll(RegExp(r'\\[^a-zA-Z]'), '');
    s = s.replaceAll('{', '').replaceAll('}', '');
    return _tidy(s);
  }

  /// 常见 HTML/XML 实体还原 + 数字实体。
  static String _entities(String s) {
    String out = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '…')
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’');
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (Match m) {
      final int? c = int.tryParse(m.group(1)!, radix: 16);
      return c == null ? '' : String.fromCharCode(c);
    });
    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (Match m) {
      final int? c = int.tryParse(m.group(1)!);
      return c == null ? '' : String.fromCharCode(c);
    });
    return out;
  }

  /// 压掉多余空行与行首尾空白，保留单空行分段。
  static String _tidy(String s) {
    final List<String> lines = s
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u{00A0}', ' ')
        .split('\n')
        .map((String l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .toList();
    final StringBuffer buf = StringBuffer();
    bool blank = true;
    for (final String l in lines) {
      if (l.isEmpty) {
        if (!blank) {
          buf.writeln();
          blank = true;
        }
      } else {
        buf.writeln(l);
        blank = false;
      }
    }
    return buf.toString().trim();
  }
}
