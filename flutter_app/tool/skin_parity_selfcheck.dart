// 皮肤跨端一致性自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/skin_parity_selfcheck.dart
//
// 唯一来源：仓库根 design/tokens.json 的 skins 数组。
// 本脚本同时解析三份"实现"并逐项比对（tokens.json 里 _readme 承诺的契约）：
//   1. 网页端 js/skins.js             —— SKINS / ACCENT_ALIAS / DEFAULT_SKIN
//   2. 网页端 css/theme.css           —— data-skin 颜色规则 / data-fx 特效档
//   3. App 端 lib/core/design_tokens.dart —— Skin 常量 / SkinFx / all 顺序
//
// 比对维度：id · 名称（中/英）· 种子色 · 种子深色 · 明暗底色 · 特效档 · 过冲档(vivid)。
//
// ★ 网页端文件找不到 → 硬失败（exit 1）并打印找过的每个路径 —— 不许假绿。
//   本地只想跑单端时显式传 `--no-web`（CI 绝不传）。
// ★ 颜色一律归一成 6 位大写 hex 再比：Dart 的 Color(0xFFxxxxxx) 取后 6 位，
//   JSON/CSS/JS 的 '#xxxxxx' 去 # 大写。不归一就会出现"同一个颜色比出不同"的假红。
// ★ Dart 的 Skin 没有 seedDeep 字段（深色由 ColorScheme.fromSeed 从 seed 推导），
//   所以"种子深色"只在 tokens.json / skins.js / theme.css 三方比对 —— 这是设计如此，
//   不是漏比；把这条写在这里，防止后人"补"一个没人读的字段。
// ★ 断言一律用 join(',') 比较 —— Dart 的 List == 是引用比较，直接 == [...] 恒假。
import 'dart:convert';
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

/// 颜色归一：'#2F6BFF' / '2f6bff' / 'FF2F6BFF' / '0xFF2F6BFF' → '2F6BFF'
String normHex(String raw) {
  String h = raw.trim().replaceFirst('#', '').replaceFirst('0x', '').replaceFirst('0X', '');
  h = h.toUpperCase();
  if (h.length == 8) h = h.substring(2); // ARGB → RGB（alpha 恒 FF）
  return '#$h';
}

String hexFromDartColor(String argb8) => normHex(argb8);

// ── 路径解析（与 member_levels_selfcheck 同一套约定）─────────────────────

List<String> webCandidates(String rel) {
  final List<String> out = <String>[];
  final String? env = Platform.environment['TH_WEB_ROOT'];
  if (env != null && env.trim().isNotEmpty) {
    out.add('${env.replaceAll(r'\', '/')}/$rel');
  }
  out.add('D:/ai/deep seek/$rel');
  // CI：网页端被 checkout 到 $GITHUB_WORKSPACE/_web
  final String? ws = Platform.environment['GITHUB_WORKSPACE'];
  if (ws != null && ws.trim().isNotEmpty) {
    out.add('${ws.replaceAll(r'\', '/')}/_web/$rel');
  }
  out.add('../deep seek/$rel');
  return out;
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

// ── 各来源的解析结果 ────────────────────────────────────────────────────

class SkinRec {
  SkinRec(this.id, this.name, this.nameEn, this.seed, this.seedDeep,
      this.lightBg, this.darkBg, this.fx, this.vivid);
  final String id, name, nameEn, seed, seedDeep, lightBg, darkBg, fx;
  final bool vivid;
  @override
  String toString() => id;
}

List<String> repoFileCandidates(String rel) {
  // 以本脚本位置为锚：flutter_app/tool/ → 仓库根
  final String scriptDir =
      File(Platform.script.toFilePath()).parent.path.replaceAll(r'\', '/');
  return <String>[
    '$scriptDir/../../$rel',
    '../$rel', // cwd = flutter_app/
    '$rel',
  ];
}

void main(List<String> args) {
  final bool noWeb = args.contains('--no-web');

  // ══ 0. 读四个来源 ══
  print('== 0. 读取四端定义 ==');
  final String tokSrc =
      mustRead(repoFileCandidates('design/tokens.json'), 'tokens.json');
  final String dartSrc = mustRead(
      repoFileCandidates('flutter_app/lib/core/design_tokens.dart'),
      'design_tokens.dart');

  String? skinsJsSrc;
  String? themeCssSrc;
  if (!noWeb) {
    skinsJsSrc = mustRead(webCandidates('js/skins.js'), '网页端 js/skins.js');
    themeCssSrc = mustRead(webCandidates('css/theme.css'), '网页端 css/theme.css');
  } else {
    print('  （--no-web：跳过网页端，仅比 tokens.json ↔ design_tokens.dart）');
  }

  // ══ 1. 解析 tokens.json（唯一来源）══
  final Map<String, dynamic> tok =
      jsonDecode(tokSrc) as Map<String, dynamic>;
  final List<SkinRec> tokSkins = <SkinRec>[];
  for (final dynamic s in tok['skins'] as List<dynamic>) {
    final Map<String, dynamic> m = s as Map<String, dynamic>;
    tokSkins.add(SkinRec(
      m['id'] as String,
      m['name'] as String,
      m['nameEn'] as String,
      normHex(m['seed'] as String),
      normHex(m['seedDeep'] as String),
      normHex(m['lightBg'] as String),
      normHex(m['darkBg'] as String),
      m['fx'] as String,
      m['vivid'] as bool,
    ));
  }
  final List<String> tokFxKeys = <String>[
    for (final String k in (tok['fx'] as Map<String, dynamic>).keys)
      if (!k.startsWith('_')) k,
  ];
  final Map<String, String> tokAlias = <String, String>{
    for (final MapEntry<String, dynamic> e
        in ((tok['accentAliases'] as Map<String, dynamic>).entries))
      if (!e.key.startsWith('_')) e.key: e.value as String,
  };

  // ══ 2. 解析 App 端 design_tokens.dart ══
  final RegExp constRe =
      RegExp(r'static const Skin (\w+) = Skin\(([\s\S]*?)\);');
  final Map<String, SkinRec> dartByName = <String, SkinRec>{};
  for (final RegExpMatch m in constRe.allMatches(dartSrc)) {
    final String cname = m.group(1)!;
    final String body = m.group(2)!;
    String pick(String pat) => RegExp(pat).firstMatch(body)?.group(1) ?? '';
    final String fxRaw = pick(r'fx:\s*SkinFx\.(\w+)');
    final String vividRaw = pick(r'vivid:\s*(true|false)');
    dartByName[cname] = SkinRec(
      pick(r"id:\s*'([^']+)'"),
      pick(r"name:\s*'([^']+)'"),
      '', // Dart 侧不存英文名
      hexFromDartColor(pick(r'seed:\s*Color\(0x([0-9A-Fa-f]{8})\)')),
      '', // Dart 侧不存 seedDeep（由 ColorScheme.fromSeed 推导）
      hexFromDartColor(pick(r'lightBg:\s*Color\(0x([0-9A-Fa-f]{8})\)')),
      hexFromDartColor(pick(r'darkBg:\s*Color\(0x([0-9A-Fa-f]{8})\)')),
      fxRaw.isEmpty ? 'none' : fxRaw,
      vividRaw.isEmpty ? true : vividRaw == 'true',
    );
  }
  // all 顺序 = UI 排列顺序
  final RegExp allRe =
      RegExp(r'static const List<Skin> all = \[([\s\S]*?)\];');
  final List<String> allNames = <String>[
    for (final String n in (allRe.firstMatch(dartSrc)?.group(1) ?? '')
        .split(','))
      if (n.trim().isNotEmpty) n.trim(),
  ];
  final List<SkinRec> dartSkins = <SkinRec>[
    for (final String n in allNames)
      if (dartByName.containsKey(n)) dartByName[n]!,
  ];
  // SkinFx 枚举取值
  final RegExp fxEnumRe = RegExp(r'enum SkinFx \{([\s\S]*?)\n\}');
  final List<String> dartFxValues = <String>[];
  for (final String line
      in (fxEnumRe.firstMatch(dartSrc)?.group(1) ?? '').split('\n')) {
    final RegExpMatch? m = RegExp(r'^\s*([a-z]+),?\s*$').firstMatch(line);
    if (m != null) dartFxValues.add(m.group(1)!);
  }

  // ══ 3. 解析网页端 skins.js ══
  List<SkinRec> webSkins = <SkinRec>[];
  Map<String, String> webAlias = <String, String>{};
  String webDefault = '';
  if (skinsJsSrc != null) {
    final RegExp jsRe = RegExp(
        r"\{\s*id:\s*'([^']+)',\s*name:\s*'([^']+)',\s*en:\s*'([^']+)',\s*"
        r"seed:\s*'([^']+)',\s*deep:\s*'([^']+)',\s*lightBg:\s*'([^']+)',\s*"
        r"darkBg:\s*'([^']+)',\s*fx:\s*'([^']+)'");
    webSkins = <SkinRec>[
      for (final RegExpMatch m in jsRe.allMatches(skinsJsSrc))
        SkinRec(
            m.group(1)!,
            m.group(2)!,
            m.group(3)!,
            normHex(m.group(4)!),
            normHex(m.group(5)!),
            normHex(m.group(6)!),
            normHex(m.group(7)!),
            m.group(8)!,
            true),
    ];
    final RegExp aliasBlock =
        RegExp(r'export const ACCENT_ALIAS = \{([\s\S]*?)\};');
    for (final RegExpMatch m in RegExp(r"(\w+)\s*:\s*'(\w+)'")
        .allMatches(aliasBlock.firstMatch(skinsJsSrc)?.group(1) ?? '')) {
      webAlias[m.group(1)!] = m.group(2)!;
    }
    webDefault = RegExp(r"DEFAULT_SKIN = '(\w+)'")
            .firstMatch(skinsJsSrc)
            ?.group(1) ??
        '';
  }

  // ══ 4. 解析网页端 theme.css ══
  Map<String, SkinRec> cssSkins = <String, SkinRec>{};
  Set<String> cssFxBlocks = <String>{};
  if (themeCssSrc != null) {
    String cssVar(String block, String name) =>
        RegExp('--$name:(#[0-9A-Fa-f]{6})').firstMatch(block)?.group(1) ?? '';
    for (final RegExpMatch m
        in RegExp(r'body\[data-skin="(\w+)"\]\s*\{([^}]*)\}')
            .allMatches(themeCssSrc)) {
      final String id = m.group(1)!;
      final String body = m.group(2)!;
      cssSkins[id] = SkinRec(id, '', '', normHex(cssVar(body, 'primary')),
          normHex(cssVar(body, 'primary-deep')), '', '', 'none', true);
    }
    for (final RegExpMatch m in RegExp(
            r'body\[data-skin="(\w+)"\]\[data-theme="light"\]\s*\{([^}]*)\}')
        .allMatches(themeCssSrc)) {
      final SkinRec? r = cssSkins[m.group(1)!];
      final String v = normHex(cssVar(m.group(2)!, 'bg-page'));
      if (r != null) {
        cssSkins[m.group(1)!] = SkinRec(r.id, '', '', r.seed, r.seedDeep, v,
            r.darkBg, r.fx, r.vivid);
      }
    }
    for (final RegExpMatch m in RegExp(
            r'body\[data-skin="(\w+)"\]\[data-theme="dark"\]\s*\{([^}]*)\}')
        .allMatches(themeCssSrc)) {
      final SkinRec? r = cssSkins[m.group(1)!];
      final String v = normHex(cssVar(m.group(2)!, 'bg-page'));
      if (r != null) {
        cssSkins[m.group(1)!] = SkinRec(r.id, '', '', r.seed, r.seedDeep,
            r.lightBg, v, r.fx, r.vivid);
      }
    }
    for (final RegExpMatch m
        in RegExp(r'body\[data-fx="(\w+)"\]').allMatches(themeCssSrc)) {
      cssFxBlocks.add(m.group(1)!);
    }
  }

  // ══ 5. 逐项比对 ══
  print('== 1. 表体完整性 ==');
  ck('tokens.json 皮肤数 = 10', tokSkins.length == 10);
  ck('id 无重复', tokSkins.map((s) => s.id).toSet().length == tokSkins.length);
  ck('id 全为小写 ascii',
      tokSkins.every((s) => RegExp(r'^[a-z]+$').hasMatch(s.id)));
  ck('中文名无 emoji / 纯汉字',
      tokSkins.every((s) => RegExp(r'^[一-鿿]+$').hasMatch(s.name)));
  ck('英文名纯 ascii',
      tokSkins.every((s) => RegExp(r'^[A-Za-z ]+$').hasMatch(s.nameEn)));
  ck('fx 取值都在 fx 词表内',
      tokSkins.every((s) => tokFxKeys.contains(s.fx)));

  final String tokIds = tokSkins.map((s) => s.id).join(',');
  print('== 2. App 端 design_tokens.dart ==');
  ck('Skin 常量数 = 10', dartByName.length == 10);
  ck('all 顺序 = tokens.json 顺序',
      dartSkins.map((s) => s.id).join(',') == tokIds);
  ck('SkinFx 枚举 = fx 词表', dartFxValues.join(',') == tokFxKeys.join(','));
  for (final SkinRec t in tokSkins) {
    final SkinRec? d = dartSkins.cast<SkinRec?>().firstWhere(
        (s) => s!.id == t.id,
        orElse: () => null);
    if (d == null) {
      ck('App 端缺皮肤 ${t.id}', false);
      continue;
    }
    ck('[${t.id}] 名称  App="${d.name}" = tokens="${t.name}"', d.name == t.name);
    ck('[${t.id}] 种子色 App=${d.seed} = tokens=${t.seed}', d.seed == t.seed);
    ck('[${t.id}] 明底色 App=${d.lightBg} = tokens=${t.lightBg}',
        d.lightBg == t.lightBg);
    ck('[${t.id}] 暗底色 App=${d.darkBg} = tokens=${t.darkBg}',
        d.darkBg == t.darkBg);
    ck('[${t.id}] 特效档 App=${d.fx} = tokens=${t.fx}', d.fx == t.fx);
    ck('[${t.id}] 过冲档 App=${d.vivid} = tokens=${t.vivid}',
        d.vivid == t.vivid);
  }

  if (skinsJsSrc != null) {
    print('== 3. 网页端 js/skins.js ==');
    ck('SKINS 数 = 10', webSkins.length == 10);
    ck('SKINS 顺序 = tokens.json 顺序',
        webSkins.map((s) => s.id).join(',') == tokIds);
    ck('DEFAULT_SKIN = tokens.json 首个皮肤',
        webDefault == tokSkins.first.id);
    ck('ACCENT_ALIAS = tokens.json accentAliases',
        (webAlias.keys.toList()..sort())
            .map((k) => '$k:${webAlias[k]}')
            .join(',') ==
            (tokAlias.keys.toList()..sort())
                .map((k) => '$k:${tokAlias[k]}')
                .join(','));
    for (final SkinRec t in tokSkins) {
      final SkinRec? w = webSkins.cast<SkinRec?>().firstWhere(
          (s) => s!.id == t.id,
          orElse: () => null);
      if (w == null) {
        ck('skins.js 缺皮肤 ${t.id}', false);
        continue;
      }
      ck('[${t.id}] 名称  js="${w.name}" = tokens="${t.name}"',
          w.name == t.name);
      ck('[${t.id}] 英文名 js="${w.nameEn}" = tokens="${t.nameEn}"',
          w.nameEn == t.nameEn);
      ck('[${t.id}] 种子色 js=${w.seed} = tokens=${t.seed}', w.seed == t.seed);
      ck('[${t.id}] 种子深 js=${w.seedDeep} = tokens=${t.seedDeep}',
          w.seedDeep == t.seedDeep);
      ck('[${t.id}] 明底色 js=${w.lightBg} = tokens=${t.lightBg}',
          w.lightBg == t.lightBg);
      ck('[${t.id}] 暗底色 js=${w.darkBg} = tokens=${t.darkBg}',
          w.darkBg == t.darkBg);
      ck('[${t.id}] 特效档 js=${w.fx} = tokens=${t.fx}', w.fx == t.fx);
    }
  }

  if (themeCssSrc != null) {
    print('== 4. 网页端 css/theme.css ==');
    ck('data-skin 规则数 = 10', cssSkins.length == 10);
    for (final SkinRec t in tokSkins) {
      final SkinRec? c = cssSkins[t.id];
      if (c == null) {
        ck('theme.css 缺 data-skin="${t.id}" 规则', false);
        continue;
      }
      ck('[${t.id}] 种子色 css=${c.seed} = tokens=${t.seed}', c.seed == t.seed);
      ck('[${t.id}] 种子深 css=${c.seedDeep} = tokens=${t.seedDeep}',
          c.seedDeep == t.seedDeep);
      ck('[${t.id}] 明底色 css=${c.lightBg} = tokens=${t.lightBg}',
          c.lightBg == t.lightBg);
      ck('[${t.id}] 暗底色 css=${c.darkBg} = tokens=${t.darkBg}',
          c.darkBg == t.darkBg);
    }
    final Set<String> nonNoneFx = tokFxKeys.toSet()..remove('none');
    ck('每个非 none 特效档都有 data-fx 规则块',
        nonNoneFx.every(cssFxBlocks.contains));
    ck('data-fx 规则块没有词表外的档',
        cssFxBlocks.every((f) => tokFxKeys.contains(f)));
    ck('带特效的皮肤（shuimo/mecha/glass）在 CSS 里有对应 data-fx',
        tokSkins
            .where((s) => s.fx != 'none')
            .every((s) => cssFxBlocks.contains(s.fx)));
  }

  print('皮肤跨端一致性：$pass 通过 / $fail 失败');
  exit(fail > 0 ? 1 : 0);
}
