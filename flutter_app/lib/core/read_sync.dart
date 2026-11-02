// ThirdHub 阅读数据同步层（IO）：把 `Cloud` 的网络能力接到「本机 prefs」上。
//
// 分工：
//   · 合并规则 / 字段映射 → `sync_contract.dart`（纯逻辑，有闸门跑它）
//   · 网络               → `cloud.dart`（tableUp/tableDown/tableDelete）
//   · 本文件             → 读本机 prefs、写墓碑、跑重试队列、执行合并结果
//
// 为什么要墓碑 + 重试队列（不是"直接删/直接推"）：
//   · **墓碑**：只删本机会被下次 pullAll 原样拉回来。删完必须记一笔
//     `sync_tomb`，且只有**云端删成功才清**。网页端 v3.29.6 踩过同一个坑。
//   · **重试队列**：手机上网络随时断/登出态随时过期。推失败就静默丢弃的话，
//     用户看到的是"我加了书架，过两天换手机没了"，且没有任何痕迹可查。
//
// 所有 push* 都是**旁路**（不 await 调用点）：书架/阅读是主路径，
// 不能因为云端慢卡住一次点击。失败进队列，下次前台恢复时补发。

import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'cloud.dart';
import 'sync_contract.dart';

class ReadSync {
  // ── prefs 键 ──
  static const String _tombKey = 'sync_tomb'; // {"<table>:<id>": ts}
  static const String _pendKey = 'sync_pending'; // [{op,table,id,data,ts}]
  static const String _tsPrefix = 'sync_ts_'; // sync_ts_th_bookshelf = {id: ts}
  static const String _srcPrefix = 'progress_src_'; // progress_src_<bookUrl> = sourceId
  static const String _ptsPrefix = 'progress_ts_'; // progress_ts_<bookUrl> = ts

  static const int _pendMax = 200;
  static const int _tombMax = 400;
  static const int _progressDebounceMs = 3000;

  static bool _busy = false;
  static final Map<String, int> _lastProgressAt = <String, int>{};
  static final Map<String, Timer> _progressTimers = <String, Timer>{};
  /// 尾随合并期间"最后停在那一章"：切后台时要靠它补发，
  /// 只留 Timer 是发不出去的（闭包里那一章的号码拿不到）。
  static final Map<String, int> _pendingChapter = <String, int>{};

  static bool get enabled => Cloud.loggedIn;

  // ══════════════════════════════════════════════════════════════════
  // 上行（本机写入后调用，一律 fire-and-forget）
  // ══════════════════════════════════════════════════════════════════

  /// 加入书架 → 推 `th_bookshelf`。
  static Future<void> pushShelf(Map<String, dynamic> book, String kind) async {
    if (!enabled) return;
    final String id = rowIdOf('${book['sourceId'] ?? ''}', '${book['bookUrl'] ?? ''}');
    if (id.isEmpty) return;
    final Map<String, dynamic> row = cloudRowOfBook(book, kind);
    await _push('th_bookshelf', SyncRow(id, row, tsOf(row)));
  }

  /// 打开书 → 推 `th_history`（时间戳用"现在"，因为它表达的是"最近打开"）。
  static Future<void> pushHistory(Map<String, dynamic> book, String kind) async {
    if (!enabled) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = rowIdOf('${book['sourceId'] ?? ''}', '${book['bookUrl'] ?? ''}');
    if (id.isEmpty) return;
    final Map<String, dynamic> row = cloudRowOfBook(book, kind, history: true, nowMs: now);
    await _push('th_history', SyncRow(id, row, now));
  }

  /// 从书架删除 → 写墓碑 + 删云端（**不是只删本机**）。
  static Future<void> removeShelf(String sourceId, String bookUrl) async {
    if (!enabled) return;
    final String id = rowIdOf(sourceId, bookUrl);
    if (id.isEmpty) return;
    await _del('th_bookshelf', id);
  }

  /// 阅读进度 → 推 `th_reading_progress`。
  ///
  /// 翻一页就发一次请求既费流量也费电，所以做 [ _progressDebounceMs ] 尾随合并：
  /// 连续翻页只在停下来 3 秒后发**最后一章**。离开阅读器时用 [flushProgress] 强制发。
  static Future<void> pushProgress(String sourceId, String bookUrl, int chapterIndex) async {
    if (!enabled) return;
    final String id = rowIdOf(sourceId, bookUrl);
    if (id.isEmpty) return;
    // sourceId 记在 prefs 里：拉取时要靠它把 `progress_<bookUrl>` 映射回行 id
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (sourceId.trim().isNotEmpty) await p.setString('$_srcPrefix$bookUrl', sourceId.trim());
    await p.setInt('$_ptsPrefix$bookUrl', DateTime.now().millisecondsSinceEpoch);

    final int now = DateTime.now().millisecondsSinceEpoch;
    final int? last = _lastProgressAt[id];
    if (last != null && now - last < _progressDebounceMs) {
      _progressTimers[id]?.cancel();
      _pendingChapter[id] = chapterIndex;
      _progressTimers[id] = Timer(const Duration(milliseconds: _progressDebounceMs), () {
        _progressTimers.remove(id);
        final int? ci = _pendingChapter.remove(id);
        if (ci != null) _sendProgress(id, ci);
      });
      return;
    }
    _lastProgressAt[id] = now;
    await _sendProgress(id, chapterIndex);
  }

  /// 把**所有**还在尾随合并里的进度立刻发出去（切后台 / 退出阅读器时调）。
  static Future<void> flushAllProgress() async {
    if (!enabled) return;
    final List<String> ids = _pendingChapter.keys.toList();
    for (final String id in ids) {
      _progressTimers.remove(id)?.cancel();
      final int? ci = _pendingChapter.remove(id);
      if (ci != null) await _sendProgress(id, ci);
    }
  }

  /// 立刻把最后一次进度发出去（阅读器 dispose 时调）。
  static Future<void> flushProgress(String sourceId, String bookUrl, int chapterIndex) async {
    if (!enabled) return;
    final String id = rowIdOf(sourceId, bookUrl);
    if (id.isEmpty) return;
    _progressTimers.remove(id)?.cancel();
    _lastProgressAt[id] = DateTime.now().millisecondsSinceEpoch;
    await _sendProgress(id, chapterIndex);
  }

  static Future<void> _sendProgress(String id, int chapterIndex) async {
    final Map<String, dynamic> data = progressRowOf(chapterIndex);
    await _push('th_reading_progress', SyncRow(id, data, tsOf(data)));
  }

  // ══════════════════════════════════════════════════════════════════
  // 下行（启动 / 回前台调用）
  // ══════════════════════════════════════════════════════════════════

  /// 全量拉取合并。返回本机被改动的条数（给人看"云端补了多少"）。
  ///
  /// 三张表各跑一次 [planMerge]：书架 / 历史 / 进度。
  /// `th_favorites` 不接：App 侧**没有"收藏"这个独立概念**（UI 上的"收藏"就是加书架），
  /// 硬接会把网页端的收藏夹混进书架。这一点写在「同步清单」里，不是遗漏。
  static Future<Map<String, int>> pullAll() async {
    final Map<String, int> out = <String, int>{'local': 0, 'cloud': 0, 'deleted': 0};
    if (!enabled || _busy) return out;
    _busy = true;
    try {
      await _flushPending();
      final Map<String, int> tombs = await _tombs();
      final SharedPreferences p = await SharedPreferences.getInstance();

      int n = await _pullBookTable('th_bookshelf', tombs, p);
      n += await _pullBookTable('th_history', tombs, p);
      n += await _pullProgress(tombs, p);
      out['local'] = n;

      await _saveTombs(tombs);
      // 用 add() 而不是自造的 info()：AppLog 只有 add/account/warn 三个入口
      if (out['local']! > 0) {
        AppLog.add('sync', 'info', '云端阅读数据已补到本机', detail: {'rows': out['local']});
      }
    } catch (e) {
      AppLog.warn('sync', '拉取阅读数据失败', d: {'err': '$e'});
    } finally {
      _busy = false;
    }
    return out;
  }

  /// 书架 / 历史：一张表的完整「读本机 → 拉云端 → 合并 → 落盘 + 推送」。
  static Future<int> _pullBookTable(
      String table, Map<String, int> tombs, SharedPreferences p) async {
    final String localKeyPrefix = table == 'th_bookshelf' ? 'shelf_' : 'history_';

    // 1) 本机现有行（跨 kind 汇总；id 相同以先出现的为准）
    final Map<String, SyncRow> local = <String, SyncRow>{};
    for (final String kind in kAppKinds) {
      for (final Map<String, dynamic> b in _readBooks(p, '$localKeyPrefix$kind')) {
        final String id = rowIdOf('${b['sourceId'] ?? ''}', '${b['bookUrl'] ?? ''}');
        if (id.isEmpty || local.containsKey(id)) continue;
        local[id] = SyncRow(id, b, tsOf(b));
      }
    }

    // 2) 云端行
    final List<SyncRow> cloud = <SyncRow>[];
    for (final Map<String, dynamic> e in await Cloud.tableDown(table)) {
      final String id = '${e['id'] ?? ''}';
      if (id.isEmpty) continue;
      final Object? d = e['data'];
      cloud.add(SyncRow(
        id,
        d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{},
        tsOfIso('${e['updated_at'] ?? ''}'),
      ));
    }
    if (cloud.isEmpty && local.isEmpty) return 0;

    // 3) 合并
    final MergePlan plan = planMerge(local: local, cloud: cloud, tombs: tombs);

    // 4) 落盘（云端胜的写进本机；墓碑命中的清掉）
    int changed = 0;
    for (final SyncRow r in plan.toLocal) {
      if (_upsertBook(p, localKeyPrefix, r, table == 'th_history')) changed++;
    }
    for (final String id in plan.dropLocal) {
      if (_removeBook(p, localKeyPrefix, id)) changed++;
    }

    // 5) 上行
    for (final SyncRow r in plan.toCloud) {
      await _push(table, r);
    }
    for (final String id in plan.deleteCloud) {
      final bool ok = await Cloud.tableDelete(table, id);
      if (ok) tombs.remove(tombKeyOf(table, id));
    }
    return changed;
  }

  /// 阅读进度：云端 `chapterIndex` → 本机 `progress_<bookUrl>`。
  static Future<int> _pullProgress(Map<String, int> tombs, SharedPreferences p) async {
    final List<SyncRow> cloud = <SyncRow>[];
    for (final Map<String, dynamic> e in await Cloud.tableDown('th_reading_progress')) {
      final String id = '${e['id'] ?? ''}';
      if (id.isEmpty) continue;
      final Object? d = e['data'];
      cloud.add(SyncRow(
        id,
        d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{},
        tsOfIso('${e['updated_at'] ?? ''}'),
      ));
    }
    if (cloud.isEmpty) return 0;

    int changed = 0;
    for (final SyncRow r in cloud) {
      final (String src, String bookUrl) = splitRowId(r.id);
      if (bookUrl.isEmpty) continue;
      if (tombs.containsKey(r.id)) {
        final bool ok = await Cloud.tableDelete('th_reading_progress', r.id);
        if (ok) tombs.remove(tombKeyOf('th_reading_progress', r.id));
        continue;
      }
      final int cloudTs = r.ts > 0 ? r.ts : tsOf(r.data);
      final int localTs = p.getInt('$_ptsPrefix$bookUrl') ?? 0;
      if (localTs > cloudTs) continue; // 本机更新 → 下次翻页自然会推，无需在这里反推
      final Object? idx = r.data['chapterIndex'];
      if (idx is! num) continue;
      final int ci = idx.toInt();
      if (ci < 0) continue;
      if (p.getInt('progress_$bookUrl') == ci) {
        if (cloudTs > localTs) await p.setInt('$_ptsPrefix$bookUrl', cloudTs);
        continue;
      }
      await p.setInt('progress_$bookUrl', ci);
      await p.setInt('$_ptsPrefix$bookUrl', cloudTs);
      if (src.isNotEmpty && src != kLocalSrc) await p.setString('$_srcPrefix$bookUrl', src);
      changed++;
    }
    return changed;
  }

  // ══════════════════════════════════════════════════════════════════
  // 本机 prefs 读写
  // ══════════════════════════════════════════════════════════════════

  static List<Map<String, dynamic>> _readBooks(SharedPreferences p, String key) {
    try {
      final String? raw = p.getString(key);
      if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
      return <Map<String, dynamic>>[
        for (final Object? e in jsonDecode(raw) as List)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _writeBooks(
      SharedPreferences p, String key, List<Map<String, dynamic>> list) async {
    await p.setString(key, jsonEncode(list));
  }

  /// 把一行云端数据写进本机对应的 `<prefix><kind>` 列表。
  ///
  /// 三条纪律（写成函数而不是散在三处）：
  /// ① 同 id 已在**正确分类**里 → **原地替换**，保住用户原有顺序
  ///    （书架顺序是用户排的，往里插一条就把整个顺序打乱，比不同步更恼人）；
  /// ② 同 id 在**别的分类**里（云端 `audio` → 本机 `music`）→ 从旧分类移除；
  /// ③ 本机完全没有 → 插到该分类最前面（与网页端"新加的在最上"一致）。
  static bool _upsertBook(
      SharedPreferences p, String prefix, SyncRow r, bool history) {
    final Map<String, dynamic> book = bookJsonFromCloud(r.data);
    final String bookUrl = '${book['bookUrl'] ?? ''}';
    if (bookUrl.isEmpty) return false;
    final String kind = kindOfType('${r.data['type'] ?? ''}');
    final String id = rowIdOf('${book['sourceId'] ?? ''}', bookUrl);
    final Map<String, dynamic> row = <String, dynamic>{
      ...book,
      if (history) ...<String, dynamic>{
        '_ts': r.ts,
        '_at': _atText(r.ts > 0 ? r.ts : DateTime.now().millisecondsSinceEpoch),
      },
    };

    // ① 目标分类里已有 → 原地替换
    final List<Map<String, dynamic>> target = _readBooks(p, '$prefix$kind');
    final int at = target.indexWhere((Map<String, dynamic> e) => _idOf(e) == id);
    if (at >= 0) {
      target[at] = <String, dynamic>{...target[at], ...row};
      _writeBooks(p, '$prefix$kind', target);
      _stripFromOtherKinds(p, prefix, kind, id);
      return true;
    }

    // ②③ 别的分类里挪走，然后插到最前
    _stripFromOtherKinds(p, prefix, kind, id);
    _writeBooks(p, '$prefix$kind', <Map<String, dynamic>>[row, ...target]);
    return true;
  }

  static String _idOf(Map<String, dynamic> e) =>
      rowIdOf('${e['sourceId'] ?? ''}', '${e['bookUrl'] ?? ''}');

  static void _stripFromOtherKinds(
      SharedPreferences p, String prefix, String keepKind, String id) {
    for (final String k in kAppKinds) {
      if (k == keepKind) continue;
      final List<Map<String, dynamic>> list = _readBooks(p, '$prefix$k');
      final int before = list.length;
      list.removeWhere((Map<String, dynamic> e) => _idOf(e) == id);
      if (list.length != before) _writeBooks(p, '$prefix$k', list);
    }
  }

  static bool _removeBook(SharedPreferences p, String prefix, String id) {
    bool removed = false;
    for (final String k in kAppKinds) {
      final List<Map<String, dynamic>> list = _readBooks(p, '$prefix$k');
      final int before = list.length;
      list.removeWhere((Map<String, dynamic> e) =>
          rowIdOf('${e['sourceId'] ?? ''}', '${e['bookUrl'] ?? ''}') == id);
      if (list.length != before) {
        _writeBooks(p, '$prefix$k', list);
        removed = true;
      }
    }
    return removed;
  }

  /// 与 `Book.recordHistory` 同一格式（`yyyy-MM-dd HH:mm`），否则历史列表显示空白。
  static String _atText(int ms) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  // ══════════════════════════════════════════════════════════════════
  // 墓碑 / 重试队列
  // ══════════════════════════════════════════════════════════════════

  static Future<Map<String, int>> _tombs() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    try {
      final String? raw = p.getString(_tombKey);
      if (raw == null || raw.isEmpty) return <String, int>{};
      final Map<String, int> out = <String, int>{};
      (jsonDecode(raw) as Map).forEach((Object? k, Object? v) {
        final int? ts = v is num ? v.toInt() : int.tryParse('$v');
        if (ts != null) out['$k'] = ts;
      });
      return out;
    } catch (_) {
      return <String, int>{};
    }
  }

  static Future<void> _saveTombs(Map<String, int> tombs) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (tombs.length > _tombMax) {
      final List<String> keys = tombs.keys.toList()
        ..sort((String a, String b) => tombs[a]!.compareTo(tombs[b]!));
      for (final String k in keys.take(tombs.length - _tombMax)) {
        tombs.remove(k);
      }
    }
    await p.setString(_tombKey, jsonEncode(tombs));
  }

  static Future<void> _push(String table, SyncRow r) async {
    if (r.id.isEmpty) return;
    // 时间戳随行一起上云：网页端用 data.lastAt / addedAt / ts 与本机比新旧。
    // 只发服务端列里允许的键，多塞字段会被列约束拒掉。
    final Map<String, dynamic> data = <String, dynamic>{...r.data};
    if (table == 'th_history') {
      data['lastAt'] = r.ts;
    } else if (table == 'th_bookshelf') {
      data['addedAt'] = r.ts;
    } else if (table == 'th_reading_progress') {
      data['ts'] = r.ts;
    }
    bool ok = false;
    try {
      ok = await Cloud.tableUp(table, r.id, data);
    } catch (_) {}
    if (!ok) {
      await _enqueue(<String, dynamic>{
        'op': 'put', 'table': table, 'id': r.id, 'data': data, 'ts': r.ts,
      });
    }
  }

  static Future<void> _del(String table, String id) async {
    Map<String, int> tombs = await _tombs();
    tombs[tombKeyOf(table, id)] = DateTime.now().millisecondsSinceEpoch;
    await _saveTombs(tombs);
    bool ok = false;
    try {
      ok = await Cloud.tableDelete(table, id);
    } catch (_) {}
    if (ok) {
      tombs = await _tombs();
      tombs.remove(tombKeyOf(table, id));
      await _saveTombs(tombs);
    } else {
      await _enqueue(<String, dynamic>{'op': 'del', 'table': table, 'id': id, 'ts': 0});
    }
  }

  static Future<List<Map<String, dynamic>>> _pending() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    try {
      final String? raw = p.getString(_pendKey);
      if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
      return <Map<String, dynamic>>[
        for (final Object? e in jsonDecode(raw) as List)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _savePending(List<Map<String, dynamic>> list) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(_pendKey, jsonEncode(list.take(_pendMax).toList()));
  }

  static Future<void> _enqueue(Map<String, dynamic> item) async {
    final List<Map<String, dynamic>> l = await _pending();
    // 同一行只留最后一次（连续翻页会产生一串进度写入，全部重放没有意义）
    l.removeWhere((Map<String, dynamic> e) =>
        e['table'] == item['table'] && e['id'] == item['id']);
    l.add(item);
    await _savePending(l);
  }

  /// 补发队列（启动 / 回前台 / 每次 pullAll 开头都会跑一次）。
  static Future<int> _flushPending() async {
    if (!Cloud.loggedIn) return 0;
    final List<Map<String, dynamic>> l = await _pending();
    if (l.isEmpty) return 0;
    final List<Map<String, dynamic>> still = <Map<String, dynamic>>[];
    int done = 0;
    for (final Map<String, dynamic> e in l) {
      final String table = '${e['table'] ?? ''}';
      final String id = '${e['id'] ?? ''}';
      bool ok = false;
      if (e['op'] == 'del') {
        ok = await Cloud.tableDelete(table, id);
        if (ok) {
          final Map<String, int> t = await _tombs();
          t.remove(tombKeyOf(table, id));
          await _saveTombs(t);
        }
      } else {
        final Object? d = e['data'];
        final Map<String, dynamic> data =
            d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
        ok = await Cloud.tableUp(table, id, data);
      }
      if (ok) {
        done++;
      } else {
        still.add(e);
      }
    }
    await _savePending(still);
    return done;
  }

  /// 同步状态（给「云存储」页 / 设置页展示；不在自动流程里）。
  static Future<Map<String, int>> status() async {
    final List<Map<String, dynamic>> pend = await _pending();
    final Map<String, int> tombs = await _tombs();
    return <String, int>{'pending': pend.length, 'tomb': tombs.length};
  }

  /// 测试/排障用：清空墓碑与队列（不动云端数据）。
  static Future<void> resetLocalState() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(_tombKey);
    await p.remove(_pendKey);
  }
}
