// ═══════════════════════════════════════════════════════════════════════════
// THA/1 · Agent 事件与实体模型（Flutter 控制面）
//
// 设计立场（见 docs/AGENT-PROTOCOL.md）：
//   Flutter 只做**控制面** —— 发起任务、渲染事件流、处理确认、展示审计。
//   Agent 内核（上下文装配 / 插件 / 沙箱 / MCP）在 server 侧的 DSH 里。
//   没有 DSH 时降级为轻量 Agent，但**事件协议不变**，所以这一层不用改。
//
// 本文件刻意零 Flutter 依赖（只用 dart:convert），以便：
//   · 纯 Dart VM 自检：dart run tool/agent_proto_selfcheck.dart
//   · server 侧同一份 JSON 在两端解析结果一致，不会「服务端说有、前端看不见」
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';

/// 事件类型（与 server/agent-dsh.js 的 EVENT_TYPES 必须逐字一致）
class AgentEventType {
  static const userMessage = 'user_message';
  static const assistantDelta = 'assistant_delta';
  static const assistantMessage = 'assistant_message';
  static const toolCall = 'tool_call';
  static const toolResult = 'tool_result';
  static const confirmRequest = 'confirm_request';
  static const confirmResult = 'confirm_result';
  static const audit = 'audit';
  static const artifact = 'artifact';
  static const error = 'error';
  static const done = 'done';

  static const all = <String>{
    userMessage,
    assistantDelta,
    assistantMessage,
    toolCall,
    toolResult,
    confirmRequest,
    confirmResult,
    audit,
    artifact,
    error,
    done,
  };
}

/// 运行模式：full = 接上了 DSH；fallback = 本机/后端没有 DSH，走轻量 Agent
class AgentMode {
  static const full = 'full';
  static const fallback = 'fallback';
}

/// 一个事件。协议里唯一的「事实」单位 —— append-only，永不修改。
class AgentEvent {
  final String id;
  final String sessionId;
  final int seq;
  final int ts;
  final String type;
  final Map<String, dynamic> payload;

  const AgentEvent({
    required this.id,
    required this.sessionId,
    required this.seq,
    required this.ts,
    required this.type,
    required this.payload,
  });

  factory AgentEvent.from(Map<String, dynamic> j) => AgentEvent(
        id: '${j['id'] ?? ''}',
        sessionId: '${j['sessionId'] ?? ''}',
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        type: '${j['type'] ?? ''}',
        payload: j['payload'] is Map
            ? Map<String, dynamic>.from(j['payload'] as Map)
            : <String, dynamic>{},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'seq': seq,
        'ts': ts,
        'type': type,
        'payload': payload,
      };

  /// 流式增量文本（assistant_delta 才有）
  String get deltaText => '${payload['text'] ?? ''}';

  /// 需要用户确认时的确认 id
  String get confirmId => type == AgentEventType.confirmRequest
      ? id
      : '${payload['confirmId'] ?? ''}';

  /// 是否为终态（这一轮结束了）
  bool get isTerminal =>
      type == AgentEventType.done || type == AgentEventType.error;

  bool get isKnownType => AgentEventType.all.contains(type);

  @override
  String toString() => 'AgentEvent($type #$seq)';
}

/// 工具调用（tool_call 事件的载荷视图）
class AgentToolCall {
  final String tool;
  final Map<String, dynamic> arguments;
  final String argsDigest;
  final String risk;
  final String decision;

  const AgentToolCall({
    required this.tool,
    this.arguments = const {},
    this.argsDigest = '',
    this.risk = 'unknown',
    this.decision = '',
  });

  factory AgentToolCall.from(Map<String, dynamic> j) => AgentToolCall(
        tool: '${j['tool'] ?? j['name'] ?? ''}',
        arguments: j['arguments'] is Map
            ? Map<String, dynamic>.from(j['arguments'] as Map)
            : (j['args'] is Map
                ? Map<String, dynamic>.from(j['args'] as Map)
                : <String, dynamic>{}),
        argsDigest: '${j['argsDigest'] ?? ''}',
        risk: '${j['risk'] ?? 'unknown'}',
        decision: '${j['decision'] ?? ''}',
      );

  String get prettyArgs {
    if (arguments.isEmpty) return '（无参数）';
    try {
      return const JsonEncoder.withIndent('  ').convert(arguments);
    } catch (_) {
      return '$arguments';
    }
  }
}

/// 产物（代码/文件/diff 统一走 artifact，不把大段内容塞进对话）
class AgentArtifact {
  final String kind; // patch | file | diff | log
  final String uri; // server://artifacts/xxx
  final String summary;
  final bool requiresConfirm;

  const AgentArtifact({
    required this.kind,
    required this.uri,
    this.summary = '',
    this.requiresConfirm = true,
  });

  factory AgentArtifact.from(Map<String, dynamic> j) => AgentArtifact(
        kind: '${j['kind'] ?? 'file'}',
        uri: '${j['uri'] ?? ''}',
        summary: '${j['summary'] ?? ''}',
        requiresConfirm: j['requiresConfirm'] != false,
      );

  static bool looksLikeArtifact(Map<String, dynamic> j) =>
      j.containsKey('artifact') ||
      j.containsKey('kind') && j.containsKey('uri');
}

/// 审计记录（§9）—— 字段与 server 侧 audit() 一一对应
class AgentAuditRecord {
  final int ts;
  final String sessionId,
      userId,
      profile,
      tool,
      argsDigest,
      decision,
      result,
      plugin,
      mcpServer,
      note;

  const AgentAuditRecord({
    this.ts = 0,
    this.sessionId = '',
    this.userId = '',
    this.profile = '',
    this.tool = '',
    this.argsDigest = '',
    this.decision = '',
    this.result = '',
    this.plugin = '',
    this.mcpServer = '',
    this.note = '',
  });

  factory AgentAuditRecord.from(Map<String, dynamic> j) => AgentAuditRecord(
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        sessionId: '${j['sessionId'] ?? ''}',
        userId: '${j['userId'] ?? ''}',
        profile: '${j['profile'] ?? ''}',
        tool: '${j['tool'] ?? ''}',
        argsDigest: '${j['argsDigest'] ?? ''}',
        decision: '${j['decision'] ?? ''}',
        result: '${j['result'] ?? ''}',
        plugin: '${j['plugin'] ?? ''}',
        mcpServer: '${j['mcpServer'] ?? ''}',
        note: '${j['note'] ?? ''}',
      );

  bool get isDenied => decision == 'deny';
  bool get isConfirm => decision == 'confirm';

  /// UI 上给一行人话
  String get line {
    final d = decision == 'allow'
        ? '允许'
        : decision == 'deny'
            ? '拒绝'
            : '待确认';
    final r = result.isEmpty ? '' : ' · $result';
    final src = mcpServer.isNotEmpty
        ? '（MCP $mcpServer）'
        : (plugin.isNotEmpty ? '（插件 $plugin）' : '');
    return '$tool  $d$r$src';
  }
}

/// 权限档位（服务端权威，这里是它的投影）
class AgentProfile {
  final String id, label, desc;
  final bool visibleToUser, denyFullAccess;

  const AgentProfile({
    required this.id,
    required this.label,
    this.desc = '',
    this.visibleToUser = true,
    this.denyFullAccess = true,
  });

  factory AgentProfile.from(Map<String, dynamic> j) => AgentProfile(
        id: '${j['id'] ?? ''}',
        label: '${j['label'] ?? j['id'] ?? ''}',
        desc: '${j['desc'] ?? ''}',
        visibleToUser: j['visibleToUser'] != false,
        denyFullAccess: j['denyFullAccess'] != false,
      );
}

/// 工具在某个档位下的判定结果（由服务端算好回传）
class AgentToolInfo {
  final String name, risk, riskLabel, decision, reason;

  const AgentToolInfo({
    required this.name,
    this.risk = 'unknown',
    this.riskLabel = '',
    this.decision = '',
    this.reason = '',
  });

  factory AgentToolInfo.from(Map<String, dynamic> j) => AgentToolInfo(
        name: '${j['name'] ?? ''}',
        risk: '${j['risk'] ?? 'unknown'}',
        riskLabel: '${j['riskLabel'] ?? ''}',
        decision: '${j['decision'] ?? ''}',
        reason: '${j['reason'] ?? ''}',
      );

  bool get allowed => decision == 'allow';
  bool get needsConfirm => decision == 'confirm';
  bool get denied => decision == 'deny';
}

/// 健康/能力快照 —— 客户端靠它决定走完整 Agent 还是降级
class AgentHealth {
  final String mode, protocolVersion;
  final bool fullAgentAvailable;
  final bool dshDetected, dshRunning;
  final String dshKind, dshTarget, dshVersion, dshError;
  final Map<String, bool> capabilities;
  final List<AgentProfile> profiles;
  final List<Map<String, dynamic>> plugins;

  const AgentHealth({
    this.mode = AgentMode.fallback,
    this.protocolVersion = '',
    this.fullAgentAvailable = false,
    this.dshDetected = false,
    this.dshRunning = false,
    this.dshKind = 'none',
    this.dshTarget = '',
    this.dshVersion = '',
    this.dshError = '',
    this.capabilities = const {},
    this.profiles = const [],
    this.plugins = const [],
  });

  factory AgentHealth.from(Map<String, dynamic> j) {
    final dsh = j['dsh'] is Map
        ? Map<String, dynamic>.from(j['dsh'] as Map)
        : <String, dynamic>{};
    final caps = j['capabilities'] is Map
        ? Map<String, dynamic>.from(j['capabilities'] as Map)
        : <String, dynamic>{};
    return AgentHealth(
      mode: '${j['mode'] ?? AgentMode.fallback}',
      protocolVersion: '${j['protocolVersion'] ?? ''}',
      fullAgentAvailable: j['fullAgentAvailable'] == true,
      dshDetected: dsh['detected'] == true,
      dshRunning: dsh['running'] == true,
      dshKind: '${dsh['kind'] ?? 'none'}',
      dshTarget: '${dsh['target'] ?? ''}',
      dshVersion: '${dsh['version'] ?? ''}',
      dshError: '${dsh['error'] ?? ''}',
      capabilities: {for (final e in caps.entries) e.key: e.value == true},
      profiles: [
        for (final p in (j['profiles'] as List? ?? []))
          if (p is Map) AgentProfile.from(Map<String, dynamic>.from(p)),
      ],
      plugins: [
        for (final p in (j['plugins'] as List? ?? []))
          if (p is Map) Map<String, dynamic>.from(p),
      ],
    );
  }

  bool get isFull => mode == AgentMode.full && fullAgentAvailable;

  /// 给用户看的一句话（降级时要说清原因，不能只说「不可用」）
  String get summary {
    if (isFull)
      return '完整 Agent 已连接${dshVersion.isEmpty ? '' : ' · DSH $dshVersion'}';
    if (dshError.isNotEmpty) return '完整 Agent 不可用：$dshError';
    return '完整 Agent 不可用（未检测到 DSH），已降级为轻量模式';
  }
}

/// Agent 会话（列表项）
class AgentSession {
  final String id, title, profile, status;
  final int createdAt, updatedAt, eventCount, tokens;
  final double cost;

  const AgentSession({
    required this.id,
    this.title = '',
    this.profile = 'default',
    this.status = 'open',
    this.createdAt = 0,
    this.updatedAt = 0,
    this.eventCount = 0,
    this.tokens = 0,
    this.cost = 0,
  });

  factory AgentSession.from(Map<String, dynamic> j) => AgentSession(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        profile: '${j['profile'] ?? 'default'}',
        status: '${j['status'] ?? 'open'}',
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
        eventCount: (j['eventCount'] as num?)?.toInt() ?? 0,
        tokens: (j['tokens'] as num?)?.toInt() ?? 0,
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
      );
}

/// 上下文引用 —— Flutter 不拼大 prompt，只上报「引用 + 优先级」
class AgentContextRef {
  final String type; // selected_text | book | file | kb | page
  final String
      ref; // clipboard | shelf:bookId | server:path#hash | kb:docId#chunk
  final String preview;

  const AgentContextRef(
      {required this.type, required this.ref, this.preview = ''});

  factory AgentContextRef.from(Map<String, dynamic> j) => AgentContextRef(
        type: '${j['type'] ?? ''}',
        ref: '${j['ref'] ?? ''}',
        preview: '${j['preview'] ?? ''}',
      );

  Map<String, dynamic> toJson() =>
      {'type': type, 'ref': ref, 'preview': preview};
}

/// 一次会话内使用的 token/成本统计（done 事件带出来）
class AgentTurnStat {
  final int tokens;
  final double cost;
  final String taskStatus;
  const AgentTurnStat({this.tokens = 0, this.cost = 0, this.taskStatus = ''});

  factory AgentTurnStat.from(Map<String, dynamic> j) => AgentTurnStat(
        tokens: (j['tokens'] as num?)?.toInt() ?? 0,
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
        taskStatus: '${j['taskStatus'] ?? ''}',
      );
}

/// 把事件流折叠成「对话气泡 + 工具轨迹」，供 UI 直接渲染。
/// 纯函数、确定性 —— 抽出来是为了能脱离 UI 自检。
class AgentTimeline {
  final List<AgentEvent> events;
  AgentTimeline(this.events);

  /// 当前流式累积的助手文本（把连续的 assistant_delta 拼起来）
  String get streamingText {
    final buf = StringBuffer();
    for (final e in events) {
      if (e.type == AgentEventType.assistantDelta) buf.write(e.deltaText);
    }
    return buf.toString();
  }

  List<AgentEvent> get toolCalls =>
      events.where((e) => e.type == AgentEventType.toolCall).toList();
  List<AgentEvent> get confirms =>
      events.where((e) => e.type == AgentEventType.confirmRequest).toList();
  List<AgentEvent> get errors =>
      events.where((e) => e.type == AgentEventType.error).toList();
  List<AgentEvent> get artifacts =>
      events.where((e) => e.type == AgentEventType.artifact).toList();

  bool get finished => events.any((e) => e.type == AgentEventType.done);

  /// 还未答复的确认（发过 confirm_request 但没有对应 confirm_result）
  List<AgentEvent> get openConfirms {
    final answered = <String>{
      for (final e in events)
        if (e.type == AgentEventType.confirmResult)
          '${e.payload['confirmId'] ?? ''}',
    };
    return [
      for (final e in confirms)
        if (!answered.contains(e.id)) e
    ];
  }

  /// 待确认的高危工具必须挡住 —— 有未答复确认时不允许继续
  bool get blockedByConfirm => openConfirms.isNotEmpty;

  AgentTurnStat? get lastStat {
    for (final e in events.reversed) {
      if (e.type == AgentEventType.done) return AgentTurnStat.from(e.payload);
    }
    return null;
  }
}
