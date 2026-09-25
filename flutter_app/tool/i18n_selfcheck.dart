// i18n 字典完整性自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/i18n_selfcheck.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// 为什么必须有这条闸门：**缺键回退是静默的**。
//
// 查找链是 `dict[当前语言][k] ?? dict['en'][k] ?? k`（i18n.dart 的 tr()）。
// 也就是说：键在目标语言里没有 → 悄悄显示英文；目标语言和 en 都没有 → 悄悄
// 显示中文原文。**两种都不报错、不崩、不留日志**，只有用户切了语言才发现
// "怎么还是中文"。靠人眼在 200 个键 × 6 种语言里查，等于没查。
//
// 2026-09-25 实测：有 18 个键（含本轮刚从硬编码改成 tr() 的
// 「确认资源库指纹」「信任」）在**全部 6 种语言连 en 都缺** → 任何语言都显示
// 中文；ja 另缺 29 个键。已全部补齐，本自检把结论钉死，防止再退化。
//
// 为什么不直接 `import '../lib/core/i18n.dart'`：
//   i18n.dart 里有 `Widget segLabel(...) => Text(...)`，即**依赖 Flutter**；
//   而本仓 CI 跑的是 `dart run`（不是 `flutter test`）—— 导入会因
//   `package:flutter/material.dart` 拉进 dart:ui 而失败。所以这里把两个字典
//   文件当**文本**解析。副作用是它顺带成了"字典文件语法仍可被解析"的检查。
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

/// 语言列表必须与 I18n.supported 一致（zh 是原文，不作为字典块存在）。
const kLocales = ['en', 'ja', 'fr', 'ru', 'es', 'ar'];

/// 各语言字典键数的下限 —— 低于它说明**解析漏了整块**，而非"译文少"。
/// 教训：第一版用 `'xx': {` 匹配，没认 `<String, String>{` 写法，
/// 于是 i18n_extra.dart 整块没被解析、fr/ru/es/ar 被报成只有 8 个键，
/// 审计结论完全反了。错误的审计比没有审计更坏，所以这里硬钉一道下限。
///
/// 取 100 而不是贴着实测最小值（当前最少的是 ja=153）：解析失败的形态是
/// "只剩 8 个键或 0 个键"，100 足以区分，又给 ja 留出增长空间 —— 否则
/// 以后往 en 加几十个键而 ja 没同步，会报成"解析漏块"，把人带偏。
const kMinKeys = 100;

class _Str {
  final int start, end;
  final String value;
  _Str(this.start, this.end, this.value);
}

String _unesc(String c) {
  switch (c) {
    case 'n':
      return '\n';
    case 't':
      return '\t';
    case 'r':
      return '\r';
    default:
      return c;
  }
}

/// 扫描 Dart 字符串字面量（单/双引号），返回位置与**还原转义后**的值。
List<_Str> scanStrings(String src) {
  final out = <_Str>[];
  for (var i = 0; i < src.length; i++) {
    final q = src[i];
    if (q != "'" && q != '"') continue;
    var j = i + 1;
    final sb = StringBuffer();
    var closed = false;
    while (j < src.length) {
      final c = src[j];
      if (c == r'\') {
        if (j + 1 < src.length) {
          sb.write(_unesc(src[j + 1]));
          j += 2;
          continue;
        }
      }
      if (c == q) {
        closed = true;
        break;
      }
      if (c == '\n') break; // 未闭合 → 放弃这个
      sb.write(c);
      j++;
    }
    if (closed) {
      out.add(_Str(i, j, sb.toString()));
      i = j;
    }
  }
  return out;
}

/// 解析 `{ '<locale>': <String,String>{ ... } }` 形式的字典文件。
Map<String, Map<String, String>> parseDict(String src) {
  final res = <String, Map<String, String>>{};
  final locRe = RegExp(r"'([a-z]{2})'\s*:\s*(?:<[^>]*>\s*)?\{");
  for (final m in locRe.allMatches(src)) {
    final loc = m.group(1)!;
    if (!kLocales.contains(loc)) continue;
    final braceStart = src.indexOf('{', m.end - 1);
    var depth = 0, k = braceStart;
    while (k < src.length) {
      final c = src[k];
      if (c == "'" || c == '"') {
        // 跳过整个字符串，避免键值里的花括号干扰配对
        var j = k + 1;
        while (j < src.length) {
          if (src[j] == r'\') {
            j += 2;
            continue;
          }
          if (src[j] == c) break;
          j++;
        }
        k = j + 1;
        continue;
      }
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) break;
      }
      k++;
    }
    final body = src.substring(braceStart + 1, k);
    final strs = scanStrings(body);
    final pairs = <String, String>{};
    for (var b = 0; b + 1 < strs.length; b++) {
      final between = body.substring(strs[b].end + 1, strs[b + 1].start);
      if (!RegExp(r'^\s*:\s*$').hasMatch(between)) continue;
      pairs[strs[b].value] = strs[b + 1].value;
      b++;
    }
    res[loc] = {...?res[loc], ...pairs};
  }
  return res;
}

void main() {
  final mainSrc = File('lib/core/i18n.dart').readAsStringSync();
  final extraSrc = File('lib/core/i18n_extra.dart').readAsStringSync();

  final d1 = parseDict(mainSrc);
  final d2 = parseDict(extraSrc);

  // 合并方向必须与 `_mergeExtra` 一致：**extra 覆盖基础**。
  final dict = <String, Map<String, String>>{};
  for (final l in kLocales) {
    dict[l] = {...?d1[l], ...?d2[l]};
  }

  // ── 1. 解析器自检（防止"审计本身错了"） ──
  print('== 1. 字典解析完整性 ==');
  for (final l in kLocales) {
    final n = dict[l]!.length;
    ck('$l 解析到 $n 个键（须 ≥ $kMinKeys）', n >= kMinKeys);
  }
  ck('源码里出现了全部 ${kLocales.length} 种语言块', kLocales.every((l) => d1.containsKey(l) || d2.containsKey(l)));
  ck('zh 不作为字典块存在（中文原文即 key）', !d1.containsKey('zh') && !d2.containsKey('zh'));

  // ── 2. 收集源码里真正用到的 key ──
  print('== 2. 源码 tr() 用法收集 ==');
  final used = <String>{};
  final trRe = RegExp(r"""\b(?:tr|t)\(\s*'((?:[^'\\]|\\.)*)'""");
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    for (final m in trRe.allMatches(e.readAsStringSync())) {
      used.add(m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (x) => _unesc(x.group(1)!)));
    }
  }
  ck('收集到 tr() 用到的 key：${used.length} 个（须 > 0）', used.isNotEmpty);
  ck('tr() key 数量合理（30~400）', used.length >= 30 && used.length <= 400);

  // ── 3. ★核心：每个语言都必须覆盖每个用到的 key ──
  //
  // 判据取 "该语言自己有没有"，不取"能不能回退到 en"：
  //   回退到 en 也算语言没做完（用户选了法语却看到英文）。所以一律要求
  //   目标语言自己有译文 —— 这样这条闸门同时锁住两类静默回退。
  print('== 3. 各语言覆盖率（缺一个即 FAIL） ==');
  for (final l in kLocales) {
    final miss = used.where((k) => dict[l]![k] == null).toList()..sort();
    if (miss.isNotEmpty) {
      print('  [$l] 缺 ${miss.length} 个键，例：${miss.take(8).join(' / ')}');
    }
    ck('$l 覆盖全部 ${used.length} 个 key', miss.isEmpty);
  }

  // ── 4. 反向检查：字典里的键必须在源码里用过（防拼写漂移） ──
  //
  // 只对 en 做（en 是最全的基准）。字典里有、源码从来不用 → 多半是
  // key 拼错或源码那句文案被删了，属可清理项；这里只报告不判负。
  print('== 4. 反向检查（仅报告） ==');
  final enKeys = dict['en']!.keys.toSet();
  final unused = enKeys.difference(used).toList()..sort();
  print('  en 有 ${enKeys.length} 键，其中源码未直接引用 ${unused.length} 个'
      '（可能是动态拼接的文案，仅提示）');
  for (final k in unused.take(6)) {
    print('     · $k');
  }
  ck('en 字典非空', enKeys.isNotEmpty);

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ i18n 字典完整：6 语言 × ${used.length} 键，无静默回退');
}
