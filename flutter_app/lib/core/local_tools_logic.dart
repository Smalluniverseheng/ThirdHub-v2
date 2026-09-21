// 本地能力工具箱（TH-LocalTools v2 的纯逻辑内核）。
//
// ★ 本文件刻意**零依赖**（只用 dart:core / dart:convert / dart:math），
//   因此：① 可以用纯 Dart VM 跑自检；② 在没有后端、没有网络、没有 DSH 的
//   情况下依然 100% 可用 —— 这就是"前端不该因为没连后端就变成废物"的落点。
//
// 与 local_tools.dart 的分工：
//   · 本文件 = 算法/解析/格式化（可自检，跨端复用）
//   · local_tools.dart = 需要 Flutter 插件的能力（文件/剪贴板/分享/TTS）
library;

import 'dart:convert';
import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────
// 0. 上下文快照（零依赖载体）
// ─────────────────────────────────────────────────────────────────────────

/// 当前上下文的**同步**快照：用户在哪、什么状态、能做什么。
///
/// 为什么要有它：prompt 的构建是同步的，而"取上下文"（问后端状态、数笔记条数）
/// 是异步的。所以由前端在状态变化时把结果写进来，构建 prompt 时直接读。
///
/// 为什么放在这个**零依赖**文件里：ai_agent.dart 需要它来注入 system prompt，
/// 而 local_tools.dart 已经 import 了 ai.dart；把载体放这里就避免了
/// `ai_agent → local_tools → ai → ai_agent` 的循环 import。
class LocalContextSnapshot {
  static String text = '';

  static void set(String v) => text = v;
  static void clear() => text = '';
  static bool get has => text.isNotEmpty;
}

// ─────────────────────────────────────────────────────────────────────────
// 1. 表达式计算（安全求值，不用 eval）
// ─────────────────────────────────────────────────────────────────────────
//
// 语法：+ - * / ^ 括号 一元正负 百分比后缀
//   · `%` 是**后缀百分比**（`20%` → 0.2），不是取模 —— 日常算"350 的 20%"更常用
//   · `^` 右结合（`2^3^2` = 2^9）
//   · 非法表达式一律返回 null，绝不抛异常
class LocalCalc {
  /// 求值。无法解析 / 结果为 NaN 或无穷 → null。
  static double? eval(String src) {
    if (src.trim().isEmpty) return null;
    final p = _CalcParser(src);
    final v = p.parseExpr();
    if (v == null) return null;
    p.skipWs();
    if (p.pos != src.length) return null; // 有剩余字符 → 表达式非法
    if (v.isNaN || v.isInfinite) return null;
    return v;
  }

  /// 人类可读的数字格式化：整数不带小数点，小数去掉末尾 0。
  static String fmt(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    var s = v.toStringAsFixed(10);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 求值并格式化；失败返回 null。
  static String? calc(String src) {
    final v = eval(src);
    return v == null ? null : fmt(v);
  }
}

class _CalcParser {
  _CalcParser(this.src);
  final String src;
  int pos = 0;

  static final RegExp _numChars = RegExp(r'[0-9]');
  static final RegExp _eChars = RegExp(r'[eE]');

  void skipWs() {
    while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n')) {
      pos++;
    }
  }

  bool eat(String ch) {
    skipWs();
    if (pos < src.length && src[pos] == ch) { pos++; return true; }
    return false;
  }

  /// expr := term (('+' | '-') term)*
  double? parseExpr() {
    var left = parseTerm();
    if (left == null) return null;
    for (;;) {
      skipWs();
      if (eat('+')) {
        final r = parseTerm();
        if (r == null) return null;
        left = left! + r;
      } else if (eat('-')) {
        final r = parseTerm();
        if (r == null) return null;
        left = left! - r;
      } else {
        return left;
      }
    }
  }

  /// term := unary (('*' | '/') unary)*
  double? parseTerm() {
    var left = parseUnary();
    if (left == null) return null;
    for (;;) {
      skipWs();
      if (eat('*')) {
        final r = parseUnary();
        if (r == null) return null;
        left = left! * r;
      } else if (eat('/')) {
        final r = parseUnary();
        if (r == null || r == 0) return null; // 除零 → 非法
        left = left! / r;
      } else {
        return left;
      }
    }
  }

  /// unary := ('-' | '+') unary | power
  double? parseUnary() {
    skipWs();
    if (eat('-')) { final v = parseUnary(); return v == null ? null : -v; }
    if (eat('+')) return parseUnary();
    return parsePower();
  }

  /// power := primary ('^' unary)?   —— 右结合
  double? parsePower() {
    final b = parsePrimary();
    if (b == null) return null;
    skipWs();
    if (eat('^')) {
      final e = parseUnary();
      if (e == null) return null;
      return math.pow(b, e).toDouble();
    }
    return b;
  }

  /// primary := '(' expr ')' | number   后接可选的 '%'
  double? parsePrimary() {
    skipWs();
    if (eat('(')) {
      final v = parseExpr();
      if (v == null) return null;
      if (!eat(')')) return null;
      return _pct(v);
    }
    final start = pos;
    while (pos < src.length) {
      final c = src[pos];
      if (_numChars.hasMatch(c) || c == '.' || _eChars.hasMatch(c)) {
        // 科学计数法的符号位：1e-5
        if (_eChars.hasMatch(c) && pos + 1 < src.length && (src[pos + 1] == '+' || src[pos + 1] == '-')) {
          pos += 2;
          continue;
        }
        pos++;
        continue;
      }
      break;
    }
    if (pos == start) return null;
    final n = double.tryParse(src.substring(start, pos));
    if (n == null) return null;
    return _pct(n);
  }

  /// 可选的百分比后缀。
  double _pct(double v) {
    skipWs();
    if (pos < src.length && src[pos] == '%') { pos++; return v / 100.0; }
    return v;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 2. 文本统计
// ─────────────────────────────────────────────────────────────────────────
class TextStats {
  static final RegExp _cjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]');
  static final RegExp _latin = RegExp(r'[A-Za-z]');
  static final RegExp _digit = RegExp(r'[0-9]');
  static final RegExp _space = RegExp(r'\s');

  /// 一次算出常用的几个口径。空串返回全 0（不是 1 行）。
  static Map<String, int> of(String s) {
    final lines = s.isEmpty ? const <String>[] : s.split('\n');
    final words = RegExp(r"[A-Za-z0-9']+").allMatches(s).length;
    final sentences = s.split(RegExp(r'[。！？!?.;；]+')).where((x) => x.trim().isNotEmpty).length;
    return {
      'chars': s.length,
      'charsNoSpace': s.replaceAll(_space, '').length,
      'cjk': _cjk.allMatches(s).length,
      'latin': _latin.allMatches(s).length,
      'digits': _digit.allMatches(s).length,
      'lines': lines.length,
      'nonEmptyLines': lines.where((l) => l.trim().isNotEmpty).length,
      'words': words,
      'sentences': sentences,
    };
  }

  /// 词频前 [n] 名（英文词 + 中文按 2 字滑窗），用于快速看一段文本在讲什么。
  static List<MapEntry<String, int>> topWords(String s, {int n = 10, int gram = 2}) {
    final count = <String, int>{};
    for (final m in RegExp(r"[A-Za-z0-9']+").allMatches(s)) {
      final w = m.group(0)!.toLowerCase();
      if (w.length < 2) continue;
      count[w] = (count[w] ?? 0) + 1;
    }
    final cjkRun = StringBuffer();
    void flush() {
      final t = cjkRun.toString();
      cjkRun.clear();
      if (gram <= 0 || t.length < gram) return;
      for (var i = 0; i + gram <= t.length; i++) {
        final g = t.substring(i, i + gram);
        count[g] = (count[g] ?? 0) + 1;
      }
    }
    for (final ch in s.split('')) {
      if (_cjk.hasMatch(ch)) { cjkRun.write(ch); } else { flush(); }
    }
    flush();
    final list = count.entries.toList()..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return list.take(n).toList();
  }

  /// 最长的一行（返回 行号(1 起) 与内容），空文本返回 null。
  static (int, String)? longestLine(String s) {
    if (s.isEmpty) return null;
    final lines = s.split('\n');
    var bi = 0;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].length > lines[bi].length) bi = i;
    }
    return (bi + 1, lines[bi]);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 3. JSON
// ─────────────────────────────────────────────────────────────────────────
class JsonTool {
  /// 美化。非法 JSON → null。
  static String? pretty(String s, {int indent = 2}) {
    final o = parse(s);
    if (o == null) return null;
    if (indent <= 0) return jsonEncode(o);
    return const JsonEncoder.withIndent('  ').convert(o);
  }

  /// 压缩成一行。
  static String? minify(String s) {
    final o = parse(s);
    return o == null ? null : jsonEncode(o);
  }

  /// 解析成功返回对象，失败返回 null（不抛）。
  static Object? parse(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    try { return jsonDecode(t); } catch (_) { return null; }
  }

  static bool valid(String s) => parse(s) != null;

  /// 按点号路径取值：`a.b.0.c`。取不到返回 null。
  static Object? at(String s, String dotPath) {
    Object? cur = parse(s);
    if (cur == null) return null;
    for (final seg in dotPath.split('.')) {
      if (seg.isEmpty) continue;
      if (cur is Map) {
        if (!cur.containsKey(seg)) return null;
        cur = cur[seg];
      } else if (cur is List) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= cur.length) return null;
        cur = cur[i];
      } else {
        return null;
      }
    }
    return cur;
  }

  /// 键路径清单（浅层，用于"这坨 JSON 里有什么"）。
  static List<String> keys(String s, {int depth = 2}) => _keys(parse(s), '', depth);

  static List<String> _keys(Object? o, String prefix, int depth) {
    final out = <String>[];
    if (depth <= 0) return out;
    if (o is Map) {
      for (final e in o.entries) {
        final p = prefix.isEmpty ? '${e.key}' : '$prefix.${e.key}';
        out.add(p);
        out.addAll(_keys(e.value, p, depth - 1));
      }
    } else if (o is List && o.isNotEmpty) {
      for (var i = 0; i < o.length && i < 3; i++) {
        out.addAll(_keys(o[i], prefix.isEmpty ? '$i' : '$prefix.$i', depth - 1));
      }
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 4. 编解码
// ─────────────────────────────────────────────────────────────────────────
class Codec {
  static String b64e(String s) => base64.encode(utf8.encode(s));

  /// Base64 解码（自动兼容 URL-safe 与缺省 padding）。失败 → null。
  static String? b64d(String s) {
    var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
    // 空串是合法的 Base64（空字节串），要能原样往返，不能当非法输入
    if (t.isEmpty) return '';
    final pad = t.length % 4;
    if (pad == 2) { t += '=='; } else if (pad == 3) { t += '='; } else if (pad == 1) { return null; }
    try { return utf8.decode(base64.decode(t)); } catch (_) { return null; }
  }

  static String urlE(String s) => Uri.encodeComponent(s);

  /// URL 解码；非法百分号转义 → null（Uri.decodeComponent 会抛）。
  static String? urlD(String s) {
    try { return Uri.decodeComponent(s); } catch (_) { return null; }
  }

  static String hexE(String s) =>
      utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 十六进制还原；奇数长度或非法字符 → null。
  static String? hexD(String s) {
    final t = s.replaceAll(RegExp(r'\s'), '');
    if (t.isEmpty || t.length.isOdd) return null;
    final bytes = <int>[];
    for (var i = 0; i < t.length; i += 2) {
      final b = int.tryParse(t.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      bytes.add(b);
    }
    try { return utf8.decode(bytes); } catch (_) { return null; }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 5. 摘要（不引第三方库；用于去重/短指纹，不是密码学安全摘要）
// ─────────────────────────────────────────────────────────────────────────
class Hashing {
  /// FNV-1a 32 位，8 位十六进制。
  static String fnv1a32(String s) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// FNV-1a 64 位（用 BigInt 保证不溢出），16 位十六进制。
  static String fnv1a64(String s) {
    final mask = (BigInt.one << 64) - BigInt.one;
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    for (final b in utf8.encode(s)) {
      h = h ^ BigInt.from(b);
      h = (h * prime) & mask;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 6. ID 生成
// ─────────────────────────────────────────────────────────────────────────
//
// ★ 教训：本项目曾用「纯毫秒时间戳」做 id，Windows 上毫秒粒度 → 同毫秒连续
//   调用产生完全相同的 id（AI 记忆连 add 三条时丢数据）。所以这里加**自增序号**兜底。
class IdGen {
  static int _seq = 0;
  static int get seq => _seq;

  /// 形如 `note-mabc123-001`：时间基（36 进制）+ 自增序 + 随机尾。
  static String next(String prefix, {int randomBits = 4}) {
    _seq++;
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final s = _seq.toRadixString(36).padLeft(3, '0');
    final r = randomBits <= 0 ? '' : '-${_randHex(randomBits)}';
    return '$prefix-$t-$s$r';
  }

  static String _randHex(int n) {
    final chars = List.generate(n, (_) => _rnd.nextInt(16).toRadixString(16));
    return chars.join();
  }

  static final math.Random _rnd = math.Random();
  static void reset() => _seq = 0;
}

// ─────────────────────────────────────────────────────────────────────────
// 7. 时间
// ─────────────────────────────────────────────────────────────────────────
class TimeTool {
  static String _p2(int v) => v.toString().padLeft(2, '0');

  static String ymd(DateTime t) => '${t.year}-${_p2(t.month)}-${_p2(t.day)}';

  static String hms(DateTime t) => '${_p2(t.hour)}:${_p2(t.minute)}:${_p2(t.second)}';

  static String full(DateTime t) => '${ymd(t)} ${hms(t)}';

  /// 相对时间：「刚刚 / N 分钟前 / N 小时前 / N 天前 / 具体日期」。
  static String rel(DateTime now, DateTime then) {
    final d = now.difference(then);
    if (d.isNegative) {
      final f = then.difference(now);
      if (f.inMinutes < 1) return '片刻后';
      if (f.inHours < 1) return '${f.inMinutes} 分钟后';
      if (f.inDays < 1) return '${f.inHours} 小时后';
      return '${f.inDays} 天后';
    }
    if (d.inSeconds < 60) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    if (d.inDays < 365) return '${d.inDays ~/ 30} 个月前';
    return '${d.inDays ~/ 365} 年前';
  }

  /// 毫秒时长 → 「1 天 2 小时 3 分 4 秒」（自动省略 0 段；全 0 → 「0 秒」）。
  static String dur(int ms) {
    if (ms < 0) ms = 0;
    final d = ms ~/ 86400000;
    final h = (ms % 86400000) ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final parts = <String>[];
    if (d > 0) parts.add('$d 天');
    if (h > 0) parts.add('$h 小时');
    if (m > 0) parts.add('$m 分');
    if (s > 0 || parts.isEmpty) parts.add('$s 秒');
    return parts.join(' ');
  }

  /// 秒数 → mm:ss 或 h:mm:ss（用于播放进度）。
  static String clock(int seconds) {
    if (seconds < 0) seconds = 0;
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
    return h > 0 ? '$h:${_p2(m)}:${_p2(s)}' : '${_p2(m)}:${_p2(s)}';
  }

  /// 时间戳（秒或毫秒，自动识别）→ DateTime（本地时区）。
  static DateTime? fromEpoch(num v) {
    if (v <= 0) return null;
    // 10 位以内当秒，超过当毫秒
    final ms = v < 100000000000 ? (v * 1000).round() : v.round();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 8. 单位换算
// ─────────────────────────────────────────────────────────────────────────
class UnitConv {
  static const Map<String, double> length = {
    'mm': 0.001, 'cm': 0.01, 'dm': 0.1, 'm': 1.0, 'km': 1000.0,
    'inch': 0.0254, 'ft': 0.3048, 'yard': 0.9144, 'mile': 1609.344,
    '里': 500.0, '尺': 1.0 / 3.0,
  };
  static const Map<String, double> mass = {
    'mg': 1e-6, 'g': 0.001, 'kg': 1.0, 't': 1000.0,
    'lb': 0.45359237, 'oz': 0.028349523125, '斤': 0.5, '两': 0.05,
  };
  static const Map<String, double> data = {
    'B': 1.0, 'KB': 1024.0, 'MB': 1048576.0, 'GB': 1073741824.0,
    'TB': 1099511627776.0, 'PB': 1125899906842624.0,
  };
  static const Map<String, double> area = {
    'm2': 1.0, 'km2': 1e6, 'cm2': 1e-4, 'ha': 10000.0,
    '亩': 2000.0 / 3.0, 'ft2': 0.09290304,
  };

  static const Map<String, Map<String, double>> all = {
    'length': length, 'mass': mass, 'data': data, 'area': area,
  };

  /// 换算。类别或单位不认识 → null。
  static double? convert(String category, String from, String to, double v) {
    if (category == 'temperature') return temperature(from, to, v);
    final table = all[category];
    if (table == null) return null;
    final f = table[from], t = table[to];
    if (f == null || t == null) return null;
    return v * f / t;
  }

  /// 温度：C 摄氏 / F 华氏 / K 开尔文。
  static double? temperature(String from, String to, double v) {
    const units = {'C', 'F', 'K'};
    if (!units.contains(from) || !units.contains(to)) return null;
    double c;
    switch (from) {
      case 'C': c = v; break;
      case 'F': c = (v - 32) * 5 / 9; break;
      default: c = v - 273.15; break;
    }
    switch (to) {
      case 'C': return c;
      case 'F': return c * 9 / 5 + 32;
      default: return c + 273.15;
    }
  }

  /// 存储换算 + 人类可读格式（1234 → 「1.21 KB」）。
  static String humanBytes(int bytes) {
    if (bytes < 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var v = bytes / 1024.0;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return '${v.toStringAsFixed(v >= 100 ? 0 : (v >= 10 ? 1 : 2))} ${units[i]}';
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 9. 正则
// ─────────────────────────────────────────────────────────────────────────
class RegexTool {
  /// 全部匹配（默认取第 0 组）。正则非法 → 空表。结果上限 [limit] 条。
  static List<String> all(String pattern, String input, {int group = 0, int limit = 100, bool caseSensitive = true}) {
    try {
      final re = RegExp(pattern, caseSensitive: caseSensitive);
      final out = <String>[];
      for (final m in re.allMatches(input)) {
        if (out.length >= limit) break;
        final g = group == 0 ? m.group(0) : m.group(group);
        if (g != null) out.add(g);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static String? first(String pattern, String input, {int group = 0, bool caseSensitive = true}) {
    final l = all(pattern, input, group: group, limit: 1, caseSensitive: caseSensitive);
    return l.isEmpty ? null : l.first;
  }

  static bool test(String pattern, String input, {bool caseSensitive = true}) {
    try { return RegExp(pattern, caseSensitive: caseSensitive).hasMatch(input); } catch (_) { return false; }
  }

  static String? replace(String pattern, String input, String with_, {bool caseSensitive = true, bool all = true}) {
    try {
      final re = RegExp(pattern, caseSensitive: caseSensitive);
      return all ? input.replaceAll(re, with_) : input.replaceFirst(re, with_);
    } catch (_) {
      return null;
    }
  }

  /// 正则是否合法 + 出的错（给用户看）。
  static (bool, String) check(String pattern) {
    try { RegExp(pattern); return (true, ''); } catch (e) { return (false, '$e'); }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 10. 文本差异（行级 LCS）
// ─────────────────────────────────────────────────────────────────────────
class TextDiffLine {
  /// same / add / del
  final String kind;
  final String text;
  const TextDiffLine(this.kind, this.text);
  @override String toString() => '$kind|$text';
}

class TextDiff {
  /// 超过这个行数不做 LCS（O(n·m) 会卡），退化成「整块替换」。
  static const int maxLines = 400;

  static List<String> splitLines(String s) => s.isEmpty ? const [] : s.split('\n');

  /// 行级差异。[a] 是旧文本、[b] 是新文本。
  static List<TextDiffLine> byLine(String a, String b) {
    final la = splitLines(a), lb = splitLines(b);
    if (la.length > maxLines || lb.length > maxLines) {
      // 退路：不做精细比对，别让 UI 卡住
      return [
        for (final l in la) TextDiffLine('del', l),
        for (final l in lb) TextDiffLine('add', l),
      ];
    }
    // LCS 动态规划
    final n = la.length, m = lb.length;
    final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        dp[i][j] = la[i] == lb[j] ? dp[i + 1][j + 1] + 1 : math.max(dp[i + 1][j], dp[i][j + 1]);
      }
    }
    final out = <TextDiffLine>[];
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (la[i] == lb[j]) { out.add(TextDiffLine('same', la[i])); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) { out.add(TextDiffLine('del', la[i])); i++; }
      else { out.add(TextDiffLine('add', lb[j])); j++; }
    }
    while (i < n) { out.add(TextDiffLine('del', la[i])); i++; }
    while (j < m) { out.add(TextDiffLine('add', lb[j])); j++; }
    return out;
  }

  /// 差异统计：新增行数、删除行数。
  static (int, int) stat(List<TextDiffLine> d) {
    var add = 0, del = 0;
    for (final l in d) {
      if (l.kind == 'add') add++;
      else if (l.kind == 'del') del++;
    }
    return (add, del);
  }

  /// 两段文本是否完全一致。
  static bool same(String a, String b) => a == b;

  /// 相似度（0~1）：相同行数 / 最大行数。
  static double similarity(String a, String b) {
    final la = splitLines(a), lb = splitLines(b);
    if (la.isEmpty && lb.isEmpty) return 1.0;
    final mx = math.max(la.length, lb.length);
    if (mx == 0) return 1.0;
    var sameCount = 0;
    for (final l in byLine(a, b)) { if (l.kind == 'same') sameCount++; }
    return sameCount / mx;
  }
}
