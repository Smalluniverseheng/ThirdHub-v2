// AI 智能体控制台(TH-Agent v1 / THA-1 协议)
//
// 五个子页，职责各不相同：
//   · 任务   —— Agent 控制面：运行模式、权限档位、事件流、确认审批、审计
//   · 指令   —— 全局人格与指令(Custom Instructions)
//   · 智能体 —— 可授权的智能体定义(人格 + 工具授权 + 轮数 + 审批)
//   · 记忆   —— 跨会话长期记忆(Memory)
//   · 钉注   —— 会话级固定上下文(Pinned Context)
// 前四栏作用于**轻量 Agent** 路径；「任务」栏对着服务端 Agent Runtime(DSH)。
// 两条路的上下文装配规则是同一套(见 ai_agent.dart 的 AiContext)。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'agent_dsh_client.dart';
import 'agent_models.dart';
import 'agent_policy.dart';
import 'ai.dart';
import 'ai_agent.dart';
import 'local_tools.dart';

class AiAgentPage extends StatefulWidget {
  /// 传入会话 id 时多出「钉注」一栏(钉注是会话级的)
  final String sessionId;
  const AiAgentPage({super.key, this.sessionId = ''});
  @override State<AiAgentPage> createState() => _AiAgentPageState();
}

class _AiAgentPageState extends State<AiAgentPage> with SingleTickerProviderStateMixin {
  late final bool _hasPins = widget.sessionId.isNotEmpty;
  late final TabController _tab = TabController(length: _hasPins ? 5 : 4, vsync: this);

  @override void initState() {
    super.initState();
    Future.wait([AiAgents.load(), AiInstruct.load(), AiMemory.load()])
        .then((_) { if (mounted) setState(() {}); });
  }

  @override void dispose() { _tab.dispose(); super.dispose(); }

  void _refresh() { if (mounted) setState(() {}); }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('智能体 · 任务 · 指令 · 记忆'), bottom: TabBar(controller: _tab, tabs: [
      const Tab(text: '任务'), const Tab(text: '指令'), const Tab(text: '智能体'), const Tab(text: '记忆'),
      if (_hasPins) const Tab(text: '钉注'),
    ])),
    body: TabBarView(controller: _tab, children: [
      _TaskTab(onChanged: _refresh),
      _InstructView(onChanged: _refresh),
      _AgentsTab(onChanged: _refresh),
      _MemoryTab(onChanged: _refresh),
      if (_hasPins) _PinsTab(sessionId: widget.sessionId, onChanged: _refresh),
    ]));
}

// ── 指令: 对话风格 + 全局指令(对所有会话生效) ──
class _InstructView extends StatefulWidget {
  final VoidCallback onChanged;
  const _InstructView({required this.onChanged});
  @override State<_InstructView> createState() => _InstructViewState();
}

class _InstructViewState extends State<_InstructView> {
  final _ctl = TextEditingController(); bool _init = false;

  @override void dispose() { _ctl.dispose(); super.dispose(); }

  @override Widget build(BuildContext c) {
    if (!_init) { _ctl.text = AiInstruct.custom; _init = true; }
    return ListView(padding: const EdgeInsets.all(14), children: [
      const Text('对话风格', style: TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 6),
      Card(margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          for (final e in AiInstruct.personas.entries)
            ListTile(dense: true,
              title: Text(e.value.$1, style: const TextStyle(fontSize: 14)),
              subtitle: e.value.$2.isEmpty
                ? const Text('不加任何风格约束', style: TextStyle(fontSize: 11))
                : Text(e.value.$2, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              trailing: AiInstruct.personaId == e.key
                ? const Icon(Icons.check, size: 18, color: Colors.blueAccent) : null,
              onTap: () async {
                await AiInstruct.setPersona(e.key);
                widget.onChanged();
                setState(() {});
              }),
        ])),
      const SizedBox(height: 18),
      const Text('全局指令', style: TextStyle(fontSize: 12, color: Colors.grey)),
      const Padding(padding: EdgeInsets.only(top: 4, bottom: 8),
        child: Text('写给所有会话的"使用说明书"，每轮对话都会带上。例：我是做后端的，少讲前端；回答先给结论。',
          style: TextStyle(fontSize: 11, color: Colors.grey))),
      Card(margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(padding: const EdgeInsets.all(12),
          child: TextField(controller: _ctl, maxLines: 8, minLines: 4, style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(border: InputBorder.none, hintText: '在这里写你的全局指令…')))),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: FilledButton(
          onPressed: () async {
            await AiInstruct.setCustom(_ctl.text);
            widget.onChanged();
            setState(() {});
            if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(
              content: Text(AiInstruct.custom.isEmpty ? '已清空全局指令' : '已保存，下一轮对话生效')));
          },
          child: const Text('保存'))),
        const SizedBox(width: 10),
        OutlinedButton(onPressed: () => setState(() => _ctl.clear()), child: const Text('清空')),
      ]),
      const SizedBox(height: 12),
      Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(
        color: Theme.of(c).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('装配顺序（由弱到强）', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('① 对话风格  ② 全局指令  ③ 智能体人格  ④ 技能  ⑤ 长期记忆  ⑥ 会话钉注  ⑦ 工具清单',
            style: TextStyle(fontSize: 11.5, height: 1.6, color: Theme.of(c).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          const Text('越靠后优先级越高；上下文超预算时自动折叠早期消息为摘要。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        ])),
    ]);
  }
}

// ── 智能体 ──
class _AgentsTab extends StatefulWidget {
  final VoidCallback onChanged;
  const _AgentsTab({required this.onChanged});
  @override State<_AgentsTab> createState() => _AgentsTabState();
}

class _AgentsTabState extends State<_AgentsTab> {
  @override Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(14), children: [
    Row(children: [
      const Expanded(child: Text('智能体 = 人格 + 工具授权 + 轮数上限',
        style: TextStyle(fontSize: 12, color: Colors.grey))),
      TextButton.icon(onPressed: () => _edit(c, null),
        icon: const Icon(Icons.add, size: 18), label: const Text('新建')),
    ]),
    for (final a in AiAgents.all)
      Card(margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ListTile(
          leading: Text(a.icon, style: const TextStyle(fontSize: 20)),
          title: Row(children: [
            Expanded(child: Text(a.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
            _tag(a.builtin ? '内置' : '自定义', a.builtin),
          ]),
          subtitle: Padding(padding: const EdgeInsets.only(top: 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.desc, style: const TextStyle(fontSize: 11)),
              Text('工具: ${a.grant} · 最多 ${a.maxRounds} 轮'
                   '${a.autoApprove ? " · 自动批准" : " · 危险操作需确认"}',
                style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
            ])),
          trailing: const Icon(Icons.edit_outlined, size: 18),
          onTap: () => _edit(c, a),
        )),
  ]);

  static Widget _tag(String text, bool builtin) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: builtin ? Colors.grey.withValues(alpha: 0.2) : Colors.blue.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(6)),
    child: Text(text, style: TextStyle(fontSize: 9.5, color: builtin ? Colors.grey : Colors.blueAccent)));

  static List<String> _split(String s) =>
    [for (final e in s.split(',')) if (e.trim().isNotEmpty) e.trim()];

  Future<void> _edit(BuildContext c, AiAgentDef? src) async {
    // 全部先摊平成非空局部量: 闭包里用 src.x 会触发空安全告警
    final isNew = src == null;
    final isFork = src != null && src.builtin;
    final editing = !isNew && !isFork;
    final baseId = src?.id ?? '';
    final srcName = src?.name ?? '';

    final name = TextEditingController(text: src?.name ?? '');
    final icon = TextEditingController(text: src?.icon ?? '🤖');
    final desc = TextEditingController(text: src?.desc ?? '');
    final sys = TextEditingController(text: src?.system ?? '');
    final allow = TextEditingController(text: src?.allow.join(', ') ?? '');
    final deny = TextEditingController(text: src?.deny.join(', ') ?? '');
    var rounds = src?.maxRounds ?? 8;
    var auto = src?.autoApprove ?? false;

    final saved = await showModalBottomSheet<bool>(
      context: c, isScrollControlled: true,
      builder: (c2) => StatefulBuilder(builder: (c2, setD) {
        InputDecoration dec(String label) => InputDecoration(labelText: label);
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(c2).viewInsets.bottom),
          child: SafeArea(child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(isNew ? '新建智能体' : (isFork ? '复制内置「$srcName」为自定义' : '编辑智能体'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Row(children: [
                SizedBox(width: 70, child: TextField(controller: icon, textAlign: TextAlign.center,
                  decoration: dec('图标'))),
                const SizedBox(width: 10),
                Expanded(child: TextField(controller: name, decoration: dec('名称'))),
              ]),
              const SizedBox(height: 10),
              TextField(controller: desc, decoration: dec('一句话简介')),
              const SizedBox(height: 10),
              TextField(controller: sys, maxLines: 5,
                decoration: const InputDecoration(labelText: '人格指令(system)', alignLabelWithHint: true)),
              const SizedBox(height: 12),
              const Text('工具授权', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const Padding(padding: EdgeInsets.only(top: 2, bottom: 6),
                child: Text('填 local / mcp 表示整类放行；也可写精确工具名或 local_file_* 前缀通配。留空 = 全部工具。',
                  style: TextStyle(fontSize: 11, color: Colors.grey))),
              Wrap(spacing: 6, runSpacing: 4, children: [
                ActionChip(label: const Text('全部', style: TextStyle(fontSize: 11)),
                  onPressed: () => setD(() { allow.text = ''; deny.text = ''; })),
                ActionChip(label: const Text('只用本机', style: TextStyle(fontSize: 11)),
                  onPressed: () => setD(() { allow.text = 'local'; deny.text = ''; })),
                ActionChip(label: const Text('只用 MCP', style: TextStyle(fontSize: 11)),
                  onPressed: () => setD(() { allow.text = 'mcp'; deny.text = ''; })),
                ActionChip(label: const Text('只读不写', style: TextStyle(fontSize: 11)),
                  onPressed: () => setD(() {
                    allow.text = 'local_file_read, local_file_list, local_web_search, mcp'; deny.text = ''; })),
                ActionChip(label: const Text('不调工具', style: TextStyle(fontSize: 11)),
                  onPressed: () => setD(() { allow.text = '__none__'; deny.text = ''; })),
              ]),
              const SizedBox(height: 8),
              TextField(controller: allow, decoration: dec('allow(逗号分隔)')),
              const SizedBox(height: 8),
              TextField(controller: deny, decoration: dec('deny(优先级高于 allow)')),
              const SizedBox(height: 14),
              Row(children: [
                const Expanded(child: Text('轮数上限(最多"想-做-看"几轮)', style: TextStyle(fontSize: 13))),
                Text('$rounds', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ]),
              Slider(value: rounds.toDouble(), min: 1, max: 24, divisions: 23, label: '$rounds',
                onChanged: (v) => setD(() => rounds = v.round())),
              SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, value: auto,
                onChanged: (v) => setD(() => auto = v),
                title: const Text('自动批准工具执行', style: TextStyle(fontSize: 13.5)),
                subtitle: const Text('关闭时，改文件/删文件/写剪贴板等操作会先弹确认',
                  style: TextStyle(fontSize: 11))),
              const SizedBox(height: 12),
              Row(children: [
                if (editing) ...[
                  OutlinedButton.icon(
                    onPressed: () async {
                      await AiAgents.removeCustom(baseId);
                      if (c2.mounted) Navigator.pop(c2, true);
                    },
                    icon: const Icon(Icons.delete_outline, size: 18), label: const Text('删除')),
                  const SizedBox(width: 10),
                ],
                const Spacer(),
                FilledButton(onPressed: () async {
                  final n = name.text.trim();
                  if (n.isEmpty) {
                    ScaffoldMessenger.of(c2).showSnackBar(const SnackBar(content: Text('名称不能为空')));
                    return;
                  }
                  await AiAgents.saveCustom(AiAgentDef(
                    id: editing ? baseId : AiAgents.newId(),
                    name: n, icon: icon.text.trim().isEmpty ? '🤖' : icon.text.trim(),
                    desc: desc.text.trim(), system: sys.text.trim(),
                    allow: _split(allow.text), deny: _split(deny.text),
                    maxRounds: rounds, autoApprove: auto, builtin: false));
                  if (c2.mounted) Navigator.pop(c2, true);
                }, child: const Text('保存')),
              ]),
            ]),
          )),
        );
      }));

    name.dispose(); icon.dispose(); desc.dispose(); sys.dispose(); allow.dispose(); deny.dispose();
    if (saved == true) { widget.onChanged(); if (mounted) setState(() {}); }
  }
}

// ── 记忆 ──
class _MemoryTab extends StatefulWidget {
  final VoidCallback onChanged;
  const _MemoryTab({required this.onChanged});
  @override State<_MemoryTab> createState() => _MemoryTabState();
}

class _MemoryTabState extends State<_MemoryTab> {
  final _ctl = TextEditingController();

  @override void dispose() { _ctl.dispose(); super.dispose(); }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('长期记忆', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        const Padding(padding: EdgeInsets.only(top: 3),
          child: Text('写在这里的事实，之后「每个」会话都会自动带上。适合记"我是谁""我的偏好"。',
            style: TextStyle(fontSize: 11, color: Colors.grey))),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: _ctl, style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '例: 我在杭州，做后端，习惯用 Dart',
              isDense: true, border: OutlineInputBorder()))),
          const SizedBox(width: 8),
          FilledButton(onPressed: () async {
            final t = _ctl.text.trim();
            if (t.isEmpty) return;
            await AiMemory.add(t);
            _ctl.clear();
            widget.onChanged();
            if (mounted) setState(() {});
          }, child: const Text('记住')),
        ]),
      ])),
    const Divider(height: 1),
    Expanded(child: AiMemory.entries.isEmpty
      ? const Center(child: Text('还没有记忆条目', style: TextStyle(fontSize: 12, color: Colors.grey)))
      : ListView.builder(padding: const EdgeInsets.all(10), itemCount: AiMemory.entries.length,
          itemBuilder: (_, i) {
            final e = AiMemory.entries[i];
            return Card(margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(dense: true,
                title: Text(e.text, style: const TextStyle(fontSize: 13)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.edit_outlined, size: 17),
                    onPressed: () => _edit(c, e)),
                  IconButton(icon: const Icon(Icons.close, size: 17), onPressed: () async {
                    await AiMemory.remove(e.id); widget.onChanged(); if (mounted) setState(() {});
                  }),
                ])));
          })),
  ]);

  Future<void> _edit(BuildContext c, AiMemoryEntry e) async {
    final t = TextEditingController(text: e.text);
    final ok = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(
      title: const Text('编辑记忆'),
      content: TextField(controller: t, maxLines: 4),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存')),
      ]));
    // 先取值再 dispose(dispose 后不能读 controller.text)
    final txt = t.text;
    t.dispose();
    if (ok == true) {
      await AiMemory.update(e.id, txt);
      widget.onChanged();
      if (mounted) setState(() {});
    }
  }
}

// ── 会话钉注 ──
class _PinsTab extends StatefulWidget {
  final String sessionId;
  final VoidCallback onChanged;
  const _PinsTab({required this.sessionId, required this.onChanged});
  @override State<_PinsTab> createState() => _PinsTabState();
}

class _PinsTabState extends State<_PinsTab> {
  final _ctl = TextEditingController();
  List<String> _pins = []; bool _loading = true;

  @override void initState() { super.initState(); _load(); }
  @override void dispose() { _ctl.dispose(); super.dispose(); }

  Future<void> _load() async {
    final p = await AiPins.get(widget.sessionId);
    if (mounted) setState(() { _pins = p; _loading = false; });
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('本次会话钉注', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        const Padding(padding: EdgeInsets.only(top: 3),
          child: Text('只作用于当前这条会话，每轮都会随请求带上。适合钉一份资料、一段规则。',
            style: TextStyle(fontSize: 11, color: Colors.grey))),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: _ctl, maxLines: 3, minLines: 1,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '粘贴资料 / 写规则…',
              isDense: true, border: OutlineInputBorder()))),
          const SizedBox(width: 8),
          FilledButton(onPressed: () async {
            if (_ctl.text.trim().isEmpty) return;
            await AiPins.add(widget.sessionId, _ctl.text);
            _ctl.clear();
            await _load();
            widget.onChanged();
          }, child: const Text('钉住')),
        ]),
      ])),
    const Divider(height: 1),
    Expanded(child: _loading
      ? const Center(child: CircularProgressIndicator())
      : _pins.isEmpty
        ? const Center(child: Text('本次会话还没有钉注', style: TextStyle(fontSize: 12, color: Colors.grey)))
        : ListView.builder(padding: const EdgeInsets.all(10), itemCount: _pins.length,
            itemBuilder: (_, i) => Card(margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(dense: true,
                leading: CircleAvatar(radius: 11, child: Text('${i + 1}', style: const TextStyle(fontSize: 10))),
                title: Text(_pins[i], maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                trailing: IconButton(icon: const Icon(Icons.push_pin_outlined, size: 17), tooltip: '取消钉住',
                  onPressed: () async { await AiPins.removeAt(widget.sessionId, i); await _load(); widget.onChanged(); }))))),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────
// 任务：Agent 控制面
// ─────────────────────────────────────────────────────────────────────────
// 这一栏只做**控制面** —— 发起任务、渲染事件流、批准/拒绝高危操作、看审计。
// Agent 内核（上下文装配 / 插件 / 沙箱 / MCP）不在 Dart 侧：
//   · 服务端接上了 DSH → 完整模式，事件由 DSH 产出；
//   · 没接上 → 降级为轻量模式，并**如实说明现在缺哪些能力**，
//     而不是把按钮画得能点、点下去却什么都不发生。
// 协议见 docs/AGENT-PROTOCOL.md（THA/1）。
class _TaskTab extends StatefulWidget {
  final VoidCallback onChanged;
  const _TaskTab({required this.onChanged});
  @override State<_TaskTab> createState() => _TaskTabState();
}

class _TaskTabState extends State<_TaskTab> {
  AgentHealth _h = AgentRuntime.health;
  String _profile = AgentRuntime.profile;
  final List<AgentEvent> _events = [];
  AgentSession? _session;
  List<AgentAuditRecord> _audit = [];
  List<Map<String, dynamic>> _tools = [];
  bool _busy = false, _booted = false, _waiting = false;
  String _note = '';
  bool _noteBad = false;
  StreamSubscription<AgentEvent>? _sub;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// artifact：已回取的全文 / 正在回取 / 已展开的 diff（都按事件 id 存，跨重建保持）
  final Map<String, String> _artFull = {};
  final Set<String> _artBusy = {};
  final Set<String> _artDiffOpen = {};

  /// 轻量循环正在流式输出的正文（还没落成 assistant_message 事件的那部分）。
  /// 单独放一个字段而不是塞假事件进 `_events`：事件流必须是**服务端权威**的
  /// append-only 记录，本地草稿不该混进去。
  String _liteStream = '';
  bool _liteRunning = false;

  /// 后端是否**真的能连上**。
  ///
  /// 原来这里写的是 `AgentRuntime.backendConnected`，而它只表示「地址填过」——
  /// 后端关机后界面照旧显示已连接、能发任务，然后静默失败。
  bool get _online => AgentRuntime.online;
  AgentTimeline get _tl => AgentTimeline(_events);
  int get _lastSeq => _events.isEmpty ? 0 : _events.last.seq;

  @override void initState() { super.initState(); _boot(); }

  @override void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _say(String text, {bool bad = false}) {
    if (!mounted) return;
    setState(() { _note = text; _noteBad = bad; });
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _boot() async {
    _profile = AgentRuntime.profile;
    // 不再用 `if (_online)` 把探测挡在外面 —— online 的初值是 false，
    // 那样写就永远探不到、永远停在「离线」，是个自锁。
    final h = await AgentRuntime.refresh();
    if (h != null) _h = h;
    await _reloadTools();
    await _reloadAudit();
    if (mounted) setState(() => _booted = true);
  }

  /// 工具清单：在线时用服务端判定（服务端是权威），离线时退回本地镜像。
  Future<void> _reloadTools() async {
    if (_online) {
      final list = await AgentDshClient.tools(profile: _profile);
      _tools = [
        for (final t in list)
          {
            'name': t.name, 'risk': t.risk, 'riskLabel': t.riskLabel,
            'decision': t.decision, 'reason': t.reason,
          }
      ];
    } else {
      _tools = AgentPolicy.catalog(_profile);
    }
    if (mounted) setState(() {});
  }

  Future<void> _reloadAudit() async {
    if (!_online) return;
    final a = await AgentDshClient.audit(limit: 50);
    if (mounted) setState(() => _audit = a);
  }

  Future<void> _pickProfile(String? id) async {
    if (id == null || id == _profile) return;
    await AgentRuntime.setProfile(id);
    _profile = AgentRuntime.profile;
    await _reloadTools();
    widget.onChanged();
  }

  Future<void> _toggleDsh(bool start) async {
    if (!_online) {
      _say('连不上家庭后端（${AgentRuntime.offlineReason.isEmpty ? "地址未填或探测无响应" : AgentRuntime.offlineReason}）'
           ' —— DSH 跑在后端那侧，先去「我的 → 系统 → 连接资源库」把地址填上并确认能连通', bad: true);
      return;
    }
    setState(() => _busy = true);
    final ok = start ? await AgentDshClient.startDsh() : await AgentDshClient.stopDsh();
    final err = AgentDshClient.lastDshError;
    final h = await AgentRuntime.refresh();
    if (h != null) _h = h;
    if (mounted) setState(() => _busy = false);
    _say(
        ok
            ? (start ? '已请求启动 DSH，正在重新检测…' : '已请求停止 DSH')
            // 把服务端给的**真因**透出来。原来这里一律换成「后端版本或权限不符」，
            // 而实测最常见的真因是「这台后端根本没装 DSH」，用户被引去查日志。
            : 'DSH 启动失败：${err.isEmpty ? "后端未响应" : err}'
              '${err.contains("未找到") ? "（后端机器上没装 DSH。装好后用环境变量 TH_DSH_CMD 或 TH_DSH_URL 指向它，详见后端 docs/AGENT-PROTOCOL.md §14）" : ""}',
        bad: !ok);
  }

  /// 按序号补事件 —— SSE 被中间设备掐断时不会漏事件。
  Future<void> _pull() async {
    final sid = _session?.id ?? '';
    if (sid.isEmpty || !_online) return;
    final r = await AgentDshClient.events(sid, since: _lastSeq);
    if (!mounted) return;
    if (r.events.isEmpty) { _say('没有新事件'); return; }
    setState(() {
      _events.addAll(r.events);
      if (r.events.any((e) => e.isTerminal)) _waiting = false;
    });
    _say('已拉取 ${r.events.length} 条新事件');
    _toBottom();
  }

  void _subscribe(String sid) {
    _sub?.cancel();
    _sub = AgentDshClient.streamEvents(sid, since: _lastSeq).listen((e) {
      if (!mounted) return;
      setState(() {
        _events.add(e);
        if (e.isTerminal) _waiting = false;
      });
      _toBottom();
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _waiting = false);
      _say('事件流中断 —— 中间设备可能掐了长连接。点下方「拉取新事件」按序号补齐，不会丢事件', bad: true);
    }, onDone: () {
      if (mounted) setState(() => _waiting = false);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!_online) {
      _say('还连不上家庭后端（${AgentRuntime.offlineReason.isEmpty ? "地址未填或探测无响应" : AgentRuntime.offlineReason}）'
           ' —— 点上面的「去填后端地址」填上并确认能连通。'
           '只想聊天的话直接去「AI 对话」页，那条路不依赖后端', bad: true);
      return;
    }
    if (_busy) return;
    setState(() { _busy = true; _note = ''; _noteBad = false; });
    if (_session == null) {
      final title = text.length > 18 ? '${text.substring(0, 18)}…' : text;
      final s = await AgentDshClient.createSession(title: title, profile: _profile);
      if (s == null) {
        if (mounted) setState(() => _busy = false);
        _say('建会话失败：后端无响应，或档位「$_profile」不被接受', bad: true);
        return;
      }
      _session = s;
    }
    final sid = _session!.id;
    _input.clear();
    final r = await AgentDshClient.send(sid, text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.event != null) _events.add(r.event!);
      _waiting = r.full;
    });
    _toBottom();
    if (r.full) {
      _say('完整模式：已落账，事件由后端的 DSH 产出，正在订阅事件流…');
      _subscribe(sid);
    } else {
      // ★ 降级路径落地：后端在、但没有 DSH —— 由**本机模型**跑完这一轮，
      //   过程事件回填到同一份事件流里（THA/1 的立场是「事件协议不变、
      //   控制面不分叉」，循环在哪跑，记录都该是同一份）。
      await _runLite(sid, text);
    }
  }

  /// 轻量循环：本机模型 + 本机/MCP 工具，按当前权限档位逐项判定，
  /// confirm 级工具在本地弹确认，每一步都 appendEvent 回服务端。
  ///
  /// 为什么必须做回填：此前这里只落一条 user_message 就结束，界面上留下一句
  /// 「过程事件由客户端按轻量循环回填」的承诺，而回填用的
  /// `AgentDshClient.appendEvent` 全仓无人调用 —— 于是任务页永远表现为
  /// 「发了没反应」，而降级模式是最常见的状态（大多数人没装 DSH）。
  Future<void> _runLite(String sid, String text) async {
    if (_liteRunning) return;
    final (provId, lastModelId) = await AiRegistry.lastModel();
    final prov = AiRegistry.byId(provId);
    if (prov == null) {
      _say('轻量模式需要一个本机模型：先去「AI 对话」页选一个模型'
           '（本机记住的是「$provId」，它不在厂商表里）', bad: true);
      return;
    }
    if ((await AiRegistry.keyOf(prov.id)).isEmpty) {
      _say('模型「${prov.name}」还没填 API Key —— 在「AI 对话」页右上角设置里填上，回来就能用', bad: true);
      return;
    }
    final model = lastModelId.isNotEmpty
        ? lastModelId
        : (prov.models.isEmpty ? '' : prov.models.first);
    if (model.isEmpty) {
      _say('厂商「${prov.name}」没有可用模型名，请到「AI 对话」页重新选一个', bad: true);
      return;
    }
    setState(() { _liteRunning = true; _liteStream = ''; });
    _say('轻量模式（后端没有 DSH）：本轮由本机「${prov.name} · $model」执行，过程会回填到下面的事件流');

    final tools = <Map<String, dynamic>>[
      ...Mcp.allTools(),
      ...LocalTools.schemas(),
    ];

    Future<String> exec(String serverId, String name,
        Map<String, dynamic> args) async {
      final d = AgentRuntime.checkTool(name);
      await AgentDshClient.appendEvent(sid, AgentEventType.toolCall, {
        'tool': name, 'args': args, 'risk': d.risk,
        'riskLabel': AgentPolicy.riskLabel(d.risk),
        'decision': d.decision, 'reason': d.reason, 'serverId': serverId,
      });
      if (d.decision == AgentDecision.deny) {
        final msg = '权限档位「$_profile」禁用该工具：${d.reason}';
        await AgentDshClient.appendEvent(sid, AgentEventType.toolResult,
            {'tool': name, 'ok': false, 'text': msg});
        return msg;
      }
      if (d.decision == AgentDecision.confirm) {
        if (!await _askLiteConfirm(name, args, d.reason)) {
          final msg = '用户拒绝了本次工具调用「$name」，请换一种方式，或直接说明你做不到。';
          await AgentDshClient.appendEvent(sid, AgentEventType.toolResult,
              {'tool': name, 'ok': false, 'text': msg});
          return msg;
        }
      }
      var out = '';
      try {
        if (serverId == 'local') {
          out = await LocalTools.call(name, args);
        } else {
          final res = await Mcp.callTool(serverId, name, args);
          out = [
            for (final c in (res['content'] as List? ?? [])) '${c['text'] ?? c}'
          ].join('\n');
          if (out.isEmpty) out = jsonEncode(res);
        }
      } catch (e) {
        out = '工具执行失败: $e';
      }
      await AgentDshClient.appendEvent(sid, AgentEventType.toolResult,
          {'tool': name, 'ok': true, 'text': out});
      return out;
    }

    var full = '';
    try {
      final stack = await AiContext.systemStack(
          pins: const [], toolManifest: true, tools: tools);
      final msgs = <Map<String, String>>[
        ...stack,
        {'role': 'user', 'content': text},
      ];
      var pending = '';
      Timer? flushT;
      full = await AiChat.chat(
        provider: prov, model: model, messages: msgs,
        mcpTools: tools.isEmpty ? null : tools,
        toolExecutor: exec,
        maxRounds: 8,
        textToolFallback: true,
        onToolCall: (name) => _say('正在调用工具 $name'),
        onDelta: (delta) {
          pending += delta;
          // 与 AI 对话页同款合帧：66ms 落一次 UI，避免逐 token 抖动
          flushT ??= Timer(const Duration(milliseconds: 66), () {
            flushT = null;
            if (!mounted || pending.isEmpty) return;
            final add = pending; pending = '';
            setState(() => _liteStream += add);
            _toBottom();
          });
        },
      );
      flushT?.cancel();
      if (pending.isNotEmpty && mounted) {
        setState(() => _liteStream += pending);
        pending = '';
      }
      if (full.trim().isEmpty) full = '（模型没有返回内容）';
      await AgentDshClient.appendEvent(
          sid, AgentEventType.assistantMessage, {'text': full});
      await AgentDshClient.appendEvent(sid, AgentEventType.done, {});
      if (!mounted) return;
      setState(() {
        _liteRunning = false;
        _liteStream = '';
        _waiting = false;
      });
      await _pull();          // 把服务端落账的 assistant_message/done 拉回来
      await _reloadAudit();
      _say('本轮完成（轻量模式 · ${prov.name}）');
    } catch (e) {
      if (!mounted) return;
      setState(() { _liteRunning = false; _liteStream = ''; _waiting = false; });
      _say('轻量循环失败: $e', bad: true);
    }
  }

  /// 轻量循环里 confirm 级工具的确认弹窗（与控制面同一套语义：
  /// 档位说「需确认」就一定要人点一下，绝不因为「本地跑」就自动放行）
  Future<bool> _askLiteConfirm(
      String name, Map<String, dynamic> args, String reason) async {
    if (!mounted) return false;
    var pretty = '';
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(args);
    } catch (_) {
      pretty = '$args';
    }
    if (pretty.length > 900) pretty = '${pretty.substring(0, 900)}…';
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: Row(children: const [
                Icon(Icons.gpp_maybe_outlined, size: 20),
                SizedBox(width: 8),
                Expanded(child: Text('这轮任务想执行一个操作', style: TextStyle(fontSize: 15))),
              ]),
              content: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                    if (reason.isNotEmpty)
                      Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('档位判定：$reason',
                              style: const TextStyle(fontSize: 11, color: Colors.grey))),
                    const SizedBox(height: 8),
                    Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: Theme.of(c).colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(8)),
                        child: SelectableText(
                            pretty.isEmpty ? '(无参数)' : pretty,
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
                  ])),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('拒绝')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('允许一次')),
              ],
            ));
    return ok == true;
  }

  Future<void> _newSession() async {
    _sub?.cancel();
    setState(() { _events.clear(); _session = null; _note = ''; _waiting = false; });
  }

  Future<void> _answerConfirm(String confirmId, bool allow) async {
    if (!_online) return;
    final ok = await AgentDshClient.resolveConfirm(confirmId, allow);
    if (!mounted) return;
    if (!ok) { _say('答复失败：该确认可能已过期或已被处理', bad: true); return; }
    // 服务端会往事件流里补一条 confirm_result —— 立刻拉回来，免得 UI 停在「待确认」
    await _pull();
    await _reloadAudit();
  }

  // ── 视图 ──────────────────────────────────────────────────────────────
  @override Widget build(BuildContext c) {
    if (!_booted) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(c).colorScheme;
    return Column(children: [
      Expanded(child: ListView(controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8), children: [
          _modeCard(cs),
          const SizedBox(height: 10),
          _profileCard(cs),
          const SizedBox(height: 10),
          _sessionCard(cs),
          const SizedBox(height: 10),
          if (_events.isEmpty) _emptyHint() else ..._renderStream(cs),
          const SizedBox(height: 10),
          _toolsCard(cs),
          if (_online) ...[const SizedBox(height: 10), _auditCard(cs)],
        ])),
      _composer(cs),
    ]);
  }

  Widget _modeCard(ColorScheme cs) {
    final full = _h.isFull;
    final col = full ? Colors.green : Colors.orange;
    return Card(margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.circle, size: 9, color: col),
            const SizedBox(width: 6),
            Text(full ? '完整 Agent（DSH）' : '轻量 Agent（无 DSH）',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_busy) const SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text(_h.summary, style: const TextStyle(fontSize: 11.5, height: 1.5)),
          const SizedBox(height: 4),
          Text('协议 ${_h.protocolVersion.isEmpty ? 'THA/1' : _h.protocolVersion}'
               ' · DSH ${_h.dshKind}${_h.dshVersion.isEmpty ? '' : ' ${_h.dshVersion}'}'
               ' · 进程 ${_h.dshRunning ? '运行中' : '未运行'}',
            style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final e in _h.capabilities.entries) _capChip(e.key, e.value),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (!_online)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => AgentRuntime.openConnector?.call(),
                icon: const Icon(Icons.link, size: 16),
                label: const Text('去填后端地址', style: TextStyle(fontSize: 12))),
            OutlinedButton.icon(onPressed: _busy ? null : _boot,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新检测', style: TextStyle(fontSize: 12))),
            if (!_h.dshRunning)
              OutlinedButton.icon(
                onPressed: _busy || !_online ? null : () => _toggleDsh(true),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('启动 DSH', style: TextStyle(fontSize: 12)))
            else
              OutlinedButton.icon(onPressed: _busy ? null : () => _toggleDsh(false),
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('停止 DSH', style: TextStyle(fontSize: 12))),
          ]),
        ])));
  }

  static Widget _capChip(String key, bool on) {
    const label = <String, String>{
      'eventLog': '事件流', 'policy': '权限判定', 'confirmQueue': '确认队列',
      'audit': '审计', 'mcpRegistry': 'MCP 注册表',
      'nativePlugins': '原生插件', 'sandbox': '沙箱',
    };
    final col = on ? Colors.green : Colors.grey;
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: col.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(on ? Icons.check : Icons.remove, size: 11, color: col),
        const SizedBox(width: 4),
        Text(label[key] ?? key, style: TextStyle(fontSize: 10, color: col)),
      ]));
  }

  Widget _profileCard(ColorScheme cs) {
    final vis = AgentPolicy.visibleProfiles();
    final ids = [for (final p in vis) '${p['id']}'];
    final sel = ids.contains(_profile) ? _profile : (ids.isEmpty ? null : ids.first);
    // 档位名可能在普通用户可见列表之外（管理侧的 full-access）—— 下拉框那时退到
    // 第一个可见档位，但下面的判定概览**仍按真实档位算**：UI 显示不该改权限。
    final s = AgentPolicy.summary(_profile);
    return Card(margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('权限档位', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const Spacer(),
            DropdownButton<String>(value: sel, isDense: true, underline: const SizedBox.shrink(),
              style: TextStyle(fontSize: 13, color: cs.onSurface),
              items: [for (final p in vis)
                DropdownMenuItem(value: '${p['id']}',
                  child: Text('${p['label']}', style: const TextStyle(fontSize: 13)))],
              onChanged: _pickProfile),
          ]),
          const SizedBox(height: 4),
          Text('可执行 ${s['allow']} · 需确认 ${s['confirm']} · 禁用 ${s['deny']}',
            style: const TextStyle(fontSize: 11.5)),
          const SizedBox(height: 3),
          Text(_online
              ? '判定由服务端给出（服务端是权威${AgentPolicy.usingServerTable ? " · 已同步服务端表 v${AgentPolicy.serverVersion}" : ""}）'
              : '离线：以下判定用本地镜像预演，连上后端后以服务端为准',
            style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
          if (sel != null && sel != _profile)
            Padding(padding: const EdgeInsets.only(top: 3),
              child: Text('当前实际档位：$_profile（不在普通用户可见列表内，仅管理侧使用）',
                style: const TextStyle(fontSize: 10.5, color: Colors.orange))),
        ])));
  }

  Widget _sessionCard(ColorScheme cs) => Card(margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(children: [
        Icon(Icons.task_alt, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_session == null ? '未开始任务' : (_session!.title.isEmpty ? '未命名任务' : _session!.title),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          Text(_session == null ? '发送第一条指令时自动建会话（档位：$_profile）'
                                : '${_session!.eventCount} 事件 · $_profile · ${_session!.status}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
        ])),
        TextButton(onPressed: _newSession, child: const Text('新任务', style: TextStyle(fontSize: 12))),
      ])));

  Widget _emptyHint() => Container(padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(!_online
            ? '还连不上家庭后端'
            : (_h.isFull ? '完整模式：事件由后端的 DSH 产出' : '轻量模式：这一轮由你手机上的模型执行'),
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text(!_online
          ? '现象：发送按钮是灰的，任务发不出去。'
            '原因：${AgentRuntime.offlineReason.isEmpty ? "还没填后端地址，或探测无响应" : AgentRuntime.offlineReason}。'
            '怎么办：点上面「去填后端地址」把家庭后端地址填上并确认能连通。'
            '不连后端也能用 —— 「AI 对话」页那条路本来就不依赖后端。'
          : (_h.isFull
              ? '发一条任务后，这一栏会按顺序出现：① 助手流式正文  ② 工具调用（工具名 + 风险等级 + 参数）\n'
                '③ 确认请求（高危操作会停在这里等你点「允许一次 / 拒绝」）  ④ 工具结果与产物'
              : '发一条任务后：后端负责落账与审计，具体执行由本机模型完成，过程和结果同样会回到这一栏。'
                '需要确认的操作会当场弹窗 —— 档位判定与完整模式用的是同一套规则（确认弹窗两边都会弹）。'),
        style: const TextStyle(fontSize: 11, height: 1.6, color: Colors.grey)),
    ]));

  // ── 事件流渲染（把 append-only 的事件日志折叠成可读轨迹） ──
  List<Widget> _renderStream(ColorScheme cs) {
    final out = <Widget>[];
    final buf = StringBuffer();
    final open = {for (final e in _tl.openConfirms) e.id};

    Widget bubble(String text, {bool dim = false}) => Align(
      alignment: Alignment.centerLeft,
      child: Container(margin: const EdgeInsets.only(bottom: 8, right: 24),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(fontSize: 13, height: 1.55,
          color: dim ? Colors.grey : null))));

    void flush() {
      if (buf.isEmpty) return;
      out.add(bubble(buf.toString(), dim: true));
      buf.clear();
    }

    for (final e in _events) {
      if (e.type == AgentEventType.assistantDelta) { buf.write(e.deltaText); continue; }
      flush();
      final w = _single(e, open.contains(e.id));
      if (w != null) out.add(w);
    }
    flush();
    // 轻量循环正在流式输出的正文（本地草稿，不混进 _events —— 那是服务端权威记录）
    if (_liteStream.isNotEmpty) out.add(bubble(_liteStream));
    if (_waiting || _liteRunning) {
      out.add(Padding(padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          const SizedBox(width: 13, height: 13,
            child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(child: Text(
            _liteRunning
                ? (_liteStream.isEmpty ? '本机模型正在思考…' : '本机模型正在回答…')
                : '等后端 DSH 产出事件…（若一直不动，多半是后端没装 DSH）',
            style: const TextStyle(fontSize: 11, color: Colors.grey))),
        ])));
    }
    return out;
  }

  Widget? _single(AgentEvent e, bool confirmOpen) {
    if (e.type == AgentEventType.userMessage) {
      return Align(alignment: Alignment.centerRight,
        child: Container(margin: const EdgeInsets.only(bottom: 8, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12)),
          child: Text('${e.payload['text'] ?? ''}',
            style: const TextStyle(fontSize: 13, height: 1.5))));
    }
    if (e.type == AgentEventType.assistantMessage) {
      final t = '${e.payload['text'] ?? ''}';
      return t.isEmpty ? null : Padding(padding: const EdgeInsets.only(bottom: 8), child: _mdText(t));
    }
    if (e.type == AgentEventType.toolCall) return _toolCard(AgentToolCall.from(e.payload));
    if (e.type == AgentEventType.toolResult) return _resultCard(e);
    if (e.type == AgentEventType.confirmRequest) return _confirmCard(e, confirmOpen);
    if (e.type == AgentEventType.artifact) return _artifactCard(e);
    if (e.type == AgentEventType.error) return _errorCard(e);
    if (e.type == AgentEventType.done) return _doneLine(e);
    return null; // audit 事件有专门一栏，不混进对话流
  }

  Widget _mdText(String t) => Align(alignment: Alignment.centerLeft,
    child: Container(margin: const EdgeInsets.only(bottom: 8, right: 24),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12)),
      child: SelectableText(t, style: const TextStyle(fontSize: 13, height: 1.6))));

  Widget _toolCard(AgentToolCall t) {
    final col = t.risk == AgentRisk.danger
        ? Colors.redAccent
        : (t.risk == AgentRisk.write ? Colors.orange : Colors.blueGrey);
    return Card(margin: const EdgeInsets.only(bottom: 8, right: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      child: Padding(padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.build_outlined, size: 14, color: col),
            const SizedBox(width: 6),
            Expanded(child: Text(t.tool.isEmpty ? '（未命名工具）' : t.tool,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: col.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6)),
              child: Text(AgentPolicy.riskLabel(t.risk),
                style: TextStyle(fontSize: 9.5, color: col))),
          ]),
          if (t.arguments.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6),
              child: Text(t.prettyArgs,
                style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace', height: 1.45))),
        ])));
  }

  Widget _resultCard(AgentEvent e) {
    final txt = '${e.payload['text'] ?? e.payload['output'] ?? e.payload['summary'] ?? ''}';
    final ok = e.payload['ok'] != false && '${e.payload['error'] ?? ''}'.isEmpty;
    return Container(margin: const EdgeInsets.only(left: 12, bottom: 8, right: 24),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ok ? Icons.subdirectory_arrow_right : Icons.error_outline,
          size: 13, color: ok ? Colors.grey : Colors.redAccent),
        const SizedBox(width: 6),
        Expanded(child: Text(txt.isEmpty ? '（工具无输出）' : txt,
          maxLines: 8, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, height: 1.45))),
      ]));
  }

  Widget _confirmCard(AgentEvent e, bool open) {
    final tool = '${e.payload['tool'] ?? ''}';
    final reason = '${e.payload['reason'] ?? ''}';
    return Card(margin: const EdgeInsets.only(bottom: 8, right: 12),
      color: Colors.orange.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.orange.withValues(alpha: 0.5))),
      child: Padding(padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.gpp_maybe_outlined, size: 15, color: Colors.orange),
            const SizedBox(width: 6),
            const Text('需要你确认', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          Text(reason.isEmpty ? tool : '$tool · $reason',
            style: const TextStyle(fontSize: 11.5, height: 1.5)),
          if (open)
            Padding(padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                FilledButton(onPressed: () => _answerConfirm(e.id, true),
                  child: const Text('允许一次', style: TextStyle(fontSize: 12))),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => _answerConfirm(e.id, false),
                  child: const Text('拒绝', style: TextStyle(fontSize: 12))),
              ]))
          else
            const Padding(padding: EdgeInsets.only(top: 6),
              child: Text('已答复', style: TextStyle(fontSize: 11, color: Colors.grey))),
        ])));
  }

  // ── artifact：补丁要看得懂「哪几行被改了」，不能只丢一个文件名 ──
  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 10.5, height: 1.42);
  static const _diffFoldAt = 60;

  static String _size(int b) {
    if (b <= 0) return '大小未知';
    if (b < 1024) return '$b 字节';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 按 id 回取被截断的全文（事件流里只带了预览）
  Future<void> _fetchArtifact(String key, AgentArtifact a) async {
    setState(() => _artBusy.add(key));
    final r = await AgentDshClient.artifact(a.storeId);
    if (!mounted) return;
    setState(() {
      _artBusy.remove(key);
      if (r.ok) {
        _artFull[key] = r.text;
      } else {
        _note = r.error;
        _noteBad = true;
      }
    });
  }

  Widget _artifactCard(AgentEvent e) {
    final a = AgentArtifact.from(e.payload);
    final key = e.id;
    final full = _artFull[key]; // 非 null 表示已取回全文
    final body = full ?? a.text;
    final d = body.trim().isEmpty ? null : AgentDiff.parse(body, assumeDiff: a.isDiff);
    final open = _artDiffOpen.contains(key);
    final busy = _artBusy.contains(key);

    return Card(
        margin: const EdgeInsets.only(bottom: 8, right: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(a.isDiff ? Icons.difference_outlined : Icons.folder_zip_outlined, size: 15),
                const SizedBox(width: 8),
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.summary.isEmpty ? a.kind : a.summary,
                      style: const TextStyle(fontSize: 12)),
                  if (d != null && d.hunks > 0)
                    Text('${d.hunks} 处改动 · +${d.added} −${d.removed}',
                        style: const TextStyle(fontSize: 10, color: Colors.grey))
                  else if (a.uri.isNotEmpty && a.text.isEmpty)
                    Text(a.uri,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ])),
                if (a.requiresConfirm)
                  const Text('待确认', style: TextStyle(fontSize: 9.5, color: Colors.orange)),
              ]),
              if (d != null && d.lines.isNotEmpty) ...[
                const SizedBox(height: 6),
                _diffBody(d, key, open),
                if (full != null)
                  const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text('已载入全文', style: TextStyle(fontSize: 10, color: Colors.grey))),
              ],
              if (a.textTruncated && a.canFetchFull && full == null)
                Row(children: [
                  TextButton.icon(
                    onPressed: busy ? null : () => _fetchArtifact(key, a),
                    icon: busy
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download_outlined, size: 14),
                    label: Text(
                        busy ? '取回中…' : '查看全文（预览被截断，全文 ${_size(a.bytes)}）',
                        style: const TextStyle(fontSize: 11.5)),
                  ),
                ])
              else if (a.textTruncated && !a.canFetchFull)
                const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('预览已截断，但服务端未给出全文地址',
                        style: TextStyle(fontSize: 10.5, color: Colors.orange))),
            ])));
  }

  Widget _diffBody(AgentDiff d, String key, bool open) {
    final cut = (!open && d.lines.length > _diffFoldAt) ? _diffFoldAt : d.lines.length;
    final rows = d.lines.take(cut).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(children: [for (final l in rows) _diffRow(l)]),
      ),
      if (cut < d.lines.length)
        TextButton(
          onPressed: () => setState(() => _artDiffOpen.add(key)),
          child: Text('展开全部（共 ${d.lines.length} 行）',
              style: const TextStyle(fontSize: 11.5)),
        )
      else if (d.lines.length > _diffFoldAt)
        TextButton(
          onPressed: () => setState(() => _artDiffOpen.remove(key)),
          child: const Text('收起', style: TextStyle(fontSize: 11.5)),
        ),
    ]);
  }

  Widget _diffRow(AgentDiffLine l) {
    Color bg = Colors.transparent;
    Color markColor = Colors.grey;
    String mark = ' ';
    var strong = false;
    if (l.kind == AgentDiffKind.add) {
      bg = Colors.green.withValues(alpha: 0.13);
      mark = '+';
      markColor = Colors.green;
    } else if (l.kind == AgentDiffKind.del) {
      bg = Colors.red.withValues(alpha: 0.13);
      mark = '−';
      markColor = Colors.red;
    } else if (l.kind == AgentDiffKind.hunk) {
      bg = Colors.blueGrey.withValues(alpha: 0.16);
      strong = true;
    } else if (l.kind == AgentDiffKind.file) {
      bg = Colors.grey.withValues(alpha: 0.14);
      strong = true;
    } else if (l.kind == AgentDiffKind.meta) {
      bg = Colors.grey.withValues(alpha: 0.08);
    }
    final no = l.kind == AgentDiffKind.add ? l.bLine : l.aLine;
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 26,
            child: Text(no == null ? '' : '$no',
                textAlign: TextAlign.right,
                style: _mono.copyWith(color: Colors.grey, fontSize: 9.5))),
        const SizedBox(width: 6),
        SizedBox(
            width: 9,
            child: Text(mark,
                style: _mono.copyWith(color: markColor, fontWeight: FontWeight.w700))),
        Expanded(
            child: SelectableText(l.text.isEmpty ? ' ' : l.text,
                style: _mono.copyWith(
                    fontWeight: strong ? FontWeight.w700 : FontWeight.normal))),
      ]),
    );
  }

  Widget _errorCard(AgentEvent e) {
    final code = '${e.payload['code'] ?? ''}';
    final msg = '${e.payload['message'] ?? ''}';
    return Container(margin: const EdgeInsets.only(bottom: 8, right: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
        const SizedBox(width: 6),
        Expanded(child: Text(code.isEmpty ? msg : '$code：$msg',
          style: const TextStyle(fontSize: 11.5, height: 1.45))),
      ]));
  }

  Widget _doneLine(AgentEvent e) {
    final s = AgentTurnStat.from(e.payload);
    final parts = <String>[];
    if (s.tokens > 0) parts.add('${s.tokens} tokens');
    if (s.cost > 0) parts.add('\$${s.cost.toStringAsFixed(4)}');
    if (s.taskStatus.isNotEmpty) parts.add(s.taskStatus);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        const Expanded(child: Divider(height: 1)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(parts.isEmpty ? '本轮结束' : '本轮结束 · ${parts.join(" · ")}',
            style: const TextStyle(fontSize: 10, color: Colors.grey))),
        const Expanded(child: Divider(height: 1)),
      ]));
  }

  Widget _toolsCard(ColorScheme cs) {
    var a = 0, c2 = 0, d = 0;
    for (final t in _tools) {
      final dd = '${t['decision']}';
      if (dd == AgentDecision.allow) { a++; } else if (dd == AgentDecision.confirm) { c2++; } else { d++; }
    }
    return Card(margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('工具与权限', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(_online ? '服务端判定' : '本地镜像判定',
              style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
          ]),
          const SizedBox(height: 3),
          Text('可执行 $a · 需确认 $c2 · 禁用 $d',
            style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
          const SizedBox(height: 6),
          for (final t in _tools)
            Padding(padding: const EdgeInsets.symmetric(vertical: 2.5),
              child: Row(children: [
                Icon(_decIcon('${t['decision']}'), size: 13, color: _decColor('${t['decision']}')),
                const SizedBox(width: 6),
                Expanded(child: Text('${t['name']}', style: const TextStyle(fontSize: 11.5))),
                Text('${t['riskLabel']}', style: const TextStyle(fontSize: 9.5, color: Colors.grey)),
              ])),
        ])));
  }

  Widget _auditCard(ColorScheme cs) => Card(margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    child: Padding(padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('最近审计', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(onPressed: _reloadAudit, child: const Text('刷新', style: TextStyle(fontSize: 12))),
        ]),
        const SizedBox(height: 2),
        if (_audit.isEmpty)
          const Text('暂无记录。工具的每次放行 / 拒绝 / 待确认都会在这里留痕。',
            style: TextStyle(fontSize: 11, color: Colors.grey))
        else
          for (final r in _audit.take(20))
            Padding(padding: const EdgeInsets.symmetric(vertical: 2.5),
              child: Row(children: [
                Icon(r.isDenied ? Icons.block : (r.isConfirm ? Icons.help_outline : Icons.check_circle_outline),
                  size: 12, color: r.isDenied ? Colors.redAccent : (r.isConfirm ? Colors.orange : Colors.green)),
                const SizedBox(width: 6),
                Text(_fmtTs(r.ts), style: const TextStyle(fontSize: 9.5, color: Colors.grey)),
                const SizedBox(width: 6),
                Expanded(child: Text(r.line, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11))),
              ])),
      ])));

  Widget _composer(ColorScheme cs) {
    final blocked = _tl.blockedByConfirm;
    final canSend = _online && !_busy && !blocked && !_liteRunning;
    return SafeArea(top: false, child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_note.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(_noteBad ? Icons.error_outline : Icons.info_outline,
                size: 14, color: _noteBad ? Colors.redAccent : Colors.grey),
              const SizedBox(width: 6),
              Expanded(child: Text(_note, style: TextStyle(fontSize: 11, height: 1.45,
                color: _noteBad ? Colors.redAccent : Colors.grey))),
            ])),
        Row(children: [
          Expanded(child: TextField(controller: _input,
            enabled: _online && !_busy && !_liteRunning, minLines: 1, maxLines: 4,
            style: const TextStyle(fontSize: 13),
            onSubmitted: (_) { if (canSend) _send(); },
            decoration: InputDecoration(
              hintText: !_online
                  ? '先填上家庭后端地址（点上面的「去填后端地址」）'
                  : (_liteRunning
                      ? '本轮还在执行…'
                      : (blocked ? '有待确认的操作，先处理上面的卡片' : '下达一条任务，例：把书架里这本书的简介整理成表格')),
              isDense: true, border: const OutlineInputBorder()))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: canSend ? _send : null,
            icon: const Icon(Icons.send, size: 18)),
        ]),
        Row(children: [
          TextButton.icon(onPressed: _online ? _pull : null,
            icon: const Icon(Icons.download, size: 15),
            label: const Text('拉取新事件', style: TextStyle(fontSize: 11))),
          const Spacer(),
          if (_events.isNotEmpty)
            Text('${_events.length} 条事件 · seq $_lastSeq',
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      ])));
  }

  static IconData _decIcon(String d) => d == AgentDecision.allow
      ? Icons.check_circle_outline
      : (d == AgentDecision.confirm ? Icons.help_outline : Icons.block);
  static Color _decColor(String d) => d == AgentDecision.allow
      ? Colors.green
      : (d == AgentDecision.confirm ? Colors.orange : Colors.redAccent);

  static String _fmtTs(int ms) {
    if (ms <= 0) return '--';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
