// 播放源解析：**本地优先**的四级降级（纯逻辑 + 少量磁盘 IO，不 import main.dart）。
//
// ══════════════════════════════════════════════════════════════════════════════
// 为什么需要这一层（4.81.76）
// ══════════════════════════════════════════════════════════════════════════════
// 此前的写法是「先联网解析播放地址，解析到了再查本地文件有没有」：
//
//     var url = await 解析();                 // ← 断网时这里就抛了
//     if (url.isEmpty) { err = '解析失败'; return; }   // ← 直接回家
//     final lf = await MediaOfflineStore.localFileOf(key);   // ← 永远执行不到
//
// 结果：**用户明明下载到手机里的视频，在断网/后端关掉时一集都播不了**，
// 报的还是「解析失败」—— 用户会以为是源坏了，其实文件就躺在磁盘上。
// 音乐（main.dart:7689）、影视（9020）、漫画（16681）三处都是这个顺序。
//
// 本文件把顺序翻正，并把「失败原因」分类清楚，别让用户看 `ClientException`：
//
//     ① 本机有 → 直接播（不碰网络，飞机上也能看）
//     ② 本机没有 → 交给调用方的 online()（引擎直连 → 后端 → 源站直连）
//     ③ online() 抛错/返回空 → 按「网络不可达」和「源没给地址」分开报
//
// 纪律：本文件只做「找源」，不播、不建控制器、不认识 Scaffold。
//       播放器的选择留给调用方（视频/音频/漫画各自的 UI 差异太大）。
library;

import 'dart:async';
import 'dart:io';

import 'offline_media_store.dart';

/// 播放源来自哪一层。UI 可据此显示「离线播放」「直连」等小标。
enum PlayOrigin {
  /// 本机文件（已下载 / 本地导入）。
  local,

  /// 局域网引擎直连（不经 NAS 后端）。
  engine,

  /// NAS 后端（/v1/...）。
  backend,

  /// App 内直连源站（如 B 站官方 API、番茄/红果）。
  direct,
}

extension PlayOriginLabel on PlayOrigin {
  String get label => switch (this) {
        PlayOrigin.local => '离线播放',
        PlayOrigin.engine => '应用内播放',
        PlayOrigin.backend => '后端',
        PlayOrigin.direct => '直连源站',
      };
}

/// 失败原因分类 —— 文案直接给用户看，不要塞异常类名。
enum PlayFail {
  /// 本机没有，且网络层不可达（断网 / 后端关了 / 源站连不上）。
  offline,

  /// 网络通了，但源站没给出播放地址（源失效、需要付费、解析规则过期）。
  noSource,

  /// 本地文件存在但读不出来（损坏、被清理、权限）。
  localBroken,

  /// 其它未归类的异常。
  unknown,
}

/// 一次「找播放源」的结果。
class PlaySource {
  final PlayOrigin origin;

  /// 本地单文件（视频 / 音频）。
  final File? file;

  /// 本地漫画逐页。
  final List<File>? pages;

  /// 远程地址（本地未命中时才有）。
  final String? url;

  /// 失败分类与文案；成功时为 null。
  final PlayFail? fail;
  final String? error;

  const PlaySource._({
    required this.origin,
    this.file,
    this.pages,
    this.url,
    this.fail,
    this.error,
  });

  bool get ok => localReady || remoteReady;

  /// 本机就能播 —— 不依赖任何网络。
  bool get localReady => file != null || (pages != null && pages!.isNotEmpty);

  bool get remoteReady => url != null && url!.isNotEmpty;

  @override
  String toString() => ok
      ? 'PlaySource(${origin.name}${localReady ? ', local' : ', remote'})'
      : 'PlaySource(fail=${fail?.name}: $error)';
}

class PlayResolver {
  /// 小于这个字节数的本地文件视为「没下完/下坏了」，不当成本地命中。
  /// 为什么不是 0：downloader 会先建空文件再写，中途被杀就留下一个 0 字节壳子，
  /// 播它必报错，还不如当作没下载、走在线。
  static const int minLocalBytes = 64 * 1024;

  static const Duration defaultTimeout = Duration(seconds: 25);

  /// 视频 / 音频：本地文件优先。
  ///
  /// [key] 必须与下载时用的键**完全一致**（`video:<sourceId>:<epUrl>` /
  /// `music:<url|id|name>`），否则查不到已下载的那份。
  ///
  /// [online] 由调用方实现「怎么联网拿地址」，内部通常再分
  /// 引擎直连 → 后端 → 源站直连。返回空串或 null 视为「源没给地址」。
  static Future<PlaySource> media({
    required String key,
    required String title,
    required Future<OnlineUrl?> Function() online,
    Duration timeout = defaultTimeout,
  }) async {
    // ① 本地优先：命中就直接回家，一个网络包都不发。
    final local = await _localFile(key, title);
    if (local != null) {
      return PlaySource._(origin: PlayOrigin.local, file: local);
    }

    // ② 联网解析。
    return _runOnline(online, timeout);
  }

  /// 漫画：本地逐页优先。
  static Future<PlaySource> comicPages({
    required String key,
    required String title,
    required Future<OnlinePages?> Function() online,
    Duration timeout = defaultTimeout,
  }) async {
    final local = await _localPages(key, title);
    if (local != null && local.isNotEmpty) {
      return PlaySource._(origin: PlayOrigin.local, pages: local);
    }

    try {
      final r = await online().timeout(timeout);
      final pages = r?.pages ?? const <String>[];
      if (pages.isEmpty) {
        return PlaySource._(
          origin: PlayOrigin.backend,
          fail: PlayFail.noSource,
          error: r?.hint ?? '没有返回任何图片（来源可能已失效）',
        );
      }
      return PlaySource._(
        origin: r?.origin ?? PlayOrigin.backend,
        url: pages.first,
      );
    } catch (e) {
      return _fail(e, hasLocal: false);
    }
  }

  /// 只查本地，不联网 —— 给「离线库」列表、播放前的快速判断用。
  static Future<File?> localFileOf(String key, {String title = ''}) =>
      _localFile(key, title);

  static Future<List<File>?> localPagesOf(String key, {String title = ''}) =>
      _localPages(key, title);

  // ─────────────────────────── 内部 ───────────────────────────

  static Future<File?> _localFile(String key, String title) async {
    try {
      final f = await MediaOfflineStore.localFileOf(key, title: title);
      if (f == null) return null;
      if (!await f.exists()) return null;
      // 0 字节 / 未下完的壳子不算命中（见 minLocalBytes 注释）。
      final len = await f.length();
      if (len < minLocalBytes) return null;
      return f;
    } catch (_) {
      return null;
    }
  }

  static Future<List<File>?> _localPages(String key, String title) async {
    try {
      final fs = await MediaOfflineStore.localPagesOf(key, title: title);
      if (fs.isEmpty) return null;
      return fs;
    } catch (_) {
      return null;
    }
  }

  static Future<PlaySource> _runOnline(
      Future<OnlineUrl?> Function() online, Duration timeout) async {
    try {
      final r = await online().timeout(timeout);
      final url = (r?.url ?? '').trim();
      if (url.isEmpty) {
        return PlaySource._(
          origin: r?.origin ?? PlayOrigin.backend,
          fail: PlayFail.noSource,
          error: r?.hint ?? '源站没有给出播放地址（源可能已失效）',
        );
      }
      return PlaySource._(origin: r?.origin ?? PlayOrigin.backend, url: url);
    } catch (e) {
      return _fail(e, hasLocal: false);
    }
  }

  /// 把异常翻译成「用户能照着做点什么」的话。
  static PlaySource _fail(Object e, {required bool hasLocal}) {
    final s = '$e';
    final isNet = e is SocketException ||
        e is TimeoutException ||
        s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Handshake') ||
        s.contains('Failed host lookup') ||
        s.contains('Connection refused') ||
        s.contains('Connection reset') ||
        s.contains('timed out');

    if (isNet) {
      return PlaySource._(
        origin: PlayOrigin.backend,
        fail: PlayFail.offline,
        error: hasLocal
            ? '本地文件读取失败（$s）'
            : '连不上后端或源站 —— 这一项没有下载到本机，离线时无法播放。\n'
                '可以先在「我的 → 离线内容」里确认是否已下载。',
      );
    }
    return PlaySource._(
      origin: PlayOrigin.backend,
      fail: PlayFail.unknown,
      error: s,
    );
  }
}

/// [PlayResolver.media] 的联网结果：地址 + 它是从哪一层拿到的。
class OnlineUrl {
  final String url;
  final PlayOrigin origin;

  /// 拿不到地址时给用户的额外说明（如「需要 DASH」「源已失效」）。
  final String? hint;

  const OnlineUrl(this.url, {this.origin = PlayOrigin.backend, this.hint});
}

/// [PlayResolver.comicPages] 的联网结果。
class OnlinePages {
  final List<String> pages;
  final PlayOrigin origin;
  final String? hint;

  const OnlinePages(this.pages, {this.origin = PlayOrigin.backend, this.hint});
}
