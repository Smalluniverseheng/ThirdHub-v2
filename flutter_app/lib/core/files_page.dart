// 文件管理器模块: 自研实现(参考开源 Material Files(GPL)/Amaze 的功能设计, 无代码拷贝, 无协议冲突)
// 目录浏览 · 打开 · 分享 · 删除 · 新建文件夹 · 存储信息
// ★2026-09-20: 补递归搜索(文件名, 当前目录起) + 排序(名称/大小/时间) —— 对齐开源文件管理器的基本盘
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class FilesPage extends StatefulWidget { const FilesPage({super.key}); @override State<FilesPage> createState() => _Fp(); }
class _Fp extends State<FilesPage> {
  String path = ''; List<FileSystemEntity> items = []; bool loading = true; String err = '';
  final List<String> roots = [];
  // 搜索与排序
  bool searching = false;       // 搜索模式开关(显示搜索框)
  bool searchBusy = false;      // 递归搜索进行中
  int searchGen = 0;            // 代际号: 取消/新搜索作废旧结果
  List<FileSystemEntity>? searchResults;
  final searchC = TextEditingController();
  String sortBy = 'name';       // name | size | time
  bool sortAsc = true;

  @override void initState() { super.initState(); _boot(); }
  Future<void> _boot() async {
    // 可用根目录: 外部存储根 + 常用目录 + App目录
    const ext = '/storage/emulated/0';
    if (await Directory(ext).exists()) roots.add(ext);
    for (final sub in ['Download', 'DCIM', 'Documents', 'Pictures', 'Movies', 'Music']) {
      if (await Directory('$ext/$sub').exists()) roots.add('$ext/$sub');
    }
    try { final d = await getApplicationDocumentsDirectory(); roots.add(d.path); } catch (_) {}
    path = roots.isNotEmpty ? roots.first : '/';
    await _go(path);
  }

  Future<void> _go(String p) async {
    setState(() { loading = true; err = ''; searchResults = null; });
    try {
      final list = await Directory(p).list().toList();
      list.sort((a, b) { final ad = a is Directory ? 0 : 1; final bd = b is Directory ? 0 : 1;
        return ad != bd ? ad - bd : a.path.toLowerCase().compareTo(b.path.toLowerCase()); });
      items = list; path = p;
    } catch (e) { err = '无法访问该目录(权限受限)'; }
    if (mounted) setState(() => loading = false);
  }

  // 目录排序(文件夹恒在前): 名称/大小/修改时间 × 升/降
  List<FileSystemEntity> _sorted(List<FileSystemEntity> src) {
    final list = List<FileSystemEntity>.from(src);
    int cmp(FileSystemEntity a, FileSystemEntity b) {
      final ad = a is Directory ? 0 : 1; final bd = b is Directory ? 0 : 1;
      if (ad != bd) return ad - bd;
      int r;
      switch (sortBy) {
        case 'size':
          final as = a is File ? a.lengthSync() : 0; final bs = b is File ? b.lengthSync() : 0;
          r = as.compareTo(bs);
        case 'time':
          r = a.statSync().modified.compareTo(b.statSync().modified);
        default:
          r = a.path.toLowerCase().compareTo(b.path.toLowerCase());
      }
      return sortAsc ? r : -r;
    }
    list.sort(cmp);
    return list;
  }

  // 递归搜索: 从当前目录向下找文件名包含关键词的条目(跳过隐藏目录, 容错权限受限目录)
  Future<void> _search(String q) async {
    final query = q.trim().toLowerCase();
    if (query.isEmpty) { setState(() => searchResults = null); return; }
    final gen = ++searchGen;
    setState(() { searchBusy = true; searchResults = []; });
    final found = <FileSystemEntity>[];
    try {
      await for (final e in Directory(path).list(recursive: true, followLinks: false)
          .handleError((_) {/* 权限受限目录跳过 */})) {
        if (gen != searchGen) return; // 已被新搜索/关闭作废
        final name = e.path.split('/').last.toLowerCase();
        if (name.startsWith('.')) continue; // 隐藏文件不打扰结果
        if (name.contains(query)) {
          found.add(e);
          if (found.length >= 300) break; // 上限防卡
          if (found.length % 25 == 0 && mounted) setState(() => searchResults = List.of(found)); // 渐进上屏
        }
      }
    } catch (_) {}
    if (gen != searchGen || !mounted) return;
    setState(() { searchResults = found; searchBusy = false; });
  }

  void _closeSearch() {
    searchGen++;
    setState(() { searching = false; searchBusy = false; searchResults = null; searchC.clear(); });
  }

  String _name(FileSystemEntity e) => e.path.split('/').last;
  String _size(File f) { final n = f.lengthSync();
    if (n > 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)} MB';
    if (n > 1 << 10) return '${(n / (1 << 10)).toStringAsFixed(1)} KB';
    return '$n B'; }
  IconData _icon(FileSystemEntity e) {
    if (e is Directory) return Icons.folder;
    final n = _name(e).toLowerCase();
    if (RegExp(r'\.(jpg|jpeg|png|gif|webp|bmp)$').hasMatch(n)) return Icons.image_outlined;
    if (RegExp(r'\.(mp4|mkv|avi|mov|webm)$').hasMatch(n)) return Icons.videocam_outlined;
    if (RegExp(r'\.(mp3|flac|aac|wav|ogg|m4a)$').hasMatch(n)) return Icons.music_note_outlined;
    if (RegExp(r'\.(txt|md|log|json)$').hasMatch(n)) return Icons.article_outlined;
    if (RegExp(r'\.(pdf)$').hasMatch(n)) return Icons.picture_as_pdf_outlined;
    if (RegExp(r'\.(apk)$').hasMatch(n)) return Icons.android;
    if (RegExp(r'\.(zip|rar|7z|tar|gz)$').hasMatch(n)) return Icons.archive_outlined;
    return Icons.insert_drive_file_outlined;
  }

  void _fileMenu(FileSystemEntity e) {
    showModalBottomSheet(context: context, builder: (c2) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(dense: true, leading: const Icon(Icons.open_in_new), title: const Text('打开'),
        onTap: () { Navigator.pop(c2); OpenFilex.open(e.path); }),
      ListTile(dense: true, leading: const Icon(Icons.share_outlined), title: const Text('分享'),
        onTap: () { Navigator.pop(c2); Share.shareXFiles([XFile(e.path)]); }),
      ListTile(dense: true, leading: const Icon(Icons.drive_file_rename_outline), title: const Text('重命名'),
        onTap: () { Navigator.pop(c2); _rename(e); }),
      ListTile(dense: true, leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
        title: const Text('删除', style: TextStyle(color: Colors.redAccent)),
        onTap: () async { Navigator.pop(c2);
          final ok = await showDialog<bool>(context: context, builder: (c3) => AlertDialog(
            title: Text('删除「${_name(e)}」?'),
            actions: [TextButton(onPressed: () => Navigator.pop(c3, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(c3, true), child: const Text('删除'))]));
          if (ok == true) { try { await e.delete(recursive: true); } catch (_) {} _go(path); } }),
    ])));
  }

  Future<void> _rename(FileSystemEntity e) async {
    final ctrl = TextEditingController(text: _name(e));
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(title: const Text('重命名'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(isDense: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('确定'))]));
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try { await e.rename('${e.parent.path}/${ctrl.text.trim()}'); } catch (_) {}
      _go(path);
    }
  }

  Future<void> _mkdir() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(title: const Text('新建文件夹'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '文件夹名', isDense: true)),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('创建'))]));
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try { await Directory('$path/${ctrl.text.trim()}').create(); } catch (_) {}
      _go(path);
    }
  }

  @override Widget build(BuildContext c) {
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    final results = searchResults;
    return Column(children: [
      // 路径条 + 快捷根目录 + 搜索/排序
      SizedBox(height: 38, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
        for (var i = 0; i < segs.length; i++) ...[
          if (i > 0) const Center(child: Icon(Icons.chevron_right, size: 14, color: Colors.grey)),
          ActionChip(label: Text(segs[i], style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact,
            onPressed: () => _go('/${segs.sublist(0, i + 1).join('/')}')),
        ],
        const SizedBox(width: 12),
        for (final r in roots.skip(1).take(6))
          Padding(padding: const EdgeInsets.only(right: 4), child: ActionChip(
            avatar: const Icon(Icons.sd_storage, size: 12),
            label: Text(r.split('/').last, style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact,
            onPressed: () => _go(r))),
      ])),
      // 工具行: 搜索 + 排序 + 新建文件夹
      Padding(padding: const EdgeInsets.fromLTRB(8, 0, 4, 4), child: Row(children: [
        if (searching)
          Expanded(child: TextField(controller: searchC, autofocus: true,
            decoration: const InputDecoration(hintText: '搜索当前目录(含子目录)…', isDense: true,
              prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
            onChanged: (v) { if (v.trim().isEmpty) setState(() => searchResults = null); },
            onSubmitted: _search))
        else
          Expanded(child: Text(results != null ? '搜索: ${searchC.text} (${results.length} 项)' : path,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.grey))),
        if (searchBusy) const Padding(padding: EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
        IconButton(visualDensity: VisualDensity.compact, tooltip: searching ? '关闭搜索' : '搜索文件',
          icon: Icon(searching ? Icons.close : Icons.search, size: 19),
          onPressed: () => searching ? _closeSearch() : setState(() => searching = true)),
        PopupMenuButton<String>(icon: const Icon(Icons.sort, size: 19), tooltip: '排序',
          onSelected: (v) => setState(() {
            if (v.endsWith('_desc')) { sortBy = v.substring(0, v.length - 5); sortAsc = false; }
            else { sortBy = v; sortAsc = true; }
          }),
          itemBuilder: (_) => [
            _sortItem('name', '按名称'), _sortItem('size', '按大小'), _sortItem('time', '按时间'),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(value: '${sortBy}_desc', checked: !sortAsc, child: const Text('降序', style: TextStyle(fontSize: 13))),
          ]),
      ])),
      // 搜索结果层 / 目录列表层
      Expanded(child: results != null
        ? (results.isEmpty && !searchBusy
            ? const Center(child: Text('没有找到匹配的文件', style: TextStyle(color: Colors.grey)))
            : ListView(children: [
                for (final e in _sorted(results))
                  ListTile(dense: true, leading: Icon(_icon(e), size: 20,
                      color: e is Directory ? Colors.amber.shade700 : null),
                    title: Text(_name(e), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(e.path, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9, color: Colors.grey)),
                    onTap: () { if (e is Directory) { _closeSearch(); _go(e.path); } else { OpenFilex.open(e.path); } },
                    onLongPress: () => _fileMenu(e)),
                if (searchBusy) const Padding(padding: EdgeInsets.all(10),
                  child: Center(child: Text('搜索中…', style: TextStyle(fontSize: 11, color: Colors.grey)))),
              ]))
        : loading ? const Center(child: CircularProgressIndicator())
        : err.isNotEmpty ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_off_outlined, size: 44, color: Colors.grey),
            const SizedBox(height: 10),
            Text(err, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            TextButton(onPressed: _boot, child: const Text('返回可用目录')),
          ])))
        : items.isEmpty ? const Center(child: Text('空文件夹', style: TextStyle(color: Colors.grey)))
        : ListView(children: [
          for (final e in _sorted(items))
            ListTile(dense: true, leading: Icon(_icon(e), size: 20,
                color: e is Directory ? Colors.amber.shade700 : null),
              title: Text(_name(e), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: e is File ? Text(_size(e), style: const TextStyle(fontSize: 10, color: Colors.grey)) : null,
              onTap: () { if (e is Directory) { _go(e.path); } else { OpenFilex.open(e.path); } },
              onLongPress: () => _fileMenu(e),
              trailing: e is File ? IconButton(icon: const Icon(Icons.more_vert, size: 18), onPressed: () => _fileMenu(e)) : null),
        ])),
    ]);
  }

  PopupMenuItem<String> _sortItem(String v, String label) => CheckedPopupMenuItem(value: v,
    checked: sortBy == v && sortAsc, child: Text(label, style: const TextStyle(fontSize: 13)));
}
