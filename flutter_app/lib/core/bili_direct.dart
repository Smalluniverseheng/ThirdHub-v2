// 直连 B 站（4.81.97 重写）
//
// 目的：后端（NAS）连不上时，App 也能浏览/搜索/看详情/看评论/看弹幕/看直播/看番剧。
// 做法：把后端那套 /v1/bili/* 语义在端内重放一遍，返回**与后端一致的结构**，
//       上层页面完全不用改。
//
// 4.81.96 之前「B站看着有界面、点进去空白」的三个真实原因（都修在这里）：
//   ① 推荐/搜索/播放/空间等接口要 WBI 签名（w_rid+wts），不带签名 -352/-412；
//   ② 弹幕接口返回 raw deflate 压缩二进制，之前直接 utf8 解码 → 0 条；
//   ③ 缺 buvid3/buvid4 匿名指纹，风控命中率高。
//
// 注意：下载（bilidown）只有后端有，直连模式下不可用。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bili_auth.dart' show BiliAuth;
import 'bili_wbi.dart' show BiliWbi;
import 'bili_social.dart'
    show fetchFavFolders, fetchFavList, fetchSpaceInfo, fetchSpaceVideos;
import 'bili_subtitle_parser.dart' show parseSubtitle;

const String biliUA =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const String biliReferer = 'https://www.bilibili.com/';

/// live 域请求
Future<Map<String, dynamic>> _live(String path) async {
  try {
    final r = await http.get(Uri.parse('https://api.live.bilibili.com$path'),
        headers: {
          'user-agent': biliUA,
          'referer': 'https://live.bilibili.com/',
        }).timeout(const Duration(seconds: 20));
    final j = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
    if (j is Map) return Map<String, dynamic>.from(j);
  } catch (_) {}
  return <String, dynamic>{};
}

String _https(Object? u) {
  var s = '${u ?? ''}'.trim();
  if (s.isEmpty) return '';
  if (s.startsWith('//')) s = 'https:$s';
  if (s.startsWith('http://')) s = s.replaceFirst('http://', 'https://');
  return s;
}

/// 统一的视频条目映射（与后端 feedItem 同构）
Map<String, dynamic> _mapItem(Map<String, dynamic> v) {
  final stat = (v['stat'] as Map?) ?? const {};
  final owner = (v['owner'] as Map?) ?? const {};
  final dur = v['duration'];
  return <String, dynamic>{
    'bvid': '${v['bvid'] ?? v['id'] ?? ''}',
    'title': '${v['title'] ?? ''}'.replaceAll(RegExp(r'</?em[^>]*>'), ''),
    'cover': _https(v['pic'] ?? v['cover']),
    'owner': '${owner['name'] ?? v['author'] ?? v['uname'] ?? ''}',
    'play': stat['view'] ?? v['play'] ?? v['video_review'] ?? 0,
    'danmaku': stat['danmaku'] ?? v['video_review'] ?? v['danmaku'] ?? 0,
    'duration': dur is num ? dur.toInt() : _durFromText('${v['duration'] ?? ''}'),
    'desc': '${v['desc'] ?? ''}',
    if (v['pubdate'] != null) 'pubdate': v['pubdate'],
    if (v['cid'] != null) 'cid': v['cid'],
  };
}

int _durFromText(String s) {
  final parts = s
      .split(':')
      .where((e) => e.isNotEmpty)
      .map((e) => int.tryParse(e) ?? 0)
      .toList();
  if (parts.isEmpty) return 0;
  if (parts.length == 2) return parts[0] * 60 + parts[1];
  if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  return 0;
}

List<Map<String, dynamic>> _mapList(Object? raw) {
  final list = (raw is List) ? raw : const [];
  return list
      .whereType<Map>()
      .map((e) => _mapItem(Map<String, dynamic>.from(e)))
      .where((e) => '${e['bvid']}'.startsWith('BV'))
      .toList(growable: false);
}

/// 分区表（B站 web 侧 rid；直连时无需请求，服务端也是常量）
const List<Map<String, dynamic>> biliPartitions = [
  {'rid': 1, 'name': '动画', 'icon': ''},
  {'rid': 13, 'name': '番剧', 'icon': ''},
  {'rid': 167, 'name': '国创', 'icon': ''},
  {'rid': 3, 'name': '音乐', 'icon': ''},
  {'rid': 129, 'name': '舞蹈', 'icon': ''},
  {'rid': 4, 'name': '游戏', 'icon': ''},
  {'rid': 36, 'name': '知识', 'icon': ''},
  {'rid': 188, 'name': '科技', 'icon': ''},
  {'rid': 234, 'name': '运动', 'icon': ''},
  {'rid': 223, 'name': '汽车', 'icon': ''},
  {'rid': 160, 'name': '生活', 'icon': ''},
  {'rid': 211, 'name': '美食', 'icon': ''},
  {'rid': 217, 'name': '动物', 'icon': ''},
  {'rid': 119, 'name': '鬼畜', 'icon': ''},
  {'rid': 155, 'name': '时尚', 'icon': ''},
  {'rid': 5, 'name': '娱乐', 'icon': ''},
  {'rid': 181, 'name': '影视', 'icon': ''},
  {'rid': 11, 'name': '电视剧', 'icon': ''},
  {'rid': 23, 'name': '电影', 'icon': ''},
  {'rid': 177, 'name': '纪录片', 'icon': ''},
];

/// 从任意输入里抽 bvid（支持 BV 号、av 号、完整链接、b23 短链内容）
String? parseBvid(String input) {
  final s = input.trim();
  final bv = RegExp(r'(BV1[0-9A-Za-z]{9})').firstMatch(s);
  if (bv != null) return bv.group(1);
  final av = RegExp(r'av(\d+)', caseSensitive: false).firstMatch(s);
  if (av != null) return 'av${av.group(1)}';
  return null;
}

/// 直连入口：传入后端同款路径，返回同款 JSON；不支持或失败返回 null。
Future<Map<String, dynamic>?> biliDirect(String path) async {
  try {
    await BiliWbi.I.ensureBuvid();
    final uri = Uri.parse('https://placeholder$path');
    final q = uri.queryParameters;
    final op = path.split('?').first.replaceFirst('/v1/bili', '');

    // ── 状态 ──────────────────────────────────────────
    if (op.isEmpty || op == '/status') {
      return {
        'ok': true,
        'login': BiliAuth.I.loggedIn,
        'name': BiliAuth.I.name,
        'downloadFolder': '',
        'base': '',
        'direct': true,
      };
    }
    if (op == '/logout') {
      await BiliAuth.I.logout();
      return {'ok': true};
    }
    if (op == '/qr') {
      final r = await BiliAuth.I.generate();
      if (r == null) return {'ok': false, 'error': '取二维码失败'};
      return {'ok': true, 'key': r.key, 'url': r.url};
    }
    if (op == '/qr/status') {
      final p = await BiliAuth.I.poll(q['key'] ?? '');
      return {
        'ok': true,
        'login': p.state == 'ok',
        'state': p.state,
        'message': p.message,
      };
    }
    // ── 收藏夹 / UP 主页（4.81.100）─────────────────────
    // 后端暂时没有这两组 op，直连是唯一通道；返回结构按后端同款约定，
    // 将来后端补上后上层页面无需改动。
    if (op == '/fav/folders') {
      return await fetchFavFolders(mid: q['mid']);
    }
    if (op == '/fav/list') {
      final pn = int.tryParse(q['pn'] ?? '1') ?? 1;
      return await fetchFavList(q['media_id'] ?? q['id'] ?? '', pn);
    }
    if (op == '/space/info') {
      return await fetchSpaceInfo(q['mid'] ?? '');
    }
    if (op == '/space/videos') {
      final pn = int.tryParse(q['pn'] ?? '1') ?? 1;
      return await fetchSpaceVideos(q['mid'] ?? '', pn);
    }

    if (op == '/partitions') {
      return {'ok': true, 'items': biliPartitions};
    }
    if (op == '/folders') {
      // 直连没有下载服务，给一个「本机下载」占位，界面不至于空
      return {
        'ok': true,
        'targets': [
          {'id': 'video', 'name': '影视'},
          {'id': 'music', 'name': '音乐'},
        ],
        'folder': 'video',
      };
    }
    if (op == '/tidy') return {'ok': true, 'moved': 0};

    // ── 解析链接（端内直接取详情）──────────────────────
    if (op == '/parse') {
      final raw = q['url'] ?? '';
      var bvid = parseBvid(raw);
      if (bvid == null && raw.contains('b23.tv')) {
        try {
          final r = await http.get(Uri.parse(_https(raw)),
              headers: BiliAuth.I.headers()).timeout(
                const Duration(seconds: 12),
              );
          bvid = parseBvid('${r.request?.url ?? ''}');
        } catch (_) {}
      }
      if (bvid == null) return {'ok': false, 'error': '没识别出视频号'};
      final v = await biliDirect('/v1/bili/view?bvid=$bvid');
      if (v == null || v['ok'] != true) return {'ok': false, 'error': '取详情失败'};
      final pages = (v['pages'] as List?) ?? const [];
      final first = pages.isNotEmpty ? (pages.first as Map) : const {};
      return {
        'ok': true,
        'bvid': v['bvid'],
        'aid': v['aid'],
        'cid': first['cid'] ?? v['cid'],
        'title': v['title'],
        'pic': v['pic'],
        'owner': v['owner'],
        'duration': v['duration'],
        'pages': pages,
      };
    }

    // ── 浏览：热门 / 推荐 / 排行榜 / 分区 ───────────────
    if (op == '/feed') {
      final type = q['type'] ?? 'popular';
      final pn = int.tryParse(q['pn'] ?? '1') ?? 1;
      if (type == 'recommend') {
        // 走 WBI 版 rcmd（无签名接口 2024 起大面积为 0/-352）
        final j = await BiliWbi.I.getWbi(
          '/x/web-interface/wbi/index/top/feed/rcmd',
          query: {
            'feed_version': 'V8',
            'fresh_type': '3',
            'ps': '12',
            'fresh_idx': '$pn',
            'fresh_idx_1h': '$pn',
            'brush': pn > 1 ? '1' : '0',
            'homepage_ver': '1',
            'uniq_id': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
          },
        );
        var items = _mapList((j['data'] as Map?)?['item']);
        if (items.isEmpty) {
          final j2 = await BiliWbi.I
              .getJson('/x/web-interface/popular?ps=20&pn=$pn');
          items = _mapList((j2['data'] as Map?)?['list']);
        }
        return {
          'ok': items.isNotEmpty,
          'items': items,
          'hasMore': true,
          if (items.isEmpty) 'error': '${j['message'] ?? '推荐为空'}',
        };
      }
      final j = await BiliWbi.I.getJson('/x/web-interface/popular?ps=20&pn=$pn');
      return {
        'ok': (j['code'] ?? -1) == 0,
        'code': j['code'],
        'items': _mapList((j['data'] as Map?)?['list']),
        'message': j['message'] ?? '',
      };
    }

    if (op == '/rank') {
      final rid = q['rid'] ?? '0';
      final j = await BiliWbi.I
          .getJson('/x/web-interface/ranking/v2?rid=$rid&type=all');
      return {
        'ok': (j['code'] ?? -1) == 0,
        'code': j['code'],
        'items': _mapList((j['data'] as Map?)?['list']),
        'message': j['message'] ?? '',
      };
    }

    if (op == '/region') {
      final rid = q['rid'] ?? '1';
      final pn = q['pn'] ?? '1';
      final ps = q['ps'] ?? '20';
      // newlist 免签名、比 dynamic/region 稳（后者已下线 -404）
      final j = await BiliWbi.I.getJson(
          '/x/web-interface/newlist?rid=$rid&ps=$ps&pn=$pn&type=0');
      var items = _mapList((j['data'] as Map?)?['archives']);
      if (items.isEmpty) {
        // 番剧/影视类 rid 走 pgc 分季
        final j2 = await BiliWbi.I.getJson(
            '/pgc/web/season/section?season_type=1&rid=$rid');
        final secs = (j2['data'] as List?) ?? const [];
        items = [];
        for (final s in secs.whereType<Map>()) {
          items.addAll(_mapList(s['episodes']));
        }
      }
      return {
        'ok': (j['code'] ?? -1) == 0,
        'code': j['code'],
        'items': items,
        'message': j['message'] ?? '',
      };
    }

    // ── 搜索 ──────────────────────────────────────────
    if (op == '/search') {
      final kw = q['q'] ?? '';
      final pn = q['pn'] ?? '1';
      final kind = q['type'] ?? 'video';
      if (kw.isEmpty) return {'ok': false, 'error': '缺少关键词'};
      final j = await BiliWbi.I.getWbi(
        '/x/web-interface/wbi/search/type',
        query: {
          'search_type': kind,
          'keyword': kw,
          'page': pn,
          if (kind == 'video') 'order': q['order'] ?? 'totalrank',
        },
      );
      var items = _mapList((j['data'] as Map?)?['result']);
      if (items.isEmpty) {
        // 签名失败时退到非 wbi 老接口（部分 CDN 仍放行）
        final j2 = await BiliWbi.I.getJson(
            '/x/web-interface/search/type?search_type=video&keyword=${Uri.encodeQueryComponent(kw)}&page=$pn');
        items = _mapList((j2['data'] as Map?)?['result']);
      }
      return {
        'ok': (j['code'] ?? -1) == 0,
        'code': j['code'],
        'items': items,
        'message': j['message'] ?? '',
      };
    }

    // ── 详情 ──────────────────────────────────────────
    if (op == '/view') {
      final bvid = q['bvid'] ?? '';
      var j = await BiliWbi.I.getJson('/x/web-interface/view?bvid=$bvid');
      if ((j['code'] ?? -1) != 0) {
        // 风控命中重试一次（buvid 已就绪）
        j = await BiliWbi.I.getJson('/x/web-interface/view?bvid=$bvid');
      }
      if ((j['code'] ?? -1) != 0) {
        return {'ok': false, 'code': j['code'], 'error': '${j['message'] ?? '取详情失败'}'};
      }
      final d = (j['data'] as Map?) ?? const {};
      final s = (d['stat'] as Map?) ?? const {};
      final owner = (d['owner'] as Map?) ?? const {};
      final pages = ((d['pages'] as List?) ?? const [])
          .whereType<Map>()
          .map((p) => {
                'cid': p['cid'],
                'page': p['page'],
                'part': p['part'] ?? '',
                'duration': p['duration'] ?? 0,
              })
          .toList();
      return {
        'ok': true,
        'bvid': '${d['bvid'] ?? bvid}',
        'aid': d['aid'],
        'cid': d['cid'],
        'title': '${d['title'] ?? ''}',
        'desc': '${d['desc'] ?? ''}',
        'pic': _https(d['pic']),
        'owner': {
          'name': '${owner['name'] ?? ''}',
          'face': _https(owner['face']),
          'mid': owner['mid'] ?? 0,
        },
        'stat': {
          'view': s['view'] ?? 0,
          'danmaku': s['danmaku'] ?? 0,
          'like': s['like'] ?? 0,
          'coin': s['coin'] ?? 0,
          'favorite': s['favorite'] ?? 0,
          'share': s['share'] ?? 0,
          'reply': s['reply'] ?? 0,
          'now_rank': s['now_rank'] ?? 0,
        },
        'pubdate': d['pubdate'] ?? 0,
        'duration': d['duration'] ?? 0,
        'videos': d['videos'] ?? 1,
        'pages': pages,
      };
    }

    if (op == '/pages') {
      final bvid = q['bvid'] ?? '';
      final j = await BiliWbi.I.getJson('/x/player/pagelist?bvid=$bvid');
      final list = ((j['data'] as List?) ?? const []).whereType<Map>().map((p) => {
            'cid': p['cid'],
            'page': p['page'],
            'part': p['part'] ?? '',
            'duration': p['duration'] ?? 0,
          }).toList();
      return {
        'ok': (j['code'] ?? -1) == 0 && list.isNotEmpty,
        'pages': list,
        'message': j['message'] ?? '',
      };
    }

    // ── 播放地址 ──────────────────────────────────────
    // 实测（2026-11-24）：fnval=1&qn=64&platform=html5 无 cookie 给 720p 有声 MP4；
    // 登录 + qn≥80 走 fnval=16&platform=web 拿 DASH（音视频分离，media_kit 外挂音轨）。
    if (op == '/playurl' || op == '/play') {
      final bvid = q['bvid'] ?? '';
      final cid = q['cid'] ?? '';
      final qn = int.tryParse(q['qn'] ?? '64') ?? 64;
      final loggedIn = BiliAuth.I.loggedIn;
      final hd = loggedIn && qn >= 80;

      Future<Map<String, dynamic>> hit(String fnval, String platform) =>
          BiliWbi.I.getWbi('/x/player/wbi/playurl', query: {
            'bvid': bvid,
            'cid': cid,
            'fnval': fnval,
            'qn': '$qn',
            'fourk': '1',
            'platform': platform,
          });

      var j = hd ? await hit('16', 'web') : await hit('1', 'html5');
      // 签名/风控失败时退回非 wbi 版（html5 通道对未登录更宽松）
      if ((j['code'] ?? -1) != 0) {
        j = await BiliWbi.I.getJson(hd
            ? '/x/player/playurl?bvid=$bvid&cid=$cid&fnval=16&qn=$qn&fourk=1&platform=web'
            : '/x/player/playurl?bvid=$bvid&cid=$cid&fnval=1&qn=$qn&platform=html5');
      }
      final d = (j['data'] as Map?) ?? const {};
      final dash = (d['dash'] as Map?) ?? const {};
      final vids = (dash['video'] as List?) ?? const [];
      final auds = (dash['audio'] as List?) ?? const [];

      String best = '';
      int bestId = -1;
      int bestCodec = 0;
      for (final v in vids.whereType<Map>()) {
        final id = (v['id'] is num) ? (v['id'] as num).toInt() : 0;
        final codec = '${v['codecs'] ?? ''}'.contains('avc') ? 1 : 0; // 优先 avc
        final url = _https(v['baseUrl'] ?? v['base_url']);
        if (url.isEmpty) continue;
        if (id > bestId || (id == bestId && codec > bestCodec)) {
          bestId = id;
          bestCodec = codec;
          best = url;
        }
      }
      String audioUrl = '';
      int abr = -1;
      for (final a in auds.whereType<Map>()) {
        final url = _https(a['baseUrl'] ?? a['base_url']);
        final br = (a['bandwidth'] is num) ? (a['bandwidth'] as num).toInt() : 0;
        if (url.isNotEmpty && br > abr) {
          abr = br;
          audioUrl = url;
        }
      }
      final isDash = best.isNotEmpty && audioUrl.isNotEmpty;
      if (best.isEmpty) {
        final durl = (d['durl'] as List?) ?? const [];
        if (durl.isNotEmpty && durl.first is Map) {
          best = _https((durl.first as Map)['url']);
        }
      }
      if (best.isEmpty) {
        return {
          'ok': false,
          'url': '',
          'error': '${j['message'] ?? '无可用播放地址'}',
          'needLoginForHd': !loggedIn && qn >= 80,
        };
      }
      final real = (d['quality'] is num) ? (d['quality'] as num).toInt() : bestId;
      final accept = d['acceptQuality'] ?? d['accept_quality'];
      final durl = (d['durl'] as List?) ?? const [];
      return {
        'ok': true,
        'url': best,
        'quality': real,
        'format': d['format'] ?? 'mp4',
        'size': (durl.isNotEmpty && durl.first is Map)
            ? ((durl.first as Map)['size'] ?? 0)
            : 0,
        'segments': durl.length,
        'cid': cid,
        'dash': isDash,
        if (isDash) 'audioUrl': audioUrl,
        if (accept is List && accept.isNotEmpty) 'acceptQuality': accept,
        // 直链校验 Referer/UA，播放器必须带
        'referer': biliReferer,
        'userAgent': biliUA,
        if (!loggedIn) 'needLoginForHd': true,
      };
    }

    // ── 弹幕 ──────────────────────────────────────────
    if (op == '/danmaku') {
      final cid = int.tryParse(q['cid'] ?? '') ?? 0;
      if (cid <= 0) return {'ok': false, 'error': '缺少 cid'};
      final xml = await BiliWbi.I.danmakuXml(cid);
      final items = <Map<String, dynamic>>[];
      if (xml.isNotEmpty) {
        final re = RegExp(r'<d p="([^"]*)"[^>]*>([\s\S]*?)</d>');
        for (final m in re.allMatches(xml)) {
          final p = (m.group(1) ?? '').split(',');
          if (p.isEmpty) continue;
          final text = (m.group(2) ?? '')
              .replaceAll('&amp;', '&')
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&quot;', '"')
              .replaceAll('&#39;', "'");
          if (text.isEmpty) continue;
          items.add({
            't': (double.tryParse(p[0]) ?? 0),
            'm': int.tryParse(p.length > 1 ? p[1] : '1') ?? 1,
            's': int.tryParse(p.length > 2 ? p[2] : '25') ?? 25,
            'c': int.tryParse(p.length > 3 ? p[3] : '16777215') ?? 16777215,
            'x': text.length > 80 ? text.substring(0, 80) : text,
          });
        }
      }
      items.sort((a, b) => (a['t'] as double).compareTo(b['t'] as double));
      return {
        'ok': items.isNotEmpty,
        'cid': cid,
        'total': items.length,
        'items': items,
        if (items.isEmpty) 'error': '这条视频还没人发弹幕，或弹幕接口暂时不可用',
      };
    }

    // ── 字幕 4.81.103 ──────────────────────────────────
    // B站 /x/player/v2 的 data.subtitle.subtitles[] = [{lan,lan_doc,subtitle_url}]
    // 未登录时通常为空（给出明确原因，不静默）；登录 cookie 下能拿到 AI/CC 字幕。
    // 字幕体在 CDN（//i0.hdslb.com/bfs/subtitle/*.json），要带 UA+Referer+cookie
    // 单独下载，且可能是 json（原生）/srt/ass 三态 —— 统一走 parseSubtitle。
    if (op == '/subtitle') {
      final bvid = q['bvid'] ?? '';
      final cid = q['cid'] ?? '';
      if (bvid.isEmpty) return {'ok': false, 'error': '缺少 bvid'};
      final j = await BiliWbi.I.getJson(
          '/x/player/v2?bvid=${Uri.encodeQueryComponent(bvid)}&cid=${Uri.encodeQueryComponent(cid)}');
      final subtitles = (((j['data'] as Map?)?['subtitle'] as Map?)?['subtitles'] as List?) ?? const [];
      final tracks = <Map<String, dynamic>>[];
      for (final raw in subtitles.whereType<Map>()) {
        final url = _https(raw['subtitle_url']);
        if (url.isEmpty) continue;
        // 字幕体可能与 B站 API 不同域，必须带登录态 headers 单独取
        List<int> bytes = const [];
        try {
          final r = await http.get(Uri.parse(url), headers: BiliAuth.I.headers())
              .timeout(const Duration(seconds: 20));
          bytes = r.bodyBytes;
        } catch (_) {}
        if (bytes.isEmpty) continue;
        String text;
        try {
          text = utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          continue;
        }
        final cues = parseSubtitle(text);
        if (cues.isEmpty) continue;
        tracks.add({
          'lan': '${raw['lan'] ?? ''}',
          'label': '${raw['lan_doc'] ?? raw['lan'] ?? '字幕'}',
          'url': url,
          'cues': cues,
        });
      }
      return {
        'ok': tracks.isNotEmpty,
        'tracks': tracks,
        if (tracks.isEmpty)
          'error': BiliAuth.I.loggedIn
              ? '这条视频没有可用字幕，或字幕暂时无法加载'
              : '登录后可以显示这条视频的字幕',
      };
    }

    // ── 评论（一级 + 二级）─────────────────────────────
    if (op == '/replies') {
      final bvid = q['bvid'] ?? '';
      final pn = q['pn'] ?? '1';
      final ps = q['ps'] ?? '20';
      final sort = q['sort'] ?? '2';
      final aid = q['aid'] ?? await _aidOf(bvid);
      if (aid == null) return {'ok': false, 'error': '取 aid 失败'};
      final j = await BiliWbi.I.getJson(
          '/x/v2/reply?type=1&oid=$aid&pn=$pn&ps=$ps&sort=$sort&nohot=0');
      final d = (j['data'] as Map?) ?? const {};
      final pg = (d['page'] as Map?) ?? const {};
      final raw = ((d['replies'] as List?) ?? (d['top_replies'] as List?) ?? const []);
      final items = raw.whereType<Map>().map(_mapReply).toList();
      return {
        'ok': (j['code'] ?? -1) == 0,
        'code': j['code'],
        'total': pg['count'] ?? 0,
        'pn': pg['num'] ?? pn,
        'size': pg['size'] ?? ps,
        'items': items,
        'message': j['message'] ?? '',
      };
    }

    // 二级评论（点「展开更多回复」）
    if (op == '/reply/reply') {
      final aid = q['aid'] ?? '';
      final root = q['root'] ?? '';
      final pn = q['pn'] ?? '1';
      final j = await BiliWbi.I.getJson(
          '/x/v2/reply/reply?type=1&oid=$aid&root=$root&pn=$pn&ps=20');
      final d = (j['data'] as Map?) ?? const {};
      final raw = (d['replies'] as List?) ?? const [];
      return {
        'ok': (j['code'] ?? -1) == 0,
        'items': raw.whereType<Map>().map(_mapReply).toList(),
      };
    }

    // ── 相关推荐 ──────────────────────────────────────
    if (op == '/related') {
      final bvid = q['bvid'] ?? '';
      final j = await BiliWbi.I
          .getJson('/x/web-interface/archive/related?bvid=$bvid');
      return {'ok': true, 'items': _mapList(j['data']).take(24).toList()};
    }

    // ── 直播 ──────────────────────────────────────────
    if (op == '/live') {
      final page = q['page'] ?? '1';
      final ps = q['ps'] ?? '20';
      // 新版 getList 要 wbi，旧版 recommend 免签名仍可用
      final j = await _live(
          '/room/v1/room/get_user_recommend?page=$page&page_size=$ps');
      final raw = (j['data'] is List) ? (j['data'] as List) : const [];
      final items = raw.whereType<Map>().map((v) {
        final ws = (v['watched_show'] as Map?) ?? const {};
        return <String, dynamic>{
          'roomId': v['roomid'] ?? 0,
          'title': '${v['title'] ?? ''}',
          'uname': '${v['uname'] ?? ''}',
          'face': _https(v['face']),
          'cover': _https(v['system_cover'] ?? v['user_cover'] ?? v['cover']),
          'online': v['online'] ?? 0,
          'watched': '${ws['text_large'] ?? ws['text_small'] ?? ''}',
          'area': '${v['areaName'] ?? ''}',
          'uid': v['uid'] ?? 0,
        };
      }).where((e) => (e['roomId'] as int) > 0).toList();
      return {
        'ok': items.isNotEmpty,
        'code': j['code'],
        'page': page,
        'items': items,
        'hasMore': items.length >= (int.tryParse(ps) ?? 20),
        'message': j['message'] ?? '',
      };
    }

    if (op == '/live/play') {
      final roomId = q['room_id'] ?? '';
      if (roomId.isEmpty) return {'ok': false, 'error': '缺少 room_id'};
      final j = await _live(
          '/xlive/web-room/v2/index/getRoomPlayInfo?room_id=$roomId&protocol=0,1&format=0,1,2&codec=0,1&qn=10000&platform=web&ptype=8');
      final dd = (j['data'] as Map?) ?? const {};
      final pd = (dd['playurl_info'] as Map?) ?? const {};
      if (pd.isEmpty) {
        return {
          'ok': false,
          'liveStatus': dd['live_status'] ?? 0,
          'error': (dd['live_status'] == 2) ? '主播还没开播' : '拿不到播放地址',
        };
      }
      final cands = <Map<String, dynamic>>[];
      for (final s in (((pd['playurl'] as Map?)?['stream'] as List?) ?? const []).whereType<Map>()) {
        final proto = '${s['protocol_name'] ?? ''}';
        for (final f in ((s['format'] as List?) ?? const []).whereType<Map>()) {
          final fmt = '${f['format_name'] ?? ''}';
          for (final c in ((f['codec'] as List?) ?? const []).whereType<Map>()) {
            final infos = ((c['url_info'] as List?) ?? const []).whereType<Map>();
            if (infos.isEmpty) continue;
            final first = infos.first;
            final host = '${first['host'] ?? ''}';
            final baseUrl = '${c['base_url'] ?? ''}';
            final extra = '${first['extra'] ?? ''}';
            final url = '$host$baseUrl$extra';
            if (url.isEmpty) continue;
            final codec = '${c['codec_name'] ?? ''}';
            var rank = 99;
            if (proto == 'http_hls' && fmt == 'fmp4' && codec == 'avc') {
              rank = 0;
            } else if (proto == 'http_hls' && fmt == 'ts' && codec == 'avc') {
              rank = 1;
            } else if (proto == 'http_stream' && fmt == 'flv' && codec == 'avc') {
              rank = 2;
            } else if (proto == 'http_hls' && fmt == 'fmp4') {
              rank = 3;
            } else if (proto == 'http_hls') {
              rank = 4;
            }
            cands.add({
              'rank': rank,
              'protocol': proto,
              'format': fmt,
              'codec': codec,
              'qn': c['current_qn'] ?? 0,
              'url': url,
            });
          }
        }
      }
      cands.sort((a, b) => (a['rank'] as int).compareTo(b['rank'] as int));
      if (cands.isEmpty) return {'ok': false, 'error': '这个直播间没有可用播放地址'};
      final best = cands.first;
      return {
        'ok': true,
        'roomId': roomId,
        'liveStatus': dd['live_status'] ?? 1,
        'url': best['url'],
        'protocol': best['protocol'],
        'format': best['format'],
        'codec': best['codec'],
        'quality': best['qn'],
        'referer': 'https://live.bilibili.com/',
        'options': cands.take(8).toList(),
      };
    }

    // ── 番剧时间表 ────────────────────────────────────
    if (op == '/bangumi') {
      final before = q['before'] ?? '0';
      final after = q['after'] ?? '6';
      final j = await BiliWbi.I.getJson(
          '/pgc/web/timeline?types=1&before=$before&after=$after');
      final days = (j['result'] is List) ? (j['result'] as List) : const [];
      final out = days.whereType<Map>().map((day) {
        final eps = ((day['episodes'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => {
                  'title': '${e['title'] ?? ''}',
                  'cover': _https(e['cover']),
                  'ep': '${e['pub_index'] ?? ''}',
                  'pubTs': e['pub_ts'] ?? 0,
                  'url': '${e['url'] ?? ''}',
                  'seasonId': e['season_id'] ?? 0,
                  'episodeId': e['episode_id'] ?? 0,
                })
            .toList();
        return {'date': '${day['date'] ?? ''}', 'items': eps};
      }).where((d) => (d['items'] as List).isNotEmpty).toList();
      return {'ok': (j['code'] ?? -1) == 0, 'days': out, 'message': j['message'] ?? ''};
    }
  } catch (_) {}
  return null;
}

/// 取 aid（评论接口按 aid）
Future<String?> _aidOf(String bvid) async {
  if (bvid.startsWith('av')) return bvid.substring(2);
  final j = await BiliWbi.I.getJson('/x/web-interface/view?bvid=$bvid');
  final d = (j['data'] as Map?) ?? const {};
  final aid = d['aid'];
  return aid == null ? null : '$aid';
}

Map<String, dynamic> _mapReply(Map r) {
  final m = (r['member'] as Map?) ?? const {};
  final ct = (r['content'] as Map?) ?? const {};
  final lv = ((m['level_info'] as Map?) ?? const {})['current_level'];
  return <String, dynamic>{
    'id': '${r['rpid_str'] ?? r['rpid'] ?? ''}',
    'uname': '${m['uname'] ?? '匿名'}',
    'face': _https(m['avatar']),
    'level': lv ?? 0,
    'message': '${ct['message'] ?? ''}',
    'like': r['like'] ?? 0,
    'ctime': r['ctime'] ?? 0,
    'rcount': r['rcount'] ?? 0,
    'mid': m['mid'] ?? 0,
    'replies': ((r['replies'] as List?) ?? const [])
        .whereType<Map>()
        .take(3)
        .map((x) {
          final mm = (x['member'] as Map?) ?? const {};
          return {
            'id': '${x['rpid_str'] ?? x['rpid'] ?? ''}',
            'uname': '${mm['uname'] ?? '匿名'}',
            'message': '${(x['content'] as Map?)?['message'] ?? ''}',
            'like': x['like'] ?? 0,
          };
        })
        .toList(),
  };
}
