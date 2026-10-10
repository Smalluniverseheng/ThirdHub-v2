// ─────────────────────────────────────────────────────────────────────────────
// 构件库（Widgets）—— 只依赖 design_tokens.dart，页面统一用这里的东西。
//
// 为什么单独一个文件：
//   以前每个页面自己拼 Container + BoxDecoration，导致「十个页面十种圆角、
//   十种阴影、十种按压反馈」。这里把「大厂感」的三个来源固化成构件：
//     ① 一致性 —— 同一件事只有一种画法
//     ② 反馈感 —— 每个可点区域都有按压/抬起的两态
//     ③ 层次感 —— 用投影阶梯而不是描边区分层级
//
// ★ STYLE_GUIDE 第 1 条：**禁 emoji**。本项目件库所有图标位只接受
//   `IconData`，不接受字符串，从签名上就杜绝 `Text('📖')` 这种写法。
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design_tokens.dart';

/// 大卡片：圆角 + 柔和投影 + **按压缩放**反馈。
///
/// 按压反馈是"大厂感"最廉价也最有效的来源：手指按下去时整块**轻微缩小**
/// （0.98），抬起弹回 —— 用弹簧曲线，形成"抓到实体"的错觉。
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(Gap.md),
    this.radius = Radii.md,
    this.accent,
    this.margin = const EdgeInsets.symmetric(vertical: 6),
    this.gradientTop,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? accent;

  /// 顶部渐变强调（用于"重点卡"，如进行中的任务）
  final Color? gradientTop;
  final EdgeInsetsGeometry margin;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color base = dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.045),
            Theme.of(context).scaffoldBackgroundColor)
        : Colors.white;

    final Widget face = AnimatedContainer(
      duration: Motion.durFor(context, Motion.durEffect),
      curve: Motion.effect,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: _down ? const [] : Elev.card(Colors.black),
        gradient: widget.gradientTop == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                      widget.gradientTop!.withValues(alpha: dark ? 0.16 : 0.10),
                      base),
                  base,
                ],
                stops: const [0.0, 0.6],
              ),
        border: widget.accent == null
            ? null
            : Border.all(
                color: widget.accent!.withValues(alpha: 0.35), width: 1),
      ),
      child: widget.child,
    );

    if (widget.onTap == null && widget.onLongPress == null) {
      return Padding(padding: widget.margin, child: face);
    }

    return Padding(
      padding: widget.margin,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              },
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        child: AnimatedScale(
          duration: Motion.durFor(context, Motion.durFast),
          curve: Motion.curveFor(context, Motion.springFast),
          scale: _down ? 0.978 : 1.0,
          child: face,
        ),
      ),
    );
  }
}

/// 区块标题：主标 + 可选副标 + 可选右侧动作。
///
/// 用**字阶对比**建立层次（2025 趋势），而不是加分隔线或色块。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.padH = Gap.md,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final double padH;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(padH, Gap.lg, padH, Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Types.h2.copyWith(color: scheme.onSurface)),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(subtitle!,
                        style: Types.caption.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.55))),
                  ),
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// 空态：**带一个动作出口**，不是干巴巴一行字。
///
/// 这直接对应 STYLE_GUIDE 第 2 条（错误反馈要给"怎么办"）：
/// 空态也是失败的一种，同样要给出口。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.07),
              ),
              child: Icon(icon,
                  size: 40, color: scheme.primary.withValues(alpha: 0.75)),
            ),
            const SizedBox(height: Gap.md),
            Text(title,
                textAlign: TextAlign.center,
                style: Types.title.copyWith(color: scheme.onSurface)),
            if (hint != null) ...[
              const SizedBox(height: Gap.sm),
              Text(hint!,
                  textAlign: TextAlign.center,
                  style: Types.caption.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55))),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Gap.lg),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 主 CTA 按钮：实心 + **主色光晕**，在一屏里只有一个是这种规格。
///
/// 「震撼感」的来源之一是**稀缺性**：如果整屏都是抢眼按钮，就没有重点。
/// 因此这里只给主操作，次要操作一律走 `AppChip` 或文本按钮。
class PrimaryAction extends StatefulWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;

  @override
  State<PrimaryAction> createState() => _PrimaryActionState();
}

class _PrimaryActionState extends State<PrimaryAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool dis = widget.onPressed == null || widget.busy;

    final Widget inner = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.busy)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: scheme.onPrimary),
          )
        else if (widget.icon != null)
          Icon(widget.icon, size: 19, color: scheme.onPrimary),
        if (widget.busy || widget.icon != null) const SizedBox(width: 10),
        Text(widget.label,
            style: Types.title.copyWith(color: scheme.onPrimary)),
      ],
    );

    return GestureDetector(
      onTapDown: dis ? null : (_) => setState(() => _down = true),
      onTapCancel: dis ? null : () => setState(() => _down = false),
      onTapUp: dis ? null : (_) => setState(() => _down = false),
      onTap: dis
          ? null
          : () {
              HapticFeedback.mediumImpact();
              widget.onPressed!();
            },
      child: AnimatedContainer(
        duration: Motion.durFor(context, Motion.durFast),
        curve: Motion.curveFor(context, Motion.springFast),
        transform: Matrix4.identity()..scale(_down ? 0.97 : 1.0),
        transformAlignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        decoration: BoxDecoration(
          color: dis ? scheme.primary.withValues(alpha: 0.45) : scheme.primary,
          borderRadius: Radii.mdAll,
          boxShadow: _down || dis ? const [] : Elev.accent(scheme.primary),
        ),
        child: widget.expand ? SizedBox(width: double.infinity, child: inner) : inner,
      ),
    );
  }
}

/// 胶囊标签（分类、状态）。选中态用主色实心。
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurface.withValues(alpha: 0.72);
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      child: AnimatedContainer(
        duration: Motion.durFor(context, Motion.durEffect),
        curve: Motion.effect,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
            ],
            Text(label, style: Types.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// 统计数字块：大数字 + 小标签，用于"成就/概览"区。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.tint,
  });

  final String value;
  final String label;
  final IconData? icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = tint ?? scheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          Icon(icon, size: 18, color: c.withValues(alpha: 0.85)),
        if (icon != null) const SizedBox(height: 8),
        Text(value,
            style: Types.h1.copyWith(color: scheme.onSurface, fontSize: 24)),
        const SizedBox(height: 2),
        Text(label,
            style: Types.micro.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.5))),
      ],
    );
  }
}

/// 分段控件（2~4 段）：滑块带**弹簧位移**，取代 `SegmentedButton` 的硬切换。
class SpringSegments<T> extends StatelessWidget {
  const SpringSegments({
    super.key,
    required this.values,
    required this.labels,
    required this.value,
    required this.onChanged,
  });

  final List<T> values;
  final List<String> labels;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final int idx = values.indexOf(value).clamp(0, values.length - 1);
    return LayoutBuilder(builder: (ctx, cst) {
      final double w = cst.maxWidth / values.length;
      return Container(
        height: 40,
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: Motion.durFor(context, Motion.durFast),
              curve: Motion.curveFor(context, Motion.springFast),
              left: idx * w,
              top: 0,
              bottom: 0,
              width: w,
              child: Container(
                margin: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(Radii.pill),
                  boxShadow: Elev.card(Colors.black),
                ),
              ),
            ),
            Row(
              children: [
                for (int i = 0; i < values.length; i++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onChanged(values[i]);
                      },
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: Motion.durFor(context, Motion.durEffect),
                          style: Types.caption.copyWith(
                            fontWeight:
                                i == idx ? FontWeight.w700 : FontWeight.w500,
                            color: i == idx
                                ? scheme.onSurface
                                : scheme.onSurface.withValues(alpha: 0.5),
                          ),
                          child: Text(labels[i]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

/// 「环境就绪」状态点 —— 用**色点 + 文字**表达状态。
///
/// STYLE_GUIDE 第 1 条明确要求：状态用色点 + 文字，**不用 ●/☁/⚡ 这类符号字符**。
class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    required this.label,
    required this.ok,
    this.detail,
  });

  final String label;
  final bool ok;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color c = ok ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(label,
            style: Types.caption.copyWith(color: scheme.onSurface)),
        if (detail != null) ...[
          const SizedBox(width: 6),
          Text(detail!,
              style: Types.micro.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.45))),
        ],
      ],
    );
  }
}

/// 逐步显现的列表（staggered entrance）。
///
/// **震撼感**的合法来源：进入列表时每项依次淡入上浮。
/// ★ 必须尊重「减弱动态效果」；且**只用于首次进入**，滚动时不重放
///   （否则会伤 P0-2 的阅读流畅度）。
class StaggerIn extends StatefulWidget {
  const StaggerIn({
    super.key,
    required this.index,
    required this.child,
    this.stepMs = 38,
    this.maxDelayMs = 320,
  });

  final int index;
  final Widget child;
  final int stepMs;
  final int maxDelayMs;

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));
  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: Motion.springFast);

  @override
  void initState() {
    super.initState();
    final int delay = (widget.index * widget.stepMs).clamp(0, widget.maxDelayMs);
    Future<void>.delayed(Duration(milliseconds: delay), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return widget.child;
    return AnimatedBuilder(
      animation: _a,
      builder: (_, __) => Opacity(
        opacity: _a.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - _a.value) * 14),
          child: widget.child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// 骨架屏（加载占位）—— 比转圈"高级"：内容区域的形状先出来，再被填充。
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.height = 14,
    this.width,
    this.radius = 8,
    this.lines = 1,
  });

  final double height;
  final double? width;
  final double radius;

  /// 连续多行（行宽自动递减，模仿段落）
  final int lines;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool reduced = Motion.reduced(context);
    if (!reduced) _c.repeat(reverse: true);

    Widget bar(double? w, double h) => Container(
          width: w,
          height: h,
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );

    if (widget.lines <= 1) return bar(widget.width, widget.height);

    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < widget.lines; i++)
            Opacity(
              opacity: reduced ? 0.6 : 0.45 + 0.35 * _c.value,
              child: bar(
                i == widget.lines - 1
                    ? (widget.width ?? 220) * 0.6
                    : widget.width,
                widget.height,
              ),
            ),
        ],
      ),
    );
  }
}

/// 页面级滚动容器：统一内边距 + 下拉刷新 + 底部安全区。
class AppScroll extends StatelessWidget {
  const AppScroll({
    super.key,
    required this.children,
    this.onRefresh,
    this.padBottom = 96,
  });

  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final double padBottom;

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: EdgeInsets.only(top: Gap.sm, bottom: padBottom),
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      children: children,
    );
    if (onRefresh == null) return body;
    return RefreshIndicator(onRefresh: onRefresh!, child: body);
  }
}
