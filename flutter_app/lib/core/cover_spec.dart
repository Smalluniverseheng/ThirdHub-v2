// 封面 / 图片网格的统一规格（**零 Flutter 依赖**）
//
// 为什么单独一个文件：
//   `ui_cover.dart`（CoverImage 等）import 了 `package:flutter/material.dart`，
//   → 最终依赖 `dart:ui`，纯 Dart VM 下连编译都过不去。
//   把**数值与判定**放这里，纯 Dart 自检就能直接 import 去断言
//   「圆角一律 12」「每个 kind 都登记过」「未知 kind 有兜底」，
//   而不必靠脆弱的字符串 grep。
//
// 为什么要有这套规格（2026-10-01 实测）：
//   全仓 `childAspectRatio` 出现过 11 种取值、间距 5 种、封面圆角有 10/8/4，
//   而 `STYLE_GUIDE.md` 第 3 条写的是「卡片圆角 12，间距基准 8 的倍数」。
//   同一个书架，换个模块就换一套参数 —— 用户看到的就是「不统一」。
//   这里把参数**收归一处**：改一个数，全仓跟着变。

/// 网格用途分类。**新增 kind 必须同时在 `CoverSpec.aspect` 登记**（自检会拦）。
class CoverKind {
  const CoverKind._();

  /// 书封网格（小说/漫画/绘本，**含书名条与副标题**）
  static const String bookGrid = 'bookGrid';

  /// 纯封面网格（只有封面，无书名条；如引擎直连的结果墙）
  static const String coverGrid = 'coverGrid';

  /// 影视/剧集封面卡（含名条，偏横或近方）
  static const String videoGrid = 'videoGrid';

  /// 直播频道卡（封面 + 2 行频道名）
  static const String liveGrid = 'liveGrid';

  /// 相册 / 壁纸 / 图墙（竖图为主，纯图无文字）
  static const String wallGrid = 'wallGrid';

  /// 菜谱 / 图文卡（图 + 文字说明）
  static const String cardGrid = 'cardGrid';

  /// 通用方形宫格（功能入口，非内容封面）
  static const String squareGrid = 'squareGrid';

  /// **全部 kind 常量的显式清单**。
  ///
  /// 存在意义：Dart 没有反射，自检无法自动枚举类里的 `static const`。
  /// 自检拿它去比对 `CoverSpec.aspect` / `CoverSpec.columns` 的键集 ——
  /// 于是"新加了一个 kind 常量却忘了在比例表里登记"会当场变红，
  /// 而不是等到界面上某个网格悄悄退回默认 1.0（正方）才发现。
  static const List<String> declared = [
    bookGrid,
    coverGrid,
    videoGrid,
    liveGrid,
    wallGrid,
    cardGrid,
    squareGrid,
  ];
}

/// 封面相关的尺寸常量。**改这里 = 改全仓**。
class CoverSpec {
  const CoverSpec._();

  /// 卡片圆角。`STYLE_GUIDE.md` 第 3 条：卡片 12。
  static const double radius = 12;

  /// 网格间距。`STYLE_GUIDE.md` 第 3 条：间距基准 8 的倍数。
  static const double gap = 8;

  /// 网格外边距（与间距同源，避免"内边距 12 外边距 8"这类不一致）。
  static const double pad = 8;

  /// 列表行内小缩略图的圆角。**不是卡片**（嵌在 `ListTile.leading` 里，
  /// 12 在 40×56 的尺寸上会显得圆得过分），故与卡片圆角分开登记。
  static const double thumbRadius = 4;

  /// 列表行内小缩略图尺寸（书目列表统一 40×56）。
  static const double thumbWidth = 40;
  static const double thumbHeight = 56;

  /// 照片墙（相册/已同步照片）的缩略圆角。照片墙是**无缝拼贴**语义，
  /// 与"卡片"不同，故单独登记且保持极小值。
  static const double photoRadius = 2;

  /// 每个 kind 的格子宽高比（w/h）。
  ///
  /// ★ 注意口径：这是**整个格子**的比例，不是封面图本身的比例。
  ///   带书名条的格子必须更"瘦高"（如 bookGrid=0.52），因为它要同时装下
  ///   封面 + 书名 2 行 + 副标题 1 行；纯封面格子（coverGrid=0.68）才接近
  ///   封面真实比例。混用这两个口径就会出现"封面被压扁/书名被裁掉"。
  static const Map<String, double> aspect = {
    CoverKind.bookGrid: 0.52,
    CoverKind.coverGrid: 0.68,
    CoverKind.videoGrid: 0.75,
    CoverKind.liveGrid: 0.75,
    CoverKind.wallGrid: 0.65,
    CoverKind.cardGrid: 0.85,
    CoverKind.squareGrid: 1.0,
  };

  /// 每个 kind 的默认列数。
  static const Map<String, int> columns = {
    CoverKind.bookGrid: 3,
    CoverKind.coverGrid: 3,
    CoverKind.videoGrid: 3,
    CoverKind.liveGrid: 3,
    CoverKind.wallGrid: 3,
    CoverKind.cardGrid: 2,
    CoverKind.squareGrid: 3,
  };

  /// 取比例；未知 kind **兜底 1.0**（不抛异常 —— 界面不能因为传错字符串就崩）。
  static double aspectOf(String kind) => aspect[kind] ?? 1.0;

  /// 取列数；未知 kind **兜底 3**。
  static int columnsOf(String kind) => columns[kind] ?? 3;

  /// 该 kind 是否登记过（自检用它拦"加了新 kind 忘登记"）。
  static bool isKnown(String kind) => aspect.containsKey(kind);

  /// 已登记的 kind 全集（自检遍历用）。
  static List<String> get kinds => aspect.keys.toList();
}
