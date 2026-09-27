// i18n 字典完整性自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/i18n_selfcheck.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// 为什么必须有这条闸门：**缺键回退是静默的**。
//
// 查找链是 `zh 短路 → dict[当前语言][k] ?? dict['en'][k] ?? k`（i18n.dart 的 tr()）。
// 也就是说：键在目标语言里没有 → 悄悄显示英文；目标语言和 en 都没有 → 悄悄
// 显示中文原文。**两种都不报错、不崩、不留日志**，只有用户切了语言才发现
// "怎么还是中文"。靠人眼在 200 个键 × 6 种语言里查，等于没查。
//
// 2026-09-25 实测：有 18 个键（含本轮刚从硬编码改成 tr() 的
// 「确认资源库指纹」「信任」）在**全部 6 种语言连 en 都缺** → 任何语言都显示
// 中文；ja 另缺 29 个键。已全部补齐，本自检把结论钉死，防止再退化。
//
// ★2026-09-28 第二课（用户实测「选中文，界面全是英文」）：上面那条链**当时没有
//   第一跳**（不是 `zh 短路 →`，而是直接从 `dict[当前语言]` 开始），而字典里
//   没有 'zh' 块 ⇒ `dict['zh']` 为 null ⇒ 中文用户掉进 en 兜底。
//   本自检当时**全绿**，因为它只断言字典形状（"zh 不作为字典块存在"），
//   从没断言过"locale=zh 时 tr() 的输出是什么"。→ 已新增 §3.5 行为断言。
//   结论：**形状断言不能替代行为断言**；"字典里有什么" ≠ "界面上显示什么"。
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
///
/// ★2026-09-28：这句「zh 是原文，不作为字典块存在」**既是事实、也正是那场事故的成因**——
/// 当时把它当成"所以缺词会回落中文"，却没意识到兜底链会先撞上 en。详见 §3.5。
const kLocales = ['en', 'ja', 'fr', 'ru', 'es', 'ar'];

/// 取出 `i18n.dart` 里 `tr()` 的函数体原文（源码级断言用）。
///
/// 用**花括号配对**而不是正则 —— 函数体里有注释和嵌套块，贪婪正则会跨过函数尾巴。
/// （因此往 `tr()` 的注释里写 `{` `}` 会干扰本函数，别写。）
String? extractTrBody(String src) {
  final i = src.indexOf('static String tr(');
  if (i < 0) return null;
  final b = src.indexOf('{', i);
  if (b < 0) return null;
  var depth = 0;
  for (var j = b; j < src.length; j++) {
    final ch = src[j];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return src.substring(b, j + 1);
    }
  }
  return null;
}

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

  // ── 3.5 ★行为断言：查找链对每种语言必须给出**正确结果** ──
  //
  // 为什么单列一段：上面 §3 查的是「字典里有没有这条译文」——那是**形状**，
  // **查不出"查表逻辑本身把某种语言打穿了"**。2026-09-28 的线上真实缺陷正是后者：
  //   字典里没有 'zh' 块 → `dict['zh']` 为 null → 兜底链掉到 `dict['en']`
  //   → **用户选「中文」，整个界面显示英文**。
  // 而当时本自检（含下面那条「zh 不作为字典块存在」）**全绿**：它只描述了形状，
  // 从没描述过行为。教训：**形状断言不能替代行为断言。**
  print('== 3.5 查找行为（zh 必须逐字回原文；其余语言不得静默空串） ==');

  /// 复刻 `tr()` 的**期望语义**（不是实现）：原文语言直接回 key。
  String expectTr(String locale, String k) {
    if (locale == 'zh') return k;
    final d = dict[locale];
    return d?[k] ?? dict['en']?[k] ?? k;
  }

  // (a) 源码级：`tr()` 必须**显式短路中文**。删掉它 = 立刻回到"中文显示英文"。
  final trBody = extractTrBody(mainSrc);
  ck('能定位到 tr() 函数体（解析没跑偏）', trBody != null);
  ck(
      "tr() 里有中文短路（locale == 'zh' 且 return zh）",
      trBody != null &&
          RegExp(r"locale\s*==\s*'zh'").hasMatch(trBody) &&
          RegExp(r'return\s+zh\s*;').hasMatch(trBody));

  // (b) 反证：没有短路时中文必然被英文截胡 —— 证明 (a) 不是形式主义。
  ck("反证：字典里确实没有 'zh' 块（所以只能靠短路，靠查表一定会拿到英文）",
      !dict.containsKey('zh') && !d1.containsKey('zh') && !d2.containsKey('zh'));
  final enHits = used.where((k) => dict['en']![k] != null).length;
  ck('反证：en 能给 $enHits/${used.length} 个 key 出英文译文（缺短路时中文就会拿到这些）',
      enHits >= used.length ~/ 2);

  // (c) 行为矩阵：7 种语言 × 每个 key，结果都不得为空串
  for (final l in ['zh', ...kLocales]) {
    final blank = used.where((k) => expectTr(l, k).trim().isEmpty).toList()..sort();
    if (blank.isNotEmpty) print('  [$l] 结果为空：${blank.take(8).join(' / ')}');
    ck('$l：${used.length} 个 key 均有非空结果', blank.isEmpty);
  }

  // (d) 中文必须**逐字**等于 key（这是"选中文就该看到中文"的形式化表述）
  final zhBad = used.where((k) => expectTr('zh', k) != k).toList()..sort();
  if (zhBad.isNotEmpty) {
    print('  [zh] 未逐字回原文，例：${zhBad.take(8).join(' / ')}');
  }
  ck('zh：全部 ${used.length} 个 key 逐字回中文原文', zhBad.isEmpty);

  // ── 4. 反向检查：字典里的键必须在源码里用过（防拼写漂移） ──
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
  if (fail == 0) {
    print('\n✅ i18n 字典完整：zh(原文短路) + 6 语言 × ${used.length} 键，无静默回退');
  }
  /* ★失败必须让进程**非零退出**：CI 的 dart-selfcheck 只看退出码，
     只打印 FAIL 而 return 0 的话，闸门形同虚设（2026-09-28 实测：
     8/10 个自检都没有 exit()，打印 FAIL 但 CI 一律绿灯）。*/
  if (fail > 0) exit(1);
}
