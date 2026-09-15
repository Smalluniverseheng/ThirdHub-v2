// ThirdHub v4 Flutter m2: 纯播放器前端 = 小说阅读器 + 漫画播放器 + 视频播放器
// 定位: 零处理逻辑, 只渲染后端IR。净化在插件(Legado)完成, 后端转发。
// 每个板块右上角: [搜索] [设置→连接资源库]
import 'dart:async'; import 'dart:convert'; import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:image/image.dart' as img;
import 'core/neu.dart';
import 'core/i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.init();
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
}

// 全局设置中心: 所有前端设置唯一入口, 本地存储+云端同步(1MB配额)骨架
class AppSettings {
  static SharedPreferences? _p;
  static void Function()? onChanged; // 主题变更回调
  static Future<void> init() async { _p = await SharedPreferences.getInstance();
    I18n.instance.locale = p.getString('locale') ?? 'zh';
    if (p.getString('identity_code') == null) {
      final code = 'TH-' + DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()
        + '-' + (p.getString('nickname')?.hashCode ?? 0).toRadixString(36).toUpperCase();
      await p.setString('identity_code', code);
    } }
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
  static String get locale => p.getString('locale') ?? 'zh';
  static Future<void> setLocale(String v) async {
    await p.setString('locale', v); await I18n.instance.setLocale(v); await sync();
  }
  // ── 外观(网页版"我的"-主题外观) ──
  static String get themeModeStr => p.getString('theme_mode') ?? 'dark'; // system|dark|light
  static int get accentColor => p.getInt('accent_color') ?? 0xFF5B9BFF;   // 强调色
  static bool get splashAnim => p.getBool('splash_anim') ?? true;         // 开屏动画
  static Future<void> setThemeMode(String v) async { await p.setString('theme_mode', v); await sync(); onChanged?.call(); }
  static Future<void> setAccent(int v) async { await p.setInt('accent_color', v); await sync(); onChanged?.call(); }
  static Future<void> setSplashAnim(bool v) async { await p.setBool('splash_anim', v); await sync(); }

  // ── 导航(网页版-手表端导航栏位置) ──
  static String get navSide => p.getString('nav_side') ?? 'right'; // left|right(悬浮球默认吸附侧)
  static Future<void> setNavSide(String v) async { await p.setString('nav_side', v); await sync(); }

  // ── 资料(网页版-个人资料) ──
  static String get bio => p.getString('bio') ?? '';
  static String get identityCode => p.getString('identity_code') ?? ''; // 身份码(好友系统)
  static Future<void> setBio(String v) async { await p.setString('bio', v); await sync(); }

  // ── 阅读偏好 ──
  static double get fontSize => p.getDouble('fontSize') ?? 18.0;
  static int get readerTheme => p.getInt('readerTheme') ?? 0;
  static String get pageMode => p.getString('pageMode') ?? 'scroll'; // scroll|paged(分页占位, 开发中)

  static Future<void> setFontSize(double v) async { await p.setDouble('fontSize', v); await sync(); }
  static Future<void> setReaderTheme(int v) async { await p.setInt('readerTheme', v); await sync(); }
  static Future<void> setPageMode(String v) async { await p.setString('pageMode', v); await sync(); }

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
  static Future<void> add(Book b, String kind) async {
    final p = await SharedPreferences.getInstance(); final l = await shelf(kind);
    if (l.any((x) => x.bookUrl == b.bookUrl)) return;
    l.add(b); await p.setString('shelf_$kind', jsonEncode(l.map((e) => e.toJson()).toList())); }
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
    ThemeData buildTheme(Brightness b) => ThemeData(useMaterial3: true, brightness: b,
      scaffoldBackgroundColor: b == Brightness.dark ? const Color(0xFF2A2F38) : const Color(0xFFE8EAEE),
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: b),
      cardColor: b == Brightness.dark ? const Color(0xFF2A2F38) : Colors.white,
      appBarTheme: AppBarTheme(backgroundColor: b == Brightness.dark ? const Color(0xFF2A2F38) : const Color(0xFFE8EAEE), elevation: 0));
    return MaterialApp(title: 'ThirdHub',
      theme: buildTheme(Brightness.light), darkTheme: buildTheme(Brightness.dark),
      themeMode: mode == 'system' ? ThemeMode.system : mode == 'light' ? ThemeMode.light : ThemeMode.dark,
      home: widget.locked ? const LockScreen() : (widget.fresh ? const OnboardingPage() : (widget.ready ? const OrbShell() : const ConnectLibraryPage()))); }
}

// 首启引导: 三页滑屏(是什么→怎么用→连接)
class OnboardingPage extends StatefulWidget { const OnboardingPage({super.key}); @override State<OnboardingPage> createState() => _Ob(); }
class _Ob extends State<OnboardingPage> { int page = 0; final ctrl = PageController();
  static const pages = [
    (Icons.auto_awesome, '一个入口, 所有娱乐', '小说 · 漫画 · 视频 · 音乐 · 直播\n全部聚合, 搜一次全出来'),
    (Icons.hub, '资源库在哪, 内容就在哪', '在你的电脑/旧手机/电视上装 ThirdHub 后端\n本App自动连接, 数据全在你家'),
    (Icons.touch_app, '装上插件, 一切自动', '开源阅读等插件自动配对\n书源一键导入, 去广告全在后台'),
  ];
  Future<void> finish() async { final p = await SharedPreferences.getInstance();
    await p.setBool('first_run', true);
    if (mounted) runApp(ThApp(ready: (p.getString('base') ?? '').isNotEmpty, base: p.getString('base') ?? '', token: p.getString('token') ?? '')); }
  @override Widget build(BuildContext c) => Scaffold(body: SafeArea(child: Column(children: [
    Expanded(child: PageView.builder(controller: ctrl, itemCount: pages.length,
      onPageChanged: (i) => setState(() => page = i),
      itemBuilder: (_, i) => Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(pages[i].$1, size: 88, color: Colors.blue),
        const SizedBox(height: 32),
        Text(pages[i].$2, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(pages[i].$3, style: const TextStyle(color: Colors.grey, height: 1.7), textAlign: TextAlign.center),
      ])))),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [ for (var i = 0; i < pages.length; i++)
      Container(width: 8, height: 8, margin: const EdgeInsets.all(4), decoration: BoxDecoration(
        shape: BoxShape.circle, color: i == page ? Colors.blue : Colors.grey.shade800)) ]),
    Padding(padding: const EdgeInsets.all(20), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      TextButton(onPressed: finish, child: const Text('跳过')),
      FilledButton(onPressed: page < pages.length - 1 ? () => ctrl.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut) : finish,
        child: Text(page < pages.length - 1 ? '下一页' : tr('开始连接'))),
    ])),
  ])));
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
  String? fp; bool busy = false; String? err;
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
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const OrbShell())); }
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

// ═══ 悬浮球外壳: 板块切换 ═══
class OrbShell extends StatefulWidget { const OrbShell({super.key}); @override State<OrbShell> createState() => _Orb(); }
class _Orb extends State<OrbShell> {
  int tab = 0; bool menu = false;
  Offset orb = const Offset(16, 520); final orbSize = 56.0;
  static const _tabIcons = [Icons.search, Icons.menu_book, Icons.photo_library, Icons.play_circle, Icons.music_note, Icons.dns, Icons.link];
  List<(String, IconData)> get tabs => [(tr('搜索'), _tabIcons[0]), (tr('小说'), _tabIcons[1]), (tr('漫画'), _tabIcons[2]), (tr('视频'), _tabIcons[3]), (tr('音乐'), _tabIcons[4]), (tr('后端'), _tabIcons[5]), (tr('资源库'), _tabIcons[6])];
  void snap() { final w = MediaQuery.of(context).size.width;
    setState(() => orb = Offset((orb.dx + orbSize / 2) < w / 2 ? 12 : w - orbSize - 12, orb.dy.clamp(80.0, MediaQuery.of(context).size.height - 160))); }
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(leading: IconButton(icon: const Icon(Icons.person_outline), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage()))),
        title: Text(tabs[tab].$1), actions: [
        if (tab >= 1 && tab <= 4) IconButton(icon: const Icon(Icons.search), onPressed: () => showSearch(context: context, delegate: ThSearchDelegate(tab))),
        IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectLibraryPage()))),
      ]),
      body: Stack(children: [
        [const SearchSection(), const NovelSection(), const ComicSection(), const VideoSection(), const MusicSection(),
         const EnginesPage(), const ToolsSection()][tab],
        if (menu) GestureDetector(onTap: () => setState(() => menu = false), child: Container(color: Colors.black54)),
        if (menu) Positioned(left: orb.dx.clamp(8, size.width - 76), top: (orb.dy - 440).clamp(70.0, size.height - 540),
          child: Column(children: [ for (var i = 0; i < tabs.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 6),
            child: NeuSurface(radius: 26, width: 52, height: 52, selected: tab == i,
              onTap: () => setState(() { tab = i; menu = false; }),
              child: Icon(tabs[i].$2, color: tab == i ? Colors.blueAccent : Colors.grey.shade400, size: 22)))])),
        Positioned(left: orb.dx, top: orb.dy, child: GestureDetector(
          onPanUpdate: (d) => setState(() => orb += d.delta), onPanEnd: (_) => snap(),
          child: NeuSurface(radius: orbSize / 2, width: orbSize, height: orbSize, selected: menu,
            onTap: () => setState(() => menu = !menu),
            child: Icon(menu ? Icons.close : Icons.hub, color: Colors.blueAccent, size: 26)))),
      ]));
  }
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

// 个人中心: 昵称头像(本地)+收藏统计+清理+关于
class ProfilePage extends StatefulWidget { const ProfilePage({super.key}); @override State<ProfilePage> createState() => _Pf(); }
class _Pf extends State<ProfilePage> {
  Map<String, int> stats = {};
  @override void initState() { super.initState(); load(); AppSettings.loadFromBackend().then((_) => setState(() {})); }
  Future<void> load() async { final p = await SharedPreferences.getInstance();
    int count(String k) { try { return (jsonDecode(p.getString(k) ?? '[]') as List).length; } catch (_) { return 0; } }
    setState(() => stats = { tr('书架'): count('shelf_novel'), tr('漫画'): count('shelf_comic'), '片库': count('shelf_video'), tr('歌单'): count('playlist') }); }

  // ── 头像(网页版: 选择头像→压缩→更新) ──
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
      final b64 = base64Encode(jpg);
      await AppSettings.setAvatar(b64);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('头像已更新 (${(jpg.length / 1024).toStringAsFixed(1)}KB)')));
      setState(() {});
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败: $e'))); } }

  Widget section(String title, List<Widget> children) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text(title, style: TextStyle(fontSize: 12, color: Colors.blueAccent.shade100, fontWeight: FontWeight.bold))),
    Card(margin: EdgeInsets.zero, child: Column(children: children)),
  ]);

  @override Widget build(BuildContext c) {
    final avatar = AppSettings.avatarB64;
    final nameC = TextEditingController(text: AppSettings.nickname);
    final bioC = TextEditingController(text: AppSettings.bio);
    return Scaffold(appBar: AppBar(title: Text(tr('我的'))), body: ListView(padding: const EdgeInsets.all(12), children: [
      // ═══ ① 个人资料(网页版: 头像/昵称/简介/身份码) ═══
      Row(children: [
        GestureDetector(onTap: pickAvatar, child: CircleAvatar(radius: 32,
          backgroundImage: avatar.isNotEmpty ? MemoryImage(base64Decode(avatar)) : null,
          child: avatar.isEmpty ? Text(AppSettings.nickname.isEmpty ? 'T' : AppSettings.nickname[0].toUpperCase(), style: const TextStyle(fontSize: 22)) : null)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: nameC, decoration: InputDecoration(hintText: tr('昵称'), isDense: true, border: InputBorder.none), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            onSubmitted: (v) async { final p = await SharedPreferences.getInstance(); await p.setString('nickname', v.trim()); await AppSettings.sync(); }),
          GestureDetector(onTap: () async {
            final r = await showDialog<String>(context: c, builder: (c2) {
              final cc = TextEditingController(text: AppSettings.bio);
              return AlertDialog(title: Text(tr('简介')), content: TextField(controller: cc, maxLines: 2, decoration: InputDecoration(hintText: tr('这个人很懒，什么都没写'))),
                actions: [TextButton(onPressed: () => Navigator.pop(c2), child: Text(tr('取消'))), FilledButton(onPressed: () => Navigator.pop(c2, cc.text), child: Text(tr('保存')))]); });
            if (r != null) { await AppSettings.setBio(r); setState(() {}); } },
            child: Text(AppSettings.bio.isEmpty ? tr('这个人很懒，什么都没写') : AppSettings.bio, style: const TextStyle(fontSize: 12, color: Colors.grey))),
        ])),
      ]),
      const SizedBox(height: 6),
      // 身份码(网页版: 生成好友二维码/复制身份码)
      Card(child: ListTile(dense: true, leading: const Icon(Icons.badge_outlined, size: 20),
        title: Text(AppSettings.identityCode, style: const TextStyle(fontSize: 12, letterSpacing: 0.5)),
        subtitle: const Text('身份码 · 加好友用(云端好友二期)', style: TextStyle(fontSize: 10)),
        trailing: IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('身份码已复制'))); }))),
      Card(child: Padding(padding: const EdgeInsets.all(10), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        for (final e in stats.entries) Column(children: [ Text('${e.value}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
          Text(e.key, style: const TextStyle(fontSize: 10, color: Colors.grey)) ]),
      ]))),

      // ═══ ② 外观(网页版: 主题外观/强调色/开屏动画) ═══
      section('个性化', [
        ListTile(dense: true, leading: const Icon(Icons.language, size: 20), title: const Text('语言', style: TextStyle(fontSize: 13)),
          subtitle: Text(I18n.names[AppSettings.locale] ?? '中文', style: const TextStyle(fontSize: 10)),
          onTap: () async {
            final l = await showDialog<String>(context: c, builder: (c2) => SimpleDialog(title: const Text('语言 / Language'),
              children: [ for (final lc in I18n.supported) SimpleDialogOption(onPressed: () => Navigator.pop(c2, lc),
                child: Row(children: [ if (lc == AppSettings.locale) const Icon(Icons.check, size: 16, color: Colors.blueAccent),
                  Text(I18n.names[lc] ?? lc) ])) ]));
            if (l != null) { await AppSettings.setLocale(l); setState(() {}); } }),
        ListTile(dense: true, leading: const Icon(Icons.brightness_6_outlined, size: 20), title: Text(tr('主题外观'), style: TextStyle(fontSize: 13)),
          trailing: SegmentedButton<String>(showSelectedIcon: false, style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: [ButtonSegment(value: 'system', label: Text(tr('跟随系统'), style: TextStyle(fontSize: 10))), ButtonSegment(value: 'dark', label: Text(tr('深色'), style: TextStyle(fontSize: 10))), ButtonSegment(value: 'light', label: Text(tr('浅色'), style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.themeModeStr}, onSelectionChanged: (s) => AppSettings.setThemeMode(s.first).then((_) => setState(() {})))),
        ListTile(dense: true, leading: const Icon(Icons.color_lens_outlined, size: 20), title: Text(tr('强调色'), style: TextStyle(fontSize: 13)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [ for (final col in [0xFF5B9BFF, 0xFF7C6CFF, 0xFF4ADE80, 0xFFF472B6, 0xFFFBBF24])
            GestureDetector(onTap: () => AppSettings.setAccent(col).then((_) => setState(() {})),
              child: Container(width: 22, height: 22, margin: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(
                color: Color(col), shape: BoxShape.circle, border: AppSettings.accentColor == col ? Border.all(color: Colors.white, width: 2) : null))) ])),
        SwitchListTile(dense: true, secondary: const Icon(Icons.movie_filter_outlined, size: 20), title: Text(tr('开屏动画'), style: TextStyle(fontSize: 13)),
          value: AppSettings.splashAnim, onChanged: (v) => AppSettings.setSplashAnim(v).then((_) => setState(() {}))),
      ]),

      // ═══ ③ 导航(网页版: 手表端导航栏位置→悬浮球默认侧) ═══
      section('导航', [
        ListTile(dense: true, leading: const Icon(Icons.swipe_outlined, size: 20), title: Text(tr('悬浮球默认位置'), style: TextStyle(fontSize: 13)),
          trailing: SegmentedButton<String>(showSelectedIcon: false, style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            segments: [ButtonSegment(value: 'left', label: Text(tr('左侧'), style: TextStyle(fontSize: 10))), ButtonSegment(value: 'right', label: Text(tr('右侧'), style: TextStyle(fontSize: 10)))],
            selected: {AppSettings.navSide}, onSelectionChanged: (s) => AppSettings.setNavSide(s.first).then((_) => setState(() {})))),
      ]),

      // ═══ ④ 系统(网页版: 连接器管理/贤者模式/清理缓存/版本) ═══
      section('系统', [
        ListTile(dense: true, leading: const Icon(Icons.extension_outlined, size: 20), title: Text(tr('连接器管理'), style: TextStyle(fontSize: 13)),
          subtitle: const Text('引擎与源 · 等同于"后端"板块', style: TextStyle(fontSize: 10)), onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const EnginesPage()))),
        SwitchListTile(dense: true, secondary: const Icon(Icons.shield_outlined, size: 20), title: Text(tr('贤者模式（内容保护）'), style: TextStyle(fontSize: 13)),
          subtitle: const Text('PIN锁 · 在"连接资源库"页设置', style: TextStyle(fontSize: 10)),
          value: (SharedPreferences.getInstance().then((p) => p.getString('app_pin') ?? '')).toString().isNotEmpty && false,
          onChanged: (_) => Navigator.push(c, MaterialPageRoute(builder: (_) => const ConnectLibraryPage()))),
        ListTile(dense: true, leading: const Icon(Icons.delete_sweep_outlined, size: 20), title: Text(tr('清理缓存'), style: TextStyle(fontSize: 13)),
          onTap: () async { final p = await SharedPreferences.getInstance();
            for (final k in ['sh_novel', 'search_history']) { await p.remove(k); }
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('缓存已清理'))); }),
        ListTile(dense: true, leading: const Icon(Icons.system_update_alt, size: 20), title: Text(tr('版本与更新'), style: TextStyle(fontSize: 13)),
          subtitle: Text('v4.0.0-m2 · 自动检查已开启', style: TextStyle(fontSize: 10))),
      ]),

      // ═══ ⑤ 云端(网页版: 云存储用量/会员) — 会员冻结占位 ═══
      section('云端', [
        ListTile(dense: true, leading: const Icon(Icons.cloud_outlined, size: 20), title: Text(tr('云存储'), style: TextStyle(fontSize: 13)),
          subtitle: Text('用量 ${AppSettings.localUsageKB.toStringAsFixed(1)}KB / 1024KB(头像限0.5MB) · 进度存自己后端不占配额', style: const TextStyle(fontSize: 10)),
          trailing: const Icon(Icons.refresh, size: 18)),
        ListTile(dense: true, leading: const Icon(Icons.workspace_premium_outlined, size: 20), title: Text(tr('会员等级'), style: TextStyle(fontSize: 13)),
          subtitle: Text('免费 · 会员体系冻结期', style: TextStyle(fontSize: 10)), enabled: false),
      ]),

      // ═══ ⑥ 关于(网页版: 使用指南/开源致谢) ═══
      section('关于', [
        ListTile(dense: true, leading: const Icon(Icons.menu_book_outlined, size: 20), title: Text(tr('使用指南'), style: TextStyle(fontSize: 13)), enabled: false),
        ListTile(dense: true, leading: const Icon(Icons.favorite_border, size: 20), title: Text(tr('开源致谢'), style: TextStyle(fontSize: 13)),
          subtitle: Text('Legado/dr_py/Venera/MusicFree/Cloudreve 及全体开源社区', style: TextStyle(fontSize: 10))),
      ]),
      const SizedBox(height: 16),
      const Center(child: Text('ThirdHub v4.0.0-m2 · 纯播放器前端', style: TextStyle(fontSize: 11, color: Colors.grey))),
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
      if ((e['sources'] ?? 0) > 0) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: Colors.grey.shade800, borderRadius: BorderRadius.circular(10)),
        child: Text('${e['sources']} 源', style: const TextStyle(fontSize: 10, color: Colors.grey))),
      if (e['health'] != null && e['health']['rate'] != null) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: Colors.grey.shade800, borderRadius: BorderRadius.circular(10)),
        child: Text('成功率${e['health']['rate']}%', style: const TextStyle(fontSize: 10, color: Colors.grey))),
      if (e['lastSeen'] != null) Text('最后在线 ${DateTime.fromMillisecondsSinceEpoch(e['lastSeen']).toString().substring(11, 16)}',
        style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ]),
  ])));
  @override Widget build(BuildContext c) => loading && builtin.isEmpty ? const Center(child: CircularProgressIndicator())
    : RefreshIndicator(onRefresh: load, child: ListView(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: Text(
        '内置引擎 ${meta['builtinOnline'] ?? 0}/${meta['builtinTotal'] ?? 0} 在线 · 网络引擎 ${meta['networkOnline'] ?? 0}/${meta['networkTotal'] ?? 0} 在线 · 10秒自动刷新',
        style: const TextStyle(fontSize: 12, color: Colors.grey))),
      for (final e in builtin) engineCard(Map<String, dynamic>.from(e)),
      if (network.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: Text(tr('网络引擎(局域网设备)'), style: TextStyle(fontSize: 12, color: Colors.grey))),
      for (final e in network) engineCard(Map<String, dynamic>.from(e)),
      if (network.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text('暂无网络引擎\n改造版开源阅读装后会自动出现(自动配对)', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
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
  int typeFilter = 0; // 0全部 1小说 2漫画 3视频 4音乐
  static final typeNames = [tr('全部'), tr('小说'), tr('漫画'), tr('视频'), tr('音乐')];
  static const typeKeys = ['', 'novel', 'comic', 'video', 'music'];
  Future<void> go() async { final q = ctrl.text.trim(); if (q.isEmpty) return;
    setState(() { loading = true; agg = null; });
    try {
      if (typeFilter == 0) { final r = await Api.get('/v1/search/all?q=${Uri.encodeComponent(q)}'); setState(() { agg = r['data']; }); }
      else {
        // 单类型: 走统一路由, 后端按能力分发到对应引擎集合
        final r = await Api.get('/v1/search?type=${typeKeys[typeFilter]}&q=${Uri.encodeComponent(q)}');
        setState(() { agg = { 'single': r['data'], 'q': q }; });
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  Widget group(String title, List items, Widget Function(Map) tile) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (items.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text('$title (${items.length})', style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold))),
    for (final it in items) tile(it),
  ]);
  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 0), child: Wrap(spacing: 6, children: [
      for (var i = 0; i < typeNames.length; i++) ChoiceChip(
        label: Text(typeNames[i], style: const TextStyle(fontSize: 12)), selected: typeFilter == i,
        onSelected: (_) { setState(() => typeFilter = i); if (ctrl.text.trim().isNotEmpty) go(); }),
    ])),
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
    if (loading) const LinearProgressIndicator(),
    if (agg != null) Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: Align(alignment: Alignment.centerLeft,
      child: Text('书源${agg!['stats']?['bookSources'] ?? 0} · 图源${agg!['stats']?['comicSources'] ?? 0} · 影视源${agg!['stats']?['videoSources'] ?? 0} · 音源${agg!['stats']?['musicSources'] ?? 0}', style: const TextStyle(fontSize: 11, color: Colors.grey)))),
    Expanded(child: ListView(children: [
      if (agg != null && agg!['single'] != null) ...[
        for (final g in ((agg!['single'] as List?) ?? [])) ...[
          if (g['ok'] == true) Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency'] ?? 0}ms)', style: const TextStyle(color: Colors.blueAccent, fontSize: 12))),
          for (final it in ((g['items'] ?? g['books']) as List? ?? [])) _singleTile(typeFilter, g['sourceId'] ?? '', it, context),
        ],
      ] else if (agg != null) ...[
        for (final g in (agg!['books'] as List? ?? []))
          group('📖 ${g['source']}', (g['books'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(Map<String, dynamic>.from(b))))))),
        for (final g in (agg!['comics'] as List? ?? []))
          group('🎨 ${g['source']}', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['title'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ComicDetailPage(sourceId: g['sourceId'] ?? '', comicId: b['id'] ?? '', title: b['title'] ?? ''))))),
        for (final g in (agg!['videos'] as List? ?? []))
          group('🎬 ${g['source']}', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['name'] ?? ''), subtitle: Text(b['type'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VideoDetailPage(sourceId: g['sourceId'] ?? '', vodId: b['id'] ?? '', title: b['name'] ?? ''))))),
        for (final g in (agg!['musics'] as List? ?? []))
          group('🎵 ${g['source']}', (g['items'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, leading: const Icon(Icons.music_note, size: 20),
            title: Text(b['name'] ?? ''), subtitle: Text(b['artist'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => MusicPlayPage(item: Map<String, dynamic>.from(b), sourceId: g['sourceId'] ?? ''))))),
        if (((agg!['books'] as List?) ?? []).isEmpty && ((agg!['comics'] as List?) ?? []).isEmpty && ((agg!['videos'] as List?) ?? []).isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Text('无结果(先导入各类源)', style: TextStyle(color: Colors.grey))),
      ],
      if (agg == null && !loading) const Padding(padding: EdgeInsets.all(40), child: Text('输入关键词, 全类型或按类型搜索\n后端按引擎能力自动路由', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
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
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('书架'))), ButtonSegment(value: 1, label: Text(tr('搜索'))), ButtonSegment(value: 2, label: Text(tr('源')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [ShelfPage(kind: 'novel', builder: (b) => TocPage(book: b)), const NovelSearchResults(query: ''),
      const SourceManagerPage(kind: 'book')][sub]),
  ]); }

class NovelSearchResults extends StatefulWidget { final String query; const NovelSearchResults({super.key, required this.query}); @override State<NovelSearchResults> createState() => _NSR(); }
class _NSR extends State<NovelSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = ''; List<String> history = [];
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    final p = await SharedPreferences.getInstance();
    history.remove(q); history.insert(0, q); history = history.take(10).toList();
    await p.setStringList('sh_novel', history);
    setState(() { loading = true; groups = []; });
    try { final r = await Api.get('/v1/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); }); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
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
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.blueAccent, fontSize: 12))),
        for (final b in (g['books'] as List? ?? [])) ListTile(
          leading: (b['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(Api.img(b['coverUrl']), width: 40, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
          title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(Map<String, dynamic>.from(b)))))),
      ], if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('点右上角搜索找书', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class ShelfPage extends StatefulWidget { final String kind; final Widget Function(Book) builder; const ShelfPage({super.key, required this.kind, required this.builder}); @override State<ShelfPage> createState() => _Sh(); }
class _Sh extends State<ShelfPage> { List<Book> items = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { items = await Book.shelf(widget.kind); setState(() => loading = false); }
  Future<void> remove(Book b) async { final p = await SharedPreferences.getInstance();
    items.removeWhere((x) => x.bookUrl == b.bookUrl);
    await p.setString('shelf_${widget.kind}', jsonEncode(items.map((e) => e.toJson()).toList())); setState(() {}); }
  @override Widget build(BuildContext c) => loading ? const Center(child: CircularProgressIndicator())
    : items.isEmpty ? const Center(child: Text('书架为空\n进入书籍详情页加入', style: TextStyle(color: Colors.grey)))
    : ListView(children: [ for (final b in items) ListTile(
        leading: b.coverUrl != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
          child: Image.network(Api.img(b.coverUrl), width: 40, height: 56, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
        title: Text(b.name), subtitle: Text(b.author),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => widget.builder(b))).then((_) => load()),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => remove(b))) ]); }

class TocPage extends StatefulWidget { final Book book; const TocPage({super.key, required this.book}); @override State<TocPage> createState() => _T(); }
class _T extends State<TocPage> { List chapters = []; bool loading = true; int lastRead = -1;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try {
      final r = await Api.get('/v1/toc?sourceId=${Uri.encodeComponent(widget.book.sourceId)}&url=${Uri.encodeComponent(widget.book.bookUrl)}');
      chapters = r['data'] ?? []; } catch (e) {}
    final p = await SharedPreferences.getInstance();
    lastRead = p.getInt('progress_${widget.book.bookUrl}') ?? -1;
    try { final r = await Api.get('/v1/reading-progress');
      final remote = r['data']?[widget.book.bookUrl];
      if (remote != null) lastRead = remote['index'] ?? lastRead; } catch (_) {}
    setState(() => loading = false); }
  Future<void> save() async { await Book.add(widget.book, 'novel');
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('已加入书架')))); }
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

class NovelReadPage extends StatefulWidget { final String sourceId, bookName, bookUrl; final List chapters; final int index;
  const NovelReadPage({super.key, required this.sourceId, required this.chapters, required this.index, required this.bookName, required this.bookUrl});
  @override State<NovelReadPage> createState() => _NR(); }
class _NR extends State<NovelReadPage> {
  String text = ''; List<String> images = []; bool loading = true;
  double fontSize = AppSettings.fontSize; int theme = AppSettings.readerTheme; // 设置中心默认值
  final Map<int, Map> chapCache = {}; // 预加载: 章index → content数据
  static const themes = [(Color(0xFF121212), Color(0xFFE0E0E0)), (Colors.white, Colors.black87), (Color(0xFFF5F0E1), Color(0xFF4A3F30))];
  int get idx => widget.index; Map<String, dynamic> get chapter => widget.chapters[idx];
  bool get hasPrev => idx > 0; bool get hasNext => idx < widget.chapters.length - 1;
  @override void initState() { super.initState(); load(); }
  Future<void> preload(int i) async { if (i < 0 || i >= widget.chapters.length || chapCache.containsKey(i)) return;
    try { final ch = widget.chapters[i];
      final r = await Api.get('/v1/content?sourceId=${Uri.encodeComponent(widget.sourceId)}&url=${Uri.encodeComponent(ch['url'])}');
      if (r['object'] != 'error') chapCache[i] = Map<String, dynamic>.from(r['data']);
    } catch (_) {} }
  Future<void> load() async { setState(() => loading = true); try {
      if (chapCache.containsKey(idx)) { final d = chapCache[idx]!;
        text = d['text'] as String? ?? ''; images = List<String>.from(d['images'] ?? []); }
      else {
        final r = await Api.get('/v1/content?sourceId=${Uri.encodeComponent(widget.sourceId)}&url=${Uri.encodeComponent(chapter['url'])}');
        text = r['data']?['text'] as String? ?? ''; images = List<String>.from(r['data']?['images'] ?? []);
        chapCache[idx] = Map<String, dynamic>.from(r['data'] ?? {});
      }
      if (text.isEmpty && images.isEmpty) text = '本章无内容';
      final p = await SharedPreferences.getInstance(); await p.setInt('progress_${widget.bookUrl}', idx);
      try { await http.post(Uri.parse('${Api.base}/v1/reading-progress'),
        headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
        body: jsonEncode({'bookUrl': widget.bookUrl, 'index': idx, 'chapter': chapter['name'] ?? ''})); } catch (_) {}
      preload(idx + 1); preload(idx - 1); // 预加载前后章
    } catch (e) { text = '错误: $e'; }
    setState(() => loading = false); }
  void goChapter(int i) => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => NovelReadPage(
    sourceId: widget.sourceId, chapters: widget.chapters, index: i, bookName: widget.bookName, bookUrl: widget.bookUrl)));
  @override Widget build(BuildContext c) { final isImgs = images.isNotEmpty;
    final t = themes[theme];
    return Scaffold(appBar: AppBar(title: Text('${chapter['name'] ?? ''}  (${idx + 1}/${widget.chapters.length})'), actions: [
        IconButton(icon: const Icon(Icons.brightness_6_outlined), onPressed: () => setState(() => theme = (theme + 1) % 3)),
        if (!isImgs) IconButton(icon: const Icon(Icons.text_increase), onPressed: () => setState(() => fontSize += 1)),
        if (!isImgs) IconButton(icon: const Icon(Icons.text_decrease), onPressed: () => setState(() => fontSize = (fontSize - 1).clamp(12, 32)))]),
      body: Column(children: [
        Expanded(child: loading ? const Center(child: CircularProgressIndicator()) : isImgs
          ? ListView.builder(itemCount: images.length, itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 2),
              child: InteractiveViewer(child: Image.network(Api.img(images[i]), fit: BoxFit.fitWidth,
                errorBuilder: (_, __, ___) => const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image, color: Colors.grey)))))))
          : GestureDetector(
              onHorizontalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                if (v < -300 && hasNext) goChapter(idx + 1);        // 左滑下一章
                else if (v > 300 && hasPrev) goChapter(idx - 1);    // 右滑上一章
              },
              child: Container(color: t.$1, child: SingleChildScrollView(padding: const EdgeInsets.all(16),
              child: SelectableText(text, style: TextStyle(fontSize: fontSize, height: 1.8, color: t.$2)))))),
        SafeArea(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          TextButton.icon(onPressed: hasPrev ? () => goChapter(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: Text(tr('上一章'))),
          TextButton.icon(onPressed: hasNext ? () => goChapter(idx + 1) : null, label: Text(tr('下一章')), icon: const Icon(Icons.chevron_right)),
        ]))])); }
}

// ═══ 板块二: 漫画播放器(UI先行, 数据源待后端comic引擎) ═══
class ComicSection extends StatefulWidget { const ComicSection({super.key}); @override State<ComicSection> createState() => _Cs(); }
class _Cs extends State<ComicSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('书架'))), ButtonSegment(value: 1, label: Text(tr('搜索'))), ButtonSegment(value: 2, label: Text(tr('源')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [ShelfPage(kind: 'comic', builder: (b) => ComicDetailPage(sourceId: b.sourceId, comicId: b.bookUrl, title: b.name)),
      const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('点右上角搜索框找漫画', style: TextStyle(color: Colors.grey)))),
      const SourceManagerPage(kind: 'comic')][sub]),
  ]); }

class ComicSearchResults extends StatefulWidget { final String query; const ComicSearchResults({super.key, required this.query}); @override State<ComicSearchResults> createState() => _CSR(); }
class _CSR extends State<ComicSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = '';
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    setState(() { loading = true; groups = []; });
    try { final r = await Api.get('/v1/comic/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); }); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override void initState() { super.initState(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(ComicSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['ok'] == true && (g['items'] as List?)?.isNotEmpty == true)
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.blueAccent, fontSize: 12))),
        for (final b in (g['items'] as List? ?? [])) ListTile(
          leading: (b['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(Api.img(b['coverUrl']), width: 40, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
          title: Text(b['title'] ?? ''), subtitle: Text(b['subTitle'] ?? ''),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ComicDetailPage(
            sourceId: g['sourceId'] ?? '', comicId: b['id'] ?? '', title: b['title'] ?? '')))),
      ],
      if (groups.isNotEmpty) for (final g in groups) if (g['ok'] == false)
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']}: ${g['error'] ?? '失败'}', style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
      if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('无结果(或尚未导入Venera图源)', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class ComicDetailPage extends StatefulWidget { final String sourceId, comicId, title; const ComicDetailPage({super.key, required this.sourceId, required this.comicId, required this.title}); @override State<ComicDetailPage> createState() => _Cd(); }
class _Cd extends State<ComicDetailPage> {
  Map<String, dynamic>? info; List chapters = []; bool loading = true; String? err; int lastRead = -1;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try {
      final r = await Api.get('/v1/comic/info?sourceId=${Uri.encodeComponent(widget.sourceId)}&id=${Uri.encodeComponent(widget.comicId)}');
      if (r['object'] == 'error') { err = r['data']?['message'] ?? '失败'; }
      else { info = r['data']; chapters = info?['chapters'] ?? []; }
      final p = await SharedPreferences.getInstance();
      lastRead = p.getInt('cprog_${widget.comicId}') ?? -1;
    } catch (e) { err = '$e'; }
    setState(() => loading = false); }
  Future<void> save() async { await Book.add(Book(widget.title, (info?['tags'] ?? []).join('/'), info?['coverUrl'] ?? '', info?['description'] ?? '', widget.comicId, widget.sourceId), 'comic');
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
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text('${widget.chapters[idx]['title'] ?? ''}  (${idx + 1}/${widget.chapters.length})')),
    body: Column(children: [
      Expanded(child: loading ? const Center(child: CircularProgressIndicator())
        : err != null ? Center(child: Text(err!, style: const TextStyle(color: Colors.red)))
        : images.isEmpty ? const Center(child: Text('本章无图片'))
        : ListView.builder(itemCount: images.length, itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 1),
            child: InteractiveViewer(child: Image.network(Api.img(images[i]), fit: BoxFit.fitWidth,
              loadingBuilder: (_, w, p) => p == null ? w : const SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
              errorBuilder: (_, __, ___) => const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image, color: Colors.grey)))))))),
      SafeArea(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        TextButton.icon(onPressed: hasPrev ? () => goChapter(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: Text(tr('上一话'))),
        TextButton.icon(onPressed: hasNext ? () => goChapter(idx + 1) : null, label: Text(tr('下一话')), icon: const Icon(Icons.chevron_right)),
      ]))])); }

// ═══ 源管理(四类通用: 列表/启停/删除/粘贴导入) ═══
class SourceManagerPage extends StatefulWidget { final String kind; const SourceManagerPage({super.key, required this.kind}); @override State<SourceManagerPage> createState() => _SM(); }
class _SM extends State<SourceManagerPage> {
  static final cfgs = {
    'book':  (list: '/v1/sources', imp: '/v1/sources', label: tr('书源'), hint: '粘贴书源JSON(单条或数组)'),
    'video': (list: '/v1/video/sources', imp: '/v1/video/sources', label: tr('影视源'), hint: '粘贴{name, code}JSON'),
    'comic': (list: '/v1/comic/sources', imp: '/v1/comic/sources', label: tr('图源'), hint: '粘贴{name, code}JSON'),
    'music': (list: '/v1/music/sources', imp: '/v1/music/sources', label: tr('音源'), hint: '粘贴{name, code}JSON'),
  };
  List<Map> items = []; bool loading = true; final importC = TextEditingController(); String? msg;
  String get kind => widget.kind;
  ({String list, String imp, String label, String hint}) get cfg => cfgs[kind]!;
  Future<void> load() async { try {
      final r = await Api.get(cfg.$1);
      items = (r['data'] as List? ?? []).cast<Map>();
    } catch (e) {}
    setState(() => loading = false); }
  @override void initState() { super.initState(); load(); }
  Future<void> toggle(Map s) async { await Api.get('/v1/src/$kind/toggle?id=${Uri.encodeComponent(s['id'] ?? '')}'); load(); }
  Future<void> remove(Map s) async { await Api.get('/v1/src/$kind/delete?id=${Uri.encodeComponent(s['id'] ?? '')}'); load(); }
  Future<void> doImport() async { final t = importC.text.trim(); if (t.isEmpty) return;
    setState(() => msg = '导入中…');
    try {
      http.Response r;
      if (t.startsWith('http')) {
        r = await http.post(Uri.parse('${Api.base}${cfg.$2}'), headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
          body: jsonEncode(t.endsWith('.json') && kind == 'book' ? jsonDecode(await (await Api.client().get(Uri.parse(t))).body) : {'name': t.split('/').last, 'code': t}));
      } else {
        final j = jsonDecode(t);
        r = await http.post(Uri.parse('${Api.base}${cfg.$2}'), headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json'},
          body: jsonEncode(kind == 'book' ? j : (j is Map ? j : {'name': '导入源', 'code': t})));
      }
      setState(() { msg = r.statusCode == 200 ? '导入成功' : '失败: ${r.statusCode}'; importC.clear(); });
      load();
    } catch (e) { setState(() => msg = '导入失败: $e'); } }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator() else Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Align(alignment: Alignment.centerLeft,
      child: Text('${cfg.$3} ${items.length} 个 (批量导入用命令行脚本)', style: const TextStyle(fontSize: 12, color: Colors.grey)))),
    Expanded(child: ListView(children: [
      for (final s in items) SwitchListTile(
        title: Text(s['name'] ?? '', style: TextStyle(color: s['enabled'] == false ? Colors.grey : null)),
        value: s['enabled'] != false, onChanged: (_) => toggle(s),
        secondary: IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => remove(s)),
      ),
    ])),
    const Divider(height: 1),
    Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: importC, maxLines: 2, minLines: 1, decoration: InputDecoration(hintText: cfg.$4, border: const OutlineInputBorder(), isDense: true))),
      const SizedBox(width: 8),
      FilledButton(onPressed: doImport, child: Text(tr('导入'))),
    ])),
    if (msg != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(msg!, style: const TextStyle(fontSize: 12, color: Colors.blueAccent))),
  ]); }

// ═══ 板块四: 音乐播放器 ═══
class MusicSection extends StatefulWidget { const MusicSection({super.key}); @override State<MusicSection> createState() => _Ms(); }
class _Ms extends State<MusicSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text(tr('歌单'))), ButtonSegment(value: 1, label: Text(tr('搜索'))), ButtonSegment(value: 2, label: Text(tr('源')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [const _MusicPlaylist(),
      const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('点右上角搜索框找歌', style: TextStyle(color: Colors.grey)))),
      const SourceManagerPage(kind: 'music')][sub]),
  ]); }

class _MusicPlaylist extends StatefulWidget { const _MusicPlaylist(); @override State<_MusicPlaylist> createState() => _MpList(); }
class _MpList extends State<_MusicPlaylist> {
  List<Map> items = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    try { items = (jsonDecode(p.getString('playlist') ?? '[]') as List).cast<Map>(); } catch (_) {}
    setState(() => loading = false); }
  Future<void> remove(Map m) async { final p = await SharedPreferences.getInstance();
    items.removeWhere((x) => x['id'] == m['id']);
    await p.setString('playlist', jsonEncode(items)); setState(() {}); }
  @override Widget build(BuildContext c) => loading ? const Center(child: CircularProgressIndicator())
    : items.isEmpty ? const Center(child: Text('歌单为空\n播放过的歌自动入单', style: TextStyle(color: Colors.grey)))
    : ListView(children: [ for (final m in items) ListTile(
        leading: (m['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
          child: Image.network(Api.img(m['coverUrl']), width: 44, height: 44, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox(width: 44, height: 44))) : const Icon(Icons.music_note),
        title: Text(m['name'] ?? ''), subtitle: Text(m['artist'] ?? ''),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => MusicPlayPage(item: m))),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => remove(m))) ]); }

class MusicSearchResults extends StatefulWidget { final String query; const MusicSearchResults({super.key, required this.query}); @override State<MusicSearchResults> createState() => _MSR(); }
class _MSR extends State<MusicSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = '';
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    setState(() { loading = true; groups = []; });
    try { final r = await Api.get('/v1/music/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); }); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override void initState() { super.initState(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(MusicSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  Future<void> play(Map item, String sourceId) async {
    // 入歌单
    final p = await SharedPreferences.getInstance();
    final list = (jsonDecode(p.getString('playlist') ?? '[]') as List).cast<Map>();
    if (!list.any((x) => x['id'] == item['id'])) { list.add(item); await p.setString('playlist', jsonEncode(list)); }
    if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => MusicPlayPage(item: item, sourceId: sourceId)));
  }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['ok'] == true && (g['items'] as List?)?.isNotEmpty == true)
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.blueAccent, fontSize: 12))),
        for (final m in (g['items'] as List? ?? [])) ListTile(
          leading: (m['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(Api.img(m['coverUrl']), width: 44, height: 44, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 44, height: 44))) : const Icon(Icons.music_note),
          title: Text(m['name'] ?? ''), subtitle: Text('${m['artist'] ?? ''} · ${m['album'] ?? ''}'.trim()),
          trailing: const Icon(Icons.play_arrow),
          onTap: () => play(Map<String, dynamic>.from(m), g['sourceId'] ?? '')),
      ],
      if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('无结果(或尚未导入音源)', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class MusicPlayPage extends StatefulWidget { final Map item; final String sourceId; const MusicPlayPage({super.key, required this.item, this.sourceId = ''}); @override State<MusicPlayPage> createState() => _MPlay(); }
class _MPlay extends State<MusicPlayPage> {
  final AudioPlayer player = AudioPlayer(); bool loading = true; String? err; String lyric = '';
  @override void initState() { super.initState(); start(); }
  Future<void> start() async {
    try {
      String playUrl = widget.item['url'] as String? ?? '';
      if (playUrl.isEmpty && widget.sourceId.isNotEmpty) {
        final r = await Api.get('/v1/music/url?sourceId=${Uri.encodeComponent(widget.sourceId)}&item=${Uri.encodeComponent(jsonEncode(widget.item))}');
        playUrl = r['data']?['url'] as String? ?? '';
      }
      if (playUrl.isEmpty) { setState(() { loading = false; err = '无播放地址(音源未实现getMediaSource?)'; }); return; }
      await player.setUrl(playUrl);
      await player.play();
      setState(() => loading = false);
      // 歌词(尽力而为)
      if (widget.sourceId.isNotEmpty) {
        try { final l = await Api.get('/v1/music/lyric?sourceId=${Uri.encodeComponent(widget.sourceId)}&item=${Uri.encodeComponent(jsonEncode(widget.item))}');
          lyric = l['data']?['lyric'] as String? ?? ''; if (mounted) setState(() {}); } catch (_) {}
      }
    } catch (e) { setState(() { loading = false; err = '$e'; }); } }
  @override void dispose() { player.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.item['name'] ?? '')),
    body: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const SizedBox(height: 20),
      if ((widget.item['coverUrl'] ?? '') != '') ClipRRect(borderRadius: BorderRadius.circular(12),
        child: Image.network(Api.img(widget.item['coverUrl']), width: 200, height: 200, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 120))) else const Icon(Icons.music_note, size: 120),
      const SizedBox(height: 16),
      Text(widget.item['name'] ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      Text(widget.item['artist'] ?? '', style: const TextStyle(color: Colors.grey)),
      const SizedBox(height: 24),
      if (loading) const CircularProgressIndicator()
      else if (err != null) Text(err!, style: const TextStyle(color: Colors.red))
      else StreamBuilder<PlayerState>(stream: player.playerStateStream, builder: (_, s) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(icon: const Icon(Icons.replay), iconSize: 36, onPressed: () => player.seek(Duration.zero)),
        IconButton(icon: Icon(s.data?.playing == true ? Icons.pause_circle : Icons.play_circle), iconSize: 64,
          onPressed: () => s.data?.playing == true ? player.pause() : player.play()),
        IconButton(icon: const Icon(Icons.stop_circle), iconSize: 36, onPressed: () { player.stop(); Navigator.pop(c); }),
      ])),
      const SizedBox(height: 12),
      if (lyric.isNotEmpty) Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16),
        child: Text(lyric, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, height: 1.6)))),
    ])); }

// ═══ 板块三: 视频播放器(UI先行, 数据源待后端drpy引擎) ═══
class VideoSection extends StatefulWidget { const VideoSection({super.key}); @override State<VideoSection> createState() => _Vs(); }
class _Vs extends State<VideoSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: [ButtonSegment(value: 0, label: Text('片库')), ButtonSegment(value: 1, label: Text('直播')), ButtonSegment(value: 2, label: Text(tr('源')))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [const ShelfPage(kind: 'video', builder: _videoDetail), const LivePage(),
      const SourceManagerPage(kind: 'video')][sub]),
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
      ? const Center(child: Text('搜索频道名, 或点上方热词\n(需先导入含直播分类的drpy源)', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
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
  List<Map> groups = []; bool loading = false; String lastQ = '';
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    setState(() { loading = true; groups = []; });
    try { final r = await Api.get('/v1/video/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); }); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override void initState() { super.initState(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(VideoSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['ok'] == true && (g['items'] as List?)?.isNotEmpty == true)
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.blueAccent, fontSize: 12))),
        for (final b in (g['items'] as List? ?? [])) ListTile(
          leading: (b['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(Api.img(b['coverUrl']), width: 40, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
          title: Text(b['name'] ?? ''), subtitle: Text('${b['type'] ?? ''} ${b['year'] ?? ''}'.trim()),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VideoDetailPage(
            sourceId: g['sourceId'] ?? '', vodId: b['id'] ?? '', title: b['name'] ?? '')))),
      ],
      if (groups.isNotEmpty) for (final g in groups) if (g['ok'] == false)
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']}: ${g['error'] ?? '失败'}', style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
      if (groups.isEmpty && !loading) const Padding(padding: EdgeInsets.all(32), child: Text('无结果(或尚未导入drpy源)', style: TextStyle(color: Colors.grey))),
    ])), ]); }

class VideoDetailPage extends StatefulWidget { final String sourceId, vodId, title; const VideoDetailPage({super.key, required this.sourceId, required this.vodId, required this.title}); @override State<VideoDetailPage> createState() => _Vd(); }
class _Vd extends State<VideoDetailPage> {
  Map<String, dynamic>? info; List episodes = []; bool loading = true; String? err;
  @override void initState() { super.initState(); load(); }
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
      _cc = ChewieController(videoPlayerController: _vc!, autoPlay: true, aspectRatio: _vc!.value.aspectRatio,
        allowedScreenSleep: false);
      setState(() => loading = false);
    } catch (e) { setState(() { loading = false; err = '$e'; }); } }
  @override void dispose() { _cc?.dispose(); _vc?.dispose(); super.dispose(); }
  void goEpisode(int i) { final ep = widget.episodes[i];
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => VideoPlayPage(
      sourceId: widget.sourceId, epUrl: ep['url'] ?? '', flag: ep['flag'] ?? '', title: ep['name'] ?? '',
      episodes: widget.episodes, index: i))); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title)),
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
