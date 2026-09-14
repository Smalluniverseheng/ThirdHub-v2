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
import 'package:just_audio/just_audio.dart';

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
  static const tabs = [('首页', Icons.home), ('小说', Icons.menu_book), ('漫画', Icons.photo_library), ('视频', Icons.play_circle), ('音乐', Icons.music_note), ('资源库', Icons.link)];
  void snap() { final w = MediaQuery.of(context).size.width;
    setState(() => orb = Offset((orb.dx + orbSize / 2) < w / 2 ? 12 : w - orbSize - 12, orb.dy.clamp(80.0, MediaQuery.of(context).size.height - 160))); }
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(title: Text(tabs[tab].$1), actions: [
        if (tab >= 1 && tab <= 4) IconButton(icon: const Icon(Icons.search), onPressed: () => showSearch(context: context, delegate: ThSearchDelegate(tab))),
        IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectLibraryPage()))),
      ]),
      body: Stack(children: [
        [const HomeSection(), const NovelSection(), const ComicSection(), const VideoSection(), const MusicSection(),
         const Center(child: Text('资源库状态正常\n连接信息在"连接资源库"页查看', textAlign: TextAlign.center))][tab],
        if (menu) GestureDetector(onTap: () => setState(() => menu = false), child: Container(color: Colors.black54)),
        if (menu) Positioned(left: orb.dx.clamp(8, size.width - 76), top: (orb.dy - 380).clamp(70.0, size.height - 470),
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

// ═══ 首页: 聚合搜索(书+漫+影一次搜) ═══
class HomeSection extends StatefulWidget { const HomeSection({super.key}); @override State<HomeSection> createState() => _Home(); }
class _Home extends State<HomeSection> {
  final ctrl = TextEditingController(); Map<String, dynamic>? agg; bool loading = false;
  Future<void> go() async { final q = ctrl.text.trim(); if (q.isEmpty) return;
    setState(() { loading = true; agg = null; });
    try { final r = await Api.get('/v1/search/all?q=${Uri.encodeComponent(q)}'); setState(() { agg = r['data']; }); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  Widget group(String title, List items, Widget Function(Map) tile) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (items.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text('$title (${items.length})', style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold))),
    for (final it in items) tile(it),
  ]);
  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '一次搜索: 书 / 漫画 / 视频', border: OutlineInputBorder(), prefixIcon: Icon(Icons.search)), onSubmitted: (_) => go())),
      IconButton(icon: const Icon(Icons.arrow_forward), onPressed: go)])),
    if (loading) const LinearProgressIndicator(),
    if (agg != null) Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: Align(alignment: Alignment.centerLeft,
      child: Text('书源${agg!['stats']?['bookSources'] ?? 0} · 图源${agg!['stats']?['comicSources'] ?? 0} · 影视源${agg!['stats']?['videoSources'] ?? 0} · 音源${agg!['stats']?['musicSources'] ?? 0}', style: const TextStyle(fontSize: 11, color: Colors.grey)))),
    Expanded(child: ListView(children: [
      if (agg != null) ...[
        for (final g in (agg!['books'] as List? ?? []))
          group('📖 ${g['source']}', (g['books'] as List? ?? []).cast<Map>(), (b) => ListTile(
            dense: true, title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(b)))))),
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
      if (agg == null && !loading) const Padding(padding: EdgeInsets.all(40), child: Text('输入关键词, 一次搜遍书/漫画/视频', style: TextStyle(color: Colors.grey))),
    ])), ]); }

// ═══ 板块一: 小说阅读器(功能完整) ═══
class NovelSection extends StatefulWidget { const NovelSection({super.key}); @override State<NovelSection> createState() => _Nv(); }
class _Nv extends State<NovelSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('书架')), ButtonSegment(value: 1, label: Text('搜索')), ButtonSegment(value: 2, label: Text('源'))],
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
  final Map<int, Map> chapCache = {}; // 预加载: 章index → content数据
  int theme = 0; // 0夜间 1白天 2护眼
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
              child: SelectableText(text, style: TextStyle(fontSize: fontSize, height: 1.8, color: t.$2))))),
        SafeArea(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          TextButton.icon(onPressed: hasPrev ? () => goChapter(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: const Text('上一章')),
          TextButton.icon(onPressed: hasNext ? () => goChapter(idx + 1) : null, label: const Text('下一章'), icon: const Icon(Icons.chevron_right)),
        ]))])); }
}

// ═══ 板块二: 漫画播放器(UI先行, 数据源待后端comic引擎) ═══
class ComicSection extends StatefulWidget { const ComicSection({super.key}); @override State<ComicSection> createState() => _Cs(); }
class _Cs extends State<ComicSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('书架')), ButtonSegment(value: 1, label: Text('搜索')), ButtonSegment(value: 2, label: Text('源'))],
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
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.tealAccent, fontSize: 12))),
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
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已加入书架'))); }
  void openAt(int i) => Navigator.push(context, MaterialPageRoute(builder: (_) => ComicReaderPage(
    sourceId: widget.sourceId, comicId: widget.comicId, chapters: chapters, index: i))).then((_) => load());
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.title), actions: [
      IconButton(icon: const Icon(Icons.bookmark_add), onPressed: save),
      Text('  ${chapters.length}话  ', style: const TextStyle(color: Colors.grey))]),
    body: loading ? const Center(child: CircularProgressIndicator())
    : err != null ? Center(child: Text(err!, style: const TextStyle(color: Colors.red)))
    : Column(children: [
      if (lastRead >= 0 && lastRead < chapters.length) MaterialBanner(content: Text('上次读到: ${chapters[lastRead]['title']}'),
        actions: [TextButton(onPressed: () => openAt(lastRead), child: const Text('继续阅读')),
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
        : images.isEmpty ? const Center(child: Text('本章无图片')
        : ListView.builder(itemCount: images.length, itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 1),
            child: InteractiveViewer(child: Image.network(Api.img(images[i]), fit: BoxFit.fitWidth,
              loadingBuilder: (_, w, p) => p == null ? w : const SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
              errorBuilder: (_, __, ___) => const SizedBox(height: 120, child: Center(child: Icon(Icons.broken_image, color: Colors.grey))))))),
      SafeArea(child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        TextButton.icon(onPressed: hasPrev ? () => goChapter(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: const Text('上一话')),
        TextButton.icon(onPressed: hasNext ? () => goChapter(idx + 1) : null, label: const Text('下一话'), icon: const Icon(Icons.chevron_right)),
      ]))])); }

// ═══ 源管理(四类通用: 列表/启停/删除/粘贴导入) ═══
class SourceManagerPage extends StatefulWidget { final String kind; const SourceManagerPage({super.key, required this.kind}); @override State<SourceManagerPage> createState() => _SM(); }
class _SM extends State<SourceManagerPage> {
  static const cfgs = {
    'book':  (list: '/v1/sources', imp: '/v1/sources', label: '书源', hint: '粘贴书源JSON(单条或数组)'),
    'video': (list: '/v1/video/sources', imp: '/v1/video/sources', label: '影视源', hint: '粘贴{name, code}JSON'),
    'comic': (list: '/v1/comic/sources', imp: '/v1/comic/sources', label: '图源', hint: '粘贴{name, code}JSON'),
    'music': (list: '/v1/music/sources', imp: '/v1/music/sources', label: '音源', hint: '粘贴{name, code}JSON'),
  };
  List<Map> items = []; bool loading = true; final importC = TextEditingController(); String? msg;
  String get kind => widget.kind;
  (String, String, String, String) get cfg => cfgs[kind]!;
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
      FilledButton(onPressed: doImport, child: const Text('导入')),
    ])),
    if (msg != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(msg!, style: const TextStyle(fontSize: 12, color: Colors.tealAccent))),
  ]); }

// ═══ 板块四: 音乐播放器 ═══
class MusicSection extends StatefulWidget { const MusicSection({super.key}); @override State<MusicSection> createState() => _Ms(); }
class _Ms extends State<MusicSection> { int sub = 0;
  @override Widget build(BuildContext c) => Column(children: [
    SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('歌单')), ButtonSegment(value: 1, label: Text('搜索')), ButtonSegment(value: 2, label: Text('源'))],
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
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']} (${g['latency']}ms)', style: const TextStyle(color: Colors.tealAccent, fontSize: 12))),
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
    SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('片库')), ButtonSegment(value: 1, label: Text('搜索')), ButtonSegment(value: 2, label: Text('源'))],
      selected: {sub}, onSelectionChanged: (s) => setState(() => sub = s.first)),
    Expanded(child: [const ShelfPage(kind: 'video', builder: _videoDetail),
      const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('点右上角搜索框找片', style: TextStyle(color: Colors.grey)))),
      const SourceManagerPage(kind: 'video')][sub]),
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
            sourceId: widget.sourceId, epUrl: episodes[i]['url'] ?? '', flag: episodes[i]['flag'] ?? '',
            title: episodes[i]['name'] ?? '', episodes: episodes, index: i))),
        ))])); }

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
          TextButton.icon(onPressed: hasPrev ? () => goEpisode(idx - 1) : null, icon: const Icon(Icons.chevron_left), label: const Text('上一集')),
          TextButton.icon(onPressed: hasNext ? () => goEpisode(idx + 1) : null, label: const Text('下一集'), icon: const Icon(Icons.chevron_right)),
        ]))])); }
