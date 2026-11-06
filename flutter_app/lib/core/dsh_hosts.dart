// DSH 引擎来源管理：本机 / 远程，带优先策略与会话聚合。
//
// 用户需求（2026-11-06）：
//   「我希望产品能在本机运行，也能在 NAS 上运行。像 Kimi 那样把后台删掉，
//     它也在远端继续跑，再打开时把结果同步过来。」
//   「两者数据打通：本机跑了什么自动同步到桌面端，也可以选优先方式（优先本机/优先桌面）。」
//
// 关键认识（这是整套设计的支点）：
//   DSH 的会话是**跑在 Host 上**的，客户端只是 UI。所以「切到远端继续跑」不需要发明任何同步协议 ——
//   Host 侧一直在跑，客户端重新连上后用 `events(sessionId, since: lastSeq)` 把漏掉的事件补回来。
//   这个能力 `agent_dsh_client.dart` 里已经有了（events / streamEvents 都带 since）。
//
// 本文件解决的是**它上面那一层**：
//   ① 记住多个 Host（本机 127.0.0.1、家里的电脑、NAS），而不是只记一个 base
//   ② 按用户设的「优先方式」决定连谁，连不上自动降级到下一个
//   ③ 把多个 Host 的会话列表合并成一个视图，用户不用关心它是在哪台机器上跑的
//
// ★ 本机 Host（PRoot + Node）还没实现，这里先把接口留好。
//   等原生层接上后，只要把 `localBase` 填成 `http://127.0.0.1:<port>`，其余逻辑不用改。

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 一个 DSH Host。
class DshHost {
  const DshHost({
    required this.id,
    required this.name,
    required this.base,
    this.token = '',
    this.kind = DshHostKind.remote,
  });

  final String id;
  final String name;
  final String base;
  final String token;
  final DshHostKind kind;

  bool get isLocal => kind == DshHostKind.local;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'base': base,
        'token': token,
        'kind': kind.name,
      };

  static DshHost fromJson(Map<String, dynamic> j) => DshHost(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? '未命名'}',
        base: '${j['base'] ?? ''}',
        token: '${j['token'] ?? ''}',
        kind: DshHostKind.values.firstWhere(
          (e) => e.name == '${j['kind']}',
          orElse: () => DshHostKind.remote,
        ),
      );
}

enum DshHostKind { local, remote }

/// 优先方式。
enum DshPrefer {
  /// 先试本机，不通再连远程
  localFirst,

  /// 先试远程（电脑/NAS），不通再退回本机
  remoteFirst,

  /// 只用本机，不去连远程
  localOnly,

  /// 只用远程，不在手机上跑
  remoteOnly,
}

/// 会话在哪个 Host 上。
class DshSessionRef {
  const DshSessionRef({
    required this.hostId,
    required this.sessionId,
    required this.title,
    required this.updatedAt,
    required this.running,
  });

  final String hostId;
  final String sessionId;
  final String title;
  final int updatedAt;

  /// Host 侧是否还在跑（这是「杀后台任务还在跑」的可视化依据）
  final bool running;
}

class DshHosts {
  static const _kHosts = 'dsh_hosts_v1';
  static const _kPrefer = 'dsh_prefer';
  static const _kActive = 'dsh_active_host';

  static List<DshHost> _hosts = const [];
  static DshPrefer _prefer = DshPrefer.remoteFirst;
  static String _active = '';

  static List<DshHost> get hosts => _hosts;
  static DshPrefer get prefer => _prefer;

  /// 当前生效的 Host（可能为空 = 一个都没连上）
  static DshHost? get active {
    for (final h in _hosts) {
      if (h.id == _active) return h;
    }
    return null;
  }

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kHosts) ?? '';
    if (raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          _hosts = [
            for (final e in list)
              if (e is Map) DshHost.fromJson(Map<String, dynamic>.from(e))
          ];
        }
      } catch (_) {
        _hosts = const [];
      }
    }
    _prefer = DshPrefer.values.firstWhere(
      (e) => e.name == (p.getString(_kPrefer) ?? ''),
      orElse: () => DshPrefer.remoteFirst,
    );
    _active = p.getString(_kActive) ?? '';
  }

  static Future<void> saveHosts() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kHosts, jsonEncode(_hosts.map((e) => e.toJson()).toList()));
  }

  static Future<void> setPrefer(DshPrefer v) async {
    _prefer = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPrefer, v.name);
  }

  /// 增/改一个 Host（按 id 覆盖）。
  static Future<void> upsert(DshHost h) async {
    final list = [..._hosts];
    final i = list.indexWhere((e) => e.id == h.id);
    if (i >= 0) {
      list[i] = h;
    } else {
      list.add(h);
    }
    _hosts = list;
    await saveHosts();
  }

  static Future<void> remove(String id) async {
    _hosts = _hosts.where((e) => e.id != id).toList();
    if (_active == id) _active = '';
    await saveHosts();
  }

  /// 探活：能不能连上、是不是 DSH。超时 4 秒（本地应该秒回，远程也不该等太久）。
  static Future<bool> probe(DshHost h) async {
    if (h.base.trim().isEmpty) return false;
    try {
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4)
        ..badCertificateCallback = (_, __, ___) => true;
      final req = await c.getUrl(Uri.parse('${h.base}/agent/health'));
      if (h.token.isNotEmpty) req.headers.set('X-TH-Token', h.token);
      final r = await req.close().timeout(const Duration(seconds: 5));
      await r.drain<void>();
      c.close();
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// 按优先方式挑一个可用 Host 并设为当前。
  ///
  /// 返回选中的 Host（null = 一个都连不上）。
  /// 这个方法的产物会被写进 `AgentDshClient.base/token` —— 调用方负责这一步，
  /// 因为 client 是底层，不该反过来 import 本文件。
  static Future<DshHost?> pick() async {
    final locals = _hosts.where((h) => h.isLocal).toList();
    final remotes = _hosts.where((h) => !h.isLocal).toList();

    List<DshHost> order;
    switch (_prefer) {
      case DshPrefer.localFirst:
        order = [...locals, ...remotes];
      case DshPrefer.remoteFirst:
        order = [...remotes, ...locals];
      case DshPrefer.localOnly:
        order = locals;
      case DshPrefer.remoteOnly:
        order = remotes;
    }

    for (final h in order) {
      if (await probe(h)) {
        _active = h.id;
        final p = await SharedPreferences.getInstance();
        await p.setString(_kActive, h.id);
        return h;
      }
    }
    _active = '';
    final p = await SharedPreferences.getInstance();
    await p.remove(_kActive);
    return null;
  }

  /// 拉所有在线 Host 的会话并合并成一个列表。
  ///
  /// 为什么合并而不是让用户先选 Host：
  ///   用户关心的是「我那个任务跑到哪了」，不关心它在哪台机器上跑。
  ///   按 updatedAt 倒序排，最近动过的在最上面。
  static Future<List<DshSessionRef>> allSessions() async {
    final out = <DshSessionRef>[];
    for (final h in _hosts) {
      try {
        final c = HttpClient()
          ..connectionTimeout = const Duration(seconds: 4)
          ..badCertificateCallback = (_, __, ___) => true;
        final req = await c.getUrl(
            Uri.parse('${h.base}/agent/sessions?limit=30'));
        if (h.token.isNotEmpty) req.headers.set('X-TH-Token', h.token);
        final r = await req.close().timeout(const Duration(seconds: 6));
        final body = await r.transform(utf8.decoder).join();
        c.close();
        if (r.statusCode < 200 || r.statusCode >= 300) continue;
        final j = jsonDecode(body);
        final data = (j is Map ? j['data'] : null) ?? j;
        if (data is! List) continue;
        for (final e in data) {
          if (e is! Map) continue;
          out.add(DshSessionRef(
            hostId: h.id,
            sessionId: '${e['id'] ?? e['sessionId'] ?? ''}',
            title: '${e['title'] ?? e['name'] ?? '未命名会话'}',
            updatedAt: (e['updatedAt'] as num?)?.toInt() ??
                (e['updated_at'] == null
                    ? 0
                    : DateTime.tryParse('${e['updated_at']}')
                            ?.millisecondsSinceEpoch ??
                        0),
            running: e['running'] == true || e['status'] == 'running',
          ));
        }
      } catch (_) {
        // 某台连不上就跳过，不影响其他 Host 的会话展示
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 把「本机会话」迁到远端（用户要的「本机数据同步到桌面端」）。
  ///
  /// 做法不是搬数据库，而是**把事件流原样重放到目标 Host** ——
  /// 两边是同一套 session 事件模型，重放即可得到等价会话，且不依赖两边的存储实现。
  /// 返回迁移的事件条数（0 = 没东西可迁）。
  static Future<int> migrateSession(
    String sessionId, {
    required String fromHostId,
    required String toHostId,
  }) async {
    DshHost? from, to;
    for (final h in _hosts) {
      if (h.id == fromHostId) from = h;
      if (h.id == toHostId) to = h;
    }
    if (from == null || to == null) return 0;

    // 1) 从源 Host 把所有事件拉全（分页直到 lastSeq 不再前进）
    final all = <Map<String, dynamic>>[];
    var since = 0;
    for (var guard = 0; guard < 200; guard++) {
      final r = await _getJson(
          from, '/agent/events?sessionId=$sessionId&since=$since&limit=500');
      if (r == null) break;
      final data = (r['data'] as List?) ?? const [];
      final lastSeq = ((r['meta'] as Map?)?['lastSeq'] as num?)?.toInt() ?? since;
      for (final e in data) {
        if (e is Map) all.add(Map<String, dynamic>.from(e));
      }
      if (lastSeq <= since || data.isEmpty) break;
      since = lastSeq;
    }
    if (all.isEmpty) return 0;

    // 2) 在目标 Host 建同名会话并重放
    final created = await _postJson(to, '/agent/session', {'title': sessionId});
    final newId = '${(created?['data'] as Map?)?['id'] ?? ''}';
    if (newId.isEmpty) return 0;
    var n = 0;
    for (final e in all) {
      final ok = await _postJson(to, '/agent/event', {
        'sessionId': newId,
        'type': '${e['type'] ?? 'message'}',
        'payload': e['payload'] ?? {},
      });
      if (ok != null) n++;
    }
    return n;
  }

  static Future<Map<String, dynamic>?> _getJson(DshHost h, String path) async {
    try {
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..badCertificateCallback = (_, __, ___) => true;
      final req = await c.getUrl(Uri.parse('${h.base}$path'));
      if (h.token.isNotEmpty) req.headers.set('X-TH-Token', h.token);
      final r = await req.close().timeout(const Duration(seconds: 10));
      final body = await r.transform(utf8.decoder).join();
      c.close();
      if (r.statusCode < 200 || r.statusCode >= 300) return null;
      final j = jsonDecode(body);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _postJson(
      DshHost h, String path, Map<String, dynamic> body) async {
    try {
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..badCertificateCallback = (_, __, ___) => true;
      final req = await c.postUrl(Uri.parse('${h.base}$path'));
      req.headers.contentType = ContentType.json;
      if (h.token.isNotEmpty) req.headers.set('X-TH-Token', h.token);
      req.write(jsonEncode(body));
      final r = await req.close().timeout(const Duration(seconds: 15));
      final txt = await r.transform(utf8.decoder).join();
      c.close();
      if (r.statusCode < 200 || r.statusCode >= 300) return null;
      final j = txt.isEmpty ? null : jsonDecode(txt);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }
}
