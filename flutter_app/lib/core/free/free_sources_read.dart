// 可阅读的开放源：MangaDex（漫画）/ 中文维基文库（书）/ 古登堡澳洲站（公版书）/ 今日诗词
//
// 之所以是这几个：
//   · 漫画板块在后端是 8 源 0 条（全废），MangaDex 是唯一有公开文档且实测可用的正规漫画 API；
//   · 小说板块依赖后端 2415 个书源，App 内跑不了，公版书用维基文库/古登堡是**干净合法**的替代；
//   · 维基文库在国内**间歇可达**（实测两次通、两次超时），所以必须做成「可失败」的源，
//     不能让它拖死整个页面 —— 这是这里所有 try 都单独兜的原因。
import 'dart:convert';

import 'free_http.dart';
import 'free_models.dart';
import 'free_sources_media.dart' show asList, asMap;

// ─────────────────────────────────────────────────────────────
// MangaDex —— 有官方文档的开放漫画 API（OAuth 可选，只读接口匿名即可）
// ─────────────────────────────────────────────────────────────
class MangaDexSource {
  MangaDexSource._();

  static const String id = 'mangadex';
  static const String name = 'MangaDex';
  static const String note = '开放漫画库，官方文档 API，支持中文，只读匿名可用';
  // ★探活用实测通过的 /manga?limit=1，不用 /ping：
  //   /ping 在部分网络下返回 404，会让 UI 误判「整个源不可达」，
  //   而实际搜索是好的 —— 假红比没红更糟。
  static const String pingUrl = 'https://api.mangadex.org/manga?limit=1';

  static const String _api = 'https://api.mangadex.org';
  static const String _uploads = 'https://uploads.mangadex.org';

  /// 内容分级只取 safe / suggestive，**排除 erotica / pornographic**。
  /// 这是「正规」这条底线的一部分，不是可选项。
  static const List<String> _ratings = ['safe', 'suggestive'];

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.comic, pingUrl: pingUrl);

  /// 搜索。
  ///
  /// MangaDex 对 UA 有要求：**不能是浏览器 UA**（实测浏览器 UA 直接 403
  /// 「Bot challenge」）。FreeHttp 的默认 UA 是 `ThirdHub/4.81.77 (Android; …)`，
  /// 恰好满足，不要在这里改成 Chrome。
  static Future<List<FreeItem>> search(String q, {int limit = 20}) async {
    final b = StringBuffer('$_api/manga?limit=$limit');
    b.write('&title=${Uri.encodeQueryComponent(q)}');
    b.write('&includes%5B%5D=cover_art');
    for (final r in _ratings) {
      b.write('&contentRating%5B%5D=$r');
    }
    b.write('&order%5Brelevance%5D=desc');
    return _list(await FreeHttp.json(b.toString()));
  }

  /// 热门中文作品（无关键词时的首屏）。
  static Future<List<FreeItem>> popularZh({int limit = 20}) async {
    final b = StringBuffer('$_api/manga?limit=$limit');
    b.write('&includes%5B%5D=cover_art');
    b.write('&translatedLanguage%5B%5D=zh');
    b.write('&hasAvailableChapters=true');
    for (final r in _ratings) {
      b.write('&contentRating%5B%5D=$r');
    }
    b.write('&order%5BfollowedCount%5D=desc');
    return _list(await FreeHttp.json(b.toString()));
  }

  /// 章节列表。中文优先，没有中文就退回全部语言（至少能看）。
  static Future<List<FreeItem>> chapters(FreeItem manga,
      {String lang = 'zh'}) async {
    final mid = manga.id;
    Future<List<FreeItem>> fetch(String? language) async {
      final b = StringBuffer('$_api/manga/$mid/feed?limit=500');
      b.write('&order%5Bvolume%5D=asc&order%5Bchapter%5D=asc');
      b.write('&includes%5B%5D=scanlation_group');
      if (language != null) b.write('&translatedLanguage%5B%5D=$language');
      for (final r in _ratings) {
        b.write('&contentRating%5B%5D=$r');
      }
      final d = await FreeHttp.json(b.toString());
      final out = <FreeItem>[];
      for (final c in asList(d['data'])) {
        final m = asMap(c);
        final a = asMap(m['attributes']);
        final cid = '${m['id'] ?? ''}';
        if (cid.isEmpty) continue;
        final chNo = '${a['chapter'] ?? ''}';
        final chTitle = '${a['title'] ?? ''}'.trim();
        final pages = (a['pages'] as num?)?.toInt() ?? 0;
        final langName = _langName('${a['translatedLanguage'] ?? ''}');
        out.add(FreeItem(
          id: cid,
          source: id,
          kind: FreeKind.comic,
          title: chNo.isEmpty
              ? (chTitle.isEmpty ? '（无编号）' : chTitle)
              : '第 $chNo 话${chTitle.isEmpty ? '' : ' · $chTitle'}',
          subtitle: [
            if (pages > 0) '$pages 页',
            if (langName.isNotEmpty) langName,
          ].join(' · '),
          cover: manga.cover,
          raw: {'chapterId': cid, 'manga': manga.displayTitle},
        ));
      }
      return out;
    }

    final zh = await fetch(lang);
    if (zh.isNotEmpty) return zh;
    // 中文没有 → 全语言兜底，避免"这漫画点进去是空的"。
    return fetch(null);
  }

  /// 取一话的图片地址列表。
  ///
  /// `dataSaver` 是压缩版（体积约 1/3），弱网/移动流量下更合适；
  /// 本项目此前漫画板块全废，这次至少保证「能看」优先于「最高清」。
  static Future<List<String>> pages(String chapterId,
      {bool dataSaver = true}) async {
    final d = await FreeHttp.json('$_api/at-home/server/$chapterId');
    final base = '${d['baseUrl'] ?? ''}';
    if (base.isEmpty) {
      throw const FreeNetException('漫画服务器未返回图片地址');
    }
    final ch = asMap(d['chapter']);
    final hash = '${ch['hash'] ?? ''}';
    final files = asList(dataSaver ? ch['dataSaver'] : ch['data']);
    if (files.isEmpty) {
      // 极少数章节没有 dataSaver，回落原图。
      final full = asList(ch['data']);
      return [for (final f in full) '$base/data/$hash/$f'];
    }
    final seg = dataSaver ? 'data-saver' : 'data';
    return [for (final f in files) '$base/$seg/$hash/$f'];
  }

  static List<FreeItem> _list(Map<String, dynamic> d) {
    final out = <FreeItem>[];
    for (final e in asList(d['data'])) {
      final m = asMap(e);
      final mid = '${m['id'] ?? ''}';
      if (mid.isEmpty) continue;
      final a = asMap(m['attributes']);
      // 标题优先中文，其次繁中/别名，再次任意一种语言，最后退回 id。
      final titleMap = asMap(a['title']);
      final zhAlt = _findZhAlt(asList(a['altTitles']));
      var title = '${titleMap['zh'] ?? titleMap['zh-hk'] ?? zhAlt}'.trim();
      if (title.isEmpty && titleMap.isNotEmpty) title = '${titleMap.values.first}'.trim();
      if (title.isEmpty) title = mid;
      // 简介：description 是 {语言: 文本}，取中文，没有就取英文。
      var desc = '';
      final dsc = a['description'];
      if (dsc is Map) {
        final dm = asMap(dsc);
        desc = '${dm['zh'] ?? dm['en'] ?? ''}';
      }
      final status = '${a['status'] ?? ''}';
      final year = (a['year'] as num?)?.toInt() ?? 0;
      String cover = '';
      for (final rel in asList(m['relationships'])) {
        final r = asMap(rel);
        if ('${r['type']}' == 'cover_art') {
          final fn = '${asMap(r['attributes'])['fileName'] ?? ''}';
          if (fn.isNotEmpty) cover = '$_uploads/covers/$mid/$fn.512.jpg';
        }
      }
      out.add(FreeItem(
        id: mid,
        source: id,
        kind: FreeKind.comic,
        title: title,
        subtitle: [
          if (year > 0) '$year',
          _statusName(status),
        ].where((s) => s.isNotEmpty).join(' · '),
        cover: cover,
        desc: stripHtml(desc),
        drill: true,
        raw: m,
      ));
    }
    return out;
  }

  static String _findZhAlt(List<dynamic> alts) {
    for (final a in alts) {
      final m = asMap(a);
      final zh = '${m['zh'] ?? m['zh-hk'] ?? ''}';
      if (zh.isNotEmpty) return zh;
    }
    return '';
  }

  static String _statusName(String s) {
    switch (s) {
      case 'ongoing':
        return '连载中';
      case 'completed':
        return '已完结';
      case 'hiatus':
        return '休载';
      case 'cancelled':
        return '已取消';
      default:
        return '';
    }
  }

  static String _langName(String code) {
    switch (code) {
      case 'zh':
        return '中文';
      case 'zh-hk':
        return '繁中';
      case 'en':
        return '英文';
      case 'ja':
        return '日文';
      default:
        return code;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 中文维基文库 —— 公版古籍与现代公版作品的正文（MediaWiki 官方 API）
// ─────────────────────────────────────────────────────────────
class WikisourceSource {
  WikisourceSource._();

  static const String id = 'wikisource';
  static const String name = '维基文库';
  static const String note = '公版书籍与古籍全文，MediaWiki 官方接口（国内时通时不通）';
  static const String pingUrl =
      'https://zh.wikisource.org/w/api.php?action=query&meta=siteinfo&format=json';

  static const String _api = 'https://zh.wikisource.org/w/api.php';

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.book, pingUrl: pingUrl);

  /// 搜作品。`intitle:` 让匹配落在标题上，避免全文搜索把无关页面带进来。
  static Future<List<FreeItem>> search(String q, {int limit = 20}) async {
    Map<String, dynamic> d;
    try {
      d = await FreeHttp.json(_api, query: {
        'action': 'query',
        'list': 'search',
        'srsearch': 'intitle:$q',
        'srlimit': '$limit',
        'format': 'json',
        'formatversion': '2',
      });
    } on FreeNetException catch (e) {
      // 维基系在国内是间歇性的：网络层失败重试一次（换不了 IP，但能跨过瞬时抖动）。
      if (!e.offline) rethrow;
      d = await FreeHttp.json(_api,
          timeout: const Duration(seconds: 22),
          query: {
            'action': 'query',
            'list': 'search',
            'srsearch': 'intitle:$q',
            'srlimit': '$limit',
            'format': 'json',
            'formatversion': '2',
          });
    }
    final out = <FreeItem>[];
    for (final s in asList(asMap(d['query'])['search'])) {
      final m = asMap(s);
      final title = '${m['title'] ?? ''}';
      if (title.isEmpty) continue;
      out.add(FreeItem(
        id: title,
        source: id,
        kind: FreeKind.book,
        title: title,
        subtitle: stripHtml('${m['snippet'] ?? ''}'),
        // 带「/」的是子页面（某一回、某一章），可以直接读。
        drill: !title.contains('/'),
        raw: {'pageTitle': title},
      ));
    }
    return out;
  }

  /// 作品的子页面 = 目录（古籍通常按「回」拆页）。
  static Future<List<FreeItem>> toc(String pageTitle) async {
    final d = await FreeHttp.json(_api, query: {
      'action': 'query',
      'list': 'allpages',
      'apprefix': '$pageTitle/',
      'aplimit': '200',
      'format': 'json',
      'formatversion': '2',
    });
    final out = <FreeItem>[];
    for (final p in asList(asMap(d['query'])['allpages'])) {
      final m = asMap(p);
      final t = '${m['title'] ?? ''}';
      if (t.isEmpty) continue;
      out.add(FreeItem(
        id: t,
        source: id,
        kind: FreeKind.book,
        title: t.replaceFirst('$pageTitle/', ''),
        subtitle: '',
        raw: {'pageTitle': t},
      ));
    }
    // 没有子页面 → 这本书是单页，把它自己当唯一一章。
    if (out.isEmpty) {
      out.add(FreeItem(
        id: pageTitle,
        source: id,
        kind: FreeKind.book,
        title: pageTitle,
        raw: {'pageTitle': pageTitle},
      ));
    }
    return out;
  }

  /// 读正文（MediaWiki `action=parse`）。`variant=zh-cn` 统一简体。
  static Future<String> read(String pageTitle) async {
    final d = await FreeHttp.json(_api,
        timeout: const Duration(seconds: 25),
        query: {
          'action': 'parse',
          'page': pageTitle,
          'prop': 'text',
          'format': 'json',
          'formatversion': '2',
          'variant': 'zh-cn',
        });
    final html = '${asMap(d['parse'])['text'] ?? ''}';
    if (html.isEmpty) {
      throw const FreeNetException('这一页没有正文');
    }
    final text = stripHtml(html);
    if (text.length < 30) {
      throw const FreeNetException('这一页正文过短（可能是目录或空页）');
    }
    return text;
  }
}

// ─────────────────────────────────────────────────────────────
// 古登堡澳洲站 —— 公版英文书的纯 HTML 全文（Project Gutenberg Australia）
// ─────────────────────────────────────────────────────────────
class GutenbergAuSource {
  GutenbergAuSource._();

  static const String id = 'gutenberg_au';
  static const String name = '古登堡（澳洲站）';
  static const String note = '公版英文书全文，HTML 直读';
  static const String pingUrl = 'https://gutenberg.net.au/';

  static const String _base = 'https://gutenberg.net.au';

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.book, pingUrl: pingUrl);

  /// 两个索引页（A–M / N–Z）。
  static const Map<String, String> buckets = {
    'A–M': '$_base/plusfifty-a-m.html',
    'N–Z': '$_base/plusfifty-n-z.html',
  };

  static final Map<String, List<FreeItem>> _cache = {};

  /// 拉索引页并解析出书目。
  ///
  /// 索引是 700KB 的手写 HTML，结构是 `<a href="ebooksXX/XXXXXXXh.html">书名</a>`。
  /// 用正则挑「指向 ebooks 目录的链接」，再取锚文本 —— 比引 HTML 解析库稳，
  /// 也不会因为页面里其他链接（导航、脚注）混进来。
  static Future<List<FreeItem>> browse({String bucket = 'A–M'}) async {
    if (_cache.containsKey(bucket)) return _cache[bucket]!;
    final url = buckets[bucket];
    if (url == null) return const [];
    final html = await FreeHttp.text(url,
        timeout: const Duration(seconds: 30), maxBytes: 6 * 1024 * 1024);
    final out = <FreeItem>[];
    final re = RegExp(
        r'''<a\s[^>]*href\s*=\s*["']([^"']*ebooks[^"']*\.html?)["'][^>]*>([\s\S]{1,200}?)</a>''',
        caseSensitive: false);
    final seen = <String>{};
    for (final m in re.allMatches(html)) {
      final href = m.group(1) ?? '';
      final label = stripHtml(m.group(2) ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (href.isEmpty || label.isEmpty || label.length < 2) continue;
      final full = href.startsWith('http') ? href : '$_base/${href.replaceFirst(RegExp(r'^/'), '')}';
      if (!seen.add(full)) continue;
      out.add(FreeItem(
        id: full,
        source: id,
        kind: FreeKind.book,
        title: label,
        subtitle: 'Project Gutenberg Australia · 公版',
        drill: false,
        raw: {'url': full},
      ));
    }
    _cache[bucket] = out;
    return out;
  }

  /// 本地过滤（索引量大，服务端没有搜索接口）。
  static Future<List<FreeItem>> search(String q, {String bucket = 'A–M'}) async {
    final all = await browse(bucket: bucket);
    final k = q.toLowerCase().trim();
    if (k.isEmpty) return all;
    return all.where((e) => e.title.toLowerCase().contains(k)).toList();
  }

  /// 读全文。
  static Future<String> read(String url) async {
    final html = await FreeHttp.text(url,
        timeout: const Duration(seconds: 30), maxBytes: 12 * 1024 * 1024);
    final text = stripHtml(html);
    if (text.length < 200) {
      throw const FreeNetException('这本书的页面没有解析出正文');
    }
    return text;
  }
}

// ─────────────────────────────────────────────────────────────
// 今日诗词 —— 公开公益接口，给「书」板块一个每天都能看的小内容
// ─────────────────────────────────────────────────────────────
class PoemSource {
  PoemSource._();

  static const String id = 'poem';
  static const String name = '今日诗词';
  static const String note = '每日一句古典诗词，公开接口';
  static const String pingUrl = 'https://v1.jinrishici.com/all.json';

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.poem, pingUrl: pingUrl);

  /// 随机一句。返回 content/origin/author/category。
  static Future<Map<String, String>> one() async {
    final d = await FreeHttp.json(pingUrl);
    return {
      'content': '${d['content'] ?? ''}',
      'origin': '${d['origin'] ?? ''}',
      'author': '${d['author'] ?? ''}',
      'category': '${d['category'] ?? ''}',
    };
  }
}

/// 把所有「书」类源聚成一个列表，供 UI 展示来源说明。
List<FreeSource> get bookSources =>
    [WikisourceSource.source, GutenbergAuSource.source];

/// JSON 编码便捷入口（部分调试分支要用）。
String jsonBrief(Object? v, [int n = 160]) {
  final s = jsonEncode(v);
  return s.length > n ? '${s.substring(0, n)}…' : s;
}
