// 本机 Agent 页 —— 手机本地跑的那套 Agent 框架的入口
//
// 与「AI 助手」的区别（写在页面上，用户要能看懂）：
//   · AI 助手：一次问答，模型直接回答。
//   · 本机 Agent：模型可以调这台手机上的工具（切模块、搜资料库、开书、读写设置…），
//     每一步都看得见，会改动数据的操作先问你。
// 与「DSH 遥控」的区别：遥控连的是电脑端，这台手机不在同一网络就用不了；
// 本机 Agent 不连电脑端，模型 key 存在本机，工具在本机执行。
//
// 事件流与电脑端 DSH 完全同构（复用 agent_models 的 AgentEvent），所以两处界面
// 能看懂同一种数据；以后要合并成一个时间线也不用改协议。

import 'dart:async';

import 'package:flutter/material.dart';

import 'ai.dart';
import 'agent_models.dart';
import 'local_agent.dart';
import 'local_tools.dart';
import 'i18n.dart';

class LocalAgentPage extends StatefulWidget {
  const LocalAgentPage({super.key});

  @override
  State<LocalAgentPage> createState() => _LocalAgentPageState();
}

class _LocalAgentPageState extends State<LocalAgentPage> {
  final TextEditingController input = TextEditingController();
  final ScrollController scroll = ScrollController();
  final List<AgentEvent> events = <AgentEvent>[];
  final LocalAgentCancel cancel = LocalAgentCancel();

  bool running = false;
  String sessionId = 'local-${DateTime.now().millisecondsSinceEpoch}';

  /// 待确认：引擎在等用户点「批准 / 不批准」
  Completer<bool>? pending;

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients) return;
      scroll.animateTo(scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || running) return;
    input.clear();
    setState(() {
      running = true;
      events.clear();
    });

    final engine = LocalAgentEngine(
      tools: localAgentTools,
      execTool: (name, args) => LocalTools.call(name, args),
      model: _callModel,
      confirm: _askUser,
    );

    try {
      await for (final ev in engine.run(sessionId: sessionId, input: text)) {
        if (!mounted) return;
        setState(() => events.add(ev));
        _scrollToEnd();
      }
    } catch (e) {
      if (mounted) {
        setState(() => events.add(AgentEvent(
              id: '$sessionId-err',
              sessionId: sessionId,
              seq: events.length + 1,
              ts: DateTime.now().millisecondsSinceEpoch,
              type: AgentEventType.error,
              payload: <String, dynamic>{'message': '$e'},
            )));
      }
    } finally {
      if (mounted) setState(() => running = false);
      sessionId = 'local-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// 模型调用：挑一台已经填了 key 的厂商，把整段回复拼起来交给引擎。
  Future<String> _callModel(List<Map<String, dynamic>> msgs) async {
    AiProvider? provider;
    String key = '';
    for (final p in AiRegistry.all) {
      final k = await AiRegistry.keyOf(p.id);
      if (k.isNotEmpty && p.models.isNotEmpty) {
        provider = p;
        key = k;
        break;
      }
    }
    if (provider == null || key.isEmpty) {
      throw Exception(tr('还没填模型 Key，先去「AI → 密钥」里填一个'));
    }
    final model = provider.models.first;
    final messages = msgs
        .map((m) => <String, String>{
              'role': '${m['role'] ?? 'user'}',
              'content': '${m['content'] ?? ''}',
            })
        .toList();
    final buf = StringBuffer();
    await AiChat.chat(
      provider: provider,
      model: model,
      messages: messages,
      onDelta: (d) => buf.write(d),
    );
    final out = buf.toString().trim();
    return out.isEmpty ? '{"final":"（模型没有返回内容）"}' : out;
  }

  /// 要改动数据的操作先问用户。
  Future<bool> _askUser(String tool, String risk, Map<String, dynamic> args) async {
    final c = Completer<bool>();
    pending = c;
    if (!mounted) return false;
    setState(() {}); // 让确认卡片出现
    final ok = await c.future;
    pending = null;
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('本机 Agent')),
        actions: [
          if (running)
            TextButton.icon(
              onPressed: () {
                cancel.cancel(tr('你按了停止'));
                pending?.complete(false);
              },
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: Text(tr('停止')),
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: cs.surfaceContainerHighest,
            child: Text(
              tr('在这台手机上直接跑：模型可以调本机工具，会改数据的操作先问你。不连电脑端也能用。'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: events.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(tr('说一句你想做的事，比如「找一本小说并打开」'),
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    ),
                  )
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: events.length,
                    itemBuilder: (_, i) => _eventCard(events[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: tr('让这台手机帮你做点什么'),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: running ? null : _send,
                    child: Text(running ? tr('运行中') : tr('发送')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _eventCard(AgentEvent e) {
    final cs = Theme.of(context).colorScheme;
    final p = e.payload;
    switch (e.type) {
      case AgentEventType.userMessage:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12, left: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('${p['text'] ?? ''}',
                style: TextStyle(color: cs.onPrimaryContainer)),
          ),
        );
      case AgentEventType.assistantDelta:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('· ${p['text'] ?? ''}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        );
      case AgentEventType.assistantMessage:
        return Container(
          margin: const EdgeInsets.only(bottom: 12, right: 24),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText('${p['text'] ?? ''}'),
        );
      case AgentEventType.toolCall:
        return _line(Icons.build_outlined, tr('调用工具'),
            '${p['tool']}  ${_brief(p['args'])}', cs.secondary);
      case AgentEventType.toolResult:
        final bool ok = p['ok'] == true;
        return _line(ok ? Icons.check_circle_outline : Icons.error_outline,
            ok ? tr('工具结果') : tr('工具失败'),
            '${p['tool']}：${_brief(p['observation'], 300)}',
            ok ? cs.onSurfaceVariant : cs.error);
      case AgentEventType.confirmRequest:
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${tr('要执行')} ${p['tool']}（${p['reason'] ?? ''}）',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton(
                    onPressed: () {
                      pending?.complete(true);
                      setState(() {});
                    },
                    child: Text(tr('批准')),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      pending?.complete(false);
                      setState(() {});
                    },
                    child: Text(tr('不批准')),
                  ),
                ],
              ),
            ],
          ),
        );
      case AgentEventType.confirmResult:
        return _line(p['allowed'] == true ? Icons.verified_outlined : Icons.block,
            tr('确认结果'), p['allowed'] == true ? tr('已批准') : tr('已拒绝'), cs.onSurfaceVariant);
      case AgentEventType.audit:
        return _line(Icons.receipt_long_outlined, tr('审计'),
            '${p['tool']} → ${p['decision']}', cs.onSurfaceVariant);
      case AgentEventType.error:
        return _line(Icons.warning_amber_outlined, tr('出错'), '${p['message'] ?? ''}', cs.error);
      case AgentEventType.done:
        return _line(Icons.flag_outlined, tr('结束'),
            '${tr('回合')} ${p['steps']} · ${p['stopped']}', cs.onSurfaceVariant);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _line(IconData icon, String label, String body, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 12, color: color),
                children: [
                  TextSpan(text: '$label  ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: body),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _brief(Object? v, [int max = 120]) {
    final s = v is Map || v is List ? v.toString() : '${v ?? ''}';
    final one = s.replaceAll('\n', ' ');
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }
}
