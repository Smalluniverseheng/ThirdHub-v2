// 拟态（Neumorphism）设计系统。
//
// 核心规则：整个界面只有**一种底色**，所有元素靠「双向阴影」表现凹凸 ——
// 左上打高光、右下打暗影 = 凸起；两者对调 = 凹陷。没有描边、没有强对比色块。
//
// 为什么必须单独写一套：Material 的 `elevation` 只能投**单侧**阴影，
// 做不出拟态的双向光影。所以按钮、卡片、输入框这些都不能用
// `Card` / `ElevatedButton` 的默认外观，得自己画 `BoxDecoration`。

import 'package:flutter/material.dart';

/// 拟态的取色板（明 / 暗各一套）。
///
/// 明暗两套不是简单反色：暗色主题下"高光"仍然要比底色**亮**、
/// "暗影"要比底色**暗**，否则凹凸关系会反过来、视觉上变成一团糊。
class NeuPalette {
  const NeuPalette({
    required this.bg,
    required this.hilite,
    required this.shadow,
    required this.text,
    required this.sub,
    required this.accent,
  });

  /// 全局唯一底色
  final Color bg;

  /// 高光（光源来自左上）
  final Color hilite;

  /// 暗影（右下）
  final Color shadow;

  /// 主文字
  final Color text;

  /// 次要文字
  final Color sub;

  /// 强调色（CTA / 选中态）
  final Color accent;

  static const NeuPalette light = NeuPalette(
    bg: Color(0xFFE9EDF3),
    hilite: Color(0xFFFFFFFF),
    shadow: Color(0xFFC2CBD9),
    text: Color(0xFF2F3B4C),
    sub: Color(0xFF6B7A90),
    accent: Color(0xFF3B82F6),
  );

  static const NeuPalette dark = NeuPalette(
    bg: Color(0xFF2A2F38),
    hilite: Color(0xFF383E4A),
    shadow: Color(0xFF1C1F26),
    text: Color(0xFFE7EBF3),
    sub: Color(0xFF9AA6B8),
    accent: Color(0xFF5B9BFF),
  );

  /// 按当前主题亮度取用
  static NeuPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 拟态几何：凸起 / 凹陷的 `BoxDecoration` 工厂。
class Neu {
  Neu._();

  /// 凸起：左上高光 + 右下暗影
  static BoxDecoration raised(
    NeuPalette p, {
    double radius = 16,
    double depth = 5,
    double blur = 10,
  }) =>
      BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: <BoxShadow>[
          BoxShadow(color: p.hilite, offset: Offset(-depth, -depth), blurRadius: blur),
          BoxShadow(color: p.shadow, offset: Offset(depth, depth), blurRadius: blur),
        ],
      );

  /// 凹陷：光影对调（用于输入框、进度槽、按下态）
  static BoxDecoration inset(
    NeuPalette p, {
    double radius = 16,
    double depth = 4,
    double blur = 8,
  }) =>
      BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: <BoxShadow>[
          BoxShadow(color: p.shadow, offset: Offset(-depth, -depth), blurRadius: blur),
          BoxShadow(color: p.hilite, offset: Offset(depth, depth), blurRadius: blur),
        ],
      );
}

/// 拟态容器：凸起或凹陷的一块面。
///
/// [onTap] 非空时表现为可按，按下瞬间自动切成凹陷 —— 这是拟态最重要的交互反馈。
class NeuSurface extends StatefulWidget {
  const NeuSurface({
    super.key,
    required this.child,
    this.pressed = false,
    this.radius = 16,
    this.depth = 5,
    this.blur = 10,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
  });

  final Widget child;

  /// 强制凹陷（不受按压影响）
  final bool pressed;
  final double radius;
  final double depth;
  final double blur;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// 覆盖底色（默认用主题底色）
  final Color? color;

  @override
  State<NeuSurface> createState() => _NeuSurfaceState();
}

class _NeuSurfaceState extends State<NeuSurface> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final NeuPalette p = NeuPalette.of(context);
    final bool sink = widget.pressed || _down;
    final BoxDecoration d =
        sink ? Neu.inset(p, radius: widget.radius) : Neu.raised(p, radius: widget.radius, depth: widget.depth, blur: widget.blur);

    Widget body = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: widget.padding,
      decoration: widget.color == null
          ? d
          : d.copyWith(color: widget.color),
      child: widget.child,
    );

    if (widget.onTap == null) return body;
    body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: body,
    );
    return body;
  }
}

/// 拟态按钮。凸起态 + 按下凹陷，[primary] 为 true 时用强调色实心。
///
/// 取舍说明：纯拟态按钮（同底色 + 文字）在**长列表 / 深色背景**上辨识度不足，
/// 因此主操作仍保留实心强调色，只把「凸起 / 凹陷」的质感拿过来。
class NeuButton extends StatelessWidget {
  const NeuButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.expand = false,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool expand;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final NeuPalette p = NeuPalette.of(context);
    final bool disabled = onPressed == null;
    final Color fg = primary
        ? Colors.white
        : (disabled ? p.sub : p.text);

    final Widget inner = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: dense ? 16 : 18, color: fg),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: fg,
                fontSize: dense ? 12.5 : 14,
                fontWeight: primary ? FontWeight.w600 : FontWeight.w500),
          ),
        ),
      ],
    );

    if (primary) {
      // 实心主按钮：保留拟态圆角与按压下沉，但用强调色填充
      return NeuSurface(
        radius: dense ? 12 : 14,
        depth: dense ? 3 : 4,
        padding: EdgeInsets.symmetric(
            horizontal: dense ? 12 : 18, vertical: dense ? 7 : 11),
        color: disabled ? p.shadow : p.accent,
        onTap: onPressed,
        child: inner,
      );
    }

    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: NeuSurface(
        radius: dense ? 12 : 14,
        depth: dense ? 3 : 4,
        padding: EdgeInsets.symmetric(
            horizontal: dense ? 12 : 18, vertical: dense ? 7 : 11),
        onTap: onPressed,
        child: inner,
      ),
    );
  }
}

/// 拟态图标按钮（圆形）。
class NeuIconButton extends StatelessWidget {
  const NeuIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 20,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final NeuPalette p = NeuPalette.of(context);
    final bool disabled = onPressed == null;
    final Color fg = disabled
        ? p.sub.withValues(alpha: 0.5)
        : (selected ? p.accent : p.text);

    Widget btn = NeuSurface(
      radius: 999,
      depth: 3,
      blur: 7,
      padding: EdgeInsets.all(size * 0.55),
      onTap: onPressed,
      child: Icon(icon, size: size, color: fg),
    );
    if (tooltip != null) {
      btn = Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}

/// 拟态凹陷槽：给输入框 / 进度条 / 分段控件做"陷进去"的底。
class NeuInset extends StatelessWidget {
  const NeuInset({
    super.key,
    required this.child,
    this.radius = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => NeuSurface(
        radius: radius,
        pressed: true,
        padding: padding,
        child: child,
      );
}
