// B站「收藏夹 + UP 主页」数据层（4.81.100）
//
// 为什么单独一层：bili_direct.dart 负责把后端 /v1/bili/* 语义在端内重放，
// 本文件只负责这两组新接口的实际请求与字段归一化，不碰 UI、不碰路由，
// 避免 bili_module_page ↔ bili_direct ↔ 页面 的循环依赖。
//
// 实测结论（2026-11-25，匿名 + buvid）：
//   · /x/space/acc/info?mid=        → code 0，字段最全，首选
//   · /x/web-interface/card?mid=    → code 0，data.card，备选
//   · /x/space/wbi/acc/info         → 匿名经常 -352，兜底才用
//   · /x/space/wbi/arc/search       → 低频可用，连发会 412（端上用户单次点击不受影响）
//   · /x/v3/fav/folder/created/list-all → code 0；未登录或无公开收藏夹时 data=null
//   · /x/v3/fav/resource/list       → code 0，data.medias
// 风控时一律返回 ok=false + 明确 error，绝不返回空列表假装"没有内容"。
import 'bili_wbi.dart' show BiliWbi;

String _https(Object? u) {
  var s = '${u ?? ''}'.trim();
  if (s.isEmpty) return '';
  if (s.startsWith('//')) s = 'https:$s';
  if (s.startsWith('http://')) s = s.replaceFirst('http://', 'https://');
  return s;
}

Map<String, dynamic> _ok(Map<String, dynamic> extra) =>
    <String, dynamic>{'ok': true, ...extra};

Map<String, dynamic> _fail(String error, {int? code, bool needLogin = false}) =>
    <String, dynamic>{
      'ok': false,
      'error': error,
      if (code != null) 'code': code,
      if (needLogin) 'needLogin': true,
    };

List<Map<String, dynamic>> _videos(Object? raw) {
  final list = (raw is List) ? raw : const [];
  return list.whereType<Map>().map((e) {
    final m = Map<String, dynamic>.from(e);
    final owner = (m['owner'] as Map?) ?? const {};
    final stat = (m['stat'] as Map?) ?? const {};
    final cnt = (m['cnt_info'] as Map?) ?? const {};
    final dur = m['duration'];
    return <String, dynamic>{
      'bvid': '${m['bvid'] ?? m['id'] ?? ''}',
      'title': '${m['title'] ?? ''}'.replaceAll(RegExp(r'</?em[^>]*>'), ''),
      'cover': _https(m['pic'] ?? m['cover']),
      'owner': '${owner['name'] ?? m['author'] ?? m['uname'] ?? ''}',
      'face': _https(owner['face'] ?? m['face']),
      'play': stat['view'] ?? cnt['play'] ?? m['play'] ?? 0,
      'danmaku': stat['danmaku'] ?? cnt['danmaku'] ?? m['video_review'] ?? 0,
      'duration': dur is num ? dur.toInt() : 0,
      'desc': '${m['description'] ?? m['desc'] ?? ''}',
      if (m['created'] != null) 'pubdate': m['created'],
      if (m['pubdate'] != null) 'pubdate': m['pubdate'],
    };
  }).where((e) => '${e['bvid']}'.startsWith('BV')).toList(growable: false);
}

/// 收藏夹分组。mid 为空时取当前登录用户；未登录给出明确引导。
Future<Map<String, dynamic>> fetchFavFolders({String? mid}) async {
  var uid = (mid ?? '').trim();
  if (uid.isEmpty) {
    final nav = await BiliWbi.I.getJson('/x/web-interface/nav');
    final login = nav['isLogin'] == true;
    if (!login) {
      return _fail('请先登录 B 站后再查看收藏夹', needLogin: true);
    }
    uid = '${((nav['data'] as Map?) ?? const {})['mid'] ?? ''}';
  }
  if (uid.isEmpty) return _fail('取不到用户 ID', needLogin: true);

  final j = await BiliWbi.I.getJson('/x/v3/fav/folder/created/list-all',
      query: {'up_mid': uid, 'jsonp': 'jsonp'});
  if ((j['code'] ?? -1) != 0) {
    return _fail('${j['message'] ?? '收藏夹读取失败'}', code: j['code'] is int ? j['code'] : null);
  }
  final raw = j['data'];
  if (raw is! List) {
    // 未登录 / 无公开收藏夹时 B站给 null，这不是错误，是空态
    return _ok(<String, dynamic>{'folders': <Map<String, dynamic>>[], 'mid': uid});
  }
  final folders = raw.whereType<Map>().map((e) {
    final m = Map<String, dynamic>.from(e);
    return <String, dynamic>{
      'id': '${m['id'] ?? ''}',
      'name': '${m['title'] ?? ''}',
      'count': m['media_count'] ?? 0,
      'cover': _https(m['cover']),
    };
  }).where((e) => '${e['id']}'.isNotEmpty).toList(growable: false);
  return _ok(<String, dynamic>{'folders': folders, 'mid': uid});
}

/// 收藏夹内视频（分页）。
Future<Map<String, dynamic>> fetchFavList(String mediaId, int pn) async {
  if (mediaId.trim().isEmpty) return _fail('缺少收藏夹 ID');
  final j = await BiliWbi.I.getJson('/x/v3/fav/resource/list',
      query: {
        'media_id': mediaId,
        'pn': pn,
        'ps': 20,
        'keyword': '',
        'order': 'mtime',
        'type': 0,
        'tid': 0,
        'platform': 'web',
      });
  if ((j['code'] ?? -1) != 0) {
    return _fail('${j['message'] ?? '收藏夹内容读取失败'}', code: j['code'] is int ? j['code'] : null);
  }
  final d = (j['data'] as Map?) ?? const {};
  return _ok(<String, dynamic>{
    'list': _videos(d['medias']),
    'count': d['media_count'] ?? d['count'] ?? 0,
    'hasMore': (_videos(d['medias']).length >= 20),
  });
}

/// UP 主信息：旧接口优先（实测最稳），card 兜底，WBI 最后。
Future<Map<String, dynamic>> fetchSpaceInfo(String mid) async {
  if (mid.trim().isEmpty) return _fail('缺少 UP 主 ID');

  Future<Map<String, dynamic>?> from(Map<String, dynamic> j, bool wrapped) async {
    if ((j['code'] ?? -1) != 0) return null;
    final raw = j['data'];
    final d = wrapped
        ? ((raw is Map ? (raw['card'] as Map?) : null) ?? const {})
        : ((raw is Map) ? raw : const {});
    if (d.isEmpty) return null;
    final lv = (d['level_info'] as Map?) ?? const {};
    return <String, dynamic>{
      'mid': '${d['mid'] ?? mid}',
      'name': '${d['name'] ?? ''}',
      'face': _https(d['face']),
      'sign': '${d['sign'] ?? d['description'] ?? ''}',
      'fans': d['fans'] ?? d['follower'] ?? 0,
      'following': d['attention'] ?? d['following'] ?? 0,
      'level': lv['current_level'] ?? d['level'] ?? 0,
      'videos': d['archive_count'] ?? d['video'] ?? 0,
    };
  }

  var j = await BiliWbi.I.getJson('/x/space/acc/info', query: {'mid': mid});
  var info = await from(j, false);
  if (info == null) {
    j = await BiliWbi.I.getJson('/x/web-interface/card',
        query: {'mid': mid, 'photo': 'false'});
    info = await from(j, true);
  }
  if (info == null) {
    j = await BiliWbi.I.getWbi('/x/space/wbi/acc/info',
        query: {'mid': mid, 'platform': 'web', 'web_location': '1550101'});
    info = await from(j, false);
  }
  if (info == null) return _fail('UP 主信息读取失败（可能被风控）');
  return _ok(<String, dynamic>{'info': info});
}

/// UP 主投稿列表（WBI 签名，分页）。
Future<Map<String, dynamic>> fetchSpaceVideos(String mid, int pn) async {
  if (mid.trim().isEmpty) return _fail('缺少 UP 主 ID');
  final j = await BiliWbi.I.getWbi('/x/space/wbi/arc/search',
      query: {
        'mid': mid,
        'pn': pn,
        'ps': 30,
        'order': 'pubdate',
        'platform': 'web',
      });
  if ((j['code'] ?? -1) != 0) {
    // 风控命中时退到老接口（部分 CDN 放行）
    final j2 = await BiliWbi.I.getJson('/x/space/arc/search',
        query: {'mid': mid, 'pn': pn, 'ps': 30, 'order': 'pubdate'});
    if ((j2['code'] ?? -1) != 0) {
      return _fail('投稿列表读取失败（${j['message'] ?? j['code'] ?? '风控'}）',
          code: j['code'] is int ? j['code'] : null);
    }
    final list = ((j2['data'] as Map?)?['list'] as Map?)?['vlist'];
    final items = _videos(list);
    return _ok(<String, dynamic>{
      'list': items,
      'count': ((j2['data'] as Map?)?['page'] as Map?)?['count'] ?? items.length,
      'hasMore': items.length >= 30,
    });
  }
  final d = (j['data'] as Map?) ?? const {};
  final items = _videos(((d['list'] as Map?) ?? const {})['vlist']);
  return _ok(<String, dynamic>{
    'list': items,
    'count': ((d['page'] as Map?) ?? const {})['count'] ?? items.length,
    'hasMore': items.length >= 30,
  });
}
