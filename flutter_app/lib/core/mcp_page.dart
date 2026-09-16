// MCP 服务管理页(与网站 mcp-client.js 一致: SSE/Streamable HTTP 传输, 连上后自动发现工具)
import 'dart:async';
import 'package:flutter/material.dart';
import 'ai.dart';

class McpPage extends StatefulWidget { const McpPage({super.key}); @override State<McpPage> createState() => _McpPageState(); }
class _McpPageState extends State<McpPage> {
  StreamSubscription? _sub;
  @override void initState() { super.initState(); _sub = Mcp.onChange.listen((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { _sub?.cancel(); super.dispose(); }

  Future<void> _add() async {
    final nameC = TextEditingController(); final urlC = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('添加 MCP Server'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('支持 SSE / Streamable HTTP 传输的远程服务; 公开服务可在 mcp.so / mcp.tools 查找, 复制地址粘贴即可',
          style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 8),
        TextField(controller: nameC, decoration: const InputDecoration(labelText: '名称', hintText: '我的 MCP 服务', isDense: true)),
        TextField(controller: urlC, decoration: const InputDecoration(labelText: '服务地址', hintText: 'https://example.com/mcp', isDense: true)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('添加并连接'))]));
    if (ok != true) return;
    final s = await Mcp.add(nameC.text.trim().isEmpty ? '我的 MCP 服务' : nameC.text.trim(), urlC.text.trim());
    final connected = await Mcp.connect(s.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
      connected ? '已连接 · 发现 ${s.tools.length} 个工具' : '连接失败: ${s.error}')));
  }

  Color _sc(String s) => s == 'connected' ? Colors.blue : s == 'error' ? Colors.redAccent : Colors.grey;
  String _st(String s) => s == 'connected' ? '已连接' : s == 'connecting' ? '连接中' : s == 'error' ? '连接失败' : '未连接';

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('MCP 服务'), actions: [IconButton(icon: const Icon(Icons.add), onPressed: _add)]),
    body: Mcp.servers.isEmpty
      ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hub_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('还没有 MCP 服务', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add, size: 18), label: const Text('添加 MCP Server')),
        ])))
      : ListView(children: [
          const Padding(padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('接入 MCP 工具服务后, AI 对话可调用外部工具(仅支持 SSE / HTTP 传输)', style: TextStyle(fontSize: 11, color: Colors.grey))),
          for (final s in Mcp.servers)
            Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: Padding(padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ])),
                  Column(children: [Icon(Icons.circle, size: 10, color: _sc(s.status)),
                    Text(_st(s.status), style: TextStyle(fontSize: 10, color: _sc(s.status)))]),
                  Switch(value: s.enabled, onChanged: (v) => Mcp.toggle(s.id, v)),
                ]),
                if (s.status == 'error' && s.error.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text(s.error, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: Colors.redAccent))),
                if (s.tools.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final t in s.tools) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: Text('${t['name']}', style: const TextStyle(fontSize: 10, color: Colors.blueAccent))),
                ])),
                Row(children: [
                  Text('${s.tools.length} 个工具', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  const Spacer(),
                  TextButton(onPressed: () => Mcp.connect(s.id), child: const Text('重新连接', style: TextStyle(fontSize: 12))),
                  TextButton(onPressed: () async {
                    final ok = await showDialog<bool>(context: c, builder: (c3) => AlertDialog(title: const Text('删除该 MCP 服务?'),
                      actions: [TextButton(onPressed: () => Navigator.pop(c3, false), child: const Text('取消')),
                        FilledButton(onPressed: () => Navigator.pop(c3, true), child: const Text('删除'))]));
                    if (ok == true) Mcp.remove(s.id);
                  }, child: const Text('删除', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
                ]),
              ]))),
        ]),
    floatingActionButton: Mcp.servers.isEmpty ? null : FloatingActionButton.small(onPressed: _add, child: const Icon(Icons.add)),
  );
}
