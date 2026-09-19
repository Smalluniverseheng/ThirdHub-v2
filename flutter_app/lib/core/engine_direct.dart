// 前端直连引擎(THP): 不经过后端, 直接向局域网引擎发起搜索/目录/内容/发现请求
//
// 端点(引擎 engine-v1.5.x 实际实现):
//   /thp/meta · /thp/search · /thp/chapters · /thp/content · /thp/discover · /thp/explore
//   (docs/THP.md 的 /thp/m/{module}/... 是规范端点；本 App 走旧草稿端点，
//    两者由引擎同时提供，服务端降级链负责互通)
//
// ══════════════════════════════════════════════════════════════════════════
// ★ 2026-09-19 修复「连上了却一直显示未连接引擎 / 搜索什么都搜不到」
// ══════════════════════════════════════════════════════════════════════════
// 根因(1)【硬阻断】AndroidManifest 缺 usesCleartextTraffic，targetSdk=36 时
//   Android 默认禁止明文 HTTP → 所有到 http://<局域网IP>:1234 的请求被**系统层**拦死，
//   报 `CLEARTEXT communication ... not permitted by network security policy`，
//   在 Dart 里表现为 http.ClientException。
//   已修：manifest 加 usesCleartextTraffic + network_security_config.xml。
// 根因(2)【假状态】旧 _isNetErr() 把上述 ClientException 当成「连接已过期」，
//   于是每失败一次就 url='' → autoConnect() → connect() 又发 http → 又失败 →
//   永久停在「未连接引擎」，且原因被吞掉、界面无从解释。
//   已修：本文件重写为显式状态机 + 变更通知，并把失败原因一路带到 UI。
// 根因(3)【状态不通知】静态字段被各页面在 build 时读一次就再也不更新 →
//   「状态那里变化特别慢」。已修：暴露 `EngineDirect.state`(ValueNotifier)，
//   各页面用 ListenableBuilder 订阅。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'discover.dart';

/// 连接状态（供 UI 直接展示，不要用布尔值表达四态）
enum EngineStatus {
  /// 从未连接过，也没在尝试
  idle,

  /// 正在探测/自动发现/握手
  connecting,

  /// 已连接且可用
  connected,

  /// 连接失败，message 说明原因（可重试）
  failed,
}

@immutable
class EngineState {
  final EngineStatus status;
  final String url;
  final String name;
  final List<String> caps;

  /// 引擎包版本（取自 /thp/meta 的 version，如 "1.5.5"）。
  /// ★能力判断必须靠它：引擎 1.5.5 起 /thp/search 才支持 page/limit/budget 与 type=all，
  ///   对着老引擎发这些参数不会报错、只会**静默**退化成"只搜小说/只返回第一页"，
  ///   是最难查的一类不兼容 —— 所以按版本分流，别指望"多传参数旧版会忽略"。
  final String version;

  /// 面向用户的一句话说明（失败原因/连接进度），可直接显示
  final String message;

  const EngineState({
    this.status = EngineStatus.idle,
    this.url = '',
    this.name = '',
    this.caps = const [],
    this.version = '',
    this.message = '',
  });

  bool get connected => status == EngineStatus.connected && url.isNotEmpty;
  bool get working => status == EngineStatus.connecting;

  /// 引擎是否支持 /thp/search 的分页与 type=all（1.5.5+）
  bool get supportsPaging => _cmpVersion(version, '1.5.5') >= 0;

  static int _cmpVersion(String a, String b) {
    final x = a.split('.'), y = b.split('.');
    for (var i = 0; i < 3; i++) {
      final n1 = i < x.length ? (int.tryParse(x[i]) ?? 0) : 0;
      final n2 = i < y.length ? (int.tryParse(y[i]) ?? 0) : 0;
      if (n1 != n2) return n1 - n2;
    }
    return 0;
  }

  EngineState copyWith({
    EngineStatus? status, String? url, String? name,
    List<String>? caps, String? version, String? message,
  }) => EngineState(
    status: status ?? this.status,
    url: url ?? this.url,
    name: name ?? this.name,
    caps: caps ?? this.caps,
    version: version ?? this.version,
    message: message ?? this.message,
  );

  @override
  String toString() =>
      'EngineState(${status.name}, url=$url, name=$name, v=$version, msg=$message)';
}

/// 一次搜索页的结果。引擎 1.5.5+ 会带 hasMore/total；老引擎这三项为默认值
/// （hasMore=false, total=items.length），调用方据此自然退化成"只有第一页"。
class SearchPage {
  final List<Map<String, dynamic>> items;
  final int page;
  final int total;
  final bool hasMore;

  /// 引擎这轮扫描被时间预算截断（还有源没跑完）→ 用更大的 budget 再取能拿到更多
  final bool truncated;
  final int budgetSec;

  const SearchPage({
    this.items = const [],
    this.page = 1,
    this.total = 0,
    this.hasMore = false,
    this.truncated = false,
    this.budgetSec = 0,
  });

  static SearchPage from(Map<String, dynamic> r) {
    final raw = r['raw'];
    final items = <Map<String, dynamic>>[];
    final d = r['data'];
    final list = (d is Map) ? (d['items'] as List? ?? []) : (d is List ? d : const []);
    for (final e in list) {
      if (e is Map) items.add(Map<String, dynamic>.from(e));
    }
    int intOf(String k, int dv) {
      if (raw is! Map) return dv;
      final v = raw[k];
      if (v is int) return v;
      return int.tryParse('${v ?? ''}') ?? dv;
    }
    bool boolOf(String k) => (raw is Map) && raw[k] == true;
    return SearchPage(
      items: items,
      page: intOf('page', 1),
      total: intOf('total', items.length),
      hasMore: boolOf('hasMore'),
      truncated: boolOf('truncated'),
      budgetSec: intOf('budgetSec', 0),
    );
  }
}

class EngineDirect {
  /// ★ 唯一的连接状态来源。UI 必须订阅它，不要直接读静态字段后再也不刷新。
  static final ValueNotifier<EngineState> state =
      ValueNotifier<EngineState>(const EngineState());

  static EngineState get s => state.value;
  static bool get connected => s.connected;
  static String get url => s.url;
  static String get name => s.name;
  static List<String> get caps => s.caps;
  static String get version => s.version;
  /// 引擎是否支持 /thp/search 分页 + type=all（1.5.5+）
  static bool get supportsPaging => s.supportsPaging;
  static String get lastError => s.message;

  static bool _autoConnecting = false;
  static bool _inited = false;

  /// 启动探测超时：引擎随手机开机时 THP 服务是**异步**起来的，给足时间。
  /// (旧值 5s 过于激进：开机/唤醒后首次探测经常超时，旧逻辑据此清空已保存的连接。)
  static const _probeTimeout = Duration(seconds: 12);
  static const _searchTimeoutSec = 35;
  static const _metaTimeoutSec = 8;

  static http.Client _client() {
    // 局域网资源库 :9527 用自签证书，需放行；引擎 :1234 是明文(靠 manifest 放行)
    final c = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    c.connectionTimeout = const Duration(seconds: 8);
    return IOClient(c);
  }

  // ─────────────────────────── 生命周期 ───────────────────────────

  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final p = await SharedPreferences.getInstance();
    final savedUrl = p.getString('engine_direct_url') ?? '';
    final savedName = p.getString('engine_direct_name') ?? '';
    final savedCaps = p.getStringList('engine_direct_caps') ?? [];
    final savedVer = p.getString('engine_direct_version') ?? '';
    if (savedUrl.isNotEmpty) {
      state.value = EngineState(
        status: EngineStatus.connecting, url: savedUrl, name: savedName,
        caps: savedCaps, version: savedVer, message: '正在校验引擎连接…');
    }
    // 启动 THP 发现监听(全局常驻, 模块页随时可读设备列表)
    unawaited(ThpDiscovery.start());

    if (savedUrl.isEmpty) {
      unawaited(autoConnect());
      return;
    }
    unawaited(_verifySaved(savedUrl, savedName, savedCaps));
  }

  /// 校验上次连接；★失败**不再直接清空**用户选择（旧逻辑会清，导致「开机就显示未连接」）。
  /// 只有明确探测成功才维持连接；失败则转为「重连中」并尝试发现新引擎，
  /// 若发现到**不同**的引擎才替换，否则保留原地址并给出可读原因。
  static Future<void> _verifySaved(String u, String n, List<String> c) async {
    Object? err;
    for (var i = 0; i < 2; i++) {
      try {
        // ★必须把 meta 的 name/caps/**version** 一起读回来。
        //   只标 connected 会让 version 一直是空串 → supportsPaging 判假 →
        //   新引擎也被当成老引擎走逐类搜索（"重启后搜索又变慢/丢类型"就是这么来的）。
        final j = await _probeMeta(u, _probeTimeout);
        final m = (j['data'] is Map ? j['data'] : j) as Map;
        final nm = '${m['name'] ?? ''}';
        final cp = m['caps'] is List ? [for (final x in m['caps'] as List) '$x'] : c;
        final ver = '${m['version'] ?? ''}';
        final p = await SharedPreferences.getInstance();
        await p.setString('engine_direct_name', nm.isEmpty ? n : nm);
        await p.setStringList('engine_direct_caps', cp);
        await p.setString('engine_direct_version', ver);
        state.value = EngineState(
          status: EngineStatus.connected, url: u,
          name: nm.isEmpty ? (n.isEmpty ? 'THP 引擎' : n) : nm, caps: cp,
          version: ver, message: '');
        return;
      } catch (e) {
        err = e;
        if (i == 0) await Future.delayed(const Duration(milliseconds: 600));
      }
    }
    // 两次都失败：保留地址但标注不可达，同时后台找找有没有新地址的引擎
    state.value = EngineState(
      status: EngineStatus.failed, url: u,
      name: n.isEmpty ? 'THP 引擎' : n, caps: c,
      message: '引擎当前不可达（${_describe(err)}）· 正在后台重试发现…');
    final found = await autoConnect(force: true);
    if (found && state.value.url != u) return;   // 找到别的引擎，已切换
    if (!found) {
      state.value = state.value.copyWith(
        message: '引擎不可达：${_describe(err)}\n请确认引擎 App 已启动且与本机同一局域网');
    }
  }

  static Future<Map<String, dynamic>> _probeMeta(String u, Duration t) async {
    final r = await _client().get(Uri.parse('$u/thp/meta')).timeout(t);
    if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// 自动连接：已有发现设备直接连；没有则监听广播 15s，出现引擎即连。
  /// 返回是否成功建立连接。
  static Future<bool> autoConnect({bool force = false}) async {
    if (_autoConnecting) return connected;
    if (connected && !force) return true;
    _autoConnecting = true;
    if (!connected) {
      state.value = state.value.copyWith(
        status: EngineStatus.connecting, message: '正在发现局域网引擎…');
    }
    try {
      await ThpDiscovery.start();
      var devs = available();
      if (devs.isEmpty) {
        // 等广播：期间一旦发现设备就立刻连，别等满 15s
        final completer = Completer<void>();
        late final StreamSubscription sub;
        sub = ThpDiscovery.onChange.listen((_) {
          if (!completer.isCompleted && available().isNotEmpty) completer.complete();
        });
        await Future.any([
          completer.future,
          Future.delayed(const Duration(seconds: 15)),
        ]);
        await sub.cancel();
        devs = available();
      }
      if (devs.isEmpty) {
        if (!connected) {
          state.value = state.value.copyWith(
            status: EngineStatus.failed,
            message: '未发现引擎。请确认：\n'
                '① 引擎 App 已打开并显示在运行\n'
                '② 两台设备在同一局域网(WiFi)\n'
                '③ 路由器未开启「AP 隔离」');
        }
        return false;
      }
      // 优先连上次用过的那个，其次列表首个
      final prefer = devs.firstWhere((d) => d.url == state.value.url, orElse: () => devs.first);
      try {
        await connect(prefer.url);
        return true;
      } catch (e) {
        // 换一个再试
        for (final d in devs) {
          if (d.url == prefer.url) continue;
          try { await connect(d.url); return true; } catch (_) {}
        }
        state.value = state.value.copyWith(
          status: EngineStatus.failed,
          message: '发现 ${devs.length} 个引擎但都连不上：${_describe(e)}');
        return false;
      }
    } finally {
      _autoConnecting = false;
    }
  }

  /// 手动/自动连接指定地址。成功后写入偏好并广播状态。
  static Future<void> connect(String u) async {
    final from = state.value.status;
    state.value = state.value.copyWith(status: EngineStatus.connecting, message: '正在连接 $u …');
    try {
      final j = await _probeMeta(u, Duration(seconds: _metaTimeoutSec));
      final m = (j['data'] is Map ? j['data'] : j) as Map;
      final nm = '${m['name'] ?? 'THP 引擎'}';
      final cp = [for (final x in (m['caps'] as List? ?? [])) '$x'];
      final ver = '${m['version'] ?? ''}';
      final p = await SharedPreferences.getInstance();
      await p.setString('engine_direct_url', u);
      await p.setString('engine_direct_name', nm);
      await p.setStringList('engine_direct_caps', cp);
      await p.setString('engine_direct_version', ver);
      state.value = EngineState(
          status: EngineStatus.connected, url: u, name: nm, caps: cp, version: ver);
    } catch (e) {
      state.value = EngineState(
        status: EngineStatus.failed, url: '', name: '', caps: const [],
        message: '连接失败：${_describe(e)}');
      // 保留上一状态的可读性：若之前是已连接，提示更明确
      if (from == EngineStatus.connected) {
        state.value = state.value.copyWith(message: '与引擎的连接已断开：${_describe(e)}');
      }
      rethrow;
    }
  }

  static Future<void> disconnect() async {
    state.value = const EngineState();
    final p = await SharedPreferences.getInstance();
    await p.remove('engine_direct_url');
    await p.remove('engine_direct_name');
    await p.remove('engine_direct_caps');
  }

  /// 手动重试（UI 上「重试」按钮用）
  static Future<void> retry() async {
    if (s.url.isNotEmpty) {
      await _verifySaved(s.url, s.name, s.caps);
    } else {
      await autoConnect(force: true);
    }
  }

  // ─────────────────────────── 网络层 ───────────────────────────

  /// 把异常翻译成用户看得懂的一句话。
  /// ★关键：明文被系统拦截与「连接被拒」在 Dart 里都是 ClientException/SocketException，
  ///   旧代码一律当成「连接过期」，于是真正的原因永远看不到。
  static String _describe(Object? e) {
    if (e is TimeoutException) return '超时未响应（引擎可能正忙或已退出）';
    final t = '${e is Exception ? e.toString() : e}';
    if (t.contains('CLEARTEXT') || t.contains('not permitted')) {
      return '系统拦截了明文 HTTP（需更新到修复版 App）';
    }
    if (t.contains('Connection refused')) return '连接被拒绝（引擎未在运行）';
    if (t.contains('Network is unreachable') || t.contains('No route to host')) {
      return '网络不可达（检查是否同一 WiFi）';
    }
    if (t.contains('Failed host lookup')) return '地址解析失败';
    if (t.contains('HandshakeException')) return 'TLS 握手失败';
    return t.replaceFirst(RegExp(r'^(SocketException|ClientException|HttpException):\s*'), '');
  }

  static bool _isNetErr(Object e) =>
      e is SocketException || e is http.ClientException || e is TimeoutException;

  static Future<Map<String, dynamic>> _get(
    String path, [bool retried = false, int timeoutSec = 30]) async {
    if (url.isEmpty) throw Exception('未连接引擎');
    final cli = _client();
    try {
      final r = await cli.get(Uri.parse('$url$path')).timeout(Duration(seconds: timeoutSec));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      // 旧草稿错误信封: {object:'error', data:{message}}
      if (j is Map && j['object'] == 'error') {
        throw Exception('${j['data']?['message'] ?? '引擎错误'}');
      }
      // THP 规范信封: {ok:false, error:{code,message}} —— 失败唯一依据是 ok:false
      if (j is Map && j['ok'] == false) {
        final em = j['error'];
        throw Exception('${em is Map ? (em['message'] ?? em['code']) : em}');
      }
      if (j is Map && j.containsKey('data')) {
        return {'data': j['data'], 'meta': j['meta'], 'raw': j};
      }
      return {'data': j, 'raw': j};
    } catch (e) {
      // ★只有「网络层」错误才尝试重连换地址；业务错误(400/ok:false)直接抛，别吞掉原因。
      if (retried || !_isNetErr(e)) rethrow;
      final old = url;
      // 不再先把 url 清空再 autoConnect（那会让 UI 闪一下「未连接」）；
      // 改为后台找一个可用地址，且**必须与旧地址不同**才切换重试。
      final ok = await autoConnect(force: true);
      if (!ok || url.isEmpty || url == old) rethrow;
      return _get(path, true, timeoutSec);
    } finally {
      cli.close();
    }
  }

  // ─────────────────────────── 业务端点 ───────────────────────────

  static List<Map<String, dynamic>> _items(Map<String, dynamic> r) {
    final d = r['data'];
    final raw = (d is Map) ? (d['items'] as List? ?? []) : (d is List ? d : const []);
    return [for (final e in raw) if (e is Map) Map<String, dynamic>.from(e)];
  }

  /// 搜索: type = novel/comic/video/music，或 'all'（引擎一次扫描返回全部类型）。
  /// 引擎侧一轮要跑全部书源，耗时可达 20s+（返回的是预算内的部分结果）。
  static Future<List<Map<String, dynamic>>> search(String type, String q) async {
    final p = await searchPage(type, q);
    return p.items;
  }

  /// ★分页搜索（引擎 1.5.5+ 才有意义；老引擎会忽略 page/budget 只返回第一页）。
  ///
  /// [budgetSec] 是**扫描时间预算**：一次全源扫描的耗时几乎就等于这个值。
  /// 首屏传小值(如 8s)让结果尽快出来，用户按「加载更多」时再传大值(如 25s)扫得更深。
  /// [type] 传 'all' 时引擎一次扫描返回**全部类型**（每项带 type 字段）——
  /// 旧做法按类型逐个请求 = 同一份扫描做 4 遍，白等 4 倍时间。
  static Future<SearchPage> searchPage(
    String type,
    String q, {
    int page = 1,
    int limit = 40,
    int budgetSec = 25,
  }) async {
    final r = await _get(
      '/thp/search?type=$type&q=${Uri.encodeComponent(q)}'
      '&page=$page&limit=$limit&budget=$budgetSec',
      false, _searchTimeoutSec);
    return SearchPage.from(r);
  }

  /// 目录/选集
  static Future<List<Map<String, dynamic>>> chapters(String type, String id) async {
    final r = await _get('/thp/chapters?type=$type&id=${Uri.encodeComponent(id)}', false, 30);
    return _items(r);
  }

  /// 正文/图片/播放地址
  static Future<Map<String, dynamic>> content(String type, String id, String chapter) async {
    final r = await _get(
      '/thp/content?type=$type&id=${Uri.encodeComponent(id)}&chapter=${Uri.encodeComponent(chapter)}',
      false, 30);
    final d = r['data'];
    return Map<String, dynamic>.from(d is Map ? d : {'text': '$d'});
  }

  /// 发现页结构: 各书源的分类标签 [{source, sourceName, tags:[{name,url}]}]
  /// 空 url 的标签会被引擎过滤；这里再兜一层，避免 UI 渲染出点了必 400 的标签。
  static Future<List<Map<String, dynamic>>> discover(String type) async {
    final r = await _get('/thp/discover?type=$type', false, _searchTimeoutSec);
    // 引擎对 2060 个带 exploreUrl 的源有总预算，到点即返回部分结果
    final raw = r['raw'];
    if (raw is Map && raw['truncated'] == true) {
      final tot = raw['total'];
      discoverNotice = '发现页结果被引擎时间预算截断'
          '${tot != null ? '（共 $tot 个源，已返回可用部分）' : ''}';
    } else {
      discoverNotice = '';
    }
    return _items(r).where((s) {
      final tags = s['tags'];
      if (tags is! List || tags.isEmpty) return false;
      return tags.any((t) => t is Map && '${t['url'] ?? ''}'.trim().isNotEmpty);
    }).toList();
  }

  /// 过滤掉 url 为空的标签（引擎 1.5.5 之前会返回空 url，点进去必然 400）
  static List<Map<String, dynamic>> validTags(Map<String, dynamic> source) {
    final tags = source['tags'];
    if (tags is! List) return const [];
    return [
      for (final t in tags)
        if (t is Map && '${t['url'] ?? ''}'.trim().isNotEmpty) Map<String, dynamic>.from(t),
    ];
  }

  /// 发现列表(按 源+分类URL+页码 取条目, 字段与 search 一致)
  static Future<List<Map<String, dynamic>>> explore(
    String type, String source, String tagUrl, [int page = 1]) async {
    if (source.trim().isEmpty || tagUrl.trim().isEmpty) {
      throw Exception('该分类没有可用的列表地址');
    }
    final r = await _get(
      '/thp/explore?type=$type&source=${Uri.encodeComponent(source)}'
      '&url=${Uri.encodeComponent(tagUrl)}&page=$page', false, _searchTimeoutSec);
    return _items(r);
  }

  /// 发现页被引擎预算截断的提示（discover 返回 truncated=true 时非空）
  static String discoverNotice = '';

  /// 可直连的引擎列表(THP 发现的非资源库设备)
  static List<ThpDevice> available() =>
      ThpDiscovery.list().where((d) => !d.isLibrary).toList();
}
