// ThirdHub v4 Flutter M1-iter2: 首启引导页 + 搜索/目录/阅读/书架
import 'dart:convert'; import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final base = prefs.getString('base') ?? '';
  final token = prefs.getString('token') ?? '';
  runApp(ThApp(configured: base.isNotEmpty && token.isNotEmpty, base: base, token: token));
}

class Api {
  static String base = ''; static String token = '';
  static http.Client client() {
    final ctx = HttpClient()..badCertificateCallback = (_, __, ___) => true; // M1局域网, TOFU二期
    return IOClient(ctx);
  }
  static Future<Map<String, dynamic>> get(String path) async {
    final r = await client().get(Uri.parse('$base$path'), headers: {'X-TH-Token': token});
    return jsonDecode(utf8.decode(r.bodyBytes));
  }
}

class ThApp extends StatelessWidget {
  final bool configured; final String base, token;
  const ThApp({super.key, required this.configured, required this.base, required this.token});
  @override
  Widget build(BuildContext c) {
    Api.base = base; Api.token = token;
    return MaterialApp(title: 'ThirdHub', theme: ThemeData.dark(useMaterial3: true),
      home: configured ? const HomePage() : const SetupPage());
  }
}

class SetupPage extends StatefulWidget { const SetupPage({super.key}); @override State<SetupPage> createState() => _Setup(); }
class _Setup extends State<SetupPage> {
  final baseC = TextEditingController(); final tokenC = TextEditingController();
  String? fp; bool testing = false; String? err;
  Future<void> testAndSave() async {
    setState(() { testing = true; err = null; fp = null; });
    try {
      final r = await Api.client().get(Uri.parse('${baseC.text.trim()}/v1/meta'));
      final meta = jsonDecode(r.body);
      fp = meta['data']?['fingerprint']?.toString();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('base', baseC.text.trim());
      await prefs.setString('token', tokenC.text.trim());
      if (!mounted) return;
      setState(() => testing = false);
      // 确认指纹后进入主界面
      final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        title: const Text('确认服务器指纹'),
        content: SelectableText('SHA256:\n$fp\n\n如与后端通知栏显示一致请确认'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('信任并进入'))]));
      if (ok == true && mounted) {
        Api.base = baseC.text.trim(); Api.token = tokenC.text.trim();
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomePage()));
      }
    } catch (e) { setState(() { testing = false; err = '连接失败: $e'; }); }
  }
  @override
  Widget build(BuildContext c) => Scaffold(body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
    child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('ThirdHub', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
      const SizedBox(height: 24),
      TextField(controller: baseC, decoration: const InputDecoration(labelText: '后端地址', hintText: 'https://192.168.x.x:9527', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: tokenC, decoration: const InputDecoration(labelText: '访问密钥', hintText: 'thsec_...', border: OutlineInputBorder())),
      if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: testing ? null : testAndSave, icon: const Icon(Icons.link), label: Text(testing ? '连接中…' : '连接')),
    ]))))));
}

class Book { final String name, author, coverUrl, intro, bookUrl, sourceId;
  Book(this.name, this.author, this.coverUrl, this.intro, this.bookUrl, this.sourceId);
  factory Book.from(Map<String, dynamic> j) => Book(j['name']??'', j['author']??'', j['coverUrl']??'', j['intro']??'', j['bookUrl']??'', j['sourceId']??''); }

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState() => _H(); }
class _H extends State<HomePage> { int tab = 0; final shelf = <Book>[];
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('ThirdHub v4'), actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SetupPage())))]),
    body: tab == 0 ? const SearchPage() : ShelfPage(shelf: shelf),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i)=>setState(()=>tab=i),
      destinations: const [NavigationDestination(icon: Icon(Icons.search), label: '搜索'), NavigationDestination(icon: Icon(Icons.menu_book), label: '书架')]), ); }

class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _S(); }
class _S extends State<SearchPage> {
  final ctrl = TextEditingController(); List<Map> groups = []; bool loading = false;
  Future<void> go() async { setState(() { loading = true; groups = []; });
    try { final r = await Api.get('/v1/search?q=${Uri.encodeComponent(ctrl.text)}'); setState(() { groups = List<Map>.from(r['data'] ?? []); }); }
    catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false); }
  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '书名/作者', border: OutlineInputBorder()), onSubmitted: (_) => go())),
      IconButton(icon: const Icon(Icons.search), onPressed: go)])),
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups) ...[
        if (g['error'] == null && (g['books'] as List?)?.isNotEmpty == true)
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Text('${g['source']}', style: const TextStyle(color: Colors.tealAccent))),
        for (final b in (g['books'] as List? ?? [])) ListTile(
          title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(b))))) ],
    ])), ]); }

class TocPage extends StatefulWidget { final Book book; const TocPage({super.key, required this.book}); @override State<TocPage> createState() => _T(); }
class _T extends State<TocPage> { List chapters = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try {
      final r = await Api.get('/v1/toc?sourceId=${Uri.encodeComponent(widget.book.sourceId)}&url=${Uri.encodeComponent(widget.book.bookUrl)}');
      chapters = r['data'] ?? []; } catch (e) {}
    setState(() => loading = false); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(widget.book.name)),
    body: loading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
      itemCount: chapters.length, itemBuilder: (_, i) => ListTile(title: Text(chapters[i]['name'] ?? ''),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ReadPage(
          sourceId: widget.book.sourceId, url: chapters[i]['url'], title: chapters[i]['name'], bookName: widget.book.name))))))); }

class ReadPage extends StatefulWidget { final String sourceId, url, title, bookName;
  const ReadPage({super.key, required this.sourceId, required this.url, required this.title, required this.bookName});
  @override State<ReadPage> createState() => _R(); }
class _R extends State<ReadPage> {
  String text = ''; List<String> images = []; bool loading = true; double fontSize = 18;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async { try {
      final r = await Api.get('/v1/content?sourceId=${Uri.encodeComponent(widget.sourceId)}&url=${Uri.encodeComponent(widget.url)}');
      text = r['data']?['text'] as String? ?? '';
      images = List<String>.from(r['data']?['images'] ?? []);
      if (text.isEmpty && images.isEmpty) text = '本章无内容'; } catch (e) { text = '错误: $e'; }
    setState(() => loading = false); }
  String imgProxy(String u) => '${Api.base}/v1/img?url=${Uri.encodeComponent(u)}';
  @override
  Widget build(BuildContext c) {
    final isImgs = images.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        if (!isImgs) IconButton(icon: const Icon(Icons.text_increase), onPressed: () => setState(() => fontSize += 1)),
        if (!isImgs) IconButton(icon: const Icon(Icons.text_decrease), onPressed: () => setState(() => fontSize = (fontSize - 1).clamp(12, 32))),
      ]),
      body: loading ? const Center(child: CircularProgressIndicator())
        : isImgs
          ? ListView.builder(
              itemCount: images.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: InteractiveViewer(child: Image.network(imgProxy(images[i]),
                  fit: BoxFit.fitWidth, errorBuilder: (_, __, ___) => const SizedBox(
                    height: 120, child: Center(child: Icon(Icons.broken_image, color: Colors.grey))))),
              ))
          : SingleChildScrollView(padding: const EdgeInsets.all(16),
              child: SelectableText(text, style: TextStyle(fontSize: fontSize, height: 1.8))),
    );
  }
}

class ShelfPage extends StatelessWidget { final List<Book> shelf; const ShelfPage({super.key, required this.shelf});
  @override Widget build(BuildContext c) => shelf.isEmpty ? const Center(child: Text('书架为空, 从搜索进入书籍后自动记录'))
    : ListView(children: [ for (final b in shelf) ListTile(title: Text(b.name), subtitle: Text(b.author)) ]); }
