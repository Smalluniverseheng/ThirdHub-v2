// 小模块做实第十批: 共享清单(本地多清单 + 云端 th_shared 同步)
//
// 注：此前文件头写「云端同步待后端资源库接口」、空态也这么写 —— 与实际不符：
// `Cloud.syncUp/syncDown('shared_list')` 早就在同步，`th_shared` 表也确实存在。
// 真正的问题不是「没接口」，而是同步失败被静默吞掉（见 cloud.dart 的 syncUp 注释）。
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud.dart';

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
    _pullCloud();
  }

  // 云端同步: 登录后, 同名清单云端覆盖本地(后写赢), 本地独有的推上去
  //
  // 这个提示此前**只赋值、从不渲染**（页面上没有它），等于同步成功与否用户完全看不到；
  // 现在它在标题下方真的显示出来（见 build 里的 `if (syncMsg.isNotEmpty)`）。
  String syncMsg = '';
  bool syncBad = false;
  Future<void> _pullCloud() async {
    if (!Cloud.loggedIn) {
      if (mounted) setState(() { syncMsg = '未登录 —— 这份清单只存在本机；登录后会与云端合并'; syncBad = false; });
      return;
    }
    try {
      final remote = await Cloud.syncDown('shared_list');
      var changed = false;
      for (final row in remote) {
        final name = row['name'] as String;
        final items = [for (final it in (row['payload']?['items'] ?? [])) Map<String, dynamic>.from(it)];
        lists[name] = items;
        changed = true;
      }
      for (final entry in lists.entries.toList()) {
        if (remote.every((r) => r['name'] != entry.key)) {
          await Cloud.syncUp('shared_list', entry.key, {'items': entry.value});
        }
      }
      if (changed) {
        if (!lists.containsKey(current)) current = lists.keys.first;
        await _save();
      }
      if (mounted) {
        setState(() {
          syncMsg = changed ? '已从云端拉取并合并（${remote.length} 份清单）'
                            : '已是最新（云端 ${remote.length} 份清单）';
          syncBad = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { syncMsg = '拉取云端清单失败：$e —— 现在显示的是本机版本'; syncBad = true; });
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(lists));
    if (!lists.containsKey(current)) return;
    final ok = await Cloud.syncUp('shared_list', current, {'items': lists[current]});
    if (!mounted) return;
    setState(() {
      if (!Cloud.loggedIn) {
        syncMsg = '已存到本机（未登录，暂不同步云端）'; syncBad = false;
      } else if (ok) {
        syncMsg = '已保存并同步到云端'; syncBad = false;
      } else {
        // 不再吞掉：说清楚「本机存住了、云端没上去」，用户才知道别的端看不到
        syncMsg = '已存到本机，但没能同步到云端（网络或权限问题）—— 换端看不到这次改动';
        syncBad = true;
      }
    });
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
      if (syncMsg.isNotEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(syncBad ? Icons.cloud_off : Icons.cloud_done, size: 13,
              color: syncBad ? Colors.orange : Colors.grey),
            const SizedBox(width: 5),
            Expanded(child: Text(syncMsg, style: TextStyle(fontSize: 10.5, height: 1.4,
              color: syncBad ? Colors.orange : Colors.grey))),
          ])),
      Expanded(child: items.isEmpty
        ? const Center(child: Text('点右下角添加第一条\n登录后这份清单会同步到你的其它端', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
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
