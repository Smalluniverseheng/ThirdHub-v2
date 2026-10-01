// 界面图标的**纯数据与纯函数**层（零 Flutter 依赖）。
//
// 为什么拆成两个文件（本仓的既有分层：`chat_logic.dart` / `chat_crypto.dart`
// 都是这个路子）：
//   纯 Dart VM **不能 import `package:flutter/material.dart`** —— 它最终依赖
//   `dart:ui`，而 `dart:ui` 只在 Flutter 引擎里存在。一旦 import，自检脚本
//   连编译都过不去（实测报 `Dart library 'dart:ui' is not available on this
//   platform`，满屏 11 万字节的错误），于是"UI 不许有 emoji"这条就没法进 CI。
//   把「键 / emoji → 图标名」的映射与判定逻辑放在这里（只用 String），
//   自检就能真跑；`ui_icons.dart` 只负责把**图标名**翻成 IconData。
//
// ★ 两个文件之间的唯一契约是**图标名**（如 'smart_toy_outlined'）。
//   `tool/ui_icons_selfcheck.dart` 会交叉核对：
//   本文件里出现过的每个名字，都必须在 `ui_icons.dart` 的落地表里存在 ——
//   写错一个字母的表现是"某个图标变成占位方块"，只在特定页面出现，最难发现。

/// 图标键 → Material 图标名。
/// 键是本仓内部约定的 ASCII 短名（可写进存储、可下发、可让人手输）。
const Map<String, String> kIconKeyToName = {
  // ── 助理 / 技能 ──
  'robot': 'smart_toy_outlined',
  'research': 'science_outlined',
  'code': 'terminal',
  'device': 'smartphone',
  'chart': 'insert_chart_outlined',
  'writer': 'edit_note',
  'translate': 'language',
  'library': 'folder_copy_outlined',
  'review': 'search',
  'summary': 'notes',
  'teacher': 'school_outlined',
  'sql': 'storage',
  'prompt': 'gps_fixed',
  'tool': 'build_outlined',
  'search': 'search',
  // ── 引擎总览（后端下发的键，取值沿用既有 `_engineIcon`，勿改）──
  'book': 'menu_book',
  'movie': 'movie_outlined',
  'palette': 'palette_outlined',
  'music': 'music_note',
  'cloud': 'cloud_outlined',
  'plug': 'power',
  // ── 后台任务模板 ──
  'clean': 'cleaning_services_outlined',
  'stats': 'library_books_outlined',
  'link': 'link',
  'backup': 'save_outlined',
  'task': 'assignment_outlined',
  // ── 小游戏 ──
  'game2048': 'grid_view',
  'snake': 'gesture',
  'gomoku': 'circle_outlined',
  // ── 日记心情 ──
  'happy': 'sentiment_very_satisfied',
  'ok': 'sentiment_satisfied_alt',
  'meh': 'sentiment_neutral',
  'sad': 'sentiment_dissatisfied',
  'angry': 'sentiment_very_dissatisfied',
  // ── 其它 ──
  'pin': 'push_pin_outlined',
  'download': 'download_outlined',
  'delete': 'delete_outline',
  'check': 'check_circle_outline',
  // 兜底：认不出的值统一退回它（下面 kUnknownIconKey 也指向同一名字）
  'unknown': 'extension_outlined',
};

/// 认不出的字符串统一落到这个键。选 `extension` 而不是 `help_outline`：
/// 它是"这是个占位图标"的通用语义，不会被误读成"这里需要帮助"。
const String kUnknownIconKey = 'unknown';

/// 历史 emoji → 图标键。
///
/// ★ 留着这张表**不是**为了继续用 emoji，而是为了**不破坏已有数据**：
///   · `AiAgentDef` 的 icon 从后端 JSON / 本机存档读，旧存档里是 emoji；
///   · 日记心情、用户手输的助理图标，也已以 emoji 形式落在本机存储里。
///   表在，这些老值照常显示矢量图标；表不在，用户升级后看到一排占位方块。
///
/// ★ 自检里有一条固定断言要求这张表**不能少于下面这些** —— 删任何一个
///   都会让某个老用户的历史数据变方块，而这种退化在开发机上永远复现不了。
const Map<String, String> kEmojiToKey = {
  '\u{1F916}': 'robot', // 🤖
  '\u{1F52C}': 'research', // 🔬
  '\u{1F4BB}': 'code', // 💻
  '\u{1F4F1}': 'device', // 📱
  '\u{1F4CA}': 'chart', // 📊
  '\u{270D}\u{FE0F}': 'writer', // ✍️
  '\u{270D}': 'writer', // ✍
  '\u{1F310}': 'translate', // 🌐
  '\u{1F5C2}\u{FE0F}': 'library', // 🗂️
  '\u{1F5C2}': 'library', // 🗂
  '\u{1F50D}': 'search', // 🔍
  '\u{1F6E0}\u{FE0F}': 'tool', // 🛠️
  '\u{1F6E0}': 'tool', // 🛠
  '\u{1F5D1}\u{FE0F}': 'delete', // 🗑️
  '\u{1F5D1}': 'delete', // 🗑
  '\u{1F4DD}': 'summary', // 📝
  '\u{1F393}': 'teacher', // 🎓
  '\u{1F5C4}\u{FE0F}': 'sql', // 🗄️
  '\u{1F5C4}': 'sql', // 🗄
  '\u{1F3AF}': 'prompt', // 🎯
  '\u{1F9F9}': 'clean', // 🧹
  '\u{1F4DA}': 'stats', // 📚
  '\u{1F517}': 'link', // 🔗
  '\u{1F4BE}': 'backup', // 💾
  '\u{1F4CB}': 'task', // 📋
  '\u{1F522}': 'game2048', // 🔢
  '\u{1F40D}': 'snake', // 🐍
  '\u{26AB}': 'gomoku', // ⚫
  '\u{1F604}': 'happy', // 😄
  '\u{1F642}': 'ok', // 🙂
  '\u{1F610}': 'meh', // 😐
  '\u{1F614}': 'sad', // 😔
  '\u{1F624}': 'angry', // 😤
  '\u{1F4CC}': 'pin', // 📌
  '\u{2B07}\u{FE0F}': 'download', // ⬇️
  '\u{2B07}': 'download', // ⬇
};

/// 核心入口：任意字符串（图标键 / 历史 emoji / 认不出的东西）→ 图标键。
/// **永不返回 null、永不返回空** —— 返回空会让界面出现比 emoji 更糟的空白。
String resolveIconKey(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return kUnknownIconKey;
  if (kIconKeyToName.containsKey(s)) return s;
  final direct = kEmojiToKey[s];
  if (direct != null) return direct;
  // 同一条 emoji 在不同输入法/旧数据里可能带或不带变体选择符 FE0F，
  // 去掉后再试一次（'✍️' 与 '✍' 在数据里是两条不同的字符串）。
  final stripped = s.replaceAll('\u{FE0F}', '');
  if (stripped != s) {
    final alt = kEmojiToKey[stripped];
    if (alt != null) return alt;
  }
  return kUnknownIconKey;
}

/// 任意字符串 → Material 图标名；认不出时返回兜底图标名（可能是空串，
/// 由调用方决定用什么兜底 —— 保持本层不认识 Flutter）。
String iconNameOf(String? raw) => kIconKeyToName[resolveIconKey(raw)] ?? '';

/// 是否认识这个字符串。用于给人看的提示（"这个图标名无法识别"）。
bool knowsIcon(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return false;
  if (kIconKeyToName.containsKey(s)) return true;
  return kEmojiToKey.containsKey(s) ||
      kEmojiToKey.containsKey(s.replaceAll('\u{FE0F}', ''));
}
