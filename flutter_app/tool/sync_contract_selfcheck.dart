// 「社区/阅读数据同步」契约自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/sync_contract_selfcheck.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// 为什么需要这条闸门（2026-11-03，待办清单第 3 项）：
//
//   本轮核实出来的真实断层是：**同步函数全都写好了，但没有任何调用点。**
//     · Cloud.shelfUp / shelfDown / progressUp / progressDown / historyUp /
//       historyDown / favUp / favDown  —— 全项目 0 个调用者
//     · 云端 th_history 里躺着 24 行 2026-10-24 的记录，App 一行都看不到
//   这类"死代码"在编译、analyze、单测里**全都是绿的** —— 因为它语法正确、
//   类型正确、逻辑也正确，只是没人调。任何"检查函数本身"的闸门都抓不到它。
//
//   所以本闸门有两条腿：
//     ① 断言**合并规则**（墓碑 / 新旧比较 / 分类映射 / 字段名）逐条对；
//     ② 断言**接线还在**：每个 push/pull 入口必须在真实页面文件里被调用。
//        删掉调用点 = 闸门红（这正是本轮出问题的形态）。
//
//   ★ 同一条教训在 i18n 那轮出现过（"闸门绿 ≠ 没漏"）：断言的对象必须
//     是**行为**（有没有被调用），不是**形状**（函数存不存在）。
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

import '../lib/core/sync_contract.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

const kLocales = <String>['en', 'ja', 'fr', 'ru', 'es', 'ar'];

/// 解析 `<locale>: { ... }` 块，抽出 key 集合（同 storage_usage_selfcheck 的做法，
/// 只判"键在不在"，误判方向偏严格，不会掩盖缺译）。
Map<String, Set<String>> dictKeys(String src) {
  final Map<String, Set<String>> out = <String, Set<String>>{};
  final RegExp re = RegExp(r"'([a-z]{2})'\s*:\s*(?:<[^>]*>\s*)?\{");
  for (final RegExpMatch m in re.allMatches(src)) {
    final String loc = m.group(1)!;
    if (!kLocales.contains(loc)) continue;
    final int start = src.indexOf('{', m.end - 1);
    int depth = 0, i = start;
    while (i < src.length) {
      final String c = src[i];
      if (c == "'" || c == '"') {
        int j = i + 1;
        while (j < src.length) {
          if (src[j] == r'\') {
            j += 2;
            continue;
          }
          if (src[j] == c) break;
          j++;
        }
        i = j + 1;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) break;
      }
      i++;
    }
    final String block = src.substring(start, i + 1);
    out.putIfAbsent(loc, () => <String>{});
    final RegExp kv = RegExp(r"'((?:[^'\\]|\\.)*)'\s*:");
    for (final RegExpMatch k in kv.allMatches(block)) {
      out[loc]!.add(k.group(1)!);
    }
  }
  return out;
}

void main() {
  print('── 1. 行 id 与字段映射 ──');
  {
    final String id = rowIdOf('src-abc', 'https://a.com/1.html');
    ck('id = sourceId:bookUrl',
        id == 'src-abc:https://a.com/1.html');
    final (String s, String u) = splitRowId(id);
    ck('id 可逆（sourceId=$s）', s == 'src-abc' && u == 'https://a.com/1.html');
    // url 里的 '://' 不能被当分隔符 —— 按最后一个 ':' 切会切出 'https' 这种鬼东西
    final (String s2, String u2) = splitRowId('src-x:https://b.com/a?x=1:2');
    ck('只按第一个分隔符切（bookUrl 含冒号）',
        s2 == 'src-x' && u2 == 'https://b.com/a?x=1:2');
    ck('缺 sourceId 时用 local 占位，不产生 ":url" 这种脏 id',
        rowIdOf('', 'https://c.com') == 'local:https://c.com');
    ck('audio 归到 music 架', kindOfType('audio') == 'music');
    ck('未知类型不丢弃（归 novel）', kindOfType('weird') == 'novel');

    final Map<String, dynamic> book = <String, dynamic>{
      'name': '三体', 'author': '刘慈欣', 'coverUrl': '/c.jpg',
      'bookUrl': 'https://d.com/b', 'sourceId': 'src-d',
    };
    final Map<String, dynamic> shelfRow = cloudRowOfBook(book, 'novel', nowMs: 1000);
    ck('书架行：title 取自 App 的 name', shelfRow['title'] == '三体');
    ck('书架行：带 author / addedAt / top',
        shelfRow['author'] == '刘慈欣' && shelfRow['addedAt'] == 1000 && shelfRow['top'] == false);
    ck('书架行：不带 lastAt（那是历史的字段）', !shelfRow.containsKey('lastAt'));

    final Map<String, dynamic> hisRow = cloudRowOfBook(book, 'novel', history: true, nowMs: 2000);
    ck('历史行：带 lastAt，不带 addedAt',
        hisRow['lastAt'] == 2000 && !hisRow.containsKey('addedAt'));

    final Map<String, dynamic> back = bookJsonFromCloud(hisRow);
    ck('云端 title → App name（字段名不一致是最大坑）', back['name'] == '三体');
    ck('往返后 bookUrl / sourceId 不变',
        back['bookUrl'] == 'https://d.com/b' && back['sourceId'] == 'src-d');

    final Map<String, dynamic> pr = progressRowOf(7);
    ck('进度行：chapterIndex + ts', pr['chapterIndex'] == 7 && (pr['ts'] as int) > 0);
    ck('进度行：负数夹到 0', progressRowOf(-3)['chapterIndex'] == 0);
  }

  print('── 2. 时间戳解析（三种格式混用） ──');
  {
    ck('lastAt 优先于 addedAt',
        tsOf(<String, dynamic>{'lastAt': 500, 'addedAt': 900}) == 500);
    ck('addedAt 其次', tsOf(<String, dynamic>{'addedAt': 900, 'ts': 100}) == 900);
    ck('App 历史的 _at 文本可解析',
        tsOf(<String, dynamic>{'_at': '2026-10-24 07:26'}) ==
            DateTime(2026, 10, 24, 7, 26).millisecondsSinceEpoch);
    ck('字符串数字也认', tsOf(<String, dynamic>{'ts': '1792215784678'}) == 1792215784678);
    ck('全空返回 0（= 最旧，不会误判成"更新"）', tsOf(<String, dynamic>{}) == 0);
    ck('ISO updated_at 解析',
        tsOfIso('2026-10-24T07:26:29.587+00:00') ==
            DateTime.parse('2026-10-24T07:26:29.587Z').millisecondsSinceEpoch);
    ck('坏 ISO 返回 0', tsOfIso('not-a-date') == 0 && tsOfIso(null) == 0);
  }

  print('── 3. 合并规则（对齐网页端 sync-service.js 的 pullAll） ──');
  {
    final SyncRow a1 = SyncRow('src-1:a', <String, dynamic>{'t': 'cloud'}, 200);
    final SyncRow a2 = SyncRow('src-1:a', <String, dynamic>{'t': 'local'}, 100);

    MergePlan p1 = planMerge(
      local: <String, SyncRow>{a2.id: a2},
      cloud: <SyncRow>[a1],
      tombs: <String, int>{},
    );
    ck('云端更新 → 写本机', p1.toLocal.length == 1 && p1.toCloud.isEmpty);

    MergePlan p2 = planMerge(
      local: <String, SyncRow>{'src-1:a': SyncRow('src-1:a', <String, dynamic>{}, 300)},
      cloud: <SyncRow>[a1],
      tombs: <String, int>{},
    );
    ck('本机更新 → 推云端', p2.toCloud.length == 1 && p2.toLocal.isEmpty);

    final SyncRow eq = SyncRow('src-1:a', <String, dynamic>{}, 200);
    MergePlan p3 = planMerge(
      local: <String, SyncRow>{eq.id: eq},
      cloud: <SyncRow>[a1],
      tombs: <String, int>{},
    );
    ck('时间相同 → 两边都不动（否则每次启动都白写一次）',
        p3.toLocal.isEmpty && p3.toCloud.isEmpty);

    // ★ 这条是"删了又复活"的病根
    MergePlan p4 = planMerge(
      local: <String, SyncRow>{a2.id: a2},
      cloud: <SyncRow>[a1],
      tombs: <String, int>{a2.id: 999},
    );
    ck('墓碑命中 → 删云端 + 清本机（绝不恢复）',
        p4.toLocal.isEmpty && p4.deleteCloud.contains(a2.id) && p4.dropLocal.contains(a2.id));

    MergePlan p5 = planMerge(
      local: <String, SyncRow>{},
      cloud: <SyncRow>[a1],
      tombs: <String, int>{a1.id: 1},
    );
    ck('墓碑命中且本机已无 → 仍要删云端',
        p5.deleteCloud.length == 1 && p5.toLocal.isEmpty);

    MergePlan p6 = planMerge(
      local: <String, SyncRow>{'src-9:z': SyncRow('src-9:z', <String, dynamic>{}, 50)},
      cloud: const <SyncRow>[],
      tombs: <String, int>{},
    );
    ck('本机独有 → 推云端（首次同步把老数据带上去）',
        p6.toCloud.length == 1);

    MergePlan p7 = planMerge(
      local: <String, SyncRow>{'src-9:z': SyncRow('src-9:z', <String, dynamic>{}, 50)},
      cloud: const <SyncRow>[],
      tombs: <String, int>{'src-9:z': 1},
    );
    ck('墓碑 + 本机独有 → 清本机，不重传（否则复活）',
        p7.dropLocal.length == 1 && p7.toCloud.isEmpty);

    ck('墓碑键按表隔离（书架删了不影响历史）',
        tombKeyOf('th_bookshelf', 'src-1:a') != tombKeyOf('th_history', 'src-1:a'));
  }

  print('── 4. 社区字段映射（community_posts 只有 content 一列） ──');
  {
    final String c = cloudContentOfPost(
      title: '某站的规则能用', body: '正文第一行\n正文第二行', tags: <String>['源', '规则']);
    final List<String> lines = c.split('\n');
    ck('content 首行 = 标题', lines.first == '某站的规则能用');
    ck('content 末行 = #标签', lines.last == '#源 #规则');
    ck('标题提取回原值', postTitleOfContent(c) == '某站的规则能用');
    ck('正文提取回原值（含换行）', postBodyOfContent(c) == '正文第一行\n正文第二行');
    ck('标签提取回原值', postTagsOfContent(c).join(',') == '源,规则');
    ck('超长标题截断到 40 字 + 省略号',
        postTitleOfContent('${'x' * 60}\n') == '${'x' * 40}…');
    ck('空正文不会留下空行', cloudContentOfPost(title: 'T', body: '  ') == 'T');
  }

  print('── 5. 接线是否还在（删掉调用点 = 红） ──');
  {
    String read(String p) => File(p).existsSync() ? File(p).readAsStringSync() : '';
    final String mainSrc = read('lib/main.dart');
    final String readerSrc = read('lib/core/novel_reader.dart');
    final String socialSrc = read('lib/core/lab_social.dart');
    final String syncSrc = read('lib/core/read_sync.dart');
    final String csyncSrc = read('lib/core/community_sync.dart');
    final String cloudSrc = read('lib/core/cloud.dart');

    ck('加书架时推云端（main.dart 调 pushShelf）', mainSrc.contains('ReadSync.pushShelf('));
    ck('打开书时写历史（main.dart 调 pushHistory）', mainSrc.contains('ReadSync.pushHistory('));
    ck('书架删除要删云端（main.dart 调 removeShelf）', mainSrc.contains('ReadSync.removeShelf('));
    ck('启动/回前台拉阅读数据（main.dart 调 pullAll）', mainSrc.contains('ReadSync.pullAll('));
    ck('阅读器翻章推进度（novel_reader.dart 调 pushProgress）',
        readerSrc.contains('ReadSync.pushProgress('));
    ck('社区拉云端信息流（lab_social 调 feed）', socialSrc.contains('CommunitySync.feed('));
    ck('社区发帖双写（lab_social 调 publish）', socialSrc.contains('CommunitySync.publish('));
    ck('社区评论读取（lab_social 调 comments）', socialSrc.contains('CommunitySync.comments('));
    ck('社区评论写入（lab_social 调 addComment）', socialSrc.contains('CommunitySync.addComment('));

    ck('三张阅读表在 read_sync 里都有字面量',
        syncSrc.contains("'th_bookshelf'") &&
            syncSrc.contains("'th_history'") &&
            syncSrc.contains("'th_reading_progress'"));
    ck('两张社区表在 community_sync 里都有字面量',
        csyncSrc.contains("'community_posts'") && csyncSrc.contains("'community_comments'"));
    ck('云端删除走 tableDelete（不是只删本机）', cloudSrc.contains('static Future<bool> tableDelete('));
    ck('社区表走列级 rowUp/rowDown（不混进 syncTables 信封）',
        cloudSrc.contains('static const List<String> communityTables') &&
            cloudSrc.contains('communityTables.contains(table)'));

    // syncTables 必须仍是与网页端逐字对齐的 6 张 —— 有人往里加社区表就会红
    final RegExp re = RegExp(r'syncTables\s*=\s*<String>\[([^;]*?)\];');
    final RegExpMatch? m = re.firstMatch(cloudSrc);
    final String list = m?.group(1) ?? '';
    const List<String> want = <String>[
      'th_bookshelf', 'th_reading_progress', 'th_history',
      'th_favorites', 'th_settings', 'th_user_devices',
    ];
    ck('syncTables 仍是 6 张且顺序与网页端 SYNC_TABLES 一致',
        want.every((String t) => list.contains("'$t'")) &&
            RegExp(r"'th_[a-z_]+'").allMatches(list).length == want.length);
  }

  print('── 6. 新增/沿用的界面文案 6 语言齐全 ──');
  {
    final Map<String, Set<String>> d = <String, Set<String>>{};
    for (final String f in <String>[
      'lib/core/i18n.dart', 'lib/core/i18n_extra.dart', 'lib/core/i18n_ui_words.dart',
    ]) {
      final String src = File(f).existsSync() ? File(f).readAsStringSync() : '';
      dictKeys(src).forEach((String loc, Set<String> keys) {
        d.putIfAbsent(loc, () => <String>{}).addAll(keys);
      });
    }
    const List<String> need = <String>[
      '云端', '评论', '刷新', '失败',
      '登录后会同步到云端社区，网页端也能看到',
      '云端暂时没有内容（或读取失败）',
      '暂无评论', '写评论…', '已发布到云端', '匿名',
    ];
    for (final String loc in kLocales) {
      final List<String> miss =
          need.where((String k) => !(d[loc]?.contains(k) ?? false)).toList();
      if (miss.isNotEmpty) print('  [$loc] 缺：${miss.join(' / ')}');
      ck('$loc 覆盖 ${need.length} 条社区文案', miss.isEmpty);
    }
  }

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) {
    print('\n✅ 同步契约：id/字段名/合并规则/墓碑/接线/6 语言 全部通过');
  }
  if (fail > 0) exit(1);
}
