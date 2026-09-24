// ThirdHub 云端: Supabase 账号体系 + 设备配对 + 更新清单
// 前后端共用同一账号: 登录后互发密钥, 免填地址自动连接
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_bridge.dart';

class Cloud {
  static const String base = 'https://mxvxlgjzeboktufumxbp.supabase.co';
  static const String anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im14dnhsZ2p6ZWJva3R1ZnVteGJwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzODM5OTcsImV4cCI6MjA5OTk1OTk5N30.QjSLfYAFhwX72YSeAcbTN5O2_PDLaNcv76HhdGJsqpo';

  static String accessToken = '';
  static String refreshToken = '';
  static String userId = '';
  static String email = '';
  static Map<String, dynamic> profileData = {};
  static bool get loggedIn => accessToken.isNotEmpty;

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    accessToken = p.getString('cloud_token') ?? '';
    refreshToken = p.getString('cloud_refresh') ?? '';
    userId = p.getString('cloud_uid') ?? '';
    email = p.getString('cloud_email') ?? '';
    if (loggedIn) {
      try { await profile(); } catch (_) {}
      if (refreshToken.isNotEmpty) { try { await refresh(); } catch (_) {} }
    }
  }

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('cloud_token', accessToken);
    await p.setString('cloud_refresh', refreshToken);
    await p.setString('cloud_uid', userId);
    await p.setString('cloud_email', email);
  }

  static Map<String, String> get _authHeaders => {
    'apikey': anonKey, 'Content-Type': 'application/json',
    if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
  };

  static Future<void> signIn(String mail, String password) async {
    final r = await http.post(Uri.parse('$base/auth/v1/token?grant_type=password'),
      headers: _authHeaders, body: jsonEncode({'email': mail, 'password': password}));
    final j = jsonDecode(r.body);
    if (r.statusCode != 200) throw Exception(j['error_description'] ?? j['msg'] ?? '登录失败');
    accessToken = j['access_token'] ?? ''; refreshToken = j['refresh_token'] ?? '';
    userId = j['user']?['id'] ?? ''; email = j['user']?['email'] ?? mail;
    await _save(); await profile();
  }

  static Future<void> signUp(String mail, String password) async {
    final r = await http.post(Uri.parse('$base/auth/v1/signup'),
      headers: _authHeaders, body: jsonEncode({'email': mail, 'password': password}));
    final j = jsonDecode(r.body);
    if (r.statusCode != 200) throw Exception(j['error_description'] ?? j['msg'] ?? '注册失败');
    if (j['access_token'] != null) {
      accessToken = j['access_token']; refreshToken = j['refresh_token'] ?? '';
      userId = j['user']?['id'] ?? ''; email = j['user']?['email'] ?? mail;
      await _save();
    } else {
      await signIn(mail, password);
    }
  }

  static Future<void> refresh() async {
    final r = await http.post(Uri.parse('$base/auth/v1/token?grant_type=refresh_token'),
      headers: _authHeaders, body: jsonEncode({'refresh_token': refreshToken}));
    if (r.statusCode == 200) {
      final j = jsonDecode(r.body);
      accessToken = j['access_token'] ?? accessToken;
      refreshToken = j['refresh_token'] ?? refreshToken;
      await _save();
    }
  }

  static Future<void> signOut() async {
    accessToken = ''; refreshToken = ''; userId = ''; email = ''; profileData = {};
    await _save();
  }

  static Future<Map<String, dynamic>> profile() async {
    if (!loggedIn) return {};
    // ★ 必须是 th_profiles，不是 profiles。
    // 库里同时存在两张表：profiles 是旧 OmniHub 时代的遗留（字段是 token_quota/balance/
    // agent_code 那套），th_profiles 才是网页端当前在读写的那张（nickname/avatar/level/
    // uid12/handle）。此前这里读的是旧表 → 用户在网页端改了昵称/头像，手机上看不到，
    // 就是「两端资料不同步」的直接原因。
    final r = await http.get(Uri.parse('$base/rest/v1/th_profiles?id=eq.$userId&select=*'), headers: _authHeaders);
    if (r.statusCode == 200) {
      final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
      if (list.isNotEmpty) { profileData = Map<String, dynamic>.from(list.first); return profileData; }
    }
    return {};
  }

  static Future<void> updateProfile(Map<String, dynamic> fields) async {
    if (!loggedIn) return;
    // 同上：写 th_profiles，网页端读的就是这张。
    await http.post(Uri.parse('$base/rest/v1/th_profiles'),
      headers: {..._authHeaders, 'Prefer': 'resolution=merge-duplicates,return=minimal'},
      body: jsonEncode({'id': userId, ...fields}));
    await profile();
  }

  // 设备配对: 后端注册(地址+密钥), 前端拉取后自动连接
  static Future<List<dynamic>> devices() async {
    if (!loggedIn) return [];
    final r = await http.get(Uri.parse('$base/rest/v1/th_devices?user_id=eq.$userId&select=*'), headers: _authHeaders);
    if (r.statusCode == 200) return jsonDecode(r.body) as List;
    return [];
  }

  // 更新清单(公共桶)
  static Future<Map<String, dynamic>?> latestManifest(String channel) async {
    try {
      final r = await http.get(Uri.parse('$base/storage/v1/object/public/downloads/thirdhub/latest-$channel.json'));
      if (r.statusCode == 200) return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {}
    return null;
  }

  // ── 多前端数据共享(th_shared): 每用户/每类/每名单行, last-write-wins ──
  static Future<void> syncUp(String kind, String name, Map<String, dynamic> payload) async {
    if (!loggedIn) return;
    try {
      await http.post(Uri.parse('$base/rest/v1/th_shared'),
        headers: {..._authHeaders, 'Prefer': 'resolution=merge-duplicates,return=minimal'},
        body: jsonEncode({'user_id': userId, 'kind': kind, 'name': name,
          'payload': payload, 'updated_at': DateTime.now().toUtc().toIso8601String()}));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> syncDown(String kind) async {
    if (!loggedIn) return [];
    try {
      final r = await http.get(Uri.parse('$base/rest/v1/th_shared?user_id=eq.$userId&kind=eq.$kind&select=name,payload,updated_at'),
        headers: _authHeaders);
      if (r.statusCode == 200) {
        return [for (final e in jsonDecode(utf8.decode(r.bodyBytes)) as List) Map<String, dynamic>.from(e)];
      }
    } catch (_) {}
    return [];
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 与网页端互通的数据同步层
  //
  // 契约来源（改这里必须同步改网页端，反之亦然 —— 两端读写同一批表、同一套键名，
  // 这就是「软件 ↔ 网页」数据互通的全部依据）：
  //   · 表清单   ← 网页端 js/supabase.js 的 SYNC_TABLES
  //   · 设置键名 ← 网页端 js/store.js 的 DEFAULT_SETTINGS
  //   · 载荷格式 ← {user_id, id, data, updated_at}（网页端 syncPush 同款）
  //
  // 此前客户端只有 th_shared 一张自用表（kind/name 键值），网页端读的是上面这 6 张，
  // 两张网各说各话 → 网页上改设置、手机上不变，就是「跟网站的同步没做好」的根因。
  // ══════════════════════════════════════════════════════════════════════════

  /// 可同步的表（与网页端 js/supabase.js 的 SYNC_TABLES 逐字一致）
  static const List<String> syncTables = <String>[
    'th_bookshelf', 'th_reading_progress', 'th_history', 'th_favorites', 'th_settings', 'th_user_devices',
  ];

  /// 云端设置键清单（与网页端 js/store.js 的 DEFAULT_SETTINGS 逐字一致，共 38 个）。
  ///
  /// ★ 但**不能拿这些名字去读本机 prefs**：本机的键名与它们几乎完全不同
  ///   （本机是 fontSize / theme_mode / flip_mode …，唯一同名键 readerTheme 还是
  ///   int↔String 不同型）。按云端键名直读本机 → 全部取空 → 上行静默不发，
  ///   表现就是「同步点了没反应」。取值一律走 `SettingsBridge`。
  static List<String> get settingKeys => SettingsBridge.cloudKeys;

  /// 上次成功同步时刻（epoch ms）。
  /// ★ 与网页端同一判据（js/modules/settings-sync.js 的 `settings:syncedAt`）——
  ///   两端靠它判断"云端新还是本机新"，不要另发明一套冲突策略。
  static const String _syncedAtKey = 'settings_synced_at';

  /// 通用：按表写一行（载荷与网页端 syncPush 同构）
  static Future<bool> tableUp(String table, String id, Object data) async {
    if (!loggedIn || !syncTables.contains(table)) return false;
    try {
      final r = await http.post(Uri.parse('$base/rest/v1/$table'),
        headers: {..._authHeaders, 'Prefer': 'resolution=merge-duplicates,return=minimal'},
        body: jsonEncode({
          'user_id': userId, 'id': id, 'data': data,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }));
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) { return false; }
  }

  /// 通用：按表读回本用户的全部行
  static Future<List<Map<String, dynamic>>> tableDown(String table) async {
    if (!loggedIn || !syncTables.contains(table)) return [];
    try {
      final r = await http.get(Uri.parse('$base/rest/v1/$table?user_id=eq.$userId&select=*'), headers: _authHeaders);
      if (r.statusCode == 200) {
        return [for (final e in jsonDecode(utf8.decode(r.bodyBytes)) as List) Map<String, dynamic>.from(e)];
      }
    } catch (_) {}
    return [];
  }

  // ── 设置互通（表 th_settings，格式与网页端 settings-sync.js 完全一致）──
  // 行形状：{ id: <uid>, data: { settings: { s: {...}, kv: {...} }, updatedAt } }
  //
  // ★三条纪律（照网页端 js/modules/settings-sync.js 抄，别自己发明）：
  //   ① **只写共识键**：本机没有这个值时就不写 —— 否则等于拿默认值盖掉用户云端已有的设置。
  //   ② **合并写入，绝不整体覆盖**：网页端有 38 个键，本机只映射得上 13 个；
  //      整体覆盖会把用户在网页上设的另外 25 个键连同 kv 一起抹掉。
  //   ③ **冲突判据 = data.updatedAt（epoch ms）对比本机 _syncedAtKey**；
  //      云端较新 → 拉下来；本机较新 → 推上去；相等 → 什么都不做。
  //  （注：库里 version 列恒为 1、从不自增，所以"带版本号防冲突"实际等于 LWW by updatedAt。）

  /// 读回云端设置行（未登录 / 无行 → null）
  static Future<Map<String, dynamic>?> _settingsRow() async {
    if (!loggedIn) return null;
    try {
      final r = await http.get(
        Uri.parse('$base/rest/v1/th_settings?user_id=eq.$userId&select=data,updated_at'),
        headers: _authHeaders);
      if (r.statusCode != 200) return null;
      final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
      if (list.isEmpty) return null;
      return Map<String, dynamic>.from(list.first);
    } catch (_) { return null; }
  }

  /// 本机 prefs 全量快照（键名原样，不做任何假设 —— 转换交给 SettingsBridge）
  static Future<Map<String, dynamic>> _localSnapshot() async {
    final p = await SharedPreferences.getInstance();
    return {for (final k in p.getKeys()) k: p.get(k)};
  }

  static int _cloudUpdatedAt(Map<String, dynamic>? row) {
    final d = row == null ? null : row['data'];
    if (d is! Map) return 0;
    final v = d['updatedAt'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// 把本机设置推上云（**合并**写入，绝不丢云端已有键）。成功返回 true。
  static Future<bool> settingsUp() async {
    if (!loggedIn) return false;
    try {
      final mine = SettingsBridge.toCloud(await _localSnapshot());
      if (mine.isEmpty) return false; // 本机一个可映射设置都没有 → 不拿空对象去盖云端

      // ① 读回云端现状，做真合并
      final row = await _settingsRow();
      final cloudS = <String, dynamic>{};
      final cloudKv = <String, dynamic>{};
      final d = row == null ? null : row['data'];
      if (d is Map) {
        final st = d['settings'];
        if (st is Map) {
          final s = st['s']; if (s is Map) cloudS.addAll(Map<String, dynamic>.from(s));
          final kv = st['kv']; if (kv is Map) cloudKv.addAll(Map<String, dynamic>.from(kv));
        }
      }
      cloudS.addAll(mine); // 认识的键以本机为准；不认识的键原样留在云端

      final now = DateTime.now().millisecondsSinceEpoch;
      final r = await http.post(Uri.parse('$base/rest/v1/th_settings'),
        headers: {..._authHeaders, 'Prefer': 'resolution=merge-duplicates,return=minimal'},
        body: jsonEncode({
          'id': userId, 'user_id': userId,
          'data': {
            'settings': {'s': cloudS, if (cloudKv.isNotEmpty) 'kv': cloudKv},
            'updatedAt': now,
          },
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }));
      if (r.statusCode >= 200 && r.statusCode < 300) {
        final p = await SharedPreferences.getInstance();
        await p.setInt(_syncedAtKey, now);
        return true;
      }
      return false;
    } catch (_) { return false; }
  }

  /// 从云端拉设置写回本机，返回写入的键数（0 = 云端没有或读取失败）。
  /// 只写双方共识的键 —— 云端多出来的 25 个键与 kv **一律忽略**，不猜、不覆盖本机独有项。
  static Future<int> settingsDown() async {
    if (!loggedIn) return 0;
    try {
      final row = await _settingsRow();
      if (row == null) return 0;
      final d = row['data'];
      if (d is! Map) return 0;
      final st = d['settings'];
      if (st is! Map) return 0;
      final s = st['s'];
      if (s is! Map) return 0;

      final items = SettingsBridge.fromCloud(Map<String, dynamic>.from(s));
      final p = await SharedPreferences.getInstance();
      var n = 0;
      for (final e in items) {
        final v = e.value;
        if (v is bool) { await p.setBool(e.key, v); n++; }
        else if (v is int) { await p.setInt(e.key, v); n++; }
        else if (v is double) { await p.setDouble(e.key, v); n++; }
        else if (v is String) { await p.setString(e.key, v); n++; }
      }
      final at = _cloudUpdatedAt(row);
      if (at > 0) await p.setInt(_syncedAtKey, at);
      return n;
    } catch (_) { return 0; }
  }

  /// 上次成功同步时刻（epoch ms，0 = 从未同步）。给界面展示用。
  static Future<int> lastSyncedAt() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_syncedAtKey) ?? 0;
  }

  // ── 阅读进度（表 th_reading_progress）──
  // id 形状与网页端一致：「源id:书id」，如 src-msyei37k2owmfp:1236488

  static Future<bool> progressUp(String bookId, Map<String, dynamic> data) =>
      tableUp('th_reading_progress', bookId, data);

  static Future<Map<String, dynamic>?> progressDown(String bookId) async {
    final rows = await tableDown('th_reading_progress');
    for (final e in rows) {
      if (e['id'] == bookId) {
        final d = e['data'];
        return d is Map ? Map<String, dynamic>.from(d) : null;
      }
    }
    return null;
  }

  // ── 书架 / 收藏 / 历史 ──

  static Future<bool> shelfUp(String bookId, Map<String, dynamic> data) =>
      tableUp('th_bookshelf', bookId, data);
  static Future<List<Map<String, dynamic>>> shelfDown() => tableDown('th_bookshelf');

  static Future<bool> favUp(String id, Map<String, dynamic> data) =>
      tableUp('th_favorites', id, data);
  static Future<List<Map<String, dynamic>>> favDown() => tableDown('th_favorites');

  static Future<bool> historyUp(String id, Map<String, dynamic> data) =>
      tableUp('th_history', id, data);
  static Future<List<Map<String, dynamic>>> historyDown() => tableDown('th_history');

  // ── 一键全量同步（给设置页的「与网页端同步」按钮用）──
  // 按网页端同款判据决定方向，**不是**无条件又推又拉（那是旧的错法：
  // 先推后被自己的拉覆盖、或把本机新改动丢掉）。纯统计，不抛异常。
  // 返回 { 'result': 'pulled'|'pushed'|'same'|'no-user'|'error', 'keys': 拉下来的键数 }
  static Future<Map<String, dynamic>> syncAll() async {
    if (!loggedIn) return {'result': 'no-user', 'keys': 0};
    try {
      final row = await _settingsRow();
      final cloudAt = _cloudUpdatedAt(row);
      final p = await SharedPreferences.getInstance();
      final localAt = p.getInt(_syncedAtKey) ?? 0;

      if (row == null || cloudAt == 0) {
        // 云端还没有这一行（首次同步）→ 以本机为准推上去
        return {'result': (await settingsUp()) ? 'pushed' : 'error', 'keys': 0};
      }
      if (cloudAt > localAt) return {'result': 'pulled', 'keys': await settingsDown()};
      if (localAt > cloudAt) return {'result': (await settingsUp()) ? 'pushed' : 'error', 'keys': 0};
      return {'result': 'same', 'keys': 0};
    } catch (_) { return {'result': 'error', 'keys': 0}; }
  }
}
