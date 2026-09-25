// 小模块做实第五批: Markdown编辑器 / 记忆卡(卡片) / 菜谱 / 翻译 / 传感器(尺子)
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _Store5 {
  static Future<List<Map<String, dynamic>>> list(String key) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try { return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e)).toList(); } catch (_) { return []; }
  }
  static Future<void> save(String key, List<Map<String, dynamic>> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(items));
  }
}

// ═══ Markdown 编辑器: 编辑/预览/导出TXT+MD ═══
class MarkdownPage extends StatefulWidget { const MarkdownPage({super.key}); @override State<MarkdownPage> createState() => _Md(); }
class _Md extends State<MarkdownPage> {
  List<Map<String, dynamic>> docs = [];
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final v = await _Store5.list('md_docs');
    if (!mounted) return;
    setState(() => docs = v);
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.add, size: 18), label: const Text('新建 Markdown 文档'),
        onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const MdEditPage())).then((_) => _load())))),
    Expanded(child: docs.isEmpty
      ? const Center(child: Text('还没有文档', style: TextStyle(color: Colors.grey)))
      : ListView(children: [
          for (final d in docs) ListTile(
            leading: const Icon(Icons.text_fields, size: 20),
            title: Text((d['title'] ?? '').toString().isEmpty ? '无标题' : d['title'],
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
            subtitle: Text(DateTime.fromMillisecondsSinceEpoch(d['updated'] ?? d['ts'] ?? 0).toString().substring(0, 16),
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => MdEditPage(doc: d))).then((_) => _load()),
            onLongPress: () async {
              final ok = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(title: const Text('删除文档'),
                content: Text('删除「${d['title'] ?? '无标题'}」?'),
                actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('删除'))]));
              if (ok == true) { docs.remove(d); await _Store5.save('md_docs', docs); _load(); }
            }),
        ])),
  ]);
}

class MdEditPage extends StatefulWidget {
  final Map<String, dynamic>? doc;
  const MdEditPage({super.key, this.doc});
  @override State<MdEditPage> createState() => _MdEdit();
}
class _MdEdit extends State<MdEditPage> {
  late final TextEditingController title = TextEditingController(text: widget.doc?['title'] ?? '');
  late final TextEditingController body = TextEditingController(text: widget.doc?['content'] ?? '');
  bool preview = false;

  Future<void> _save() async {
    if (title.text.trim().isEmpty && body.text.trim().isEmpty) { Navigator.pop(context); return; }
    final docs = await _Store5.list('md_docs');
    if (widget.doc != null) docs.removeWhere((d) => d['ts'] == widget.doc!['ts']);
    docs.insert(0, {'title': title.text.trim(), 'content': body.text,
      'ts': widget.doc?['ts'] ?? DateTime.now().millisecondsSinceEpoch,
      'updated': DateTime.now().millisecondsSinceEpoch});
    await _Store5.save('md_docs', docs);
    if (mounted) Navigator.pop(context);
  }

  // 工具条插入标记
  void _wrap(String l, [String r = '']) {
    final sel = body.selection;
    final t = body.text;
    final s = sel.isValid ? sel.start : t.length;
    final e = sel.isValid ? sel.end : t.length;
    final mid = t.substring(s, e);
    body.text = t.substring(0, s) + l + mid + r + t.substring(e);
    body.selection = TextSelection.collapsed(offset: s + l.length + mid.length + r.length);
    setState(() {});
  }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(widget.doc == null ? '新建文档' : '编辑文档'), actions: [
      IconButton(icon: Icon(preview ? Icons.edit : Icons.visibility_outlined, size: 20),
        onPressed: () => setState(() => preview = !preview)),
      IconButton(icon: const Icon(Icons.copy, size: 20), tooltip: '复制全文',
        onPressed: () { Clipboard.setData(ClipboardData(text: body.text));
          ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已复制 Markdown 源码'))); }),
      IconButton(icon: const Icon(Icons.check, size: 20), tooltip: '保存', onPressed: _save),
    ]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TextField(controller: title, decoration: const InputDecoration(hintText: '标题', isDense: true, border: InputBorder.none),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
      if (!preview) SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (final b in [('H1', '# ', ''), ('H2', '## ', ''), ('粗体', '**', '**'), ('斜体', '*', '*'),
              ('引用', '> ', ''), ('列表', '- ', ''), ('代码', '`', '`'), ('链接', '[', '](https://)'), ('分割线', '\n---\n', '')])
            Padding(padding: const EdgeInsets.only(right: 4),
              child: ActionChip(label: Text(b.$1, style: const TextStyle(fontSize: 11)), onPressed: () => _wrap(b.$2, b.$3))),
        ])),
      const Divider(height: 1),
      Expanded(child: preview
        ? ListView(padding: const EdgeInsets.all(14), children: [mdPreview(body.text)])
        : TextField(controller: body, maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.all(14),
              hintText: '# 标题\n**加粗** *斜体*\n- 列表\n> 引用\n`代码`'))),
    ]));
}

// 轻量 Markdown 渲染(笔记模块同款规则, 独立副本避免跨文件私有依赖)
Widget mdPreview(String src) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
  for (final ln in src.split('\n')) _mdLine(ln),
]);
Widget _mdLine(String ln) {
  Widget styled(String t, TextStyle s) {
    final spans = <TextSpan>[];
    var rest = t;
    while (rest.contains('**')) {
      final i = rest.indexOf('**'); final j = rest.indexOf('**', i + 2);
      if (j < 0) break;
      if (i > 0) spans.add(TextSpan(text: rest.substring(0, i)));
      spans.add(TextSpan(text: rest.substring(i + 2, j), style: const TextStyle(fontWeight: FontWeight.w700)));
      rest = rest.substring(j + 2);
    }
    spans.add(TextSpan(text: rest));
    return Text.rich(TextSpan(children: spans), style: s);
  }
  if (ln.startsWith('### ')) return styled(ln.substring(4), const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.8));
  if (ln.startsWith('## ')) return styled(ln.substring(3), const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.9));
  if (ln.startsWith('# ')) return styled(ln.substring(2), const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 2.0));
  if (ln == '---') return const Divider(height: 16);
  if (ln.startsWith('- ') || ln.startsWith('* ')) return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('  • ', style: TextStyle(height: 1.6)), Expanded(child: styled(ln.substring(2), const TextStyle(fontSize: 14, height: 1.6)))]);
  if (ln.startsWith('> ')) return Container(margin: const EdgeInsets.symmetric(vertical: 2), padding: const EdgeInsets.only(left: 8),
    decoration: const BoxDecoration(border: Border(left: BorderSide(color: Colors.grey, width: 3))),
    child: styled(ln.substring(2), const TextStyle(fontSize: 14, height: 1.6, color: Colors.grey)));
  if (ln.startsWith('`') && ln.endsWith('`') && ln.length > 2) return Container(margin: const EdgeInsets.symmetric(vertical: 2),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
    child: Text(ln.substring(1, ln.length - 1), style: const TextStyle(fontFamily: 'monospace', fontSize: 13)));
  return styled(ln, const TextStyle(fontSize: 14, height: 1.6));
}

// ═══ 记忆卡: 单词卡/背诵卡(自建卡组) ═══
class StudyPage extends StatefulWidget { const StudyPage({super.key}); @override State<StudyPage> createState() => _Study(); }
class _Study extends State<StudyPage> {
  List<Map<String, dynamic>> cards = []; // {front, back, known}
  int idx = 0;
  bool showBack = false;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final v = await _Store5.list('study_cards');
    if (!mounted) return;
    setState(() => cards = v);
  }

  Future<void> _add() async {
    final frontC = TextEditingController(); final backC = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('新建卡片'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: frontC, decoration: const InputDecoration(labelText: '正面(单词/问题)', isDense: true)),
        TextField(controller: backC, maxLines: 3, decoration: const InputDecoration(labelText: '背面(释义/答案)', isDense: true)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))]));
    if (ok != true || frontC.text.trim().isEmpty) return;
    cards.add({'front': frontC.text.trim(), 'back': backC.text.trim(), 'known': false});
    await _Store5.save('study_cards', cards);
    _load();
  }

  Future<void> _mark(bool known) async {
    if (cards.isEmpty) return;
    cards[idx]['known'] = known;
    // 认识了排到最后, 不认识稍后重见
    final card = cards.removeAt(idx);
    if (known) { cards.add(card); } else { cards.insert((idx + 3).clamp(0, cards.length), card); }
    if (idx >= cards.length) idx = 0;
    showBack = false;
    await _Store5.save('study_cards', cards);
    setState(() {});
  }

  @override Widget build(BuildContext c) {
    final known = cards.where((e) => e['known'] == true).length;
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
        Expanded(child: Text('共 ${cards.length} 张 · 已记住 $known', style: const TextStyle(fontSize: 12, color: Colors.grey))),
        IconButton.filled(icon: const Icon(Icons.add, size: 20), tooltip: '新建卡片', onPressed: _add),
      ])),
      Expanded(child: cards.isEmpty
        ? const Center(child: Text('还没有卡片\n点右上角 + 建一张单词卡/问题卡', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
        : Column(children: [
            const SizedBox(height: 20),
            GestureDetector(onTap: () => setState(() => showBack = !showBack),
              child: Card(margin: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(width: double.infinity, constraints: const BoxConstraints(minHeight: 200),
                  padding: const EdgeInsets.all(24), alignment: Alignment.center,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(cards[idx]['front'] ?? '', textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    if (showBack) ...[
                      const Divider(height: 24),
                      Text(cards[idx]['back'] ?? '', textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16, color: Colors.grey)),
                    ] else
                      const Padding(padding: EdgeInsets.only(top: 16),
                        child: Text('点按看答案', style: TextStyle(fontSize: 11, color: Colors.grey))),
                  ])))),
            const SizedBox(height: 16),
            if (showBack) Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              FilledButton.tonalIcon(icon: const Icon(Icons.close, size: 18), label: const Text('还不熟'),
                onPressed: () => _mark(false)),
              const SizedBox(width: 12),
              FilledButton.icon(icon: const Icon(Icons.check, size: 18), label: const Text('记住了'),
                onPressed: () => _mark(true)),
            ]),
            const SizedBox(height: 8),
            TextButton.icon(icon: const Icon(Icons.delete_outline, size: 16), label: const Text('删除这张'),
              onPressed: () async { cards.removeAt(idx); if (idx >= cards.length && idx > 0) idx--;
                showBack = false; await _Store5.save('study_cards', cards); setState(() {}); }),
          ])),
    ]);
  }
}

// ═══ 菜谱: TheMealDB 免费公开 API ═══
class RecipePage extends StatefulWidget { const RecipePage({super.key}); @override State<RecipePage> createState() => _Rp(); }
class _Rp extends State<RecipePage> {
  List meals = [];
  List cats = [];
  bool loading = false;
  String err = '';
  final searchC = TextEditingController();

  @override void initState() { super.initState(); _loadCats(); _search(''); }

  Future<void> _loadCats() async {
    try {
      final r = await http.get(Uri.parse('https://www.themealdb.com/api/json/v1/1/categories.php')).timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) setState(() => cats = jsonDecode(utf8.decode(r.bodyBytes))['categories'] ?? []);
    } catch (_) {}
  }
  Future<void> _search(String q) async {
    setState(() { loading = true; err = ''; });
    try {
      final url = q.isEmpty
        ? 'https://www.themealdb.com/api/json/v1/1/search.php?s='
        : 'https://www.themealdb.com/api/json/v1/1/search.php?s=${Uri.encodeComponent(q)}';
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      setState(() => meals = jsonDecode(utf8.decode(r.bodyBytes))['meals'] ?? []);
    } catch (e) { setState(() => err = '$e'); }
    setState(() => loading = false);
  }
  Future<void> _byCat(String cat) async {
    setState(() { loading = true; err = ''; });
    try {
      final r = await http.get(Uri.parse('https://www.themealdb.com/api/json/v1/1/filter.php?c=${Uri.encodeComponent(cat)}'))
        .timeout(const Duration(seconds: 12));
      setState(() => meals = jsonDecode(utf8.decode(r.bodyBytes))['meals'] ?? []);
    } catch (e) { setState(() => err = '$e'); }
    setState(() => loading = false);
  }

  Future<void> _detail(String id) async {
    try {
      final r = await http.get(Uri.parse('https://www.themealdb.com/api/json/v1/1/lookup.php?i=$id')).timeout(const Duration(seconds: 12));
      final m = (jsonDecode(utf8.decode(r.bodyBytes))['meals'] as List).first;
      if (!mounted) return;
      final ings = <String>[];
      for (var i = 1; i <= 20; i++) {
        final ing = (m['strIngredient$i'] ?? '').toString().trim();
        final mea = (m['strMeasure$i'] ?? '').toString().trim();
        if (ing.isNotEmpty) ings.add('$ing  $mea');
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
        appBar: AppBar(title: Text(m['strMeal'] ?? '')),
        body: ListView(padding: const EdgeInsets.all(14), children: [
          if ((m['strMealThumb'] ?? '').toString().isNotEmpty)
            ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(m['strMealThumb'])),
          const SizedBox(height: 10),
          Text('${m['strArea'] ?? ''} · ${m['strCategory'] ?? ''}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const Padding(padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('配料', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
          Card(child: Column(children: [for (final g in ings) ListTile(dense: true, title: Text(g, style: const TextStyle(fontSize: 13)))])),
          const Padding(padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('做法', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
          Text(m['strInstructions'] ?? '', style: const TextStyle(fontSize: 13, height: 1.7)),
        ]))));
    } catch (_) {
      // 这里原来是个空 catch：网络失败、或返回体里没有 meals（`as List` 之后
      // `.first` 抛错）时，用户点了菜谱**什么都不发生** —— 不跳转也不提示，
      // 看起来就像 App 卡住了。把真因说出来。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('打不开这道菜 · 菜谱库（TheMealDB）没连上，或这道菜已下架 —— 稍后再试一次')));
      }
    }
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
      Expanded(child: TextField(controller: searchC, decoration: const InputDecoration(
        hintText: '搜索菜谱(英文库, 如 chicken / beef)…', isDense: true, border: OutlineInputBorder()),
        onSubmitted: (v) => _search(v.trim()))),
      const SizedBox(width: 6),
      IconButton.filled(icon: const Icon(Icons.search, size: 20), onPressed: () => _search(searchC.text.trim())),
    ])),
    if (cats.isNotEmpty) SizedBox(height: 38, child: ListView(scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10), children: [
        for (final ct in cats) Padding(padding: const EdgeInsets.only(right: 6),
          child: ActionChip(label: Text(ct['strCategory'], style: const TextStyle(fontSize: 11)),
            onPressed: () => _byCat(ct['strCategory']))),
      ])),
    if (err.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text('加载失败: $err', style: const TextStyle(fontSize: 11, color: Colors.redAccent))),
    Expanded(child: loading
      ? const Center(child: CircularProgressIndicator())
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 0.85),
        padding: const EdgeInsets.all(10),
        itemCount: meals.length,
        itemBuilder: (_, i) {
          final m = meals[i];
          return InkWell(onTap: () => _detail(m['idMeal']),
            child: Card(margin: EdgeInsets.zero, clipBehavior: Clip.antiAlias, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: SizedBox(width: double.infinity,
                child: Image.network(m['strMealThumb'] ?? '', fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(color: Colors.grey.withValues(alpha: 0.2))))),
              Padding(padding: const EdgeInsets.all(8),
                child: Text(m['strMeal'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
            ])));
        })),
  ]);
}

// ═══ 翻译: MyMemory 免费公开接口 + 历史 ═══
class TranslatePage extends StatefulWidget { const TranslatePage({super.key}); @override State<TranslatePage> createState() => _Tr(); }
class _Tr extends State<TranslatePage> {
  final input = TextEditingController();
  String result = '';
  String from = 'zh-CN', to = 'en-US';
  bool loading = false;
  List<Map<String, dynamic>> history = [];
  static const langs = {'自动检测': 'auto', '中文': 'zh-CN', '英语': 'en-US', '日语': 'ja-JP', '韩语': 'ko-KR',
    '法语': 'fr-FR', '德语': 'de-DE', '西班牙语': 'es-ES', '俄语': 'ru-RU'};

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final v = await _Store5.list('translate_history');
    if (!mounted) return;
    setState(() => history = v);
  }

  Future<void> _translate() async {
    final s = input.text.trim();
    if (s.isEmpty) return;
    setState(() { loading = true; result = ''; });
    try {
      // MyMemory: auto 时用 zh|en 猜方向(含中文→英, 否则→中)
      var f = from, t = to;
      if (f == 'auto') {
        final hasCn = RegExp(r'[一-鿿]').hasMatch(s);
        f = hasCn ? 'zh-CN' : 'en-US';
        t = hasCn ? (to == 'zh-CN' ? 'en-US' : to) : 'zh-CN';
      }
      if (f == t) t = f == 'zh-CN' ? 'en-US' : 'zh-CN';
      final r = await http.get(Uri.parse('https://api.mymemory.translated.net/get?q=${Uri.encodeComponent(s)}&langpair=$f|$t'))
        .timeout(const Duration(seconds: 12));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final translated = j['responseData']?['translatedText'] ?? '';
      if (translated.isEmpty) throw Exception('接口无结果(可能超当日免费额度)');
      setState(() => result = translated);
      history.insert(0, {'from': s, 'to': translated, 'ts': DateTime.now().millisecondsSinceEpoch});
      if (history.length > 50) history = history.sublist(0, 50);
      await _Store5.save('translate_history', history);
    } catch (e) { setState(() => result = '翻译失败: $e'); }
    setState(() => loading = false);
  }

  @override Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(12), children: [
    Row(children: [
      Expanded(child: DropdownButtonFormField<String>(value: from, isDense: true,
        decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
        items: [for (final e in langs.entries) DropdownMenuItem(value: e.value, child: Text(e.key, style: const TextStyle(fontSize: 12)))],
        onChanged: (v) => setState(() => from = v ?? 'auto'))),
      IconButton(icon: const Icon(Icons.swap_horiz, size: 20), onPressed: () => setState(() {
        if (from != 'auto') { final t = from; from = to; to = t; } })),
      Expanded(child: DropdownButtonFormField<String>(value: to, isDense: true,
        decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
        items: [for (final e in langs.entries) if (e.value != 'auto') DropdownMenuItem(value: e.value, child: Text(e.key, style: const TextStyle(fontSize: 12)))],
        onChanged: (v) => setState(() => to = v ?? 'en-US'))),
    ]),
    const SizedBox(height: 8),
    TextField(controller: input, maxLines: 5, decoration: const InputDecoration(
      hintText: '输入要翻译的文本…', border: OutlineInputBorder(), isDense: true)),
    const SizedBox(height: 8),
    Row(children: [
      FilledButton.icon(icon: const Icon(Icons.translate, size: 18),
        label: Text(loading ? '翻译中…' : '翻译'), onPressed: loading ? null : _translate),
      const SizedBox(width: 8),
      TextButton.icon(icon: const Icon(Icons.paste, size: 18), label: const Text('粘贴'),
        onPressed: () async { final d = await Clipboard.getData('text/plain'); if (d?.text != null) setState(() => input.text = d!.text!); }),
    ]),
    if (result.isNotEmpty) Card(margin: const EdgeInsets.only(top: 10), child: ListTile(
      title: SelectableText(result, style: const TextStyle(fontSize: 14, height: 1.6)),
      trailing: IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () {
        Clipboard.setData(ClipboardData(text: result));
        ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已复制'))); }))),
    if (history.isNotEmpty) ...[
      const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text('历史记录', style: TextStyle(fontSize: 12, color: Colors.grey))),
      Card(child: Column(children: [
        for (final h in history.take(20)) ListTile(dense: true,
          title: Text(h['from'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          subtitle: Text(h['to'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          onTap: () { input.text = h['from'] ?? ''; _translate(); }),
      ])),
    ],
    const Padding(padding: EdgeInsets.only(top: 10),
      child: Text('接口: MyMemory 免费翻译(每日有额度); 接入自己的 AI 密钥后可在 AI 模块获得更高质量翻译',
        style: TextStyle(fontSize: 10, color: Colors.grey))),
  ]);
}

// ═══ 传感器模块已移至 core/sensor_page.dart(尺子/水平仪/指南针/取色器, 基于 sensors_plus) ═══
