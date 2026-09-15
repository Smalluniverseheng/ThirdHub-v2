// AI 模块页面: 厂商列表(折叠展示模型) + Key 管理 + 流式对话
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ai.dart';

class AiSection extends StatefulWidget { const AiSection({super.key}); @override State<AiSection> createState() => _AiSec(); }
class _AiSec extends State<AiSection> {
  String filter = ''; bool onlyKeyed = false; final Set<String> keyed = {};
  @override void initState() { super.initState(); _load(); AiRegistry.onChange.listen((_) { if (mounted) setState(() {}); }); }
  Future<void> _load() async {
    for (final p in AiRegistry.providers) { if ((await AiRegistry.keyOf(p.id)).isNotEmpty) keyed.add(p.id); }
    if (mounted) setState(() {});
  }
  @override Widget build(BuildContext c) {
    var list = AiRegistry.providers;
    if (onlyKeyed) list = list.where((p) => keyed.contains(p.id)).toList();
    if (filter.isNotEmpty) {
      final f = filter.toLowerCase();
      list = list.where((p) => p.name.toLowerCase().contains(f) || p.id.contains(f) ||
        p.models.any((m) => m.toLowerCase().contains(f))).toList();
    }
    return Scaffold(appBar: AppBar(title: const Text('AI'), actions: [
        IconButton(icon: const Icon(Icons.chat_bubble_outline), tooltip: '开始对话',
          onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const AiChatPage()))),
        IconButton(icon: const Icon(Icons.refresh), tooltip: '刷新厂商清单',
          onPressed: () async { final ok = await AiRegistry.refresh(); await _load();
            if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(ok ? '已从网站同步 ${AiRegistry.providers.length} 家厂商' : '同步失败, 使用本地清单'))); }),
      ]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: TextField(
          decoration: const InputDecoration(hintText: '搜索厂商或模型…', prefixIcon: Icon(Icons.search), isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)))),
          onChanged: (v) => setState(() => filter = v))),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          Text('${AiRegistry.providers.length} 家厂商 · ${AiRegistry.providers.fold<int>(0, (a, b) => a + b.models.length)} 个模型',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const Spacer(),
          FilterChip(label: const Text('只看已配Key', style: TextStyle(fontSize: 11)), selected: onlyKeyed,
            onSelected: (v) => setState(() => onlyKeyed = v), visualDensity: VisualDensity.compact),
        ])),
        Expanded(child: ListView.builder(itemCount: list.length, itemBuilder: (_, i) {
          final p = list[i];
          return ExpansionTile(dense: true, leading: CircleAvatar(radius: 14,
              child: Text(p.name.isEmpty ? '?' : p.name[0], style: const TextStyle(fontSize: 11))),
            title: Text(p.name, style: const TextStyle(fontSize: 14)),
            subtitle: Text('${p.models.length} 个模型${keyed.contains(p.id) ? ' · 已配Key' : ''}',
              style: TextStyle(fontSize: 10, color: keyed.contains(p.id) ? Colors.green : Colors.grey)),
            children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
                Expanded(child: Text(p.base, style: const TextStyle(fontSize: 10, color: Colors.grey), overflow: TextOverflow.ellipsis)),
                TextButton(onPressed: () => _keyDialog(p), child: Text(keyed.contains(p.id) ? '改Key' : '配Key', style: const TextStyle(fontSize: 12))),
              ])),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final m in p.models.take(60))
                  ActionChip(label: Text(m, style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact,
                    onPressed: () async { await AiRegistry.setLastModel(p.id, m);
                      if (c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => const AiChatPage())); }),
              ])),
            ]);
        })),
      ]));
  }
  Future<void> _keyDialog(AiProvider p) async {
    final ctrl = TextEditingController(text: await AiRegistry.keyOf(p.id));
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: Text('${p.name} API Key', style: const TextStyle(fontSize: 16)),
      content: TextField(controller: ctrl, obscureText: true, decoration: const InputDecoration(hintText: 'sk-...', isDense: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))]));
    if (ok == true) {
      await AiRegistry.setKey(p.id, ctrl.text.trim());
      await _load();
    }
  }
}

class AiChatPage extends StatefulWidget { const AiChatPage({super.key}); @override State<AiChatPage> createState() => _AiChat(); }
class _AiChat extends State<AiChatPage> {
  final List<Map<String, String>> msgs = [];
  final input = TextEditingController(); final scroll = ScrollController();
  String providerId = '', model = ''; bool sending = false; String streaming = '';
  @override void initState() { super.initState(); _init(); }
  Future<void> _init() async { final (p, m) = await AiRegistry.lastModel();
    setState(() { providerId = p; model = m; }); }
  Future<void> _pickModel() async {
    final chosen = await showModalBottomSheet<(String, String)>(context: context, isScrollControlled: true,
      builder: (c2) => DraggableScrollableSheet(initialChildSize: 0.7, expand: false, builder: (_, sc) =>
        ListView(controller: sc, children: [ for (final p in AiRegistry.providers)
          ExpansionTile(dense: true, title: Text(p.name, style: const TextStyle(fontSize: 13)),
            subtitle: Text('${p.models.length} 个模型', style: const TextStyle(fontSize: 10)),
            children: [ for (final m in p.models)
              ListTile(dense: true, title: Text(m, style: const TextStyle(fontSize: 12)),
                trailing: p.id == providerId && m == model ? const Icon(Icons.check, size: 16, color: Colors.blueAccent) : null,
                onTap: () => Navigator.pop(c2, (p.id, m))) ]) ])));
    if (chosen != null) { await AiRegistry.setLastModel(chosen.$1, chosen.$2); setState(() { providerId = chosen.$1; model = chosen.$2; }); }
  }
  Future<void> _send() async {
    final text = input.text.trim(); if (text.isEmpty || sending) return;
    final prov = AiRegistry.byId(providerId);
    if (prov == null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择模型'))); return; }
    if ((await AiRegistry.keyOf(providerId)).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请先在 AI 页配置 ${prov.name} 的 API Key'))); return; }
    input.clear();
    setState(() { msgs.add({'role': 'user', 'content': text}); sending = true; streaming = ''; });
    try {
      final full = await AiChat.chat(provider: prov, model: model, messages: msgs,
        onDelta: (d) { setState(() => streaming += d);
          scroll.jumpTo(scroll.position.maxScrollExtent + 80); });
      setState(() { msgs.add({'role': 'assistant', 'content': full}); streaming = ''; });
    } catch (e) {
      setState(() { msgs.add({'role': 'assistant', 'content': '出错了: $e'}); streaming = ''; });
    }
    setState(() => sending = false);
    scroll.jumpTo(scroll.position.maxScrollExtent + 200);
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(
      title: GestureDetector(onTap: _pickModel, child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(model.isEmpty ? '选择模型' : model, style: const TextStyle(fontSize: 15), overflow: TextOverflow.ellipsis)),
        const Icon(Icons.arrow_drop_down, size: 20)])),
      actions: [IconButton(icon: const Icon(Icons.delete_outline), tooltip: '清空对话',
        onPressed: () => setState(() => msgs.clear()))]),
    body: Column(children: [
      Expanded(child: msgs.isEmpty && streaming.isEmpty
        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.smart_toy_outlined, size: 56, color: Colors.grey),
            const SizedBox(height: 10),
            Text('${AiRegistry.providers.length} 家厂商 · 300+ 模型\n点顶部切换模型, 先配好 API Key',
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 12, height: 1.8))]))
        : ListView.builder(controller: scroll, padding: const EdgeInsets.all(14),
            itemCount: msgs.length + (streaming.isNotEmpty ? 1 : 0), itemBuilder: (_, i) {
              final m = i < msgs.length ? msgs[i] : {'role': 'assistant', 'content': streaming};
              final me = m['role'] == 'user';
              return Align(alignment: me ? Alignment.centerRight : Alignment.centerLeft,
                child: GestureDetector(onLongPress: () { Clipboard.setData(ClipboardData(text: m['content'] ?? ''));
                    ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已复制'))); },
                  child: Container(margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(c).size.width * 0.8),
                    decoration: BoxDecoration(
                      color: me ? Theme.of(c).colorScheme.primary : Theme.of(c).cardTheme.color,
                      borderRadius: BorderRadius.circular(14)),
                    child: Text(m['content'] ?? '', style: TextStyle(fontSize: 14, height: 1.6,
                      color: me ? Colors.white : null)))));
            })),
      SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 10), child: Row(children: [
        Expanded(child: TextField(controller: input, minLines: 1, maxLines: 4,
          decoration: const InputDecoration(hintText: '输入消息…', isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(22))),
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
          onSubmitted: (_) => _send())),
        const SizedBox(width: 8),
        sending ? const SizedBox(width: 40, height: 40, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
          : IconButton.filled(onPressed: _send, icon: const Icon(Icons.send, size: 18)),
      ]))),
    ]));
}
