// ThirdHub v4 Flutter m2: 纯播放器前端 = 小说阅读器 + 漫画播放器 + 视频播放器
// 定位: 零处理逻辑, 只渲染后端IR。净化在插件(Legado)完成, 后端转发。
// 每个板块右上角: [搜索] [设置→连接资源库]
import 'dart:async'; import 'dart:convert';
import 'dart:math'; import 'dart:io';
import 'dart:ui' show PlatformDispatcher, ImageFilter;
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
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'core/nav_swipe.dart';
import 'core/local_tools.dart';
import 'core/mini_modules.dart';
import 'core/backend_admin_page.dart';
import 'core/recents.dart';
import 'core/read_stats.dart';
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
import 'core/changelog.dart';
import 'core/media_formats.dart';
import 'core/local_import.dart';
import 'core/discover.dart';
import 'core/novel_reader.dart';
import 'core/reader_fonts.dart';
import 'core/i18n.dart';
import 'core/ai.dart';
import 'core/ai_page.dart';
import 'core/ai_agent.dart';
import 'core/agent_dsh_client.dart';
import 'core/peer_hub.dart';
import 'core/peer_page.dart';
import 'core/ai_agent_page.dart';
import 'core/ai_store_prefs.dart';
import 'core/job_center.dart';
import 'core/lab_games.dart';
import 'core/lab_social.dart';
import 'core/home_io.dart';
import 'core/sensor_page.dart';
import 'core/browser_page.dart';
import 'core/notify.dart';
import 'core/engine_direct.dart';
import 'core/engine_direct_page.dart';
import 'core/gallery_page.dart';
import 'core/files_page.dart';
import 'core/feedback_page.dart';
import 'core/app_log.dart';
import 'core/log_page.dart';
import 'core/auto_scan_page.dart';
import 'core/tts_presets.dart';
// ── v4.40.0 一次性补全批次(PLAN-v3 剩余阶段) ──
import 'core/pro_reading.dart';
import 'core/pro_media.dart';
import 'core/pro_browser.dart';
import 'core/pro_gallery.dart';
import 'core/pro_system.dart';
import 'core/pro_ai.dart';
import 'core/pip.dart';
import 'core/chat.dart';
import 'core/app_version.dart';
import 'core/share_card.dart';
import 'core/module_clog_page.dart';


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
  // TH-Agent 的智能体/指令/记忆/钉注统一落盘到 shared_preferences
  installAiStorePrefs();
  await AppSettings.init();
  // 报错中心: 全局捕获 Flutter 框架异常 → 日志中心（release 下灰屏类崩溃也能回看）
  FlutterError.onError = (d) { AppLog.error('Flutter 框架异常', err: d.exception, st: d.stack); FlutterError.presentError(d); };
  PlatformDispatcher.instance.onError = (e, st) { AppLog.error('未捕获异常', err: e, st: st); return true; };
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
  // v4.40.0: 注册进阶功能桥(系统页要动导航/主题/字体; 浏览器译文要交给阅读器)
  registerProBridges();
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
  // ── 自动全屏（D-11）：进入模块后 N 秒没有切换模块操作 → 隐藏底部导航进入全屏 ──
  // autoFsSec: 0=关闭；默认 3 秒（用户拍板值）。范围 2-10s。
  static int get autoFsSec => p.getInt('auto_fs_sec') ?? 3;
  static Future<void> setAutoFsSec(int v) async { await p.setInt('auto_fs_sec', v.clamp(0, 10)); await sync(); }
  // 逐模块开关：默认全开，少数"操作型"模块默认关（我的/设置类页面进全屏没意义）
  static const fsOffByDefault = {'我的'};
  static bool fsEnabledFor(String modKey) =>
      p.getBool('fs_mod_$modKey') ?? !fsOffByDefault.contains(modKey);
  static Future<void> setFsEnabledFor(String modKey, bool v) async {
    await p.setBool('fs_mod_$modKey', v); await sync(); }
  // 左右滑动切换模块（★2026-09-20 默认改回 **开**）。
  // 曾默认关(09-19): 担心"沿途构建中间模块"——那是 animateToPage 跳页的问题(已改 jumpToPage 根治);
  // 物理拖拽一次只能过相邻一页, 相邻页本来就由 PageView 缓存构建, 不存在沿途加载。
  // 模块内横向手势(游戏/歌词翻页等)都在 push 出来的子页或小热区里, 与本层拖拽不冲突。
  // 不想横滑的人仍可在「我的 → 导航」关闭。
  static bool get navSwipe => p.getBool('nav_swipe') ?? true;
  static Future<void> setNavSwipe(bool v) async { await p.setBool('nav_swipe', v); await sync(); }
  static Offset get orbPos {
    final x = p.getDouble('orb_x'), y = p.getDouble('orb_y');
    return (x != null && y != null) ? Offset(x, y) : const Offset(-1, -1);
  }
  static Future<void> setOrbPos(Offset o) async { await p.setDouble('orb_x', o.dx); await p.setDouble('orb_y', o.dy); }
  // ★4.44.0 退出全屏悬浮球的位置：原先是**固定在右上角**（right:8/top:0），
  // 全屏时正好压在手指常滑的区域上、会挡住手势。改成可随意拖动并记住位置。
  // 默认 (-1,-1) = 尚未拖过 → 首次仍落在右上角，与旧行为一致。
  static Offset get fsOrbPos {
    final x = p.getDouble('fs_orb_x'), y = p.getDouble('fs_orb_y');
    return (x != null && y != null) ? Offset(x, y) : const Offset(-1, -1);
  }
  static Future<void> setFsOrbPos(Offset o) async {
    await p.setDouble('fs_orb_x', o.dx); await p.setDouble('fs_orb_y', o.dy); }
  static Future<void> resetFsOrbPos() async {
    await p.remove('fs_orb_x'); await p.remove('fs_orb_y'); }

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
// ★ 与网页端 #boot-splash 同一套视觉：自家商标 + 双向模糊光晕 + 呼吸律动
//   + 品牌名 + 副标题「一个入口 · One Hub」+ 环形加载。
//
//   此前这里的问题（用户报的「开屏图标不是自家商标、加载页没用网页端那一套」）：
//   ① 图标用的是 Material 内置 Icons.hub_outlined —— 系统通用图标，与网页端开屏、
//      桌面快捷方式、安装包图标都不是同一个东西；
//   ② 副标题写成「资源 · 引擎 · 互联」，与网页端的「一个入口 · One Hub」不是一套；
//   ③ 底部版本号写死 'v4.24.0' —— 装了 4.44.0 开屏仍显示旧版本（与旁支
//      「关于页写死 0.4.0」是同一类病：常量会忘记同步，读 kAppVersion 不会）。
class _Sp extends State<SplashPage> with TickerProviderStateMixin {
  // 入场：淡入 + 轻微放大，一次性
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  // 呼吸律动：与网页端 .bs-logo 的 bs-breathe 2.8s 同期，循环往复
  late final AnimationController br = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat(reverse: true);
  @override void dispose() { ac.dispose(); br.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) {
    // 与网页端 #boot-splash 逐项对齐：网页端用 @media (prefers-color-scheme: light)
    // 切明暗，这里用 platformBrightness，语义相同。上一版把浅色配色写死，
    // 深色系统上会亮成一片白 —— 「对齐样式」必须连明暗一起对齐。
    //   dark  : bg #0F1115 / 标题 #EEF0F6 / 副标题 #9AA3B2 / 光晕 rgba(99,102,241,.20)
    //   light : bg #F4F5F9 / 标题 #1C1F2A / 副标题 #5A6072 / 光晕 rgba(99,102,241,.12)
    final bool dark = MediaQuery.platformBrightnessOf(c) == Brightness.dark;
    const accent = Color(0xFF3B5BFD);
    final Color bg = dark ? const Color(0xFF0F1115) : const Color(0xFFF4F5F9);
    final Color titleC = dark ? const Color(0xFFEEF0F6) : const Color(0xFF1C1F2A);
    final Color subC = dark ? const Color(0xFF9AA3B2) : const Color(0xFF5A6072);
    // rgba(255,255,255,.14) / rgba(15,20,30,.14)
    final Color track = dark ? const Color(0x24FFFFFF) : const Color(0x241F141E);
    final Color glow = const Color(0xFF6366F1).withValues(alpha: dark ? 0.20 : 0.12);
    final List<BoxShadow> logoShadow = dark
        ? const [BoxShadow(color: Color(0x6B000000), blurRadius: 44, offset: Offset(0, 18))]
        : const [BoxShadow(color: Color(0x29141A28), blurRadius: 36, offset: Offset(0, 14))];
    return Scaffold(backgroundColor: bg, body: Stack(children: [
      // 网页端 #boot-splash::before / ::after 的两团模糊光晕（左上大、右下略小且更淡）
      Positioned(top: -140, left: -120, child: _Glow(420, color: glow)),
      Positioned(bottom: -130, right: -110, child: _Glow(380, color: glow, opacity: 0.8)),
      SafeArea(child: Column(children: [
        const Spacer(),
        FadeTransition(opacity: CurvedAnimation(parent: ac, curve: Curves.easeOut),
          child: ScaleTransition(scale: Tween<double>(begin: 0.82, end: 1).animate(CurvedAnimation(parent: ac, curve: Curves.easeOutBack)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ScaleTransition(scale: Tween<double>(begin: 1, end: 1.045).animate(CurvedAnimation(parent: br, curve: Curves.easeInOut)),
                child: Container(width: 96, height: 96,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), boxShadow: logoShadow),
                  child: ClipRRect(borderRadius: BorderRadius.circular(22),
                    // 自家商标：assets/branding/logo-96.png 与网页端 icons/launcher-96.png 逐字节同源
                    child: Image.asset('assets/branding/logo-96.png', width: 96, height: 96, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: accent,
                        child: Icon(Icons.hub_outlined, color: Colors.white, size: 46)))))),
              const SizedBox(height: 14),
              Text('第三方聚合站', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: titleC, letterSpacing: 0.5)),
              const SizedBox(height: 14),
              Text('一个入口 · One Hub', style: TextStyle(fontSize: 12, color: subC, letterSpacing: 0.5)),
            ]))),
        const SizedBox(height: 14),
        // 网页端 .bs-spin：26px 环、3px 描边、顶段 #3b5bfd
        SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3, color: accent, backgroundColor: track)),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.lan_outlined, size: 13, color: subC), const SizedBox(width: 4),
          Text('支持 IPv6 网络', style: TextStyle(fontSize: 11, color: subC)),
          const SizedBox(width: 10),
          // 版本号读唯一来源，不再写死
          Text('v$kAppVersion', style: TextStyle(fontSize: 11, color: subC)),
        ]),
        const SizedBox(height: 18),
      ])),
    ]));
  }
}

/// 开屏的模糊光晕。网页端用 `filter: blur(110px)` 把纯色圆晕开；
/// CSS 的 blur(radius) 与 Flutter 的 sigma 约为 2:1，取 sigma 55 还原同一观感。
class _Glow extends StatelessWidget {
  final double size; final Color color; final double opacity;
  const _Glow(this.size, {required this.color, this.opacity = 1});
  @override Widget build(BuildContext c) => IgnorePointer(child: Opacity(opacity: opacity,
    child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
      child: Container(width: size, height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color)))));
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
            boxShadow: const [BoxShadow(color: Color(0x29141A28), blurRadius: 20, offset: Offset(0, 8))]),
            // 与开屏同源：协议门也显示自家商标，不再用 Material 通用图标
            child: ClipRRect(borderRadius: BorderRadius.circular(18),
              child: Image.asset('assets/branding/logo-96.png', width: 64, height: 64, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: accent,
                  child: Icon(Icons.hub_outlined, color: Colors.white, size: 34))))),
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
  /// 记住上一次已探测过的后端地址 —— 只有地址变了才重新探 DSH，避免每帧都发请求
  String _agentBootedBase = '';

  @override void initState() { super.initState();
    AppSettings.onChanged = () { if (mounted) setState(() {}); };
    I18n.instance.addListener(_onLang); }
  void _onLang() { if (mounted) setState(() {}); }
  @override void dispose() { I18n.instance.removeListener(_onLang); super.dispose(); }
  @override Widget build(BuildContext c) { Api.base = widget.base; Api.token = widget.token;
    // 同步给 TTS 后端合成通道（core/tts_presets.dart 为避免循环 import 不直接读 Api）
    TtsBackend.base = Api.base; TtsBackend.token = Api.token;
    // Agent Runtime(DSH) 用的是同一个后端 —— 两处必须同源，否则会出现
    // 「TTS 通了、AI 却说没后端」这种自相矛盾的状态。
    AgentDshClient.base = Api.base; AgentDshClient.token = Api.token;
    // ★4.44.0 端网(PH/1)用的是**同一个后端** —— 同样必须同源，
    //   否则会出现「DSH 通了、端网却说没后端」这种自相矛盾的状态。
    PeerHubClient.base = Api.base; PeerHubClient.token = Api.token;
    if (_agentBootedBase != Api.base) {
      _agentBootedBase = Api.base;
      // build 里不能 await：把探测推到这一帧画完之后，探一次就够。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(AgentRuntime.bootstrap());
      });
    }
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
        TtsBackend.base = Api.base; TtsBackend.token = Api.token;
        AgentDshClient.base = Api.base; AgentDshClient.token = Api.token;
        PeerHubClient.base = Api.base; PeerHubClient.token = Api.token;
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
  @override void initState() { super.initState(); AppSettings.loadFromBackend().then((_) { if (mounted) setState(() {}); });
    // TH-Agent v1: 「AI 智能体与指令」入口要按已配置状态显示, 所以进页面时把配置读回来
    Future.wait([AiAgents.load(), AiInstruct.load(), AiMemory.load()]).then((_) { if (mounted) setState(() {}); }); }


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
      // ★2026-09-19 修「我的」页头像/昵称/身份码整体左贴:
      //   Stack 默认 alignment 是 topStart, 非定位子节点会被摆到左上角;
      //   而 Column 在松约束下宽度只等于"最宽的那个孩子", 于是整块内容左贴而不是居中。
      //   显式给 Stack 加 center + Column 收紧 mainAxisSize 才是真正居中的写法。
      child: Stack(alignment: Alignment.center, children: [
        const Positioned.fill(child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          child: _Particles())),
        Padding(padding: const EdgeInsets.symmetric(vertical: 26),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
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
          // ★未登录给一颗醒目的登录按钮——登录入口不能再藏在三级页面里
          if (!logged) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: scheme.primary),
              icon: const Icon(Icons.login, size: 17),
              label: const Text('登录 / 注册', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              onPressed: () => Navigator.push(context, smoothRoute(const ProfileSubPage())).then((_) { if (mounted) setState(() {}); })),
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
      _section(tr('进阶'), [
        entry(Icons.menu_book_outlined, tr('阅读进阶'), value: tr('换源 · 批注 · 摘抄 · 追更'), page: const ReadingProPage()),
        _sep(),
        entry(Icons.cast_outlined, tr('影音进阶'), value: tr('投屏 DLNA · 下载归一 · 画中画'), page: const MediaProPage()),
        _sep(),
        entry(Icons.photo_library_outlined, tr('相册闭环'), value: tr('备份 · 秒传 · 地图 · 加密柜 · 分享链'), page: const GalleryProPage()),
        _sep(),
        entry(Icons.forum_outlined, tr('聊天'), value: tr('离线优先 · 多设备同步 · AI 摘要'), page: const ChatSessionsPage()),
        _sep(),
        entry(Icons.auto_awesome_outlined, tr('AI 工作台'), value: tr('工具 · 确认队列 · 定时 · 审计'), page: const AiWorkbenchPage()),
        _sep(),
        entry(Icons.hub_outlined, tr('系统与生态'), value: tr('模块 · 多后端 · 迁移 · 授权'), page: const SystemCenterPage()),
      ]),
      _section('数据', [
        entry(Icons.cloud_outlined, tr('云端'), page: const CloudPage()),
        _sep(),
        entry(Icons.dns_outlined, '后端管理', value: Api.base.isEmpty ? '未连接' : '已连接', page: const BackendAdminPage()),
        _sep(),
        entry(Icons.play_circle_outline, '最近播放', page: const RecentPlayPage()),
        _sep(),
        entry(Icons.bar_chart_outlined, '阅读统计', page: const ReadStatsPage()),
        _sep(),
        entry(Icons.delete_outline, '回收站', page: const RecycleBinPage()),
        _sep(),
        entry(Icons.receipt_long_outlined, '日志中心', value: '运行透明 · 含报错中心', page: const LogCenterPage()),
        _sep(),
        entry(Icons.download_outlined, '下载 App', page: const DownloadAppsPage()),
      ]),
      _section('服务', [
        entry(Icons.extension_outlined, '引擎直连', value: EngineDirect.connected ? '已连接' : '', page: const EngineDirectPage()),
        _sep(),
        entry(Icons.smart_toy_outlined, 'AI 智能体与指令',
          value: AiInstruct.active || AiMemory.entries.isNotEmpty ? '已配置' : '',
          page: const AiAgentPage()),
        _sep(),
        entry(Icons.settings_outlined, tr('系统'), page: const SystemPage()),
      ]),
      _section('帮助中心', [
        entry(Icons.help_outline, '帮助中心', page: const HelpPage()),
        _sep(),
        entry(Icons.mail_outline, '反馈中心', value: '文字+截图，直达管理后台', page: const FeedbackPage()),
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
  // 复制到剪贴板(邮箱/身份码这种"只能看不能改"的字段, 点一下就该能拿走)
  Future<void> _copy(String label, String v) async {
    if (v.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: v));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label 已复制')));
  }

  Future<void> _editField(String key, String name, String cur) async {
    final ctrl = TextEditingController(text: cur);
    final v = await showDialog<String>(context: context, builder: (c2) => AlertDialog(title: Text(name),
      content: TextField(controller: ctrl, autofocus: true, decoration: InputDecoration(hintText: name, isDense: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, ctrl.text.trim()), child: const Text('保存'))]));
    ctrl.dispose(); // 不 dispose 会随每次编辑泄漏一个 controller
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
    // ★2026-09-19 修「假交互」: 原来邮箱/身份码挂了空回调却还画 chevron,
    //   用户点了没反应(看着能点)。现在箭头只在真有动作时才出现, 并且点一下即复制。
    Widget row(String name, String val, VoidCallback? onTap) => InkWell(onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), child: Row(children: [
        Text(name, style: const TextStyle(fontSize: 14)),
        const Spacer(),
        Flexible(child: Text(val, style: const TextStyle(fontSize: 13, color: Colors.grey), overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        Icon(onTap == null ? Icons.lock_outline : Icons.chevron_right, size: onTap == null ? 14 : 18,
          color: Colors.grey.withValues(alpha: onTap == null ? 0.5 : 1)),
      ])));
    return Scaffold(appBar: AppBar(title: const Text('个人资料')), body: ListView(padding: const EdgeInsets.all(14), children: [
      // ★未登录时把登录/注册卡片放在最顶上——此前登录入口只有首启引导里那一处,
      //   跳过引导后全 App 找不到登录(用户原话: 前端根本不知道去哪里登录)
      if (!logged) ...[
        Card(margin: EdgeInsets.zero, child: const AccountTile()),
        const SizedBox(height: 12),
      ],
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
        if (logged) ...[ row('邮箱', Cloud.email, () => _copy('邮箱', Cloud.email)), const Divider(height: 1, indent: 16) ],
        row('身份码', logged ? AppSettings.identityCode : '登录后生成',
          logged && AppSettings.identityCode.isNotEmpty ? () => _copy('身份码', AppSettings.identityCode) : null),
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

// ═══ 统一最近播放(规划 M-4): 音乐/视频/有声书/广播 一处回看 ═══
class RecentPlayPage extends StatefulWidget { const RecentPlayPage({super.key}); @override State<RecentPlayPage> createState() => _Rp(); }
class _Rp extends State<RecentPlayPage> {
  List<Map<String, String>> items = [];
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await Recents.list(); if (mounted) setState(() {}); }
  static const _icons = {'music': Icons.music_note, 'video': Icons.play_circle_outline, 'audiobook': Icons.headphones, 'radio': Icons.radio};
  static const _kinds = {'music': '音乐', 'video': '视频', 'audiobook': '有声书', 'radio': '广播'};
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('最近播放')),
    body: items.isEmpty
      ? const Center(child: Text('还没有播放记录\n去音乐/视频/有声书/广播里播点什么', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView(children: [
          for (final e in items)
            ListTile(dense: true,
              leading: Icon(_icons[e['kind']] ?? Icons.play_arrow, size: 20),
              title: Text(e['title'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: Text('${_kinds[e['kind']] ?? e['kind']}${(e['sub'] ?? '').isNotEmpty ? ' · ${e['sub']}' : ''} · ${e['at'] ?? ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              trailing: IconButton(icon: const Icon(Icons.close, size: 16),
                onPressed: () async { await Recents.remove(e['kind'] ?? '', e['target'] ?? ''); _load(); })),
        ]));
}

// ═══ 阅读统计(规划 R-1): 时长 + 字数, 今日/本周 ═══
class ReadStatsPage extends StatefulWidget { const ReadStatsPage({super.key}); @override State<ReadStatsPage> createState() => _Rs(); }
class _Rs extends State<ReadStatsPage> {
  (int, int, int, int) s = (0, 0, 0, 0); Map<String, Map<String, int>> days = {};
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { s = await ReadStats.summary(); days = await ReadStats.load(); if (mounted) setState(() {}); }
  String _fmtSec(int sec) { if (sec >= 3600) return '${(sec / 3600).toStringAsFixed(1)} 小时'; if (sec >= 60) return '${(sec / 60).round()} 分钟'; return '$sec 秒'; }
  String _fmtChars(int n) => n >= 10000 ? '${(n / 10000).toStringAsFixed(1)} 万字' : '$n 字';
  @override Widget build(BuildContext c) {
    final sorted = days.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    return Scaffold(appBar: AppBar(title: const Text('阅读统计')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Row(children: [
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            const Text('今日时长', style: TextStyle(fontSize: 11, color: Colors.grey)),
            Text(_fmtSec(s.$1), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ])))),
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            const Text('今日字数', style: TextStyle(fontSize: 11, color: Colors.grey)),
            Text(_fmtChars(s.$2), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ])))),
        ]),
        Row(children: [
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            const Text('本周时长', style: TextStyle(fontSize: 11, color: Colors.grey)),
            Text(_fmtSec(s.$3), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ])))),
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            const Text('本周字数', style: TextStyle(fontSize: 11, color: Colors.grey)),
            Text(_fmtChars(s.$4), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ])))),
        ]),
        if (sorted.isEmpty) const Padding(padding: EdgeInsets.all(32),
          child: Center(child: Text('还没有阅读记录\n打开任意一本小说开始计时', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))),
        if (sorted.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 6), child: Text('按天明细', style: TextStyle(fontSize: 12, color: Colors.grey))),
          Card(child: Column(children: [
            for (final e in sorted.take(30))
              ListTile(dense: true, leading: const Icon(Icons.calendar_today_outlined, size: 16),
                title: Text(e.key, style: const TextStyle(fontSize: 13)),
                trailing: Text('${_fmtSec(e.value['sec'] ?? 0)} · ${_fmtChars(e.value['chars'] ?? 0)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey))),
          ])),
        ],
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
  // 图标键 → 矢量图标（总纲: UI 一律矢量图标, 不用 emoji）
  static IconData _engineIcon(String k) => switch (k) {
    'book' => Icons.menu_book, 'movie' => Icons.movie_outlined, 'palette' => Icons.palette_outlined,
    'music' => Icons.music_note, 'cloud' => Icons.cloud_outlined, 'plug' => Icons.power,
    _ => Icons.memory };
  Widget engineCard(Map e) => Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: Padding(
    padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      // 引擎图标: 后端发的是图标键(book/movie/palette/music/cloud/plug), 本地映射成矢量图标
      Icon(_engineIcon('${e['icon'] ?? ''}'), size: 22, color: Colors.blueAccent),
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
        statusRow('网盘 Cloudreve', st!['cloudreve'] ?? '?', 5212, () => Navigator.push(c, MaterialPageRoute(builder: (_) => NetDiskPage(baseUrl: Api.base)))),
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
  // ★2026-09-19 逐类上屏 + 客户端分页（引擎一次已返回全部结果，首屏不必一次画上千条）
  static const _pageSize = 40;
  /// 首屏扫描预算(秒)：小值让结果尽快出现（这是"瀑布流"的起点）
  static const _firstBudget = 8;
  /// 「加载更多」时的扫描预算(秒)：更大 → 引擎扫得更深、返回更多
  static const _moreBudget = 25;
  int _shown = _pageSize;
  int _seq = 0;                            // 搜索代次：旧请求回来直接丢弃
  final Set<String> _done = {};            // 已返回的类型（老引擎逐类模式用）
  final Map<String, String> _failed = {};  // 类型 → 失败原因
  final Set<String> _ids = {};             // 已收条目 id：翻页会与首批重叠，靠它去重
  // ── 引擎分页状态（引擎 1.5.5+）──
  int _engPage = 0;                        // 已取到第几页
  int _engTotal = 0;                       // 引擎这轮扫描的总条数（网络侧，不是已加载的）
  bool _engHasMore = false;
  bool _engTruncated = false;
  bool _more = false;                      // 正在取下一页
  String _engType = 'all';                 // 当前搜索的引擎类型（all / novel / …）
  String _engQuery = '';
  // ── ★本轮新增：自动续拉 + 可中断（用户反馈「引擎几千本，前端只收到二十几本」）──
  //
  // 旧行为有两处叠加，导致引擎明明扫到几千条、前端只显示几十条：
  //   ① 首屏只取 page=1（`_pageSize`=40 条），**不会自己继续** —— 必须用户滑到底、
  //      再点一次「向引擎加载更多」，取一页停一次；
  //   ② 渲染窗口 `_shown` 初始 40，`_engGroup` 里 `all.take(_shown)` →
  //      就算拉回来 3000 条，也只画 40 条，看起来还是「只有二十几本」。
  // 现在改成：首屏回来就**自动连续翻页**直到 `_engHasMore` 为假或用户停止，
  // 并把结果**逐帧铺开**（每次 +_pumpStep 条）——既是用户要的「一条一条蹦出来」，
  // 又不会一次性构建上千个 ListTile 把首帧卡死。
  bool _autoPull = false;                  // 正在自动续拉
  /// 逐帧铺开的步长（条/帧）。40 条/帧 ≈ 60fps 下每 0.1s 冒一批，观感是「持续在出」。
  static const _pumpStep = 40;
  /// 自动续拉的页间最小间隔（毫秒）：别把引擎打得太狠，也让结果"一点点来"。
  static const _autoPullGap = 200;
  final ScrollController _scroll = ScrollController();
  @override void initState() {
    super.initState();
    _loadHistory();
    // ★订阅连接状态：旧版只在 build 时读一次静态字段 →「连上了还显示未连接 / 变化特别慢」
    EngineDirect.state.addListener(_onConn);
    _scroll.addListener(_maybeMore);
  }
  @override void dispose() {
    EngineDirect.state.removeListener(_onConn);
    _scroll.dispose();
    ctrl.dispose();
    super.dispose();
  }
  void _onConn() { if (mounted) setState(() {}); }
  /// 触底：先把**已经拿到本地**的条目多画一屏（零网络、零风险），
  /// 画完了才向引擎要下一页 —— 这样"瀑布流"既有即时感，又不会一次渲染上千个 ListTile。
  void _maybeMore() {
    if (!_scroll.hasClients || engItems == null) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 400) return;
    if (_shown < engItems!.length) {
      setState(() => _shown += _pageSize);
    } else if (_engHasMore && !_more && !loading) {
      _loadMore();
    }
  }
  /// 向引擎取下一页（引擎侧翻页不重扫，秒回）
  Future<void> _loadMore() async {
    if (_more || !EngineDirect.connected) return;
    final mySeq = _seq;
    setState(() => _more = true);
    try {
      final p = await EngineDirect.searchPage(_engType, _engQuery,
        page: _engPage + 1, limit: _pageSize,
        budgetSec: _engTruncated ? _moreBudget : _firstBudget);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _appendEng(p.items);
        _engPage = p.page;
        _engHasMore = p.hasMore;
        _engTotal = p.total;
        _engTruncated = p.truncated;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _engHasMore = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载更多失败：${EngineDirect.lastError.isNotEmpty ? EngineDirect.lastError : e}')));
      }
    } finally { if (mounted) setState(() => _more = false); }
  }
  /// 追加并把每类标上 _type（type=all 的响应里带 type 字段；没有则归到当前类型）
  void _appendEng(List<Map<String, dynamic>> items) {
    for (final it in items) {
      final id = '${it['id'] ?? it['bookUrl'] ?? it['name']}';
      if (!_ids.add(id)) continue;   // 深度重扫后翻页会与首批重叠 → 必须去重
      // 引擎给的是数字 type(0小说/1听书/2漫画/4视频)；按它映射成模块键，
      // 不能直接用引擎的 typeName（那是 text/audio/image/video，与模块名不同）
      var t = _typeKeyFromInt(it['type']);
      if (t.isEmpty) t = _engType == 'all' ? 'novel' : _engType;
      engItems = [...?engItems, {...it, '_type': t}];
    }
  }
  /// 把渲染窗口 `_shown` 逐帧撑到「已加载条数」—— 这就是用户要的「一条一条蹦出来」。
  ///
  /// 为什么不在 `_appendEng` 里直接把 `_shown` 设成 total：
  /// 列表用的是 `ListView(children: [...])`（**非懒加载**），一次铺 3000 个 ListTile
  /// 会把首帧卡死。分帧铺开既保住了观感，也保住了流畅度。
  bool _pumping = false;
  Future<void> _pumpShown() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (mounted) {
        final total = engItems?.length ?? 0;
        if (_shown >= total) break;
        _shown = (_shown + _pumpStep).clamp(0, total);
        setState(() {});
        await Future.delayed(const Duration(milliseconds: 16)); // 一帧
      }
    } finally { _pumping = false; }
  }
  /// 自动续拉：首屏拿到后不等用户操作，自己把 `_engHasMore` 翻到没有为止。
  ///
  /// 退出条件有四个，缺一不可 —— 否则用户点了停止还会继续往上灌：
  ///   ① 用户停止（`_autoPull` 被置假）；② 代次变了（`_seq` 不等 = 又发起了新搜索）；
  ///   ③ 引擎说没有更多了；④ 组件已卸载。
  Future<void> _autoPullLoop(int mySeq) async {
    while (mounted && _autoPull && mySeq == _seq) {
      if (!_engHasMore || !EngineDirect.connected) break;
      if (_more) { await Future.delayed(const Duration(milliseconds: 80)); continue; }
      await Future.delayed(const Duration(milliseconds: _autoPullGap));
      if (!mounted || !_autoPull || mySeq != _seq) break;
      final before = engItems?.length ?? 0;
      await _loadMore();
      if (!mounted || !_autoPull || mySeq != _seq) break;
      // `_loadMore` 失败会把 `_engHasMore` 置假 → 下一轮 while 自然退出；
      // 但引擎返回空页也会让 hasMore 变假，这里再兜一层「一条都没新增」就收工。
      if ((engItems?.length ?? 0) == before) break;
      unawaited(_pumpShown());
    }
    if (mounted && mySeq == _seq) setState(() => _autoPull = false);
  }
  /// 用户按「停止」：先确认再停（误触一次就不用重搜一整轮）。
  ///
  /// 停止 = `_seq++`（让所有在途请求回来时对不上代次、直接丢弃）+ `_autoPull=false`。
  /// **已收到的结果全部保留** —— 停止是「不要再拉了」，不是「清空」。
  Future<void> _askStop() async {
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('停止搜索？'),
      content: Text('已收到 ${engItems?.length ?? 0} 条'
          '${_engTotal > 0 ? '（引擎共 $_engTotal 条）' : ''}。\n'
          '停止后已收到的不受影响，可以随时再点搜索继续。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('继续搜索')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('确认停止')),
      ]));
    if (ok != true || !mounted) return;
    _seq++; // 在途请求全部作废
    setState(() { _autoPull = false; _more = false; loading = false; _engHasMore = false; });
    unawaited(_pumpShown()); // 把已经拿到的条目铺完（否则会停在半截）
  }
  static String _typeKeyFromInt(Object? v) {
    final n = v is int ? v : int.tryParse('${v ?? ''}');
    return const {0: 'novel', 1: 'music', 2: 'comic', 4: 'video'}[n] ?? '';
  }
  Future<void> _loadHistory() async { final p = await SharedPreferences.getInstance();
    history = p.getStringList('search_history') ?? []; if (mounted) setState(() {}); }
  Future<void> _record(String q) async { final p = await SharedPreferences.getInstance();
    history.remove(q); history.insert(0, q); history = history.take(15).toList();
    await p.setStringList('search_history', history); }
  static final typeNames = [tr('全部'), tr('小说'), tr('漫画'), tr('视频'), tr('音乐')];
  static const typeKeys = ['', 'novel', 'comic', 'video', 'music'];
  Future<void> go() async { final q = ctrl.text.trim(); if (q.isEmpty) return;
    _record(q);
    final mySeq = ++_seq;
    setState(() { loading = true; agg = null; engItems = []; _shown = _pageSize;
      _done.clear(); _failed.clear(); _ids.clear();
      _engPage = 0; _engTotal = 0; _engHasMore = false; _engTruncated = false;
      _autoPull = false;   // 新一轮先停掉上一轮的续拉
      _engQuery = q; _engType = typeFilter == 0 ? 'all' : typeKeys[typeFilter]; });
    try {
      if (EngineDirect.connected) {
        // ★2026-09-19 引擎直连搜索
        // 引擎 1.5.5+：一次请求(type=all)拿全部类型 + 8s 预算快速出首屏，
        //   之后「加载更多」按 page 翻页（引擎侧有结果缓存，翻页不重扫，秒回）。
        // 老引擎(<=1.5.4)：不认 page/budget/type=all → 退回"逐类并发、谁先回来谁先上屏"，
        //   否则 type=all 在老引擎上会被当成 novel，漫画/视频/音乐全丢。
        if (EngineDirect.supportsPaging) {
          final p = await EngineDirect.searchPage(_engType, q,
            page: 1, limit: _pageSize, budgetSec: _firstBudget);
          if (!mounted || mySeq != _seq) return;
          setState(() {
            _ids.clear();
            _appendEng(p.items);
            _engPage = p.page; _engTotal = p.total;
            _engHasMore = p.hasMore; _engTruncated = p.truncated;
            if (p.hasMore) _autoPull = true;   // ← 首屏之后自己接着拉，不等用户滑到底
          });
          unawaited(_pumpShown());              // 首屏逐帧铺开
          if (p.hasMore) unawaited(_autoPullLoop(mySeq));
        } else {
          final types = typeFilter == 0
              ? const ['novel', 'comic', 'video', 'music']
              : [typeKeys[typeFilter]];
          await Future.wait(types.map((t) async {
            try {
              final rs = await EngineDirect.search(t, q);
              if (!mounted || mySeq != _seq) return;
              setState(() {
                _done.add(t);
                engItems = [...?engItems, ...rs.map((it) => {...it, '_type': t})];
              });
            } catch (e) {
              if (!mounted || mySeq != _seq) return;
              setState(() {
                _done.add(t);
                _failed[t] = EngineDirect.lastError.isNotEmpty ? EngineDirect.lastError : '$e';
              });
            }
          }));
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
        throw Exception('未连接引擎或资源库\n引擎启动后会自动发现；'
          '若长时间未发现，请到「我的 → 引擎直连」查看具体原因');
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    if (mounted) { setState(() => loading = false); unawaited(_pumpShown()); } }
  /// 是否「正在搜索」——含首屏请求中与自动续拉中两段。
  /// 搜索键的形态由它决定：搜索中转圈 → 变方块停止键（用户点名要的交互）。
  bool get _searching => loading || _autoPull;
  Widget group(String title, List items, Widget Function(Map) tile, [IconData? ic]) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (items.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(children: [
        if (ic != null) ...[ Icon(ic, size: 16, color: Colors.blueAccent), const SizedBox(width: 6) ],
        Text('$title (${items.length})', style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold))])),
    for (final it in items) tile(it),
  ]);
  String _typeLabel(String t) =>
    const {'novel': '小说', 'comic': '漫画', 'video': '视频', 'music': '音乐'}[t] ?? t;
  int get _typeTotal => typeFilter == 0 ? 4 : 1;
  // 顶部汇总: 逐类上屏过程中也能看出「已回几类 / 还在搜 / 引擎一共多少条」
  String _engSummary() {
    final loaded = engItems?.length ?? 0;
    final sb = StringBuffer('来自引擎「${EngineDirect.name}」');
    if (EngineDirect.version.isNotEmpty) sb.write(' v${EngineDirect.version}');
    sb.write(' · THP 直连 · 已返回 $loaded 条');
    if (EngineDirect.supportsPaging && _engTotal > loaded) {
      sb.write(' / 引擎共 $_engTotal 条${_autoPull ? '，继续拉取中…' : '（已停，可继续）'}');
    }
    if (!EngineDirect.supportsPaging) {
      final done = _done.length;
      if (done < _typeTotal && loading) sb.write('（$done/$_typeTotal 类已回，其余搜索中…）');
    } else if (_engTruncated) {
      sb.write('（引擎扫描被时间预算截断，加载更多可扫得更深）');
    }
    return sb.toString();
  }
  // THP 引擎结果分组渲染: 点条目 → 引擎直连详情页(目录→内容全程走引擎)
  List<Widget> _engGroup(BuildContext c, String t) {
    const labels = {'novel': '小说', 'comic': '漫画', 'video': '视频', 'music': '音乐'};
    const labelIcons = {'novel': Icons.menu_book, 'comic': Icons.palette_outlined, 'video': Icons.movie_outlined, 'music': Icons.music_note};
    final all = engItems!.where((e) => e['_type'] == t).toList();
    if (all.isEmpty) return const [];
    // ★客户端分页: 首屏每类最多画 _shown 条, 触底/点按钮再追加
    final its = all.take(_shown).toList();
    return [
      Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [ Icon(labelIcons[t] ?? Icons.menu_book, size: 16, color: Colors.blueAccent), const SizedBox(width: 6),
          Text('${labels[t]} (${its.length})', style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)) ])),
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
      // ★搜索中 → 变成「停止」方块键（用户给的参照：像 AI 对话框那样，转圈变方块，
      //   点一下先弹确认再停）。不按停止就一直把引擎拉到的东西往前端灌。
      if (_searching)
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: _askStop,
          icon: const Icon(Icons.stop_rounded, size: 18),
          label: const Text('停止'))
      else
        FilledButton(onPressed: go, child: Text(tr('搜索')))])),
    Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 4), child: Align(alignment: Alignment.centerLeft,
      child: Wrap(spacing: 6, children: [
        for (var i = 0; i < typeNames.length; i++) ChoiceChip(
          label: Text(typeNames[i], style: const TextStyle(fontSize: 12)), selected: typeFilter == i,
          onSelected: (_) { setState(() => typeFilter = i); if (ctrl.text.trim().isNotEmpty) go(); }),
      ]))),
    // 数据来源状态行: 引擎直连(绿) / 连接中(橙) / 资源库(灰) / 不可达(红)
    // ★已订阅 EngineDirect.state（见 initState），连接成功会立刻变绿，不再"变化特别慢"
    Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 2), child: Align(alignment: Alignment.centerLeft,
      child: Builder(builder: (ctx) {
        final st = EngineDirect.state.value;
        final (String txt, Color col) = switch (st.status) {
          EngineStatus.connected => ('THP 引擎直连: ${st.name}', Colors.green),
          EngineStatus.connecting => ('正在连接引擎…', Colors.orangeAccent),
          EngineStatus.failed => (Api.base.isNotEmpty
              ? '资源库模式 · 引擎离线' : '引擎不可达 — 点此查看原因/重试', Colors.redAccent),
          EngineStatus.idle => (Api.base.isNotEmpty
              ? '资源库模式' : '未连接引擎 — 点此连接', Colors.redAccent),
        };
        return GestureDetector(
          onTap: st.connected ? null : () => Navigator.push(ctx,
            MaterialPageRoute(builder: (_) => const EngineDirectPage())),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.circle, size: 8, color: col), const SizedBox(width: 5),
            Text(txt, style: TextStyle(fontSize: 10, color: col)) ]));
      }))),
    if (_searching) const LinearProgressIndicator(),
    Expanded(child: ListView(controller: _scroll, children: [
      if (engItems != null) ...[
        Padding(padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
          child: Text(_engSummary(), style: const TextStyle(fontSize: 11, color: Colors.grey))),
        if (_failed.isNotEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Text(
              [for (final e in _failed.entries) '${_typeLabel(e.key)}：${e.value}'].join('\n'),
              style: const TextStyle(fontSize: 10, color: Colors.redAccent, height: 1.5))),
        if (engItems!.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32),
          child: Center(child: Text('没有找到相关内容', style: TextStyle(color: Colors.grey)))),
        for (final t in const ['novel', 'comic', 'video', 'music']) ..._engGroup(c, t),
        // 加载更多: 先画本地已拿到的(零网络)，本地画完了才向引擎翻页(引擎侧有缓存，秒回)
        if (engItems!.length > _shown)
          Padding(padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(child: TextButton(
              onPressed: () => setState(() => _shown += _pageSize),
              child: Text('显示更多（已显示 $_shown / 已加载 ${engItems!.length} 条）',
                style: const TextStyle(fontSize: 12))))),
        if (_engHasMore && engItems!.length <= _shown)
          Padding(padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(child: _autoPull
              // 自动续拉中：显示进度 + 就地给一个停止出口（不必回顶栏找）
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text('正在继续拉取${_engTotal > 0 ? '（${engItems!.length}/$_engTotal 条）' : ''}…',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)) ]),
                  TextButton(onPressed: _askStop,
                    child: const Text('停止', style: TextStyle(fontSize: 12))),
                ])
              : _more
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(
                    onPressed: () { setState(() => _autoPull = true); unawaited(_autoPullLoop(_seq)); },
                    child: Text('向引擎加载更多${_engTotal > 0 ? '（已 ${engItems!.length}/$_engTotal 条）' : ''}',
                      style: const TextStyle(fontSize: 12))))),
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
          group('小说', (g['books'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(Map<String, dynamic>.from(b))))))),
        for (final g in (agg!['comics'] as List? ?? []))
          group('漫画', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['title'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ComicDetailPage(sourceId: g['sourceId'] ?? '', comicId: b['id'] ?? '', title: b['title'] ?? ''))))),
        for (final g in (agg!['videos'] as List? ?? []))
          group('视频', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['name'] ?? ''), subtitle: Text(b['type'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VideoDetailPage(sourceId: g['sourceId'] ?? '', vodId: b['id'] ?? '', title: b['name'] ?? ''))))),
        for (final g in (agg!['musics'] as List? ?? []))
          group('音乐', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
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

// 模块菜单入口: 底栏已取消 ⋯, 改放各模块页分段按钮行右侧(需要菜单的模块才有)
Widget modMenuBtn(BuildContext c) => IconButton(icon: const Icon(Icons.more_vert, size: 20), tooltip: '模块菜单',
  visualDensity: VisualDensity.compact,
  onPressed: () { HapticFeedback.selectionClick(); c.findAncestorStateOfType<_RootNavState>()?.openModuleMenu(); });

// ═══ 板块一: 小说阅读器(功能完整) ═══
class NovelSection extends StatefulWidget { const NovelSection({super.key}); @override State<NovelSection> createState() => _Nv(); }
class _Nv extends State<NovelSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    Row(children: [ const SizedBox(width: 40), Expanded(child: Center(child: SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('书架'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)))), SizedBox(width: 40, child: modMenuBtn(c)) ]),
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

/// 搜索结果空态 —— 一个函数覆盖四个内容模块（小说 / 漫画 / 视频 / 音乐）。
///
/// ★为什么必须重做这段：引擎路径**即使 0 条命中也会塞一个空 group 进 `groups`**，
///   于是旧判定 `if (groups.isEmpty && !loading)` 恒为假 → 空态永不显示 →
///   用户看到的是一个只剩搜索框的白页。而「引擎没连上」与「连上了但一条没有」
///   在白页上完全无法区分 → 「引擎连着、源是空的」被读成「应用坏了」。
///   这里把三种情形分开讲清，并给「未连接」一条可点的出路（直达引擎直连页）。
Widget searchEmptyState({
  required bool loading,
  required String query,
  required bool searched,
  required bool needConn,
  required List<Map> groups,
  required List<String> listKeys,
  required String kind,
  VoidCallback? onFix,
}) {
  if (loading) return const SizedBox.shrink();
  final hasAny =
      groups.any((g) => listKeys.any((k) => (g[k] as List?)?.isNotEmpty == true));
  if (hasAny) return const SizedBox.shrink();
  if (!searched) {
    if (query.isEmpty) return _searchEmptyBox(Icons.search, '输入关键词搜索$kind', '');
    return const SizedBox.shrink();
  }
  if (needConn) {
    return _searchEmptyBox(Icons.link_off, '还没连上内容来源',
        '「$kind」的内容由引擎 App 或家庭后端提供，两者任连其一即可开始搜索。',
        onFix: onFix);
  }
  return _searchEmptyBox(Icons.search_off, '没有找到相关$kind',
      '已经连上来源，但这一条确实没有命中。常见原因是引擎里还没有导入可用的源，换一个关键词也可以再试试。');
}

Widget _searchEmptyBox(IconData icon, String title, String sub,
        {VoidCallback? onFix, String fixLabel = '去连接引擎'}) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(28, 44, 28, 28),
      child: Column(children: [
        Icon(icon, size: 40, color: Colors.grey),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontSize: 14)),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(sub,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.6)),
        ],
        if (onFix != null) ...[
          const SizedBox(height: 14),
          FilledButton.tonal(onPressed: onFix, child: Text(fixLabel)),
        ],
      ]),
    );

class NovelSearchResults extends StatefulWidget { final String query; const NovelSearchResults({super.key, required this.query}); @override State<NovelSearchResults> createState() => _NSR(); }
class _NSR extends State<NovelSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; int _seq = 0; List<String> history = [];
  // 本次搜索是否被「未连接引擎与资源库」拦下 —— 决定空态是"没结果"还是"没连上"。
  bool needConn = false;
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    final p = await SharedPreferences.getInstance();
    history.remove(q); history.insert(0, q); history = history.take(10).toList();
    await p.setStringList('sh_novel', history);
    setState(() { loading = true; groups = []; needConn = false; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('novel', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'books': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        if (mounted) setState(() => needConn = true);
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
      ], searchEmptyState(
        loading: loading, query: widget.query, searched: lastQ.isNotEmpty,
        needConn: needConn, groups: groups, listKeys: const ['books'], kind: '书籍',
        onFix: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const EngineDirectPage()))),
    ])), ]); }

class ShelfPage extends StatefulWidget { final String kind; final Widget Function(Book) builder; const ShelfPage({super.key, required this.kind, required this.builder}); @override State<ShelfPage> createState() => _Sh(); }
class _Sh extends State<ShelfPage> { List<Book> items = []; List<Map<String, dynamic>> local = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    items = await Book.shelf(widget.kind);
    // 本地导入的书直接进书架(点按即读, 不经过后端/引擎)
    if (widget.kind == 'novel') {
      try { local = await LocalLib.list('novel'); } catch (_) {}
      // 清掉文件已不存在的条目
      final alive = <Map<String, dynamic>>[];
      for (final b in local) { if (await File('${b['path']}').exists()) alive.add(b); }
      local = alive;
    }
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
    : (items.isEmpty && local.isEmpty) ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.auto_stories_outlined, size: 56, color: Colors.grey.withValues(alpha: 0.5)),
      const SizedBox(height: 10),
      const Text('书架为空', style: TextStyle(color: Colors.grey, fontSize: 14)),
      const SizedBox(height: 4),
      Text(widget.kind == 'novel' ? '搜索后进入详情页点书签加入, 或从模块菜单导入本地小说' : '搜索后进入详情页, 点书签图标加入', style: const TextStyle(color: Colors.grey, fontSize: 11)),
    ]))
    : GridView.builder(padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.52, mainAxisSpacing: 12, crossAxisSpacing: 12),
        itemCount: local.length + items.length, itemBuilder: (_, i) {
        // 前段: 本地导入的书(仅小说模块)
        if (i < local.length) {
          final lb = local[i];
          final prog = AppSettings.p.getInt('progress_local_${lb['path']}') ?? -1;
          return GestureDetector(
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => LocalNovelReader(book: lb))).then((_) => load()),
            onLongPress: () async {
              final del = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(
                title: const Text('删除本地书'), content: Text('《${lb['name']}》\n将同时删除本地文件'),
                actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('删除'))]));
              if (del == true) { await LocalLib.remove('novel', '${lb['path']}'); load(); }
            },
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.14), blurRadius: 8, offset: const Offset(0, 3))]),
                child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Stack(fit: StackFit.expand, children: [
                  _coverFallback(Book('${lb['name'] ?? ''}', '', '', '', '', '')),
                  Positioned(left: 0, right: 0, bottom: 0, child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54])),
                    child: Text(prog >= 0 ? '第${prog + 1}章 · 本地' : '本地导入', style: const TextStyle(fontSize: 9, color: Colors.white)))),
                ])))),
              const SizedBox(height: 4),
              Text('${lb['name'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.2)),
              Text(prog >= 0 ? '读到第${prog + 1}章' : '${lb['format'] ?? 'txt'} · 本地',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ]));
        }
        final b = items[i - local.length];
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
  // ★此前目录加载失败被 `catch (e) {}` 静默吞掉：页面显示「0 章」+ 一片空白，
  //   用户无法区分「加载失败」与「这本书真的没有章节」。漫画详情页与视频详情页
  //   都正确地把错误落到 err 并展示，唯独小说目录页没有 —— 这里补齐。
  String? err;
  @override void initState() { super.initState(); Book.recordHistory(widget.book, 'novel'); load(); }
  Future<void> load() async { err = null; try {
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
      } } catch (e) { err = '$e'; }
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
    body: loading ? const Center(child: CircularProgressIndicator())
      : (err != null && chapters.isEmpty)
        ? Center(child: SingleChildScrollView(child: _searchEmptyBox(Icons.error_outline,
            '目录加载失败', err!, fixLabel: '重试',
            onFix: () { setState(() { loading = true; err = null; }); load(); })))
        : Column(children: [
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
    Row(children: [ const SizedBox(width: 40), Expanded(child: Center(child: SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('书架'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)))), SizedBox(width: 40, child: modMenuBtn(c)) ]),
    Expanded(child: [ShelfPage(kind: 'comic', builder: (b) => _detailOf(b, 'comic',
        () => ComicDetailPage(sourceId: b.sourceId, comicId: b.bookUrl, title: b.name))),
      HistoryPage(kind: 'comic', builder: (b) => _detailOf(b, 'comic',
        () => ComicDetailPage(sourceId: b.sourceId, comicId: b.bookUrl, title: b.name))),
      EngineDiscoverView(type: 'comic', onOpen: (it) => Navigator.push(c, MaterialPageRoute(builder: (_) => EngineItemPage(type: 'comic', item: it)))),
      const ModuleSearchTab(tab: 2)][sub]),
  ]); }

class ComicSearchResults extends StatefulWidget { final String query; const ComicSearchResults({super.key, required this.query}); @override State<ComicSearchResults> createState() => _CSR(); }
class _CSR extends State<ComicSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; int _seq = 0;
  bool needConn = false; // 本次是否被「未连接引擎与资源库」拦下（空态要用）
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    setState(() { loading = true; groups = []; needConn = false; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('comic', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'items': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/comic/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        if (mounted) setState(() => needConn = true);
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
      searchEmptyState(
        loading: loading, query: widget.query, searched: lastQ.isNotEmpty,
        needConn: needConn, groups: groups, listKeys: const ['items'], kind: '漫画',
        onFix: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const EngineDirectPage()))),
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
    Row(children: [ const SizedBox(width: 40), Expanded(child: Center(child: SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('歌单'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)))), SizedBox(width: 40, child: modMenuBtn(c)) ]),
    Expanded(child: [const _MusicPlaylist(),
      HistoryPage(kind: 'music', builder: (b) => _detailOf(b, 'music',
        () => MusicPlayPage(item: {'name': b.name, 'url': b.bookUrl, 'artist': b.author, 'coverUrl': b.coverUrl}, sourceId: b.sourceId))),
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
  bool needConn = false; // 本次是否被「未连接引擎与资源库」拦下（空态要用）
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    setState(() { loading = true; groups = []; needConn = false; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('music', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'items': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/music/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        if (mounted) setState(() => needConn = true);
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
      searchEmptyState(
        loading: loading, query: widget.query, searched: lastQ.isNotEmpty,
        needConn: needConn, groups: groups, listKeys: const ['items'], kind: '音乐',
        onFix: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const EngineDirectPage()))),
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
      Recents.add('music', '${cur['name'] ?? ''}', sub: '${cur['artist'] ?? ''}', target: playUrl);
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
    Row(children: [ const SizedBox(width: 40), Expanded(child: Center(child: SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('片库'))), ButtonSegment(value: 1, label: Text(tr('历史'))), ButtonSegment(value: 2, label: Text(tr('发现'))), ButtonSegment(value: 3, label: Text(tr('搜索')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)))), SizedBox(width: 40, child: modMenuBtn(c)) ]),
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
  bool searched = false;  // 是否已经搜过一轮（决定空态说"请搜索"还是"没找到"）
  bool needConn = false;  // 本次是否因为没连引擎/后端而空
  // ★此前这里**只走家庭后端**，没有引擎分支：没配后端时点搜索必然抛异常，
  //   只弹一句「错误: …」然后列表永远空白，用户无从知道"这个模块需要后端"。
  //   录像/直播频道在引擎的 video 类源里同样有，所以与视频模块共用一条取数路径。
  Future<void> go([String? preset]) async { final q = preset ?? ctrl.text.trim(); if (q.isEmpty) return;
    setState(() { loading = true; channels = []; needConn = false; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('video', q);
        for (final it in items) channels.add({...Map<String, dynamic>.from(it), 'engine': true});
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/video/search?q=${Uri.encodeComponent(q)}');
        for (final g in (r['data'] as List? ?? [])) {
          if (g['ok'] == true) for (final it in (g['items'] as List? ?? [])) channels.add({...Map<String, dynamic>.from(it), 'sourceId': g['sourceId']});
        }
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { await go(q); return; }
        needConn = true;
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    if (mounted) setState(() { loading = false; searched = true; }); }
  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '搜频道(如:央视/卫视/电影)', border: OutlineInputBorder(), isDense: true), onSubmitted: (_) => go())),
      IconButton(icon: const Icon(Icons.search), onPressed: () => go())])),
    Wrap(spacing: 8, children: [ for (final h in ['央视', '卫视', '电影', '动漫'])
      ActionChip(label: Text(h, style: const TextStyle(fontSize: 12)), onPressed: () { ctrl.text = h; go(h); }) ]),
    if (loading) const LinearProgressIndicator(),
    Expanded(child: channels.isEmpty
      ? Center(child: SingleChildScrollView(child: searched
          ? _searchEmptyBox(needConn ? Icons.link_off : Icons.search_off,
              needConn ? '还没连上内容来源' : '没有找到相关频道',
              '直播频道由引擎 App 或家庭后端提供，两者任连其一即可；\n也可以在「我的 → 引擎直连」里查看当前连接状态。',
              onFix: needConn ? () => Navigator.push(c, MaterialPageRoute(builder: (_) => const EngineDirectPage())) : null)
          : _searchEmptyBox(Icons.live_tv, '搜索频道名', '也可以点上方热词快速试一个。')))
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.75),
        itemCount: channels.length, itemBuilder: (_, i) {
          final ch = channels[i];
          return GestureDetector(onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ch['engine'] == true
              ? EngineItemPage(type: 'video', item: Map<String, dynamic>.from(ch))
              : VideoPlayPage(
                  sourceId: ch['sourceId'] ?? '', epUrl: ch['id'] ?? '', flag: '', title: ch['name'] ?? '频道',
                  episodes: [{'name': ch['name'], 'url': ch['id'], 'flag': ''}], index: 0))),
            child: Column(children: [
              Expanded(child: (ch['coverUrl'] ?? '') != '' ? Image.network(ch['engine'] == true ? '${ch['coverUrl']}' : Api.img(ch['coverUrl']), fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26, child: Icon(Icons.live_tv))) : const ColoredBox(color: Colors.black26, child: Icon(Icons.live_tv))),
              Padding(padding: const EdgeInsets.all(4), child: Text(ch['name'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))),
            ])); })),
  ]); }
// ★ 书架 / 历史的「详情页」此前一律走后端接口（`/v1/video/detail`、`/v1/comic/info`、
//   `/v1/music/url`），但走引擎直连的用户把内容加入书架或浏览过之后，书架里存的是
//   `sourceId == 'engine'` 的条目（见 `EngineItemPage._addShelf` / `_markOpened`）——
//   详情页**没有引擎分支**，点进去只会得到「失败」或播不出来：
//   · 没配家庭后端时：`Api.get` 直接抛异常 → 一屏红字；
//   · 配了后端时：`sourceId=engine` 不是后端的源 → 后端返回 error。
//   小说侧早就没这个问题（`TocPage.load()` 有 `book.sourceId == 'engine'` 分支走 EngineDirect），
//   视频 / 漫画 / 音乐三种内容一直缺这条兜底 —— 这正是「娱乐线」里最容易被当成
//   「引擎坏了」的一处（其实是路由少了一条分支）。
//   修法：**不在这里重抄一遍引擎取数逻辑**，而是对引擎条目直接进 `EngineItemPage`。
//   它本来就**是**引擎内容的详情页：目录取章（含「无目录直出条目」兜底）、正文、直链播放
//   全已实现并经真机路径验证。少一份重复实现，就少一处将来会漂移的地方。
Widget _detailOf(Book b, String type, Widget Function() backend) => b.sourceId == 'engine'
    ? EngineItemPage(type: type, item: {
        'id': b.bookUrl, 'name': b.name, 'coverUrl': b.coverUrl,
        'author': b.author, 'intro': b.intro})
    : backend();
Widget _videoDetail(Book b) => _detailOf(b, 'video',
    () => VideoDetailPage(sourceId: b.sourceId, vodId: b.bookUrl, title: b.name));

class VideoSearchResults extends StatefulWidget { final String query; const VideoSearchResults({super.key, required this.query}); @override State<VideoSearchResults> createState() => _VSR(); }
class _VSR extends State<VideoSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; int _seq = 0;
  bool needConn = false; // 本次是否被「未连接引擎与资源库」拦下（空态要用）
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final mySeq = ++_seq;
    await Future.delayed(const Duration(milliseconds: 350)); // 输入防抖: 停顿 350ms 再发请求, 避免逐字打引擎
    if (!mounted || mySeq != _seq) return;
    setState(() { loading = true; groups = []; needConn = false; });
    try {
      if (EngineDirect.connected) {
        final items = await EngineDirect.search('video', q);
        setState(() { groups = [{'ok': true, 'engine': true, 'items': items}]; });
      } else if (Api.base.isNotEmpty) {
        final r = await Api.get('/v1/video/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); });
      } else {
        await EngineDirect.autoConnect();
        if (EngineDirect.connected) { lastQ = ''; await go(q); return; }
        if (mounted) setState(() => needConn = true);
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
      searchEmptyState(
        loading: loading, query: widget.query, searched: lastQ.isNotEmpty,
        needConn: needConn, groups: groups, listKeys: const ['items'], kind: '视频',
        onFix: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const EngineDirectPage()))),
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
  // 画中画（与本地播放器同一套机制，见 core/pip.dart）
  bool _pipOk = false; bool _pipLastPlaying = false; int _pipGen = 0;
  double get _aspect { final v = _vc;
    if (v == null || !v.value.isInitialized) return 16 / 9;
    final a = v.value.aspectRatio; return a > 0 ? a : 16 / 9; }
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
      await _setupPip();
      setState(() => loading = false);
    } catch (e) { setState(() { loading = false; err = '$e'; }); } }

  /// 声明「正在放视频」并接上画中画小窗里的播放/暂停按钮。
  Future<void> _setupPip() async {
    _pipOk = await Pip.supported();
    Pip.onToggle = () {
      final v = _vc;
      if (v == null || !v.value.isInitialized) return;
      v.value.isPlaying ? v.pause() : v.play();
    };
    _vc?.addListener(_onPipTick);
    if (!mounted) return;
    setState(() {});
    if (!_pipOk) return;
    _pipGen = await Pip.claimAuto(aspect: _aspect, playing: _vc?.value.isPlaying ?? false);
  }

  void _onPipTick() {
    final v = _vc;
    if (v == null || !v.value.isInitialized) return;
    if (v.value.isPlaying == _pipLastPlaying) return;
    _pipLastPlaying = v.value.isPlaying;
    Pip.updatePlaying(_pipLastPlaying);
  }

  @override void dispose() {
    Pip.releaseAuto(_pipGen); Pip.onToggle = null; Pip.inPip.value = false;
    _vc?.removeListener(_onPipTick);
    _cc?.dispose(); _vc?.dispose(); super.dispose(); }
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
  @override Widget build(BuildContext c) => ValueListenableBuilder<bool>(
        valueListenable: Pip.inPip,
        builder: (c, pip, _) => pip ? _pipOnly() : _buildFull(c),
      );

  /// 画中画里只留画面：AppBar、选集条、上一集/下一集都不该被缩进那个小窗。
  Widget _pipOnly() => Scaffold(backgroundColor: Colors.black, body: Center(
    child: _cc == null ? const SizedBox.shrink()
      : AspectRatio(aspectRatio: _cc!.aspectRatio ?? 16 / 9, child: Chewie(controller: _cc!))));

  Widget _buildFull(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title, style: const TextStyle(fontSize: 15)), actions: [
      if (_pipOk) IconButton(icon: const Icon(Icons.picture_in_picture_alt, size: 20), tooltip: '画中画',
        onPressed: () async {
          final ok = await Pip.enter(aspect: _aspect, playing: _vc?.value.isPlaying ?? false);
          if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这台设备/当前状态进不了画中画')));
        }),
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
  // ★4.44.0 端网：前端/后端/插件/DSA 任意组合互相插线的地方。
  //   放在「核心」分类紧挨 AI —— 它是 AI 能力的延伸（让模型能指挥别的端）。
  '端网': const ModuleDef('端网', Icons.hub_outlined, PeerPage()),
  '聊天': const ModuleDef('聊天', Icons.forum_outlined, ChatPage()),
  '游戏': const ModuleDef('游戏', Icons.sports_esports_outlined, GamesPage()),
  '社区': const ModuleDef('社区', Icons.groups_outlined, CommunityPage()),
  '论坛': const ModuleDef('论坛', Icons.article_outlined, ForumPage()),
  '直播': const ModuleDef('直播', Icons.live_tv, LivePage()),
  '浏览器': const ModuleDef('浏览器', Icons.language, BrowserPage()),
  '相册': const ModuleDef('相册', Icons.photo_library_outlined, GalleryPage()),
  '文件': const ModuleDef('文件', Icons.folder_outlined, FilesPage()),
  '我的': ModuleDef('我的', Icons.person_outline, const ProfilePage()),
  // ═══ 规划文档 v2.0 全量模块框架(骨架页, 功能按版本逐步落地) ═══
  // ── Work 模式 ──
  // ★原名「作业中心」极易被理解成"学生写作业"，实际是本地**任务调度运行时**
  //   (作业队列/步骤回放/定时调度/模板/归档/待确认审批)，故改名。
  '自动化任务': ModuleDef('自动化任务', Icons.auto_mode_outlined, const JobCenterPage()),
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
  '天气与快递': const ModuleDef('天气与快递', Icons.wb_sunny_outlined, WeatherPage()),
  '菜谱': const ModuleDef('菜谱', Icons.restaurant_menu, RecipePage()),
  // ★原名「学习工具」名不副实：页面里只有"单词卡/背诵卡"一种功能，故改名。
  '记忆卡': const ModuleDef('记忆卡', Icons.style_outlined, StudyPage()),
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
  '远程打印': ModuleDef('远程打印', Icons.print_outlined, const RemotePrintPage()),
  // ── 家庭/多端 ──
  '共享相册': ModuleDef('共享相册', Icons.photo_library_outlined, SharedAlbumPage()),
  '共享清单': ModuleDef('共享清单', Icons.checklist_outlined, SharedListPage()),
  '家庭影院': ModuleDef('家庭影院', Icons.weekend_outlined, HomeCinemaPage()),
  '家庭音乐库': ModuleDef('家庭音乐库', Icons.library_music_outlined, HomeMusicPage()),
  '摄像头': ModuleDef('摄像头', Icons.videocam_outlined, CameraPage()),
  '智能家居': ModuleDef('智能家居', Icons.home_outlined, const SmartHomePage()),
  '设备互联': ModuleDef('设备互联', Icons.devices_outlined, DeviceLinkPage()),
  '家庭日历': ModuleDef('家庭日历', Icons.family_restroom_outlined, const CalendarPage(storageKey: 'family_calendar_events')),
  // ── 聚合入口(一个模块装一类, 导航栏不再排长队) ──
  '工具箱': const ModuleDef('工具箱', Icons.construction_outlined, ModuleHubPage(name: '工具箱', icon: Icons.construction_outlined,
    desc: '效率工具聚合: 翻译/扫描/二维码/计算器等一处直达',
    children: ['翻译', '扫描仪', '二维码', '悬浮便签', '计算器', '白板', '文本工具箱', '传感器', '文件互传', '远程打印'])),
  '家庭中心': const ModuleDef('家庭中心', Icons.home_work_outlined, ModuleHubPage(name: '家庭中心', icon: Icons.home_work_outlined,
    desc: '家庭/多端聚合: 共享相册/影院/智能家居等一处直达',
    children: ['共享相册', '共享清单', '家庭影院', '家庭音乐库', '摄像头', '智能家居', '设备互联', '家庭日历'])),
  // ★2026-09-19 用户反馈"功能全拆开了、找的时候非常麻烦"→ 按**同一使用场景**合并：
  //   只有"同一件事的不同步骤/同类物"才合进一个入口，避免又造出一堆平级模块。
  '学习中心': const ModuleDef('学习中心', Icons.school_outlined, ModuleHubPage(name: '学习中心', icon: Icons.school_outlined,
    desc: '学习聚合: 记忆卡(背单词/问答卡) + 课程表',
    children: ['记忆卡', '课程表'])),
  '音频中心': const ModuleDef('音频中心', Icons.headphones, ModuleHubPage(name: '音频中心', icon: Icons.headphones,
    desc: '「听」的聚合: 播客/有声书/广播电台一处直达（音乐播放器仍在「音乐」）',
    children: ['播客', '有声书', '广播'])),
  '记录中心': const ModuleDef('记录中心', Icons.edit_note, ModuleHubPage(name: '记录中心', icon: Icons.edit_note,
    desc: '随手写与临时存: 笔记/日记/便签/Markdown/代码片段/书签/剪贴板',
    children: ['笔记', '日记', '悬浮便签', 'Markdown', '代码片段', '书签', '剪贴板'])),
  '备份迁移': const ModuleDef('备份迁移', Icons.settings_backup_restore, ModuleHubPage(name: '备份迁移', icon: Icons.settings_backup_restore,
    desc: '换机/存档: 通讯录与短信备份一处直达',
    children: ['通讯录备份', '短信备份'])),
};

// ═══ 模块改名映射(旧键 → 新键) ═══
// ★为什么必须有这张表：nav_modules 里存的是**模块键**。直接改键会让老用户
//   底部导航里那个模块被 `where(kModules.containsKey)` 过滤掉 —— 表现为
//   "升级后模块凭空消失"。所有键改名都必须在这里登记，读取时先迁移再校验。
const Map<String, String> kModuleRenames = {
  '作业中心': '自动化任务',
  '学习工具': '记忆卡',
  '天气快递': '天气与快递',
};

// ═══ 模块分类(导航栏管理树状分组用) ═══
const kCatOrder = ['核心', '内容', '生活', '效率', '家庭', '实验室'];
const Map<String, String> kModuleCats = {
  '搜索': '核心', 'AI': '核心', '端网': '核心', '浏览器': '核心', '文件': '核心', '相册': '核心', '我的': '核心',
  '小说': '内容', '漫画': '内容', '视频': '内容', '音乐': '内容', '直播': '内容',
  '播客': '内容', '有声书': '内容', '广播': '内容', '短剧': '内容', '壁纸': '内容', '资讯': '内容',
  '笔记': '生活', '待办': '生活', '录音机': '生活', '日历': '生活', '提醒中心': '生活', '日记': '生活', '记账': '生活',
  '剪贴板': '生活', '书签': '生活', '代码片段': '生活', 'Markdown': '生活', '健康记录': '生活',
  '通讯录备份': '生活', '短信备份': '生活', '天气与快递': '生活', '菜谱': '生活', '记忆卡': '生活', '课程表': '生活',
  '自动化任务': '效率', '工具箱': '效率', '翻译': '效率', '扫描仪': '效率', '二维码': '效率', '计算器': '效率',
  '白板': '效率', '文本工具箱': '效率', '传感器': '效率', '文件互传': '效率', '远程打印': '效率', '悬浮便签': '效率',
  '家庭中心': '家庭', '共享相册': '家庭', '共享清单': '家庭', '家庭影院': '家庭', '家庭音乐库': '家庭',
  '摄像头': '家庭', '智能家居': '家庭', '设备互联': '家庭', '家庭日历': '家庭',
  // 聚合入口自身也归到它收纳内容所属的分类
  '音频中心': '内容', '学习中心': '生活', '记录中心': '生活', '备份迁移': '生活',
  '聊天': '实验室', '社区': '实验室', '论坛': '实验室', '游戏': '实验室',
};
String moduleCat(String k) => kModuleCats[k] ?? '其他';

/// 把持久化的模块键列表迁到当前键名（改过名的模块不会丢）。
List<String> migrateModuleKeys(Iterable<String> raw) {
  final out = <String>[];
  for (final k in raw) {
    final n = kModuleRenames[k] ?? k;
    if (!out.contains(n)) out.add(n);
  }
  return out;
}

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

// ★2026-09-19 「敬请期待」占位页与模块骨架页(ModuleScaffoldPage)已全部退役:
//   聊天/游戏/社区/论坛 四个实验室模块与 自动化任务/远程打印/智能家居 三个骨架模块
//   都换成了真页面(见 core/lab_social.dart, core/lab_games.dart, core/job_center.dart, core/home_io.dart),
//   这里不再保留任何"框架已就位"式的空壳页面。

// ═══ 模块骨架页 Template 已删除(所有模块都有真页面了) ═══

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
  // ★4.44.0 左右滑动切模块: 手势改由 NavSwipeRecognizer 接管(带主方向判定)。
  // 原实现直接用 PageView 的 PageScrollPhysics —— 内置识别器只看水平位移是否
  // 超过 kTouchSlop(18), 不看垂直分量, 于是"斜着上滑"会被误判成切模块。
  bool _swHand = false;    // 本手势正在被手工跟手驱动
  int _swFrom = 0;         // 手势起始页(不随拖拽中的 idx 变化)
  double _swBasePx = 0;    // 手势起始像素位置
  final ScrollController _navScroll = ScrollController();
  // 沉浸式模块: 自带页头(浏览器=地址栏, 相册=相册条), 隐藏系统顶栏
  static const _noAppBarModules = {'浏览器', '相册'};
  // 全沉浸模块: 连底部导航也隐藏(屏幕留给正文, 通过模块宫格返回)
  // ★浏览器已撤出该名单(用户反馈"一进去就直接全屏"): 现在和其它模块一样
  //   进入先显示底栏, 3 秒(可调)无操作才按自动全屏规则收起。
  static const _noNavModules = <String>{};
  @override void initState() { super.initState(); _load();
    RootNav.navTick.addListener(_onNavChanged);
    RootNav.fullscreen.addListener(_onFs);
    // 4.40.0: AI 工具 / 系统中心等"打开某模块"请求 → 真正切模块(未启用则自动加入导航)
    proOpenModule.addListener(_onProOpen);
    // 浏览器等沉浸页的"切换模块"入口
    BrowserHooks.openModules = (c) => NavOrb.showModuleGrid(c, enabled, idx, (i) => _go(i, animate: false));
    _wireLocalHooks(); // ★4.44.0 上下文注入 + 前端控制能力
    unawaited(_bootPeers()); // ★4.44.0 端网：接入 + 定时心跳（无后端时自动退化为直连模式）
    Future.delayed(const Duration(seconds: 4), () { if (mounted) Updater.check(context); }); }

  /// ★4.44.0 把本端接入端网（PH/1）。
  ///
  /// 放在 _RootNavState 而不是 ThApp 的原因：本端要**对外声明**的东西
  /// （模块列表 / 离线工具 / 设置项 / 是否已连后端）都只有这里知道；
  /// 换个地方就得把这些信息复制一份，早晚走偏。
  ///
  /// 失败不影响启动：PeerHubRuntime 会退化成"离线模式/无后端直连模式"。
  Future<void> _bootPeers() async {
    PeerHubRuntime.addressProvider = () => {
          // 本端对外可达地址。留空也能用 —— 只是别的端无法反向直连本机。
          // 填了内网穿透地址后，即使后端不在线，别的端也能通过它找到本机。
          'url': AppSettings.p.get('peer_url')?.toString() ?? '',
          'ipv6': AppSettings.p.get('peer_ipv6')?.toString() ?? '',
          'tunnel': AppSettings.p.get('peer_tunnel')?.toString() ?? '',
        };
    PeerHubRuntime.capabilityProvider = () => {
          'caps': <String>[
            'front',
            'tools',
            'secrets',
            if (AgentRuntime.backendConnected) 'llm',
          ],
          // 把本机离线工具全报上去 —— 其他端就知道"这台手机能干什么"。
          'tools': LocalTools.all.map((t) => 'local_${t.name}').toList(),
        };
    try {
      await PeerHubRuntime.start(name: '我的手机');
    } catch (_) {
      // 端网起不来绝不能拖垮启动
    }
  }

  /// ★4.44.0 把「前端知道的东西」与「前端能做的事」交给本地工具层。
  ///
  /// 这是"上下文注入"的落点：AI 不再需要用户先告诉它"我在哪个模块"。
  /// 同时也是"前端是控制层"的落点：goto_module / setting 让模型能直接指挥前端，
  /// 而**这些能力完全不依赖后端** —— 没连后端时照样能用。
  static const List<String> _settingKeys = [
    'nav_swipe', 'nav_style', 'nav_side', 'nav_autohide', 'auto_fs_sec',
    'orb_snap', 'theme_mode', 'accent_color', 'locale', 'splash_anim',
  ];

  void _wireLocalHooks() {
    LocalHooks.listModules = () async => List<String>.from(enabled);
    LocalHooks.gotoModule = (m) async {
      final name = m.trim();
      var i = enabled.indexOf(name);
      if (i < 0) {
        // 容忍"浏览器"/"浏览器模块"这类写法
        i = enabled.indexWhere((e) => e == name || name.startsWith(e) || e.startsWith(name));
      }
      if (i < 0) return '当前导航栏没有「$name」。可用模块: ${enabled.join(' · ')}';
      _go(i);
      return '已切到「${enabled[i]}」';
    };
    LocalHooks.contextOf = () async {
      final now = DateTime.now();
      final mod = enabled.isEmpty ? '(无)' : enabled[idx.clamp(0, enabled.length - 1)];
      final buf = StringBuffer()
        ..writeln('App: ThirdHub ${Updater.currentVersion} (build ${Updater.currentCode})')
        ..writeln('当前模块: $mod')
        ..writeln('导航栏: ${enabled.join(' · ')}')
        ..writeln('全屏中: ${RootNav.fullscreen.value ? '是' : '否'} · 左右滑动切模块: ${AppSettings.navSwipe ? '开' : '关'}')
        ..writeln('本地时间: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}')
        ..writeln('家庭后端: ${AgentRuntime.backendConnected ? '已连接' : '未连接（离线能力仍可用）'}')
        ..writeln('Agent 模式: ${AgentRuntime.modeLabel}');
      try { buf.writeln('本地笔记: ${await LocalNotes.count()} 条'); } catch (_) {}
      return buf.toString().trim();
    };
    LocalHooks.getSetting = (k) async => _readSetting(k);
    LocalHooks.setSetting = (k, v) async => _writeSetting(k, v);
    _syncContext();
  }

  /// 刷新「当前上下文」快照（同步，供 prompt 构建直接读）。
  /// 模块切换 / 翻页 / 全屏变化时调用。
  void _syncContext() {
    if (!mounted) return;
    final now = DateTime.now();
    final mod = enabled.isEmpty ? '(无)' : enabled[idx.clamp(0, enabled.length - 1)];
    final t = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    LocalContextSnapshot.set(
      '【当前状态】ThirdHub ${Updater.currentVersion} · 用户正在「$mod」模块 · '
      '导航栏: ${enabled.join(" / ")} · ${RootNav.fullscreen.value ? "全屏中" : "非全屏"} · '
      '家庭后端${AgentRuntime.backendConnected ? "已连接" : "未连接(离线能力仍可用)"} · '
      'Agent 模式 ${AgentRuntime.modeLabel} · '
      // ★4.44.0 端网状态也进上下文：模型据此知道"现在能不能指挥别的端"，
      //   不用等用户先说"我连了插件没有"。
      '端网 ${PeerHubRuntime.status.isEmpty ? "未接入" : PeerHubRuntime.status}'
      '${PeerHubRuntime.registry.hub != null ? "" : "（无后端直连模式）"} · '
      '本地时间 $t。'
      '回答时可以自然地结合用户所在模块给出建议，但不要生硬复述这串状态。');
  }

  String _readSetting(String k) {
    final key = k.trim();
    if (!_settingKeys.contains(key)) return '未知设置项。可用: ${_settingKeys.join(' · ')}';
    final v = AppSettings.p.get(key);
    return v == null ? '$key = (未设置, 用默认值)' : '$key = $v';
  }

  Future<String> _writeSetting(String k, String v) async {
    final key = k.trim();
    if (!_settingKeys.contains(key)) return '未知设置项。可用: ${_settingKeys.join(' · ')}';
    final p = AppSettings.p;
    try {
      if (const {'nav_swipe', 'nav_autohide', 'orb_snap', 'splash_anim'}.contains(key)) {
        final b = v == 'true' || v == '1' || v == 'on' || v == '开';
        await p.setBool(key, b);
      } else if (const {'auto_fs_sec', 'accent_color'}.contains(key)) {
        final n = int.tryParse(v.trim());
        if (n == null) return '$key 需要整数';
        await p.setInt(key, key == 'auto_fs_sec' ? n.clamp(0, 10) : n);
      } else {
        await p.setString(key, v);
      }
    } catch (e) {
      return '写入失败: $e';
    }
    AppSettings.onChanged?.call();
    RootNav.navTick.value++; // 让导航层/设置页重读
    if (mounted) setState(() {});
    return '已设置 $key = $v';
  }
  void _onNavChanged() { _load(); }
  // 4.40.0: 消费一次"打开模块"请求(AI 工具 / 系统中心 / 任意 Pro 模块发起)
  Future<void> _onProOpen() async {
    final k = proOpenModule.value;
    if (k == null) return;
    proOpenModule.value = null;            // 消费掉, 避免重复触发
    if (!mounted || !kModules.containsKey(k)) return;
    var i = enabled.indexOf(k);
    if (i < 0) {
      // 该模块还没在用户导航栏里 → 自动加入(排在"我的"之前)并持久化
      try {
        final p = await SharedPreferences.getInstance();
        final list = [...enabled.where((e) => e != '我的'), k, '我的'];
        await p.setStringList('nav_modules', list);
      } catch (_) {}
      await _load();
      if (!mounted) return;
      i = enabled.indexOf(k);
    }
    if (i < 0) return;
    if (mounted) _go(i, animate: false);
  }
  void _onFs() {
    if (RootNav.fullscreen.value) { SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); }
    else { SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); }
    if (mounted) setState(() {});
  }
  @override void dispose() { RootNav.navTick.removeListener(_onNavChanged); RootNav.fullscreen.removeListener(_onFs); proOpenModule.removeListener(_onProOpen); BrowserHooks.openModules = null; _fsTimer?.cancel(); _page.dispose(); _navScroll.dispose(); super.dispose(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getStringList('nav_modules');
    if (saved == null || saved.isEmpty) {
      setState(() { enabled = ['我的']; if (idx >= enabled.length) idx = 0; });
      return;
    }
    // ★先迁移旧键再校验：改过名的模块若被 containsKey 过滤掉，用户会以为"模块升级后没了"
    final migrated = migrateModuleKeys(saved).where((k) => kModules.containsKey(k)).toList();
    if (!migrated.contains('我的')) migrated.add('我的');
    setState(() { enabled = migrated; if (idx >= enabled.length) idx = 0; });
    // 迁移结果回写，避免每次启动都重算（也避免旧键一直在盘里）
    if (migrated.join('\u0001') != saved.join('\u0001')) {
      try { await p.setStringList('nav_modules', migrated); } catch (_) {}
    }
  }
  bool _animating = false;
  // ── 自动全屏（D-11）：切换模块后计时，N 秒无切换操作则收起底部导航进入全屏 ──
  Timer? _fsTimer;
  bool _fsSuppressed = false; // 用户手动退出全屏后，本次驻留该模块期间不再自动进入
  void _armAutoFs() {
    _fsTimer?.cancel();
    final sec = AppSettings.autoFsSec;
    if (sec <= 0 || !mounted) return;
    final key = enabled.isEmpty ? '' : enabled[idx.clamp(0, enabled.length - 1)];
    if (key.isEmpty || _fsSuppressed || RootNav.fullscreen.value) return;
    if (_noNavModules.contains(key)) return;          // 本来就无导航栏的模块
    if (!AppSettings.fsEnabledFor(key)) return;       // 用户关掉了这个模块的全屏
    _fsTimer = Timer(Duration(seconds: sec), () {
      if (!mounted || _fsSuppressed || RootNav.fullscreen.value) return;
      final nowKey = enabled.isEmpty ? '' : enabled[idx.clamp(0, enabled.length - 1)];
      if (nowKey != key || !AppSettings.fsEnabledFor(nowKey)) return;
      RootNav.fullscreen.value = true;
      AppLog.module('进入全屏', d: {'module': nowKey, 'auto': true, 'sec': sec});
    });
  }
  void _exitFs() {
    _fsSuppressed = true; // 这次手动退出后，留在本模块不再自动进入；切走再回来才会重新计时
    RootNav.fullscreen.value = false;
  }
  /// 切换模块。
  ///
  /// ★2026-09-19：默认改为**直接跳**（`jumpToPage`），不再 `animateToPage` 沿路滑过。
  /// 原因：`animateToPage` 会让 PageView 在 240ms 内**依次构建中间那些模块**，
  /// 每个模块的 initState/网络请求都会被触发 —— 用户看到的"从好几个模块之间切过去"、
  /// "造成很多不必要的加载"（AI 模块切走时把左上角的东西呼出来）都来自这里。
  /// 只有调用方明确要动画时（目前没有）才走动画分支。
  void _go(int i, {bool animate = false}) {
    if (i < 0 || i >= enabled.length) return;
    // S-6 模块锁(4.40.0): 设过 PIN 的模块, 本次会话首次进入需验证
    final lockKey = enabled[i];
    ModuleLocks.locked(lockKey).then((need) {
      if (!mounted) return;
      if (!need) { _goNow(i, animate: animate); return; }
      final cc = TextEditingController();
      showDialog<bool>(context: context, builder: (c2) => AlertDialog(
        title: Text('$lockKey 已锁定'),
        content: TextField(controller: cc, keyboardType: TextInputType.number, obscureText: true,
          decoration: const InputDecoration(hintText: '输入 PIN')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('解锁')),
        ])).then((ok) async {
        if (ok != true) return;
        final pin = await ModuleLocks.pinOf(lockKey);
        if (cc.text.trim() == pin) {
          await ModuleLocks.unlock(lockKey);
          if (mounted) _goNow(i, animate: animate);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN 不正确')));
        }
      });
    });
  }
  void _goNow(int i, {bool animate = false}) {
    HapticFeedback.selectionClick(); // 切换模块轻微震动
    if (i == idx) return;
    setState(() { idx = i; RootNav.currentModuleKey = enabled[i]; });
    _fsSuppressed = false; // 切模块 = 一次操作，重新允许自动全屏计时
    AppLog.module('打开模块', d: {'module': enabled[i]});
    _armAutoFs();
    _syncContext(); // 上下文注入：模块变了，快照跟着变
    if (!_page.hasClients) return;
    if (animate) {
      _animating = true;
      _page.animateToPage(i, duration: const Duration(milliseconds: 240), curve: Curves.easeOut)
        .whenComplete(() => _animating = false);
    }
    else { _page.jumpToPage(i); }
  }
  /// ★4.44.0 跟手驱动：把 PageView 挪到 `起始页 - 累计手势位移` 处。
  ///
  /// PageView 的 physics 恒为 NeverScrollableScrollPhysics（它自己不碰手势），
  /// 位置完全由这里驱动。用**绝对位移**而不是增量，天然幂等，不会累积漂移。
  void _swDragTo(double dx) {
    if (!_page.hasClients) return;
    final p = _page.position;
    final target = (_swBasePx - dx).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (target != p.pixels) p.jumpTo(target);
  }
  /// ★4.44.0 松手结算：按「位移比例 or 甩动速度」决定翻页还是回弹。
  ///
  /// [dx] 是累计手势位移（手指向左为负），[vx] 是手指水平速度。
  /// 注意 `_swFrom` 是**手势起始页**而不是当前 idx —— 拖拽途中 onPageChanged
  /// 可能已经把 idx 改掉，用 idx 会算错方向。
  void _swSettle(double dx, double vx) {
    if (!_page.hasClients) return;
    final p = _page.position;
    final t = SwipeSettleDecider.target(
      from: _swFrom, count: enabled.length,
      movedPx: -dx, pageWidth: p.viewportDimension, velocityDx: vx);
    if (t == _swFrom) {
      // 没滑够 → 弹回原页（不记日志、不震动，什么都没发生）
      _page.animateToPage(_swFrom,
        duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
      return;
    }
    // 落到目标页：副作用在这里显式补一次 —— 拖拽途中 onPageChanged 被静默处理了
    HapticFeedback.selectionClick();
    setState(() { idx = t; RootNav.currentModuleKey = enabled[t]; });
    _fsSuppressed = false; // 切模块 = 一次操作，重新允许自动全屏计时
    AppLog.module('滑动切到模块', d: {'module': enabled[t]});
    _armAutoFs();
    _syncContext();
    _page.animateToPage(t,
      duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }
  @override Widget build(BuildContext c) {
    ScreenFit.update(c);
    final key = enabled[idx];
    final fs = RootNav.fullscreen.value;
    final hideBar = _noAppBarModules.contains(key);   // 沉浸: 该模块自带页头, 不补状态栏留白
    final hideNav = _noNavModules.contains(key);      // 底栏: 沉浸页不显示
    final kbOpen = MediaQuery.viewInsetsOf(c).bottom > 100; // 键盘弹出时底栏让位(网页端 kb-open 同款)
    // 左右滑动切换模块(默认开): 关闭时退回"模块间手势完全隔离"
    final swipe = AppSettings.navSwipe;
    // PageView 防回跳兜底: 任何原因导致页面重建后停在第0页而 idx 不在0时, 帧末拉回当前模块。
    // 只在**禁止滑动**时启用 —— 允许滑动时 `_page.page` 会在手势中途出现 2.5 这种值,
    // 用 round() 判定会把用户正在拖的这一页硬拽回去, 正是"切换很别扭"的来源之一。
    if (!swipe && _page.hasClients && !_animating && (_page.page?.round() ?? idx) != idx && idx < enabled.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_page.hasClients && !_animating && idx < enabled.length) _page.jumpToPage(idx);
      });
    }
    // 点按正文→底栏收起为 1/3 细条(保持收起, 不再因松手/上滑弹回); 点细条恢复
    // ── ★4.44.0 左右滑动切模块：PageView 不再自己处理手势 ──
    // physics 恒定 NeverScrollableScrollPhysics ⇒ Scrollable 不注册内置识别器，
    // 手势全部交给外层 NavSwipeRecognizer（要求"水平分量明确占主导"）。
    // 这样"在模块内斜着上滑"会主动退场、让位给模块自己的滚动视图，永不误判成切模块。
    final pageView = PageView(
      controller: _page,
      physics: const NeverScrollableScrollPhysics(),
      onPageChanged: (i) {
        // 手工跟手期间（或目标页已被 _swSettle 先行 setState）只同步状态：
        // 避免"拖到一半就写日志/震动/重置自动全屏"这类半途副作用。
        if (_swHand || i == idx) {
          setState(() { idx = i; });
          RootNav.currentModuleKey = enabled[i];
          _syncContext();
          return;
        }
        setState(() { idx = i; });
        RootNav.currentModuleKey = enabled[i];
        RootNav.moduleTick.value++;
        _fsSuppressed = false;
        AppLog.module('滑动切到模块', d: {'module': enabled[i]});
        _armAutoFs();
        _syncContext();
      },
      children: [ for (final k in enabled) _KeepAlivePage(key: ValueKey(k), child: kModules[k]!.page) ]);
    final body = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (fs || !AppSettings.navAutoHide || hideNav || _navCollapsed) return;
        _fsTimer?.cancel(); // 点按正文 = 一次操作，本轮不再自动进入全屏
        setState(() => _navCollapsed = true);
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: swipe ? <Type, GestureRecognizerFactory>{
          NavSwipeRecognizer: GestureRecognizerFactoryWithHandlers<NavSwipeRecognizer>(
            () => NavSwipeRecognizer(debugOwner: this),
            (r) => r
              ..onDown = (d) {
                _swFrom = idx;
                _swHand = false;
                // 用「起始页 × 视口宽」定位基准，而不是 position.pixels ——
                // 若上一次翻页动画还没跑完，pixels 是中间值，会让跟手起点偏移。
                _swBasePx = _page.hasClients ? _swFrom * _page.position.viewportDimension : 0;
              }
              ..onStart = (_) { _swHand = true; _animating = true; }
              ..onUpdate = (d) {
                if (r.yieldedVertical) return; // 已让位给内层滚动
                _swDragTo(r.totalDx(d.globalPosition.dx));
              }
              ..onEnd = (d) {
                _swHand = false; _animating = false;
                // 竞技场只剩本识别器时会被强制 accept，此时仍可能是垂直手势 ——
                // 必须再查一次，否则"上滑也翻页"会从后门回来。
                if (r.yieldedVertical) return;
                _swSettle(r.totalDx(d.globalPosition.dx), d.velocity.pixelsPerSecond.dx);
              }
              ..onCancel = () {
                _swHand = false; _animating = false;
                if (_page.hasClients) _swSettle(0, 0); // 取消 → 回弹原页
              },
          ),
        } : const <Type, GestureRecognizerFactory>{},
        child: pageView));
    // 顶栏已移除: 模块名由底栏高亮承担, 模块菜单收进各模块页分段行右侧 ⋯ / 悬浮球长按 (openModuleMenu)
    // body 始终位于 Stack 第 0 位且包裹类型恒定(SafeArea.top 开关), 全屏切换不再重建 PageView —— 修复"点全屏跳回搜索页"
    final bodyStack = Stack(children: [
      SafeArea(top: !hideBar && !fs, bottom: false, child: body),
      if (fs) const FsExitOrb(),
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
      // ★2026-09-19 去掉外层 AnimatedSize：它给底栏套了一层"按当前尺寸裁剪"的容器，
      //   实测在模拟器上会出现**底栏肉眼可见、点却点不动**（hit test 落在被裁剪区域之外），
      //   用户表现为"卡在某个模块里出不来"。底栏内部每格已有 AnimatedContainer 做选中态过渡，
      //   高度切换（展开/收起）不需要再包一层动画容器。
      bottomNavigationBar: (hideNav || fs || kbOpen) ? null
        : _scrollNavBar(collapsed: _navCollapsed && AppSettings.navAutoHide));
  }

  // 模块菜单(底部弹层, 替代原顶栏 ⋯): 新会话(AI)/本地库/导入/模块设置/全屏/切换模块
  // 入口: 各模块页分段按钮行右侧 ⋯(modMenuBtn) / 悬浮球长按; 底部导航栏不再放 ⋯
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
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(importSnack(n, '个文件')); }),
      ],
      if (_settingsModules.contains(key))
        ListTile(dense: true, leading: const Icon(Icons.tune, size: 20), title: Text('${mod.name}设置'),
          onTap: () { Navigator.pop(c2); showModuleSettings(context, key); }),
      // ★4.44.0 每个模块各自的更新公告。放在这里而不是给 65 个模块各改一次 UI ——
      //   模块菜单本来就是"这一模块自己的事"的入口（本地库/导入/模块设置都在这）。
      ListTile(dense: true, leading: const Icon(Icons.campaign_outlined, size: 20),
        title: Text('${mod.name}更新公告'),
        subtitle: const Text('只显示与这个模块有关的改动', style: TextStyle(fontSize: 11)),
        onTap: () { Navigator.pop(c2); Navigator.push(context, smoothRoute(ModuleClogPage(module: key))); }),
      ListTile(dense: true, leading: const Icon(Icons.history, size: 20), title: const Text('全部更新历史'),
        onTap: () { Navigator.pop(c2); Navigator.push(context, smoothRoute(const ChangelogPage())); }),
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
    final p = NeuPalette.fromTheme(Theme.of(context));
    final mod = kModules[enabled[idx]]!;
    return SafeArea(child: GestureDetector(
      onTap: () { HapticFeedback.selectionClick(); NavOrb.showModuleGrid(context, enabled, idx, (i) => _go(i, animate: false)); },
      child: Container(height: 40, margin: const EdgeInsets.fromLTRB(48, 0, 48, 8),
        decoration: Neu.raised(p, radius: 20, depth: 3, blur: 7),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(mod.icon, size: 16, color: p.accent), const SizedBox(width: 6),
          Text(tr(mod.name), style: TextStyle(fontSize: 12, color: p.accent, fontWeight: FontWeight.bold)),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_up, size: 16, color: p.accent),
        ]))));
  }

  // 完全体同款底栏: 整条是一块**微微凸起的面**(顶边高光 + 底边暗影), 选中项"陷进去"。
  // 模块多→横向自由滑动, "我的"永远固定在最右端。
  //
  // 为什么不用渐变胶囊: 换背景色是 Material 的思路(强对比色块), 而全应用其它地方
  // 都是拟态(同底色 + 双向光影)。选中态用"凹陷"表达, 底栏才和页面是同一块材质;
  // 渐变胶囊飘在上面, 就会显得脏、切换时视觉重量乱跳 —— 这正是旧版手感差的主因。
  // collapsed=滚动收起态: 去掉文字只留图标, 高度 62→36。
  Widget _scrollNavBar({bool collapsed = false}) {
    final p = NeuPalette.fromTheme(Theme.of(context));
    final mineIdx = enabled.indexOf('我的');
    final scrollKeys = [ for (var i = 0; i < enabled.length; i++) if (i != mineIdx) i ];
    final barH = collapsed ? 36.0 : 62.0;
    Widget item(int i, {double? width}) {
      final k = enabled[i]; final m = kModules[k]!; final on = i == idx;
      final fg = on ? p.accent : p.sub;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () { HapticFeedback.selectionClick(); _go(i); },
        child: SizedBox(width: width, height: barH,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
            child: AnimatedContainer(duration: const Duration(milliseconds: 150), curve: Curves.easeOut,
              decoration: on ? Neu.inset(p, radius: 13, depth: 3, blur: 6) : null,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                // 选中项图标轻微弹一下, 给切换一个"到位"的反馈
                TweenAnimationBuilder<double>(tween: Tween(begin: 1, end: on ? 1.08 : 1.0),
                  duration: const Duration(milliseconds: 220), curve: Curves.easeOutBack,
                  builder: (_, s, child) => Transform.scale(scale: s, child: child),
                  child: Icon(m.icon, size: collapsed ? 19 : 21, color: fg)),
                if (!collapsed) ...[
                  const SizedBox(height: 3),
                  Text(tr(m.name), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: fg, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
                ],
              ])))));
    }
    return GestureDetector(
      // 收起态: 点按细条恢复完整底栏; 任意状态: 长按弹出模块抽屉
      onTap: collapsed ? () => setState(() => _navCollapsed = false) : null,
      onLongPress: () { HapticFeedback.selectionClick(); NavOrb.showModuleGrid(context, enabled, idx, (i) => _go(i, animate: false)); },
      child: DecoratedBox(
        // 顶边打光、底边压暗: 这一条就"长"在页面底部, 而不是浮在上面
        decoration: BoxDecoration(color: p.bg, boxShadow: [
          BoxShadow(color: p.hilite, offset: const Offset(0, -3), blurRadius: 7),
          BoxShadow(color: p.shadow, offset: const Offset(0, -1), blurRadius: 3),
        ]),
        child: SafeArea(top: false, child: SizedBox(height: barH, child: LayoutBuilder(builder: (ctx, box) {
          // ★2026-09-19 底栏槽宽统一（用户反馈：模块图标与"我的"对不齐、像没居中）。
          //   旧实现有两处宽度基准不一致：
          //     ① "模块少"时滚动项用 Expanded 等分、而"我的"固定 78px —— 只要
          //        (屏宽-78)/n ≠ 78 就必然错位，且 n 越小错得越多；
          //     ② "模块多"时把固定 78px 的项硬塞进剩余宽度，320px 窄屏下末项被压成
          //        8px 的细条（实测 Videos 的可见宽度正好是 8px），看着就像"图标没居中"。
          //   现在改为：**所有槽位（含"我的"）一律等宽**，且槽宽 = 屏宽 ÷ 能放下的整数个，
          //   任意屏宽下都不会出现残项，"我的"与相邻项严格对齐、每格图标居中。
          final ideal = collapsed ? 54.0 : 78.0;
          final cap = (box.maxWidth / ideal).floor().clamp(2, 8);   // 一屏最多放几个槽
          final total = enabled.length;
          if (total <= cap) {
            // 模块少：全部等分铺满（含"我的"），每项严格等宽
            final w = box.maxWidth / (total == 0 ? 1 : total);
            return Row(children: [
              for (final i in scrollKeys) SizedBox(width: w, child: item(i)),
              if (mineIdx >= 0) SizedBox(width: w, child: item(mineIdx)),
            ]);
          }
          // 模块多：左区横向滑动（每项恒等于槽宽，末项不再被压扁），"我的"固定最右且同宽
          final w = box.maxWidth / cap;
          final slots = mineIdx >= 0 ? cap - 1 : cap;
          return Row(children: [
            SizedBox(width: slots * w, child: ListView.builder(controller: _navScroll,
              scrollDirection: Axis.horizontal, itemCount: scrollKeys.length,
              itemBuilder: (_, n) => SizedBox(width: w, child: item(scrollKeys[n])))),
            if (mineIdx >= 0) SizedBox(width: w, child: item(mineIdx)),
          ]);
        })))),
      );
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

/// 导入结果的统一提示：成功条数 + 每条失败原因。
///
/// 为什么不再用一句"未导入"：用户根本没法知道是格式不支持、编码坏了、
/// 还是压缩包解不开。把原因摆出来，才知道下一步该做什么。
SnackBar importSnack(int n, String unit) {
  final errs = LocalLib.lastErrors;
  final String head = n > 0 ? '已导入 $n $unit' : '没有导入成功';
  if (errs.isEmpty) return SnackBar(content: Text(head));
  final int extra = errs.length - 3;
  return SnackBar(
    duration: const Duration(seconds: 6),
    content: Text('$head\n失败 ${errs.length} 项：\n${errs.take(3).join('\n')}${extra > 0 ? '\n…还有 $extra 项' : ''}'),
  );
}

// 底部导航自定义(像网站: 勾选哪些模块 + 按住拖动调整顺序)
Future<void> showNavSettings(BuildContext c) async {
  final p = await SharedPreferences.getInstance();
  final saved = migrateModuleKeys(p.getStringList('nav_modules') ?? ['我的']);
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
    // ★头像字段对齐: 本端上传写的是 avatar_b64(见 _pickAvatar), 此前这里只读 avatar_url
    //   → 头像永远同步不下来。两个字段都认, avatar_b64 优先。
    if (prof['avatar_b64'] != null && '${prof['avatar_b64']}'.isNotEmpty) {
      try { await AppSettings.setAvatar('${prof['avatar_b64']}'); } catch (_) {}
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
        TtsBackend.base = Api.base; TtsBackend.token = Api.token;
        AgentDshClient.base = Api.base; AgentDshClient.token = Api.token;
        PeerHubClient.base = Api.base; PeerHubClient.token = Api.token;
        // 刚自动连上后端：顺手探一次 Agent Runtime，让「任务」栏一进去就是正确的模式
        try { await AgentRuntime.bootstrap(); } catch (_) {}
        // 端网也要跟着切到新后端（否则会拿着旧地址去 join）
        try { await PeerHubRuntime.refresh(); } catch (_) {}
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
class DownloadCenterTile extends StatefulWidget {
  const DownloadCenterTile({super.key});
  static const _base = 'https://mxvxlgjzeboktufumxbp.supabase.co/storage/v1/object/public/downloads/thirdhub';
  static const products = [
    ('第三方聚合', 'Flutter 纯播放器前端(本应用)', '$_base/thirdhub-app.apk', Icons.phone_android,
      '聚合 AI 对话 / 小说 / 漫画 / 视频 / 音乐 / 直播 / 相册 / 文件管理器。纯播放器设计, 不内置任何源, 通过后端与引擎获取内容。'),
    ('第三方后端', '手机内嵌 Node.js 后端', '$_base/thirdhub-backend.apk', Icons.dns,
      '在手机上运行的资源库后端: 内容源引擎 + 局域网共享 + TLS 加密。装好后前端自动发现。'),
    ('电脑版后端 · Windows', '一键安装脚本 · 把电脑变成资源库服务器', '$_base/install-windows.ps1', Icons.computer,
      '在 Windows 电脑上跑后端: 下载脚本后用管理员 PowerShell 执行即可(自动装 Node、部署、注册开机自启)。与手机后端同一账号体系。'),
    ('电脑版后端 · Linux', '一键安装脚本 · systemd 常驻', '$_base/install-linux.sh', Icons.terminal,
      '在 Linux 服务器/电脑上跑后端: 下载脚本后 bash 执行(自动装 Node、部署、systemd 常驻)。适合长期挂机当家庭服务器。'),
    ('网页版', 'thirdhub.pages.dev', 'https://thirdhub.pages.dev', Icons.language,
      '浏览器打开即用, 可安装为 PWA。与客户端同一账号体系, 数据全端互通。'),
    ('网页版 1.0(经典旧版)', '最初网页版存档 · 怀旧/老设备', 'https://0d57a5ba.thirdhub.pages.dev', Icons.history,
      'ThirdHub 最初的网页版 1.0 存档(2026-08-06 首次部署)。功能与界面以新版网页版为准, 此版本仅供老设备兼容与怀旧使用。'),
  ];
  @override State<DownloadCenterTile> createState() => _Dct();
}

class _Dct extends State<DownloadCenterTile> {
  // 引擎下载条目仅管理员可见(与更新历史同一套账号体系判定, 权限在服务端 RLS)
  Map<String, dynamic>? _engine, _venera;
  // 前端/后端版本化清单(所有用户可见)
  Map<String, dynamic>? _app, _backend;
  @override void initState() {
    super.initState();
    _loadManifests();
  }
  Future<void> _loadManifests() async {
    try { _app = await Cloud.latestManifest('app'); } catch (_) {}
    try { _backend = await Cloud.latestManifest('backend'); } catch (_) {}
    if (ChangelogStore.isAdmin) {
      // 引擎条目额外拉版本化清单: 永远指向最新引擎包(服务端发版时同步推进)
      try { _engine = await Cloud.latestManifest('engine'); } catch (_) {}
      try { _venera = await Cloud.latestManifest('venera'); } catch (_) {}
    }
    if (mounted) setState(() {});
  }
  @override Widget build(BuildContext c) {
    final admin = ChangelogStore.isAdmin;
    final av = '${_app?['version'] ?? ''}';
    final bv = '${_backend?['version'] ?? ''}';
    final appUrl = '${_app?['url'] ?? '${DownloadCenterTile._base}/thirdhub-app.apk'}';
    final backendUrl = '${_backend?['url'] ?? '${DownloadCenterTile._base}/thirdhub-backend.apk'}';
    final ev = '${_engine?['version'] ?? ''}';
    final vv = '${_venera?['version'] ?? ''}';
    final engineUrl = '${_engine?['url'] ?? '${DownloadCenterTile._base}/thirdhub-engine.apk'}';
    final veneraUrl = '${_venera?['url'] ?? '${DownloadCenterTile._base}/thirdhub-venera.apk'}';
    // 前端/后端条目按清单实时显示版本号(其余条目保持静态)
    final items = [
      ('第三方聚合', 'Flutter 纯播放器前端(本应用) · 最新 ${av.isEmpty ? '读取中…' : 'v$av'}', appUrl, Icons.phone_android,
        '聚合 AI 对话 / 小说 / 漫画 / 视频 / 音乐 / 直播 / 相册 / 文件管理器。纯播放器设计, 不内置任何源, 通过后端与引擎获取内容。'),
      ('第三方后端', '手机内嵌 Node.js 后端 · 最新 ${bv.isEmpty ? '读取中…' : 'v$bv'}', backendUrl, Icons.dns,
        '在手机上运行的资源库后端: 内容源引擎 + 局域网共享 + TLS 加密。装好后前端自动发现。登录同一账号后, 后端设备跟随账号云端找回。'),
      ...DownloadCenterTile.products.skip(2),
    ];
    return Column(children: [
      // 账号体系状态条: 前后端共用「第三方聚合」Supabase 账号
      Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Row(children: [
        Icon(Cloud.loggedIn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, size: 14,
          color: Cloud.loggedIn ? Colors.green : Colors.grey),
        const SizedBox(width: 6),
        Expanded(child: Text(
          Cloud.loggedIn
            ? '已登录 ${Cloud.email} · 前后端同一账号体系, 数据互通'
            : '未登录 · 登录「第三方聚合」账号后, 后端设备绑定与数据自动云端同步',
          style: const TextStyle(fontSize: 10, color: Colors.grey))),
      ])),
      for (final p in items)
        ListTile(dense: true, leading: Icon(p.$4, size: 20),
          title: Text(p.$1, style: const TextStyle(fontSize: 13)),
          subtitle: Text(p.$2, style: const TextStyle(fontSize: 10)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ProductDetailPage(name: p.$1, sub: p.$2, url: p.$3, icon: p.$4, desc: p.$5)))),
      if (admin) ...[
        ListTile(dense: true, leading: const Icon(Icons.menu_book, size: 20),
          title: const Text('开源阅读引擎', style: TextStyle(fontSize: 13)),
          subtitle: Text('THP 直连 · 最新 ${ev.isEmpty ? '读取中…' : 'v$ev'}', style: const TextStyle(fontSize: 10)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ProductDetailPage(
            name: '开源阅读引擎${ev.isEmpty ? '' : ' v$ev'}', sub: 'Legado 书源引擎(THP 直连)', url: engineUrl, icon: Icons.menu_book,
            desc: '兼容"开源阅读"书源格式的独立引擎。匿名无鉴权, THP 协议局域网直连, 前端发现后即可搜书看书。')))),
        ListTile(dense: true, leading: const Icon(Icons.photo_library, size: 20),
          title: const Text('venera 漫画引擎', style: TextStyle(fontSize: 13)),
          subtitle: Text('THP 直连 · 最新 ${vv.isEmpty ? '读取中…' : 'v$vv'}', style: const TextStyle(fontSize: 10)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ProductDetailPage(
            name: 'venera 漫画引擎${vv.isEmpty ? '' : ' v$vv'}', sub: 'venera JS 漫画源引擎(THP 直连)', url: veneraUrl, icon: Icons.photo_library,
            desc: '兼容 venera JS 漫画源的独立引擎。支持图源 URL/代码导入、搜索聚合、探索发现页。THP 协议直连。')))),
      ],
    ]);
  }
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
      // ★4.44.0 下载物要能"离开这台设备"：直链在手机上没法传给家人，
      //   所以这一页除了下载按钮，还给二维码和分享图。
      const Padding(padding: EdgeInsets.fromLTRB(4, 20, 4, 4),
        child: Text('扫码安装 / 分享给家人', style: TextStyle(fontSize: 12, color: Colors.grey))),
      DownloadShareBlock(name: name, url: url, sub: sub),
    ]),
    bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(16),
      child: url.toLowerCase().endsWith('.apk')
        ? FilledButton.icon(icon: const Icon(Icons.download), label: const Text('下载软件'),
            onPressed: () => Updater.downloadProduct(c, url, name))
        : FilledButton.icon(icon: const Icon(Icons.open_in_new),
            label: Text(url.contains('pages.dev') ? '打开网页版' : '获取(浏览器打开/下载)'),
            onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)))));
}

// ═══ 自动更新: 公告 → 点击下载 → 拉取安装(覆盖安装保留数据) ═══
// 更新历史**不再打进安装包**：点开「更新历史」时才从云端按需拉取
// （数据层见 core/changelog.dart 与 ChangelogPanel）。分级可见由服务端
// RLS 强制 —— 公开段人人可读，4.0 之前的全部历史仅管理员账号可读。
class Updater {
  // ★ 版本号唯一来源 = core/app_version.dart。
  //   4.40.0 时这里漏改，导致装了新版仍被判成旧版、反复弹升级提示。别再写死字面量。
  static const String currentVersion = kAppVersion;
  static const int currentCode = kAppCode;
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
    // 已有该版本安装包 → 按钮变「立即安装」, 不重复下载
    final localApk = await _findLocalApk(ver);
    if (!c.mounted) return;
    final go = await showDialog<bool>(context: c, builder: (c2) {
      // 小屏适配: 内容限高可滚动, 按钮区永远可见不被挤出
      final maxH = MediaQuery.sizeOf(c2).height * 0.5;
      return AlertDialog(
        title: Text('发现新版本 v$ver'),
        content: ConstrainedBox(constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (notes.isNotEmpty) Text(notes, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Text(localApk != null ? '已下载过该版本安装包, 可直接安装(覆盖安装数据保留)' : '覆盖安装, 数据自动保留',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('稍后')),
          TextButton(onPressed: () { Navigator.pop(c2, false); launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); }, child: const Text('浏览器下载')),
          FilledButton(onPressed: () => Navigator.pop(c2, true), child: Text(localApk != null ? '立即安装' : '立即更新'))]);
    });
    if (go == true) {
      if (localApk != null) { unawaited(OpenFilex.open(localApk)); return; }
      if (url.isNotEmpty && c.mounted) { newVer = ver; _downloadAndInstall(c, url); }
    }
  }
  static String newVer = '';

  // 多镜像: 主URL(云端) → Supabase版本包 → ghfast 镜像(GitHub) → GitHub 直链(国外线路兜底)
  // ★GitHub 直链对国内用户需要翻墙, 默认不放在前面——镜像优先, 直链仅作最后手段
  static List<String> _mirrorUrls(String url, String ver) {
    final list = <String>[url];
    if (ver.isNotEmpty) {
      list.add('https://mxvxlgjzeboktufumxbp.supabase.co/storage/v1/object/public/downloads/thirdhub-app-$ver.apk');
      const gh = 'https://github.com/Smalluniverseheng/ThirdHub-v2/releases/download';
      list.add('https://ghfast.top/$gh/v$ver/ThirdHub-$ver.apk');
      list.add('$gh/v$ver/ThirdHub-$ver.apk');
    }
    return list.toSet().toList();
  }

  // 在「已下载安装包」留档里找指定版本的现存文件, 找到返回路径(否则 null)
  static Future<String?> _findLocalApk(String ver) async {
    if (ver.isEmpty) return null;
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList('update_apks') ?? [];
    for (final e in list) {
      final parts = e.split('|');
      if (parts.length < 2) continue;
      if (parts[1].contains(ver) && await File(parts.first).exists()) return parts.first;
    }
    return null;
  }

  // 单镜像下载到文件, 支持断点续传: .part 临时文件 + .meta 记录 url/总长。
  // 同 URL 中断重下 → 发 Range: bytes=pos- 续传; 服务器不认 Range(200) → 从头重写;
  // 换镜像(URL 变了) → 旧进度作废从零开始。progress = 0..1。
  static Future<void> _fetchTo(String url, File f, ValueNotifier<double> progress) async {
    final part = File('${f.path}.part');
    final meta = File('${f.path}.part.meta');
    final client = HttpClient();
    try {
      var pos = 0;
      var total = 0;
      if (await part.exists() && await meta.exists()) {
        final m = (await meta.readAsString()).split('\n');
        if (m.isNotEmpty && m[0] == url) {
          pos = await part.length();
          if (m.length > 1) total = int.tryParse(m[1]) ?? 0;
        } else {
          try { await part.delete(); } catch (_) {}
        }
      }
      if (pos > 0 && total > 0) progress.value = pos / total;
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (pos > 0) req.headers.add('Range', 'bytes=$pos-');
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final status = resp.statusCode;
      if (status != 200 && status != 206) throw Exception('HTTP $status');
      if (status == 206 && pos == 0) throw Exception('服务器 Range 响应异常');
      final append = status == 206;
      if (!append) pos = 0; // 200 = 全量重发
      final contentLen = resp.contentLength; // 206 时是剩余字节数, 200 时是全长
      if (contentLen > 0) total = append ? pos + contentLen : contentLen;
      try { await meta.writeAsString('$url\n$total'); } catch (_) {}
      final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var got = 0;
      await for (final chunk in resp) {
        sink.add(chunk); got += chunk.length;
        if (total > 0) progress.value = (pos + got) / total;
      }
      await sink.close();
      final len = await part.length();
      if (total > 0 && len != total) throw Exception('文件不完整($len/$total)');
      if (len < 1024 * 1024) { try { await part.delete(); } catch (_) {} throw Exception('文件过小($len字节), 疑似错误页'); }
      await part.rename(f.path);
      try { await meta.delete(); } catch (_) {}
    } finally { client.close(); }
  }

  // 后台下载时把进度同步到通知栏(800ms 节流); 返回清理函数(完成后调用撤掉进度条)
  static void Function() _bgProgressNotify(ValueNotifier<double> progress, int notifId, String title) {
    var lastPush = 0;
    void push() {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastPush < 800) return;
      lastPush = now;
      final v = progress.value;
      unawaited(Notify.progress(notifId, title, v > 0 ? '${(v * 100).toStringAsFixed(0)}%' : '连接中…',
        value: (v * 100).round(), indeterminate: v <= 0));
    }
    progress.addListener(push);
    return () { progress.removeListener(push); unawaited(Notify.cancelProgress(notifId)); };
  }

  // 通用产品下载(下载中心用): 进度弹窗 + 后台下载 + 完成通知 + 留档
  static Future<void> downloadProduct(BuildContext c, String url, String name) async {
    // 去重: 已有同版本安装包 → 直接安装, 不重复下载
    final vm0 = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(name);
    final exist = await _findLocalApk(vm0?.group(1) ?? '');
    if (exist != null && c.mounted) {
      final r0 = await showDialog<String>(context: c, builder: (c2) => AlertDialog(
        title: const Text('已下载过该版本'),
        content: const Text('检测到本地已存在该版本的安装包, 可直接安装(覆盖安装数据保留)'),
        actions: [TextButton(onPressed: () => Navigator.pop(c2, 'redl'), child: const Text('重新下载')),
          FilledButton(onPressed: () => Navigator.pop(c2, 'install'), child: const Text('直接安装'))]));
      if (r0 == 'install') { unawaited(OpenFilex.open(exist)); return; }
      if (r0 == null) return;
    }
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
      final stopNotify = _bgProgressNotify(progress, 88003, '正在下载 $name');
      try {
        for (var i = 0; i < mirrors.length && !ok; i++) {
          try {
            if (i > 0 && c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('主线路失败, 切换镜像 ${i + 1}/${mirrors.length}…')));
            progress.value = 0;
            await _fetchTo(mirrors[i], f, progress);
            ok = true;
          } catch (e) { lastErr = e is Exception ? e : Exception('$e'); }
        }
      } finally { stopNotify(); }
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
      final stopNotify = _bgProgressNotify(progress, 88002, '正在下载更新 v$newVer');
      try {
        for (var i = 0; i < mirrors.length && !ok; i++) {
          try {
            if (i > 0 && c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('主线路失败, 切换镜像 ${i + 1}/${mirrors.length}…')));
            progress.value = 0;
            await _fetchTo(mirrors[i], f, progress);
            ok = true;
          } catch (e) { lastErr = e is Exception ? e : Exception('$e'); }
        }
      } finally { stopNotify(); }
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
  // 批量管理(规划 R-6): 长按进多选 → 批量删除
  bool selecting = false; final Set<String> sel = {};
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await LocalLib.list('novel'); setState(() => loading = false); }

  Future<void> _batchDelete() async {
    if (sel.isEmpty) return;
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: Text('删除 ${sel.length} 本书?'),
      content: const Text('从书架移除(不删本地文件)'),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('删除'))]));
    if (ok != true) return;
    for (final path in sel) { await LocalLib.remove('novel', path); }
    setState(() { selecting = false; sel.clear(); });
    _load();
  }

  // 编辑书籍(学开源阅读): 书名/作者/封面, 封面从相册选并复制到书籍同目录持久保存
  Future<void> _editBook(Map<String, dynamic> b) async {
    final nameC = TextEditingController(text: '${b['name'] ?? ''}');
    final authorC = TextEditingController(text: '${b['author'] ?? ''}');
    String? cover = (b['cover'] ?? '').toString().isEmpty ? null : b['cover'].toString();
    final ok = await showDialog<bool>(context: context, builder: (c2) => StatefulBuilder(builder: (c3, setD) => AlertDialog(
      title: const Text('编辑书籍'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GestureDetector(onTap: () async {
              final r = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
              if (r != null) {
                try {
                  final dst = File('${File(b['path']).parent.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
                  await File(r.path).copy(dst.path);
                  cover = dst.path;
                } catch (_) { cover = r.path; }
                setD(() {});
              }
            }, child: Container(width: 56, height: 76, decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(6)),
              clipBehavior: Clip.antiAlias, child: cover != null ? Image.file(File(cover!), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.add_photo_alternate_outlined, size: 26, color: Colors.grey))
                : const Icon(Icons.add_photo_alternate_outlined, size: 26, color: Colors.grey))),
          const SizedBox(width: 12),
          Expanded(child: Column(children: [
            TextField(controller: nameC, decoration: const InputDecoration(labelText: '书名', isDense: true)),
            const SizedBox(height: 8),
            TextField(controller: authorC, decoration: const InputDecoration(labelText: '作者(可空)', isDense: true)),
          ])),
        ]),
        if (cover != null) Align(alignment: Alignment.centerRight,
          child: TextButton(onPressed: () { cover = null; setD(() {}); }, child: const Text('清除封面'))),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c3, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c3, true), child: const Text('保存'))])));
    if (ok == true) {
      final name = nameC.text.trim();
      await LocalLib.updateMeta('novel', b['path'], {
        if (name.isNotEmpty) 'name': name,
        'author': authorC.text.trim(),
        'cover': cover,
      });
      _load();
    }
    nameC.dispose(); authorC.dispose();
  }

  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(
    title: Text(selecting ? '已选 ${sel.length} 本' : '本地小说'),
    actions: selecting ? [
      TextButton(onPressed: () => setState(() { sel..clear()..addAll(items.map((e) => '${e['path']}')); }),
        child: const Text('全选')),
      TextButton(onPressed: _batchDelete, child: const Text('删除', style: TextStyle(color: Colors.redAccent))),
      TextButton(onPressed: () => setState(() { selecting = false; sel.clear(); }), child: const Text('取消')),
    ] : [
    IconButton(icon: const Icon(Icons.library_add_check_outlined), tooltip: '批量管理',
      onPressed: () => setState(() => selecting = true)),
    IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await importWithChoice(c, 'novel') ?? 0;
      ScaffoldMessenger.of(c).showSnackBar(importSnack(n, '本')); _load(); })]),
    body: loading ? const Center(child: CircularProgressIndicator())
      : items.isEmpty ? const Center(child: Text('还没有本地小说\n点右上角 + 导入 txt / epub', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: items.length, itemBuilder: (_, i) { final b = items[i];
        final cov = (b['cover'] ?? '').toString();
        final author = (b['author'] ?? '').toString();
        final path = '${b['path'] ?? ''}';
        final checked = sel.contains(path);
        return ListTile(leading: selecting
          ? Icon(checked ? Icons.check_circle : Icons.radio_button_unchecked,
              color: checked ? Theme.of(c).colorScheme.primary : Colors.grey)
          : ClipRRect(borderRadius: BorderRadius.circular(4),
            child: cov.isNotEmpty && File(cov).existsSync()
              ? Image.file(File(cov), width: 38, height: 52, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.menu_book, size: 30))
              : const Icon(Icons.menu_book, size: 30)),
          title: Text(b['name'] ?? ''), subtitle: Text('${author.isNotEmpty ? '$author · ' : ''}${b['format'] ?? 'txt'} · 本地', style: const TextStyle(fontSize: 11)),
          onTap: () {
            if (selecting) { setState(() { if (checked) { sel.remove(path); } else { sel.add(path); } }); return; }
            Navigator.push(c, MaterialPageRoute(builder: (_) => LocalNovelReader(book: b)));
          },
          onLongPress: () { if (!selecting) setState(() { selecting = true; sel.add(path); }); },
          trailing: selecting ? null : Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _editBook(b)),
            IconButton(icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async { await LocalLib.remove('novel', b['path']); _load(); })])); }));
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
      // 统一走 LocalLib: 自动识别 UTF-8/GBK/UTF-16(带缓存, 翻章不重读)
      raw = await LocalLib.readNovelChapters(widget.book['path']);
      if (raw.isEmpty || (raw.length == 1 && raw[0].trim().isEmpty)) raw = ['(空文件)'];
    } catch (e) { raw = ['读取失败: $e']; }
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
        // 命中缓存: 不再重复读文件
        final raw = await LocalLib.readNovelChapters(widget.book['path']);
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
    IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await importWithChoice(c, 'video') ?? 0;
      ScaffoldMessenger.of(c).showSnackBar(importSnack(n, '个')); _load(); })]),
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
  // 外挂字幕: 同目录同前缀的 srt/vtt/ass 自动挂上, 可在右上角切换或关闭
  List<String> _subs = <String>[];
  List<Cue> _cues = <Cue>[];
  int _subIdx = -1;            // -1 = 关闭字幕; 否则为 _subs 的下标
  String _cueText = '';
  Timer? _cueTimer;
  // 画中画: 系统是否支持 / 上次同步给原生侧的播放状态(变化才过通道, 避免每帧都走 JNI)
  bool _pipOk = false; bool _pipLastPlaying = false;
  int _pipGen = 0;   // 本次「允许自动进画中画」声明的代，dispose 时按代释放

  /// 当前片源的宽高比。初始化之前统一按 16:9 报给系统——未初始化时 aspectRatio
  /// 读出来是 1.0，直接传进去会让画中画小窗变成正方形。
  double get _aspect {
    final c = ctrl;
    if (c == null || !c.value.isInitialized) return 16 / 9;
    final a = c.value.aspectRatio;
    return a > 0 ? a : 16 / 9;
  }

  @override void initState() { super.initState(); _init();
    Recents.add('video', '${widget.item['name'] ?? ''}', target: '${widget.item['path'] ?? ''}'); }
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
      _setupPip();
      _posTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (ctrl != null && ctrl!.value.isPlaying) AppSettings.p.setInt(_posKey, ctrl!.value.position.inSeconds);
      });
      // 字幕: 落盘时和视频同前缀, 这里按前缀把同目录的字幕都找出来
      _subs = await LocalLib.findSubtitles('${widget.item['path']}');
      if (_subs.isNotEmpty) await _pickSub(0);
      setState(() {});
    } catch (e) { setState(() => err = '$e'); }
  }

  // ═══ 画中画 ═══
  // 这里只负责「声明状态 + 接按钮」；真正缩窗由 MainActivity 做（Flutter 没有该 API）。
  Future<void> _setupPip() async {
    _pipOk = await Pip.supported();
    // PiP 小窗里那颗播放/暂停按钮按下去会回到这里
    Pip.onToggle = () {
      final c = ctrl;
      if (c == null || !c.value.isInitialized) return;
      c.value.isPlaying ? c.pause() : c.play();
    };
    ctrl?.addListener(_onPipTick);
    if (!mounted) return;
    setState(() {});
    if (!_pipOk) return;
    // 声明「正在放视频」：此后按 Home 会自动缩成小窗
    _pipGen = await Pip.claimAuto(aspect: _aspect, playing: ctrl?.value.isPlaying ?? false);
  }

  /// 播放/暂停一变就刷新小窗里的按钮图标。只在真正变化时过通道。
  void _onPipTick() {
    final c = ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying == _pipLastPlaying) return;
    _pipLastPlaying = c.value.isPlaying;
    Pip.updatePlaying(_pipLastPlaying);
  }

  /// 装载第 [i] 条字幕并开始跟随播放进度。
  /// 解析失败时清空字幕并保持视频照常播放——字幕不该拖垮播放。
  Future<void> _pickSub(int i) async {
    _cueTimer?.cancel();
    _cues = <Cue>[];
    _cueText = '';
    if (i < 0 || i >= _subs.length) { if (mounted) setState(() => _subIdx = -1); return; }
    try {
      final raw = await File(_subs[i]).readAsBytes();
      final text = LocalLib.decodeText(raw);
      final ext = _subs[i].split('.').last;
      _cues = MediaFormats.parseSubtitle(text, ext);
    } catch (_) {
      _cues = <Cue>[];
    }
    if (!mounted) return;
    setState(() => _subIdx = _cues.isEmpty ? -1 : i);
    if (_cues.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这条字幕没解析出内容: ${_subs[i].split('/').last}')));
      return;
    }
    // 200ms 一次足够跟手, 又不会像监听器那样每帧都重建
    _cueTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final vc = ctrl;
      if (vc == null || !vc.value.isInitialized) return;
      final pos = vc.value.position;
      String t = '';
      for (final c in _cues) { if (c.covers(pos)) { t = c.text; break; } }
      if (t != _cueText && mounted) setState(() => _cueText = t);
    });
  }

  /// 切换字幕的弹层: 关 / 自动找到的每一条。
  void _pickSubSheet() {
    if (_subs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没找到外挂字幕。把 srt/vtt/ass 放在视频同目录、与视频同名即可自动识别')));
      return;
    }
    showModalBottomSheet(context: context, showDragHandle: true, builder: (c2) => SafeArea(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.only(bottom: 4),
          child: Text('字幕', style: TextStyle(fontWeight: FontWeight.bold))),
        ListTile(dense: true, leading: const Icon(Icons.subtitles_off, size: 20), title: const Text('关闭字幕'),
          trailing: _subIdx < 0 ? const Icon(Icons.check, size: 18) : null,
          onTap: () { Navigator.pop(c2); _pickSub(-1); }),
        for (var i = 0; i < _subs.length; i++)
          ListTile(dense: true, leading: const Icon(Icons.subtitles, size: 20),
            title: Text(_subs[i].split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: _subIdx == i ? const Icon(Icons.check, size: 18) : null,
            onTap: () { Navigator.pop(c2); _pickSub(i); }),
        const SizedBox(height: 6),
      ])));
  }

  @override void dispose() { _posTimer?.cancel(); _hintTimer?.cancel(); _cueTimer?.cancel();
    // 离开视频页必须收回「允许自动进画中画」——不收回的话，在列表页按 Home 也会缩窗。
    // 这里不能 await（dispose 是同步的），但通道调用是即发即走，原生侧不依赖返回值。
    // 按「代」释放：切集是 pushReplacement，旧页 dispose 可能晚于新页声明，
    // 不带代就会把新页刚开的开关又关掉。
    Pip.releaseAuto(_pipGen);
    Pip.onToggle = null;
    Pip.inPip.value = false;
    ctrl?.removeListener(_onPipTick);
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

  /// 画中画里只该有画面本身——AppBar、播放条、双击提示都不该被缩进那个小窗。
  /// 不切布局的话，整个 App 界面会被等比缩成一个小方块，等于没法看。
  @override Widget build(BuildContext c) => ValueListenableBuilder<bool>(
        valueListenable: Pip.inPip,
        builder: (c, pip, _) => pip
            ? Scaffold(backgroundColor: Colors.black,
                body: Center(child: _videoArea(true)))
            : _buildFull(c),
      );

  Widget _buildFull(BuildContext c) {
    final Widget body = _videoArea(false);
    if (_fs) return Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Stack(children: [
      Center(child: body),
      Positioned(top: 4, left: 4, child: IconButton(icon: const Icon(Icons.fullscreen_exit, color: Colors.white), onPressed: _toggleFs)),
    ])));
    return Scaffold(appBar: AppBar(title: Text(widget.item['name'] ?? '', style: const TextStyle(fontSize: 14)),
      actions: [
        if (_pipOk) IconButton(icon: const Icon(Icons.picture_in_picture_alt, size: 20), tooltip: '画中画',
          onPressed: () async {
            final ok = await Pip.enter(aspect: _aspect, playing: ctrl?.value.isPlaying ?? false);
            if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('这台设备/当前状态进不了画中画')));
          }),
        IconButton(icon: Icon(_subIdx >= 0 ? Icons.subtitles : Icons.subtitles_off),
          tooltip: _subs.isEmpty ? '没有外挂字幕' : '字幕 (${_subs.length})', onPressed: _pickSubSheet),
        IconButton(icon: const Icon(Icons.fullscreen), tooltip: '横屏全屏', onPressed: _toggleFs),
      ]),
      body: Center(child: body));
  }

  /// 画面本身。系统解码器解不了的封装(部分 rmvb/wmv/老 avi 等)不吞错，给一条真正的出路。
  /// [pip] 为真时按小窗调尺寸——字幕贴底 56px 是为了躲开播放条，小窗里没有播放条。
  Widget _videoArea(bool pip) => err != null
      ? Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 10),
          const Text('这个文件系统解码器打不开', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('$err', style: const TextStyle(fontSize: 11, color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Wrap(spacing: 10, children: [
            FilledButton.icon(icon: const Icon(Icons.open_in_new, size: 18), label: const Text('用系统播放器打开'),
              onPressed: () => OpenFilex.open('${widget.item['path']}')),
            OutlinedButton(onPressed: () { setState(() => err = null); _init(); }, child: const Text('重试')),
          ]),
        ]))
      : chewie != null ? GestureDetector(
          onDoubleTapDown: (d) {
            final w = MediaQuery.of(context).size.width;
            _seekBy(d.globalPosition.dx < w / 2 ? -10 : 10);
          },
          onDoubleTap: () {},
          child: Stack(alignment: Alignment.center, children: [
            AspectRatio(aspectRatio: ctrl!.value.aspectRatio, child: Chewie(controller: chewie!)),
            if (_cueText.trim().isNotEmpty) Positioned(left: 12, right: 12, bottom: pip ? 10 : 56, child: IgnorePointer(
              child: Align(alignment: Alignment.bottomCenter, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6)),
                child: Text(_cueText, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35)))))),
            if (!pip && _seekHint.isNotEmpty) IgnorePointer(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(_seekHint, style: const TextStyle(color: Colors.white, fontSize: 14)))),
          ]))
      : const CircularProgressIndicator();
}

// ═══ 本地音乐库 ═══
class LocalMusicsPage extends StatefulWidget { const LocalMusicsPage({super.key}); @override State<LocalMusicsPage> createState() => _Lm(); }
class _Lm extends State<LocalMusicsPage> {
  List<Map<String, dynamic>> items = []; bool loading = true;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { items = await LocalLib.list('music'); setState(() => loading = false); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('本地音乐'), actions: [
    IconButton(icon: const Icon(Icons.add), onPressed: () async { final n = await importWithChoice(c, 'music') ?? 0;
      ScaffoldMessenger.of(c).showSnackBar(importSnack(n, '首')); _load(); })]),
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
      ScaffoldMessenger.of(c).showSnackBar(importSnack(n, '部')); _load(); })]),
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

// ═══════════════════════════════════════════════════════════════════════
// v4.40.0 进阶功能桥: core/ 层的功能页需要"宿主能力"(切模块/改主题/改字号/
// 把文本交给阅读器), 但 core 不该反向依赖 main.dart 的实现细节 —— 统一在这里注入。
// ═══════════════════════════════════════════════════════════════════════
/// AI 工具或系统页请求打开某个模块(由 RootNav 监听)
final ValueNotifier<String?> proOpenModule = ValueNotifier<String?>(null);

void registerProBridges() {
  // ── S-1 模块市场: 读写与首启引导同一份 nav_modules ──
  ProBridge.moduleKeys = () => kModules.keys.toList();
  ProBridge.navModules = () =>
      (AppSettings.p.getStringList('nav_modules') ?? <String>[]).toList();
  ProBridge.setNavModules = (l) async {
    final list = migrateModuleKeys(l);
    if (!list.contains('我的')) list.add('我的');
    await AppSettings.p.setStringList('nav_modules', list);
    RootNav.navTick.value = RootNav.navTick.value + 1; // 通知 RootNav 重新读取
  };

  // ── S-4 深色 / S-5 模式字号 ──
  ProBridge.themeMode = () => AppSettings.themeModeStr;
  ProBridge.setThemeMode = (m) => AppSettings.setThemeMode(m);
  ProBridge.textScale = () => AppSettings.p.getDouble('ui_text_scale') ?? 1.0;
  ProBridge.setTextScale = (v) async {
    await AppSettings.p.setDouble('ui_text_scale', v);
    AppSettings.onChanged?.call();
  };

  // ── P1 数据互通: 从云端拉下设置后重新生效（语言 / 主题 / 字号）──
  // settingsDown() 只写了 SharedPreferences，界面不会自己变；不接这个回调，
  // 用户会看到"提示同步成功但界面没动" —— 等于又一种假同步。
  ProBridge.reloadSettings = () async {
    await I18n.instance.setLocale(I18n.resolve(AppSettings.locale));
    AppSettings.onChanged?.call();
  };

  // ── Agent 控制面: 从任务页直接跳到「连接资源库」填后端地址 ──
  // 后端地址唯一的填写入口此前藏在「我的 → 系统 → 连接资源库」，用户在任务页
  // 看到「连不上」时只能自己去翻菜单 —— 现在任务页那颗「去填后端地址」按钮
  // 走这个钩子，一步到地方。用钩子是因为 ai_agent.dart 刻意不依赖 Flutter/main。
  AgentRuntime.openConnector = () async {
    final ctx = IntentRouter.navKey.currentContext;
    if (ctx == null) return;
    await Navigator.push(ctx, smoothRoute(const ConnectLibraryPage()));
    // 回来后立刻重新探测一次 —— 否则用户填完地址，任务页还是显示「连不上」，
    // 又会以为是没生效。
    try { await AgentRuntime.bootstrap(); } catch (_) {}
  };

  // ── AI-1 工具: 打开模块 / 把文本交给阅读器 ──
  ProBridge.openModule = (k) { proOpenModule.value = k; };
  ProBridge.openReader = (title, text) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/pro_${DateTime.now().millisecondsSinceEpoch}.txt');
    await f.writeAsString('$title\n\n$text', flush: true);
    final ctx = IntentRouter.navKey.currentContext;
    if (ctx == null) return;
    await Navigator.push(ctx, MaterialPageRoute(
      builder: (_) => LocalNovelReader(
        book: {'name': title.isEmpty ? '文本' : title, 'path': f.path, 'format': 'txt'})));
  };

  // ── B-2 译文页 → 小说阅读器(继承排版/听书/进度) ──
  ProBrowserBridge.handToReader = (c, title, text) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/trans_${DateTime.now().millisecondsSinceEpoch}.txt');
    await f.writeAsString('$title\n\n$text', flush: true);
    if (!c.mounted) return;
    await Navigator.push(c, MaterialPageRoute(
      builder: (_) => LocalNovelReader(
        book: {'name': title.isEmpty ? '译文' : title, 'path': f.path, 'format': 'txt'})));
  };
}

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
    // 下拉刷新: 更新历史是按需拉的, 给它一个顺手的手动重载入口
    body: RefreshIndicator(onRefresh: () async {
      final h = ChangelogPanel.refreshHook;
      if (h != null) await h();
    }, child: ListView(padding: EdgeInsets.all(ScreenFit.pad),
      // 内容不足一屏时也要能下拉, 否则刷不了更新历史
      physics: const AlwaysScrollableScrollPhysics(), children: [
      const Padding(padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Text('ThirdHub 全系列产品 · 点按查看详情与下载 · 覆盖安装数据保留', style: TextStyle(fontSize: 12, color: Colors.grey))),
      const Card(child: DownloadCenterTile()),
      // ★4.44.0 下载页多了一个真实用途：把 App 交给别人。
      //   直链在手机上没法递给家人（微信会拦、手打太长），所以这里给二维码和分享图。
      //   用**无版本别名** thirdhub-app.apk：扫码的一方永远拿到当前最新包，
      //   不会因为分享图在群里躺了半个月就装到旧版。
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('把 App 分享给家人', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          const Text('扫码直接下载最新版 · 或保存分享图发到群里', style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 10),
          DownloadShareBlock(
            name: '第三方聚合(ThirdHub)',
            url: '${DownloadCenterTile._base}/thirdhub-app.apk',
            sub: '全系列产品下载入口 · 覆盖安装数据保留',
            version: 'v${Updater.currentVersion}',
            compact: true,
          ),
        ]))),
      ),
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
      // 更新历史不随包下发: 点开这一页时才去云端拉, 折叠展开
      const ChangelogPanel(),
    ])));
}

/// 「全部更新历史」独立页。
///
/// 入口在任意模块菜单里。之所以要单独一页、而不是让用户去下载页翻：
/// 下载页是"我要装东西"的地方，更新历史是"我想看改了什么"的地方，
/// 两种意图混在同一屏，用户会找不到。
///
/// 刷新走 [GlobalKey] 直连自己那份面板的 `_load`，**不经过** [ChangelogPanel] 的
/// 静态 hook —— 否则它会顶掉下载页那份、并在本页 dispose 时把对方清空。
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  final GlobalKey<_ChangelogPanelState> _panelKey = GlobalKey<_ChangelogPanelState>();

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('全部更新历史')),
      body: RefreshIndicator(
        onRefresh: () async {
          await _panelKey.currentState?._load(force: true);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: <Widget>[ChangelogPanel(key: _panelKey, ownRefresh: true)],
        ),
      ),
    );
  }
}

/// 更新历史面板。
///
/// 设计取舍：
///  * **按需拉取** —— 四代累计的记录有数千行，塞进安装包只会让包体变大、启动变慢；
///    这里点开才拉一次，之后走本地缓存（离线也能看）。
///  * **分级可见** —— 普通账号看 4.0 之后；管理员多一个「全部历史」档看到更早的记录。
///    权限由服务端 RLS 强制，这一层只管要不要显示入口。
///  * **逐版本折叠** —— 默认全收起，副标题给两行摘要，需要时再展开看全。
class ChangelogPanel extends StatefulWidget {
  const ChangelogPanel({super.key, this.ownRefresh = false});

  /// true = 这一份自己管刷新，不碰全局 [refreshHook]。
  ///
  /// 下载页那一份把刷新函数挂到静态 hook 上，供页面级下拉刷新调用（面板自己
  /// 不是滚动容器）。但「全部更新历史」页是独立路由 —— 两份面板同时躺在导航栈
  /// 上时，共用一个静态字段会互相覆盖，且**先建的那份 dispose 时会把 hook 清成
  /// null**，回到下载页后下拉刷新就静默失效。所以独立页这份用 ownRefresh 退出
  /// 这套全局约定，自己挂 RefreshIndicator。
  final bool ownRefresh;

  /// 面板把自己刷新函数挂出来，供页面级下拉刷新调用（面板本身不是滚动容器）。
  static Future<void> Function()? refreshHook;

  @override State<ChangelogPanel> createState() => _ChangelogPanelState();
}

class _ChangelogPanelState extends State<ChangelogPanel> {
  bool _full = false;          // false=近期(4.0 之后)  true=全部历史(仅管理员)
  bool _loading = true;
  bool _refreshing = false;
  bool _fromCache = false;
  String _err = '';
  String _latestVer = '';
  String _latestUrl = '';
  ClogDoc? _doc;

  @override void initState() {
    super.initState();
    if (!widget.ownRefresh) ChangelogPanel.refreshHook = () => _load(force: true);
    _load();
  }

  @override void dispose() {
    // ★ 只清自己挂的那一个：ownRefresh 的实例从没写过 hook，若它也执行清空，
    //   就会把下载页那份挂着的刷新函数抹掉。
    if (!widget.ownRefresh && ChangelogPanel.refreshHook != null) ChangelogPanel.refreshHook = null;
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    if (mounted) setState(() { _loading = _doc == null; _refreshing = _doc != null; });
    // 顺带拿一次最新清单，用来标记"可下载的版本"
    try {
      final m = await Cloud.latestManifest('app');
      if (m != null) { _latestVer = (m['version'] as String?) ?? ''; _latestUrl = (m['url'] as String?) ?? ''; }
    } catch (_) {}
    final r = await ChangelogStore.load(admin: _full, force: force, onRemote: (ClogDoc d) {
      // 后台拉到比当前展示的更新的数据时, 当场换上去(不再等下次打开)
      if (!mounted) return;
      final cur = _doc;
      if (cur == null || d.latest != cur.latest || d.updated != cur.updated) {
        setState(() { _doc = d; _fromCache = false; _err = ''; });
      }
    });
    if (!mounted) return;
    setState(() {
      _loading = false; _refreshing = false;
      if (r.doc != null) _doc = r.doc;
      _fromCache = r.fromCache;
      _err = r.error;
    });
  }

  Future<void> _switch(bool full) async {
    if (_full == full) return;
    setState(() { _full = full; _doc = null; _err = ''; _loading = true; });
    await _load(force: true);
  }

  @override Widget build(BuildContext context) {
    final p = NeuPalette.of(context);
    final ClogDoc? doc = _doc;
    final bool isAdmin = ChangelogStore.isAdmin;
    final String cur = 'v${Updater.currentVersion}';

    return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ── 头部: 范围切换 + 刷新 ──
      Padding(padding: const EdgeInsets.fromLTRB(12, 10, 6, 4), child: Row(children: [
        Text('更新历史', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.text)),
        const SizedBox(width: 8),
        if (isAdmin)
          Expanded(child: SegmentedButton<bool>(showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: false, label: Text('近期', style: TextStyle(fontSize: 10))),
              ButtonSegment<bool>(value: true, label: Text('全部历史', style: TextStyle(fontSize: 10))),
            ],
            selected: <bool>{_full},
            onSelectionChanged: (Set<bool> s) => _switch(s.first)))
        else
          const Spacer(),
        IconButton(visualDensity: VisualDensity.compact, tooltip: '刷新',
          icon: _refreshing
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.refresh, size: 18),
          onPressed: _refreshing ? null : () => _load(force: true)),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 8), child: Text(
        _subtitleText(doc, isAdmin, cur),
        style: TextStyle(fontSize: 10.5, color: p.sub))),

      if (_loading)
        const Padding(padding: EdgeInsets.symmetric(vertical: 22),
          child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))
      else if (doc == null || doc.entries.isEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(14, 6, 14, 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_err.isEmpty ? '暂时拿不到更新记录' : _err, style: const TextStyle(fontSize: 12, color: Colors.orange)),
          const SizedBox(height: 6),
          const Text('下拉此页即可重试；更新记录不随安装包下发，需要联网获取。',
            style: TextStyle(fontSize: 10.5, color: Colors.grey)),
        ]))
      else ...[
        for (final ClogEntry e in doc.entries)
          _entryTile(e, cur),
        const SizedBox(height: 6),
      ],
    ]));
  }

  String _subtitleText(ClogDoc? doc, bool isAdmin, String cur) {
    if (doc == null) return isAdmin ? '可切换查看全部历史' : '仅显示 4.0 之后的记录';
    final String scope = _full ? '全部历史（含 4.0 之前，仅管理员可见）' : '4.0 之后的记录';
    final String src = _fromCache ? '本地缓存' : '已同步';
    final String upd = doc.updated.isEmpty ? '' : ' · ${doc.updated}';
    return '$scope · 共 ${doc.entries.length} 个版本 · $src$upd'
        '${_err.isNotEmpty ? ' · ${_err}' : ''}';
  }

  /// 版本串归一：`v4.25.0` / `4.25.0` / 带空格 都归一成 `4.25.0`。
  ///
  /// 云端记录里 `v` 字段不带 `v` 前缀，而界面别处带前缀；直接比字符串会让
  /// 「当前版本」标签与「可下载」按钮永远不出现——这种静默不匹配最难发现。
  static String _normVer(String v) => v.trim().replaceFirst(RegExp(r'^[vV]'), '');

  Widget _entryTile(ClogEntry e, String cur) {
    final String ev = _normVer(e.v);
    final String cv = _normVer(cur);
    final String lv = _normVer(_latestVer);
    final bool isCur = ev.isNotEmpty && ev == cv;
    final bool isLatest = ev.isNotEmpty && ev == lv;
    final bool canDown = _latestUrl.isNotEmpty && isLatest && !isCur &&
        Updater._verCmp(lv, cv) > 0;
    return Theme(
      // 去掉 ExpansionTile 展开时的分隔线，保持卡片干净
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: const Icon(Icons.history, size: 18),
        title: Row(children: [
          Text(ev.isEmpty ? e.v : ev, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          if (isCur) _tag('当前版本', Colors.green),
          if (isLatest && !isCur) _tag('最新', Colors.blueAccent),
          if (e.tag.isNotEmpty) _tag(e.tag, e.tag == '重构' ? Colors.deepOrange : Colors.purple),
        ]),
        // 收起时的两行摘要，不展开也能知道这版干了什么
        subtitle: Text(e.items.isEmpty ? '' : e.items.first,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        children: <Widget>[
          for (final String it in e.items)
            Padding(padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 6, right: 6),
                  child: SizedBox(width: 4, height: 4, child: DecoratedBox(decoration: BoxDecoration(color: Colors.grey, shape: BoxShape.circle)))),
                Expanded(child: Text(it, style: const TextStyle(fontSize: 11.5, height: 1.5))),
              ])),
          if (canDown)
            Align(alignment: Alignment.centerLeft, child: FilledButton.tonal(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10)),
              onPressed: () => Updater.downloadProduct(context, _latestUrl, 'ThirdHub-$_latestVer.apk'),
              child: const Text('下载此版本', style: TextStyle(fontSize: 11)))),
        ],
      ),
    );
  }
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
  // 逐模块全屏开关（D-11）：列出全部已启用模块，每个可独立开关
  void _fsModuleSheet(BuildContext c) {
    showModalBottomSheet(context: c, isScrollControlled: true, builder: (c2) => StatefulBuilder(builder: (c2, setD) {
      final mods = kModules.keys.toList();
      return SafeArea(child: SizedBox(height: 460, child: Column(children: [
        const Padding(padding: EdgeInsets.all(12),
          child: Text('逐模块全屏开关', style: TextStyle(fontWeight: FontWeight.bold))),
        const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('进入模块后 N 秒无切换操作则收起底部导航进入全屏。在此关掉不需要全屏的模块。',
            style: TextStyle(fontSize: 11, color: Colors.grey))),
        Expanded(child: ListView(children: [
          for (final k in mods)
            SwitchListTile(dense: true,
              secondary: Icon(kModules[k]!.icon, size: 20),
              title: Text(tr(kModules[k]!.name), style: const TextStyle(fontSize: 13)),
              value: AppSettings.fsEnabledFor(k),
              onChanged: (v) { AppSettings.setFsEnabledFor(k, v).then((_) { setD(() {}); setState(() {}); }); }),
        ])),
      ])));
    }));
  }
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
        SwitchListTile(secondary: const Icon(Icons.swipe_right_alt, size: 20),
          title: const Text('左右滑动切换模块', style: TextStyle(fontSize: 14)),
          subtitle: const Text('在正文区横向滑动即可换模块; 关掉可避免与模块内部的横向手势互相干扰', style: TextStyle(fontSize: 11)),
          value: AppSettings.navSwipe,
          onChanged: (v) => AppSettings.setNavSwipe(v).then((_) { RootNav.navTick.value++; setState(() {}); })),
        const Divider(height: 1, indent: 56),
        // ── 自动全屏（D-11）──
        SwitchListTile(secondary: const Icon(Icons.fullscreen, size: 20),
          title: const Text('自动全屏', style: TextStyle(fontSize: 14)),
          subtitle: Text(AppSettings.autoFsSec > 0
            ? '进入模块 ${AppSettings.autoFsSec} 秒没有切换操作 → 收起底部导航进入全屏; 右上角可退出'
            : '已关闭', style: const TextStyle(fontSize: 11)),
          value: AppSettings.autoFsSec > 0,
          onChanged: (v) => AppSettings.setAutoFsSec(v ? 3 : 0).then((_) { RootNav.navTick.value++; setState(() {}); })),
        if (AppSettings.autoFsSec > 0) Padding(padding: const EdgeInsets.fromLTRB(56, 0, 16, 6), child: Row(children: [
          const Text('触发秒数', style: TextStyle(fontSize: 12)),
          Expanded(child: Slider(value: AppSettings.autoFsSec.toDouble(), min: 2, max: 10, divisions: 8,
            label: '${AppSettings.autoFsSec} 秒',
            onChanged: (v) => AppSettings.setAutoFsSec(v.round()).then((_) { RootNav.navTick.value++; setState(() {}); }))),
          Text('${AppSettings.autoFsSec} 秒', style: const TextStyle(fontSize: 12)),
        ])),
        if (AppSettings.autoFsSec > 0) ListTile(leading: const Icon(Icons.tune, size: 20),
          title: const Text('逐模块全屏开关', style: TextStyle(fontSize: 14)),
          subtitle: const Text('关闭后该模块不再自动进入全屏', style: TextStyle(fontSize: 11)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _fsModuleSheet(c)),
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
    '端网': '前端/后端/插件任意插线 · 端列表与跨端调用 · 密钥统一 · 无后端可直连 · 插件登录账号即接入',
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
          subtitle: const Text('各开源阅读、漫画与聚合方案的作者，以及全体开源社区', style: TextStyle(fontSize: 11))),
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
  bool shelved = false;
  @override void initState() { super.initState(); _load(); _markOpened(); }

  /// 把「引擎直连看的内容」也写进书架历史，并查一下它是否已在书架。
  ///
  /// 为什么必须补这一步：全项目**只有后端路径的详情页**（VideoDetailPage /
  /// ComicDetailPage）会写 history_*。走引擎的用户因此**永远进不了「片库 / 历史」**；
  /// 而那几个页面的空态还写着「搜索后进入详情页，点书签图标加入」—— 它指的就是本页，
  /// 可本页此前既没有书签按钮、也不写历史，用户照着做也做不到。
  Future<void> _markOpened() async {
    final k = widget.type;
    if (k != 'novel' && k != 'comic' && k != 'video' && k != 'music') return;
    try {
      await Book.recordHistory(Book(name, authorS, cover, introS, id, 'engine'), k);
    } catch (_) {}
    try {
      final l = await Book.shelf(k);
      if (mounted) setState(() => shelved = l.any((x) => x.bookUrl == id));
    } catch (_) {}
  }

  Future<void> _addShelf() async {
    if (shelved) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('它已经在书架里了')));
      return;
    }
    // target 固定 local：引擎直连的内容没有后端资源库条目，没必要往后端提交
    await Book.add(Book(name, authorS, cover, introS, id, 'engine'), widget.type,
        target: 'local');
    if (!mounted) return;
    setState(() => shelved = true);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已加入书架')));
  }
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
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
    actions: [
      // 引擎条目此前没有任何收藏入口 —— 而「片库 / 历史」的空态正是叫用户
      // 来这里点书签。补上它，那句引导才成立。
      if (widget.type == 'novel' || widget.type == 'comic' || widget.type == 'video' || widget.type == 'music')
        IconButton(
          icon: Icon(shelved ? Icons.bookmark : Icons.bookmark_border, size: 21),
          tooltip: shelved ? '已在书架' : '加入书架',
          onPressed: _addShelf),
    ]),
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


// ═══ ★4.44.0 退出全屏悬浮球：可随意拖动、记住位置 ═══
//
// 旧实现把退出全屏按钮**钉死在右上角**（`Positioned(top:0, right:8)`）。
// 全屏本来就是"想专心看内容"的状态，而这个按钮正好压在右手拇指最常滑动的
// 区域上 —— 用户反馈"会挡住手"。现在改成和导航悬浮球同款的手势：
//   · 按住拖动 → 停哪放哪（不强制吸边，满足"随意拖动"）
//   · 位置写进设置，下次进全屏还在原地
//   · 不拖动时半透明（0.5），拖动中变实心并放大一点，看得见手在哪
//   · 长按可复位回右上角默认位（拖动后找不到它时的退路）
class FsExitOrb extends StatefulWidget {
  const FsExitOrb({super.key});
  @override State<FsExitOrb> createState() => _FsExitOrbState();
}

class _FsExitOrbState extends State<FsExitOrb> {
  static const double sz = 44;
  Offset _pos = const Offset(-1, -1);
  bool _drag = false;

  @override void initState() { super.initState(); _pos = AppSettings.fsOrbPos; }

  void _clampInto(Size screen, EdgeInsets pad) {
    final mx = (screen.width - sz).clamp(0.0, double.infinity);
    final my = (screen.height - sz).clamp(0.0, double.infinity);
    _pos = Offset(_pos.dx.clamp(0.0, mx), _pos.dy.clamp(pad.top + 4, my));
  }

  @override Widget build(BuildContext c) {
    final screen = MediaQuery.of(c).size;
    final pad = MediaQuery.of(c).padding;
    if (_pos.dx < 0) {
      // 首次（或用户复位后）：右上角，与旧行为一致
      _pos = Offset(screen.width - sz - 12, pad.top + 8);
    } else {
      _clampInto(screen, pad); // 屏幕旋转/换设备后保证还在可见范围内
    }
    return Positioned(
      left: _pos.dx, top: _pos.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _drag = true),
        onPanUpdate: (d) => setState(() {
          final mx = (screen.width - sz).clamp(0.0, double.infinity);
          final my = (screen.height - sz).clamp(0.0, double.infinity);
          _pos = Offset((_pos.dx + d.delta.dx).clamp(0.0, mx),
                        (_pos.dy + d.delta.dy).clamp(pad.top + 4, my));
        }),
        onPanEnd: (_) { setState(() => _drag = false); AppSettings.setFsOrbPos(_pos); },
        onPanCancel: () { setState(() => _drag = false); AppSettings.setFsOrbPos(_pos); },
        onTap: () {
          HapticFeedback.selectionClick();
          c.findAncestorStateOfType<_RootNavState>()?._exitFs();
        },
        onLongPress: () async {
          HapticFeedback.mediumImpact();
          await AppSettings.resetFsOrbPos();
          if (!mounted) return;
          setState(() => _pos = Offset(-1, -1)); // 回默认右上角
          if (mounted) {
            ScaffoldMessenger.maybeOf(c)?.showSnackBar(
              const SnackBar(content: Text('退出全屏按钮已复位到右上角'), duration: Duration(seconds: 2)));
          }
        },
        child: Tooltip(
          message: '退出全屏（可拖动 · 长按复位）',
          child: AnimatedScale(
            scale: _drag ? 1.12 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: sz, height: sz,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: _drag ? 0.78 : 0.5),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: _drag ? 0.55 : 0.25)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: _drag ? 12 : 6)]),
              child: Icon(_drag ? Icons.open_with : Icons.fullscreen_exit,
                color: Colors.white.withValues(alpha: _drag ? 1.0 : 0.9), size: 22)))),
      ));
  }
}

// ═══ 导航悬浮球: 可自由拖动/自动吸边, 点按弹出模块宫格(按屏宽自适应排布) ═══
class NavOrb extends StatefulWidget {
  const NavOrb({super.key});
  // 模块宫格: 悬浮球与折叠导航共用
  //
  // ★2026-09-19 三处修正（用户反馈：面板"不完全"/"不能再往上拉"/"长按应像桌面一样自由拖动"）：
  //   ① 旧实现 `showModalBottomSheet` 没开 `isScrollControlled` → 面板最高只有半屏，
  //      内容超出就被裁掉（后加的模块因此"里面都没有显示"），而且**根本拉不上去**。
  //      改为 isScrollControlled + DraggableScrollableSheet（可拖到 92% 高）。★
  //   ② 内容改为可滚动容器（吃 sheet 的 scrollController），模块再多也能看全。
  //   ③ 每格支持**长按拖动排序**（LongPressDraggable + DragTarget），松手即落位并持久化，
  //      与「我的 → 导航 → 底部导航栏」里的排序共用同一份 nav_modules。
  static void showModuleGrid(BuildContext c, List<String> enabled, int cur, void Function(int) onGo) {
    showModalBottomSheet(
      context: c,
      isScrollControlled: true,      // ★缺了它 = 拉不上去 + 内容被裁
      backgroundColor: Colors.transparent,
      builder: (c2) => DraggableScrollableSheet(
        initialChildSize: 0.58, minChildSize: 0.3, maxChildSize: 0.92, expand: false,
        builder: (_, sc) => _ModulePanel(scroll: sc, enabled: enabled, cur: cur, onGo: onGo)));
  }
  @override State<NavOrb> createState() => _NavOrbState();
}

/// 模块切换面板（可上拉 / 可滚动 / 长按拖动排序）。
///
/// 交互（照用户要求"像应用商店、像桌面布局"）：
///   · 点一下 → 直接跳到该模块（不经过中间的其它模块，不触发它们的加载）
///   · 长按 → 拿起（震动反馈）→ 拖到另一格上松手 → 落位，顺序立刻保存
///   · 整张面板可往上拖到 92% 高，内容可滚动，模块再多也不会被裁掉
class _ModulePanel extends StatefulWidget {
  final ScrollController scroll;
  final List<String> enabled;
  final int cur;
  final void Function(int) onGo;
  const _ModulePanel({required this.scroll, required this.enabled, required this.cur, required this.onGo});
  @override State<_ModulePanel> createState() => _ModulePanelState();
}

class _ModulePanelState extends State<_ModulePanel> {
  late List<String> order = [...widget.enabled];
  int? _dragging;   // 正在拖的格位
  int? _hover;      // 当前悬停到的格位（用于高亮落点）
  /// 左侧分类栏当前选中项。
  ///   '已启用' = 我的底部导航（保留长按拖动排序）；
  ///   其它 = 分类名 → 右侧列出该分类**全部**模块（含未启用的），可一键加入导航。
  String _rail = '已启用';

  @override void initState() { super.initState(); order = [...widget.enabled]; }

  /// 实际存在的分类（按 kCatOrder 排序，末尾补"其他"）
  List<String> get _cats {
    final seen = <String>{ for (final k in kModules.keys) moduleCat(k) };
    return [...kCatOrder.where(seen.contains), if (seen.contains('其他')) '其他'];
  }

  List<String> _modulesOf(String cat) =>
      [for (final e in kModules.entries) if (moduleCat(e.key) == cat) e.key];

  static IconData _catIcon(String cat) => switch (cat) {
    '已启用' => Icons.apps,
    '核心' => Icons.star_outline,
    '内容' => Icons.play_circle_outline,
    '生活' => Icons.coffee_outlined,
    '效率' => Icons.bolt_outlined,
    '家庭' => Icons.home_outlined,
    '实验室' => Icons.science_outlined,
    _ => Icons.folder_outlined,
  };

  Future<void> _persistNav(List<String> list) async {
    final out = [...list];
    if (!out.contains('我的')) out.add('我的');
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('nav_modules', out);
      RootNav.navTick.value++;   // 根导航即时重载
    } catch (_) {}
  }

  /// 分类视图里把模块加入/移出底部导航（→ 用户不用再翻设置页）
  Future<void> _toggleNav(String k, bool add) async {
    if (k == '我的') return;
    final list = [...order];
    if (add) {
      if (!list.contains(k)) {
        final at = list.contains('我的') ? list.indexOf('我的') : list.length;
        list.insert(at, k);
      }
    } else {
      list.remove(k);
    }
    setState(() => order = list);
    HapticFeedback.selectionClick();
    await _persistNav(list);
  }

  /// 落位：把 _dragging 移到 _hover。立刻写盘并通知根导航重载（与设置页共用 nav_modules）。
  Future<void> _drop(int to) async {
    final from = _dragging;
    setState(() { _dragging = null; _hover = null; });
    if (from == null || from == to) return;
    setState(() { final it = order.removeAt(from); order.insert(to, it); });
    HapticFeedback.mediumImpact();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('nav_modules', order);
      RootNav.navTick.value++;
    } catch (_) {}
  }

  Widget _tile(int i) {
    final k = order[i];
    final m = kModules[k];
    if (m == null) return const SizedBox.shrink();
    final on = i == widget.cur;
    final isHover = _hover == i && _dragging != null && _dragging != i;
    final scheme = Theme.of(context).colorScheme;
    final body = Container(
      decoration: BoxDecoration(
        color: on ? scheme.primaryContainer : null,
        borderRadius: BorderRadius.circular(14),
        border: isHover ? Border.all(color: scheme.primary, width: 2) : null),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(m.icon, size: 24, color: on ? scheme.primary : null),
        const SizedBox(height: 4),
        Text(tr(m.name), style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]));
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) { if (_hover != i) setState(() => _hover = i); return d.data != i; },
      onLeave: (_) { if (_hover == i) setState(() => _hover = null); },
      onAcceptWithDetails: (d) => _drop(i),
      builder: (_, __, ___) => LongPressDraggable<int>(
        data: i,
        delay: const Duration(milliseconds: 220),
        onDragStarted: () { HapticFeedback.selectionClick(); setState(() { _dragging = i; _hover = null; }); },
        onDraggableCanceled: (_, __) => setState(() { _dragging = null; _hover = null; }),
        onDragEnd: (_) => setState(() { _dragging = null; _hover = null; }),
        feedback: Material(color: Colors.transparent,
          child: SizedBox(width: 76, height: 84,
            child: Opacity(opacity: 0.9, child: Container(
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12)]),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(m.icon, size: 24, color: scheme.primary),
                const SizedBox(height: 4),
                Text(tr(m.name), style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]))))),
        childWhenDragging: Opacity(opacity: 0.25, child: body),
        child: InkWell(borderRadius: BorderRadius.circular(14),
          // 长按被拖动接管，所以点按只负责"直接跳过去"
          onTap: () { Navigator.pop(context); widget.onGo(i); },
          child: body)));
  }

  /// 左侧分类栏的一格（图标 + 名称 + 数量）
  Widget _railItem(String cat) {
    final on = _rail == cat;
    final scheme = Theme.of(context).colorScheme;
    final n = cat == '已启用' ? order.length : _modulesOf(cat).length;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () { HapticFeedback.selectionClick(); setState(() => _rail = cat); },
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        decoration: BoxDecoration(
          color: on ? scheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          Icon(_catIcon(cat), size: 18, color: on ? scheme.primary : Colors.grey),
          const SizedBox(height: 3),
          Text(cat, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5,
            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on ? scheme.primary : null)),
          Text('$n', style: const TextStyle(fontSize: 9, color: Colors.grey)),
        ])));
  }

  /// 分类视图里的一格：点开模块；右上角小按钮 = 加入/移出底部导航
  Widget _catTile(String k) {
    final m = kModules[k];
    if (m == null) return const SizedBox.shrink();
    final inNav = order.contains(k);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        // ★先取 Navigator 再 pop：pop 之后本 sheet 的 context 已失效
        final nav = Navigator.of(context);
        final i = widget.enabled.indexOf(k);
        nav.pop();
        if (i >= 0) { widget.onGo(i); return; }
        nav.push(smoothRoute(Scaffold(
          appBar: AppBar(title: Text(tr(m.name))), body: m.page)));
      },
      child: Stack(children: [
        Container(width: double.infinity, height: double.infinity,
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: inNav ? 0.55 : 0.12),
            borderRadius: BorderRadius.circular(14)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(m.icon, size: 24, color: inNav ? scheme.primary : null),
            const SizedBox(height: 4),
            Text(tr(m.name), style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
        Positioned(right: 0, top: 0, child: IconButton(
          tooltip: inNav ? '从底部导航移除' : '加入底部导航',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          icon: Icon(inNav ? Icons.check_circle : Icons.add_circle_outline,
            size: 16, color: inNav ? Colors.green : Colors.grey),
          onPressed: () => _toggleNav(k, !inNav))),
      ]));
  }

  @override Widget build(BuildContext c) {
    final w = MediaQuery.of(c).size.width;
    const railW = 76.0;
    final gap = 8.0;
    final contentW = w - 16 - railW - 8 - 16;          // 左内边距 + 栏宽 + 间隔 + 右内边距
    final cols = (contentW / 88).floor().clamp(2, 8);
    final tileW = (contentW - gap * (cols - 1)) / cols;
    final list = _rail == '已启用' ? order : _modulesOf(_rail);
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(c).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18))),
      child: Column(children: [
        // 拖动条（提示可上拉）
        Padding(padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Container(width: 36, height: 4, decoration: BoxDecoration(
            color: Theme.of(c).dividerColor, borderRadius: BorderRadius.circular(2)))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(children: [
            const Text('切换模块', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Expanded(child: Text(
              _rail == '已启用'
                ? '长按某格可拖动排序 · 共 ${order.length} 个'
                : '$_rail · ${list.length} 个模块 · 点右上角 ⊕ 加入导航',
              style: const TextStyle(fontSize: 10.5, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis)),
            IconButton(icon: const Icon(Icons.tune, size: 18), tooltip: '启用/停用模块',
              // 先取 Navigator 再 pop：pop 会把本 sheet 的 context 销毁，
              // 在销毁后的 context 上开对话框会抛 "Looking up a deactivated widget's ancestor"
              onPressed: () { final nav = Navigator.of(context); nav.pop(); showNavSettings(nav.context); }),
          ])),
        const SizedBox(height: 4),
        Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── 左侧：竖向分类栏 ──
          SizedBox(width: railW, child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(8, 2, 6, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _railItem('已启用'),
              const Divider(height: 14, indent: 4, endIndent: 4),
              for (final cat in _cats) _railItem(cat),
            ]))),
          const VerticalDivider(width: 1, thickness: 1),
          // ── 右侧：模块格 ──
          Expanded(child: SingleChildScrollView(
            controller: widget.scroll,     // ★吃 sheet 的控制器 → 面板仍能上拉、能滚动
            padding: EdgeInsets.fromLTRB(8, 4, 16, 16 + MediaQuery.of(c).viewPadding.bottom),
            child: Wrap(spacing: gap, runSpacing: gap, children: [
              if (_rail == '已启用')
                for (var i = 0; i < order.length; i++) SizedBox(width: tileW, height: 84, child: _tile(i))
              else
                for (final k in list) SizedBox(width: tileW, height: 84, child: _catTile(k)),
            ]))),
        ])),
      ]));
  }
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