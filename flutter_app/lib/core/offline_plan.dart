// 离线下载的**规则层**（零 Flutter 依赖，纯 Dart 自检可直接 import 断言）。
//
// 用户需求(2026-10-01)：「书架真正的离线下载」。
// 此前 `Book.add(target:'local')` 只把**元数据**写进 `shelf_<kind>`，正文一个字都
// 不下 —— 所以"下载到本机"名不副实：关掉网络再点开，照样要走引擎，页面上只有一句
// 取内容失败。要的是「抓全章节 → 落本地 → 由本地读」。
//
// 为什么把规则单独抽成一个纯 Dart 文件：
//   `offline_store.dart` 要 import path_provider / engine_direct（都依赖 Flutter），
//   纯 Dart VM 下连编译都过不去，自检根本 import 不了。凡是"算得出来对不对"的都放
//   这里：目录名怎么取、章节文件怎么命名、下载到第几章算完、断点续传该从哪章接着下。
//   IO 那层只是照着这里的规则读写文件，不许自己另想一套。
//
// ★ 设计取舍：**按章落盘 + meta.json 记进度**，而不是下完合成一个大 txt。
//   ① 一部书几百章，中途断网/退出是常态，按章落盘天然是断点续传；
//   ② 合成大 txt 会**双份存储**，且 `LocalLib.splitChapters` 靠正则切章节，
//      书名或正文里出现「第一章」这种行会被误切。逐章文件没有这个问题。
//   合并成单文件只作为**导出**用途（`mergeToText`），不作为存储形态。
library;

/// 下载进度。UI 直接拿它画进度条，不用自己再算百分比。
class OfflineProgress {
  /// 章节总数。0 = 还没取到目录（正在列目录的那一下）。
  final int total;

  /// 已经落盘的章节数（含上次留下的 —— 断点续传会把旧的算进来）。
  final int done;

  /// 取不到正文的章节数（源站缺章、超时等）。不算失败重来，接着往下下。
  final int failed;

  /// running=下载中 · done=全下完 · partial=下了一部分就停了 · error=整轮失败
  final String status;

  /// 给用户看的一句话（"正在下载 第 12/320 章"、"已离线 320 章"）。
  final String message;

  const OfflineProgress({
    required this.total,
    required this.done,
    required this.failed,
    required this.status,
    this.message = '',
  });

  bool get running => status == 'running';
  bool get finished => !running;

  /// 0.0 ~ 1.0。分母为 0 时回 0（不要返回 NaN 之类去污染进度条）。
  double get ratio {
    if (total <= 0) return 0;
    final v = (done + failed) / total;
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  OfflineProgress copyWith({
    int? total,
    int? done,
    int? failed,
    String? status,
    String? message,
  }) =>
      OfflineProgress(
        total: total ?? this.total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        status: status ?? this.status,
        message: message ?? this.message,
      );

  Map<String, dynamic> toJson() => {
        'total': total,
        'done': done,
        'failed': failed,
        'status': status,
        'message': message,
      };

  @override
  String toString() => 'OfflineProgress($done/$total, $status)';
}

/// 一本书的离线清单。落盘在 `<文档>/offline_books/<slug>/meta.json`。
class OfflineMeta {
  /// 与 `Book.bookUrl` 一一对应，也是离线目录的**唯一标识**（不是书名 ——
  /// 书名会重名、会被用户改，bookUrl 才是稳定键）。
  final String bookUrl;
  final String name, author, coverUrl, intro, sourceId, kind;

  /// running=还在下 · done=全下完 · partial=缺章 · error=失败
  final String status;

  /// 清单最后更新时间（yyyy-MM-dd HH:mm）。
  final String at;

  final int total, done, failed;

  /// 目录：[{name, url}]，顺序与章节文件 `c_00000.txt` 一一对应。
  final List<Map<String, String>> chapters;

  const OfflineMeta({
    required this.bookUrl,
    required this.name,
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.sourceId = 'engine',
    this.kind = 'novel',
    required this.status,
    required this.at,
    required this.total,
    required this.done,
    required this.failed,
    required this.chapters,
  });

  factory OfflineMeta.fromJson(Map<String, dynamic> j) => OfflineMeta(
        bookUrl: '${j['bookUrl'] ?? ''}',
        name: '${j['name'] ?? ''}',
        author: '${j['author'] ?? ''}',
        coverUrl: '${j['coverUrl'] ?? ''}',
        intro: '${j['intro'] ?? ''}',
        sourceId: '${j['sourceId'] ?? 'engine'}',
        kind: '${j['kind'] ?? 'novel'}',
        status: '${j['status'] ?? 'error'}',
        at: '${j['at'] ?? ''}',
        total: _int(j['total']),
        done: _int(j['done']),
        failed: _int(j['failed']),
        chapters: [
          for (final c in (j['chapters'] as List? ?? const []))
            if (c is Map)
              {
                'name': '${c['name'] ?? ''}',
                'url': '${c['url'] ?? ''}',
              }
        ],
      );

  Map<String, dynamic> toJson() => {
        'bookUrl': bookUrl,
        'name': name,
        'author': author,
        'coverUrl': coverUrl,
        'intro': intro,
        'sourceId': sourceId,
        'kind': kind,
        'status': status,
        'at': at,
        'total': total,
        'done': done,
        'failed': failed,
        'chapters': chapters,
      };

  OfflineMeta copyWith({
    String? status,
    String? at,
    int? total,
    int? done,
    int? failed,
    List<Map<String, String>>? chapters,
  }) =>
      OfflineMeta(
        bookUrl: bookUrl,
        name: name,
        author: author,
        coverUrl: coverUrl,
        intro: intro,
        sourceId: sourceId,
        kind: kind,
        status: status ?? this.status,
        at: at ?? this.at,
        total: total ?? this.total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        chapters: chapters ?? this.chapters,
      );

  static int _int(Object? v) => v is int ? v : (int.tryParse('$v') ?? 0);
}

/// 纯规则：所有"从输入算出输出"的判断都在这里，不碰文件系统。
class OfflinePlan {
  /// 离线库根目录名（挂在应用文档目录下）。
  static const String dirName = 'offline_books';

  /// 每本书目录里的清单文件名。
  static const String metaFile = 'meta.json';

  /// 章节正文文件前缀，后面接 5 位补零下标 → `c_00000.txt`。
  /// 补零是为了让文件管理器按名字排序 == 按章节顺序（不补零 c_9 会排在 c_10 后面）。
  static const String chapterPrefix = 'c_';

  /// 章节下标补零位数。5 位 = 最多 10 万章，够用且文件名不长。
  static const int chapterPad = 5;

  /// FNV-1a 32 位。
  ///
  /// 用 32 位而不是 64 位：`h * prime` 在 32 位下最大约 2^56，远在 int64 安全区，
  /// **不会溢出**；64 位 FNV 的乘法会溢出，而 Dart 在 Web 上 int 是 JS number
  /// （53 位有效位），溢出行为与 VM 不一致 → 同一份书在两端算出不同目录名。
  static int fnv1a32(String s) {
    var h = 0x811c9dc5;
    for (final r in s.runes) {
      // 按 UTF-8 字节喂，保证与"任意语言实现的 FNV"结果可比对。
      for (final b in _utf8(r)) {
        h = (h ^ b) & 0xffffffff;
        h = (h * 0x01000193) & 0xffffffff;
      }
    }
    return h;
  }

  static List<int> _utf8(int r) {
    if (r < 0x80) return [r];
    if (r < 0x800) return [0xc0 | (r >> 6), 0x80 | (r & 0x3f)];
    if (r < 0x10000) {
      return [0xe0 | (r >> 12), 0x80 | ((r >> 6) & 0x3f), 0x80 | (r & 0x3f)];
    }
    return [
      0xf0 | (r >> 18),
      0x80 | ((r >> 12) & 0x3f),
      0x80 | ((r >> 6) & 0x3f),
      0x80 | (r & 0x3f)
    ];
  }

  /// 书名 → 文件系统安全的名字。只保留中英文数字与 `-_.`，其余一律 `_`。
  ///
  /// ★ 必须做：书名里出现 `/` `:` `?` 是常事（《三体Ⅰ：地球往事》），直接拿去当
  /// 目录名会在 Windows 上创建失败、在 Linux 上**多建一层目录**，表现是"下了半天
  /// 一本书都没有"。这类 bug 只有真跑起来才发现，所以收进规则层做成可断言的。
  ///
  /// 契约：全非法字符时返回**空串**（不是一堆下划线），由 [slugOf] 退回纯哈希，
  /// 目录名就是哈希本身、不会出现 `_a1b2c3d4` 这种前导下划线。
  static String sanitizeName(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      final ok = (r >= 0x30 && r <= 0x39) || // 0-9
          (r >= 0x41 && r <= 0x5a) || // A-Z
          (r >= 0x61 && r <= 0x7a) || // a-z
          (r >= 0x4e00 && r <= 0x9fff) || // CJK 统一汉字
          (r >= 0x3400 && r <= 0x4dbf) || // CJK 扩展 A
          r == 0x2d || // -
          r == 0x5f || // _
          r == 0x2e; // .
      buf.writeCharCode(ok ? r : 0x5f);
    }
    var out = buf.toString();
    // 连续下划线折叠，首尾去掉
    out = out.replaceAll(RegExp(r'_{2,}'), '_');
    out = out.replaceAll(RegExp(r'^_+|_+$'), '');
    if (out.length > 24) out = out.substring(0, 24);
    return out;
  }

  /// bookUrl → 8 位十六进制哈希。**目录名的唯一稳定部分**。
  ///
  /// 为什么查找（has/toc/chapter）只认这段：那几处手上可能只有 bookUrl
  /// （比如阅读器翻章时），若目录名依赖书名就查不到。`offline_store` 的
  /// `findDir` 先按精确名找、找不到再按 `_$hash` 后缀扫一遍，两头都兜住。
  static String hashOf(String bookUrl) =>
      fnv1a32(bookUrl).toRadixString(16).padLeft(8, '0');

  /// 离线目录名：`书名_哈希`。哈希保证不撞车，书名前缀保证人在文件管理器里认得出。
  ///
  /// 为什么不能只用书名：两本书同名（不同作者/不同源）会互相覆盖对方的正文。
  /// 为什么不能只用哈希：用户翻手机存储找书时看到一串 16 进制，认不出是哪本。
  static String slugOf(String bookUrl, {String name = ''}) {
    final h = hashOf(bookUrl);
    final n = sanitizeName(name);
    return n.isEmpty ? h : '${n}_$h';
  }

  /// 第 i 章的正文文件名。
  static String chapterFileName(int i) {
    final n = i < 0 ? 0 : i;
    return '$chapterPrefix${n.toString().padLeft(chapterPad, '0')}.txt';
  }

  /// 文件名 → 章节下标。不匹配返回 null（垃圾文件不算章节）。
  ///
  /// ★ 必须允许 `.txt` 扩展名、并容忍带目录前缀：调用方传进来的是
  /// `chapters/` 目录列表里的文件名（带扩展名），只匹配 `c_00032` 的话会
  /// **一律返回 null** —— 于是 `countDone` 恒为 0（清单永远显示"0 章"），
  /// `nextMissingIndex` 也恒返回 0（整本书每次重下一遍）。
  /// 这个坑自检第 2 节钉住了：扩展名往返 + 带路径往返。
  static int? chapterIndexOf(String fileName) {
    final n = fileName.trim().split(RegExp(r'[/\\]')).last;
    final m =
        RegExp('^${RegExp.escape(chapterPrefix)}(\\d+)(?:\\.txt)?\$').firstMatch(n);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// 由"已落盘的文件名集合"算出**下一个要下的章节下标**。
  ///
  /// ★ 这是断点续传的核心：必须返回第一个**缺失**的下标，而不是"已完成数"。
  /// 用已完成数会在"第 3 章失败、第 4-10 章成功"时永远跳过第 3 章 ——
  /// 表现是书下完了，中间缺一章，用户翻到那里才发现。
  /// 全部存在时返回 null。
  static int? nextMissingIndex(List<String> existingFileNames, int total) {
    if (total <= 0) return 0;
    final have = <int>{};
    for (final f in existingFileNames) {
      final i = chapterIndexOf(f);
      if (i != null) have.add(i);
    }
    for (var i = 0; i < total; i++) {
      if (!have.contains(i)) return i;
    }
    return null;
  }

  /// 实际已落盘的章节数（只算下标落在 [0,total) 内的，越界的垃圾文件不算）。
  static int countDone(List<String> existingFileNames, int total) {
    final have = <int>{};
    for (final f in existingFileNames) {
      final i = chapterIndexOf(f);
      if (i != null && i >= 0 && (total <= 0 || i < total)) have.add(i);
    }
    return have.length;
  }

  /// 由计数决定状态。这是**唯一**的状态判定点，不许在别处另写一套。
  static String statusOf(int total, int done, int failed) {
    if (total <= 0) return 'error';
    if (done >= total) return 'done';
    if (done > 0) return 'partial';
    return failed > 0 ? 'error' : 'partial';
  }

  static bool isDone(OfflineMeta m) => m.total > 0 && m.done >= m.total;

  /// 书架上那行小字：「已离线 320/320 章」/「离线 12/320 章」/「离线失败」。
  static String describe(OfflineMeta m) {
    if (m.status == 'error' && m.done == 0) return '离线失败';
    if (isDone(m)) return '已离线 ${m.total} 章';
    return '离线 ${m.done}/${m.total} 章';
  }

  /// 合并成单文件时给每章加的标题行。
  ///
  /// ★ 格式必须命中 `LocalLib.splitChapters` 的正则
  /// `第[0-9零一二三四五六七八九十百千万两]+[章节卷回部篇集]...`，
  /// 否则导出的 txt 在别的阅读器里是"一整坨"、在本 App 里会被切成错的段。
  /// 自检会拿真字符跑一遍那个正则来钉这条（见 offline_book_selfcheck）。
  static String headingOf(int i, String name) {
    final t = name.trim();
    return t.isEmpty ? '第${i + 1}章' : '第${i + 1}章 $t';
  }

  /// 把逐章正文合成一份 txt（**导出**用，不是存储形态）。
  /// [texts] 与 [names] 等长；短的一边按空章处理，不抛异常。
  static String mergeToText(List<String> texts, List<String> names) {
    final buf = StringBuffer();
    final n = texts.length > names.length ? texts.length : names.length;
    for (var i = 0; i < n; i++) {
      final name = i < names.length ? names[i] : '';
      final body = i < texts.length ? texts[i] : '';
      buf.writeln(headingOf(i, name));
      buf.writeln();
      final t = body.trim();
      if (t.isNotEmpty) {
        buf.writeln(t);
        buf.writeln();
      }
    }
    return buf.toString();
  }

  /// 合并结果会被 `LocalLib.splitChapters` 切成几段。
  /// 用于自检证明"导出的 txt 能被正确切回来"。
  ///
  /// 这里**复制**而不是 import `local_import.dart` —— 后者 import 了
  /// file_picker/path_provider，纯 Dart VM 下编译不过。
  static List<String> splitChaptersLikeLocalLib(String text) {
    final re = RegExp(
        r'^\s*(第[0-9零一二三四五六七八九十百千万两]+[章节卷回部篇集].{0,40}|序章|楔子|序|番外.{0,20}|Chapter\s+\d+.{0,40})\s*$',
        multiLine: true);
    final matches = re.allMatches(text).toList();
    if (matches.isEmpty) return [text];
    final chapters = <String>[];
    if (matches.first.start > 0) chapters.add(text.substring(0, matches.first.start));
    for (var i = 0; i < matches.length; i++) {
      final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
      chapters.add(text.substring(matches[i].start, end));
    }
    return chapters;
  }

  /// 给人看的时间戳，与全仓其它 `at` 字段格式一致（yyyy-MM-dd HH:mm）。
  static String stamp([DateTime? now]) {
    final t = now ?? DateTime.now();
    return t.toString().substring(0, 16);
  }
}
