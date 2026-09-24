// ═══════════════════════════════════════════════════════════════════════════
// THA/1 · DSH 客户端（Flutter 侧唯一的 Agent 后端入口）
//
// 只做 HTTP，不引第三方包 —— 与 tts_presets.dart 的 TtsBackend 同款写法
// （局域网自签证书，badCertificateCallback 直接放行）。
//
// 三个约定：
//   · base/token 由 main.dart 在连上后端时写入（与 TtsBackend 同源）；
//   · 所有响应信封都是 {object, data, meta}，解析统一走 _data()；
//   · 任何失败都返回 null / 空表，**不抛异常** —— 调用方据此降级到轻量模式，
//     不该因为「后端没开」而让 AI 功能整个炸掉。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_models.dart';
import 'agent_policy.dart';

class AgentDshClient {
  /// 后端根地址（如 https://192.168.1.5:9527），由 main.dart 写入
  static String base = '';

  /// 配对密钥，随请求头 X-TH-Token
  static String token = '';

  static bool get configured => base.trim().isNotEmpty;

  static const _short = Duration(seconds: 8);
  static const _long = Duration(seconds: 30);

  // ── HTTP 底座 ───────────────────────────────────────────────────────────
  // 不能写成 `HttpClient()..a = (_, __, ___) => true ..b = x`：
  // 第二个 `..` 会被解析成对 lambda 体 `true` 的级联（而不是对 HttpClient），
  // 编译器会报 "The setter 'b' isn't defined for the type 'bool'"。老老实实写块体。
  static HttpClient _client() {
    final c = HttpClient();
    c.badCertificateCallback = (_, __, ___) => true;
    c.connectionTimeout = const Duration(seconds: 8);
    return c;
  }

  static Uri _uri(String path, [Map<String, String>? q]) {
    final b = base.trim().replaceAll(RegExp(r'/+$'), '');
    final u = Uri.parse('$b$path');
    return q == null || q.isEmpty
        ? u
        : u.replace(queryParameters: {...u.queryParameters, ...q});
  }

  /// 返回解密后的 data 段；失败一律 null
  static Future<Map<String, dynamic>?> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = _short,
  }) async {
    if (!configured) return null;
    try {
      final c = _client();
      final u = _uri(path, query);
      final req = method == 'POST'
          ? await c.postUrl(u).timeout(timeout)
          : await c.getUrl(u).timeout(timeout);
      req.headers.set('X-TH-Token', token);
      if (body != null) {
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(timeout);
      final bytes = await resp.expand((x) => x).toList();
      final text = utf8.decode(bytes, allowMalformed: true);
      final j = jsonDecode(text);
      if (j is! Map) return null;
      return Map<String, dynamic>.from(j);
    } catch (_) {
      return null;
    }
  }

  static Object? _data(Map<String, dynamic>? j) => j == null ? null : j['data'];
  static Map<String, dynamic>? _meta(Map<String, dynamic>? j) => j == null
      ? null
      : (j['meta'] is Map ? Map<String, dynamic>.from(j['meta'] as Map) : null);

  static List<Map<String, dynamic>> _list(Object? v) => [
        if (v is List)
          for (final e in v)
            if (e is Map) Map<String, dynamic>.from(e),
      ];

  // ── 1. 健康与模式判定 ───────────────────────────────────────────────────
  /// [probe] = true 时让服务端真去探一次 DSH（会慢一点，但拿到的是实时状态）
  static Future<AgentHealth?> health({bool probe = false}) async {
    final j = await _send('GET', '/agent/health',
        query: probe ? {'probe': '1'} : null,
        timeout: probe ? const Duration(seconds: 15) : _short);
    final d = _data(j);
    if (d is! Map) return null;
    return AgentHealth.from(Map<String, dynamic>.from(d));
  }

  /// 拉服务端权威表覆盖本地策略镜像。失败就保持本地镜像（不放宽权限）。
  static Future<bool> syncPolicy() async {
    final pj = await _send('GET', '/agent/profiles');
    if (pj == null) return false;
    final meta = _meta(pj) ?? const <String, dynamic>{};
    final ver = (meta['version'] as num?)?.toInt() ?? 0;
    AgentPolicy.applyServerTable(meta['risk'], _data(pj), version: ver);
    return true;
  }

  /// 服务端算好的工具目录（含每项的 allow/confirm/deny）
  static Future<List<AgentToolInfo>> tools({String profile = 'default'}) async {
    final j = await _send('GET', '/agent/tools', query: {'profile': profile});
    return [for (final m in _list(_data(j))) AgentToolInfo.from(m)];
  }

  // ── 2. 会话与事件 ───────────────────────────────────────────────────────
  static Future<AgentSession?> createSession({
    String title = '新任务',
    String profile = AgentProfileId.normal,
    String userId = '',
    String? id,
  }) async {
    final j = await _send('POST', '/agent/session', body: {
      'title': title,
      'profile': profile,
      if (userId.isNotEmpty) 'userId': userId,
      if (id != null) 'id': id,
    });
    final d = _data(j);
    return d is Map ? AgentSession.from(Map<String, dynamic>.from(d)) : null;
  }

  static Future<List<AgentSession>> sessions({int limit = 50}) async {
    final j = await _send('GET', '/agent/sessions', query: {'limit': '$limit'});
    return [for (final m in _list(_data(j))) AgentSession.from(m)];
  }

  static Future<({List<AgentEvent> events, int lastSeq})> events(
      String sessionId,
      {int since = 0,
      int limit = 500}) async {
    final j = await _send('GET', '/agent/events',
        query: {'sessionId': sessionId, 'since': '$since', 'limit': '$limit'});
    final meta = _meta(j) ?? const <String, dynamic>{};
    return (
      events: [for (final m in _list(_data(j))) AgentEvent.from(m)],
      lastSeq: (meta['lastSeq'] as num?)?.toInt() ?? since,
    );
  }

  static Future<AgentEvent?> appendEvent(
      String sessionId, String type, Map<String, dynamic> payload) async {
    final j = await _send('POST', '/agent/event',
        body: {'sessionId': sessionId, 'type': type, 'payload': payload});
    final d = _data(j);
    return d is Map ? AgentEvent.from(Map<String, dynamic>.from(d)) : null;
  }

  /// 发起一轮。返回 (mode, hint) —— hint 在降级时告诉调用方该怎么走。
  static Future<({String mode, bool full, String hint, AgentEvent? event})>
      send(
    String sessionId,
    String text, {
    List<AgentContextRef> contextRefs = const [],
  }) async {
    final j = await _send('POST', '/agent/send',
        body: {
          'sessionId': sessionId,
          'text': text,
          'contextRefs': [for (final r in contextRefs) r.toJson()],
        },
        timeout: _long);
    final d = _data(j);
    if (d is! Map)
      return (
        mode: AgentMode.fallback,
        full: false,
        hint: '后端无响应',
        event: null
      );
    final m = Map<String, dynamic>.from(d);
    final ev = m['event'] is Map
        ? AgentEvent.from(Map<String, dynamic>.from(m['event'] as Map))
        : null;
    return (
      mode: '${m['mode'] ?? AgentMode.fallback}',
      full: m['fullAgentAvailable'] == true,
      hint: '${m['hint'] ?? ''}',
      event: ev,
    );
  }

  /// SSE 增量事件流。服务端每 700ms 推一次，本轮 done 后自动 close。
  /// 连不上或流断了，调用方应回落到 [pollEvents]。
  static Stream<AgentEvent> streamEvents(String sessionId, {int since = 0}) {
    final ctl = StreamController<AgentEvent>();
    HttpClient? c;
    try {
      c = _client();
      c
          .getUrl(_uri('/agent/events/stream',
              {'sessionId': sessionId, 'since': '$since'}))
          .then((req) {
        req.headers.set('X-TH-Token', token);
        req.headers.set('Accept', 'text/event-stream');
        return req.close();
      }).then((resp) {
        if (resp.statusCode != 200) {
          ctl.addError('HTTP ${resp.statusCode}');
          ctl.close();
          return;
        }
        final buf = StringBuffer();
        resp.transform(utf8.decoder).transform(const LineSplitter()).listen(
            (line) {
          if (line.startsWith(':')) return; // 心跳
          if (line.startsWith('event: ')) return; // 事件名与 payload.type 重复，忽略
          if (line.startsWith('id: ')) return; // seq 已含在 payload 里
          if (line.startsWith('data: ')) {
            buf.write(line.substring(6));
            return;
          }
          if (line.trim().isEmpty) {
            // 一个 SSE 块结束
            final raw = buf.toString();
            buf.clear();
            if (raw.isEmpty) return;
            try {
              final j = jsonDecode(raw);
              if (j is Map<String, dynamic>) {
                if (j.containsKey('type')) ctl.add(AgentEvent.from(j));
                if (j['type'] == 'done') {
                  ctl.close();
                }
              }
            } catch (_) {/* 坏帧跳过，不让一条脏数据打断整个流 */}
          }
        }, onError: (e) {
          ctl.addError(e);
          ctl.close();
        }, onDone: () {
          if (!ctl.isClosed) ctl.close();
        });
      }).catchError((e) {
        ctl.addError(e);
        ctl.close();
      });
    } catch (e) {
      ctl.addError(e);
      ctl.close();
    }
    ctl.onCancel = () {
      try {
        c?.close(force: true);
      } catch (_) {}
    };
    return ctl.stream;
  }

  /// 轮询兜底（SSE 被中间设备掐掉时用）
  static Future<List<AgentEvent>> pollEvents(String sessionId,
      {int since = 0}) async {
    final r = await events(sessionId, since: since);
    return r.events;
  }

  // ── 3. 确认队列 ─────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> pendingConfirms(
      String sessionId) async {
    final j =
        await _send('GET', '/agent/confirm', query: {'sessionId': sessionId});
    return _list(_data(j));
  }

  /// 主动请求确认（一般由服务端在工具调用时发起，这里是客户端预判用）
  static Future<({bool ok, String confirmId, String reason})> requestConfirm(
      String sessionId, String tool, Map<String, dynamic> args) async {
    final j = await _send('POST', '/agent/confirm',
        body: {'sessionId': sessionId, 'tool': tool, 'args': args});
    final d = _data(j);
    if (d is Map) {
      final m = Map<String, dynamic>.from(d);
      return (
        ok: m['ok'] == true,
        confirmId: '${m['confirmId'] ?? ''}',
        reason: '${m['reason'] ?? ''}'
      );
    }
    // 被拒时服务端返回 error 段
    final err = j == null ? null : j['data'];
    final msg = err is Map ? '${err['message'] ?? ''}' : '';
    return (ok: false, confirmId: '', reason: msg.isEmpty ? '请求失败' : msg);
  }

  static Future<bool> resolveConfirm(String confirmId, bool allow,
      {String by = 'user'}) async {
    final j = await _send('POST', '/agent/confirm',
        body: {'confirmId': confirmId, 'allow': allow, 'by': by});
    final d = _data(j);
    return d is Map && d['ok'] == true;
  }

  // ── 4. 审计 ─────────────────────────────────────────────────────────────
  static Future<List<AgentAuditRecord>> audit(
      {int limit = 200, String sessionId = ''}) async {
    final j = await _send('GET', '/agent/audit', query: {
      'limit': '$limit',
      if (sessionId.isNotEmpty) 'sessionId': sessionId
    });
    return [for (final m in _list(_data(j))) AgentAuditRecord.from(m)];
  }

  // ── 5. MCP（只管理服务端注册表，不在本地跑 stdio） ──────────────────────
  // ── 产物全文（事件里只带预览时才需要回取） ───────────────────────────────
  /// 按 id 取回落盘产物全文。大 diff / 大日志走这条，事件流因此保持轻量。
  static Future<({bool ok, String text, int bytes, String error})> artifact(
      String id) async {
    final key = id.trim();
    if (key.isEmpty) return (ok: false, text: '', bytes: 0, error: '缺产物 id');
    final m = await _send('GET', '/agent/artifact',
        query: {'id': key}, timeout: _long);
    final d = _data(m);
    if (d is Map) {
      final t = '${d['text'] ?? ''}';
      final b = d['bytes'] is num ? (d['bytes'] as num).toInt() : t.length;
      return (ok: true, text: t, bytes: b, error: '');
    }
    return (
      ok: false,
      text: '',
      bytes: 0,
      error: '取回失败（后端未连接，或产物已被清理）',
    );
  }

  /// 把一份文本存到服务端换回 id/uri（需要落地大产物的调用方用）
  static Future<({bool ok, String id, String uri, String error})> putArtifact(
      String text) async {
    final m = await _send('POST', '/agent/artifact',
        body: {'text': text}, timeout: _long);
    final d = _data(m);
    if (d is Map && d['id'] != null) {
      return (ok: true, id: '${d['id']}', uri: '${d['uri'] ?? ''}', error: '');
    }
    return (ok: false, id: '', uri: '', error: '保存失败（后端未连接）');
  }

  static Future<List<Map<String, dynamic>>> mcpList() async =>
      _list(_data(await _send('GET', '/agent/mcp')));

  static Future<({bool ok, String id, String error})> mcpAdd(
      String name, String url) async {
    final j =
        await _send('POST', '/agent/mcp', body: {'name': name, 'url': url});
    final d = _data(j);
    if (d is Map && d['id'] != null)
      return (ok: true, id: '${d['id']}', error: '');
    final e = d is Map ? '${d['message'] ?? ''}' : '';
    return (ok: false, id: '', error: e.isEmpty ? '添加失败' : e);
  }

  static Future<bool> mcpToggle(String id, bool enabled) async {
    final j = await _send('POST', '/agent/mcp/toggle',
        body: {'id': id, 'enabled': enabled});
    return _data(j) is Map;
  }

  static Future<bool> mcpRemove(String id) async {
    final j = await _send('POST', '/agent/mcp/remove', body: {'id': id});
    return _data(j) is Map;
  }

  static Future<({bool ok, int tools, String error})> mcpConnect(
      String id) async {
    final j = await _send('POST', '/agent/mcp/connect',
        body: {'id': id}, timeout: _long);
    final d = _data(j);
    if (d is Map) {
      return (
        ok: d['ok'] == true,
        tools: (d['tools'] as num?)?.toInt() ?? 0,
        error: '${d['error'] ?? ''}'
      );
    }
    return (ok: false, tools: 0, error: '连接失败');
  }

  static Future<({bool ok, String text, String error})> mcpCall(
      String serverId, String tool, Map<String, dynamic> args,
      {String profile = 'default', String sessionId = ''}) async {
    final j = await _send('POST', '/agent/mcp/call',
        body: {
          'serverId': serverId,
          'tool': tool,
          'args': args,
          'profile': profile,
          'sessionId': sessionId,
        },
        timeout: _long);
    final d = _data(j);
    if (d is Map && d['text'] != null)
      return (ok: true, text: '${d['text']}', error: '');
    final e = d is Map ? '${d['message'] ?? ''}' : '';
    return (ok: false, text: '', error: e.isEmpty ? '调用失败' : e);
  }

  // ── 6. DSH 进程控制（服务端侧） ─────────────────────────────────────────
  /// 最近一次 DSH 操作的**真实失败原因**（服务端 400 时 data.message）。
  /// 之前这里被丢掉，界面上只剩一句「后端版本或权限不符」，而真因是「没装 DSH」。
  static String lastDshError = '';

  /// 信封判定：只有 `object != 'error'` 且带 data 才算成功。
  ///
  /// 为什么不能写 `_data(j) is Map`：服务端失败时返回的信封是
  /// `{object:'error', data:{type:'dsh_start_failed', message:'未找到 DSH 可执行文件'}}`
  /// —— 它的 data **本身就是 Map**，于是「没装 DSH」被报成了「启动成功」。
  static bool _accepted(Map<String, dynamic>? j) =>
      j != null && j['object'] != 'error' && _data(j) is Map;

  static String _errText(Map<String, dynamic>? j) {
    final d = _data(j);
    if (d is Map) {
      final m = '${d['message'] ?? ''}'.trim();
      if (m.isNotEmpty) return m;
      final t = '${d['type'] ?? ''}'.trim();
      if (t.isNotEmpty) return t;
    }
    return j == null ? '后端无响应（地址不通或 token 不符）' : '后端拒绝了该操作';
  }

  static Future<bool> startDsh() async {
    final j = await _send('POST', '/agent/dsh/start');
    lastDshError = _accepted(j) ? '' : _errText(j);
    return _accepted(j);
  }

  static Future<bool> stopDsh() async {
    final j = await _send('POST', '/agent/dsh/stop');
    lastDshError = _accepted(j) ? '' : _errText(j);
    return _accepted(j);
  }
}
