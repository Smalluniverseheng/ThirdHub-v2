// 可播放的开放源：Audius / 播客(iTunes+RSS) / 网络电台 / PeerTube。
//
// 全部为**公网正规接口、无需 key、无需后端**，实测国内网络可达（2026-11-20）：
//   · Audius     完整 MP3（audio/mpeg，Range 206）
//   · Podcast    完整 m4a（故事FM RSS 2.9MB → audio/mp4 206）
//   · Radio      直播 AAC/MP3 流（audio/aac 206）
//   · PeerTube   fMP4 直链（video/mp4 206）
//
// 为什么选这几个而不是"再抓一批源站"：
// 本项目的后端跑的是 JS 源脚本（MusicFree/Venera/drpy/TVBox），App 内无法执行，
// 所以"脱离后端"只能走**有公开文档的 API**。上面这些恰好都有，且内容合法。
import 'dart:convert';

import 'free_http.dart';
import 'free_models.dart';

/// 秒 → `12:34` / `1:02:03`
String fmtDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

// ─────────────────────────────────────────────────────────────
// Audius —— 去中心化音乐平台，公开 API，给的是**完整曲目**而不是 30 秒试听
// ─────────────────────────────────────────────────────────────
class AudiusSource {
  AudiusSource._();

  static const String id = 'audius';
  static const String name = 'Audius 音乐';
  static const String note = '去中心化音乐平台，完整曲目，公开接口无需登录';
  static const String pingUrl = 'https://api.audius.co/';
  static const String app = 'ThirdHub';

  /// 主节点。若挂掉，[_fallbackHost] 会从 api.audius.co 的列表里换一个。
  static const String _primary = 'https://discoveryprovider.audius.co';
  static String? _activeHost;

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.music, pingUrl: pingUrl);

  static Future<String> _host() async {
    if (_activeHost != null) return _activeHost!;
    try {
      final d = await FreeHttp.json('https://api.audius.co/',
          timeout: const Duration(seconds: 8));
      final list = (d['data'] as List?)?.cast<dynamic>() ?? const [];
      final first = list.isNotEmpty ? '${list.first}'.replaceAll(RegExp(r'/$'), '') : '';
      _activeHost = first.isNotEmpty ? first : _primary;
    } catch (_) {
      _activeHost = _primary;
    }
    return _activeHost!;
  }

  /// 榜单（无关键词时的首屏）。
  static Future<List<FreeItem>> trending({int limit = 24}) async {
    final host = await _host();
    final d = await FreeHttp.json('$host/v1/tracks/trending',
        query: {'app_name': app, 'limit': '$limit'});
    return _map(d['data']);
  }

  /// 搜索曲目。
  static Future<List<FreeItem>> search(String q, {int limit = 24}) async {
    final host = await _host();
    final d = await FreeHttp.json('$host/v1/tracks/search',
        query: {'query': q, 'app_name': app, 'limit': '$limit'});
    return _map(d['data']);
  }

  /// 播放地址。Audius 的 stream 端点会 302 到 CDN，播放器能跟随。
  static String streamUrl(String trackId) =>
      '${_activeHost ?? _primary}/v1/tracks/$trackId/stream?app_name=$app';

  static List<FreeItem> _map(dynamic data) {
    final out = <FreeItem>[];
    for (final t in (data as List? ?? const [])) {
      if (t is! Map) continue;
      final m = Map<String, dynamic>.from(t);
      final trackId = '${m['id'] ?? ''}';
      if (trackId.isEmpty) continue;
      final art = m['artwork'];
      String cover = '';
      if (art is Map) {
        cover = '${art['480x480'] ?? art['150x150'] ?? ''}';
      }
      final user = m['user'];
      final artist = user is Map ? '${user['name'] ?? ''}' : '';
      final dur = (m['duration'] as num?)?.toInt() ?? 0;
      out.add(FreeItem(
        id: trackId,
        source: id,
        kind: FreeKind.music,
        title: '${m['title'] ?? ''}',
        subtitle: [
          if (artist.isNotEmpty) artist,
          if (dur > 0) fmtDuration(dur),
          if ('${m['genre'] ?? ''}'.isNotEmpty) '${m['genre']}',
        ].join(' · '),
        cover: cover,
        playUrl: streamUrl(trackId),
        raw: m,
      ));
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────
// 播客 —— iTunes Search 只做「找节目」，音频走节目自己的 RSS（完整单集，不是试听）
// ─────────────────────────────────────────────────────────────
class PodcastSource {
  PodcastSource._();

  static const String id = 'podcast';
  static const String name = '播客';
  static const String note = 'iTunes 目录检索，音频来自节目自身 RSS，完整单集';
  static const String pingUrl =
      'https://itunes.apple.com/search?term=podcast&media=podcast&limit=1';

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.podcast, pingUrl: pingUrl);

  /// 搜节目。返回项 `drill = true`，点进去加载单集。
  static Future<List<FreeItem>> search(String q, {int limit = 20}) async {
    final d = await FreeHttp.json('https://itunes.apple.com/search', query: {
      'term': q,
      'media': 'podcast',
      'entity': 'podcast',
      'limit': '$limit',
      'country': 'CN',
    });
    final out = <FreeItem>[];
    for (final r in (d['results'] as List? ?? const [])) {
      if (r is! Map) continue;
      final m = Map<String, dynamic>.from(r);
      final feed = '${m['feedUrl'] ?? ''}';
      if (feed.isEmpty) continue;
      out.add(FreeItem(
        id: '${m['collectionId'] ?? feed}',
        source: id,
        kind: FreeKind.podcast,
        title: '${m['collectionName'] ?? ''}',
        subtitle: [
          if ('${m['artistName'] ?? ''}'.isNotEmpty) '${m['artistName']}',
          if ((m['trackCount'] as num?) != null)
            '${(m['trackCount'] as num).toInt()} 集',
        ].join(' · '),
        cover: '${m['artworkUrl600'] ?? m['artworkUrl100'] ?? ''}',
        desc: '${m['collectionCensoredName'] ?? ''}',
        drill: true,
        raw: {
          'feedUrl': feed,
          'cover': '${m['artworkUrl600'] ?? m['artworkUrl100'] ?? ''}',
        },
      ));
    }
    return out;
  }

  /// 拉 RSS 取单集。
  ///
  /// 为什么自己解析 XML 而不引 xml 包：本项目多次因为 pubspec 增删把 CI 搞红，
  /// 而这里只需要 item/title/enclosure 三个字段，正则足够且没有依赖风险。
  static Future<List<FreeItem>> episodes(FreeItem show,
      {int limit = 60}) async {
    final feed = '${show.raw['feedUrl'] ?? ''}';
    if (feed.isEmpty) return const [];
    final xml = await FreeHttp.text(feed,
        timeout: const Duration(seconds: 25), maxBytes: 24 * 1024 * 1024);
    return parseRss(xml, show: show, limit: limit);
  }

  /// 纯函数，便于自检。
  static List<FreeItem> parseRss(String xml,
      {required FreeItem show, int limit = 60}) {
    final out = <FreeItem>[];
    final blocks = RegExp(r'<item[\s>][\s\S]*?</item>', caseSensitive: false)
        .allMatches(xml);
    for (final b in blocks) {
      if (out.length >= limit) break;
      final x = b.group(0) ?? '';
      final title = _tag(x, 'title');
      var url = _enclosureUrl(x);
      if (url.isEmpty) continue;
      final dur = _tag(x, 'itunes:duration');
      final pub = _tag(x, 'pubDate');
      final desc = _tag(x, 'description').isNotEmpty
          ? _tag(x, 'description')
          : _tag(x, 'itunes:summary');
      out.add(FreeItem(
        id: url,
        source: id,
        kind: FreeKind.podcast,
        title: title.isEmpty ? show.displayTitle : title,
        subtitle: [
          if (show.displayTitle.isNotEmpty) show.displayTitle,
          if (pub.isNotEmpty) _shortDate(pub),
          if (dur.isNotEmpty) dur,
        ].join(' · '),
        cover: '${show.raw['cover'] ?? show.cover}',
        desc: stripHtml(desc),
        playUrl: url,
        raw: {'feedTitle': show.displayTitle},
      ));
    }
    return out;
  }

  static String _enclosureUrl(String item) {
    final enc = RegExp(r'<enclosure[^>]*>', caseSensitive: false).firstMatch(item);
    if (enc != null) {
      // ★raw string 里不能转义引号（`r'\''` 会在引号处直接截断），
      //   所以这里的引号字符一律用三引号 raw 包住：同时容纳 " 与 '。
      final u = RegExp(r'''url\s*=\s*["']([^"']+)["']''')
          .firstMatch(enc.group(0)!);
      if (u != null) return u.group(1)!.trim();
    }
    final mc = RegExp(r'''<media:content[^>]*url\s*=\s*["']([^"']+)["']''',
            caseSensitive: false)
        .firstMatch(item);
    return mc?.group(1)?.trim() ?? '';
  }

  static String _tag(String xml, String tag) {
    final m = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>', caseSensitive: false)
        .firstMatch(xml);
    if (m == null) return '';
    return stripHtml(_cdata(m.group(1) ?? '')).trim();
  }

  static String _cdata(String s) {
    final m = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(s);
    return m != null ? m.group(1)! : s;
  }

  /// RSS 的 pubDate 是 RFC822，整串太长，只留 `MM-DD`。
  static String _shortDate(String pub) {
    final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})').firstMatch(pub);
    if (m != null) return '${m.group(2)} ${m.group(1)}';
    return pub.length > 10 ? pub.substring(0, 10) : pub;
  }
}

// ─────────────────────────────────────────────────────────────
// 网络电台 —— radio-browser 是开源公益目录（5 万+ 台），直接给可播流地址
// ─────────────────────────────────────────────────────────────
class RadioSource {
  RadioSource._();

  static const String id = 'radio';
  static const String name = '网络电台';
  static const String note = 'radio-browser 公共目录，直播流，无需登录';
  static const String pingUrl =
      'https://de1.api.radio-browser.info/json/stations/topclick/1';

  /// 多个镜像：国内访问公共镜像会有抖动，任一可用即可。
  static const List<String> _mirrors = [
    'https://de1.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
    'https://at1.api.radio-browser.info',
  ];

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.radio, pingUrl: pingUrl);

  /// 热门台（无关键词时）。
  static Future<List<FreeItem>> top({int limit = 30}) =>
      _fetch('/json/stations/topclick/$limit');

  static Future<List<FreeItem>> search(String q, {int limit = 30}) =>
      _fetch('/json/stations/search', query: {
        'name': q,
        'limit': '$limit',
        'hidebroken': 'true',
        'order': 'clickcount',
        'reverse': 'true',
      });

  static Future<List<FreeItem>> _fetch(String path,
      {Map<String, String>? query}) async {
    FreeNetException? last;
    for (final m in _mirrors) {
      try {
        final d = await FreeHttp.jsonAny('$m$path', query: query);
        return _map(d);
      } on FreeNetException catch (e) {
        last = e;
        // 只有网络层的问题才换镜像；格式错误换镜像也没用。
        if (!e.offline) rethrow;
      }
    }
    throw last ?? const FreeNetException('电台目录不可达', offline: true);
  }

  static List<FreeItem> _map(dynamic data) {
    final out = <FreeItem>[];
    for (final s in (data as List? ?? const [])) {
      if (s is! Map) continue;
      final m = Map<String, dynamic>.from(s);
      final url = '${m['url_resolved'] ?? m['url'] ?? ''}';
      if (url.isEmpty) continue;
      final codec = '${m['codec'] ?? ''}';
      final bitrate = (m['bitrate'] as num?)?.toInt() ?? 0;
      out.add(FreeItem(
        id: '${m['stationuuid'] ?? url}',
        source: id,
        kind: FreeKind.radio,
        title: '${m['name'] ?? ''}'.trim(),
        subtitle: [
          if ('${m['country'] ?? ''}'.isNotEmpty) '${m['country']}',
          if (codec.isNotEmpty) codec.toUpperCase(),
          if (bitrate > 0) '${bitrate}kbps',
        ].join(' · '),
        cover: '${m['favicon'] ?? ''}',
        desc: '${m['tags'] ?? ''}',
        playUrl: url,
        raw: m,
      ));
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────
// PeerTube —— 去中心化视频平台（ActivityPub），每个实例都有公开 API
// ─────────────────────────────────────────────────────────────
class PeerTubeSource {
  PeerTubeSource._();

  static const String id = 'peertube';
  static const String name = 'PeerTube';
  static const String note = '去中心化视频平台，公开实例接口，可直连 mp4';
  static const String pingUrl = 'https://framatube.org/api/v1/videos?count=1';

  /// 默认实例几个。任何一个可用就行；用户也可在页面里换。
  /// （实测 framatube 国内可直连，取到的 fMP4 是 video/mp4。）
  static const List<String> instances = [
    'https://framatube.org',
    'https://tilvids.com',
    'https://video.blender.org',
  ];

  static const FreeSource source = FreeSource(
      id: id, name: name, note: note, kind: FreeKind.video, pingUrl: pingUrl);

  static Future<List<FreeItem>> search(String q,
      {String? host, int limit = 20}) async {
    final h = (host ?? instances.first).replaceAll(RegExp(r'/$'), '');
    final d = await FreeHttp.json('$h/api/v1/search/videos',
        query: {'search': q, 'count': '$limit'});
    return _map(d['data'], h);
  }

  static Future<List<FreeItem>> latest({String? host, int limit = 20}) async {
    final h = (host ?? instances.first).replaceAll(RegExp(r'/$'), '');
    final d = await FreeHttp.json('$h/api/v1/videos',
        query: {'count': '$limit', 'sort': '-publishedAt'});
    return _map(d['data'], h);
  }

  /// 列表接口往往不给 `files`（只有 HLS 的实例是空数组），
  /// 必须再取一次详情才能拿到直链 —— 这是 PeerTube API 的实际行为。
  static Future<String> playUrl(String uuid, {String? host}) async {
    final h = (host ?? instances.first).replaceAll(RegExp(r'/$'), '');
    final d = await FreeHttp.json('$h/api/v1/videos/$uuid');
    final direct = _firstFileUrl(d);
    if (direct.isNotEmpty) return direct;
    throw const FreeNetException('该实例没有提供直链（可能只允许在线播放）');
  }

  static String _firstFileUrl(Map<String, dynamic> d) {
    final files = d['files'];
    if (files is List && files.isNotEmpty) {
      final f = files.first;
      if (f is Map && '${f['fileUrl'] ?? ''}'.isNotEmpty) return '${f['fileUrl']}';
    }
    final hls = d['streamingPlaylists'];
    if (hls is List && hls.isNotEmpty) {
      final p = hls.first;
      if (p is Map) {
        final fs = p['files'];
        if (fs is List && fs.isNotEmpty) {
          final f = fs.first;
          if (f is Map && '${f['fileUrl'] ?? ''}'.isNotEmpty) {
            return '${f['fileUrl']}';
          }
        }
        // 最后退回 playlist 地址（播放器支持 m3u8）。
        if ('${p['playlistUrl'] ?? ''}'.isNotEmpty) return '${p['playlistUrl']}';
      }
    }
    return '';
  }

  static List<FreeItem> _map(dynamic data, String host) {
    final out = <FreeItem>[];
    for (final v in (data as List? ?? const [])) {
      if (v is! Map) continue;
      final m = Map<String, dynamic>.from(v);
      final uuid = '${m['uuid'] ?? m['shortUUID'] ?? ''}';
      if (uuid.isEmpty) continue;
      String thumb = '${m['thumbnailPath'] ?? m['previewPath'] ?? ''}';
      if (thumb.isNotEmpty && thumb.startsWith('/')) thumb = '$host$thumb';
      final dur = (m['duration'] as num?)?.toInt() ?? 0;
      final chan = m['channel'];
      out.add(FreeItem(
        id: uuid,
        source: id,
        kind: FreeKind.video,
        title: '${m['name'] ?? ''}',
        subtitle: [
          if (chan is Map && '${chan['displayName'] ?? ''}'.isNotEmpty)
            '${chan['displayName']}',
          if (dur > 0) fmtDuration(dur),
          Uri.tryParse(host)?.host ?? '',
        ].join(' · '),
        cover: thumb,
        desc: stripHtml('${m['description'] ?? ''}'),
        drill: false,
        raw: {...m, 'host': host, 'directUrl': _firstFileUrl(m)},
      ));
    }
    return out;
  }
}

/// 小工具：把 JSON 里可能为 null 的 Map 安全转成 Map<String,dynamic>。
Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// 小工具：把 JSON 里的数组安全取出来。
List<dynamic> asList(dynamic v) => v is List ? v : const [];

/// 便于调试时打印：把对象裁成前 n 个字符。
String briefJson(dynamic v, [int n = 200]) {
  final s = jsonEncode(v);
  return s.length > n ? '${s.substring(0, n)}…' : s;
}
