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

import 'package:flutter/material.dart';

import 'agent_dsh_client.dart';
import 'agent_models.dart';
import 'agent_policy.dart';
import 'ai_agent.dart';

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

  bool get _online => AgentRuntime.backendConnected;
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
    if (_online) {
      final h = await AgentRuntime.refresh();
      if (h != null) _h = h;
      await _reloadAudit();
    }
    await _reloadTools();
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
      _say('未连接家庭后端 —— DSH 是后端侧的运行时，请先在后端连接页连上再启动', bad: true);
      return;
    }
    setState(() => _busy = true);
    final ok = start ? await AgentDshClient.startDsh() : await AgentDshClient.stopDsh();
    final h = await AgentRuntime.refresh();
    if (h != null) _h = h;
    if (mounted) setState(() => _busy = false);
    _say(ok
        ? (start ? '已请求启动 DSH，正在重新检测…' : '已请求停止 DSH')
        : '请求失败：后端未接受该操作（现象：接口无响应；原因：后端版本或权限不符；怎么办：看后端日志）',
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
      _say('未连接家庭后端 —— 轻量模式在这里不发任务，请到「AI 对话」页正常聊天（那边不受影响）', bad: true);
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
      _say('完整模式：已落账，正在订阅事件流…');
      _subscribe(sid);
    } else {
      _say(r.hint.isEmpty
          ? '已落账（轻量模式）：本轮不调用工具，过程事件由客户端按轻量循环回填'
          : r.hint);
    }
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
          Row(children: [
            OutlinedButton.icon(onPressed: _busy ? null : _boot,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新检测', style: TextStyle(fontSize: 12))),
            const SizedBox(width: 8),
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
      Text(_online ? '任务栏会按顺序渲染四类事件' : '轻量模式下这一栏不会产出事件',
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text(_online
          ? '① 助手增量（流式正文）  ② 工具调用（工具名 + 风险等级 + 参数）\n'
            '③ 确认请求（高危操作会停在这里等你点「允许一次 / 拒绝」）  ④ 工具结果与产物'
          : '现象：事件流为空。原因：本机没检测到 DSH，Agent 循环不在后端跑。'
            '怎么办：① 连上家庭后端后点「启动 DSH」；② 或直接在「AI 对话」页聊天 —— '
            '那条路走轻量循环，不依赖 DSH。',
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
    if (_waiting) {
      out.add(const Padding(padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('等待 DSH 产出事件…', style: TextStyle(fontSize: 11, color: Colors.grey)),
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
    if (e.type == AgentEventType.artifact) return _artifactCard(AgentArtifact.from(e.payload));
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

  Widget _artifactCard(AgentArtifact a) => Card(margin: const EdgeInsets.only(bottom: 8, right: 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    child: Padding(padding: const EdgeInsets.all(10),
      child: Row(children: [
        const Icon(Icons.folder_zip_outlined, size: 15),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a.summary.isEmpty ? a.kind : a.summary, style: const TextStyle(fontSize: 12)),
          if (a.uri.isNotEmpty)
            Text(a.uri, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ])),
        if (a.requiresConfirm)
          const Text('待确认', style: TextStyle(fontSize: 9.5, color: Colors.orange)),
      ])));

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
    final canSend = _online && !_busy && !blocked;
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
            enabled: _online && !_busy, minLines: 1, maxLines: 4,
            style: const TextStyle(fontSize: 13),
            onSubmitted: (_) { if (canSend) _send(); },
            decoration: InputDecoration(
              hintText: !_online
                  ? '未连接后端：轻量模式不发任务'
                  : (blocked ? '有待确认的操作，先处理上面的卡片' : '下达一条任务，例：把书架里这本书的简介整理成表格'),
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
