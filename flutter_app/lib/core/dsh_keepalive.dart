// 本机 AI 保活（4.81.107）
//
// 起因：本机运行靠 PRoot 在 App 进程里拉 node。用户切出去回个消息，Android 把进程
// 判成「后台空闲」就冻结/回收 —— 回来时 AI 断开、得再等一分钟展开 rootfs。
//
// Dart 侧做不到两件必须的事：
//   ① 常驻前台服务（系统的「我还在干活」声明，唯一有效的抗杀手段）
//   ② PARTIAL_WAKE_LOCK（防 CPU 休眠把 node 的定时器/网络回调一起冻住）
// 所以走原生通道，代码在 android/.../DshKeepAliveService.kt。
//
// 语义边界要清楚：保活是「更好」，不是「必须」。任何一步失败（用户关了通知权限、
// ROM 不给起前台服务）都只记日志，绝不阻断本机运行。
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';

class DshKeepAlive {
  static const MethodChannel _ch = MethodChannel('thirdhub/keepalive');

  /// 用户从通知栏点「停止」时的回调。由 DshPack 在初始化时挂上。
  static Future<void> Function()? onUserStop;

  static bool _wired = false;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'stop') {
        AppLog.add('dsh', 'info', '通知栏点了停止');
        final cb = onUserStop;
        if (cb != null) {
          try {
            await cb();
          } catch (e) {
            AppLog.add('dsh', 'warn', '停止回调异常: $e');
          }
        }
      }
      return null;
    });
  }

  /// 起前台服务。失败只记日志，返回实际是否处于「在跑」状态。
  static Future<bool> start({String title = '', String text = ''}) async {
    if (!Platform.isAndroid) return false;
    _wire();
    try {
      final r = await _ch.invokeMethod<bool>('start', {
        'title': title.isEmpty ? '本机 AI 运行中' : title,
        'text': text.isEmpty ? '断网也能用，点这里回到对话' : text,
      });
      return r ?? false;
    } catch (e) {
      AppLog.add('dsh', 'warn', '保活服务没起来（不影响本机运行）: $e');
      return false;
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  /// 是否已在系统电池优化白名单里。非 Android / 通道异常一律按「未加白」处理，
  /// 界面据此给用户入口 —— 宁可多显示一个入口，也不要谎报已优化。
  static Future<bool> batteryExempt() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _ch.invokeMethod<bool>('batteryExempt') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 弹系统的「允许后台运行」对话框。返回 true 表示对话框已弹出（不代表用户同意）。
  static Future<bool> requestBatteryExempt() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('requestExempt') ?? false;
    } catch (_) {
      return false;
    }
  }
}
