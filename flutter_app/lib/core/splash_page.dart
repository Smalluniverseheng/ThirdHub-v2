// 开屏（2026-10-18 重做）—— 广告位 + 右下角跳过
//
// ★用户要求：
//   「开屏动画我很不喜欢，模仿别人那种，预留广告位：以后有广告就显示，
//     现在先用官方图标/宣传内容占位；右下角弄跳过 ——
//     正在加载时那个位置是转圈，加载好了显示 5 秒倒计时跳过；
//     会员账号无需跳过自动跳过、不显示任何广告。」
//
// 实现要点：
//   ① **广告位**是一块独立区域（`_AdSlot`）—— 现在渲染官方品牌宣传，
//      将来接了广告 SDK 只换这个 widget 的内容，外层流程不动。
//   ② **右下角的状态机**（关键）：
//        booting  → 转圈（此时点不了，因为还没加载完）
//        ready    → "跳过 5s" 倒计时（可点提前进）
//        member   → 不显示广告、不显示跳过，加载完直接进
//   ③ **谁通知"加载完成"**：main() 里的初始化是顶层 await，用 `bootDone`
//      （ValueNotifier）把状态推给本页；本页倒计时结束/被点跳过后回调
//      `onFinish`，main() 才 runApp 主界面。这样"转圈→倒计时→进入"的顺序
//      和真实加载进度是一致的，不是假动画。
//
// 为什么要拆出独立文件：main.dart 已经一万五千行，开屏的流程+状态机再塞进去
// 以后没人敢动。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'haptic.dart';

class SplashApp extends StatelessWidget {
  const SplashApp({
    super.key,
    required this.anim,
    required this.bootDone,
    required this.onFinish,
  });

  final bool anim;
  /// main() 的初始化是否已完成（true 之后才开始 5 秒倒计时）。
  final ValueNotifier<bool> bootDone;
  /// 开屏结束（倒计时完 / 点了跳过 / 会员直通）—— main() 收到才切主界面。
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: SplashPage(anim: anim, bootDone: bootDone, onFinish: onFinish),
      );
}

class SplashPage extends StatefulWidget {
  const SplashPage({
    super.key,
    required this.bootDone,
    required this.onFinish,
    this.anim = true,
  });

  final ValueNotifier<bool> bootDone;
  final VoidCallback onFinish;
  final bool anim;

  @override
  State<SplashPage> createState() => _Sp();
}

class _Sp extends State<SplashPage> with TickerProviderStateMixin {
  /// 入场：淡入 + 轻放大（克制，不做花哨动效 —— 用户明确说不喜欢原来的）
  late final AnimationController _in = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420))
    ..forward();

  /// 广告位内容的极缓呼吸（只在广告位里，不晃整屏）
  late final AnimationController _breathe = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2600))
    ..repeat(reverse: true);

  bool _ready = false; // 初始化完成？
  bool _member = false; // 会员：不显示广告
  int _left = 5; // 倒计时剩余秒
  Timer? _cd;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _loadMember();
    widget.bootDone.addListener(_onBoot);
    if (widget.bootDone.value) _onBoot();
  }

  @override
  void dispose() {
    widget.bootDone.removeListener(_onBoot);
    _cd?.cancel();
    _in.dispose();
    _breathe.dispose();
    super.dispose();
  }

  Future<void> _loadMember() async {
    try {
      final p = await SharedPreferences.getInstance();
      final lv = p.getString('member_level_cached') ?? 'guest';
      // 除 guest 外都算会员（satellite 及以上）
      if (mounted) setState(() => _member = lv != '' && lv != 'guest');
    } catch (_) {}
    // 会员：加载一完成就直通（不等倒计时）
    if (_member && _ready) _finish();
  }

  void _onBoot() {
    if (!mounted || _ready) return;
    setState(() => _ready = true);
    if (_member) {
      // 会员不显示广告也不走倒计时，短暂停留后直通（避免闪一下白屏）
      Future<void>.delayed(const Duration(milliseconds: 260), _finish);
      return;
    }
    _startCountdown();
  }

  void _startCountdown() {
    _cd?.cancel();
    setState(() => _left = 5);
    _cd = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _left--);
      if (_left <= 0) {
        t.cancel();
        _finish();
      }
    });
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _cd?.cancel();
    Haptic.light();
    widget.onFinish();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF0E1016) : const Color(0xFFF7F6FA);

    return Scaffold(
      backgroundColor: bg,
      body: Stack(children: [
        // ══ 广告位（占满；现在是品牌宣传占位）══
        Positioned.fill(
          child: FadeTransition(
            opacity: CurvedAnimation(parent: _in, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.985, end: 1).animate(
                  CurvedAnimation(parent: _in, curve: Curves.easeOutCubic)),
              child: _AdSlot(anim: widget.anim),
            ),
          ),
        ),

        // ══ 右下角：跳过 / 转圈 / 会员无 ══
        Positioned(
          right: 16,
          bottom: 28,
          child: _corner(context, dark),
        ),

        // ══ 底部版本号（小字，别抢广告位）══
        Positioned(
          left: 0,
          right: 0,
          bottom: 10,
          child: Center(
            child: Text('v$kAppVersion',
                style: TextStyle(
                    fontSize: 10,
                    color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.28))),
          ),
        ),
      ]),
    );
  }

  /// 右下角那一块：三种形态
  ///  · 未加载完 → 转圈（不可点）
  ///  · 加载完    → "跳过 5s"（可点）
  ///  · 会员      → 什么都不显示（不打扰）
  Widget _corner(BuildContext c, bool dark) {
    if (_member) return const SizedBox.shrink();

    final bg = dark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.06);
    final fg = dark ? Colors.white.withValues(alpha: 0.85) : Colors.black.withValues(alpha: 0.7);

    if (!_ready) {
      // 加载中：转圈（用户原话「那个跳过那个位置就有一个转圈」）
      return Container(
        width: 62,
        height: 30,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(15)),
        alignment: Alignment.center,
        child: SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 1.8, color: fg),
        ),
      );
    }

    // 加载完：5 秒倒计时跳过
    return GestureDetector(
      onTap: _finish,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(15)),
        alignment: Alignment.center,
        child: Text(
          _left > 0 ? '跳过 $_left' : '进入',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
        ),
      ),
    );
  }
}

/// 广告位。
///
/// **接入真实广告时只改这里**：把内部换成广告 SDK 的 view 即可，
/// 外层的「加载中→倒计时→跳过」流程一行都不用动。
///
/// ★2026-11-27 改版（用户：商标没安好 / 想要 3D 星球）：
///   旧版中间是个 `Icons.hub_rounded`（Material 通用图标）—— 那不是我们的商标，
///   所以开屏看起来像"别人家的 Demo"。现在换成**真实商标资产**
///   `assets/branding/logo-96.png`，外面套一层自绘 3D 星体：
///   球面明暗 + 高光 + 旋转经线 + 倾斜轨道环 + 卫星，全部 CustomPainter 手绘，
///   零第三方 3D 依赖（为一个小动效塞引擎不值当），60fps 只画几十条路径。
class _AdSlot extends StatelessWidget {
  const _AdSlot({required this.anim});
  final bool anim;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? Colors.white : const Color(0xE6000000);
    final sub = dark ? Colors.white.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.45);

    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _BrandPlanet(anim: anim),
        const SizedBox(height: 22),
        Text('第三方聚合',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: fg, letterSpacing: .5)),
        const SizedBox(height: 6),
        Text('一个入口 · One Hub', style: TextStyle(fontSize: 12.5, color: sub, letterSpacing: .3)),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            'AI 对话 · 小说 · 漫画 · 影视 · 音乐\n你的资料库，一个入口全都在',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.9, color: sub),
          ),
        ),
      ]),
    );
  }
}

/// 3D 观感的品牌星球：球体本身是自家商标，外面是旋转的经纬线与轨道。
///
/// 用 2D Canvas 模拟 3D，而不是引入 three_dart / model_viewer：
///   ① 开屏只有 1–5 秒，为它加载几十 MB 的渲染器不划算；
///   ② 球体是"圆 + 明暗 + 纬线椭圆"，用投影公式算出来就能骗过眼睛；
///   ③ 全程只依赖 Canvas.drawCircle / drawArc / drawPath，没有 shader 编译等待。
class _BrandPlanet extends StatefulWidget {
  const _BrandPlanet({required this.anim});
  final bool anim;
  @override
  State<_BrandPlanet> createState() => _BrandPlanetState();
}

class _BrandPlanetState extends State<_BrandPlanet> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
      vsync: this, duration: const Duration(seconds: 14));

  @override
  void initState() {
    super.initState();
    if (widget.anim) _spin.repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = Theme.of(context).colorScheme.primary;
    const size = 168.0;
    // 系统开了「减少动态效果」就只画静态帧：眩晕敏感用户不该被强制转圈。
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (_, __) => CustomPaint(
          painter: _PlanetPainter(
            t: (widget.anim && !reduce) ? _spin.value : 0.18,
            base: base,
            dark: dark,
          ),
          child: Center(
            // 商标本体：比球体略小，压在球面中间，看起来像"球心就是它"
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                boxShadow: [
                  BoxShadow(
                    color: base.withValues(alpha: dark ? 0.45 : 0.28),
                    blurRadius: 26,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Image.asset('assets/branding/logo-96.png',
                    width: 96, height: 96, fit: BoxFit.cover),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanetPainter extends CustomPainter {
  _PlanetPainter({required this.t, required this.base, required this.dark});
  final double t; // 0..1 自转相位
  final Color base;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width * 0.42;

    // 外层光晕：两圈不同透明度的圆，代替高斯模糊（开屏不该有 blur 的帧开销）
    canvas.drawCircle(c, r * 1.05, Paint()..color = base.withValues(alpha: dark ? 0.13 : 0.10));
    canvas.drawCircle(c, r * 0.92, Paint()..color = base.withValues(alpha: dark ? 0.08 : 0.06));

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

    // 球面边缘：一圈细描边把球"扣"出来
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = base.withValues(alpha: dark ? 0.5 : 0.28));

    // 纬线：横向椭圆，越靠上下越扁（球面投影）
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    for (var i = -2; i <= 2; i++) {
      if (i == 0) continue;
      final ry = r * (0.22 + 0.16 * i.abs());
      final rect = Rect.fromCenter(center: c.translate(0, i * r * 0.20), width: r * 2, height: ry * 2);
      canvas.drawArc(rect, 0, 3.14159 * 2, false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = base.withValues(alpha: dark ? 0.30 : 0.22));
    }

    // 经线：相位随 t 平移，形成"转起来"的错觉（用椭圆宽度做余弦压缩）
    for (var k = 0; k < 6; k++) {
      final phase = (t + k / 6) % 1.0;
      final w = (sin(phase * 3.14159 * 2)).abs() * r * 2;
      if (w < 2) continue;
      final rect = Rect.fromCenter(center: c, width: w.clamp(2.0, r * 2), height: r * 2);
      canvas.drawOval(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.9
            ..color = base.withValues(alpha: (dark ? 0.34 : 0.24) * (1 - w / (r * 2.2))));
    }
    canvas.restore();

    // 高光：左上一块柔光，球体立刻有"塑料球"质感
    canvas.drawCircle(
        c.translate(-r * 0.34, -r * 0.40),
        r * 0.22,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.white.withValues(alpha: dark ? 0.30 : 0.75), Colors.white.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c.translate(-r * 0.34, -r * 0.40), radius: r * 0.22)));

    // 倾斜轨道环 + 环上卫星：这是"3D"读感最强的一笔
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-0.42);
    final orbit = Rect.fromCenter(center: Offset.zero, width: r * 2.62, height: r * 0.86);
    canvas.drawOval(
        orbit,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = base.withValues(alpha: dark ? 0.55 : 0.35));
    // 卫星沿椭圆走一圈（参数方程），前半圈画亮、后半圈藏到球后
    final ang = t * 3.14159 * 2;
    final sx = cos(ang) * orbit.width / 2;
    final sy = sin(ang) * orbit.height / 2;
    if (sin(ang) >= -0.15) {
      canvas.drawCircle(Offset(sx, sy), 3.2, Paint()..color = Colors.white.withValues(alpha: dark ? 0.9 : 0.95));
      canvas.drawCircle(Offset(sx, sy), 6.0, Paint()..color = base.withValues(alpha: 0.35));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlanetPainter old) => old.t != t || old.base != base || old.dark != dark;
}
