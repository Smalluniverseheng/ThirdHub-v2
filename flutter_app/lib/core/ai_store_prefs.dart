// ═══════════════════════════════════════════════════════════════════════════
// TH-Agent 存储适配器: 把 AiStore 接到 shared_preferences 上
//
// `ai_agent.dart` / `peer_hub.dart` 本身都不 import Flutter(便于纯 Dart 自检),
// 真正落盘由本文件负责。App 启动时调用一次 [installAiStorePrefs] 即可让
// 智能体/指令/记忆/钉注/**端列表与身份**全部持久化。
//
// ★2026-10-21：接口改成从 `kv.dart` 来，并补了 remove / setInt ——
//   PeerHub 以前直连 shared_preferences，正是那处直连把 Flutter 拖进了
//   纯 Dart 自检的编译链（导致 agent_selfcheck 红了 6 个版本、连带
//   15 道门禁被跳过）。现在两边共用同一个后端。
// ═══════════════════════════════════════════════════════════════════════════
import 'package:shared_preferences/shared_preferences.dart';

import 'kv.dart';

class _AiStorePrefs implements AiStore {
  SharedPreferences? _p;

  Future<SharedPreferences> _prefs() async =>
      _p ??= await SharedPreferences.getInstance();

  @override
  Future<String?> getString(String key) async => (await _prefs()).getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await (await _prefs()).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await _prefs()).remove(key);
  }

  @override
  Future<void> setInt(String key, int value) async {
    await (await _prefs()).setInt(key, value);
  }
}

/// 装载 shared_preferences 后端(幂等, 可重复调用)
void installAiStorePrefs() {
  if (aiStore is! _AiStorePrefs) setAiStore(_AiStorePrefs());
}
