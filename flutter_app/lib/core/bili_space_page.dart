// B站「我的收藏夹 / UP 主页」页面（4.81.100）
//
// 数据走 biliGet：后端有对应 op 就走后端，没有就自动退回端上直连。
// 这样 NAS 关机、出门在外、账号没配后端时这两块仍然可用。
import 'package:flutter/material.dart';

import 'bili_auth_page.dart';
import 'bili_module_page.dart'
    show BiliCtx, biliCover, biliDur, biliGet, biliPlays, openBiliVideo;
import 'bili_swipe_page.dart';
import 'design_tokens.dart';
import 'i18n.dart';

/// 收藏夹：先列分组，点进去看视频。mid 为空表示"我的收藏夹"。
class BiliFavPage extends StatefulWidget {
  const BiliFavPage({super.key, required this.ctx, this.mid});

  final BiliCtx ctx;
  final String? mid;

  @override
  State<BiliFavPage> createState() => _BiliFavPageState();
}

class _BiliFavPageState extends State<BiliFavPage> {
  List<Map<String, dynamic>> _folders = const [];
  Map<String, dynamic>? _selected;
  List<Map<String, dynamic>> _items = const [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  bool _busy = false;
  bool _needLogin = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    setState(() {
      _loading = true;
      _error = '';
      _needLogin = false;
    });
    final q = (widget.mid ?? '').isNotEmpty
        ? '?mid=${Uri.encodeQueryComponent(widget.mid!)}'
        : '';
    final j = await biliGet(widget.ctx, '/v1/bili/fav/folders$q');
    if (!mounted) return;
    if (j == null || j['ok'] != true) {
      setState(() {
        _loading = false;
        _needLogin = j?['needLogin'] == true;
        _error = '${j?['error'] ?? tr('加载失败')}';
      });
      return;
    }
    final raw = (j['folders'] as List?) ?? const [];
    setState(() {
      _loading = false;
      _folders = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    });
  }

  Future<void> _openFolder(Map<String, dynamic> f) async {
    setState(() {
      _selected = f;
      _items = const [];
      _page = 1;
      _hasMore = false;
      _loading = true;
      _error = '';
    });
    await _loadList(1);
  }

  Future<void> _loadList(int pn) async {
    final id = '${_selected?['id'] ?? ''}';
    if (id.isEmpty) return;
    setState(() => _busy = true);
    final j = await biliGet(
        widget.ctx, '/v1/bili/fav/list?media_id=${Uri.encodeQueryComponent(id)}&pn=$pn');
    if (!mounted) return;
    setState(() => _busy = false);
    if (j == null || j['ok'] != true) {
      setState(() => _error = '${j?['error'] ?? tr('加载失败')}');
      return;
    }
    final raw = (j['list'] as List?) ?? const [];
    final more = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    setState(() {
      _items = pn == 1 ? more : [..._items, ...more];
      _page = pn;
      _hasMore = j['hasMore'] == true && more.isNotEmpty;
      _loading = false;
      _error = '';
    });
  }

  void _openVideo(int i) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BiliSwipePage(
        ctx: widget.ctx,
        items: List<Map<String, dynamic>>.from(_items),
        initialIndex: i,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = _selected;
    return Scaffold(
      appBar: AppBar(
        title: Text(f == null ? tr('我的收藏夹') : '${f['name'] ?? ''}'),
        leading: f == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _selected = null;
                  _items = const [];
                  _error = '';
                }),
              ),
      ),
      body: _needLogin
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.login_outlined, size: 40, color: cs.primary),
                    const SizedBox(height: 12),
                    Text(_error, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const BiliAuthPage()));
                        if (mounted) _loadFolders();
                      },
                      child: Text(tr('登录 B 站')),
                    ),
                  ],
                ),
              ),
            )
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : f == null
                  ? _folderList(cs)
                  : _videoList(cs),
    );
  }

  Widget _folderList(ColorScheme cs) {
    if (_error.isNotEmpty) return _errorView(cs, _loadFolders);
    if (_folders.isEmpty) {
      return Center(child: Text(tr('这里还没有收藏夹')));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _folders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final d = _folders[i];
        final cover = '${d['cover'] ?? ''}';
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => _openFolder(d),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: cover.isEmpty
                        ? Container(color: cs.surfaceContainerHighest)
                        : biliCover(context, widget.ctx, cover, radius: 6),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${d['name'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('${d['count'] ?? 0} ${tr('个视频')}',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.outline),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _videoList(ColorScheme cs) {
    if (_items.isEmpty && _error.isNotEmpty) {
      return _errorView(cs, () => _loadList(1));
    }
    if (_items.isEmpty) return Center(child: Text(tr('这里还没有内容')));
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        if (i == _items.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : OutlinedButton(
                    onPressed: () => _loadList(_page + 1),
                    child: Text(tr('加载更多')),
                  ),
          );
        }
        final d = _items[i];
        return InkWell(
          onTap: () => _openVideo(i),
          onLongPress: () => openBiliVideo(context, widget.ctx, d),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 116,
                  height: 70,
                  child: biliCover(context, widget.ctx, '${d['cover'] ?? ''}',
                      radius: 6),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${d['title'] ?? ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 6),
                    Text(
                      '${d['owner'] ?? ''} · ${biliPlays(d['play'] is num ? d['play'] as num : null)} · ${biliDur(d['duration'] is num ? d['duration'] as num : null)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _errorView(ColorScheme cs, Future<void> Function() retry) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 36, color: cs.outline),
              const SizedBox(height: 10),
              Text(_error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: retry, child: Text(tr('重试'))),
            ],
          ),
        ),
      );
}

/// UP 主页：头像/简介/数据 + 投稿列表分页。
class BiliSpacePage extends StatefulWidget {
  const BiliSpacePage({super.key, required this.ctx, required this.mid});

  final BiliCtx ctx;
  final String mid;

  @override
  State<BiliSpacePage> createState() => _BiliSpacePageState();
}

class _BiliSpacePageState extends State<BiliSpacePage> {
  Map<String, dynamic>? _info;
  List<Map<String, dynamic>> _items = const [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load(true);
  }

  Future<void> _load(bool initial) async {
    setState(() {
      if (initial) _loading = true;
      _busy = !initial;
      _error = '';
    });
    final mid = Uri.encodeQueryComponent(widget.mid);
    // 个人资料与投稿列表互不依赖：并行拉，谁慢都不拖另一个
    final infoFuture = initial
        ? biliGet(widget.ctx, '/v1/bili/space/info?mid=$mid')
        : Future<Map<String, dynamic>?>.value(null);
    final listFuture = biliGet(
        widget.ctx, '/v1/bili/space/videos?mid=$mid&pn=${initial ? 1 : _page + 1}');
    final results = await Future.wait([infoFuture, listFuture]);
    if (!mounted) return;
    final infoJ = results[0];
    final listJ = results[1];

    if (initial &&
        infoJ != null &&
        infoJ['ok'] == true &&
        infoJ['info'] is Map) {
      setState(() =>
          _info = Map<String, dynamic>.from(infoJ['info'] as Map));
    }
    if (listJ == null || listJ['ok'] != true) {
      setState(() {
        _loading = false;
        _busy = false;
        _error = '${listJ?['error'] ?? tr('加载失败')}';
      });
      return;
    }
    final raw = (listJ['list'] as List?) ?? const [];
    final more = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    setState(() {
      _items = initial ? more : [..._items, ...more];
      _page = initial ? 1 : _page + 1;
      _hasMore = listJ['hasMore'] == true && more.isNotEmpty;
      _loading = false;
      _busy = false;
    });
  }

  void _openVideo(int i) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BiliSwipePage(
        ctx: widget.ctx,
        items: List<Map<String, dynamic>>.from(_items),
        initialIndex: i,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('UP 主页'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _load(true),
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _header(cs),
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _errorView(cs),
                  ],
                  const SizedBox(height: 12),
                  for (var i = 0; i < _items.length; i++) ...[
                    _videoRow(cs, _items[i], i),
                    const SizedBox(height: 8),
                  ],
                  if (_hasMore)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: _busy
                          ? const Center(child: CircularProgressIndicator())
                          : OutlinedButton(
                              onPressed: () => _load(false),
                              child: Text(tr('加载更多')),
                            ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _header(ColorScheme cs) {
    final d = _info ?? const {};
    final face = '${d['face'] ?? ''}';
    final sign = '${d['sign'] ?? ''}';
    String fmtNum(Object? v) {
      final n = v is num ? v.toInt() : 0;
      // 中文用「万」，其它语言用 K/M；数量单位不进翻译字典。
      if (I18n.instance.locale == 'zh') {
        if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
        if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
        return '$n';
      }
      if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
      if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
      return '$n';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 56,
              height: 56,
              child: face.isEmpty
                  ? Container(
                      color: cs.surfaceContainerHighest,
                      child: Icon(Icons.person, color: cs.outline))
                  : biliCover(context, widget.ctx, face, radius: 0),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${d['name'] ?? ''}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                if (sign.isNotEmpty)
                  Text(sign,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 14,
                  children: [
                    Text('${fmtNum(d['fans'])} ${tr('粉丝')}',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                    Text('${fmtNum(d['following'])} ${tr('关注')}',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                    Text('${fmtNum(d['videos'])} ${tr('投稿')}',
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
          if ((d['mid'] ?? '').toString().isNotEmpty)
            IconButton(
              tooltip: tr('收藏夹'),
              icon: const Icon(Icons.folder_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    BiliFavPage(ctx: widget.ctx, mid: '${d['mid']}'),
              )),
            ),
        ],
      ),
    );
  }

  Widget _videoRow(ColorScheme cs, Map<String, dynamic> d, int i) => InkWell(
        onTap: () => _openVideo(i),
        onLongPress: () => openBiliVideo(context, widget.ctx, d),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 116,
                height: 70,
                child: biliCover(context, widget.ctx, '${d['cover'] ?? ''}',
                    radius: 6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${d['title'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  Text(
                    '${biliPlays(d['play'] is num ? d['play'] as num : null)} · ${biliDur(d['duration'] is num ? d['duration'] as num : null)}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _errorView(ColorScheme cs) => Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: cs.outline),
          const SizedBox(width: 6),
          Expanded(
              child: Text(_error,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
          TextButton(onPressed: () => _load(true), child: Text(tr('重试'))),
        ],
      );
}
