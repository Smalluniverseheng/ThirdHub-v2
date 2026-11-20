// 统一的媒体描述模型。
//
// 为什么需要它：本项目此前有 9 套播放器（VideoPlayPage / LocalVideoPlayerPage /
// UrlVideoPlayer / _ShortPlayer / _CinemaPlayer / _VideoPlayerPage / _MPlay /
// _BiliPlayerPage ...），每套各自定义参数，导致「同一个视频在影视板块能播、
// 推到音乐模块就不会播」，生态根本连不起来。
//
// 本文件把「要播什么」抽象成 MediaSpec，「怎么播」交给 UnifiedPlayer。
// 任何模块想把内容交给播放器，只要构造一个 MediaSpec，不再关心播放器实现。
import 'media_probe.dart';

/// 播放形态。判定见 [MediaKind.of]。
enum MediaKind {
  /// 有画面：影视、短视频、本地视频、B 站视频
  video,

  /// 只有声音：音乐、播客、有声书、TTS
  audio,
}

/// 一条可播放的媒体。
///
/// 设计原则：**不可变**（全 final），由各模块构造后交给播放器，
/// 播放器内部状态自己管。避免"改了一个字段导致别处在用旧值"。
class MediaSpec {
  /// 实际播放地址。支持 http(s) 直链、Range 分片、m3u8、本地 file:// 或绝对路径。
  final String url;

  final String title;

  /// 播放形态。默认按扩展名自动判定（见 [MediaKind] 与 media_probe.dart）。
  final MediaKind? kindOverride;

  /// 封面。音频模式下是主视觉，视频模式下用于加载前的占位。
  final String? cover;

  /// 附加请求头（Referer / User-Agent 等，部分源站强校验）。
  final Map<String, String> headers;

  /// 音频模式显示用。
  final String? artist;
  final String? album;

  /// 非空时挂弹幕层（B 站 cid）。需要 [apiBase] + [token] 才能拉取。
  final String? danmakuCid;
  final String? apiBase;
  final String? token;

  /// 从第几秒开始播（续播）。
  final Duration? startAt;

  /// 播放队列（影视多集 / 歌单）。播放器用它实现"下一集/上一集"。
  final List<MediaSpec> queue;
  final int index;

  /// 是否允许切到「只听」模式。
  /// 视频默认允许 —— 这正是生态互通的关键：B 站上的纯音乐视频，
  /// 用户在视频页听一遍，可以直接"只听音频"丢进音乐语境继续放。
  final bool allowAudioMode;

  /// 内容来源标识（板块/源名），用于播放历史与"从哪来"的展示。
  final String sourceTag;

  const MediaSpec({
    required this.url,
    required this.title,
    this.kindOverride,
    this.cover,
    this.headers = const {},
    this.artist,
    this.album,
    this.danmakuCid,
    this.apiBase,
    this.token,
    this.startAt,
    this.queue = const [],
    this.index = 0,
    this.allowAudioMode = true,
    this.sourceTag = '',
  });

  /// 最终的播放形态。
  MediaKind get kind => kindOverride ?? MediaProbe.kindOf(url, headers: headers);

  /// 当前队列里的下一条（无则 null）。
  MediaSpec? get next =>
      (index + 1 < queue.length) ? queue[index + 1] : null;

  /// 当前队列里的上一条（无则 null）。
  MediaSpec? get prev => (index > 0) ? queue[index - 1] : null;

  MediaSpec copyWith({
    String? url,
    String? title,
    MediaKind? kindOverride,
    String? cover,
    Map<String, String>? headers,
    String? artist,
    String? album,
    String? danmakuCid,
    String? apiBase,
    String? token,
    Duration? startAt,
    List<MediaSpec>? queue,
    int? index,
    bool? allowAudioMode,
    String? sourceTag,
  }) =>
      MediaSpec(
        url: url ?? this.url,
        title: title ?? this.title,
        kindOverride: kindOverride ?? this.kindOverride,
        cover: cover ?? this.cover,
        headers: headers ?? this.headers,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        danmakuCid: danmakuCid ?? this.danmakuCid,
        apiBase: apiBase ?? this.apiBase,
        token: token ?? this.token,
        startAt: startAt ?? this.startAt,
        queue: queue ?? this.queue,
        index: index ?? this.index,
        allowAudioMode: allowAudioMode ?? this.allowAudioMode,
        sourceTag: sourceTag ?? this.sourceTag,
      );
}
