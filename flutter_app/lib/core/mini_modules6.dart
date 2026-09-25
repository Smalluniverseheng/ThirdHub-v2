// 小模块做实第六批: 健康记录 / 资讯(RSS 阅读器)
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class _Store6 {
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

// ═══ 健康记录: 体重/血压/睡眠 记录 + 趋势图 + 统计 ═══
class HealthPage extends StatefulWidget { const HealthPage({super.key}); @override State<HealthPage> createState() => _He(); }
class _He extends State<HealthPage> {
  List<Map<String, dynamic>> records = []; // {type, value, value2?, ts}
  String type = '体重';
  static const types = ['体重', '血压', '睡眠'];
  static const units = {'体重': 'kg', '血压': 'mmHg', '睡眠': '小时'};

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final v = await _Store6.list('health_records');
    if (!mounted) return;
    setState(() => records = v);
  }

  Future<void> _add() async {
    final v1 = TextEditingController(); final v2 = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: Text('记录$type'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: v1, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: type == '血压' ? '收缩压(高压)' : '$type(${units[type]})', isDense: true)),
        if (type == '血压') TextField(controller: v2, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '舒张压(低压)', isDense: true)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))]));
    if (ok != true) return;
    final a = double.tryParse(v1.text.trim());
    if (a == null || a <= 0) return;
    records.insert(0, {'type': type, 'value': a,
      if (type == '血压') 'value2': double.tryParse(v2.text.trim()) ?? 0,
      'ts': DateTime.now().millisecondsSinceEpoch});
    await _Store6.save('health_records', records);
    _load();
  }

  @override Widget build(BuildContext c) {
    final list = records.where((e) => e['type'] == type).toList();
    final vals = list.map((e) => (e['value'] as num).toDouble()).toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
        for (final t in types) Padding(padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(label: Text(t, style: const TextStyle(fontSize: 12)), selected: type == t,
            onSelected: (_) => setState(() => type = t))),
        const Spacer(),
        IconButton.filled(icon: const Icon(Icons.add, size: 20), tooltip: '记一条', onPressed: _add),
      ])),
      if (vals.length >= 2) SizedBox(height: 120, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
        child: CustomPaint(size: Size.infinite, painter: _TrendPainter(vals.reversed.toList())))),
      if (vals.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(
        '最新 ${vals.first}${units[type]} · 最高 ${vals.reduce((a, b) => a > b ? a : b)} · 最低 ${vals.reduce((a, b) => a < b ? a : b)} · 平均 ${(vals.reduce((a, b) => a + b) / vals.length).toStringAsFixed(1)}',
        style: const TextStyle(fontSize: 11, color: Colors.grey))),
      Expanded(child: list.isEmpty
        ? Center(child: Text('还没有$type记录\n点右上角 + 记一条', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)))
        : ListView(children: [
            for (final e in list) Dismissible(key: ValueKey('${e['ts']}_${e['value']}'),
              direction: DismissDirection.endToStart,
              background: Container(color: Colors.redAccent, alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
              onDismissed: (_) { records.remove(e); _Store6.save('health_records', records).then((_) => _load()); },
              child: ListTile(dense: true,
                title: Text(type == '血压' ? '${(e['value'] as num).toStringAsFixed(0)}/${(e['value2'] as num?)?.toStringAsFixed(0) ?? '-'} mmHg'
                  : '${e['value']} ${units[type]}', style: const TextStyle(fontSize: 14)),
                subtitle: Text(DateTime.fromMillisecondsSinceEpoch(e['ts'] ?? 0).toString().substring(0, 16),
                  style: const TextStyle(fontSize: 10, color: Colors.grey)))),
          ])),
    ]);
  }
}
class _TrendPainter extends CustomPainter {
  final List<double> vals;
  _TrendPainter(this.vals);
  @override void paint(Canvas canvas, Size size) {
    if (vals.length < 2) return;
    final mn = vals.reduce((a, b) => a < b ? a : b), mx = vals.reduce((a, b) => a > b ? a : b);
    final range = (mx - mn) == 0 ? 1 : (mx - mn);
    final path = Path();
    for (var i = 0; i < vals.length; i++) {
      final x = size.width * i / (vals.length - 1);
      final y = size.height - 14 - (vals[i] - mn) / range * (size.height - 28);
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
      canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = Colors.tealAccent);
    }
    canvas.drawPath(path, Paint()..color = Colors.teal..strokeWidth = 2..style = PaintingStyle.stroke);
  }
  @override bool shouldRepaint(_TrendPainter old) => true;
}

// ═══ 资讯: RSS 阅读器(预置源 + 自定义) ═══
class NewsPage extends StatefulWidget { const NewsPage({super.key}); @override State<NewsPage> createState() => _News(); }
class _News extends State<NewsPage> {
  List<Map<String, dynamic>> feeds = [];
  List<Map<String, String>> articles = [];
  String curFeed = '';
  bool loading = false;
  String err = '';

  /// 内置源版本：**改了内置源必须 +1**，配合 `_load()` 里的迁移。
  /// 老判据是 `if (saved.isEmpty)` —— 用户机器上已有旧列表时恒假，**新增的内置源永远进不来**。
  /// （第十二轮「预置书源包改了但老安装不生效」是同一类坑，只是对象换成了内置 RSS 源。）
  static const builtinVer = 2;
  /// 每一条都是**实测过**的（2026-09-25 逐条拉起核对：HTTP 200 且能解析出条目）。
  /// 注意机核的 `/rss` 是**图文**订阅 —— 放资讯合适，放播客则会永远 0 集。
  static const builtin = [
    {'title': '少数派', 'url': 'https://sspai.com/feed'},
    {'title': 'Solidot', 'url': 'https://www.solidot.org/index.rss'},
    {'title': '机核', 'url': 'https://www.gcores.com/rss'},
    {'title': '阮一峰周刊', 'url': 'https://www.ruanyifeng.com/blog/atom.xml'},
    {'title': 'InfoQ中文', 'url': 'https://www.infoq.cn/feed'},
  ];

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final saved = await _Store6.list('news_feeds');
    final p = await SharedPreferences.getInstance();
    final seen = p.getInt('news_feeds_builtin_v') ?? 0;
    List<Map<String, dynamic>> list = saved;
    if (saved.isEmpty) {
      list = builtin.map((e) => Map<String, dynamic>.from(e)).toList();
    } else if (seen < builtinVer) {
      // 老安装升级：补上缺失的内置源；**用户自加/删改的源一律不动**（只按 url 去重追加）。
      list = List<Map<String, dynamic>>.from(saved);
      for (final b in builtin) {
        if (!list.any((f) => f['url'] == b['url'])) list.add(Map<String, dynamic>.from(b));
      }
    }
    await p.setInt('news_feeds_builtin_v', builtinVer);
    await _Store6.save('news_feeds', list);
    if (!mounted) return;
    setState(() => feeds = list);
    if (list.isNotEmpty) _openFeed(list.first);
  }

  static List<Map<String, String>> _parse(String src) {
    final out = <Map<String, String>>[];
    // RSS <item> 与 Atom <entry> 都兼容
    final items = RegExp(r'<(?:item|entry)[\s>]([\s\S]*?)</(?:item|entry)>').allMatches(src);
    for (final m in items.take(60)) {
      final b = m.group(1)!;
      String pick(String tag) {
        final mm = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>').firstMatch(b);
        return (mm?.group(1) ?? '').replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '').replaceAll(RegExp(r'<[^>]+>'), '').trim();
      }
      var link = pick('link');
      if (link.isEmpty) {
        link = RegExp(r'<link[^>]*href="([^"]+)"').firstMatch(b)?.group(1) ?? '';
      }
      final title = pick('title');
      if (title.isEmpty || link.isEmpty) continue;
      out.add({'title': title, 'link': link, 'date': pick('pubDate').isEmpty ? pick('updated') : pick('pubDate'),
        'desc': pick('description').isEmpty ? pick('summary') : pick('description')});
    }
    return out;
  }

  Future<void> _openFeed(Map f) async {
    setState(() { loading = true; err = ''; curFeed = f['title']; articles = []; });
    try {
      final r = await http.get(Uri.parse(f['url']), headers: {'User-Agent': 'Mozilla/5.0 ThirdHub'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      setState(() => articles = _parse(utf8.decode(r.bodyBytes)));
      if (articles.isEmpty) throw Exception('没有解析到文章(该源格式可能特殊)');
    } catch (e) { setState(() => err = '$e'); }
    setState(() => loading = false);
  }

  Future<void> _addFeed() async {
    final urlC = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('添加资讯 RSS 源'),
      content: TextField(controller: urlC, decoration: const InputDecoration(hintText: 'https://…/feed', isDense: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('添加'))]));
    if (ok != true || urlC.text.trim().isEmpty) return;
    feeds.add({'title': urlC.text.trim(), 'url': urlC.text.trim()});
    await _Store6.save('news_feeds', feeds);
    _openFeed(feeds.last);
  }

  /// 空态兜底：旧版这一块是**真的空白**（`ListView` 条目 0 条就什么都不画），
  /// 只在顶部留一行小红字 `加载失败: …`。用户看到的是「模块坏了」，而不是「这个源失效了，
  /// 你可以换个源」。这里补成可操作空态：说清原因 + 重试 / 换源 / 加源三个出口。
  Widget _emptyBox() {
    final failed = curFeed.isNotEmpty;
    return Center(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
      Icon(failed ? Icons.wifi_off : Icons.newspaper, size: 42, color: Colors.grey),
      const SizedBox(height: 10),
      Text(failed ? '这个源没能取到内容' : '还没有资讯源', style: const TextStyle(fontSize: 14)),
      const SizedBox(height: 6),
      Text(failed
          ? '「$curFeed」没有返回可解析的文章。内置源会随时间失效，可以重试、换一个源，或自己添加一个 RSS 地址。'
          : '可以添加一个 RSS 地址（例如 https://example.com/feed）。',
        textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      if (failed && err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
        child: Text('原因: $err', textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.redAccent))),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        if (failed) FilledButton.tonalIcon(
          onPressed: () { final f = feeds.firstWhere((x) => x['title'] == curFeed, orElse: () => const {}); if (f.isNotEmpty) _openFeed(f); },
          icon: const Icon(Icons.refresh, size: 16), label: const Text('重试')),
        if (failed && feeds.length > 1) FilledButton.tonalIcon(
          onPressed: () {
            final i = feeds.indexWhere((x) => x['title'] == curFeed);
            _openFeed(feeds[(i < 0 ? 0 : i + 1) % feeds.length]);
          },
          icon: const Icon(Icons.skip_next, size: 16), label: const Text('换个源')),
        TextButton.icon(onPressed: _addFeed, icon: const Icon(Icons.add, size: 16), label: const Text('加 RSS')),
      ]),
    ]))));
  }

  @override Widget build(BuildContext c) => Column(children: [
    SizedBox(height: 46, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      children: [
        for (final f in feeds) Padding(padding: const EdgeInsets.only(right: 6),
          child: InputChip(label: Text(f['title'], style: const TextStyle(fontSize: 11)),
            selected: curFeed == f['title'], onSelected: (_) => _openFeed(f),
            onDeleted: feeds.length > 1 ? () async { feeds.remove(f); await _Store6.save('news_feeds', feeds);
              if (curFeed == f['title']) _openFeed(feeds.first); setState(() {}); } : null)),
        ActionChip(avatar: const Icon(Icons.add, size: 14), label: const Text('加源', style: TextStyle(fontSize: 11)),
          onPressed: _addFeed),
      ])),
    if (err.isNotEmpty && articles.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text('加载失败: $err', style: const TextStyle(fontSize: 11, color: Colors.redAccent))),
    Expanded(child: loading
      ? const Center(child: CircularProgressIndicator())
      : articles.isEmpty
        ? _emptyBox()
        : ListView.builder(itemCount: articles.length, itemBuilder: (_, i) {
          final a = articles[i];
          return ListTile(dense: true,
            title: Text(a['title'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Text(a['desc'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
            trailing: const Icon(Icons.open_in_new, size: 14, color: Colors.grey),
            onTap: () => launchUrl(Uri.parse(a['link'] ?? ''), mode: LaunchMode.externalApplication));
        })),
  ]);
}
