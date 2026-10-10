// 自适应断点/铰链跨端一致性自检（纯 Dart VM 可跑）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/adaptive_selfcheck.dart
//
// 覆盖三件事：
//   一、**行为断言**（真 import 纯 Dart 的 lib/core/breakpoints.dart）：
//       windowClassOf 在边界值 599/600/839/840 的判档结果 —— 形状断言不能
//       替代行为断言（i18n 2026-09-28 事故的教训）。
//   二、**跨端一致性**：tokens.json breakpoints ↔ App Breakpoints ↔
//       网页端 device-adapt.js 的 windowClass() 三处阈值逐项一致；
//       deviceTiers 六档与 device-adapt.js 的设备形态键集合一致。
//   三、**接线到位**（文本断言，防"改了没接上"的假绿）：
//       dynamic_layouts 的 kBreakpointConfig 映射、主从双栏/浮层停靠/
//       铰链让位确实在 main.dart 与 adaptive.dart 里被用上。
//
// ★ 网页端文件找不到 → 硬失败（exit 1）并打印找过的每个路径 —— 不许假绿。
//   本地只想跑单端时显式传 `--no-web`（CI 绝不传）。
import 'dart:convert';
import 'dart:io';

import '../lib/core/breakpoints.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

List<String> webCandidates(String rel) {
  final List<String> out = <String>[];
  final String? env = Platform.environment['TH_WEB_ROOT'];
  if (env != null && env.trim().isNotEmpty) {
    out.add('${env.replaceAll(r'\', '/')}/$rel');
  }
  out.add('D:/ai/deep seek/$rel');
  final String? ws = Platform.environment['GITHUB_WORKSPACE'];
  if (ws != null && ws.trim().isNotEmpty) {
    out.add('${ws.replaceAll(r'\', '/')}/_web/$rel');
  }
  out.add('../deep seek/$rel');
  return out;
}

List<String> repoFileCandidates(String rel) {
  final String scriptDir =
      File(Platform.script.toFilePath()).parent.path.replaceAll(r'\', '/');
  return <String>['$scriptDir/../../$rel', '../$rel', '$rel'];
}

String? findFirst(List<String> candidates) {
  for (final String p in candidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

String mustRead(List<String> candidates, String what) {
  final String? p = findFirst(candidates);
  if (p == null) {
    print('FAIL 找不到$what，找过的路径：');
    for (final String c in candidates) {
      print('  - $c');
    }
    exit(1);
  }
  print('  读取 $what ← $p');
  return File(p).readAsStringSync();
}

void main(List<String> args) {
  final bool noWeb = args.contains('--no-web');

  print('== 0. 读取定义 ==');
  final String tokSrc =
      mustRead(repoFileCandidates('design/tokens.json'), 'tokens.json');
  final String dartSrc = mustRead(
      repoFileCandidates('flutter_app/lib/core/design_tokens.dart'),
      'design_tokens.dart');
  final String bpSrc = mustRead(
      repoFileCandidates('flutter_app/lib/core/breakpoints.dart'),
      'breakpoints.dart');
  final String adSrc = mustRead(
      repoFileCandidates('flutter_app/lib/core/adaptive.dart'), 'adaptive.dart');
  final String mainSrc = mustRead(
      repoFileCandidates('flutter_app/lib/main.dart'), 'main.dart');
  String devSrc = '';
  if (!noWeb) {
    devSrc = mustRead(webCandidates('js/device-adapt.js'), '网页端 device-adapt.js');
  } else {
    print('  （--no-web：跳过网页端）');
  }

  final Map<String, dynamic> tok = jsonDecode(tokSrc) as Map<String, dynamic>;
  final Map<String, dynamic> bp =
      (tok['breakpoints'] as Map<String, dynamic>);
  final Map<String, dynamic> tiers =
      (tok['deviceTiers'] as Map<String, dynamic>);

  // ══ 一、行为断言：边界值判档 ══
  print('== 1. windowClassOf 行为（边界值逐个钉死）==');
  ck('599 → compact', windowClassOf(599) == WindowClass.compact);
  ck('600 → medium', windowClassOf(600) == WindowClass.medium);
  ck('839 → medium', windowClassOf(839) == WindowClass.medium);
  ck('840 → expanded', windowClassOf(840) == WindowClass.expanded);
  ck('0 → compact', windowClassOf(0) == WindowClass.compact);
  ck('4000 → expanded', windowClassOf(4000) == WindowClass.expanded);

  // dynamic_layouts 阈值映射的行为等价性：
  // 包语义：width < smallMax → small；width > largeMin → large；其余 medium。
  // kBreakpointConfig 映射为 smallMax=compactMax+1、largeMin=expandedMin-1。
  double smallMax = Breakpoints.compactMax + 1;
  double largeMin = Breakpoints.expandedMin - 1;
  WindowClass pkg(double w) => w < smallMax
      ? WindowClass.compact
      : (w > largeMin ? WindowClass.expanded : WindowClass.medium);
  ck('包阈值映射与 windowClassOf 逐点等价（边界+抽样）',
      [0.0, 360.0, 599.0, 600.0, 839.0, 840.0, 1200.0, 4000.0]
          .every((w) => pkg(w) == windowClassOf(w)));

  // ══ 二、三方阈值一致 ══
  print('== 2. tokens.json ↔ App ↔ 网页端 阈值一致 ==');
  ck('compactMax = tokens.json', Breakpoints.compactMax == (bp['compactMax'] as num).toDouble());
  ck('mediumMax = tokens.json', Breakpoints.mediumMax == (bp['mediumMax'] as num).toDouble());
  ck('expandedMin = tokens.json', Breakpoints.expandedMin == (bp['expandedMin'] as num).toDouble());
  ck('foldHingeMin = tokens.json', Breakpoints.foldHingeMin == (bp['foldHingeMin'] as num).toDouble());
  ck('listDetailMin = tokens.json', Breakpoints.listDetailMin == (bp['listDetailMin'] as num).toDouble());
  ck('design_tokens.dart 转出 breakpoints.dart（既有 import 用法不变）',
      dartSrc.contains("export 'breakpoints.dart';"));
  ck('三档无缝衔接（medium 占满 compact 之后到 expanded 之前）',
      Breakpoints.mediumMax == Breakpoints.expandedMin - 1 &&
          Breakpoints.mediumMax > Breakpoints.compactMax);

  // breakpoints.dart 文本里出现的字面值 = tokens.json（防"只改了一处"）
  for (final String name in [
    'compactMax', 'mediumMax', 'expandedMin', 'foldHingeMin', 'listDetailMin'
  ]) {
    final RegExp re = RegExp('static const double $name = (\\d+)');
    final String? v = re.firstMatch(bpSrc)?.group(1);
    ck('breakpoints.dart $name 字面值 = ${bp[name]}（实得 $v）',
        v == '${bp[name]}');
  }

  if (!noWeb && devSrc.isNotEmpty) {
    print('== 3. 网页端 device-adapt.js ==');
    // windowClass() 的两个阈值字面量
    final RegExp fnRe =
        RegExp(r'export function windowClass[\s\S]*?\n\}');
    final String fn = fnRe.firstMatch(devSrc)?.group(0) ?? '';
    ck('device-adapt.js 有 windowClass() 导出', fn.isNotEmpty);
    final String? le = RegExp(r'width <= (\d+)').firstMatch(fn)?.group(1);
    final String? lt = RegExp(r'width < (\d+)').firstMatch(fn)?.group(1);
    ck('windowClass() compact 阈值 = ${bp['compactMax']}（实得 $le）',
        le == '${bp['compactMax']}');
    ck('windowClass() expanded 阈值 = ${bp['expandedMin']}（实得 $lt）',
        lt == '${bp['expandedMin']}');
    // 六档设备形态键集合 = tokens.json deviceTiers 键集合。
    // 抽取口径：每个 `dev = ...;` 赋值语句取**第一个**字符串字面量 ——
    // `dev = cond ? 'fold' : 'tablet';` 这种三元只会拿到 'fold'，
    // 'tablet' 由后面 `else dev = 'tablet';` 兜到（原先只匹配 `dev = 'x'`
    // 直接赋值，把三元里的 'fold' 漏掉，是断言自己的坑）。
    final Set<String> devTiers = RegExp(r"dev = [^;]*?'(\w+)'")
        .allMatches(devSrc)
        .map((m) => m.group(1)!)
        .toSet();
    final Set<String> tokTiers = tiers.keys
        .where((k) => !k.startsWith('_'))
        .toSet();
    // ★ 集合比较用双向差集，不能 join(',') —— Set 的遍历顺序不稳定，
    //   同一个集合两种顺序 join 出来就是两串不同的字符（本闸门第一版栽过）。
    ck('六档设备形态一致（device-adapt ↔ tokens.json）：${devTiers.join(',')}',
        devTiers.length == 6 &&
            devTiers.difference(tokTiers).isEmpty &&
            tokTiers.difference(devTiers).isEmpty);
    ck('deviceTiers 取值都在 compact/medium/expanded 内',
        tokTiers.every((k) =>
            ['compact', 'medium', 'expanded'].contains(tiers[k])));
  }

  // ══ 四、接线到位（文本断言）══
  print('== 4. 接线到位 ==');
  ck('adaptive.dart 的 kBreakpointConfig 由 Breakpoints 推导',
      adSrc.contains('smallMax: Breakpoints.compactMax + 1') &&
          adSrc.contains('largeMin: Breakpoints.expandedMin - 1'));
  ck('adaptive.dart 铰链判定用 foldHingeMin',
      adSrc.contains('f.bounds.shortestSide >= Breakpoints.foldHingeMin'));
  ck('main.dart 侧栏让位调 railHingeGap(hingeOf(...))',
      mainSrc.contains('railHingeGap(hingeOf('));
  ck('main.dart 书架主从双栏用 MasterDetailFrame',
      mainSrc.contains('MasterDetailFrame('));
  ck('main.dart 模块菜单走 showAdaptiveSheet（浮层停靠）',
      mainSrc.contains('showAdaptiveSheet('));
  ck('main.dart ScreenFit 判档走 windowClassOf',
      mainSrc.contains('windowClassOf(_w)'));
  ck('main.dart 主从双栏只在 expanded 分栏',
      mainSrc.contains('ScreenFit.cls != WindowClass.expanded'));

  print('自适应断点一致性：$pass 通过 / $fail 失败');
  exit(fail > 0 ? 1 : 0);
}
