// 直连 B 站（4.81.71）
//
// 目的：后端（NAS）连不上时，App 也能浏览/搜索/看详情/看评论/看弹幕。
// 做法：把后端那套 /v1/bili/* 语义在端内重放一遍，返回**与后端一致的结构**，
//       上层页面完全不用改。
// 注意：下载（bilidown）只有后端有，直连模式下不可用。
import 'dart:convert';

import 'package:http/http.dart' as http;

const String biliUA =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const String biliReferer = 'https://www.bilibili.com/';

Future<Map<String, dynamic>> _getJson(String apiPath) async {
  final r = await http.get(
    Uri.parse('https://api.bilibili.com$apiPath'),
    headers: {
      'user-agent': biliUA,
      'referer': biliReferer,
      'accept': 'application/json,text/plain,*/*',
      'accept-language': 'zh-CN,zh;q=0.9',
    },
  ).timeout(const Duration(seconds: 20));
  final j = jsonDecode(utf8.decode(r.bodyBytes));
  if (j is Map) return Map<String, dynamic>.from(j);
  return <String, dynamic>{};
}

/// 统一的视频条目映射（与后端 feedItem 同构）
Map<String, dynamic> _mapItem(Map<String, dynamic> v) {
  final stat = (v['stat'] as Map?) ?? const {};
  final owner = (v['owner'] as Map?) ?? const {};
  final pic = '${v['pic'] ?? ''}';
  final dur = v['duration'];
  return <String, dynamic>{
    'bvid': '${v['bvid'] ?? ''}',
    'title': '${v['title'] ?? ''}'.replaceAll(RegExp(r'</?em[^>]*>'), ''),
    'cover': pic.isEmpty ? '' : pic.replaceFirst('http:', 'https:'),
    'owner': '${owner['name'] ?? v['author'] ?? ''}',
    'play': stat['view'] ?? v['play'] ?? 0,
    'danmaku': stat['danmaku'] ?? v['video_review'] ?? 0,
    'duration': dur is num ? dur.toInt() : _durFromText('${v['duration'] ?? ''}'),
    'desc': '${v['desc'] ?? ''}',
  };
}

int _durFromText(String s) {
  // 搜索接口时长是 "12:34" / "1:02:03" 文本
  final parts = s.split(':').where((e) => e.isNotEmpty).map((e) => int.tryParse(e) ?? 0).toList();
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

/// 直连入口：传入后端同款路径，返回同款 JSON；不支持或失败返回 null。
Future<Map<String, dynamic>?> biliDirect(String path) async {
  try {
    final uri = Uri.parse('https://placeholder$path');
    final q = uri.queryParameters;

    // 推荐 / 热门
    if (path.startsWith('/v1/bili/feed')) {
      final type = q['type'] ?? 'popular';
      final pn = q['pn'] ?? '1';
      if (type == 'recommend') {
        // rcmd 的 ps 上限 12（15 以上直接 -400）
        final j = await _getJson(
            '/x/web-interface/index/top/rcmd?ps=12&fresh_idx=$pn&fresh_idx_1h=$pn');
        return {'ok': true, 'items': _mapList((j['data'] as Map?)?['item'])};
      }
      final j = await _getJson('/x/web-interface/popular?ps=20&pn=$pn');
      return {'ok': true, 'items': _mapList((j['data'] as Map?)?['list'])};
    }

    // 分区
    if (path.startsWith('/v1/bili/region')) {
      final rid = q['rid'] ?? '1';
      final pn = q['pn'] ?? '1';
      final j = await _getJson(
          '/x/web-interface/dynamic/region?rid=$rid&ps=20&pn=$pn');
      // 老接口偶尔空，退化到 newlist
      var items = _mapList((j['data'] as Map?)?['archives']);
      if (items.isEmpty) {
        final j2 = await _getJson('/x/web-interface/newlist?rid=$rid&ps=20&pn=$pn');
        items = _mapList((j2['data'] as Map?)?['archives']);
      }
      return {'ok': true, 'items': items};
    }

    // 搜索
    if (path.startsWith('/v1/bili/search')) {
      final kw = q['q'] ?? '';
      final pn = q['pn'] ?? '1';
      final j = await _getJson(
          '/x/web-interface/search/type?search_type=video&keyword=${Uri.encodeQueryComponent(kw)}&page=$pn');
      return {'ok': true, 'items': _mapList((j['data'] as Map?)?['result'])};
    }

    // 详情
    if (path.startsWith('/v1/bili/view')) {
      final bvid = q['bvid'] ?? '';
      final j = await _getJson('/x/web-interface/view?bvid=$bvid');
      if ((j['code'] ?? -1) != 0) return {'ok': false, 'error': '${j['message'] ?? '取详情失败'}'};
      final d = (j['data'] as Map?) ?? const {};
      final s = (d['stat'] as Map?) ?? const {};
      final owner = (d['owner'] as Map?) ?? const {};
      return {
        'ok': true,
        'bvid': '${d['bvid'] ?? bvid}',
        'aid': d['aid'],
        'title': '${d['title'] ?? ''}',
        'desc': '${d['desc'] ?? ''}',
        'pic': '${d['pic'] ?? ''}'.replaceFirst('http:', 'https:'),
        'owner': {
          'name': '${owner['name'] ?? ''}',
          'face': '${owner['face'] ?? ''}'.replaceFirst('http:', 'https:'),
        },
        'stat': {
          'view': s['view'] ?? 0,
          'danmaku': s['danmaku'] ?? 0,
          'like': s['like'] ?? 0,
          'coin': s['coin'] ?? 0,
          'favorite': s['favorite'] ?? 0,
          'share': s['share'] ?? 0,
          'reply': s['reply'] ?? 0,
        },
        'pubdate': d['pubdate'] ?? 0,
        'duration': d['duration'] ?? 0,
        'videos': d['videos'] ?? 1,
        'pages': ((d['pages'] as List?) ?? const []).whereType<Map>().map((p) => {
              'cid': p['cid'],
              'page': p['page'],
              'part': p['part'] ?? '',
              'duration': p['duration'] ?? 0,
            }).toList(),
      };
    }

    // 分P
    if (path.startsWith('/v1/bili/pages')) {
      final bvid = q['bvid'] ?? '';
      final j = await _getJson('/x/player/pagelist?bvid=$bvid');
      final list = ((j['data'] as List?) ?? const []).whereType<Map>().map((p) => {
            'cid': p['cid'],
            'page': p['page'],
            'part': p['part'] ?? '',
            'duration': p['duration'] ?? 0,
          }).toList();
      return {'ok': true, 'pages': list};
    }

    // 播放地址：优先 MP4 单流（有声、直连播放器能播），qn 缺省给最高可用的 720p。
    // 实测（2026-11-24）：fnval=16&platform=html5 只回 480p durl；
    //   fnval=1&qn=64 无 cookie 就能拿 720p 有声 MP4。DASH 高清流是音视频
    //   分离，本机 video_player 单 URL 播会没声音，故不走 DASH。
    if (path.startsWith('/v1/bili/playurl')) {
      final bvid = q['bvid'] ?? '';
      final cid = q['cid'] ?? '';
      final qn = q['qn'] ?? '64';
      final j = await _getJson(
          '/x/player/playurl?bvid=$bvid&cid=$cid&fnval=1&qn=$qn&platform=html5');
      final d = (j['data'] as Map?) ?? const {};
      final dash = (d['dash'] as Map?) ?? const {};
      final vids = (dash['video'] as List?) ?? const [];
      String best = '';
      int bestId = -1;
      for (final v in vids.whereType<Map>()) {
        final id = (v['id'] is num) ? (v['id'] as num).toInt() : 0;
        final url = '${v['baseUrl'] ?? v['base_url'] ?? ''}';
        if (url.isNotEmpty && id > bestId) {
          bestId = id;
          best = url;
        }
      }
      if (best.isEmpty) {
        final durl = (d['durl'] as List?) ?? const [];
        if (durl.isNotEmpty && durl.first is Map) {
          best = '${(durl.first as Map)['url'] ?? ''}';
        }
      }
      if (best.isEmpty) return {'ok': false, 'url': '', 'error': '无可用播放地址'};
      final realQuality = (d['quality'] is num) ? (d['quality'] as num).toInt() : bestId;
      final accept = d['acceptQuality'];
      return {
        'ok': true,
        'url': best,
        'quality': realQuality,
        if (accept is List && accept.isNotEmpty) 'acceptQuality': accept,
      };
    }

    // 评论
    if (path.startsWith('/v1/bili/replies')) {
      final bvid = q['bvid'] ?? '';
      final pn = q['pn'] ?? '1';
      final ps = q['ps'] ?? '20';
      final sort = q['sort'] ?? '2';
      final v = await _getJson('/x/web-interface/view?bvid=$bvid');
      final aid = (v['data'] as Map?)?['aid'];
      if (aid == null) return {'ok': false, 'error': '取 aid 失败'};
      final j = await _getJson(
          '/x/v2/reply?type=1&oid=$aid&pn=$pn&ps=$ps&sort=$sort');
      final d = (j['data'] as Map?) ?? const {};
      final pg = (d['page'] as Map?) ?? const {};
      final raw = ((d['replies'] as List?) ?? (d['top_replies'] as List?) ?? const []);
      final items = raw.whereType<Map>().map((r) {
        final m = (r['member'] as Map?) ?? const {};
        final ct = (r['content'] as Map?) ?? const {};
        return {
          'id': '${r['rpid_str'] ?? r['rpid'] ?? ''}',
          'uname': '${m['uname'] ?? '匿名'}',
          'face': '${m['avatar'] ?? ''}'.replaceFirst('http:', 'https:'),
          'level': (m['level_info'] is Map) ? ((m['level_info'] as Map)['current_level'] ?? 0) : 0,
          'message': '${ct['message'] ?? ''}',
          'like': r['like'] ?? 0,
          'ctime': r['ctime'] ?? 0,
          'rcount': r['rcount'] ?? 0,
          'replies': ((r['replies'] as List?) ?? const []).whereType<Map>().take(3).map((x) {
            final mm = (x['member'] as Map?) ?? const {};
            return {
              'uname': '${mm['uname'] ?? '匿名'}',
              'message': '${(x['content'] as Map?)?['message'] ?? ''}',
              'like': x['like'] ?? 0,
            };
          }).toList(),
        };
      }).toList();
      return {'ok': true, 'total': pg['count'] ?? 0, 'pn': pn, 'items': items};
    }

    // 相关推荐
    if (path.startsWith('/v1/bili/related')) {
      final bvid = q['bvid'] ?? '';
      final j = await _getJson('/x/web-interface/archive/related?bvid=$bvid');
      return {'ok': true, 'items': _mapList(j['data']).take(20).toList()};
    }

    // 弹幕（XML → 结构化）
    if (path.startsWith('/v1/bili/danmaku')) {
      final cid = q['cid'] ?? '';
      final r = await http.get(
        Uri.parse('https://api.bilibili.com/x/v1/dm/list.so?oid=$cid'),
        headers: {'user-agent': biliUA, 'referer': biliReferer},
      ).timeout(const Duration(seconds: 20));
      final xml = utf8.decode(r.bodyBytes, allowMalformed: true);
      final re = RegExp(r'<d p="([^"]*)"[^>]*>([\s\S]*?)</d>');
      final items = <Map<String, dynamic>>[];
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
          't': (double.tryParse(p[0]) ?? 0).toStringAsFixed(2),
          'm': int.tryParse(p.length > 1 ? p[1] : '1') ?? 1,
          'c': int.tryParse(p.length > 3 ? p[3] : '16777215') ?? 16777215,
          's': int.tryParse(p.length > 2 ? p[2] : '25') ?? 25,
          'x': text.length > 80 ? text.substring(0, 80) : text,
        });
      }
      // 与后端一致：t 用数字
      final norm = items
          .map((e) => {
                't': double.tryParse('${e['t']}') ?? 0.0,
                'm': e['m'],
                'c': e['c'],
                's': e['s'],
                'x': e['x'],
              })
          .toList()
        ..sort((a, b) => (a['t'] as double).compareTo(b['t'] as double));
      return {'ok': true, 'total': norm.length, 'items': norm};
    }
  } catch (_) {}
  return null;
}
