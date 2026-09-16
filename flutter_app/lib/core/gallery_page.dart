// 相册模块: 自研实现(参考开源相册 Simple Gallery(私有限制)/LeafPic 的功能设计, 无代码拷贝)
// 相册列表 → 照片网格 → 大图浏览(左右滑动) · 删除
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

class GalleryPage extends StatefulWidget { const GalleryPage({super.key}); @override State<GalleryPage> createState() => _Gp(); }
class _Gp extends State<GalleryPage> {
  List<AssetPathEntity> albums = []; AssetPathEntity? cur; List<AssetEntity> photos = [];
  bool loading = true; bool denied = false; int page = 0; bool hasMore = true;
  final scroll = ScrollController();

  @override void initState() { super.initState(); _boot();
    scroll.addListener(() { if (scroll.position.pixels > scroll.position.maxScrollExtent - 400) _more(); }); }
  @override void dispose() { scroll.dispose(); super.dispose(); }

  Future<void> _boot() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) { setState(() { loading = false; denied = true; }); return; }
    albums = await PhotoManager.getAssetPathList(type: RequestType.image, hasAll: true);
    if (albums.isNotEmpty) { cur = albums.first; await _loadAlbum(cur!); }
    if (mounted) setState(() => loading = false);
  }
  Future<void> _loadAlbum(AssetPathEntity a) async {
    page = 0; hasMore = true; photos = await a.getAssetListPaged(page: 0, size: 120);
    if (mounted) setState(() {});
  }
  Future<void> _more() async {
    if (!hasMore || cur == null) return;
    final next = await cur!.getAssetListPaged(page: page + 1, size: 120);
    if (next.isEmpty) { hasMore = false; return; }
    page++; photos.addAll(next);
    if (mounted) setState(() {});
  }

  @override Widget build(BuildContext c) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (denied) return Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
      const SizedBox(height: 12),
      const Text('需要相册权限才能浏览照片', style: TextStyle(color: Colors.grey)),
      const SizedBox(height: 12),
      FilledButton.tonal(onPressed: () { PhotoManager.openSetting(); }, child: const Text('去授权')),
    ])));
    return Column(children: [
      // 相册选择条
      SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
        for (final a in albums)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: FutureBuilder<int>(future: a.assetCountAsync, builder: (_, snap) =>
            ChoiceChip(label: Text('${a.name} (${snap.data ?? ''})', style: const TextStyle(fontSize: 11)),
              selected: cur?.id == a.id, visualDensity: VisualDensity.compact,
              onSelected: (_) { setState(() { cur = a; photos = []; }); _loadAlbum(a); }))),
      ])),
      Expanded(child: photos.isEmpty ? const Center(child: Text('没有照片', style: TextStyle(color: Colors.grey)))
        : GridView.builder(controller: scroll, padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
          itemCount: photos.length, itemBuilder: (_, i) {
            final e = photos[i];
            return GestureDetector(onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => _Viewer(photos: photos, index: i))),
              child: AssetEntityImage(e, isOriginal: false, thumbnailSize: const ThumbnailSize.square(200), fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26)));
          })),
    ]);
  }
}

class _Viewer extends StatefulWidget { final List<AssetEntity> photos; final int index;
  const _Viewer({required this.photos, required this.index}); @override State<_Viewer> createState() => _Vw(); }
class _Vw extends State<_Viewer> {
  late int i = widget.index; late final PageController pc = PageController(initialPage: i);
  @override Widget build(BuildContext c) {
    final e = widget.photos[i];
    return Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.transparent,
      title: Text('${i + 1}/${widget.photos.length}', style: const TextStyle(fontSize: 13)),
      actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async {
        final ok = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(title: const Text('删除这张照片?'),
          actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('删除'))]));
        if (ok == true) { await PhotoManager.editor.deleteWithIds([e.id]); if (c.mounted) Navigator.pop(c); }
      })]),
      body: PageView.builder(controller: pc, itemCount: widget.photos.length,
        onPageChanged: (v) => setState(() => i = v),
        itemBuilder: (_, idx) => InteractiveViewer(maxScale: 5, child: Center(
          child: AssetEntityImage(widget.photos[idx], fit: BoxFit.contain,
            loadingBuilder: (_, child, p) => p == null ? child : const CircularProgressIndicator())))));
  }
}
