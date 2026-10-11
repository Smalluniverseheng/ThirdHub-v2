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
// ★ 直播 / HLS（.m3u8）**不支持整文件保存** —— 它是分片流，不是文件。
//   判定口径收口在 [MediaOfflinePlan.isStreamOnly]，UI 层照它提示，不许各判各的。
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
