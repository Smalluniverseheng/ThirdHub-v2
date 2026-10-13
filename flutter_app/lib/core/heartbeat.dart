// 客户端心跳 —— 记录「现在谁在用」与「用了多久」
//
// 为什么直连 Supabase 而不是走后端：
//   本项目既有架构就是「客户端直连 Supabase + 后端只做聚合」——后端 index.js
//   里根本没有 SB_KEY，它压根不碰 Supabase。心跳跟着走同一条路，
//   不给后端加新职责，也就不会出现「后端没起 → 心跳断 → 统计空白」。
//
// 计时口径（与 SQL 里的 admin_online_stats 对齐）：
//   · 客户端只上报「我在」+ 时间戳，**不做本地累加** ——客户端被杀/断网时
//     本地计时会失真；时长在查询时按相邻心跳差值算，单次间隔封顶 5 分钟。
//
// 隐私：只上报 user_id / 平台 / 版本，**不采集任何使用内容**（读了什么书、
// 听了什么歌都不上报）。管理后台只显示账号、在线状态、时长。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'cloud.dart';

class Heartbeat {
  Heartbeat._();

  /// 心跳间隔：60 秒（与 SQL 的 90 秒在线判定窗口配套，留一格余量）。
  static const Duration interval = Duration(seconds: 60);

  static Timer? _timer;
  static bool _busy = false;

  /// 开始心跳。重复调用安全（已在跑则忽略）。**未登录时不会发**——
  /// 统计里只该有真人，不该有匿名设备。
  static void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => beat());
    unawaited(beat()); // 立刻打一次，别等一个周期
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static bool get running => _timer != null;

  /// 打一次心跳。任何失败都静默 —— 心跳不该给用户添麻烦。
  static Future<void> beat() async {
    if (_busy) return;
    if (!Cloud.loggedIn || Cloud.userId.isEmpty) return;
    _busy = true;
    try {
      await http
          .post(
            Uri.parse('${Cloud.base}/rest/v1/rpc/admin_user_heartbeat'),
            headers: {
              'Content-Type': 'application/json',
              'apikey': Cloud.anonKey,
              'Authorization': 'Bearer ${Cloud.accessToken}',
            },
            body: jsonEncode({
              'p_user_id': Cloud.userId,
              'p_platform': 'android',
              'p_app_version': kAppVersion,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // 离线 / 表还没建 / RPC 不在 —— 都忽略，等下一拍
    } finally {
      _busy = false;
    }
  }
}