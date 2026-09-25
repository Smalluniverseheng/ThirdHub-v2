// 小模块做实第四批: 壁纸 / 广播 / 播客 / 书签 / 代码片段
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'play_tag.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'browser_page.dart';
import 'recents.dart';

class _Store4 {
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

// ═══ 壁纸: Wallhaven 公开 API 浏览/搜索 + 下载 ═══
class WallpaperPage extends StatefulWidget { const WallpaperPage({super.key}); @override State<WallpaperPage> createState() => _Wp(); }
class _Wp extends State<WallpaperPage> {
  List items = [];
  bool loading = false;
  String err = '';
  final searchC = TextEditingController();
  int page = 1;

  @override void initState() { super.initState(); _fetch(); }

  Future<void> _fetch({String q = '', bool more = false}) async {
    setState(() { loading = true; err = ''; });
    try {
      final pg = more ? page + 1 : 1;
      final url = 'https://wallhaven.cc/api/v1/search?sorting=${q.isEmpty ? 'toplist' : 'relevance'}'
        '${q.isEmpty ? '' : '&q=${Uri.encodeComponent(q)}'}&page=$pg&purity=100';
      final r = await http.get(Uri.parse(url), headers: {'User-Agent': 'ThirdHub/4'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final list = (jsonDecode(utf8.decode(r.bodyBytes))['data'] as List?) ?? [];
      setState(() { page = pg; if (more) { items.addAll(list); } else { items = list; } });
    } catch (e) { setState(() => err = '$e'); }
    setState(() => loading = false);
  }

  Future<void> _download(Map w) async {
    try {
      final r = await http.get(Uri.parse(w['path']), headers: {'User-Agent': 'ThirdHub/4'}).timeout(const Duration(seconds: 60));
      final ext = await getExternalStorageDirectory();
      final dir = Directory('${ext!.path}/wallpapers'); if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}/wp-${w['id']}.jpg');
      await f.writeAsBytes(r.bodyBytes);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存: ${f.path}\n可到 文件 模块设为壁纸')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    }
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
      Expanded(child: TextField(controller: searchC, decoration: const InputDecoration(
        hintText: '搜索壁纸(英文更准, 如 nature / anime)…', isDense: true, border: OutlineInputBorder()),
        onSubmitted: (v) => _fetch(q: v.trim()))),
      const SizedBox(width: 6),
      IconButton.filled(icon: const Icon(Icons.search, size: 20), onPressed: () => _fetch(q: searchC.text.trim())),
    ])),
    if (err.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text('加载失败: $err', style: const TextStyle(fontSize: 11, color: Colors.redAccent))),
    Expanded(child: items.isEmpty
      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            if (loading) const CircularProgressIndicator()
            else const Icon(Icons.image_not_supported_outlined, size: 34, color: Colors.grey),
            const SizedBox(height: 10),
            Text(
              // 原来无论「在加载」「失败」「真没结果」都写「加载中或没有结果」，
              // 用户分不清是卡住了还是没搜到。三态分开说。
              loading
                  ? '正在拉取壁纸…'
                  : (err.isNotEmpty
                      ? '没拉到壁纸（上方是失败原因）\n换个英文关键词试试，例如 nature / city / anime'
                      : '还没有壁纸\n搜一个英文关键词开始，例如 nature / city / anime'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.6)),
            if (!loading)
              TextButton(onPressed: () => _fetch(q: searchC.text.trim()),
                child: const Text('重试', style: TextStyle(fontSize: 12))),
          ])))
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4, childAspectRatio: 0.65),
        padding: const EdgeInsets.all(8),
        itemCount: items.length + 1,
        itemBuilder: (_, i) {
          if (i == items.length) return TextButton(onPressed: loading ? null : () => _fetch(q: searchC.text.trim(), more: true),
            child: Text(loading ? '加载中…' : '加载更多'));
          final w = items[i];
          final thumb = w['thumbs']?['small'] ?? w['thumbs']?['original'] ?? '';
          return InkWell(onTap: () => _preview(c, w), child: ClipRRect(borderRadius: BorderRadius.circular(8),
            child: Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: Colors.grey.withValues(alpha: 0.2)))));
        })),
  ]);

  void _preview(BuildContext c, Map w) {
    Navigator.push(c, MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text('${w['resolution'] ?? ''}', style: const TextStyle(fontSize: 13))),
      body: Center(child: InteractiveViewer(child: Image.network(w['path'],
        loadingBuilder: (_, child, p) => p == null ? child : const Center(child: CircularProgressIndicator())))),
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.download), label: const Text('下载原图'),
        onPressed: () => _download(w)),
    )));
  }
}

// ═══ 广播: radio-browser 公共电台库 + 在线收听 ═══
class RadioPage extends StatefulWidget { const RadioPage({super.key}); @override State<RadioPage> createState() => _Radio(); }
class _Radio extends State<RadioPage> {
  List stations = [];
  bool loading = false;
  String err = '';
  final searchC = TextEditingController();
  final _player = AudioPlayer();
  String? playingUrl;
  String playingName = '';
  Set<String> favs = {};

  static const apis = ['https://de1.api.radio-browser.info/json', 'https://nl1.api.radio-browser.info/json', 'https://at1.api.radio-browser.info/json'];

  @override void initState() { super.initState(); _loadFavs(); _top(); }
  @override void dispose() { _player.dispose(); super.dispose(); }
  Future<void> _loadFavs() async {
    final p = await SharedPreferences.getInstance();
    setState(() => favs = (p.getStringList('radio_favs') ?? []).toSet());
  }

  Future<String> _get(String path) async {
    Exception? last;
    for (final base in apis) {
      try {
        final r = await http.get(Uri.parse('$base$path'), headers: {'User-Agent': 'ThirdHub/4'}).timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) return utf8.decode(r.bodyBytes);
      } catch (e) { last = Exception('$e'); }
    }
    throw last ?? Exception('所有节点不可用');
  }

  Future<void> _top() async {
    setState(() { loading = true; err = ''; });
    try {
      final body = await _get('/stations/topclick/60');
      setState(() => stations = jsonDecode(body));
    } catch (e) { setState(() => err = '$e'); }
    setState(() => loading = false);
  }
  Future<void> _search(String q) async {
    if (q.isEmpty) { _top(); return; }
    setState(() { loading = true; err = ''; });
    try {
      final body = await _get('/stations/search?name=${Uri.encodeComponent(q)}&limit=60&hidebroken=true');
      setState(() => stations = jsonDecode(body));
    } catch (e) { setState(() => err = '$e'); }
    setState(() => loading = false);
  }

  Future<void> _play(Map s) async {
    final url = s['url_resolved'] ?? s['url'] ?? '';
    if (url.isEmpty) return;
    if (playingUrl == url) { await _player.stop(); setState(() { playingUrl = null; playingName = ''; }); return; }
    try {
      await _player.setAudioSource(tagUrl(url, title: '${s['name'] ?? '网络电台'}', album: 'ThirdHub 电台'));
      setState(() { playingUrl = url; playingName = s['name'] ?? ''; });
      await _player.play();
      Recents.add('radio', '${s['name'] ?? '网络电台'}', target: url);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('播放失败: $e')));
    }
  }

  Future<void> _toggleFav(Map s) async {
    final id = s['stationuuid'] ?? s['url'] ?? '';
    if (favs.contains(id)) { favs.remove(id); } else { favs.add(id); }
    final p = await SharedPreferences.getInstance();
    await p.setStringList('radio_favs', favs.toList());
    setState(() {});
  }

  @override Widget build(BuildContext c) => Column(children: [
    if (playingName.isNotEmpty) Container(color: Theme.of(c).colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        const Icon(Icons.graphic_eq, size: 18), const SizedBox(width: 8),
        Expanded(child: Text(playingName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        IconButton(icon: const Icon(Icons.stop, size: 20), onPressed: () async { await _player.stop(); setState(() { playingUrl = null; playingName = ''; }); }),
      ])),
    Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
      Expanded(child: TextField(controller: searchC, decoration: const InputDecoration(
        hintText: '搜索电台(如 BBC / 中文 / jazz)…', isDense: true, border: OutlineInputBorder()),
        onSubmitted: (v) => _search(v.trim()))),
      const SizedBox(width: 6),
      IconButton.filled(icon: const Icon(Icons.search, size: 20), onPressed: () => _search(searchC.text.trim())),
    ])),
    if (err.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text('加载失败: $err', style: const TextStyle(fontSize: 11, color: Colors.redAccent))),
    Expanded(child: loading
      ? const Center(child: CircularProgressIndicator())
      : stations.isEmpty
      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.radio_outlined, size: 34, color: Colors.grey),
            const SizedBox(height: 10),
            // 原来 0 条时 listView itemCount=0 → 一片空白，用户以为界面坏了
            Text(err.isNotEmpty
                ? '没搜到电台（上方是失败原因）\n电台库是公开接口，偶尔会抽风，稍后再试一次'
                : '还没有电台\n搜一个关键词开始，例如 BBC / jazz / 中文',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.6)),
            TextButton(onPressed: () => _search(searchC.text.trim()),
              child: const Text('重试', style: TextStyle(fontSize: 12))),
          ])))
      : ListView.builder(itemCount: stations.length, itemBuilder: (_, i) {
          final s = stations[i];
          final id = s['stationuuid'] ?? s['url'] ?? '';
          final on = playingUrl == (s['url_resolved'] ?? s['url']);
          return ListTile(dense: true,
            leading: Icon(on ? Icons.stop_circle : Icons.play_circle_outline, size: 26,
              color: on ? Theme.of(c).colorScheme.primary : null),
            title: Text(s['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Text('${s['country'] ?? ''} ${s['tags'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
            trailing: IconButton(icon: Icon(favs.contains(id) ? Icons.star : Icons.star_border, size: 18,
              color: favs.contains(id) ? Colors.amber : Colors.grey), onPressed: () => _toggleFav(s)),
            onTap: () => _play(s));
        })),
  ]);
}

// ═══ 播客: RSS 订阅 + 单集在线听 ═══
class PodcastPage extends StatefulWidget { const PodcastPage({super.key}); @override State<PodcastPage> createState() => _Pod(); }
class _Pod extends State<PodcastPage> {
  List<Map<String, dynamic>> feeds = []; // {title, url}
  List<Map<String, String>> episodes = [];
  String curFeed = '';
  bool loading = false;
  String err = '';
  final _player = AudioPlayer();
  String? playingUrl;
  String playingTitle = '';

  /// 内置源版本。**改了内置源就必须 +1** —— 见 `_load()` 里的迁移：
  /// 老代码的判据是 `if (saved.isEmpty)`，一旦用户机器上已有旧列表，新内置源
  /// **永远进不来**。这与第十二轮「预置书源包改了但老安装不生效」是同一类坑，
  /// 只是对象换成了「内置 RSS 源」。
  static const builtinVer = 2;
  /// 只写**实测可用**的源（本次逐条拉起核对：HTTP 200 且含音频 enclosure）。
  static const builtin = [
    {'title': '故事FM', 'url': 'https://feeds.storyfm.cn/storyfm.xml'},
    {'title': '声东击西', 'url': 'https://feeds.fireside.fm/shengdongjixi/rss'},
    {'title': '忽左忽右', 'url': 'https://feed.xyzfm.space/cv4bkgpuglwp'},
  ];
  /// 已下线的旧内置源。**只清理内置项，用户自己加的源一律保留。**
  /// · `feed.xyzfm.space/9h8wkgvmq2f9` 是「小宇宙精选·声东击西」的旧 token，实测 **HTTP 404**；
  /// · `www.gcores.com/rss` 是机核的**图文** RSS，实测 `mp3=0 / enclosure=0`
  ///   → 在播客模块里永远解析出 0 集（它不是播客源，之前被误当播客源内置）。
  static const retiredBuiltin = [
    'https://feed.xyzfm.space/9h8wkgvmq2f9',
    'https://www.gcores.com/rss',
  ];

  @override void initState() { super.initState(); _load(); }
  @override void dispose() { _player.dispose(); super.dispose(); }
  Future<void> _load() async {
    final saved = await _Store4.list('podcast_feeds');
    final p = await SharedPreferences.getInstance();
    final seen = p.getInt('podcast_feeds_builtin_v') ?? 0;
    List<Map<String, dynamic>> list = saved;
    if (saved.isEmpty) {
      list = builtin.map((e) => Map<String, dynamic>.from(e)).toList();
    } else if (seen < builtinVer) {
      // 老安装升级：① 摘掉已下线的**内置**源；② 补齐缺失的内置源；③ 用户自加的原样保留。
      list = saved.where((f) => !retiredBuiltin.contains('${f['url']}')).toList();
      for (final b in builtin) {
        if (!list.any((f) => f['url'] == b['url'])) list.add(Map<String, dynamic>.from(b));
      }
    }
    await p.setInt('podcast_feeds_builtin_v', builtinVer);
    await _Store4.save('podcast_feeds', list);
    if (!mounted) return;
    setState(() => feeds = list);
  }

  Future<void> _addFeed() async {
    final urlC = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('添加播客 RSS'),
      content: TextField(controller: urlC, decoration: const InputDecoration(hintText: 'https://…/feed.xml', isDense: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('添加'))]));
    if (ok != true || urlC.text.trim().isEmpty) return;
    feeds.add({'title': urlC.text.trim(), 'url': urlC.text.trim()});
    await _Store4.save('podcast_feeds', feeds);
    _load();
    _openFeed(feeds.last);
  }

  /// 在线找源（**兜底**）。
  ///
  /// 为什么需要它：内置 RSS 会随时间腐烂 —— 本次实测就发现两个内置源一个 **HTTP 404**、
  /// 一个**根本没有音频**，也就是**开箱即空**。而界面上此前只有一个「添加 RSS」，
  /// 等于要用户自己去别处找一个 feed 地址贴进来（多数人做不到，于是这个模块等于废掉）。
  /// 这里改用 Apple Podcasts 的**公开搜索接口**按关键词找真实可用的 feed（返回体带 `feedUrl`），
  /// 搜到即可一键加入源列表。接口无需密钥，实测 `HTTP 200` 且能拿到 `feedUrl`。
  Future<void> _discover() async {
    final qc = TextEditingController();
    final term = await showDialog<String>(context: context, builder: (c2) => AlertDialog(
      title: const Text('在线找播客源'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('按节目名或关键词搜索（Apple Podcasts 公开目录）', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 10),
        TextField(controller: qc, autofocus: true, decoration: const InputDecoration(hintText: '例如：故事FM / 忽左忽右', isDense: true)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, qc.text.trim()), child: const Text('搜索'))]));
    if (term == null || term.isEmpty) return;
    setState(() { loading = true; err = ''; });
    try {
      final r = await http.get(Uri.parse('https://itunes.apple.com/search?media=podcast&limit=20&term=${Uri.encodeComponent(term)}'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final found = <Map<String, dynamic>>[];
      for (final it in (j['results'] as List? ?? [])) {
        final url = '${it['feedUrl'] ?? ''}';
        if (url.isEmpty) continue;
        if (feeds.any((f) => f['url'] == url) || found.any((f) => f['url'] == url)) continue;
        found.add({'title': '${it['collectionName'] ?? url}', 'url': url});
      }
      if (!mounted) return;
      setState(() => loading = false);
      if (found.isEmpty) {
        setState(() => err = '没搜到带 RSS 的节目，换个关键词试试');
        return;
      }
      final pick = await showDialog<Map<String, dynamic>>(context: context, builder: (c2) => SimpleDialog(
        title: Text('找到 ${found.length} 个源'),
        children: [for (final f in found.take(12)) SimpleDialogOption(
          onPressed: () => Navigator.pop(c2, f),
          child: Text('${f['title']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)))]));
      if (pick == null) return;
      feeds.add(pick);
      await _Store4.save('podcast_feeds', feeds);
      if (!mounted) return;
      setState(() {});
      _openFeed(pick);
    } catch (e) {
      if (mounted) setState(() { loading = false; err = '在线找源失败: $e'; });
    }
  }

  // 极简 RSS 解析(正则够用): title + enclosure url + pubDate
  static List<Map<String, String>> _parseRss(String src) {
    final out = <Map<String, String>>[];
    final items = RegExp(r'<item[\s>]([\s\S]*?)</item>').allMatches(src);
    for (final m in items.take(80)) {
      final b = m.group(1)!;
      String pick(String tag) {
        final mm = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>').firstMatch(b);
        var v = mm?.group(1) ?? '';
        v = v.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '').trim();
        return v;
      }
      final enc = RegExp(r'<enclosure[^>]*url="([^"]+)"').firstMatch(b);
      final audio = enc?.group(1) ?? RegExp(r'(https?://[^\s"<>]+\.mp3[^\s"<>]*)').firstMatch(b)?.group(1) ?? '';
      if (audio.isEmpty) continue;
      out.add({'title': pick('title'), 'audio': audio, 'date': pick('pubDate')});
    }
    return out;
  }

  Future<void> _openFeed(Map f) async {
    setState(() { loading = true; err = ''; curFeed = f['title']; episodes = []; });
    try {
      final r = await http.get(Uri.parse(f['url']), headers: {'User-Agent': 'ThirdHub/4'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final eps = _parseRss(utf8.decode(r.bodyBytes));
      setState(() { episodes = eps; });
      // 顺手把真实标题存回来
      final titleM = RegExp(r'<title[^>]*>([\s\S]*?)</title>').firstMatch(utf8.decode(r.bodyBytes));
      if (titleM != null && (f['title'] as String).startsWith('http')) {
        f['title'] = titleM.group(1)!.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '').trim();
        await _Store4.save('podcast_feeds', feeds);
      }
    } catch (e) { setState(() => err = '$e'); }
    setState(() => loading = false);
  }

  Future<void> _play(Map<String, String> ep) async {
    final url = ep['audio']!;
    if (playingUrl == url) { await _player.stop(); setState(() { playingUrl = null; playingTitle = ''; }); return; }
    try {
      await _player.setAudioSource(tagUrl(url, title: ep['title'] ?? '播客节目', album: 'ThirdHub 播客'));
      setState(() { playingUrl = url; playingTitle = ep['title'] ?? ''; });
      await _player.play();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('播放失败: $e')));
    }
  }

  /// 空态兜底：无论是「还没选源」还是「选了但一条都取不到」，都必须给得出**出口**。
  /// 旧版这里只有一句「选一个播客源开始 / 也可以添加自己的 RSS」—— 在「内置源全都失效」
  /// 的情况下，这句话既没说明原因、也没给任何可点的操作，模块看起来就是坏的。
  Widget _emptyBox() {
    final failed = curFeed.isNotEmpty && episodes.isEmpty;
    return Center(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
      Icon(failed ? Icons.podcasts : Icons.rss_feed, size: 42, color: Colors.grey),
      const SizedBox(height: 10),
      Text(failed ? '这个源没能取到节目' : '选一个播客源开始', style: const TextStyle(fontSize: 14)),
      const SizedBox(height: 6),
      Text(failed
          ? '「$curFeed」没有返回可播放的音频。内置源会随时间失效，可以重试、换一个源，或在线找一个能用的。'
          : '也可以点「在线找源」按节目名搜，或直接添加自己的 RSS 地址。',
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
        FilledButton.tonalIcon(onPressed: _discover,
          icon: const Icon(Icons.travel_explore, size: 16), label: const Text('在线找源')),
        TextButton.icon(onPressed: _addFeed, icon: const Icon(Icons.add, size: 16), label: const Text('加 RSS')),
      ]),
    ]))));
  }

  @override Widget build(BuildContext c) => Column(children: [
    if (playingTitle.isNotEmpty) Container(color: Theme.of(c).colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        const Icon(Icons.graphic_eq, size: 18), const SizedBox(width: 8),
        Expanded(child: Text(playingTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        IconButton(icon: const Icon(Icons.stop, size: 20), onPressed: () async { await _player.stop(); setState(() { playingUrl = null; playingTitle = ''; }); }),
      ])),
    SizedBox(height: 46, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      children: [
        for (final f in feeds) Padding(padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(label: Text(f['title'], style: const TextStyle(fontSize: 11)),
            selected: curFeed == f['title'], onSelected: (_) => _openFeed(f))),
        ActionChip(avatar: const Icon(Icons.add, size: 14), label: const Text('添加 RSS', style: TextStyle(fontSize: 11)),
          onPressed: _addFeed),
      ])),
    if (err.isNotEmpty && episodes.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: Text('加载失败: $err', style: const TextStyle(fontSize: 11, color: Colors.redAccent))),
    Expanded(child: loading
      ? const Center(child: CircularProgressIndicator())
      : episodes.isEmpty
        ? _emptyBox()
        : ListView.builder(itemCount: episodes.length, itemBuilder: (_, i) {
            final ep = episodes[i];
            final on = playingUrl == ep['audio'];
            return ListTile(dense: true,
              leading: Icon(on ? Icons.stop_circle : Icons.play_circle_outline, size: 24,
                color: on ? Theme.of(c).colorScheme.primary : null),
              title: Text(ep['title'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: Text((ep['date'] ?? '').length > 16 ? ep['date']!.substring(0, 16) : ep['date'] ?? '',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
              onTap: () => _play(ep));
          })),
  ]);
}

// ═══ 书签: 与浏览器模块共用同一份书签(规划「模块合并」——不再各存一份) ═══
// 存储键与浏览器完全一致('browser_bookmarks'); 首次打开把旧独立书签迁移过来。
// 点按书签 → 内置浏览器打开(跨模块调用), 不再跳系统浏览器。
class BookmarksPage extends StatefulWidget { const BookmarksPage({super.key}); @override State<BookmarksPage> createState() => _Bm(); }
class _Bm extends State<BookmarksPage> {
  List<Map<String, String>> items = [];

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    try { items = [ for (final e in jsonDecode(p.getString('browser_bookmarks') ?? '[]') as List) Map<String, String>.from(e) ]; } catch (_) { items = []; }
    // 一次性迁移: 旧独立书签(_Store4 'bookmarks')并进浏览器书签
    if (p.getBool('bookmarks_merged_v1') != true) {
      try {
        final legacy = await _Store4.list('bookmarks');
        if (legacy.isNotEmpty) {
          for (final e in legacy) {
            final url = '${e['url'] ?? ''}';
            if (url.isEmpty || items.any((b) => b['url'] == url)) continue;
            items.add({'title': '${e['title'] ?? url}', 'url': url, 'at': DateTime.now().toString().substring(0, 16)});
          }
          await _save();
        }
        await p.setBool('bookmarks_merged_v1', true);
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }
  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('browser_bookmarks', jsonEncode(items));
  }

  Future<void> _add() async {
    final titleC = TextEditingController(); final urlC = TextEditingController();
    // 如果剪贴板里是链接, 自动填上
    try { final d = await Clipboard.getData('text/plain');
      if ((d?.text ?? '').startsWith('http')) urlC.text = d!.text!; } catch (_) {}
    if (!mounted) return;
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('添加书签'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: titleC, decoration: const InputDecoration(labelText: '名称', isDense: true)),
        TextField(controller: urlC, decoration: const InputDecoration(labelText: '链接', isDense: true)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))]));
    if (ok != true || urlC.text.trim().isEmpty) return;
    var url = urlC.text.trim();
    if (!url.startsWith('http')) url = 'https://$url';
    items.insert(0, {'title': titleC.text.trim().isEmpty ? Uri.parse(url).host : titleC.text.trim(),
      'url': url, 'at': DateTime.now().toString().substring(0, 16)});
    await _save();
    _load();
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.add, size: 18), label: const Text('添加书签(与浏览器同步)'), onPressed: _add))),
    Expanded(child: items.isEmpty
      ? const Center(child: Text('还没有书签\n浏览器里点地址栏右侧书签图标也会进这里', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView(children: [
          for (final e in items) Dismissible(key: ValueKey('${e['at']}_${e['url']}'),
            direction: DismissDirection.endToStart,
            background: Container(color: Colors.redAccent, alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
            onDismissed: (_) { items.remove(e); _save().then((_) => _load()); },
            child: ListTile(dense: true,
              leading: const Icon(Icons.bookmark_border, size: 20),
              title: Text(e['title'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: Text(e['url'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
              trailing: const Icon(Icons.open_in_new, size: 16, color: Colors.grey),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => BrowserPage(initialUrl: e['url']))))),
        ])),
  ]);
}

// ═══ 代码片段: 按语言收藏 + 复制 ═══
class SnippetsPage extends StatefulWidget { const SnippetsPage({super.key}); @override State<SnippetsPage> createState() => _Snip(); }
class _Snip extends State<SnippetsPage> {
  List<Map<String, dynamic>> items = [];
  static const langs = ['其他', 'Dart', 'Python', 'JS/TS', 'Java/Kotlin', 'C/C++', 'Go', 'Rust', 'Shell', 'SQL', 'HTML/CSS'];
  String filter = '全部';

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final v = await _Store4.list('snippets');
    if (!mounted) return;
    setState(() => items = v);
  }

  Future<void> _edit([Map<String, dynamic>? exist]) async {
    final titleC = TextEditingController(text: exist?['title'] ?? '');
    final codeC = TextEditingController(text: exist?['code'] ?? '');
    var lang = exist?['lang'] ?? '其他';
    final ok = await showDialog<bool>(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: Text(exist == null ? '新建代码片段' : '编辑片段'),
      content: SizedBox(width: 500, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: TextField(controller: titleC, decoration: const InputDecoration(labelText: '标题(如: 防抖函数)', isDense: true))),
          const SizedBox(width: 8),
          DropdownButton<String>(value: lang, items: [for (final l in langs) DropdownMenuItem(value: l, child: Text(l, style: const TextStyle(fontSize: 12)))],
            onChanged: (v) => setD(() => lang = v ?? '其他')),
        ]),
        const SizedBox(height: 8),
        TextField(controller: codeC, maxLines: 10, style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(hintText: '贴代码…', border: OutlineInputBorder(), isDense: true)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))])));
    if (ok != true || codeC.text.trim().isEmpty) return;
    if (exist != null) items.remove(exist);
    items.insert(0, {'title': titleC.text.trim().isEmpty ? '未命名片段' : titleC.text.trim(),
      'code': codeC.text, 'lang': lang, 'ts': DateTime.now().millisecondsSinceEpoch});
    await _Store4.save('snippets', items);
    _load();
  }

  @override Widget build(BuildContext c) {
    final shown = filter == '全部' ? items : items.where((e) => e['lang'] == filter).toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
        Expanded(child: SizedBox(height: 36, child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final l in ['全部', ...langs]) Padding(padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(label: Text(l, style: const TextStyle(fontSize: 11)), selected: filter == l,
              onSelected: (_) => setState(() => filter = l))),
        ]))),
        IconButton.filled(icon: const Icon(Icons.add, size: 20), tooltip: '新建片段', onPressed: () => _edit()),
      ])),
      Expanded(child: shown.isEmpty
        ? const Center(child: Text('还没有代码片段\n点右上角 + 收藏一段', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
        : ListView(children: [
            for (final e in shown) Card(margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: ListTile(
                title: Text(e['title'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text((e['code'] ?? '').toString().split('\n').take(2).join('\n'),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey)),
                trailing: Text(e['lang'] ?? '', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                onTap: () => _edit(e),
                onLongPress: () { Clipboard.setData(ClipboardData(text: e['code'] ?? ''));
                  ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('代码已复制'))); })),
          ])),
    ]);
  }
}
