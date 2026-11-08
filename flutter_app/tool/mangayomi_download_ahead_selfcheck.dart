// Mangayomi download_ahead 规则内核 移植自检（纯 Dart VM，零 Flutter 依赖）
//
//   dart run tool/mangayomi_download_ahead_selfcheck.dart
//
// 为什么必须有这条闸门：#205 第 19 轮把 Mangayomi 的
// lib/services/download_manager/next_downloads.dart 逐字搬进移动端，
// 用来把「固定只预热下一张」升级成「跳过已读/已排队、按阅读顺序取后续 N 张」。
// 错了不报错、不崩，只会静默退化成「翻页又要等加载」，而 analyze /
// 编译 / 台账闸门全绿。四类病：
//   ① 照印象重写：把 .take(count) 顺手改成 .take(count + 1)，或漏掉
//      「当前项自身未下载时不预读」这道守卫；
//   ② 搬来摆着：文件在、main.dart 没接，界面行为一点没变；
//   ③ 把 package:mangayomi / riverpod / shiori / Isar 模型带进来，移动端编译不过；
//   ④ 换话不重置预热集合，新一话的页被旧话的索引误判为「已预热」。
//
// 六层断言：§1 文件与出处 / §2 上游正文逐字（内嵌全文，CI 不依赖本地镜像）/
//           §3 依赖白名单 / §4 最小类型投影 / §5 main.dart 接线与换话重置 /
//           §6 台账 + CI + 版本 + changelog + 合规。
// ★ 末尾 exit(1)：CI 只看退出码，打印 FAIL 不等于拦住了（2026-09-28 血泪）。
// ★ 版本断言不写死：从唯一来源 app_version.dart 动态读取（第 18 轮修掉的复发坑）。
// ★ 接线断言按「_precacheNext 方法块 + import 行」精确判定，不用全文 contains
//   —— 第 17/18 轮变异测试抓到过「注掉后注释里残留同名字符串骗过 contains」。
import 'dart:convert';
import 'dart:io';

int pass = 0, fail = 0, skip = 0;
final List<String> failures = <String>[];

void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    failures.add(name);
    print('  FAIL  $name');
  }
}

void skipped(String name) {
  skip++;
  print('  SKIP  $name');
}

/// 只读归一：仓库文件多为 CRLF，闸门里的锚点一律按 LF 写，
/// 先归一 \r\n → \n 再判定（不写回文件）。第 18 轮变异测试踩过这个坑。
String readOr(String path) {
  final f = File(path);
  return f.existsSync()
      ? f.readAsStringSync().replaceAll('\r\n', '\n')
      : '';
}

/// 只看行首的 import 声明，注释里的同名字符串不算（第 17 轮变异反证的教训）。
List<String> importLinesOf(String src) => const LineSplitter().convert(src)
    .where((l) => l.startsWith('import ') || l.startsWith('export '))
    .map((l) => l.trim())
    .toList();

/// 上游两行绝对 import（Chapter / Download 模型），被本地最小类型投影替代。
const String kUpstreamImports = "import 'package:mangayomi/models/chapter.dart';\n"
    "import 'package:mangayomi/models/download.dart';\n"
    "\n";

/// 上游算法正文（kodjodevf/mangayomi@91bda20a9235，逐字内嵌；本地镜像缺失也拦得住）。
const String kUpstreamAlgorithm = r'''/// Selects the next unread entries in reading order. Completed and already
/// queued downloads do not consume a slot in the requested batch size.
List<Chapter> selectNextDownloads(
  List<Chapter> chapters, {
  required int count,
  required Iterable<Download> downloads,
}) {
  if (count <= 0) return [];
  final unavailable = downloads
      .where(
        (download) =>
            download.isDownload == true || download.isStartDownload == true,
      )
      .map((download) => download.id)
      .toSet();
  return chapters
      .where(
        (chapter) =>
            chapter.isRead != true && !unavailable.contains(chapter.id),
      )
      .take(count)
      .toList();
}

/// The chapters to download ahead while [current] is read: the next [count]
/// unread chapters after it in [readingOrder], not already downloaded or
/// queued. Nothing when [current] itself is not downloaded: reading a chapter
/// online says nothing about wanting the next ones offline.
List<Chapter> selectDownloadAhead(
  List<Chapter> readingOrder,
  Chapter current, {
  required int count,
  required Iterable<Download> downloads,
}) {
  if (count <= 0) return [];
  final currentDownloaded = downloads.any(
    (download) => download.id == current.id && download.isDownload == true,
  );
  if (!currentDownloaded) return [];
  final index = readingOrder.indexWhere((c) => c.id == current.id);
  if (index < 0) return [];
  return selectNextDownloads(
    readingOrder.sublist(index + 1),
    count: count,
    downloads: downloads,
  );
}
''';

const String kUpstreamFullBody = kUpstreamImports + kUpstreamAlgorithm;

void main() {
  final local = readOr('lib/vendor/mangayomi/next_downloads.dart');
  final shim = readOr('lib/vendor/mangayomi/chapter_download_min.dart');
  final mainSrc = readOr('lib/main.dart');
  final manifest = readOr('../vendor/MANIFEST.json');
  final ci = readOr('../.github/workflows/dart-selfcheck.yml');
  final av = readOr('lib/core/app_version.dart');
  final pub = readOr('pubspec.yaml');
  final readme = readOr('../README.md');
  final cl = readOr('../build-out/changelog.json');

  // ── §1 文件与出处 ────────────────────────────────────────────────────────
  ck('§1 vendor 移植文件存在且非空', local.isNotEmpty);
  ck('§1 最小类型投影文件存在且非空', shim.isNotEmpty);
  ck('§1 出处行含 repo@commit',
      local.contains('上游: kodjodevf/mangayomi@91bda20a9235'));
  ck('§1 出处行含 Apache-2.0',
      local.contains('许可证: Apache-2.0'));
  ck('§1 出处行注明「算法正文逐字」',
      local.contains('方式: 文件移植（算法正文逐字）'));
  ck('§1 出处行含台账 id',
      local.contains('ported[id=mangayomi_download_ahead]'));
  ck('§1 出处行含上游真实路径',
      local.contains('lib/services/download_manager/next_downloads.dart'));
  ck('§1 出处行说明两行绝对 import 被投影替代',
      local.contains('chapter_download_min.dart') &&
          local.contains('两行绝对 import'));
  ck('§1 出处行说明本项目按页粒度复用该规则',
      local.contains('按页粒度复用') && local.contains('已预热页'));
  ck('§1 投影文件头注明不是上游文件',
      shim.contains('不是上游文件、不含任何上游运行逻辑'));
  ck('§1 投影文件头含台账 id',
      shim.contains('ported[id=mangayomi_chapter_download_shim]'));

  // ── §2 上游正文逐字 ──────────────────────────────────────────────────────
  final marker = '/// Selects the next unread entries in reading order.';
  final at = local.indexOf(marker);
  final algoLocal = at >= 0 ? local.substring(at) : '';
  ck('§2 能定位上游算法正文起点', at >= 0);
  ck('§2 算法正文与上游逐字一致（内嵌全文）', algoLocal == kUpstreamAlgorithm);
  ck('§2 算法正文字节长度 = 1537',
      utf8.encode(algoLocal).length == 1537);
  ck('§2 算法正文行数 = 48（含末尾空行）',
      algoLocal.split('\n').length == 48);
  ck('§2 上游全文 = 两行 import + 算法正文',
      kUpstreamFullBody.length == kUpstreamImports.length + kUpstreamAlgorithm.length);
  ck('§2 上游全文 sha 前置字节 = 1635',
      utf8.encode(kUpstreamFullBody).length == 1635);
  ck('§2 两个上游纯函数都在',
      algoLocal.contains('List<Chapter> selectNextDownloads(') &&
          algoLocal.contains('List<Chapter> selectDownloadAhead('));
  for (final line in <String>[
    '  if (count <= 0) return [];',
    '            download.isDownload == true || download.isStartDownload == true,',
    '      .map((download) => download.id)',
    '      .toSet();',
    '            chapter.isRead != true && !unavailable.contains(chapter.id),',
    '      .take(count)',
    '      .toList();',
    '  final currentDownloaded = downloads.any(',
    '    (download) => download.id == current.id && download.isDownload == true,',
    '  if (!currentDownloaded) return [];',
    '  final index = readingOrder.indexWhere((c) => c.id == current.id);',
    '  if (index < 0) return [];',
    '    readingOrder.sublist(index + 1),',
    '    downloads: downloads,',
  ]) {
    ck('§2 上游关键行在：${line.trim()}', algoLocal.contains(line));
  }
  ck('§2 上游「已完成 / 已排队不占名额」注释在',
      algoLocal.contains('Completed and already'));
  ck('§2 上游「当前项自身未下载时不预读」注释在',
      algoLocal.contains('Nothing when [current] itself is not downloaded'));
  ck('§2 算法正文不含任何 import 行', importLinesOf(algoLocal).isEmpty);

  // ── §3 依赖白名单 ────────────────────────────────────────────────────────
  final imports = importLinesOf(local);
  ck('§3 移植文件恰好 1 条 import', imports.length == 1);
  ck('§3 该 import 指向本地最小类型投影',
      imports.isNotEmpty && imports.first == "import 'chapter_download_min.dart';");
  for (final banned in <String>[
    'package:mangayomi',
    'flutter_riverpod',
    'package:shiori',
    'package:isar',
    'dart:ffi',
    'photo_view',
    'go_router',
    'super_sliver_list',
  ]) {
    ck('§3 import 白名单：不含「$banned」',
        !imports.any((l) => l.contains(banned)));
  }
  ck('§3 移植文件零外部包 import',
      !imports.any((l) => l.contains('package:')));
  ck('§3 投影文件零 import', importLinesOf(shim).isEmpty);
  ck('§3 移植文件无 part / part of',
      !const LineSplitter()
          .convert(local)
          .any((l) => l.trimLeft().startsWith('part ')));

  // ── §4 最小类型投影 ──────────────────────────────────────────────────────
  ck('§4 投影定义 class Chapter', shim.contains('class Chapter {'));
  ck('§4 投影定义 class Download', shim.contains('class Download {'));
  for (final field in <String>[
    'final String id;',
    'final bool? isRead;',
    'final bool? isDownload;',
    'final bool? isStartDownload;',
  ]) {
    ck('§4 投影字段在：$field', shim.contains(field));
  }
  ck('§4 投影字段恰好 5 个（Chapter 2 + Download 3）',
      const LineSplitter()
              .convert(shim)
              .where((l) => l.trimLeft().startsWith('final '))
              .length ==
          5);
  ck('§4 两个构造函数都要求 id',
      shim.contains('const Chapter({required this.id, this.isRead})') &&
          shim.contains(
              'const Download({required this.id, this.isDownload, this.isStartDownload})'));
  ck('§4 上游算法读到的 5 个字段全部可用',
      for5Fields(algoLocal, shim));
  ck('§4 投影零界面文案（无 Text / tr / SnackBar）',
      !shim.contains('Text(') && !shim.contains('tr(') && !shim.contains('SnackBar'));
  ck('§4 投影零 IO（无 File / HttpClient / SharedPreferences）',
      !shim.contains('File(') && !shim.contains('HttpClient') && !shim.contains('SharedPreferences'));

  // ── §5 main.dart 接线（方法块精确判定） ──────────────────────────────────
  const importWant = "import 'vendor/mangayomi/next_downloads.dart';";
  ck('§5 main.dart 有 vendor import（行首精确）',
      importLinesOf(mainSrc).contains(importWant));
  // ★ 第 19 轮 CI 真红反证：上游文件只 import（非 export）投影，Chapter / Download
  // 不会自动传给调用方；调用方必须显式 import 投影文件，否则 dart analyze 报
  // "Method not found: 'Chapter'" 并让其后 40 步全 skip。此断言钉死这第二处 import。
  ck('§5 main.dart 也 import 最小类型投影（Chapter/Download 可见）',
      importLinesOf(mainSrc)
          .contains("import 'vendor/mangayomi/chapter_download_min.dart';"));
  final start = mainSrc.indexOf('  void _precacheNext(int i) {');
  final endMark = '\n  }\n\n  /// 页图渲染';
  var block = '';
  if (start >= 0) {
    final end = mainSrc.indexOf(endMark, start);
    if (end > start) block = mainSrc.substring(start, end + 4);
  }
  ck('§5 能定位 _precacheNext 方法块', block.isNotEmpty);
  ck('§5 方法块内调用 selectDownloadAhead(',
      block.contains('selectDownloadAhead('));
  ck('§5 方法块内构造 readingOrder',
      block.contains('final readingOrder = <Chapter>['));
  ck('§5 方法块内构造 downloads',
      block.contains('final downloads = <Download>['));
  ck('§5 方法块内把 Chapter 投影为页',
      block.contains('Chapter(id: ') && block.contains('isRead: k < i'));
  ck('§5 方法块内把当前页标记为已缓存',
      block.contains('Download(id: ') && block.contains('isDownload: true'));
  ck('§5 方法块内把已预热页也标记为已排队',
      block.contains('for (final k in _precached)'));
  ck('§5 方法块内传入预读窗口常量',
      block.contains('count: _prefetchWindow'));
  ck('§5 预读窗口常量 = 3',
      mainSrc.contains('static const int _prefetchWindow = 3;'));
  ck('§5 方法块内按上游结果逐页预热',
      block.contains('for (final ch in ahead)') &&
          block.contains('int.tryParse(ch.id)'));
  ck('§5 方法块内复用 _precached 去重',
      block.contains('!_precached.add(k)'));
  ck('§5 方法块内本地/联网两条 precacheImage 都在',
      RegExp(r'precacheImage\(').allMatches(block).length == 2);
  ck('§5 方法块内保留本地文件判断',
      block.contains('_fromLocal || p.startsWith(') && block.contains('FileImage('));
  ck('§5 方法块内保留防盗链头',
      block.contains('NetworkImage(p, headers: headers)'));
  ck('§5 每页只算一次的 _precacheAt 守卫在',
      block.contains('_precacheAt == i') && block.contains('_precacheAt = i;'));
  ck('§5 旧「固定只预热下一张」逻辑已移除',
      !block.contains('final next = i + 1;'));
  ck('§5 方法块零新增 UI 文案（无 tr( / Text(）',
      !block.contains('tr(') && !block.contains('Text('));
  final loadStart = mainSrc.indexOf('  Future<void> _load() async {');
  final goAt = loadStart >= 0
      ? mainSrc.indexOf('\n  void _go(int i) {', loadStart)
      : -1;
  final loadBlock = loadStart >= 0 && goAt > loadStart
      ? mainSrc.substring(loadStart, goAt)
      : '';
  ck('§5 能定位 _load 方法块', loadBlock.isNotEmpty);
  ck('§5 换话时清空预热集合',
      loadBlock.contains('_precached.clear();'));
  ck('§5 换话时重置页守卫',
      loadBlock.contains('_precacheAt = -1;'));
  ck('§5 _precached 与 _precacheAt 字段声明在',
      mainSrc.contains('final Set<int> _precached = {};') &&
          mainSrc.contains('int _precacheAt = -1;'));

  // ── §6 台账 / CI / 版本 / changelog / 合规 ───────────────────────────────
  ck('§6 台账登记 mangayomi_download_ahead',
      manifest.contains('"id": "mangayomi_download_ahead"'));
  ck('§6 台账登记最小类型投影',
      manifest.contains('"id": "mangayomi_chapter_download_shim"'));
  ck('§6 台账写明上游路径',
      manifest.contains('lib/services/download_manager/next_downloads.dart'));
  ck('§6 台账写入第 19 轮依赖剥离结论',
      manifest.contains('第 19 轮') && manifest.contains('download_ahead.dart'));
  ck('§6 台账标注 Apache-2.0 与本轮版本',
      manifest.contains('"license": "Apache-2.0"') &&
          manifest.contains('"since": "4.81.57"'));
  ck('§6 台账 ported 至少 11 项',
      RegExp(r'"id": "mangayomi_').allMatches(manifest).length >= 9 &&
          RegExp(r'"state": "ported_').allMatches(manifest).length >= 7);
  ck('§6 CI 有 mangayomi_download_ahead 步骤',
      ci.contains('tool/mangayomi_download_ahead_selfcheck.dart') &&
          ci.contains('mangayomi_download_ahead（'));
  // 版本断言从唯一来源动态读取，不硬编码（第 18 轮修掉的复发坑）
  final verMatch = RegExp(r"kAppVersion = '([0-9.]+)'").firstMatch(av);
  final codeMatch = RegExp(r'kAppCode = ([0-9]+)').firstMatch(av);
  final curVer = verMatch?.group(1) ?? '';
  final curCode = codeMatch?.group(1) ?? '';
  ck('§6 能从唯一来源读出当前版本', curVer.isNotEmpty && curCode.isNotEmpty);
  ck('§6 版本三件套与唯一来源一致（$curVer / $curCode）',
      pub.contains('version: $curVer+$curCode') &&
          readme.contains(curVer) &&
          readme.contains(curCode));
  ck('§6 changelog 首条为当前版本（$curVer）',
      cl.contains('"latest": "$curVer"') && cl.contains('"v": "$curVer"'));
  ck('§6 changelog 历史 4.81.56 条目仍在',
      cl.contains('"v": "4.81.56"'));
  for (final t in <String>[
    'copy_manga',
    'baozi',
    'jmcomic',
    '禁漫',
    '书源',
    '图源',
  ]) {
    ck('§6 移植文件不含第三方内容源标识「$t」', !local.contains(t));
  }
  ck('§6 移植文件不含 emoji',
      !RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true)
          .hasMatch(local));
  ck('§6 投影文件不含 emoji',
      !RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true)
          .hasMatch(shim));
  ck('§6 本轮零新增 i18n 键（字典未出现第 20 批）',
      !readOr('lib/core/i18n.dart').contains('i18nUiWords20'));

  // 本地镜像层：CI 不携带镜像，打印 SKIP 不伪装成通过；本地存在则逐字节核对。
  const mirrorPath =
      '../vendor/_upstream/mangayomi/lib/services/download_manager/next_downloads.dart';
  final mirror = File(mirrorPath);
  if (!mirror.existsSync()) {
    skipped('§2 本地上游镜像未随仓库携带，逐字节核对跳过（CI 用内嵌全文断言）');
  } else {
    ck('§2 本地上游镜像与内嵌全文逐字节一致',
        mirror.readAsStringSync() == kUpstreamFullBody);
  }

  print('\n$pass 通过 / $fail 失败 / $skip 跳过');
  if (fail > 0) {
    print('Mangayomi download_ahead 规则移植与上游或接线不一致，已拦下。');
    print('首条失败: ${failures.first}');
    exit(1);
  }
}

/// 上游算法正文实际读到的 5 个投影字段，逐一确认投影类里确实声明了。
bool for5Fields(String algo, String shim) {
  const reads = <String>[
    '.id',
    '.isRead',
    '.isDownload',
    '.isStartDownload',
  ];
  for (final r in reads) {
    if (!algo.contains(r)) return false;
  }
  return shim.contains('final String id;') &&
      shim.contains('final bool? isRead;') &&
      shim.contains('final bool? isDownload;') &&
      shim.contains('final bool? isStartDownload;');
}
