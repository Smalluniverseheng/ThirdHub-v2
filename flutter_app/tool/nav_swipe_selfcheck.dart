// 模块切换手势主方向判定自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/nav_swipe_selfcheck.dart
//
// 覆盖：方向判定矩阵 / 一次性方向锁 / 松手结算 / 边界与夹取。
// 重点回归用户报告的场景：在模块内**向上滑动**时被误判为左右切换模块。
import '../lib/core/nav_swipe_logic.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) { pass++; } else { fail++; print('  FAIL  $name'); }
}

const kSlop = SwipeAxisDecider.kSlop; // 18.0

void main() {
  // ── 1. 基准方向 ──
  print('== 1. 基准方向 ==');
  ck('纯上滑 → vertical', SwipeAxisDecider.decide(0, -60) == SwipeAxis.vertical);
  ck('纯下滑 → vertical', SwipeAxisDecider.decide(0, 60) == SwipeAxis.vertical);
  ck('纯左滑 → horizontal', SwipeAxisDecider.decide(-60, 0) == SwipeAxis.horizontal);
  ck('纯右滑 → horizontal', SwipeAxisDecider.decide(60, 0) == SwipeAxis.horizontal);
  ck('原地不动 → none', SwipeAxisDecider.decide(0, 0) == SwipeAxis.none);

  // ── 2. ★核心回归：斜着上滑绝不能被判成切模块 ──
  print('== 2. 上滑误判回归 ==');
  // 原版只看 |dx| > 18，下面这些 dx 全都超过 18 ⇒ 原版都会切走模块
  ck('斜上滑 dx=20 dy=60 → vertical（原版会误切）',
      SwipeAxisDecider.decide(20, -60) == SwipeAxis.vertical);
  ck('斜上滑 dx=25 dy=-40 → vertical（原版会误切）',
      SwipeAxisDecider.decide(25, -40) == SwipeAxis.vertical);
  ck('斜上滑 dx=30 dy=-90 → vertical', SwipeAxisDecider.decide(30, -90) == SwipeAxis.vertical);
  ck('斜下滑 dx=-22 dy=75 → vertical', SwipeAxisDecider.decide(-22, 75) == SwipeAxis.vertical);
  ck('大角度上滑 dx=40 dy=-200 → vertical', SwipeAxisDecider.decide(40, -200) == SwipeAxis.vertical);
  // 对照：证明"原版条件"确实会被这些位移满足，而新版不会
  for (final c in [[20, -60], [25, -40], [30, -90], [-22, 75], [40, -200]]) {
    final dx = c[0].toDouble(), dy = c[1].toDouble();
    ck('对照 dx=$dx dy=$dy：原版会接受、新版拒绝',
        dx.abs() > kSlop && SwipeAxisDecider.decide(dx, dy) != SwipeAxis.horizontal);
  }

  // ── 3. 斜向但未定 → 谁都不动（宁可少切一次） ──
  print('== 3. 缓冲带 ==');
  ck('dx=25 dy=22 → none（未明确，不切）',
      SwipeAxisDecider.decide(25, 22) == SwipeAxis.none);
  ck('dx=22 dy=-20 → none', SwipeAxisDecider.decide(22, -20) == SwipeAxis.none);
  ck('dx=40 dy=35 → none', SwipeAxisDecider.decide(40, 35) == SwipeAxis.none);

  // ── 4. 水平明确主导 → 允许切换 ──
  print('== 4. 合法切换 ==');
  ck('dx=-40 dy=20 → horizontal', SwipeAxisDecider.decide(-40, 20) == SwipeAxis.horizontal);
  ck('dx=60 dy=-30 → horizontal', SwipeAxisDecider.decide(60, -30) == SwipeAxis.horizontal);
  ck('dx=-200 dy=5 → horizontal', SwipeAxisDecider.decide(-200, 5) == SwipeAxis.horizontal);

  // ── 5. 位移不足 ──
  print('== 5. 位移不足 ==');
  ck('dx=5 dy=5 → none', SwipeAxisDecider.decide(5, 5) == SwipeAxis.none);
  ck('dx=17 dy=0 → none', SwipeAxisDecider.decide(17, 0) == SwipeAxis.none);
  ck('dx=0 dy=17 → none', SwipeAxisDecider.decide(0, 17) == SwipeAxis.none);

  // ── 6. 边界：恰好等于 slop ──
  print('== 6. 阈值边界 ==');
  ck('dx=18 dy=0 → horizontal（达到 slop 即接受）',
      SwipeAxisDecider.decide(18, 0) == SwipeAxis.horizontal);
  ck('dx=17.9 dy=0 → none', SwipeAxisDecider.decide(17.9, 0) == SwipeAxis.none);
  ck('dx=0 dy=18 → vertical', SwipeAxisDecider.decide(0, 18) == SwipeAxis.vertical);
  ck('dx=18 dy=17 → none（刚好落在缓冲带）',
      SwipeAxisDecider.decide(18, 17) == SwipeAxis.none);
  ck('dx=18 dy=14 → horizontal（1.28 > 1.25）',
      SwipeAxisDecider.decide(18, 14) == SwipeAxis.horizontal);

  // ── 7. allowsModuleSwitch 与 decide 一致 ──
  print('== 7. 便捷判定一致性 ==');
  ck('allows(-60,0)=true', SwipeAxisDecider.allowsModuleSwitch(-60, 0));
  ck('allows(20,-60)=false', !SwipeAxisDecider.allowsModuleSwitch(20, -60));
  ck('allows(5,5)=false', !SwipeAxisDecider.allowsModuleSwitch(5, 5));
  ck('allows(25,22)=false', !SwipeAxisDecider.allowsModuleSwitch(25, 22));

  // ── 8. 一次性方向锁（防止"上滑途中突然跳模块"） ──
  print('== 8. 方向锁 ==');
  {
    final l = SwipeLatch();
    ck('初始未锁定', !l.locked && l.axis == SwipeAxis.none);
    l.update(2, -3);
    ck('位移不足时仍不锁定', !l.locked);
    l.update(6, -30);
    ck('判定垂直后锁定', l.locked && l.yieldedVertical);
    l.update(200, -35); // 拖到一半又横向大幅偏移
    ck('★锁死后不回改成 horizontal', l.yieldedVertical && !l.acceptedHorizontal);
    l.reset();
    ck('reset 后可重新判定', !l.locked);
  }
  {
    final l = SwipeLatch();
    l.update(-40, 2);
    ck('先判水平则锁水平', l.acceptedHorizontal && !l.yieldedVertical);
    l.update(-45, 300);
    ck('锁死后不回改成 vertical', l.acceptedHorizontal);
  }

  // ── 9. 松手结算 ──
  print('== 9. 松手结算 ==');
  int tgt({int from = 2, int count = 5, double moved = 0, double w = 400, double vx = 0}) =>
      SwipeSettleDecider.target(from: from, count: count, movedPx: moved, pageWidth: w, velocityDx: vx);
  ck('位移未够且没速度 → 原地', tgt(moved: 50) == 2);
  ck('位移超过 22% → 下一页', tgt(moved: 100) == 3);
  ck('位移超过 22% 反向 → 上一页', tgt(moved: -100) == 1);
  ck('位移恰好 88(=400*0.22) → 原地（用 > 判定）', tgt(moved: 88) == 2);
  ck('位移 89 → 下一页', tgt(moved: 89) == 3);
  ck('轻扫但速度够 → 下一页', tgt(moved: 10, vx: -400) == 3);
  ck('轻扫反向速度 → 上一页', tgt(moved: -10, vx: 400) == 1);
  ck('速度恰好 350 → 原地（用 < 判定）', tgt(vx: -350) == 2);
  ck('速度 351 → 下一页', tgt(vx: -351) == 3);
  ck('首页往回滑 → 夹在 0', tgt(from: 0, moved: -200) == 0);
  ck('末页往前滑 → 夹在 count-1', tgt(from: 4, moved: 200) == 4);
  ck('count=1 时恒为 0', tgt(from: 0, count: 1, moved: 300) == 0);
  ck('count=0 时不崩且返回 0', tgt(from: 0, count: 0) == 0);
  ck('速度与位移同向但不冲突', tgt(moved: 150, vx: -500) == 3);

  // ── 10. 回弹判定 ──
  print('== 10. 回弹 ==');
  ck('没滑够 → isSnapBack', SwipeSettleDecider.isSnapBack(
      from: 2, count: 5, movedPx: 30, pageWidth: 400, velocityDx: 0));
  ck('滑够了 → 不是回弹', !SwipeSettleDecider.isSnapBack(
      from: 2, count: 5, movedPx: 200, pageWidth: 400, velocityDx: 0));
  ck('末页硬滑 → 夹回原页 ⇒ 仍算回弹', SwipeSettleDecider.isSnapBack(
      from: 4, count: 5, movedPx: 300, pageWidth: 400, velocityDx: 0));

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ 全部通过');
}
