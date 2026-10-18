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
              child: const _AdSlot(),
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
class _AdSlot extends StatelessWidget {
  const _AdSlot();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? Colors.white : const Color(0xE6000000);
    final sub = dark ? Colors.white.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.45);

    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // 品牌标记（占位 = 自家图标；将来换成广告主的图）
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.22),
                width: 0.8),
          ),
          child: Icon(Icons.hub_rounded,
              size: 40, color: Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(height: 18),
        Text('第三方聚合',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: fg)),
        const SizedBox(height: 6),
        Text('一个入口 · One Hub', style: TextStyle(fontSize: 12.5, color: sub)),
        const SizedBox(height: 22),
        // 宣传语（占位内容，以后可以换成广告文案）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            'AI 对话 · 小说 · 漫画 · 影视 · 音乐\n你的资料库，一个入口全都在',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.8, color: sub),
          ),
        ),
      ]),
    );
  }
}
