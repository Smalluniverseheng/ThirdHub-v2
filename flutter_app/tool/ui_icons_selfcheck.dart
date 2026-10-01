// D-H2 「UI 不许出现 emoji」自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   cd flutter_app
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/ui_icons_selfcheck.dart
//
// 为什么要有这道闸门：
//   2026-10-01 把 UI 面的 emoji 清到 0 时，全仓还躺着 570 余处 —— 但它们全在
//   `docs/*.md` 的状态表（✅/❌ 是表格语义）与 `tool/*_selfcheck.dart` 往**终端**
//   打印的 `✅ 全部通过` 里。那两类**不是界面**，清了反而看不懂。
//   于是"还剩几处"一直没有明确数字，D-H2 就一直停在 `[~]`。
//   本闸门把口径钉死：**只认 UI 面**（`lib/**` 与 `server/public/**` 等），
//   要求恒为 0；文档与终端输出完全不看。这样它才是一个会归零也守得住的数。
//
// ★ 第二类断言（更重要）：拦住「退回 Text(icon)」。
//   数据里 '🤖' 换成 'robot' 之后，若有人把渲染改回 `Text(a.icon)`，
//   界面上不会再有 emoji —— emoji 扫描器**照样绿**，但用户看到的是
//   一行字面量 "robot"。这种"扫描器绿、界面坏"的缺陷只能靠单独断言拦。
//
// ★ 为什么本文件**不 import** `lib/core/ui_icons.dart`：
//   那个文件 import 了 `package:flutter/material.dart` → 最终依赖 `dart:ui`，
//   而 `dart:ui` 只在 Flutter 引擎里存在。纯 Dart VM 下连编译都过不去
//   （实测 `Dart library 'dart:ui' is not available on this platform`，
//     满屏 11 万字节报错）。所以：
//     · 映射的**数据与判定**放在零依赖的 `ui_icon_map.dart` → 直接 import，真跑；
//     · 名→IconData 的**落地表**在 `ui_icons.dart` 里是编译期常量、纯 VM
//       取不到，改为**解析其源码文本**做交叉核对（见第 5 节）。
import 'dart:io';

import '../lib/core/ui_icon_map.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name${extra.isEmpty ? '' : '  → $extra'}');
  }
}

/// UI 面根目录（相对仓库根）。只放**会渲染给用户看的**东西；
/// 文档 / 自检脚本 / 终端输出一律不算。
const List<String> kUiRoots = [
  'flutter_app/lib',
  'server/public',
  'server/routes-admin.js',
  'server/routes-data.js',
  'server/engine.js',
  'server/peer-hub.js',
];

/// 刻意保留的几何/符号类标记（STYLE_GUIDE 第 1 条例外）。
/// ★ 必须与 `tools/scan-ui-emoji.cjs` 的 ALLOWED 保持一致。
const Set<String> kAllowed = {
  '★', '☆', '✦', '✧', '✓', '✗', '●', '○', '◆', '◇', '▲', '▼', '⚡',
  '→', '←', '↑', '↓', '·', '×', '—', '…',
};

final RegExp kEmoji = RegExp(
  r'[\u{1F000}-\u{1FAFF}\u{1F300}-\u{1F5FF}\u{1F600}-\u{1F64F}'
  r'\u{1F680}-\u{1F6FF}\u{1F900}-\u{1F9FF}\u{2600}-\u{27BF}'
  r'\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{1F1E6}-\u{1F1FF}]',
  unicode: true,
);

const Set<String> kSkipDir = {
  'node_modules', 'node_modules.msh-partial', '.git', 'build', '.dart_tool',
  'vendor', 'assets', 'ios', 'web', 'android', 'windows', 'linux', 'macos',
};
const Set<String> kExt = {'.dart', '.html', '.js', '.cjs', '.mjs', '.md'};

List<File> collect(String root) {
  final d = Directory(root);
  if (!d.existsSync()) return [];
  final out = <File>[];
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.replaceAll('\\', '/');
    if (kSkipDir.any((s) => rel.contains('/$s/'))) continue;
    final dot = rel.lastIndexOf('.');
    if (dot < 0 || !kExt.contains(rel.substring(dot))) continue;
    out.add(e);
  }
  return out;
}

/// 行内注释区间（`//` 与单行内闭合的 `/* */`）。
/// 注释里的 emoji 一律放行 —— 那是写给维护者看的，渲染不到界面上。
List<List<int>> commentSpans(String line) {
  final spans = <List<int>>[];
  var i = 0;
  while (true) {
    final a = line.indexOf('/*', i);
    if (a < 0) break;
    final b = line.indexOf('*/', a + 2);
    if (b < 0) {
      spans.add([a, line.length]);
      break;
    }
    spans.add([a, b + 2]);
    i = b + 2;
  }
  final lc = line.indexOf('//');
  if (lc >= 0) spans.add([lc, line.length]);
  return spans;
}

bool inSpans(int i, List<List<int>> sp) =>
    sp.any((s) => i >= s[0] && i < s[1]);

List<String> uiEmojiIn(File f) {
  final hits = <String>[];
  final lines = f.readAsLinesSync();
  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    final sp = commentSpans(line);
    for (final m in kEmoji.allMatches(line)) {
      final ch = m[0]!;
      if (kAllowed.contains(ch)) continue;
      if (inSpans(m.start, sp)) continue;
      hits.add('${f.path.replaceAll('\\', '/')}:${li + 1}  $ch  |  ${line.trim()}');
    }
  }
  return hits;
}

/// 从 `ui_icons.dart` 源码里抽出落地表 `byName` 的键集合与「哪些名字指向 fallback」。
({Set<String> names, Set<String> fallbackNames}) parseByName(String src) {
  final names = <String>{};
  final fallbackNames = <String>{};
  final re = RegExp(r"'([a-z0-9_]+)'\s*:\s*Icons\.([A-Za-z0-9_]+)");
  for (final m in re.allMatches(src)) {
    final name = m[1]!;
    names.add(name);
    if (m[2] == 'extension_outlined') fallbackNames.add(name);
  }
  return (names: names, fallbackNames: fallbackNames);
}

void main() {
  final cwd = Directory.current.path.replaceAll('\\', '/');
  final isAppDir = cwd.endsWith('/flutter_app');
  String repoPath(String rel) => isAppDir ? '../$rel' : rel;

  // ═══ 1. 映射表本身 ═══
  print('== 1. 映射表 ==');
  ck('键表非空（防被整体删空）', kIconKeyToName.length >= 30, 'len=${kIconKeyToName.length}');
  ck('历史 emoji 表非空（老数据要能显示）', kEmojiToKey.length >= 30, 'len=${kEmojiToKey.length}');
  ck('兜底键在键表内', kIconKeyToName.containsKey(kUnknownIconKey));
  ck('每个键都指向非空图标名', kIconKeyToName.values.every((v) => v.trim().isNotEmpty));
  ck('每个 emoji 都指向已存在的键',
      kEmojiToKey.values.every(kIconKeyToName.containsKey),
      kEmojiToKey.entries.where((e) => !kIconKeyToName.containsKey(e.value)).map((e) => e.key).join(','));

  // 历史数据保护：这些 emoji 曾经真的落过盘，任何一个被删都会让老用户
  // 升级后看到占位方块 —— 而开发机上永远复现不了（新装应用里没有老数据）。
  const legacyMustKeep = [
    '\u{1F916}', '\u{1F52C}', '\u{1F4BB}', '\u{1F4F1}', '\u{1F4CA}',
    '\u{270D}\u{FE0F}', '\u{1F310}', '\u{1F5C2}\u{FE0F}', '\u{1F50D}',
    '\u{1F6E0}', '\u{1F5D1}', '\u{1F4DD}', '\u{1F393}', '\u{1F5C4}\u{FE0F}',
    '\u{1F3AF}', '\u{1F9F9}', '\u{1F4DA}', '\u{1F517}', '\u{1F4BE}',
    '\u{1F4CB}', '\u{1F522}', '\u{1F40D}', '\u{26AB}', '\u{1F604}',
    '\u{1F642}', '\u{1F610}', '\u{1F614}', '\u{1F624}', '\u{1F4CC}',
    '\u{2B07}\u{FE0F}',
  ];
  final missing = legacyMustKeep.where((e) => !kEmojiToKey.containsKey(e)).toList();
  ck('历史 emoji 一个都不许删（删了老存档会变占位方块）', missing.isEmpty,
      '缺 ${missing.length} 个');

  // ═══ 2. resolveIconKey / knowsIcon 行为 ═══
  print('\n== 2. 判定行为：认识的给键，不认识也不能给空白 ==');
  for (final k in kIconKeyToName.keys) {
    ck('键 $k → 原样返回', resolveIconKey(k) == k);
  }
  ck('🤖 → robot', resolveIconKey('\u{1F916}') == 'robot');
  ck('🧹 → clean', resolveIconKey('\u{1F9F9}') == 'clean');
  ck('带变体选择符 ✍️ → writer', resolveIconKey('\u{270D}\u{FE0F}') == 'writer');
  ck('不带变体选择符 ✍ → 同一键 writer',
      resolveIconKey('\u{270D}') == resolveIconKey('\u{270D}\u{FE0F}'));
  ck('认不出的字符串 → 兜底键（不是 null/空）', resolveIconKey('完全没见过的东西') == kUnknownIconKey);
  ck('空串 → 兜底键', resolveIconKey('') == kUnknownIconKey);
  ck('null → 兜底键', resolveIconKey(null) == kUnknownIconKey);
  ck('两侧空白被 trim 后仍命中', resolveIconKey('  robot  ') == 'robot');
  ck('of 系列永不返回空图标名（空 = 界面开天窗）',
      [null, '', 'zzz', '  ', '🤖', 'robot'].every((v) => iconNameOf(v).isNotEmpty));

  ck('knowsIcon 对已知键为真', knowsIcon('robot'));
  ck('knowsIcon 对历史 emoji 为真', knowsIcon('\u{1F916}'));
  ck('knowsIcon 对未知为假', !knowsIcon('zzz-unknown'));
  ck('knowsIcon 对空为假', !knowsIcon(''));

  // ═══ 3. UI 面 emoji 必须为 0 ═══
  print('\n== 3. UI 面 emoji 扫描（必须为 0）==');
  var uiTotal = 0;
  for (final r in kUiRoots) {
    for (final f in collect(repoPath(r))) {
      final hits = uiEmojiIn(f);
      if (hits.isNotEmpty) {
        uiTotal += hits.length;
        for (final h in hits) print('    UI-EMOJI  $h');
      }
    }
  }
  ck('UI 面 emoji = 0（STYLE_GUIDE 第 1 条）', uiTotal == 0, '仍有 $uiTotal 处');
  // 反向确认扫描器没扫到空目录（假绿）
  final libDart = collect(repoPath('flutter_app/lib')).where((f) => f.path.endsWith('.dart')).length;
  ck('确实扫到了 lib/** 的 dart 文件（防扫空目录假绿）', libDart >= 50, 'count=$libDart');

  // ═══ 4. ★ 回归护栏：不许退回 Text(icon) 渲染图标 ═══
  print('\n== 4. 回归护栏：图标字段不得用 Text() 渲染 ==');
  final textIcon = RegExp(
    r"""Text\(\s*[\w'\"\[\]\$\.]*\.?icon\b|Text\(\s*[a-zA-Z_][\w]*\['icon'\]""",
  );
  final offenders = <String>[];
  for (final f in collect(repoPath('flutter_app/lib'))) {
    if (!f.path.endsWith('.dart')) continue;
    if (f.path.endsWith('ui_icons.dart')) continue;
    if (f.path.endsWith('ui_icon_map.dart')) continue;
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final code = lines[i].split('//').first;
      if (textIcon.hasMatch(code)) {
        offenders.add('${f.path.replaceAll('\\', '/')}:${i + 1}  |  ${lines[i].trim()}');
      }
    }
  }
  ck('没有用 Text(...) 直接渲染图标字段', offenders.isEmpty, offenders.take(5).join(' ;; '));

  // ═══ 5. 两个文件的交叉核对（名 → IconData 落地表） ═══
  print('\n== 5. ui_icon_map.dart ↔ ui_icons.dart 交叉核对 ==');
  final implFile = File(repoPath('flutter_app/lib/core/ui_icons.dart'));
  ck('ui_icons.dart 存在', implFile.existsSync(), implFile.path);
  if (implFile.existsSync()) {
    final implSrc = implFile.readAsStringSync();
    final parsed = parseByName(implSrc);
    ck('解析到落地表条目（防正则失效假绿）', parsed.names.length >= 30, 'parsed=${parsed.names.length}');

    final wanted = kIconKeyToName.values.toSet();
    final missing2 = wanted.difference(parsed.names);
    ck('键表用到的每个图标名都在落地表里（写错一个字母 = 某页面出占位方块）',
        missing2.isEmpty, '缺: ${missing2.join(', ')}');

    final unused = parsed.names.difference(wanted);
    ck('落地表没有多余条目', unused.isEmpty, '多余: ${unused.join(', ')}');

    // 只有兜底那一个允许指向 extension_outlined；
    // 否则"认不出"和"某个正常图标"会长得一模一样，界面上分不出。
    ck('落地表里只有兜底那一条指向 extension_outlined',
        parsed.fallbackNames.length == 1 && parsed.fallbackNames.contains('extension_outlined'),
        parsed.fallbackNames.join(','));
  }

  // ═══ 6. 数据侧图标字面量必须都被认识 ═══
  print('\n== 6. 数据侧图标字面量都在映射表内 ==');
  // 漏一个的表现是**某个模块的图标变成占位方块**，只在特定页面出现，最难漏测。
  final iconLit = RegExp(r"""['"]?icon['"]?\s*[:=]\s*['"]([^'"]{0,24})['"]""");
  final unknown = <String>{};
  var litCount = 0;
  for (final f in collect(repoPath('flutter_app/lib'))) {
    if (!f.path.endsWith('.dart')) continue;
    if (f.path.endsWith('ui_icons.dart') || f.path.endsWith('ui_icon_map.dart')) continue;
    for (final line in f.readAsLinesSync()) {
      final code = line.split('//').first;
      for (final m in iconLit.allMatches(code)) {
        final v = m[1]!;
        if (v.isEmpty || v.contains(r'$')) continue; // 运行时才定的值跳过
        litCount++;
        if (!knowsIcon(v)) unknown.add(v);
      }
    }
  }
  ck('确实扫到了图标字面量（防扫描器空转假绿）', litCount >= 15, 'litCount=$litCount');
  ck('所有图标字面量都能被映射', unknown.isEmpty, unknown.join(', '));

  print('\nPASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ 全部通过');
  if (fail > 0) exit(1);
}
