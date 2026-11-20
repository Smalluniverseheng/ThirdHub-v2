// 转场与交互质感（2026-11-20 / 4.81.78）
//
// ══ 补的是什么 ══
// 全库 `Hero` 0 处、`AnimatedSwitcher` 0 处。表现是：
//   · 列表点进详情是"整页换掉"，没有封面飞过去的连续感；
//   · 卡片按下只有 Material 的涟漪，没有 0.98 的"压下去"；
//   · 列表一次性刷出来，没有错峰入场。
// 这三样是头部 App 手感的基础，缺了就显得"能跑但廉价"。
//
// 这里给的三个东西都不改页面结构，包一层就能用：
//   HeroImage    —— 列表封面 → 详情大图 的共享元素
//   Pressable    —— 按下缩放 + 触感（替代裸 GestureDetector）
//   StaggerList  —— 列表项错峰入场
//
// 注意：页面级转场（翻页曲线）**不用**在这里重造 —— 主题里已经有
// design_tokens.dart 的 6 套 PageTransitionsBuilder，MaterialPageRoute
// 会自动沿用。重造只会跟皮肤打架。
library;

import 'package:flutter/material.dart';

import 'app_image.dart';
import '../haptic.dart';

/// 生成 Hero tag。
///
/// 用 URL 派生而不是手写常量：同一个封面在不同列表里出现时，
/// 手写 tag 必然重复 → Flutter 会抛 "multiple heroes share the same tag"。
String heroTagOf(String url, {String prefix = 'img'}) {
  if (url.isEmpty) return '';
  var h = 0x811c9dc5;
  for (final c in url.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return '$prefix-${h.toRadixString(16)}';
}

/// 可做共享元素的图片。
///
/// 用法：列表里 `HeroImage(url, width: 96, height: 128)`，
/// 详情页里 `HeroImage(url, width: 140, height: 196)` —— tag 由 URL 自动对齐，
/// 不用两边手动传一个字符串（那是最容易写错、且错了只在运行时炸的地方）。
class HeroImage extends StatelessWidget {
  const HeroImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.radius = 10,
    this.fit = BoxFit.cover,
    this.headers,
    this.enabled = true,
  });

  final String url;
  final double? width;
  final double? height;
  final double radius;
  final BoxFit fit;
  final Map<String, String>? headers;

  /// 关掉共享元素（例如同一页里同一个封面出现两次）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final img = AppImage(
      url,
      width: width,
      height: height,
      radius: radius,
      fit: fit,
      headers: headers,
      showRetryOnFail: false,
    );
    final tag = heroTagOf(url);
    if (!enabled || tag.isEmpty) return img;
    return Hero(
      tag: tag,
      // 飞行途中的占位用同形状的圆角块，避免"白框"从按钮里冒出来
      flightShuttleBuilder: (_, animation, direction, fromCtx, toCtx) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: AppImage(url,
              fit: fit, headers: headers, showRetryOnFail: false),
        );
      },
      child: img,
    );
  }
}

/// 按下缩放的包装层。
///
/// 为什么不用 InkWell：InkWell 的涟漪画在 Material 上，遇到自定义背景/图片时
/// 会被盖住或溢出圆角。这里用纯 scale + 可选触感，任何背景上都成立，
/// 而且**手感更接近 iOS/头部安卓 App**（按下 0.98，抬起回弹）。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.975,
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  /// 按下是否给一次轻触感（走 Haptic 层，用户关掉即全静音）。
  final bool haptic;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  bool get _interactive => widget.onTap != null || widget.onLongPress != null;

  void _set(bool v) {
    if (!_interactive || _down == v) return;
    setState(() => _down = v);
    if (v && widget.haptic) Haptic.tap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: Duration(milliseconds: _down ? 90 : 160),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

/// 列表项错峰入场。
///
/// 只对**首屏可见的若干项**做动画（[maxIndex] 之后直接显示）：
/// 长列表每项都动会让滚动时的插入动画互相打架，反而更卡。
class StaggerItem extends StatefulWidget {
  const StaggerItem({
    super.key,
    required this.index,
    required this.child,
    this.maxIndex = 8,
    this.step = const Duration(milliseconds: 45),
  });

  final int index;
  final Widget child;
  final int maxIndex;
  final Duration step;

  @override
  State<StaggerItem> createState() => _StaggerItemState();
}

class _StaggerItemState extends State<StaggerItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.index >= widget.maxIndex) {
      _c.value = 1; // 超出错峰范围：直接就位，不做动画
    } else {
      _scheduled = true;
      Future<void>.delayed(widget.step * widget.index, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_scheduled) return widget.child;
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
                begin: const Offset(0, 0.06), end: Offset.zero)
            .animate(curved),
        child: widget.child,
      ),
    );
  }
}

/// 给 ListView/GridView 的 itemBuilder 包一层错峰。
Widget staggered(int index, Widget child, {int maxIndex = 8}) =>
    StaggerItem(index: index, maxIndex: maxIndex, child: child);
