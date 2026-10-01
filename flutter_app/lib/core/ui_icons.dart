import 'package:flutter/material.dart';

import 'ui_icon_map.dart';

/// 界面图标统一映射 —— **落地层**：把图标名翻成 `IconData`。
///
/// 纯数据与判定逻辑在 `ui_icon_map.dart`（零 Flutter 依赖，故纯 Dart VM
/// 可跑自检、能进 CI）。本文件只做一件事：`String → IconData`。
///
/// 为什么要有这个文件，而不是就地 `Icon(Icons.xxx)`：
///   同一个"图标语义"在本仓有**三个来源**，就地替换一定会漏掉其中一个：
///     ① 本地常量（`ai_skills.dart` 的技能、`job_center.dart` 的任务模板、
///        `lab_games.dart` 的游戏、日记的心情）；
///     ② **后端下发的图标键**（`agent-profiles.json`；引擎总览的
///        `book/movie/palette/music/cloud/plug`）；
///     ③ **用户自己敲进去的字符串**（`ai_agent_page` 的新建助理对话框允许
///        手输图标），可能是键、可能是历史 emoji、也可能是谁也认不出的东西。
///   前两代代码是就地各写一套判断（`main.dart` 里的 `_engineIcon` 就是 ② 的
///   局部解），同一件事三种写法三套默认值。这里收敛成一张表。
///
/// ★ 唯一的硬约束：`of()` **绝不返回 null**。
///   旧写法 `Text(a.icon)` 遇到认不出的值至少还显示个字符；换成 Icon 之后，
///   认不出就什么都不显示 —— 那是**比 emoji 更糟的回归**（一个空白的图标位
///   比一个难看的 emoji 更难排查）。所以认不出 → 兜底图标。
///
/// ★ `byName` 的键必须**逐一**覆盖 `kIconKeyToName` 的所有取值。
///   写错一个字母的表现是"某个页面出现占位方块"，只在特定路径复现。
///   这条由 `tool/ui_icons_selfcheck.dart` 交叉核对（解析本文件源码）。
class UiIcon {
  /// 键 → 图标名（供自检与调试查看；渲染请用 `of()`）。
  static Map<String, String> get keys => kIconKeyToName;

  /// 历史 emoji → 键（供自检查看）。
  static Map<String, String> get emoji => kEmojiToKey;

  /// 认不出的值统一退回这里。
  static const IconData fallback = Icons.extension_outlined;

  /// 图标名 → IconData。键名与 `ui_icon_map.dart` 里写的一一对应。
  /// （Flutter 无反射、`Icons.xxx` 是编译期常量，故只能显式列一张表。）
  static const Map<String, IconData> byName = {
    'smart_toy_outlined': Icons.smart_toy_outlined,
    'science_outlined': Icons.science_outlined,
    'terminal': Icons.terminal,
    'smartphone': Icons.smartphone,
    'insert_chart_outlined': Icons.insert_chart_outlined,
    'edit_note': Icons.edit_note,
    'language': Icons.language,
    'folder_copy_outlined': Icons.folder_copy_outlined,
    'notes': Icons.notes,
    'school_outlined': Icons.school_outlined,
    'storage': Icons.storage,
    'gps_fixed': Icons.gps_fixed,
    'build_outlined': Icons.build_outlined,
    'search': Icons.search,
    'menu_book': Icons.menu_book,
    'movie_outlined': Icons.movie_outlined,
    'palette_outlined': Icons.palette_outlined,
    'music_note': Icons.music_note,
    'cloud_outlined': Icons.cloud_outlined,
    'power': Icons.power,
    'cleaning_services_outlined': Icons.cleaning_services_outlined,
    'library_books_outlined': Icons.library_books_outlined,
    'link': Icons.link,
    'save_outlined': Icons.save_outlined,
    'assignment_outlined': Icons.assignment_outlined,
    'grid_view': Icons.grid_view,
    'gesture': Icons.gesture,
    'circle_outlined': Icons.circle_outlined,
    'sentiment_very_satisfied': Icons.sentiment_very_satisfied,
    'sentiment_satisfied_alt': Icons.sentiment_satisfied_alt,
    'sentiment_neutral': Icons.sentiment_neutral,
    'sentiment_dissatisfied': Icons.sentiment_dissatisfied,
    'sentiment_very_dissatisfied': Icons.sentiment_very_dissatisfied,
    'push_pin_outlined': Icons.push_pin_outlined,
    'download_outlined': Icons.download_outlined,
    'delete_outline': Icons.delete_outline,
    'check_circle_outline': Icons.check_circle_outline,
    'extension_outlined': Icons.extension_outlined,
  };

  /// 核心入口：把任意字符串（键 / 历史 emoji / 认不出的东西）映射成图标。
  static IconData of(String? raw) => byName[iconNameOf(raw)] ?? fallback;

  /// 是否认识这个字符串。用于给人看的提示。
  static bool knows(String? raw) => knowsIcon(raw);
}

/// 渲染入口：认识的显示矢量图标，不认识的回退到占位图标。
///
/// ★ 为什么以 `warnUnknown` 的形式让"认不出"可见：
///   因为**用户手输的图标**可能是任何东西（`ai_agent_page` 那个输入框）。
///   静默替换成占位图标正是本项目反复吃亏的那类缺陷（见 STYLE_GUIDE 第 2 条：
///   错误必须"现象/原因/怎么办"三段说清，不许静默吞）。所以允许调用方
///   在关键位置把"认不出"暴露成 Tooltip。
Widget uiIcon(String? raw,
    {double size = 20, Color? color, bool warnUnknown = false}) {
  final w = Icon(UiIcon.of(raw), size: size, color: color);
  final s = (raw ?? '').trim();
  if (!warnUnknown || s.isEmpty || UiIcon.knows(s)) return w;
  return Tooltip(message: '无法识别的图标「$s」，已用占位图标显示', child: w);
}
