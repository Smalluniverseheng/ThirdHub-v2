// Mangayomi 条漫滚动物理 / 阅读动效 移植自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/mangayomi_motion_selfcheck.dart
//
// 为什么必须有这条闸门：#205 把 Mangayomi 的 reader_motion.dart 与
// webtoon_scroll_physics.dart 原样搬进本项目。这类代码「搬错了不会报错、不会崩」，
// 只会静默表现成「iOS 上滑一下就停」「滑到章末弹一下」「翻页写死 200ms」，
// 而 analyze / 编译 / 台账闸门全绿。尤其三类病：
//   ① 搬成「照印象重写」——常量被顺手改掉，界面上没人看得出来；
//   ② 搬来摆着——文件在、接线没接，Android 上行为毫无变化；
//   ③ 顺手带上上游自有包（riverpod / shiori / 绝对 package:mangayomi import），
//      移动端就编译不过，或者把整套依赖拖进 App。
//
// 五层断言：§1 文件与出处 / §2 上游常量与公式逐字 / §3 依赖白名单 /
//           §4 接线 / §5 台账 + CI + 合规。
// ★ 末尾 exit(1)：CI 只看退出码，打印 FAIL 不等于拦住了（2026-09-28 血泪）。
import 'dart:io';

int pass = 0, fail = 0;
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

String readOr(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : '';
}

/// 上游常量逐值核对：从源码里用正则把字面量抓出来，跟写死在这儿的期望值比。
/// 写死的值是 2026-11-08 从 kodjodevf/mangayomi@91bda20a9235 上游原文读来的，
/// 不是照印象填的；上游换版本时应同步更新这里并重新核对。
String? pick(String src, String pattern) {
  final m = RegExp(pattern).firstMatch(src);
  return m == null ? null : (m.groupCount >= 1 ? m.group(1) : m.group(0));
}

void main() {
  const motionRel = 'lib/vendor/mangayomi/reader_motion.dart';
  const physicsRel = 'lib/vendor/mangayomi/webtoon_scroll_physics.dart';
  final motion = readOr(motionRel);
  final physics = readOr(physicsRel);
  final mainSrc = readOr('lib/main.dart');
  final manifest = readOr('../vendor/MANIFEST.json');
  final yml = readOr('../.github/workflows/dart-selfcheck.yml');

  // ── §1 文件存在 + 头部出处 ────────────────────────────────────────────
  ck('§1 reader_motion.dart 存在', motion.isNotEmpty);
  ck('§1 webtoon_scroll_physics.dart 存在', physics.isNotEmpty);
  for (final e in <String, String>{'motion': motion, 'physics': physics}.entries) {
    final head = e.value.split('\n').take(8).join('\n');
    ck('§1 ${e.key} 头部有「上游:」出处行', head.contains('上游:'));
    ck('§1 ${e.key} 头部有「许可证: Apache-2.0」', head.contains('许可证: Apache-2.0'));
    ck('§1 ${e.key} 头部出处含上游 repo', head.contains('kodjodevf/mangayomi'));
    ck('§1 ${e.key} 头部出处含上游 commit', head.contains('91bda20a9235'));
    ck('§1 ${e.key} 头部写明上游路径', head.contains('上游路径:'));
    ck('§1 ${e.key} 头部写明台账 id', head.contains('台账:'));
  }

  // ── §2 上游常量与公式逐字一致（防「照印象重写」） ──────────────────────
  // ReaderMotion
  ck('§2 quinticOut 是 _QuinticOut 实例',
      motion.contains('static const Curve quinticOut = _QuinticOut();'));
  ck('§2 quinticOut 公式 (t-1)^5+1',
      motion.contains('final u = t - 1;') &&
      motion.contains('return u * u * u * u * u + 1;'));
  ck('§2 maxSettle = 600ms',
      motion.contains('static const Duration maxSettle = Duration(milliseconds: 600);'));
  ck('§2 settle 无速度用 (distance/extent + 1) * 100',
      motion.contains('ms = ((distance / extent + 1) * 100).round();'));
  ck('§2 settle 有速度用 0.3*pi/2 的 sin 缓动',
      motion.contains('final eased = half + half * sin((ratio - 0.5) * 0.3 * pi / 2);'));
  ck('§2 settle 有速度用 4 * (1000 * eased / velocity)',
      motion.contains('ms = 4 * (1000 * eased / velocity).round();'));
  ck('§2 settle 结果受 maxSettle 封顶',
      motion.contains('min(ms, maxSettle.inMilliseconds)'));
  ck('§2 settle 边界：extent<=0 或 distance==0 返回零时长',
      motion.contains('if (extent <= 0 || distance == 0) return Duration.zero;'));
  ck('§2 settle 距离与速度取绝对值',
      motion.contains('distance = distance.abs();') && motion.contains('velocity = velocity.abs();'));
  ck('§2 scroll 用 (distance.abs()/extent + 1) * 300',
      motion.contains('final ms = ((distance.abs() / extent + 1) * 300).round();'));
  ck('§2 scroll 封顶 2000ms', motion.contains('min(ms, 2000)'));
  ck('§2 scroll 边界：extent<=0 返回零时长',
      motion.contains('if (extent <= 0) return Duration.zero;'));
  ck('§2 doubleTapZoom 三档 1 / 250 / 500ms',
      motion.contains('0 => const Duration(milliseconds: 1),') &&
      motion.contains('2 => const Duration(milliseconds: 250),') &&
      motion.contains('_ => const Duration(milliseconds: 500),'));
  ck('§2 stripDoubleTapZoom 两档 1 / 200ms',
      motion.contains('? const Duration(milliseconds: 1)') &&
      motion.contains(': const Duration(milliseconds: 200);'));
  ck('§2 flingTravel = 0.2',
      motion.contains('static const double flingTravel = 0.2;'));
  ck('§2 flingDuration = 400ms',
      motion.contains('static const Duration flingDuration = Duration(milliseconds: 400);'));
  ck('§2 ReaderMotion 是 abstract final class',
      motion.contains('abstract final class ReaderMotion'));
  ck('§2 _QuinticOut 继承 Curve 且 const 构造',
      motion.contains('class _QuinticOut extends Curve') && motion.contains('const _QuinticOut();'));
  // 数值抽取值（正则抓字面量，防手改）
  ck('§2 iosDrag 字面值 0.135', pick(physics, r'iosDrag\s*=\s*([0-9.]+)') == '0.135');
  ck('§2 maxSettle 字面值 600', pick(motion, r'maxSettle\s*=\s*Duration\(milliseconds:\s*(\d+)\)') == '600');
  ck('§2 flingTravel 字面值 0.2', pick(motion, r'flingTravel\s*=\s*([0-9.]+)') == '0.2');

  // WebtoonScrollPhysics
  ck('§2 继承 ClampingScrollPhysics（不是 Bouncing）',
      physics.contains('class WebtoonScrollPhysics extends ClampingScrollPhysics'));
  ck('§2 const 构造带 super.parent',
      physics.contains('const WebtoonScrollPhysics({super.parent});'));
  ck('§2 applyTo 用 buildParent 保留祖先',
      physics.contains('WebtoonScrollPhysics applyTo(ScrollPhysics? ancestor) =>') &&
      physics.contains('WebtoonScrollPhysics(parent: buildParent(ancestor));'));
  ck('§2 只对 ClampingScrollSimulation 且 iOS/macOS 改写',
      physics.contains('if (simulation is! ClampingScrollSimulation || !_glidesLikeIos)'));
  ck('§2 非 iOS 分支原样返回上游 simulation',
      physics.contains('return simulation;'));
  ck('§2 用 FrictionSimulation(iosDrag, ...) 模拟 UIKit 减速',
      physics.contains('FrictionSimulation(') &&
      physics.contains('iosDrag,') && physics.contains('position.pixels,') &&
      physics.contains('velocity,') && physics.contains('tolerance: toleranceFor(position),'));
  ck('§2 _glidesLikeIos 只认 iOS / macOS',
      physics.contains('TargetPlatform.iOS || TargetPlatform.macOS => true,') &&
      physics.contains('_ => false,'));
  ck('§2 _StopAtEdges 继承 Simulation 且透传 tolerance',
      physics.contains('class _StopAtEdges extends Simulation') &&
      physics.contains('super(tolerance: _glide.tolerance);'));
  ck('§2 _StopAtEdges.x 把位移夹在 min/max 内',
      physics.contains('double x(double time) => _glide.x(time).clamp(_min, _max);'));
  ck('§2 _atEdge 双向判边（含速度方向）',
      physics.contains('return (x <= _min && v <= 0) || (x >= _max && v >= 0);'));
  ck('§2 _StopAtEdges 到边即速度归零',
      physics.contains('double dx(double time) => _atEdge(time) ? 0 : _glide.dx(time);'));
  ck('§2 _StopAtEdges 到边或滑行结束即 done',
      physics.contains('bool isDone(double time) => _atEdge(time) || _glide.isDone(time);'));
  ck('§2 stripFlingVelocity 用 flingTravel 预测落点',
      physics.contains('final target = offset + velocity * ReaderMotion.flingTravel;'));
  ck('§2 stripFlingVelocity 未越界返回 0',
      physics.contains('if (target.abs() <= maxOffset) return 0;'));
  ck('§2 stripFlingVelocity 越界把速度反向交给长条',
      physics.contains('return -velocity;'));
  ck('§2 glideStrip 只在 hasClients 时动作',
      physics.contains('if (!controller.hasClients) return;'));
  ck('§2 glideStrip 用 goBallistic 续滑',
      physics.contains('if (position is ScrollPositionWithSingleContext)') &&
      physics.contains('position.goBallistic(velocity);'));

  // ── §3 依赖白名单：搬进移动端必须能独立编译 ───────────────────────────
  final allSrc = '$motion\n$physics';
  final imports = <String>[];
  for (final line in allSrc.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('import ')) continue;
    final q1 = t.indexOf("'");
    final q2 = t.lastIndexOf("'");
    if (q1 >= 0 && q2 > q1) imports.add(t.substring(q1 + 1, q2));
  }
  const allowed = <String>{
    'dart:math',
    'package:flutter/animation.dart',
    'package:flutter/foundation.dart',
    'package:flutter/physics.dart',
    'package:flutter/widgets.dart',
    'reader_motion.dart',
  };
  ck('§3 恰好 6 条 import（上游 2 + 4，去掉绝对路径 1 条）', imports.length == 6);
  for (final i in imports) {
    ck('§3 import 在白名单内: $i', allowed.contains(i));
  }
  ck('§3 不含上游绝对 package:mangayomi import',
      !allSrc.contains("import 'package:mangayomi/"));
  // 按 import 行判定，不用全文 contains：上游原样注释里有 `// shiori-file:`
  // 这类生成标记，它不是依赖；全文扫会造出「代码没坏但闸门红」的假红。
  // 真正引入依赖必然出现在 import 行里，那条路径由白名单与这里同时守住。
  for (final bad in <String>['riverpod', 'shiori', 'photo_view', 'isar', 'dart:ffi']) {
    ck('§3 不引入 $bad（按 import 行判定）',
        !imports.any((i) => i.contains(bad)));
  }
  ck('§3 physics 用同目录相对 import 引用 motion',
      physics.contains("import 'reader_motion.dart';"));
  ck('§3 无 part / part of（不是共享作用域的分片）',
      !allSrc.contains('part of ') && !RegExp(r'^part ', multiLine: true).hasMatch(allSrc));

  // ── §4 接线：文件不是搬来摆着 ─────────────────────────────────────────
  ck('§4 main.dart import reader_motion.dart',
      mainSrc.contains("import 'vendor/mangayomi/reader_motion.dart';"));
  ck('§4 main.dart import webtoon_scroll_physics.dart',
      mainSrc.contains("import 'vendor/mangayomi/webtoon_scroll_physics.dart';"));
  ck('§4 连续模式 ListView 接了 WebtoonScrollPhysics',
      mainSrc.contains('physics: const WebtoonScrollPhysics(),'));
  ck('§4 physics 与 autoScrollController 在同一个 ListView',
      RegExp(r'ListView\.builder\([\s\S]{0,400}?controller: autoScrollController,[\s\S]{0,300}?physics: const WebtoonScrollPhysics\(\),')
          .hasMatch(mainSrc));
  ck('§4 翻页动画时长改用 ReaderMotion.settle',
      mainSrc.contains('duration: ReaderMotion.settle('));
  ck('§4 settle 传入 distance / extent',
      mainSrc.contains('distance: size.width, extent: size.width),'));
  ck('§4 翻页曲线改用 ReaderMotion.quinticOut',
      mainSrc.contains('curve: ReaderMotion.quinticOut);'));
  ck('§4 不再写死 200ms 的翻页动画',
      !mainSrc.contains('duration: const Duration(milliseconds: 200), curve: Curves.easeOut);'));
  ck('§4 接线点在 _Ecr 漫画阅读器内（不是别处误接）',
      mainSrc.indexOf('class _Ecr extends State<EngineComicReader>') <
          mainSrc.indexOf('physics: const WebtoonScrollPhysics(),'));
  ck('§4 既有 ReaderAutoScroll 接线未被破坏',
      mainSrc.contains('with TickerProviderStateMixin, ReaderAutoScroll') &&
      mainSrc.contains('disposeAutoScroll();') &&
      mainSrc.contains('onAutoScrollChanged();'));

  // ── §5 台账 / CI / 合规 ───────────────────────────────────────────────
  ck('§5 台账登记 mangayomi_reader_motion',
      manifest.contains('"id": "mangayomi_reader_motion"'));
  ck('§5 台账登记 mangayomi_webtoon_physics',
      manifest.contains('"id": "mangayomi_webtoon_physics"'));
  ck('§5 两项都标记 Apache-2.0',
      (manifest.split('"id": "mangayomi_reader_motion"').length > 1) &&
      manifest.contains('"license": "Apache-2.0"'));
  ck('§5 两项都声明 wired_in 指向 main.dart',
      manifest.contains('"wired_in"') &&
      manifest.contains('"flutter_app/lib/main.dart"'));
  ck('§5 台账 schema 未变', manifest.contains('"schema": "thirdhub.vendor_manifest/1"'));
  ck('§5 台账仍把 Namida 留在 blocked（EULA 不可搬）',
      manifest.contains('"upstream": "namida"') && manifest.contains('"blocked"'));
  ck('§5 CI 接了本自检 step',
      yml.contains('dart run tool/mangayomi_motion_selfcheck.dart'));
  ck('§5 CI step 排在 vendor_manifest 之后、local_agent 之前',
      yml.indexOf('dart run tool/vendor_manifest_selfcheck.dart') <
          yml.indexOf('dart run tool/mangayomi_motion_selfcheck.dart') &&
      yml.indexOf('dart run tool/mangayomi_motion_selfcheck.dart') <
          yml.indexOf('dart run tool/local_agent_selfcheck.dart'));
  ck('§5 CI push paths 覆盖 lib/** 与 tool/**',
      yml.contains("- 'flutter_app/lib/**'") && yml.contains("- 'flutter_app/tool/**'"));
  for (final t in <String>['copy_manga', 'baozi', 'jmcomic', '禁漫', '书源', '图源']) {
    ck('§5 移植文件不含第三方内容源标识「$t」', !allSrc.contains(t));
  }
  ck('§5 移植文件不含 emoji',
      !RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true).hasMatch(allSrc));

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) {
    print('Mangayomi 动效/物理移植与上游或接线不一致，已拦下。');
    print('首条失败: ${failures.first}');
    exit(1);
  }
}
