// ─────────────────────────────────────────────────────────────────────────────
// 设计令牌（Design Tokens）—— 对标 Material 3 Expressive（2025-05 起）
//
// 为什么要有这个文件：
//   此前主题是 main.dart 里内联的 `ThemeData(...)` —— 底色、圆角、字号、动效
//   全部散落在各处硬编码。"难看/不够炫"的根因不是某一处配色错了，而是
//   **没有一套统一的、可切换的量表**：页面之间圆角不一致、字重不成阶、
//   动效各写各的曲线，凑在一起就"糊"。
//
//   本文件把这些量抽成**令牌**（token），页面只引用令牌、不写字面量。
//   这样"换一套皮肤"才可能是一行配置，而不是改 100 个文件。
//
// 对标依据（2026-10 调研，真实来源）：
//   · Material 3 Expressive 的运动物理系统（弹簧：stiffness / damping / velocity）
//     https://m3.material.io/styles/motion/overview/how-it-works
//   · 2025 移动 UI 趋势：动态拟物、层次感回归、大字阶排版、克制微交互
//
// ★ 与 STYLE_GUIDE.md 的约束不冲突：仍然禁 emoji、仍用矢量图标。
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';

/// 间距量表（8 的倍数，沿用 STYLE_GUIDE 第 3 条）。
class Gap {
  Gap._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: 16);
  static const EdgeInsets card = EdgeInsets.all(16);
}

/// 圆角量表。**收敛**：以前卡片 12/14/18 混用，这里定成三档。
class Radii {
  Radii._();
  static const double sm = 10; // 小控件：chip、小按钮
  static const double md = 16; // 主力：卡片、输入框
  static const double lg = 24; // 大面：底部弹层、大卡片
  static const double pill = 999; // 胶囊

  static BorderRadius get smAll => BorderRadius.circular(sm);
  static BorderRadius get mdAll => BorderRadius.circular(md);
  static BorderRadius get lgAll => BorderRadius.circular(lg);
}

/// 字号阶（Type Scale）。
///
/// 2025 趋势是「大字阶排版」：标题更粗更大、正文更克制，
/// 靠**对比**建立层次，而不是靠堆装饰。
class Types {
  Types._();

  /// 展示级（引导页、空态主标、成就）
  static const TextStyle display = TextStyle(
    fontSize: 34,
    height: 1.15,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.0,
  );

  /// 页大标
  static const TextStyle h1 = TextStyle(
    fontSize: 26,
    height: 1.2,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.6,
  );

  /// 区块标
  static const TextStyle h2 = TextStyle(
    fontSize: 19,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );

  /// 卡片标
  static const TextStyle title = TextStyle(
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );

  /// 正文（行高 1.55 —— 长文可读性）
  static const TextStyle body = TextStyle(fontSize: 14.5, height: 1.55);

  /// 辅助说明
  static const TextStyle caption = TextStyle(fontSize: 12.5, height: 1.4);

  /// 极小标（角标、计数）
  static const TextStyle micro = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );
}

/// 动效曲线与时长 —— 对标 M3 Expressive 弹簧物理。
///
/// ★ 关键设计决定：M3 Expressive 在 Compose 上是**真弹簧**（见 `spring()`），
///   但 Flutter 官方**尚未提供**（调研原话：Flutter: unavailable）。
///   所以这里用官方给出的 **spring → cubic-bezier 换算表** 来逼近：
///     Expressive fast spatial : cubic-bezier(0.42, 1.67, 0.21, 0.90)  350ms
///     Expressive default spatial: cubic-bezier(0.38, 1.21, 0.22, 1.00) 500ms
///     Expressive fast effects : cubic-bezier(0.31, 0.94, 0.34, 1.00)  150ms
///   注意 y 分量 >1（如 1.67）= **过冲**，这正是"弹到位"的观感来源。
///   Flutter 的 `Cubic` 支持控制点 >1，因此可以如实表达。
class Motion {
  Motion._();

  // ── 位移类（spatial）：带过冲，"弹到位" ──
  /// 快：小元件（按钮、开关、chip）
  static const Cubic springFast = Cubic(0.42, 1.67, 0.21, 0.90);
  static const Duration durFast = Duration(milliseconds: 350);

  /// 默认：大部分转场（卡片展开、弹层）
  static const Cubic spring = Cubic(0.38, 1.21, 0.22, 1.00);
  static const Duration durDefault = Duration(milliseconds: 500);

  /// 慢：整屏（页面切换、全屏内容刷新）
  static const Cubic springSlow = Cubic(0.39, 1.29, 0.35, 0.98);
  static const Duration durSlow = Duration(milliseconds: 650);

  // ── 色彩/透明度类（effects）：**不过冲** ──
  static const Cubic effect = Cubic(0.31, 0.94, 0.34, 1.00);
  static const Duration durEffect = Duration(milliseconds: 150);

  /// 旧值兼容别名（既有代码在用 `Motion.easeOut` 之类的散装曲线）。
  static const Cubic easeOut = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 全局动效档位（由 `AppSettings.motionLevel` 注入，见 main.dart）。
  ///
  /// 为什么不用直接读 SharedPreferences：design_tokens 要能被纯 Dart 自检
  /// （`tool/design_system_selfcheck.dart`）加载，不能依赖 Flutter 插件。
  /// 所以这里留一个**可注入的静态值**，由 App 启动时写入。
  /// 'full' = 带过冲（默认）｜'calm' = 轻（收敛到不过冲）｜'off' = 几乎无。
  static String level = 'full';

  /// 按档位缩放时长：off → 1ms，calm → 60%，full → 100%。
  static Duration scale(Duration d) {
    if (level == 'off') return const Duration(milliseconds: 1);
    if (level == 'calm') {
      return Duration(milliseconds: (d.inMilliseconds * 0.6).round());
    }
    return d;
  }

  /// 按档位选曲线：calm/off 时**去掉过冲**（观感更"正经"，也更省电）。
  static Curve shape(Curve expressive) =>
      level == 'full' ? expressive : Curves.easeOutCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false ||
      level == 'off';

  /// 按需取曲线：系统要求减弱或用户关了动效时退回缓出。
  static Curve curveFor(BuildContext context, Curve c) =>
      reduced(context) ? Curves.easeOut : shape(c);

  /// 按需取时长：系统要求减弱时压到 1ms（≈瞬变，避免眩晕）。
  static Duration durFor(BuildContext context, Duration d) =>
      reduced(context) ? const Duration(milliseconds: 1) : scale(d);
}

/// 层次感用的投影阶梯。
///
/// 2025 趋势是「平面回归 + 轻投影建立层次」（Dimensional Minimalism）：
/// 不再用重描边或强色块区分层级，而是**同一套色系 + 递进的柔和投影**。
class Elev {
  Elev._();

  /// 贴合（列表项悬起）
  static List<BoxShadow> card(Color seed) => [
        BoxShadow(
          color: seed.withValues(alpha: 0.06),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: seed.withValues(alpha: 0.04),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];

  /// 悬浮（弹层、FAB）
  static List<BoxShadow> floating(Color seed) => [
        BoxShadow(
          color: seed.withValues(alpha: 0.14),
          blurRadius: 28,
          offset: const Offset(0, 10),
        ),
        BoxShadow(
          color: seed.withValues(alpha: 0.06),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ];

  /// 强调（主 CTA，带一点主色光晕）
  static List<BoxShadow> accent(Color c) => [
        BoxShadow(
          color: c.withValues(alpha: 0.32),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ];
}

/// 「皮肤」= 一套强调色 + 底色倾向 + 动效强度。
///
/// 这是"UI 切换"的落地物：用户可在设置里换皮肤，整站跟着变，
/// 而不是只有明/暗两档。
class Skin {
  const Skin({
    required this.id,
    required this.name,
    required this.seed,
    required this.lightBg,
    required this.darkBg,
    this.vivid = true,
  });

  final String id;

  /// 展示名（**不用 emoji**，符合 STYLE_GUIDE 第 1 条）
  final String name;

  /// 种子色（Material 3 动态取色源）
  final Color seed;

  /// 明色底
  final Color lightBg;

  /// 暗色底
  final Color darkBg;

  /// 是否启用过冲动效（"炫酷档"）。关掉 = "正经档"。
  final bool vivid;

  static const Skin ocean = Skin(
    id: 'ocean',
    name: '深海',
    seed: Color(0xFF2F6BFF),
    lightBg: Color(0xFFF5F7FC),
    darkBg: Color(0xFF0D1017),
  );

  static const Skin ink = Skin(
    id: 'ink',
    name: '墨玉',
    seed: Color(0xFF1F2937),
    lightBg: Color(0xFFF7F7F8),
    darkBg: Color(0xFF0A0A0B),
    vivid: false,
  );

  static const Skin jade = Skin(
    id: 'jade',
    name: '青瓷',
    seed: Color(0xFF0E9F6E),
    lightBg: Color(0xFFF4FAF7),
    darkBg: Color(0xFF0B1512),
  );

  static const Skin amber = Skin(
    id: 'amber',
    name: '暖阳',
    seed: Color(0xFFD97706),
    lightBg: Color(0xFFFCF8F2),
    darkBg: Color(0xFF16110A),
  );

  static const Skin violet = Skin(
    id: 'violet',
    name: '紫极',
    seed: Color(0xFF7C3AED),
    lightBg: Color(0xFFF8F6FD),
    darkBg: Color(0xFF120E1C),
  );

  static const Skin rose = Skin(
    id: 'rose',
    name: '绯樱',
    seed: Color(0xFFE11D6F),
    lightBg: Color(0xFFFDF5F8),
    darkBg: Color(0xFF180A11),
  );

  /// 全部可选皮肤（设置页遍历它渲染选项）
  static const List<Skin> all = [ocean, ink, jade, amber, violet, rose];

  static Skin byId(String? id) =>
      all.firstWhere((s) => s.id == id, orElse: () => ocean);
}

/// 由皮肤 + 亮度构造完整 `ThemeData`。
///
/// 这是把上面所有令牌**装进 Flutter 主题系统**的唯一入口 ——
/// main.dart 只调它一次，页面侧仍然走 `Theme.of(context)`。
ThemeData buildSkinTheme(Skin skin, Brightness b) {
  final bool dark = b == Brightness.dark;
  final Color bg = dark ? skin.darkBg : skin.lightBg;
  final ColorScheme scheme = ColorScheme.fromSeed(seedColor: skin.seed, brightness: b);

  // 表面色带一点底色倾向：纯粹的统一底色才"高级"，
  // 页面里出现两种不同的灰是最显廉价的错误。
  final Color surface = bg;
  final Color surfaceCard =
      dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.045), bg)
           : Color.alphaBlend(Colors.black.withValues(alpha: 0.018), bg);

  final TextTheme text = const TextTheme().copyWith(
    displayLarge: Types.display,
    headlineMedium: Types.h1,
    titleLarge: Types.h2,
    titleMedium: Types.title,
    bodyMedium: Types.body,
    bodySmall: Types.caption,
    labelSmall: Types.micro,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: surface,
    colorScheme: scheme.copyWith(primary: skin.seed, surface: surface),
    textTheme: text,
    // 大字阶：M3 Expressive 会把强调标题再加重一档
    typography: Typography.material2021(platform: TargetPlatform.android),
    canvasColor: surface,
    splashFactory: InkSparkle.splashFactory, // 安卓原生级涟漪
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: surfaceCard,
      shape: RoundedRectangleBorder(borderRadius: Radii.lgAll),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: Types.h2.copyWith(color: scheme.onSurface),
    ),
    listTileTheme: const ListTileThemeData(minVerticalPadding: 4),
    dividerTheme: DividerThemeData(
      color: scheme.onSurface.withValues(alpha: 0.07),
      thickness: 1,
      space: 1,
    ),
    // 表单：统一圆角
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: Radii.mdAll,
        borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: Radii.mdAll,
        borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: Radii.mdAll,
        borderSide: BorderSide(color: skin.seed, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: Types.title,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.14)),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: Radii.smAll),
      side: BorderSide.none,
      backgroundColor: surfaceCard,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll),
      insetPadding: const EdgeInsets.all(16),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceCard,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: Radii.lgAll),
    ),
    // 页面转场统一走弹簧曲线
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: _SpringPageTransition(),
      TargetPlatform.iOS: _SpringPageTransition(),
    }),
  );
}

/// 弹簧式页面转场：新页**带轻微过冲**滑入 + 旧页淡出。
///
/// 与默认 `ZoomPageTransitionsBuilder` 的区别：默认转场是"缩放淡入"，
/// 观感偏"糊"；这里改成**位移 + 过冲**，方向感更强、更"到位"。
class _SpringPageTransition extends PageTransitionsBuilder {
  const _SpringPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    final Animation<double> slide = CurvedAnimation(
      parent: animation,
      curve: Motion.springFast,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).animate(slide),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Motion.effect),
        child: child,
      ),
    );
  }
}
