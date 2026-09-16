// 浏览器模块: 自研实现(参考 FOSS Browser / Privacy Browser 的功能设计, 无代码拷贝, 无协议冲突)
// 多标签页 · 地址栏(搜索/网址) · 前进后退刷新 · 书签 · 历史 · 进度条
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

class _Tab {
  WebViewController? ctrl; String url = ''; String title = '新标签页'; int progress = 0;
  _Tab(this.url);
}

class BrowserPage extends StatefulWidget { const BrowserPage({super.key}); @override State<BrowserPage> createState() => _Bp(); }
class _Bp extends State<BrowserPage> {
  final List<_Tab> tabs = [_Tab('')];
  int cur = 0;
  final addr = TextEditingController();
  bool editing = false; // 首页/编辑地址模式
  List<Map<String, String>> bookmarks = [];
  List<Map<String, String>> history = [];

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    try { bookmarks = [ for (final e in jsonDecode(p.getString('browser_bookmarks') ?? '[]') as List) Map<String, String>.from(e) ]; } catch (_) {}
    try { history = [ for (final e in jsonDecode(p.getString('browser_history') ?? '[]') as List) Map<String, String>.from(e) ]; } catch (_) {}
    if (mounted) setState(() {});
  }
  Future<void> _save(String key, List<Map<String, String>> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(list));
  }

  _Tab get t => tabs[cur];

  String _normalize(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    final isUrl = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s) ||
      (RegExp(r'^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$').hasMatch(s) && !s.contains(' '));
    if (isUrl) { if (!s.contains('://')) s = 'https://$s'; return s; }
    return 'https://www.bing.com/search?q=${Uri.encodeComponent(s)}';
  }

  WebViewController _ensureCtrl(_Tab tab) {
    if (tab.ctrl != null) return tab.ctrl!;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) { if (mounted) setState(() => tab.progress = p); },
        onPageStarted: (u) { if (mounted) setState(() { tab.url = u; }); },
        onPageFinished: (u) async {
          final title = await c.getTitle() ?? '';
          if (mounted) setState(() { tab.url = u; if (title.isNotEmpty) tab.title = title; });
          _recordHistory(title.isNotEmpty ? title : u, u);
        },
      ));
    tab.ctrl = c;
    if (tab.url.isNotEmpty) c.loadRequest(Uri.parse(tab.url));
    return c;
  }

  void _recordHistory(String title, String url) {
    if (url.isEmpty || url == 'about:blank') return;
    history.removeWhere((h) => h['url'] == url);
    history.insert(0, {'title': title, 'url': url, 'at': DateTime.now().toString().substring(0, 16)});
    history = history.take(200).toList();
    _save('browser_history', history);
  }

  void _open(String input, {bool newTab = false}) {
    final url = _normalize(input);
    if (url.isEmpty) return;
    setState(() {
      editing = false;
      if (newTab) { tabs.add(_Tab(url)); cur = tabs.length - 1; }
      else { t.url = url; t.title = url; if (t.ctrl != null) t.ctrl!.loadRequest(Uri.parse(url)); }
    });
    if (tabs[cur].ctrl == null) _ensureCtrl(tabs[cur]);
  }

  bool get _showHome => t.ctrl == null || t.url.isEmpty || editing;

  @override Widget build(BuildContext c) {
    return Column(children: [
      // 地址栏
      SafeArea(bottom: false, child: Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 4), child: Row(children: [
        IconButton(icon: const Icon(Icons.grid_view_rounded, size: 20), tooltip: '标签页',
          onPressed: _tabSheet),
        Expanded(child: TextField(controller: addr, keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: '搜索或输入网址', isDense: true, filled: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => addr.clear()),
            border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(22)), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
          onTap: () { addr.text = t.url; addr.selection = TextSelection(baseOffset: 0, extentOffset: addr.text.length); setState(() => editing = true); },
          onSubmitted: (v) => _open(v))),
        IconButton(icon: Icon(_isBookmarked(t.url) ? Icons.bookmark : Icons.bookmark_border, size: 20), tooltip: '书签',
          onPressed: _toggleBookmark),
        PopupMenuButton<String>(icon: const Icon(Icons.more_vert, size: 20), onSelected: (v) {
          if (v == 'bookmarks') _listSheet('书签', bookmarks);
          if (v == 'history') _listSheet('历史', history);
          if (v == 'home') setState(() { t.url = ''; t.ctrl?.clearCache(); editing = true; });
          if (v == 'newtab') setState(() { tabs.add(_Tab('')); cur = tabs.length - 1; editing = true; });
        }, itemBuilder: (_) => const [
          PopupMenuItem(value: 'newtab', child: Text('新建标签页')),
          PopupMenuItem(value: 'bookmarks', child: Text('书签')),
          PopupMenuItem(value: 'history', child: Text('历史记录')),
          PopupMenuItem(value: 'home', child: Text('回到主页')),
        ]),
      ]))),
      // 进度条
      if (!_showHome && t.progress < 100) LinearProgressIndicator(value: t.progress / 100, minHeight: 2),
      // 工具栏(非主页时)
      if (!_showHome) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        IconButton(icon: const Icon(Icons.arrow_back, size: 20), onPressed: () async { if (await t.ctrl?.canGoBack() ?? false) t.ctrl!.goBack(); }),
        IconButton(icon: const Icon(Icons.arrow_forward, size: 20), onPressed: () async { if (await t.ctrl?.canGoForward() ?? false) t.ctrl!.goForward(); }),
        IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: () => t.ctrl?.reload()),
        IconButton(icon: const Icon(Icons.home_outlined, size: 20), onPressed: () => setState(() => editing = true)),
      ])),
      // 内容区
      Expanded(child: _showHome ? _homeView(c) : IndexedStack(
        index: cur,
        children: [ for (final tab in tabs) tab.ctrl == null || tab.url.isEmpty ? const SizedBox() : WebViewWidget(controller: _ensureCtrl(tab)) ],
      )),
    ]);
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
                  const Icon(Icons.language, size: 16),
                  const Spacer(),
                  Text(tab.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ])),
                if (tabs.length > 1) Positioned(top: 0, right: 0, child: GestureDetector(
                  onTap: () { setState(() { tabs.removeAt(i); if (cur >= tabs.length) cur = tabs.length - 1; if (cur > i) cur--; }); setD(() {}); },
                  child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 14)))),
              ]))));
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
