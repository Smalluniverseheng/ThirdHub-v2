// 触觉反馈统一层（2026-10-17）
//
// ★用户要求：「可以搞震动反馈，但记得搞开关键」。
//
// 为什么要有这一层（而不是各处直接调 HapticFeedback）：
//   ① **开关**：用户关掉之后，**所有**震动都要停 —— 分散调用必然漏掉几处，
//      表现为"关了还有震动"（和静音没静干净一个道理）；
//   ② 语义化：调用点写 Haptic.tap() / Haptic.medium()，强度策略集中在一处调，
//      以后要"整体调轻一点"只改一个文件；
//   ③ 平台差异收口：Web/桌面上没有触觉马达，统一在这里吞掉异常。
//
// 键：`haptic_on`（SharedPreferences，默认 true）
library;

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Haptic {
  const Haptic._();

  static bool _on = true;
  static bool _loaded = false;

  /// App 启动时调一次（读盘）；之后由设置页写。
  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _on = p.getBool('haptic_on') ?? true;
      _loaded = true;
    } catch (_) {
      _on = true;
    }
  }

  /// 当前是否开启（设置页用它渲染开关状态）。
  static bool get enabled => _on;

  /// 设置页调它；写盘 + 立即生效。
  static Future<void> setEnabled(bool v) async {
    _on = v;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('haptic_on', v);
    } catch (_) {}
    if (v) {
      // 打开时给一次反馈，让用户确认生效
      try { await HapticFeedback.selectionClick(); } catch (_) {}
    }
  }

  static bool get _warm => _loaded || _on; // 未初始化时按默认（开）放行

  /// 轻点（按钮、切换、选择）——用 selectionClick：比 lightImpact 更"细"。
  static Future<void> tap() async {
    if (!_warm || !_on) return;
    try { await HapticFeedback.selectionClick(); } catch (_) {}
  }

  /// 轻震（收起面板、轻量动作）。
  static Future<void> light() async {
    if (!_warm || !_on) return;
    try { await HapticFeedback.lightImpact(); } catch (_) {}
  }

  /// 中震（滑出抽屉、关键操作）。
  static Future<void> medium() async {
    if (!_warm || !_on) return;
    try { await HapticFeedback.mediumImpact(); } catch (_) {}
  }

  /// 重震（删除、危险操作确认）。
  static Future<void> heavy() async {
    if (!_warm || !_on) return;
    try { await HapticFeedback.heavyImpact(); } catch (_) {}
  }

  /// 成功提示（长按完成、下载完成）。
  static Future<void> success() async {
    if (!_warm || !_on) return;
    try { await HapticFeedback.mediumImpact(); } catch (_) {}
  }
}
