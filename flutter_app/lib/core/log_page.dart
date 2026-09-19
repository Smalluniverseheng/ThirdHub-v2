// 日志中心页（D-06）：全部分类 + 报错中心 + 上限/保留期设置 + 导出/清空。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

class LogCenterPage extends StatefulWidget {
  const LogCenterPage({super.key});
  @override
  State<LogCenterPage> createState() => _Lc();
}

class _Lc extends State<LogCenterPage> {
  List<Map<String, dynamic>> _all = [];
  String _cat = 'all'; // all | error | 各类
  String _q = '';
  bool _loading = true;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = AppLog.onChange.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final l = await AppLog.all();
    if (mounted) setState(() {
      _all = l;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _view {
    var l = _all;
    if (_cat == 'error') {
      l = l.where((e) => e['lv'] == 'error' || e['cat'] == 'error').toList();
    } else if (_cat != 'all') {
      l = l.where((e) => e['cat'] == _cat).toList();
    }
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      l = l.where((e) => '${e['msg']}'.toLowerCase().contains(q)).toList();
    }
    return l;
  }

  Color _lvColor(String lv) => switch (lv) {
        'error' => Colors.redAccent,
        'warn' => Colors.orange,
        _ => Colors.grey,
      };

  void _settings() {
    showModalBottomSheet(
        context: context,
        builder: (c2) => StatefulBuilder(builder: (c2, setD) {
              return SafeArea(
                  child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('日志存储设置', style: TextStyle(fontWeight: FontWeight.bold)),
                  FutureBuilder<int>(
                      future: AppLog.limit(),
                      builder: (_, s) {
                        final v = (s.data ?? 2000).toDouble();
                        return Column(children: [
                          const SizedBox(height: 12),
                          Text('存储上限：${v.toInt()} 条', style: const TextStyle(fontSize: 13)),
                          Slider(
                              value: v,
                              min: 500,
                              max: 20000,
                              divisions: 39,
                              onChanged: (x) {
                                AppLog.setLimit(x.toInt());
                                setD(() {});
                              }),
                        ]);
                      }),
                  FutureBuilder<int>(
                      future: AppLog.keepDays(),
                      builder: (_, s) {
                        final v = (s.data ?? 30).toDouble();
                        return Column(children: [
                          Text('自动清理：保留 ${v.toInt()} 天', style: const TextStyle(fontSize: 13)),
                          Slider(
                              value: v,
                              min: 1,
                              max: 365,
                              divisions: 52,
                              onChanged: (x) {
                                AppLog.setKeepDays(x.toInt());
                                setD(() {});
                              }),
                        ]);
                      }),
                  const Text('日志只存在本机，不会上传到任何第三方服务器。',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
              ));
            }));
  }

  @override
  Widget build(BuildContext c) {
    final cats = ['all', 'error', ...AppLog.cats.keys];
    final errCount = _all.where((e) => e['lv'] == 'error' || e['cat'] == 'error').length;
    return Scaffold(
      appBar: AppBar(title: const Text('日志中心'), actions: [
        IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: '导出（复制到剪贴板）',
            onPressed: () async {
              final t = await AppLog.export();
              await Clipboard.setData(ClipboardData(text: t));
              if (mounted) {
                ScaffoldMessenger.of(c).showSnackBar(
                    const SnackBar(content: Text('日志已复制到剪贴板'), duration: Duration(seconds: 1)));
              }
            }),
        IconButton(icon: const Icon(Icons.tune), tooltip: '存储设置', onPressed: _settings),
        IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: () async {
              final ok = await showDialog<bool>(
                  context: c,
                  builder: (d) => AlertDialog(
                        title: const Text('清空全部日志？'),
                        content: const Text('此操作不可恢复。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('清空')),
                        ],
                      ));
              if (ok == true) {
                await AppLog.clear();
              }
            }),
      ]),
      body: Column(children: [
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final k in cats)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(k == 'all'
                      ? '全部 ${_all.length}'
                      : k == 'error'
                          ? '报错 $errCount'
                          : (AppLog.cats[k] ?? k)),
                  selected: _cat == k,
                  onSelected: (_) => setState(() => _cat = k),
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            decoration: InputDecoration(
              hintText: '搜索日志内容',
              isDense: true,
              filled: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _view.isEmpty
                  ? const Center(child: Text('暂无日志', style: TextStyle(color: Colors.grey)))
                  : ListView.separated(
                      itemCount: _view.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final e = _view[i];
                        final t = DateTime.fromMillisecondsSinceEpoch(e['at'] as int)
                            .toString()
                            .substring(5, 16);
                        final d = e['d'];
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.circle, size: 8, color: _lvColor('${e['lv']}')),
                          title: Text('${e['msg']}', style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                              '$t · ${AppLog.cats[e['cat']] ?? e['cat']}',
                              style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          trailing: d != null ? const Icon(Icons.expand_more, size: 16) : null,
                          onTap: d == null
                              ? null
                              : () => showModalBottomSheet(
                                  context: c,
                                  builder: (_) => SafeArea(
                                      child: SingleChildScrollView(
                                          padding: const EdgeInsets.all(16),
                                          child: SelectableText('$d',
                                              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))))),
                        );
                      })),
      ]),
    );
  }
}
