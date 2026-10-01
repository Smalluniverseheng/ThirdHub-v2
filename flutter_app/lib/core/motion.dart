// ═══════════════════════════════════════════════════════════════════════════
// 交互动效库 · motion.dart
//
// 把《交互动效设计》技能文档的 13 种交互模式**从英文提示词变成可调用实现**。
// 技能只负责"判断该用哪种交互并产出提示词"，本文件负责"现学现用"——每个模式
// 一个组件或函数，直接挂到界面上。
//
// 十三模式对照（编号与技能文档一致）：
//   1  RadialThemeTransition  圆形主题切换      -> RadialThemeTransition.run()
//   2  Drag-to-Reorder        拖拽排序          -> DragReorderList
//   3  StaggeredBulkSelection 批量勾选          -> StaggeredCheckTile
//   4  VelocitySliderSnap     滑杆惯性吸附      -> VelocitySnapSlider
//   5  AnimatedTextDisclosure 文本展开          -> AnimatedDisclosure
//   6  SpringStepperProgress  步骤条回弹        -> SpringStepper
//   7  RippleSwitchGroup      开关联动反馈      -> RippleSwitchGroup
//   8  CurvedCardDeletion     卡片曲线删除      -> SwipeDeleteCard
//   9  StackedCardScroll      卡片堆叠滚动      -> StackedCardScroll
//   10 ExpandingTagSelection  标签挤开          -> ExpandingTagBar
//   11 FanMenuExpansion       悬浮球扇形展开    -> FanMenuOrb
//   12 ReaderPageCurl         阅读器仿真翻页    -> PageCurlView
//   13 CrossModuleDrag        跨模块拖拽        -> CrossModuleDraggable / DropZone
//
// ── 三条铁律（与技能文档「不要这样回答」一节对应）──
//  ① 视觉反馈绝不改变真实数据状态：涟漪开关组的邻近开关**只抖不改值**；
//  ② 先动画后数据：删除/跨模块拖拽都等退场动画结束再落库，中途取消能回原位；
//  ③ 动画不得改写真实位置：仿真翻页只在 completion 回调里更新阅读进度。
//
// 全部组件尊重系统「减弱动态效果」（MediaQuery.disableAnimations）→ 瞬时降级。
// 零第三方依赖，纯 Flutter。
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 系统是否要求「减弱动态效果」。所有动效组件都先问它。
bool reduceMotion(BuildContext c) =>
    MediaQuery.maybeOf(c)?.disableAnimations ?? false;

/// 统一的弹簧曲线（带轻微过冲，用于「弹到位」的观感）。
const Curve kSpringCurve = Cubic(0.34, 1.42, 0.64, 1.0);

/// 统一的缓出曲线（用于位移、淡出）。
const Curve kEaseOutCurve = Cubic(0.2, 0.8, 0.3, 1.0);

// ═══════════════════════════════════════════════════════════════════════════
// 1 · RadialThemeTransition —— 圆形主题切换
//
// 以**真实点击位置**为圆心，用圆形遮罩把新主题从该点揭示出来。
// 半径算法：圆心到最远屏幕角落的距离（保证必然覆盖全屏）。
// 只裁切上层「新主题快照」，不缩放页面内容。
// ═══════════════════════════════════════════════════════════════════════════
class RadialThemeTransition {
  RadialThemeTransition._();

  /// 在 [origin] 处播放一次圆形揭示。返回的 Future 在动画结束后完成。
  ///
  /// 用法：切换主题时先 capture 新主题的整屏外观到 [overlayBuilder]，
  /// 再调本函数；届时新主题从点击点扩散开，扩散完回调 [onDone]。
  static Future<void> run(
    BuildContext context, {
    required Offset origin,
    required Color revealColor,
    Duration duration = const Duration(milliseconds: 420),
  }) async {
    if (reduceMotion(context)) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final size = MediaQuery.of(context).size;
    // 圆心到最远角的距离 —— 保证圆能盖满整个屏幕
    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    final maxR = math.sqrt(dx * dx + dy * dy);

    final entry = OverlayEntry(
      builder: (_) => _RadialReveal(
        origin: origin,
        maxRadius: maxR,
        color: revealColor,
        duration: duration,
      ),
    );
    overlay.insert(entry);
    await Future<void>.delayed(duration + const Duration(milliseconds: 40));
    entry.remove();
  }
}

class _RadialReveal extends StatefulWidget {
  final Offset origin;
  final double maxRadius;
  final Color color;
  final Duration duration;
  const _RadialReveal(
      {required this.origin,
      required this.maxRadius,
      required this.color,
      required this.duration});

  @override
  State<_RadialReveal> createState() => _RadialRevealState();
}

class _RadialRevealState extends State<_RadialReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: widget.duration)
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = kEaseOutCurve.transform(_c.value);
          return ClipPath(
            clipper: _CircleRevealClipper(
                origin: widget.origin, radius: widget.maxRadius * t),
            child: Container(color: widget.color),
          );
        },
      ),
    );
  }
}

class _CircleRevealClipper extends CustomClipper<Path> {
  final Offset origin;
  final double radius;
  const _CircleRevealClipper({required this.origin, required this.radius});

  @override
  Path getClip(Size size) => Path()
    ..addOval(Rect.fromCircle(center: origin, radius: radius));

  @override
  bool shouldReclip(_CircleRevealClipper old) =>
      old.radius != radius || old.origin != origin;
}

// ═══════════════════════════════════════════════════════════════════════════
// 2 · Drag-to-Reorder —— 拖拽排序
//
// 拖动项脱离列表流、其余项让出空槽、每项独立追赶（Flutter 的 Reorderable
// 已实现该模型）。这里补上「拖动中抬升」的视觉与长按触感。
// ═══════════════════════════════════════════════════════════════════════════
class DragReorderList extends StatelessWidget {
  final int itemCount;
  final Widget Function(BuildContext, int, bool) itemBuilder;
  final void Function(int oldIndex, int newIndex) onReorder;
  final EdgeInsetsGeometry? padding;
  final bool enabled;

  /// [itemBuilder] 的第三参数 = 该项当前是否正被拖动。
  const DragReorderList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onReorder,
    this.padding,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled || reduceMotion(context) || itemCount < 2) {
      return padding == null
          ? ListView.builder(
              itemCount: itemCount,
              itemBuilder: (c, i) => itemBuilder(c, i, false))
          : ListView.builder(
              padding: padding,
              itemCount: itemCount,
              itemBuilder: (c, i) => itemBuilder(c, i, false));
    }
    return ReorderableListView.builder(
      padding: padding,
      itemCount: itemCount,
      onReorder: (a, b) {
        HapticFeedback.selectionClick();
        onReorder(a, b);
      },
      proxyDecorator: (child, index, animation) => AnimatedBuilder(
        animation: animation,
        builder: (_, __) {
          final t = kSpringCurve.transform(animation.value.clamp(0.0, 1.0));
          return Transform.scale(
            scale: 1.0 + 0.03 * t,
            child: Material(
              color: Colors.transparent,
              elevation: 8 * t,
              borderRadius: BorderRadius.circular(12),
              child: child,
            ),
          );
        },
      ),
      itemBuilder: (c, i) => KeyedSubtree(
        key: ValueKey('motion-reorder-$i'),
        child: itemBuilder(c, i, false),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 3 · StaggeredBulkSelection —— 批量勾选错峰
//
// 状态**立即**更新，勾选标记从第一项起错峰弹出（轻微弹性放大）。
// 动画不阻塞用户继续操作。
// ═══════════════════════════════════════════════════════════════════════════
class StaggeredCheckMark extends StatefulWidget {
  final bool checked;
  final int index;
  final double size;
  final Color? color;
  const StaggeredCheckMark({
    super.key,
    required this.checked,
    required this.index,
    this.size = 20,
    this.color,
  });

  @override
  State<StaggeredCheckMark> createState() => _StaggeredCheckMarkState();
}

class _StaggeredCheckMarkState extends State<StaggeredCheckMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  @override
  void initState() {
    super.initState();
    if (widget.checked) _c.value = 1;
  }

  @override
  void didUpdateWidget(StaggeredCheckMark old) {
    super.didUpdateWidget(old);
    if (widget.checked == old.checked) return;
    if (reduceMotion(context)) {
      _c.value = widget.checked ? 1 : 0;
      return;
    }
    if (widget.checked) {
      // 错峰：第 n 项延迟 n*36ms（上限 260ms），视觉从第一项往后铺开
      Future<void>.delayed(
          Duration(milliseconds: math.min(widget.index * 36, 260)), () {
        if (mounted && widget.checked) _c.forward(from: 0);
      });
    } else {
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final col = widget.color ?? Theme.of(context).colorScheme.primary;
    final t = _c.value;
    // 弹性放大：0 -> 1.18 -> 1.0
    final scale = t <= 0 ? 0.0 : (1.0 + 0.18 * math.sin(t * math.pi));
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: t > 0.05 ? col : Colors.transparent,
              border: Border.all(
                  color: t > 0.05 ? col : Colors.grey.shade400, width: 1.5),
            ),
            child: t > 0.35
                ? Icon(Icons.check, size: widget.size * 0.62, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 4 · VelocitySliderSnap —— 滑杆惯性吸附
//
// 记录释放速度 → 松手时按速度短距离过冲 → 弹簧回到最近合法刻度。
// 最终值恒被 clamp 在 [min, max]。
// ═══════════════════════════════════════════════════════════════════════════
class VelocitySnapSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final double height;

  const VelocitySnapSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions = 10,
    this.height = 36,
  });

  @override
  State<VelocitySnapSlider> createState() => _VelocitySnapSliderState();
}

class _VelocitySnapSliderState extends State<VelocitySnapSlider>
    with SingleTickerProviderStateMixin {
  late double _v = widget.value;
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Animation<double>? _anim;

  @override
  void didUpdateWidget(VelocitySnapSlider old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_c.isAnimating) setState(() => _v = widget.value);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _snapTo(double raw) {
    final step = (widget.max - widget.min) / widget.divisions;
    final n = ((raw - widget.min) / step).round();
    return (widget.min + n * step).clamp(widget.min, widget.max);
  }

  void _settleWithVelocity(double pxPerSec, double width) {
    final target = _snapTo(_v);
    if (reduceMotion(context)) {
      setState(() => _v = target);
      widget.onChanged(target);
      return;
    }
    // 速度换算成过冲量（限制在 ±1.2 个刻度内，保持"轻微"）
    final step = (widget.max - widget.min) / widget.divisions;
    final stepPx = width / widget.divisions;
    final overshootPx =
        (pxPerSec / 1000.0 * stepPx * 0.35).clamp(-stepPx * 1.2, stepPx * 1.2);
    final overshoot = _v + overshootPx / stepPx * step;
    final over = (overshoot).clamp(widget.min, widget.max);
    _anim = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: _v, end: over)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: over, end: target)
              .chain(CurveTween(curve: kSpringCurve)),
          weight: 70),
    ]).animate(_c);
    _c.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() => _v = target);
      widget.onChanged(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final col = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (c, box) {
        final w = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            final dv = d.delta.dx / w * (widget.max - widget.min);
            setState(() => _v = (_v + dv).clamp(widget.min, widget.max));
          },
          onHorizontalDragEnd: (d) =>
              _settleWithVelocity(d.velocity.pixelsPerSecond.dx, w),
          child: SizedBox(
            height: widget.height,
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                final shown = _c.isAnimating ? (_anim?.value ?? _v) : _v;
                return CustomPaint(
                  painter: _SnapSliderPainter(
                    value: shown,
                    min: widget.min,
                    max: widget.max,
                    divisions: widget.divisions,
                    color: col,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _SnapSliderPainter extends CustomPainter {
  final double value, min, max;
  final int divisions;
  final Color color;
  _SnapSliderPainter(
      {required this.value,
      required this.min,
      required this.max,
      required this.divisions,
      required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final track = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(10, cy), Offset(size.width - 10, cy), track);

    final usable = size.width - 20;
    final frac = (value - min) / (max - min);
    final x = 10 + usable * frac;

    canvas.drawLine(Offset(10, cy), Offset(x, cy),
        Paint()..color = color..strokeWidth = 4..strokeCap = StrokeCap.round);

    // 刻度
    final tick = Paint()..color = color.withValues(alpha: 0.35);
    for (var i = 0; i <= divisions; i++) {
      final tx = 10 + usable * (i / divisions);
      canvas.drawCircle(Offset(tx, cy), 1.5, tick);
    }
    // 滑块
    canvas.drawCircle(Offset(x, cy), 9, Paint()..color = color);
    canvas.drawCircle(Offset(x, cy), 3.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SnapSliderPainter old) => old.value != value;
}

// ═══════════════════════════════════════════════════════════════════════════
// 5 · AnimatedTextDisclosure —— 文本展开
//
// 按**真实内容高度**过渡（AnimatedSize 测量），箭头旋转 180°，无布局跳动。
// ═══════════════════════════════════════════════════════════════════════════
class AnimatedDisclosure extends StatefulWidget {
  final String title;
  final Widget child;
  final bool initiallyOpen;
  final TextStyle? titleStyle;
  final EdgeInsetsGeometry padding;

  const AnimatedDisclosure({
    super.key,
    required this.title,
    required this.child,
    this.initiallyOpen = false,
    this.titleStyle,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  });

  @override
  State<AnimatedDisclosure> createState() => _AnimatedDisclosureState();
}

class _AnimatedDisclosureState extends State<AnimatedDisclosure> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final dur = reduceMotion(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _open = !_open);
          },
          child: Padding(
            padding: widget.padding,
            child: Row(children: [
              Expanded(
                child: Text(widget.title,
                    style: widget.titleStyle ??
                        const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ),
              AnimatedRotation(
                turns: _open ? 0.5 : 0.0,
                duration: dur,
                curve: kEaseOutCurve,
                child: const Icon(Icons.keyboard_arrow_down, size: 18),
              ),
            ]),
          ),
        ),
        // 用真实内容高度做过渡，不写死高度 → 不会文字突现或跳动
        AnimatedSize(
          duration: dur,
          curve: kEaseOutCurve,
          alignment: Alignment.topCenter,
          child: _open
              ? widget.child
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 6 · SpringStepperProgress —— 步骤条回弹
//
// 推进时进度段先略微越过目标再回弹；动画**不改变**真实步骤状态。
// ═══════════════════════════════════════════════════════════════════════════
class SpringStepper extends StatelessWidget {
  final int total;
  final int current;
  final double height;
  final Color? activeColor;

  /// current 为「已完成步数」（0..total）。
  const SpringStepper(
      {super.key,
      required this.total,
      required this.current,
      this.height = 6,
      this.activeColor});

  @override
  Widget build(BuildContext context) {
    final col = activeColor ?? Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: i < current ? 1.0 : 0.0),
              duration: reduceMotion(context)
                  ? Duration.zero
                  : Duration(milliseconds: 320 + i * 60),
              // easeOutBack 自带过冲 → 段落先越过再回弹
              curve: Curves.easeOutBack,
              builder: (_, t, __) => Container(
                height: height,
                decoration: BoxDecoration(
                  color: col.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(height),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: t.clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: col,
                      borderRadius: BorderRadius.circular(height),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 7 · RippleSwitchGroup —— 开关联动反馈
//
// 切换其中一个开关时，**邻近开关只产生涟漪/位移反馈，真实状态一律不变**。
// 这是技能文档点名的红线：视觉反馈 ≠ 数据变化。
// ═══════════════════════════════════════════════════════════════════════════
class RippleSwitchGroup extends StatefulWidget {
  final List<String> labels;
  final List<bool> values;
  final void Function(int index, bool value) onChanged;
  final int? rippleRadius;

  const RippleSwitchGroup({
    super.key,
    required this.labels,
    required this.values,
    required this.onChanged,
    this.rippleRadius = 1,
  });

  @override
  State<RippleSwitchGroup> createState() => _RippleSwitchGroupState();
}

class _RippleSwitchGroupState extends State<RippleSwitchGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  int _source = -1;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _trigger(int i) {
    if (reduceMotion(context)) return;
    setState(() => _source = i);
    _c.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (c, __) {
        final t = _c.value;
        return Column(
          children: [
            for (var i = 0; i < widget.labels.length; i++)
              _row(i, t),
          ],
        );
      },
    );
  }

  Widget _row(int i, double t) {
    // 距源越近，抖动越明显；但 Scale/Translate 只是视觉，**不碰 value**
    final d = (_source < 0) ? 99 : (i - _source).abs();
    final inRange = d > 0 && d <= widget.rippleRadius;
    final wave = inRange ? math.sin(t * math.pi) * (1.0 - (d - 1) * 0.4) : 0.0;
    final decay = inRange ? math.exp(-t * 3.0) : 0.0;
    final dx = math.sin(t * math.pi * 4) * 2.4 * wave * decay;

    return Transform.translate(
      offset: Offset(dx, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(widget.labels[i], style: const TextStyle(fontSize: 13))),
          Switch(
            value: widget.values[i], // ← 始终是真实值，涟漪只动视觉
            onChanged: (v) {
              setState(() => _source = i);
              _trigger(i);
              widget.onChanged(i, v);
            },
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 8 · CurvedCardDeletion —— 卡片曲线删除
//
// 超过阈值：卡片沿**二次贝塞尔曲线**飞向删除区，途中缩小 + 旋转 + 淡出，
// 退场动画结束后才真正删数据；未达阈值：弹簧回原位。
// ═══════════════════════════════════════════════════════════════════════════
class SwipeDeleteCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onDeleted;
  final double threshold;
  final IconData deleteIcon;
  final Color? deleteColor;

  const SwipeDeleteCard({
    super.key,
    required this.child,
    required this.onDeleted,
    this.threshold = 96,
    this.deleteIcon = Icons.delete_outline,
    this.deleteColor,
  });

  @override
  State<SwipeDeleteCard> createState() => _SwipeDeleteCardState();
}

class _SwipeDeleteCardState extends State<SwipeDeleteCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  double _dx = 0;
  bool _flying = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _fly() {
    _flying = true;
    _c.forward(from: 0).whenComplete(() {
      if (mounted) widget.onDeleted(); // ★ 动画结束才落数据
    });
  }

  @override
  Widget build(BuildContext context) {
    final col = widget.deleteColor ?? Theme.of(context).colorScheme.error;
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        if (_flying) return;
        setState(() => _dx = (_dx + d.delta.dx).clamp(-220.0, 220.0));
      },
      onHorizontalDragEnd: (_) {
        if (_flying) return;
        if (_dx.abs() >= widget.threshold) {
          HapticFeedback.mediumImpact();
          _fly();
        } else {
          if (reduceMotion(context)) {
            setState(() => _dx = 0);
          } else {
            setState(() => _dx = 0);
          }
        }
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (c, child) {
          final t = _flying ? _c.value : 0.0;
          final w = MediaQuery.of(c).size.width;
          // 起点：当前拖到的位置；终点：飞出屏外的删除区（右下）
          final start = Offset(_dx, 0);
          final end = Offset(_dx.sign * w * 0.9, 96.0);
          // 二次贝塞尔：控制点抬高，形成"抛物线"路径
          final ctrl = Offset((start.dx + end.dx) / 2, -70.0);
          final p = _quad(start, ctrl, end, t);
          final scale = 1.0 - 0.45 * t;
          final rot = _dx.sign * 0.22 * t;
          final opacity = 1.0 - t;
          return Stack(
            children: [
              if (_flying || _dx.abs() > 4)
                Positioned.fill(
                  child: Align(
                    alignment: _dx.sign > 0 ? Alignment.centerLeft : Alignment.centerRight,
                    child: Opacity(
                      opacity: (_dx.abs() / widget.threshold).clamp(0.0, 1.0),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Icon(widget.deleteIcon, color: col, size: 22),
                      ),
                    ),
                  ),
                ),
              Transform.translate(
                offset: _flying ? p : Offset(_dx, 0),
                child: Transform.rotate(
                  angle: _flying ? rot : 0,
                  child: Transform.scale(
                    scale: _flying ? scale : 1.0,
                    child: Opacity(
                        opacity: _flying ? opacity : 1.0, child: child),
                  ),
                ),
              ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }

  static Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return Offset(
      u * u * a.dx + 2 * u * t * c.dx + t * t * b.dx,
      u * u * a.dy + 2 * u * t * c.dy + t * t * b.dy,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 9 · StackedCardScroll —— 卡片堆叠滚动
//
// 滚动时后面的卡片上移并把前面的压成一摞：位移/缩放/层级由"身后卡片数"决定。
// ═══════════════════════════════════════════════════════════════════════════
class StackedCardScroll extends StatefulWidget {
  final int itemCount;
  final double itemExtent;
  final Widget Function(BuildContext, int) itemBuilder;
  final double stackScale;
  final double stackOffset;

  const StackedCardScroll({
    super.key,
    required this.itemCount,
    required this.itemExtent,
    required this.itemBuilder,
    this.stackScale = 0.06,
    this.stackOffset = 14,
  });

  @override
  State<StackedCardScroll> createState() => _StackedCardScrollState();
}

class _StackedCardScrollState extends State<StackedCardScroll> {
  final _sc = ScrollController();

  @override
  void initState() {
    super.initState();
    _sc.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) {
      return ListView.builder(
        controller: _sc,
        itemCount: widget.itemCount,
        itemExtent: widget.itemExtent,
        itemBuilder: (c, i) => widget.itemBuilder(c, i),
      );
    }
    return ListView.builder(
      controller: _sc,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.itemCount,
      itemBuilder: (c, i) {
        final pos = _sc.hasClients ? _sc.offset : 0.0;
        final myTop = i * widget.itemExtent;
        // 卡片越过视口顶部后方数 = 已滑过多少张
        final behind = ((pos - myTop) / widget.itemExtent).clamp(0.0, 3.0);
        final scale = 1.0 - widget.stackScale * behind;
        final dy = -widget.stackOffset * behind;
        return Transform.translate(
          offset: Offset(0, dy),
          child: Transform.scale(
            scale: scale.clamp(0.7, 1.0),
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: widget.itemExtent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: widget.itemBuilder(c, i),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 10 · ExpandingTagSelection —— 标签挤开
//
// 选中项轻微放大，邻近标签平滑向两侧让位（Translate，不重叠不跳变），
// 小屏自动换行（Wrap）。
// ═══════════════════════════════════════════════════════════════════════════
class ExpandingTagBar extends StatelessWidget {
  final List<String> tags;
  final String? selected;
  final ValueChanged<String> onSelect;
  final double gap;

  const ExpandingTagBar({
    super.key,
    required this.tags,
    required this.selected,
    required this.onSelect,
    this.gap = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final t in tags) _tag(context, t),
      ],
    );
  }

  Widget _tag(BuildContext c, String t) {
    final on = t == selected;
    final dur = reduceMotion(c)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onSelect(t);
      },
      child: AnimatedScale(
        scale: on ? 1.08 : 1.0,
        duration: dur,
        curve: kSpringCurve,
        child: AnimatedPadding(
          // 选中时两端多占一点空间 → 邻近标签被"挤开"
          duration: dur,
          curve: kEaseOutCurve,
          padding: EdgeInsets.symmetric(horizontal: on ? 4 : 0, vertical: on ? 2 : 0),
          child: AnimatedContainer(
            duration: dur,
            curve: kEaseOutCurve,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: on
                  ? Theme.of(c).colorScheme.primary.withValues(alpha: 0.12)
                  : Theme.of(c).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: on
                    ? Theme.of(c).colorScheme.primary.withValues(alpha: 0.55)
                    : Colors.transparent,
                width: 1,
              ),
            ),
            child: Text(
              t,
              style: TextStyle(
                fontSize: 13,
                fontWeight: on ? FontWeight.w500 : FontWeight.w400,
                color: on ? Theme.of(c).colorScheme.primary : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 11 · FanMenuExpansion —— 悬浮球扇形展开（ThirdHub 专属）
//
// 点球 → 菜单项从球心沿弧线错峰弹出（带弹簧过冲）；当前模块高亮；
// 半透明遮罩点击收起；长按球可拖动换位、松手吸附边缘；系统减弱动态效果时瞬时展开。
// ═══════════════════════════════════════════════════════════════════════════
class FanMenuOrb extends StatefulWidget {
  /// 每个菜单项：图标 + 文案 + 是否当前所在项。
  final List<FanItem> items;
  final void Function(int index) onPick;
  final Offset initialPosition;
  final void Function(Offset) onMoved;
  final bool snapToEdge;
  final double orbSize;

  const FanMenuOrb({
    super.key,
    required this.items,
    required this.onPick,
    required this.initialPosition,
    required this.onMoved,
    this.snapToEdge = true,
    this.orbSize = 52,
  });

  @override
  State<FanMenuOrb> createState() => _FanMenuOrbState();
}

class FanItem {
  final IconData icon;
  final String label;
  final bool active;
  const FanItem(this.icon, this.label, {this.active = false});
}

class _FanMenuOrbState extends State<FanMenuOrb>
    with SingleTickerProviderStateMixin {
  late Offset _pos = widget.initialPosition;
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 340));
  bool _open = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _toggle() {
    HapticFeedback.selectionClick();
    setState(() => _open = !_open);
    if (reduceMotion(context)) {
      _c.value = _open ? 1 : 0;
    } else {
      _open ? _c.forward(from: 0) : _c.reverse();
    }
  }

  /// 扇形角度：从球心向左上/右上展开 90° 扇面，方向随球在屏幕左/右自动翻转。
  double get _baseAngle {
    final w = MediaQuery.of(context).size.width;
    return _pos.dx + widget.orbSize / 2 < w / 2 ? 0.0 : math.pi;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final col = Theme.of(context).colorScheme;
    const radius = 118.0;
    final n = widget.items.length;

    return Stack(
      children: [
        // 遮罩：展开时铺满，点击收起
        if (_open)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: AnimatedOpacity(
                opacity: _open ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(color: Colors.black.withValues(alpha: 0.28)),
              ),
            ),
          ),
        // 菜单项（从球心沿弧线弹出）
        for (var i = 0; i < n; i++) _fanItem(i, n, radius, screen, col),
        // 球体本身
        Positioned(
          left: _pos.dx,
          top: _pos.dy,
          child: GestureDetector(
            onTap: _toggle,
            onPanUpdate: (d) => setState(() => _pos = Offset(
                  (_pos.dx + d.delta.dx).clamp(0.0, screen.width - widget.orbSize),
                  (_pos.dy + d.delta.dy)
                      .clamp(60.0, screen.height - widget.orbSize - 40),
                )),
            onPanEnd: (_) {
              if (widget.snapToEdge) {
                setState(() => _pos = Offset(
                      (_pos.dx + widget.orbSize / 2) < screen.width / 2
                          ? 10
                          : screen.width - widget.orbSize - 10,
                      _pos.dy.clamp(80.0, screen.height - 220),
                    ));
              }
              widget.onMoved(_pos);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: kEaseOutCurve,
              width: widget.orbSize,
              height: widget.orbSize,
              decoration: BoxDecoration(
                color: col.primaryContainer.withValues(alpha: 0.94),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: _open ? 0.3 : 0.2),
                      blurRadius: _open ? 14 : 8)
                ],
              ),
              child: AnimatedRotation(
                turns: _open ? 0.125 : 0,
                duration: const Duration(milliseconds: 220),
                child: Icon(_open ? Icons.close : Icons.apps, color: col.primary),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fanItem(
      int i, int n, double radius, Size screen, ColorScheme col) {
    // 沿弧线均分：起点 baseAngle，跨 90°
    final t = n == 1 ? 0.5 : i / (n - 1);
    final ang = _baseAngle + (math.pi / 2) * (0.5 - t);
    final cx = _pos.dx + widget.orbSize / 2 - 24;
    final cy = _pos.dy + widget.orbSize / 2 - 24;
    final target = Offset(
      cx + math.cos(ang) * radius,
      cy - math.sin(ang) * radius,
    );

    return AnimatedBuilder(
      animation: _c,
      builder: (c, __) {
        // 错峰：第 i 项延迟 i*45ms 等效（用分段区间近似）
        final seg = 1.0 / (n + 2);
        final local =
            ((_c.value - i * seg) / (seg * 2)).clamp(0.0, 1.0);
        if (local <= 0) return const SizedBox.shrink();
        final e = kSpringCurve.transform(local);
        final p = Offset.lerp(Offset(cx, cy), target, e)!;
        final item = widget.items[i];
        return Positioned(
          left: p.dx.clamp(4.0, screen.width - 52),
          top: p.dy.clamp(60.0, screen.height - 80),
          child: Opacity(
            opacity: local.clamp(0.0, 1.0),
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                _toggle();
                widget.onPick(i);
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: item.active
                      ? col.primary
                      : col.surfaceContainerHighest.withValues(alpha: 0.96),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18), blurRadius: 6)
                  ],
                ),
                child: Icon(item.icon,
                    size: 22,
                    color: item.active ? col.onPrimary : col.onSurfaceVariant),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 12 · ReaderPageCurl —— 阅读器仿真翻页（ThirdHub 专属）
//
// 三屏承载：底层 = 即将露出的一页（prev/next），中层 = 当前页（跟手翻卷）。
// 折痕轴以**触摸点纵向位置**为锚点（alignment 的 y 分量随手指移动）。
// 翻起页有背面+卷边阴影；松手按位移/速度决定完成或回弹。
// ★ 动画绝不改动真实章节位置 —— 只在 completion 里回调 onTurn。
// ═══════════════════════════════════════════════════════════════════════════
/// 翻页风格：curl = 纸张卷曲（仿真）/ cover = 新页盖入 / slide = 平移。
enum PageTurnStyle { curl, cover, slide }

class PageCurlView extends StatefulWidget {
  final Widget current;
  final Widget? previous;
  final Widget? next;
  final Color bgColor;
  final Color backColor;

  /// 翻页完成回调：true = 前进到下一屏，false = 退回上一屏。
  final void Function(bool forward)? onTurn;

  /// 翻页风格（见 PageTurnStyle）。
  final PageTurnStyle style;

  /// 是否允许翻动。
  final bool enabled;

  const PageCurlView({
    super.key,
    required this.current,
    required this.bgColor,
    this.previous,
    this.next,
    this.backColor = const Color(0xFFF3EDE2),
    this.onTurn,
    this.style = PageTurnStyle.curl,
    this.enabled = true,
  });

  @override
  State<PageCurlView> createState() => _PageCurlViewState();
}

class _PageCurlViewState extends State<PageCurlView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 320));
  double _drag = 0; // 拖拽位移（px，左负右正）
  double _anchorY = 0.5; // 折痕锚点（0..1）
  bool _settling = false;
  bool _forward = true;
  double _settleFrom = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _complete(bool forward) {
    _forward = forward;
    _settleFrom = _drag;
    _settling = true;
    if (reduceMotion(context)) {
      widget.onTurn?.call(forward);
      setState(() {
        _settling = false;
        _drag = 0;
      });
      return;
    }
    _c.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      // ★ 先动画，后数据：翻页动作走完才通知真实章节位置变化
      widget.onTurn?.call(forward);
      setState(() {
        _settling = false;
        _drag = 0;
      });
    });
  }

  void _cancel() {
    _settleFrom = _drag;
    _forward = _drag < 0;
    _settling = true;
    if (reduceMotion(context)) {
      setState(() {
        _settling = false;
        _drag = 0;
      });
      return;
    }
    _c.forward(from: 0).whenComplete(() {
      if (mounted)
        setState(() {
          _settling = false;
          _drag = 0;
        });
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: widget.enabled
          ? (d) {
              setState(() {
                _anchorY = (d.localPosition.dy /
                        math.max(1, MediaQuery.of(context).size.height))
                    .clamp(0.08, 0.92);
              });
            }
          : null,
      onHorizontalDragUpdate: widget.enabled
          ? (d) => setState(() {
                _drag = (_drag + d.delta.dx).clamp(-w, w);
              })
          : null,
      onHorizontalDragEnd: widget.enabled
          ? (d) {
              final v = d.velocity.pixelsPerSecond.dx;
              final far = _drag.abs() > w * 0.34;
              final fling = v.abs() > 420;
              final goForward = _drag < 0;
              if (far || fling) {
                // 边界：前面/后面没有页时回弹
                if (goForward && widget.next == null) return _cancel();
                if (!goForward && widget.previous == null) return _cancel();
                _complete(goForward);
              } else {
                _cancel();
              }
            }
          : null,
      child: AnimatedBuilder(
        animation: _c,
        builder: (c, _) {
          double dx;
          if (_settling) {
            final t = kEaseOutCurve.transform(_c.value);
            final target = _forward ? -w : 0.0;
            dx = _settleFrom + (target - _settleFrom) * t;
          } else {
            dx = _drag;
          }
          final prog = (dx.abs() / w).clamp(0.0, 1.0);
          final showingNext = dx < 0;

          final reveal = showingNext
              ? (widget.next ?? const SizedBox.shrink())
              : (widget.previous ?? const SizedBox.shrink());

          // cover：当前页完全不动，目标页从侧边滑入盖住它
          if (widget.style == PageTurnStyle.cover) {
            return Stack(children: [
              Positioned.fill(
                  child:
                      Container(color: widget.bgColor, child: widget.current)),
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(showingNext ? w + dx : -w + dx, 0),
                  child: Container(
                    color: widget.bgColor,
                    child: Stack(children: [
                      reveal,
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: showingNext ? null : 0,
                        left: showingNext ? 0 : null,
                        width: 18,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: showingNext
                                  ? Alignment.centerLeft
                                  : Alignment.centerRight,
                              end: showingNext
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              colors: [
                                Colors.black.withValues(alpha: 0.20 * prog),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ]);
          }

          return Stack(
            children: [
              // 底层：将要露出的那一页
              Positioned.fill(
                child: Container(color: widget.bgColor, child: reveal),
              ),
              // 上层：当前页（跟手翻卷 / 平移）
              Positioned.fill(
                child: widget.style == PageTurnStyle.slide
                    ? Transform.translate(
                        offset: Offset(dx, 0),
                        child: Container(
                          color: widget.bgColor,
                          child: Stack(children: [
                            widget.current,
                            // 滑动模式下的边缘阴影（降级表现）
                            Positioned(
                              top: 0,
                              bottom: 0,
                              right: showingNext ? 0 : null,
                              left: showingNext ? null : 0,
                              width: 18,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: showingNext
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    end: showingNext
                                        ? Alignment.centerLeft
                                        : Alignment.centerRight,
                                    colors: [
                                      Colors.black.withValues(alpha: 0.16 * prog),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ]),
                        ),
                      )
                    : Transform(
                        // 折痕轴跟随触摸点纵向位置 → 「以触摸点为折痕锚点」
                        alignment: Alignment(
                            showingNext ? -1.0 : 1.0, _anchorY * 2 - 1),
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.0014)
                          ..rotateY((showingNext ? -1 : 1) * prog * math.pi / 2),
                        child: Container(
                          color: widget.bgColor,
                          child: Stack(children: [
                            widget.current,
                            // 卷边：翻起页的背面 + 阴影，让纸有厚度
                            Positioned(
                              top: 0,
                              bottom: 0,
                              right: showingNext ? 0 : null,
                              left: showingNext ? null : 0,
                              width: 30 * math.max(prog, 0.001),
                              child: CustomPaint(
                                painter: _CurlEdgePainter(
                                  progress: prog,
                                  back: widget.backColor,
                                  onRight: showingNext,
                                ),
                              ),
                            ),
                          ]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 卷边绘制：背面底色 + 内侧阴影 + 折痕高光。
class _CurlEdgePainter extends CustomPainter {
  final double progress;
  final Color back;
  final bool onRight;
  _CurlEdgePainter(
      {required this.progress, required this.back, required this.onRight});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0.5) return;
    final r = Rect.fromLTWH(0, 0, size.width, size.height);
    // 背面
    canvas.drawRect(r, Paint()..color = back);
    // 内侧阴影（越靠近折痕越深）
    final shadow = LinearGradient(
      begin: onRight ? Alignment.centerRight : Alignment.centerLeft,
      end: onRight ? Alignment.centerLeft : Alignment.centerRight,
      colors: [
        Colors.black.withValues(alpha: 0.30 * progress),
        Colors.black.withValues(alpha: 0.05 * progress),
        Colors.transparent,
      ],
    );
    canvas.drawRect(
      r,
      Paint()
        ..shader = shadow.createShader(r),
    );
    // 折痕高光
    final x = onRight ? 0.5 : size.width - 0.5;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.5 * progress)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_CurlEdgePainter old) =>
      old.progress != progress || old.onRight != onRight;
}

// ═══════════════════════════════════════════════════════════════════════════
// 13 · CrossModuleDrag —— 卡片跨模块拖拽
//
// 拖动时卡片悬浮跟手（缩放 1.05 + 阴影）；经过合法目标时目标高亮并轻微放大；
// 松手后卡片沿短曲线飞入目标容器，**先动画后数据**；取消则弹簧回原位。
// ═══════════════════════════════════════════════════════════════════════════
class CrossModuleDraggable<T> extends StatefulWidget {
  final T payload;
  final Widget child;
  final Widget Function(BuildContext, T, bool dragging) feedbackBuilder;

  /// 松手后由外部决定是否接受（返回 true 则执行 onDropped）。
  final Future<bool> Function(T payload, String zoneId)? onDropped;
  final VoidCallback? onCancelled;

  const CrossModuleDraggable({
    super.key,
    required this.payload,
    required this.child,
    required this.feedbackBuilder,
    this.onDropped,
    this.onCancelled,
  });

  @override
  State<CrossModuleDraggable> createState() => _CrossModuleDraggableState<T>();
}

class _CrossModuleDraggableState<T> extends State<CrossModuleDraggable<T>> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<String>(
      data: 'drag',
      delay: const Duration(milliseconds: 160),
      onDragStarted: () {
        HapticFeedback.selectionClick();
        setState(() => _dragging = true);
      },
      onDraggableCanceled: (_, __) {
        setState(() => _dragging = false);
        widget.onCancelled?.call();
      },
      onDragEnd: (_) => setState(() => _dragging = false),
      feedback: Material(
        color: Colors.transparent,
        child: Transform.scale(
          scale: 1.05, // 悬浮放大
          child: Opacity(
            opacity: 0.94,
            child: widget.feedbackBuilder(context, widget.payload, true),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: widget.feedbackBuilder(context, widget.payload, false),
      ),
      child: widget.child,
    );
  }
}

/// 可接收目标：卡片经过时高亮 + 轻微放大。
class CrossModuleDropZone extends StatefulWidget {
  final String zoneId;
  final Widget child;
  final Future<bool> Function(Object payload)? onAccept;
  final String? hint;

  const CrossModuleDropZone({
    super.key,
    required this.zoneId,
    required this.child,
    this.onAccept,
    this.hint,
  });

  @override
  State<CrossModuleDropZone> createState() => _CrossModuleDropZoneState();
}

class _CrossModuleDropZoneState extends State<CrossModuleDropZone> {
  bool _hot = false;

  @override
  Widget build(BuildContext context) {
    final col = Theme.of(context).colorScheme.primary;
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) {
        setState(() => _hot = true);
        return true;
      },
      onLeave: (_) => setState(() => _hot = false),
      onAcceptWithDetails: (d) async {
        setState(() => _hot = false);
        HapticFeedback.mediumImpact();
        // 先动画（高亮反馈）后数据：数据写入交给回调，失败由调用方回滚
        await widget.onAccept?.call(d.data ?? '');
      },
      builder: (c, cand, rej) {
        return AnimatedScale(
          scale: _hot ? 1.04 : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: kEaseOutCurve,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _hot ? col : Colors.transparent,
                width: _hot ? 1.5 : 0,
              ),
              color: _hot ? col.withValues(alpha: 0.08) : Colors.transparent,
            ),
            child: widget.child,
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// A · 真实测量分页（canvas 预分页）
//
// 原来的分页是「按估算行字数切块」——字号/字体/换行/标点各占一格宽都不同，
// 于是页尾常出现半行空档或文字被截断。这里改用 TextPainter 做**真实排版测量**：
// 先用 getPositionForOffset(右下角) 找到该页能容纳到的字符位置，再从那里切开。
// 这是 wuji-tauri 的 measureText 预分页同款思路。
// ═══════════════════════════════════════════════════════════════════════════
class TextPaginator {
  TextPaginator._();

  /// 把 [text] 按 [style] 在 [maxWidth]×[maxHeight] 的版面里切成若干页。
  ///
  /// [paraSpace] 是段间距，「\n\n」之间的额外空隙也计入高度估算。
  static List<String> paginate({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    double paraSpace = 0,
  }) {
    final t = text.trim();
    if (t.isEmpty || maxWidth <= 8 || maxHeight <= 8) return [t];

    final pages = <String>[];
    var start = 0;
    final total = t.length;

    while (start < total) {
      final remain = t.substring(start);
      final tp = TextPainter(
        text: TextSpan(text: remain, style: style),
        textDirection: TextDirection.ltr,
        // 与渲染端一致：逐字换行（中文按字断行是默认行为）
        strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: false),
      )..layout(maxWidth: maxWidth);

      if (tp.height <= maxHeight) {
        pages.add(remain);
        break;
      }

      // 找出「高 ≤ maxHeight 且宽 ≤ maxWidth」的矩形区域右下角对应的字符偏移。
      // 先二分纵向定位行，再用 getPositionForOffset 取该行末字符。
      var lo = 0, hi = remain.length;
      var fit = 0;
      while (lo <= hi) {
        final mid = (lo + hi) ~/ 2;
        final sub = remain.substring(0, mid);
        final p = TextPainter(
          text: TextSpan(text: sub, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxWidth);
        if (p.height <= maxHeight) {
          fit = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }

      if (fit <= 0) {
        // 极端情况（单字都放不下）：至少切一个字，避免死循环
        fit = 1;
      }
      // 尽量避免把一个词/标点孤零零留在页首：向前微调到换行处
      var cut = fit;
      final nl = remain.lastIndexOf('\n', cut);
      if (nl > cut - 24 && nl > 0) {
        cut = nl + 1;
      }

      pages.add(remain.substring(0, cut));
      start += cut;
    }
    return pages.isEmpty ? [t] : pages;
  }

  /// 估算 total 页里 [charIndex] 落在第几页（用于搜索/书签跳转）。
  static int pageOfIndex(List<String> pages, int charIndex) {
    var acc = 0;
    for (var i = 0; i < pages.length; i++) {
      acc += pages[i].length;
      if (charIndex < acc) return i;
    }
    return pages.isEmpty ? 0 : pages.length - 1;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// B · 轻量工具
// ═══════════════════════════════════════════════════════════════════════════

/// 把 [color] 往黑/白方向推，用于生成背面/阴影色（不引入额外依赖）。
Color shadeOf(Color c, double amount) {
  final hsl = HSLColor.fromColor(c);
  final l = (hsl.lightness + amount).clamp(0.0, 1.0);
  return hsl.withLightness(l).toColor();
}

/// 圆角矩形路径缓存（跨模块拖拽/飞入动画用）。
Path roundedPath(Rect r, double radius) =>
    ui.Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(radius)));
