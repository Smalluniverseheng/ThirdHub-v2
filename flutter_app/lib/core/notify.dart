// 本地通知: 系统通知栏(公告/下载完成/后台任务)
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

class Notify {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return; _inited = true;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try { await a?.requestNotificationsPermission(); } catch (_) {}
  }

  static Future<void> show(int id, String title, String body, {String channel = 'general', String channelName = '通用通知'}) async {
    await init();
    await _plugin.show(id, title, body, NotificationDetails(android: AndroidNotificationDetails(
      channel, channelName, importance: Importance.high, priority: Priority.high)));
  }

  // 进度条通知(后台下载用): onlyAlertOnce 不反复响铃; 完成/失败务必 cancelProgress
  static Future<void> progress(int id, String title, String body, {int max = 100, int value = 0, bool indeterminate = false}) async {
    await init();
    await _plugin.show(id, title, body, NotificationDetails(android: AndroidNotificationDetails(
      'download', '下载进度', importance: Importance.low, priority: Priority.low,
      showProgress: true, maxProgress: max, progress: indeterminate ? 0 : value,
      indeterminate: indeterminate, onlyAlertOnce: true, ongoing: true, autoCancel: false,
      channelShowBadge: false)));
  }
  static Future<void> cancelProgress(int id) async { await cancel(id); }

  // 定时通知(提醒中心用): 到点弹系统通知, 关屏也响; inexact 模式免精确闹钟权限
  static Future<void> schedule(int id, String title, DateTime when) async {
    await init();
    try {
      await _plugin.zonedSchedule(id, '提醒: $title', '',
        tz.TZDateTime.from(when, tz.local),
        const NotificationDetails(android: AndroidNotificationDetails('reminder', '提醒',
          importance: Importance.high, priority: Priority.high)),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime);
    } catch (_) {}
  }
  static Future<void> cancel(int id) async { try { await _plugin.cancel(id); } catch (_) {} }

  // 公告轮询: 管理后台 ThirdHub-Admin「全局公告」写入 Supabase th_configs(announcement)
  // 客户端启动时检查, 新公告 → 系统通知 + 记住已读; 兼容存储桶 announce.json
  static Future<void> checkAnnouncements() async {
    try {
      await init();
      final p = await SharedPreferences.getInstance();
      // 1) 管理后台公告(th_configs.key=announcement)
      const anon = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im14dnhsZ2p6ZWJva3R1ZnVteGJwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzODM5OTcsImV4cCI6MjA5OTk1OTk5N30.QjSLfYAFhwX72YSeAcbTN5O2_PDLaNcv76HhdGJsqpo';
      final r = await http.get(Uri.parse('https://mxvxlgjzeboktufumxbp.supabase.co/rest/v1/th_configs?key=eq.announcement&select=*'),
        headers: {'apikey': anon, 'Authorization': 'Bearer $anon'}).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final l = jsonDecode(utf8.decode(r.bodyBytes)) as List;
        if (l.isNotEmpty) {
          final row = Map<String, dynamic>.from(l.first);
          final body = '${row['value'] ?? ''}'.trim();
          final id = '${row['updated_at'] ?? body.hashCode}';
          if (body.isNotEmpty && p.getString('announce_read') != id) {
            await p.setString('announce_read', id);
            await show(88001, 'ThirdHub 公告', body, channel: 'announce', channelName: '公告');
            return;
          }
        }
      }
      // 2) 兼容: 存储桶 announce.json {id,title,body}
      final r2 = await http.get(Uri.parse('https://mxvxlgjzeboktufumxbp.supabase.co/storage/v1/object/public/downloads/thirdhub/announce.json?ts=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 8));
      if (r2.statusCode != 200) return;
      final j = jsonDecode(utf8.decode(r2.bodyBytes));
      final id = '${j['id'] ?? ''}';
      if (id.isEmpty || p.getString('announce_read') == id) return;
      await p.setString('announce_read', id);
      await show(88001, '${j['title'] ?? 'ThirdHub 公告'}', '${j['body'] ?? ''}', channel: 'announce', channelName: '公告');
    } catch (_) {}
  }
}
