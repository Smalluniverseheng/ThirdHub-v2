// Mangayomi 页码滑杆指示器 移植自检（纯 Dart VM，零 Flutter 依赖）
//
//   dart run tool/mangayomi_page_slider_selfcheck.dart
//
// 为什么必须有这条闸门：#205 第 17 轮把 Mangayomi 的
// custom_value_indicator_shape.dart 搬进漫画阅读器底部页码滑杆。这类「抄现成开源」
// 的改动错了不报错、不崩，只会静默表现成「拖进度条没有页码气泡」「从右往左阅读时
// 气泡没镜像」「或者文件搬来了但 SliderTheme 根本没接」，而 analyze / 编译 / 台账闸门全绿。
// 四类病：
//   ① 照印象重写：上游的 canvas.scale(-1.0, 1.0) 与 canvas.save/restore 被顺手简化；
//   ② 搬来摆着：文件在、main.dart 没接，界面上一点变化都没有；
//   ③ 把 riverpod / shiori / package:mangayomi 绝对 import 带进来，移动端直接编译不过；
//   ④ 只加了 Slider、忘了双页页码换算与翻页动画，拖动后页码与画面对不上。
//
// 五层断言：§1 文件与出处 / §2 上游正文逐字（内嵌全文，CI 不依赖本地镜像）/
//           §3 依赖白名单 / §4 main.dart 接线 / §5 台账 + CI + 版本 + 合规。
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
const String kUpstreamBody = r'''import 'package:flutter/material.dart';

class CustomValueIndicatorShape extends SliderComponentShape {
  final _indicatorShape = const PaddleSliderValueIndicatorShape();
  final bool tranform;
  const CustomValueIndicatorShape({this.tranform = false});
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(40, 40);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final textSpan = TextSpan(
      text: labelPainter.text?.toPlainText(),
      style: sliderTheme.valueIndicatorTextStyle,
    );

    final textPainter = TextPainter(
      text: textSpan,
      textAlign: labelPainter.textAlign,
      textDirection: textDirection,
    );

    textPainter.layout();

    context.canvas.save();
    context.canvas.translate(center.dx, center.dy);
    context.canvas.scale(tranform ? -1.0 : 1.0, 1.0);
    context.canvas.translate(-center.dx, -center.dy);

    _indicatorShape.paint(
      context,
      center,
      activationAnimation: activationAnimation,
      enableAnimation: enableAnimation,
      labelPainter: textPainter,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      value: value,
      textScaleFactor: textScaleFactor,
      sizeWithOverflow: sizeWithOverflow,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
    );

    context.canvas.restore();
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
  final local = readOr('lib/vendor/mangayomi/custom_value_indicator_shape.dart');
  final mainSrc = readOr('lib/main.dart');
  final manifest = readOr('../vendor/MANIFEST.json');
  final ci = readOr('../.github/workflows/dart-selfcheck.yml');
  final av = readOr('lib/core/app_version.dart');
  final pub = readOr('pubspec.yaml');
  final readme = readOr('../README.md');
  final cl = readOr('../build-out/changelog.json');
  final body = local.isEmpty ? '' : bodyOf(local);

  // ── §1 文件与出处 ──────────────────────────────────────────────
  ck('§1 移植文件存在', local.isNotEmpty);
  final head = const LineSplitter().convert(local).take(12).join('\n');
  ck('§1 头部有「上游:」出处行', head.contains('上游:'));
  ck('§1 头部有「许可证:」', head.contains('许可证:'));
  ck('§1 头部写明 repo@commit', head.contains('kodjodevf/mangayomi@91bda20a9235'));
  ck('§1 头部许可证为 Apache-2.0', head.contains('Apache-2.0'));
  ck('§1 头部写明上游路径',
      head.contains('lib/modules/manga/reader/widgets/custom_value_indicator_shape.dart'));
  ck('§1 头部写明台账 id', head.contains('mangayomi_value_indicator_shape'));
  ck('§1 文件首条 import 是 flutter/material.dart',
      body.startsWith("import 'package:flutter/material.dart';"));

  // ── §2 上游正文逐字 ────────────────────────────────────────────
  ck('§2 上游正文逐字一致（内嵌全文）', body == kUpstreamBody);
  ck('§2 上游正文 1774 字节长度闸', utf8.encode(body).length == 1774);
  ck('§2 上游正文 62 行（LineSplitter 不计末尾换行）',
      const LineSplitter().convert(body).length == 62);
  for (final line in <String>[
    'class CustomValueIndicatorShape extends SliderComponentShape {',
    '  final _indicatorShape = const PaddleSliderValueIndicatorShape();',
    '  final bool tranform;',
    '  const CustomValueIndicatorShape({this.tranform = false});',
    '  Size getPreferredSize(bool isEnabled, bool isDiscrete) {',
    '    return const Size(40, 40);',
    '    final textSpan = TextSpan(',
    '      text: labelPainter.text?.toPlainText(),',
    '      style: sliderTheme.valueIndicatorTextStyle,',
    '    context.canvas.save();',
    '    context.canvas.translate(center.dx, center.dy);',
    '    context.canvas.scale(tranform ? -1.0 : 1.0, 1.0);',
    '    context.canvas.translate(-center.dx, -center.dy);',
    '    _indicatorShape.paint(',
    '    context.canvas.restore();',
  ]) {
    ck('§2 上游关键行: $line', body.contains(line));
  }
  ck('§2 镜像方向与 scale 常量未被改坏',
      body.contains('context.canvas.scale(tranform ? -1.0 : 1.0, 1.0);') &&
          !body.contains('context.canvas.scale(tranform ? 1.0 : 1.0, 1.0);'));

  // ── §3 依赖白名单 ──────────────────────────────────────────────
  final imports = importLinesOf(body);
  ck('§3 移植文件只有 1 条 import', imports.length == 1);
  ck('§3 唯一 import 为 flutter/material.dart',
      imports.length == 1 && imports.first == "import 'package:flutter/material.dart';");
  for (final banned in <String>[
    'package:mangayomi',
    'package:shiori',
    'flutter_riverpod',
    'package:photo_view',
    'package:super_sliver_list',
    "part of",
  ]) {
    ck('§3 移植文件不含依赖「$banned」', !body.contains(banned));
  }
  ck('§3 移植文件无绝对上游 import', !body.contains("import 'package:mangayomi/"));

  // ── §4 main.dart 接线 ──────────────────────────────────────────
  const sliderImport =
      "import 'vendor/mangayomi/custom_value_indicator_shape.dart';";
  ck('§4 main.dart 引入移植文件', mainSrc.contains(sliderImport));
  // contains 会被「注掉 import 后残留在注释里的同一字符串」骗过（变异反证抓到），
  // 必须按行首精确匹配，确保它是一条真的 import 语句。
  ck('§4 import 是行首语句（不是注释残骸）',
      const LineSplitter().convert(mainSrc).any((l) => l.trim() == sliderImport));
  ck('§4 SliderTheme 设置了 valueIndicatorShape',
      mainSrc.contains('SliderTheme(') && mainSrc.contains('valueIndicatorShape:'));
  ck('§4 气泡形状用上游类', mainSrc.contains('const CustomValueIndicatorShape()'));
  ck('§4 底部加了 Slider',
      mainSrc.contains('child: Slider(') && mainSrc.contains('onChangeEnd: (v) {'));
  ck('§4 Slider 屏数用 ReaderPageIndexMath',
      mainSrc.contains('divisions: pageMath.pageViewPageCount - 1,') &&
          mainSrc.contains('max: (pageMath.pageViewPageCount - 1)'));
  ck('§4 只有多屏时才显示滑杆',
      mainSrc.contains('if (pageMath.pageViewPageCount > 1)'));
  ck('§4 滑杆页码标签用双页换算',
      mainSrc.contains('label: pageMath.currentIndexLabel('));
  ck('§4 松手跳页沿用 ReaderMotion 动画',
      mainSrc.contains('pc.animateToPage(v.round(),') &&
          mainSrc.contains('duration: ReaderMotion.settle(') &&
          mainSrc.contains('curve: ReaderMotion.quinticOut);'));
  ck('§4 拖动时页码随手指更新',
      mainSrc.contains('if (mounted) setState(() => curPage = v.round());'));
  ck('§4 调用前检查 PageController 已挂载', mainSrc.contains('if (pc.hasClients) {'));
  ck('§4 既有双页/动效接线未被破坏',
      mainSrc.contains('itemCount: pageMath.pageViewPageCount,') &&
          mainSrc.contains('physics: const WebtoonScrollPhysics(),') &&
          mainSrc.contains('duration: ReaderMotion.settle('));
  // main.dart 里另有 3 处 child: Slider( 在 _Ecr 之前，必须从阅读器类之后开始找。
  final ecrAt = mainSrc.indexOf('class _Ecr extends State<EngineComicReader>');
  final sliderAt = ecrAt < 0 ? -1 : mainSrc.indexOf('child: Slider(', ecrAt);
  ck('§4 阅读器类仍存在且滑杆在其后', ecrAt >= 0 && sliderAt > ecrAt);

  // ── §5 台账 / CI / 版本 / 合规 ─────────────────────────────────
  ck('§5 台账登记了 mangayomi_value_indicator_shape',
      manifest.contains('"id": "mangayomi_value_indicator_shape"'));
  ck('§5 台账 upstream_path 指向上游 widgets 路径',
      manifest.contains('lib/modules/manga/reader/widgets/custom_value_indicator_shape.dart'));
  ck('§5 台账 local 指向实际移植文件',
      manifest.contains('flutter_app/lib/vendor/mangayomi/custom_value_indicator_shape.dart'));
  ck('§5 台账声明 wired_in = main.dart',
      manifest.contains('"wired_in"') &&
          manifest.contains('"flutter_app/lib/main.dart"'));
  ck('§5 台账标注 Apache-2.0 与本轮版本',
      manifest.contains('"license": "Apache-2.0"') && manifest.contains('"since": "4.81.55"'));
  ck('§5 台账写入第 17 轮上游全树实测结论',
      manifest.contains('第 17 轮') && manifest.contains('part of'));
  ck('§5 CI 有 mangayomi_page_slider 步骤',
      ci.contains('tool/mangayomi_page_slider_selfcheck.dart') &&
          ci.contains('mangayomi_page_slider（'));
  ck('§5 版本三件套一致 4.81.55 / 50726',
      av.contains("kAppVersion = '4.81.55'") &&
          av.contains('kAppCode = 50726') &&
          pub.contains('version: 4.81.55+50726') &&
          readme.contains('4.81.55') &&
          readme.contains('50726'));
  ck('§5 版本三件套无旧版残留',
      !av.contains('4.81.54') &&
          !pub.contains('4.81.54') &&
          !readme.contains('4.81.54'));
  ck('§5 changelog 首条为 4.81.55',
      cl.contains('"latest": "4.81.55"') && cl.contains('"v": "4.81.55"'));
  ck('§5 changelog 历史 4.81.54 条目仍在',
      cl.contains('"v": "4.81.54"'));
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
  // 只扫描本次新增的滑杆块：main.dart 既有 3 处 label: tr( 与本轮无关。
  final nextTextAt = sliderAt < 0 ? -1 : mainSrc.indexOf("Text('", sliderAt);
  final sliderBlock = (sliderAt >= 0 && nextTextAt > sliderAt)
      ? mainSrc.substring(sliderAt, nextTextAt)
      : '';
  ck('§5 新增滑杆零新增 UI 文案（label 为数字页码，无 tr 新键）',
      sliderBlock.isNotEmpty &&
          sliderBlock.contains('label: pageMath.currentIndexLabel(') &&
          !sliderBlock.contains('tr('));

  // 本地镜像层：CI 不携带镜像，打印 SKIP 不伪装成通过；本地存在则逐字节核对。
  const mirrorPath =
      '../vendor/_upstream/mangayomi/lib/modules/manga/reader/widgets/custom_value_indicator_shape.dart';
  final mirror = File(mirrorPath);
  if (!mirror.existsSync()) {
    skipped('§2 本地上游镜像未随仓库携带，逐字节核对跳过（CI 用内嵌全文断言）');
  } else {
    ck('§2 本地上游镜像与内嵌全文逐字节一致',
        mirror.readAsStringSync() == kUpstreamBody);
  }

  print('\n$pass 通过 / $fail 失败 / $skip 跳过');
  if (fail > 0) {
    print('Mangayomi 页码滑杆移植与上游或接线不一致，已拦下。');
    print('首条失败: ${failures.first}');
    exit(1);
  }
}
