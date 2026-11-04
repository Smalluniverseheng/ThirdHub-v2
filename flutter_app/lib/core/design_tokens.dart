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

  /// ★2026-11-05：按**皮肤套餐的阴影档**取投影 —— 卡片/构件统一走这里。
  ///
  ///   none  = 纯平面（素白、墨玉、水墨：靠描边分层，不要投影）
  ///   flat  = 极薄一层
  ///   soft  = 默认柔和（两层）
  ///   float = 浮起（大模糊，玻璃）
  ///   hard  = 硬投影（0 模糊 + 4px 偏移，漫画分镜框）
  ///   glow  = 强调色辉光（机甲霓虹）
  static List<BoxShadow> packShadow(SkinShadow s, Color seed) => switch (s) {
        SkinShadow.none => const <BoxShadow>[],
        SkinShadow.flat => [
            BoxShadow(
              color: seed.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        SkinShadow.soft => card(seed),
        SkinShadow.float => floating(seed),
        SkinShadow.hard => [
            BoxShadow(
              color: seed.withValues(alpha: 0.72),
              blurRadius: 0,
              offset: const Offset(4, 4),
            ),
          ],
        SkinShadow.glow => [
            BoxShadow(
              color: seed.withValues(alpha: 0.42),
              blurRadius: 18,
              spreadRadius: -4,
            ),
          ],
      };
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
    fx: SkinFx.calm,
  );

  /// ★2026-10-11 新增：简约黑白（tokens.json 里的 mono）
  static const Skin mono = Skin(
    id: 'mono',
    name: '素白',
    seed: Color(0xFF111111),
    lightBg: Color(0xFFFFFFFF),
    darkBg: Color(0xFF0B0B0C),
    fx: SkinFx.flat,
    vivid: false,
  );

  static const Skin ink = Skin(
    id: 'ink',
    name: '墨玉',
    seed: Color(0xFF1F2937),
    lightBg: Color(0xFFF7F7F8),
    darkBg: Color(0xFF0A0A0B),
    fx: SkinFx.crisp,
    vivid: false,
  );

  static const Skin jade = Skin(
    id: 'jade',
    name: '青瓷',
    seed: Color(0xFF0E9F6E),
    lightBg: Color(0xFFF4FAF7),
    darkBg: Color(0xFF0B1512),
    fx: SkinFx.calm,
  );

  static const Skin amber = Skin(
    id: 'amber',
    name: '暖阳',
    seed: Color(0xFFD97706),
    lightBg: Color(0xFFFCF8F2),
    darkBg: Color(0xFF16110A),
    fx: SkinFx.calm,
  );

  static const Skin violet = Skin(
    id: 'violet',
    name: '紫极',
    seed: Color(0xFF7C3AED),
    lightBg: Color(0xFFF8F6FD),
    darkBg: Color(0xFF120E1C),
    fx: SkinFx.calm,
  );

  static const Skin rose = Skin(
    id: 'rose',
    name: '绯樱',
    seed: Color(0xFFE11D6F),
    lightBg: Color(0xFFFDF5F8),
    darkBg: Color(0xFF180A11),
    fx: SkinFx.calm,
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

/// 特效档 —— 一套皮肤的「几何 / 质感 / 动效 / 密度」族名。
/// 与 tokens.json 的 `fx` 取值一一对应，同时是 `packs` 表的键。
///
/// ★ 2026-11-05：以前 7 套皮肤挂 `none`（= 只换了 seed 色，圆角阴影密度全一样），
///   现在每一套都必须挂一个真 pack —— `skin_parity_selfcheck` 里有一条
///   「没有皮肤可以取 none」的断言，就是为了不让它退回去。
enum SkinFx {
  /// 兼容值：历史配置可能存着它。**现在没有任何皮肤使用它。**
  none,

  /// 静：标准圆角 + 柔和投影 + 弹簧转场（默认）
  calm,

  /// 素：小圆角、纯平面无投影、稀疏密度
  flat,

  /// 锐：更小圆角、hairline 描边、紧凑密度
  crisp,

  /// 墨：近直角、去阴影只留线条、衬线标题
  ink,

  /// 霓：直角 + 发光描边 + 机械滑动转场
  neon,

  /// 玻：大圆角 + 胶囊按钮 + 浮起投影
  glass,

  /// 漫：墨线描边 + 硬投影 + 弹跳转场
  comic,
}

/// 投影档（pack.shadow）。App 端走 `CardTheme.elevation` + `shadowColor`，
/// 网页端走 `--pack-shadow` 关键词映射到具体 box-shadow。
enum SkinShadow {
  none,
  flat,
  soft,
  float,
  hard,
  glow,
}

/// 动效曲线族（pack.motion）。决定页面转场走哪条曲线。
///
/// ★ 这是「皮肤不只是换颜色」的第二个落点：机甲是机械滑动、漫画是弹跳弹出、
///   素白是干脆快出、水墨是慢起缓收 —— 同样的页面切换，观感完全不同。
enum SkinMotion {
  spring,
  swift,
  smooth,
  mech,
  bounce,
}

/// 一套皮肤的**完整套餐** —— 圆角 / 描边 / 阴影 / 动效曲线 / 卡片密度。
///
/// 值必须与 `design/tokens.json` 的 `packs` 逐字段一致（闸门比对），
/// 网页端 `css/theme.css` 的 `body[data-fx="<id>"]` 块是同一份数据的 CSS 表达。
///
/// ★ 收敛原则：页面**不许**自己写圆角/间距/曲线字面量。
///   要么用 `Radii.*`（全局基础档），要么用 `SkinTokens.of(context)`（随皮肤变）。
class SkinPack {
  const SkinPack({
    required this.id,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.btnRadius,
    required this.cardPad,
    required this.cardGap,
    required this.rowPad,
    required this.borderW,
    required this.shadow,
    required this.motion,
    required this.ease,
  });

  /// 与 `SkinFx` 同名
  final String id;

  /// 小控件圆角（chip / 小按钮）
  final double radiusSm;

  /// 卡片圆角
  final double radiusMd;

  /// 弹层 / 大面圆角
  final double radiusLg;

  /// 按钮与输入框圆角（999 = 胶囊）
  final double btnRadius;

  /// 卡片内边距
  final double cardPad;

  /// 卡片之间垂直间距（密度的一半落在上下各一份）
  final double cardGap;

  /// 列表行额外垂直内边距（密度：越大越稀疏）
  final double rowPad;

  /// 卡片描边宽度
  final double borderW;

  final SkinShadow shadow;
  final SkinMotion motion;

  /// 网页端等价曲线（仅作跨端契约，Dart 侧实际走 [Motion] 的 Cubic）
  final String ease;

  /// 卡片圆角
  BorderRadius get cardRadius => BorderRadius.circular(radiusMd);

  /// 按钮 / 输入框圆角
  BorderRadius get controlRadius => BorderRadius.circular(btnRadius);

  /// 弹层圆角
  BorderRadius get sheetRadius => BorderRadius.circular(radiusLg);

  /// 卡片内边距
  EdgeInsets get cardPadding => EdgeInsets.all(cardPad);

  /// 卡片外边距（上下各半档密度 —— 相邻两张卡片之间正好一个 cardGap）
  EdgeInsets get cardMargin => EdgeInsets.symmetric(vertical: cardGap / 2);

  /// 映射到 Material 的 elevation（阴影强度）
  double get elevation => switch (shadow) {
        SkinShadow.none => 0,
        SkinShadow.flat => 1,
        SkinShadow.soft => 2,
        SkinShadow.float => 8,
        SkinShadow.glow => 6,
        SkinShadow.hard => 0, // 硬投影靠粗描边立住，Material 表达不了偏移实影
      };

  // ── 七套套餐（顺序 = tokens.json packs 的键序去掉 none）──────────────
  static const SkinPack calm = SkinPack(
    id: 'calm', radiusSm: 10, radiusMd: 16, radiusLg: 24, btnRadius: 16,
    cardPad: 16, cardGap: 12, rowPad: 4, borderW: 1,
    shadow: SkinShadow.soft, motion: SkinMotion.spring,
    ease: 'cubic-bezier(.38,1.21,.22,1)',
  );

  static const SkinPack flat = SkinPack(
    id: 'flat', radiusSm: 6, radiusMd: 10, radiusLg: 16, btnRadius: 10,
    cardPad: 20, cardGap: 18, rowPad: 8, borderW: 1,
    shadow: SkinShadow.none, motion: SkinMotion.swift,
    ease: 'cubic-bezier(.22,1,.36,1)',
  );

  static const SkinPack crisp = SkinPack(
    id: 'crisp', radiusSm: 4, radiusMd: 6, radiusLg: 10, btnRadius: 6,
    cardPad: 14, cardGap: 10, rowPad: 3, borderW: 1,
    shadow: SkinShadow.none, motion: SkinMotion.swift,
    ease: 'cubic-bezier(.22,1,.36,1)',
  );

  static const SkinPack ink = SkinPack(
    id: 'ink', radiusSm: 3, radiusMd: 5, radiusLg: 8, btnRadius: 4,
    cardPad: 18, cardGap: 14, rowPad: 6, borderW: 1,
    shadow: SkinShadow.none, motion: SkinMotion.smooth,
    ease: 'cubic-bezier(.25,.8,.25,1)',
  );

  static const SkinPack neon = SkinPack(
    id: 'neon', radiusSm: 2, radiusMd: 4, radiusLg: 8, btnRadius: 4,
    cardPad: 14, cardGap: 10, rowPad: 3, borderW: 1,
    shadow: SkinShadow.glow, motion: SkinMotion.mech,
    ease: 'cubic-bezier(.15,.85,.35,1)',
  );

  static const SkinPack glass = SkinPack(
    id: 'glass', radiusSm: 12, radiusMd: 24, radiusLg: 30, btnRadius: 999,
    cardPad: 20, cardGap: 16, rowPad: 6, borderW: 1,
    shadow: SkinShadow.float, motion: SkinMotion.smooth,
    ease: 'cubic-bezier(.25,.8,.25,1)',
  );

  static const SkinPack comic = SkinPack(
    id: 'comic', radiusSm: 8, radiusMd: 10, radiusLg: 14, btnRadius: 10,
    cardPad: 16, cardGap: 14, rowPad: 4, borderW: 2,
    shadow: SkinShadow.hard, motion: SkinMotion.bounce,
    ease: 'cubic-bezier(.34,1.56,.64,1)',
  );

  /// 全部套餐（顺序与 tokens.json 的 packs 键序一致）
  static const List<SkinPack> all = [
    calm, flat, crisp, ink, neon, glass, comic,
  ];

  /// 由特效档取套餐；未知/兼容值回落到 calm
  static SkinPack of(SkinFx fx) {
    for (final SkinPack p in all) {
      if (p.id == fx.name) return p;
    }
    return calm;
  }
}

/// 把当前皮肤的套餐暴露进 `Theme.of(context)`。
///
/// 页面要「随皮肤变的密度/圆角」时读它，**不要**自己写 16/12 这种字面量：
///   `final pack = SkinTokens.of(context);`
///   `padding: pack.cardPadding`
class SkinTokens extends ThemeExtension<SkinTokens> {
  const SkinTokens({required this.pack, required this.skin});

  final SkinPack pack;
  final Skin skin;

  /// 取当前套餐（没有扩展时回落到 calm，保证永不 null）
  static SkinPack of(BuildContext context) =>
      Theme.of(context).extension<SkinTokens>()?.pack ?? SkinPack.calm;

  /// 取当前皮肤（用于需要原始 seed/bg 的地方）
  static Skin skinOf(BuildContext context) =>
      Theme.of(context).extension<SkinTokens>()?.skin ?? Skin.ocean;

  @override
  SkinTokens copyWith({SkinPack? pack, Skin? skin}) =>
      SkinTokens(pack: pack ?? this.pack, skin: skin ?? this.skin);

  @override
  SkinTokens lerp(ThemeExtension<SkinTokens>? other, double t) {
    if (other is! SkinTokens) return this;
    // 套餐是离散值，不做插值：过半直接换（皮肤切换是"跳变"，本来就该瞬切）
    return t < 0.5 ? this : other;
  }
}

/// 由皮肤 + 亮度构造完整 `ThemeData`。
///
/// 这是把上面所有令牌**装进 Flutter 主题系统**的唯一入口 ——
/// main.dart 只调它一次，页面侧仍然走 `Theme.of(context)`。
ThemeData buildSkinTheme(Skin skin, Brightness b) {
  final bool dark = b == Brightness.dark;
  final Color bg = dark ? skin.darkBg : skin.lightBg;
  final ColorScheme scheme = ColorScheme.fromSeed(seedColor: skin.seed, brightness: b);

  // ── 皮肤套餐决定的"风格量"（圆角 / 卡片色 / 边框 / 阴影 / 密度）──────
  //   ★ 这里就是"换皮肤不只是换颜色"的落点：同一个底色配不同 pack，
  //     圆角、描边、透明度、阴影、卡片密度都不一样，观感是两套东西。
  //   ★ 2026-11-05：原来是 5 个 `switch (fx)`，加一档要改 5 处、漏一处就半新半旧。
  //     现在全部收进 `SkinPack` 一张表 —— 加套餐只改 tokens.json + SkinPack.all。
  final SkinPack pack = SkinPack.of(skin.fx);
  final BorderRadius cardRadius = pack.cardRadius;
  final BorderRadius btnRadius = pack.controlRadius;
  // 表面色带一点底色倾向：纯粹的统一底色才"高级"，
  // 页面里出现两种不同的灰是最显廉价的错误。
  final Color surface = bg;
  // ── 反差阶梯（2026-10-30：用户反馈「夜间模式一片黑，反差色没做」）────────
  //   病根：深色下卡片只叠 4.5% 白、输入框同色、边框 6%、分隔线 7% ——
  //   在手机屏上全部糊成一整块黑，"卡片/输入框/悬浮层"分不出层次。
  //   修法：四层逐级提亮（页面 < 卡片 < 输入 < 悬浮），边框与分隔线加到能看见，
  //   并把 M3 的 surfaceContainer* 全部显式赋值 —— 没走自定义色的 Material
  //   组件（Chip / Menu / 弹层 / SnackBar）也就跟着有层次了。
  Color lift(double a) =>
      dark ? Color.alphaBlend(Colors.white.withValues(alpha: a), bg) : Colors.white;
  final Color surfaceLow = lift(0.055);   // 低层：整块列表底
  final Color surfaceMid = lift(0.085);   // 中层：卡片
  final Color surfaceHigh = lift(0.125);  // 高层：输入框 / 选中项
  final Color surfaceTop = lift(0.175);   // 顶层：悬浮面板 / 对话框
  final double lineA = dark ? 0.14 : 0.09;   // 分隔线
  final double edgeA = dark ? 0.20 : 0.10;   // 卡片描边
  Color surfaceCard = surfaceMid;
  if (pack.id == 'glass') {
    // 玻璃：卡片更"浮"一点，靠模糊与描边拉开层次
    surfaceCard = dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.11), bg)
                       : Color.alphaBlend(Colors.white.withValues(alpha: 0.55), bg);
  }
  // 机甲：卡片带一层极淡的强调色，配合霓虹描边
  if (pack.id == 'neon') {
    surfaceCard = Color.alphaBlend(skin.seed.withValues(alpha: dark ? 0.05 : 0.035), surfaceCard);
  }
  // 素白：纯平面 —— 卡片与页底拉开一点点，靠描边而不是投影分层
  if (pack.id == 'flat') {
    surfaceCard = dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.035), bg) : Colors.white;
  }
  // ── 卡片描边：宽度来自 pack.borderW（漫画 = 2px 墨线），颜色按套餐分派 ──
  //   分派只此一处，页面里不写 border 字面量。
  final BorderSide cardSide = switch (pack.id) {
    // 机甲：强调色描边，深色下更亮（霓虹感）
    'neon' => BorderSide(
        color: skin.seed.withValues(alpha: dark ? 0.45 : 0.30), width: pack.borderW),
    // 玻璃：白描边（模拟玻璃边缘反光）
    'glass' => BorderSide(
        color: Colors.white.withValues(alpha: dark ? 0.10 : 0.65), width: pack.borderW),
    // 漫画：2px 墨线 —— 亮色用墨黑、暗色用纸白，黑白对比是漫画印刷的灵魂
    'comic' => BorderSide(
        color: dark
            ? Colors.white.withValues(alpha: 0.85)
            : scheme.onSurface.withValues(alpha: 0.88),
        width: pack.borderW),
    // 墨玉：描边深一档（hairline 更"锐"）
    'crisp' => BorderSide(
        color: scheme.onSurface.withValues(alpha: dark ? 0.30 : 0.20), width: pack.borderW),
    // 其余：极淡描边（无描边时深色下卡片与页底同色，等于没有卡片）
    _ => BorderSide(color: scheme.onSurface.withValues(alpha: edgeA), width: pack.borderW),
  };
  // 标题字形：水墨走衬线（有"书卷气"），其余沿用默认无衬线
  final bool serif = skin.fx == SkinFx.ink;
  final TextStyle h1 = serif
      ? Types.h1.copyWith(fontFamily: 'serif', letterSpacing: 0.5)
      : Types.h1;
  final TextStyle h2 = serif
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
    colorScheme: scheme.copyWith(
      primary: skin.seed,
      surface: surface,
      // 反差阶梯落到 M3 语义色上：任何走 surfaceContainer* 的内置组件都有层次
      surfaceContainerLowest: dark ? bg : Colors.white,
      surfaceContainerLow: surfaceLow,
      surfaceContainer: surfaceCard,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceTop,
      outline: scheme.onSurface.withValues(alpha: dark ? 0.42 : 0.30),
      outlineVariant: scheme.onSurface.withValues(alpha: dark ? 0.20 : 0.12),
    ),
    textTheme: text,
    // 大字阶：M3 Expressive 会把强调标题再加重一档
    typography: Typography.material2021(platform: TargetPlatform.android),
    canvasColor: surface,
    splashFactory: InkSparkle.splashFactory, // 安卓原生级涟漪
    cardTheme: CardThemeData(
      // 阴影档由 pack.shadow 决定（none/flat/soft/float/hard/glow）
      elevation: pack.elevation,
      // ★ 卡片密度：上下各半档，相邻两张之间正好一个 cardGap
      margin: pack.cardMargin,
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
    // 列表行密度：随皮肤变（素白/玻璃更松、机甲/墨玉更紧）
    listTileTheme: ListTileThemeData(
      minVerticalPadding: pack.rowPad,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: pack.rowPad / 2),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.onSurface.withValues(alpha: lineA),
      thickness: 1,
      space: 1,
    ),
    // 表单：统一圆角 + 输入框底色比卡片再亮一档（否则深色下"输入框看不见"）
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: btnRadius,
        borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: edgeA)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: btnRadius,
        borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: edgeA)),
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
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(pack.radiusSm)),
      side: BorderSide.none,
      backgroundColor: surfaceCard,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: cardRadius),
      insetPadding: const EdgeInsets.all(16),
    ),
    // ★2026-10-31 修「浮窗半透明、和背后文字重叠」：
    //   原来这里是 backgroundColor: Colors.transparent —— 于是所有 showModalBottomSheet
    //   出来的面板（更多功能 / 模型选择 / 语音设置…）都不画底，直接把内容浮在正文上。
    //   截图里那种"拍照/相册/文件 叠在 AI 回复文字上"就是它。
    //   现在给实底（surfaceTop：比卡片再亮一档，视觉上"浮起来"）+ 顶部圆角 + 上缘描边。
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surfaceTop,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: surfaceTop,
      modalBarrierColor: Colors.black.withValues(alpha: 0.55),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(pack.radiusLg)),
        side: BorderSide(color: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.06), width: 1),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceTop,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: pack.sheetRadius),
    ),
    // ── 2026-11-04 补齐「仍在用 Material 默认值」的组件 ──
    //   这些组件此前没在主题里声明，于是永远长成 Material 默认样：
    //   默认开关是紫/灰、默认滑块是 M3 紫、TabBar 下划线是默认色、弹出菜单是方角。
    //   在带皮肤的 App 里它们就是「局部不像同一套设计」的破绽。
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
          ? scheme.onPrimary
          : scheme.onSurface.withValues(alpha: 0.55)),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
          ? skin.seed
          : scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.08)),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
          ? Colors.transparent
          : scheme.onSurface.withValues(alpha: 0.22)),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
          ? skin.seed
          : Colors.transparent),
      checkColor: WidgetStateProperty.all(scheme.onPrimary),
      side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.28), width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
          ? skin.seed
          : scheme.onSurface.withValues(alpha: 0.45)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: skin.seed,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: dark ? 0.16 : 0.10),
      thumbColor: skin.seed,
      overlayColor: skin.seed.withValues(alpha: 0.12),
      trackHeight: 4,
      valueIndicatorColor: skin.seed,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: skin.seed,
      // 轨道颜色：不给就是默认的 primary 淡化，深色下几乎看不见
      linearTrackColor: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.08),
      circularTrackColor: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.08),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: skin.seed,
      unselectedLabelColor: scheme.onSurface.withValues(alpha: 0.60),
      labelStyle: Types.title.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
      unselectedLabelStyle: Types.title.copyWith(fontSize: 13),
      dividerColor: scheme.onSurface.withValues(alpha: lineA),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: skin.seed, width: 2.5),
        insets: const EdgeInsets.symmetric(horizontal: 2),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surfaceTop,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: skin.seed.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(borderRadius: cardRadius),
      textStyle: Types.body.copyWith(fontSize: 13),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? surfaceTop : const Color(0xF21F2124),
        borderRadius: Radii.smAll,
      ),
      textStyle: Types.caption.copyWith(
          color: dark ? scheme.onSurface : Colors.white, fontSize: 11),
      waitDuration: const Duration(milliseconds: 500),
    ),
    // 滚动条纤细化：Material 默认滚动条又粗又没有颜色过渡，是"廉价感"的典型来源。
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) ? 6 : 3),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.resolveWith((s) => scheme.onSurface
          .withValues(alpha: s.contains(WidgetState.hovered) ? 0.38 : 0.20)),
    ),
    // 分段按钮（导航形态切换那类控件）同样走圆角与主色，不然是默认方角。
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(pack.radiusSm)),
        selectedBackgroundColor: skin.seed.withValues(alpha: dark ? 0.28 : 0.14),
        selectedForegroundColor: skin.seed,
        textStyle: Types.caption.copyWith(fontSize: 11),
      ),
    ),
    // 图标默认色：不声明时是 onSurface 全黑，和正文同色导致"哪里都是重点"。
    iconTheme: IconThemeData(
      size: 22,
      color: scheme.onSurface.withValues(alpha: 0.82),
    ),
    // 页面转场按**套餐的动效族**分派 —— 这就是"效果皮肤"与"颜色皮肤"的分水岭：
    //   机甲（mech）  = 机械滑动（快启动 → 匀速推进 → 精准刹停，伺服感）
    //   漫画（bounce）= 弹跳弹出（夸张过冲，像分镜砸进画面）
    //   素白/墨玉（swift）= 干脆快出，没有回弹（利落）
    //   水墨/玻璃（smooth）= 慢起缓收
    //   深海等（spring）= M3 Expressive 弹簧
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      TargetPlatform.android: _pageTransitionFor(pack.motion),
      TargetPlatform.iOS: _pageTransitionFor(pack.motion),
    }),
    // 把套餐挂进 Theme，页面用 SkinTokens.of(context) 读，不写死数值
    extensions: <ThemeExtension<dynamic>>[
      SkinTokens(pack: pack, skin: skin),
    ],
  );
}

/// 按动效族选择页面转场（"效果皮肤"的唯一分派点）。
///
/// ★ 新增动效族 = 在这里加一条分支 + 写一个 PageTransitionsBuilder 子类，
///   不要在页面里写 if (皮肤=='x') —— 分派只此一处，保证不漏页。
PageTransitionsBuilder _pageTransitionFor(SkinMotion m) => switch (m) {
      SkinMotion.mech => const _MechaPageTransition(),
      SkinMotion.bounce => const _ComicPageTransition(),
      SkinMotion.swift => const _SwiftPageTransition(),
      SkinMotion.smooth => const _SmoothPageTransition(),
      SkinMotion.spring => const _SpringPageTransition(),
    };

/// 干脆式转场：快速淡入 + 极小位移，**没有过冲**。
/// 素白/墨玉用 —— 这两套要的是"利落"，回弹会显得轻浮。
class _SmoothPageTransition extends PageTransitionsBuilder {
  const _SmoothPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Motion.effect),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.018),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: const Cubic(0.25, 0.8, 0.25, 1),
          reverseCurve: Curves.easeInCubic,
        )),
        child: child,
      ),
    );
  }
}

/// 快出式转场：无过冲、位移小、起手快（easeOut）—— "翻页即到"。
class _SwiftPageTransition extends PageTransitionsBuilder {
  const _SwiftPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.04, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: const Cubic(0.22, 1.0, 0.36, 1.0),
        reverseCurve: Curves.easeInCubic,
      )),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Motion.effect),
        child: child,
      ),
    );
  }
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
