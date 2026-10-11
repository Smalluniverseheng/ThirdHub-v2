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

/// 断点/窗口档令牌在 `breakpoints.dart`（纯 Dart，供 tool/adaptive_selfcheck
/// 做行为断言）—— 这里转出，既有 `import design_tokens.dart` 的用法不变。
export 'breakpoints.dart';

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
  /// 胶囊圆角（玻璃特效档的按钮用）
  static BorderRadius get pillAll => BorderRadius.circular(pill);
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

/// 「皮肤」= 一套强调色 + 底色倾向 + 动效强度 + **特效档**。
///
/// 这是"UI 切换"的落地物：用户可在设置里换皮肤，整站跟着变，
/// 而不是只有明/暗两档。
///
/// ★★ 2026-10-11：皮肤定义**不再只属于 App** —— 唯一来源是仓库根的
///   `design/tokens.json`，网页端 `css/theme.css` 读的是同一份定义。
///   两端 id / 名称 / 种子色 / 底色 / 特效必须逐项一致，
///   由 `tool/skin_parity_selfcheck.dart` 同时解析本文件与网页端 CSS 来把关。
///   改这里 = 同时改 tokens.json 与 theme.css，否则闸门红。
class Skin {
  const Skin({
    required this.id,
    required this.name,
    required this.seed,
    required this.lightBg,
    required this.darkBg,
    this.fx = SkinFx.none,
    this.vivid = true,
  });

  final String id;

  /// 展示名（**不用 emoji**，符合 STYLE_GUIDE 第 1 条）
  final String name;

  /// 种子色（Material 3 动态取色源）。对应 tokens.json 的 `seed`。
  final Color seed;

  /// 明色底。对应 tokens.json 的 `lightBg`。
  final Color lightBg;

  /// 暗色底。对应 tokens.json 的 `darkBg`。
  final Color darkBg;

  /// 特效档（圆角/边框/阴影/标题字形随它变）。对应 tokens.json 的 `fx`。
  final SkinFx fx;

  /// 是否启用过冲动效（"炫酷档"）。关掉 = "正经档"。
  final bool vivid;

  static const Skin ocean = Skin(
    id: 'ocean',
    name: '深海',
    seed: Color(0xFF2F6BFF),
    lightBg: Color(0xFFF5F7FC),
    darkBg: Color(0xFF0D1017),
  );

  /// ★2026-10-11 新增：简约黑白（tokens.json 里的 mono）
  static const Skin mono = Skin(
    id: 'mono',
    name: '素白',
    seed: Color(0xFF111111),
    lightBg: Color(0xFFFFFFFF),
    darkBg: Color(0xFF0B0B0C),
    vivid: false,
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

  /// ★2026-10-11 新增：水墨（fx=ink）
  static const Skin shuimo = Skin(
    id: 'shuimo',
    name: '水墨',
    seed: Color(0xFF3A3A3A),
    lightBg: Color(0xFFF6F3EC),
    darkBg: Color(0xFF101010),
    fx: SkinFx.ink,
    vivid: false,
  );

  /// ★2026-10-11 新增：机甲（fx=neon）
  static const Skin mecha = Skin(
    id: 'mecha',
    name: '机甲',
    seed: Color(0xFF00E5FF),
    lightBg: Color(0xFFEDF3F8),
    darkBg: Color(0xFF060A12),
    fx: SkinFx.neon,
  );

  /// ★2026-10-11 新增：玻璃（fx=glass）
  static const Skin glass = Skin(
    id: 'glass',
    name: '玻璃',
    seed: Color(0xFF5B8DEF),
    lightBg: Color(0xFFF2F5FB),
    darkBg: Color(0xFF0A0E17),
    fx: SkinFx.glass,
  );

  /// ★2026-10-11 新增：漫画（fx=comic）——粗描边、硬阴影、弹跳转场
  static const Skin comic = Skin(
    id: 'comic',
    name: '漫画',
    seed: Color(0xFFE8342A),
    lightBg: Color(0xFFFFFDF7),
    darkBg: Color(0xFF171213),
    fx: SkinFx.comic,
  );

  /// 全部可选皮肤（设置页遍历它渲染选项）。
  /// ★ 顺序即 UI 里的排列顺序，与 tokens.json 的 `skins` 数组顺序一致。
  static const List<Skin> all = [
    ocean, mono, ink, jade, amber, violet, rose, shuimo, mecha, glass, comic,
  ];

  static Skin byId(String? id) =>
      all.firstWhere((s) => s.id == id, orElse: () => ocean);
}

/// 特效档 —— 决定圆角/边框/阴影/标题字形这一组"风格量"。
/// 与 tokens.json 的 `fx` 取值一一对应。
enum SkinFx {
  /// 无额外特效（绝大多数皮肤）
  none,

  /// 水墨：圆角收小、边框细、标题走衬线、去阴影只留线条
  ink,

  /// 机甲：卡片发光描边 + 强调色辉光 + 按钮直角化 + **机械滑动转场**（快进精准刹停）
  neon,

  /// 玻璃：卡片半透明 + 模糊、按钮胶囊化、渐变底
  glass,

  /// 漫画：粗描边 + 硬阴影、**弹跳弹出转场**（夸张过冲，像分镜弹出）
  comic,
}

/// 由皮肤 + 亮度构造完整 `ThemeData`。
///
/// 这是把上面所有令牌**装进 Flutter 主题系统**的唯一入口 ——
/// main.dart 只调它一次，页面侧仍然走 `Theme.of(context)`。
ThemeData buildSkinTheme(Skin skin, Brightness b) {
  final bool dark = b == Brightness.dark;
  final Color bg = dark ? skin.darkBg : skin.lightBg;
  final ColorScheme scheme = ColorScheme.fromSeed(seedColor: skin.seed, brightness: b);

  // ── 特效档决定的"风格量"（圆角 / 卡片色 / 边框 / 阴影）──────────────
  //   ★ 这里就是"换皮肤不只是换颜色"的落点：同一个底色配不同 fx，
  //     圆角、描边、透明度、是否有阴影都不一样，观感是两套东西。
  final SkinFx fx = skin.fx;
  final BorderRadius cardRadius = switch (fx) {
    SkinFx.ink => Radii.smAll,      // 水墨：小圆角，接近直角
    SkinFx.neon => Radii.smAll,     // 机甲：直角化
    SkinFx.glass => Radii.lgAll,    // 玻璃：大圆角
    SkinFx.comic => Radii.mdAll,    // 漫画：中圆角 + 粗描边（分镜框感）
    SkinFx.none => Radii.lgAll,
  };
  final BorderRadius btnRadius = switch (fx) {
    SkinFx.ink => const BorderRadius.all(Radius.circular(4)),
    SkinFx.neon => const BorderRadius.all(Radius.circular(6)),
    SkinFx.glass => Radii.pillAll,  // 玻璃：胶囊
    SkinFx.comic => const BorderRadius.all(Radius.circular(8)),
    SkinFx.none => Radii.mdAll,
  };
  // 表面色带一点底色倾向：纯粹的统一底色才"高级"，
  // 页面里出现两种不同的灰是最显廉价的错误。
  final Color surface = bg;
  Color surfaceCard = dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.045), bg)
                           : Color.alphaBlend(Colors.black.withValues(alpha: 0.018), bg);
  if (fx == SkinFx.glass) {
    // 玻璃：卡片更"浮"一点，靠模糊与描边拉开层次
    surfaceCard = dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.075), bg)
                       : Color.alphaBlend(Colors.white.withValues(alpha: 0.55), bg);
  }
  // 机甲：卡片带一层极淡的强调色，配合霓虹描边
  if (fx == SkinFx.neon) {
    surfaceCard = Color.alphaBlend(skin.seed.withValues(alpha: dark ? 0.05 : 0.035), surfaceCard);
  }
  final BorderSide cardSide = switch (fx) {
    SkinFx.neon => BorderSide(color: skin.seed.withValues(alpha: dark ? 0.45 : 0.30), width: 1),
    SkinFx.ink => BorderSide(color: scheme.onSurface.withValues(alpha: 0.16), width: 1),
    SkinFx.glass => BorderSide(color: Colors.white.withValues(alpha: dark ? 0.10 : 0.65), width: 1),
    // 漫画：2px 粗描边（分镜框）——亮色用墨黑、暗色用纸白，黑白对比是漫画印刷的灵魂
    SkinFx.comic => BorderSide(
        color: dark
            ? Colors.white.withValues(alpha: 0.85)
            : scheme.onSurface.withValues(alpha: 0.88),
        width: 2),
    SkinFx.none => BorderSide.none,
  };
  // 标题字形：水墨走衬线（有"书卷气"），其余沿用默认无衬线
  final TextStyle h1 = fx == SkinFx.ink
      ? Types.h1.copyWith(fontFamily: 'serif', letterSpacing: 0.5)
      : Types.h1;
  final TextStyle h2 = fx == SkinFx.ink
      ? Types.h2.copyWith(fontFamily: 'serif', letterSpacing: 0.4)
      : Types.h2;

  final TextTheme text = const TextTheme().copyWith(
    displayLarge: Types.display,
    headlineMedium: h1,
    titleLarge: h2,
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
      // 阴影靠 elevation 触发；水墨明确要"无阴影"，所以给 0；机甲/玻璃各一档。
      elevation: switch (fx) {
        SkinFx.ink => 0,
        SkinFx.neon => 6,
        SkinFx.glass => 2,
        SkinFx.comic => 0, // 漫画靠粗描边立住，不用投影
        SkinFx.none => 0,
      },
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: surfaceCard,
      shadowColor: skin.seed.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(
        borderRadius: cardRadius,
        side: cardSide,
      ),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: h2.copyWith(color: scheme.onSurface),
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
        borderRadius: btnRadius,
        borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: btnRadius,
        borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: btnRadius,
        borderSide: BorderSide(color: skin.seed, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: btnRadius),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: Types.title,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: btnRadius),
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
    // 页面转场按特效档分派 —— 这就是"效果皮肤"与"颜色皮肤"的分水岭：
    //   机甲（neon） = 机械滑动（快启动 → 匀速推进 → 精准刹停，伺服感）
    //   漫画（comic）= 弹跳弹出（夸张过冲，像分镜砸进画面）
    //   其余         = 弹簧滑动（M3 Expressive 默认，不改变既有观感）
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      TargetPlatform.android: _pageTransitionFor(fx),
      TargetPlatform.iOS: _pageTransitionFor(fx),
    }),
  );
}

/// 按特效档选择页面转场（"效果皮肤"的唯一分派点）。
///
/// ★ 新增效果皮肤 = 在这里加一条分支 + 写一个 PageTransitionsBuilder 子类，
///   不要在页面里写 if (皮肤=='x') —— 分派只此一处，保证不漏页。
PageTransitionsBuilder _pageTransitionFor(SkinFx fx) => switch (fx) {
      SkinFx.neon => const _MechaPageTransition(),
      SkinFx.comic => const _ComicPageTransition(),
      _ => const _SpringPageTransition(),
    };

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

/// 机械制动曲线：快启动 → 匀速推进 → 精准刹停。
///
/// 与弹簧曲线的区别：弹簧是"过冲回弹"（果冻感），机械是"快进 + 刹车"
/// （伺服电机的到位感）——这正是机甲皮肤"机械滑动"的来源。
class _MechanicalCurve extends Curve {
  const _MechanicalCurve();

  @override
  double transformInternal(double t) {
    // 前 72% 时间走完 92% 行程（急速推进）；后 28% 时间做"刹车"段（缓出收尾）。
    if (t < 0.72) return (t / 0.72) * 0.92;
    final double u = (t - 0.72) / 0.28;
    return 0.92 + 0.08 * Curves.easeOutCubic.transform(u);
  }
}

/// 机甲转场：整页快速滑入 + 精准刹停（无回弹、无缩放，位移更大 → "闸门"感）。
class _MechaPageTransition extends PageTransitionsBuilder {
  const _MechaPageTransition();

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
      curve: const _MechanicalCurve(),
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.22, 0),
        end: Offset.zero,
      ).animate(slide),
      child: child,
    );
  }
}

/// 漫画转场：弹跳弹出 —— 分镜"砸"进画面（夸张过冲 + 轻微放大）。
class _ComicPageTransition extends PageTransitionsBuilder {
  const _ComicPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    // backOut 经典参数：过冲后回落，像漫画分镜弹进画格
    final Animation<double> pop = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0.34, 1.56, 0.64, 1.0),
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Motion.effect),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.90, end: 1.0).animate(pop),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.0, 0.045),
            end: Offset.zero,
          ).animate(pop),
          child: child,
        ),
      ),
    );
  }
}
