// 端间互通的网络与心跳层（PH/1 客户端）。
//
// 分工：peer_hub_logic.dart 是纯逻辑内核（可纯 Dart 自检，292/0）；
//       本文件只做 I/O —— HTTP、持久化、定时心跳、UI 通知。
//       所以本文件**不应出现任何新的判定逻辑**，判定一律委托给内核。
//
// 三层可用性（这是设计目标，改动前先确认没破坏它）：
//   ① 有后端    → 一切走后端（join/list/invoke/secrets 全通）
//   ② 无后端    → 用本地缓存的端列表 + 直连插件（/peer/exec）
//   ③ 什么都没  → 返回明确的原因字符串，绝不假装成功
//
// 与 AgentDshClient 的关系：两者都连同一个后端，但职责不同 ——
//   AgentDshClient 管"会话/事件/工具调用"；本文件管"有哪些端/谁是中枢/密钥同步"。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'peer_hub_logic.dart';

export 'peer_hub_logic.dart';

// ─────────────────────────────────────────────────────────────────────────
// HTTP 基座
// ─────────────────────────────────────────────────────────────────────────
class _Resp {
  final int code;
  final String text;
  final String error;
  const _Resp(this.code, this.text, [this.error = '']);
  bool get ok => code >= 200 && code < 300;
  @override
  String toString() => 'Resp($code${error.isEmpty ? "" : " $error"})';
}

class _Http {
  static HttpClient? _c;

  static HttpClient get _client {
    final c = _c;
    if (c != null) return c;
    final n = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 20)
      // 家庭后端起的是自签证书 —— 与 AgentDshClient 同样的放行策略。
      ..badCertificateCallback = (_, __, ___) => true;
    _c = n;
    return n;
  }

  static Future<_Resp> send(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    int timeoutMs = 9000,
  }) async {
    if (url.isEmpty) return const _Resp(0, '', '空地址');
    HttpClientRequest req;
    try {
      final u = Uri.parse(url);
      req = await _client.openUrl(method, u).timeout(Duration(milliseconds: timeoutMs));
    } catch (e) {
      return _Resp(0, '', '连不上 ${PeerUrl.hostOf(url)}: ${_short(e)}');
    }
    try {
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      headers.forEach(req.headers.set);
      if (body != null) req.write(jsonEncode(body));
      final r = await req.close().timeout(Duration(milliseconds: timeoutMs));
      final t = await r.transform(utf8.decoder).join().timeout(Duration(milliseconds: timeoutMs));
      return _Resp(r.statusCode, t);
    } catch (e) {
      return _Resp(0, '', _short(e));
    }
  }

  static String _short(Object e) {
    var s = e.toString();
    final i = s.indexOf(':');
    if (s.length > 160) s = '${s.substring(0, 160)}…';
    return i > 0 && s.length > 80 ? s : s;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 一次端间调用的结果
// ─────────────────────────────────────────────────────────────────────────
class PeerCallResult {
  final bool ok;
  final PeerVia via;
  final PeerInfo? peer;
  final String base;
  final dynamic result;
  final String error;

  const PeerCallResult({
    required this.ok,
    required this.via,
    this.peer,
    this.base = '',
    this.result,
    this.error = '',
  });

  /// 失败但"以何种理由失败"要能直接展示 —— 这三类问题的处理方式完全不同：
  ///   没端能接  → 去装个插件 / 打开后端
  ///   目标离线  → 等它上线
  ///   没地址    → 去插件侧填 url/穿透地址
  bool get isNoRoute => error.startsWith('NO_ROUTE');
  bool get isOffline => error.startsWith('PEER_OFFLINE');
  bool get isNoAddress => error.startsWith('NO_ADDRESS');

  factory PeerCallResult.fail(String code, String msg, {PeerVia via = PeerVia.direct}) =>
      PeerCallResult(ok: false, via: via, error: '$code: $msg');

  @override
  String toString() => ok ? 'OK(${via.name}${base.isEmpty ? "" : " @$base"})' : error;
}

// ─────────────────────────────────────────────────────────────────────────
// 端间互通客户端
// ─────────────────────────────────────────────────────────────────────────
class PeerHubClient {
  /// 后端地址与密钥（由 main.dart 在设置变化时写入，同 AgentDshClient 的做法）。
  static String base = '';
  static String token = '';

  static bool get configured => base.trim().isNotEmpty;

  /// 本端身份（join 后填）。
  static String myIid = '';
  static String myToken = '';

  static const String _kIid = 'peer_iid';
  static const String _kToken = 'peer_token';
  static const String _kCache = 'peer_cache';        // 端列表缓存（无后端时靠它）
  static const String _kSecrets = 'peer_secrets';    // 密钥本地副本
  static const String _kSecretsAt = 'peer_secrets_at';

  static const String kindFront = 'front';

  // ── URL 组装 ──
  static String _ep(String path) => PeerUrl.join(base, path);

  // ── 持久化 ──
  static SharedPreferences? _sp;

  static Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  static Future<void> loadIdentity() async {
    try {
      final p = await _prefs();
      myIid = p.getString(_kIid) ?? '';
      myToken = p.getString(_kToken) ?? '';
    } catch (_) {}
  }

  static Future<void> _saveIdentity() async {
    try {
      final p = await _prefs();
      await p.setString(_kIid, myIid);
      await p.setString(_kToken, myToken);
    } catch (_) {}
  }

  static Future<void> clearIdentity() async {
    myIid = '';
    myToken = '';
    try {
      final p = await _prefs();
      await p.remove(_kIid);
      await p.remove(_kToken);
    } catch (_) {}
  }

  /// 端列表缓存：无后端时 `list()` 回落读它，UI 仍能显示"上次看到过哪些插件"。
  static Future<void> _saveCache(PeerRegistry reg) async {
    try {
      final p = await _prefs();
      await p.setString(_kCache, jsonEncode({'peers': reg.peers.map((e) => e.toJson()).toList()}));
    } catch (_) {}
  }

  static Future<PeerRegistry> loadCache() async {
    try {
      final p = await _prefs();
      final s = p.getString(_kCache) ?? '';
      if (s.isEmpty) return PeerRegistry.empty;
      return PeerRegistry.fromJson(PeerJson.obj(s));
    } catch (_) {
      return PeerRegistry.empty;
    }
  }

  // ── join ──
  /// 端/插件上线。凭据二选一：后端密钥（token）或账号口令。
  /// 已持 peerToken 时无需再传凭据（自动续期）。
  static Future<Map<String, dynamic>> join({
    String kind = kindFront,
    String name = '',
    String url = '',
    String ipv6 = '',
    String tunnel = '',
    List<String> caps = const [],
    List<String> tools = const [],
    String account = '',
    String password = '',
  }) async {
    final ep = _ep('/agent/peer/join');
    if (ep.isEmpty) return {'ok': false, 'error': '未配置后端地址'};
    final body = <String, dynamic>{
      'kind': kind,
      'name': name,
      'url': url,
      'ipv6': ipv6,
      'tunnel': tunnel,
      'caps': caps,
      'tools': tools,
      if (myIid.isNotEmpty) 'iid': myIid,
      if (myToken.isNotEmpty) 'peerToken': myToken,
      if (myToken.isEmpty && token.isNotEmpty) 'token': token,
      if (myToken.isEmpty && account.isNotEmpty) 'account': account,
      if (myToken.isEmpty && account.isNotEmpty) 'password': password,
    };
    final r = await _Http.send('POST', ep, body: body);
    if (!r.ok) {
      final e = r.error.isNotEmpty ? r.error : PeerJson.errOf(r.text);
      return {'ok': false, 'error': e.isEmpty ? 'HTTP ${r.code}' : e};
    }
    final d = PeerJson.unwrap(r.text);
    if (d is! Map) return {'ok': false, 'error': '响应格式异常'};
    final m = Map<String, dynamic>.from(d);
    final t = (m['peerToken'] ?? '').toString();
    final iid = (m['iid'] ?? '').toString();
    if (t.isNotEmpty) {
      myToken = t;
      myIid = iid.isEmpty ? myIid : iid;
      await _saveIdentity();
    }
    return {'ok': true, 'iid': myIid, 'online': m['online'], 'hub': m['hub']};
  }

  /// 心跳（含增量字段更新：能力/地址变了不用重新 join）。
  static Future<bool> beat({
    String? url,
    String? ipv6,
    String? tunnel,
    List<String>? caps,
    List<String>? tools,
  }) async {
    final ep = _ep('/agent/peer/beat');
    if (ep.isEmpty || myToken.isEmpty) return false;
    final r = await _Http.send('POST', ep, body: {
      'peerToken': myToken,
      if (url != null) 'url': url,
      if (ipv6 != null) 'ipv6': ipv6,
      if (tunnel != null) 'tunnel': tunnel,
      if (caps != null) 'caps': caps,
      if (tools != null) 'tools': tools,
    }, timeoutMs: 7000);
    return r.ok;
  }

  /// 端列表。**无后端时回落本地缓存**（并标注 fromCache），这样 UI 不会空白。
  static Future<PeerRegistry> list({bool refresh = true}) async {
    if (refresh && configured && myToken.isNotEmpty) {
      final r = await _Http.send('GET', '${_ep('/agent/peer/list')}?peerToken=$myToken');
      if (r.ok) {
        final d = PeerJson.unwrap(r.text);
        if (d is Map) {
          final reg = PeerRegistry.fromJson(Map<String, dynamic>.from(d));
          await _saveCache(reg);
          return reg;
        }
      }
    }
    return loadCache();
  }

  /// 拉取收件箱（增量）。
  static Future<List<PeerMsg>> pull({String topic = '', String cursor = ''}) async {
    final ep = _ep('/agent/peer/pull');
    if (ep.isEmpty || myToken.isEmpty) return const [];
    final q = StringBuffer('?peerToken=$myToken');
    if (topic.isNotEmpty) q.write('&topic=$topic');
    if (cursor.isNotEmpty) q.write('&since=$cursor');
    final r = await _Http.send('GET', '$ep$q');
    if (!r.ok) return const [];
    final d = PeerJson.unwrap(r.text);
    if (d is! Map) return const [];
    return PeerJson.arr(d['msgs']).map(PeerMsg.fromJson).toList();
  }

  static Future<List<PeerMsg>> inbox({String topic = '', String cursor = ''}) async {
    final raw = await pull(topic: topic, cursor: cursor);
    return PeerInbox.dedupe(PeerInbox.filter(raw, myIid, topic: topic, cursor: cursor));
  }

  /// 广播 / 定向投递 —— 『一方输入，其他方都能用』的入口。
  static Future<bool> relay(Map<String, dynamic> payload, {String to = '', String topic = 'input'}) async {
    final ep = _ep('/agent/peer/relay');
    if (ep.isEmpty || myToken.isEmpty) return false;
    final r = await _Http.send('POST', ep, body: {
      'peerToken': myToken,
      'to': to,
      'topic': topic,
      'payload': payload,
    });
    return r.ok;
  }

  // ── 跨端调用 ──
  /// 让某个端执行一个工具。**这是"端到端控制层"的唯一入口。**
  ///
  /// 路径选择完全交给 PeerRouter（内核），这里只负责把选好的路走通：
  ///   hub    → POST {后端}/agent/peer/invoke（后端代转发）
  ///   direct → POST {插件}/peer/exec（无后端，直连插件）
  static Future<PeerCallResult> invoke(
    String cap, {
    String? tool,
    Map<String, dynamic> args = const {},
    String? preferIid,
    PeerRegistry? registry,
  }) async {
    final reg = registry ?? await list();
    final route = PeerRouter.route(reg, cap: cap, preferIid: preferIid);
    if (route == null) {
      return PeerCallResult.fail('NO_ROUTE', '没有端能接「$cap」（未装插件或后端未启用相关能力）');
    }
    if (route.via == PeerVia.local) {
      return PeerCallResult.fail('LOCAL', '「$cap」应由本机离线能力处理，不该跨端调用', via: PeerVia.local);
    }
    if (route.peer == null) {
      return PeerCallResult.fail('NO_ADDRESS', route.reason);
    }
    final name = route.peer!.name.isEmpty ? route.peer!.iid : route.peer!.name;
    final t = (tool == null || tool.isEmpty) ? cap : tool;

    if (route.via == PeerVia.hub) {
      final ep = _ep('/agent/peer/invoke');
      if (ep.isEmpty) return PeerCallResult.fail('PEER_OFFLINE', '未配置后端，无法转发给 $name');
      final r = await _Http.send('POST', ep, body: {
        'peerToken': myToken,
        'to': route.peer!.iid,
        'tool': t,
        'args': args,
      }, timeoutMs: 20000);
      if (!r.ok) {
        return _mapFail(PeerJson.obj(r.text), r.code, name);
      }
      final d = PeerJson.unwrap(r.text);
      final m = d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
      return PeerCallResult(
        ok: true, via: PeerVia.hub, peer: route.peer,
        base: (m['via'] ?? '').toString(), result: m['result'],
      );
    }

    // 直连
    final url = PeerUrl.join(route.base, '/peer/exec');
    final r = await _Http.send('POST', url, body: {
      'tool': t,
      'args': args,
      'from': myIid,
    }, timeoutMs: 20000);
    if (!r.ok) {
      final msg = r.error.isNotEmpty ? r.error : 'HTTP ${r.code}';
      return PeerCallResult.fail('INVOKE_FAILED', '$name: $msg', via: PeerVia.direct);
    }
    final j = PeerJson.obj(r.text);
    if (j['ok'] == false) {
      final e = j['error'];
      final em = e is Map ? (e['message'] ?? '').toString() : '';
      return PeerCallResult.fail('INVOKE_FAILED', '$name: ${em.isEmpty ? "插件返回失败" : em}', via: PeerVia.direct);
    }
    return PeerCallResult(
      ok: true, via: PeerVia.direct, peer: route.peer, base: route.base,
      result: j.containsKey('data') ? j['data'] : j,
    );
  }

  /// 后端返回的业务错误码要原样保留（PEER_OFFLINE / PEER_NO_URL …），
  /// 因为它们对应三种完全不同的用户动作，压成一个"调用失败"就没法指导用户了。
  static PeerCallResult _mapFail(Map<String, dynamic> j, int code, String name) {
    final e = j['error'];
    if (e is Map) {
      final c = (e['code'] ?? '').toString();
      final m = (e['message'] ?? '').toString();
      if (c.isNotEmpty) return PeerCallResult.fail(c, m.isEmpty ? name : m, via: PeerVia.hub);
    }
    return PeerCallResult.fail('INVOKE_FAILED', '$name: HTTP $code', via: PeerVia.hub);
  }

  // ── 密钥统一 ──
  static Future<Map<String, dynamic>> localSecrets() async {
    try {
      final p = await _prefs();
      final s = p.getString(_kSecrets) ?? '';
      return s.isEmpty ? <String, dynamic>{} : PeerJson.obj(s);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _saveSecrets(Map<String, dynamic> m) async {
    try {
      final p = await _prefs();
      await p.setString(_kSecrets, jsonEncode(m));
      await p.setInt(_kSecretsAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> remoteSecrets() async {
    final ep = _ep('/agent/peer/secrets');
    if (ep.isEmpty || myToken.isEmpty) return <String, dynamic>{};
    final r = await _Http.send('GET', ep, headers: {'X-TH-Peer': myToken});
    if (!r.ok) return <String, dynamic>{};
    final d = PeerJson.unwrap(r.text);
    if (d is! Map) return <String, dynamic>{};
    final s = d['secrets'];
    return s is Map ? Map<String, dynamic>.from(s) : <String, dynamic>{};
  }

  /// 双向同步。返回报告供 UI 显示"拉了几条、推了几条、几条冲突"。
  static Future<SecretMergeReport> syncSecrets() async {
    final local = PeerSecretStore.canonMap(await localSecrets());
    final remote = PeerSecretStore.canonMap(await remoteSecrets());
    final rep = SecretMerge.merge(local, remote);
    // 先拉（远端更新），再推（本地更新）
    var now = SecretMerge.applyPull(local, remote, rep.pull);
    await _saveSecrets(now);
    if (rep.push.isNotEmpty) {
      final ep = _ep('/agent/peer/secrets');
      if (ep.isNotEmpty && myToken.isNotEmpty) {
        final body = SecretMerge.pushBody(now, rep);
        (body as Map)['peerToken'] = myToken;
        final r = await _Http.send('POST', ep, body: body);
        if (r.ok) {
          // 推成功后把本地 rev 对齐远端（否则下次还会判成 push，无限重推）
          final after = await remoteSecrets();
          now = SecretMerge.applyPull(now, after, rep.push);
          await _saveSecrets(now);
        }
      }
    }
    return rep;
  }

  /// 本端写一条密钥（随后由 syncSecrets 统一到其他端）。
  static Future<void> putSecret(String name, String value) async {
    final m = PeerSecretStore.canonMap(await localSecrets());
    final k = SecretMerge.canonKey(name);
    if (k.isEmpty) return;
    final cur = m[k];
    final rev = cur is Map ? ((cur['rev'] as num?)?.toInt() ?? 0) + 1 : 1;
    m[k] = {'value': value, 'rev': rev, 'updatedAt': DateTime.now().millisecondsSinceEpoch, 'from': myIid};
    await _saveSecrets(m);
  }

  static Future<void> delSecret(String name) async {
    final m = PeerSecretStore.canonMap(await localSecrets());
    m.remove(SecretMerge.canonKey(name));
    await _saveSecrets(m);
  }

  /// 读一条密钥的明文（keys 类工具用）。
  static Future<String> getSecret(String name) async {
    final m = await localSecrets();
    final e = m[SecretMerge.canonKey(name)];
    if (e is Map) return (e['value'] ?? '').toString();
    return e == null ? '' : e.toString();
  }

  static Future<List<String>> secretNames() async {
    final m = await localSecrets();
    final out = m.keys.toList()..sort();
    return out;
  }

  /// 诊断文本：UI 的"为什么连不上"面板直接用。
  static Future<String> diagnose() async {
    final sb = StringBuffer();
    sb.writeln('后端地址: ${base.isEmpty ? "(未配置)" : base}');
    sb.writeln('已配密钥: ${token.isEmpty ? "否" : "是"}');
    sb.writeln('本端 iid: ${myIid.isEmpty ? "(未注册)" : myIid}');
    sb.writeln('本端令牌: ${myToken.isEmpty ? "(无)" : "有(已隐藏)"}');
    if (!configured) {
      sb.writeln('\n→ 未配置后端。仍可用：本地离线能力 + 直连已缓存地址的插件。');
      final c = await loadCache();
      sb.writeln('缓存里 ${c.peers.length} 个端，其中在线 ${c.online.length}');
      return sb.toString();
    }
    if (myToken.isEmpty) {
      sb.writeln('\n→ 还没 join。需要账号口令或后端密钥才能接入端网。');
      return sb.toString();
    }
    final r = await _Http.send('GET', '${_ep('/agent/peer/diag')}?peerToken=$myToken', timeoutMs: 7000);
    if (!r.ok) {
      sb.writeln('\n→ 后端不可达：${r.error.isEmpty ? "HTTP ${r.code}" : r.error}');
      sb.writeln('  已回落为直连模式（用缓存地址调插件）。');
      final c = await loadCache();
      for (final p in c.peers) {
        sb.writeln('  · ${p.name.isEmpty ? p.iid : p.name} [${peerKindName(p.kind)}]'
            '${p.online ? "" : " 离线"} 路由=${p.routes.length}');
      }
      return sb.toString();
    }
    final d = PeerJson.unwrap(r.text);
    if (d is Map) {
      final peers = PeerJson.arr(d['peers']);
      sb.writeln('\n后端可达。在线端 ${peers.length} 个：');
      for (final p in peers) {
        final pi = PeerInfo.fromJson(p);
        sb.writeln('  · ${pi.name.isEmpty ? pi.iid : pi.name} [${peerKindName(pi.kind)}]'
            '${pi.caps.isEmpty ? "" : " caps=${pi.caps.join("/")}"}'
            '${pi.tools.isEmpty ? "" : " tools=${pi.tools.length}"}'
            '${pi.routes.isEmpty ? " (无直连地址)" : ""}');
      }
      final hints = d['hints'];
      if (hints is List && hints.isNotEmpty) {
        sb.writeln('\n建议：');
        for (final h in hints) {
          sb.writeln('  · $h');
        }
      }
      sb.writeln('\n密钥 ${d['secrets'] ?? 0} 条 · 账号 ${d['accounts'] ?? 0} 个');
    }
    return sb.toString();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 密钥本地副本（键名归一写在 PeerSecretStore，避免各处各写一套归一规则）
// ─────────────────────────────────────────────────────────────────────────
class PeerSecretStore {
  static Map<String, dynamic> canonMap(Map<String, dynamic> src) => SecretMerge.canonAll(src);
}

// ─────────────────────────────────────────────────────────────────────────
// 运行时：定时心跳 + 注册表缓存 + UI 通知
// ─────────────────────────────────────────────────────────────────────────
class PeerHubRuntime {
  static const Duration beatEvery = Duration(seconds: 15);

  static PeerRegistry registry = PeerRegistry.empty;
  static String status = '未连接';
  static String lastError = '';
  static bool running = false;

  /// 本端对外可达地址的提供者（由 main.dart 注入：读设置里的穿透地址、网卡 IPv6）。
  /// 不注入时上报空 —— 前端仍可用，只是别的端不能反向直连它。
  static Map<String, String> Function()? addressProvider;

  /// 本端对外声明的能力与工具（由 main.dart 注入：离线工具清单 + 后端能力）。
  static Map<String, List<String>> Function()? capabilityProvider;

  static Timer? _t;
  static final StreamController<PeerRegistry> _ctrl =
      StreamController<PeerRegistry>.broadcast();
  static Stream<PeerRegistry> get changes => _ctrl.stream;

  static void _emit() {
    if (!_ctrl.isClosed) _ctrl.add(registry);
  }

  /// 本机在端网里的显示名。
  ///
  /// 必须存成字段：`start()` 有 `name` 形参，但 `tick()` 没有 —— 心跳是周期性
  /// 重连，不该每次重带一遍身份。之前 `tick()` 里直接写 `name: name`，引用了一个
  /// 该作用域里不存在的标识符；语法检查看不出来，直到真编译才炸。
  static String selfName = '我的手机';

  /// 启动：加载身份 → 缓存先上屏 → join → 立刻 beat 一次 → 定时心跳。
  static Future<void> start({String name = '我的手机'}) async {
    if (running) return;
    running = true;
    selfName = name;
    await PeerHubClient.loadIdentity();
    registry = (await PeerHubClient.list(refresh: false)).stamped(DateTime.now().millisecondsSinceEpoch);
    _emit();

    if (!PeerHubClient.configured) {
      status = '离线模式（未配置后端）';
      // 没后端也要起定时器：定期重算在线态，让 UI 及时把过期端标为离线。
      _t = Timer.periodic(beatEvery, (_) => tick(doJoin: false));
      return;
    }
    await tick(doJoin: true);
    _t = Timer.periodic(beatEvery, (_) => tick(doJoin: false));
  }

  static void stop() {
    running = false;
    _t?.cancel();
    _t = null;
  }

  /// 一次心跳周期。doJoin=true 时会（重新）join，用于首次与断线恢复。
  static Future<void> tick({bool doJoin = false}) async {
    if (!PeerHubClient.configured) {
      // 无后端：只重算在线态 + 刷新缓存视图
      registry = (await PeerHubClient.list(refresh: false))
          .stamped(DateTime.now().millisecondsSinceEpoch);
      status = PeerRouter.summarize(registry);
      _emit();
      return;
    }
    final needJoin = doJoin || PeerHubClient.myToken.isEmpty;
    if (needJoin) {
      final addr = addressProvider?.call() ?? const <String, String>{};
      final caps = capabilityProvider?.call() ?? const <String, List<String>>{};
      final r = await PeerHubClient.join(
        name: selfName,
        url: addr['url'] ?? '',
        ipv6: addr['ipv6'] ?? '',
        tunnel: addr['tunnel'] ?? '',
        caps: caps['caps'] ?? const ['front'],
        tools: caps['tools'] ?? const [],
      );
      if (r['ok'] != true) {
        lastError = (r['error'] ?? '').toString();
        status = '接入失败：$lastError';
        registry = (await PeerHubClient.loadCache())
            .stamped(DateTime.now().millisecondsSinceEpoch);
        _emit();
        return;
      }
      lastError = '';
    } else {
      final ok = await PeerHubClient.beat();
      if (!ok) {
        // 心跳不通 = 后端掉了 → 回到"无后端直连"模式，但**保留令牌**，
        // 下次心跳成功即自动恢复（不需要用户重新输密码）。
        lastError = '心跳失败（后端可能已离线）';
      } else {
        lastError = '';
      }
    }
    registry = (await PeerHubClient.list())
        .stamped(DateTime.now().millisecondsSinceEpoch);
    status = PeerRouter.summarize(registry);
    _emit();
  }

  /// App 回到前台/设置变更后手动刷新。
  static Future<void> refresh() => tick(doJoin: PeerHubClient.myToken.isEmpty);

  static void dispose() {
    stop();
    if (!_ctrl.isClosed) _ctrl.close();
  }
}
