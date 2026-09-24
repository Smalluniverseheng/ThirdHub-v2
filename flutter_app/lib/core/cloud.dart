// ThirdHub 云端: Supabase 账号体系 + 设备配对 + 更新清单
// 前后端共用同一账号: 登录后互发密钥, 免填地址自动连接
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// 参与同步的设置键（与网页端 js/store.js 的 DEFAULT_SETTINGS 逐字一致，共 38 个）
  static const List<String> settingKeys = <String>[
    'theme', 'lang', 'readerFontSize', 'readerLineHeight', 'readerTheme', 'readerFlip',
    'comicMode', 'comicDir', 'proxyMode', 'proxyUrl', 'ttsRate',
    'ttsEngine', 'ttsCustomUrl', 'asrEngine', 'asrCustomUrl',
    'readerFont', 'readerFontWeight', 'readerPadding', 'readerParaGap', 'readerTextColor',
    'readerBgColor', 'readerBrightness', 'readerFullscreen', 'readerVolumeFlip', 'readerAutoScroll',
    'readerIllust', 'readerTapFlip', 'readerInfoBar',
    'comicLayout', 'comicFit', 'comicGap', 'comicBrightness', 'comicCropBorder', 'comicPreload',
    'navDesktop', 'navMobile', 'navWatch', 'aiDrawerSide',
  ];

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
  // 行形状：{ id: <uid>, data: { settings: { s: {...} }, updatedAt } }

  /// 把本机设置推上云。返回是否成功。本机一个设置都没有时不发（避免用空对象盖掉云端的）。
  static Future<bool> settingsUp() async {
    if (!loggedIn) return false;
    try {
      final p = await SharedPreferences.getInstance();
      final s = <String, dynamic>{};
      for (final k in settingKeys) {
        final v = p.get('setting:$k') ?? p.get(k);
        if (v != null) s[k] = v;
      }
      if (s.isEmpty) return false;
      final now = DateTime.now().toUtc().toIso8601String();
      final r = await http.post(Uri.parse('$base/rest/v1/th_settings'),
        headers: {..._authHeaders, 'Prefer': 'resolution=merge-duplicates,return=minimal'},
        body: jsonEncode({
          'id': userId, 'user_id': userId,
          'data': {'settings': {'s': s}, 'updatedAt': now},
          'updated_at': now,
        }));
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) { return false; }
  }

  /// 从云端拉设置并写回本机，返回写入的键数（0 = 云端没有或读取失败）。
  /// 只写双方共识的键 —— 云端多出来的键一律忽略，不猜、不覆盖本机独有项。
  static Future<int> settingsDown() async {
    if (!loggedIn) return 0;
    try {
      final r = await http.get(Uri.parse('$base/rest/v1/th_settings?id=eq.$userId&select=data,updated_at'),
        headers: _authHeaders);
      if (r.statusCode != 200) return 0;
      final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
      if (list.isEmpty) return 0;
      final data = list.first['data'];
      if (data is! Map) return 0;
      final settings = data['settings'];
      if (settings is! Map) return 0;
      final s = settings['s'];
      if (s is! Map) return 0;
      final p = await SharedPreferences.getInstance();
      var n = 0;
      for (final k in settingKeys) {
        if (!s.containsKey(k)) continue;
        final v = s[k];
        if (v is bool) { await p.setBool('setting:$k', v); n++; }
        else if (v is int) { await p.setInt('setting:$k', v); n++; }
        else if (v is double) { await p.setDouble('setting:$k', v); n++; }
        else if (v is String) { await p.setString('setting:$k', v); n++; }
      }
      return n;
    } catch (_) { return 0; }
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
  // 返回 (上行成功表数, 下行设置键数)；纯统计，不抛异常。
  static Future<Map<String, int>> syncAll({bool push = true}) async {
    var up = 0, keys = 0;
    if (!loggedIn) return {'up': 0, 'keys': 0};
    if (push) { if (await settingsUp()) up++; }
    keys = await settingsDown();
    return {'up': up, 'keys': keys};
  }
}
