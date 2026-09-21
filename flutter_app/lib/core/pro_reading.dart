// ThirdHub v4.40.0 · R 组 阅读深化(PLAN-v3 §3.1)
//   R-2 换源(源健康度本地统计 + 自动换源) · R-3 阅读批注 · R-10 读书摘抄
//   R-5 漫画双页 · R-7 追更检查
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pro_kit.dart';

// ══════════════════════════════════════════════════════════════
// R-2 换源: 每次章节抓取的成败/耗时都记一笔 → 算出健康度 → 自动换源
// 只统计"哪条线路好用", 不含任何源规则(源仍在引擎/后端)
// ══════════════════════════════════════════════════════════════
class SourceHealth {
  static const _key = 'src_health_v1';
  static const _autoKey = 'auto_swap_source';

  /// { '源名|host': {'ok':n,'fail':n,'ms':总耗时ms,'at':最后时间戳} }
  static Future<Map<String, Map<String, int>>> load() async {
    try {
      final p = await ProKit.prefs();
      final raw = jsonDecode(p.getString(_key) ?? '{}') as Map<String, dynamic>;
      return {
        for (final e in raw.entries)
          e.key: {
            for (final f in (e.value as Map).entries)
              f.key: (f.value as num).toInt(),
          }
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> record(String source, {required bool ok, int ms = 0}) async {
    if (source.trim().isEmpty) return;
    try {
      final p = await ProKit.prefs();
      final m = await load();
      final rec = m[source] ?? {'ok': 0, 'fail': 0, 'ms': 0, 'at': 0};
      rec[ok ? 'ok' : 'fail'] = (rec[ok ? 'ok' : 'fail'] ?? 0) + 1;
      rec['ms'] = (rec['ms'] ?? 0) + ms;
      rec['at'] = DateTime.now().millisecondsSinceEpoch;
      await p.setString(_key, jsonEncode({...m, source: rec}));
    } catch (_) {}
  }

  /// 健康度 0..1: 成功率为主(0.75 权重), 平均耗时归一为辅(0.25)。
  static Future<double> score(String source, Map<String, Map<String, int>>? cached) async {
    final m = cached ?? await load();
    final r = m[source];
    if (r == null) return 0.5; // 未知源给中性分, 别一上来就判死
    final ok = r['ok'] ?? 0, fail = r['fail'] ?? 0;
    final total = ok + fail;
    if (total == 0) return 0.5;
    final rate = ok / total;
    final avg = ok > 0 ? (r['ms'] ?? 0) / ok : 4000.0;
    final speed = 1 - (avg.clamp(0, 8000) / 8000);
    return (rate * 0.75 + speed * 0.25).clamp(0, 1);
  }

  static Future<String?> best(List<String> sources) async {
    if (sources.isEmpty) return null;
    final m = await load();
    String? best;
    double bs = -1;
    for (final s in sources) {
      final v = await score(s, m);
      if (v > bs) {
        bs = v;
        best = s;
      }
    }
    return best;
  }

  static Future<bool> get autoEnabled async =>
      (await ProKit.prefs()).getBool(_autoKey) ?? true;
  static Future<void> setAutoEnabled(bool v) async =>
      (await ProKit.prefs()).setBool(_autoKey, v);

  static Future<void> clear() async => (await ProKit.prefs()).remove(_key);
}

// ══════════════════════════════════════════════════════════════
// R-3 批注 + R-10 摘抄: 共用一张表, note 为空即"纯摘抄", 非空即"批注"
// 结构: {id, book, chapter, quote, note, at}
// 一键可转笔记模块(导出 Markdown, 由笔记页粘贴/导入)
// ══════════════════════════════════════════════════════════════
class Annotations {
  static const _key = 'annotations_v1';

  static Future<List<Map<String, String>>> all() => ProKit.listOf(_key);

  static Future<void> add({
    required String book,
    required String chapter,
    required String quote,
    String note = '',
  }) async {
    if (quote.trim().isEmpty && note.trim().isEmpty) return;
    await ProKit.push(_key, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'book': book,
      'chapter': chapter,
      'quote': quote.trim(),
      'note': note.trim(),
      'at': ProKit.now(),
    }, max: 2000);
  }

  static Future<void> remove(String id) async {
    final l = await all();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(_key, l);
  }

  static Future<void> update(String id, String note) async {
    final l = await all();
    for (final e in l) {
      if (e['id'] == id) e['note'] = note;
    }
    await ProKit.saveList(_key, l);
  }

  static Future<List<Map<String, String>>> ofBook(String book) async =>
      (await all()).where((e) => e['book'] == book).toList();

  /// 导出为 Markdown(可直接贴进笔记模块 / 分享)
  static String toMarkdown(List<Map<String, String>> list, {String title = '读书摘抄'}) {
    final b = StringBuffer('# $title\n\n');
    String lastBook = '';
    for (final e in list) {
      if (e['book'] != lastBook) {
        lastBook = e['book'] ?? '';
        b.write('\n## $lastBook\n\n');
      }
      if ((e['chapter'] ?? '').isNotEmpty) b.write('> ${e['chapter']}\n>\n');
      b.write('> ${(e['quote'] ?? '').replaceAll('\n', '\n> ')}\n');
      if ((e['note'] ?? '').isNotEmpty) b.write('\n想法: ${e['note']}\n');
      b.write('\n<sub>${e['at'] ?? ''}</sub>\n\n');
    }
    return b.toString();
  }

  /// 推给后端(可选, 后端没起就只用本地)
  static Future<int> syncUp() async {
    final l = await all();
    if (l.isEmpty) return 0;
    final r = await ProKit.postJson('/v1/annotations', {'list': l});
    return (r['ok'] == true) ? l.length : 0;
  }

  static Future<List<Map<String, String>>> pullDown() async {
    final r = await ProKit.getJson('/v1/annotations');
    final d = r['data'];
    if (d is Map && d['list'] is List) {
      final l = [
        for (final e in (d['list'] as List)) Map<String, String>.from(e as Map)
      ];
      if (l.isNotEmpty) await ProKit.saveList(_key, l);
      return l;
    }
    return [];
  }
}

// ══════════════════════════════════════════════════════════════
// R-7 追更检查: 登记在追的书 → 一键/定时比对章节数 → 有更新进提醒中心
// 结构: {id, book, source, url, last, new, at}
// ══════════════════════════════════════════════════════════════
class FollowUp {
  static const _key = 'follow_up_v1';

  static Future<List<Map<String, String>>> all() => ProKit.listOf(_key);

  static Future<void> add({
    required String book,
    String source = '',
    String url = '',
    String last = '',
  }) async {
    await ProKit.push(_key, {
      'id': book.hashCode.toRadixString(16),
      'book': book,
      'source': source,
      'url': url,
      'last': last,
      'new': '',
      'at': ProKit.now(),
    }, max: 200);
  }

  static Future<void> remove(String id) async {
    final l = await all();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(_key, l);
  }

  static Future<void> markRead(String id) async {
    final l = await all();
    for (final e in l) {
      if (e['id'] == id) e['new'] = '';
    }
    await ProKit.saveList(_key, l);
  }

  /// 检查一本书的最新目录。走引擎/后端 THP, 失败即返回 null(不误报)。
  static Future<String?> probe(Map<String, String> item) async {
    final url = item['url'] ?? '';
    if (url.isEmpty) return null;
    for (final p in [
      '/thp/m/novel/toc?url=${Uri.encodeComponent(url)}',
      '/v1/toc?url=${Uri.encodeComponent(url)}',
    ]) {
      final r = await ProKit.getJson(p);
      final d = r['data'];
      if (d is List && d.isNotEmpty) {
        final last = (d.last is Map) ? (d.last['title'] ?? '') : '$d';
        return last.toString();
      }
      if (d is Map && d['chapters'] is List && (d['chapters'] as List).isNotEmpty) {
        final e = (d['chapters'] as List).last;
        return ((e is Map ? e['title'] : e) ?? '').toString();
      }
    }
    return null;
  }

  /// 全量检查: 返回有更新的条目数
  static Future<int> checkAll() async {
    final l = await all();
    var hit = 0;
    final out = <Map<String, String>>[];
    for (final e in l) {
      final latest = await probe(e);
      if (latest != null && latest.isNotEmpty && latest != e['last']) {
        e['new'] = latest;
        hit++;
      } else if (latest != null && latest.isNotEmpty) {
        e['last'] = latest;
      }
      out.add(e);
    }
    await ProKit.saveList(_key, out);
    return hit;
  }
}

// ══════════════════════════════════════════════════════════════
// R-5 漫画双页(平板横屏)
// ══════════════════════════════════════════════════════════════
class ComicPrefs {
  static Future<bool> get doublePage async =>
      (await ProKit.prefs()).getBool('comic_double_page') ?? false;
  static Future<void> setDoublePage(bool v) async =>
      (await ProKit.prefs()).setBool('comic_double_page', v);

  /// 实际生效判定: 双页只在"宽屏 + 横屏"时启用(手机竖屏强行双页会看不清)
  static bool effective(bool enabled, double w, double h) => enabled && w >= 640 && w > h;
}

// ══════════════════════════════════════════════════════════════
// 阅读进阶页: 源健康度 + 自动换源 + 双页 + 追更 + 批注/摘抄入口
// ══════════════════════════════════════════════════════════════
class ReadingProPage extends ProPage {
  const ReadingProPage({super.key});
  @override
  State<ReadingProPage> createState() => _ReadingPro();
}

class _ReadingPro extends ProPageState<ReadingProPage> {
  Map<String, Map<String, int>> health = {};
  List<Map<String, String>> follow = [];
  bool auto = true;
  bool doublePage = false;
  int annCount = 0;

  @override
  String get titleText => '阅读进阶';

  @override
  Future<void> load() async {
    health = await SourceHealth.load();
    follow = await FollowUp.all();
    auto = await SourceHealth.autoEnabled;
    doublePage = await ComicPrefs.doublePage;
    annCount = await ProKit.count('annotations_v1');
  }

  List<MapEntry<String, double>> get _ranked {
    final l = health.entries.map((e) {
      final r = e.value;
      final ok = r['ok'] ?? 0, fail = r['fail'] ?? 0;
      final total = ok + fail;
      final rate = total == 0 ? 0.5 : ok / total;
      final avg = ok > 0 ? ((r['ms'] ?? 0) / ok) : 4000.0;
      final speed = 1 - (avg.clamp(0, 8000) / 8000);
      return MapEntry(e.key, rate * 0.75 + speed * 0.25);
    }).toList();
    l.sort((a, b) => b.value.compareTo(a.value));
    return l;
  }

  @override
  List<Widget> buildBody(BuildContext c) {
    final ranked = _ranked;
    return [
      ProUI.card('R-2 换源',
          [
            ProUI.sw('自动换源', auto, (v) async {
              await SourceHealth.setAutoEnabled(v);
              touch(() => auto = v);
            },
                sub: '章节抓取连续失败时, 自动切到健康度最高的线路',
                icon: Icons.swap_horiz),
            for (final e in ranked.take(12))
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: SizedBox(
                    width: 34,
                    child: Text('${(e.value * 100).round()}',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: e.value > 0.7
                                ? Colors.green
                                : (e.value > 0.4 ? Colors.orange : Colors.red)))),
                title: Text(e.key,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '成功 ${health[e.key]?['ok'] ?? 0} · 失败 ${health[e.key]?['fail'] ?? 0} · 均耗时 ${((health[e.key]?['ms'] ?? 0) / ((health[e.key]?['ok'] ?? 0) == 0 ? 1 : (health[e.key]?['ok'] ?? 1))).round()}ms',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                trailing: TextButton(
                  onPressed: () async {
                    await SourceHealth.record(e.key, ok: false, ms: 0);
                    await refresh();
                  },
                  child: const Text('标记失败', style: TextStyle(fontSize: 11)),
                ),
              ),
            if (ranked.isEmpty) ProUI.note('还没有换源统计。读过几章后这里会列出每条线路的成功率与耗时。'),
            if (ranked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: TextButton.icon(
                    onPressed: () async {
                      if (await ProKit.confirm(c, '清空统计', '将删除全部源健康度记录。')) {
                        await SourceHealth.clear();
                        await refresh();
                      }
                    },
                    icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                    label: const Text('清空统计', style: TextStyle(fontSize: 12))),
              ),
          ],
          sub: '分数 = 成功率 75% + 平均耗时 25%',
          trailing: ProUI.chip('${ranked.length} 条线路')),

      ProUI.card('R-3 / R-10 批注与摘抄', [
        ProUI.row(Icons.format_quote, '我的摘抄与批注',
            value: '$annCount 条',
            sub: '划线、写想法, 可一键导出 Markdown 进笔记',
            onTap: () => Navigator.push(
                c, MaterialPageRoute(builder: (_) => const AnnotationPage()))),
        ProUI.row(Icons.sync, '与后端同步', sub: '上传本机批注 / 拉回其它设备的批注', onTap: () async {
          final up = await Annotations.syncUp();
          if (up == 0) {
            ProUI.toast(c, ProKit.lastOnline ? '本机无可上传批注' : '未连接后端, 仅本地保存');
            return;
          }
          ProUI.toast(c, '已上传 $up 条批注');
          await refresh();
        }),
      ]),

      ProUI.card('R-5 漫画双页', [
        ProUI.sw('平板横屏双页', doublePage, (v) async {
          await ComicPrefs.setDoublePage(v);
          touch(() => doublePage = v);
        }, sub: '宽度 640 以上且横屏时才生效, 手机竖屏不变', icon: Icons.auto_stories),
      ]),

      ProUI.card('R-7 追更检查', [
        ProUI.row(Icons.add_alert_outlined, '登记在追的书',
            sub: '填书名 + 目录地址, 一键比对最新章节', onTap: () => _addFollow(c)),
        ProUI.row(Icons.refresh, '立即检查全部', sub: '需要后端或引擎在线', onTap: () async {
          ProUI.toast(c, '检查中…');
          final n = await FollowUp.checkAll();
          await refresh();
          ProUI.toast(c, n > 0 ? '发现 $n 本有更新' : '暂无更新(或线路不可达)');
        }),
        for (final e in follow)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(
                (e['new'] ?? '').isEmpty
                    ? Icons.book_outlined
                    : Icons.mark_email_unread_outlined,
                size: 20,
                color: (e['new'] ?? '').isEmpty ? null : Colors.orange),
            title: Text(e['book'] ?? '', style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(
                (e['new'] ?? '').isEmpty
                    ? '最新: ${(e['last'] ?? '').isEmpty ? '未知' : e['last']}'
                    : '更新至: ${e['new']}',
                style: TextStyle(
                    fontSize: 11,
                    color: (e['new'] ?? '').isEmpty ? Colors.grey : Colors.orange)),
            trailing: IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () async {
                  await FollowUp.remove(e['id'] ?? '');
                  await refresh();
                }),
          ),
        if (follow.isEmpty) ProUI.note('还没有在追的书。登记后「立即检查」可比对最新章节。'),
      ]),

      ProUI.note('阅读统计在「我的 → 阅读统计」; 本页只放"读得更顺"的开关与记录。'),
    ];
  }

  Future<void> _addFollow(BuildContext c) async {
    final book = await ProKit.prompt(c, '登记在追的书', hint: '书名', init: '');
    if (book == null) return;
    final url = await ProKit.prompt(c, '目录地址', hint: '可留空, 留空则只做人工记录', init: '');
    final last = await ProKit.prompt(c, '当前最新章节', hint: '可留空', init: '');
    await FollowUp.add(book: book, url: url ?? '', last: last ?? '');
    await refresh();
  }
}

// ══════════════════════════════════════════════════════════════
// 批注/摘抄页: 增删改 + 导出 + 搜索
// ══════════════════════════════════════════════════════════════
class AnnotationPage extends ProPage {
  const AnnotationPage({super.key});
  @override
  State<AnnotationPage> createState() => _Ann();
}

class _Ann extends ProPageState<AnnotationPage> {
  List<Map<String, String>> list = [];
  String kw = '';

  @override
  String get titleText => '摘抄与批注';

  @override
  Future<void> load() async => list = await Annotations.all();

  List<Map<String, String>> get shown => kw.isEmpty
      ? list
      : list
          .where((e) =>
              (e['book'] ?? '').contains(kw) ||
              (e['quote'] ?? '').contains(kw) ||
              (e['note'] ?? '').contains(kw))
          .toList();

  @override
  List<Widget> buildBody(BuildContext c) {
    return [
      TextField(
        decoration: const InputDecoration(
            hintText: '搜索书名 / 原文 / 想法',
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true),
        onChanged: (v) => touch(() => kw = v.trim()),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Text('${shown.length} 条', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const Spacer(),
        TextButton.icon(
          onPressed: () => _showMarkdown(c),
          icon: const Icon(Icons.description_outlined, size: 16),
          label: const Text('导出 Markdown', style: TextStyle(fontSize: 12)),
        ),
      ]),
      if (shown.isEmpty) ProUI.empty('还没有摘抄。读书时选中文字 → 笔记, 就会出现在这里。'),
      for (final e in shown)
        ProUI.card('', [
          if ((e['book'] ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Row(children: [
                Expanded(
                    child: Text('${e['book']} · ${e['chapter'] ?? ''}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis)),
                Text(e['at'] ?? '',
                    style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border(
                      left: BorderSide(
                          color: Theme.of(c).colorScheme.primary, width: 3))),
              child: Text(e['quote'] ?? '',
                  style: const TextStyle(fontSize: 13, height: 1.55)),
            ),
          ),
          if ((e['note'] ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.edit_note, size: 15, color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(e['note'] ?? '',
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.blueGrey, height: 1.5))),
              ]),
            ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () async {
                  final n = await ProKit.prompt(c, '写想法', init: e['note'] ?? '', lines: 3);
                  if (n != null) {
                    await Annotations.update(e['id'] ?? '', n);
                    await refresh();
                  }
                },
                child: const Text('想法', style: TextStyle(fontSize: 12))),
            TextButton(
                onPressed: () async {
                  await Annotations.remove(e['id'] ?? '');
                  await refresh();
                },
                child: const Text('删除', style: TextStyle(fontSize: 12))),
          ]),
        ]),
    ];
  }

  void _showMarkdown(BuildContext c) {
    final md = Annotations.toMarkdown(shown);
    showDialog(
      context: c,
      builder: (c2) => AlertDialog(
        title: const Text('Markdown 全文'),
        content: SizedBox(
            width: 420,
            height: 300,
            child: SingleChildScrollView(
                child: SelectableText(md,
                    style: const TextStyle(fontSize: 12, height: 1.5)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
        ],
      ),
    );
  }
}
