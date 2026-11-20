// 加载态与骨架屏（2026-11-20 / 4.81.78）
//
// ══ 为什么要专门一个文件 ══
// 全库有 **138 处** `CircularProgressIndicator`。统一转圈是最"便宜"的加载态，
// 也是最菜的：用户不知道要等出什么、等多久，页面会"跳"一下。
// 头部 App 的做法是**骨架屏** —— 提前把内容的形状画出来，数据到了原地替换，
// 视觉上没有跳变，主观上还更快。
//
// 项目里其实早写过 `SkeletonBox`（core/app_widgets.dart），但全库只有 2 处在用，
// 别的地方全在各写各的。这里补成一套完整的、能直接铺开的组件：
//   ShimmerBox       —— 扫光色块（最小单元）
//   SkeletonLine     —— 文本行
//   SkeletonListTile —— 列表行（封面 + 两行字）
//   SkeletonGrid     —— 封面网格
//   SkeletonArticle  —— 详情/正文页
//   AppLoading       —— 实在没法画骨架时的统一加载指示
//
// 设计约束：颜色全部走 Theme（不写死灰值），深色/浅色/换肤都自动跟。
library;

import 'package:flutter/material.dart';

/// 扫光色块 — 骨架屏的最小单元。
///
/// 用 `AnimatedBuilder` 平移一个三段渐变，而不是 `ShaderMask`：
/// ShaderMask 会开离屏图层，一个列表里几十个骨架同时开层，中低端机会掉帧。
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 6,
    this.circle = false,
  });

  final double? width;

  /// null = 撑满父约束（配合 `Expanded` 用在网格里）。
  final double? height;
  final double radius;
  final bool circle;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1250));

  @override
  void initState() {
    super.initState();
    // 骨架只在"等待"期间存在，重复播放是合理的；但必须随 dispose 停掉，
    // 否则页面关了动画还在跑 —— 这是耗电的经典来源。
    _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 底色用主题的"高层"，高光再亮一档 —— 深浅色都不用改代码
    final base = dark
        ? Colors.white.withValues(alpha: 0.055)
        : Colors.black.withValues(alpha: 0.055);
    final hi = dark
        ? Colors.white.withValues(alpha: 0.115)
        : Colors.black.withValues(alpha: 0.028);

    return AnimatedBuilder(
      animation: _c,
      builder: (c, _) {
        // -1 → 2 的位移，保证光带完整扫过一次
        final t = _c.value * 3 - 1;
        return Container(
          width: widget.circle ? widget.height : widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: base,
            shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
            borderRadius:
                widget.circle ? null : BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(t - 1, 0),
              end: Alignment(t + 1, 0),
              colors: [base, hi, base],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// 文本行骨架。[widthFactor] 控制行宽比例（模拟长短不一的文字）。
class SkeletonLine extends StatelessWidget {
  const SkeletonLine({
    super.key,
    this.width,
    this.widthFactor,
    this.height = 12,
    this.radius = 6,
  });

  final double? width;
  final double? widthFactor;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final w = width ??
        (widthFactor == null
            ? null
            : MediaQuery.sizeOf(context).width * widthFactor!);
    return ShimmerBox(width: w, height: height, radius: radius);
  }
}

/// 列表行骨架：左侧封面/头像 + 右侧两行字。
class SkeletonListTile extends StatelessWidget {
  const SkeletonListTile({
    super.key,
    this.thumbSize = 56,
    this.thumbRadius = 8,
    this.lines = 2,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  final double thumbSize;
  final double thumbRadius;
  final int lines;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShimmerBox(
              width: thumbSize, height: thumbSize, radius: thumbRadius),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 4 : 9),
                    child: SkeletonLine(
                      widthFactor: i == 0 ? 0.62 : (i.isEven ? 0.86 : 0.44),
                      height: i == 0 ? 14 : 11,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表骨架：[count] 行。
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.count = 8,
    this.thumbSize = 56,
    this.padding = EdgeInsets.zero,
  });

  final int count;
  final double thumbSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    // 骨架本身不可交互，用 IgnorePointer 避免用户点到"假条目"
    return IgnorePointer(
      child: ListView.builder(
        padding: padding,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        itemBuilder: (_, __) => SkeletonListTile(thumbSize: thumbSize),
      ),
    );
  }
}

/// 封面网格骨架。影视/漫画/音乐首页都长这样。
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({
    super.key,
    this.count = 9,
    this.crossAxisCount = 3,
    this.aspectRatio = 0.68,
    this.padding = const EdgeInsets.all(12),
  });

  final int count;
  final int crossAxisCount;
  final double aspectRatio;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: GridView.builder(
        padding: padding,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: aspectRatio,
          crossAxisSpacing: 10,
          mainAxisSpacing: 14,
        ),
        itemCount: count,
        itemBuilder: (_, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(child: ShimmerBox(height: null, radius: 10)),
            const SizedBox(height: 7),
            SkeletonLine(widthFactor: 0.62, height: 11),
            const SizedBox(height: 5),
            SkeletonLine(widthFactor: 0.38, height: 9),
          ],
        ),
      ),
    );
  }
}

/// 详情 / 正文页骨架：大封面 + 标题 + 若干段落。
class SkeletonArticle extends StatelessWidget {
  const SkeletonArticle({super.key, this.paragraphs = 6});

  final int paragraphs;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ShimmerBox(width: 92, height: 128, radius: 12),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonLine(widthFactor: 0.55, height: 18),
                    const SizedBox(height: 10),
                    SkeletonLine(widthFactor: 0.4, height: 12),
                    const SizedBox(height: 8),
                    SkeletonLine(widthFactor: 0.3, height: 12),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          for (var p = 0; p < paragraphs; p++) ...[
            SkeletonLine(height: 11),
            const SizedBox(height: 8),
            SkeletonLine(height: 11),
            const SizedBox(height: 8),
            SkeletonLine(widthFactor: 0.72, height: 11),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}

/// 统一加载指示器。
///
/// 只用在**确实没法画骨架**的地方（按钮内、弹窗里、未知形状的等待）。
/// 页面级加载请优先用上面那几个 Skeleton —— 转圈是最后的选择，不是默认。
class AppLoading extends StatelessWidget {
  const AppLoading({super.key, this.label, this.size = 20});

  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
                strokeWidth: 2.0, color: cs.primary),
          ),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(label!,
                style: TextStyle(
                    fontSize: 12, color: cs.onSurface.withValues(alpha: 0.55))),
          ],
        ],
      ),
    );
  }
}
