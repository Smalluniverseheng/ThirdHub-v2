// 小模块做实第十批: 共享清单(本地多清单, 云端同步待后端资源库接口)
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SharedListPage extends StatefulWidget { const SharedListPage({super.key}); @override State<SharedListPage> createState() => _Sl(); }
class _Sl extends State<SharedListPage> {
  static const _key = 'shared_lists';
  Map<String, List<Map<String, dynamic>>> lists = {}; // 清单名 -> [{t, done, who}]
  String current = '';

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw != null) {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      lists = m.map((k, v) => MapEntry(k, [for (final it in v) Map<String, dynamic>.from(it)]));
    }
    if (lists.isEmpty) lists['购物清单'] = [];
    current = lists.keys.first;
    setState(() {});
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(lists));
  }

  void _addItem() {
    final tc = TextEditingController();
    final wc = TextEditingController();
    showDialog(context: context, builder: (d) => AlertDialog(
      title: const Text('添加事项', style: TextStyle(fontSize: 15)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: tc, autofocus: true, decoration: const InputDecoration(hintText: '要买/要做的事', isDense: true)),
        const SizedBox(height: 8),
        TextField(controller: wc, decoration: const InputDecoration(hintText: '谁添加的(可选)', isDense: true)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        FilledButton(onPressed: () {
          if (tc.text.trim().isNotEmpty) {
            setState(() => lists[current]!.add({'t': tc.text.trim(), 'done': false, 'who': wc.text.trim()}));
            _save();
          }
          Navigator.pop(d);
        }, child: const Text('添加')),
      ])).then((_) { tc.dispose(); wc.dispose(); });
  }

  void _addList() {
    final c = TextEditingController();
    showDialog(context: context, builder: (d) => AlertDialog(
      title: const Text('新建清单', style: TextStyle(fontSize: 15)),
      content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: '清单名, 如: 周末采购', isDense: true)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        FilledButton(onPressed: () {
          if (c.text.trim().isNotEmpty && !lists.containsKey(c.text.trim())) {
            setState(() { lists[c.text.trim()] = []; current = c.text.trim(); });
            _save();
          }
          Navigator.pop(d);
        }, child: const Text('创建')),
      ])).then((_) => c.dispose());
  }

  @override Widget build(BuildContext context) {
    final items = lists[current] ?? [];
    final todo = items.where((e) => e['done'] != true).toList();
    final done = items.where((e) => e['done'] == true).toList();
    return Column(children: [
      SizedBox(height: 46, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final name in lists.keys)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
              child: ChoiceChip(label: Text(name, style: const TextStyle(fontSize: 12)), selected: name == current,
                onSelected: (_) => setState(() => current = name))),
          IconButton(icon: const Icon(Icons.add, size: 18), onPressed: _addList, tooltip: '新建清单'),
        ])),
      Expanded(child: items.isEmpty
        ? const Center(child: Text('点右下角添加第一条\n云端家庭共享同步待资源库接口开放', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
        : ListView(children: [
            for (final it in todo)
              ListTile(dense: true,
                leading: const Icon(Icons.circle_outlined, size: 18),
                title: Text(it['t'], style: const TextStyle(fontSize: 13)),
                subtitle: (it['who'] as String).isNotEmpty ? Text(it['who'], style: const TextStyle(fontSize: 10, color: Colors.grey)) : null,
                onTap: () { setState(() => it['done'] = true); _save(); },
                onLongPress: () { setState(() => items.remove(it)); _save(); }),
            if (done.isNotEmpty) ...[
              const Padding(padding: EdgeInsets.fromLTRB(14, 8, 0, 2),
                child: Text('已完成', style: TextStyle(fontSize: 10, color: Colors.grey))),
              for (final it in done)
                ListTile(dense: true,
                  leading: const Icon(Icons.check_circle, size: 18, color: Colors.teal),
                  title: Text(it['t'], style: const TextStyle(fontSize: 13, color: Colors.grey, decoration: TextDecoration.lineThrough)),
                  onTap: () { setState(() => it['done'] = false); _save(); },
                  onLongPress: () { setState(() => items.remove(it)); _save(); }),
            ],
          ])),
      Padding(padding: const EdgeInsets.all(10), child: SizedBox(width: double.infinity,
        child: FilledButton.icon(icon: const Icon(Icons.add, size: 18), label: const Text('添加事项'), onPressed: _addItem))),
    ]);
  }
}
