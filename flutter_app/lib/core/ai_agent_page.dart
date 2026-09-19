// AI 智能体 · 全局指令 · 长期记忆 · 会话钉注 管理页(TH-Agent v1)
// 对应"大厂 Agent"里的 Custom Instructions / Agent 授权 / Memory / Pinned Context 四件事
import 'package:flutter/material.dart';
import 'ai_agent.dart';

class AiAgentPage extends StatefulWidget {
  /// 传入会话 id 时多出「钉注」一栏(钉注是会话级的)
  final String sessionId;
  const AiAgentPage({super.key, this.sessionId = ''});
  @override State<AiAgentPage> createState() => _AiAgentPageState();
}

class _AiAgentPageState extends State<AiAgentPage> with SingleTickerProviderStateMixin {
  late final bool _hasPins = widget.sessionId.isNotEmpty;
  late final TabController _tab = TabController(length: _hasPins ? 4 : 3, vsync: this);

  @override void initState() {
    super.initState();
    Future.wait([AiAgents.load(), AiInstruct.load(), AiMemory.load()])
        .then((_) { if (mounted) setState(() {}); });
  }

  @override void dispose() { _tab.dispose(); super.dispose(); }

  void _refresh() { if (mounted) setState(() {}); }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('智能体 · 指令 · 记忆'), bottom: TabBar(controller: _tab, tabs: [
      const Tab(text: '指令'), const Tab(text: '智能体'), const Tab(text: '记忆'),
      if (_hasPins) const Tab(text: '钉注'),
    ])),
    body: TabBarView(controller: _tab, children: [
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
