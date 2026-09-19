// ═══════════════════════════════════════════════════════════════════════════
// TH-Agent 存储适配器: 把 AiStore 接到 shared_preferences 上
//
// ai_agent.dart 本身不 import Flutter(便于纯 Dart 单测/自检), 真正落盘由本文件负责。
// App 启动时调用一次 [installAiStorePrefs] 即可让智能体/指令/记忆/钉注全部持久化。
// ═══════════════════════════════════════════════════════════════════════════
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_agent.dart';

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
}

/// 装载 shared_preferences 后端(幂等, 可重复调用)
void installAiStorePrefs() {
  if (aiStore is! _AiStorePrefs) aiStore = _AiStorePrefs();
}
