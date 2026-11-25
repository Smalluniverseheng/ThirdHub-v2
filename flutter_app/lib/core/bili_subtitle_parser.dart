// B站字幕三态解析（json / srt / ass）—— 纯 Dart，零 Flutter 依赖，
// 可被 `dart run tool/subtitle_selfcheck.dart` 直接跑自检。
//
// 统一吐出 cue：{t0:秒, t1:秒, x:文本}。三种来源在 UI 上是一条时间轴。
import 'dart:convert';

/// 一条字幕：t0 起、t1 止（秒），x 文本（可含 \n）。
Map<String, dynamic> subCue(double t0, double t1, String x) =>
    <String, dynamic>{'t0': t0, 't1': t1, 'x': x};

/// 解析字幕体，自动嗅探格式（也可由 [hint] 指定 json/srt/ass）。
List<Map<String, dynamic>> parseSubtitle(String raw, {String hint = ''}) {
  final s = raw.trim();
  if (s.isEmpty) return const [];
  var fmt = hint.toLowerCase();
  if (fmt.isEmpty) {
    // ★先认 ASS 特征：ASS 以 `[Script Info]`/`[Events]` 开头，会被 json 的
    //   startsWith('[') 误判 —— 必须先按内容特征判定，再看起始字符。
    if (s.contains('Dialogue:') || s.contains('[Events]')) {
      fmt = 'ass';
    } else if (s.contains('-->')) {
      fmt = 'srt';
    } else if (s.startsWith('{') || s.startsWith('[')) {
      fmt = 'json';
    } else {
      fmt = 'json';
    }
  }
  late final List<Map<String, dynamic>> out;
  switch (fmt) {
    case 'srt':
      out = _parseSrt(s);
      break;
    case 'ass':
      out = _parseAss(s);
      break;
    default:
      out = _parseJson(s);
  }
  out.sort((a, b) => (a['t0'] as double).compareTo(b['t0'] as double));
  return out;
}

double _asSec(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim()) ?? 0.0;
  return 0.0;
}

List<Map<String, dynamic>> _parseJson(String s) {
  final out = <Map<String, dynamic>>[];
  Object? decoded;
  try {
    decoded = jsonDecode(s);
  } catch (_) {
    return out;
  }
  Object? body = decoded;
  if (decoded is Map) {
    body = decoded['body'] ??
        (decoded['data'] is Map ? (decoded['data'] as Map)['body'] : null) ??
        decoded['subtitles'];
  }
  if (body is! List) return out;
  for (final e in body.whereType<Map>()) {
    final t0 = _asSec(e['from'] ?? e['start'] ?? e['t0']);
    final t1 = _asSec(e['to'] ?? e['end'] ?? e['t1']);
    final x = '${e['content'] ?? e['text'] ?? e['x'] ?? ''}'
        .replaceAll('\\n', '\n')
        .trim();
    if (x.isEmpty) continue;
    out.add(subCue(t0, t1 <= t0 ? t0 + 2 : t1, x));
  }
  return out;
}

/// 解析 `00:00:01,500` / `00:01:02.500` / `01:02,5` / `1:02.3` → 秒
double _clock(String s) {
  final t = s.trim().replaceAll(',', '.');
  final parts = t.split(':');
  var sec = 0.0;
  for (final p in parts) {
    sec = sec * 60 + (double.tryParse(p) ?? 0);
  }
  return sec;
}

List<Map<String, dynamic>> _parseSrt(String s) {
  final out = <Map<String, dynamic>>[];
  final blocks = s.split(RegExp(r'\n\s*\n'));
  final arrow = RegExp(r'(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})'
      r'\s*-->\s*'
      r'(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}|\d{1,2}:\d{2}[,.]\d{1,3})');
  for (final b in blocks) {
    final m = arrow.firstMatch(b);
    if (m == null) continue;
    final t0 = _clock(m.group(1) ?? '0');
    final t1 = _clock(m.group(2) ?? '0');
    final tail = b.substring(m.end).trimLeft();
    final lines = tail.split(RegExp(r'\r?\n'))
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.trim())
        .toList();
    if (lines.isEmpty) continue;
    out.add(subCue(t0, t1 <= t0 ? t0 + 2 : t1, lines.join('\n')));
  }
  return out;
}

List<Map<String, dynamic>> _parseAss(String s) {
  final out = <Map<String, dynamic>>[];
  List<String>? cols;
  for (final line in s.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.startsWith('Format:')) {
      cols = t.substring(7).split(',').map((e) => e.trim().toLowerCase()).toList();
    } else if (t.startsWith('Dialogue:')) {
      final vals = t.substring(9).split(',');
      final iStart = cols?.indexOf('start') ?? 1;
      final iEnd = cols?.indexOf('end') ?? 2;
      final iText = cols?.indexOf('text') ?? 9;
      String pick(int i) => (i >= 0 && i < vals.length) ? vals[i].trim() : '';
      final t0 = _clock(pick(iStart));
      final t1 = _clock(pick(iEnd));
      final text = vals.skip(iText < 0 ? 9 : iText).join(',').trim();
      if (text.isEmpty) continue;
      out.add(subCue(t0, t1 <= t0 ? t0 + 2 : t1, text));
    }
  }
  return out;
}

/// 字幕轨（来自 B站 subtitles[] 或后端转出）。
class SubTrack {
  const SubTrack({
    required this.lan,
    required this.label,
    required this.cues,
    this.url = '',
  });

  final String lan;
  final String label;
  final List<Map<String, dynamic>> cues;
  final String url;

  bool get isEmpty => cues.isEmpty;
}

/// 时间轴命中：返回 [pos] 所在的 cue（含边界），否则 null。cues 按 t0 升序。
Map<String, dynamic>? cueAt(List<Map<String, dynamic>> cues, double pos) {
  if (cues.isEmpty) return null;
  var lo = 0, hi = cues.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final c = cues[mid];
    final t0 = c['t0'] as double;
    final t1 = c['t1'] as double;
    if (pos < t0) {
      hi = mid - 1;
    } else if (pos > t1) {
      lo = mid + 1;
    } else {
      return c;
    }
  }
  return null;
}
