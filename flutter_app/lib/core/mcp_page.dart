// MCP 服务管理页
//
// 两种来源，治理方式不同：
//   · 后端托管（推荐）—— 注册表存在服务端，工具由服务端侧的 Agent Runtime 调用。
//     凭据、连接、调用都不落到手机上，换设备即生效，也才有统一的审计与审批。
//   · 本机直连（兼容保留）—— Flutter 直接对 SSE / Streamable HTTP 服务说话。
//     只在没有后端时用。**不跑 stdio**：手机上起不了子进程，起了也没法隔离。
//
// 两边的工具最终都汇进同一张工具表，是否可调用由权限档位判定（见 agent_policy.dart）。
import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_dsh_client.dart';
import 'ai.dart';

class McpPage extends StatefulWidget { const McpPage({super.key}); @override State<McpPage> createState() => _McpPageState(); }
class _McpPageState extends State<McpPage> {
  StreamSubscription? _sub;

  // 后端托管侧
  List<Map<String, dynamic>> _remote = [];
  bool _loadingRemote = false;
  bool _loadedOnce = false;

  bool get _hasBackend => AgentDshClient.configured;

  @override void initState() {
    super.initState();
    _sub = Mcp.onChange.listen((_) { if (mounted) setState(() {}); });
    _refreshRemote();
  }

  @override void dispose() { _sub?.cancel(); super.dispose(); }

  Future<void> _refreshRemote() async {
    if (!_hasBackend) {
      if (mounted) setState(() { _remote = []; _loadedOnce = true; });
      return;
    }
    setState(() { _loadingRemote = true; });
    final list = await AgentDshClient.mcpList();
    if (!mounted) return;
    setState(() { _remote = list; _loadingRemote = false; _loadedOnce = true; });
  }

  // ── 添加：让用户选加到哪一侧 ──
  Future<void> _add() async {
    final where = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text('MCP 服务加到哪里？', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
        const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text('远程服务可在 mcp.so / mcp.tools 查找，复制地址粘贴即可。',
            style: TextStyle(fontSize: 11, color: Colors.grey))),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('后端托管（推荐）', style: TextStyle(fontSize: 14)),
          subtitle: Text(_hasBackend ? '注册在服务端，工具调用有统一审批与审计' : '当前未连接后端，加不了',
            style: const TextStyle(fontSize: 11)),
          enabled: _hasBackend,
          onTap: _hasBackend ? () => Navigator.pop(c, 'remote') : null),
        ListTile(
          leading: const Icon(Icons.phone_android_outlined),
          title: const Text('本机直连（兼容）', style: TextStyle(fontSize: 14)),
          subtitle: const Text('手机直接连服务；没有后端时仍可用，但不进审计', style: TextStyle(fontSize: 11)),
          onTap: () => Navigator.pop(c, 'local')),
        const SizedBox(height: 8),
      ])));

    if (where == 'remote') return _addRemote();
    if (where == 'local') return _addLocal();
  }

  Future<(String, String)?> _ask(String title, String hint) async {
    final nameC = TextEditingController(); final urlC = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('支持 SSE / Streamable HTTP 传输的远程服务',
          style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 8),
        TextField(controller: nameC, decoration: const InputDecoration(labelText: '名称', hintText: '我的 MCP 服务', isDense: true)),
        TextField(controller: urlC, decoration: InputDecoration(labelText: '服务地址', hintText: hint, isDense: true)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('添加并连接'))]));
    final n = nameC.text.trim(); final u = urlC.text.trim();
    nameC.dispose(); urlC.dispose();
    if (ok != true) return null;
    return (n.isEmpty ? '我的 MCP 服务' : n, u);
  }

  Future<void> _addRemote() async {
    final r = await _ask('添加 MCP 服务（后端托管）', 'https://example.com/mcp');
    if (r == null || !mounted) return;
    if (r.$2.isEmpty) { _toast('服务地址不能为空'); return; }
    final a = await AgentDshClient.mcpAdd(r.$1, r.$2);
    if (!mounted) return;
    if (!a.ok) { _toast('添加失败：${a.error}'); return; }
    final c = await AgentDshClient.mcpConnect(a.id);
    if (!mounted) return;
    await _refreshRemote();
    _toast(c.ok ? '已连接 · 发现 ${c.tools} 个工具' : '已登记，但连接失败：${c.error}');
  }

  Future<void> _addLocal() async {
    final r = await _ask('添加 MCP 服务（本机直连）', 'https://example.com/mcp');
    if (r == null || !mounted) return;
    final s = await Mcp.add(r.$1, r.$2);
    final connected = await Mcp.connect(s.id);
    if (!mounted) return;
    _toast(connected ? '已连接 · 发现 ${s.tools.length} 个工具' : '连接失败: ${s.error}');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Color _sc(String s) => s == 'connected' ? Colors.blue
      : (s == 'error' ? Colors.redAccent : (s == 'connecting' ? Colors.orange : Colors.grey));
  String _st(String s) => s == 'connected' ? '已连接'
      : (s == 'connecting' ? '连接中' : (s == 'error' ? '连接失败' : (s == 'disabled' ? '已停用' : '未连接')));

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('MCP 服务'), actions: [
      IconButton(icon: const Icon(Icons.refresh), tooltip: '刷新后端托管列表', onPressed: _refreshRemote),
      IconButton(icon: const Icon(Icons.add), onPressed: _add),
    ]),
    body: !_loadedOnce && _loadingRemote
      ? const Center(child: CircularProgressIndicator())
      : ListView(children: [
          _sectionTitle('后端托管', '注册在服务端 · 调用有审批与审计'),
          if (!_hasBackend) _backendMissingHint() else ..._remoteCards(),
          const Divider(height: 24),
          _sectionTitle('本机直连（兼容）', '手机直接连服务 · 没有后端时仍可用'),
          if (Mcp.servers.isEmpty)
            const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text('本机没有直连的 MCP 服务。', style: TextStyle(fontSize: 11, color: Colors.grey)))
          else
            for (final s in Mcp.servers) _localCard(c, s),
          const SizedBox(height: 80),
        ]),
    floatingActionButton: FloatingActionButton.small(onPressed: _add, child: const Icon(Icons.add)),
  );

  Widget _sectionTitle(String title, String sub) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        if (_loadingRemote) const Padding(padding: EdgeInsets.only(left: 8),
          child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))),
      ]),
      Text(sub, style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
    ]));

  /// 没有后端时不能说「还没有服务」—— 要说清为什么加不了、怎么办
  Widget _backendMissingHint() => Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    child: const Padding(padding: EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.info_outline, size: 15, color: Colors.orange), SizedBox(width: 6),
          Text('未连接家庭后端', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold))]),
        SizedBox(height: 5),
        Text('现象：后端托管列表为空。原因：MCP 注册表存在服务端，本机没连上就没得读。'
             '怎么办：先在「设备互联」里连接后端，再回来添加；或先用下面的「本机直连」。',
          style: TextStyle(fontSize: 11, height: 1.55, color: Colors.grey)),
      ])));

  List<Widget> _remoteCards() {
    if (_remote.isEmpty)
      return [const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text('还没有后端托管的 MCP 服务，点右上角 + 添加。',
          style: TextStyle(fontSize: 11, color: Colors.grey)))];
    return [for (final s in _remote) _remoteCard(s)];
  }

  Widget _remoteCard(Map<String, dynamic> s) {
    final id = '${s['id'] ?? ''}';
    final status = '${s['status'] ?? 'idle'}';
    final err = '${s['error'] ?? ''}';
    final enabled = s['enabled'] == true;
    final tools = (s['tools'] as List? ?? []);
    return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              Text('${s['url'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ])),
            Column(children: [
              Icon(Icons.circle, size: 10, color: _sc(status)),
              Text(_st(status), style: TextStyle(fontSize: 10, color: _sc(status))),
            ]),
            Switch(value: enabled, onChanged: (v) async {
              await AgentDshClient.mcpToggle(id, v);
              await _refreshRemote();
            }),
          ]),
          if (err.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(err, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Colors.redAccent))),
          if (tools.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                for (final t in tools)
                  Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10)),
                    child: Text('${t is Map ? t['name'] : t}',
                      style: const TextStyle(fontSize: 10, color: Colors.blueAccent))),
              ])),
          Row(children: [
            Text('${tools.length} 个工具', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const Spacer(),
            TextButton(onPressed: () async {
              final r = await AgentDshClient.mcpConnect(id);
              if (!mounted) return;
              await _refreshRemote();
              _toast(r.ok ? '已连接 · ${r.tools} 个工具' : '连接失败：${r.error}');
            }, child: const Text('重新连接', style: TextStyle(fontSize: 12))),
            TextButton(onPressed: () async {
              final ok = await showDialog<bool>(context: context, builder: (c3) => AlertDialog(
                title: const Text('从后端注册表删除该服务?'),
                actions: [TextButton(onPressed: () => Navigator.pop(c3, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(c3, true), child: const Text('删除'))]));
              if (ok == true) { await AgentDshClient.mcpRemove(id); await _refreshRemote(); }
            }, child: const Text('删除', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
          ]),
        ])));
  }

  Widget _localCard(BuildContext c, McpServer s) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    child: Padding(padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ])),
          Column(children: [Icon(Icons.circle, size: 10, color: _sc(s.status)),
            Text(_st(s.status), style: TextStyle(fontSize: 10, color: _sc(s.status)))]),
          Switch(value: s.enabled, onChanged: (v) => Mcp.toggle(s.id, v)),
        ]),
        if (s.status == 'error' && s.error.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(s.error, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.redAccent))),
        if (s.tools.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final t in s.tools)
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10)),
                  child: Text('${t['name']}', style: const TextStyle(fontSize: 10, color: Colors.blueAccent))),
            ])),
        Row(children: [
          Text('${s.tools.length} 个工具', style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const Spacer(),
          TextButton(onPressed: () => Mcp.connect(s.id), child: const Text('重新连接', style: TextStyle(fontSize: 12))),
          TextButton(onPressed: () async {
            final ok = await showDialog<bool>(context: c, builder: (c3) => AlertDialog(
              title: const Text('删除该 MCP 服务?'),
              actions: [TextButton(onPressed: () => Navigator.pop(c3, false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(c3, true), child: const Text('删除'))]));
            if (ok == true) Mcp.remove(s.id);
          }, child: const Text('删除', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
        ]),
      ])));
}
