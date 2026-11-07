// Mangayomi 双页索引数学 移植自检（纯 Dart VM，零 Flutter 依赖）
//
//   dart run tool/mangayomi_double_page_selfcheck.dart
//
// 为什么必须有这条闸门：#205 第 16 轮把 Mangayomi 的
// reader_page_index_math.dart 与配套类型投影搬进漫画阅读器。这类「抄现成开源」
// 的改动错了不会报错、不会崩，只会静默表现成「双页时页码乱跳」「翻到一半
// 跨话配对」「第一屏把封面和下一页挤在一起」，而 analyze / 编译 / 台账闸门全绿。
// 尤其四类病：
//   ① 照印象重写：上游的跨章/宽页/过渡页分组规则被顺手简化；
//   ② 搬来摆着：文件在、main.dart 没接，界面上一点变化都没有；
//   ③ 把上游 UChapDataPreload 整类连 Chapter / PageUrl / riverpod 一起拖进来，
//      移动端直接编译不过；
//   ④ 只搬了分页、忘了页码标签与判页边界，双页模式下翻页越界。
//
// 五层断言：§1 文件与出处 / §2 上游正文逐字（关键行 + 长度闸 + 本地镜像逐字节）/
//           §3 依赖白名单与类型投影 / §4 main.dart 接线 / §5 台账 + CI + 六语言 + 合规。
// ★ 末尾 exit(1)：CI 只看退出码，打印 FAIL 不等于拦住了（2026-09-28 血泪）。
import 'dart:convert';
import 'dart:io';

int pass = 0, fail = 0, skip = 0;
final List<String> failures = <String>[];

void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    failures.add(name);
    print('  FAIL  $name');
  }
}

void skipped(String name) {
  skip++;
  print('  SKIP  $name');
}

String readOr(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : '';
}

/// 从「首个 import 行」之后切出正文（不硬编码头部行数；出处注释可增可减）。
String bodyAfterFirstImport(String src, String firstImport) {
  final lines = src.split('\n');
  final idx = lines.indexWhere((l) => l.trim() == firstImport);
  return idx < 0 ? '' : lines.sublist(idx + 1).join('\n');
}

/// 上游 kodjodevf/mangayomi@91bda20a9235 的 reader_page_index_math.dart
/// 去掉首行 import 之后，共 298 行 / 9351 字节（2026-11-08 实测）。
const int kUpstreamBodyBytes = 9351;
const int kUpstreamBodyLines = 298;

/// 上游算法的关键行（原样摘录，防「照印象重写」）。只选不含引号与 $ 的行，
/// 避免 Dart 字符串转义把闸门自己写坏（2026-11-08 第 15 轮踩过 raw string 坑）。
const List<String> kUpstreamKeyLines = <String>[
  'class DoublePageSpread {',
  '  bool get isSingle => secondIndex == null;',
  'class ReaderPageIndexMath {',
  '  List<DoublePageSpread>? _cachedSpreads;',
  '  List<DoublePageSpread> get spreads {',
  '  static List<DoublePageSpread> buildSpreads(',
  '    if (pages.isEmpty) return const [];',
  '      if (current.isTransitionPage) {',
  '        result.add(DoublePageSpread(i));',
  '      final chapterId = current.chapter?.id;',
  '      while (i < n &&',
  '      final int runEnd = i; // exclusive',
  '      if (singleFirst && cIdx < runEnd) {',
  '        if (_isPageWide(p1)) {',
  '          result.add(DoublePageSpread(cIdx, cIdx + 1));',
  '  static bool _isPageWide(UChapDataPreload page) {',
  '    return w > h;',
  '  static List<DoublePageSpread> _buildSyntheticSpreads(',
  '        result.add(DoublePageSpread(i, i + 1));',
  '  int pageViewToActualIndex(int pageViewIndex) {',
  '    final clampedPv = pageViewIndex.clamp(0, s.length - 1);',
  '    return s[clampedPv].firstIndex;',
  '  int actualToPageViewIndex(int actualIndex) {',
  '    final clampedActual = actualIndex.clamp(0, pageCount - 1);',
  '  int get pageViewPageCount {',
  '    return spreads.length;',
  '  String chapterPageLabel(int pageInChapter, int? chapterId, int totalPages) {',
  '  String currentIndexLabel(int index, int totalPages) {',
  '    if (index < 0) return',
  '    if (singleFirst) {',
  '      final pv = (index + 1) ~/ 2;',
  '    } else {',
  '      final pv = index ~/ 2;',
  '      final p2 = p1 + 1;',
];

void main() {
  const mathRel = 'lib/vendor/mangayomi/reader_page_index_math.dart';
  const shimRel = 'lib/vendor/mangayomi/u_chap_data_preload_min.dart';
  const firstImport = "import 'u_chap_data_preload_min.dart';";
  final math = readOr(mathRel);
  final shim = readOr(shimRel);
  final mainSrc = readOr('lib/main.dart');
  final i18nWords = readOr('lib/core/i18n_ui_words.dart');
  final i18nCore = readOr('lib/core/i18n.dart');
  final manifest = readOr('../vendor/MANIFEST.json');
  final yml = readOr('../.github/workflows/dart-selfcheck.yml');

  // ── §1 文件存在 + 头部出处 ────────────────────────────────────────────
  ck('§1 reader_page_index_math.dart 存在', math.isNotEmpty);
  ck('§1 u_chap_data_preload_min.dart 存在', shim.isNotEmpty);
  for (final e in <String, String>{'算法': math, '类型投影': shim}.entries) {
    final head = e.value.split('\n').take(14).join('\n');
    ck('§1 ${e.key} 头部有「上游:」出处行', head.contains('上游:'));
    ck('§1 ${e.key} 头部有「许可证: Apache-2.0」', head.contains('许可证: Apache-2.0'));
    ck('§1 ${e.key} 头部出处含上游 repo', head.contains('kodjodevf/mangayomi'));
    ck('§1 ${e.key} 头部出处含上游 commit', head.contains('91bda20a9235'));
    ck('§1 ${e.key} 头部写明上游路径', head.contains('上游路径:'));
    ck('§1 ${e.key} 头部写明台账 id', head.contains('台账:'));
  }

  // ── §2 上游正文逐字一致 ───────────────────────────────────────────────
  final body = bodyAfterFirstImport(math, firstImport);
  ck('§2 正文可从首个 import 行切出', body.isNotEmpty);
  ck('§2 正文字节数 = $kUpstreamBodyBytes（防整段重写）',
      body.isNotEmpty && utf8.encode(body).length == kUpstreamBodyBytes);
  ck('§2 正文行数 = $kUpstreamBodyLines', body.split('\n').length == kUpstreamBodyLines);
  for (final line in kUpstreamKeyLines) {
    ck('§2 上游关键行逐字保留: $line', body.contains(line));
  }
  // 上游核心数值/规则不能被顺手改掉
  ck('§2 过渡页单独占屏', body.contains('Transition pages always stand alone'));
  ck('§2 跨章不配对', body.contains('A chapter\'s pages never pair across chapters'));
  ck('§2 首页单放由 singleFirst 控制', body.contains('If [singleFirst] is true'));
  ck('§2 页码标签双页显示连字符', body.contains('or "12-13" for a double-page spread'));
  ck('§2 双页 spread 类有 == / hashCode / toString',
      body.contains('bool operator ==(Object other)') &&
      body.contains('int get hashCode => Object.hash(firstIndex, secondIndex);') &&
      body.contains('String toString() =>'));
  ck('§2 构造时 pages 为空走合成路径',
      body.contains('// Fallback when `pages` list object is not provided:'));
  ck('§2 pageViewToActualIndex 单页直通',
      body.contains('if (!isDoublePageActive) return pageViewIndex;'));
  ck('§2 actualToPageViewIndex 单页直通',
      body.contains('if (!isDoublePageActive) return actualIndex;'));

  // 本地镜像存在则逐字节比对（CI 不携带镜像 → SKIP 并计数，但上面的断言一条不少）
  const mirrorRel = '../vendor/_upstream/mangayomi/lib/modules/manga/reader/utils/reader_page_index_math.dart';
  final mirrorFile = File(mirrorRel);
  if (!mirrorFile.existsSync()) {
    skipped('vendor/_upstream/mangayomi 未随仓库携带，跳过上游镜像逐字节比对');
  } else {
    final up = mirrorFile.readAsStringSync();
    final upBody = bodyAfterFirstImport(
        up, "import 'package:mangayomi/modules/manga/reader/u_chap_data_preload.dart';");
    ck('§2 本地算法正文与上游镜像逐字节一致', upBody == body);
    ck('§2 上游镜像去掉 import 后字节数一致',
        upBody.length == body.length && upBody.length == kUpstreamBodyBytes);
  }

  // ── §3 依赖白名单 + 类型投影完整性 ────────────────────────────────────
  final allSrc = '$math\n$shim';
  final imports = <String>[];
  for (final line in allSrc.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('import ')) continue;
    final q1 = t.indexOf("'");
    final q2 = t.lastIndexOf("'");
    if (q1 >= 0 && q2 > q1) imports.add(t.substring(q1 + 1, q2));
  }
  ck('§3 两份文件合计恰好 1 条 import', imports.length == 1);
  ck('§3 唯一 import 指向本地类型投影', imports.length == 1 && imports.single == 'u_chap_data_preload_min.dart');
  ck('§3 算法文件用相对 import 引用投影', math.contains("import 'u_chap_data_preload_min.dart';"));
  ck('§3 不含上游绝对 package:mangayomi import',
      !allSrc.contains("import 'package:mangayomi/"));
  for (final bad in <String>['riverpod', 'shiori', 'photo_view', 'isar', 'dart:ffi', 'flutter_riverpod']) {
    ck('§3 不引入 $bad（按 import 行判定）', !imports.any((i) => i.contains(bad)));
  }
  ck('§3 无 part / part of（不是共享作用域的分片）',
      !allSrc.contains('part of ') && !RegExp(r'^part ', multiLine: true).hasMatch(allSrc));
  // 类型投影：算法真正读到的字段一个都不能少
  ck('§3 类型投影定义 UChapDataPreload', shim.contains('class UChapDataPreload {'));
  ck('§3 类型投影定义 UChapChapterRef', shim.contains('class UChapChapterRef {'));
  for (final f in <String>['chapter', 'index', 'isTransitionPage', 'loadedWidth', 'loadedHeight']) {
    ck('§3 类型投影含字段 $f', shim.contains('$f;') || shim.contains('$f,') || shim.contains('$f ='));
  }
  ck('§3 类型投影零 import', !shim.split('\n').any((l) => l.trim().startsWith('import ')));

  // ── §4 接线：文件不是搬来摆着 ─────────────────────────────────────────
  ck('§4 main.dart import reader_page_index_math.dart',
      mainSrc.contains("import 'vendor/mangayomi/reader_page_index_math.dart';"));
  ck('§4 _Ecr 声明 doublePage 开关', mainSrc.contains('bool doublePage = false;'));
  ck('§4 _Ecr 声明 curPage 当前屏', mainSrc.contains('int curPage = 0;'));
  ck('§4 pageMath getter 用 isDoublePageActive: doublePage && paged',
      mainSrc.contains('isDoublePageActive: doublePage && paged,'));
  ck('§4 pageMath getter 用 singleFirst: true（封面单独占一屏）',
      mainSrc.contains('singleFirst: true,'));
  ck('§4 pageMath getter 用 pageCount: images.length',
      mainSrc.contains('pageCount: images.length,'));
  ck('§4 翻页屏数改用 pageMath.pageViewPageCount',
      mainSrc.contains('itemCount: pageMath.pageViewPageCount,'));
  ck('§4 每屏按上游 spreads 分组取页',
      mainSrc.contains('final spread = pageMath.spreads[i];'));
  ck('§4 双页时用 Row 并排两张且间距 8',
      mainSrc.contains('Row(children: [') && mainSrc.contains('const SizedBox(width: 8),'));
  ck('§4 单页回落仍取 spread.firstIndex',
      mainSrc.contains(': _img(spread.firstIndex);'));
  ck('§4 判页边界改用屏数（不再用 images.length）',
      mainSrc.contains('if (target >= 0 && target < pageMath.pageViewPageCount) {'));
  ck('§4 页码标签用 currentIndexLabel + pageViewToActualIndex',
      mainSrc.contains('pageMath.currentIndexLabel(') &&
      mainSrc.contains('pageMath.pageViewToActualIndex(curPage),'));
  ck('§4 AppBar 双页开关仅翻页模式显示且文案走 tr()',
      mainSrc.contains("tooltip: doublePage ? tr('单页') : tr('双页'),"));
  ck('§4 换话重置当前屏', mainSrc.contains('curPage = 0;'));
  ck('§4 既有 WebtoonScrollPhysics / ReaderMotion 接线未被破坏',
      mainSrc.contains('physics: const WebtoonScrollPhysics(),') &&
      mainSrc.contains('duration: ReaderMotion.settle(') &&
      mainSrc.contains('curve: ReaderMotion.quinticOut);'));
  ck('§4 接线点在 _Ecr 漫画阅读器内',
      mainSrc.indexOf('class _Ecr extends State<EngineComicReader>') <
          mainSrc.indexOf('itemCount: pageMath.pageViewPageCount,'));

  // ── §5 台账 / CI / i18n 六语言 / 合规 ─────────────────────────────────
  ck('§5 台账登记 mangayomi_page_index_math',
      manifest.contains('"id": "mangayomi_page_index_math"'));
  ck('§5 台账登记 mangayomi_u_chap_shim',
      manifest.contains('"id": "mangayomi_u_chap_shim"'));
  ck('§5 台账声明 wired_in 指向 main.dart',
      manifest.contains('"wired_in"') && manifest.contains('"flutter_app/lib/main.dart"'));
  ck('§5 台账 schema 未变', manifest.contains('"schema": "thirdhub.vendor_manifest/1"'));
  ck('§5 台账仍把 Namida 留在 blocked（EULA 不可搬）',
      manifest.contains('"upstream": "namida"') && manifest.contains('"blocked"'));
  ck('§5 CI 接了本自检 step',
      yml.contains('dart run tool/mangayomi_double_page_selfcheck.dart'));
  ck('§5 CI step 排在 mangayomi_motion 之后、local_agent 之前',
      yml.indexOf('dart run tool/mangayomi_motion_selfcheck.dart') <
          yml.indexOf('dart run tool/mangayomi_double_page_selfcheck.dart') &&
      yml.indexOf('dart run tool/mangayomi_double_page_selfcheck.dart') <
          yml.indexOf('dart run tool/local_agent_selfcheck.dart'));
  ck('§5 i18n 第 19 批存在', i18nWords.contains('i18nUiWords19'));
  ck('§5 i18n.dart 合并了第 19 批', i18nCore.contains('i18nUiWords19.forEach'));
  final batch = i18nWords.contains('i18nUiWords19')
      ? i18nWords.substring(i18nWords.indexOf('i18nUiWords19')) : '';
  for (final lang in <String>['en', 'ja', 'fr', 'ru', 'es', 'ar']) {
    // 逐语言块切片，不用全文 contains —— 否则「任一语言补了」就会让全部语言假绿。
    final marker = "'$lang': {";
    final at = batch.indexOf(marker);
    final block = at < 0
        ? ''
        : batch.substring(at, at + 400 > batch.length ? batch.length : at + 400);
    ck('§5 第 19 批有 $lang 语言块', at >= 0);
    for (final key in <String>['双页', '单页']) {
      ck('§5 第 19 批 $lang 含译文「$key」', block.contains('"$key"'));
    }
  }
  for (final t in <String>['copy_manga', 'baozi', 'jmcomic', '禁漫', '书源', '图源']) {
    ck('§5 移植文件不含第三方内容源标识「$t」', !allSrc.contains(t));
  }
  ck('§5 移植文件不含 emoji',
      !RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true).hasMatch(allSrc));

  print('\n$pass 通过 / $fail 失败 / $skip 跳过');
  if (fail > 0) {
    print('Mangayomi 双页索引数学移植与上游或接线不一致，已拦下。');
    print('首条失败: ${failures.first}');
    exit(1);
  }
}
