// 媒体离线下载的 **规则层**（纯 Dart，可单独自检）。
//
// 与 `offline_plan.dart` 同一套思想分工：
//   · 「算得出来对不对」的判断全在这层 —— 文件命名、扩展名、HLS 判定、状态口径；
//   · 「碰磁盘、碰网络」在 `offline_media_store.dart`，那层不许自己另想一套规则。
//
// 为什么小说（offline_books）和媒体（offline_media）是两套落盘：
//   小说是「逐章 txt」，媒体是「整文件 / 逐页图片」，落盘形态完全不同
//   （offline_store.dart 里对非 novel 直接拒绝就是这个原因）。
//   规则可以复用（hashOf/slugOf/statusOf 都是调 OfflinePlan 的），落盘必须分开。
//
// 落盘形态（一条记录一个目录）：
//   <应用文档>/offline_media/<标题_哈希>/
//     meta.json           清单：标题/类型/来源/文件表/状态/字节数
//     media.mp4           视频或音频（ext 按 URL 推断：mp4/mkv/mp3/flac…）
//     pages/p_00001.jpg   漫画逐页（5 位补零，文件管理器排序 == 阅读顺序）
//
// ★ 直播**不支持整文件保存**（边播边生成、没有完整分片列表）；但**点播 HLS（.m3u8）
//   支持** —— 拉清单 → 逐分片下载 → 边下边拼成单文件。判定与解析全在 [HlsPlan]
//   （纯函数，可自检）。旧的「所有 m3u8 一律拒绝」口径已升级（2026-10-11 · 规划册 H1）。
library;

import 'offline_plan.dart';

class MediaOfflinePlan {
  static const String dirName = 'offline_media';
  static const String metaFile = 'meta.json';
  static const String pagePrefix = 'p_';
  static const int pagePad = 5;
  static const String pageDirName = 'pages';

  /// 目录稳定键：只认 URL（标题会重名、会被改）。
  static String hashOf(String key) => OfflinePlan.hashOf(key);

  static String slugOf(String key, {String name = ''}) =>
      OfflinePlan.slugOf(key, name: name);

  /// 从 URL 推断扩展名。查不出（签名地址/无后缀）回 [fallback]。
  static String extOf(String url, {String fallback = 'bin'}) {
    final clean = url.split('?').first.split('#').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return fallback;
    final ext = clean.substring(dot + 1).toLowerCase();
    // 只认媒体扩展名白名单，别把 ?token= 里的乱码当扩展名
    const ok = {
      'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'm4v', 'ts', 'mpg', 'mpeg',
      'mp3', 'flac', 'm4a', 'aac', 'ogg', 'wav', 'wma', 'opus',
      'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif',
    };
    return ok.contains(ext) ? ext : fallback;
  }

  /// 单媒体文件名。
  static String mediaFileName(String ext) => 'media.${_clean(ext)}';

  /// 漫画页文件名：`p_00001.jpg`（5 位补零 ⇒ 文件管理器排序 == 阅读顺序）。
  static String pageFileName(int i, String ext) =>
      '$pagePrefix${i.toString().padLeft(pagePad, '0')}.${_clean(ext)}';

  /// 页文件名 → 下标；不是页文件回 null（与 OfflinePlan.chapterIndexOf 同思路）。
  static int? pageIndexOf(String fileName) {
    final m = RegExp('^$pagePrefix(\\d+)\\.').firstMatch(fileName);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  // ─────────────── 回收站（2026-10-12：删除可撤销）───────────────
  //
  // 设计取舍：为什么是"rename 进 .trash"而不是"先记 key、撤销时重下"——
  //   媒体离线动辄几十上百 MB，误删后重下既费流量又费时间；rename 是**原子**的，
  //   撤销只是搬回来（秒级）。过期清理由 [trashExpired] 判定（默认 7 天）。
  // 目录名：`<slug>__<yyyyMMddHHmmss>`（时间戳用于过期判定；slug 可还原原位）。
  static const String trashDirName = '.trash';

  /// 回收站里的目录名（slug + 双下划线 + 14 位时间戳）。
  static String trashName(String slug, DateTime when) =>
      '${slug}__${_trashStamp(when)}';

  static String _trashStamp(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}'
      '${d.hour.toString().padLeft(2, '0')}'
      '${d.minute.toString().padLeft(2, '0')}'
      '${d.second.toString().padLeft(2, '0')}';

  /// 回收站目录名 → 时间（解析不出回 null）。null 由 [trashExpired] 视为"即清"。
  static DateTime? trashTimeOf(String name) {
    final i = name.indexOf('__');
    if (i < 0) return null;
    final s = name.substring(i + 2);
    if (s.length < 14) return null;
    final y = int.tryParse(s.substring(0, 4));
    final mo = int.tryParse(s.substring(4, 6));
    final d = int.tryParse(s.substring(6, 8));
    final h = int.tryParse(s.substring(8, 10));
    final mi = int.tryParse(s.substring(10, 12));
    final se = int.tryParse(s.substring(12, 14));
    if (y == null || mo == null || d == null || h == null || mi == null || se == null) {
      return null;
    }
    return DateTime(y, mo, d, h, mi, se);
  }

  /// 是否过期（超过 [days] 天）。时间戳解析不出的一律视为过期（宁可早清、不堆垃圾）。
  static bool trashExpired(String name, {int days = 7}) {
    final t = trashTimeOf(name);
    if (t == null) return true;
    return DateTime.now().difference(t) > Duration(days: days);
  }

  /// 回收站目录名 → 原 slug（`__` 前的部分；没有 `__` 则原样返回）。
  static String trashSlugOf(String name) {
    final i = name.indexOf('__');
    return i < 0 ? name : name.substring(0, i);
  }

  static String _clean(String ext) {
    final e = ext.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return e.isEmpty ? 'bin' : e;
  }

  /// 直播 / HLS 判定：`.m3u8` 是分片流清单，不是文件，整存没有意义。
  /// 也拦 `.m3u`（旧扩展名）。
  static bool isStreamOnly(String url) {
    final p = url.split('?').first.split('#').first.toLowerCase();
    return p.endsWith('.m3u8') || p.endsWith('.m3u');
  }

  static String statusOf(int total, int done, int failed) =>
      OfflinePlan.statusOf(total, done, failed);

  static String stamp([DateTime? now]) => OfflinePlan.stamp(now);

  /// 人类可读字节数。
  static String bytesLabel(int n) {
    if (n <= 0) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB'];
    var v = n.toDouble();
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v >= 100 || i == 0 ? v.round() : v.toStringAsFixed(1)} ${u[i]}';
  }

  /// 一句话状态（列表页/长按菜单用）。
  static String describe(MediaOfflineMeta m) {
    if (m.status == 'running') return '正在下载…';
    if (m.total <= 0) return '未开始';
    if (m.kind == 'comic') {
      return '${m.done}/${m.total} 页 · ${bytesLabel(m.bytes)}'
          '${m.failed > 0 ? ' · ${m.failed} 页没取到' : ''}';
    }
    return m.done > 0
        ? '已离线 · ${bytesLabel(m.bytes)}'
        : m.status == 'partial'
            ? '下载不完整，可再点一次补'
            : '没下成功';
  }
}

/// 一条媒体离线记录的清单（落盘 `meta.json`）。
///
/// 一条记录 = 一个可独立播放/阅读的单元：
///   视频一集 / 音乐一首 / 漫画一话。
/// 整部剧全集、整部漫画的批量下载是「多条记录」的组合动作，不改本结构。
class MediaOfflineMeta {
  /// 稳定键（集地址/歌地址/话地址），目录名由它 + 标题算出。
  final String key;

  /// video / music / comic
  final String kind;

  final String title, subtitle, coverUrl, sourceId;

  /// running=还在下 · done=全下完 · partial=缺页 · error=失败
  final String status;

  /// 清单最后更新时间（yyyy-MM-dd HH:mm）。
  final String at;

  /// 单文件记录 total=1；漫画记录 = 总页数。
  final int total, done, failed;

  /// 落盘字节数（列表页显示占用）。
  final int bytes;

  /// 相对文件名清单：单文件是 ['media.mp4']；漫画是 ['pages/p_00001.jpg', …]。
  final List<String> files;

  const MediaOfflineMeta({
    required this.key,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.coverUrl = '',
    this.sourceId = 'engine',
    required this.status,
    required this.at,
    required this.total,
    required this.done,
    required this.failed,
    this.bytes = 0,
    this.files = const [],
  });

  factory MediaOfflineMeta.fromJson(Map<String, dynamic> j) => MediaOfflineMeta(
        key: '${j['key'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        title: '${j['title'] ?? ''}',
        subtitle: '${j['subtitle'] ?? ''}',
        coverUrl: '${j['coverUrl'] ?? ''}',
        sourceId: '${j['sourceId'] ?? 'engine'}',
        status: '${j['status'] ?? 'error'}',
        at: '${j['at'] ?? ''}',
        total: _intOf(j['total']),
        done: _intOf(j['done']),
        failed: _intOf(j['failed']),
        bytes: _intOf(j['bytes']),
        files: [for (final f in (j['files'] as List? ?? const [])) '$f'],
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind,
        'title': title,
        'subtitle': subtitle,
        'coverUrl': coverUrl,
        'sourceId': sourceId,
        'status': status,
        'at': at,
        'total': total,
        'done': done,
        'failed': failed,
        'bytes': bytes,
        'files': files,
      };

  MediaOfflineMeta copyWith({
    String? status,
    String? at,
    int? total,
    int? done,
    int? failed,
    int? bytes,
    List<String>? files,
  }) =>
      MediaOfflineMeta(
        key: key,
        kind: kind,
        title: title,
        subtitle: subtitle,
        coverUrl: coverUrl,
        sourceId: sourceId,
        status: status ?? this.status,
        at: at ?? this.at,
        total: total ?? this.total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        bytes: bytes ?? this.bytes,
        files: files ?? this.files,
      );
}

int _intOf(Object? v) => v is int ? v : (int.tryParse('$v') ?? 0);

/// ─────────────── HLS（m3u8）解析：点播可整存 / 直播不可 ───────────────
///
/// 背景（2026-10-11 · 规划册 H1）：此前把**所有** m3u8 一律拒绝（"分片流不能整存"），
/// 但点播剧集大部分正是 m3u8，拒绝过宽。HLS 规范里点播与直播有**唯一可靠信号**：
///   点播（VOD）清单含 `#EXT-X-ENDLIST`（"不会再有新分片了"）→ 可以整存；
///   直播 / 滚动清单没有它 → 边播边生成，整存没有意义 → 仍然拒绝。
/// 判定放**运行时**（拉一次清单就知道），不靠 URL 猜。
///
/// 还有两类要拦：
///   · 加密流（`#EXT-X-KEY` 且 `METHOD≠NONE`）：分片是密文，直接拼接播不了，
///     解密链路不值得做 → 明确拒绝并给清楚理由；
///   · master 清单（多码率）：含 `#EXT-X-STREAM-INF`，自身没有分片 ——
///     解析器返回 [HlsManifest.childPlaylists]，IO 层往下拉一层（最多两层）。
///
/// 纯函数、零 IO：输入（清单文本 + 基地址），输出 [HlsManifest]。
class HlsPlan {
  /// 是不是 m3u8 / m3u 地址（含 query 也认）。
  static bool isHls(String url) {
    final p = url.split('?').first.split('#').first.toLowerCase();
    return p.endsWith('.m3u8') || p.endsWith('.m3u');
  }

  /// 解析清单。[baseUrl] 用于把相对分片地址还原成绝对地址。
  /// 非 HLS 文本（没有 `#EXTM3U`）→ null。
  static HlsManifest? parse(String text, String baseUrl) {
    final lines = text.split('\n').map((l) => l.trim()).toList();
    if (!lines.any((l) => l.startsWith('#EXTM3U'))) return null;

    var isVod = false;
    var encrypted = false;
    var isMaster = false;
    String? initSegment;
    final segments = <String>[];
    final children = <String>[];
    var pendingVariant = false;

    String abs(String uri) {
      try {
        return Uri.parse(baseUrl).resolve(uri).toString();
      } catch (_) {
        return uri;
      }
    }

    for (final l in lines) {
      if (l.isEmpty) continue;
      if (l == '#EXT-X-ENDLIST') {
        isVod = true;
        continue;
      }
      if (l.startsWith('#EXT-X-KEY:')) {
        // METHOD=NONE 表示这一段不加密（可覆盖之前的加密标记？不 —— 有任一加密段
        // 就没法整段直接拼，按"含加密 KEY 即拒绝"处理最安全）。
        if (!l.contains('METHOD=NONE')) encrypted = true;
        continue;
      }
      if (l.startsWith('#EXT-X-STREAM-INF')) {
        isMaster = true;
        pendingVariant = true;
        continue;
      }
      if (l.startsWith('#EXT-X-MAP:')) {
        final m = RegExp(r'URI="([^"]+)"').firstMatch(l);
        if (m != null) initSegment = abs(m.group(1)!); // fMP4 的 init 段，拼在最前
        continue;
      }
      if (l.startsWith('#')) continue; // 其它标签（EXTINF/EXT-X-TARGETDURATION…）跳过
      // 普通 URI 行：master 里是子清单，媒体清单里是分片
      if (isMaster) {
        if (pendingVariant) {
          children.add(abs(l));
          pendingVariant = false;
        }
      } else {
        segments.add(abs(l));
      }
    }

    return HlsManifest(
      isMaster: isMaster,
      isVod: isVod,
      encrypted: encrypted,
      initSegment: initSegment,
      segments: List.unmodifiable(segments),
      childPlaylists: List.unmodifiable(children),
      mergedExt: _mergedExtOf(segments),
    );
  }

  /// 合并后的文件扩展名：按多数分片的扩展名判。
  ///   .ts → ts（经典 HLS，Android ExoPlayer 可播）｜.m4s/.mp4 → mp4（fMP4）
  ///   .aac → aac（纯音频流）｜判不出 → ts（保守，HLS 最常见容器）
  static String _mergedExtOf(List<String> segs) {
    var ts = 0, m4 = 0, aac = 0;
    for (final s in segs) {
      final p = s.split('?').first.toLowerCase();
      if (p.endsWith('.m4s') || p.endsWith('.mp4') || p.endsWith('.m4v')) {
        m4++;
      } else if (p.endsWith('.aac')) {
        aac++;
      } else if (p.endsWith('.ts')) {
        ts++;
      }
    }
    if (m4 > ts && m4 >= aac && m4 > 0) return 'mp4';
    if (aac > ts && aac > 0) return 'aac';
    return 'ts';
  }
}

/// HLS 清单的解析结果（不可变）。
class HlsManifest {
  const HlsManifest({
    required this.isMaster,
    required this.isVod,
    required this.encrypted,
    required this.initSegment,
    required this.segments,
    required this.childPlaylists,
    required this.mergedExt,
  });

  /// master（多码率总清单）——自身无分片，要去 [childPlaylists] 再拉一层。
  final bool isMaster;

  /// 点播（含 `#EXT-X-ENDLIST`）。false = 直播 / 滚动清单，不可整存。
  final bool isVod;

  /// 含加密分段（`#EXT-X-KEY` 且非 METHOD=NONE）。
  final bool encrypted;

  /// fMP4 的初始化段（`#EXT-X-MAP` 的 URI），拼接时放最前；无则 null。
  final String? initSegment;

  /// 媒体分片绝对 URL（不含 init 段）。
  final List<String> segments;

  /// master 清单里的子清单绝对 URL（按出现顺序 = 码率从高到低通常如此）。
  final List<String> childPlaylists;

  /// 合并文件扩展名：ts / mp4 / aac。
  final String mergedExt;

  int get count => segments.length;
}
