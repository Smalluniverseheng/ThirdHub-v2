// 端上小说引擎（4.81.84）—— 不连后端也能搜、能看
//
// ── 定位 ───────────────────────────────────────────────────────────────
//   「后端是保底，不是前提」。源池（995 个纯选择器源）打进安装包，
//   搜索/目录/正文全部在手机上直连源站完成；后端只在这条链路拿不到东西时兜底。
//
// ── 为什么不照搬后端 ───────────────────────────────────────────────────
//   后端是 Node + 2400 源 + JS 规则，端上跑不了 JS。但可用源里绝大多数是
//   纯选择器规则（见 legado.dart 顶部说明），这部分在端上执行反而更快
//   （不用过一次 NAS 中转），也不怕 NAS 关机。
//
// ── 关键行为 ───────────────────────────────────────────────────────────
//   ① 多源并发，先成功的先算数；总预算到点就返回已有的（不全军覆没）。
//   ② 记住每个源「成功过几次 / 失败过几次」，下次优先用能用的源
//      —— 995 个源里常年能用的可能只有几十个，不学习的话每次都从死源开始。
//   ③ 返回 JSON 与后端 /v1/search、/v1/toc、/v1/content 同构，UI 层无需分叉。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart' as cs;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../th_http.dart';
import '../th_http.dart' show ThirdHubHttpOverrides;
import 'legado.dart';

/// 一个书源（打包时裁过字段，见 assets/sources/novel-ok.json）。
class BookSource {
  BookSource({
    required this.name,
    required this.url,
    required this.searchUrl,
    required this.group,
    required this.ruleSearch,
    required this.ruleBookInfo,
    required this.ruleToc,
    required this.ruleContent,
    required this.header,
  });

  final String name;
  final String url;
  final String searchUrl;
  final String group;
  final Map<String, dynamic> ruleSearch;
  final Map<String, dynamic> ruleBookInfo;
  final Map<String, dynamic> ruleToc;
  final Map<String, dynamic> ruleContent;
  final String header;

  /// 源身份用 URL：和后端的 sourceId 语义一致（后端也是拿源地址当 id）。
  String get id => url;

  factory BookSource.fromJson(Map<String, dynamic> j) => BookSource(
        name: '${j['n'] ?? ''}'.trim(),
        url: '${j['u'] ?? ''}'.trim(),
        searchUrl: '${j['s'] ?? ''}'.trim(),
        group: '${j['g'] ?? ''}'.trim(),
        ruleSearch: _map(j['rs']),
        ruleBookInfo: _map(j['ri']),
        ruleToc: _map(j['rt']),
        ruleContent: _map(j['rc']),
        header: j['h'] is String ? j['h'] as String : '',
      );

  static Map<String, dynamic> _map(dynamic v) {
    if (v is Map) {
      return v.map((k, e) => MapEntry('$k', e is String ? e : '$e'));
    }
    if (v is String && v.trim().isNotEmpty) return {'': v};
    return const {};
  }
}

/// 一个源的搜索结果是否可用（用于学习）。
class _Score {
  int ok = 0;
  int fail = 0;
  double get rank => ok - fail * 0.6;
}

class LocalBookEngine {
  LocalBookEngine._();
  static final LocalBookEngine I = LocalBookEngine._();

  static const _asset = 'assets/sources/novel-ok.json';
  List<BookSource>? _sources;
  Map<String, BookSource> _byId = const {};
  Map<String, _Score> _score = {};
  Future<int>? _loading;
  int lastSourceCount = 0;

  /// 加载源池。多次调用只解析一次；失败返回 0（不抛，调用方按「端上不可用」处理）。
  Future<int> warmUp() {
    return _loading ??= _load().catchError((_) => 0);
  }

  Future<int> _load() async {
    final raw = await rootBundle.loadString(_asset);
    final list = jsonDecode(raw);
    if (list is! List) return lastSourceCount = 0;
    final out = <BookSource>[];
    for (final e in list) {
      if (e is! Map) continue;
      final s = BookSource.fromJson(Map<String, dynamic>.from(e));
      if (s.url.isEmpty || s.searchUrl.isEmpty || s.ruleToc.isEmpty) continue;
      out.add(s);
    }
    _sources = out;
    _byId = {for (final s in out) s.id: s};
    lastSourceCount = out.length;
    await _loadScore();
    return out.length;
  }

  Future<void> _loadScore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('lg_score');
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      _score = {
        for (final e in m.entries)
          '${e.key}': _Score()
            ..ok = (e.value is Map ? (e.value['ok'] as num?)?.toInt() : 0) ?? 0
            ..fail =
                (e.value is Map ? (e.value['fail'] as num?)?.toInt() : 0) ?? 0
      };
    } catch (_) {}
  }

  Future<void> _bump(String srcId, bool ok) async {
    final s = _score.putIfAbsent(srcId, () => _Score());
    if (ok) {
      s.ok++;
    } else {
      s.fail++;
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          'lg_score',
          jsonEncode({
            for (final e in _score.entries)
              e.key: {'ok': e.value.ok, 'fail': e.value.fail}
          }));
    } catch (_) {}
  }

  /// 候选源的排序：能用的在前，长期失败的凉一边。
  List<BookSource> _ranked({int limit = 12}) {
    final all = _sources ?? const <BookSource>[];
    if (all.isEmpty) return const [];
    final scored = [...all];
    scored.sort((a, b) {
      final ra = (_score[a.id]?.rank ?? 0);
      final rb = (_score[b.id]?.rank ?? 0);
      if (ra != rb) return rb.compareTo(ra);
      final fa = _score[a.id]?.fail ?? 0;
      final fb = _score[b.id]?.fail ?? 0;
      if (fa != fb) return fa.compareTo(fb);
      return a.name.compareTo(b.name);
    });
    return scored.take(limit).toList();
  }

  // ══════════════════════════ 网络 ══════════════════════════

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  // ★2026-11-20：原来这里是 `HttpClient()..badCertificateCallback = (_,__,_) => true`
  //   —— 又是「无条件信任任何证书」。这边抓的是**公网书源站**，中间人可以直接
  //   篡改正文内容，比后端那条更危险。换成全库统一的判据（只信私网/CN=ThirdHub）。
  //   同时改成工厂方法：cascade 里写 lambda 在这个 SDK 的 language version 下
  //   解析不稳（analyze 报 Expected to find ';'），拆开更明确。
  static final HttpClient _client = _mkClient();

  static HttpClient _mkClient() {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 8);
    c.autoUncompress = false;
    c.userAgent = _ua;
    c.badCertificateCallback = ThirdHubHttpOverrides.trustCert;
    return c;
  }

  /// 取页面（跟随一次 JS 跳转墙）。
  static Future<String> _fetch(String url,
      {String referer = '', Map<String, String> extra = const {}}) async {
    final body = await _getOnce(url, referer: referer, extra: extra);
    // 部分站点用「Loading... + location.replace(...)」反爬，不用执行 JS，正则取即可
    // ★raw string 里不能出现 `"`（会直接把字面量截断），原来那行 analyze 报
    //   Expected to find ';' 就是它 —— 跟 lambda 一点关系都没有。改用普通字符串。
    final m = RegExp('location\\.replace\\([\'"]([^\'"]+)[\'"]\\)')
        .firstMatch(body);
    if (m != null && body.length < 2000) {
      final next = Lg.abs(m.group(1)!, url);
      if (next.isNotEmpty && next != url) {
        return _getOnce(next, referer: url, extra: extra);
      }
    }
    return body;
  }

  static Future<String> _getOnce(String url,
      {String referer = '', Map<String, String> extra = const {}}) async {
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    req.headers.set(HttpHeaders.userAgentHeader, _ua);
    if (referer.isNotEmpty) req.headers.set(HttpHeaders.refererHeader, referer);
    extra.forEach(req.headers.set);
    final resp = await req.close();
    final bytes = await resp
        .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 12), onTimeout: () => const <int>[]);
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw HttpException('HTTP ${resp.statusCode}');
    }
    return _decode(bytes, resp.headers.contentType?.charset ?? '');
  }

  /// 编码：源站大量是 GBK。先按响应头，再嗅 meta，最后按 utf8 兜。
  static String _decode(List<int> bytes, String hint) {
    var cs0 = hint.toLowerCase();
    if (cs0.isEmpty) {
      // 只看前 2KB，别把整页当字符串搜
      final head = String.fromCharCodes(
          bytes.take(2048).where((b) => b < 128));
      final m = RegExp(r'charset=["\x27]?([\w-]+)', caseSensitive: false)
          .firstMatch(head);
      if (m != null) cs0 = m.group(1)!.toLowerCase();
    }
    try {
      if (cs0.contains('gb')) return cs.gbk.decode(bytes);
      // ★charset 2.0 只带 gbk/euc_jp/euc_kr/shift_jis/utf，**没有 big5**（原来这行
      //   写了 `cs.big5`，analyze 直接报 undefined_prefixed_name）。繁体站现在基本
      //   都同时给 utf-8，允许 malformed 兜底即可，不会崩、最差个别字变问号。
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  // ══════════════════════════ 搜索 ══════════════════════════

  /// 端上搜索。返回与后端 `/v1/search` 同构的 groups：
  /// `[{ok:true, source:'源名', sourceId:'源地址', books:[{name,author,bookUrl,...}]}]`
  Future<List<Map<String, dynamic>>> search(
    String q, {
    int maxSources = 12,
    int perSource = 20,
    Duration budget = const Duration(seconds: 15),
  }) async {
    if (q.trim().isEmpty) return const [];
    if (await warmUp() == 0) return const [];

    final cands = _ranked(limit: maxSources);
    final groups = <Map<String, dynamic>>[];
    final done = Completer<void>();
    var running = 0;
    var stopped = false;
    Timer? timer;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    timer = Timer(budget, () {
      stopped = true;
      finish();
    });

    for (final s in cands) {
      running++;
      () async {
        try {
          final books = await _searchOne(s, q, per: perSource);
          await _bump(s.id, books.isNotEmpty);
          if (books.isNotEmpty && !stopped) {
            groups.add({
              'ok': true,
              'source': s.name,
              'sourceId': s.id,
              'local': true,
              'books': books,
            });
            // 前 4 个源就有结果时提前收工，别让用户干等冷门源
            if (groups.where((g) => (g['books'] as List).isNotEmpty).length >= 4) {
              stopped = true;
              timer?.cancel();
              finish();
            }
          }
        } catch (_) {
          await _bump(s.id, false);
        } finally {
          running--;
          if (running == 0) finish();
        }
      }();
    }

    await done.future;
    timer.cancel();
    groups.sort((a, b) =>
        ((b['books'] as List).length).compareTo((a['books'] as List).length));
    return groups;
  }

  Future<List<Map<String, dynamic>>> _searchOne(BookSource s, String q,
      {int per = 20}) async {
    final url = Lg.abs(Lg.fill(s.searchUrl, key: q), s.url);
    if (url.isEmpty || !url.startsWith('http')) return const [];
    // POST 型搜索：`url,{...json...}`
    if (s.searchUrl.contains(',{')) return const [];
    final body = await _fetch(url, referer: s.url);
    if (body.trim().isEmpty) return const [];

    final bookListRule = '${s.ruleSearch['bookList'] ?? ''}'.trim();
    if (bookListRule.isEmpty) return const [];

    // JSON 源
    if (bookListRule.startsWith(r'$')) {
      final data = jsonDecode(body);
      final nodes = Lg.jsonPath(data, bookListRule);
      final out = <Map<String, dynamic>>[];
      for (final n in nodes.take(per)) {
        String g(String k) {
          final r = '${s.ruleSearch[k] ?? ''}'.trim();
          if (r.isEmpty) return '';
          if (r.startsWith(r'$')) return Lg.jsonPick(n, r);
          return '';
        }

        final name = g('name');
        final bu = g('bookUrl');
        if (name.isEmpty) continue;
        out.add({
          'name': name,
          'author': g('author'),
          'bookUrl': Lg.abs(bu, s.url),
          'coverUrl': g('coverUrl'),
          'intro': g('intro'),
          'kind': g('kind'),
          'lastChapter': g('lastChapter'),
          'sourceId': s.id,
          'source': s.name,
          'local': true,
        });
      }
      return out;
    }

    final doc = Lg.parse(body);
    final els = Lg.list(doc, bookListRule);
    final out = <Map<String, dynamic>>[];
    for (final el in els.take(per)) {
      String f(String key) {
        final r = '${s.ruleSearch[key] ?? ''}'.trim();
        if (r.isEmpty) return '';
        return Lg.pick(el, r, base: url);
      }

      final name = f('name');
      if (name.isEmpty) continue;
      final bu = f('bookUrl');
      if (bu.isEmpty) continue;
      out.add({
        'name': name,
        'author': f('author'),
        'bookUrl': bu,
        'coverUrl': f('coverUrl'),
        'intro': f('intro'),
        'kind': f('kind'),
        'lastChapter': f('lastChapter'),
        'sourceId': s.id,
        'source': s.name,
        'local': true,
      });
    }
    return out;
  }

  // ══════════════════════════ 目录 ══════════════════════════

  /// 返回 `[{name, url}]`，与后端 `/v1/toc` 的 data 一致。
  Future<List<Map<String, dynamic>>> toc(
      String sourceId, String bookUrl) async {
    await warmUp();
    final s = _byId[sourceId];
    if (s == null) return const [];
    final body = await _fetch(bookUrl, referer: s.url);
    if (body.trim().isEmpty) return const [];
    final listRule = '${s.ruleToc['chapterList'] ?? ''}'.trim();
    if (listRule.isEmpty) return const [];
    final doc = Lg.parse(body);
    final els = Lg.list(doc, listRule);
    final out = <Map<String, dynamic>>[];
    for (final el in els) {
      final n = Lg.pick(el, '${s.ruleToc['chapterName'] ?? 'text'}', base: bookUrl);
      final u = Lg.pick(el, '${s.ruleToc['chapterUrl'] ?? 'href'}', base: bookUrl);
      if (n.isEmpty) continue;
      out.add({'name': n, 'url': u.isEmpty ? bookUrl : u});
    }
    await _bump(sourceId, out.isNotEmpty);
    return out;
  }

  // ══════════════════════════ 正文 ══════════════════════════

  /// 返回 `{content: '...'}`，与后端 `/v1/content` 的 data 一致。
  Future<Map<String, dynamic>> content(String sourceId, String url) async {
    await warmUp();
    final s = _byId[sourceId];
    if (s == null) return const {'content': ''};
    final body = await _fetch(url, referer: s.url);
    if (body.trim().isEmpty) return const {'content': ''};
    final rule = '${s.ruleContent['content'] ?? ''}'.trim();
    if (rule.isEmpty) return const {'content': ''};
    final doc = Lg.parse(body);

    // content 规则通常直接是选择器（不带 @text），先按元素取，再退回字符串
    final els = Lg.list(doc, rule.contains('@') ? rule.split('@').first : rule);
    final buf = StringBuffer();
    if (els.isNotEmpty) {
      for (final e in els) {
        // 章节正文里的 <br> 要换行，否则整章糊成一段
        final html0 = e.innerHtml
            .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
            .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
        final txt = Lg.parse(html0).documentElement?.text ?? e.text;
        buf.writeln(txt.trim());
      }
    }
    var out = buf.toString().trim();
    if (out.isEmpty) {
      out = Lg.pick(doc.documentElement, rule, base: url);
    }
    // 去掉源站塞进来的广告行（这是「读到的正文夹推荐」的老毛病）
    out = _cleanAd(out);
    await _bump(sourceId, out.length > 50);
    return {'content': out};
  }

  static final _adLine = RegExp(
      r'^.*(随机推荐|最新章节|请记住本站|手机用户请|加入书签|百度搜索|本章未完|'
      r'章节错误|求收藏|求推荐票|一秒记住|笔趣阁|首发地址|www\.[\w-]+\.(com|net|org|la|cc)).*$',
      caseSensitive: false);

  static String _cleanAd(String s) {
    if (s.isEmpty) return s;
    final lines = s.split('\n');
    final keep = <String>[];
    for (final l in lines) {
      final t = l.trim();
      if (t.isEmpty) continue;
      if (t.length < 60 && _adLine.hasMatch(t)) continue;
      keep.add(t);
    }
    return keep.join('\n');
  }

  /// 给「源管理」页用：当前源池规模 + 学到的可用度。
  List<Map<String, dynamic>> debugSources({int limit = 50}) {
    final list = _ranked(limit: limit);
    return [
      for (final s in list)
        {
          'name': s.name,
          'url': s.url,
          'group': s.group,
          'ok': _score[s.id]?.ok ?? 0,
          'fail': _score[s.id]?.fail ?? 0,
        }
    ];
  }
}
