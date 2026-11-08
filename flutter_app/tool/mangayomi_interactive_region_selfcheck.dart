// Mangayomi 阅读器交互区 移植自检（纯 Dart VM，零 Flutter 依赖）
//
//   dart run tool/mangayomi_interactive_region_selfcheck.dart
//
// 为什么必须有这条闸门：#205 第 18 轮把 Mangayomi 的
// reader_interactive_region.dart 搬进漫画阅读器，用来补回 comic_image.dart
// 头注释里记着「因缺手势协调而删掉的 ignoreNextTap」这笔欠账。
// 错了不报错、不崩，只会静默表现成「点重试按钮顺带翻一页」，而 analyze /
// 编译 / 台账闸门全绿。四类病：
//   ① 照印象重写：注册表的 hasSize / attached 守卫与 globalToLocal 被简化；
//   ② 搬来摆着：文件在、两处接线没有，界面行为一点没变；
//   ③ 把 riverpod / shiori / 绝对 package:mangayomi import 带进来，移动端编译不过；
//   ④ 只包了按钮却没在 _onReaderTap 让位（或让位写在判页之后），冲突照旧。
//
// 五层断言：§1 文件与出处 / §2 上游正文逐字（内嵌全文，CI 不依赖本地镜像）/
//           §3 依赖白名单 / §4 两处接线 + 顺序 / §5 台账 + CI + 版本 + 合规。
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

/// 上游正文（kodjodevf/mangayomi@91bda20a9235，逐字内嵌；本地镜像缺失也拦得住）。
const String kUpstreamBody = r'''import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Registry of interactive regions in the reader (e.g. Retry buttons on failed pages)
/// that should take priority over reader gesture overlay tap handlers.
class ReaderInteractiveRegions {
  static final Set<GlobalKey> _keys = {};

  static void register(GlobalKey key) => _keys.add(key);
  static void unregister(GlobalKey key) => _keys.remove(key);

  /// Checks whether [globalPosition] falls inside any currently active and mounted
  /// interactive region.
  static bool containsPosition(Offset globalPosition) {
    if (_keys.isEmpty) return false;
    for (final key in _keys) {
      final context = key.currentContext;
      if (context == null) continue;
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize && renderBox.attached) {
        final localPos = renderBox.globalToLocal(globalPosition);
        if (renderBox.paintBounds.contains(localPos)) {
          return true;
        }
      }
    }
    return false;
  }
}

/// A widget that registers its subtree as an interactive region that bypasses
/// the reader gesture overlays.
class ReaderInteractiveRegion extends StatefulWidget {
  final Widget child;
  const ReaderInteractiveRegion({super.key, required this.child});

  @override
  State<ReaderInteractiveRegion> createState() =>
      _ReaderInteractiveRegionState();
}

class _ReaderInteractiveRegionState extends State<ReaderInteractiveRegion> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    ReaderInteractiveRegions.register(_key);
  }

  @override
  void dispose() {
    ReaderInteractiveRegions.unregister(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

/// A widget that wraps reader overlays and prevents them from capturing hit tests
/// if the touch location falls inside a registered [ReaderInteractiveRegion].
class ReaderInteractiveHitTestBlocker extends SingleChildRenderObjectWidget {
  const ReaderInteractiveHitTestBlocker({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderReaderInteractiveHitTestBlocker();
  }
}

class _RenderReaderInteractiveHitTestBlocker extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final Offset globalPos = localToGlobal(position);
    if (ReaderInteractiveRegions.containsPosition(globalPos)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}
''';

/// 从「首个 import 行」起切出正文（不硬编码头部行数；出处注释可增可减）。
String bodyOf(String src) {
  final lines = const LineSplitter().convert(src);
  String? first;
  for (final l in lines) {
    if (l.startsWith('import ')) {
      first = l;
      break;
    }
  }
  if (first == null) return '';
  final at = src.indexOf(first);
  return at < 0 ? '' : src.substring(at);
}

List<String> importLinesOf(String src) => const LineSplitter()
    .convert(src)
    .where((l) => l.startsWith('import ') || l.startsWith('export '))
    .toList();

void main() {
  final local = readOr('lib/vendor/mangayomi/reader_interactive_region.dart');
  final comic = readOr('lib/core/comic_image.dart');
  final mainSrc = readOr('lib/main.dart');
  final manifest = readOr('../vendor/MANIFEST.json');
  final ci = readOr('../.github/workflows/dart-selfcheck.yml');
  final av = readOr('lib/core/app_version.dart');
  final pub = readOr('pubspec.yaml');
  final readme = readOr('../README.md');
  final cl = readOr('../build-out/changelog.json');
  final body = local.isEmpty ? '' : bodyOf(local);
  final comicLines = const LineSplitter().convert(comic);
  final mainLines = const LineSplitter().convert(mainSrc);

  // ── §1 文件与出处 ──────────────────────────────────────────────
  ck('§1 移植文件存在', local.isNotEmpty);
  final head = const LineSplitter().convert(local).take(12).join('\n');
  ck('§1 头部有「上游:」出处行', head.contains('上游:'));
  ck('§1 头部有「许可证:」', head.contains('许可证:'));
  ck('§1 头部写明 repo@commit', head.contains('kodjodevf/mangayomi@91bda20a9235'));
  ck('§1 头部许可证为 Apache-2.0', head.contains('Apache-2.0'));
  ck('§1 头部写明上游路径',
      head.contains('lib/modules/manga/reader/widgets/reader_interactive_region.dart'));
  ck('§1 头部写明台账 id', head.contains('mangayomi_interactive_region'));
  ck('§1 文件首条 import 是 flutter/rendering.dart',
      body.startsWith("import 'package:flutter/rendering.dart';"));

  // ── §2 上游正文逐字 ────────────────────────────────────────────
  ck('§2 上游正文逐字一致（内嵌全文）', body == kUpstreamBody);
  ck('§2 上游正文 2688 字节长度闸', utf8.encode(body).length == 2688);
  ck('§2 上游正文 83 行（LineSplitter 不计末尾换行）',
      const LineSplitter().convert(body).length == 83);
  for (final line in <String>[
    'class ReaderInteractiveRegions {',
    '  static final Set<GlobalKey> _keys = {};',
    '  static void register(GlobalKey key) => _keys.add(key);',
    '  static void unregister(GlobalKey key) => _keys.remove(key);',
    '  static bool containsPosition(Offset globalPosition) {',
    '    if (_keys.isEmpty) return false;',
    '    for (final key in _keys) {',
    '      final context = key.currentContext;',
    '      if (context == null) continue;',
    '      final renderBox = context.findRenderObject() as RenderBox?;',
    '      if (renderBox != null && renderBox.hasSize && renderBox.attached) {',
    '        final localPos = renderBox.globalToLocal(globalPosition);',
    '        if (renderBox.paintBounds.contains(localPos)) {',
    'class ReaderInteractiveRegion extends StatefulWidget {',
    '  final Widget child;',
    '  const ReaderInteractiveRegion({super.key, required this.child});',
    '    ReaderInteractiveRegions.register(_key);',
    '    ReaderInteractiveRegions.unregister(_key);',
    '    return KeyedSubtree(key: _key, child: widget.child);',
    'class ReaderInteractiveHitTestBlocker extends SingleChildRenderObjectWidget {',
    '  const ReaderInteractiveHitTestBlocker({super.key, required super.child});',
    '    return _RenderReaderInteractiveHitTestBlocker();',
    'class _RenderReaderInteractiveHitTestBlocker extends RenderProxyBox {',
    '  bool hitTest(BoxHitTestResult result, {required Offset position}) {',
    '    final Offset globalPos = localToGlobal(position);',
    '    if (ReaderInteractiveRegions.containsPosition(globalPos)) {',
    '      return false;',
    '    return super.hitTest(result, position: position);',
  ]) {
    ck('§2 上游关键行: $line', body.contains(line));
  }
  ck('§2 命中判定三个守卫未被简化',
      body.contains('renderBox != null && renderBox.hasSize && renderBox.attached') &&
          body.contains('renderBox.globalToLocal(globalPosition)') &&
          body.contains('renderBox.paintBounds.contains(localPos)'));
  ck('§2 空注册表早退仍在', body.contains('if (_keys.isEmpty) return false;'));
  ck('§2 注销在 dispose 中调用', body.contains('ReaderInteractiveRegions.unregister(_key);'));

  // ── §3 依赖白名单 ──────────────────────────────────────────────
  final imports = importLinesOf(body);
  ck('§3 移植文件只有 2 条 import', imports.length == 2);
  ck('§3 import 为 flutter/rendering.dart 与 flutter/widgets.dart',
      imports.length == 2 &&
          imports[0] == "import 'package:flutter/rendering.dart';" &&
          imports[1] == "import 'package:flutter/widgets.dart';");
  for (final banned in <String>[
    'package:mangayomi',
    'package:shiori',
    'flutter_riverpod',
    'package:photo_view',
    "part of",
    "import 'dart:io'",
    "import 'dart:convert'",
  ]) {
    ck('§3 移植文件不含依赖「$banned」', !body.contains(banned));
  }

  // ── §4 两处接线（按行首精确匹配，注释残骸不算） ─────────────────
  const comicImport =
      "import '../vendor/mangayomi/reader_interactive_region.dart';";
  const mainImport =
      "import 'vendor/mangayomi/reader_interactive_region.dart';";
  ck('§4 comic_image.dart 引入移植文件', comic.contains(comicImport));
  ck('§4 comic_image import 是行首语句（不是注释残骸）',
      comicLines.any((l) => l.trim() == comicImport));
  ck('§4 main.dart 引入移植文件', mainSrc.contains(mainImport));
  ck('§4 main import 是行首语句（不是注释残骸）',
      mainLines.any((l) => l.trim() == mainImport));
  ck('§4 失败态「重试」按钮被 ReaderInteractiveRegion 包住',
      comic.contains('ReaderInteractiveRegion(') &&
          comic.contains("Text(tr('重试')"));
  // contains 会被「注掉调用后残留在注释里的同一字符串」骗过（变异反证抓到），
  // 必须按行首精确匹配，确保它真是一条 widget 构造语句。
  ck('§4 ReaderInteractiveRegion 是真实代码行（不是注释残骸）',
      comicLines.any((l) => l.trim() == 'ReaderInteractiveRegion('));
  // 包裹必须在按钮之前（否则只是同名字符串摆设）
  final regionAt = comic.indexOf('ReaderInteractiveRegion(');
  final retryAt = comic.indexOf("Text(tr('重试')");
  ck('§4 ReaderInteractiveRegion 出现在重试按钮之前',
      regionAt >= 0 && retryAt > regionAt);
  ck('§4 头注释记录 ignoreNextTap 欠账已由交互区注册表替代',
      comic.contains('ignoreNextTap()') &&
          comic.contains('交互区注册表替代'));
  ck('§4 _onReaderTap 有交互区让位守卫',
      mainSrc.contains('if (ReaderInteractiveRegions.containsPosition(pos)) return;'));
  final guardLine = '    if (ReaderInteractiveRegions.containsPosition(pos)) return;';
  ck('§4 让位守卫是行首语句', mainLines.any((l) => l == guardLine));
  final ecrAt = mainSrc.indexOf('void _onReaderTap(Offset pos, Size size, int i) {');
  final guardAt = ecrAt < 0 ? -1 : mainSrc.indexOf(guardLine, ecrAt);
  final hitAt = ecrAt < 0 ? -1 : mainSrc.indexOf('ComicTapHit.at(', ecrAt);
  ck('§4 让位守卫在判页之前（顺序关键）',
      ecrAt >= 0 && guardAt > ecrAt && hitAt > guardAt);
  ck('§4 既有双页 / 动效 / 滑杆接线未被破坏',
      mainSrc.contains('itemCount: pageMath.pageViewPageCount,') &&
          mainSrc.contains('physics: const WebtoonScrollPhysics(),') &&
          mainSrc.contains('const CustomValueIndicatorShape()') &&
          mainSrc.contains('duration: ReaderMotion.settle('));

  // ── §5 台账 / CI / 版本 / 合规 ─────────────────────────────────
  ck('§5 台账登记了 mangayomi_interactive_region',
      manifest.contains('"id": "mangayomi_interactive_region"'));
  ck('§5 台账 upstream_path 指向上游 widgets 路径',
      manifest.contains('lib/modules/manga/reader/widgets/reader_interactive_region.dart'));
  ck('§5 台账 local 指向实际移植文件',
      manifest.contains('flutter_app/lib/vendor/mangayomi/reader_interactive_region.dart'));
  ck('§5 台账声明 wired_in 含 main.dart 与 comic_image.dart',
      manifest.contains('"wired_in"') &&
          manifest.contains('"flutter_app/lib/core/comic_image.dart"'));
  ck('§5 台账标注 Apache-2.0 与本轮版本',
      manifest.contains('"license": "Apache-2.0"') && manifest.contains('"since": "4.81.56"'));
  ck('§5 台账写入第 18 轮上游复测结论',
      manifest.contains('第 18 轮') && manifest.contains('reader_interactive_region.dart'));
  ck('§5 CI 有 mangayomi_interactive_region 步骤',
      ci.contains('tool/mangayomi_interactive_region_selfcheck.dart') &&
          ci.contains('mangayomi_interactive_region（'));
  // ★ 版本断言不写死：从唯一来源 app_version.dart 读当前版本，再要求三件套与
  // changelog 跟它一致。血泪：上一轮闸门把 4.81.55 硬编码，升到 4.81.56 就假红，
  // 每轮发版都得回来改旧闸门 —— 本闸门从一开始就避开这个雷。
  final verMatch = RegExp(r"kAppVersion = '([0-9.]+)'").firstMatch(av);
  final codeMatch = RegExp(r'kAppCode = ([0-9]+)').firstMatch(av);
  final curVer = verMatch?.group(1) ?? '';
  final curCode = codeMatch?.group(1) ?? '';
  ck('§5 能从唯一来源读出当前版本', curVer.isNotEmpty && curCode.isNotEmpty);
  ck('§5 版本三件套与唯一来源一致（$curVer / $curCode）',
      pub.contains('version: $curVer+$curCode') &&
          readme.contains(curVer) &&
          readme.contains(curCode));
  ck('§5 changelog 首条为当前版本（$curVer）',
      cl.contains('"latest": "$curVer"') && cl.contains('"v": "$curVer"'));
  ck('§5 changelog 历史 4.81.55 条目仍在',
      cl.contains('"v": "4.81.55"'));
  for (final t in <String>[
    'copy_manga',
    'baozi',
    'jmcomic',
    '禁漫',
    '书源',
    '图源',
  ]) {
    ck('§5 移植文件不含第三方内容源标识「$t」', !local.contains(t));
  }
  ck('§5 移植文件不含 emoji',
      !RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true)
          .hasMatch(local));
  // 本轮零新增 UI 文案：复用既有 tr('重试')，不新增任何 tr( 键。
  ck('§5 新增接线零新增 UI 文案（复用 tr(重试)）',
      comic.contains("Text(tr('重试')") &&
          !comic.contains("tr('重试加载") &&
          guardLine.contains('containsPosition'));
  ck('§5 i18n 六语言「重试」键仍在（不新增键、不改字典）',
      (() {
        final w = readOr('lib/core/i18n_ui_words.dart');
        return ( "'重试'".allMatches(w).length) >= 6;
      })());

  // 本地镜像层：CI 不携带镜像，打印 SKIP 不伪装成通过；本地存在则逐字节核对。
  const mirrorPath =
      '../vendor/_upstream/mangayomi/lib/modules/manga/reader/widgets/reader_interactive_region.dart';
  final mirror = File(mirrorPath);
  if (!mirror.existsSync()) {
    skipped('§2 本地上游镜像未随仓库携带，逐字节核对跳过（CI 用内嵌全文断言）');
  } else {
    ck('§2 本地上游镜像与内嵌全文逐字节一致',
        mirror.readAsStringSync() == kUpstreamBody);
  }

  print('\n$pass 通过 / $fail 失败 / $skip 跳过');
  if (fail > 0) {
    print('Mangayomi 交互区移植与上游或接线不一致，已拦下。');
    print('首条失败: ${failures.first}');
    exit(1);
  }
}
