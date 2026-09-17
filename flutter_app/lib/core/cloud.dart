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
    final r = await http.get(Uri.parse('$base/rest/v1/profiles?id=eq.$userId&select=*'), headers: _authHeaders);
    if (r.statusCode == 200) {
      final list = jsonDecode(r.body) as List;
      if (list.isNotEmpty) { profileData = Map<String, dynamic>.from(list.first); return profileData; }
    }
    return {};
  }

  static Future<void> updateProfile(Map<String, dynamic> fields) async {
    if (!loggedIn) return;
    await http.post(Uri.parse('$base/rest/v1/profiles'),
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
}
