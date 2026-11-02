// ThirdHub 同步契约（纯逻辑：**零 import、零 Flutter、零 IO**）
//
// 为什么要单独一个文件：
//   `tool/sync_contract_selfcheck.dart` 要在**本机**跑（本机 PUB_CACHE 是空的，
//   import 了 flutter 就必然解析失败）。把合并规则与字段映射抽成纯函数，
//   闸门才能真的执行它们，而不是只 grep 源码。
//
// 口径来源（**唯一真源**）：网页端
//   · js/engine/sync-service.js  → pullAll 的合并规则 / 删除墓碑 / MAP 表映射
//   · js/engine/content-service.js → 行形状（shelf / history / favorites / progress）
//   · js/modules/community.js      → community_posts / community_comments 的列
// 两端读写**同一批表、同一套 id、同一套字段名**，这是「手机 ↔ 网页」数据互通的全部依据。
// 改这里必须同步改网页端，否则就会出现「A 端删了、B 端又拉回来」这类幽灵问题。
//
// 2026-11-03 现状（核实结论，别再猜）：
//   th_bookshelf / th_reading_progress / th_history / th_favorites 四张表
//   在 App 里**声明了但零调用点**（Cloud.shelfUp()/progressUp() 全项目没人调），
//   云端 th_history 里躺着 24 行 2026-10-24 的数据，App 一行都看不到。

/// App 侧书架/历史的分类键（`shelf_<kind>` / `history_<kind>`）。
const List<String> kAppKinds = <String>['novel', 'comic', 'video', 'music'];

/// 服务端行 id 分隔符。网页端 `content-service.js`：
/// `const id = item.sourceId + ':' + item.bookUrl;`
const String kIdSep = ':';

/// 本机 sourceId 缺失时的占位（老数据 / 手工导入的书没有 sourceId）。
/// 不能拼成 `:bookUrl` —— 云端 id 会和网页端的 `src-xxx:bookUrl` 撞不上，
/// 也会让 `progress_<bookUrl>` 的键名解析错位。
const String kLocalSrc = 'local';

/// 一行同步数据（id + 载荷 + 时间戳）。
///
/// `ts` 一律是 **epoch 毫秒**：云端 `updated_at` 是 ISO 字符串、本机 `_at` 是
/// `yyyy-MM-dd HH:mm` 文本、`lastAt`/`addedAt` 是毫秒 —— 混着比大小必然出错，
/// 所以解析只在这一处做（[tsOf] / [tsOfIso]），别在业务里各写一套。
class SyncRow {
  final String id;
  final Map<String, dynamic> data;
  final int ts;
  const SyncRow(this.id, this.data, this.ts);

  @override
  String toString() => 'SyncRow($id, ts=$ts)';
}

/// 一次合并要做的四件事（IO 层只负责按这份清单执行）。
class MergePlan {
  /// 云端胜 / 云端独有 → 写进本机
  final List<SyncRow> toLocal = <SyncRow>[];

  /// 本机胜 / 本机独有 → 推到云端
  final List<SyncRow> toCloud = <SyncRow>[];

  /// 墓碑命中 → 删云端（删成功才清墓碑，见 IO 层）
  final List<String> deleteCloud = <String>[];

  /// 墓碑命中 / 云端已无 → 清本机（防"下次登录又复活"）
  final List<String> dropLocal = <String>[];

  bool get empty =>
      toLocal.isEmpty && toCloud.isEmpty && deleteCloud.isEmpty && dropLocal.isEmpty;

  @override
  String toString() =>
      'MergePlan(local:${toLocal.length} cloud:${toCloud.length} '
      'delCloud:${deleteCloud.length} dropLocal:${dropLocal.length})';
}

/// 取一行数据的时间戳（epoch 毫秒，取不到返回 0）。
///
/// 顺序即优先级：先看网页端的 `lastAt`/`addedAt`（历史/书架各自的写入时刻），
/// 再看通用 `ts`/`_ts`，最后 `_at`（App 历史上写的 `yyyy-MM-dd HH:mm` 文本）。
/// **不要**把 `updatedAt` 放前面：`th_settings` 的 `updatedAt` 是设置行的，
/// 不是阅读行的。
int tsOf(Map<String, dynamic>? j) {
  if (j == null) return 0;
  for (final String k in const <String>['lastAt', 'addedAt', 'ts', '_ts', 'at', '_at']) {
    final Object? v = j[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String && v.isNotEmpty) {
      final int? n = int.tryParse(v);
      if (n != null) return n;
      final DateTime? d = DateTime.tryParse(v);
      if (d != null) return d.millisecondsSinceEpoch;
    }
  }
  return 0;
}

/// 云端的 `updated_at`（ISO 8601）→ epoch 毫秒。解析不出来算 0（= 最旧）。
int tsOfIso(String? iso) {
  if (iso == null || iso.isEmpty) return 0;
  final DateTime? d = DateTime.tryParse(iso);
  return d == null ? 0 : d.millisecondsSinceEpoch;
}

/// 服务端行 id：`sourceId:bookUrl`（与网页端逐字一致）。
String rowIdOf(String sourceId, String bookUrl) {
  final String s = sourceId.trim();
  final String b = bookUrl.trim();
  if (b.isEmpty) return s.isEmpty ? '' : s;
  return '${s.isEmpty ? kLocalSrc : s}$kIdSep$b';
}

/// 把服务端行 id 拆回 (sourceId, bookUrl)。
/// 只按**第一个**分隔符切 —— url 里满是 `://`，按后面切会把 bookUrl 切碎。
(String, String) splitRowId(String id) {
  final int i = id.indexOf(kIdSep);
  if (i <= 0) return (id.isEmpty ? '' : kLocalSrc, id);
  return (id.substring(0, i), id.substring(i + 1));
}

/// 云端 `type` → App 的 kind 键。
/// 网页端把听书类内容记成 `audio`，App 侧统一归到 `music` 架；
/// 认不出的类型不丢（归 novel），否则用户会看到"云端有、本机没有"的诡异差额。
String kindOfType(String type) {
  switch (type) {
    case 'novel':
    case 'comic':
    case 'video':
    case 'music':
      return type;
    case 'audio':
      return 'music';
    default:
      return 'novel';
  }
}

/// 云端行 `data` → App 的 Book JSON（`Book.from()` 认的字段名）。
/// ★ 字段名不一致是这里最容易出错的地方：云端是 `title`，App 是 `name`。
Map<String, dynamic> bookJsonFromCloud(Map<String, dynamic> d) => <String, dynamic>{
      'name': '${d['title'] ?? d['name'] ?? ''}',
      'author': '${d['author'] ?? ''}',
      'coverUrl': '${d['coverUrl'] ?? ''}',
      'intro': '${d['intro'] ?? ''}',
      'bookUrl': '${d['bookUrl'] ?? ''}',
      'sourceId': '${d['sourceId'] ?? ''}',
    };

/// App 的 Book JSON → 云端行（书架 / 历史）。
/// [history] 决定时间戳字段名与是否带 author/top —— 形状照抄网页端
/// `content-service.js` 的 `addToShelf()` / `addHistory()`，多一个字段都可能被
/// 服务端的列约束拒掉。
Map<String, dynamic> cloudRowOfBook(
  Map<String, dynamic> book,
  String kind, {
  bool history = false,
  int nowMs = 0,
}) {
  final String src = '${book['sourceId'] ?? ''}'.trim();
  final String url = '${book['bookUrl'] ?? ''}'.trim();
  final int at = tsOf(book);
  final int stamp = at > 0 ? at : (nowMs > 0 ? nowMs : DateTime.now().millisecondsSinceEpoch);
  final Map<String, dynamic> row = <String, dynamic>{
    'id': rowIdOf(src, url),
    'sourceId': src,
    'type': kind,
    'title': '${book['name'] ?? book['title'] ?? ''}',
    'coverUrl': '${book['coverUrl'] ?? ''}',
    'bookUrl': url,
    'sourceName': '${book['sourceName'] ?? ''}',
  };
  if (history) {
    row['lastAt'] = stamp;
  } else {
    row['author'] = '${book['author'] ?? ''}';
    row['addedAt'] = stamp;
    row['top'] = false;
  }
  return row;
}

/// 阅读进度行（网页端 `saveProgress` 的行形状）。
/// 网页端会带 `offset`/`position`，App 目前只按章记，所以只发 `chapterIndex`。
Map<String, dynamic> progressRowOf(int chapterIndex, {int? tsMs}) => <String, dynamic>{
      'chapterIndex': chapterIndex < 0 ? 0 : chapterIndex,
      'ts': tsMs ?? DateTime.now().millisecondsSinceEpoch,
    };

/// 合并规则（**与网页端 `sync-service.js` 的 `pullAll()` 逐条对齐**）：
///
/// 1. 墓碑命中（本机删过）→ 删云端 + 清本机，**绝不恢复**
///    —— 「在 A 端删了小说，B 端/下次登录又同步回来」就是少了这条。
/// 2. 本机没有 → 取云端。
/// 3. 云端 `updated_at` 更新 → 覆盖本机；本机更新 → 推云端。相等 → 不动。
/// 4. 本机有、云端没有、且没墓碑 → 推云端（首次同步靠这条把老数据带上去）。
/// 5. 墓碑对应条目在本机又出现（异常恢复/换机导入）→ 本机也删掉。
///
/// [local] / [cloud] 的 key 都是行 id；[tombs] 的 key 是行 id（已按表隔离）。
MergePlan planMerge({
  required Map<String, SyncRow> local,
  required List<SyncRow> cloud,
  required Map<String, int> tombs,
}) {
  final MergePlan plan = MergePlan();
  final Set<String> cloudIds = <String>{};
  for (final SyncRow r in cloud) {
    if (r.id.isEmpty) continue;
    cloudIds.add(r.id);
    if (tombs.containsKey(r.id)) {
      plan.deleteCloud.add(r.id);
      if (local.containsKey(r.id)) plan.dropLocal.add(r.id);
      continue;
    }
    final SyncRow? l = local[r.id];
    if (l == null) {
      plan.toLocal.add(r);
    } else if (r.ts > l.ts) {
      plan.toLocal.add(r);
    } else if (l.ts > r.ts) {
      plan.toCloud.add(l);
    }
  }
  for (final SyncRow l in local.values) {
    if (l.id.isEmpty) continue;
    if (cloudIds.contains(l.id)) continue;
    if (tombs.containsKey(l.id)) {
      plan.dropLocal.add(l.id);
      continue;
    }
    plan.toCloud.add(l);
  }
  return plan;
}

/// 墓碑键：`<table>:<rowId>`（与网页端 `tombKey()` 一致）。
/// 同一本书在书架和历史里是两条独立的行，墓碑必须按表隔离，
/// 否则「从书架删掉」会把历史一起删掉。
String tombKeyOf(String table, String id) => '$table$kIdSep$id';

// ══════════════════════════════════════════════════════════════════════════
// 社区（community_posts / community_comments）
//
// 网页端是**全局公开**信息流（RLS：公开可读、仅本人可写），列结构：
//   posts:    user_id / nickname / avatar / category / content / related_* / likes / created_at
//   comments: post_id / user_id / avatar / nickname / content / created_at
// App 侧的 CommunityPost 是**本地分享板**模型（title/body/kind/tags），
// 两者字段不同，必须显式映射 —— 这也是"两边看起来都叫 community_posts，
// 实际上一个是 SharedPreferences、一个是云端表"的根因。
// ══════════════════════════════════════════════════════════════════════════

/// App 帖子 → 云端 `content`（一行文本：标题 + 正文 + #标签）。
/// 云端只存 content，没有 title 列，所以标题只能是第一行。
String cloudContentOfPost({
  required String title,
  required String body,
  List<String> tags = const <String>[],
}) {
  final List<String> lines = <String>[];
  final String t = title.trim();
  if (t.isNotEmpty) lines.add(t);
  final String b = body.trim();
  if (b.isNotEmpty) lines.add(b);
  if (tags.isNotEmpty) {
    final String tagLine = tags
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .map((String e) => '#$e')
        .join(' ');
    if (tagLine.isNotEmpty) lines.add(tagLine);
  }
  return lines.join('\n');
}

/// 云端 `content` → 标题（第一行，超过 40 字截断）。
String postTitleOfContent(String content) {
  for (final String line in content.split('\n')) {
    final String t = line.trim();
    if (t.isEmpty) continue;
    return t.length <= 40 ? t : '${t.substring(0, 40)}…';
  }
  return '';
}

/// 云端 `content` → 正文（去掉被当成标题的第一行、以及末行的 `#标签`，其余原样）。
///
/// ★ 末行标签必须剥掉：否则界面上会**同时**出现正文里的 `#源 #规则` 和下面
///   那排标签芯片，同一份信息显示两遍，看着像重复渲染的 bug。
String postBodyOfContent(String content) {
  final List<String> lines = content.split('\n');
  int i = 0;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  if (i < lines.length) i++; // 跳过标题行
  int end = lines.length;
  while (end > i && lines[end - 1].trim().isEmpty) {
    end--;
  }
  if (end > i && _isTagLine(lines[end - 1])) end--; // 剥掉末行标签
  return lines.sublist(i, end).join('\n').trim();
}

/// 一行是否"整行都是 #标签"。
bool _isTagLine(String line) {
  final String t = line.trim();
  if (!t.startsWith('#')) return false;
  for (final String s in t.split(RegExp(r'\s+'))) {
    if (s.isEmpty) continue;
    if (!s.startsWith('#') || s.length < 2) return false;
  }
  return true;
}

/// 云端 `content` → 标签（末行以 `#` 开头的按空格切）。
List<String> postTagsOfContent(String content) {
  final List<String> lines = content.split('\n');
  if (lines.isEmpty) return <String>[];
  final String last = lines.last.trim();
  if (!last.startsWith('#')) return <String>[];
  return <String>[
    for (final String s in last.split(RegExp(r'\s+')))
      if (s.startsWith('#') && s.length > 1) s.substring(1)
  ];
}
