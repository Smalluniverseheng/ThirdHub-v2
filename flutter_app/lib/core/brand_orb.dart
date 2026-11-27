// 品牌星球（BrandOrb）—— 开屏 / 登录弹窗 / 未来的引导页共用同一个「3D 商标」。
//
// 为什么抽成独立组件（2026-11-27，4.81.116）：
//   开屏那版星球是写在 splash_page.dart 里的私有类，登录弹窗想用同一套观感只能复制，
//   而复制必然漂移（改一处漏一处）。这里把它做成可配置的公共件：
//     · size  —— 直径（开屏 168、弹窗 72）
//     · anim  —— 是否自转（跟随「开屏动画」设置 / 尊重系统减弱动态效果）
//     · label —— 是否显示球心的商标图（极小尺寸时关掉，避免糊成一团）
//
// 实现取向：**零 3D 引擎**。球体是「圆 + 径向明暗 + 纬线椭圆 + 相位平移的经线 + 高光
// + 倾斜轨道环」，全用 Canvas 画几十条路径。为一个小动效引入 three_dart 会带来
// 十几 MB 体积和 shader 编译等待，与「开屏 1–5 秒就要进主界面」的目标冲突。
library;

import 'dart:math';

import 'package:flutter/material.dart';

class BrandOrb extends StatefulWidget {
  const BrandOrb({
    super.key,
    this.size = 168,
    this.anim = true,
    this.showLogo = true,
    this.period = const Duration(seconds: 14),
  });

  /// 外框边长（球体直径约等于 size 的 84%）。
  final double size;

  /// 是否自转。
  final bool anim;

  /// 球心是否叠商标图。
  final bool showLogo;

  /// 自转一圈的时长。
  final Duration period;

  @override
  State<BrandOrb> createState() => _BrandOrbState();
}

class _BrandOrbState extends State<BrandOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: widget.period);

  @override
  void initState() {
    super.initState();
    if (widget.anim) _spin.repeat();
  }

  @override
  void didUpdateWidget(BrandOrb old) {
    super.didUpdateWidget(old);
    // 设置里关掉开屏动画时不该继续耗电：包一层判断而不是直接忽略。
    if (widget.anim && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.anim && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 系统开了「减少动态效果」就只画静态帧：眩晕敏感用户不该被强制转圈。
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final running = widget.anim && !reduce;
    final logo = widget.size * 0.57;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (_, __) => CustomPaint(
          painter: _OrbPainter(
            t: running ? _spin.value : 0.18,
            base: scheme.primary,
            dark: dark,
          ),
          child: widget.showLogo
              ? Center(
                  child: Container(
                    width: logo,
                    height: logo,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(logo * 0.27),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary
                              .withValues(alpha: dark ? 0.45 : 0.28),
                          blurRadius: logo * 0.27,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(logo * 0.27),
                      child: Image.asset('assets/branding/logo-96.png',
                          width: logo, height: logo, fit: BoxFit.cover),
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.base, required this.dark});
  final double t; // 0..1 自转相位
  final Color base;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width * 0.42;

    // 外层光晕：两圈半透明圆替代高斯模糊（开屏不该有 blur 的帧开销）
    canvas.drawCircle(
        c, r * 1.05, Paint()..color = base.withValues(alpha: dark ? 0.13 : 0.10));
    canvas.drawCircle(
        c, r * 0.92, Paint()..color = base.withValues(alpha: dark ? 0.08 : 0.06));

    // 球体：径向渐变（左上亮、右下暗）制造体积感
    final body = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.4),
        radius: 0.95,
        colors: dark
            ? [base.withValues(alpha: 0.55), const Color(0xFF11162A), const Color(0xFF0B0E18)]
            : [Colors.white, base.withValues(alpha: 0.16), base.withValues(alpha: 0.32)],
        stops: const [0, 0.55, 1],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, body);

    // 边缘细描边把球"扣"出来
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = base.withValues(alpha: dark ? 0.5 : 0.28));

    // 纬线：横向椭圆，越靠上下越扁（球面投影），裁在球内
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    for (var i = -2; i <= 2; i++) {
      if (i == 0) continue;
      final ry = r * (0.22 + 0.16 * i.abs());
      final rect = Rect.fromCenter(
          center: c.translate(0, i * r * 0.20), width: r * 2, height: ry * 2);
      canvas.drawArc(
          rect,
          0,
          pi * 2,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = base.withValues(alpha: dark ? 0.30 : 0.22));
    }

    // 经线：宽度随相位做余弦压缩，连起来就是"转起来"的错觉
    for (var k = 0; k < 6; k++) {
      final phase = (t + k / 6) % 1.0;
      final w = sin(phase * pi * 2).abs() * r * 2;
      if (w < 2) continue;
      final rect =
          Rect.fromCenter(center: c, width: w.clamp(2.0, r * 2), height: r * 2);
      canvas.drawOval(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.9
            ..color =
                base.withValues(alpha: (dark ? 0.34 : 0.24) * (1 - w / (r * 2.2))));
    }
    canvas.restore();

    // 高光：左上柔光，球立刻有"塑料球"质感
    final hi = c.translate(-r * 0.34, -r * 0.40);
    canvas.drawCircle(
        hi,
        r * 0.22,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: dark ? 0.30 : 0.75),
              Colors.white.withValues(alpha: 0)
            ],
          ).createShader(Rect.fromCircle(center: hi, radius: r * 0.22)));

    // 倾斜轨道环 + 环上卫星：3D 读感最强的一笔
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-0.42);
    final orbit = Rect.fromCenter(
        center: Offset.zero, width: r * 2.62, height: r * 0.86);
    canvas.drawOval(
        orbit,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = base.withValues(alpha: dark ? 0.55 : 0.35));
    final ang = t * pi * 2;
    final sx = cos(ang) * orbit.width / 2;
    final sy = sin(ang) * orbit.height / 2;
    if (sin(ang) >= -0.15) {
      canvas.drawCircle(Offset(sx, sy), 3.2,
          Paint()..color = Colors.white.withValues(alpha: dark ? 0.9 : 0.95));
      canvas.drawCircle(
          Offset(sx, sy), 6.0, Paint()..color = base.withValues(alpha: 0.35));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.t != t || old.base != base || old.dark != dark;
}
