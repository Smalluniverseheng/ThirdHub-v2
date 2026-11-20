// 应用内 AI 自驱动 · 常驻 AI 模块里的那一版
//
// 用户原话：「应该是融入到 AI 模块上，这并不需要独立运行模块」。
// 所以这里不是一个独立页面，而是 AI 对话页 `+` 面板里弹出来的一个面板：
//   · 模型就用**当前会话的厂商/模型/Key**，不另配一套；
//   · 目标用一句话写，模型自己看截图 → 下指令 → 再看截图；
//   · 每步都能看到它看到的画面和它下的指令，能随时停。
//
// 与 agent_auto_page.dart 的分工：
//   那边是"独立配置入口"（换厂商、试新模型、离线自测用的备用面板）；
//   这里是"日常入口"，零配置。
//
// 权限：默认开启。本机内的操控不需要任何开关（不走 HTTP 端口），
// 只有让电脑连进来才需要「局域网调试通道」（见 agent_bridge.dart）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai.dart';
import '../i18n.dart';
import 'agent_llm.dart';
import 'agent_runner.dart';

class AgentInline {
  const AgentInline._();

  /// 弹出自动操作面板。调用方负责传当前会话的厂商与模型。
  static Future<void> show(
    BuildContext context, {
    required AiProvider provider,
    required String model,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: _AgentInlineSheet(provider: provider, model: model),
      ),
    );
  }
}

class _AgentInlineSheet extends StatefulWidget {
  final AiProvider provider;
  final String model;

  const _AgentInlineSheet({required this.provider, required this.model});

  @override
  State<_AgentInlineSheet> createState() => _AgentInlineSheetState();
}

class _AgentInlineSheetState extends State<_AgentInlineSheet> {
  final _goal = TextEditingController();
  final _runner = AgentRunner();
  final _scroll = ScrollController();

  bool _running = false;
  String _log = '';
  String _summary = '';
  List<AgentStepView> _steps = [];

  /// 预设目标：覆盖"平时最想让它自己跑一遍"的几件事。
  /// 不要写成营销文案 —— 这些是直接喂给模型的 goal，写清楚比写漂亮重要。
  static const List<String> _presets = [
    '打开红果短剧，滑两下，确认能出内容并点开一个能播的',
    '打开 B 站 → 番剧栏目，找一部能播的并进到播放页',
    '在搜索里搜「斗破苍穹」，打开第一条，读到正文',
    '把五个板块（小说/漫画/视频/音乐/B站）各过一遍，告诉我哪个不能用、卡在哪',
  ];

  @override
  void initState() {
    super.initState();
    _goal.text = _presets.first;
  }

  @override
  void dispose() {
    _runner.stop();
    _goal.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final goal = _goal.text.trim();
    if (goal.isEmpty) return;
    final key = await AiRegistry.keyOf(widget.provider.id);
    if (key.isEmpty) {
      setState(() => _log = '当前厂商没填 API Key。先去 + 面板 → 厂商与 Key 管理。');
      return;
    }
    setState(() {
      _running = true;
      _steps = [];
      _log = '开始：$goal';
      _summary = '';
    });
    final brain = AgentLlm(
      providerId: widget.provider.id,
      model: widget.model,
      base: widget.provider.base,
      apiKey: key,
      kind: widget.provider.type == 'anthropic' ? 'anthropic' : 'openai',
    );
    final r = await _runner.run(
      llm: brain,
      goal: goal,
      maxSteps: 12,
      onLog: (s) {
        if (mounted) setState(() => _log = s);
      },
      onStep: (v) {
        if (!mounted) return;
        setState(() => _steps = [..._steps, v]);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _summary = r.summary;
    });
  }

  void _stop() {
    _runner.stop();
    setState(() => _log = '正在停止…（当前这一步做完就停）');
  }

  /// 把整轮结论变成一段能直接粘给别人的文字（含每步做了什么）。
  /// 用户要的是"能拿去修 bug 的东西"，不是"跑完就没了"。
  String _report() {
    final sb = StringBuffer();
    sb.writeln('目标：${_goal.text.trim()}');
    sb.writeln('模型：${widget.provider.name} / ${widget.model}');
    sb.writeln('结论：${_summary.isEmpty ? '（未结束）' : _summary}');
    sb.writeln('步骤：');
    for (final s in _steps) {
      final act = s.action == null ? '（无动作）' : '${s.action}';
      sb.writeln('${s.index}. ${s.say} ｜ $act → ${s.ok ? 'ok' : 'ERR ${s.error ?? ''}'}');
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          Icon(Icons.auto_awesome, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              trf('让它自己操作 App · {p} / {m}', {'p': widget.provider.name, 'm': widget.model}),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _goal,
          enabled: !_running,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            isDense: true,
            hintText: tr('要它做什么？例如：打开红果并播一个'),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      SizedBox(
        height: 34,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          children: [
            for (var i = 0; i < _presets.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  label: Text(trf('预设 {n}', {'n': '${i + 1}'}), style: const TextStyle(fontSize: 11)),
                  tooltip: _presets[i],
                  onPressed: _running ? null : () => setState(() => _goal.text = _presets[i]),
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(children: [
          Expanded(
            child: Text(
              _running
                  ? _log
                  : (_summary.isEmpty
                      ? tr('模型会自己看截图、自己下指令。需要该模型支持看图（视觉）。')
                      : '结论：$_summary'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (_running)
            FilledButton.tonalIcon(
              onPressed: _stop,
              icon: const Icon(Icons.stop, size: 16),
              label: Text(tr('停止')),
            )
          else
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: Text(tr('开始')),
            ),
          if (!_running && _steps.isNotEmpty)
            IconButton(
              tooltip: tr('复制结论'),
              icon: const Icon(Icons.copy_all, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _report()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('已复制，可直接贴给开发看'))));
                }
              },
            ),
        ]),
      ),
      if (_running) const LinearProgressIndicator(minHeight: 2),
      const Divider(height: 8),
      Expanded(
        child: _steps.isEmpty
            ? Center(
                child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '${tr('还没有开始。写一句目标，点开始。')}\n${tr('它每步都会截图，看错也能被下一步纠正。')}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ))
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                itemCount: _steps.length,
                itemBuilder: (_, i) => _stepCard(_steps[i]),
              ),
      ),
    ]);
  }

  Widget _stepCard(AgentStepView s) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (s.shot != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(s.shot!,
                  width: 54, height: 96, fit: BoxFit.cover,
                  gaplessPlayback: true),
            )
          else
            const SizedBox(width: 54, height: 96, child: Icon(Icons.image_not_supported_outlined, size: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('${s.index}', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                const SizedBox(width: 6),
                Icon(s.ok ? Icons.check_circle : Icons.error_outline,
                    size: 13, color: s.ok ? Colors.green : Colors.redAccent),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(s.say,
                      style: const TextStyle(fontSize: 12.5),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                s.action == null ? '—' : '${s.action}',
                style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: cs.onSurfaceVariant),
                maxLines: 2, overflow: TextOverflow.ellipsis,
              ),
              if (!s.ok && s.error != null)
                Text(s.error!,
                    style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 给 AI 模块 `+` 面板用的一行入口（点开就是上面那个面板）。
class AgentInlineTile extends StatelessWidget {
  final AiProvider provider;
  final String model;

  const AgentInlineTile({super.key, required this.provider, required this.model});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.auto_awesome_outlined, size: 20),
      title: Text(tr('让它自己操作 App'), style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        trf('用当前模型 {m} 看截图、自己点，跑完给出结论', {'m': model}),
        style: const TextStyle(fontSize: 11),
        maxLines: 1, overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.pop(context);
        AgentInline.show(context, provider: provider, model: model);
      },
    );
  }
}
