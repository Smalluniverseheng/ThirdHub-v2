// ─────────────────────────────────────────────────────────────────────────────
// 自适应布局（阶段2）—— 折叠屏铰链感知 · 主从双栏 · 浮层大屏停靠
//
// 断点数值不在这儿 —— 在 `design_tokens.dart` 的 `Breakpoints`（与 tokens.json
// 逐项一致，adaptive_selfcheck 把关）。本文件只放**行为**：
//   1. 铰链检测（MediaQuery.displayFeatures）：双栏时让「栏间分界」落在铰链上；
//   2. MasterDetailFrame：展开态主从双栏（列表|详情）的通用骨架；
//   3. showAdaptiveSheet：浮层入口 —— 手机浮动底部弹层，大屏改停靠式面板。
//
// ★ 布局构件用成熟包 `dynamic_layouts`（0.7.0，钉死版本）：
//   其断点档 small/medium/large 与我们的 compact/medium/expanded 一一对应，
//   由 `kBreakpointConfig` 把 tokens.json 的 599/840 映射进包的阈值语义
//   （包：width < smallMax → small；width > largeMin → large；中间 medium）。
//   选型证据（2026-10 查证 pub.dev）：计划里点名的 adaptive_navigation、
//   adaptive_breakpoints、flutter_adaptive_scaffold **均已停维**
//   （isDiscontinued=true），dynamic_layouts 是唯一存活且零依赖的方案。
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
// DisplayFeatureType 只在 dart:ui 里（material 不转出），铰链判定要用它。
import 'dart:ui' show DisplayFeatureType;

import 'package:dynamic_layouts/dynamic_layouts.dart';
import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// tokens.json 断点 → dynamic_layouts 的阈值语义。
/// smallMax = compactMax+1 = 600（width<600 → small/compact）；
/// largeMin = expandedMin-1 = 839（width>839 → large/expanded）。
/// 于是 599→small、600→medium、839→medium、840→large，与 windowClassOf 完全一致。
const BreakpointConfig kBreakpointConfig = BreakpointConfig(
  smallMax: Breakpoints.compactMax + 1,
  largeMin: Breakpoints.expandedMin - 1,
);

/// 折叠屏铰链/折痕。
class Hinge {
  const Hinge(this.bounds, {required this.vertical});
  final Rect bounds;

  /// true = 铰链竖直走向（左右分栏场景：折叠屏横持/双屏展开）。
  final bool vertical;
  double get left => bounds.left;
  double get right => bounds.right;
  double get width => bounds.width;
}

/// 从 `MediaQuery.displayFeatures` 里认出铰链。
///
/// 判定：type == hinge（双屏合缝），或短边 ≥ [Breakpoints.foldHingeMin]
/// （三星 Fold 类折痕区有一定宽度）。挖孔/摄像头是 cutout 且薄，进不来。
Hinge? hingeOf(MediaQueryData mq) {
  for (final f in mq.displayFeatures) {
    final bool isHinge = f.type == DisplayFeatureType.hinge ||
        f.bounds.shortestSide >= Breakpoints.foldHingeMin;
    if (!isHinge) continue;
    return Hinge(f.bounds, vertical: f.bounds.height >= f.bounds.width);
  }
  return null;
}

/// 展开态主从双栏骨架：左主栏（列表）| 右详情栏。
///
/// 铰链感知：竖直铰链存在时，左栏宽度 = 铰链左缘（clamp 在 35%~65% 之间），
/// 分界（divider/缝隙）正好落在铰链上 —— 这就是「双栏避开铰链」的落点；
/// 无铰链时按 5:6 分栏。
class MasterDetailFrame extends StatelessWidget {
  const MasterDetailFrame({
    super.key,
    required this.master,
    required this.detail,
    this.masterFlex = 5,
    this.detailFlex = 6,
  });

  final Widget master;
  final Widget detail;
  final int masterFlex;
  final int detailFlex;

  @override
  Widget build(BuildContext context) {
    final Hinge? h = hingeOf(MediaQuery.of(context));
    return LayoutBuilder(builder: (context, box) {
      final List<Widget> children;
      if (h != null && h.vertical && h.left > 0) {
        // 左栏贴着铰链左缘收，右栏从铰链右缘起 —— 两栏都不压铰链。
        final double masterW = h.left.clamp(box.maxWidth * 0.35, box.maxWidth * 0.65);
        children = [
          SizedBox(width: masterW, child: master),
          SizedBox(width: math.max(h.width, 1), child: const SizedBox.expand()),
          Expanded(child: detail),
        ];
      } else {
        children = [
          Expanded(flex: masterFlex, child: master),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(flex: detailFlex, child: detail),
        ];
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    });
  }
}

/// 浮层入口：手机 = 浮动底部弹层（与旧观感一致）；
/// medium/expanded（平板/折叠屏展开/桌面）= **停靠式居中面板**（不再浮在底部）。
///
/// 直接复用 dynamic_layouts 的 [showAdaptiveModal] —— 不手写两套分支。
/// `desktopMaxWidth` 控制停靠面板宽度（默认 500，模块菜单这类宽内容可加大）。
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double desktopMaxWidth = 500,
  bool isDismissible = true,
}) =>
    showAdaptiveModal<T>(
      context: context,
      builder: builder,
      desktopMaxWidth: desktopMaxWidth,
      isDismissible: isDismissible,
    );

/// 侧栏让位：宽屏分支里「侧栏 | 铰链 | 内容」场景下，内容需要**再往右让**的宽度。
///
/// 铰链落在侧栏区（左缘 ≤ 320）时返回 `铰链右缘 − 侧栏最小宽`：
/// 实际侧栏宽 ≥ 80（NavigationRail 默认 minWidth），这个差值保证内容起点
/// 一定在铰链右缘之外（宁多让几像素，不压铰链）。铰链在内容区中间时返回 0
/// —— 那种情况由 [MasterDetailFrame] 的分栏贴铰链处理。
double railHingeGap(Hinge? h, {double railZone = 320, double railMin = 76}) {
  if (h == null || !h.vertical) return 0;
  if (h.left > railZone) return 0;
  return math.max(0, h.right - railMin);
}
