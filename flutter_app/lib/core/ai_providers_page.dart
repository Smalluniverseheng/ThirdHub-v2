// AI 厂商与 Key 管理页(抽屉头部设置入口)
import 'package:flutter/material.dart';
import 'ai.dart';
import 'vendor_icons.dart';

class AiProvidersPage extends StatefulWidget { const AiProvidersPage({super.key}); @override State<AiProvidersPage> createState() => _AiProv(); }
class _AiProv extends State<AiProvidersPage> {
  String filter = ''; bool onlyKeyed = false; final Set<String> keyed = {};
  @override void initState() { super.initState(); _load(); }
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
    return Scaffold(appBar: AppBar(title: const Text('厂商与 Key'), actions: [
        IconButton(icon: const Icon(Icons.refresh), tooltip: '从网站同步',
          onPressed: () async { final ok = await AiRegistry.refresh(); await _load();
            if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(ok ? '已同步 ${AiRegistry.providers.length} 家厂商' : '同步失败, 使用本地清单'))); }),
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
          return ExpansionTile(dense: true, leading: VendorIcon(p.id, size: 28),
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
                      if (c.mounted) Navigator.pop(c); }),
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
    if (ok == true) { await AiRegistry.setKey(p.id, ctrl.text.trim()); await _load(); }
  }
}
