// ThirdHub v4 Flutter M1: 搜索→目录→阅读 最小可用版(单文件)
// 忽略自签证书(开发模式); 正式版接指纹TOFU
import 'dart:convert'; import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

void main() => runApp(const ThApp());

class Api {
  static String base = 'https://192.168.1.5:9527'; // 首启引导页让用户填
  static String token = '';
  static http.Client client() {
    final ctx = HttpClient()..badCertificateCallback = (_, __, ___) => true; // M1: TOFU二期
    return IOClient(ctx);
  }
  static Future<Map<String, dynamic>> get(String path) async {
    final r = await client().get(Uri.parse('$base$path'), headers: {'X-TH-Token': token});
    return jsonDecode(utf8.decode(r.bodyBytes));
  }
}

class ThApp extends StatelessWidget {
  const ThApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
    title: 'ThirdHub', theme: ThemeData.dark(useMaterial3: true),
    home: const HomePage(),
  );
}

class Book { final String name, author, coverUrl, intro, bookUrl, sourceId;
  Book(this.name, this.author, this.coverUrl, this.intro, this.bookUrl, this.sourceId);
  factory Book.from(Map<String, dynamic> j) => Book(j['name']??'', j['author']??'',
      j['coverUrl']??'', j['intro']??'', j['bookUrl']??'', j['sourceId']??'');
}

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState() => _H(); }
class _H extends State<HomePage> {
  int tab = 0;
  final shelf = <Book>[]; // 书架(本地内存; 持久化二期)
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('ThirdHub v4')),
    body: tab == 0 ? const SearchPage() : ShelfPage(shelf: shelf),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i)=>setState(()=>tab=i),
      destinations: const [NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
        NavigationDestination(icon: Icon(Icons.menu_book), label: '书架')]),
  );
}

class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _S(); }
class _S extends State<SearchPage> {
  final ctrl = TextEditingController(); List<Map> groups = []; bool loading = false;
  Future<void> go() async {
    setState(() { loading = true; groups = []; });
    try {
      final r = await Api.get('/v1/search?q=${Uri.encodeComponent(ctrl.text)}');
      setState(() { groups = List<Map>.from(r['data'] ?? []); });
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e'))); }
    setState(() => loading = false);
  }
  @override
  Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: ctrl, decoration: const InputDecoration(
        hintText: '书名/作者', border: OutlineInputBorder()),
        onSubmitted: (_) => go())),
      IconButton(icon: const Icon(Icons.search), onPressed: go),
    ])),
    if (loading) const LinearProgressIndicator(),
    Expanded(child: ListView(children: [
      for (final g in groups)
        ...[ if (g['error'] == null) Padding(padding: const EdgeInsets.fromLTRB(12,8,12,0),
              child: Text('${g['source']}', style: const TextStyle(color: Colors.tealAccent))) ],
        for (final b in (g['books'] as List? ?? [])) ListTile(
          title: Text(b['name'] ?? ''), subtitle: Text(b['author'] ?? ''),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TocPage(book: Book.from(b)))),
        ),
    ])),
  ]);
}

class TocPage extends StatefulWidget { final Book book; const TocPage({super.key, required this.book}); @override State<TocPage> createState() => _T(); }
class _T extends State<TocPage> {
  List chapters = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    try {
      final r = await Api.get('/v1/toc?sourceId=${Uri.encodeComponent(widget.book.sourceId)}&url=${Uri.encodeComponent(widget.book.bookUrl)}');
      chapters = r['data'] ?? [];
    } catch (e) {}
    setState(() => loading = false);
  }
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(widget.book.name)),
    body: loading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
      itemCount: chapters.length, itemBuilder: (_, i) => ListTile(
        title: Text(chapters[i]['name'] ?? ''),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ReadPage(
          sourceId: widget.book.sourceId, url: chapters[i]['url'], title: chapters[i]['name'])))),
      )),
  );
}

class ReadPage extends StatefulWidget { final String sourceId, url, title;
  const ReadPage({super.key, required this.sourceId, required this.url, required this.title});
  @override State<ReadPage> createState() => _R(); }
class _R extends State<ReadPage> {
  String text = ''; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    try {
      final r = await Api.get('/v1/content?sourceId=${Uri.encodeComponent(widget.sourceId)}&url=${Uri.encodeComponent(widget.url)}');
      text = (r['data']?['text'] as String?) ?? '加载失败';
    } catch (e) { text = '错误: $e'; }
    setState(() => loading = false);
  }
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(widget.title), actions: [IconButton(icon: const Icon(Icons.format_size), onPressed: () {})]),
    body: loading ? const Center(child: CircularProgressIndicator()) :
      SingleChildScrollView(padding: const EdgeInsets.all(16),
        child: SelectableText(text, style: const TextStyle(fontSize: 18, height: 1.8))),
  );
}

class ShelfPage extends StatelessWidget { final List<Book> shelf; const ShelfPage({super.key, required this.shelf});
  @override
  Widget build(BuildContext c) => shelf.isEmpty ? const Center(child: Text('书架为空, 从搜索添加'))
    : ListView(children: [ for (final b in shelf) ListTile(title: Text(b.name), subtitle: Text(b.author)) ]);
}
