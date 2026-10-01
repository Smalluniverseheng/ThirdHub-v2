// 封面网格统一自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   cd flutter_app
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/ui_cover_selfcheck.dart
//
// 为什么要有这道闸门（2026-10-01 实测，不是印象）：
//   · 全仓 `childAspectRatio` 出现 **11 种取值**（0.52/0.62/0.65/0.75/0.85/
//     1.15/1.2/1.3/1.4/1.5/2.2）、间距 5 种、封面圆角 10/8/4 ——
//     而 `STYLE_GUIDE.md` 第 3 条写的是「卡片圆角 12，间距基准 8 的倍数」。
//   · 20+ 处 `Image.network` **各写各的兜底**：有的 loading+error 都写、
//     有的只写一个、有的一个都没写 → 断网时同一屏里灰块/裂图/空白三种混排。
//
// 本闸门分两层：
//   ① **规格层（真断言）**：数值、表体完整性、兜底行为、口径守卫；
//   ② **源码层（grep 式）**：★这是防「改一半」最有效的一条 ——
//      封面替换是逐个模块做的，漏掉的那处**不会有任何报错、也过得了编译器**，
//      只会在断网时表现为"这个页面还是老样子"，肉眼极难发现。
//      grep 断言把它变成红色。
//
// ★ 本文件**不 import** `lib/core/ui_cover.dart`：那个文件 import
//   `package:flutter/material.dart` → 最终依赖 `dart:ui`，纯 Dart VM 下连编译
//   都过不去（`Dart library 'dart:ui' is not available on this platform`）。
//   所以规格拆在零依赖的 `cover_spec.dart` 里给本自检 import，
//   `ui_cover.dart` 只做**字符串**断言。

import 'dart:io';

import '../lib/core/cover_spec.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('  ok   $name');
  } else {
    fail++;
    print('  FAIL $name${extra.isEmpty ? '' : '  [$extra]'}');
  }
}

int countOf(String src, String needle) =>
    RegExp(RegExp.escape(needle)).allMatches(src).length;

/// 统计 `Image.network(` 的出现次数。
int netImgCount(String src) => countOf(src, 'Image.network(');

/// 列出每个 `Image.network(` 之后紧跟的 24 个字符（用于判定"这处是不是阅读器正文图"）。
List<String> netImgTails(String src) {
  final re = RegExp(r'Image\.network\(');
  return [
    for (final m in re.allMatches(src))
      src.substring(m.end, (m.end + 24).clamp(0, src.length))
  ];
}

String? tryRead(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}

void main() {
  final cwd = Directory.current.path.replaceAll('\\', '/');
  final isAppDir = cwd.endsWith('/flutter_app');
  String repoPath(String rel) => isAppDir ? '../$rel' : rel;

  // ═══════════════════════════════════════════════════════════════
  // 1. 规格数值（对齐 STYLE_GUIDE）
  // ═══════════════════════════════════════════════════════════════
  print('== 1. 规格数值 ==');
  ck('卡片圆角 == 12（STYLE_GUIDE 第 3 条）', CoverSpec.radius == 12,
      '${CoverSpec.radius}');
  ck('网格间距 == 8 且为 8 的倍数', CoverSpec.gap == 8 && CoverSpec.gap % 8 == 0,
      '${CoverSpec.gap}');
  ck('网格外边距为 8 的倍数', CoverSpec.pad % 8 == 0, '${CoverSpec.pad}');
  ck('缩略圆角 < 卡片圆角（缩略嵌在列表行里，不是卡片）',
      CoverSpec.thumbRadius < CoverSpec.radius, '${CoverSpec.thumbRadius}');
  ck('照片墙圆角 <= 缩略圆角（照片墙是拼贴语义）',
      CoverSpec.photoRadius <= CoverSpec.thumbRadius, '${CoverSpec.photoRadius}');
  ck(
      '列表缩略尺寸为 40x56',
      CoverSpec.thumbWidth == 40 && CoverSpec.thumbHeight == 56,
      '${CoverSpec.thumbWidth}x${CoverSpec.thumbHeight}');

  // ═══════════════════════════════════════════════════════════════
  // 2. 表体完整性（防"加了 kind 忘登记"）
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 2. 表体完整性 ==');
  final decl = CoverKind.declared;
  final declSet = decl.toSet();
  final aspSet = CoverSpec.aspect.keys.toSet();
  final colSet = CoverSpec.columns.keys.toSet();

  ck('kind 常量清单非空（防被整体删空）', decl.isNotEmpty, '${decl.length}');
  ck('kind 常量清单无重复', decl.length == declSet.length,
      'decl=${decl.length} uniq=${declSet.length}');
  ck(
      '★ 每个 kind 常量都在比例表中登记（防"加常量漏登记 → 悄悄退回正方"）',
      declSet.containsAll(aspSet) && aspSet.containsAll(declSet),
      'decl=${declSet.length} aspect=${aspSet.length} '
          'missing=${declSet.difference(aspSet).join(",")} '
          'extra=${aspSet.difference(declSet).join(",")}');
  ck(
      '每个 kind 常量都在列数表中登记',
      declSet.containsAll(colSet) && colSet.containsAll(declSet),
      'decl=${declSet.length} columns=${colSet.length}');
  ck(
      '比例取值在合理区间 (0.3, 3.0]',
      CoverSpec.aspect.values.every((v) => v > 0.3 && v <= 3.0),
      CoverSpec.aspect.entries
          .where((e) => !(e.value > 0.3 && e.value <= 3.0))
          .map((e) => '${e.key}=${e.value}')
          .join(','));
  ck(
      '列数取值在合理区间 [2, 6]',
      CoverSpec.columns.values.every((v) => v >= 2 && v <= 6),
      CoverSpec.columns.entries
          .where((e) => !(e.value >= 2 && e.value <= 6))
          .map((e) => '${e.key}=${e.value}')
          .join(','));

  // ═══════════════════════════════════════════════════════════════
  // 3. 查表行为（含兜底）
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 3. 查表行为 ==');
  ck('未知 kind 取比例 → 兜底 1.0（不抛异常，界面不能因为传错字符串就崩）',
      CoverSpec.aspectOf('__nope__') == 1.0);
  ck('未知 kind 取列数 → 兜底 3', CoverSpec.columnsOf('__nope__') == 3);
  ck('isKnown 对已登记 kind 为 true', CoverSpec.isKnown(CoverKind.bookGrid));
  ck('isKnown 对未登记 kind 为 false', !CoverSpec.isKnown('__nope__'));
  ck('kinds 与 aspect 键集一致', CoverSpec.kinds.length == aspSet.length);

  // ★ 口径守卫：这是最容易被人"顺手改坏"的一条。
  //   bookGrid 的格子要同时装下 封面 + 书名 2 行 + 副标题 1 行，
  //   所以它必须比"纯封面网格"**更瘦高**。若有人把它调到 >= coverGrid，
  //   书封会被压扁、书名会被裁掉 —— 而那处不会报错。
  final bookA = CoverSpec.aspectOf(CoverKind.bookGrid);
  final coverA = CoverSpec.aspectOf(CoverKind.coverGrid);
  ck('★ 口径守卫：bookGrid 比 coverGrid 更瘦高（带书名条的格子）', bookA < coverA,
      'book=$bookA cover=$coverA');

  // ═══════════════════════════════════════════════════════════════
  // 4. 源码层：封面文件里不再有裸 `Image.network`
  //    ★ 这条才真正防"改一半"
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 4. 源码层：裸封面图已清零 ==');
  final mainSrc = tryRead(repoPath('flutter_app/lib/main.dart'));
  final edpSrc = tryRead(repoPath('flutter_app/lib/core/engine_direct_page.dart'));
  final mm4Src = tryRead(repoPath('flutter_app/lib/core/mini_modules4.dart'));
  final mm5Src = tryRead(repoPath('flutter_app/lib/core/mini_modules5.dart'));
  final nrSrc = tryRead(repoPath('flutter_app/lib/core/novel_reader.dart'));
  final ucSrc = tryRead(repoPath('flutter_app/lib/core/ui_cover.dart'));

  ck('确实读到了 main.dart（防路径错导致空串假绿）',
      mainSrc != null && mainSrc.length > 100000, 'len=${mainSrc?.length}');
  ck('确实读到了 ui_cover.dart', ucSrc != null && ucSrc.length > 2000,
      'len=${ucSrc?.length}');

  if (edpSrc != null) {
    ck('engine_direct_page.dart 已无裸封面图', netImgCount(edpSrc) == 0,
        'count=${netImgCount(edpSrc)}');
  }
  if (mm5Src != null) {
    ck('mini_modules5.dart（菜谱）已无裸封面图', netImgCount(mm5Src) == 0,
        'count=${netImgCount(mm5Src)}');
  }
  if (mm4Src != null) {
    ck('mini_modules4.dart 只剩壁纸预览大图（1 处）', netImgCount(mm4Src) == 1,
        'count=${netImgCount(mm4Src)}');
    ck('mini_modules4.dart 剩余那处确为预览大图（含 InteractiveViewer）',
        mm4Src.contains("InteractiveViewer(child: Image.network(w['path'],"));
  }
  if (nrSrc != null) {
    ck('novel_reader.dart 只剩正文插图（1 处）', netImgCount(nrSrc) == 1,
        'count=${netImgCount(nrSrc)}');
  }

  if (mainSrc != null) {
    // main.dart 允许保留的 `Image.network` **只有阅读器正文图**：
    // 它们的前缀必然是 `Api.img(images[` 或 `images[`（阅读页图片数组）。
    // 于是"谁往 main.dart 里加一处封面 Image.network"会立刻被抓住。
    final tails = netImgTails(mainSrc);
    final readerLike = tails
        .where((t) =>
            t.startsWith('Api.img(images[') || t.startsWith('images['))
        .length;
    final bad = tails.length - readerLike;
    ck('★ main.dart 剩余的 Image.network 全部是阅读器正文图',
        bad == 0, 'bad=$bad reader=$readerLike total=${tails.length}');
    ck('main.dart 阅读器正文图数量符合预期（4）', readerLike == 4,
        'reader=$readerLike');
    // 失败时直接给出**行号 + 紧跟的源码**，省掉"再grep一遍找是哪处"的往返。
    if (bad > 0) {
      for (final m in RegExp(r'Image\.network\(').allMatches(mainSrc)) {
        final t = mainSrc
            .substring(m.end, (m.end + 30).clamp(0, mainSrc.length))
            .replaceAll('\r', '')
            .replaceAll('\n', '/');
        if (!t.startsWith('Api.img(images[') && !t.startsWith('images[')) {
          final line =
              '\n'.allMatches(mainSrc.substring(0, m.start)).length + 1;
          print('       非阅读器处  main.dart:$line  →  $t');
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 5. 源码层：封面网格确实走了统一下发
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 5. 源码层：网格已走 coverDelegate ==');
  if (mainSrc != null) {
    ck('main.dart 小说书架 → coverDelegate(bookGrid)',
        mainSrc.contains('coverDelegate(CoverKind.bookGrid)'));
    ck('main.dart 直播频道 → coverDelegate(liveGrid)',
        mainSrc.contains('coverDelegate(CoverKind.liveGrid)'));
    ck('main.dart 已不再出现散落的小说网格比例 0.52',
        !mainSrc.contains('childAspectRatio: 0.52'));
    ck('main.dart 已不再出现散落的直播网格比例 0.75',
        !mainSrc.contains('childAspectRatio: 0.75'));
    // 剩下的 childAspectRatio 只允许是"非封面宫格"：剧集选择按钮(2.2)
    // 与 ModuleHubPage 的模块宫格(1.15)。
    ck('main.dart 剩余 childAspectRatio 只有 2 处（非封面宫格）',
        countOf(mainSrc, 'childAspectRatio') == 2,
        'count=${countOf(mainSrc, 'childAspectRatio')}');
  }
  if (edpSrc != null) {
    ck('engine_direct_page.dart → coverDelegate(coverGrid)',
        edpSrc.contains('coverDelegate(CoverKind.coverGrid)'));
  }
  if (mm4Src != null) {
    ck('mini_modules4.dart → coverDelegate(wallGrid)',
        mm4Src.contains('coverDelegate(CoverKind.wallGrid)'));
    ck('mini_modules4.dart 已无散落 childAspectRatio',
        !mm4Src.contains('childAspectRatio'));
  }
  if (mm5Src != null) {
    ck('mini_modules5.dart → coverDelegate(cardGrid)',
        mm5Src.contains('coverDelegate(CoverKind.cardGrid)'));
    ck('mini_modules5.dart 已无散落 childAspectRatio',
        !mm5Src.contains('childAspectRatio'));
  }

  // ═══════════════════════════════════════════════════════════════
  // 6. 源码层：统一组件真的被用上了 + import 齐备
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 6. 源码层：CoverImage/CoverThumb 使用与 import ==');
  if (mainSrc != null) {
    ck('main.dart 使用 CoverImage ≥ 3 处', countOf(mainSrc, 'CoverImage(') >= 3,
        '${countOf(mainSrc, 'CoverImage(')}');
    ck('main.dart 使用 CoverThumb ≥ 6 处（5 处书目列表 + 2 处专辑）',
        countOf(mainSrc, 'CoverThumb(') >= 6, '${countOf(mainSrc, 'CoverThumb(')}');
    ck('main.dart 私有兜底已收归 CoverFallback',
        mainSrc.contains('CoverFallback(name: b.name'));
  }
  for (final f in [
    'flutter_app/lib/main.dart',
    'flutter_app/lib/core/engine_direct_page.dart',
    'flutter_app/lib/core/mini_modules4.dart',
    'flutter_app/lib/core/mini_modules5.dart',
  ]) {
    final s = tryRead(repoPath(f));
    ck('${f.split('/').last} 已 import ui_cover.dart',
        s != null && s.contains('ui_cover.dart'));
  }

  // ═══════════════════════════════════════════════════════════════
  // 7. 兜底配色：同名恒定、不同名分散
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 7. 兜底配色（源码断言）==');
  if (ucSrc != null) {
    ck('兜底调色板存在且为 6 组', countOf(ucSrc, '0xFF') >= 12,
        '${countOf(ucSrc, '0xFF')}');
    ck('兜底取首字按码点（不切坏 emoji/代理对）',
        ucSrc.contains('String.fromCharCodes(t.runes.take(1))'));
    ck('CoverImage 强制带 loadingBuilder', ucSrc.contains('loadingBuilder:'));
    ck('CoverImage 强制带 errorBuilder', ucSrc.contains('errorBuilder:'));
    ck('空 URL 不发请求（先判空再 Image.network）',
        ucSrc.contains('_empty ? _fallback(context) : _network(context)'));
  }

  // ═══════════════════════════════════════════════════════════════
  // 8. 封面地址收口：Book.coverSrc
  //
  // 起因（用户 2026-10-01 报）：引擎里搜到的小说，加进书架后封面没了。
  // 根因是书架把引擎侧封面地址又套了一次 `Api.img()`（补后端前缀）→ 404 → 兜底。
  // 搜索结果列表写了三目判断，书架 / 历史各写各的、多数漏写。
  // 现在统一收口到 `Book.coverSrc`，这道断言守着"不再回退"。
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 8. 封面地址收口（源码断言）==');
  if (mainSrc != null) {
    ck('Book 提供 coverSrc 取值出口', mainSrc.contains('String get coverSrc'));
    ck('coverSrc 对引擎书原样返回、其余才补前缀',
        mainSrc.contains("sourceId == 'engine' ? u : Api.img(u)"));
    ck('书架卡片改用 b.coverSrc', mainSrc.contains('CoverImage(b.coverSrc'));
    ck('阅读历史改用 b.coverSrc', mainSrc.contains('CoverThumb(b.coverSrc'));
    // 反证：给 Book 对象再套一次 Api.img 的写法必须为零 ——
    // 它正是"引擎搜到有封面、加书架就没了"的成因，绝不允许复发。
    final relapsed = countOf(mainSrc, 'Api.img(b.coverUrl)');
    ck('无 Api.img(b.coverUrl) 残留（Book 封面二次加前缀）', relapsed == 0,
        'count=$relapsed');
  }

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail > 0) exit(1);
}
