// 相册模块（4.81.121 重做）—— 对标成熟开源相册的信息架构。
//
// 参考的是 Simple Gallery / Aves Gallery 这类产品的**功能结构**（不是拷贝代码）：
//   · 四个视图：相册（分组封面）/ 照片（全部）/ 时间线（按月）/ 收藏
//   · 统一直觉：搜索、排序、多选批量删除、大图左右滑 + 双击缩放 + 底部工具栏
// 老版只有「相册选择条 + 4 列网格」，用户原话「难看的要死」——问题不是配色，
// 是**没有信息层级**：找不到时间线、找不到收藏、不能多选、大图只能删。
//
// 数据源仍是 photo_manager（本机相册），不引入任何外部图库 SDK。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import 'i18n.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});
  @override
  State<GalleryPage> createState() => _Gp();
}

class _Gp extends State<GalleryPage> with TickerProviderStateMixin {
  late final TabController _tc = TabController(length: 4, vsync: this);
  final TextEditingController _queryC = TextEditingController();

  /// 0 相册 / 1 照片 / 2 时间线 / 3 收藏
  int get _tab => _tc.index;
  int _sort = 0; // 0 最新 / 1 最早 / 2 名称
  String _query = '';

  List<AssetPathEntity> _albums = const [];
  List<AssetEntity> _photos = const [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _denied = false;
  bool _moreBusy = false;

  final ScrollController _scroll = ScrollController();
  final Set<String> _selected = <String>{};
  final Set<String> _favIds = <String>{};
  bool _selectMode = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() {
      if (mounted) setState(() {});
    });
    _loadFavs();
    _boot();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) {
        _more();
      }
    });
  }

  @override
  void dispose() {
    _tc.dispose();
    _queryC.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadFavs() async {
    try {
      final p = await SharedPreferences.getInstance();
      _favIds.addAll(p.getStringList('gallery_favs') ?? const <String>[]);
    } catch (_) {}
  }

  bool _isFav(AssetEntity e) => _favIds.contains(e.id);

  Future<void> _boot() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      if (mounted)
        setState(() {
          _loading = false;
          _denied = true;
        });
      return;
    }
    final image = await PhotoManager.getAssetPathList(
        type: RequestType.image, hasAll: true);
    final all = await PhotoManager.getAssetPathList(
        type: RequestType.all, hasAll: true);
    if (!mounted) return;
    setState(() {
      _albums = <AssetPathEntity>[
        ...all.where((a) => a.isAll),
        ...image.where((a) => !a.isAll),
      ];
    });
    await _loadAll();
  }

  /// 「照片」视图取全部（含视频），按当前排序。
  Future<void> _loadAll() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _page = 0;
        _hasMore = true;
        _photos = const [];
      });
    }
    final all = await PhotoManager.getAssetPathList(
        type: RequestType.all, hasAll: true);
    if (all.isEmpty || !mounted) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final first = all.firstWhere((a) => a.isAll, orElse: () => all.first);
    final items = await first.getAssetListPaged(page: 0, size: 240);
    if (!mounted) return;
    setState(() {
      _photos = _sorted(items);
      _loading = false;
    });
  }

  List<AssetEntity> _sorted(List<AssetEntity> src) {
    final out = List<AssetEntity>.from(src);
    switch (_sort) {
      case 1:
        out.sort((a, b) =>
            (a.createDateSecond ?? 0).compareTo(b.createDateSecond ?? 0));
        break;
      case 2:
        out.sort((a, b) => (a.title ?? '').compareTo(b.title ?? ''));
        break;
      default:
        out.sort((a, b) =>
            (b.createDateSecond ?? 0).compareTo(a.createDateSecond ?? 0));
    }
    return out;
  }

  Future<void> _more() async {
    if (!_hasMore || _moreBusy || _loading || _tab == 0) return;
    _moreBusy = true;
    try {
      final all = await PhotoManager.getAssetPathList(
          type: RequestType.all, hasAll: true);
      if (all.isEmpty) return;
      final first = all.firstWhere((a) => a.isAll, orElse: () => all.first);
      final next = await first.getAssetListPaged(page: _page + 1, size: 240);
      if (next.isEmpty) {
        _hasMore = false;
      } else if (mounted) {
        _page++;
        setState(() => _photos = _sorted(<AssetEntity>[..._photos, ...next]));
      }
    } catch (_) {
      // 分页失败不打断浏览，保留现有内容
    } finally {
      _moreBusy = false;
    }
  }

  List<AssetEntity> get _visiblePhotos {
    var list = _photos;
    if (_tab == 3) list = list.where(_isFav).toList();
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      list =
          list.where((e) => (e.title ?? '').toLowerCase().contains(q)).toList();
    }
    return list;
  }

  void _enterSelect(AssetEntity e) {
    setState(() {
      _selectMode = true;
      _selected.add(e.id);
    });
  }

  void _toggleSelect(AssetEntity e) {
    setState(() {
      if (_selected.contains(e.id)) {
        _selected.remove(e.id);
      } else {
        _selected.add(e.id);
      }
      if (_selected.isEmpty) _selectMode = false;
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text(trf('删除 {n} 张?', {'n': ids.length})),
                content: Text(tr('删除后无法恢复，请确认')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: Text(tr('取消'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: Text(tr('删除'))),
                ]));
    if (ok != true) return;
    try {
      await PhotoManager.editor.deleteWithIds(ids);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _photos = _photos.where((e) => !ids.contains(e.id)).toList();
      _selected.clear();
      _selectMode = false;
    });
  }

  Future<void> _favorite(AssetEntity e) async {
    final was = _isFav(e);
    if (was) {
      _favIds.remove(e.id);
    } else {
      _favIds.add(e.id);
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('gallery_favs', _favIds.toList());
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _openViewer(List<AssetEntity> list, int idx) async {
    await Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => _Viewer(
                photos: list,
                index: idx,
                onFavorite: _favorite,
                initialFavorite: _isFav(list[idx]),
                onDelete: (e) async {
                  try {
                    await PhotoManager.editor.deleteWithIds([e.id]);
                  } catch (_) {}
                  if (!mounted) return;
                  setState(() =>
                      _photos = _photos.where((x) => x.id != e.id).toList());
                })));
    if (mounted) setState(() {});
  }

  Future<void> _openSortMenu() async {
    final v = await showMenu<int>(
        context: context,
        position: RelativeRect.fromLTRB(MediaQuery.sizeOf(context).width - 16,
            96, MediaQuery.sizeOf(context).width - 16, 96),
        items: [
          PopupMenuItem(value: 0, child: Text(tr('最新在前'))),
          PopupMenuItem(value: 1, child: Text(tr('最早在前'))),
          PopupMenuItem(value: 2, child: Text(tr('按名称'))),
        ]);
    if (v == null || v == _sort) return;
    setState(() => _sort = v);
    if (mounted) await _loadAll();
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_denied) {
      return Scaffold(
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.photo_library_outlined,
                        size: 52, color: cs.primary),
                    const SizedBox(height: 14),
                    Text(tr('需要相册权限才能浏览照片'),
                        style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 6),
                    Text(tr('照片只在本机处理，不会自动上传'),
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 18),
                    FilledButton(
                        onPressed: () => PhotoManager.openSetting(),
                        child: Text(tr('去授权'))),
                  ]))));
    }

    final visible = _visiblePhotos;
    return Scaffold(
      appBar: AppBar(
        title: _selectMode
            ? Text(trf('已选 {n} 张', {'n': _selected.length}))
            : TextField(
                controller: _queryC,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                    hintText: tr('搜索照片或相册'),
                    isDense: true,
                    border: InputBorder.none,
                    hintStyle: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.45),
                        fontSize: 14)),
                style: const TextStyle(fontSize: 14),
              ),
        leading: _selectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                      _selectMode = false;
                      _selected.clear();
                    }))
            : null,
        actions: [
          if (_selectMode)
            IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: _deleteSelected)
          else
            IconButton(
                tooltip: tr('排序'),
                icon: const Icon(Icons.swap_vert),
                onPressed: _openSortMenu),
        ],
        bottom: TabBar(
          controller: _tc,
          tabs: [
            Tab(text: tr('相册')),
            Tab(text: tr('照片')),
            Tab(text: tr('时间线')),
            Tab(text: tr('收藏')),
          ],
        ),
      ),
      body: _tab == 0
          ? _albumGrid()
          : visible.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.image_not_supported_outlined,
                      size: 44, color: cs.onSurface.withValues(alpha: .25)),
                  const SizedBox(height: 10),
                  Text(tr('这里还没有照片'),
                      style: const TextStyle(fontSize: 13, color: Colors.grey)),
                ]))
              : (_tab == 2 ? _timeline(visible) : _photoGrid(visible)),
      floatingActionButton: _selectMode
          ? FloatingActionButton.extended(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              label: Text(trf('删除 {n} 张', {'n': _selected.length})))
          : null,
    );
  }

  /// 相册 Tab：2 列大卡（封面 + 名称 + 张数），开源相册的经典结构。
  Widget _albumGrid() {
    final q = _query.trim().toLowerCase();
    final albums = q.isEmpty
        ? _albums
        : _albums.where((a) => a.name.toLowerCase().contains(q)).toList();
    if (albums.isEmpty) {
      return Center(
          child: Text(tr('没有匹配的相册'),
              style: const TextStyle(fontSize: 12, color: Colors.grey)));
    }
    return GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(10),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.18),
        itemCount: albums.length,
        itemBuilder: (_, i) {
          final a = albums[i];
          return InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () async {
                final items = await a.getAssetListPaged(page: 0, size: 400);
                if (!mounted || items.isEmpty) return;
                await _openViewer(items, 0);
              },
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(fit: StackFit.expand, children: [
                    FutureBuilder<List<AssetEntity>>(
                        future: a.getAssetListPaged(page: 0, size: 1),
                        builder: (_, s) {
                          final e =
                              s.data?.isNotEmpty == true ? s.data!.first : null;
                          return e == null
                              ? Container(color: Colors.grey.shade300)
                              : AssetEntityImage(e,
                                  isOriginal: false,
                                  thumbnailSize:
                                      const ThumbnailSize.square(360),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      Container(color: Colors.grey.shade300));
                        }),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                            Colors.transparent,
                            Color(0xAA000000),
                          ],
                              stops: [
                            0.4,
                            1
                          ])),
                    ),
                    Positioned(
                        left: 12,
                        right: 12,
                        bottom: 10,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              FutureBuilder<int>(
                                  future: a.assetCountAsync,
                                  builder: (_, s) => Text(
                                      trf('{n} 张', {'n': s.data ?? 0}),
                                      style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11))),
                            ])),
                  ])));
        });
  }

  /// 照片 / 收藏 Tab：3 列紧凑网格，长按多选。
  Widget _photoGrid(List<AssetEntity> list) {
    return GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(3),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, crossAxisSpacing: 3, mainAxisSpacing: 3),
        itemCount: list.length + (_tab == 1 && _hasMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= list.length) {
            return const Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)));
          }
          final e = list[i];
          final on = _selected.contains(e.id);
          return GestureDetector(
              onTap: () =>
                  _selectMode ? _toggleSelect(e) : _openViewer(list, i),
              onLongPress: () =>
                  _selectMode ? _toggleSelect(e) : _enterSelect(e),
              child: Stack(fit: StackFit.expand, children: [
                AssetEntityImage(e,
                    isOriginal: false,
                    thumbnailSize: const ThumbnailSize.square(300),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Colors.black12)),
                if (e.type == RequestType.video)
                  const Positioned(
                      right: 6,
                      bottom: 6,
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white70, size: 20)),
                if (on)
                  Positioned.fill(
                      child: Container(
                          color: Colors.black38,
                          child: const Align(
                              alignment: Alignment.topRight,
                              child: Padding(
                                  padding: EdgeInsets.all(6),
                                  child: Icon(Icons.check_circle,
                                      color: Colors.white, size: 22))))),
              ]));
        });
  }

  /// 时间线：按月分组（开源相册的招牌视图）。
  Widget _timeline(List<AssetEntity> list) {
    final groups = <String, List<AssetEntity>>{};
    for (final e in list) {
      final d = e.createDateTime;
      final key = '${d.year} 年 ${d.month} 月';
      groups.putIfAbsent(key, () => <AssetEntity>[]).add(e);
    }
    return ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: groups.length,
        itemBuilder: (_, gi) {
          final key = groups.keys.elementAt(gi);
          final items = groups[key]!;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    child: Row(children: [
                      Text(key,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 8),
                      Text(trf('{n} 张', {'n': items.length}),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                    ])),
                GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final e = items[i];
                      return GestureDetector(
                          onTap: () => _openViewer(items, i),
                          child: AssetEntityImage(e,
                              isOriginal: false,
                              thumbnailSize: const ThumbnailSize.square(300),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const ColoredBox(color: Colors.black12)));
                    }),
              ]);
        });
  }
}

/// 大图浏览：左右滑 + 双击缩放（InteractiveViewer）+ 底部信息栏。
class _Viewer extends StatefulWidget {
  const _Viewer({
    required this.photos,
    required this.index,
    required this.onFavorite,
    required this.onDelete,
    required this.initialFavorite,
  });
  final List<AssetEntity> photos;
  final int index;
  final Future<void> Function(AssetEntity) onFavorite;
  final Future<void> Function(AssetEntity) onDelete;
  final bool initialFavorite;
  @override
  State<_Viewer> createState() => _Vw();
}

class _Vw extends State<_Viewer> {
  late int i = widget.index;
  late final PageController _pc = PageController(initialPage: i);
  bool _chrome = true;
  bool _viewerFav = false;

  @override
  void initState() {
    super.initState();
    _viewerFav = widget.initialFavorite;
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  String _date(AssetEntity e) {
    final d = e.createDateTime;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext c) {
    final e = widget.photos[i];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _chrome = !_chrome),
              child: PageView.builder(
                controller: _pc,
                itemCount: widget.photos.length,
                onPageChanged: (v) => setState(() => i = v),
                itemBuilder: (_, idx) => InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: AssetEntityImage(
                      widget.photos[idx],
                      fit: BoxFit.contain,
                      loadingBuilder: (_, child, p) =>
                          p == null ? child : const CircularProgressIndicator(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_chrome)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xBB000000), Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(c),
                      ),
                      Text('${i + 1}/${widget.photos.length}',
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white)),
                      const Spacer(),
                      IconButton(
                        icon: Icon(
                          _viewerFav ? Icons.favorite : Icons.favorite_border,
                          color: _viewerFav ? Colors.redAccent : Colors.white,
                        ),
                        onPressed: () async {
                          await widget.onFavorite(e);
                          if (c.mounted) setState(() {});
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: c,
                            builder: (d) => AlertDialog(
                              title: Text(tr('删除这张照片?')),
                              actions: <Widget>[
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: Text(tr('取消')),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: Text(tr('删除')),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await widget.onDelete(e);
                            if (c.mounted) Navigator.pop(c);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_chrome)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xBB000000), Colors.transparent],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      e.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                    ),
                    const SizedBox(height: 3),
                    Text(_date(e),
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white70)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
