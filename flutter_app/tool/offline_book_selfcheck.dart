// 书架「真正的离线下载」自检 —— 纯 Dart，零 Flutter 依赖，可本地/CI 直接跑。
//
// 用户需求(2026-10-01)：此前 `Book.add(target:'local')` 只把元数据写进书架，
// 正文一个字都不下，"下载到本机"名不副实。这道闸门盯的是**真下下来了**：
//   · 目录名/章节文件名规则（下错地方 = 下了找不到）
//   · 断点续传必须找"第一个缺失的章节"，不是"已完成数"（否则中间永远缺一章）
//   · 状态判定只有一处（不许各处各判一套）
//   · 导出的 txt 能被 splitChapters 正确切回来
//   · 三层源码接线齐全（规则 / IO / 界面 / 阅读器）—— 防"改一半"：漏掉的那一处
//     不会报任何错，只会表现为"下了却读不了"。
//
// ★ 反证写法：用真实的"中间缺一章"场景钉住续传规则，而不是只断言函数存在。
//   本闸门已经在开发中抓到一个真 bug：`chapterIndexOf` 最初不认 `.txt` 扩展名，
//   导致 countDone 恒为 0、每次整本重下 —— 而这个 bug 不报任何错。

import 'dart:io';

import '../lib/core/offline_plan.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name${extra.isEmpty ? '' : '  -> $extra'}');
  }
}

String? tryRead(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : null;
}

void main() {
  print('=== 书架离线下载自检 ===\n');

  // 路径以脚本位置为准，不看 cwd —— Bash shim 的 cwd 不可靠，
  // 用相对路径会"明明文件在却报不存在"。
  final scriptDir =
      File(Platform.script.toFilePath()).parent.path.replaceAll('\\', '/');
  final lib = '$scriptDir/../lib';

  // ═══════════════════════════════════════════════════════════
  // 1. 目录命名（下错地方 = 下了找不到）
  // ═══════════════════════════════════════════════════════════
  print('== 1. 目录命名 ==');
  final u1 = 'https://engine.local/thp/book?id=abc';
  ck('hashOf 稳定（同输入同输出）',
      OfflinePlan.hashOf(u1) == OfflinePlan.hashOf(u1));
  final h1 = OfflinePlan.hashOf(u1);
  ck('hashOf 是 8 位十六进制',
      h1.length == 8 && RegExp(r'^[0-9a-f]{8}$').hasMatch(h1), h1);
  ck('不同地址 → 不同哈希（否则两本书互相覆盖正文）',
      OfflinePlan.hashOf(u1) != OfflinePlan.hashOf('$u1-x'));

  final slug = OfflinePlan.slugOf(u1, name: '三体');
  ck('slug 以哈希结尾（查找时按后缀能兜底命中）', slug.endsWith('_$h1'), slug);
  ck('slug 带书名前缀（文件管理器里认得出是哪本）', slug.startsWith('三体'), slug);
  ck('书名为空时 slug 就是哈希（不出现前导下划线）',
      OfflinePlan.slugOf(u1) == h1, OfflinePlan.slugOf(u1));

  const dirty = '《三体Ⅰ：地球往事》/上?*<>|"';
  final clean = OfflinePlan.sanitizeName(dirty);
  ck('sanitizeName 去掉全部文件系统非法字符',
      !RegExp(r'[/\\:*?"<>|]').hasMatch(clean), clean);
  ck('sanitizeName 保留中文（书名得认得出）', clean.contains('三体'), clean);
  // 契约：全非法字符时返回**空串**，由 slugOf 退回纯哈希 —— 不留前导下划线。
  // 这里断言的是"退化路径不会产出怪目录名"，不是"必须非空"。
  ck('全非法字符书名 → 退回纯哈希，不留前导下划线',
      OfflinePlan.sanitizeName('///???').isEmpty &&
          OfflinePlan.slugOf(u1, name: '///???') == h1,
      'sanitize="${OfflinePlan.sanitizeName('///???')}" slug=${OfflinePlan.slugOf(u1, name: '///???')}');
  ck('sanitizeName 截断到 ≤ 24 字符',
      OfflinePlan.sanitizeName('一二三四五六七八九十一二三四五六七八九十一二三四五').length <=
          24,
      '${OfflinePlan.sanitizeName('一二三四五六七八九十一二三四五六七八九十一二三四五').length}');

  // 同名两本书：哈希不同 → 目录不同，不会互相覆盖
  ck('同名不同书不会撞目录',
      OfflinePlan.slugOf('book-1', name: '同名') !=
          OfflinePlan.slugOf('book-2', name: '同名'));

  // ═══════════════════════════════════════════════════════════
  // 2. 章节文件命名（命名错 = 读不出来/顺序乱/整本重下）
  // ═══════════════════════════════════════════════════════════
  print('== 2. 章节文件命名 ==');
  ck('第 0 章文件名', OfflinePlan.chapterFileName(0) == 'c_00000.txt',
      OfflinePlan.chapterFileName(0));
  ck('第 320 章文件名（5 位补零）',
      OfflinePlan.chapterFileName(320) == 'c_00320.txt',
      OfflinePlan.chapterFileName(320));
  final idxs = [0, 1, 9, 10, 100, 999, 1000, 12345];
  final sortedBy = [
    for (final i in idxs) OfflinePlan.chapterFileName(i)
  ]..sort();
  final expectOrder = [
    for (final i in (List<int>.from(idxs)..sort()))
      OfflinePlan.chapterFileName(i)
  ];
  ck('文件名排序 == 章节顺序（不补零 c_9 会排到 c_10 后面）',
      sortedBy.join() == expectOrder.join());
  ck('文件名 → 下标往返（★带 .txt 扩展名也认，否则续传会整本重下）',
      OfflinePlan.chapterIndexOf('c_00320.txt') == 320,
      '${OfflinePlan.chapterIndexOf('c_00320.txt')}');
  ck('带目录前缀也认（列表传进来的可能是路径）',
      OfflinePlan.chapterIndexOf('chapters/c_00001.txt') == 1,
      '${OfflinePlan.chapterIndexOf('chapters/c_00001.txt')}');
  ck('无扩展名也认', OfflinePlan.chapterIndexOf('c_00007') == 7);
  ck('垃圾文件名返回 null（不该被当成章节）',
      OfflinePlan.chapterIndexOf('junk.txt') == null);
  ck('非数字下标返回 null', OfflinePlan.chapterIndexOf('c_abc.txt') == null);
  ck('同名其它扩展名返回 null', OfflinePlan.chapterIndexOf('c_00001.txt.bak') == null);

  // ═══════════════════════════════════════════════════════════
  // 3. 断点续传（★ 这节是本轮的重点反证）
  // ═══════════════════════════════════════════════════════════
  print('== 3. 断点续传 ==');
  ck('全部都在 → 无需再下', OfflinePlan.nextMissingIndex([
        for (var i = 0; i < 10; i++) OfflinePlan.chapterFileName(i)
      ], 10) ==
      null);

  // ★ 反证：第 3 章缺，其余 0-9 都在。
  //   "已完成数"是 9 → 按那种写法会从第 9 章开始（或判定已完成），第 3 章永远缺。
  //   正确答案是 2（下标从 0 数）。
  final withHole = [
    for (var i = 0; i < 10; i++)
      if (i != 2) OfflinePlan.chapterFileName(i)
  ];
  final miss = OfflinePlan.nextMissingIndex(withHole, 10);
  ck('★中间缺一章 → 返回那一章的下标，不是"已完成数"', miss == 2,
      '返回 $miss（应为 2；若为 ${withHole.length} 就是按已完成数写的）');
  ck('该场景 countDone == 9（有缺章所以不是 10）',
      OfflinePlan.countDone(withHole, 10) == 9,
      '${OfflinePlan.countDone(withHole, 10)}');
  ck('一个都没有 → 从第 0 章开始', OfflinePlan.nextMissingIndex([], 10) == 0);
  ck('total=0 → 返回 0（不要返回 null 让上层以为下完了）',
      OfflinePlan.nextMissingIndex([], 0) == 0);

  // 越界/垃圾文件不算已完成
  ck('越界文件名不算章节',
      OfflinePlan.countDone(['c_00099.txt', 'c_00000.txt'], 5) == 1,
      '${OfflinePlan.countDone(['c_00099.txt', 'c_00000.txt'], 5)}');
  ck('空文件名/垃圾不计入',
      OfflinePlan.countDone(['readme.txt', 'c_00001.txt'], 5) == 1,
      '${OfflinePlan.countDone(['readme.txt', 'c_00001.txt'], 5)}');

  // ═══════════════════════════════════════════════════════════
  // 4. 状态判定（只允许一处判定）
  // ═══════════════════════════════════════════════════════════
  print('== 4. 状态判定 ==');
  ck('全下完 → done', OfflinePlan.statusOf(100, 100, 0) == 'done');
  ck('下了一半 → partial', OfflinePlan.statusOf(100, 50, 0) == 'partial');
  ck('一章没下成且全失败 → error', OfflinePlan.statusOf(100, 0, 100) == 'error');
  ck('一章没下成且没有失败计数 → partial（别谎报 error）',
      OfflinePlan.statusOf(100, 0, 0) == 'partial');
  ck('total=0 → error（目录都没取到）', OfflinePlan.statusOf(0, 0, 0) == 'error');
  ck('缺 1 章也算 partial（不能算 done）',
      OfflinePlan.statusOf(100, 99, 1) == 'partial');

  OfflineMeta mk(int total, int done, int failed, String status) => OfflineMeta(
      bookUrl: 'u',
      name: 'n',
      status: status,
      at: '',
      total: total,
      done: done,
      failed: failed,
      chapters: const []);
  ck('isDone 只认 done>=total', OfflinePlan.isDone(mk(10, 10, 0, 'done')));
  ck('isDone 不认缺章的', !OfflinePlan.isDone(mk(10, 9, 1, 'partial')));
  ck('describe 完整',
      OfflinePlan.describe(mk(320, 320, 0, 'done')) == '已离线 320 章',
      OfflinePlan.describe(mk(320, 320, 0, 'done')));
  ck('describe 缺章',
      OfflinePlan.describe(mk(320, 12, 0, 'partial')) == '离线 12/320 章',
      OfflinePlan.describe(mk(320, 12, 0, 'partial')));
  ck('describe 全失败',
      OfflinePlan.describe(mk(320, 0, 5, 'error')) == '离线失败',
      OfflinePlan.describe(mk(320, 0, 5, 'error')));

  // 进度条比例
  const p0 = OfflineProgress(total: 0, done: 0, failed: 0, status: 'running');
  ck('total=0 时 ratio 回 0（不要 NaN 污染进度条）', p0.ratio == 0, '${p0.ratio}');
  const p1 = OfflineProgress(total: 10, done: 5, failed: 2, status: 'running');
  ck('ratio 含失败章（已处理过的才算进度）',
      (p1.ratio - 0.7).abs() < 1e-9, '${p1.ratio}');
  const p2 = OfflineProgress(total: 10, done: 20, failed: 0, status: 'done');
  ck('ratio 夹到 ≤ 1', p2.ratio == 1, '${p2.ratio}');
  ck('finished 判定', p1.finished == false && p2.finished == true);

  // ═══════════════════════════════════════════════════════════
  // 5. 清单 json 往返（清单读不出来 = 明明下了却显示未离线）
  // ═══════════════════════════════════════════════════════════
  print('== 5. 清单 ==');
  const meta = OfflineMeta(
      bookUrl: 'https://e/thp/book?id=1',
      name: '三体',
      author: '刘慈欣',
      coverUrl: 'http://c/1.jpg',
      intro: '简介',
      sourceId: 'engine',
      kind: 'novel',
      status: 'done',
      at: '2026-10-01 12:00',
      total: 2,
      done: 2,
      failed: 0,
      chapters: [
        {'name': '第一章', 'url': 'ch1'},
        {'name': '第二章', 'url': 'ch2'}
      ]);
  final rt = OfflineMeta.fromJson(meta.toJson());
  ck('json 往返后 bookUrl 不变', rt.bookUrl == meta.bookUrl);
  ck('json 往返后书名不变', rt.name == meta.name);
  ck('json 往返后章节数不变', rt.chapters.length == 2);
  ck('json 往返后章节名不变', rt.chapters[0]['name'] == '第一章');
  ck('json 往返后章节引用不变（离线缺章时要靠它回落引擎）',
      rt.chapters[1]['url'] == 'ch2');
  ck('json 往返后计数不变', rt.total == 2 && rt.done == 2 && rt.failed == 0);
  ck('json 往返后状态不变', rt.status == 'done');

  final cw = rt.copyWith(done: 1, status: 'partial');
  ck('copyWith 只改指定字段', cw.done == 1 && cw.status == 'partial');
  ck('copyWith 不动 bookUrl/name/章节表',
      cw.bookUrl == rt.bookUrl && cw.name == rt.name && cw.chapters.length == 2);

  // ═══════════════════════════════════════════════════════════
  // 6. 导出合并（导出的 txt 必须能被 splitChapters 切回来）
  // ═══════════════════════════════════════════════════════════
  print('== 6. 导出合并 ==');
  ck('章节标题命中 LocalLib.splitChapters 正则',
      OfflinePlan.splitChaptersLikeLocalLib(OfflinePlan.headingOf(0, '红岸基地'))
              .length ==
          1);
  ck('headingOf 空标题也不漏', OfflinePlan.headingOf(4, '') == '第5章',
      OfflinePlan.headingOf(4, ''));
  final merged = OfflinePlan.mergeToText(['甲\n乙', '', '丙'], ['开端', '空章', '结尾']);
  final back = OfflinePlan.splitChaptersLikeLocalLib(merged);
  ck('合并后能切回 3 章（切错段数 = 在别的阅读器里是一整坨）', back.length == 3,
      '切出 ${back.length} 段');
  ck('切回的第一段带章节标题', back[0].contains('第1章 开端'), back[0]);
  ck('空正文不产生多余段落/不抛异常', merged.contains('第2章 空章'));
  ck('mergeToText 空输入不炸',
      OfflinePlan.mergeToText(const [], const []).isEmpty);

  // ═══════════════════════════════════════════════════════════
  // 7. 文案规范（STYLE_GUIDE：禁 emoji）
  // ═══════════════════════════════════════════════════════════
  print('== 7. 文案规范 ==');
  // ★ 判定口径只认**真正的表情码点**（表情区 + 变体选择符 + 零宽连接符）。
  //   `★` U+2605 / `→` U+2192 是排版符号，全仓注释都在用，不算 emoji；
  //   之前把 0x2600-0x27BF 整段当 emoji 会误伤注释里的 ★。
  //   说明书正文用的是更严的口径（那里连装饰符号也不许有），见 manual_book_selfcheck。
  bool hasEmoji(String s) {
    for (final r in s.runes) {
      if (r >= 0x1F000 && r <= 0x1FAFF) return true; // 表情 / 补充符号
      if (r >= 0x1F1E6 && r <= 0x1F1FF) return true; // 区域指示符（国旗）
      if (r == 0xFE0F || r == 0x200D) return true; // 变体选择符 / 零宽连接符
    }
    return false;
  }

  final planSrc = tryRead('$lib/core/offline_plan.dart') ?? '';
  final storeSrc = tryRead('$lib/core/offline_store.dart') ?? '';
  final uiSrc = tryRead('$lib/core/offline_ui.dart') ?? '';
  final mainSrc = tryRead('$lib/main.dart') ?? '';
  ck('offline_plan.dart 不含 emoji', !hasEmoji(planSrc));
  ck('offline_store.dart 不含 emoji', !hasEmoji(storeSrc));
  ck('offline_ui.dart 不含 emoji', !hasEmoji(uiSrc));

  // ═══════════════════════════════════════════════════════════
  // 8. 三层接线（防"改一半"）
  // ═══════════════════════════════════════════════════════════
  print('== 8. 三层接线 ==');
  ck('IO 层用 dart:convert 写清单（手写转义迟早漏一种）',
      storeSrc.contains("import 'dart:convert'") &&
          storeSrc.contains('jsonEncode(m.toJson())'));
  ck('IO 层有哈希后缀兜底查找（书名对不上也能找到已下的书）',
      storeSrc.contains("n.endsWith('_\$hash')"), '缺 findDir 的后缀兜底');
  ck('IO 层续传用 nextMissingIndex（规则层的规则真的被用上）',
      storeSrc.contains('OfflinePlan.nextMissingIndex'));
  ck('IO 层收尾以磁盘实际状态为准（不信自己数的 done）',
      storeSrc.contains('countDone(namesNow') ||
          storeSrc.contains('countDone(await names()'));
  ck('IO 层每章落盘后写清单（不然中途退出就丢失续传依据）',
      storeSrc.split('_saveMeta').length - 1 >= 3,
      '_saveMeta 出现 ${storeSrc.split('_saveMeta').length - 1} 次');
  ck('取消后会收敛状态（不然书架一直显示"下载中"）',
      storeSrc.contains('finalizeMeta') && uiSrc.contains('finalizeMeta'));
  ck('只有小说能离线（漫画/视频点了不该假装能下）',
      storeSrc.contains("kind != 'novel'"));
  ck('取不到正文的章节跳过继续下，不整轮放弃', storeSrc.contains('已跳过'));

  ck('阅读器有 offline 分支（否则下了也读不了）',
      mainSrc.contains("sourceId == 'offline'"));
  ck('offline 分支真的读本地文件', mainSrc.contains('OfflineStore.chapterText'));
  ck('本地缺章时回落引擎（不给用户空白页）',
      mainSrc.contains("sourceId == 'offline'") &&
          mainSrc.contains('EngineDirect.content('));
  ck('目录页优先用离线目录', mainSrc.contains('OfflineStore.toc('));
  ck('书架卡片显示离线状态', mainSrc.contains('offLines'));
  ck('书架长按给全套动作（不只"移出书架"）',
      mainSrc.contains('OfflineUI.shelfMenu') &&
          mainSrc.contains('OfflineUI.actDeleteOffline'));
  ck('详情页有独立的离线下载按钮', mainSrc.contains('download_for_offline'));
  ck('「下载到本机」真的会触发下载（不是只写元数据）',
      mainSrc.contains('OfflineUI.download(context, widget.book.toJson()'));
  ck('界面层不 import main.dart（免得自检要编译整个 App）',
      !uiSrc.contains("import '../main.dart'"));

  // ═══════════════════════════════════════════════════════════
  // 9. 反证（证明这道闸门真能拦）
  // ═══════════════════════════════════════════════════════════
  print('== 9. 反证（证明这道闸门真能拦） ==');
  // 模拟"按已完成数续传"的写法，确认本闸门的断言会红
  int byDoneCount(List<String> files, int total) => files.length >= total
      ? -1
      : OfflinePlan.countDone(files, total); // 错误写法：跳过"已完成数"个
  final wrong = byDoneCount(withHole, 10);
  ck('★反证：按"已完成数"续传会跳过第 3 章（错的），闸门的 miss==2 才是对的',
      wrong != 2 && miss == 2, '错误写法得 $wrong，正确应为 $miss');

  // 反证 2：把 chapterIndexOf 写成不认扩展名（本闸门开发中真犯过的错）
  int? badIndexOf(String f) => RegExp(r'^c_(\d+)$').firstMatch(f.trim()) == null
      ? null
      : int.tryParse(RegExp(r'^c_(\d+)$').firstMatch(f.trim())!.group(1)!);
  ck('★反证：不认 .txt 扩展名会让 countDone 恒为 0（整本每次重下）',
      badIndexOf('c_00003.txt') == null &&
          OfflinePlan.chapterIndexOf('c_00003.txt') == 3,
      '错误写法得 ${badIndexOf('c_00003.txt')}，正确应为 ${OfflinePlan.chapterIndexOf('c_00003.txt')}');

  print('\n=== 离线下载自检：$pass 过 / $fail 挂 ===');
  if (fail > 0) {
    print('FAIL');
    exit(1);
  }
  print('OK');
}
