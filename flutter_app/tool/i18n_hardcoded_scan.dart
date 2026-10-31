// 硬编码中文 UI 文案扫描（ratchet 闸门）
//
//   dart run tool/i18n_hardcoded_scan.dart            # 报告 + 只对"新增"报错
//   dart run tool/i18n_hardcoded_scan.dart --write    # 把当前状况写回基线
//
// ─────────────────────────────────────────────────────────────────────────────
// 为什么需要这条闸门
//
// `tool/i18n_selfcheck.dart` 只管「已经用了 tr() 的 key 有没有译文」。
// 它**看不见**一类更常见的问题：文案压根没走 tr()，直接写死在 Text('搜索') 里。
// 那种情况下自检全绿、界面切到英文照样满屏中文 —— 2026-11-01 实测 lib/ 里
// 还有 300+ 条这种字面量，自检一条都没报。
//
// 为什么不直接"有一条就红"：现存条目一次改不完（要逐条补 6 语言译文）。
// 所以用 ratchet（棘轮）：
//   ① 首次把当前所有违规记进 `tool/hardcoded_zh_baseline.txt`；
//   ② 之后 CI 只对**不在基线里的新增违规**报错；
//   ③ 修掉一条就从基线删一条 —— 只降不升，防止一边修一边进新的。
//
// 判定口径（刻意保守，宁可漏判不要误报）
//   只认「整段字面量就是某个 UI 属性的值」的写法：Text('...')、hintText: '...'
//   这类。数据型字符串（URL、JSON、存储 key、模块 id）不在此列 ——
//   把它们也包上 tr() 才是真 bug（key 会随语言漂移）。
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

const kBaselinePath = 'tool/hardcoded_zh_baseline.txt';
const _cjk = r'[\u4e00-\u9fa5]';

/// 出现在字面量**前面**、说明这个位置是 UI 文案的属性/构造器。
///
/// ★口径刻意收窄（只留 9 个「值一定显示在屏幕上」的位置）：`title:` / `label:` /
///   `content:` 这类属性在业务代码里同时被用作**函数参数名**（`row(label, value)`），
///   放进白名单会把数据串一起算成"漏翻"，基线瞬间涨到 1210 条且真假混杂 ——
///   闸门一旦开始误报，人就会习惯性加白，等于废掉。宁可少报。
final _uiPrefix = RegExp(
    r'(?:Text\(\s*|Text\.rich\(\s*|hintText:\s*|labelText:\s*|helperText:\s*'
    r'|counterText:\s*|errorText:\s*|tooltip:\s*|semanticLabel:\s*)$');

/// 已经包过翻译函数的，跳过。
final _translated = RegExp(r'(?:^|[^\w.])(?:trf|tr|t|segLabel)\(\s*$');

/// 明显是数据、不是给人看的文案。
final _dataPrefix =
    RegExp(r'(?:url|Url|URL|path|Path|host|Host|id|Id|key|Key|tag|Tag)\s*:\s*$');

class Hit {
  final String file, value;
  final int line;
  Hit(this.file, this.line, this.value);
  String get sig => '$file\t$value';
}

void main(List<String> args) {
  final write = args.contains('--write');
  final hits = <Hit>[];

  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final rel = f.path.replaceAll('\\', '/').replaceFirst(RegExp(r'^lib/'), '');
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!RegExp(_cjk).hasMatch(line)) continue;
      if (line.trimLeft().startsWith('//')) continue;

      for (final m in RegExp(r"'((?:[^'\\]|\\.)*)'").allMatches(line)) {
        final v = m.group(1)!;
        if (!RegExp(_cjk).hasMatch(v)) continue;
        final before = line.substring(0, m.start);
        if (_translated.hasMatch(before)) continue;
        if (_dataPrefix.hasMatch(before.trimRight())) continue;
        if (!_uiPrefix.hasMatch(before.trimRight())) continue;
        hits.add(Hit(rel, i + 1, v));
      }
    }
  }

  final sigs = hits.map((h) => h.sig).toSet().toList()..sort();

  if (write) {
    File(kBaselinePath).writeAsStringSync(
        '# 已存在的硬编码中文 UI 文案（ratchet 基线，只降不升）\n'
        '# 格式：<lib 下相对路径>\\t<文案原文>\n'
        '# 修好一条就删掉对应的行；**不要因为想"变绿"而往里加行**。\n'
        '${sigs.join('\n')}\n');
    print('已写入基线 $kBaselinePath：${sigs.length} 条');
    return;
  }

  final baseline = File(kBaselinePath).existsSync()
      ? File(kBaselinePath)
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
          .toSet()
      : <String>{};

  final fresh = sigs.where((s) => !baseline.contains(s)).toList();
  final fixed = baseline.where((s) => !sigs.contains(s)).toList();

  print('硬编码中文 UI 文案：当前 ${sigs.length} 条，基线 ${baseline.length} 条');

  if (fixed.isNotEmpty) {
    print('\n已修好 ${fixed.length} 条（建议从基线里删掉，把水位降下来）：');
    for (final s in fixed.take(15)) {
      print('  - ${s.replaceAll('\t', '  ::  ')}');
    }
    if (fixed.length > 15) print('  …另 ${fixed.length - 15} 条');
  }

  if (fresh.isNotEmpty) {
    print('\n❌ 新增 ${fresh.length} 条硬编码文案（必须包 tr()/trf()，或加进基线并说明理由）：');
    for (final s in fresh.take(40)) {
      print('  + ${s.replaceAll('\t', '  ::  ')}');
    }
    if (fresh.length > 40) print('  …另 ${fresh.length - 40} 条');
    exit(1);
  }

  print('\n✅ 无新增硬编码文案');
}
