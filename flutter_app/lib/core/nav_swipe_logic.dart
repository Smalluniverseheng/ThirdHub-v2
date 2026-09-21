// 模块间左右滑动 与 模块内上下滚动 的主方向判定。
//
// ★ 本文件刻意**零依赖**（不用 dart:ui / flutter / any package），
//   因此可以用纯 Dart VM 直接跑自检（见 tool/nav_swipe_selfcheck.dart）。
//
// 背景（为什么需要它）：
//   RootNav 原先直接用 `PageView` + `PageScrollPhysics` 承载"左右滑动切模块"。
//   Flutter 内置的 HorizontalDragGestureRecognizer 只要求**水平位移**超过
//   kTouchSlop(18)，完全不看垂直分量 —— 于是"斜着往上滑"时水平分量先到 18，
//   模块就被切走了，而用户本意是滚动当前模块的内容。
//   而且 ScrollableState.setCanDrag 把识别器**硬编码**为
//   HorizontalDragGestureRecognizer，没有官方插口可以替换它的判定条件。
//
//   所以这里自己做判定：只有"水平分量明确占主导"时才认作切模块，
//   垂直分量占主导时主动让位给模块内的滚动视图。
library;

/// 手势被判定的方向。
enum SwipeAxis {
  /// 位移还不够 / 两个方向都不占主导 —— 谁都不动，继续观察。
  none,

  /// 水平占主导 → 允许切模块。
  horizontal,

  /// 垂直占主导 → 让位给模块内的滚动，绝不切模块。
  vertical,
}

/// 纯函数式的方向判定。入参是**相对手势起点的累计位移**（单位：逻辑像素）。
class SwipeAxisDecider {
  /// 主方向需要达到的最小位移，对齐 Flutter 的 kTouchSlop(18)。
  static const double kSlop = 18.0;

  /// 水平分量必须是垂直分量的这么多倍，才认作"横向切换"。
  /// 取 1.25 而非 1.0：宁可少切一次，也不要在用户上滑时误切模块。
  static const double kRatio = 1.25;

  /// 垂直分量超过水平分量这么多倍时，立即判定为垂直并让位。
  /// 故意比 kRatio 小一点（1.15 < 1.25），留出一段"斜向但不明确"的缓冲带：
  /// 这段区间里两个方向都不判定，等用户继续滑出倾向再定。
  static const double kVerticalBail = 1.15;

  /// 判定 [dx]/[dy]（累计位移）对应的方向。
  ///
  /// 判定顺序很重要：**先看垂直是否明确占主导**（让位优先），
  /// 再看水平是否明确占主导。两者都不满足则返回 [SwipeAxis.none]。
  static SwipeAxis decide(
    double dx,
    double dy, {
    double slop = kSlop,
    double ratio = kRatio,
    double bail = kVerticalBail,
  }) {
    final ax = dx.abs();
    final ay = dy.abs();
    // ① 垂直明确占主导 → 让位（绝不切模块）
    if (ay >= slop && ay > ax * bail) return SwipeAxis.vertical;
    // ② 水平明确占主导 → 接管（切模块）
    if (ax >= slop && ax > ay * ratio) return SwipeAxis.horizontal;
    // ③ 位移不足或斜向未定 → 继续观察
    return SwipeAxis.none;
  }

  /// 便捷判断：这个位移是否允许触发模块切换。
  static bool allowsModuleSwitch(double dx, double dy, {double slop = kSlop, double ratio = kRatio, double bail = kVerticalBail}) =>
      decide(dx, dy, slop: slop, ratio: ratio, bail: bail) == SwipeAxis.horizontal;
}

/// 一次性手势的方向锁。
///
/// 为什么要"锁"：判定发生在手势过程中。如果每次 move 都重新判定，
/// 用户上滑到一半再往侧边带一点，方向就会从 vertical 翻成 horizontal ——
/// 表现为"上滑途中突然跳模块"。一旦定过方向就不再改判（除非 [reset]）。
class SwipeLatch {
  SwipeAxis _axis = SwipeAxis.none;

  /// 当前已锁定的方向（[SwipeAxis.none] 表示尚未定）。
  SwipeAxis get axis => _axis;

  /// 是否已经锁定（定过向）。
  bool get locked => _axis != SwipeAxis.none;

  /// 是否已确认让位给垂直滚动。
  bool get yieldedVertical => _axis == SwipeAxis.vertical;

  /// 是否已确认要切模块。
  bool get acceptedHorizontal => _axis == SwipeAxis.horizontal;

  /// 喂入累计位移，返回（可能已锁定的）方向。
  SwipeAxis update(
    double dx,
    double dy, {
    double slop = SwipeAxisDecider.kSlop,
    double ratio = SwipeAxisDecider.kRatio,
    double bail = SwipeAxisDecider.kVerticalBail,
  }) {
    if (_axis != SwipeAxis.none) return _axis; // 已锁定，不改判
    final v = SwipeAxisDecider.decide(dx, dy, slop: slop, ratio: ratio, bail: bail);
    if (v != SwipeAxis.none) _axis = v;
    return _axis;
  }

  /// 新手势开始时复位。
  void reset() => _axis = SwipeAxis.none;
}

/// 松手后决定落到哪一页。纯计算，便于自检覆盖边界。
class SwipeSettleDecider {
  /// 位移超过页宽的这个比例就翻页。
  static const double kDistFrac = 0.22;

  /// 速度绝对值超过这个值（px/s）就算"甩"，即使位移不够也翻页。
  static const double kVelocity = 350.0;

  /// 计算松手后的目标页索引。
  ///
  /// [from] 起始页；[count] 总页数；[movedPx] 相对起始的像素位移
  /// （**正值 = 内容往下一页走**，即手指向左滑）；[pageWidth] 单页宽度；
  /// [velocityDx] 手指的水平速度（向左滑为负）。
  /// 结果一定被夹在 `[0, count-1]`。
  static int target({
    required int from,
    required int count,
    required double movedPx,
    required double pageWidth,
    required double velocityDx,
    double distFrac = kDistFrac,
    double velocity = kVelocity,
  }) {
    if (count <= 0) return 0;
    var t = from;
    final threshold = pageWidth * distFrac;
    // 位移够远，或往同方向甩得够快
    if (movedPx > threshold || velocityDx < -velocity) {
      t = from + 1;
    } else if (movedPx < -threshold || velocityDx > velocity) {
      t = from - 1;
    }
    return t.clamp(0, count - 1);
  }

  /// 是否属于"没滑够、弹回原页"。
  static bool isSnapBack({
    required int from,
    required int count,
    required double movedPx,
    required double pageWidth,
    required double velocityDx,
    double distFrac = kDistFrac,
    double velocity = kVelocity,
  }) =>
      target(from: from, count: count, movedPx: movedPx, pageWidth: pageWidth,
          velocityDx: velocityDx, distFrac: distFrac, velocity: velocity) == from;
}
