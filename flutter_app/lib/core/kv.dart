// 键值存储抽象 —— **纯 Dart，零 Flutter 依赖**。
//
// 为什么单独一个文件（2026-10-21）：
//   TH-Agent 核心与 PeerHub 都刻意不依赖 Flutter，好让纯 Dart VM 能跑自检。
//   但 `peer_hub.dart` 曾经直接 `import 'package:shared_preferences'`，
//   于是任何**间接**引用到 peer_hub 的自检（如 `agent_selfcheck.dart`，
//   它经 ai_agent → agent_dsh_client → peer_hub）在 `dart run` 下**编译不过**：
//       `flutter/gestures/velocity_tracker.dart … Offset isn't a type`
//   结果是那把尺子从 2026-10-17 起一直红，而 CI 会**停在第一个失败**——
//   它后面另外 15 道门禁（i18n / api_keys / ui_cover / branding / forbidden-words…）
//   整整 6 个版本没有真正跑过。那比"某个功能坏了"严重得多：
//   等于整条自检防线是聋的。
//
// 所以：把「怎么存」收敛成一个接口 + 一个进程内默认实现，
// 真正的 SharedPreferences 由 `ai_store_prefs.dart` 在 App 启动时注入。
// 自检用默认内存实现 → 纯 Dart VM 直接可跑，覆盖度一点不减。
//
// 用法：
//   · 业务代码：`final s = await aiStore.getString('k');`
//   · App 启动：`installAiStorePrefs()`（main.dart 已调用）
//   · 自检/单测：`resetAiStoreForTest()` 拿一份干净的
library;

/// 最小键值存储接口。
///
/// 故意只有五个方法 —— 接口越窄，实现越不容易走偏，
/// 也越容易给自检造一个假实现。
abstract class AiStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
  Future<void> setInt(String key, int value);
}

/// 进程内实现（默认）。重启即清空 —— 自检与单测要的正是这个。
///
/// 字符串与整数**分两个命名空间**存放，与 shared_preferences 的行为对齐：
/// 用 `setInt` 写进去的键，`getString` 读回来是 null（不是 "123"）。
class MemAiStore implements AiStore {
  final Map<String, String> _s = {};
  final Map<String, int> _i = {};

  @override
  Future<String?> getString(String key) async => _s[key];

  @override
  Future<void> setString(String key, String value) async {
    _s[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _s.remove(key);
    _i.remove(key);
  }

  @override
  Future<void> setInt(String key, int value) async {
    _i[key] = value;
  }
}

AiStore _kv = MemAiStore();

/// 全局存储实例（只读）。要换后端请用 [setAiStore]。
AiStore get aiStore => _kv;

/// 替换后端（App 启动时由 `installAiStorePrefs()` 调用）。
void setAiStore(AiStore s) => _kv = s;

/// 自检 / 单测用：换一份干净的内存存储。
void resetAiStoreForTest() => _kv = MemAiStore();
