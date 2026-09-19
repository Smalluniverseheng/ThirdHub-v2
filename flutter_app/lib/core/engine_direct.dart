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
import 'dart:typed_data';
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

/// 自检（[EngineDirect.diagnose]）的一行结果。
/// ★为什么要做成"逐项可判定"的结构：用户反馈的「连不上 / 搜不到」在旧版只能看到
///   一句「未发现引擎」，无法区分是**网络层**（明文被拦、网段不通）、**服务层**
///   （引擎没跑、端口被占）、还是**数据层**（引擎装好了但书源为 0 → 能搜但永远 0 条）。
///   拆成独立条目后，失败的那一条直接告诉用户该修什么。
class DiagItem {
  /// 检查项名称，如「本机回环引擎 127.0.0.1:1234」
  final String label;

  /// 是否通过
  final bool ok;

  /// 人话说明（成功后是现状描述，失败后是修复指引）
  final String detail;

  const DiagItem(this.label, this.ok, this.detail);
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
        // ① 先等 UDP 广播：期间一旦发现设备就立刻连，别等满。
        //   ★2026-09-19 从 15s 压到 4s —— 广播在 IPv6-only / AP 隔离网络里
        //   永远不会到，等 15s 只是让用户干等；4s 足够覆盖正常广播周期(30s)的
        //   一个"恰好错过"窗口，剩下的靠下面的主动扫描兜。
        final completer = Completer<void>();
        late final StreamSubscription sub;
        sub = ThpDiscovery.onChange.listen((_) {
          if (!completer.isCompleted && available().isNotEmpty) completer.complete();
        });
        await Future.any([
          completer.future,
          Future.delayed(const Duration(seconds: 4)),
        ]);
        await sub.cancel();
        devs = available();
      }
      if (devs.isEmpty) {
        // ② ★广播没来 → 主动扫描兜底（IPv6 单栈 / AP 隔离 / 引擎就在本机 /
        //   引擎侧广播被 Doze 挂起 —— 这四种情况下广播一定收不到，但 TCP 是通的）。
        if (!connected) {
          state.value = state.value.copyWith(
            status: EngineStatus.connecting,
            message: '广播未收到引擎，正在主动扫描本机与局域网…');
        }
        final hits = await ThpDiscovery.scan(
          subnetSweep: true,
          extra: [if (state.value.url.isNotEmpty) state.value.url],
          onProgress: (d, t) {
            // 进度回填（扫描可能 2–4s，界面要动，否则像卡死）
            if (!connected && d % 24 == 0) {
              state.value = state.value.copyWith(
                status: EngineStatus.connecting,
                message: '正在扫描本机与局域网…（$d/$t）');
            }
          },
        );
        devs = hits.isNotEmpty ? hits : available();
      }
      if (devs.isEmpty) {
        if (!connected) {
          state.value = state.value.copyWith(
            status: EngineStatus.failed,
            message: '未发现引擎（已尝试广播 + 主动扫描）。请确认：\n'
                '① 引擎 App 已打开并显示在运行（同机引擎也可）\n'
                '② 两台设备在同一局域网(WiFi)\n'
                '③ 路由器未开启「AP 隔离」\n'
                '④ 已知地址可直接到「我的 → 引擎直连 → 手动填写地址」');
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

  /// ★响应体硬上限（4MB）。为什么必须有：
  ///   旧实现 `jsonDecode(utf8.decode(r.bodyBytes))` 会把**整个响应**一次性读进内存。
  ///   引擎对 /thp/search 有服务端 limit 截断，正常响应 < 200KB；但一旦
  ///   ①装了老引擎(<1.5.5，不认 limit)、或 ②单字符搜索(如"人")命中上千书源
  ///   导致引擎返回未截断的全量 JSON，bodyBytes 可达数 MB —— 在低端机上直接 OOM，
  ///   而 Dart 网络层崩掉时抛的正是 "Connection closed before full header"，
  ///   被误读成"引擎连不上"。这里改成**流式读 + 超限即断**，把 OOM 变成一句可读提示。
  static const _maxRespBytes = 4 * 1024 * 1024;

  /// 带上限地读流：完整读完返回字节，超过 [cap] 返回 null（并立即取消订阅停止下载）。
  static Future<List<int>?> _readCapped(Stream<List<int>> s, int cap) async {
    final b = BytesBuilder(copy: false);
    final done = Completer<bool>();
    late StreamSubscription sub;
    sub = s.listen((c) {
      if (done.isCompleted) return;
      b.add(c);
      if (b.length > cap) done.complete(false);
    },
      onDone: () { if (!done.isCompleted) done.complete(true); },
      onError: (Object e) { if (!done.isCompleted) done.completeError(e); },
      cancelOnError: true);
    bool ok;
    try { ok = await done.future; } finally { await sub.cancel(); }
    return ok ? b.takeBytes() : null;
  }

  static Future<Map<String, dynamic>> _get(
    String path, [bool retried = false, int timeoutSec = 30]) async {
    if (url.isEmpty) throw Exception('未连接引擎');
    final cli = _client();
    try {
      final req = http.Request('GET', Uri.parse('$url$path'));
      final res = await cli.send(req).timeout(Duration(seconds: timeoutSec));
      // ① 有 Content-Length 时先拒（连下载都不下载）
      final cl = res.contentLength;
      if (cl != null && cl > _maxRespBytes) {
        try { await res.stream.drain<void>(); } catch (_) {}
        throw Exception('引擎响应过大（${(cl / 1048576).toStringAsFixed(1)}MB > 4MB），'
            '已中止以免内存溢出。请缩小关键词或加类型过滤');
      }
      // ② 流式读 + 上限
      final bytes = await _readCapped(res.stream, _maxRespBytes)
          .timeout(Duration(seconds: timeoutSec));
      if (bytes == null) {
        throw Exception('引擎响应超过 4MB 上限，已中止以免内存溢出。'
            '请缩小关键词（单字搜索通常命中源最多）或加类型过滤');
      }
      if (res.statusCode != 200) {
        // 引擎的错误响应是 JSON（{object:'error'} / {ok:false}），尽力取 message
        String detail = 'HTTP ${res.statusCode}';
        try {
          final ej = jsonDecode(utf8.decode(bytes));
          if (ej is Map) {
            detail = '${ej['data']?['message'] ?? (ej['error'] is Map ? ej['error']['message'] ?? ej['error']['code'] : ej['error']) ?? detail}';
          }
        } catch (_) {}
        throw HttpException('$detail（HTTP ${res.statusCode}）');
      }
      final j = jsonDecode(utf8.decode(bytes));
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
      // ★只有「网络层」错误才尝试重连换地址；业务错误(400/ok:false/超限)直接抛，别吞掉原因。
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

  /// 手动连接用户填的地址。接受 `192.168.1.5`、`192.168.1.5:1234`、
  /// `http://[fe80::1]:1234`、`[240e::x]:1234` 等写法；缺端口默认 1234。
  /// 返回 null 表示成功，否则返回失败原因（给界面直接显示）。
  static Future<String?> connectManual(String input) async {
    var t = input.trim();
    if (t.isEmpty) return '请输入引擎地址';
    if (!t.startsWith('http://') && !t.startsWith('https://')) t = 'http://$t';
    // 补默认端口
    try {
      final u0 = Uri.parse(t);
      if (!u0.hasPort) t = '${u0.scheme}://${u0.host}:${ThpDiscovery.kEnginePort}${u0.path}';
    } catch (_) { return '地址格式无法解析'; }
    try {
      await connect(t.replaceAll(RegExp(r'/+$'), ''));
      return null;
    } catch (e) { return _describe(e); }
  }

  /// 逐项自检（诊断页用）。返回一组 (名称, 通过?, 说明) 结果。
  /// ★这是把"搜不到"从玄学变成可读结论的关键：每一步独立可判定，
  ///   失败的那一步直接指出该修什么（网络/明文/服务/源/预算）。
  static Future<List<DiagItem>> diagnose({String? probeHost}) async {
    final out = <DiagItem>[];
    // ① 回环引擎（同机引擎 App）
    final loopOk = await ThpDiscovery.probeTcp('127.0.0.1', ThpDiscovery.kEnginePort, 500);
    out.add(DiagItem('本机回环引擎 127.0.0.1:${ThpDiscovery.kEnginePort}',
        loopOk, loopOk ? '通（本机跑着引擎 App）' : '未监听（本机没跑引擎，属正常）'));
    // ② UDP 发现端口能否绑定（被占用 → 广播永远收不到）
    var udpOk = false; String udpMsg = '';
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 19527, reuseAddress: true);
      s.close(); udpOk = true; udpMsg = '可监听 19527';
    } catch (e) { udpMsg = '无法监听 19527：$e'; }
    out.add(DiagItem('UDP 发现端口 19527', udpOk, udpMsg));
    // ③ 广播/扫描已知设备
    final known = available();
    out.add(DiagItem('已知引擎设备', known.isNotEmpty,
        known.isEmpty ? '暂无（可点「主动扫描」）' : known.map((d) => d.url).join('、')));
    // ④ 主动扫描
    final hits = await ThpDiscovery.scan(
        subnetSweep: probeHost == null, extra: [if (probeHost != null) probeHost]);
    out.add(DiagItem('主动扫描', hits.isNotEmpty,
        hits.isEmpty
            ? '扫了 ${ThpDiscovery.lastScanProbed} 项、${ThpDiscovery.lastScanMs}ms，未发现 THP 服务'
            : '发现 ${hits.length} 个：${hits.map((d) => '${d.url}(${d.name})').join('、')}'));
    // ⑤ 握手 /thp/meta
    if (url.isNotEmpty) {
      try {
        final j = await _probeMeta(url, Duration(seconds: _metaTimeoutSec));
        final m = (j['data'] is Map ? j['data'] : j) as Map;
        out.add(DiagItem('/thp/meta 握手', true,
            'v${m['version'] ?? '?'} · caps=${(m['caps'] as List? ?? []).join(',')}'));
      } catch (e) {
        out.add(DiagItem('/thp/meta 握手', false, _describe(e)));
      }
      // ⑥ 试搜：用"斗破"这种常见的双字词，避开单字（单字最吃内存）
      try {
        final sw = Stopwatch()..start();
        final p = await searchPage('all', '测试', page: 1, limit: 5, budgetSec: 8);
        sw.stop();
        out.add(DiagItem('试搜 /thp/search', true,
            '${p.items.length} 条 / 共 ${p.total} · ${sw.elapsedMilliseconds}ms'
            '${p.truncated ? ' · 被预算截断(引擎源较多)' : ''}'));
        // ⑦ 源数量（引擎没装源 = 搜得到但永远 0 结果）
        final cnt = await sourceCount();
        out.add(DiagItem('引擎书源数量', cnt > 0,
            cnt > 0 ? '$cnt 个源已就绪' : '0 个源！请到引擎 App 导入书源（这是"能搜但没结果"的头号原因）'));
      } catch (e) {
        out.add(DiagItem('试搜 /thp/search', false, _describe(e)));
      }
    } else {
      out.add(DiagItem('/thp/meta 握手', false, '尚未连接任何引擎'));
    }
    return out;
  }

  /// 引擎内已就绪的书源数量。引擎未提供该端点时返回 -1（不报错）。
  /// ★"能连上、能搜、但一条结果都没有"最常见的根因就是源为 0。
  static Future<int> sourceCount() async {
    for (final p in const ['/thp/sources?count=1', '/thp/meta']) {
      try {
        final r = await _get(p, true, _metaTimeoutSec);
        final d = r['data'];
        if (d is Map) {
          for (final k in const ['count', 'total', 'sourceCount', 'sources']) {
            final v = d[k];
            if (v is int) return v;
            if (v is List) return v.length;
            final n = int.tryParse('${v ?? ''}');
            if (n != null) return n;
          }
        } else if (d is List) {
          return d.length;
        }
      } catch (_) {}
    }
    return -1;
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
