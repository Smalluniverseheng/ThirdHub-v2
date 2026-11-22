// 声明式内容源（Declarative Source Spec）。
//
// ── 为什么要做这一层 ───────────────────────────────────────────
// 4.81.86 之前，每个源都是 Dart 里的 `static const`，意味着：
//   · 加一个源 = 改代码 + 重新发版；
//   · 源清单只能随安装包走，用户没法自己加；
//   · 合规源与「用户自担责任」的源混在同一份二进制里。
//
// 这一层把源定义变成**纯数据**（JSON）。于是同一份 App 可以：
//   ① 内置少量合规源（离线保底，编译期常量，可静态审计）；
//   ② 从管理员账号同步一包扩展源（不入安装包，登录后自动拉）；
//   ③ 让用户自己从文件/粘贴板导入源（不合规也能端上跑，本地生效）。
//
// ── 安全边界（重要）────────────────────────────────────────────
// 源包是**纯声明**，不含任何可执行代码：
//   · 只有「URL 模板 + 取值路径」，没有 JS/Dart 脚本，没有 eval；
//   · 协议只允许 http/https，禁止 file/javascript/data；
//   · 取值路径只能读，不能写，不能访问本地文件；
//   · 单个源最多 2 个动作（search / detail），不做递归爬站。
// 这三条决定了：导入一个恶意源包，最坏结果是「它自己拿不到数据」，
// 不会变成「App 变成了任意代码执行器」。
//
// ── 与 legado 那类源的区别 ─────────────────────────────────────
// legado 的源是 JS 脚本，表达力强但等于把执行权交给源作者。
// 这里刻意做窄：只要能描述「发一个请求、按路径取出字段」的源。
// 表达力换安全与可审计 —— App 端的定位是「消费」，抓取的重活留给桌面容器。
import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import 'free_http.dart' show stripHtml;
import 'free_models.dart';

/// 源包规格版本。改了不兼容的结构就 +1，老包会被拒绝而不是跑出诡异结果。
const int kFreeSpecSchema = 1;

/// 取数方式。
enum SpecFetch {
  /// 标准 JSON 接口：按点路径取值。
  json,

  /// RSS / Atom：按标签取值。
  rss,

  /// HTML 页面：按 CSS 选择器取值。
  html;

  static SpecFetch parse(String? s) => switch ((s ?? 'json').toLowerCase()) {
        'rss' => SpecFetch.rss,
        'atom' => SpecFetch.rss,
        'html' => SpecFetch.html,
        _ => SpecFetch.json,
      };
}

/// 一个字段怎么取。
///
/// [path] 的语法按 [SpecFetch] 分派：
///   · json：`a.b.c` 嵌套、`a.b[0]` 下标、`a[].b` 遍历拼成 `、` 分隔串
///   · html：`sel` 取文本、`sel@attr` 取属性、`sel@html` 取内层 HTML
///   · rss ：`title` / `itunes:duration` 取标签文本
///
/// 三条语法都支持**候选链**：写成 `a.path||b.path||c.path`，按顺序取第一个
/// 非空的值。真实接口同一个字段常有多种落点（MangaDex 封面在 relationships
/// 里索引不定、PeerTube 老视频用 files 新视频用 streamingPlaylists），
/// 有这条就不用把一份源拆成两个入口。
///
/// [abs] = true 时，取到的是相对地址，会用源的 [FreeSourceSpec.base] 补全。
/// [strip] = true 时剥掉 HTML 标签（简介字段常见）。
class FieldSpec {
  final String path;
  final bool abs;
  final bool strip;
  final String fallback;

  /// 模板模式：用 `{字段名}` 拼字符串，而不是从响应里取值。
  ///
  /// ★ 为什么必须有它：大量源的播放地址不是响应里的某个字段，
  ///   而是「拿 id 拼出来」的，例如网易云外链
  ///   `https://music.163.com/song/media/outer/url?id={id}.mp3`。
  ///   没有模板能力，这类源一条都接不了。
  ///
  /// 模板里的 `{x}` 取自**同一条结果已解析出的字段**（title/cover/id/…），
  /// 取不到就替换成空串 —— 不报错，让源作者自己看结果对不对。
  final String tpl;

  const FieldSpec(this.path,
      {this.abs = false,
      this.strip = false,
      this.fallback = '',
      this.tpl = ''});

  bool get isTemplate => tpl.trim().isNotEmpty;

  static FieldSpec? parse(Object? v) {
    if (v == null) return null;
    if (v is String) {
      if (v.trim().isEmpty) return null;
      return FieldSpec(v.trim());
    }
    if (v is Map) {
      final tpl = '${v['tpl'] ?? v['format'] ?? ''}'.trim();
      final p =
          '${v['path'] ?? v['json'] ?? v['html'] ?? v['rss'] ?? ''}'.trim();
      if (p.isEmpty && tpl.isEmpty) return null;
      return FieldSpec(
        p,
        abs: v['abs'] == true,
        strip: v['strip'] == true,
        fallback: '${v['fallback'] ?? v['default'] ?? ''}',
        tpl: tpl,
      );
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        if (path.isNotEmpty) 'path': path,
        if (tpl.isNotEmpty) 'tpl': tpl,
        if (abs) 'abs': true,
        if (strip) 'strip': true,
        if (fallback.isNotEmpty) 'fallback': fallback,
      };
}

/// 一个动作：发一次请求，把结果映射成条目。不做事后二次请求。
class FreeAction {
  /// GET / POST。
  final String method;

  /// 请求路径（相对 [FreeSourceSpec.base]，或完整 URL）。
  /// 支持占位符：`{q}` 搜索词、`{page}` 页码、`{id}` 条目 id。
  final String path;

  /// 附加查询参数，值同样支持占位符。
  final Map<String, String> query;

  /// 附加请求头（如部分站要 Referer / Accept）。
  final Map<String, String> headers;

  /// POST 时的请求体模板（JSON 字符串），支持占位符。为空则不带 body。
  final String body;

  final SpecFetch fetch;

  /// 结果数组的位置（json 用点路径，html 用 CSS 选择器，rss 留空）。
  final String list;

  /// 字段映射。key ∈ id/title/subtitle/cover/desc/playUrl/drill。
  final Map<String, FieldSpec> map;

  /// 结果是否可下钻（如漫画的章节、播客的单集）。
  final bool drill;

  /// 单页最多取几条（防止某个源一次吐一万条把内存打爆）。
  final int limit;

  const FreeAction({
    required this.path,
    this.method = 'GET',
    this.query = const {},
    this.headers = const {},
    this.body = '',
    this.fetch = SpecFetch.json,
    this.list = '',
    this.map = const {},
    this.drill = false,
    this.limit = 60,
  });

  static FreeAction? parse(Object? v) {
    if (v is! Map) return null;
    final path = '${v['path'] ?? ''}'.trim();
    if (path.isEmpty) return null;

    Map<String, String> strMap(Object? o) {
      if (o is! Map) return const {};
      return {
        for (final e in o.entries)
          if (e.value != null) '${e.key}': '${e.value}'
      };
    }

    final rawMap = v['map'];
    final m = <String, FieldSpec>{};
    if (rawMap is Map) {
      for (final e in rawMap.entries) {
        final f = FieldSpec.parse(e.value);
        if (f != null) m['${e.key}'] = f;
      }
    }

    final lim = v['limit'];
    return FreeAction(
      path: path,
      method: '${v['method'] ?? 'GET'}'.toUpperCase(),
      query: strMap(v['query']),
      headers: strMap(v['headers']),
      body: '${v['body'] ?? ''}',
      fetch: SpecFetch.parse('${v['fetch'] ?? v['type'] ?? 'json'}'),
      list: '${v['list'] ?? ''}'.trim(),
      map: m,
      drill: v['drill'] == true || m.containsKey('drill'),
      limit: lim is num ? lim.toInt().clamp(1, 200) : 60,
    );
  }

  Map<String, dynamic> toJson() => {
        'method': method,
        'path': path,
        if (query.isNotEmpty) 'query': query,
        if (headers.isNotEmpty) 'headers': headers,
        if (body.isNotEmpty) 'body': body,
        if (fetch != SpecFetch.json) 'fetch': fetch.name,
        if (list.isNotEmpty) 'list': list,
        if (map.isNotEmpty)
          'map': {for (final e in map.entries) e.key: e.value.toJson()},
        if (drill) 'drill': true,
        'limit': limit,
      };
}

/// 一份完整的源定义。可 JSON 序列化 —— 这是「源不入包」的前提。
class FreeSourceSpec {
  final String id;
  final String name;
  final String note;
  final FreeKind kind;
  final LicenseKind license;
  final String attribution;
  final String termsUrl;

  /// 站点根地址。相对路径与 [FieldSpec.abs] 都以它为基准。
  final String base;

  /// 探活地址（相对 base 或完整 URL）。空 = 不探测。
  final String ping;

  /// 搜索动作。
  final FreeAction? search;

  /// 下钻动作（取子列表 / 单集）。空 = 不可下钻。
  final FreeAction? detail;

  /// 来源：内置 / 管理员同步 / 用户导入。UI 据此区分口径，也是合规审计的依据。
  final SourceOrigin origin;

  /// 人类可读的「这源从哪来」，例如「我的 NAS」「某论坛分享」。
  final String originNote;

  const FreeSourceSpec({
    required this.id,
    required this.name,
    required this.note,
    required this.kind,
    required this.license,
    this.attribution = '',
    this.termsUrl = '',
    this.base = '',
    this.ping = '',
    this.search,
    this.detail,
    this.origin = SourceOrigin.user,
    this.originNote = '',
  });

  /// 转成 UI 用的 [FreeSource]（探活地址按 base 补全）。
  FreeSource get asSource => FreeSource(
        id: id,
        name: name,
        note: note,
        kind: kind,
        license: license,
        attribution: attribution,
        termsUrl: termsUrl,
        pingUrl: resolve(ping),
        origin: origin,
        originNote: originNote,
      );

  /// 相对地址补全。已是完整 URL 就原样返回。
  String resolve(String u) {
    final t = u.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    if (base.isEmpty) return t;
    if (t.startsWith('//')) return 'https:$t';
    if (t.startsWith('/')) return '$base$t';
    return '$base/$t';
  }

  /// 校验一份定义是否可用。返回问题列表，空 = 通过。
  ///
  /// 这里刻意宽松（只挡真正跑不起来或危险的），因为源包是用户的东西；
  /// 但**协议白名单**是硬约束，不能松。
  List<String> validate() {
    final errs = <String>[];
    if (id.trim().isEmpty) errs.add('缺少 id');
    if (!RegExp(r'^[a-z0-9_]{2,32}$').hasMatch(id)) {
      errs.add('id 只能用 2~32 位小写字母/数字/下划线');
    }
    if (name.trim().isEmpty) errs.add('缺少 name');
    final b = base.trim();
    if (b.isNotEmpty && !_safeUrl(b)) errs.add('base 只允许 http/https');
    if (search == null) errs.add('缺少 search 动作');
    for (final a in [search, detail]) {
      if (a == null) continue;
      if (!_safeUrl(resolve(a.path))) {
        errs.add('动作地址只允许 http/https：${a.path}');
      }
      for (final h in a.headers.entries) {
        // 请求头是注入面：禁止 CRLF 与改 Host。
        if (h.key.toLowerCase() == 'host') errs.add('请求头不允许指定 Host');
        if (h.value.contains('\n') || h.value.contains('\r')) {
          errs.add('请求头存在非法换行');
        }
      }
    }
    if (detail != null && search == null) errs.add('有 detail 却没有 search');
    return errs;
  }

  static bool _safeUrl(String u) {
    final s = u.trim().toLowerCase();
    if (s.isEmpty) return true; // 交给 resolve 后的检查
    return s.startsWith('http://') || s.startsWith('https://');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'note': note,
        'kind': kind.name,
        'license': license.name,
        if (attribution.isNotEmpty) 'attribution': attribution,
        if (termsUrl.isNotEmpty) 'termsUrl': termsUrl,
        if (base.isNotEmpty) 'base': base,
        if (ping.isNotEmpty) 'ping': ping,
        if (search != null) 'search': search!.toJson(),
        if (detail != null) 'detail': detail!.toJson(),
        'origin': origin.name,
        if (originNote.isNotEmpty) 'originNote': originNote,
      };

  /// 解析失败返回 null（不抛）—— 一个坏源不该让整包导入失败。
  static FreeSourceSpec? parse(Object? v, {SourceOrigin? origin}) {
    if (v is! Map) return null;
    final id = '${v['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;

    FreeKind? kind;
    final k = '${v['kind'] ?? ''}'.toLowerCase();
    for (final e in FreeKind.values) {
      if (e.name == k) kind = e;
    }
    if (kind == null) return null;

    LicenseKind? lic;
    final l = '${v['license'] ?? ''}'.toLowerCase();
    for (final e in LicenseKind.values) {
      if (e.name.toLowerCase() == l) lic = e;
    }
    // 未声明授权 → 一律按最严处理，绝不给默认放行。
    lic ??= LicenseKind.thirdPartyRule;

    final det = FreeAction.parse(v['detail']);
    return FreeSourceSpec(
      id: id,
      name: '${v['name'] ?? id}'.trim(),
      note: '${v['note'] ?? ''}'.trim(),
      kind: kind,
      license: lic,
      attribution: '${v['attribution'] ?? ''}'.trim(),
      termsUrl: '${v['termsUrl'] ?? ''}'.trim(),
      base: '${v['base'] ?? ''}'.trim(),
      ping: '${v['ping'] ?? ''}'.trim(),
      search: FreeAction.parse(v['search']),
      detail: det,
      origin: origin ?? _originOf('${v['origin'] ?? ''}'),
      originNote: '${v['originNote'] ?? ''}'.trim(),
    );
  }

  static SourceOrigin _originOf(String s) => switch (s.toLowerCase()) {
        'builtin' => SourceOrigin.builtin,
        'admin' => SourceOrigin.admin,
        _ => SourceOrigin.user,
      };
}

// ══════════════════════════════════════════════════════════════
// 取值引擎
// ══════════════════════════════════════════════════════════════

/// 模板插值：`{q}` `{page}` `{id}`。未知占位符原样保留（源作者自己能看出来）。
String fillTemplate(String tpl, Map<String, String> vars) {
  var s = tpl;
  for (final e in vars.entries) {
    s = s.replaceAll('{${e.key}}', Uri.encodeQueryComponent(e.value));
  }
  return s;
}

/// 按点路径从 JSON 里取值。
///
/// 支持：
///   `a.b.c`      嵌套
///   `a.b[0]`     下标（也可写 `a.b.0`）
///   `a[].b`      遍历数组，把每个元素的 `b` 拼成 `、` 分隔串
///   `$`          根节点
///
/// 按**候选链**取一个字段：`a.x||b.y||c.z`，按顺序返回第一个非空值。
///
/// 为什么要有这一层，而不是只有一个 path：
/// 真实接口里同一个语义字段的落点会随记录而变 ——
///   · MangaDex 的封面文件名在 `relationships` 里，但 cover_art 的索引
///     受 author / artist 有无影响（0/1/2 都可能），固定下标必然漏；
///   · PeerTube 老视频的播放地址在顶层 `files`，新视频在
///     `streamingPlaylists[0].files`，同一套 API 两种形态。
/// 没有候选链，就只能把同一份源拆成两个入口，用户看到重复项。
///
/// 三条 fetch 语法都走这里，所以 `||` 在 json / html / rss 上通用。
String pickField(
  Object? entry,
  String src,
  String path, {
  SpecFetch fetch = SpecFetch.json,
}) {
  for (final cand in path.split('||')) {
    final p = cand.trim();
    if (p.isEmpty) continue;
    final v = switch (fetch) {
      SpecFetch.html => pickHtml(src, p),
      SpecFetch.rss => pickRss(src, p),
      SpecFetch.json => pickJson(entry, p),
    }.trim();
    if (v.isNotEmpty) return v;
  }
  return '';
}

/// 取不到返回 ''（不抛）—— 源站字段缺一半是常态，缺字段不该让整条结果消失。
String pickJson(Object? node, String path) {
  final p = path.trim();
  if (p.isEmpty || p == r'$') return _flat(node);

  // 先处理 `[]` 展开：路径里出现 `[]` 就分左右两段递归。
  final exp = p.indexOf('[]');
  if (exp >= 0) {
    final left = p.substring(0, exp);
    final right = p.substring(exp + 2).replaceFirst(RegExp(r'^\.'), '');
    final arr = _walk(node, left);
    if (arr is List) {
      final parts = <String>[];
      for (final e in arr) {
        final v = pickJson(e, right);
        if (v.trim().isNotEmpty) parts.add(v.trim());
      }
      return parts.join('、');
    }
    if (arr == null) return '';
    return pickJson(arr, right);
  }

  final v = _walk(node, p);
  return v == null ? '' : _flat(v);
}

Object? _walk(Object? node, String path) {
  if (path.trim().isEmpty) return node;
  Object? cur = node;
  for (final rawSeg in path.split('.')) {
    if (cur == null) return null;
    var seg = rawSeg.trim();
    if (seg.isEmpty) continue;

    // 段尾的下标：`items[0]`
    int? idx;
    final b = seg.indexOf('[');
    if (b > 0 && seg.endsWith(']')) {
      idx = int.tryParse(seg.substring(b + 1, seg.length - 1));
      seg = seg.substring(0, b);
    }

    if (seg.isNotEmpty) {
      if (cur is Map) {
        cur = cur[seg];
      } else if (cur is List) {
        // `a.b.0` 这种写法：纯数字段当作下标。
        // （文档里承诺过 `[0]` 与 `.0` 等价，这里必须真的兑现，
        //   否则写源的人两种写法只有一种能跑，排查起来很费劲。）
        final asIndex = int.tryParse(seg);
        if (asIndex != null) {
          cur = (asIndex >= 0 && asIndex < cur.length) ? cur[asIndex] : null;
        } else {
          // 数组上直接取字段 → 逐个取
          final got = <Object?>[];
          for (final e in cur) {
            if (e is Map && e.containsKey(seg)) got.add(e[seg]);
          }
          cur = got.isEmpty ? null : got;
        }
      } else {
        return null;
      }
    }

    if (idx != null) {
      if (cur is List) {
        cur = (idx >= 0 && idx < cur.length) ? cur[idx] : null;
      } else {
        return null;
      }
    }
  }
  return cur;
}

/// 把任意节点压成字符串。数组默认 `、` 连接，Map 取 `name`/`text`/`title` 兜底。
String _flat(Object? v) {
  if (v == null) return '';
  if (v is String) return v.trim();
  if (v is num || v is bool) return '$v';
  if (v is List) {
    return v.map(_flat).where((e) => e.isNotEmpty).join('、');
  }
  if (v is Map) {
    for (final k in const ['name', 'text', 'title', 'value', 'label', 'zh']) {
      if (v.containsKey(k)) {
        final s = _flat(v[k]);
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }
  return '$v';
}

/// 按 CSS 选择器从 HTML 取值。
///
/// 表达式：`sel` = 文本、`sel@attr` = 属性、`sel@html` = 内层 HTML。
/// 取不到返回 ''。
String pickHtml(String doc, String expr) {
  final e = expr.trim();
  if (e.isEmpty) return '';
  var sel = e;
  var attr = '';
  final at = e.lastIndexOf('@');
  if (at > 0) {
    sel = e.substring(0, at).trim();
    attr = e.substring(at + 1).trim().toLowerCase();
  }
  if (sel.isEmpty) return '';
  try {
    final d = html_parser.parse(doc);
    final el = d.querySelector(sel);
    if (el == null) return '';
    if (attr.isEmpty || attr == 'text') return (el.text).trim();
    if (attr == 'html' || attr == 'innerhtml') return el.innerHtml.trim();
    return (el.attributes[attr] ?? '').trim();
  } catch (_) {
    // 选择器写错不该炸整页。
    return '';
  }
}

/// RSS 标签取值（复用播客那套正则思路，避免再引 xml 包）。
///
/// 表达式两种形态：
///   `title`            → 取标签文本（CDATA 会剥掉）
///   `enclosure@url`    → 取标签的属性值
///
/// ★ `@属性` 这一档是必须的：播客/音频 RSS 的**播放地址在
///   `<enclosure url="...">` 里**，没有它就没有一条 RSS 源能播。
String pickRss(String item, String tag) {
  final t = tag.trim();
  if (t.isEmpty) return '';

  var name = t;
  var attr = '';
  final at = t.lastIndexOf('@');
  if (at > 0) {
    name = t.substring(0, at).trim();
    attr = t.substring(at + 1).trim();
  }
  if (name.isEmpty) return '';

  final open = RegExp('<$name\\b[^>]*>', caseSensitive: false).firstMatch(item);
  if (open == null) return '';

  if (attr.isNotEmpty) {
    // 属性从**开标签**上取：enclosure 是自闭合的，没有内层文本。
    final a = RegExp('\\b' + RegExp.escape(attr) + '\\s*=\\s*"([^"]*)"',
            caseSensitive: false)
        .firstMatch(open.group(0)!);
    final a2 = a ??
        RegExp("\\b" + RegExp.escape(attr) + "\\s*=\\s*'([^']*)'",
                caseSensitive: false)
            .firstMatch(open.group(0)!);
    return _unescapeAttr((a2?.group(1) ?? '').trim());
  }

  final m = RegExp('<$name\\b[^>]*>([\\s\\S]*?)</$name>',
          caseSensitive: false)
      .firstMatch(item);
  if (m == null) return '';
  var s = m.group(1) ?? '';
  final cd = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(s);
  if (cd != null) s = cd.group(1)!;
  return stripHtml(s).trim();
}

/// 把响应体按 [fetch] 拆成「一条一条的原始片段」。
List<Object> splitEntries(String body, FreeAction a) {
  switch (a.fetch) {
    case SpecFetch.html:
      try {
        final doc = html_parser.parse(body);
        final nodes = doc.querySelectorAll(a.list.isEmpty ? 'body' : a.list);
        return [for (final n in nodes) n.outerHtml];
      } catch (_) {
        return const [];
      }
    case SpecFetch.rss:
      return [
        for (final m in RegExp(r'<item[\s>][\s\S]*?</item>', caseSensitive: false)
            .allMatches(body))
          m.group(0) ?? ''
      ];
    case SpecFetch.json:
      dynamic d;
      try {
        d = jsonDecode(body);
      } catch (_) {
        return const [];
      }
      final listPath = a.list.trim();
      final node = listPath.isEmpty ? d : pickJsonNode(d, listPath);
      if (node is List) return List<Object>.from(node);
      if (node is Map) return <Object>[node];
      return const <Object>[];
  }
}

/// 与 [pickJson] 相同的路径语法，但返回**原始节点**而不是字符串。
///
/// 需要它是因为「结果数组」必须拿到 List 本身，
/// 而 [pickJson] 会把数组压成 `、` 拼接的字符串。
Object? pickJsonNode(Object? node, String path) {
  final p = path.trim();
  if (p.isEmpty || p == r'$') return node;
  return _walk(node, p);
}

/// XML/HTML 实体反转义。
///
/// ★ 只做「属性里会出现的几个」：RSS 的 enclosure 地址常见 `&amp;`
///   （喜马拉雅就是这样），不还原的话播放地址会带着 `&amp;` 直接 404。
String _unescapeAttr(String s) {
  if (!s.contains('&')) return s;
  return s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
}
