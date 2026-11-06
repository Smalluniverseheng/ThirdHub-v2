// 多资料库并行搜索 —— **纯规则层**（任务 #193）。
//
// 为什么单独一层：
//   `EngineDirect` 是 1200 行的静态类，被上百个调用点引用（`EngineDirect.search(...)`）。
//   如果把它整类改成实例对象，所有调用点都要改，而一轮夜间任务既没法真机验收、
//   也没法把所有调用点逐个回归 —— 那是"改一半就上线"的典型配方。
//
//   所以采用**旁路分层**：
//     · 本文件只做无 IO 的判断 —— 谁能并行、结果怎么合并去重；
//     · `EngineDirect` 保留静态门面（调用点零改动），内部多出一层
//       「每台资料库一个 [EngineNode] 实例 + 按实例发请求」的能力。
//   这样"多实例"是真的（请求按实例各自发、各自超时、各自失败），
//   但对外契约不变 —— 单资料库场景的行为与以前逐字节相同。
//
// 本文件不 import Flutter：可以在 `tool/engine_fanout_selfcheck.dart` 里直接跑断言。

/// 一台可用资料库的**实例快照**（多实例层的单元）。
///
/// 与 `ThpDevice` 的区别：这里只留"搜不搜得到内容"相关的字段（地址/能力/端口），
/// 不带广播时间戳之类的发现期状态 —— 并行搜索不该被一次广播刷新影响。
class EngineNode {
  /// 可直接拼 URL 的地址，如 `http://192.168.1.5:1235`
  final String url;

  /// 资料库自报的名字（可能为空）
  final String name;

  /// 能力标签，如 `m:comic` / `stream-search` / `library`
  final List<String> caps;

  /// 端口（老资料库不带 `m:` 标签时按端口兜底判模块）
  final int port;

  const EngineNode({
    required this.url,
    this.name = '',
    this.caps = const [],
    this.port = 0,
  });

  /// 资源库（:9527 那一类）只管源清单，不提供内容 —— 不参与并行搜索。
  bool get isLibrary => caps.contains('library');

  /// caps 里声明的模块（`m:novel` → `novel`）
  List<String> get modules => [
        for (final c in caps)
          if (c.startsWith('m:')) c.substring(2)
      ];

  bool get isValid => url.trim().isNotEmpty;

  /// 这台资料库能不能提供 [type] 模块的内容。
  ///
  /// ★判定顺序很重要（这是「漫画页搜出音乐」那个 bug 的复发点）：
  ///   1) 有 `m:` 标签时**只认标签** —— 一台跑在 1234 端口上的漫画资料库
  ///      仍然只是漫画，绝不能因为端口像小说就把它并进小说搜索；
  ///   2) 完全没有 `m:` 标签（老资料库）才按端口兜底；
  ///   3) `all` 表示"不限类型"，任何内容资料库都可以参与。
  bool supports(String type) {
    if (isLibrary) return false;
    if (type == 'all') return true;
    final m = modules;
    if (m.isNotEmpty) return m.contains(type);
    return kPortModules[port] == type;
  }

  /// 去重键：同一个地址只算一台（大小写/尾斜杠不同也算同一台）。
  String get key => normalizeUrl(url);

  @override
  String toString() => 'EngineNode($url, caps=${caps.join(",")}, port=$port)';
}

/// 老资料库的端口 → 模块 兜底表（与 THP 发现侧的约定一致）。
const Map<int, String> kPortModules = {
  1234: 'novel',
  1235: 'comic',
  1236: 'music',
  9978: 'video',
};

/// 四个内容模块（资源库不算）。
const List<String> kContentModules = ['novel', 'comic', 'music', 'video'];

/// 地址归一化：去掉首尾空白与**结尾的斜杠**，scheme 与 host 转小写。
///
/// 为什么不整体 `toLowerCase()`：路径是区分大小写的（`/thp/m/Comic/…` 不是同一路径），
/// 而且 IPv6 字面量里也不该被动。只把 scheme+host[:port] 这一段压平。
String normalizeUrl(String u) {
  var s = u.trim();
  if (s.isEmpty) return '';
  s = s.replaceAll(RegExp(r'/+$'), '');
  final i = s.indexOf('://');
  if (i <= 0) return s.toLowerCase();
  final scheme = s.substring(0, i).toLowerCase();
  final rest = s.substring(i + 3);
  final slash = rest.indexOf('/');
  final authority = (slash < 0 ? rest : rest.substring(0, slash)).toLowerCase();
  final path = slash < 0 ? '' : rest.substring(slash);
  return '$scheme://$authority$path';
}

/// 从发现到的资料库里挑出「能一起搜 [type]」的实例。
///
/// 规则：
///   · 只留内容提供方（剔掉资源库）；
///   · 按 [EngineNode.supports] 过滤模块；
///   · 同地址只留一台（先到的优先，保持发现顺序 → 结果顺序稳定可复现）；
///   · 空地址直接丢弃（拼不出 URL 的实例只会制造无谓失败）。
List<EngineNode> pickEngines(String type, List<EngineNode> all) {
  final out = <EngineNode>[];
  final seen = <String>{};
  for (final n in all) {
    if (!n.isValid || !n.supports(type)) continue;
    final k = n.key;
    if (k.isEmpty || !seen.add(k)) continue;
    out.add(n);
  }
  return out;
}

/// 文本归一化：只保留字母/数字/CJK/假名/谚文，全角转半角，ASCII 转小写。
///
/// 为什么这么狠：同一本书在两个站上的标题常差在空格、书名号、《·》、副标题分隔符上
/// （`斗破苍穹` vs `斗破苍穹（全本）` 是不同条目，但 `斗破 苍穹` 与 `斗破苍穹` 不是）。
/// 去重只要"几乎一样就算一样"，**不能**把"跨引擎同标题不同作者"并掉 —— 那由作者字段把关。
String normalizeText(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    var c = r;
    // 全角 ASCII（！-～）与全角空格先折成半角
    if (c == 0x3000) continue;
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    final isDigit = c >= 0x30 && c <= 0x39;
    final isUpper = c >= 0x41 && c <= 0x5A;
    final isLower = c >= 0x61 && c <= 0x7A;
    final isCjk = (c >= 0x4E00 && c <= 0x9FFF) ||
        (c >= 0x3400 && c <= 0x4DBF) ||
        (c >= 0x3040 && c <= 0x30FF) ||
        (c >= 0xAC00 && c <= 0xD7AF);
    if (isDigit || isCjk) {
      b.writeCharCode(c);
    } else if (isUpper || isLower) {
      b.writeCharCode(c | 0x20);
    }
    // 其余（空白/标点/emoji/控制符）一律丢掉
  }
  return b.toString();
}

/// 标题的原始字段名在不同资料库里不统一，取第一个非空的。
String _firstOf(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    final s = '$v'.trim();
    if (s.isNotEmpty) return s;
  }
  return '';
}

/// 一条结果的去重键：`标题|作者`（都归一化）。标题为空时返回空串 → 不去重。
String dedupeKey(Map<String, dynamic> item) {
  final t = normalizeText(_firstOf(item, const ['title', 'name']));
  if (t.isEmpty) return '';
  final a = normalizeText(_firstOf(item, const ['author', 'artist', 'writer']));
  return '$t|$a';
}

/// 一台资料库这一页的结果（或它失败的原因）。
///
/// 失败不抛给上层：**多台里挂一台不该让整个搜索变红** —— 用户要的是结果，
/// 不是"其中一台超时了"。全挂才算失败（`FanoutMerged.okCount == 0`）。
class FanoutPage {
  final String url;
  final List<Map<String, dynamic>> items;
  final bool ok;
  final String error;
  final int total;
  final bool hasMore;
  final bool truncated;

  const FanoutPage({
    required this.url,
    this.items = const [],
    this.ok = true,
    this.error = '',
    this.total = 0,
    this.hasMore = false,
    this.truncated = false,
  });

  factory FanoutPage.failed(String url, Object error) =>
      FanoutPage(url: url, ok: false, error: '$error');
}

/// 合并结果。
class FanoutMerged {
  final List<Map<String, dynamic>> items;

  /// 被判为重复而丢弃的条数（诊断/日志用，界面不必显示）
  final int dropped;

  /// 失败的资料库（地址 → 原因）
  final Map<String, String> failures;

  final int total;
  final bool hasMore;
  final bool truncated;

  /// 这次真正取到结果的资料库台数（0 表示全挂）
  final int okCount;

  const FanoutMerged({
    this.items = const [],
    this.dropped = 0,
    this.failures = const {},
    this.total = 0,
    this.hasMore = false,
    this.truncated = false,
    this.okCount = 0,
  });

  /// 全挂时给调用方抛的错误文案（带上第一台的真实原因，别只说"都失败了"）。
  String get errorText => failures.isEmpty
      ? '没有可用的资料库'
      : failures.values.first;
}

/// 按标题/作者去重合并多台资料库的结果。
///
/// 顺序：**按 [pages] 的顺序**（也就是并行目标列表的顺序，主连接在最前）逐条铺，
/// 同一本书保留先出现的那条。这样单台资料库的结果相对顺序永不改变 —— 用户看到
/// 的列表不会因为"这次哪台先返回"而跳来跳去（并行返回顺序是不确定的，
/// 所以合并必须按**输入顺序**而不是完成顺序，这一点很容易写错）。
FanoutMerged mergeFanout(List<FanoutPage> pages) {
  final items = <Map<String, dynamic>>[];
  final byFull = <String, int>{}; // 标题|作者 → 首次出现下标
  final byTitle = <String, Set<String>>{}; // 标题 → 见过的作者集合（含空串）
  var dropped = 0;
  var total = 0;
  var hasMore = false;
  var truncated = false;
  var okCount = 0;
  final failures = <String, String>{};

  for (final p in pages) {
    if (!p.ok) {
      if (p.url.isNotEmpty) failures[p.url] = p.error;
      continue;
    }
    okCount++;
    total += p.total > 0 ? p.total : p.items.length;
    hasMore = hasMore || p.hasMore;
    truncated = truncated || p.truncated;
    for (final it in p.items) {
      final t = normalizeText(_firstOf(it, const ['title', 'name']));
      if (t.isEmpty) {
        // 没标题就无从判重：宁可多一条，也别把不同的东西并掉
        items.add(it);
        continue;
      }
      final a = normalizeText(_firstOf(it, const ['author', 'artist', 'writer']));
      final authors = byTitle.putIfAbsent(t, () => <String>{});
      final bool dup;
      if (a.isEmpty) {
        // 这条没作者：只要同标题已经出现过（不管那次有没有作者）就算重复
        dup = authors.isNotEmpty;
      } else {
        // 这条有作者：同「标题+作者」重复，或同标题此前只有一条且那条没有作者
        dup = byFull.containsKey('$t|$a') ||
            (authors.length == 1 && authors.first.isEmpty);
      }
      if (dup) {
        dropped++;
        continue;
      }
      byFull['$t|$a'] = items.length;
      authors.add(a);
      items.add(it);
    }
  }
  if (total < items.length) total = items.length;
  total -= dropped;
  if (total < items.length) total = items.length;

  final m = FanoutMerged(
    items: items,
    dropped: dropped,
    failures: failures,
    total: total,
    hasMore: hasMore,
    truncated: truncated,
    okCount: okCount,
  );
  return m;
}
