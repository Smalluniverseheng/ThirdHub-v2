// 本机 Agent 运行时（Local Agent Runtime）—— 把 DSH 的 Agent 内核搬到手机上跑
//
// ── 为什么要这个东西 ─────────────────────────────────────────────────────
// 之前 agent_models.dart 的注释写得很直白：「Agent 内核（上下文装配 / 插件 /
// 沙箱 / MCP）在 server 侧的 DSH 里」，「没有 DSH 时降级为轻量 Agent」。
// 于是手机只要不在同一个局域网、或不装那个 EXE，就只剩一个会聊天的壳。
//
// 用户 2026-11-07 明确要求：**手机端也能本地跑的 Agent 框架要融进来**。
// 观察 DSH 的运行方式后，它的内核其实是四件事，跟 Linux 没关系：
//   ① 会话（session）与有序事件流（seq 单调，可重放）
//   ② 回合循环（计划 → 调工具 → 观察结果 → 继续，直到给结论）
//   ③ 审批闸（读/写/危险三级，危险操作必须人工确认）
//   ④ 审计（每次工具调用留痕，谁批的、结果多大）
// PRoot / rootfs 只是让它能跑 shell 和 Python；我们的能力层是 App 自己的
// 40 个本地工具（LocalTools），不需要 Linux。所以内核可以纯 Dart 实现。
//
// ── 与远端 DSH 的关系 ────────────────────────────────────────────────────
// 事件类型与 AgentEvent 完全一致（直接复用 agent_models.dart），所以同一套
// 界面既能渲染本机事件、也能渲染电脑端事件；本机可用时优先本机，失败再降级
// 到电脑端 —— 这就是「一个框架，两种运行位置」。
//
// ── 约束 ────────────────────────────────────────────────────────────────
// 零 Flutter、零 IO、零平台通道：只 import dart:convert 与本项目两个纯 Dart
// 文件，这样 `dart run tool/local_agent_selfcheck.dart` 能直接在 VM 里跑全量
// 向量，不用起模拟器。模型调用与工具执行都用回调注入（便于换实现、便于测试）。

import 'dart:async';
import 'dart:convert';

import 'agent_models.dart';
import 'agent_policy.dart';

/// 一次模型调用：给完整 messages，返回助手这一轮的原始文本。
typedef LocalModelFn = Future<String> Function(List<Map<String, dynamic>> messages);

/// 一次工具执行：name + args → 观察结果文本（失败也返回文本，不抛）。
typedef LocalToolFn = Future<String> Function(String name, Map<String, dynamic> args);

/// 人工确认：危险操作前问用户，返回是否放行。
typedef LocalConfirmFn = Future<bool> Function(String tool, String risk, Map<String, dynamic> args);

/// 工具描述（交给模型看的最小集合，和 MCP 的 schema 形态对齐）。
class LocalAgentTool {
  final String name;
  final String description;
  final String risk;

  const LocalAgentTool({required this.name, required this.description, this.risk = AgentRisk.read});
}

/// 一个已解析的助手动作：要么调工具，要么给结论。
class LocalAgentAction {
  final String thought;
  final String? tool;
  final Map<String, dynamic> args;
  final String? answer;

  const LocalAgentAction({this.thought = '', this.tool, this.args = const {}, this.answer});

  bool get isFinal => tool == null || tool!.isEmpty;
}

/// 取消令牌：不用 Future.race，避免留下悬挂的 future。
class LocalAgentCancel {
  bool _cancelled = false;
  String reason = '';
  bool get cancelled => _cancelled;
  void cancel([String why = '用户取消']) {
    _cancelled = true;
    reason = why;
  }
}

/// 本机 Agent 内核。
///
/// 用法：
/// ```dart
/// final engine = LocalAgentEngine(
///   model: (msgs) => AiChat.chat(...),      // 由上层注入，内核不认识模型
///   execTool: (n, a) => LocalTools.call(n, a),
///   tools: localAgentTools,
/// );
/// await for (final ev in engine.run(sessionId: id, input: '帮我找一本小说')) { ... }
/// ```
class LocalAgentEngine {
  final LocalModelFn model;
  final LocalToolFn execTool;
  final LocalConfirmFn? confirm;
  final List<LocalAgentTool> tools;

  /// 最多几个「模型→工具」回合。超出就收尾，防止无限自转烧 key。
  final int maxSteps;

  /// 观察结果进上下文时最多保留多少字符（超出截断，避免上下文爆掉）。
  final int observationLimit;

  /// 上下文里最多带多少条历史观察（更早的丢掉，只留摘要行）。
  final int historyKeep;

  /// 本机审计（每轮工具调用一条）。
  final List<Map<String, dynamic>> auditLog = <Map<String, dynamic>>[];

  LocalAgentEngine({
    required this.model,
    required this.execTool,
    this.confirm,
    this.tools = const <LocalAgentTool>[],
    this.maxSteps = 12,
    this.observationLimit = 2000,
    this.historyKeep = 8,
  });

  /// 跑一次任务，产出与远端 DSH 完全同构的事件流。
  Stream<AgentEvent> run({
    required String sessionId,
    required String input,
    List<Map<String, dynamic>> systemMessages = const <Map<String, dynamic>>[],
    LocalAgentCancel? cancel,
  }) async* {
    final _Emitter em = _Emitter(sessionId);

    yield em.emit(AgentEventType.userMessage, <String, dynamic>{'text': input});

    final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
      ...systemMessages,
      if (tools.isNotEmpty) <String, dynamic>{'role': 'system', 'content': _toolMenu()},
      <String, dynamic>{'role': 'user', 'content': input},
    ];

    int steps = 0;
    String answer = '';
    String stopReason = '';

    while (true) {
      if (cancel != null && cancel.cancelled) {
        stopReason = cancel.reason.isEmpty ? '已取消' : cancel.reason;
        break;
      }
      if (steps >= maxSteps) {
        stopReason = '达到最大回合数（$maxSteps），先停在这里';
        break;
      }
      steps++;

      String raw;
      try {
        raw = await model(messages);
      } catch (e) {
        yield em.emit(AgentEventType.error, <String, dynamic>{'message': '模型调用失败: $e'});
        stopReason = '模型调用失败';
        break;
      }
      if (cancel != null && cancel.cancelled) {
        stopReason = cancel.reason.isEmpty ? '已取消' : cancel.reason;
        break;
      }

      final LocalAgentAction act = parseAction(raw);

      if (act.thought.trim().isNotEmpty) {
        yield em.emit(AgentEventType.assistantDelta, <String, dynamic>{'text': act.thought.trim()});
      }

      // ── 结论分支 ──
      if (act.isFinal) {
        answer = (act.answer ?? raw).trim();
        yield em.emit(AgentEventType.assistantMessage, <String, dynamic>{'text': answer});
        break;
      }

      final String tool = act.tool!;

      // ── 工具必须存在 ──
      final bool known = tools.isEmpty || tools.any((t) => t.name == tool);
      if (!known) {
        final String obs = '没有这个工具：$tool（可用：${tools.map((t) => t.name).join(' / ')}）';
        yield em.emit(AgentEventType.toolResult, <String, dynamic>{
          'tool': tool, 'ok': false, 'observation': obs,
        });
        _push(messages, tool, act.args, obs);
        continue;
      }

      // ── 审批闸 ──
      // 不用 AgentPolicy.decide：那张表是按「远端工具名」建的（kb.search / note.save…），
      // 本机的 app_state / goto_module 进去只会被判 unknown。这里直接用工具自带的风险级：
      //   read   → 直接执行
      //   write  → 必须人工确认
      //   danger → 必须有确认入口，且默认拒绝
      final String risk = _riskOf(tool);
      if (risk == AgentRisk.danger && confirm == null) {
        const String why = '高风险操作，但没有可用的确认入口，已拒绝';
        _audit(tool, act.args, 'deny', 0, em.seq);
        yield em.emit(AgentEventType.audit, <String, dynamic>{
          'tool': tool, 'risk': risk, 'decision': AgentDecision.deny, 'reason': why,
        });
        yield em.emit(AgentEventType.toolResult, <String, dynamic>{
          'tool': tool, 'ok': false, 'observation': why,
        });
        _push(messages, tool, act.args, why);
        continue;
      }

      bool allow = risk == AgentRisk.read;
      if (!allow && confirm != null) {
        final String cid = em.nextConfirmId();
        final String why = risk == AgentRisk.danger
            ? '这是高风险操作，会改动或外发数据'
            : '这会修改你的设置或数据';
        yield em.emit(AgentEventType.confirmRequest, <String, dynamic>{
          'confirmId': cid, 'tool': tool, 'risk': risk, 'reason': why, 'args': act.args,
        });
        try {
          allow = await confirm!(tool, risk, act.args);
        } catch (_) {
          allow = false;
        }
        yield em.emit(AgentEventType.confirmResult, <String, dynamic>{
          'confirmId': cid, 'tool': tool, 'allowed': allow,
        });
      }

      if (!allow) {
        final String obs = '用户没有批准这次 $tool 操作';
        _audit(tool, act.args, 'not_approved', 0, em.seq);
        yield em.emit(AgentEventType.toolResult, <String, dynamic>{
          'tool': tool, 'ok': false, 'observation': obs,
        });
        _push(messages, tool, act.args, obs);
        continue;
      }

      // ── 执行 ──
      yield em.emit(AgentEventType.toolCall, <String, dynamic>{
        'tool': tool, 'risk': risk, 'args': act.args,
      });

      String obsText;
      bool ok = true;
      try {
        obsText = await execTool(tool, act.args);
      } catch (e) {
        ok = false;
        obsText = '工具执行出错: $e';
      }
      if (obsText.trim().isEmpty) obsText = '（没有输出）';
      obsText = clampObservation(obsText);

      _audit(tool, act.args, ok ? 'allow' : 'error', obsText.length, em.seq);
      yield em.emit(AgentEventType.toolResult, <String, dynamic>{
        'tool': tool, 'ok': ok, 'observation': obsText,
      });
      _push(messages, tool, act.args, obsText);
    }

    // 收尾：被截断或取消时也要给用户一句人话，不要静默结束
    if (answer.isEmpty) {
      answer = stopReason.isEmpty ? '已停止' : stopReason;
      yield em.emit(AgentEventType.assistantMessage, <String, dynamic>{'text': answer});
    }
    yield em.emit(AgentEventType.done, <String, dynamic>{
      'steps': steps,
      'stopped': stopReason.isEmpty ? 'final' : stopReason,
      'audit': auditLog.length,
    });
  }

  // ── 以下是纯函数，自检直接调 ──────────────────────────────────────────

  /// 把模型这一轮的原始输出解析成「调工具」或「给结论」。
  ///
  /// 兼容三种写法（模型厂商五花八门，不能只认一种）：
  ///   ① 整段就是一个 JSON 对象：{"tool":"x","args":{...}}
  ///   ② 结论 JSON：{"final":"..."} 或 {"answer":"..."}
  ///   ③ ```json ... ``` 代码块里包着上面两种
  /// 都不是 → 当成纯文本结论（宁可给个答案，也不要把用户卡住）。
  static LocalAgentAction parseAction(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return const LocalAgentAction(answer: '');

    final String body = _stripFence(text);
    final Map<String, dynamic>? j = _tryJson(body);
    if (j != null) {
      final String thought = '${j['thought'] ?? j['thinking'] ?? ''}';
      final Object? fin = j['final'] ?? j['answer'] ?? j['result'];
      final Object? tool = j['tool'] ?? j['action'];
      if (tool is String && tool.trim().isNotEmpty) {
        Map<String, dynamic> args = const <String, dynamic>{};
        final Object? a = j['args'] ?? j['arguments'] ?? j['params'];
        if (a is Map) args = a.map((k, v) => MapEntry('$k', v));
        return LocalAgentAction(thought: thought, tool: tool.trim(), args: args);
      }
      if (fin is String) return LocalAgentAction(thought: thought, answer: fin);
      if (fin != null) return LocalAgentAction(thought: thought, answer: '$fin');
    }
    return LocalAgentAction(answer: body);
  }

  /// 观察结果进上下文前先截断：保留头尾，掐掉中间。
  ///
  /// 为什么要保留尾部：分页/报错的最后几行往往才是关键（"第 3 页 / 共 5 页"）。
  String clampObservation(String s) {
    if (s.length <= observationLimit) return s;
    final int half = observationLimit ~/ 2 - 40;
    final String head = s.substring(0, half);
    final String tail = s.substring(s.length - half);
    final int cut = s.length - observationLimit;
    return '$head\n…（中间省略 $cut 字）…\n$tail';
  }

  void _push(List<Map<String, dynamic>> messages, String tool, Map<String, dynamic> args, String obs) {
    messages.add(<String, dynamic>{
      'role': 'assistant',
      'content': jsonEncode(<String, dynamic>{'tool': tool, 'args': args}),
    });
    messages.add(<String, dynamic>{'role': 'user', 'content': '工具 $tool 的结果：\n$obs'});
    // 历史观察只留最近 N 条，再早的折成一行占位，避免上下文线性膨胀
    final List<int> toolIdx = <int>[];
    for (int i = 0; i < messages.length; i++) {
      if ('${messages[i]['role']}' == 'assistant' && '${messages[i]['content']}'.contains('"tool"')) {
        toolIdx.add(i);
      }
    }
    if (toolIdx.length > historyKeep) {
      for (final int i in toolIdx.take(toolIdx.length - historyKeep)) {
        messages[i] = <String, dynamic>{'role': 'assistant', 'content': '（更早的工具调用已折叠）'};
        if (i + 1 < messages.length) {
          messages[i + 1] = <String, dynamic>{'role': 'user', 'content': '（更早的工具结果已折叠）'};
        }
      }
    }
  }

  void _audit(String tool, Map<String, dynamic> args, String decision, int bytes, int seq) {
    auditLog.add(<String, dynamic>{
      'seq': seq, 'tool': tool, 'decision': decision, 'bytes': bytes,
      'args': args, 'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  String _riskOf(String tool) {
    for (final LocalAgentTool t in tools) {
      if (t.name == tool) return t.risk;
    }
    return AgentRisk.unknown;
  }

  String _toolMenu() {
    final List<String> lines = <String>['你现在在手机本地运行，可用工具如下：'];
    for (final LocalAgentTool t in tools) {
      lines.add('- ${t.name}（${AgentRisk.labelOf[t.risk] ?? t.risk}）：${t.description}');
    }
    lines.add('');
    lines.add('要调工具就只输出一个 JSON：{"thought":"简述理由","tool":"工具名","args":{...}}');
    lines.add('要给结论就输出：{"final":"给用户的回答"}');
    lines.add('一次只调一个工具，拿到结果后再决定下一步。');
    return lines.join('\n');
  }

  static String _stripFence(String s) {
    if (!s.startsWith('```')) return s;
    final int nl = s.indexOf('\n');
    if (nl < 0) return s;
    String body = s.substring(nl + 1);
    final int end = body.lastIndexOf('```');
    if (end >= 0) body = body.substring(0, end);
    return body.trim();
  }

  static Map<String, dynamic>? _tryJson(String s) {
    final String t = s.trim();
    if (!t.startsWith('{') || !t.endsWith('}')) return null;
    try {
      final Object? v = jsonDecode(t);
      if (v is Map) return v.map((k, val) => MapEntry('$k', val));
    } catch (_) {}
    return null;
  }
}

/// 事件发号器：seq 从 1 单调递增，id 带 sessionId 前缀，和远端同构。
class _Emitter {
  final String sessionId;
  int seq = 0;
  int _confirm = 0;

  _Emitter(this.sessionId);

  String nextConfirmId() => 'cf-${++_confirm}';

  AgentEvent emit(String type, Map<String, dynamic> payload) {
    seq++;
    return AgentEvent(
      id: '$sessionId-$seq',
      sessionId: sessionId,
      seq: seq,
      ts: DateTime.now().millisecondsSinceEpoch,
      type: type,
      payload: payload,
    );
  }
}

/// 手机本机能提供的工具清单（风险级别与远端 riskTable 对齐）。
///
/// 只列「不碰内容源、不越权」的那些：读上下文、切模块、读写设置、查资料库状态、
/// 近况、书架、笔记、语音。危险操作（删数据、外发）走 confirm。
const List<LocalAgentTool> localAgentTools = <LocalAgentTool>[
  LocalAgentTool(name: 'app_state', description: '当前在哪个模块、版本、是否联网、资料库状态', risk: AgentRisk.read),
  LocalAgentTool(name: 'capabilities', description: '这台设备与 App 具备哪些能力', risk: AgentRisk.read),
  LocalAgentTool(name: 'list_modules', description: '列出所有模块及其键名', risk: AgentRisk.read),
  LocalAgentTool(name: 'goto_module', description: '切换到指定模块（参数 module 用键名）', risk: AgentRisk.write),
  LocalAgentTool(name: 'get_setting', description: '读一个设置项（参数 key）', risk: AgentRisk.read),
  LocalAgentTool(name: 'set_setting', description: '写一个设置项（参数 key / value）', risk: AgentRisk.write),
  LocalAgentTool(name: 'engine_status', description: '资料库（引擎）连接与健康状态', risk: AgentRisk.read),
  LocalAgentTool(name: 'engine_search', description: '在资料库搜索（参数 type=novel/comic/music/video/all、query、limit）', risk: AgentRisk.read),
  LocalAgentTool(name: 'open_item', description: '打开一本书/一部漫画/一个媒体（参数 type、id、title）', risk: AgentRisk.write),
  LocalAgentTool(name: 'recent_history', description: '最近的阅读/观看记录（参数 limit）', risk: AgentRisk.read),
  LocalAgentTool(name: 'shelf_list', description: '书架里的条目', risk: AgentRisk.read),
  LocalAgentTool(name: 'tavern_list', description: '角色卡列表', risk: AgentRisk.read),
  // ── 飞牛 NAS（fnOS）· 调官方 fnos-cli（MIT），见 vendor/MANIFEST.json ──
  LocalAgentTool(name: 'nas_status', description: '查看飞牛 NAS 的系统型号、存储与运行状态', risk: AgentRisk.read),
  LocalAgentTool(name: 'nas_ls', description: '列出 NAS 某个目录的内容（参数 path）', risk: AgentRisk.read),
  LocalAgentTool(name: 'nas_search', description: '在 NAS 上按文件名搜索（参数 key、path）', risk: AgentRisk.read),
  LocalAgentTool(name: 'nas_photos', description: 'NAS 照片相册目录或按关键词搜照片（参数 key）', risk: AgentRisk.read),
  LocalAgentTool(name: 'nas_docker', description: 'NAS 上运行的 Docker 容器列表', risk: AgentRisk.read),
  LocalAgentTool(name: 'nas_download', description: 'NAS 上的下载任务', risk: AgentRisk.read),
  LocalAgentTool(name: 'nas_media', description: 'NAS 影音库（影片列表/搜索）。注意 media 需单独授权，未授权会报 403', risk: AgentRisk.read),
  LocalAgentTool(name: 'note_add', description: '记一条本地笔记（参数 text）', risk: AgentRisk.write),
  LocalAgentTool(name: 'note_list', description: '列出本地笔记', risk: AgentRisk.read),
];
