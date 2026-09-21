import 'package:flutter/gestures.dart';

import 'nav_swipe_logic.dart';

export 'nav_swipe_logic.dart';

/// 带「主方向判定」的水平拖拽识别器。
///
/// 与内置 [HorizontalDragGestureRecognizer] 的区别只有一处：
/// **接受手势的条件额外要求"水平分量明确占主导"**。
///
/// 原版只检查水平位移是否超过 kTouchSlop(18)，不看垂直分量 ——
/// 所以"斜着往上滑"时水平分量先到 18，模块就被切走，而用户本意是滚动内容。
/// 本类要求 `|dx| >= slop && |dx| > |dy| * 1.25` 才接受；
/// 一旦发现 `|dy| > |dx| * 1.15`，立刻 [resolve] 成 rejected 主动退出竞技场，
/// 让模块内的滚动视图成为唯一成员并接管这次手势。
///
/// ★ 注意 `_resolveByDefault`（竞技场只剩一个成员时强制 accept）的存在：
/// 若当前页内没有可滚动视图，reject 后本识别器仍会被**强制接受**。
/// 所以调用方**必须**在 onStart/onUpdate/onEnd 回调里检查 [yieldedVertical]，
/// 已让位时不做任何驱动 —— 否则会退化成"上滑也翻页"。
class NavSwipeRecognizer extends HorizontalDragGestureRecognizer {
  NavSwipeRecognizer({super.debugOwner});

  final SwipeLatch _latch = SwipeLatch();
  double _startX = 0;
  double _startY = 0;

  /// 本次手势是否已经决定让位给垂直滚动。
  bool get yieldedVertical => _latch.yieldedVertical;

  /// 本次手势是否已经决定切模块。
  bool get acceptedHorizontal => _latch.acceptedHorizontal;

  /// 从按下点算起的累计水平位移（绝对位置差，不受 accept 时机影响）。
  double totalDx(double currentX) => currentX - _startX;

  /// 从按下点算起的累计垂直位移。
  double totalDy(double currentY) => currentY - _startY;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _latch.reset();
    _startX = event.position.dx;
    _startY = event.position.dy;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      final axis = _latch.update(totalDx(event.position.dx), totalDy(event.position.dy));
      if (axis == SwipeAxis.vertical) {
        // 明确垂直 → 主动退场。不调 super，避免它顺势接受这次手势。
        // 竞技场移除本成员后，若模块内有滚动视图，它将成为唯一成员并胜出。
        resolve(GestureDisposition.rejected);
        return;
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _latch.reset();
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    // 先过主方向这一关：只有横向明确占主导才允许进入"位移够不够"的判断。
    if (!_latch.acceptedHorizontal) return false;
    return super.hasSufficientGlobalDistanceToAccept(pointerDeviceKind, deviceTouchSlop);
  }
}
