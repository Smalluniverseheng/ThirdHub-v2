// 导入自动识别（D-05）：选扫描根 → 全盘扫描支持的格式 → 分组勾选 → 导入。
// 与"手动选择文件"并存：入口 sheet 让用户二选一，省得一个个翻存储空间。
import 'package:flutter/material.dart';

import 'local_import.dart';

/// 导入入口弹层：返回导入成功的数量（null=取消）。
/// kind = novel / video / music / comic。
Future<int?> importWithChoice(BuildContext c, String kind) async {
  final choice = await showModalBottomSheet<String>(
    context: c,
    builder: (c2) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 8),
      ListTile(
        leading: const Icon(Icons.folder_open),
        title: const Text('选择文件'),
        subtitle: const Text('从系统文件管理器里挑', style: TextStyle(fontSize: 12)),
        onTap: () => Navigator.pop(c2, 'pick'),
      ),
      ListTile(
        leading: const Icon(Icons.document_scanner_outlined),
        title: const Text('自动识别'),
        subtitle: const Text('自动扫描本机里所有支持的格式', style: TextStyle(fontSize: 12)),
        onTap: () => Navigator.pop(c2, 'scan'),
      ),
      const SizedBox(height: 8),
    ])),
  );
  if (choice == null) return null;
  if (choice == 'pick') {
    return switch (kind) {
      'novel' => LocalLib.importNovels(),
      'video' => LocalLib.importVideos(),
      'music' => LocalLib.importAudios(),
      'comic' => LocalLib.importComic(),
      _ => LocalLib.importNovels(),
    };
  }
  if (!c.mounted) return null;
  final n = await Navigator.push<int>(
      c, MaterialPageRoute(builder: (_) => AutoScanPage(kind: kind)));
  return n;
}

class AutoScanPage extends StatefulWidget {
  final String kind;
  const AutoScanPage({super.key, required this.kind});
  @override
  State<AutoScanPage> createState() => _As();
}

class _As extends State<AutoScanPage> {
  List<(String, String)> _roots = [];
  String? _root;
  bool _scanning = false;
  int _found = 0;
  Map<String, List<String>> _groups = {};
  final Set<String> _sel = {};
  bool _importing = false;

  static const _kindName = {'novel': '小说', 'video': '视频', 'music': '音乐', 'comic': '漫画'};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _roots = await LocalLib.scanRoots();
    if (mounted) setState(() {});
  }

  Future<void> _scan(String root) async {
    setState(() {
      _root = root;
      _scanning = true;
      _found = 0;
      _groups = {};
      _sel.clear();
    });
    try {
      final g = await LocalLib.autoScan(widget.kind, root,
          onProgress: (n) {
            if (mounted) setState(() => _found = n);
          });
      if (mounted) setState(() => _groups = g);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('扫描失败: $e')));
      }
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _import() async {
    if (_sel.isEmpty) return;
    setState(() => _importing = true);
    int n = 0;
    try {
      final paths = _sel.toList();
      n = widget.kind == 'novel'
          ? await LocalLib.importNovelPaths(paths)
          : await LocalLib.importMediaPaths(widget.kind, paths);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
    if (mounted) Navigator.pop(context, n);
  }

  String _base(String p) => p.split(RegExp(r'[/\\]')).last;

  @override
  Widget build(BuildContext c) {
    final kn = _kindName[widget.kind] ?? widget.kind;
    return Scaffold(
      appBar: AppBar(title: Text('自动识别$kn'), actions: [
        if (_sel.isNotEmpty)
          TextButton(
              onPressed: _importing ? null : _import,
              child: Text('导入 ${_sel.length} 项')),
      ]),
      body: _roots.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              // 扫描根选择
              SizedBox(
                height: 46,
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    children: [
                      for (final r in _roots)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(r.$1, style: const TextStyle(fontSize: 12)),
                            selected: _root == r.$2,
                            onSelected: _scanning ? null : (_) => _scan(r.$2),
                          ),
                        ),
                    ]),
              ),
              if (_scanning)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text('扫描中… 已发现 $_found 个', style: const TextStyle(fontSize: 13)),
                  ]),
                ),
              const Divider(height: 1),
              Expanded(
                child: _groups.isEmpty
                    ? Center(
                        child: Text(
                            _scanning
                                ? '正在扫描…'
                                : _root == null
                                    ? '先在上面选一个要扫描的位置'
                                    : '这个目录下没找到可导入的${_kindName[widget.kind]}文件',
                            style: const TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center))
                    : ListView(children: [
                        for (final g in _groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Row(children: [
                              Text('.${g.key} · ${g.value.length} 个',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                              const Spacer(),
                              TextButton(
                                  onPressed: () {
                                    setState(() {
                                      final all = g.value.every((p) => _sel.contains(p));
                                      if (all) {
                                        _sel.removeAll(g.value);
                                      } else {
                                        _sel.addAll(g.value);
                                      }
                                    });
                                  },
                                  child: Text(
                                      g.value.every((p) => _sel.contains(p)) ? '全不选' : '全选',
                                      style: const TextStyle(fontSize: 12))),
                            ]),
                          ),
                          for (final p in g.value)
                            CheckboxListTile(
                              dense: true,
                              value: _sel.contains(p),
                              onChanged: (v) =>
                                  setState(() => v == true ? _sel.add(p) : _sel.remove(p)),
                              title: Text(_base(p),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(p,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
                            ),
                        ],
                      ]),
              ),
            ]),
    );
  }
}
