// 文件管理器模块: 自研实现(参考开源 Material Files(GPL)/Amaze 的功能设计, 无代码拷贝, 无协议冲突)
// 目录浏览 · 打开 · 分享 · 删除 · 新建文件夹 · 存储信息
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class FilesPage extends StatefulWidget { const FilesPage({super.key}); @override State<FilesPage> createState() => _Fp(); }
class _Fp extends State<FilesPage> {
  String path = ''; List<FileSystemEntity> items = []; bool loading = true; String err = '';
  final List<String> roots = [];

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
    setState(() { loading = true; err = ''; });
    try {
      final list = await Directory(p).list().toList();
      list.sort((a, b) { final ad = a is Directory ? 0 : 1; final bd = b is Directory ? 0 : 1;
        return ad != bd ? ad - bd : a.path.toLowerCase().compareTo(b.path.toLowerCase()); });
      items = list; path = p;
    } catch (e) { err = '无法访问该目录(权限受限)'; }
    if (mounted) setState(() => loading = false);
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
    return Column(children: [
      // 路径条 + 快捷根目录
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
      Expanded(child: loading ? const Center(child: CircularProgressIndicator())
        : err.isNotEmpty ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_off_outlined, size: 44, color: Colors.grey),
            const SizedBox(height: 10),
            Text(err, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            TextButton(onPressed: _boot, child: const Text('返回可用目录')),
          ])))
        : items.isEmpty ? const Center(child: Text('空文件夹', style: TextStyle(color: Colors.grey)))
        : ListView(children: [
          for (final e in items)
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
}
