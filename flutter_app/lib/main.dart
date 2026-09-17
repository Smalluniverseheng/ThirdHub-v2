// ThirdHub v4 Flutter m2: 纯播放器前端 = 小说阅读器 + 漫画播放器 + 视频播放器
// 定位: 零处理逻辑, 只渲染后端IR。净化在插件(Legado)完成, 后端转发。
// 每个板块右上角: [搜索] [设置→连接资源库]
import 'dart:async'; import 'dart:convert';
import 'dart:math'; import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'core/mini_modules.dart';
import 'core/mini_modules2.dart';
import 'core/mini_modules3.dart';
import 'core/mini_modules4.dart';
import 'core/mini_modules5.dart';
import 'core/mini_modules6.dart';
import 'core/mini_modules7.dart';
import 'core/mini_modules8.dart';
import 'core/mini_modules9.dart';
import 'core/mini_modules10.dart';
import 'core/mini_modules11.dart';
import 'core/neu.dart';
import 'package:cryptography/cryptography.dart';
import 'core/cloud.dart';
import 'core/local_import.dart';
import 'core/discover.dart';
import 'core/novel_reader.dart';
import 'core/reader_fonts.dart';
import 'core/i18n.dart';
import 'core/ai.dart';
import 'core/ai_page.dart';
import 'core/browser_page.dart';
import 'core/notify.dart';
import 'core/engine_direct.dart';
import 'core/engine_direct_page.dart';
import 'core/gallery_page.dart';
import 'core/files_page.dart';


// ═══ 打开方式/分享 路由: 外部打开 txt/epub/音频/视频/链接 → 对应模块 ═══
class IntentRouter {
  static final navKey = GlobalKey<NavigatorState>();
  static const _ch = MethodChannel('thirdhub/intent');
  static bool _inited = false;

  static void init() {
    if (_inited) return;
    _inited = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'incoming' && call.arguments is Map) {
        await _route(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    // 冷启动: 取原生侧暂存的启动意图
    Future.delayed(const Duration(seconds: 2), () async {
      try {
        final p = await _ch.invokeMethod('consume');
        if (p is Map) await _route(Map<String, dynamic>.from(p));
      } catch (_) {}
    });
  }

  static Future<String?> _resolveFile(String uri) async {
    try {
      if (uri.startsWith('file://')) return Uri.parse(uri).toFilePath();
      final r = await _ch.invokeMethod('readUri', {'uri': uri});
      if (r is Map) return r['path'] as String?;
    } catch (_) {}
    return null;
  }

  static Future<void> _route(Map<String, dynamic> p) async {
    final nav = navKey.currentState;
    if (nav == null) return;
    final mime = (p['mime'] as String? ?? '').toLowerCase();
    final uri = p['uri'] as String?;
    final text = p['text'] as String?;
    try {
      // 纯文本分享 / 链接
      if (text != null && text.isNotEmpty) {
        final m = RegExp(r'https?://\S+').firstMatch(text);
        if (m != null) { _openBrowser(m.group(0)!); return; }
        await _openTextAsNovel(text, '分享文本');
        return;
      }
      if (uri == null) return;
      final lu = uri.toLowerCase();
      if (lu.startsWith('http://') || lu.startsWith('https://')) { _openBrowser(uri); return; }
      final path = await _resolveFile(uri);
      if (path == null) return;
      final lp = path.toLowerCase();
      final isTxt = mime.startsWith('text/') || lp.endsWith('.txt') || lp.endsWith('.epub') || lp.endsWith('.md') || lp.endsWith('.umd');
      final isAudio = mime.startsWith('audio/') || RegExp(r'\.(mp3|flac|wav|aac|m4a|ogg|wma|ape)$').hasMatch(lp);
      final isVideo = mime.startsWith('video/') || RegExp(r'\.(mp4|mkv|avi|mov|flv|wmv|webm|ts)$').hasMatch(lp);
      if (isTxt) { await _openFileAsNovel(path); return; }
      if (isAudio) {
        await _importTo('music', path);
        nav.push(MaterialPageRoute(builder: (_) => MusicPlayPage(item: {
          'name': path.split('/').last, 'url': path, 'artist': '本地', 'coverUrl': ''})));
        return;
      }
      if (isVideo) {
        await _importTo('video', path);
        nav.push(MaterialPageRoute(builder: (_) => LocalVideoPlayerPage(item: {'name': path.split('/').last, 'path': path})));
        return;
      }
    } catch (_) {}
  }

  static void _openBrowser(String url) {
    final nav = navKey.currentState;
    if (nav == null) return;
    nav.push(MaterialPageRoute(builder: (_) => BrowserPage(initialUrl: url)));
  }

  static Future<void> _importTo(String kind, String path) async {
    try {
      final items = await LocalLib.list(kind);
      if (!items.any((e) => e['path'] == path)) {
        items.insert(0, {'name': path.split('/').last.replaceAll(RegExp(r'^\d+_'), ''), 'path': path});
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('local_$kind', jsonEncode(items));
      }
    } catch (_) {}
  }

  static Future<void> _openFileAsNovel(String path) async {
    final nav = navKey.currentState;
    if (nav == null) return;
    final lp = path.toLowerCase();
    String usePath = path;
    if (lp.endsWith('.epub')) {
      // epub → 纯文本缓存
      try {
        final bytes = await File(path).readAsBytes();
        final txt = LocalLib.epubToText(bytes);
        final out = File('${path}_txt.txt');
        await out.writeAsString(txt);
        usePath = out.path;
      } catch (_) {}
    }
    await _importTo('novel', usePath);
    final name = usePath.split('/').last.replaceAll(RegExp(r'^\d+_'), '').replaceAll(RegExp(r'\.(txt|md|umd|epub)$', caseSensitive: false), '');
    nav.push(MaterialPageRoute(builder: (_) => LocalNovelReader(book: {'name': name, 'path': usePath, 'format': 'txt'})));
  }

  static Future<void> _openTextAsNovel(String text, String name) async {
    final nav = navKey.currentState;
    if (nav == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/local_novel/${DateTime.now().millisecondsSinceEpoch}_$name.txt');
      await f.create(recursive: true);
      await f.writeAsString(text);
      await _importTo('novel', f.path);
      nav.push(MaterialPageRoute(builder: (_) => LocalNovelReader(book: {'name': name, 'path': f.path, 'format': 'txt'})));
    } catch (_) {}
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.init();
  // 加载式开屏: 仅展示初始化过程, 完成即被替换, 不固定占用时长; 关闭动画则白屏加载
  IntentRouter.init();
  runApp(SplashApp(anim: AppSettings.splashAnim));
  await Cloud.init();
  unawaited(AiRegistry.init());
  unawaited(EngineDirect.init());
  // 通知栏音乐控制(锁屏/通知栏播放键)
  try { await JustAudioBackground.init(androidNotificationChannelId: 'com.thirdhub.app.audio',
    androidNotificationChannelName: '音乐播放', androidNotificationOngoing: true); } catch (_) {}
  unawaited(Notify.init());
  unawaited(Notify.checkAnnouncements());
  final prefs = await SharedPreferences.getInstance();
  final pin = prefs.getString('app_pin') ?? '';
  final onboarded = prefs.getBool('first_run') ?? false;
  runApp(ThApp(ready: (prefs.getString('base') ?? '').isNotEmpty,
    base: prefs.getString('base') ?? '', token: prefs.getString('token') ?? '', locked: pin.isNotEmpty, fresh: !onboarded));
}

class Api {
  static String base = ''; static String token = '';
  static http.Client client() { final c = HttpClient()..badCertificateCallback = (_, __, ___) => true; return IOClient(c); }
  static Future<Map<String, dynamic>> get(String path) async {
    final r = await client().get(Uri.parse('$base$path'), headers: {'X-TH-Token': token});
    return jsonDecode(utf8.decode(r.bodyBytes)); }
  static String img(String u) => '$base/v1/img?url=${Uri.encodeComponent(u)}';
  // AES-256-GCM 加密POST(密钥=sha256(token), 头 X-TH-Enc: aes-gcm, body=base64(nonce‖cipher‖tag))
  static Future<Map<String, dynamic>> postEncrypted(String path, Map<String, dynamic> body) async {
    final alg = AesGcm.with256bits();
    final key = await Sha256().hash(utf8.encode(token));
    final nonce = alg.newNonce();
    final box = await alg.encrypt(utf8.encode(jsonEncode(body)), secretKey: SecretKey(key.bytes), nonce: nonce);
    final payload = base64Encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
    final r = await client().post(Uri.parse('$base$path'),
      headers: {'X-TH-Token': token, 'X-TH-Enc': 'aes-gcm', 'Content-Type': 'text/plain'}, body: payload);
    return jsonDecode(utf8.decode(r.bodyBytes));
  }
}

// 全局设置中心: 所有前端设置唯一入口, 本地存储+云端同步(1MB配额)骨架
class AppSettings {
  static SharedPreferences? _p;
  static void Function()? onChanged; // 主题变更回调
  static Future<void> init() async { _p = await SharedPreferences.getInstance();
    I18n.instance.locale = I18n.resolve(p.getString('locale') ?? 'system'); }
  // 身份码: 登录 ThirdHub 账号后才生成(与云端账号绑定)
  static Future<String> ensureIdentity() async {
    var code = p.getString('identity_code');
    if (code == null && Cloud.loggedIn) {
      code = 'TH-' + Cloud.userId.replaceAll('-', '').substring(0, 8).toUpperCase()
        + '-' + DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase();
      await p.setString('identity_code', code);
    }
    return code ?? '';
  }
  static SharedPreferences get p => _p!;

  // ── 计量: 1MB配额, 头像<0.5MB, 其余给设置 ──
  static double get cloudQuotaKB => 1024.0;
  static double get localUsageKB {
    double u = 0;
    for (final k in ['avatar_b64', 'nickname', 'fontSize', 'readerTheme', 'pageMode']) {
      final v = p.get(k); if (v is String) u += v.length / 1024;
    }
    return u;
  }

  // ── 语言(完全体: 调整语言全前端立即生效) ──
  static String get locale => p.getString('locale') ?? 'system'; // system=跟随系统
  static Future<void> setLocale(String v) async {
    await p.setString('locale', v); await I18n.instance.setLocale(I18n.resolve(v)); await sync();
  }
  // ── 外观(网页版"我的"-主题外观) ──
  static String get themeModeStr => p.getString('theme_mode') ?? 'system'; // system|dark|light 默认跟随系统
  static int get accentColor => p.getInt('accent_color') ?? 0xFF3B5BFD;   // 强调色(网页端蓝)
  static bool get splashAnim => p.getBool('splash_anim') ?? true;         // 开屏动画
  static Future<void> setThemeMode(String v) async { await p.setString('theme_mode', v); await sync(); onChanged?.call(); }
  static Future<void> setAccent(int v) async { await p.setInt('accent_color', v); await sync(); onChanged?.call(); }
  static Future<void> setSplashAnim(bool v) async { await p.setBool('splash_anim', v); await sync(); }

  // ── 导航(网页版-手表端导航栏位置) ──
  static String get navSide => p.getString('nav_side') ?? 'right'; // left|right(悬浮球默认吸附侧)
  static Future<void> setNavSide(String v) async { await p.setString('nav_side', v); await sync(); }
  // 导航形态: bar=底部导航栏 | orb=悬浮球 | fold=折叠(细条,点按展开)
  static String get navStyle => p.getString('nav_style') ?? 'bar';
  static Future<void> setNavStyle(String v) async { await p.setString('nav_style', v); await sync(); }
  // 悬浮球: 吸附边缘(开=自动吸边, 关=自由拖动停哪放哪)
  static bool get orbSnap => p.getBool('orb_snap') ?? true;
  static Future<void> setOrbSnap(bool v) async { await p.setBool('orb_snap', v); await sync(); }
  // 底部导航栏: 向下滚动自动收起(去文字, 高度缩1/3), 向上滚动展开(网页端 nav-folded 同款)
  static bool get navAutoHide => p.getBool('nav_autohide') ?? true;
  static Future<void> setNavAutoHide(bool v) async { await p.setBool('nav_autohide', v); await sync(); }
  static Offset get orbPos {
    final x = p.getDouble('orb_x'), y = p.getDouble('orb_y');
    return (x != null && y != null) ? Offset(x, y) : const Offset(-1, -1);
  }
  static Future<void> setOrbPos(Offset o) async { await p.setDouble('orb_x', o.dx); await p.setDouble('orb_y', o.dy); }

  // ── 资料(网页版-个人资料) ──
  static String get bio => p.getString('bio') ?? '';
  static String get identityCode => p.getString('identity_code') ?? ''; // 身份码(好友系统)
  static Future<void> setBio(String v) async { await p.setString('bio', v); await sync(); }

  // ── 阅读偏好(仿番茄小说: 字号/字体/颜色/背景/翻页/间距/护眼) ──
  static double get fontSize => p.getDouble('fontSize') ?? 18.0;
  static int get readerTheme => p.getInt('readerTheme') ?? 0;
  static String get pageMode => p.getString('pageMode') ?? 'scroll'; // scroll|paged
  static String get readerFont => p.getString('reader_font') ?? 'default';
  static int get readerBg => p.getInt('reader_bg') ?? 1;            // 背景预设index
  static int get readerTextColor => p.getInt('reader_text') ?? 0xFF4A3F30;
  static double get lineHeight => p.getDouble('line_height') ?? 1.8;
  static double get paraSpace => p.getDouble('para_space') ?? 8.0;  // 段间距
  static double get readerMargin => p.getDouble('reader_margin') ?? 16.0; // 页边距
  static String get flipMode => p.getString('flip_mode') ?? 'slide'; // sim仿真|cover覆盖|slide平移|vertical上下|none无动画
  static bool get eyeCare => p.getBool('eye_care') ?? false;

  static Future<void> setFontSize(double v) async { await p.setDouble('fontSize', v); await sync(); }
  static Future<void> setReaderTheme(int v) async { await p.setInt('readerTheme', v); await sync(); }
  static Future<void> setPageMode(String v) async { await p.setString('pageMode', v); await sync(); }
  static Future<void> setReaderFont(String v) async { await p.setString('reader_font', v); await sync(); }
  static Future<void> setReaderBg(int v) async { await p.setInt('reader_bg', v); await sync(); }
  static Future<void> setReaderTextColor(int v) async { await p.setInt('reader_text', v); await sync(); }
  static Future<void> setLineHeight(double v) async { await p.setDouble('line_height', v); await sync(); }
  static Future<void> setParaSpace(double v) async { await p.setDouble('para_space', v); await sync(); }
  static Future<void> setReaderMargin(double v) async { await p.setDouble('reader_margin', v); await sync(); }
  static Future<void> setFlipMode(String v) async { await p.setString('flip_mode', v); await sync(); }
  static Future<void> setEyeCare(bool v) async { await p.setBool('eye_care', v); await sync(); }

  // ── 传输加密(默认不加密, aes-gcm可选) ──
  static String get encMode => p.getString('enc_mode') ?? 'none';
  static Future<void> setEncMode(String v) async { await p.setString('enc_mode', v); await sync(); }

  // ── 账号 ──
  static String get nickname => p.getString('nickname') ?? '';
  static String get avatarB64 => p.getString('avatar_b64') ?? '';
  static Future<void> setAvatar(String b64) async {
    // 压缩保证 < 0.5MB (调用前已压缩到~30KB, 这里兜底检查)
    if (b64.length > 700 * 1024) throw Exception('头像超过0.5MB限制');
    await p.setString('avatar_b64', b64); await sync();
  }

  // ── 云端同步骨架: 目前本地优先, 同步写后端(二期加CF账号后自动生效) ──
  static bool syncEnabled = true;
  static Future<void> sync() async {
    if (!syncEnabled || Api.base.isEmpty) return;
    try {
      if (encMode == 'aes-gcm') {
        await Api.postEncrypted('/v1/settings', { 'data': {
          'nickname': nickname, 'fontSize': fontSize, 'readerTheme': readerTheme,
          'pageMode': pageMode, 'avatar_b64': avatarB64, '_usageKB': localUsageKB, '_at': DateTime.now().toIso8601String() }});
        return;
      }
      await http.post(Uri.parse('${Api.base}/v1/settings'),
        headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
        body: jsonEncode({ 'data': {
          'nickname': nickname, 'fontSize': fontSize, 'readerTheme': readerTheme,
          'pageMode': pageMode, 'avatar_b64': avatarB64, '_usageKB': localUsageKB, '_at': DateTime.now().toIso8601String() }}));
    } catch (_) {}
  }
  // 加载: 优先后端(同步设置)
  static Future<void> loadFromBackend() async {
    if (Api.base.isEmpty) return;
    try { final r = await Api.get('/v1/settings'); final d = r['data'] ?? {};
      if (d['fontSize'] != null) await p.setDouble('fontSize', (d['fontSize'] as num).toDouble());
      if (d['readerTheme'] != null) await p.setInt('readerTheme', d['readerTheme']);
      if (d['pageMode'] != null) await p.setString('pageMode', d['pageMode']);
      if (d['nickname'] != null) await p.setString('nickname', d['nickname']);
      if (d['avatar_b64'] != null && d['avatar_b64'] != avatarB64) await p.setString('avatar_b64', d['avatar_b64']);
    } catch (_) {}
  }
}

class Book {
  final String name, author, coverUrl, intro, bookUrl, sourceId;
  Book(this.name, this.author, this.coverUrl, this.intro, this.bookUrl, this.sourceId);
  factory Book.from(Map<String, dynamic> j) => Book(j['name'] ?? '', j['author'] ?? '', j['coverUrl'] ?? '', j['intro'] ?? '', j['bookUrl'] ?? '', j['sourceId'] ?? '');
  Map<String, dynamic> toJson() => {'name': name, 'author': author, 'coverUrl': coverUrl, 'intro': intro, 'bookUrl': bookUrl, 'sourceId': sourceId};
  static Future<List<Book>> shelf(String kind) async {
    final p = await SharedPreferences.getInstance();
    try { return (jsonDecode(p.getString('shelf_$kind') ?? '[]') as List).map((e) => Book.from(e)).toList(); } catch (_) { return []; } }
  // 阅读历史(最近打开的书, 新→旧)
  static Future<void> recordHistory(Book b, String kind) async {
    final p = await SharedPreferences.getInstance();
    List l = [];
    try { l = jsonDecode(p.getString('history_$kind') ?? '[]') as List; } catch (_) {}
    l.removeWhere((x) => x['bookUrl'] == b.bookUrl);
    l.insert(0, {...b.toJson(), '_at': DateTime.now().toString().substring(0, 16)});
    await p.setString('history_$kind', jsonEncode(l.take(50).toList()));
  }
  static Future<List<Book>> history(String kind) async {
    final p = await SharedPreferences.getInstance();
    try { return (jsonDecode(p.getString('history_$kind') ?? '[]') as List).map((e) => Book.from(e)).toList(); } catch (_) { return []; } }
  // target: local=只存本机 · backend=只下载到后端资源库 · both=都下
  static Future<void> add(Book b, String kind, {String target = 'both'}) async {
    if (target == 'local' || target == 'both') {
      final p = await SharedPreferences.getInstance(); final l = await shelf(kind);
      if (!l.any((x) => x.bookUrl == b.bookUrl)) {
        l.add(b); await p.setString('shelf_$kind', jsonEncode(l.map((e) => e.toJson()).toList()));
      }
    }
    // 后端下载: 通知资源库把这份资源收进去(多前端共享, 换设备不丢)
    if ((target == 'backend' || target == 'both') && Api.base.isNotEmpty) {
      try { await http.post(Uri.parse('${Api.base}/v1/shelf/add'),
        headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
        body: jsonEncode({'kind': kind, 'book': b.toJson()})); } catch (_) {}
    }
  }
}

// ═══ 回收站(本地): 书架/歌单/安装包删除后先进这里, 可恢复或彻底删除 ═══
class Trash {
  static const key = 'recycle_bin';
  static Future<List<Map<String, dynamic>>> list() async {
    final p = await SharedPreferences.getInstance();
    try { return (jsonDecode(p.getString(key) ?? '[]') as List).map((e) => Map<String, dynamic>.from(e)).toList(); }
    catch (_) { return []; }
  }
  static Future<void> _save(List<Map<String, dynamic>> l) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(l));
  }
  static Future<void> add(String kind, String title, Map<String, dynamic> payload) async {
    final l = await list();
    l.insert(0, {'id': DateTime.now().millisecondsSinceEpoch.toString(), 'kind': kind, 'title': title,
      'payload': payload, 'at': DateTime.now().toString().substring(0, 16)});
    await _save(l.take(200).toList());
  }
  static Future<void> remove(String id) async { final l = await list(); l.removeWhere((e) => e['id'] == id); await _save(l); }
  static Future<void> clear() async { final p = await SharedPreferences.getInstance(); await p.remove(key); }
}

class RecycleBinPage extends StatefulWidget { const RecycleBinPage({super.key}); @override State<RecycleBinPage> createState() => _Rb(); }
class _Rb extends State<RecycleBinPage> {
  List<Map<String, dynamic>> items = []; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await Trash.list(); if (mounted) setState(() => loading = false); }
  IconData _icon(String k) => k == 'apk' ? Icons.android : k == 'music' ? Icons.music_note : k == 'shelf' ? Icons.auto_stories_outlined : Icons.delete_outline;
  String _kindName(String k) => k == 'apk' ? '安装包' : k == 'music' ? '音乐' : k == 'shelf' ? '书架' : k;
  Future<void> _restore(Map<String, dynamic> it) async {
    final kind = it['kind'] as String? ?? '';
    final payload = Map<String, dynamic>.from(it['payload'] ?? {});
    try {
      if (kind == 'shelf') {
        await Book.add(Book.from(Map<String, dynamic>.from(payload['book'] ?? {})), payload['kind'] ?? 'novel', target: 'local');
      } else if (kind == 'music') {
        final p = await SharedPreferences.getInstance();
        final l = (jsonDecode(p.getString('playlist') ?? '[]') as List).cast<Map>();
        final m = Map<String, dynamic>.from(payload['item'] ?? {});
        if (m.isNotEmpty && !l.any((x) => x['id'] == m['id'] && m['id'] != null)) { l.add(m); await p.setString('playlist', jsonEncode(l)); }
      } else if (kind == 'apk') {
        final src = File(payload['path'] ?? '');
        if (await src.exists()) {
          final dir = await Updater._updateDir();
          final name = (payload['path'] as String).split('/').last;
          final dst = File('$dir/$name');
          await src.rename(dst.path);
          final p = await SharedPreferences.getInstance();
          final l = p.getStringList('update_apks') ?? [];
          l.add('${dst.path}|${payload['name'] ?? '安装包'}|${payload['date'] ?? ''}');
          await p.setStringList('update_apks', l);
        }
      }
      await Trash.remove(it['id']);
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已恢复'))); _load(); }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('恢复失败: $e'))); }
  }
  Future<void> _destroy(Map<String, dynamic> it) async {
    if (it['kind'] == 'apk') { try { await File('${it['payload']?['path'] ?? ''}').delete(); } catch (_) {} }
    await Trash.remove(it['id']); _load();
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('回收站'), actions: [
      if (items.isNotEmpty) IconButton(icon: const Icon(Icons.delete_sweep_outlined), tooltip: '清空', onPressed: () async {
        for (final it in items) { if (it['kind'] == 'apk') { try { await File('${it['payload']?['path'] ?? ''}').delete(); } catch (_) {} } }
        await Trash.clear(); _load(); }),
    ]),
    body: loading ? const Center(child: CircularProgressIndicator())
      : items.isEmpty ? const Center(child: Text('回收站为空', style: TextStyle(color: Colors.grey)))
      : ListView(padding: const EdgeInsets.all(12), children: [
        const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('删除的书架/歌单/安装包会先进入回收站, 可恢复或彻底删除', style: TextStyle(fontSize: 11, color: Colors.grey))),
        Card(child: Column(children: [
          for (final it in items) ListTile(dense: true,
            leading: Icon(_icon(it['kind'] ?? ''), size: 20),
            title: Text('${it['title'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Text('${_kindName(it['kind'] ?? '')} · ${it['at'] ?? ''}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.restore, size: 18), tooltip: '恢复', onPressed: () => _restore(it)),
              IconButton(icon: const Icon(Icons.delete_forever_outlined, size: 18, color: Colors.redAccent), tooltip: '彻底删除', onPressed: () => _destroy(it)),
            ])),
        ])),
      ]));
}

// 下载位置三选: 前端本机 / 后端资源库 / 都下
Future<String?> chooseDownloadTarget(BuildContext c) => showDialog<String>(context: c, builder: (c2) => SimpleDialog(
  title: const Text('下载到哪里？'),
  children: [
    SimpleDialogOption(onPressed: () => Navigator.pop(c2, 'local'),
      child: const ListTile(dense: true, leading: Icon(Icons.phone_android), title: Text('下载到本机'), subtitle: Text('只存在这台设备, 不占资源库空间', style: TextStyle(fontSize: 11)))),
    SimpleDialogOption(onPressed: () => Navigator.pop(c2, 'backend'),
      child: const ListTile(dense: true, leading: Icon(Icons.dns_outlined), title: Text('下载到后端资源库'), subtitle: Text('存进资源库, 所有前端设备共享', style: TextStyle(fontSize: 11)))),
    SimpleDialogOption(onPressed: () => Navigator.pop(c2, 'both'),
      child: const ListTile(dense: true, leading: Icon(Icons.sync), title: Text('都下'), subtitle: Text('本机+资源库各存一份', style: TextStyle(fontSize: 11)))),
  ]));


// ── 开屏: 加载用(初始化完成即消失); 动画可在 我的→外观 关闭, 关闭后白屏加载(属正常) ──
class SplashApp extends StatelessWidget {
  final bool anim;
  const SplashApp({super.key, required this.anim});
  @override Widget build(BuildContext c) => MaterialApp(debugShowCheckedModeBanner: false,
    home: anim ? const SplashPage() : const Scaffold(backgroundColor: Colors.white, body: SizedBox.expand()));
}
class SplashPage extends StatefulWidget { const SplashPage({super.key}); @override State<SplashPage> createState() => _Sp(); }
class _Sp extends State<SplashPage> with SingleTickerProviderStateMixin {
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  @override void dispose() { ac.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) {
    const accent = Color(0xFF3B5BFD);
    return Scaffold(backgroundColor: Colors.white, body: SafeArea(child: Column(children: [
      const Spacer(),
      FadeTransition(opacity: CurvedAnimation(parent: ac, curve: Curves.easeOut),
        child: ScaleTransition(scale: Tween<double>(begin: 0.82, end: 1).animate(CurvedAnimation(parent: ac, curve: Curves.easeOutBack)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 84, height: 84, decoration: BoxDecoration(borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accent, Color(0xFF7C6CFF)])),
              child: const Icon(Icons.hub_outlined, color: Colors.white, size: 46)),
            const SizedBox(height: 18),
            const Text('ThirdHub', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Color(0xFF1A1D26), letterSpacing: 0.5)),
            const SizedBox(height: 6),
            const Text('资源 · 引擎 · 互联', style: TextStyle(fontSize: 12, color: Color(0xFF9AA0AE))),
          ]))),
      const SizedBox(height: 40),
      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: accent)),
      const Spacer(),
      const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.lan_outlined, size: 13, color: Color(0xFF9AA0AE)), SizedBox(width: 4),
        Text('支持 IPv6 网络', style: TextStyle(fontSize: 11, color: Color(0xFF9AA0AE))),
        SizedBox(width: 10),
        Text('v4.24.0', style: TextStyle(fontSize: 11, color: Color(0xFF9AA0AE))),
      ]),
      const SizedBox(height: 18),
    ])));
  }
}

// ── 首启协议门: 未同意《用户服务协议》与《隐私政策》前不进入主界面(大厂同款) ──
class ConsentGate extends StatefulWidget {
  final bool locked, fresh;
  const ConsentGate({super.key, required this.locked, required this.fresh});
  @override State<ConsentGate> createState() => _Cg();
}
class _Cg extends State<ConsentGate> {
  late bool agreed = AppSettings.p.getBool('agreed_terms_v1') ?? false;
  @override Widget build(BuildContext c) {
    if (!agreed) return ConsentPage(onAgree: () async {
      await AppSettings.p.setBool('agreed_terms_v1', true);
      if (mounted) setState(() => agreed = true);
    });
    return widget.locked ? const LockScreen() : widget.fresh ? const OnboardingPage() : const RootNav();
  }
}
class ConsentPage extends StatelessWidget {
  final VoidCallback onAgree;
  const ConsentPage({super.key, required this.onAgree});
  @override Widget build(BuildContext c) {
    const accent = Color(0xFF3B5BFD);
    Widget link(String label, String asset, String title) => GestureDetector(
      onTap: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => LegalDocPage(title: title, asset: asset))),
      child: Text(label, style: const TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13.5, height: 1.6)));
    return Scaffold(backgroundColor: const Color(0xFFF6F7FB), body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Card(elevation: 0, color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Padding(padding: const EdgeInsets.fromLTRB(24, 30, 24, 20), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 64, height: 64, decoration: BoxDecoration(borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(colors: [accent, Color(0xFF7C6CFF)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
            child: const Icon(Icons.hub_outlined, color: Colors.white, size: 34)),
          const SizedBox(height: 16),
          const Text('用户协议与隐私政策', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Wrap(alignment: WrapAlignment.center, children: [
            const Text('欢迎使用 ThirdHub！请您仔细阅读并同意 ', style: TextStyle(fontSize: 13.5, height: 1.6)),
            link('《用户服务协议》', 'assets/legal/terms.md', '用户服务协议'),
            const Text(' 与 ', style: TextStyle(fontSize: 13.5, height: 1.6)),
            link('《隐私政策》', 'assets/legal/privacy.md', '隐私政策'),
            const Text('。', style: TextStyle(fontSize: 13.5, height: 1.6)),
          ]),
          const SizedBox(height: 10),
          const Text('ThirdHub 是纯播放器：不收集、不上传您的任何个人信息；AI 密钥等敏感数据仅加密保存在本机。THP 引擎是用户自制的协议插件，与本软件相互独立。',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, height: 1.7, color: Color(0xFF6B7280))),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: onAgree,
            style: FilledButton.styleFrom(backgroundColor: accent, padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('同意并继续', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)))),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: TextButton(onPressed: () => showDialog(context: c, builder: (d) => AlertDialog(
            title: const Text('不同意并退出'),
            content: const Text('若您不同意本协议与隐私政策，很遗憾将无法继续使用 ThirdHub。您可以在同意后随时回来。'),
            actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('再想想')),
              FilledButton(onPressed: () => SystemNavigator.pop(), child: const Text('退出应用'))])),
            child: const Text('不同意并退出', style: TextStyle(color: Color(0xFF9AA0AE))))),
        ]))))))));
  }
}

// 内置法律文档阅读页(打包进 assets, 离线可读, 无需联网)
class LegalDocPage extends StatelessWidget {
  final String title, asset;
  const LegalDocPage({super.key, required this.title, required this.asset});
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: FutureBuilder<String>(future: rootBundle.loadString(asset),
      builder: (c2, s) => s.hasData
        ? Scrollbar(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
            child: SelectableText(s.data!, style: const TextStyle(fontSize: 13.5, height: 1.75))))
        : const Center(child: CircularProgressIndicator())));
}

class ThApp extends StatefulWidget {
  final bool ready, locked, fresh; final String base, token;
  const ThApp({super.key, required this.ready, required this.base, required this.token, this.locked = false, this.fresh = false});
  @override State<ThApp> createState() => _ThAppState();
}
class _ThAppState extends State<ThApp> {
  @override void initState() { super.initState();
    AppSettings.onChanged = () { if (mounted) setState(() {}); };
    I18n.instance.addListener(_onLang); }
  void _onLang() { if (mounted) setState(() {}); }
  @override void dispose() { I18n.instance.removeListener(_onLang); super.dispose(); }
  @override Widget build(BuildContext c) { Api.base = widget.base; Api.token = widget.token;
    final accent = Color(AppSettings.accentColor);
    final mode = AppSettings.themeModeStr;
    ThemeData buildTheme(Brightness b) {
      final dark = b == Brightness.dark;
      final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: b);
      return ThemeData(useMaterial3: true, brightness: b,
        scaffoldBackgroundColor: dark ? const Color(0xFF0F1115) : const Color(0xFFF6F7FB),
        colorScheme: scheme.copyWith(primary: accent,
          surface: dark ? const Color(0xFF0F1115) : const Color(0xFFF6F7FB)),
        cardTheme: CardThemeData(elevation: 0, margin: const EdgeInsets.symmetric(vertical: 6),
          color: dark ? const Color(0xFF181B22) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
        listTileTheme: const ListTileThemeData(minVerticalPadding: 4),
        appBarTheme: AppBarTheme(centerTitle: false, elevation: 0, scrolledUnderElevation: 0,
          backgroundColor: dark ? const Color(0xFF0F1115) : const Color(0xFFF6F7FB)),
        pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.android: _SmoothTransitionsBuilder(),
          TargetPlatform.iOS: _SmoothTransitionsBuilder(),
        }));
    }
    return MaterialApp(title: 'ThirdHub', navigatorKey: IntentRouter.navKey,
      theme: buildTheme(Brightness.light), darkTheme: buildTheme(Brightness.dark),
      themeMode: mode == 'system' ? ThemeMode.system : mode == 'light' ? ThemeMode.light : ThemeMode.dark,
      home: ConsentGate(locked: widget.locked, fresh: widget.fresh)); }
}

// 首启引导: 语言 → 外观 → 模块选择 → 账号(登录/注册/游客), 全程可跳过
class OnboardingPage extends StatefulWidget { const OnboardingPage({super.key}); @override State<OnboardingPage> createState() => _Ob(); }
class _Ob extends State<OnboardingPage> {
  int step = 0; final ctrl = PageController();
  final Set<String> _mods = kModules.keys.toSet();
  static const _titles = ['选择语言', '外观偏好', '选择模块', '账号'];
  static const _subs = ['Choose your language', '主题与强调色, 之后随时可改', '勾选底部导航要显示的模块(我的固定保留)', '登录可云端同步并远程连接; 游客模式仅用本地与局域网'];
  Future<void> finish() async { final p = await SharedPreferences.getInstance();
    final list = kModules.keys.where((k) => _mods.contains(k)).toList();
    if (!list.contains('我的')) list.add('我的');
    await p.setStringList('nav_modules', list);
    await p.setBool('first_run', true);
    if (mounted) runApp(ThApp(ready: (p.getString('base') ?? '').isNotEmpty, base: p.getString('base') ?? '', token: p.getString('token') ?? '')); }
  void next() { if (step < 3) { ctrl.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut); } else { finish(); } }

  Widget _langStep() => ListView(padding: const EdgeInsets.symmetric(horizontal: 24), children: [
    RadioListTile<String>(value: 'system', groupValue: AppSettings.locale, title: const Text('跟随系统 / System'),
      onChanged: (v) => AppSettings.setLocale(v!).then((_) => setState(() {}))),
    for (final lc in I18n.supported)
      RadioListTile<String>(value: lc, groupValue: AppSettings.locale, title: Text(I18n.names[lc] ?? lc),
        onChanged: (v) => AppSettings.setLocale(v!).then((_) => setState(() {}))),
  ]);

  Widget _lookStep() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListView(padding: const EdgeInsets.all(24), children: [
      const Text('主题', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      SegmentedButton<String>(segments: [
        ButtonSegment(value: 'system', icon: const Icon(Icons.settings_suggest_outlined, size: 16), label: Text(tr('跟随系统'))),
        ButtonSegment(value: 'light', icon: const Icon(Icons.light_mode_outlined, size: 16), label: Text(tr('浅色'))),
        ButtonSegment(value: 'dark', icon: const Icon(Icons.dark_mode_outlined, size: 16), label: Text(tr('深色'))),
      ], selected: {AppSettings.themeModeStr},
        onSelectionChanged: (s) => AppSettings.setThemeMode(s.first).then((_) => setState(() {}))),
      const SizedBox(height: 28),
      const Text('强调色', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 12, children: [ for (final col in [0xFF3B5BFD, 0xFF7C6CFF, 0xFF4ADE80, 0xFFF472B6, 0xFFFBBF24, 0xFFFF6B4A, 0xFF22D3EE])
        GestureDetector(onTap: () => AppSettings.setAccent(col).then((_) => setState(() {})),
          child: Container(width: 40, height: 40, decoration: BoxDecoration(color: Color(col), shape: BoxShape.circle,
            border: AppSettings.accentColor == col ? Border.all(color: dark ? Colors.white : Colors.black87, width: 2.5) : null,
            boxShadow: [BoxShadow(color: Color(col).withValues(alpha: 0.4), blurRadius: 8)]))) ]),
      const SizedBox(height: 28),
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color, borderRadius: BorderRadius.circular(18)),
        child: Row(children: [Icon(Icons.auto_awesome, color: Color(AppSettings.accentColor)),
          const SizedBox(width: 12), const Expanded(child: Text('预览: 卡片、按钮、进度条都会使用强调色', style: TextStyle(fontSize: 12)))])),
    ]);
  }

  Widget _modStep() => ListView(padding: const EdgeInsets.symmetric(horizontal: 24), children: [
    for (final e in kModules.entries)
      CheckboxListTile(value: _mods.contains(e.key),
        secondary: Icon(e.value.icon),
        title: Text(e.key),
        subtitle: e.key == '我的' ? const Text('固定保留', style: TextStyle(fontSize: 11)) : null,
        onChanged: e.key == '我的' ? null : (v) => setState(() { v == true ? _mods.add(e.key) : _mods.remove(e.key); })),
  ]);

  Widget _accountStep() => ListView(padding: const EdgeInsets.all(24), children: [
    Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(
      color: Theme.of(context).cardTheme.color, borderRadius: BorderRadius.circular(18)),
      child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.cloud_outlined, size: 20), SizedBox(width: 8),
          Text('登录账号', style: TextStyle(fontWeight: FontWeight.bold))]),
        SizedBox(height: 6),
        Text('· 前后端自动配对(局域网 / IPv6 / 内网穿透三路竞速)\n· 书架、阅读进度云端同步\n· 远程(外出)也能连家里的资源库', style: TextStyle(fontSize: 12, height: 1.7)),
      ])),
    const SizedBox(height: 8),
    const AccountTile(),
    const SizedBox(height: 16),
    Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(
      color: Theme.of(context).cardTheme.color, borderRadius: BorderRadius.circular(18)),
      child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.person_outline, size: 20), SizedBox(width: 8),
          Text('游客模式', style: TextStyle(fontWeight: FontWeight.bold))]),
        SizedBox(height: 6),
        Text('不登录也能用: 本地播放 + 局域网内手动连接/自动发现资源库。\n云端同步与远程连接需登录后解锁。', style: TextStyle(fontSize: 12, height: 1.7)),
      ])),
    const SizedBox(height: 12),
    OutlinedButton.icon(onPressed: finish, icon: const Icon(Icons.arrow_forward, size: 16),
      label: const Text('以游客身份进入')),
  ]);

  @override Widget build(BuildContext c) {
    final accent = Color(AppSettings.accentColor);
    return Scaffold(body: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 20, 12, 0), child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_titles[step], style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(_subs[step], style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ])),
        TextButton(onPressed: finish, child: const Text('跳过')),
      ])),
      const SizedBox(height: 8),
      Expanded(child: PageView(controller: ctrl, physics: const NeverScrollableScrollPhysics(),
        onPageChanged: (i) => setState(() => step = i),
        children: [_langStep(), _lookStep(), _modStep(), _accountStep()])),
      Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 20), child: Row(children: [
        Row(children: [ for (var i = 0; i < 4; i++)
          AnimatedContainer(duration: const Duration(milliseconds: 250), width: i == step ? 22 : 8, height: 8,
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4),
              color: i == step ? accent : Colors.grey.withValues(alpha: 0.35))) ]),
        const Spacer(),
        if (step > 0) TextButton(onPressed: () => ctrl.previousPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut),
          child: const Text('上一步')),
        const SizedBox(width: 8),
        FilledButton(onPressed: next, child: Text(step < 3 ? '下一步' : '完成')),
      ])),
    ])));
  }
}

// 应用锁: 本地PIN, 输对才进主界面
class LockScreen extends StatefulWidget { const LockScreen({super.key}); @override State<LockScreen> createState() => _Lock(); }
class _Lock extends State<LockScreen> {
  String input = ''; String? err; bool checking = false;
  Future<void> verify() async {
    setState(() => checking = true);
    final p = await SharedPreferences.getInstance();
    if (input == (p.getString('app_pin') ?? '')) {
      runApp(ThApp(ready: (p.getString('base') ?? '').isNotEmpty, base: p.getString('base') ?? '', token: p.getString('token') ?? ''));
    } else { setState(() { checking = false; err = tr('密码错误'); input = ''; }); }
  }
  void press(String d) { if (checking) return;
    if (d == 'DEL') { input = input.isEmpty ? '' : input.substring(0, input.length - 1); }
    else if (input.length < 6) input += d;
    setState(() {}); if (input.length >= 4) verify(); }
  @override Widget build(BuildContext c) => Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.lock_outline, size: 48, color: Colors.blue),
    const SizedBox(height: 12), const Text('ThirdHub 已锁定'),
    const SizedBox(height: 16),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [ for (var i = 0; i < 6; i++)
      Container(width: 14, height: 14, margin: const EdgeInsets.all(6), decoration: BoxDecoration(
        shape: BoxShape.circle, color: i < input.length ? Colors.blue : Colors.grey.shade800)) ]),
    if (err != null) Text(err!, style: const TextStyle(color: Colors.red, fontSize: 12)),
    const SizedBox(height: 16),
    for (final row in [['1','2','3'],['4','5','6'],['7','8','9'],['','0','DEL']])
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [ for (final d in row)
        SizedBox(width: 72, height: 54, child: d.isEmpty ? const SizedBox() : TextButton(
          onPressed: () => press(d), child: Text(d == 'DEL' ? '⌫' : d, style: const TextStyle(fontSize: 20)))) ]),
  ])));
}

// ═══ 连接资源库(唯一的"设置") ═══
class ConnectLibraryPage extends StatefulWidget { const ConnectLibraryPage({super.key}); @override State<ConnectLibraryPage> createState() => _Conn(); }
class _Conn extends State<ConnectLibraryPage> {
  final baseC = TextEditingController(); final tokenC = TextEditingController();
  String? fp; bool busy = false; String? err; StreamSubscription? _discSub;
  @override void initState() { super.initState();
    ThpDiscovery.start();
    _discSub = ThpDiscovery.onChange.listen((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { _discSub?.cancel(); baseC.dispose(); tokenC.dispose(); super.dispose(); }
  Future<void> connect() async {
    setState(() { busy = true; err = null; });
    try {
      final r = await Api.client().get(Uri.parse('${baseC.text.trim()}/v1/meta'));
      fp = jsonDecode(r.body)['data']?['fingerprint']?.toString();
      final p = await SharedPreferences.getInstance();
      await p.setString('base', baseC.text.trim()); await p.setString('token', tokenC.text.trim());
      if (!mounted) return; setState(() => busy = false);
      final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        title: const Text('确认资源库指纹'), content: SelectableText('SHA256:\n$fp'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('取消'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('信任'))]));
      if (ok == true && mounted) { Api.base = baseC.text.trim(); Api.token = tokenC.text.trim();
        runApp(ThApp(ready: true, base: baseC.text.trim(), token: tokenC.text.trim())); }
    } catch (e) { setState(() { busy = false; err = '连接失败: $e'; }); } }
  @override Widget build(BuildContext c) => Scaffold(body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
    child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('ThirdHub', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
      const Text('纯播放器前端 · 连接资源库开始', style: TextStyle(color: Colors.grey)),
      const SizedBox(height: 24),
      TextField(controller: baseC, decoration: InputDecoration(labelText: tr('资源库地址'), hintText: 'https://192.168.x.x:9527', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: tokenC, decoration: const InputDecoration(labelText: '密钥', hintText: 'thsec_...', border: OutlineInputBorder())),
      if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: busy ? null : connect, icon: const Icon(Icons.link), label: Text(busy ? '连接中…' : tr('连接资源库'))),
      const SizedBox(height: 20),
      // 局域网自动发现(THP): 资源库一键连接, 引擎仅展示(前端也可直接当资源用)
      Align(alignment: Alignment.centerLeft, child: Text('局域网发现的设备', style: TextStyle(fontSize: 12, color: Colors.grey))),
      const SizedBox(height: 6),
      if (ThpDiscovery.list().isEmpty)
        const Text('暂未发现 · 资源库/引擎开机后会自动广播', style: TextStyle(fontSize: 11, color: Colors.grey))
      else
        for (final d in ThpDiscovery.list())
          ListTile(dense: true, contentPadding: EdgeInsets.zero,
            leading: Icon(d.isLibrary ? Icons.dns : Icons.extension, size: 20,
              color: d.isLibrary ? Colors.blueAccent : Colors.grey),
            title: Text('${d.label} · ${d.host}:${d.port}', style: const TextStyle(fontSize: 13)),
            subtitle: d.isLibrary ? null : Text(d.caps.join(' / '), style: const TextStyle(fontSize: 10)),
            trailing: d.isLibrary ? FilledButton.tonal(child: const Text('连接', style: TextStyle(fontSize: 12)),
              onPressed: () { baseC.text = d.url; connect(); }) : null),
      const SizedBox(height: 12),
      const AppLockSettings(),
    ])))));
}

class AppLockSettings extends StatefulWidget { const AppLockSettings({super.key}); @override State<AppLockSettings> createState() => _Als(); }
class _Als extends State<AppLockSettings> {
  bool enabled = false; final c = TextEditingController(); String msg = '';
  @override void initState() { super.initState(); check(); }
  Future<void> check() async { final p = await SharedPreferences.getInstance();
    setState(() => enabled = (p.getString('app_pin') ?? '').isNotEmpty); }
  Future<void> toggle(bool v) async { final p = await SharedPreferences.getInstance();
    if (!v) { await p.remove('app_pin'); setState(() { enabled = false; msg = tr('已关闭'); }); }
    else if (c.text.length >= 4) { await p.setString('app_pin', c.text); setState(() { enabled = true; msg = tr('已开启'); c.clear(); }); }
    else setState(() => msg = '至少4位数字'); }
  @override Widget build(BuildContext context) => Column(children: [
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.lock_outline, size: 16, color: Colors.grey), const SizedBox(width: 6),
      Text(tr('应用锁'), style: TextStyle(color: Colors.grey, fontSize: 12)),
      Switch(value: enabled, onChanged: toggle),
    ]),
    if (!enabled) SizedBox(width: 180, child: TextField(controller: c, obscureText: true, keyboardType: TextInputType.number,
      maxLength: 6, decoration: InputDecoration(hintText: tr('设置PIN(4-6位)'), isDense: true, counterText: '', border: OutlineInputBorder()), style: const TextStyle(fontSize: 13))),
    if (msg.isNotEmpty) Text(msg, style: const TextStyle(fontSize: 11, color: Colors.blueAccent)),
  ]);
}

// ═══ 全局搜索代理(按板块走各自API, 二期接后端) ═══
class ThSearchDelegate extends SearchDelegate {
  final int tab; ThSearchDelegate(this.tab);
  @override String get searchFieldLabel => ['', '搜小说', '搜漫画', '搜视频', '搜音乐'][tab];
  @override List<Widget> buildActions(BuildContext c) => [IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];
  @override Widget buildLeading(BuildContext c) => IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(c, null));
  @override Widget buildResults(BuildContext c) => _body(c);
  @override Widget buildSuggestions(BuildContext c) => _body(c);
  Widget _body(BuildContext c) {
    if (tab == 1) return NovelSearchResults(query: query);
    if (tab == 2) return ComicSearchResults(query: query);
    if (tab == 3) return VideoSearchResults(query: query);
    if (tab == 4) return MusicSearchResults(query: query);
    return const SizedBox.shrink();
  }
}

// 模块"搜索"页签: 顶部伪搜索框(点开全屏搜索页, 自动弹键盘) + 下方历史/结果区
class ModuleSearchTab extends StatelessWidget {
  final int tab; // 1小说 2漫画 3视频 4音乐 (与 ThSearchDelegate 同编号)
  const ModuleSearchTab({super.key, required this.tab});
  @override Widget build(BuildContext c) {
    const hints = {1: '搜小说', 2: '搜漫画', 3: '搜视频', 4: '搜音乐'};
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: GestureDetector(
        onTap: () => showSearch(context: c, delegate: ThSearchDelegate(tab)),
        child: NeuInset(radius: 14, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [const Icon(Icons.search, size: 19, color: Colors.grey), const SizedBox(width: 8),
            Expanded(child: Text(hints[tab] ?? '搜索', style: const TextStyle(fontSize: 13, color: Colors.grey))),
            const Icon(Icons.north_west, size: 13, color: Colors.grey)])))),
      Expanded(child: switch (tab) {
        2 => const ComicSearchResults(query: ''),
        3 => const VideoSearchResults(query: ''),
        4 => const MusicSearchResults(query: ''),
        _ => const NovelSearchResults(query: ''),
      }),
    ]);
  }
}

// 个人中心: 昵称头像(本地)+收藏统计+清理+关于

// ── 漂浮光点背景(个人卡/炫酷效果用) ──
class _Particles extends StatefulWidget { const _Particles(); @override State<_Particles> createState() => _ParticlesState(); }
class _ParticlesState extends State<_Particles> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat();
  static final _rnd = Random(7);
  static final List<Offset> _pts = [for (var i = 0; i < 26; i++) Offset(_rnd.nextDouble(), _rnd.nextDouble())];
  static final List<double> _r = [for (var i = 0; i < 26; i++) 1.2 + _rnd.nextDouble() * 2.8];
  static final List<double> _sp = [for (var i = 0; i < 26; i++) 0.2 + _rnd.nextDouble() * 0.8];
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) => AnimatedBuilder(animation: _c, builder: (_, __) => CustomPaint(
    painter: _ParticlesPainter(_c.value, _pts, _r, _sp)));
}
class _ParticlesPainter extends CustomPainter {
  final double t; final List<Offset> pts; final List<double> r; final List<double> sp;
  _ParticlesPainter(this.t, this.pts, this.r, this.sp);
  @override void paint(Canvas canvas, Size size) {
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      // 缓慢上飘 + 左右摆动 + 透明度呼吸
      final y = (p.dy - t * sp[i]) % 1.0;
      final x = (p.dx + 0.03 * sin((t * 2 * pi * sp[i]) + i)) % 1.0;
      final a = 0.12 + 0.18 * (0.5 + 0.5 * sin(t * 2 * pi * sp[i] + i * 1.7));
      canvas.drawCircle(Offset(x * size.width, (y < 0 ? y + 1 : y) * size.height), r[i],
        Paint()..color = Colors.white.withValues(alpha: a));
    }
  }
  @override bool shouldRepaint(_ParticlesPainter old) => true;
}

class ProfilePage extends StatefulWidget { const ProfilePage({super.key}); @override State<ProfilePage> createState() => _Pf(); }
class _Pf extends State<ProfilePage> {
  @override void initState() { super.initState(); AppSettings.loadFromBackend().then((_) { if (mounted) setState(() {}); }); }


  // ── 顶部个人大卡: 渐变底 + 漂浮光点 + 头像环(卡片式头像框回归) ──
  Widget _heroCard() {
    final logged = Cloud.loggedIn;
    final nick = AppSettings.nickname;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [
          scheme.primary.withValues(alpha: 0.85),
          scheme.tertiary.withValues(alpha: 0.75),
          scheme.primaryContainer,
        ])),
      child: Stack(children: [
        const Positioned.fill(child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          child: _Particles())),
        Padding(padding: const EdgeInsets.symmetric(vertical: 26), child: Column(children: [
          // 点头像 → 账号与设置子页; 点右下角相机角标 → 换头像
          GestureDetector(onTap: () => Navigator.push(context, smoothRoute(const ProfileSubPage())).then((_) { if (mounted) setState(() {}); }),
            child: Stack(clipBehavior: Clip.none, children: [
            Container(
              padding: const EdgeInsets.all(3.5),
              decoration: BoxDecoration(shape: BoxShape.circle,
                gradient: SweepGradient(colors: [Colors.white, Colors.white.withValues(alpha: 0.25), Colors.white]),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 6))]),
              child: CircleAvatar(radius: 44, backgroundColor: scheme.surface,
                backgroundImage: AppSettings.avatarB64.isNotEmpty ? MemoryImage(base64Decode(AppSettings.avatarB64)) : null,
                child: AppSettings.avatarB64.isEmpty
                  ? Icon(Icons.person, size: 44, color: scheme.primary) : null)),
            Positioned(right: -1, bottom: -1, child: GestureDetector(onTap: pickAvatar,
              child: Container(padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surface,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 6)]),
                child: Icon(Icons.photo_camera_outlined, size: 14, color: scheme.primary)))),
          ])),
          const SizedBox(height: 12),
          Text(logged ? (nick.isEmpty ? Cloud.email : nick) : '未登录 · 游客模式',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 4),
          Text(logged ? Cloud.email : '本地播放 + 局域网资源库可用, 登录解锁云同步',
            style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.85))),
          if (logged && AppSettings.identityCode.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withValues(alpha: 0.35))),
              child: Text('身份码 ${AppSettings.identityCode}', style: const TextStyle(fontSize: 11, color: Colors.white, letterSpacing: 0.5))),
          ],
        ])),
      ]));
  }

  Future<void> pickAvatar() async {
    final permitted = await pm.PhotoManager.requestPermissionExtend();
    if (!permitted.isAuth) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('相册权限被拒'))); return; }
    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image);
    if (albums.isEmpty) return;
    final assets = await albums.first.getAssetListPaged(page: 0, size: 30);
    if (!mounted) return;
    final picked = await showDialog<pm.AssetEntity>(context: context, builder: (c) => AlertDialog(
      title: const Text('选择头像'),
      content: SizedBox(width: 300, height: 300, child: GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
        itemCount: assets.length, itemBuilder: (_, i) => GestureDetector(
          onTap: () => Navigator.pop(c, assets[i]),
          child: Padding(padding: const EdgeInsets.all(2), child: AssetEntityImage(assets[i], width: 100, height: 100, fit: BoxFit.cover, isOriginal: false))))),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('取消')))]));
    if (picked == null) return;
    try {
      final file = await picked.file; if (file == null) return;
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes); if (decoded == null) return;
      final resized = img.copyResize(decoded, width: 256);
      final jpg = img.encodeJpg(resized, quality: 85);
      await AppSettings.setAvatar(base64Encode(jpg));
      // 登录状态下同步到云端账号体系
      if (Cloud.loggedIn) { try { await Cloud.updateProfile({'avatar_b64': base64Encode(jpg)}); } catch (_) {} }
      if (mounted) setState(() {});
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败: $e'))); } }

  // Kimi 式设置行: 素色左图标 + 标题 + 右侧灰值 + chevron
  Widget entry(IconData icon, String title, {String value = '', Widget? page, VoidCallback? onTap}) => ListTile(
    dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: Icon(icon, size: 21),
    title: Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      if (value.isNotEmpty) Text(value, style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
      const SizedBox(width: 2),
      const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
    ]),
    onTap: onTap ?? (page != null ? () => Navigator.push(context, smoothRoute(page)).then((_) { if (mounted) setState(() {}); }) : null));

  // Kimi 式分组: 组名在卡片外(灰小字), 卡片大圆角
  Widget _section(String title, List<Widget> children) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (title.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 14, 14, 6),
      child: Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey))),
    Card(margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(children: children)),
  ]);
  Widget _sep() => const Divider(height: 1, indent: 52);

  @override Widget build(BuildContext c) {
    final nick = AppSettings.nickname;
    final logged = Cloud.loggedIn;
    return ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 20), children: [
      _heroCard(),
      const SizedBox(height: 10),
      _section('', [
        entry(Icons.person_outline, '账号安全', value: logged ? (nick.isEmpty ? Cloud.email : nick) : '未登录', page: const ProfileSubPage()),
        _sep(),
        entry(Icons.notifications_none, '通知', page: const NotificationSettingsPage()),
        _sep(),
        entry(Icons.wb_sunny_outlined, tr('外观'), page: const AppearancePage()),
        _sep(),
        entry(Icons.dashboard_customize_outlined, '功能管理', page: const NavSettingsPage()),
      ]),
      _section('数据', [
        entry(Icons.cloud_outlined, tr('云端'), page: const CloudPage()),
        _sep(),
        entry(Icons.delete_outline, '回收站', page: const RecycleBinPage()),
        _sep(),
        entry(Icons.download_outlined, '下载 App', page: const DownloadAppsPage()),
      ]),
      _section('服务', [
        entry(Icons.extension_outlined, '引擎直连', value: EngineDirect.connected ? '已连接' : '', page: const EngineDirectPage()),
        _sep(),
        entry(Icons.settings_outlined, tr('系统'), page: const SystemPage()),
      ]),
      _section('帮助中心', [
        entry(Icons.help_outline, '帮助中心', page: const HelpPage()),
        _sep(),
        entry(Icons.mail_outline, '反馈问题', onTap: () => launchUrl(Uri.parse('https://github.com/Smalluniverseheng/ThirdHub-v2/issues'), mode: LaunchMode.externalApplication)),
        _sep(),
        entry(Icons.info_outline, '关于 ThirdHub', page: const AboutPage()),
        _sep(),
        entry(Icons.system_update_alt, '检查更新', value: 'v${Updater.currentVersion}', onTap: () => Updater.check(context, manual: true)),
      ]),
      if (logged) ...[
        const SizedBox(height: 18),
        FilledButton.tonal(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23))),
          onPressed: () async { await Cloud.signOut(); if (mounted) setState(() {}); },
          child: const Text('退出登录')),
      ],
      const SizedBox(height: 12),
      Center(child: Text('ThirdHub v${Updater.currentVersion} · 纯播放器前端 · 支持 IPv6', style: const TextStyle(fontSize: 10.5, color: Colors.grey))),
    ]);
  }
}

// ── 通知设置(Kimi 格式子页) ──
class NotificationSettingsPage extends StatefulWidget { const NotificationSettingsPage({super.key}); @override State<NotificationSettingsPage> createState() => _Nsp(); }
class _Nsp extends State<NotificationSettingsPage> {
  bool _ann = true, _work = true, _update = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() { _ann = p.getBool('notify_ann') ?? true; _work = p.getBool('notify_work') ?? true; _update = p.getBool('notify_update') ?? true; });
  }
  Future<void> _set(String k, bool v) async { final p = await SharedPreferences.getInstance(); await p.setBool(k, v); setState(() {}); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('通知')),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), child: Column(children: [
        SwitchListTile(dense: true, value: _ann, onChanged: (v) { _ann = v; _set('notify_ann', v); },
          title: const Text('公告通知', style: TextStyle(fontSize: 14.5)), subtitle: const Text('版本公告与活动', style: TextStyle(fontSize: 11))),
        const Divider(height: 1, indent: 52),
        SwitchListTile(dense: true, value: _work, onChanged: (v) { _work = v; _set('notify_work', v); },
          title: const Text('作业完成提醒', style: TextStyle(fontSize: 14.5)), subtitle: const Text('Work 作业完成/待确认时提醒', style: TextStyle(fontSize: 11))),
        const Divider(height: 1, indent: 52),
        SwitchListTile(dense: true, value: _update, onChanged: (v) { _update = v; _set('notify_update', v); },
          title: const Text('追更提醒', style: TextStyle(fontSize: 14.5)), subtitle: const Text('书架有新章节时提醒', style: TextStyle(fontSize: 11))),
      ])),
    ]));
}

// ── 帮助中心(Kimi 格式子页) ──
class HelpPage extends StatelessWidget { const HelpPage({super.key});
  Widget _row(BuildContext c, IconData icon, String title, VoidCallback onTap) => ListTile(dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: Icon(icon, size: 21), title: Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
    trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.grey), onTap: onTap);
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('帮助中心')),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), child: Column(children: [
        _row(c, Icons.menu_book_outlined, '使用文档', () => launchUrl(Uri.parse('https://github.com/Smalluniverseheng/ThirdHub-v2'), mode: LaunchMode.externalApplication)),
        const Divider(height: 1, indent: 52),
        _row(c, Icons.privacy_tip_outlined, '隐私政策', () => Navigator.push(c, smoothRoute(const LegalDocPage(title: '隐私政策', asset: 'assets/legal/privacy.md')))),
        const Divider(height: 1, indent: 52),
        _row(c, Icons.description_outlined, '用户服务协议', () => Navigator.push(c, smoothRoute(const LegalDocPage(title: '用户服务协议', asset: 'assets/legal/terms.md')))),
      ])),
      const Padding(padding: EdgeInsets.fromLTRB(16, 14, 14, 6),
        child: Text('常见问题', style: TextStyle(fontSize: 12, color: Colors.grey))),
      Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), child: const Column(children: [
        ListTile(dense: true, title: Text('后端/引擎连不上?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text('确认手机与后端在同一局域网; 后端已启动且指纹已确认; 引擎靠局域网广播自动发现, 无需配置', style: TextStyle(fontSize: 11.5))),
        Divider(height: 1, indent: 16),
        ListTile(dense: true, title: Text('数据存在哪?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text('用户数据全部存你自己的资源库; 云端只存账号、头像、设置与公钥', style: TextStyle(fontSize: 11.5))),
        Divider(height: 1, indent: 16),
        ListTile(dense: true, title: Text('内容从哪来?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text('ThirdHub 是纯播放器, 零内置源; 内容由你自行接入的引擎提供', style: TextStyle(fontSize: 11.5))),
      ])),
    ]));
}

// ── 个人资料子页(网页版同款): 大头像带相机角标 + 可编辑资料行 + 退出登录 ──
class ProfileSubPage extends StatefulWidget { const ProfileSubPage({super.key}); @override State<ProfileSubPage> createState() => _Psub(); }
class _Psub extends State<ProfileSubPage> {
  Future<void> _editField(String key, String name, String cur) async {
    final ctrl = TextEditingController(text: cur);
    final v = await showDialog<String>(context: context, builder: (c2) => AlertDialog(title: Text(name),
      content: TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(hintText: name, isDense: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, ctrl.text.trim()), child: const Text('保存'))]));
    if (v == null) return;
    final p = await SharedPreferences.getInstance();
    if (key == 'nickname') { await p.setString('nickname', v);
      if (Cloud.loggedIn) { try { await Cloud.updateProfile({'nickname': v, 'display_name': v}); } catch (_) {} } }
    if (key == 'bio') { await AppSettings.setBio(v);
      if (Cloud.loggedIn) { try { await Cloud.updateProfile({'bio': v}); } catch (_) {} } }
    if (mounted) setState(() {});
  }

  Future<void> _pickAvatar() async {
    final permitted = await pm.PhotoManager.requestPermissionExtend();
    if (!permitted.isAuth) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('相册权限被拒'))); return; }
    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image);
    if (albums.isEmpty) return;
    final assets = await albums.first.getAssetListPaged(page: 0, size: 60);
    if (!mounted) return;
    final picked = await showDialog<pm.AssetEntity>(context: context, builder: (c) => AlertDialog(
      title: const Text('选择头像'),
      content: SizedBox(width: 300, height: 320, child: GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
        itemCount: assets.length, itemBuilder: (_, i) => GestureDetector(
          onTap: () => Navigator.pop(c, assets[i]),
          child: Padding(padding: const EdgeInsets.all(2), child: AssetEntityImage(assets[i], width: 100, height: 100, fit: BoxFit.cover, isOriginal: false))))),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('取消')))]));
    if (picked == null) return;
    try {
      final file = await picked.file; if (file == null) return;
      final decoded = img.decodeImage(await file.readAsBytes()); if (decoded == null) return;
      final jpg = img.encodeJpg(img.copyResize(decoded, width: 256), quality: 85);
      await AppSettings.setAvatar(base64Encode(jpg));
      if (Cloud.loggedIn) { try { await Cloud.updateProfile({'avatar_b64': base64Encode(jpg)}); } catch (_) {} }
      if (mounted) setState(() {});
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败: $e'))); }
  }

  @override Widget build(BuildContext c) {
    final avatar = AppSettings.avatarB64;
    final nick = AppSettings.nickname;
    final logged = Cloud.loggedIn;
    final accent = Theme.of(c).colorScheme.primary;
    Widget row(String name, String val, VoidCallback onTap) => InkWell(onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), child: Row(children: [
        Text(name, style: const TextStyle(fontSize: 14)),
        const Spacer(),
        Flexible(child: Text(val, style: const TextStyle(fontSize: 13, color: Colors.grey), overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
      ])));
    return Scaffold(appBar: AppBar(title: const Text('个人资料')), body: ListView(padding: const EdgeInsets.all(14), children: [
      // hero: 大头像+相机角标+昵称+邮箱+等级牌
      Center(child: Column(children: [
        const SizedBox(height: 14),
        GestureDetector(onTap: _pickAvatar, child: Stack(children: [
          CircleAvatar(radius: 44,
            backgroundImage: avatar.isNotEmpty ? MemoryImage(base64Decode(avatar)) : null,
            child: avatar.isEmpty ? Text(nick.isEmpty ? 'T' : nick[0].toUpperCase(), style: const TextStyle(fontSize: 28)) : null),
          Positioned(right: 0, bottom: 0, child: Container(padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle, border: Border.all(color: Theme.of(c).scaffoldBackgroundColor, width: 2)),
            child: const Icon(Icons.photo_camera, size: 13, color: Colors.white))),
        ])),
        const SizedBox(height: 10),
        Text(nick.isEmpty ? '未设置昵称' : nick, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(logged ? Cloud.email : '游客模式', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: (logged ? accent : Colors.grey).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
          child: Text(logged ? '会员' : '游客', style: TextStyle(fontSize: 10, color: logged ? accent : Colors.grey))),
        const SizedBox(height: 16),
      ])),
      Card(margin: EdgeInsets.zero, child: Column(children: [
        row('昵称', nick.isEmpty ? '未设置' : nick, () => _editField('nickname', '昵称', nick)),
        const Divider(height: 1, indent: 16),
        if (logged) ...[ row('邮箱', Cloud.email, () {}), const Divider(height: 1, indent: 16) ],
        row('身份码', logged ? AppSettings.identityCode : '登录后生成', () {}),
        const Divider(height: 1, indent: 16),
        row('简介', AppSettings.bio.isEmpty ? '这个人很懒，什么都没写' : AppSettings.bio, () => _editField('bio', '简介', AppSettings.bio)),
      ])),
      if (logged) Padding(padding: const EdgeInsets.only(top: 14), child: Card(margin: EdgeInsets.zero, child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () async { await Cloud.signOut(); if (c.mounted) { Navigator.pop(c); } },
        child: const Padding(padding: EdgeInsets.symmetric(vertical: 14),
          child: Center(child: Text('退出登录', style: TextStyle(color: Colors.redAccent, fontSize: 15)))),
      ))),
    ]));
  }
}

// 网盘: 内嵌Cloudreve Web UI(文件管理/上传/分享全功能)
class NetDiskPage extends StatefulWidget { final String baseUrl; const NetDiskPage({super.key, required this.baseUrl}); @override State<NetDiskPage> createState() => _Nd(); }
class _Nd extends State<NetDiskPage> {
  WebViewController? ctrl; bool loading = true; String? err;
  @override void initState() { super.initState(); init(); }
  void init() {
    try {
      final host = Uri.parse(widget.baseUrl).host;
      ctrl = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) => setState(() => loading = false)))
        ..loadRequest(Uri.parse('http://$host:5212'));
    } catch (e) { setState(() { loading = false; err = '$e'; }); } }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(tr('网盘'))),
    body: err != null ? Center(child: Text(err!))
      : Stack(children: [ if (ctrl != null) WebViewWidget(controller: ctrl!), if (loading) const Center(child: CircularProgressIndicator()) ])); }

// ═══ 后端管理台: 引擎拓扑(谁在线/什么能力) ═══
class EnginesPage extends StatefulWidget { const EnginesPage({super.key}); @override State<EnginesPage> createState() => _Eng(); }
class _Eng extends State<EnginesPage> {
  List builtin = []; List network = []; Map<String, int> meta = {}; bool loading = true; Timer? timer;
  @override void initState() { super.initState(); load(); timer = Timer.periodic(const Duration(seconds: 10), (_) => load()); }
  @override void dispose() { timer?.cancel(); super.dispose(); }
  Future<void> load() async { try { final r = await Api.get('/v1/engines');
    setState(() { builtin = (r['data']?['builtin'] as List? ?? []); network = (r['data']?['network'] as List? ?? []);
      meta = Map<String, int>.from(r['meta'] ?? {}); loading = false; }); } catch (_) { setState(() => loading = false); } }
  Color statusColor(String s) => s == 'online' ? Colors.blue : s == 'standby' ? Colors.orange : Colors.red;
  String statusText(String s) => s == 'online' ? tr('在线') : s == 'standby' ? tr('待机') : s == 'error' ? tr('故障') : tr('离线');
  Widget engineCard(Map e) => Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: Padding(
    padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Text('${e['icon'] ?? '🔧'}', style: const TextStyle(fontSize: 20)),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(e['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(e['kind'] == 'network' ? (e['id'] ?? '') : (e['detail'] ?? '内置引擎'), style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ])),
      Column(children: [ Icon(Icons.circle, size: 10, color: statusColor(e['status'] ?? 'offline')),
        Text(statusText(e['status'] ?? 'offline'), style: TextStyle(fontSize: 10, color: statusColor(e['status'] ?? 'offline'))) ]),
    ]),
    const SizedBox(height: 8),
    Wrap(spacing: 6, runSpacing: 4, children: [
      for (final cap in (e['caps'] as List? ?? [])) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: Colors.blue.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
        child: Text(cap, style: const TextStyle(fontSize: 10, color: Colors.blueAccent))),
      if (e['health'] != null && e['health']['rate'] != null) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: Colors.grey.shade800, borderRadius: BorderRadius.circular(10)),
        child: Text('成功率${e['health']['rate']}%', style: const TextStyle(fontSize: 10, color: Colors.grey))),
      if (e['lastSeen'] != null) Text('最后在线 ${DateTime.fromMillisecondsSinceEpoch(e['lastSeen']).toString().substring(11, 16)}',
        style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ]),
  ])));
  Widget emptyState() => Padding(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48), child: Column(children: [
    Container(width: 72, height: 72, decoration: BoxDecoration(color: Colors.blue.withOpacity(0.12), shape: BoxShape.circle),
      child: const Icon(Icons.settings_input_antenna, size: 34, color: Colors.blueAccent)),
    const SizedBox(height: 16),
    const Text('暂无网络引擎在线', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    const SizedBox(height: 8),
    const Text('安装 ThirdHub 阅读引擎 / venera 漫画引擎后,\n同一局域网下会自动配对出现在这里', textAlign: TextAlign.center,
      style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5)),
    const SizedBox(height: 16),
    OutlinedButton.icon(onPressed: load, icon: const Icon(Icons.refresh, size: 16), label: const Text('重新扫描')),
  ]));
  @override Widget build(BuildContext c) => loading && builtin.isEmpty && network.isEmpty ? const Center(child: CircularProgressIndicator())
    : RefreshIndicator(onRefresh: load, child: ListView(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: Text(
        '内置引擎 ${meta['builtinOnline'] ?? 0}/${meta['builtinTotal'] ?? 0} 在线 · 网络引擎 ${meta['networkOnline'] ?? 0}/${meta['networkTotal'] ?? 0} 在线 · 10秒自动刷新',
        style: const TextStyle(fontSize: 12, color: Colors.grey))),
      for (final e in builtin) engineCard(Map<String, dynamic>.from(e)),
      if (network.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: Text(tr('网络引擎(局域网设备)'), style: TextStyle(fontSize: 12, color: Colors.grey))),
      for (final e in network) engineCard(Map<String, dynamic>.from(e)),
      if (network.isEmpty) emptyState(),
    ]));
}

// ═══ 资源库: 存储服务状态 + 下载管理 ═══
class ToolsSection extends StatefulWidget { const ToolsSection({super.key}); @override State<ToolsSection> createState() => _Tools(); }
class _Tools extends State<ToolsSection> {
  Map<String, dynamic>? st; List active = []; List waiting = []; final urlC = TextEditingController(); String? msg;
  Timer? timer;
  @override void initState() { super.initState(); load(); timer = Timer.periodic(const Duration(seconds: 3), (_) => loadTasks()); }
  @override void dispose() { timer?.cancel(); super.dispose(); }
  Future<void> load() async { try { final r = await Api.get('/v1/storage/status'); setState(() => st = r['data']); } catch (_) {}
    loadTasks(); }
  Future<void> loadTasks() async { try { final r = await Api.get('/v1/download/tasks');
      setState(() { active = (r['data']?['active'] as List? ?? []); waiting = (r['data']?['waiting'] as List? ?? []); }); } catch (_) {} }
  Future<void> addTask() async { final u = urlC.text.trim(); if (u.isEmpty) return;
    try { final r = await http.post(Uri.parse('${Api.base}/v1/download/add'),
      headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'}, body: jsonEncode({'url': u}));
      setState(() { msg = r.statusCode == 200 ? tr('已添加下载') : '添加失败 ${r.statusCode}'; urlC.clear(); });
      loadTasks();
    } catch (e) { setState(() => msg = '错误: $e'); } }
  Widget statusRow(String name, String state, int port, [VoidCallback? onOpen]) => Row(children: [
    Icon(state == 'running' ? Icons.check_circle : Icons.error_outline, size: 18,
      color: state == 'running' ? Colors.blue : Colors.orange),
    const SizedBox(width: 8),
    Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
    Text(state == 'running' ? ':$port 运行中' : state == 'absent' ? '未安装' : state, style: const TextStyle(fontSize: 12, color: Colors.grey)),
    if (onOpen != null && state == 'running') TextButton(onPressed: onOpen, child: const Text('打开', style: TextStyle(fontSize: 12))),
  ]);
  @override Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(12), children: [
    Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('存储服务'), style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      if (st != null) ...[
        statusRow('☁️ 网盘 Cloudreve', st!['cloudreve'] ?? '?', 5212, () => Navigator.push(c, MaterialPageRoute(builder: (_) => NetDiskPage(baseUrl: Api.base)))),
        const SizedBox(height: 4),
        statusRow('⬇️ 下载引擎 aria2', st!['aria2'] ?? '?', 6800),
        const SizedBox(height: 4),
        Text(st!['hint'] ?? '', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ] else const Text('加载中…'),
    ]))),
    Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('下载任务 (${active.length}进行中/${waiting.length}等待)', style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: TextField(controller: urlC, decoration: const InputDecoration(hintText: '粘贴下载链接(HTTP/磁力/种子URL)', isDense: true, border: OutlineInputBorder()), style: const TextStyle(fontSize: 12))),
        IconButton(icon: const Icon(Icons.add), onPressed: addTask),
      ]),
      if (msg != null) Text(msg!, style: const TextStyle(fontSize: 11, color: Colors.blueAccent)),
      const SizedBox(height: 8),
      for (final t in [...active, ...waiting]) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [ Expanded(child: Text(t['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
          Text('${t['progress'] ?? 0}%', style: const TextStyle(fontSize: 11, color: Colors.blueAccent)) ]),
        const SizedBox(height: 2),
        LinearProgressIndicator(value: ((t['progress'] ?? 0) as int) / 100, minHeight: 3),
        if ((t['speed'] ?? '') != '' && t['speed'] != '0') Text('${t['speed']} B/s', style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ])),
      if (active.isEmpty && waiting.isEmpty) Text(tr('暂无任务'), style: TextStyle(fontSize: 12, color: Colors.grey)),
    ]))),
    const AlbumSyncCard(),
    const KeyVaultCard(),
  ]);
}

// 密钥库: AI Key等敏感信息加密存后端
class KeyVaultCard extends StatefulWidget { const KeyVaultCard({super.key}); @override State<KeyVaultCard> createState() => _Kvc(); }
class _Kvc extends State<KeyVaultCard> {
  List items = []; final nameC = TextEditingController(); final valC = TextEditingController(); String? msg;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try { final r = await Api.get('/v1/keyvault'); setState(() => items = (r['data'] as List? ?? [])); } catch (_) {} }
  Future<void> save() async { if (nameC.text.isEmpty || valC.text.isEmpty) return;
    try { final r = await http.post(Uri.parse('${Api.base}/v1/keyvault'),
      headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
      body: jsonEncode({'name': nameC.text.trim(), 'value': valC.text.trim()}));
      setState(() { msg = r.statusCode == 200 ? '已保存(加密)' : '失败'; nameC.clear(); valC.clear(); }); load();
    } catch (e) { setState(() => msg = '错误: $e'); } }
  Future<void> remove(String name) async { await Api.get('/v1/keyvault/delete?name=${Uri.encodeComponent(name)}'); load(); }
  @override Widget build(BuildContext c) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('密钥库', style: TextStyle(fontWeight: FontWeight.bold)),
    const Text('AI Key等敏感信息, AES加密存资源库', style: TextStyle(fontSize: 11, color: Colors.grey)),
    Row(children: [
      Expanded(flex: 2, child: TextField(controller: nameC, decoration: const InputDecoration(hintText: '名称(如 deepseek-key)', isDense: true, border: OutlineInputBorder()), style: const TextStyle(fontSize: 12))),
      const SizedBox(width: 6),
      Expanded(flex: 3, child: TextField(controller: valC, obscureText: true, decoration: const InputDecoration(hintText: '密钥值', isDense: true, border: OutlineInputBorder()), style: const TextStyle(fontSize: 12))),
      IconButton(icon: const Icon(Icons.save, size: 20), onPressed: save),
    ]),
    if (msg != null) Text(msg!, style: const TextStyle(fontSize: 11, color: Colors.blueAccent)),
    for (final k in items) Row(children: [
      Expanded(child: Text('${k['name']}: ${k['value']}', style: const TextStyle(fontSize: 12))),
      IconButton(icon: const Icon(Icons.copy, size: 16), onPressed: () async {
        final r = await Api.get('/v1/keyvault/get?name=${Uri.encodeComponent(k['name'])}');
        final v = r['data']?['value'] ?? '';
        if (v.isNotEmpty && mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取出(请谨慎粘贴)'))); } }),
      IconButton(icon: const Icon(Icons.delete_outline, size: 16), onPressed: () => remove(k['name'])),
    ]),
    if (items.isEmpty) const Text('空', style: TextStyle(fontSize: 12, color: Colors.grey)),
  ])));
}

// 相册同步: 选本地照片→上传后端→已同步网格
class AlbumSyncCard extends StatefulWidget { const AlbumSyncCard({super.key}); @override State<AlbumSyncCard> createState() => _Asc(); }
class _Asc extends State<AlbumSyncCard> {
  List synced = []; bool loading = false; String? msg; int uploading = 0;
  @override void initState() { super.initState(); loadSynced(); }
  Future<void> loadSynced() async { try { final r = await Api.get('/v1/album/photos');
    setState(() => synced = (r['data'] as List? ?? [])); } catch (_) {} }
  Future<void> pickAndUpload() async {
    final permitted = await pm.PhotoManager.requestPermissionExtend();
    if (!permitted.isAuth) { setState(() => msg = '相册权限被拒'); return; }
    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image);
    if (albums.isEmpty) { setState(() => msg = '无相册'); return; }
    final assets = await albums.first.getAssetListPaged(page: 0, size: 50);
    if (!mounted) return;
    final picked = await showDialog<List<pm.AssetEntity>>(context: context, builder: (c) => AlertDialog(
      title: Text('选择照片 (${assets.length}张可选前50)'),
      content: SizedBox(width: 300, height: 400, child: GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
        itemCount: assets.length, itemBuilder: (_, i) => GestureDetector(
          onTap: () => Navigator.pop(c, [assets[i]]),
          child: Padding(padding: const EdgeInsets.all(2), child: AssetEntityImage(assets[i], width: 100, height: 100, fit: BoxFit.cover, isOriginal: false)),
        ))),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('取消'))),
        TextButton(onPressed: () => Navigator.pop(c, assets), child: const Text('全选上传'))]));
    if (picked == null || picked.isEmpty) return;
    setState(() { uploading = picked.length; msg = null; });
    int ok = 0, fail = 0;
    for (final a in picked) {
      try {
        final file = await a.file; if (file == null) { fail++; continue; }
        final bytes = await file.readAsBytes();
        final b64 = base64Encode(bytes);
        final r = await http.post(Uri.parse('${Api.base}/v1/album/upload'),
          headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
          body: jsonEncode({'filename': a.title ?? 'photo.jpg', 'data': b64, 'mime': 'image/jpeg'}));
        r.statusCode == 200 ? ok++ : fail++;
      } catch (e) { fail++; }
      setState(() => uploading--);
    }
    setState(() => msg = '完成: 成功$ok 失败$fail');
    loadSynced();
  }
  Future<void> removePhoto(Map p) async { await Api.get('/v1/album/delete?id=${p['id']}'); loadSynced(); }
  @override Widget build(BuildContext c) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [ const Text('相册同步', style: TextStyle(fontWeight: FontWeight.bold)), const Spacer(),
      TextButton.icon(onPressed: loading ? null : pickAndUpload, icon: const Icon(Icons.cloud_upload, size: 18), label: Text(uploading > 0 ? '上传中$uploading…' : tr('选照片同步'))) ]),
    if (msg != null) Text(msg!, style: const TextStyle(fontSize: 11, color: Colors.blueAccent)),
    const SizedBox(height: 8),
    Text('已同步 ${synced.length} 张(点右上角管理删除)', style: const TextStyle(fontSize: 11, color: Colors.grey)),
    const SizedBox(height: 8),
    if (synced.isNotEmpty) GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4),
      itemCount: synced.length > 8 ? 8 : synced.length,
      itemBuilder: (_, i) { final p = synced[i]; return GestureDetector(
        onLongPress: () => removePhoto(Map<String, dynamic>.from(p)),
        child: Padding(padding: const EdgeInsets.all(2), child: Image.network('${Api.base}/v1/album/file?id=${p['id']}',
          fit: BoxFit.cover, headers: {'X-TH-Token': Api.token},
          errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26, child: Icon(Icons.broken_image, size: 18))))); }),
    if (synced.length > 8) Text('…还有 ${synced.length - 8} 张', style: const TextStyle(fontSize: 11, color: Colors.grey)),
  ])));
}

// ═══ 搜索板块: 统一入口, 选类型(全部/小说/漫画/视频/音乐), 后端按能力路由 ═══
class SearchSection extends StatefulWidget { const SearchSection({super.key}); @override State<SearchSection> createState() => _Home(); }
class _Home extends State<SearchSection> {
  final ctrl = TextEditingController(); Map<String, dynamic>? agg; bool loading = false;
  List<Map<String, dynamic>>? engItems; // THP 引擎直连搜索结果(已连引擎时替代后端结果)
  int typeFilter = 0; // 0全部 1小说 2漫画 3视频 4音乐
  List<String> history = [];
  @override void initState() { super.initState(); _loadHistory(); }
  Future<void> _loadHistory() async { final p = await SharedPreferences.getInstance();
    history = p.getStringList('search_history') ?? []; if (mounted) setState(() {}); }
  Future<void> _record(String q) async { final p = await SharedPreferences.getInstance();
    history.remove(q); history.insert(0, q); history = history.take(15).toList();
    await p.setStringList('search_history', history); }
  static final typeNames = [tr('全部'), tr('小说'), tr('漫画'), tr('视频'), tr('音乐')];
  static const typeKeys = ['', 'novel', 'comic', 'video', 'music'];
  Future<void> go() async { final q = ctrl.text.trim(); if (q.isEmpty) return;
    _record(q);
    setState(() { loading = true; agg = null; engItems = null; });
    try {
      if (EngineDirect.connected) {
        // THP 引擎直连: 不经过后端, 直接问局域网引擎
        if (typeFilter == 0) {
          const types = ['novel', 'comic', 'video', 'music'];
          final rs = await Future.wait(types.map((t) async {
            try { return await EngineDirect.search(t, q); } catch (_) { return <Map<String, dynamic>>[]; }
          }));
          final out = <Map<String, dynamic>>[];
          for (var i = 0; i < types.length; i++) { for (final it in rs[i]) { out.add({...it, '_type': types[i]}); } }
          if (mounted) setState(() => engItems = out);
        } else {
          final t = typeKeys[typeFilter];
          final rs = await EngineDirect.search(t, q);
          if (mounted) setState(() => engItems = [for (final it in rs) {...it, '_type': t}]);
        }
      } else if (Api.base.isNotEmpty) {
        if (typeFilter == 0) { final r = await Api.get('/v1/search/all?q=${Uri.encodeComponent(q)}'); setState(() { agg = r['data']; }); }
        else {
          // 单类型: 走统一路由, 后端按能力分发到对应引擎集合
          final r = await Api.get('/v1/search?type=${typeKeys[typeFilter]}&q=${Uri.encodeComponent(q)}');
          setState(() { agg = { 'single': r['data'], 'q': q }; });
        }
      } else {
        // 既没连引擎也没连资源库: 尝试自动连一次, 连不上再提示
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { await go(); return; }
        throw Exception('未连接引擎或资源库\n引擎启动后会自动发现, 或在「我的 → 引擎直连」手动连接');
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    if (mounted) setState(() => loading = false); }
  Widget group(String title, List items, Widget Function(Map) tile) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (items.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text('$title (${items.length})', style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold))),
    for (final it in items) tile(it),
  ]);
  // THP 引擎结果分组渲染: 点条目 → 引擎直连详情页(目录→内容全程走引擎)
  List<Widget> _engGroup(BuildContext c, String t) {
    const labels = {'novel': '📖 小说', 'comic': '🎨 漫画', 'video': '🎬 视频', 'music': '🎵 音乐'};
    final its = engItems!.where((e) => e['_type'] == t).toList();
    if (its.isEmpty) return const [];
    return [
      Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Text('${labels[t]} (${its.length})', style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold))),
      for (final it in its) ListTile(dense: true,
        leading: ('${it['coverUrl'] ?? ''}') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
          child: Image.network('${it['coverUrl']}', width: 40, height: 56, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
        title: Text('${it['name'] ?? it['title'] ?? ''}'),
        subtitle: Text('${it['author'] ?? it['subTitle'] ?? it['type'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => EngineItemPage(type: t, item: it)))),
    ];
  }
  @override Widget build(BuildContext c) => Column(children: [
    // 先进搜索页: 输入框在最上, 搜索分类显示在输入框下方
    Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 6), child: Row(children: [
      Expanded(child: NeuInset(radius: 14, padding: const EdgeInsets.symmetric(horizontal: 8),
        child: TextField(controller: ctrl, textInputAction: TextInputAction.search,
          onSubmitted: (_) => go(),
          decoration: InputDecoration(hintText: typeFilter == 0 ? '一次搜索: 书/漫画/视频/音乐' : '搜索${typeNames[typeFilter]}',
            prefixIcon: const Icon(Icons.search),
            isDense: true, filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none)))),
      const SizedBox(width: 8),
      FilledButton(onPressed: loading ? null : go, child: loading
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Text(tr('搜索')))])),
    Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 4), child: Align(alignment: Alignment.centerLeft,
      child: Wrap(spacing: 6, children: [
        for (var i = 0; i < typeNames.length; i++) ChoiceChip(
          label: Text(typeNames[i], style: const TextStyle(fontSize: 12)), selected: typeFilter == i,
          onSelected: (_) { setState(() => typeFilter = i); if (ctrl.text.trim().isNotEmpty) go(); }),
      ]))),
    // 数据来源状态行: 引擎直连(绿) / 资源库(灰) / 未连接(红)
    Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 2), child: Align(alignment: Alignment.centerLeft,
      child: Text(EngineDirect.connected ? '⚡ THP 引擎直连: ${EngineDirect.name}'
          : (Api.base.isNotEmpty ? '☁ 资源库模式' : '● 未连接引擎/资源库 — 请先连接'),
        style: TextStyle(fontSize: 10, color: EngineDirect.connected ? Colors.green
          : (Api.base.isNotEmpty ? Colors.grey : Colors.redAccent))))),
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      if (engItems != null) ...[
        Padding(padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
          child: Text('来自引擎「${EngineDirect.name}」 · THP 直连 · ${engItems!.length} 条结果',
            style: const TextStyle(fontSize: 11, color: Colors.grey))),
        if (engItems!.isEmpty) const Padding(padding: EdgeInsets.all(32),
          child: Center(child: Text('没有找到相关内容', style: TextStyle(color: Colors.grey)))),
        for (final t in const ['novel', 'comic', 'video', 'music']) ..._engGroup(c, t),
      ],
      if (agg == null && engItems == null && history.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [ const Icon(Icons.history, size: 15, color: Colors.grey), const SizedBox(width: 4),
            const Text('搜索历史', style: TextStyle(fontSize: 12, color: Colors.grey)), const Spacer(),
            GestureDetector(onTap: () async { final p = await SharedPreferences.getInstance();
                await p.remove('search_history'); setState(() => history = []); },
              child: const Icon(Icons.delete_outline, size: 16, color: Colors.grey)) ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [ for (final h in history)
            ActionChip(label: Text(h, style: const TextStyle(fontSize: 12)), visualDensity: VisualDensity.compact,
              onPressed: () { ctrl.text = h; go(); }) ]),
        ])),
      if (agg != null && agg!['single'] != null) ...[
        for (final g in ((agg!['single'] as List?) ?? [])) ...[
          if (g['ok'] == true) 
          for (final it in ((g['items'] ?? g['books']) as List? ?? [])) _singleTile(typeFilter, g['sourceId'] ?? '', it, context),
        ],
      ] else if (agg != null) ...[
        for (final g in (agg!['books'] as List? ?? []))
          group('📖 小说', (g['books'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(Map<String, dynamic>.from(b))))))),
        for (final g in (agg!['comics'] as List? ?? []))
          group('🎨 漫画', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['title'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ComicDetailPage(sourceId: g['sourceId'] ?? '', comicId: b['id'] ?? '', title: b['title'] ?? ''))))),
        for (final g in (agg!['videos'] as List? ?? []))
          group('🎬 视频', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['name'] ?? ''), subtitle: Text(b['type'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VideoDetailPage(sourceId: g['sourceId'] ?? '', vodId: b['id'] ?? '', title: b['name'] ?? ''))))),
        for (final g in (agg!['musics'] as List? ?? []))
          group('🎵 音乐', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, leading: const Icon(Icons.music_note, size: 20),
            title: Text(b['name'] ?? ''), subtitle: Text(b['artist'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => MusicPlayPage(item: Map<String, dynamic>.from(b), sourceId: g['sourceId'] ?? ''))))),
        if (((agg!['books'] as List?) ?? []).isEmpty && ((agg!['comics'] as List?) ?? []).isEmpty && ((agg!['videos'] as List?) ?? []).isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Text('没有找到相关内容', style: TextStyle(color: Colors.grey))),
      ],
      if (agg == null && !loading) const Padding(padding: EdgeInsets.all(40), child: Text('输入关键词开始搜索\n可全类型或按下方分类搜索', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
    ])), ]); }

  Widget _singleTile(int type, String sourceId, Map it, BuildContext context) {
    switch (type) {
      case 1: return ListTile(dense: true, title: Text(it['name'] ?? ''), subtitle: Text(it['author'] ?? ''),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(Map<String, dynamic>.from(it))))));
      case 2: return ListTile(dense: true, title: Text(it['title'] ?? ''),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ComicDetailPage(sourceId: sourceId, comicId: it['id'] ?? '', title: it['title'] ?? ''))));
      case 3: return ListTile(dense: true, title: Text(it['name'] ?? ''), subtitle: Text(it['type'] ?? ''),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VideoDetailPage(sourceId: sourceId, vodId: it['id'] ?? '', title: it['name'] ?? ''))));
      case 4: return ListTile(dense: true, leading: const Icon(Icons.music_note, size: 18),
        title: Text(it['name'] ?? ''), subtitle: Text(it['artist'] ?? ''),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MusicPlayPage(item: Map<String, dynamic>.from(it), sourceId: sourceId))));
      default: return const SizedBox.shrink();
    }
  }

// ═══ 板块一: 小说阅读器(功能完整) ═══
class NovelSection extends StatefulWidget { const NovelSection({super.key}); @override State<NovelSection> createState() => _Nv(); }
class _Nv extends State<NovelSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('书架'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [ShelfPage(kind: 'novel', builder: (b) => TocPage(book: b)),
      HistoryPage(kind: 'novel', builder: (b) => TocPage(book: b)),
      EngineDiscoverView(type: 'novel', onOpen: (it) => Navigator.push(c, MaterialPageRoute(builder: (_) => EngineItemPage(type: 'novel', item: it)))),
      const ModuleSearchTab(tab: 1)][sub]),
  ]); }

// 阅读历史(番茄式"历史"标签)
class HistoryPage extends StatefulWidget { final String kind; final Widget Function(Book) builder;
  const HistoryPage({super.key, required this.kind, required this.builder}); @override State<HistoryPage> createState() => _Hp(); }
class _Hp extends State<HistoryPage> { List<Book> items = []; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await Book.history(widget.kind); setState(() => loading = false); }
  @override Widget build(BuildContext c) => loading ? const Center(child: CircularProgressIndicator())
    : items.isEmpty ? const Center(child: Text('暂无阅读历史', style: TextStyle(color: Colors.grey)))
    : ListView(children: [ for (final b in items) ListTile(
        leading: b.coverUrl != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
          child: Image.network(Api.img(b.coverUrl), width: 40, height: 56, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : const Icon(Icons.history),
        title: Text(b.name), subtitle: Text(b.author, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => widget.builder(b))).then((_) => _load())) ]); }

class NovelSearchResults extends StatefulWidget { final String query; const NovelSearchResults({super.key, required this.query}); @override State<NovelSearchResults> createState() => _NSR(); }
class _NSR extends State<NovelSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; int _seq = 0; List<String> history = [];
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    final p = await SharedPreferences.getInstance();
    history.remove(q); history.insert(0, q); history = history.take(10).toList();
    await p.setStringList('sh_novel', history);
    setState(() { loading = true; groups = []; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('novel', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'books': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        throw Exception('未连接引擎或资源库');
      }
    }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    if (mounted) setState(() => loading = false); }
  Future<void> loadHistory() async { final p = await SharedPreferences.getInstance();
    history = p.getStringList('sh_novel') ?? []; if (mounted) setState(() {}); }
  @override void initState() { super.initState(); loadHistory(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(NovelSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      if (widget.query.isEmpty && history.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          for (final h in history) ActionChip(label: Text(h, style: const TextStyle(fontSize: 12)),
            onPressed: () => showSearch(context: context, delegate: ThSearchDelegate(1)..query = h)),
          GestureDetector(onTap: () async { final p = await SharedPreferences.getInstance();
            await p.remove('sh_novel'); setState(() => history = []); },
            child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.clear_all, size: 18, color: Colors.grey))),
        ])),
      for (final g in groups) ...[
        if (g['ok'] == true && (g['books'] as List?)?.isNotEmpty == true)
          
        for (final b in (g['books'] as List? ?? [])) ListTile(
          leading: (b['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(g['engine'] == true ? '${b['coverUrl']}' : Api.img(b['coverUrl']), width: 40, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
          title: Text(b['name'] ?? b['title'] ?? ''), subtitle: Text(b['author'] ?? ''),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => g['engine'] == true
            ? EngineItemPage(type: 'novel', item: Map<String, dynamic>.from(b))
            : TocPage(book: Book.from(Map<String, dynamic>.from(b)))))),
      ], if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('输入关键词搜索', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class ShelfPage extends StatefulWidget { final String kind; final Widget Function(Book) builder; const ShelfPage({super.key, required this.kind, required this.builder}); @override State<ShelfPage> createState() => _Sh(); }
class _Sh extends State<ShelfPage> { List<Book> items = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    items = await Book.shelf(widget.kind);
    // 云端书架同步读取: 后端资源库已下载的书(shelf_ 前缀)合并进书架, 换设备不丢
    if (widget.kind == 'novel' && Api.base.isNotEmpty) {
      try {
        final r = await Api.get('/v1/library');
        final cloudBooks = [for (final b in (r['data'] as List? ?? []))
          if ((b['id'] as String? ?? '').startsWith('shelf_'))
            Book(b['name'] ?? '', b['author'] ?? '', b['coverUrl'] ?? '', '', 'lib:${b['id']}', 'lib')];
        for (final cb in cloudBooks) {
          if (!items.any((x) => x.bookUrl == cb.bookUrl)) items.add(cb);
        }
      } catch (_) {}
    }
    setState(() => loading = false);
  }
  Future<void> remove(Book b) async { final p = await SharedPreferences.getInstance();
    await Trash.add('shelf', b.name, {'kind': widget.kind, 'book': b.toJson()});
    items.removeWhere((x) => x.bookUrl == b.bookUrl);
    await p.setString('shelf_${widget.kind}', jsonEncode(items.map((e) => e.toJson()).toList())); setState(() {}); }
  // 番茄式网格书架: 封面大图 + 书名 + 阅读进度
  @override Widget build(BuildContext c) => loading ? const Center(child: CircularProgressIndicator())
    : items.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.auto_stories_outlined, size: 56, color: Colors.grey.withValues(alpha: 0.5)),
      const SizedBox(height: 10),
      const Text('书架为空', style: TextStyle(color: Colors.grey, fontSize: 14)),
      const SizedBox(height: 4),
      const Text('搜索后进入详情页, 点书签图标加入', style: TextStyle(color: Colors.grey, fontSize: 11)),
    ]))
    : GridView.builder(padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.52, mainAxisSpacing: 12, crossAxisSpacing: 12),
        itemCount: items.length, itemBuilder: (_, i) {
        final b = items[i];
        final prog = AppSettings.p.getInt('progress_${b.bookUrl}') ?? -1;
        return GestureDetector(
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => widget.builder(b))).then((_) => load()),
          onLongPress: () async {
            final del = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(
              title: Text('移出书架'), content: Text('《${b.name}》'),
              actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('移出'))]));
            if (del == true) remove(b);
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.14), blurRadius: 8, offset: const Offset(0, 3))]),
              child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Stack(fit: StackFit.expand, children: [
                b.coverUrl != '' ? Image.network(Api.img(b.coverUrl), fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _coverFallback(b)) : _coverFallback(b),
                if (prog >= 0) Positioned(left: 0, right: 0, bottom: 0, child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54])),
                  child: Text('第${prog + 1}章', style: const TextStyle(fontSize: 9, color: Colors.white)))),
              ])))),
            const SizedBox(height: 4),
            Text(b.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.2)),
            Text(prog >= 0 ? '读到第${prog + 1}章' : (b.author.isNotEmpty ? b.author : '未开始'),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ])); });
  Widget _coverFallback(Book b) {
    const palette = [[0xFF5B7FFF, 0xFF8E5BFF], [0xFFFF7A59, 0xFFFFB347], [0xFF2EBD85, 0xFF56C6A9],
      [0xFFF06292, 0xFFBA68C8], [0xFF4DD0E1, 0xFF5B7FFF], [0xFFFFB74D, 0xFFFF8A65]];
    final h = b.name.codeUnits.fold<int>(0, (a, e) => (a + e) & 0x7fffffff);
    final pair = palette[h % palette.length];
    return Container(width: double.infinity, decoration: BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(pair[0]), Color(pair[1])])),
      alignment: Alignment.center, child: Text(b.name.isEmpty ? '?' : b.name.characters.first,
        style: const TextStyle(fontSize: 30, color: Colors.white, fontWeight: FontWeight.bold)));
  } }

class TocPage extends StatefulWidget { final Book book; const TocPage({super.key, required this.book}); @override State<TocPage> createState() => _T(); }
class _T extends State<TocPage> { List chapters = []; bool loading = true; int lastRead = -1;
  @override void initState() { super.initState(); Book.recordHistory(widget.book, 'novel'); load(); }
  Future<void> load() async { try {
      if (widget.book.sourceId == 'engine') {
        // 引擎直连书: 目录走 THP /thp/chapters
        chapters = await EngineDirect.chapters('novel', widget.book.bookUrl);
      } else if (widget.book.bookUrl.startsWith('lib:')) {
        // 后端资源库书: 全书已在库, 直接取目录
        final r = await Api.get('/v1/library/book?id=${Uri.encodeComponent(widget.book.bookUrl.substring(4))}');
        final chs = (r['data']?['chapters'] as List? ?? []);
        chapters = [for (var i = 0; i < chs.length; i++) {'name': chs[i]['name'] ?? '第${i + 1}章', 'url': '$i', 'index': i}];
      } else {
        final r = await Api.get('/v1/toc?sourceId=${Uri.encodeComponent(widget.book.sourceId)}&url=${Uri.encodeComponent(widget.book.bookUrl)}');
        chapters = r['data'] ?? [];
      } } catch (e) {}
    final p = await SharedPreferences.getInstance();
    lastRead = p.getInt('progress_${widget.book.bookUrl}') ?? -1;
    try { final r = await Api.get('/v1/reading-progress');
      final remote = r['data']?[widget.book.bookUrl];
      if (remote != null) lastRead = remote['index'] ?? lastRead; } catch (_) {}
    setState(() => loading = false); }
  Future<void> save() async {
    final t = await chooseDownloadTarget(context); if (t == null) return;
    await Book.add(widget.book, 'novel', target: t);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t == 'local' ? '已下载到本机书架' : t == 'backend' ? '已提交后端资源库下载' : tr('已加入书架')))); }
  void openAt(int i) => Navigator.push(context, MaterialPageRoute(builder: (_) => NovelReadPage(
    sourceId: widget.book.sourceId, chapters: chapters, index: i, bookName: widget.book.name, bookUrl: widget.book.bookUrl))).then((_) => load());
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.book.name), actions: [
      IconButton(icon: const Icon(Icons.bookmark_add), onPressed: save),
      Text('  ${chapters.length}章  ', style: const TextStyle(color: Colors.grey))]),
    body: loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
      if (lastRead >= 0 && lastRead < chapters.length) MaterialBanner(content: Text('上次读到: ${chapters[lastRead]['name'] ?? '第${lastRead + 1}章'}'),
        actions: [TextButton(onPressed: () => openAt(lastRead), child: Text(tr('继续阅读'))),
                  TextButton(onPressed: () => setState(() => lastRead = -1), child: const Text('关闭'))]),
      Expanded(child: ListView.builder(itemCount: chapters.length, itemBuilder: (_, i) => ListTile(
        title: Text(chapters[i]['name'] ?? ''), trailing: i == lastRead ? const Icon(Icons.history, size: 16, color: Colors.blueAccent) : null,
        onTap: () => openAt(i)))),
    ])); }

// 网络书籍阅读页: 适配到番茄式阅读器(目录/夜间/设置全内建)
class NovelReadPage extends StatelessWidget {
  final String sourceId, bookName, bookUrl; final List chapters; final int index;
  const NovelReadPage({super.key, required this.sourceId, required this.chapters, required this.index, required this.bookName, required this.bookUrl});
  @override Widget build(BuildContext c) => NovelReaderPage(
    sourceId: sourceId, chapters: chapters, index: index, bookName: bookName, bookUrl: bookUrl,
    fetchContent: (sid, url) async {
      if (sourceId == 'engine') {
        // 引擎直连书: 正文走 THP /thp/content (text/content 字段归一)
        final d = await EngineDirect.content('novel', bookUrl, url);
        if (d['text'] == null && d['content'] != null) d['text'] = d['content'];
        return d;
      }
      if (bookUrl.startsWith('lib:')) {
        final r = await Api.get('/v1/library/chapter?id=${Uri.encodeComponent(bookUrl.substring(4))}&index=${int.tryParse(url) ?? 0}');
        final d = Map<String, dynamic>.from(r['data'] ?? {});
        return {'content': d['text'] ?? d['content'] ?? ''};
      }
      final r = await Api.get('/v1/content?sourceId=${Uri.encodeComponent(sid)}&url=${Uri.encodeComponent(url)}');
      return Map<String, dynamic>.from(r['data'] ?? {});
    },
    onProgress: (i, name) async {
      try { await http.post(Uri.parse('${Api.base}/v1/reading-progress'),
        headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
        body: jsonEncode({'bookUrl': bookUrl, 'index': i, 'chapter': name})); } catch (_) {}
    });
}


// ═══ 板块二: 漫画播放器(UI先行, 数据源待后端comic引擎) ═══
class ComicSection extends StatefulWidget { const ComicSection({super.key}); @override State<ComicSection> createState() => _Cs(); }
class _Cs extends State<ComicSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('书架'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [ShelfPage(kind: 'comic', builder: (b) => ComicDetailPage(sourceId: b.sourceId, comicId: b.bookUrl, title: b.name)),
      HistoryPage(kind: 'comic', builder: (b) => ComicDetailPage(sourceId: b.sourceId, comicId: b.bookUrl, title: b.name)),
      EngineDiscoverView(type: 'comic', onOpen: (it) => Navigator.push(c, MaterialPageRoute(builder: (_) => EngineItemPage(type: 'comic', item: it)))),
      const ModuleSearchTab(tab: 2)][sub]),
  ]); }

class ComicSearchResults extends StatefulWidget { final String query; const ComicSearchResults({super.key, required this.query}); @override State<ComicSearchResults> createState() => _CSR(); }
class _CSR extends State<ComicSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; int _seq = 0;
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    setState(() { loading = true; groups = []; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('comic', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'items': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/comic/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        throw Exception('未连接引擎或资源库');
      }
    }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    if (mounted) setState(() => loading = false); }
  @override void initState() { super.initState(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(ComicSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['ok'] == true && (g['items'] as List?)?.isNotEmpty == true)
          
        for (final b in (g['items'] as List? ?? [])) ListTile(
          leading: (b['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(g['engine'] == true ? '${b['coverUrl']}' : Api.img(b['coverUrl']), width: 40, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
          title: Text(b['title'] ?? b['name'] ?? ''), subtitle: Text(b['subTitle'] ?? b['author'] ?? ''),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => g['engine'] == true
            ? EngineItemPage(type: 'comic', item: Map<String, dynamic>.from(b))
            : ComicDetailPage(sourceId: g['sourceId'] ?? '', comicId: b['id'] ?? '', title: b['title'] ?? '')))),
      ],
            if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('没有找到相关漫画', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class ComicDetailPage extends StatefulWidget { final String sourceId, comicId, title; const ComicDetailPage({super.key, required this.sourceId, required this.comicId, required this.title}); @override State<ComicDetailPage> createState() => _Cd(); }
class _Cd extends State<ComicDetailPage> {
  Map<String, dynamic>? info; List chapters = []; bool loading = true; String? err; int lastRead = -1;
  @override void initState() { super.initState();
    Book.recordHistory(Book(widget.title, '', '', '', widget.comicId, widget.sourceId), 'comic');
    load(); }
  Future<void> load() async { try {
      final r = await Api.get('/v1/comic/info?sourceId=${Uri.encodeComponent(widget.sourceId)}&id=${Uri.encodeComponent(widget.comicId)}');
      if (r['object'] == 'error') { err = r['data']?['message'] ?? '失败'; }
      else { info = r['data']; chapters = info?['chapters'] ?? []; }
      final p = await SharedPreferences.getInstance();
      lastRead = p.getInt('cprog_${widget.comicId}') ?? -1;
    } catch (e) { err = '$e'; }
    setState(() => loading = false); }
  Future<void> save() async {
    final t = await chooseDownloadTarget(context); if (t == null) return;
    await Book.add(Book(widget.title, (info?['tags'] ?? []).join('/'), info?['coverUrl'] ?? '', info?['description'] ?? '', widget.comicId, widget.sourceId), 'comic', target: t);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('已加入书架')))); }
  void openAt(int i) => Navigator.push(context, MaterialPageRoute(builder: (_) => ComicReaderPage(
    sourceId: widget.sourceId, comicId: widget.comicId, chapters: chapters, index: i))).then((_) => load());
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title), actions: [
      IconButton(icon: const Icon(Icons.bookmark_add), onPressed: save),
      Text('  ${chapters.length}话  ', style: const TextStyle(color: Colors.grey))]),
    body: loading ? const Center(child: CircularProgressIndicator())
    : err != null ? Center(child: Text(err!, style: const TextStyle(color: Colors.red)))
    : Column(children: [
      if (lastRead >= 0 && lastRead < chapters.length) MaterialBanner(content: Text('上次读到: ${chapters[lastRead]['title']}'),
        actions: [TextButton(onPressed: () => openAt(lastRead), child: Text(tr('继续阅读'))),
                  TextButton(onPressed: () => setState(() => lastRead = -1), child: const Text('关闭'))]),
      Expanded(child: ListView.builder(itemCount: chapters.length, itemBuilder: (_, i) => ListTile(
        title: Text(chapters[i]['title'] ?? ''), subtitle: (chapters[i]['time'] ?? '') != '' ? Text(chapters[i]['time'], style: const TextStyle(fontSize: 11, color: Colors.grey)) : null,
        onTap: () => openAt(i)))),
    ])); }

class ComicReaderPage extends StatefulWidget { final String sourceId, comicId; final List chapters; final int index;
  const ComicReaderPage({super.key, required this.sourceId, required this.comicId, required this.chapters, required this.index});
  @override State<ComicReaderPage> createState() => _Cr(); }
class _Cr extends State<ComicReaderPage> {
  List<String> images = []; bool loading = true; String? err; int get idx => widget.index;
  final Map<int, List<String>> pageCache = {}; // 预加载缓存: 话index → 图片URL列表
  bool get hasPrev => idx > 0; bool get hasNext => idx < widget.chapters.length - 1;
  @override void initState() { super.initState(); load(); }
  Future<void> preload(int i) async { if (i < 0 || i >= widget.chapters.length || pageCache.containsKey(i)) return;
    try { final ch = widget.chapters[i];
      final r = await Api.get('/v1/comic/pages?sourceId=${Uri.encodeComponent(widget.sourceId)}&chapterId=${Uri.encodeComponent(ch['id'] ?? '')}');
      if (r['object'] != 'error') pageCache[i] = List<String>.from(r['data']?['images'] ?? []);
    } catch (_) {} }
  Future<void> load() async { setState(() { loading = true; err = null; images = []; }); try {
      if (pageCache.containsKey(idx)) { images = pageCache[idx]!; }
      else {
        final ch = widget.chapters[idx];
        final r = await Api.get('/v1/comic/pages?sourceId=${Uri.encodeComponent(widget.sourceId)}&chapterId=${Uri.encodeComponent(ch['id'] ?? '')}');
        if (r['object'] == 'error') { err = r['data']?['message'] ?? '失败'; }
        else { images = List<String>.from(r['data']?['images'] ?? []); pageCache[idx] = images; }
      }
      final p = await SharedPreferences.getInstance(); await p.setInt('cprog_${widget.comicId}', idx);
      // 预加载下一话和上一话(翻话秒开)
      preload(idx + 1); preload(idx - 1);
    } catch (e) { err = '$e'; }
    setState(() => loading = false); }
  void goChapter(int i) => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ComicReaderPage(
    sourceId: widget.sourceId, comicId: widget.comicId, chapters: widget.chapters, index: i)));
  int _page = 0;
  @override Widget build(BuildContext c) {
    final paged = (AppSettings.p.getString('comic_mode') ?? 'webtoon') == 'paged';
    return Scaffold(appBar: AppBar(title: Text('${widget.chapters[idx]['title'] ?? ''}  (${idx + 1}/${widget.chapters.length})', style: const TextStyle(fontSize: 14)), actions: [
        IconButton(icon: Icon(paged ? Icons.view_agenda_outlined : Icons.chrome_reader_mode_outlined), tooltip: paged ? '切条漫' : '切翻页',
          onPressed: () { AppSettings.p.setString('comic_mode', paged ? 'webtoon' : 'paged'); setState(() {}); }),
      ]),
    body: Column(children: [
      Expanded(child: loading ? const Center(child: CircularProgressIndicator())
        : err != null ? Center(child: Text(err!, style: const TextStyle(color: Colors.red)))
        : images.isEmpty ? const Center(child: Text('本章无图片'))
        : paged
          ? PageView.builder(itemCount: images.length, onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) => InteractiveViewer(maxScale: 5, child: Center(child: Image.network(Api.img(images[i]), fit: BoxFit.contain,
                loadingBuilder: (_, w, p) => p == null ? w : const Center(child: CircularProgressIndicator()),
                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey)))))
          : ListView.builder(itemCount: images.length, itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 1),
              child: InteractiveViewer(child: Image.network(Api.img(images[i]), fit: BoxFit.fitWidth,
                loadingBuilder: (_, w, p) => p == null ? w : const SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
                errorBuilder: (_, __, ___) => const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image, color: Colors.grey)))))))),
      SafeArea(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        TextButton.icon(onPressed: hasPrev ? () => goChapter(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: Text(tr('上一话'))),
        if (paged) Text('${_page + 1}/${images.length}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        TextButton.icon(onPressed: hasNext ? () => goChapter(idx + 1) : null, label: Text(tr('下一话')), icon: const Icon(Icons.chevron_right)),
      ]))])); }
}

// ═══ 板块四: 音乐播放器 ═══
class MusicSection extends StatefulWidget { const MusicSection({super.key}); @override State<MusicSection> createState() => _Ms(); }
class _Ms extends State<MusicSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('歌单'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [const _MusicPlaylist(),
      HistoryPage(kind: 'music', builder: (b) => MusicPlayPage(item: {'name': b.name, 'url': b.bookUrl, 'artist': b.author, 'coverUrl': b.coverUrl}, sourceId: b.sourceId)),
      EngineDiscoverView(type: 'music', onOpen: (it) => Navigator.push(c, MaterialPageRoute(builder: (_) => EngineItemPage(type: 'music', item: it)))),
      const ModuleSearchTab(tab: 4)][sub]),
  ]); }

class _MusicPlaylist extends StatefulWidget { const _MusicPlaylist(); @override State<_MusicPlaylist> createState() => _MpList(); }
class _MpList extends State<_MusicPlaylist> {
  List<Map> items = []; List<Map<String, dynamic>> local = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    try { items = (jsonDecode(p.getString('playlist') ?? '[]') as List).cast<Map>(); } catch (_) {}
    local = await LocalLib.list('music'); // 本地导入的音乐也进歌单体系
    setState(() => loading = false); }
  Future<void> remove(Map m) async { final p = await SharedPreferences.getInstance();
    await Trash.add('music', '${m['name'] ?? ''}', {'item': Map<String, dynamic>.from(m)});
    items.removeWhere((x) => x['id'] == m['id']);
    await p.setString('playlist', jsonEncode(items)); setState(() {}); }
  @override Widget build(BuildContext c) => loading ? const Center(child: CircularProgressIndicator())
    : (items.isEmpty && local.isEmpty) ? const Center(child: Text('歌单为空\n播放过的歌自动入单 · 本地导入的歌也在这里', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
    : ListView(children: [
      if (local.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Text('本地音乐', style: TextStyle(fontSize: 12, color: Colors.grey))),
      for (final m in local) ListTile(
        leading: const Icon(Icons.music_note),
        title: Text(m['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: const Text('本地', style: TextStyle(fontSize: 11)),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => MusicPlayPage(item: {'name': m['name'], 'url': m['path'], 'artist': '本地', 'coverUrl': ''}))),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await LocalLib.remove('music', m['path']); load(); })),
      if (items.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(12, 10, 12, 2),
        child: Text('歌单', style: TextStyle(fontSize: 12, color: Colors.grey))),
      for (final m in items) ListTile(
        leading: (m['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
          child: Image.network(Api.img(m['coverUrl']), width: 44, height: 44, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox(width: 44, height: 44))) : const Icon(Icons.music_note),
        title: Text(m['name'] ?? ''), subtitle: Text(m['artist'] ?? ''),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => MusicPlayPage(item: m, sourceId: m['sourceId'] as String? ?? ''))),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => remove(m))) ]); }

class MusicSearchResults extends StatefulWidget { final String query; const MusicSearchResults({super.key, required this.query}); @override State<MusicSearchResults> createState() => _MSR(); }
class _MSR extends State<MusicSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; int _seq = 0;
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    setState(() { loading = true; groups = []; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('music', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'items': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/music/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        throw Exception('未连接引擎或资源库');
      }
    }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override void initState() { super.initState(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(MusicSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  Future<void> play(Map item, String sourceId) async {
    // 入歌单
    final p = await SharedPreferences.getInstance();
    final list = (jsonDecode(p.getString('playlist') ?? '[]') as List).cast<Map>();
    if (!list.any((x) => x['id'] == item['id'])) { list.add({...item, 'sourceId': sourceId}); await p.setString('playlist', jsonEncode(list)); }
    if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => MusicPlayPage(item: item, sourceId: sourceId)));
  }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['ok'] == true && (g['items'] as List?)?.isNotEmpty == true)
          
        for (final m in (g['items'] as List? ?? [])) ListTile(
          leading: (m['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(g['engine'] == true ? '${m['coverUrl']}' : Api.img(m['coverUrl']), width: 44, height: 44, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 44, height: 44))) : const Icon(Icons.music_note),
          title: Text(m['name'] ?? ''), subtitle: Text('${m['artist'] ?? ''} · ${m['album'] ?? ''}'.trim()),
          trailing: const Icon(Icons.play_arrow),
          onTap: () => g['engine'] == true
            ? Navigator.push(c, MaterialPageRoute(builder: (_) => EngineItemPage(type: 'music', item: Map<String, dynamic>.from(m))))
            : play(Map<String, dynamic>.from(m), g['sourceId'] ?? '')),
      ],
      if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('没有找到相关音乐', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class MusicPlayPage extends StatefulWidget { final Map item; final String sourceId; const MusicPlayPage({super.key, required this.item, this.sourceId = ''}); @override State<MusicPlayPage> createState() => _MPlay(); }
class _MPlay extends State<MusicPlayPage> {
  final AudioPlayer player = AudioPlayer(); bool loading = true; String? err; String lyric = '';
  // LRC 歌词: (毫秒, 文本) 有序列表; 纯文本歌词则只有一行无法同步
  List<({int ms, String text})> lrc = [];
  final PageController _coverPager = PageController(); int _coverPage = 0; // 0封面 1歌词(左右滑动切换)
  final ScrollController _lrcScroll = ScrollController(); int _lrcLine = -1;
  bool get showLyric => _coverPage == 1;
  List<Map> queue = []; int qIdx = -1; late Map cur; late String curSource;
  Timer? _posTimer; bool _resumed = false;
  String get _posKey => 'mpos_${cur['url'] ?? cur['id'] ?? cur['name']}';
  void _savePos() { if (player.playing && player.position.inSeconds > 5) AppSettings.p.setInt(_posKey, player.position.inSeconds); }
  Future<void> _restorePos() async {
    final s = AppSettings.p.getInt(_posKey) ?? 0;
    final dur = player.duration ?? Duration.zero;
    if (s > 10 && (dur == Duration.zero || s < dur.inSeconds - 10)) {
      await player.seek(Duration(seconds: s));
      if (mounted && !_resumed) { _resumed = true;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已从 ${_fmt(Duration(seconds: s))} 继续播放'), duration: const Duration(seconds: 2))); }
    }
  }
  @override void initState() { super.initState(); cur = widget.item; curSource = widget.sourceId; _loadQueue(); start(); _initEq();
    _posTimer = Timer.periodic(const Duration(seconds: 3), (_) => _savePos());
    // 记录音乐历史
    Book.recordHistory(Book(cur['name'] ?? '', cur['artist'] ?? '', cur['coverUrl'] ?? '', '', cur['url'] ?? cur['id'] ?? '', curSource), 'music'); }
  Future<void> _loadQueue() async {
    final p = await SharedPreferences.getInstance();
    try { queue = (jsonDecode(p.getString('playlist') ?? '[]') as List).cast<Map>(); } catch (_) {}
    qIdx = queue.indexWhere((x) => x['id'] == cur['id'] && cur['id'] != null);
    if (mounted) setState(() {});
    // 播完自动下一首(按播放模式)
    player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) { AppSettings.p.remove(_posKey); _next(auto: true); }
    });
  }
  String get playMode => AppSettings.p.getString('play_mode') ?? 'seq';
  void _next({bool auto = false}) {
    if (queue.isEmpty) return;
    if (auto && playMode == 'one') { player.seek(Duration.zero); player.play(); return; }
    var n = qIdx;
    if (playMode == 'rand' && queue.length > 1) { do { n = (n + 1 + (DateTime.now().millisecond % (queue.length - 1))) % queue.length; } while (n == qIdx); }
    else { n = (qIdx + 1) % queue.length; }
    _switchTo(n);
  }
  void _prev() { if (queue.isEmpty) return; _switchTo((qIdx - 1 + queue.length) % queue.length); }
  Future<void> _switchTo(int i) async {
    qIdx = i; cur = queue[i]; curSource = cur['sourceId'] as String? ?? '';
    lyric = ''; lrc = []; _lrcLine = -1; setState(() { loading = true; err = null; });
    await start();
  }
  // 解析 LRC: [mm:ss.xx] 时间戳行 → 有序 (ms, text); 无时间戳则返回空
  static List<({int ms, String text})> _parseLrc(String raw) {
    final out = <({int ms, String text})>[];
    final re = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    for (final line in const LineSplitter().convert(raw)) {
      final ms = re.allMatches(line).toList();
      if (ms.isEmpty) continue;
      final text = line.replaceAll(re, '').trim();
      for (final m0 in ms) {
        final mm = int.parse(m0.group(1)!), ss = int.parse(m0.group(2)!);
        var frac = m0.group(3) ?? '0';
        if (frac.length == 1) frac = frac + '00'; else if (frac.length == 2) frac = frac + '0';
        out.add((ms: mm * 60000 + ss * 1000 + (int.tryParse(frac.substring(0, 3)) ?? 0), text: text));
      }
    }
    out.sort((a, b) => a.ms.compareTo(b.ms));
    return out;
  }
  // 歌词获取: 内联字段(lrc/lyric, 支持文本或URL) → 本地同名.lrc → 后端 /v1/music/lyric
  Future<void> _loadLyric(String playUrl) async {
    String raw = '';
    try {
      for (final k in ['lrc', 'lyric', 'lrcUrl']) {
        final v = '${cur[k] ?? ''}'.trim();
        if (v.isEmpty) continue;
        if (v.startsWith('http')) { final r = await http.get(Uri.parse(v)); if (r.statusCode == 200) { raw = utf8.decode(r.bodyBytes); break; } }
        else { raw = v; break; }
      }
      if (raw.isEmpty && (playUrl.startsWith('/') || playUrl.startsWith('file://'))) {
        final path = playUrl.replaceFirst('file://', '');
        final dot = path.lastIndexOf('.');
        final lf = File('${dot > 0 ? path.substring(0, dot) : path}.lrc');
        if (await lf.exists()) { final b = await lf.readAsBytes();
          try { raw = utf8.decode(b); } catch (_) { raw = latin1.decode(b); } }
      }
      if (raw.isEmpty && curSource.isNotEmpty) {
        final l = await Api.get('/v1/music/lyric?sourceId=${Uri.encodeComponent(curSource)}&item=${Uri.encodeComponent(jsonEncode(cur))}');
        raw = l['data']?['lyric'] as String? ?? '';
      }
    } catch (_) {}
    if (!mounted || raw.isEmpty) return;
    setState(() { lyric = raw; lrc = _parseLrc(raw); });
  }
  Future<void> start() async {
    try {
      String playUrl = cur['url'] as String? ?? '';
      if (playUrl.isEmpty && curSource.isNotEmpty) {
        final q = AppSettings.p.getString('music_quality') ?? '320k';
        final r = await Api.get('/v1/music/url?sourceId=${Uri.encodeComponent(curSource)}&quality=$q&item=${Uri.encodeComponent(jsonEncode(cur))}');
        playUrl = r['data']?['url'] as String? ?? '';
      }
      if (playUrl.isEmpty) { setState(() { loading = false; err = '暂时无法播放这首歌'; }); return; }
      final mediaItem = MediaItem(id: '${cur['id'] ?? playUrl}', title: '${cur['name'] ?? ''}',
        artist: '${cur['artist'] ?? ''}', artUri: Uri.tryParse('${cur['coverUrl'] ?? ''}'));
      if (playUrl.startsWith('/') || playUrl.startsWith('file://')) { await player.setAudioSource(AudioSource.file(playUrl.replaceFirst('file://', ''), tag: mediaItem)); }
      else { await player.setAudioSource(AudioSource.uri(Uri.parse(playUrl), tag: mediaItem)); }
      await _restorePos();
      await player.play();
      setState(() => loading = false);
      // 歌词(尽力而为, 支持LRC同步)
      unawaited(_loadLyric(playUrl));
    } catch (e) { setState(() { loading = false; err = '$e'; }); } }
  @override void dispose() { _posTimer?.cancel(); _sleepTimer?.cancel(); _eqSub?.cancel(); _savePos(); _coverPager.dispose(); _lrcScroll.dispose(); player.dispose(); super.dispose(); }
  String _fmt(Duration d) { final m = d.inMinutes.toString().padLeft(2, '0'); final s = (d.inSeconds % 60).toString().padLeft(2, '0'); return '$m:$s'; }
  IconData get _modeIcon => playMode == 'one' ? Icons.repeat_one : playMode == 'rand' ? Icons.shuffle : Icons.repeat;
  void _cycleMode() { final modes = ['seq', 'one', 'rand']; final n = (modes.indexOf(playMode) + 1) % 3;
    AppSettings.p.setString('play_mode', modes[n]); setState(() {}); }
  void _queueSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (c2) => DraggableScrollableSheet(
      initialChildSize: 0.55, expand: false, builder: (_, sc) => Column(children: [
        const Padding(padding: EdgeInsets.all(12), child: Text('播放队列', style: TextStyle(fontWeight: FontWeight.bold))),
        Expanded(child: queue.isEmpty ? const Center(child: Text('队列为空', style: TextStyle(color: Colors.grey)))
          : ListView.builder(controller: sc, itemCount: queue.length, itemBuilder: (_, i) => ListTile(dense: true, selected: i == qIdx,
              leading: i == qIdx ? const Icon(Icons.graphic_eq, color: Colors.blueAccent, size: 18) : const Icon(Icons.music_note, size: 18),
              title: Text(queue[i]['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: Text(queue[i]['artist'] ?? '', style: const TextStyle(fontSize: 11)),
              onTap: () { Navigator.pop(c2); _switchTo(i); }))),
      ])));
  }
  // ── 均衡器(Android audiofx, 挂播放会话) ──
  static const _eqCh = MethodChannel('thirdhub/eq');
  int? _eqSession; Map<String, dynamic>? _eqInfo; List<int> _eqLevels = [];
  StreamSubscription? _eqSub;
  void _initEq() {
    _eqSub = player.androidAudioSessionIdStream.listen((sid) async {
      _eqSession = sid;
      if (sid == null) return;
      try {
        final r = await _eqCh.invokeMethod('attach', {'sessionId': sid});
        if (r is Map && mounted) setState(() {
          _eqInfo = Map<String, dynamic>.from(r);
          _eqLevels = (r['levels'] as List).cast<int>();
        });
      } catch (_) {}
    });
  }

  void _eqSheet() {
    if (_eqInfo == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('等待音频会话就绪…'), duration: Duration(seconds: 1)));
      return;
    }
    final min = (_eqInfo!['min'] as num).toInt(), max = (_eqInfo!['max'] as num).toInt();
    final freqs = (_eqInfo!['freqs'] as List).cast<num>();
    final presets = (_eqInfo!['presets'] as List).cast<String>();
    showModalBottomSheet(context: context, isScrollControlled: true,
      builder: (c2) => StatefulBuilder(builder: (c2, setD) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('均衡器', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SizedBox(height: 34, child: ListView(scrollDirection: Axis.horizontal, children: [
            for (var pi = 0; pi < presets.length; pi++)
              Padding(padding: const EdgeInsets.only(right: 6), child: ActionChip(
                label: Text(presets[pi], style: const TextStyle(fontSize: 11)),
                onPressed: () async {
                  final r = await _eqCh.invokeMethod('preset', {'index': pi});
                  if (r is List) setD(() => _eqLevels = r.cast<int>());
                  if (mounted) setState(() {});
                })),
          ])),
          const SizedBox(height: 8),
          SizedBox(height: 170, child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            for (var b = 0; b < _eqLevels.length; b++)
              Column(children: [
                Expanded(child: RotatedBox(quarterTurns: 3, child: Slider(
                  value: _eqLevels[b].clamp(min, max).toDouble(), min: min.toDouble(), max: max.toDouble(),
                  onChanged: (v) {
                    setD(() => _eqLevels[b] = v.round());
                    _eqCh.invokeMethod('setBand', {'band': b, 'level': v.round()});
                  }))),
                Text(freqs[b] >= 1000 ? '${(freqs[b] / 1000).toStringAsFixed(1)}k' : '${freqs[b].round()}',
                  style: const TextStyle(fontSize: 9, color: Colors.grey)),
              ]),
          ])),
          Text('${min ~/ 100}.${(min.abs() % 100) ~/ 10}dB ~ +${max ~/ 100}dB · 拖滑杆或选预设', style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ])))));
  }

  // ── 睡眠定时 ──
  DateTime? _sleepEnd; Timer? _sleepTimer;
  void _sleepSheet() {
    showModalBottomSheet(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('睡眠定时', style: TextStyle(fontWeight: FontWeight.bold))),
      if (_sleepEnd != null) ListTile(dense: true, leading: const Icon(Icons.bedtime, color: Colors.blueAccent),
        title: Text('将于 ${_sleepEnd!.hour.toString().padLeft(2, '0')}:${_sleepEnd!.minute.toString().padLeft(2, '0')} 停止播放', style: const TextStyle(fontSize: 13)),
        trailing: TextButton(onPressed: () { _sleepTimer?.cancel(); setState(() => _sleepEnd = null); Navigator.pop(c2); }, child: const Text('取消'))),
      for (final m in [10, 20, 30, 45, 60, 90])
        ListTile(dense: true, leading: const Icon(Icons.timer_outlined, size: 20), title: Text('$m 分钟后停止'),
          onTap: () { _setSleep(m); Navigator.pop(c2); }),
      ListTile(dense: true, leading: const Icon(Icons.music_off, size: 20), title: const Text('播完本曲停止'),
        onTap: () { _setSleep(-1); Navigator.pop(c2); }),
      const Divider(),
      const Padding(padding: EdgeInsets.all(8), child: Text('倍速', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
          ChoiceChip(label: Text('${s}x', style: const TextStyle(fontSize: 12)),
            selected: (player.speed - s).abs() < 0.01,
            onSelected: (_) { player.setSpeed(s); setD(() {}); }),
      ]),
      const SizedBox(height: 12),
    ]))));
  }
  void _setSleep(int minutes) {
    _sleepTimer?.cancel();
    if (minutes < 0) {
      // 播完本曲: 监听完成事件, 播完不自动下一首
      _sleepTimer = Timer(player.duration != null ? player.duration! - player.position : const Duration(minutes: 5), () {
        player.pause(); setState(() => _sleepEnd = null);
      });
      setState(() => _sleepEnd = DateTime.now().add(player.duration != null ? player.duration! - player.position : const Duration(minutes: 5)));
    } else {
      _sleepEnd = DateTime.now().add(Duration(minutes: minutes));
      _sleepTimer = Timer(Duration(minutes: minutes), () async {
        await player.pause(); // 淡出体验: 先降音量再停
        if (mounted) setState(() => _sleepEnd = null);
      });
    }
    if (mounted) setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(minutes < 0 ? '将在本曲播完后停止' : '$minutes 分钟后停止播放'), duration: const Duration(seconds: 1)));
  }

  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(cur['name'] ?? '', style: const TextStyle(fontSize: 15)), actions: [
      IconButton(icon: const Icon(Icons.favorite_border), tooltip: '收藏到歌单架',
        onPressed: () async { await Book.add(Book(cur['name'] ?? '', cur['artist'] ?? '', cur['coverUrl'] ?? '', '', cur['url'] ?? cur['id'] ?? '', curSource), 'music');
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已收藏到音乐架'), duration: Duration(seconds: 1))); }),
      IconButton(icon: Icon(showLyric ? Icons.album : Icons.lyrics_outlined), tooltip: showLyric ? '封面' : '歌词',
        onPressed: () => _coverPager.animateToPage(showLyric ? 0 : 1, duration: const Duration(milliseconds: 240), curve: Curves.easeOut)),
      IconButton(icon: Icon(Icons.equalizer, color: _eqInfo != null ? null : Colors.grey), tooltip: '均衡器', onPressed: _eqSheet),
      IconButton(icon: Icon(Icons.bedtime_outlined, color: _sleepEnd != null ? Theme.of(context).colorScheme.primary : null),
        tooltip: '睡眠定时', onPressed: _sleepSheet),
      IconButton(icon: const Icon(Icons.queue_music), tooltip: '播放队列', onPressed: _queueSheet)]),
    body: SafeArea(child: Column(children: [
      const SizedBox(height: 12),
      // 封面 ↔ 歌词: 左右滑动切换(落雪/venera 同款手势)
      Expanded(child: Column(children: [
        Expanded(child: PageView(controller: _coverPager,
          onPageChanged: (i) => setState(() => _coverPage = i),
          children: [
            // 封面页
            Center(child: ClipRRect(borderRadius: BorderRadius.circular(16),
              child: (cur['coverUrl'] ?? '') != ''
                ? Image.network(Api.img(cur['coverUrl']), width: 230, height: 230, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 140))
                : const Icon(Icons.music_note, size: 140))),
            // 歌词页: LRC同步高亮+自动滚动; 无时间戳则整段展示
            lyric.isEmpty ? const Center(child: Text('暂无歌词', style: TextStyle(color: Colors.grey)))
            : lrc.isEmpty ? SingleChildScrollView(padding: const EdgeInsets.all(20),
                child: Text(lyric, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, height: 1.8)))
            : StreamBuilder<Duration>(stream: player.positionStream, builder: (_, ps) {
                final pos = (ps.data ?? Duration.zero).inMilliseconds;
                var curLine = 0;
                for (var i = 0; i < lrc.length; i++) { if (lrc[i].ms <= pos) curLine = i; else break; }
                if (curLine != _lrcLine) { _lrcLine = curLine;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_lrcScroll.hasClients) _lrcScroll.animateTo((curLine * 40.0 - 120).clamp(0.0, _lrcScroll.position.maxScrollExtent).toDouble(),
                      duration: const Duration(milliseconds: 300), curve: Curves.easeOut); });
                }
                final scheme = Theme.of(c).colorScheme;
                return ListView.builder(controller: _lrcScroll, padding: const EdgeInsets.symmetric(vertical: 140, horizontal: 16),
                  itemCount: lrc.length, itemExtent: 40, itemBuilder: (_, i) {
                    final on = i == curLine;
                    return Center(child: AnimatedDefaultTextStyle(duration: const Duration(milliseconds: 200),
                      style: TextStyle(fontSize: on ? 16 : 13, height: 1.4,
                        fontWeight: on ? FontWeight.bold : FontWeight.normal,
                        color: on ? scheme.primary : scheme.onSurface.withValues(alpha: 0.45)),
                      child: Text(lrc[i].text.isEmpty ? '·' : lrc[i].text, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center)));
                  });
              }),
          ])),
        // 页点指示
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 0; i < 2; i++) AnimatedContainer(duration: const Duration(milliseconds: 200),
            width: _coverPage == i ? 16 : 6, height: 6, margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(3),
              color: _coverPage == i ? Theme.of(c).colorScheme.primary : Colors.grey.withValues(alpha: 0.35))),
        ])),
      ])),
      const SizedBox(height: 8),
      Text(cur['name'] ?? '', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
      Text(cur['artist'] ?? '', style: const TextStyle(color: Colors.grey, fontSize: 13)),
      const SizedBox(height: 8),
      // 进度条(可拖动)
      if (loading) const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator())
      else if (err != null) Padding(padding: const EdgeInsets.all(16), child: Text(err!, style: const TextStyle(color: Colors.red)))
      else StreamBuilder<Duration>(stream: player.positionStream, builder: (_, ps) {
        final pos = ps.data ?? Duration.zero;
        final dur = player.duration ?? Duration.zero;
        return Column(children: [
          Slider(value: dur.inMilliseconds > 0 ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0,
            onChanged: dur.inMilliseconds > 0 ? (v) => player.seek(Duration(milliseconds: (v * dur.inMilliseconds).round())) : null),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_fmt(pos), style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(_fmt(dur), style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ])),
        ]);
      }),
      // 控制区: 模式/上一首/播放/下一首/队列
      StreamBuilder<PlayerState>(stream: player.playerStateStream, builder: (_, s) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        IconButton(icon: Icon(_modeIcon), iconSize: 24, onPressed: _cycleMode),
        IconButton(icon: const Icon(Icons.skip_previous), iconSize: 34, onPressed: queue.isEmpty ? null : _prev),
        IconButton(icon: Icon(s.data?.playing == true ? Icons.pause_circle_filled : Icons.play_circle_filled), iconSize: 62,
          color: Theme.of(c).colorScheme.primary,
          onPressed: () => s.data?.playing == true ? player.pause() : player.play()),
        IconButton(icon: const Icon(Icons.skip_next), iconSize: 34, onPressed: queue.isEmpty ? null : () => _next()),
        IconButton(icon: const Icon(Icons.stop_circle_outlined), iconSize: 24, onPressed: () { player.stop(); Navigator.pop(c); }),
      ])),
      const SizedBox(height: 14),
    ]))); }

// ═══ 板块三: 视频播放器(UI先行, 数据源待后端drpy引擎) ═══
// 视频模块 = 片库 + 历史 + 引擎发现(直播已拆到独立「直播」模块)
class VideoSection extends StatefulWidget { const VideoSection({super.key}); @override State<VideoSection> createState() => _Vs(); }
class _Vs extends State<VideoSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('片库'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [const ShelfPage(kind: 'video', builder: _videoDetail),
      HistoryPage(kind: 'video', builder: _videoDetail),
      EngineDiscoverView(type: 'video', onOpen: (it) => Navigator.push(c, MaterialPageRoute(builder: (_) => EngineItemPage(type: 'video', item: it)))),
      const ModuleSearchTab(tab: 3),
    ][sub]),
  ]); }

// 直播: drpy直播源搜索频道→直接播放(m3u8直播流)
class LivePage extends StatefulWidget { const LivePage({super.key}); @override State<LivePage> createState() => _Live(); }
class _Live extends State<LivePage> {
  final ctrl = TextEditingController(); List<Map> channels = []; bool loading = false;
  Future<void> go([String? preset]) async { final q = preset ?? ctrl.text.trim(); if (q.isEmpty) return;
    setState(() { loading = true; channels = []; });
    try { final r = await Api.get('/v1/video/search?q=${Uri.encodeComponent(q)}');
      for (final g in (r['data'] as List? ?? [])) {
        if (g['ok'] == true) for (final it in (g['items'] as List? ?? [])) channels.add({...Map<String, dynamic>.from(it), 'sourceId': g['sourceId']});
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '搜频道(如:央视/卫视/电影)', border: OutlineInputBorder(), isDense: true), onSubmitted: (_) => go())),
      IconButton(icon: const Icon(Icons.search), onPressed: () => go())])),
    Wrap(spacing: 8, children: [ for (final h in ['央视', '卫视', '电影', '动漫'])
      ActionChip(label: Text(h, style: const TextStyle(fontSize: 12)), onPressed: () { ctrl.text = h; go(h); }) ]),
    if (loading) const LinearProgressIndicator(),
    Expanded(child: channels.isEmpty
      ? const Center(child: Text('搜索频道名, 或点上方热词', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.75),
        itemCount: channels.length, itemBuilder: (_, i) {
          final ch = channels[i];
          return GestureDetector(onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VideoPlayPage(
              sourceId: ch['sourceId'] ?? '', epUrl: ch['id'] ?? '', flag: '', title: ch['name'] ?? '频道',
              episodes: [{'name': ch['name'], 'url': ch['id'], 'flag': ''}], index: 0))),
            child: Column(children: [
              Expanded(child: (ch['coverUrl'] ?? '') != '' ? Image.network(Api.img(ch['coverUrl']), fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26, child: Icon(Icons.live_tv))) : const ColoredBox(color: Colors.black26, child: Icon(Icons.live_tv))),
              Padding(padding: const EdgeInsets.all(4), child: Text(ch['name'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))),
            ])); })),
  ]); }
Widget _videoDetail(Book b) => VideoDetailPage(sourceId: b.sourceId, vodId: b.bookUrl, title: b.name);

class VideoSearchResults extends StatefulWidget { final String query; const VideoSearchResults({super.key, required this.query}); @override State<VideoSearchResults> createState() => _VSR(); }
class _VSR extends State<VideoSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; int _seq = 0;
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    setState(() { loading = true; groups = []; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('video', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'items': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/video/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        throw Exception('未连接引擎或资源库');
      }
    }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override void initState() { super.initState(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(VideoSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['ok'] == true && (g['items'] as List?)?.isNotEmpty == true)
          
        for (final b in (g['items'] as List? ?? [])) ListTile(
          leading: (b['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(g['engine'] == true ? '${b['coverUrl']}' : Api.img(b['coverUrl']), width: 40, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
          title: Text(b['name'] ?? ''), subtitle: Text('${b['type'] ?? ''} ${b['year'] ?? ''}'.trim()),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => g['engine'] == true
            ? EngineItemPage(type: 'video', item: Map<String, dynamic>.from(b))
            : VideoDetailPage(sourceId: g['sourceId'] ?? '', vodId: b['id'] ?? '', title: b['name'] ?? '')))),
      ],
            if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('没有找到相关视频', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class VideoDetailPage extends StatefulWidget { final String sourceId, vodId, title; const VideoDetailPage({super.key, required this.sourceId, required this.vodId, required this.title}); @override State<VideoDetailPage> createState() => _Vd(); }
class _Vd extends State<VideoDetailPage> {
  Map<String, dynamic>? info; List episodes = []; bool loading = true; String? err;
  @override void initState() { super.initState();
    Book.recordHistory(Book(widget.title, '', '', '', widget.vodId, widget.sourceId), 'video');
    load(); }
  Future<void> load() async { try {
      final r = await Api.get('/v1/video/detail?sourceId=${Uri.encodeComponent(widget.sourceId)}&id=${Uri.encodeComponent(widget.vodId)}');
      if (r['object'] == 'error') { err = r['data']?['message'] ?? '失败'; }
      else { info = r['data']; episodes = info?['episodes'] ?? []; }
    } catch (e) { err = '$e'; }
    setState(() => loading = false); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title)), body: loading
    ? const Center(child: CircularProgressIndicator())
    : err != null ? Center(child: Text(err!, style: const TextStyle(color: Colors.red)))
    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if ((info?['intro'] ?? '') != '') Padding(padding: const EdgeInsets.all(12), child: Text(info!['intro'], maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 12))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 4), child: Text('选集 (${episodes.length})', style: const TextStyle(color: Colors.blueAccent))),
        Expanded(child: ListView.builder(itemCount: episodes.length, itemBuilder: (_, i) => ListTile(
          dense: true, title: Text(episodes[i]['name'] ?? '第${i + 1}集', style: const TextStyle(fontSize: 13)),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VideoPlayPage(
            sourceId: widget.sourceId, epUrl: episodes[i]['url'] ?? '', flag: episodes[i]['flag'] ?? '',
            title: episodes[i]['name'] ?? '', episodes: episodes, index: i))),
        )))])); }

class VideoPlayPage extends StatefulWidget { final String sourceId, epUrl, flag, title; final List episodes; final int index;
  const VideoPlayPage({super.key, required this.sourceId, required this.epUrl, required this.flag, required this.title, this.episodes = const [], this.index = 0});
  @override State<VideoPlayPage> createState() => _Vp(); }
class _Vp extends State<VideoPlayPage> {
  VideoPlayerController? _vc; ChewieController? _cc; bool loading = true; String? err;
  int get idx => widget.index;
  bool get hasPrev => idx > 0; bool get hasNext => idx < widget.episodes.length - 1;
  @override void initState() { super.initState(); initPlayer(); }
  Future<void> initPlayer() async {
    try {
      final r = await Api.get('/v1/video/play?sourceId=${Uri.encodeComponent(widget.sourceId)}&flag=${Uri.encodeComponent(widget.flag)}&id=${Uri.encodeComponent(widget.epUrl)}');
      if (r['object'] == 'error') { setState(() { loading = false; err = r['data']?['message'] ?? '解析失败'; }); return; }
      final url = r['data']?['url'] as String? ?? '';
      if (url.isEmpty) { setState(() { loading = false; err = '播放地址为空'; }); return; }
      _vc = VideoPlayerController.networkUrl(Uri.parse(url));
      await _vc!.initialize();
      final speed = double.tryParse(AppSettings.p.getString('video_speed') ?? '1.0') ?? 1.0;
      _cc = ChewieController(videoPlayerController: _vc!, autoPlay: true, aspectRatio: _vc!.value.aspectRatio,
        allowedScreenSleep: false, allowPlaybackSpeedChanging: true,
        playbackSpeeds: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]);
      await _vc!.setPlaybackSpeed(speed);
      setState(() => loading = false);
    } catch (e) { setState(() { loading = false; err = '$e'; }); } }
  @override void dispose() { _cc?.dispose(); _vc?.dispose(); super.dispose(); }
  void goEpisode(int i) { final ep = widget.episodes[i];
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => VideoPlayPage(
      sourceId: widget.sourceId, epUrl: ep['url'] ?? '', flag: ep['flag'] ?? '', title: ep['name'] ?? '',
      episodes: widget.episodes, index: i))); }
  void _epSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (c2) => DraggableScrollableSheet(
      initialChildSize: 0.6, expand: false, builder: (_, sc) => GridView.builder(controller: sc, padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 2.2, mainAxisSpacing: 8, crossAxisSpacing: 8),
        itemCount: widget.episodes.length,
        itemBuilder: (_, i) => FilledButton.tonal(style: FilledButton.styleFrom(
          backgroundColor: i == idx ? Theme.of(context).colorScheme.primary : null,
          foregroundColor: i == idx ? Colors.white : null, padding: EdgeInsets.zero),
          onPressed: () { Navigator.pop(c2); goEpisode(i); },
          child: Text(widget.episodes[i]['name'] ?? '第${i + 1}集', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))))));
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title, style: const TextStyle(fontSize: 15)), actions: [
      if (widget.episodes.isNotEmpty) IconButton(icon: const Icon(Icons.grid_view), tooltip: '选集', onPressed: _epSheet)]),
    body: err != null ? Center(child: Text('播放错误: $err', style: const TextStyle(color: Colors.red)))
      : loading ? const Center(child: CircularProgressIndicator())
      : Column(children: [
        AspectRatio(aspectRatio: _cc!.aspectRatio ?? 16 / 9, child: Chewie(controller: _cc!)),
        if (widget.episodes.isNotEmpty) SizedBox(height: 56, child: ListView.builder(
          scrollDirection: Axis.horizontal, itemCount: widget.episodes.length,
          itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: ChoiceChip(label: Text(widget.episodes[i]['name'] ?? '第${i + 1}集', style: const TextStyle(fontSize: 11)),
              selected: i == idx, onSelected: (_) => goEpisode(i))))),
        SafeArea(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          TextButton.icon(onPressed: hasPrev ? () => goEpisode(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: Text(tr('上一集'))),
          TextButton.icon(onPressed: hasNext ? () => goEpisode(idx + 1) : null, label: Text(tr('下一集')), icon: const Icon(Icons.chevron_right)),
        ]))])); }


// ═══════════════════════════════════════════════════════════════
// v4.1: 网站式底部导航 + 账号体系 + 下载中心 + 自动更新 + 本地播放器
// ═══════════════════════════════════════════════════════════════

// 模块注册表(与网站一致): key → (名称, 图标, 页面, 本地导入类型)
class ModuleDef {
  final String name; final IconData icon; final Widget page; final String? localKind;
  const ModuleDef(this.name, this.icon, this.page, {this.localKind});
}

// 前端=纯播放器: 不含任何源/引擎管理(那些只在后端与引擎上)
final Map<String, ModuleDef> kModules = {
  '搜索': ModuleDef('搜索', Icons.search, const SearchSection()),
  '小说': ModuleDef('小说', Icons.menu_book, const NovelSection(), localKind: 'novel'),
  '漫画': ModuleDef('漫画', Icons.photo_library, const ComicSection(), localKind: 'comic'),
  '视频': ModuleDef('视频', Icons.play_circle, const VideoSection(), localKind: 'video'),
  '音乐': ModuleDef('音乐', Icons.music_note, const MusicSection(), localKind: 'music'),
  'AI': const ModuleDef('AI', Icons.smart_toy_outlined, AiSection()),
  '聊天': const ModuleDef('聊天', Icons.forum_outlined, _ComingSoonPage(name: '聊天')),
  '游戏': const ModuleDef('游戏', Icons.sports_esports_outlined, _ComingSoonPage(name: '游戏')),
  '社区': const ModuleDef('社区', Icons.groups_outlined, _ComingSoonPage(name: '社区')),
  '论坛': const ModuleDef('论坛', Icons.article_outlined, _ComingSoonPage(name: '论坛')),
  '直播': const ModuleDef('直播', Icons.live_tv, LivePage()),
  '浏览器': const ModuleDef('浏览器', Icons.language, BrowserPage()),
  '相册': const ModuleDef('相册', Icons.photo_library_outlined, GalleryPage()),
  '文件': const ModuleDef('文件', Icons.folder_outlined, FilesPage()),
  '我的': ModuleDef('我的', Icons.person_outline, const ProfilePage()),
  // ═══ 规划文档 v2.0 全量模块框架(骨架页, 功能按版本逐步落地) ═══
  // ── Work 模式 ──
  '作业中心': _scaffold('作业中心', Icons.assignment_turned_in_outlined, 'Work 模式: 放着不管的长任务在这里跑, 前端被杀作业继续',
    ['作业列表(运行中/排队/待确认/已完成/失败)', '作业详情+步骤回放(复用工具卡片)', 'T3 确认队列集中审批', '定时调度(每天摘要/每周整理)', '结果自动归档到笔记/待办/相册', '作业模板: 缓存全书/相册去重/失效源巡检', '完成通知(webhook/ntfy 自配)', '作业权限范围(模块/工具白名单/时长上限)', '断点续跑: 后端重启自动恢复', '维护/开发类作业: 批量URL替换/索引重建/规则批量测试/生成修复代码'],
    note: '依赖资源库 Agent 运行时(P6), 骨架先行'),
  // ── 私有数据 ──
  '笔记': const ModuleDef('笔记', Icons.edit_note, NotesPage()),
  '待办': const ModuleDef('待办', Icons.check_circle_outline, TodoPage()),
  '录音机': const ModuleDef('录音机', Icons.mic_none, RecorderPage()),
  '日历': const ModuleDef('日历', Icons.calendar_month_outlined, CalendarPage()),
  '提醒中心': const ModuleDef('提醒中心', Icons.alarm, RemindersPage()),
  '日记': const ModuleDef('日记', Icons.book_outlined, DiaryPage()),
  '记账': const ModuleDef('记账', Icons.account_balance_wallet_outlined, LedgerPage()),
  '剪贴板': const ModuleDef('剪贴板', Icons.content_paste, ClipboardPage()),
  '书签': const ModuleDef('书签', Icons.bookmark_border, BookmarksPage()),
  '代码片段': const ModuleDef('代码片段', Icons.code, SnippetsPage()),
  'Markdown': const ModuleDef('Markdown', Icons.text_fields, MarkdownPage()),
  '健康记录': const ModuleDef('健康记录', Icons.favorite_border, HealthPage()),
  '通讯录备份': const ModuleDef('通讯录备份', Icons.contacts_outlined, ContactsBackupPage()),
  '短信备份': const ModuleDef('短信备份', Icons.sms_outlined, SmsBackupPage()),
  // ── 内容消费 ──
  '播客': const ModuleDef('播客', Icons.podcasts, PodcastPage()),
  '有声书': ModuleDef('有声书', Icons.headphones_outlined, AudiobookPage()),
  '广播': const ModuleDef('广播', Icons.radio, RadioPage()),
  '短剧': ModuleDef('短剧', Icons.movie_outlined, ShortPlayPage()),
  '壁纸': const ModuleDef('壁纸', Icons.wallpaper, WallpaperPage()),
  '资讯': const ModuleDef('资讯', Icons.newspaper, NewsPage()),
  '天气快递': const ModuleDef('天气快递', Icons.wb_sunny_outlined, WeatherPage()),
  '菜谱': const ModuleDef('菜谱', Icons.restaurant_menu, RecipePage()),
  '学习工具': const ModuleDef('学习工具', Icons.school_outlined, StudyPage()),
  '课程表': const ModuleDef('课程表', Icons.table_chart_outlined, TimetablePage()),
  // ── 工具效率 ──
  '翻译': const ModuleDef('翻译', Icons.translate, TranslatePage()),
  '扫描仪': ModuleDef('扫描仪', Icons.document_scanner_outlined, ScannerPage()),
  '二维码': const ModuleDef('二维码', Icons.qr_code_scanner, QrPage()),
  '悬浮便签': const ModuleDef('悬浮便签', Icons.note_alt_outlined, QuickNotePage()),
  '计算器': const ModuleDef('计算器', Icons.calculate_outlined, CalcPage()),
  '白板': const ModuleDef('白板', Icons.draw_outlined, WhiteboardPage()),
  '文本工具箱': const ModuleDef('文本工具箱', Icons.text_snippet_outlined, TextToolsPage()),
  '传感器': const ModuleDef('传感器', Icons.sensors, SensorPage()),
  '文件互传': ModuleDef('文件互传', Icons.send_to_mobile_outlined, FileSharePage()),
  '远程打印': _scaffold('远程打印', Icons.print_outlined, '后端接打印机',
    ['文档/图片发送到资源库打印', '打印队列', '打印记录'], note: '依赖资源库接打印机'),
  // ── 家庭/多端 ──
  '共享相册': ModuleDef('共享相册', Icons.photo_library_outlined, SharedAlbumPage()),
  '共享清单': ModuleDef('共享清单', Icons.checklist_outlined, SharedListPage()),
  '家庭影院': ModuleDef('家庭影院', Icons.weekend_outlined, HomeCinemaPage()),
  '家庭音乐库': ModuleDef('家庭音乐库', Icons.library_music_outlined, HomeMusicPage()),
  '摄像头': ModuleDef('摄像头', Icons.videocam_outlined, CameraPage()),
  '智能家居': _scaffold('智能家居', Icons.home_outlined, '米家/HA 控制走引擎模式',
    ['设备控制面板', '场景联动', '引擎模式接入(官方零内置)']),
  '设备互联': ModuleDef('设备互联', Icons.devices_outlined, DeviceLinkPage()),
  '家庭日历': ModuleDef('家庭日历', Icons.family_restroom_outlined, const CalendarPage(storageKey: 'family_calendar_events')),
  // ── 聚合入口(一个模块装一类, 导航栏不再排长队) ──
  '工具箱': const ModuleDef('工具箱', Icons.construction_outlined, ModuleHubPage(name: '工具箱', icon: Icons.construction_outlined,
    desc: '效率工具聚合: 翻译/扫描/二维码/计算器等一处直达',
    children: ['翻译', '扫描仪', '二维码', '悬浮便签', '计算器', '白板', '文本工具箱', '传感器', '文件互传', '远程打印'])),
  '家庭中心': const ModuleDef('家庭中心', Icons.home_work_outlined, ModuleHubPage(name: '家庭中心', icon: Icons.home_work_outlined,
    desc: '家庭/多端聚合: 共享相册/影院/智能家居等一处直达',
    children: ['共享相册', '共享清单', '家庭影院', '家庭音乐库', '摄像头', '智能家居', '设备互联', '家庭日历'])),
};

// ═══ 模块分类(导航栏管理树状分组用) ═══
const kCatOrder = ['核心', '内容', '生活', '效率', '家庭', '实验室'];
const Map<String, String> kModuleCats = {
  '搜索': '核心', 'AI': '核心', '浏览器': '核心', '文件': '核心', '相册': '核心', '我的': '核心',
  '小说': '内容', '漫画': '内容', '视频': '内容', '音乐': '内容', '直播': '内容',
  '播客': '内容', '有声书': '内容', '广播': '内容', '短剧': '内容', '壁纸': '内容', '资讯': '内容', '游戏': '内容',
  '笔记': '生活', '待办': '生活', '录音机': '生活', '日历': '生活', '提醒中心': '生活', '日记': '生活', '记账': '生活',
  '剪贴板': '生活', '书签': '生活', '代码片段': '生活', 'Markdown': '生活', '健康记录': '生活',
  '通讯录备份': '生活', '短信备份': '生活', '天气快递': '生活', '菜谱': '生活', '学习工具': '生活', '课程表': '生活',
  '作业中心': '效率', '工具箱': '效率', '翻译': '效率', '扫描仪': '效率', '二维码': '效率', '计算器': '效率',
  '白板': '效率', '文本工具箱': '效率', '传感器': '效率', '文件互传': '效率', '远程打印': '效率', '悬浮便签': '效率',
  '家庭中心': '家庭', '共享相册': '家庭', '共享清单': '家庭', '家庭影院': '家庭', '家庭音乐库': '家庭',
  '摄像头': '家庭', '智能家居': '家庭', '设备互联': '家庭', '家庭日历': '家庭',
  '聊天': '实验室', '社区': '实验室', '论坛': '实验室',
};
String moduleCat(String k) => kModuleCats[k] ?? '其他';

// ═══ 聚合模块页: 一个入口装一类子模块, 点进子模块单独开页 ═══
class ModuleHubPage extends StatelessWidget {
  final String name; final IconData icon; final String desc; final List<String> children;
  const ModuleHubPage({super.key, required this.name, required this.icon, required this.desc, required this.children});
  @override Widget build(BuildContext c) {
    final accent = Theme.of(c).colorScheme.primary;
    return ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
        Icon(icon, size: 22, color: accent), const SizedBox(width: 10),
        Expanded(child: Text(desc, style: const TextStyle(fontSize: 12, color: Colors.grey))),
      ]))),
      const SizedBox(height: 10),
      GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: (MediaQuery.of(c).size.width / 110).floor().clamp(3, 6),
        mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.15,
        children: [ for (final k in children) if (kModules.containsKey(k)) () {
          final m = kModules[k]!;
          return InkWell(borderRadius: BorderRadius.circular(16),
            onTap: () => Navigator.push(c, smoothRoute(Scaffold(appBar: AppBar(title: Text(tr(m.name))), body: m.page))),
            child: Card(margin: EdgeInsets.zero, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(m.icon, size: 26, color: accent), const SizedBox(height: 6),
              Text(tr(m.name), style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            ])));
        }() ]),
    ]);
  }
}

class _ComingSoonPage extends StatelessWidget {
  final String name; const _ComingSoonPage({required this.name});
  @override Widget build(BuildContext c) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.rocket_launch_outlined, size: 64, color: Colors.grey),
    const SizedBox(height: 12),
    Text('$name模块准备开放', style: const TextStyle(color: Colors.grey)),
    const SizedBox(height: 4),
    const Text('敬请期待', style: TextStyle(color: Colors.grey, fontSize: 11)),
  ]));
}

// ═══ 模块骨架页: 规划文档全量模块先立框架, 功能按版本逐步落地 ═══
class ModuleScaffoldPage extends StatelessWidget {
  final String name; final IconData icon; final String desc; final List<String> features; final String note;
  const ModuleScaffoldPage({super.key, required this.name, required this.icon, required this.desc, required this.features, this.note = ''});
  @override Widget build(BuildContext c) {
    final accent = Theme.of(c).colorScheme.primary;
    return ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Row(children: [
        Container(width: 52, height: 52, decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, size: 26, color: accent)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            const SizedBox(width: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
              child: const Text('框架已就位', style: TextStyle(fontSize: 9, color: Colors.orange))),
          ]),
          const SizedBox(height: 4),
          Text(desc, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ])),
      ]))),
      const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text('规划功能(按版本逐步落地)', style: TextStyle(fontSize: 12, color: Colors.grey))),
      Card(child: Column(children: [
        for (var i = 0; i < features.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 44),
          ListTile(dense: true,
            leading: Icon(Icons.check_circle_outline, size: 18, color: Colors.grey.withValues(alpha: 0.6)),
            title: Text(features[i], style: const TextStyle(fontSize: 13))),
        ],
      ])),
      if (note.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
        child: Text(note, style: const TextStyle(fontSize: 11, color: Colors.grey))),
      Padding(padding: const EdgeInsets.only(top: 10),
        child: Text('已在「我的 → 底部导航栏」中可开关/排序此模块', style: TextStyle(fontSize: 10, color: Colors.grey.withValues(alpha: 0.7))),
      ),
    ]);
  }
}
ModuleDef _scaffold(String name, IconData icon, String desc, List<String> feats, {String note = '', String? localKind}) =>
  ModuleDef(name, icon, ModuleScaffoldPage(name: name, icon: icon, desc: desc, features: feats, note: note), localKind: localKind);

// 底部导航壳(完全体同款): PageView 左右滑动切模块 + 底部"我的"固定最右, 其它模块横向自由滑动
class RootNav extends StatefulWidget {
  const RootNav({super.key});
  // 导航设置变更时 +1, 触发 RootNav 即时重载(无需重启)
  static final ValueNotifier<int> navTick = ValueNotifier(0);
  // 全屏模式: 任何模块可经右上角 ⋯ → 全屏 进入, 隐藏顶栏+底栏+系统栏
  static final ValueNotifier<bool> fullscreen = ValueNotifier(false);
  // 当前模块广播(模块切换时 +1): AI 抽屉等用它静默收起, 避免切模块误触发侧边栏
  static final ValueNotifier<int> moduleTick = ValueNotifier(0);
  static String currentModuleKey = '';
  @override State<RootNav> createState() => _RootNavState();
}
class _RootNavState extends State<RootNav> {
  List<String> enabled = ['我的'];
  int idx = 0;
  bool _navCollapsed = false; // 点按正文收起(去文字, 缩到 ~1/3 高, 点细条恢复)
  final PageController _page = PageController();
  final ScrollController _navScroll = ScrollController();
  // 沉浸式模块: 自带页头(浏览器=地址栏, 相册=相册条), 隐藏系统顶栏
  static const _noAppBarModules = {'浏览器', '相册'};
  // 全沉浸模块: 连底部导航也隐藏(屏幕留给正文, 通过模块宫格返回)
  static const _noNavModules = {'浏览器'};
  @override void initState() { super.initState(); _load();
    RootNav.navTick.addListener(_onNavChanged);
    RootNav.fullscreen.addListener(_onFs);
    // 浏览器等沉浸页的"切换模块"入口
    BrowserHooks.openModules = (c) => NavOrb.showModuleGrid(c, enabled, idx, (i) => _go(i, animate: false));
    Future.delayed(const Duration(seconds: 4), () { if (mounted) Updater.check(context); }); }
  void _onNavChanged() { _load(); }
  void _onFs() {
    if (RootNav.fullscreen.value) { SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); }
    else { SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); }
    if (mounted) setState(() {});
  }
  @override void dispose() { RootNav.navTick.removeListener(_onNavChanged); RootNav.fullscreen.removeListener(_onFs); BrowserHooks.openModules = null; _page.dispose(); _navScroll.dispose(); super.dispose(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getStringList('nav_modules');
    setState(() {
      enabled = (saved == null || saved.isEmpty) ? ['我的'] : saved.where((k) => kModules.containsKey(k)).toList();
      if (!enabled.contains('我的')) enabled.add('我的');
      if (idx >= enabled.length) idx = 0;
    });
  }
  bool _animating = false;
  void _go(int i, {bool animate = true}) {
    if (i < 0 || i >= enabled.length) return;
    HapticFeedback.selectionClick(); // 切换模块轻微震动
    setState(() => idx = i);
    if (!_page.hasClients) return;
    if (animate) {
      _animating = true;
      _page.animateToPage(i, duration: const Duration(milliseconds: 240), curve: Curves.easeOut)
        .whenComplete(() => _animating = false);
    }
    else { _page.jumpToPage(i); }
  }
  @override Widget build(BuildContext c) {
    ScreenFit.update(c);
    final key = enabled[idx];
    final fs = RootNav.fullscreen.value;
    final hideBar = _noAppBarModules.contains(key);   // 沉浸: 该模块自带页头, 不补状态栏留白
    final hideNav = _noNavModules.contains(key);      // 底栏: 沉浸页不显示
    final kbOpen = MediaQuery.viewInsetsOf(c).bottom > 100; // 键盘弹出时底栏让位(网页端 kb-open 同款)
    // PageView 防回跳兜底: 任何原因导致页面重建后停在第0页而 idx 不在0时, 帧末拉回当前模块
    if (_page.hasClients && !_animating && (_page.page?.round() ?? idx) != idx && idx < enabled.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_page.hasClients && !_animating && idx < enabled.length) _page.jumpToPage(idx);
      });
    }
    // 模块滑动隔离: 禁止在模块间左右滑动, 各模块内部手势互不干扰
    // 点按正文→底栏收起为 1/3 细条(保持收起, 不再因松手/上滑弹回); 点细条恢复
    final body = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (fs || !AppSettings.navAutoHide || hideNav || _navCollapsed) return;
        setState(() => _navCollapsed = true);
      },
      child: PageView(controller: _page, onPageChanged: (i) { setState(() { idx = i; }); RootNav.currentModuleKey = enabled[i]; RootNav.moduleTick.value++; },
        physics: const NeverScrollableScrollPhysics(),
        children: [ for (final k in enabled) _KeepAlivePage(key: ValueKey(k), child: kModules[k]!.page) ]));
    // 顶栏已移除: 模块名由底栏高亮承担, 模块菜单收进底栏 ⋯ / 悬浮球长按 / 折叠条 ⋯ (openModuleMenu)
    // body 始终位于 Stack 第 0 位且包裹类型恒定(SafeArea.top 开关), 全屏切换不再重建 PageView —— 修复"点全屏跳回搜索页"
    final bodyStack = Stack(children: [
      SafeArea(top: !hideBar && !fs, bottom: false, child: body),
      if (fs) Positioned(top: 0, right: 8, child: SafeArea(child: Material(color: Colors.black45, shape: const CircleBorder(),
        child: IconButton(icon: const Icon(Icons.fullscreen_exit, color: Colors.white), tooltip: '退出全屏',
          onPressed: () => RootNav.fullscreen.value = false)))),
    ]);
    // 折叠屏展开/平板: 左侧 NavigationRail 双栏; 手机/手表: 底部导航
    if (ScreenFit.isWide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(selectedIndex: idx, onDestinationSelected: (i) => _go(i),
            labelType: NavigationRailLabelType.all,
            trailing: fs ? null : IconButton(icon: const Icon(Icons.more_vert), tooltip: '模块菜单', onPressed: openModuleMenu),
            destinations: [ for (final k in enabled) NavigationRailDestination(icon: Icon(kModules[k]!.icon), label: Text(tr(kModules[k]!.name))) ]),
          const VerticalDivider(width: 1),
          Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: bodyStack))),
        ]));
    }
    // 导航形态: bar=底部导航栏 / orb=悬浮球 / fold=折叠细条
    final navStyle = AppSettings.navStyle;
    if (navStyle == 'orb') {
      return Scaffold(body: Stack(children: [bodyStack, const NavOrb()]));
    }
    if (navStyle == 'fold') {
      return Scaffold(body: bodyStack,
        bottomNavigationBar: (hideNav || fs) ? null : _foldedNavBar());
    }
    return Scaffold(body: bodyStack,
      bottomNavigationBar: (hideNav || fs || kbOpen) ? null
        : AnimatedSize(duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _scrollNavBar(collapsed: _navCollapsed && AppSettings.navAutoHide)));
  }

  // 模块菜单(底部弹层, 替代原顶栏 ⋯): 新会话(AI)/本地库/导入/模块设置/全屏/切换模块
  static const _settingsModules = {'小说', '漫画', '视频', '音乐', '直播'};
  void openModuleMenu() {
    final key = enabled[idx]; final mod = kModules[key]!;
    final fsNow = RootNav.fullscreen.value;
    showModalBottomSheet(context: context, showDragHandle: true, builder: (c2) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.only(bottom: 4),
        child: Text('${tr(mod.name)} · 模块菜单', style: const TextStyle(fontWeight: FontWeight.bold))),
      if (key == 'AI')
        ListTile(dense: true, leading: const Icon(Icons.add_comment_outlined, size: 20), title: Text(tr('新会话')),
          onTap: () { Navigator.pop(c2); AiSection.newSessionTick.value++; }),
      if (mod.localKind != null) ...[
        ListTile(dense: true, leading: const Icon(Icons.folder_open, size: 20), title: const Text('本地库'),
          onTap: () { Navigator.pop(c2); Navigator.push(context, smoothRoute(localLibPage(mod.localKind!))); }),
        ListTile(dense: true, leading: const Icon(Icons.download, size: 20), title: const Text('导入本地文件'),
          onTap: () async { Navigator.pop(c2); final n = await importLocal(mod.localKind!);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n > 0 ? '已导入 $n 个文件' : '未导入'))); }),
      ],
      if (_settingsModules.contains(key))
        ListTile(dense: true, leading: const Icon(Icons.tune, size: 20), title: Text('${mod.name}设置'),
          onTap: () { Navigator.pop(c2); showModuleSettings(context, key); }),
      ListTile(dense: true, leading: Icon(fsNow ? Icons.fullscreen_exit : Icons.fullscreen, size: 20),
        title: Text(fsNow ? '退出全屏' : '全屏'),
        onTap: () { Navigator.pop(c2); RootNav.fullscreen.value = !fsNow; }),
      ListTile(dense: true, leading: const Icon(Icons.apps, size: 20), title: const Text('切换模块'),
        onTap: () { Navigator.pop(c2); NavOrb.showModuleGrid(context, enabled, idx, (i) => _go(i, animate: false)); }),
      const SizedBox(height: 6),
    ])));
  }

  // 折叠导航: 只显示当前模块细条, 点按弹出模块宫格
  Widget _foldedNavBar() {
    final scheme = Theme.of(context).colorScheme;
    final mod = kModules[enabled[idx]]!;
    return SafeArea(child: GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); NavOrb.showModuleGrid(context, enabled, idx, (i) => _go(i, animate: false)); },
      child: Container(height: 40, margin: const EdgeInsets.fromLTRB(48, 0, 48, 8),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(mod.icon, size: 16, color: scheme.primary), const SizedBox(width: 6),
          Text(tr(mod.name), style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.bold)),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_up, size: 16, color: scheme.primary),
          // 模块菜单(替代原顶栏 ⋯): 独立点击区, 不触发外层宫格
          GestureDetector(behavior: HitTestBehavior.opaque,
            onTap: () { HapticFeedback.selectionClick(); openModuleMenu(); },
            child: Padding(padding: const EdgeInsets.only(left: 10),
              child: Icon(Icons.more_vert, size: 16, color: scheme.primary.withValues(alpha: 0.7)))),
        ]))));
  }

  // 完全体同款底栏: 模块多→横向自由滑动, "我的"永远固定在最右端
  // collapsed=滚动收起态: 去掉文字只留图标, 高度 60→34 (约省1/3, 网页端 nav-folded 同款动画)
  Widget _scrollNavBar({bool collapsed = false}) {
    final mineIdx = enabled.indexOf('我的');
    final scrollKeys = [ for (var i = 0; i < enabled.length; i++) if (i != mineIdx) i ];
    final scheme = Theme.of(context).colorScheme;
    final barH = collapsed ? 34.0 : 60.0;
    Widget item(int i, {double? width}) {
      final k = enabled[i]; final m = kModules[k]!; final on = i == idx;
      final fg = on ? Colors.white : scheme.onSurface.withValues(alpha: 0.55);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () { HapticFeedback.selectionClick(); _go(i); },
        child: SizedBox(width: width, height: barH,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // 选中项: 渐变胶囊 + 图标微弹
            TweenAnimationBuilder<double>(tween: Tween(begin: 1, end: on ? 1.12 : 1.0),
              duration: const Duration(milliseconds: 220), curve: Curves.easeOutBack,
              builder: (_, s, child) => Transform.scale(scale: s, child: child),
              child: AnimatedContainer(duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: collapsed ? 1 : 3),
                decoration: on ? BoxDecoration(
                  gradient: LinearGradient(colors: [scheme.primary, scheme.tertiary],
                    begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 2))],
                ) : null,
                child: Icon(m.icon, size: collapsed ? 19 : 21, color: fg))),
            if (!collapsed) ...[
              const SizedBox(height: 2),
              Text(tr(m.name), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10.5, color: on ? scheme.primary : fg, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
            ],
          ])));
    }
    return GestureDetector(
      // 收起态: 点按细条恢复完整底栏; 任意状态: 长按弹出模块抽屉
      onTap: collapsed ? () => setState(() => _navCollapsed = false) : null,
      onLongPress: () { HapticFeedback.selectionClick(); NavOrb.showModuleGrid(context, enabled, idx, (i) => _go(i, animate: false)); },
      child: SafeArea(top: false, child: Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(collapsed ? 17 : 26),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5), width: 0.6),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(collapsed ? 17 : 26),
      child: SizedBox(height: barH, child: LayoutBuilder(builder: (ctx, box) {
        final itemW = collapsed ? 52.0 : 76.0;
        final mineW = itemW;
        final menuW = collapsed ? 38.0 : 44.0;
        final avail = box.maxWidth - (mineIdx >= 0 ? mineW : 0) - menuW;
        // 模块菜单按钮(替代原顶栏 ⋯): 固定最右端
        final menuBtn = Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5), width: 0.5))),
          child: SizedBox(width: menuW, height: barH, child: IconButton(padding: EdgeInsets.zero,
            icon: Icon(Icons.more_vert, size: collapsed ? 17 : 19, color: scheme.onSurface.withValues(alpha: 0.6)),
            tooltip: '模块菜单', onPressed: () { HapticFeedback.selectionClick(); openModuleMenu(); })));
        // 模块少→等分铺满; 模块多→横向滑动, 我的固定右侧
        if (scrollKeys.length * itemW <= avail) {
          return Row(children: [
            for (final i in scrollKeys) Expanded(child: item(i)),
            if (mineIdx >= 0) SizedBox(width: mineW, child: item(mineIdx)),
            menuBtn,
          ]);
        }
        return Row(children: [
          Expanded(child: ListView.builder(controller: _navScroll, scrollDirection: Axis.horizontal,
            itemCount: scrollKeys.length,
            itemBuilder: (_, n) => SizedBox(width: itemW, child: item(scrollKeys[n])))),
          if (mineIdx >= 0) Container(decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outlineVariant, width: 0.5))),
            child: SizedBox(width: mineW, child: item(mineIdx))),
          menuBtn,
        ]);
      }))))));
  }
}
class _KeepAlivePage extends StatefulWidget { const _KeepAlivePage({super.key, required this.child}); final Widget child;
  @override State<_KeepAlivePage> createState() => _KeepAlivePageState(); }
class _KeepAlivePageState extends State<_KeepAlivePage> with AutomaticKeepAliveClientMixin {
  @override bool get wantKeepAlive => true;
  @override Widget build(BuildContext context) { super.build(context); return widget.child; }
}

// ═══ 模块右上角设置: 只含该模块的播放器设置(全局设置都在"我的") ═══
void showModuleSettings(BuildContext c, String modKey) {
  showModalBottomSheet(context: c, isScrollControlled: true, builder: (c2) => StatefulBuilder(builder: (c2, setD) {
    Widget tile(IconData ic, String t, Widget trailing) => ListTile(leading: Icon(ic, size: 20),
      title: Text(t, style: const TextStyle(fontSize: 14)), trailing: trailing, dense: true);
    final List<Widget> children = [];
    switch (modKey) {
      case '小说':
        children.addAll([
          tile(Icons.format_size, '字号 ${AppSettings.fontSize.toStringAsFixed(0)}', SizedBox(width: 160,
            child: Slider(value: AppSettings.fontSize, min: 12, max: 32, onChanged: (v) { AppSettings.setFontSize(v); setD(() {}); }))),
          tile(Icons.brightness_6_outlined, '阅读主题', SegmentedButton<int>(showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: 0, label: Text('夜', style: TextStyle(fontSize: 10))), ButtonSegment(value: 1, label: Text('日', style: TextStyle(fontSize: 10))), ButtonSegment(value: 2, label: Text('纸', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.readerTheme}, onSelectionChanged: (s) { AppSettings.setReaderTheme(s.first); setD(() {}); })),
          tile(Icons.swipe, '翻页方式', SegmentedButton<String>(showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: 'scroll', label: Text('滚动', style: TextStyle(fontSize: 10))), ButtonSegment(value: 'paged', label: Text('翻页', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.pageMode}, onSelectionChanged: (s) { AppSettings.setPageMode(s.first); setD(() {}); })),
        ]);
        break;
      case '漫画':
        children.addAll([
          tile(Icons.view_agenda_outlined, '阅读模式', SegmentedButton<String>(showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: 'webtoon', label: Text('条漫', style: TextStyle(fontSize: 10))), ButtonSegment(value: 'paged', label: Text('翻页', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.p.getString('comic_mode') ?? 'webtoon'},
            onSelectionChanged: (s) { AppSettings.p.setString('comic_mode', s.first); setD(() {}); })),
        ]);
        break;
      case '音乐':
        children.addAll([
          tile(Icons.repeat, '播放模式', SegmentedButton<String>(showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: 'seq', label: Text('顺序', style: TextStyle(fontSize: 10))), ButtonSegment(value: 'one', label: Text('单曲', style: TextStyle(fontSize: 10))), ButtonSegment(value: 'rand', label: Text('随机', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.p.getString('play_mode') ?? 'seq'},
            onSelectionChanged: (s) { AppSettings.p.setString('play_mode', s.first); setD(() {}); })),
          tile(Icons.high_quality, '优先音质', SegmentedButton<String>(showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: '128k', label: Text('128k', style: TextStyle(fontSize: 10))), ButtonSegment(value: '320k', label: Text('320k', style: TextStyle(fontSize: 10))), ButtonSegment(value: 'flac', label: Text('无损', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.p.getString('music_quality') ?? '320k'},
            onSelectionChanged: (s) { AppSettings.p.setString('music_quality', s.first); setD(() {}); })),
        ]);
        break;
      case '视频':
        children.addAll([
          tile(Icons.speed, '默认倍速', SegmentedButton<String>(showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: '1.0', label: Text('1x', style: TextStyle(fontSize: 10))), ButtonSegment(value: '1.5', label: Text('1.5x', style: TextStyle(fontSize: 10))), ButtonSegment(value: '2.0', label: Text('2x', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.p.getString('video_speed') ?? '1.0'},
            onSelectionChanged: (s) { AppSettings.p.setString('video_speed', s.first); setD(() {}); })),
        ]);
        break;
      case '搜索':
        children.add(ListTile(leading: const Icon(Icons.history, size: 20), dense: true,
          title: const Text('清空搜索历史', style: TextStyle(fontSize: 14)),
          onTap: () async { final p = await SharedPreferences.getInstance();
            for (final k in ['sh_novel', 'search_history']) { await p.remove(k); }
            if (c2.mounted) Navigator.pop(c2); }));
        break;
      default:
        children.add(const Padding(padding: EdgeInsets.all(24),
          child: Text('该模块暂无播放器设置\n全局设置在「我的」里', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))));
    }
    return SafeArea(child: Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.all(12), child: Text('${kModules[modKey]?.name ?? ''} · 播放器设置',
        style: const TextStyle(fontWeight: FontWeight.bold))),
      ...children,
    ])));
  }));
}

Widget localLibPage(String kind) {
  switch (kind) {
    case 'novel': return const LocalNovelsPage();
    case 'video': return const LocalVideosPage();
    case 'music': return const LocalMusicsPage();
    case 'comic': return const LocalComicsPage();
    default: return const SizedBox();
  }
}

Future<int> importLocal(String kind) {
  switch (kind) {
    case 'novel': return LocalLib.importNovels();
    case 'video': return LocalLib.importVideos();
    case 'music': return LocalLib.importAudios();
    case 'comic': return LocalLib.importComic();
    default: return Future.value(0);
  }
}

// 底部导航自定义(像网站: 勾选哪些模块 + 按住拖动调整顺序)
Future<void> showNavSettings(BuildContext c) async {
  final p = await SharedPreferences.getInstance();
  final saved = p.getStringList('nav_modules') ?? ['我的'];
  final order = <String>[ ...saved.where((k) => kModules.containsKey(k)) ]; // 已启用(可拖动排序)
  final sel = order.toSet();
  // 未启用模块按分类树状分组
  final byCat = <String, List<String>>{};
  for (final k in kModules.keys) {
    if (sel.contains(k)) continue;
    byCat.putIfAbsent(moduleCat(k), () => []).add(k);
  }
  await showDialog(context: c, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
    title: const Text('底部导航栏'),
    content: SizedBox(width: 340, height: 500, child: ListView(children: [
      const Text('已启用 · 按住 ≡ 拖动排序 · 建议 ≤6 个, 其余用聚合模块(工具箱/家庭中心)收纳', style: TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: 6),
      ReorderableListView(buildDefaultDragHandles: false, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        onReorder: (oldI, newI) => setD(() {
          if (newI > oldI) newI--;
          final it = order.removeAt(oldI); order.insert(newI, it);
        }),
        children: [ for (var i = 0; i < order.length; i++) () {
          final k = order[i]; final e = kModules[k]!;
          return Row(key: ValueKey('on_$k'), children: [
            Checkbox(value: true, onChanged: k == '我的' ? null : (v) => setD(() { sel.remove(k); order.remove(k); })),
            Icon(e.icon, size: 18), const SizedBox(width: 8),
            Expanded(child: Text(tr(k), style: const TextStyle(fontSize: 14))),
            ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8),
              child: Icon(Icons.drag_indicator, size: 18, color: Colors.grey))),
          ]);
        }() ]),
      const Divider(height: 20),
      const Text('全部模块(按分类)', style: TextStyle(fontSize: 11, color: Colors.grey)),
      // 树状分类: 分类为父节点, 模块为子节点
      for (final cat in [...kCatOrder, '其他'])
        if ((byCat[cat] ?? []).isNotEmpty)
          ExpansionTile(dense: true, tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            childrenPadding: EdgeInsets.zero,
            leading: Icon({'核心': Icons.star_outline, '内容': Icons.play_circle_outline, '生活': Icons.coffee_outlined,
              '效率': Icons.bolt_outlined, '家庭': Icons.home_outlined, '实验室': Icons.science_outlined}[cat] ?? Icons.folder_outlined, size: 18),
            title: Text('$cat (${byCat[cat]!.length})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            children: [ for (final k in byCat[cat]!) () {
              final e = kModules[k]!;
              return Padding(padding: const EdgeInsets.only(left: 12), child: Row(key: ValueKey('off_$k'), children: [
                Checkbox(value: false, onChanged: (v) => setD(() {
                  sel.add(k); order.insert(order.contains('我的') ? order.indexOf('我的') : order.length, k);
                  byCat[cat]!.remove(k);
                })),
                Icon(e.icon, size: 18), const SizedBox(width: 8),
                Expanded(child: Text(tr(k), style: const TextStyle(fontSize: 14, color: Colors.grey))),
              ]));
            }() ]),
    ])),
    actions: [FilledButton(onPressed: () async {
      final list = order.where((k) => sel.contains(k)).toList();
      if (!list.contains('我的')) list.add('我的');
      await p.setStringList('nav_modules', list);
      RootNav.navTick.value++;
      if (c2.mounted) Navigator.pop(c2);
      if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已保存 · 已即时生效')));
    }, child: const Text('保存'))],
  )));
}


// ═══ 账号: ThirdHub 云端登录/注册 + 资料同步 + 自动连接后端 ═══
class AccountTile extends StatefulWidget { const AccountTile({super.key}); @override State<AccountTile> createState() => _At(); }
class _At extends State<AccountTile> {
  bool busy = false;
  Future<void> _auth(bool isLogin) async {
    final mailC = TextEditingController(); final passC = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: Text(isLogin ? '登录 ThirdHub 账号' : '注册 ThirdHub 账号'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: mailC, keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: '邮箱', isDense: true)),
        TextField(controller: passC, obscureText: true,
          decoration: const InputDecoration(labelText: '密码(至少6位)', isDense: true)),
        const SizedBox(height: 8),
        const Text('前后端登录同一账号即可自动配对连接, 无需填地址', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: Text(isLogin ? '登录' : '注册'))]));
    if (ok != true) return;
    setState(() => busy = true);
    try {
      if (isLogin) { await Cloud.signIn(mailC.text.trim(), passC.text); }
      else { await Cloud.signUp(mailC.text.trim(), passC.text); }
      await _syncProfile();
      await AppSettings.ensureIdentity();
      await _autoConnect();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已登录')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    if (mounted) setState(() => busy = false);
  }

  // 云端资料 → 本地(头像/昵称/简介)
  Future<void> _syncProfile() async {
    final prof = Cloud.profileData;
    if (prof.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final nick = prof['nickname'] ?? prof['display_name'];
    if (nick != null && '$nick'.isNotEmpty) await p.setString('nickname', '$nick');
    if (prof['bio'] != null && '${prof['bio']}'.isNotEmpty) await AppSettings.setBio('${prof['bio']}');
    if (prof['avatar_url'] != null && '${prof['avatar_url']}'.isNotEmpty) {
      try {
        final r = await http.get(Uri.parse('${prof['avatar_url']}'));
        if (r.statusCode == 200) await AppSettings.setAvatar(base64Encode(r.bodyBytes));
      } catch (_) {}
    }
    await AppSettings.sync();
  }

  // 账号配对: 拉取后端设备 → 三路(局域网/IPv6/穿透)并发竞速, 谁先通用谁
  Future<void> _autoConnect() async {
    try {
      final devs = await Cloud.devices();
      if (devs.isEmpty) return;
      final d = devs.first;
      final secret = d['secret'] as String? ?? '';
      final urls = <String, String>{
        if ((d['lan_url'] as String? ?? '').isNotEmpty) '局域网': d['lan_url'],
        if ((d['ipv6_url'] as String? ?? '').isNotEmpty) 'IPv6': d['ipv6_url'],
        if ((d['tunnel_url'] as String? ?? '').isNotEmpty) '穿透': d['tunnel_url'],
      };
      if (urls.isEmpty || secret.isEmpty) return;
      // 并发心跳: 任一通路 /v1/meta 成功即采用
      final winner = await Future.any(urls.entries.map((e) async {
        final r = await Api.client().get(Uri.parse('${e.value}/v1/meta'),
          headers: {'X-TH-Token': secret}).timeout(const Duration(seconds: 4));
        if (r.statusCode != 200) throw Exception('${e.key}不通');
        return MapEntry(e.key, e.value);
      })).catchError((_) => const MapEntry('', ''));
      if (winner.value.isNotEmpty) {
        final p = await SharedPreferences.getInstance();
        await p.setString('base', winner.value); await p.setString('token', secret);
        Api.base = winner.value; Api.token = secret;
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已通过${winner.key}自动连接后端')));
      }
    } catch (_) {}
  }

  @override Widget build(BuildContext c) {
    if (!Cloud.loggedIn) {
      return Column(children: [
        ListTile(dense: true, leading: const Icon(Icons.login, size: 20),
          title: const Text('登录 / 注册', style: TextStyle(fontSize: 13)),
          subtitle: const Text('ThirdHub 账号 · 与网页版同一体系', style: TextStyle(fontSize: 10)),
          trailing: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          onTap: busy ? null : () => _auth(true)),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(alignment: Alignment.centerLeft,
            child: GestureDetector(onTap: busy ? null : () => _auth(false),
              child: const Text('没有账号？点这里注册', style: TextStyle(fontSize: 11, color: Colors.blueAccent))))),
        Container(margin: const EdgeInsets.fromLTRB(16, 0, 16, 10), padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.blueAccent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.person_outline, size: 16, color: Colors.blueAccent),
            SizedBox(width: 8),
            Expanded(child: Text('当前为游客模式: 本地播放 + 局域网资源库可用\n登录后解锁云端同步与远程连接(IPv6/内网穿透)',
              style: TextStyle(fontSize: 10, height: 1.6, color: Colors.blueAccent))),
          ])),
      ]);
    }
    final prof = Cloud.profileData;
    final nick = prof['nickname'] ?? prof['display_name'] ?? AppSettings.nickname;
    return Column(children: [
      ListTile(dense: true,
        leading: CircleAvatar(radius: 16,
          backgroundImage: prof['avatar_url'] != null && '${prof['avatar_url']}'.isNotEmpty ? NetworkImage('${prof['avatar_url']}') : null,
          child: prof['avatar_url'] == null || '${prof['avatar_url']}'.isEmpty ? Text(nick.isEmpty ? 'T' : nick[0].toUpperCase(), style: const TextStyle(fontSize: 12)) : null),
        title: Text(nick.isEmpty ? Cloud.email : nick, style: const TextStyle(fontSize: 13)),
        subtitle: Text(Cloud.email, style: const TextStyle(fontSize: 10)),
        trailing: IconButton(icon: const Icon(Icons.refresh, size: 18), tooltip: '同步资料并重连后端',
          onPressed: () async { await Cloud.profile(); await _syncProfile(); await _autoConnect(); setState(() {}); })),
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Row(children: [
          GestureDetector(onTap: () async {
            final nickC = TextEditingController(text: nick);
            final r = await showDialog<String>(context: context, builder: (c2) => AlertDialog(title: const Text('修改昵称(同步到云端)'),
              content: TextField(controller: nickC, decoration: const InputDecoration(isDense: true)),
              actions: [TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c2, nickC.text.trim()), child: const Text('保存'))]));
            if (r != null && r.isNotEmpty) {
              await Cloud.updateProfile({'nickname': r, 'display_name': r});
              final p = await SharedPreferences.getInstance(); await p.setString('nickname', r);
              setState(() {});
            }
          }, child: const Text('改昵称', style: TextStyle(fontSize: 11, color: Colors.blueAccent))),
          const SizedBox(width: 16),
          GestureDetector(onTap: () async { await Cloud.signOut(); setState(() {}); },
            child: const Text('退出登录', style: TextStyle(fontSize: 11, color: Colors.redAccent))),
        ])),
    ]);
  }
}

// ═══ 下载中心: 产品列表(前端/后端/引擎/网页版), 点击进详情页再下载 ═══
class DownloadCenterTile extends StatelessWidget {
  const DownloadCenterTile({super.key});
  static const _base = 'https://mxvxlgjzeboktufumxbp.supabase.co/storage/v1/object/public/downloads/thirdhub';
  static const products = [
    ('第三方聚合', 'Flutter 纯播放器前端(本应用)', '$_base/thirdhub-app.apk', Icons.phone_android,
      '聚合 AI 对话 / 小说 / 漫画 / 视频 / 音乐 / 直播 / 相册 / 文件管理器。纯播放器设计, 不内置任何源, 通过后端与引擎获取内容。'),
    ('第三方后端', '手机内嵌 Node.js 后端', '$_base/thirdhub-backend.apk', Icons.dns,
      '在手机上运行的资源库后端: 书源/影视源/音源/图源引擎 + 局域网共享 + TLS 加密。装好后前端自动发现。'),
    ('开源阅读引擎', 'Legado 书源引擎(THP 直连)', '$_base/thirdhub-engine.apk', Icons.menu_book,
      '兼容"开源阅读"书源格式的独立引擎。匿名无鉴权, THP 协议局域网直连, 前端发现后即可搜书看书。'),
    ('venera 漫画引擎', 'venera JS 漫画源引擎(THP 直连)', '$_base/thirdhub-venera.apk', Icons.photo_library,
      '兼容 venera JS 漫画源的独立引擎。支持图源 URL/代码导入、搜索聚合、探索发现页。THP 协议直连。'),
    ('网页版', 'thirdhub.pages.dev', 'https://thirdhub.pages.dev', Icons.language,
      '浏览器打开即用, 可安装为 PWA。与客户端同一账号体系, 数据全端互通。'),
    ('网页版 1.0(经典旧版)', '最初网页版存档 · 怀旧/老设备', 'https://0d57a5ba.thirdhub.pages.dev', Icons.history,
      'ThirdHub 最初的网页版 1.0 存档(2026-08-06 首次部署)。功能与界面以新版网页版为准, 此版本仅供老设备兼容与怀旧使用。'),
  ];
  @override Widget build(BuildContext c) => Column(children: [
    for (final p in products)
      ListTile(dense: true, leading: Icon(p.$4, size: 20),
        title: Text(p.$1, style: const TextStyle(fontSize: 13)),
        subtitle: Text(p.$2, style: const TextStyle(fontSize: 10)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ProductDetailPage(name: p.$1, sub: p.$2, url: p.$3, icon: p.$4, desc: p.$5)))),
  ]);
}

// 产品详情子页: 介绍 + 底部下载按钮
class ProductDetailPage extends StatelessWidget {
  final String name, sub, url, desc; final IconData icon;
  const ProductDetailPage({super.key, required this.name, required this.sub, required this.url, required this.icon, required this.desc});
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(name)),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 20),
        child: CircleAvatar(radius: 36, child: Icon(icon, size: 36)))),
      Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(sub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 20),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(desc, style: const TextStyle(fontSize: 13, height: 1.8)))),
      const SizedBox(height: 12),
      const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('覆盖安装, 数据自动保留\n下载完成的安装包会保存在"已下载的安装包"列表, 可随时重装或长按删除', style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.8)))),
    ]),
    bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(16),
      child: url.toLowerCase().endsWith('.apk')
        ? FilledButton.icon(icon: const Icon(Icons.download), label: const Text('下载软件'),
            onPressed: () => Updater.downloadProduct(c, url, name))
        : FilledButton.icon(icon: const Icon(Icons.open_in_new), label: const Text('打开网页版'),
            onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)))));
}

// 历史版本更新记录(与 FEATURES.md 同步): (版本, 描述, 标记)
const kChangelog = [
  ('v4.24.0', 'THP引擎通路+界面瘦身: ① 引擎直连全自动——App启动自动发现并连接局域网引擎, 断线自动重连, 搜索/发现/目录/正文全部走 THP 不再依赖后端(修复搜索报 No host specified、发现页空白、阅读器打不开) ② 各模块"搜索"页签补搜索框(点开即输), 视频模块补搜索页签 ③ 移除全模块冗余顶部标题栏, 模块菜单(全屏/切换/设置/本地库/导入)收进底栏右侧 ⋯(悬浮球长按/折叠条 ⋯ 同效) ④ 修复"点全屏跳回搜索页"(页面结构恒定不再重建) ⑤ 我的页去掉双层顶栏, 点头像进账号设置子页, 相机角标换头像 ⑥ 修复更新清单 versionCode 读取', '里程碑'),
  ('v4.23.0', '阅读器完全体+音乐均衡器: ① 本地小说阅读器升级——txt/epub 本地书全部接入专业阅读器(横屏/长按段落/下拉书签/字体皮肤/翻页动画全继承, 自动记忆进度) ② 自定义皮肤导入: 相册选图做阅读背景+透明度滑杆 ③ 本章搜索: 关键词高亮定位, 翻页模式按字符跳页/滚动模式按比例跳 ④ 自动阅读: 上下模式平滑滚动(速度可调, 到底自动下一章), 翻页模式定时翻页 ⑤ 音乐均衡器: 真硬件级 audiofx 均衡器挂播放会话, 频段滑杆+官方预设(摇滚/流行/古典等)', ''),
  ('v4.22.0', '顶级播放器+浏览器批: ① 系统级"打开方式"——文件管理器/其他App打开 txt·epub·音频·视频·网页链接 或分享文本时, 本App 出现在系统选择列表并直达对应阅读器/播放器/浏览器 ② 小说阅读器: 横屏阅读开关 / 长按段落菜单(复制·朗读本段·从此段听书·加书签) / 顶部下拉加书签 / 书签列表 ③ 浏览器: 搜索引擎切换(必应/百度/谷歌/DDG/搜狗) / 广告拦截(域名拦截清单+页面去广告元素) / 外部链接直达开新标签 ④ 音乐播放器: 睡眠定时(含播完本曲) + 倍速 ⑤ 视频播放器: 双击左右±10s快进退 / 倍速 / 断点续播 / 横屏全屏 ⑥ 底部导航焕新: 浮动圆角胶囊+渐变选中胶囊+弹性图标动画+触感反馈', '里程碑'),
  ('v4.21.1', 'THP/1.0 协议前端补全: 发现层解析新格式 HELLO(实例ID/角色/名称) + BYE 优雅下线, 兼容旧草稿格式; 配套阅读引擎 engine-v1.2.0(THP 服务层)', ''),
  ('v4.21.0', '体验大修: ① 我的页回归头像大卡(渐变+漂浮光点+头像环+身份码胶囊) ② AI 抽屉带惯性甩动+速度判定+开关震动反馈, 修复切模块后侧边栏误展开(模块切换广播静默收起) ③ AI 右上角新会话快捷按钮 ④ 多语言真生效: 60 个模块名全入字典(英/日), 顶栏/底栏/模块抽屉/导航管理全部随语言切换 ⑤ 悬浮窗/折叠屏适配保持', '里程碑'),
  ('v4.20.0', '云同步落地: 共享清单/家庭日历登录后自动多台设备同步(新建 th_shared 表, 后写赢合并); 书架云端同步读取——后端资源库已下载的书自动合并进书架(换设备不丢), 点开直接读(全书已在库); 修复家庭日历写入个人日历存储的错位 bug; 悬浮便签升级为真全局悬浮窗(SYSTEM_ALERT_WINDOW, 退出App也能看到, 可拖动)', '里程碑'),
  ('v4.19.0', '小模块做实第7-11批(共8个): 通讯录备份(导出/恢复JSON) / 短信备份(导出+验证码提取) / 扫描仪(拍照灰度增强) / 有声书(本地连播) / 短剧(竖屏连播) / 文件互传(局域网扫码秒传) / 家庭影院(本地视频库) / 家庭音乐库(本地音乐+随机播放) / 共享清单(多清单+勾选) / 家庭日历(独立家庭日程) / 共享相册(本地相册浏览+幻灯片) / 摄像头(网络摄像机实时画面) / 设备互联(局域网设备扫描); 短信读取改为自研通道(原 telephony 插件已无人维护且不兼容新构建链)', '里程碑'),
  ('v4.18.0', '小模块做实第2-6批(共15个): 录音机(录音/暂停/回放) / 日历(月视图+日程) / 日记(心情+时间轴) / 白板(手绘+保存PNG) / 悬浮便签(速记) / 提醒中心(定时系统通知) / 课程表(7天网格) / 天气快递(wttr.in实时天气+快递查询) / 壁纸(Wallhaven) / 广播(全球电台在线听) / 播客(RSS订阅) / 书签 / 代码片段 / Markdown编辑器 / 学习工具(背诵卡) / 菜谱 / 翻译(多语言互译) / 健康记录(趋势图) / 资讯(RSS) — 全部点开即用', '里程碑'),
  ('v4.17.0', '小模块做实第一批: 计算器(四则/乘方/括号+历史) / 文本工具箱(JSON/Base64/URL/时间戳/字数统计) / 二维码(生成+保存PNG+历史) / 待办(分组+滑动删除) / 笔记(Markdown编辑预览+搜索) / 记账(分类+月度收支统计) / 剪贴板(收藏+置顶) — 全部点开即用, 不再是骨架页; 修复 AI 厂商中文名乱码(在线注册表强制 UTF-8 解码)', ''),
  ('v4.16.0', '固定Release签名(从此覆盖安装不再要求卸载) + 应用内下载修复(安装权限/FileProvider/三镜像自动切换/浏览器下载兜底) + 下载中心补网页版1.0 + 模块树状分类管理 + 聚合模块(工具箱/家庭中心) + 长按底栏弹模块抽屉 + 点击正文底栏收起为1/3保持 + 全模块右上角⋯菜单(全屏/切换模块/模块专属项, 不再一刀切播放器设置)', '里程碑'),
  ('v4.15.0', '功能规划v2.0全量模块框架落地(作业中心/笔记/待办/录音机/日历/提醒/日记/记账/剪贴板/书签/代码片段/Markdown/健康/播客/有声书/广播/短剧/壁纸/资讯/天气快递/菜谱/学习工具/课程表/翻译/扫描仪/二维码/悬浮便签/计算器/白板/文本工具箱/传感器/文件互传/远程打印/家庭系列等41个新模块, 在「我的→功能管理」开启) + 「我的」页重构为Kimi式设置(分组卡片/通知设置/帮助中心/退出登录)', '里程碑'),
  ('v4.14.1', 'THP/1.0协议漏洞修复(blob乱序写入/sha256校验/Range校验/content:batch NDJSON/关停BYE广播/双栈IPv6) + 模块介绍页 + 历史版本下载', '重构'),
  ('v4.14.0', 'THP/1.0正式协议全量落地(发现/搜索/目录/内容/订阅/大文件/作业 25项全通过) + 后端模块化重构 + 首启协议弹窗(隐私政策/服务条款) + 加载式开屏可关动画 + 开屏IPv6标识', '里程碑'),
  ('v4.13.0', '相册权限修复(真正能打开系统相册) + 音乐通知栏服务补全 + LRC同步歌词左右滑动 + 底部导航拖动排序 + 滚动自动收起导航栏(省1/3空间) + 浏览器/相册沉浸布局 + 浏览器全屏模式', ''),
  ('v4.12.0', '更新误判修复 + 后台下载/安装包回收站 + 下载中心详情与历史 + 底部导航栏/折叠/悬浮球 + 语言即时生效 + AI抽屉防误滑/快捷模型/空会话清理 + 音量键翻页 + 通知栏音乐控制 + 公告系统通知', ''),
  ('v4.11.0', 'venera漫画引擎App + 引擎漫画阅读器(条漫/翻页) + 音乐/视频断点续播 + 音乐收藏 + 后端依赖随包修复', ''),
  ('v4.10.0', '引擎直连漫画阅读器 + 下载中心4件套 + server依赖内置', ''),
  ('v4.9.0', 'AI思考链 + 消息排队 + TH-Harness本机工具 + 技能注入 + 上下文管理 + 相册/文件/浏览器模块 + 引擎直连 + THP v1.1', '里程碑'),
  ('v4.8.0', 'AI模型六分类 + 排行榜 + 中转站/Key自动识别 + 统一密钥管理 + 联网搜索 + MCP + 导航即时生效', ''),
];

// ═══ 自动更新: 公告 → 点击下载 → 拉取安装(覆盖安装保留数据) ═══
class Updater {
  static const String currentVersion = '4.24.0';
  static const int currentCode = 50513;
  static bool _checked = false;

  // 语义化版本比较: a>b 返回正数
  static int _verCmp(String a, String b) {
    List<int> p(String v) => v.replaceAll(RegExp(r'[^0-9.]'), '').split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final x = p(a), y = p(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  static Future<void> check(BuildContext c, {bool manual = false}) async {
    if (_checked && !manual) return;
    _checked = true;
    final m = await Cloud.latestManifest('app');
    if (m == null) { if (manual && c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('暂无更新信息'))); return; }
    final code = (m['versionCode'] ?? m['code']) as int? ?? 0; // 清单两种字段名都认
    final ver0 = m['version'] as String? ?? '';
    // 判定修复: versionCode 与版本号双重比较, 同版本绝不弹窗
    final isNewer = code > currentCode || _verCmp(ver0, currentVersion) > 0;
    if (!isNewer) { if (manual && c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已是最新版本'))); return; }
    if (!c.mounted) return;
    final url = m['url'] as String? ?? '';
    final notes = m['notes'] as String? ?? '';
    final ver = m['version'] as String? ?? '';
    final go = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(
      title: Text('发现新版本 v$ver'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (notes.isNotEmpty) Text(notes, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        const Text('覆盖安装, 数据自动保留', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('稍后')),
        TextButton(onPressed: () { Navigator.pop(c2, false); launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); }, child: const Text('浏览器下载')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('立即更新'))]));
    if (go == true && url.isNotEmpty && c.mounted) { newVer = ver; _downloadAndInstall(c, url); }
  }
  static String newVer = '';

  // 多镜像: 主URL(云端) → Supabase版本包 → GitHub Release, 依次尝试直到成功
  static List<String> _mirrorUrls(String url, String ver) {
    final list = <String>[url];
    if (ver.isNotEmpty) {
      list.add('https://mxvxlgjzeboktufumxbp.supabase.co/storage/v1/object/public/downloads/thirdhub-app-$ver.apk');
      list.add('https://github.com/Smalluniverseheng/ThirdHub-v2/releases/download/v$ver/ThirdHub-$ver.apk');
    }
    return list.toSet().toList();
  }

  // 单镜像下载到文件(非200视为失败抛异常), 供两个下载入口共用
  static Future<void> _fetchTo(String url, File f, ValueNotifier<double> progress) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      final sink = f.openWrite();
      var got = 0;
      await for (final chunk in resp) { sink.add(chunk); got += chunk.length; if (total > 0) progress.value = got / total; }
      await sink.close();
      final len = await f.length();
      if (total > 0 && len != total) { await f.delete(); throw Exception('文件不完整($len/$total)'); }
      if (len < 1024 * 1024) { await f.delete(); throw Exception('文件过小($len字节), 疑似错误页'); }
    } finally { client.close(); }
  }

  // 通用产品下载(下载中心用): 进度弹窗 + 后台下载 + 完成通知 + 留档
  static Future<void> downloadProduct(BuildContext c, String url, String name) async {
    final progress = ValueNotifier<double>(0);
    var background = false;
    showDialog(context: c, barrierDismissible: false, builder: (c2) => AlertDialog(
      title: Text('正在下载 $name'),
      content: ValueListenableBuilder<double>(valueListenable: progress, builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
        LinearProgressIndicator(value: v > 0 ? v : null),
        const SizedBox(height: 8),
        Text(v > 0 ? '${(v * 100).toStringAsFixed(0)}%' : '连接中…', style: const TextStyle(fontSize: 12)),
      ])),
      actions: [TextButton(onPressed: () { background = true; Navigator.pop(c2);
          ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已转入后台下载, 完成后会通知你')));
        }, child: const Text('后台下载'))]));
    try {
      final dir = await _updateDir();
      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>| ]'), '-');
      final f = File('$dir/$safe-${DateTime.now().millisecondsSinceEpoch}.apk');
      // 从文件名提取版本号用于拼镜像地址
      final vm = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(name);
      final mirrors = _mirrorUrls(url, vm?.group(1) ?? '');
      Exception? lastErr;
      var ok = false;
      for (var i = 0; i < mirrors.length && !ok; i++) {
        try {
          if (i > 0 && c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('主线路失败, 切换镜像 ${i + 1}/${mirrors.length}…')));
          progress.value = 0;
          await _fetchTo(mirrors[i], f, progress);
          ok = true;
        } catch (e) { lastErr = e is Exception ? e : Exception('$e'); }
      }
      if (!ok) throw lastErr ?? Exception('所有镜像均不可用');
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList('update_apks') ?? [];
      list.add('${f.path}|$name|${DateTime.now().toString().substring(0, 16)}');
      await p.setStringList('update_apks', list);
      if (!background && c.mounted) Navigator.pop(c);
      if (background) await Notify.show(88003, '$name 下载完成', '点按安装包即可安装');
      if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(duration: const Duration(seconds: 6),
        content: Text('已保存: ${f.path}'),
        action: SnackBarAction(label: '安装', onPressed: () => OpenFilex.open(f.path))));
    } catch (e) {
      if (!background && c.mounted) Navigator.pop(c);
      if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    }
  }

  static Future<String> _updateDir() async {
    // 应用外部目录: 文件管理器 Android/data/包名/files/updates 可见, 卸载才清除
    try {
      final ext = await getExternalStorageDirectory();
      final d = Directory('${ext!.path}/updates');
      if (!await d.exists()) await d.create(recursive: true);
      return d.path;
    } catch (_) {
      final d = await Directory.systemTemp.createTemp('th_update');
      return d.path;
    }
  }

  static Future<void> _downloadAndInstall(BuildContext c, String url) async {
    final progress = ValueNotifier<double>(0);
    var background = false;
    showDialog(context: c, barrierDismissible: false, builder: (c2) => AlertDialog(
      title: const Text('正在下载更新'),
      content: ValueListenableBuilder<double>(valueListenable: progress, builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
        LinearProgressIndicator(value: v > 0 ? v : null),
        const SizedBox(height: 8),
        Text(v > 0 ? '${(v * 100).toStringAsFixed(0)}%' : '连接中…', style: const TextStyle(fontSize: 12)),
      ])),
      actions: [TextButton(onPressed: () { background = true; Navigator.pop(c2);
          ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已转入后台下载, 完成后会通知你')));
        }, child: const Text('后台下载'))]));
    try {
      final dir = await _updateDir();
      final f = File('$dir/thirdhub-update-${DateTime.now().millisecondsSinceEpoch}.apk');
      final mirrors = _mirrorUrls(url, newVer);
      Exception? lastErr;
      var ok = false;
      for (var i = 0; i < mirrors.length && !ok; i++) {
        try {
          if (i > 0 && c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('主线路失败, 切换镜像 ${i + 1}/${mirrors.length}…')));
          progress.value = 0;
          await _fetchTo(mirrors[i], f, progress);
          ok = true;
        } catch (e) { lastErr = e is Exception ? e : Exception('$e'); }
      }
      if (!ok) throw lastErr ?? Exception('所有镜像均不可用');
      // 留档: 已下载安装包列表(可在 下载App 页重装, 不用重新下载)
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList('update_apks') ?? [];
      list.add('${f.path}|v$newVer|${DateTime.now().toString().substring(0, 16)}');
      await p.setStringList('update_apks', list);
      if (!background && c.mounted) Navigator.pop(c);
      if (background) {
        await Notify.show(88002, '更新包下载完成', 'v$newVer 已就绪, 点击安装');
      }
      if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(duration: const Duration(seconds: 6),
        content: Text('安装包已保存: ${f.path}')));
      final r = await OpenFilex.open(f.path);
      if (r.type != ResultType.done && c.mounted) {
        ScaffoldMessenger.of(c).showSnackBar(SnackBar(duration: const Duration(seconds: 10),
          content: Text('无法自动调起安装(${r.message})\n请到 下载App 页找到安装包手动安装'),
          action: SnackBarAction(label: '浏览器下载', onPressed: () => launchUrl(Uri.parse(mirrors.first), mode: LaunchMode.externalApplication))));
      }
    } catch (e) {
      if (!background && c.mounted) Navigator.pop(c);
      if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    }
  }
}


// ═══ 本地小说库 + 阅读器(txt/epub 章节切分) ═══
class LocalNovelsPage extends StatefulWidget { const LocalNovelsPage({super.key}); @override State<LocalNovelsPage> createState() => _Ln(); }
class _Ln extends State<LocalNovelsPage> {
  List<Map<String, dynamic>> items = []; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await LocalLib.list('novel'); setState(() => loading = false); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('本地小说'), actions: [
    IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await LocalLib.importNovels();
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(n > 0 ? '已导入 $n 本' : '未导入'))); _load(); })]),
    body: loading ? const Center(child: CircularProgressIndicator())
      : items.isEmpty ? const Center(child: Text('还没有本地小说\n点右上角 + 导入 txt / epub', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: items.length, itemBuilder: (_, i) { final b = items[i];
        return ListTile(leading: const Icon(Icons.menu_book),
          title: Text(b['name'] ?? ''), subtitle: Text('${b['format'] ?? 'txt'} · 本地', style: const TextStyle(fontSize: 11)),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => LocalNovelReader(book: b))),
          trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async { await LocalLib.remove('novel', b['path']); _load(); })); }));
}

class LocalNovelReader extends StatefulWidget { final Map<String, dynamic> book; const LocalNovelReader({super.key, required this.book}); @override State<LocalNovelReader> createState() => _Lnr(); }
class _Lnr extends State<LocalNovelReader> {
  List<Map<String, String>> chapters = []; int idx = 0; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Map<String, String> _chapMeta(String text, int i) {
    final firstLine = text.split('\n').first.trim();
    return {'name': firstLine.isEmpty ? '第${i + 1}节' : (firstLine.length > 30 ? '${firstLine.substring(0, 30)}…' : firstLine),
      'url': '$i'};
  }

  Future<void> _load() async {
    List<String> raw;
    try {
      final bytes = await File(widget.book['path']).readAsBytes();
      String text;
      try { text = utf8.decode(bytes); } catch (_) { text = latin1.decode(bytes); }
      raw = LocalLib.splitChapters(text);
    } catch (_) { raw = ['读取失败']; }
    chapters = [ for (var i = 0; i < raw.length; i++) _chapMeta(raw[i], i) ];
    // 恢复上次进度
    final p = await SharedPreferences.getInstance();
    idx = (p.getInt('progress_local_${widget.book['path']}') ?? 0).clamp(0, chapters.length - 1);
    setState(() => loading = false);
  }
  @override Widget build(BuildContext c) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return NovelReaderPage(
      sourceId: 'local', chapters: chapters, index: idx,
      bookName: widget.book['name'] ?? '', bookUrl: 'local_${widget.book['path']}',
      fetchContent: (sid, url) async {
        final i = int.tryParse(url) ?? 0;
        final bytes = await File(widget.book['path']).readAsBytes();
        String text;
        try { text = utf8.decode(bytes); } catch (_) { text = latin1.decode(bytes); }
        final raw = LocalLib.splitChapters(text);
        return {'text': raw[i.clamp(0, raw.length - 1)], 'images': <String>[]};
      },
      onProgress: (i, name) async {
        final p = await SharedPreferences.getInstance();
        await p.setInt('progress_local_${widget.book['path']}', i);
      });
  }
}

// ═══ 本地视频库 + 播放器 ═══
class LocalVideosPage extends StatefulWidget { const LocalVideosPage({super.key}); @override State<LocalVideosPage> createState() => _Lv(); }
class _Lv extends State<LocalVideosPage> {
  List<Map<String, dynamic>> items = []; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await LocalLib.list('video'); setState(() => loading = false); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('本地视频'), actions: [
    IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await LocalLib.importVideos();
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(n > 0 ? '已导入 $n 个' : '未导入'))); _load(); })]),
    body: loading ? const Center(child: CircularProgressIndicator())
      : items.isEmpty ? const Center(child: Text('还没有本地视频\n点右上角 + 导入 mp4 等', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: items.length, itemBuilder: (_, i) { final v = items[i];
        return ListTile(leading: const Icon(Icons.play_circle_outline),
          title: Text(v['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => LocalVideoPlayerPage(item: v))),
          trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async { await LocalLib.remove('video', v['path']); _load(); })); }));
}

class LocalVideoPlayerPage extends StatefulWidget { final Map<String, dynamic> item; const LocalVideoPlayerPage({super.key, required this.item}); @override State<LocalVideoPlayerPage> createState() => _Lvp(); }
class _Lvp extends State<LocalVideoPlayerPage> {
  VideoPlayerController? ctrl; ChewieController? chewie; String? err;
  String get _posKey => 'vpos_${widget.item['path']}';
  Timer? _posTimer; bool _fs = false;
  // 双击快进/快退提示
  String _seekHint = ''; Timer? _hintTimer;

  @override void initState() { super.initState(); _init(); }
  Future<void> _init() async {
    try {
      ctrl = VideoPlayerController.file(File(widget.item['path']));
      await ctrl!.initialize();
      // 断点续播
      final saved = AppSettings.p.getInt(_posKey) ?? 0;
      if (saved > 5 && saved < ctrl!.value.duration.inSeconds - 10) {
        await ctrl!.seekTo(Duration(seconds: saved));
      }
      chewie = ChewieController(videoPlayerController: ctrl!, autoPlay: true, looping: false,
        allowPlaybackSpeedChanging: true,
        playbackSpeeds: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0],
        allowFullScreen: true, allowMuting: true,
        materialProgressColors: ChewieProgressColors(playedColor: Theme.of(context).colorScheme.primary));
      _posTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (ctrl != null && ctrl!.value.isPlaying) AppSettings.p.setInt(_posKey, ctrl!.value.position.inSeconds);
      });
      setState(() {});
    } catch (e) { setState(() => err = '$e'); }
  }
  @override void dispose() { _posTimer?.cancel(); _hintTimer?.cancel();
    if (ctrl != null && ctrl!.value.isInitialized) {
      final pos = ctrl!.value.position.inSeconds;
      final dur = ctrl!.value.duration.inSeconds;
      if (pos > 5 && pos < dur - 10) AppSettings.p.setInt(_posKey, pos); else AppSettings.p.remove(_posKey);
    }
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    chewie?.dispose(); ctrl?.dispose(); super.dispose(); }

  void _seekBy(int seconds) {
    final c = ctrl; if (c == null || !c.value.isInitialized) return;
    final t = c.value.position + Duration(seconds: seconds);
    c.seekTo(t < Duration.zero ? Duration.zero : t);
    HapticFeedback.selectionClick();
    _hintTimer?.cancel();
    setState(() => _seekHint = seconds > 0 ? '快进 ${seconds}s ▶▶' : '◀◀ 快退 ${-seconds}s');
    _hintTimer = Timer(const Duration(milliseconds: 700), () { if (mounted) setState(() => _seekHint = ''); });
  }

  void _toggleFs() {
    setState(() => _fs = !_fs);
    SystemChrome.setPreferredOrientations(_fs
      ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
      : DeviceOrientation.values);
  }

  @override Widget build(BuildContext c) {
    final body = err != null ? Text('播放失败: $err', style: const TextStyle(color: Colors.red))
      : chewie != null ? GestureDetector(
          onDoubleTapDown: (d) {
            final w = MediaQuery.of(c).size.width;
            _seekBy(d.globalPosition.dx < w / 2 ? -10 : 10);
          },
          onDoubleTap: () {},
          child: Stack(alignment: Alignment.center, children: [
            AspectRatio(aspectRatio: ctrl!.value.aspectRatio, child: Chewie(controller: chewie!)),
            if (_seekHint.isNotEmpty) IgnorePointer(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(_seekHint, style: const TextStyle(color: Colors.white, fontSize: 14)))),
          ]))
      : const CircularProgressIndicator();
    if (_fs) return Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Stack(children: [
      Center(child: body),
      Positioned(top: 4, left: 4, child: IconButton(icon: const Icon(Icons.fullscreen_exit, color: Colors.white), onPressed: _toggleFs)),
    ])));
    return Scaffold(appBar: AppBar(title: Text(widget.item['name'] ?? '', style: const TextStyle(fontSize: 14)),
      actions: [IconButton(icon: const Icon(Icons.fullscreen), tooltip: '横屏全屏', onPressed: _toggleFs)]),
      body: Center(child: body));
  }
}

// ═══ 本地音乐库 ═══
class LocalMusicsPage extends StatefulWidget { const LocalMusicsPage({super.key}); @override State<LocalMusicsPage> createState() => _Lm(); }
class _Lm extends State<LocalMusicsPage> {
  List<Map<String, dynamic>> items = []; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await LocalLib.list('music'); setState(() => loading = false); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('本地音乐'), actions: [
    IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await LocalLib.importAudios();
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(n > 0 ? '已导入 $n 首' : '未导入'))); _load(); })]),
    body: loading ? const Center(child: CircularProgressIndicator())
      : items.isEmpty ? const Center(child: Text('还没有本地音乐\n点右上角 + 导入 mp3 等', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: items.length, itemBuilder: (_, i) { final m = items[i];
        return ListTile(leading: const Icon(Icons.music_note),
          title: Text(m['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => MusicPlayPage(item: {'name': m['name'], 'url': m['path'], 'artist': '本地', 'coverUrl': ''}))),
          trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async { await LocalLib.remove('music', m['path']); _load(); })); }));
}

// ═══ 本地漫画库 + 阅读器(图片序列/zip/cbz) ═══
class LocalComicsPage extends StatefulWidget { const LocalComicsPage({super.key}); @override State<LocalComicsPage> createState() => _Lc(); }
class _Lc extends State<LocalComicsPage> {
  List<Map<String, dynamic>> items = []; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await LocalLib.list('comic'); setState(() => loading = false); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('本地漫画'), actions: [
    IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await LocalLib.importComic();
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(n > 0 ? '已导入 $n 部' : '未导入'))); _load(); })]),
    body: loading ? const Center(child: CircularProgressIndicator())
      : items.isEmpty ? const Center(child: Text('还没有本地漫画\n点右上角 + 导入图片或 zip/cbz', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: items.length, itemBuilder: (_, i) { final m = items[i];
        final pages = (m['pages'] as List?)?.length ?? 0;
        return ListTile(leading: const Icon(Icons.photo_library),
          title: Text(m['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('$pages 页', style: const TextStyle(fontSize: 11)),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => LocalComicReader(comic: m))),
          trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async { await LocalLib.remove('comic', m['path']); _load(); })); }));
}

class LocalComicReader extends StatefulWidget { final Map<String, dynamic> comic; const LocalComicReader({super.key, required this.comic}); @override State<LocalComicReader> createState() => _Lcr(); }
class _Lcr extends State<LocalComicReader> {
  late final List<String> pages = ((widget.comic['pages'] as List?) ?? []).cast<String>();
  final ctrl = PageController(); int idx = 0;
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text('${widget.comic['name']} (${idx + 1}/${pages.length})', style: const TextStyle(fontSize: 13))),
    body: PageView.builder(controller: ctrl, itemCount: pages.length,
      onPageChanged: (i) => setState(() => idx = i),
      itemBuilder: (_, i) => InteractiveViewer(maxScale: 5,
        child: Center(child: Image.file(File(pages[i]), fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 64))))));
}


// ═══════════════════════════════════════════════════════════════
// v4.2: 丝滑转场 + 子页面体系 + 多屏适配
// ═══════════════════════════════════════════════════════════════

// 全局转场: 淡入+轻滑(类似完全体的顺滑感)
class _SmoothTransitionsBuilder extends PageTransitionsBuilder {
  const _SmoothTransitionsBuilder();
  @override Widget buildTransitions<T>(PageRoute<T> route, BuildContext context,
      Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(opacity: curved, child: SlideTransition(
      position: Tween(begin: const Offset(0.05, 0), end: Offset.zero).animate(curved),
      child: child));
  }
}

Route smoothRoute(Widget page) => MaterialPageRoute(builder: (_) => page);

// 屏幕适配: 手表(<360)紧凑 / 手机正常 / 折叠屏展开·平板(>=720)双栏
class ScreenFit {
  static double width(BuildContext c) => MediaQuery.of(c).size.width;
  static bool get isWatch => _w < 360;
  static bool get isWide => _w >= 720;
  static double _w = 400;
  static void update(BuildContext c) { _w = width(c); }
  static double get pad => isWatch ? 8 : 14;
  static double contentWidth(double w) => w >= 720 ? 900 : w;
}

// ── 子页面: 账号 ──
class AccountPage extends StatefulWidget { const AccountPage({super.key}); @override State<AccountPage> createState() => _Ap(); }
class _Ap extends State<AccountPage> {
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('账号')),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: const AccountTile()),
      if (Cloud.loggedIn) Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.badge_outlined, size: 20), title: const Text('身份码', style: TextStyle(fontSize: 14)),
          subtitle: Text(AppSettings.identityCode.isEmpty ? '生成中…' : AppSettings.identityCode, style: const TextStyle(fontSize: 12)),
          trailing: IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () {
            ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('身份码已复制'))); })),
        ListTile(leading: const Icon(Icons.notes, size: 20), title: const Text('简介', style: TextStyle(fontSize: 14)),
          subtitle: Text(AppSettings.bio.isEmpty ? '这个人很懒，什么都没写' : AppSettings.bio, style: const TextStyle(fontSize: 12)),
          onTap: () async {
            final cc = TextEditingController(text: AppSettings.bio);
            final r = await showDialog<String>(context: c, builder: (c2) => AlertDialog(title: const Text('简介'),
              content: TextField(controller: cc, maxLines: 2),
              actions: [TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c2, cc.text), child: const Text('保存'))]));
            if (r != null) { await AppSettings.setBio(r);
              if (Cloud.loggedIn) { try { await Cloud.updateProfile({'bio': r}); } catch (_) {} }
              setState(() {}); } }),
      ])),
    ]));
}

// ── 子页面: 下载 App ──
class DownloadAppsPage extends StatefulWidget { const DownloadAppsPage({super.key}); @override State<DownloadAppsPage> createState() => _Da(); }
class _Da extends State<DownloadAppsPage> {
  List<String> apks = [];
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList('update_apks') ?? [];
    // 过滤掉文件已不存在的
    final alive = <String>[];
    for (final e in list) { if (await File(e.split('|').first).exists()) alive.add(e); }
    setState(() => apks = alive.reversed.toList());
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('下载 App')),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      const Padding(padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Text('ThirdHub 全系列产品 · 点按查看详情与下载 · 覆盖安装数据保留', style: TextStyle(fontSize: 12, color: Colors.grey))),
      const Card(child: DownloadCenterTile()),
      if (apks.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Text('已下载的安装包(点按安装 · 长按删除)', style: TextStyle(fontSize: 12, color: Colors.grey))),
        Card(child: Column(children: [
          for (final e in apks)
            ListTile(dense: true, leading: const Icon(Icons.android, size: 20),
              title: Text(e.split('|').length > 1 ? e.split('|')[1] : '安装包', style: const TextStyle(fontSize: 13)),
              subtitle: Text(e.split('|').first, style: const TextStyle(fontSize: 9, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.install_mobile, size: 18),
              onTap: () => OpenFilex.open(e.split('|').first),
              onLongPress: () async {
                final ok = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(
                  title: const Text('删除安装包'),
                  content: Text('删除 ${e.split('|').length > 1 ? e.split('|')[1] : '该安装包'}? 删除后需重新下载'),
                  actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('删除'))]));
                if (ok == true) {
                  try {
                    final src = File(e.split('|').first);
                    final dir = await Updater._updateDir();
                    final td = Directory('$dir/trash'); if (!await td.exists()) await td.create(recursive: true);
                    final np = '${td.path}/${src.path.split('/').last}';
                    if (await src.exists()) await src.rename(np);
                    final parts = e.split('|');
                    await Trash.add('apk', parts.length > 1 ? parts[1] : '安装包',
                      {'path': np, 'name': parts.length > 1 ? parts[1] : '安装包', 'date': parts.length > 2 ? parts[2] : ''});
                  } catch (_) {}
                  final p = await SharedPreferences.getInstance();
                  final list = p.getStringList('update_apks') ?? [];
                  list.remove(e);
                  await p.setStringList('update_apks', list);
                  _load();
                }
              }),
        ])),
      ],
      const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text('历史版本更新记录', style: TextStyle(fontSize: 12, color: Colors.grey))),
      FutureBuilder<Map<String, dynamic>?>(future: Cloud.latestManifest('app'),
        builder: (c2, snap) {
          final m = snap.data;
          final latestVer = (m?['version'] as String?) ?? '';
          final latestUrl = (m?['url'] as String?) ?? '';
          return Card(child: Column(children: [
            for (var i = 0; i < kChangelog.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 56),
              Builder(builder: (c3) {
                final v = kChangelog[i];
                final isCurrent = v.$1 == 'v${Updater.currentVersion}';
                final isLatestAvail = latestVer.isNotEmpty && v.$1 == 'v$latestVer'
                    && Updater._verCmp(latestVer, Updater.currentVersion) > 0;
                return ListTile(dense: true, leading: const Icon(Icons.history, size: 18),
                  title: Row(children: [
                    Text(v.$1, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    if (i == 0) _tag('最新', Colors.blueAccent),
                    if (isCurrent) _tag('当前版本', Colors.green),
                    if (v.$3.isNotEmpty) _tag(v.$3, v.$3 == '重构' ? Colors.deepOrange : Colors.purple),
                  ]),
                  subtitle: Text(v.$2, style: const TextStyle(fontSize: 11)),
                  trailing: isLatestAvail
                    ? FilledButton.tonal(style: FilledButton.styleFrom(visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10)),
                        onPressed: () => Updater.downloadProduct(c3, latestUrl, 'ThirdHub-$latestVer.apk'),
                        child: const Text('下载此版本', style: TextStyle(fontSize: 11)))
                    : null);
              }),
            ],
          ]));
        }),
    ]));
}

Widget _tag(String t, Color c) => Container(margin: const EdgeInsets.only(left: 6),
  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
  decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(4),
    border: Border.all(color: c.withValues(alpha: 0.4), width: 0.5)),
  child: Text(t, style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w600)));

// ── 子页面: 个性化(语言/主题/强调色/开屏动画) ──
class AppearancePage extends StatefulWidget { const AppearancePage({super.key}); @override State<AppearancePage> createState() => _Ape(); }
class _Ape extends State<AppearancePage> {
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(tr('个性化'))),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.language, size: 20), title: const Text('语言', style: TextStyle(fontSize: 14)),
          subtitle: Text(AppSettings.locale == 'system' ? '跟随系统(默认中文)' : I18n.names[AppSettings.locale] ?? '中文',
            style: const TextStyle(fontSize: 11)),
          onTap: () async {
            final l = await showDialog<String>(context: c, builder: (c2) => SimpleDialog(title: const Text('语言 / Language'),
              children: [
                SimpleDialogOption(onPressed: () => Navigator.pop(c2, 'system'),
                  child: Row(children: [ if (AppSettings.locale == 'system') const Icon(Icons.check, size: 16, color: Colors.blueAccent),
                    const Text('跟随系统 / System') ])),
                for (final lc in I18n.supported) SimpleDialogOption(onPressed: () => Navigator.pop(c2, lc),
                  child: Row(children: [ if (lc == AppSettings.locale) const Icon(Icons.check, size: 16, color: Colors.blueAccent),
                    Text(I18n.names[lc] ?? lc) ])),
              ]));
            if (l != null) { await AppSettings.setLocale(l); setState(() {}); } }),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.brightness_6_outlined, size: 20), title: Text(tr('主题外观'), style: const TextStyle(fontSize: 14)),
          subtitle: const Text('默认跟随系统', style: TextStyle(fontSize: 11)),
          trailing: SegmentedButton<String>(showSelectedIcon: false, style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: [ButtonSegment(value: 'system', label: Text(tr('跟随系统'), style: const TextStyle(fontSize: 10))), ButtonSegment(value: 'light', label: Text(tr('浅色'), style: const TextStyle(fontSize: 10))), ButtonSegment(value: 'dark', label: Text(tr('深色'), style: const TextStyle(fontSize: 10)))],
            selected: {AppSettings.themeModeStr}, onSelectionChanged: (s) => AppSettings.setThemeMode(s.first).then((_) => setState(() {})))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.color_lens_outlined, size: 20), title: Text(tr('强调色'), style: const TextStyle(fontSize: 14)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [ for (final col in [0xFF3B5BFD, 0xFF7C6CFF, 0xFF4ADE80, 0xFFF472B6, 0xFFFBBF24])
            GestureDetector(onTap: () => AppSettings.setAccent(col).then((_) => setState(() {})),
              child: Container(width: 22, height: 22, margin: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(
                color: Color(col), shape: BoxShape.circle, border: AppSettings.accentColor == col ? Border.all(color: Colors.white, width: 2) : null))) ])),
        const Divider(height: 1, indent: 56),
        SwitchListTile(secondary: const Icon(Icons.movie_filter_outlined, size: 20), title: Text(tr('开屏动画'), style: const TextStyle(fontSize: 14)),
          value: AppSettings.splashAnim, onChanged: (v) async {
            if (!v) {
              final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
                title: const Text('关闭开屏动画'),
                content: const Text('关闭后启动时将白屏加载（应用仍在正常初始化），属正常现象，并非卡顿。开屏动画仅用于展示加载过程，本身不会延长启动时间。'),
                actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('仍然关闭'))]));
              if (ok != true) return;
            }
            await AppSettings.setSplashAnim(v); if (mounted) setState(() {});
          }),
      ])),
    ]));
}

// ── 子页面: 导航 ──
class NavSettingsPage extends StatefulWidget { const NavSettingsPage({super.key}); @override State<NavSettingsPage> createState() => _Ns(); }
class _Ns extends State<NavSettingsPage> {
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(tr('导航'))),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.navigation_outlined, size: 20), title: const Text('底部导航栏', style: TextStyle(fontSize: 14)),
          subtitle: const Text('像网站一样自定义显示哪些模块', style: TextStyle(fontSize: 11)),
          onTap: () => showNavSettings(c)),
        const Divider(height: 1, indent: 56),
        // 导航形态: 底部导航栏 / 折叠细条 / 悬浮球
        ListTile(leading: const Icon(Icons.dashboard_customize_outlined, size: 20), title: const Text('导航形态', style: TextStyle(fontSize: 14)),
          subtitle: const Text('底部导航栏 · 折叠 · 悬浮球', style: TextStyle(fontSize: 11)),
          trailing: SegmentedButton<String>(showSelectedIcon: false, style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: 'bar', label: Text('导航栏', style: TextStyle(fontSize: 10))),
              ButtonSegment(value: 'fold', label: Text('折叠', style: TextStyle(fontSize: 10))),
              ButtonSegment(value: 'orb', label: Text('悬浮球', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.navStyle},
            onSelectionChanged: (s) { AppSettings.setNavStyle(s.first).then((_) { RootNav.navTick.value++; setState(() {}); }); })),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.ads_click, size: 20), title: const Text('悬浮球自动吸附边缘', style: TextStyle(fontSize: 14)),
          subtitle: const Text('关闭后可自由拖动, 停哪放哪', style: TextStyle(fontSize: 11)),
          trailing: Switch(value: AppSettings.orbSnap,
            onChanged: (v) => AppSettings.setOrbSnap(v).then((_) => setState(() {})))),
        const Divider(height: 1, indent: 56),
        SwitchListTile(secondary: const Icon(Icons.unfold_less, size: 20),
          title: const Text('点击正文自动收起导航栏', style: TextStyle(fontSize: 14)),
          subtitle: const Text('点一下正文收起为 1/3 细条并保持, 点细条恢复; 长按底栏弹出模块抽屉', style: TextStyle(fontSize: 11)),
          value: AppSettings.navAutoHide,
          onChanged: (v) => AppSettings.setNavAutoHide(v).then((_) { RootNav.navTick.value++; setState(() {}); })),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.swipe_outlined, size: 20), title: Text(tr('悬浮球默认位置'), style: const TextStyle(fontSize: 14)),
          trailing: SegmentedButton<String>(showSelectedIcon: false, style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: [ButtonSegment(value: 'left', label: Text(tr('左侧'), style: const TextStyle(fontSize: 10))), ButtonSegment(value: 'right', label: Text(tr('右侧'), style: const TextStyle(fontSize: 10)))],
            selected: {AppSettings.navSide}, onSelectionChanged: (s) => AppSettings.setNavSide(s.first).then((_) => setState(() {})))),
      ])),
    ]));
}

// ── 子页面: 系统 ──
class SystemPage extends StatefulWidget { const SystemPage({super.key}); @override State<SystemPage> createState() => _Sy(); }
class _Sy extends State<SystemPage> {
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(tr('系统'))),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.dns_outlined, size: 20), title: const Text('资源库状态', style: TextStyle(fontSize: 14)),
          subtitle: const Text('查看后端与在线引擎', style: TextStyle(fontSize: 11)),
          onTap: () => Navigator.push(c, smoothRoute(const EnginesPage()))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.download_outlined, size: 20), title: const Text('下载与存储', style: TextStyle(fontSize: 14)),
          subtitle: const Text('后端下载任务 · 网盘', style: TextStyle(fontSize: 11)),
          onTap: () => Navigator.push(c, smoothRoute(Scaffold(appBar: AppBar(title: const Text('下载与存储')), body: const ToolsSection())))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.link, size: 20), title: const Text('连接资源库', style: TextStyle(fontSize: 14)),
          subtitle: const Text('手动输入地址 / 局域网自动发现', style: TextStyle(fontSize: 11)),
          onTap: () => Navigator.push(c, smoothRoute(const ConnectLibraryPage()))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.shield_outlined, size: 20), title: Text(tr('贤者模式（内容保护）'), style: const TextStyle(fontSize: 14)),
          subtitle: const Text('PIN锁 · 在"连接资源库"页设置', style: TextStyle(fontSize: 11)),
          onTap: () => Navigator.push(c, smoothRoute(const ConnectLibraryPage()))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.delete_sweep_outlined, size: 20), title: Text(tr('清理缓存'), style: const TextStyle(fontSize: 14)),
          onTap: () async { final p = await SharedPreferences.getInstance();
            for (final k in ['sh_novel', 'search_history']) { await p.remove(k); }
            if (mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('缓存已清理'))); }),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.lock_outline, size: 20), title: const Text('传输加密', style: TextStyle(fontSize: 14)),
          subtitle: const Text('前端⇄后端 · 默认不加密(局域网信任)', style: TextStyle(fontSize: 11)),
          trailing: SegmentedButton<String>(showSelectedIcon: false, style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const [ButtonSegment(value: 'none', label: Text('不加密', style: TextStyle(fontSize: 10))), ButtonSegment(value: 'aes-gcm', label: Text('AES-GCM', style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.encMode}, onSelectionChanged: (s) => AppSettings.setEncMode(s.first).then((_) => setState(() {})))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.system_update_alt, size: 20), title: Text(tr('版本与更新'), style: const TextStyle(fontSize: 14)),
          subtitle: Text('v${Updater.currentVersion} · 点按检查更新', style: const TextStyle(fontSize: 11)),
          onTap: () => Updater.check(c, manual: true)),
      ])),
    ]));
}

// ── 子页面: 云端 ──
class CloudPage extends StatelessWidget { const CloudPage({super.key});
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(tr('云端'))),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.cloud_outlined, size: 20), title: Text(tr('云存储'), style: const TextStyle(fontSize: 14)),
          subtitle: Text('用量 ${AppSettings.localUsageKB.toStringAsFixed(1)}KB / 1024KB · 进度存自己后端不占配额', style: const TextStyle(fontSize: 11))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.workspace_premium_outlined, size: 20), title: Text(tr('会员等级'), style: const TextStyle(fontSize: 14)),
          subtitle: const Text('免费 · 会员体系冻结期', style: TextStyle(fontSize: 11)), enabled: false),
      ])),
    ]));
}

// ── 子页面: 关于(模块介绍 + 协议入口 + 致谢) ──
class AboutPage extends StatelessWidget { const AboutPage({super.key});
  static const _features = {
    '搜索': '全局聚合搜索 · 同时检索资源库与局域网引擎 · 结果按模块分类',
    '小说': '书架/历史/发现 · 沉浸阅读器(字体/主题/翻页) · 音量键翻页 · 本地导入',
    '漫画': '条漫/翻页双模式 · 引擎直连阅读 · 本地漫画导入',
    '视频': '片库/历史/发现 · 断点续播 · 选集连播 · 本地播放',
    '音乐': '歌单/收藏/历史 · 通知栏控制 · LRC同步歌词 · 断点续播',
    'AI': '多模型六分类 · 统一密钥库 · 思考链 · 联网搜索 · MCP · 消息排队',
    '直播': '直播源聚合播放 · 低延迟',
    '浏览器': '内置网页浏览 · 全屏模式 · 沉浸式布局',
    '相册': '系统相册浏览 · 一键备份到资源库',
    '文件': '本地文件管理 · 与资源库互通 · 回收站',
    '我的': '账号云端同步 · 个性化外观 · 导航定制 · 版本更新',
  };
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(tr('关于'))),
    body: ListView(padding: EdgeInsets.all(ScreenFit.pad), children: [
      Card(child: Column(children: [
        const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Align(alignment: Alignment.centerLeft,
            child: Text('模块介绍', style: TextStyle(fontSize: 12, color: Colors.grey)))),
        for (final e in kModules.entries)
          if (_features.containsKey(e.key))
            ListTile(dense: true, leading: Icon(e.value.icon, size: 20),
              title: Text(e.value.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: Text(_features[e.key]!, style: const TextStyle(fontSize: 11))),
      ])),
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.privacy_tip_outlined, size: 20), title: const Text('隐私政策', style: TextStyle(fontSize: 14)),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LegalDocPage(title: '隐私政策', asset: 'assets/legal/privacy.md')))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.description_outlined, size: 20), title: const Text('用户服务协议', style: TextStyle(fontSize: 14)),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LegalDocPage(title: '用户服务协议', asset: 'assets/legal/terms.md')))),
        const Divider(height: 1, indent: 56),
        ListTile(leading: const Icon(Icons.favorite_border, size: 20), title: Text(tr('开源致谢'), style: const TextStyle(fontSize: 14)),
          subtitle: const Text('Legado/dr_py/Venera/MusicFree/Cloudreve 及全体开源社区', style: TextStyle(fontSize: 11))),
      ])),
      const SizedBox(height: 12),
      Center(child: Text('ThirdHub v${Updater.currentVersion} · 纯播放器前端 · 支持 IPv6', style: const TextStyle(fontSize: 11, color: Colors.grey))),
    ]));
}


// ═══ 直连引擎条目详情: 目录→内容(不经过后端, THP 直连) ═══
class EngineItemPage extends StatefulWidget { final String type; final Map item;
  const EngineItemPage({super.key, required this.type, required this.item}); @override State<EngineItemPage> createState() => _Ei(); }
class _Ei extends State<EngineItemPage> {
  List<Map<String, dynamic>> chapters = []; bool loading = true; String err = '';
  String get id => '${widget.item['id'] ?? widget.item['bookUrl'] ?? widget.item['url'] ?? ''}';
  String get name => '${widget.item['name'] ?? widget.item['title'] ?? ''}';
  String get cover => '${widget.item['coverUrl'] ?? ''}';
  String get authorS => '${widget.item['author'] ?? ''}';
  String get introS => '${widget.item['intro'] ?? ''}';
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { chapters = await EngineDirect.chapters(widget.type, id); }
    catch (e) { err = '$e'; }
    // 无目录的直出条目(音乐单曲/视频直链): 直接取内容
    if (chapters.isEmpty && err.isEmpty) { _open(null); return; }
    if (mounted) setState(() => loading = false);
  }
  Future<Map<String, dynamic>> _content(String chapter) async {
    final d = await EngineDirect.content(widget.type, id, chapter);
    if (d['pages'] != null && d['images'] == null) d['images'] = d['pages']; // THP v1 images/pages 归一
    if (d['text'] == null && d['content'] != null) d['text'] = d['content']; // 正文 text/content 归一
    return d;
  }
  Future<void> _open(int? index) async {
    final t = widget.type;
    if (t == 'comic') {
      Navigator.push(context, MaterialPageRoute(builder: (_) => EngineComicReader(
        chapters: chapters, index: index ?? 0, comicName: name,
        fetch: (chapUrl) => _content(chapUrl))));
      return;
    }
    if (t == 'novel') {
      final i = index ?? 0;
      Navigator.push(context, MaterialPageRoute(builder: (_) => NovelReaderPage(
        sourceId: 'engine', chapters: chapters, index: i, bookName: name, bookUrl: id,
        fetchContent: (s, url) => _content(url))));
      return;
    }
    // 音乐/视频: 取内容地址直接播
    try {
      final chapUrl = index != null ? '${chapters[index]['url'] ?? index}' : '';
      final title = index != null ? '${chapters[index]['name'] ?? name}' : name;
      final d = await _content(chapUrl);
      if (!mounted) return;
      if (t == 'music') {
        Navigator.push(context, MaterialPageRoute(builder: (_) => MusicPlayPage(item: {
          'name': title, 'url': d['url'] ?? '', 'artist': authorS,
          'coverUrl': cover, 'lyric': d['lyric'] ?? ''})));
      } else {
        Navigator.push(context, MaterialPageRoute(builder: (_) => UrlVideoPlayer(
          url: '${d['url'] ?? ''}', title: title,
          headers: Map<String, String>.from(d['headers'] ?? d['header'] ?? {}))));
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取播放地址失败: $e'))); }
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
    body: loading ? const Center(child: CircularProgressIndicator())
      : err.isNotEmpty ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('加载目录失败: $err', style: const TextStyle(color: Colors.redAccent))))
      : ListView(children: [
        // 信息头
        Padding(padding: const EdgeInsets.all(12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 72, height: 96,
            child: cover.isNotEmpty ? Image.network(cover, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26)) : const ColoredBox(color: Colors.black26))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            if (authorS.isNotEmpty) Text(authorS, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (introS.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(introS, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey))),
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('${chapters.length} 个章节/选集 · 来自 ${EngineDirect.name}',
              style: const TextStyle(fontSize: 10, color: Colors.grey))),
          ])),
        ])),
        const Divider(height: 1),
        for (var i = 0; i < chapters.length; i++)
          ListTile(dense: true, title: Text(() { final n = '${chapters[i]['name'] ?? ''}'; return n.isNotEmpty ? n : '第${i + 1}集'; }(), style: const TextStyle(fontSize: 13)),
            onTap: () => _open(i)),
      ]));
}

// 直链视频播放器(引擎直连内容用)
class UrlVideoPlayer extends StatefulWidget { final String url, title; final Map<String, String> headers;
  const UrlVideoPlayer({super.key, required this.url, required this.title, this.headers = const {}}); @override State<UrlVideoPlayer> createState() => _Uvp(); }
class _Uvp extends State<UrlVideoPlayer> {
  VideoPlayerController? vc; ChewieController? cc; String err = '';
  Timer? _posTimer;
  String get _posKey => 'vpos_${widget.url}';
  @override void initState() { super.initState(); _boot(); }
  Future<void> _boot() async {
    try {
      vc = VideoPlayerController.networkUrl(Uri.parse(widget.url), httpHeaders: widget.headers);
      await vc!.initialize();
      // 断点续播: 恢复上次进度(>10s 且未到结尾)
      final s = AppSettings.p.getInt(_posKey) ?? 0;
      final dur = vc!.value.duration;
      final startAt = (s > 10 && s < dur.inSeconds - 10) ? Duration(seconds: s) : null;
      cc = ChewieController(videoPlayerController: vc!, autoPlay: true, allowFullScreen: true,
        startAt: startAt,
        playbackSpeeds: const [0.5, 1.0, 1.25, 1.5, 2.0, 3.0]);
      if (startAt != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已从 ${startAt.inMinutes.toString().padLeft(2, '0')}:${(startAt.inSeconds % 60).toString().padLeft(2, '0')} 继续播放'), duration: const Duration(seconds: 2)));
      }
      _posTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (vc != null && vc!.value.isPlaying && vc!.value.position.inSeconds > 5) {
          AppSettings.p.setInt(_posKey, vc!.value.position.inSeconds);
        }
      });
    } catch (e) { err = '$e'; }
    if (mounted) setState(() {});
  }
  @override void dispose() {
    _posTimer?.cancel();
    if (vc != null && vc!.value.position.inSeconds > 5) AppSettings.p.setInt(_posKey, vc!.value.position.inSeconds);
    cc?.dispose(); vc?.dispose(); super.dispose();
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
    body: Center(child: err.isNotEmpty ? Text('播放失败: $err', style: const TextStyle(color: Colors.redAccent))
      : cc == null ? const CircularProgressIndicator()
      : AspectRatio(aspectRatio: vc!.value.aspectRatio > 0 ? vc!.value.aspectRatio : 16 / 9, child: Chewie(controller: cc!))));
}

// 引擎直连漫画阅读器(条漫滚动/翻页, 图片来源 THP /thp/content images)
class EngineComicReader extends StatefulWidget {
  final List chapters; final int index; final String comicName;
  final Future<Map<String, dynamic>> Function(String chapUrl) fetch;
  const EngineComicReader({super.key, required this.chapters, required this.index, required this.comicName, required this.fetch});
  @override State<EngineComicReader> createState() => _Ecr();
}
class _Ecr extends State<EngineComicReader> {
  late int idx = widget.index;
  List<String> images = []; Map<String, String> headers = {};
  bool loading = true; String err = ''; bool paged = false;
  final PageController pc = PageController();
  @override void initState() { super.initState(); _load(); }
  String get chapUrl { final ch = widget.chapters[idx]; return '${ch['url'] ?? ch['id'] ?? idx}'; }
  String get chapName { final ch = widget.chapters[idx]; final n = '${ch['name'] ?? ''}'; return n.isNotEmpty ? n : '第${idx + 1}话'; }
  Future<void> _load() async {
    setState(() { loading = true; err = ''; images = []; });
    try {
      final d = await widget.fetch(chapUrl);
      final raw = (d['images'] as List? ?? d['pages'] as List? ?? []);
      images = [for (final e in raw) '$e'];
      headers = Map<String, String>.from(d['headers'] ?? d['header'] ?? {});
      if (images.isEmpty) err = '本话没有图片';
    } catch (e) { err = '$e'; }
    if (mounted) setState(() => loading = false);
  }
  void _go(int i) {
    if (i < 0 || i >= widget.chapters.length) return;
    idx = i; if (paged) pc.jumpToPage(0);
    _load();
  }
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text('${widget.comicName} · $chapName', maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(icon: Icon(paged ? Icons.view_day : Icons.chrome_reader_mode, size: 20),
          tooltip: paged ? '条漫滚动' : '翻页模式',
          onPressed: () { setState(() => paged = !paged); }),
      ]),
    body: loading ? const Center(child: CircularProgressIndicator())
      : err.isNotEmpty ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('加载失败: $err', style: const TextStyle(color: Colors.redAccent))))
      : paged
        ? PageView.builder(controller: pc, itemCount: images.length,
            itemBuilder: (_, i) => InteractiveViewer(child: Center(child: Image.network(images[i], headers: headers, fit: BoxFit.contain,
              loadingBuilder: (_, w, p) => p == null ? w : const Center(child: CircularProgressIndicator()),
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey)))))
        : ListView.builder(itemCount: images.length + 1, itemBuilder: (_, i) {
            if (i == images.length) {
              return Padding(padding: const EdgeInsets.all(16), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                if (idx > 0) FilledButton.tonal(onPressed: () => _go(idx - 1), child: const Text('上一话')),
                if (idx < widget.chapters.length - 1) FilledButton(onPressed: () => _go(idx + 1), child: const Text('下一话')),
              ]));
            }
            return Image.network(images[i], headers: headers, fit: BoxFit.fitWidth,
              loadingBuilder: (_, w, p) => p == null ? w : Container(height: 160, alignment: Alignment.center, child: const CircularProgressIndicator()),
              errorBuilder: (_, __, ___) => Container(height: 120, alignment: Alignment.center, child: const Icon(Icons.broken_image, color: Colors.grey)));
          }),
    bottomNavigationBar: paged && !loading && err.isEmpty ? BottomAppBar(height: 48, child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      TextButton(onPressed: idx > 0 ? () => _go(idx - 1) : null, child: const Text('上一话')),
      Text('${idx + 1}/${widget.chapters.length} 话', style: const TextStyle(fontSize: 12, color: Colors.grey)),
      TextButton(onPressed: idx < widget.chapters.length - 1 ? () => _go(idx + 1) : null, child: const Text('下一话')),
    ])) : null);
}


// ═══ 导航悬浮球: 可自由拖动/自动吸边, 点按弹出模块宫格(按屏宽自适应排布) ═══
class NavOrb extends StatefulWidget {
  const NavOrb({super.key});
  // 模块宫格: 悬浮球与折叠导航共用
  static void showModuleGrid(BuildContext c, List<String> enabled, int cur, void Function(int) onGo) {
    showModalBottomSheet(context: c, builder: (c2) {
      final w = MediaQuery.of(c2).size.width;
      final cols = (w / 88).floor().clamp(3, 8);
      return SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('切换模块', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        GridView.count(shrinkWrap: true, crossAxisCount: cols, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.1,
          children: [ for (var i = 0; i < enabled.length; i++) () {
            final m = kModules[enabled[i]]!; final on = i == cur;
            // 网页端 vb-pop 同款: 逐格上移+缩放入场
            return TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 180 + i * 30), curve: Curves.easeOutCubic,
              builder: (_, v, child) => Opacity(opacity: v,
                child: Transform.translate(offset: Offset(0, 10 * (1 - v)),
                  child: Transform.scale(scale: 0.97 + 0.03 * v, child: child))),
              child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () { Navigator.pop(c2); onGo(i); },
              child: Container(decoration: BoxDecoration(
                  color: on ? Theme.of(c2).colorScheme.primaryContainer : null,
                  borderRadius: BorderRadius.circular(14)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(m.icon, size: 24, color: on ? Theme.of(c2).colorScheme.primary : null),
                  const SizedBox(height: 4),
                  Text(tr(m.name), style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]))));
          }() ]),
      ])));
    });
  }
  @override State<NavOrb> createState() => _NavOrbState();
}
class _NavOrbState extends State<NavOrb> {
  Offset pos = const Offset(-1, -1);
  static const double sz = 52;
  @override void initState() { super.initState(); pos = AppSettings.orbPos; }
  void _snap(Size screen) {
    if (!AppSettings.orbSnap) { AppSettings.setOrbPos(pos); return; } // 自由模式: 停哪放哪
    setState(() => pos = Offset((pos.dx + sz / 2) < screen.width / 2 ? 10 : screen.width - sz - 10,
      pos.dy.clamp(80.0, screen.height - 220)));
    AppSettings.setOrbPos(pos);
  }
  @override Widget build(BuildContext c) {
    final screen = MediaQuery.of(c).size;
    if (pos.dx < 0) { // 首次: 按默认侧边放置
      final right = AppSettings.navSide == 'right';
      pos = Offset(right ? screen.width - sz - 10 : 10, screen.height * 0.55);
    }
    return Positioned(left: pos.dx, top: pos.dy, child: GestureDetector(
      onPanUpdate: (d) => setState(() => pos = Offset(
        (pos.dx + d.delta.dx).clamp(0.0, screen.width - sz), (pos.dy + d.delta.dy).clamp(60.0, screen.height - 120))),
      onPanEnd: (_) => _snap(screen),
      onTap: () {
        HapticFeedback.selectionClick();
        final st = c.findAncestorStateOfType<_RootNavState>();
        if (st != null) NavOrb.showModuleGrid(c, st.enabled, st.idx, (i) => st._go(i, animate: false));
      },
      onLongPress: () {
        HapticFeedback.selectionClick();
        c.findAncestorStateOfType<_RootNavState>()?.openModuleMenu();
      },
      child: Container(width: sz, height: sz, decoration: BoxDecoration(
          color: Theme.of(c).colorScheme.primaryContainer.withValues(alpha: 0.92), shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8)]),
        child: Icon(Icons.apps, color: Theme.of(c).colorScheme.primary))));
  }
}