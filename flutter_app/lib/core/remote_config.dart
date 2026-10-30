// 远端配置中心（App 侧）—— 2026-10-30
//
// 用户要求：「第三方 API 要能在后台一键替换，不要打包进安装包；软件要实时连后台/服务器」。
// 所以真正的值放在 Supabase 的 th_remote_config 表，App 启动拉一次；安装包里只留兜底默认值。
//
// 三条硬约束（和网页端 js/remote-config.js 完全同口径）：
//   ① 任何失败都不许抛：断网 / 表不存在 / RPC 报错 → 用缓存，再不行用默认值；
//   ② 缺 key ≠ 出错，取值一律带默认；
//   ③ 不阻塞启动：先读缓存立刻可用，网络回来再覆盖（拿到新值广播 th:config 事件）。
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud.dart';

class RemoteConfig {
  static const String _cacheKey = 'th_remote_config_v1';

  /// 兜底默认值 —— 只是"服务器上也拿不到"的最后一层，**不是**配置真源。
  /// 要改线上行为请去后台「远端配置」，改这里不会影响线上。
  static const Map<String, Map<String, dynamic>> defaults = {
    'api.endpoints': {'search': '', 'tts': '', 'asr': ''},
    'map.provider': {'provider': 'tencent', 'key': '', 'enabled': false},
    'asr.default': {'vendor': '', 'endpoint': '', 'shape': 'openaiMultipart'},
    'tts.default': {'vendor': '', 'endpoint': ''},
    'sources.catalog': {'items': []},
    'flags.features': {'chat': false, 'library': true, 'libraryModules': ['novel'], 'p2p': false},
    'library.backend': {'mode': 'cloud', 'nasUrl': '', 'nasToken': ''},
  };

  static Map<String, dynamic> _cfg = <String, dynamic>{};
  static Map<String, dynamic> _meta = <String, dynamic>{};
  static bool ready = false;
  static Future<void>? _loading;

  /// 取一项（永远返回 Map，不会 null）
  static Map<String, dynamic> get(String key) {
    final v = _cfg[key];
    if (v is Map) return Map<String, dynamic>.from(v);
    return Map<String, dynamic>.from(defaults[key] ?? const {});
  }

  /// 取原始值（字符串/数字/布尔这类标量用）
  static dynamic raw(String key) {
    if (_cfg.containsKey(key)) return _cfg[key];
    return defaults[key];
  }

  /// 版本号（调试/后台核对用）
  static int versionOf(String key) {
    final m = _meta[key];
    if (m is Map && m['version'] is num) return (m['version'] as num).toInt();
    return 0;
  }

  static Map<String, dynamic> get all {
    final out = <String, dynamic>{};
    defaults.forEach((k, v) => out[k] = v);
    _cfg.forEach((k, v) => out[k] = v);
    return out;
  }

  /// 资源库后端：cloud=用云库 / nas=连自己 NAS（分享给家人就是它）
  static ({String mode, String url, String token}) libraryBackend() {
    final b = get('library.backend');
    final mode = (b['mode'] == 'nas' && (b['nasUrl'] ?? '').toString().isNotEmpty) ? 'nas' : 'cloud';
    return (mode: mode, url: (b['nasUrl'] ?? '').toString(), token: (b['nasToken'] ?? '').toString());
  }

  static bool featureOn(String name) {
    final f = get('flags.features');
    return f[name] == true;
  }

  /// 启动调用：先用缓存，再后台刷新。失败静默。
  static Future<void> init({bool force = false}) {
    if (_loading != null && !force) return _loading!;
    _loading = _run();
    return _loading!;
  }

  static Future<void> _run() async {
    // ① 缓存
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_cacheKey);
      if (raw != null && raw.isNotEmpty) {
        final o = jsonDecode(raw);
        if (o is Map && o['cfg'] is Map) {
          _cfg = Map<String, dynamic>.from(o['cfg']);
          if (o['meta'] is Map) _meta = Map<String, dynamic>.from(o['meta']);
          ready = true;
          _emit();
        }
      }
    } catch (_) {}

    // ② 云端
    try {
      final r = await http
          .post(Uri.parse('${Cloud.base}/rest/v1/rpc/th_config_get'),
              headers: {'apikey': Cloud.anonKey, 'Authorization': 'Bearer ${Cloud.anonKey}', 'Content-Type': 'application/json'},
              body: jsonEncode({'p_keys': null}))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        if (j is Map) {
          final next = <String, dynamic>{};
          final meta = <String, dynamic>{};
          j.forEach((k, cell) {
            if (cell is Map && cell.containsKey('value')) {
              next[k.toString()] = cell['value'];
              meta[k.toString()] = {'version': cell['version'], 'etag': cell['etag'], 'updated_at': cell['updated_at']};
            }
          });
          if (next.isNotEmpty) {
            _cfg = next;
            _meta = meta;
            ready = true;
            _emit();
            try {
              final p = await SharedPreferences.getInstance();
              await p.setString(_cacheKey, jsonEncode({'cfg': _cfg, 'meta': _meta, 'at': DateTime.now().millisecondsSinceEpoch}));
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // 断网 / DNS / 超时 —— 全部静默，用缓存或默认值
    } finally {
      ready = true;
    }
  }

  static void _emit() {
    // 轻量广播：需要感知配置变化的页面自己 listen（避免引入额外的状态管理）
    for (final fn in List<void Function()>.from(_listeners)) {
      try { fn(); } catch (_) {}
    }
  }

  static final List<void Function()> _listeners = <void Function()>[];
  static void onChange(void Function() fn) => _listeners.add(fn);
  static void offChange(void Function() fn) => _listeners.remove(fn);
}
