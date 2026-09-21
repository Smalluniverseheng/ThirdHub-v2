// 浏览器模块: 自研实现(参考 FOSS Browser / Privacy Browser 的功能设计, 无代码拷贝, 无协议冲突)
// 多标签页 · 地址栏(搜索/网址) · 前进后退刷新 · 书签 · 历史 · 进度条 · 全屏模式
// 无痕标签(不写历史/关闭即焚) · 阅读模式(提取正文 → 一键交给小说阅读器)
// 沉浸式设计: 本模块隐藏 App 顶栏/底栏, 屏幕全给网页; 切换模块走菜单/悬浮钮
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../main.dart' show LocalNovelReader;
import 'pro_browser.dart';

// 与 RootNav(main.dart) 的桥: 打开模块宫格
class BrowserHooks {
  static void Function(BuildContext)? openModules;
}

class _Tab {
  WebViewController? ctrl; String url = ''; String title = '新标签页'; int progress = 0;
  bool incognito = false; // 无痕: 不写历史, 标签页关闭即焚(会话不持久化)
  _Tab(this.url, {this.incognito = false});
}

// 搜索引擎预设
const kSearchEngines = <(String, String, String)>[
  ('必应', 'https://www.bing.com/search?q=', 'bing'),
  ('百度', 'https://www.baidu.com/s?wd=', 'baidu'),
  ('谷歌', 'https://www.google.com/search?q=', 'google'),
  ('DuckDuckGo', 'https://duckduckgo.com/?q=', 'ddg'),
  ('搜狗', 'https://www.sogou.com/web?query=', 'sogou'),
];

// 广告/跟踪域名拦截清单(参照开源广告过滤思路, 域名级拦截)
const kAdHosts = <String>[
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'google-analytics.com',
  'adservice.google.com', 'ads.yahoo.com', 'adnxs.com', 'advertising.com', 'criteo.com',
  'criteo.net', 'taboola.com', 'outbrain.com', 'moatads.com', 'scorecardresearch.com',
  'amazon-adsystem.com', 'facebook.net', 'ads.twitter.com', 'analytics.twitter.com',
  'cpro.baidu.com', 'pos.baidu.com', 'hm.baidu.com', 'eclick.baidu.com', 'baidustatic.com/af',
  'union.msn.com', 'ads.msn.com', 'adsymptotic.com', '2mdn.net', 'admob.com', 'inmobi.com',
  'umeng.com', 'cnzz.com', 'admaster.com.cn', 'miaozhen.com', 'monitor.volcvod.com',
  'vungle.com', 'applovin.com', 'unity3d.com/ads', 'chartboost.com', 'ironsrc.com',
  'mopub.com', 'flurry.com', 'adjust.com', 'appsflyer.com', 'branch.io',
];

class BrowserPage extends StatefulWidget {
  final String? initialUrl;
  const BrowserPage({super.key, this.initialUrl});
  @override State<BrowserPage> createState() => _Bp();
}
class _Bp extends State<BrowserPage> {
  final List<_Tab> tabs = [_Tab('')];
  int cur = 0;
  final addr = TextEditingController();
  final FocusNode addrFocus = FocusNode();
  bool editing = false; // 首页/编辑地址模式
  bool fullscreen = false; // 全屏: 连地址栏也隐藏, 点悬浮钮恢复
  List<Map<String, String>> bookmarks = [];
  List<Map<String, String>> history = [];
  String engine = 'bing';
  bool adblock = true;
  // ── B 组(4.40.0): 夜间注入 / 边缘手势 / 长截图边界 ──
  bool nightMode = false;
  bool edgeGesture = true;
  final GlobalKey _shotKey = GlobalKey();
  Offset? _edgeStart;

  @override void initState() { super.initState(); _load();
    if ((widget.initialUrl ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(widget.initialUrl!, newTab: tabs.first.url.isNotEmpty));
    }
  }
  @override void dispose() { addr.dispose(); addrFocus.dispose(); super.dispose(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    try { bookmarks = [ for (final e in jsonDecode(p.getString('browser_bookmarks') ?? '[]') as List) Map<String, String>.from(e) ]; } catch (_) {}
    try { history = [ for (final e in jsonDecode(p.getString('browser_history') ?? '[]') as List) Map<String, String>.from(e) ]; } catch (_) {}
    engine = p.getString('browser_engine') ?? 'bing';
    adblock = p.getBool('browser_adblock') ?? true;
    nightMode = p.getBool('browser_night') ?? false;
    edgeGesture = p.getBool('browser_gesture') ?? true;
    if (mounted) setState(() {});
  }

  // ── 长截图: 把当前视口渲染成 PNG(平台视图在混合合成下可被 RepaintBoundary 捕获) ──
  Future<Uint8List?> _capturePng() async {
    try {
      final obj = _shotKey.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return null;
      final img = await obj.toImage(pixelRatio: 1.4);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return bd?.buffer.asUint8List();
    } catch (_) { return null; }
  }

  // ── 边缘手势: 只在屏幕左右 34px 内起手, 且水平位移够大才算(不干扰网页自身滑动) ──
  void _onEdgeDown(PointerDownEvent e) {
    if (!edgeGesture) { _edgeStart = null; return; }
    final w = MediaQuery.of(context).size.width;
    final dx = e.position.dx;
    _edgeStart = (dx < 34 || dx > w - 34) ? e.position : null;
  }
  Future<void> _onEdgeUp(PointerUpEvent e) async {
    final s = _edgeStart; _edgeStart = null;
    if (s == null || !edgeGesture) return;
    final dx = e.position.dx - s.dx;
    final dy = e.position.dy - s.dy;
    if (dx.abs() < 72 || dy.abs() > 64) return;
    if (dx > 0) { if ((await t.ctrl?.canGoBack()) ?? false) t.ctrl!.goBack(); }
    else { if ((await t.ctrl?.canGoForward()) ?? false) t.ctrl!.goForward(); }
  }

  BrowserProHost _proHost() => BrowserProHost(
    url: () => t.url,
    title: () => t.title,
    run: (js) async { try { await t.ctrl?.runJavaScript(js); } catch (_) {} },
    eval: (js) async { try { return '${await t.ctrl?.runJavaScriptReturningResult(js)}'; } catch (_) { return ''; } },
    shot: _capturePng,
    reload: () async { try { await t.ctrl?.reload(); } catch (_) {} },
    canBack: () async => (await t.ctrl?.canGoBack()) ?? false,
    canForward: () async => (await t.ctrl?.canGoForward()) ?? false,
    goBack: () async { try { await t.ctrl?.goBack(); } catch (_) {} },
    goForward: () async { try { await t.ctrl?.goForward(); } catch (_) {} },
    bookmarks: () async => bookmarks,
    setBookmarks: (l) async { setState(() => bookmarks = l); await _save('browser_bookmarks', l); },
    toast: (m) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2))); },
    onChanged: () { if (mounted) setState(() {}); },
  );
  Future<void> _save(String key, List<Map<String, String>> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(list));
  }

  _Tab get t => tabs[cur];

  static bool _isAd(String url) {
    final u = url.toLowerCase();
    for (final h in kAdHosts) { if (u.contains(h)) return true; }
    return false;
  }

  void _engineSheet() {
    showModalBottomSheet(context: context, builder: (c2) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('搜索引擎', style: TextStyle(fontWeight: FontWeight.bold))),
      for (final e in kSearchEngines)
        ListTile(dense: true, title: Text(e.$1), subtitle: Text(e.$2, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          trailing: engine == e.$3 ? const Icon(Icons.check, color: Colors.blueAccent) : null,
          onTap: () async {
            setState(() => engine = e.$3);
            final p = await SharedPreferences.getInstance();
            await p.setString('browser_engine', e.$3);
            if (c2.mounted) Navigator.pop(c2);
          }),
      const SizedBox(height: 8),
    ])));
  }

  Future<void> _toggleAdblock() async {
    setState(() => adblock = !adblock);
    final p = await SharedPreferences.getInstance();
    await p.setBool('browser_adblock', adblock);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(adblock ? '广告拦截已开启' : '广告拦截已关闭'), duration: const Duration(seconds: 1)));
  }

  String _normalize(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    final isUrl = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s) ||
      (RegExp(r'^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$').hasMatch(s) && !s.contains(' '));
    if (isUrl) { if (!s.contains('://')) s = 'https://$s'; return s; }
    final tpl = kSearchEngines.firstWhere((e) => e.$3 == engine, orElse: () => kSearchEngines.first).$2;
    return '$tpl${Uri.encodeComponent(s)}';
  }

  WebViewController _ensureCtrl(_Tab tab) {
    if (tab.ctrl != null) return tab.ctrl!;
    final c = WebViewController();
    c.setJavaScriptMode(JavaScriptMode.unrestricted);
    c.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (req) {
        if (adblock && _isAd(req.url)) return NavigationDecision.prevent;
        return NavigationDecision.navigate;
      },
      onProgress: (p) { if (mounted) setState(() => tab.progress = p); },
      onPageStarted: (u) {
        if (mounted) setState(() { tab.url = u; });
        // B-7 UA 记忆: 按域名取用户记住的标识(影响本标签页后续所有请求)
        BrowserPro.uaFor(u).then((ua) async { if (ua.isNotEmpty) { try { await c.setUserAgent(ua); } catch (_) {} } });
      },
      onPageFinished: (u) async {
        final title = await c.getTitle() ?? '';
        if (mounted) setState(() { tab.url = u; if (title.isNotEmpty) tab.title = title; });
        _recordHistory(title.isNotEmpty ? title : u, u);
        // B-9 夜间模式: 换页后自动续用
        if (nightMode) { try { await c.runJavaScript(BrowserPro.jsNight(true)); } catch (_) {} }
        if (adblock) {
          c.runJavaScript("""(function(){
            if (window.__thAdClean) return; window.__thAdClean = true;
            const s = document.createElement('style');
            s.textContent = 'iframe[src*="ad"], div[id*="ad-"], div[class*="ad-"], ins.adsbygoogle, [class*="banner-ad"], [id*="banner-ad"] { display: none !important; }';
            document.head.appendChild(s);
            const kill = () => document.querySelectorAll('ins.adsbygoogle, .adsbox, [data-ad], [aria-label="Advertisement"]').forEach(e => e.remove());
            kill(); setInterval(kill, 3000);
          })();""");
        }
      },
    ));
    tab.ctrl = c;
    if (tab.url.isNotEmpty) c.loadRequest(Uri.parse(tab.url));
    return c;
  }

  void _recordHistory(String title, String url) {
    if (url.isEmpty || url == 'about:blank') return;
    if (t.incognito) return; // 无痕标签不写历史
    history.removeWhere((h) => h['url'] == url);
    history.insert(0, {'title': title, 'url': url, 'at': DateTime.now().toString().substring(0, 16)});
    history = history.take(200).toList();
    _save('browser_history', history);
  }

  void _open(String input, {bool newTab = false}) {
    final url = _normalize(input);
    if (url.isEmpty) return;
    addrFocus.unfocus();
    setState(() {
      editing = false;
      if (newTab) { tabs.add(_Tab(url)); cur = tabs.length - 1; }
      else { t.url = url; t.title = url; if (t.ctrl != null) t.ctrl!.loadRequest(Uri.parse(url)); }
    });
    if (tabs[cur].ctrl == null) _ensureCtrl(tabs[cur]);
  }

  bool get _showHome => t.ctrl == null || t.url.isEmpty || editing;

  @override Widget build(BuildContext c) {
    return Stack(children: [
      Column(children: [
        // 地址栏(全屏时隐藏, 屏幕全给网页)
        if (!fullscreen) SafeArea(bottom: false, child: Padding(padding: const EdgeInsets.fromLTRB(6, 6, 6, 4), child: Row(children: [
          IconButton(icon: const Icon(Icons.grid_view_rounded, size: 20), tooltip: '标签页',
            onPressed: _tabSheet),
          Expanded(child: TextField(controller: addr, focusNode: addrFocus, keyboardType: TextInputType.url,
            decoration: InputDecoration(hintText: '搜索或输入网址', isDense: true, filled: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => addr.clear()),
              border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(22)), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
            onTap: () { addr.text = t.url; addr.selection = TextSelection(baseOffset: 0, extentOffset: addr.text.length); setState(() => editing = true); },
            onSubmitted: (v) => _open(v))),
          IconButton(icon: Icon(_isBookmarked(t.url) ? Icons.bookmark : Icons.bookmark_border, size: 20), tooltip: '书签',
            onPressed: _toggleBookmark),
          // 导航控制收进菜单(不再单独占一行)
          PopupMenuButton<String>(icon: const Icon(Icons.more_vert, size: 20), onSelected: _onMenu, itemBuilder: (_) => [
            const PopupMenuItem(value: 'back', child: ListTile(dense: true, leading: Icon(Icons.arrow_back, size: 18), title: Text('后退', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'forward', child: ListTile(dense: true, leading: Icon(Icons.arrow_forward, size: 18), title: Text('前进', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'refresh', child: ListTile(dense: true, leading: Icon(Icons.refresh, size: 18), title: Text('刷新', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'fullscreen', child: ListTile(dense: true, leading: Icon(Icons.fullscreen, size: 18), title: Text('全屏浏览', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'readmode', child: ListTile(dense: true, leading: Icon(Icons.menu_book_outlined, size: 18), title: Text('阅读模式(交给小说阅读器)', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'incognito', child: ListTile(dense: true, leading: Icon(Icons.visibility_off_outlined, size: 18), title: Text('新建无痕标签页', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'newtab', child: ListTile(dense: true, leading: Icon(Icons.add, size: 18), title: Text('新建标签页', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'bookmarks', child: ListTile(dense: true, leading: Icon(Icons.bookmark_border, size: 18), title: Text('书签', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'history', child: ListTile(dense: true, leading: Icon(Icons.history, size: 18), title: Text('历史记录', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'home', child: ListTile(dense: true, leading: Icon(Icons.home_outlined, size: 18), title: Text('回到主页', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'engine', child: ListTile(dense: true, leading: Icon(Icons.travel_explore, size: 18), title: Text('切换搜索引擎', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'adblock', child: ListTile(dense: true, leading: Icon(Icons.block, size: 18), title: Text('广告拦截 开/关', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'translate', child: ListTile(dense: true, leading: Icon(Icons.translate, size: 18), title: Text('翻译本页正文', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'longshot', child: ListTile(dense: true, leading: Icon(Icons.photo_size_select_large, size: 18), title: Text('整页长截图存相册', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'night', child: ListTile(dense: true, leading: Icon(Icons.dark_mode_outlined, size: 18), title: Text('夜间模式 开/关', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuItem(value: 'pro', child: ListTile(dense: true, leading: Icon(Icons.tune, size: 18), title: Text('浏览器增强(UA/手势/书签同步)', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'modules', child: ListTile(dense: true, leading: Icon(Icons.apps, size: 18), title: Text('切换模块', style: TextStyle(fontSize: 13)), contentPadding: EdgeInsets.zero)),
          ]),
        ]))),
        // 进度条
        if (!fullscreen && !_showHome && t.progress < 100) LinearProgressIndicator(value: t.progress / 100, minHeight: 2),
        // 内容区: RepaintBoundary 供长截图, Listener 只监听指针(不拦截网页自身事件) → 边缘手势
        Expanded(child: Listener(
          onPointerDown: _onEdgeDown,
          onPointerUp: _onEdgeUp,
          child: RepaintBoundary(key: _shotKey, child: _showHome ? _homeView(c) : IndexedStack(
            index: cur,
            children: [ for (final tab in tabs) tab.ctrl == null || tab.url.isEmpty ? const SizedBox() : WebViewWidget(controller: _ensureCtrl(tab)) ],
          )),
        )),
      ]),
      // 全屏模式: 右下角悬浮钮(点按退出全屏; 长按打开模块宫格)
      if (fullscreen) Positioned(right: 14, bottom: 18, child: GestureDetector(
        onTap: () => setState(() => fullscreen = false),
        onLongPress: () => BrowserHooks.openModules?.call(context),
        child: Container(width: 44, height: 44, decoration: BoxDecoration(
            color: Theme.of(c).colorScheme.primaryContainer.withValues(alpha: 0.92), shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 8)]),
          child: Icon(Icons.fullscreen_exit, size: 22, color: Theme.of(c).colorScheme.primary)))),
    ]);
  }

  Future<void> _onMenu(String v) async {
    switch (v) {
      case 'back': if (await t.ctrl?.canGoBack() ?? false) t.ctrl!.goBack(); break;
      case 'forward': if (await t.ctrl?.canGoForward() ?? false) t.ctrl!.goForward(); break;
      case 'refresh': t.ctrl?.reload(); break;
      case 'fullscreen': setState(() => fullscreen = true); break;
      case 'readmode': _readMode(); break;
      case 'incognito': setState(() { tabs.add(_Tab('', incognito: true)); cur = tabs.length - 1; editing = true; }); break;
      case 'bookmarks': _listSheet('书签', bookmarks); break;
      case 'history': _listSheet('历史', history); break;
      case 'home': setState(() { editing = true; }); break;
      case 'newtab': setState(() { tabs.add(_Tab('')); cur = tabs.length - 1; editing = true; }); break;
      case 'modules': BrowserHooks.openModules?.call(context); break;
      case 'engine': _engineSheet(); break;
      case 'adblock': _toggleAdblock(); break;
      case 'translate': await runTranslateFlow(context, _proHost()); break;
      case 'longshot': await runLongShotFlow(context, _proHost()); break;
      case 'night': await _toggleNight(); break;
      case 'pro': await showBrowserPro(context, _proHost()); break;
    }
  }

  // B-9 夜间模式的快捷开关(菜单里一点即用)
  Future<void> _toggleNight() async {
    final v = !nightMode;
    setState(() => nightMode = v);
    final p = await SharedPreferences.getInstance();
    await p.setBool('browser_night', v);
    try { await t.ctrl?.runJavaScript(BrowserPro.jsNight(v)); } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(v ? '夜间模式已开启(换页自动续用)' : '夜间模式已关闭'),
          duration: const Duration(seconds: 1)));
    }
  }

  // 阅读模式: 从当前网页提取正文 → 一键交给小说阅读器(跨模块调用)
  // 提取策略(Readability-lite): 优先 <article>/<main>, 否则取 p 最多的最大文本块
  Future<void> _readMode() async {
    final ctrl = t.ctrl;
    if (ctrl == null || t.url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先打开一个网页')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('正在提取正文…'), duration: Duration(seconds: 1)));
    String title = t.title; String text = '';
    try {
      final r = await ctrl.runJavaScriptReturningResult('''
(() => {
  const art = document.querySelector('article') || document.querySelector('main');
  let best = art, bestLen = art ? (art.innerText || '').length : 0;
  if (bestLen < 400) {
    document.querySelectorAll('div,section').forEach(e => {
      const tx = e.innerText || '';
      if (tx.length > bestLen && e.querySelectorAll('p').length >= 2) { best = e; bestLen = tx.length; }
    });
  }
  const text = ((best ? best.innerText : document.body.innerText) || '').trim();
  return JSON.stringify({ title: document.title || '', text: text.slice(0, 300000) });
})()''');
      var s = '$r';
      // Android webview 返回带引号的 JSON 串, 剥一层
      if (s.startsWith('"')) { try { s = jsonDecode(s) as String; } catch (_) {} }
      final j = jsonDecode(s) as Map;
      title = '${j['title'] ?? title}'.trim();
      text = '${j['text'] ?? ''}'.trim();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('正文提取失败: $e')));
      return;
    }
    if (text.length < 200) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('这页提取不到成段正文(可能是列表页/脚本页)')));
      return;
    }
    // 落成临时 txt 交给阅读器(与本地书同一条通路, 排版/听书/进度记忆全部继承)
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/readmode_${DateTime.now().millisecondsSinceEpoch}.txt');
    await f.writeAsString('$title\n\n$text', flush: true);
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => LocalNovelReader(
      book: {'name': title.isEmpty ? '网页正文' : title, 'path': f.path, 'format': 'txt'})));
  }

  bool _isBookmarked(String url) => url.isNotEmpty && bookmarks.any((b) => b['url'] == url);
  void _toggleBookmark() {
    if (t.url.isEmpty) return;
    setState(() {
      if (_isBookmarked(t.url)) { bookmarks.removeWhere((b) => b['url'] == t.url); }
      else { bookmarks.insert(0, {'title': t.title, 'url': t.url}); }
    });
    _save('browser_bookmarks', bookmarks);
  }

  // 主页: 书签 + 历史
  Widget _homeView(BuildContext c) => ListView(padding: const EdgeInsets.all(12), children: [
    if (bookmarks.isNotEmpty) ...[
      const Text('书签', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final b in bookmarks.take(20)) ActionChip(
          avatar: const Icon(Icons.bookmark, size: 14),
          label: Text(b['title']!.isNotEmpty ? b['title']! : b['url']!, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
          onPressed: () => _open(b['url']!)),
      ]),
      const SizedBox(height: 16),
    ],
    if (history.isNotEmpty) ...[
      Row(children: [ const Text('最近访问', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
        const Spacer(),
        TextButton(onPressed: () { setState(() => history = []); _save('browser_history', history); },
          child: const Text('清空', style: TextStyle(fontSize: 11))) ]),
      for (final h in history.take(30)) ListTile(dense: true,
        leading: const Icon(Icons.language, size: 18),
        title: Text(h['title'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
        subtitle: Text(h['url'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        onTap: () => _open(h['url']!)),
    ],
    if (bookmarks.isEmpty && history.isEmpty) const Padding(padding: EdgeInsets.all(48),
      child: Center(child: Text('在上方地址栏搜索或输入网址', style: TextStyle(color: Colors.grey)))),
  ]);

  // 标签页管理
  void _tabSheet() {
    showModalBottomSheet(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.all(8), child: Row(children: [
        Text('标签页 (${tabs.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        TextButton.icon(onPressed: () { setState(() { tabs.add(_Tab('', incognito: true)); cur = tabs.length - 1; editing = true; }); Navigator.pop(c2); },
          icon: const Icon(Icons.visibility_off_outlined, size: 16), label: const Text('无痕')),
        TextButton.icon(onPressed: () { setState(() { tabs.add(_Tab('')); cur = tabs.length - 1; editing = true; }); Navigator.pop(c2); },
          icon: const Icon(Icons.add, size: 16), label: const Text('新建')),
      ])),
      SizedBox(height: 220, child: GridView.builder(padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 1.3),
        itemCount: tabs.length, itemBuilder: (_, i) {
          final tab = tabs[i];
          return Card(color: i == cur ? Theme.of(c2).colorScheme.primaryContainer : null,
            child: InkWell(onTap: () { setState(() { cur = i; editing = tab.url.isEmpty; }); Navigator.pop(c2); },
              child: Stack(children: [
                Padding(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(tab.incognito ? Icons.visibility_off_outlined : Icons.language, size: 16,
                    color: tab.incognito ? Colors.deepPurple : null),
                  const Spacer(),
                  Text(tab.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ])),
                if (tabs.length > 1) Positioned(top: 0, right: 0, child: GestureDetector(
                  onTap: () { setState(() { tabs.removeAt(i); if (cur >= tabs.length) cur = tabs.length - 1; if (cur > i) cur--; }); setD(() {}); },
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 14)))),
              ])));
        })),
    ]))));
  }

  // 书签/历史列表弹层
  void _listSheet(String title, List<Map<String, String>> list) {
    showModalBottomSheet(context: context, builder: (c2) => SafeArea(child: SizedBox(height: 420, child: Column(children: [
      Padding(padding: const EdgeInsets.all(8), child: Row(children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        if (list.isNotEmpty) TextButton(onPressed: () { setState(() => list.clear());
          _save(title == '书签' ? 'browser_bookmarks' : 'browser_history', list); Navigator.pop(c2); },
          child: const Text('清空', style: TextStyle(fontSize: 12))),
      ])),
      Expanded(child: list.isEmpty ? const Center(child: Text('暂无记录', style: TextStyle(color: Colors.grey)))
        : ListView(children: [ for (final e in list) ListTile(dense: true,
            leading: const Icon(Icons.language, size: 18),
            title: Text(e['title'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Text(e['url'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
            onTap: () { Navigator.pop(c2); _open(e['url']!); }) ])),
    ]))));
  }
}
