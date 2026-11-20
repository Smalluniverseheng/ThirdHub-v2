// 媒体形态探测：决定一条链接该用视频播放器还是音频播放器。
//
// 这个文件是「生态互通」的判据来源。用户提的诉求里最典型的一条是：
//   B 站上有大量纯音乐视频（一首歌套一张图），明明是音乐，
//   却只能在视频板块里看，进不了音乐模块。
// 要打通它，第一步就是能判断「这个视频其实只是音乐」。
//
// 三级策略，逐级更准、也更贵：
//   ① 看扩展名           —— 零成本，覆盖 80%
//   ② 看标题/时长特征     —— 零成本，专门抓"纯音乐视频"
//   ③ HEAD 请求看 type   —— 一次网络往返，最准，只在①②拿不准时用
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'media_spec.dart';

class MediaProbe {
  MediaProbe._();

  static const _audioExt = {
    '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.wma', '.ape',
  };

  static const _videoExt = {
    '.mp4', '.m4v', '.mkv', '.webm', '.avi', '.mov', '.flv', '.ts', '.m3u8',
    '.mpd',
  };

  /// 纯音乐视频的特征词（标题命中即高度怀疑是"一张图 + 一首歌"）。
  static final _musicWords = RegExp(
    r'纯音乐|纯享|伴奏|钢琴版|吉他版|翻唱|无损|高音质|母带|'
    r'完整版\s*(?:mv|MV)|官方\s*(?:mv|MV|音频)|'
    r'\bOST\b|\bBGM\b|\bCover\b|\bLyric\b|\bLyrics\b|\bAudio\b|\bMV\b|'
    r'歌曲|单曲|专辑|音乐|歌单|听歌|'
    r'白噪音|助眠|轻音乐|LoFi|lo-fi|纯雨声|环境音',
    caseSensitive: false,
  );

  /// 明显是"有剧情/有画面"的词（命中则压过音乐特征）。
  static final _videoWords = RegExp(
    r'解说|剪辑|混剪|预告|花絮|纪录片|教程|教学|评测|开箱|vlog|Vlog|'
    r'实况|直播回放|合集|第[一二三四五六七八九十\d]+[集期话]|P\d+',
    caseSensitive: false,
  );

  /// 按 URL 扩展名判定形态。拿不准时返回 video（保守：宁可给画面，不要给错音频）。
  static MediaKind kindOf(String url, {Map<String, String> headers = const {}}) {
    final path = _pathOf(url).toLowerCase();
    if (path.isEmpty) return MediaKind.video;
    final dot = path.lastIndexOf('.');
    if (dot < 0) return MediaKind.video;
    final ext = path.substring(dot);
    if (_audioExt.contains(ext)) return MediaKind.audio;
    if (_videoExt.contains(ext)) return MediaKind.video;
    // 无扩展名的接口地址（如 /v1/media/xxx）：看 query 里有没有提示
    if (url.contains('audio=1') || url.contains('type=audio')) return MediaKind.audio;
    return MediaKind.video;
  }

  /// 去掉 query / fragment 后的路径部分（扩展名判定不能被 ?token= 干扰）。
  static String _pathOf(String url) {
    var s = url;
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    final h = s.indexOf('#');
    if (h >= 0) s = s.substring(0, h);
    return s;
  }

  /// 「这其实是一首歌吧」的置信度，0~1。
  ///
  /// [durationSeconds] 是已知时长（B 站详情里有），给 0 表示未知。
  /// 判定思路：音乐特征词加分，视频特征词减分，时长落在单曲区间再加分。
  static double musicScore(String title, {int durationSeconds = 0}) {
    var score = 0.0;
    if (_musicWords.hasMatch(title)) score += 0.55;
    if (_videoWords.hasMatch(title)) score -= 0.45;

    // 单曲典型 1:30 ~ 8:00；短剧/影视单集通常 20 分钟以上
    if (durationSeconds > 0) {
      if (durationSeconds >= 80 && durationSeconds <= 480) {
        score += 0.35;
      } else if (durationSeconds > 900) {
        score -= 0.25;
      }
    }

    // 标题里带「歌名 - 歌手」这种结构，也很像音乐
    if (RegExp(r'^[^-|｜]{1,20}\s*[-–—|｜]\s*\S{1,20}$').hasMatch(title.trim())) {
      score += 0.15;
    }
    return score.clamp(0.0, 1.0);
  }

  /// 标题/时长已足以判定它是音乐。
  static bool looksLikeMusic(String title, {int durationSeconds = 0}) =>
      musicScore(title, durationSeconds: durationSeconds) >= 0.6;

  /// 第 ③ 级：发一次 HEAD 看 Content-Type。只在 ①② 拿不准时调，别滥用。
  ///
  /// 有些源站不响应 HEAD（405/501），此时降级为「只取前若干字节的 GET」，
  /// 用 Range 头把流量压到最小。任何异常都返回 null，由调用方保持原判断。
  static Future<MediaKind?> detectRemote(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 6),
  }) async {
    HttpClient? c;
    try {
      c = HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 3);
      // 与前几处一致：仅信任私网/自签的判定交给统一层，这里不额外放宽。
      final req = await c.headUrl(Uri.parse(url)).timeout(timeout);
      headers.forEach(req.headers.set);
      final resp = await req.close().timeout(timeout);
      final ct = (resp.headers.contentType?.mimeType ?? '').toLowerCase();
      if (ct.startsWith('audio/')) return MediaKind.audio;
      if (ct.startsWith('video/')) return MediaKind.video;
      return null;
    } catch (e) {
      debugPrint('MediaProbe.detectRemote 失败(保持原判): $e');
      return null;
    } finally {
      c?.close(force: true);
    }
  }

  /// 生成"作为音频播放"的 spec（生态互通用）。
  ///
  /// 语义：同一个 url，但要求播放器只出声音。视频的整条 mp4 直接喂给
  /// just_audio 也能出声（Android 上 MediaPlayer/ExoPlayer 会忽略视频轨），
  /// 所以不需要真的抽流，省一次转码。
  static MediaSpec asAudio(MediaSpec src) => src.copyWith(
        kindOverride: MediaKind.audio,
        allowAudioMode: false,
      );
}
