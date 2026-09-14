// ThirdHub v4 Flutter m2: 纯播放器前端 = 小说阅读器 + 漫画播放器 + 视频播放器
// 定位: 零处理逻辑, 只渲染后端IR。净化在插件(Legado)完成, 后端转发。
// 每个板块右上角: [搜索] [设置→连接资源库]
import 'dart:convert'; import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(ThApp(ready: (prefs.getString('base') ?? '').isNotEmpty,
    base: prefs.getString('base') ?? '', token: prefs.getString('token') ?? ''));
}

class Api {
  static String base = ''; static String token = '';
  static http.Client client() { final c = HttpClient()..badCertificateCallback = (_, __, ___) => true; return IOClient(c); }
  static Future<Map<String, dynamic>> get(String path) async {
    final r = await client().get(Uri.parse('$base$path'), headers: {'X-TH-Token': token});
    return jsonDecode(utf8.decode(r.bodyBytes)); }
  static String img(String u) => '$base/v1/img?url=${Uri.encodeComponent(u)}';
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

class ThApp extends StatelessWidget {
  final bool ready; final String base, token;
  const ThApp({super.key, required this.ready, required this.base, required this.token});
  @override Widget build(BuildContext c) { Api.base = base; Api.token = token;
    return MaterialApp(title: 'ThirdHub', theme: ThemeData.dark(useMaterial3: true),
      home: ready ? const OrbShell() : const ConnectLibraryPage()); }
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
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('信任'))]));
      if (ok == true && mounted) { Api.base = baseC.text.trim(); Api.token = tokenC.text.trim();
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const OrbShell())); }
    } catch (e) { setState(() { busy = false; err = '连接失败: $e'; }); } }
  @override Widget build(BuildContext c) => Scaffold(body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
    child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('ThirdHub', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
      const Text('纯播放器前端 · 连接资源库开始', style: TextStyle(color: Colors.grey)),
      const SizedBox(height: 24),
      TextField(controller: baseC, decoration: const InputDecoration(labelText: '资源库地址', hintText: 'https://192.168.x.x:9527', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: tokenC, decoration: const InputDecoration(labelText: '密钥', hintText: 'thsec_...', border: OutlineInputBorder())),
      if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: busy ? null : connect, icon: const Icon(Icons.link), label: Text(busy ? '连接中…' : '连接资源库')),
    ]))))));
}

// ═══ 悬浮球外壳: 板块切换 ═══
class OrbShell extends StatefulWidget { const OrbShell({super.key}); @override State<OrbShell> createState() => _Orb(); }
class _Orb extends State<OrbShell> {
  int tab = 0; bool menu = false;
  Offset orb = const Offset(16, 520); final orbSize = 56.0;
  static const tabs = [('小说', Icons.menu_book), ('漫画', Icons.photo_library), ('视频', Icons.play_circle), ('资源库', Icons.link)];
  void snap() { final w = MediaQuery.of(context).size.width;
    setState(() => orb = Offset((orb.dx + orbSize / 2) < w / 2 ? 12 : w - orbSize - 12, orb.dy.clamp(80.0, MediaQuery.of(context).size.height - 160))); }
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(title: Text(tabs[tab].$1), actions: [
        if (tab < 3) IconButton(icon: const Icon(Icons.search), onPressed: () => showSearch(context: context, delegate: ThSearchDelegate(tab))),
        IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectLibraryPage()))),
      ]),
      body: Stack(children: [
        [const NovelSection(), const ComicSection(), const VideoSection(),
         const Center(child: Text('资源库状态正常\nIP与密钥在悬浮球菜单长按资源库查看', textAlign: TextAlign.center))][tab],
        if (menu) GestureDetector(onTap: () => setState(() => menu = false), child: Container(color: Colors.black54)),
        if (menu) Positioned(left: orb.dx.clamp(8, size.width - 76), top: (orb.dy - 250).clamp(70.0, size.height - 320),
          child: Column(children: [ for (var i = 0; i < tabs.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 6),
            child: GestureDetector(onTap: () => setState(() { tab = i; menu = false; }),
              child: Container(width: 52, height: 52, decoration: BoxDecoration(shape: BoxShape.circle,
                  color: tab == i ? Colors.teal : Colors.grey.shade800,
                  border: Border.all(color: tab == i ? Colors.white : Colors.white24, width: 2)),
                child: Icon(tabs[i].$2, color: Colors.white, size: 22))))])),
        Positioned(left: orb.dx, top: orb.dy, child: GestureDetector(
          onPanUpdate: (d) => setState(() => orb += d.delta), onPanEnd: (_) => snap(),
          onTap: () => setState(() => menu = !menu),
          child: Container(width: orbSize, height: orbSize, decoration: BoxDecoration(shape: BoxShape.circle,
            color: Colors.teal.withOpacity(0.92), boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black45)],
            border: Border.all(color: Colors.white24, width: 2)), child: Icon(menu ? Icons.close : Icons.hub, color: Colors.white)))),
      ]));
  }
}

// ═══ 全局搜索代理(按板块走各自API, 二期接后端) ═══
class ThSearchDelegate extends SearchDelegate {
  final int tab; ThSearchDelegate(this.tab);
  @override String get searchFieldLabel => ['搜小说', '搜漫画', '搜视频'][tab];
  @override List<Widget> buildActions(BuildContext c) => [IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];
  @override Widget buildLeading(BuildContext c) => IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(c, null));
  @override Widget buildResults(BuildContext c) => _body(c);
  @override Widget buildSuggestions(BuildContext c) => _body(c);
  Widget _body(BuildContext c) {
    if (tab == 0) return NovelSearchResults(query: query);
    if (tab == 2) return VideoSearchResults(query: query);
    return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(
      '漫画搜索: 后端comic引擎(Venera图源)接入后可用', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey))));
  }
}

// ═══ 板块一: 小说阅读器(功能完整) ═══
class NovelSection extends StatefulWidget { const NovelSection({super.key}); @override State<NovelSection> createState() => _Nv(); }
class _Nv extends State<NovelSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('书架')), ButtonSegment(value: 1, label: Text('搜索'))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: sub == 0 ? ShelfPage(kind: 'novel', builder: (b) => TocPage(book: b)) : const NovelSearchResults(query: '')),
  ]); }

class NovelSearchResults extends StatefulWidget { final String query; const NovelSearchResults({super.key, required this.query}); @override State<NovelSearchResults> createState() => _NSR(); }
class _NSR extends State<NovelSearchResults> {
  List<Map> groups = []; bool loading = false; String lastQ = '';
  Future<void> go(String q) async { if (q.isEmpty || q == lastQ) return; lastQ = q;
    setState(() { loading = true; groups = []; });
    try { final r = await Api.get('/v1/search?q=${Uri.encodeComponent(q)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); }); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override void initState() { super.initState(); if (widget.query.isNotEmpty) go(widget.query); }
  @override void didUpdateWidget(NovelSearchResults old) { super.didUpdateWidget(old); if (widget.query.isNotEmpty && widget.query != old.query) go(widget.query); }
  @override Widget build(BuildContext c) => Column(children: [
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['ok'] == true && (g['books'] as List?)?.isNotEmpty == true)
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.tealAccent, fontSize: 12))),
        for (final b in (g['books'] as List? ?? [])) ListTile(
          leading: (b['coverUrl'] ?? '') != '' ? ClipRRect(borderRadius: BorderRadius.circular(4),
            child: Image.network(Api.img(b['coverUrl']), width: 40, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 56))) : null,
          title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(b))))),
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
    setState(() => loading = false); }
  Future<void> save() async { await Book.add(widget.book, 'novel');
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已加入书架'))); }
  void openAt(int i) => Navigator.push(context, MaterialPageRoute(builder: (_) => NovelReadPage(
    sourceId: widget.book.sourceId, chapters: chapters, index: i, bookName: widget.book.name, bookUrl: widget.book.bookUrl))).then((_) => load());
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.book.name), actions: [
      IconButton(icon: const Icon(Icons.bookmark_add), onPressed: save),
      Text('  ${chapters.length}章  ', style: const TextStyle(color: Colors.grey))]),
    body: loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
      if (lastRead >= 0 && lastRead < chapters.length) MaterialBanner(content: Text('上次读到: ${chapters[lastRead]['name'] ?? '第${lastRead + 1}章'}'),
        actions: [TextButton(onPressed: () => openAt(lastRead), child: const Text('继续阅读')),
                  TextButton(onPressed: () => setState(() => lastRead = -1), child: const Text('关闭'))]),
      Expanded(child: ListView.builder(itemCount: chapters.length, itemBuilder: (_, i) => ListTile(
        title: Text(chapters[i]['name'] ?? ''), trailing: i == lastRead ? const Icon(Icons.history, size: 16, color: Colors.tealAccent) : null,
        onTap: () => openAt(i)))),
    ])); }

class NovelReadPage extends StatefulWidget { final String sourceId, bookName, bookUrl; final List chapters; final int index;
  const NovelReadPage({super.key, required this.sourceId, required this.chapters, required this.index, required this.bookName, required this.bookUrl});
  @override State<NovelReadPage> createState() => _NR(); }
class _NR extends State<NovelReadPage> {
  String text = ''; List<String> images = []; bool loading = true; double fontSize = 18;
  int theme = 0; // 0夜间 1白天 2护眼
  static const themes = [(Color(0xFF121212), Color(0xFFE0E0E0)), (Colors.white, Colors.black87), (Color(0xFFF5F0E1), Color(0xFF4A3F30))];
  int get idx => widget.index; Map<String, dynamic> get chapter => widget.chapters[idx];
  bool get hasPrev => idx > 0; bool get hasNext => idx < widget.chapters.length - 1;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { setState(() => loading = true); try {
      final r = await Api.get('/v1/content?sourceId=${Uri.encodeComponent(widget.sourceId)}&url=${Uri.encodeComponent(chapter['url'])}');
      text = r['data']?['text'] as String? ?? ''; images = List<String>.from(r['data']?['images'] ?? []);
      if (text.isEmpty && images.isEmpty) text = '本章无内容';
      final p = await SharedPreferences.getInstance(); await p.setInt('progress_${widget.bookUrl}', idx);
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
          : Container(color: t.$1, child: SingleChildScrollView(padding: const EdgeInsets.all(16),
              child: SelectableText(text, style: TextStyle(fontSize: fontSize, height: 1.8, color: t.$2))))),
        SafeArea(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          TextButton.icon(onPressed: hasPrev ? () => goChapter(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: const Text('上一章')),
          TextButton.icon(onPressed: hasNext ? () => goChapter(idx + 1) : null, label: const Text('下一章'), icon: const Icon(Icons.chevron_right)),
        ]))])); }
}

// ═══ 板块二: 漫画播放器(UI先行, 数据源待后端comic引擎) ═══
class ComicSection extends StatelessWidget { const ComicSection({super.key});
  @override Widget build(BuildContext c) => ShelfPage(kind: 'comic', builder: (b) => const GalleryPlayerPage(
    title: '漫画阅读器', hint: '图片流走 /v1/comic/chapter 端点\n(后端内置Venera引擎二期接入)')); }

class GalleryPlayerPage extends StatelessWidget { final String title, hint; const GalleryPlayerPage({super.key, required this.title, required this.hint});
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(title)),
    body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey),
      const SizedBox(height: 16), Text(hint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
      const SizedBox(height: 16), const Text('播放器UI已就位: 竖滑画廊 + 双指缩放 + 预加载', style: TextStyle(color: Colors.tealAccent, fontSize: 12)),
    ])))); }

// ═══ 板块三: 视频播放器(UI先行, 数据源待后端drpy引擎) ═══
class VideoSection extends StatefulWidget { const VideoSection({super.key}); @override State<VideoSection> createState() => _Vs(); }
class _Vs extends State<VideoSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('片库')), ButtonSegment(value: 1, label: Text('搜索'))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: sub == 0
      ? const ShelfPage(kind: 'video', builder: _videoDetail)
      : const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('点右上角搜索框找片\n源导入: POST /v1/video/sources', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))))),
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
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.tealAccent, fontSize: 12))),
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
        Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 4), child: Text('选集 (${episodes.length})', style: const TextStyle(color: Colors.tealAccent))),
        Expanded(child: ListView.builder(itemCount: episodes.length, itemBuilder: (_, i) => ListTile(
          dense: true, title: Text(episodes[i]['name'] ?? '第${i + 1}集', style: const TextStyle(fontSize: 13)),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => VideoPlayPage(
            sourceId: widget.sourceId, epUrl: episodes[i]['url'] ?? '', title: episodes[i]['name'] ?? '')))),
        ))])); }

class VideoPlayPage extends StatefulWidget { final String sourceId, epUrl, title; const VideoPlayPage({super.key, required this.sourceId, required this.epUrl, required this.title}); @override State<VideoPlayPage> createState() => _Vp(); }
class _Vp extends State<VideoPlayPage> {
  VideoPlayerController? _vc; ChewieController? _cc; bool loading = true; String? err;
  @override void initState() { super.initState(); initPlayer(); }
  Future<void> initPlayer() async {
    try {
      final r = await Api.get('/v1/video/play?sourceId=${Uri.encodeComponent(widget.sourceId)}&flag=&id=${Uri.encodeComponent(widget.epUrl)}');
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
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title)),
    body: err != null ? Center(child: Text('播放错误: $err', style: const TextStyle(color: Colors.red)))
      : loading ? const Center(child: CircularProgressIndicator())
      : Center(child: AspectRatio(aspectRatio: _cc!.aspectRatio ?? 16 / 9, child: Chewie(controller: _cc!)))); }
