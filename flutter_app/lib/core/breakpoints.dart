// M3 自适应断点 + 折叠屏铰链阈值（阶段2）—— **纯 Dart，零 Flutter 依赖**。
//
// 单独成文件的理由：`tool/adaptive_selfcheck.dart` 要对判档函数做**行为断言**
// （边界值 599/600/839/840 各是哪一档），就必须能 `import` 本文件；
// 而 design_tokens.dart 依赖 Flutter（Color/TextStyle），`dart run` 导不进来
// —— i18n_selfcheck 的老教训：形状断言不能替代行为断言。
//
// ★ 与仓库根 `design/tokens.json` 的 `breakpoints` 逐项一致 ——
//   由 `tool/adaptive_selfcheck.dart` 把关。改这里必须同步 tokens.json
//   与网页端 `js/device-adapt.js` 的 `windowClass()`，否则闸门红。
//
// 对标 Material 3 窗口尺寸类（Window Size Classes）：
//   compact ≤599（手机竖屏）｜ medium 600–839（手机横屏/小平板）｜
//   expanded ≥840（平板横屏/折叠屏展开/桌面）。
class Breakpoints {
  Breakpoints._();

  /// compact 档上界（含）：宽度 ≤ 599
  static const double compactMax = 599;

  /// medium 档上界（含）：600 ≤ 宽度 ≤ 839
  static const double mediumMax = 839;

  /// expanded 档下界（含）：宽度 ≥ 840
  static const double expandedMin = 840;

  /// 折叠屏铰链/折痕判定阈值：displayFeature 短边 ≥ 20 逻辑像素视作铰链
  /// （挖孔/摄像头是 cutout 类型且厚度小，不进这条线）。
  static const double foldHingeMin = 20;

  /// 主从双栏（列表|详情）起始宽度 = expanded 起点。
  static const double listDetailMin = 840;
}

/// 窗口宽度档（M3 Window Size Classes）。三档命名与 tokens.json 一致。
enum WindowClass { compact, medium, expanded }

/// 由宽度判档。边界值按 tokens.json 语义：599→compact，600→medium，839→medium，840→expanded。
WindowClass windowClassOf(double width) {
  if (width <= Breakpoints.compactMax) return WindowClass.compact;
  if (width < Breakpoints.expandedMin) return WindowClass.medium;
  return WindowClass.expanded;
}
