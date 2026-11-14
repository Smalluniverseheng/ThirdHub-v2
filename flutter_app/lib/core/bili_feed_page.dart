// B 站浏览页（4.81.66 新增）
//
// 为什么单开一个文件：bili_down_page.dart 已经有 28KB，往里塞列表容易碰坏下载流程。
// 这里只做「浏览 + 播放」，接口全部走 NAS 后端（App 不直连 B 站）：
//   GET /v1/bili/feed?type=popular|recommend&ps=&pn=   热门/推荐
//   GET /v1/bili/search?q=&pn=                         搜索
//   GET /v1/bili/pages?bvid=                           分P（拿 cid）
//   GET /v1/bili/playurl?bvid=&cid=                    播放直链（后端已过媒体代理，带 Referer）
// 直链是 http://<nas>:9528/... ，播放器只带 x-th-token 即可。
import 'dart:async';
import 'dart:convert';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'design_tokens.dart';
import 'i18n.dart';

class BiliFeedPage extends StatefulWidget {
  const BiliFeedPage({super.key});

  @override
  State<BiliFeedPage> createState() => _BiliFeedPageState();
}

class _BiliFeedPageState extends State<BiliFeedPage> {
  final _q = TextEditingController();
  String _base = '';
  String _token = '';
  String _kind = 'popular';
  bool _loading = true;
  String _err = '';
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Map<String, String> get _h => _token.isEmpty ? const {} : {'x-th-token': _token};

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    _base = (p.getString('base') ?? '').trim();
    _token = (p.getString('token') ?? '').trim();
    if (_base.isEmpty) {
      setState(() {
        _loading = false;
        _err = tr('还没连上后端，请先到「我的后端」完成连接');
      });
      return;
    }
    await _load();
  }

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final r = await http
          .get(Uri.parse('$_base$path'), headers: _h)
          .timeout(const Duration(seconds: 30));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    final q = _query.trim();
    final path = q.isEmpty
        ? '/v1/bili/feed?type=$_kind&ps=20&pn=1'
        : '/v1/bili/search?q=${Uri.encodeQueryComponent(q)}&pn=1';
    final j = await _get(path);
    if (!mounted) return;
    if (j == null) {
      setState(() {
        _loading = false;
        _err = tr('失败');
      });
      return;
    }
    if (j['ok'] != true) {
      setState(() {
        _loading = false;
        _err = '${j['message'] ?? ''}'.trim().isEmpty ? tr('失败') : '${j['message']}';
      });
      return;
    }
    final list = (j['items'] as List?) ?? const [];
    setState(() {
      _items = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      _loading = false;
    });
  }

  Future<void> _open(Map<String, dynamic> it) async {
    final bvid = '${it['bvid'] ?? ''}';
    if (bvid.isEmpty) return;
    final title = '${it['title'] ?? ''}';
    final j = await _get('/v1/bili/pages?bvid=${Uri.encodeQueryComponent(bvid)}');
    if (!mounted) return;
    if (j == null || j['ok'] != true) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('失败'))));
      return;
    }
    final pages = ((j['pages'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    if (pages.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('失败'))));
      return;
    }
    if (pages.length == 1) {
      await _play(bvid, '${pages.first['cid']}', title);
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: pages.length,
          itemBuilder: (c, i) {
            final p = pages[i];
            final n = (p['page'] is int) ? p['page'] as int : (i + 1);
            final part = '${p['part'] ?? ''}';
            return ListTile(
              title: Text(trf('第{n}集', {'n': n})),
              subtitle: part.isEmpty ? null : Text(part),
              onTap: () => Navigator.of(c).pop(p),
            );
          },
        ),
      ),
    );
    if (picked == null) return;
    await _play(bvid, '${picked['cid']}', title);
  }

  Future<void> _play(String bvid, String cid, String title) async {
    final j = await _get(
        '/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(bvid)}&cid=${Uri.encodeQueryComponent(cid)}');
    if (!mounted) return;
    final url = (j == null) ? '' : '${j['url'] ?? ''}';
    if (url.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('播放失败'))));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BiliPlayerPage(title: title, url: url),
    ));
  }

  String _dur(num? s) {
    final t = (s ?? 0).toInt();
    if (t <= 0) return '';
    final m = t ~/ 60;
    final sec = t % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  String _plays(num? n) {
    final v = (n ?? 0).toInt();
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}w';
    return '$v';
  }

  Widget _cover(String raw, {required double radius}) {
    final u = raw.trim();
    if (u.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
      );
    }
    final full = u.startsWith('http')
        ? u
        : '$_base/v1/bili/cover?u=${Uri.encodeQueryComponent(u)}';
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        full,
        headers: _h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(Icons.broken_image_outlined,
              color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('B站')),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: tr('搜索'),
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md)),
              ),
              onSubmitted: (v) {
                _query = v;
                _load();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
            child: Row(
              children: [
                ChoiceChip(
                  label: Text(tr('热门')),
                  selected: _query.trim().isEmpty && _kind == 'popular',
                  onSelected: (_) {
                    _query = '';
                    _q.clear();
                    _kind = 'popular';
                    _load();
                  },
                ),
                const SizedBox(width: Gap.sm),
                ChoiceChip(
                  label: Text(tr('推荐')),
                  selected: _query.trim().isEmpty && _kind == 'recommend',
                  onSelected: (_) {
                    _query = '';
                    _q.clear();
                    _kind = 'recommend';
                    _load();
                  },
                ),
              ],
            ),
          ),
          Expanded(child: _body(cs)),
        ],
      ),
    );
  }

  Widget _body(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_err, style: TextStyle(color: cs.error)),
            const SizedBox(height: Gap.sm),
            OutlinedButton(onPressed: _load, child: Text(tr('重试'))),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text(tr('没搜到，换个词试试')));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(Gap.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: Gap.md,
        crossAxisSpacing: Gap.md,
        childAspectRatio: 0.78,
      ),
      itemCount: _items.length,
      itemBuilder: (c, i) {
        final it = _items[i];
        final title = '${it['title'] ?? ''}';
        final owner = '${it['owner'] ?? ''}';
        final dur = _dur(it['duration'] is num ? it['duration'] as num : null);
        final play = _plays(it['play'] is num ? it['play'] as num : null);
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => _open(it),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _cover('${it['coverRaw'] ?? it['cover'] ?? ''}', radius: Radii.md),
                    if (dur.isNotEmpty)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(dur,
                              style: const TextStyle(color: Colors.white, fontSize: 11)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 1.25),
              ),
              const SizedBox(height: 2),
              Text(
                play.isEmpty ? owner : '$owner · $play',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
            ],
          ),
        );
      },
    );
  }
}

class BiliPlayerPage extends StatefulWidget {
  final String title;
  final String url;
  const BiliPlayerPage({required this.title, required this.url});

  @override
  State<BiliPlayerPage> createState() => _BiliPlayerPageState();
}

class _BiliPlayerPageState extends State<BiliPlayerPage> {
  VideoPlayerController? _vp;
  ChewieController? _chewie;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final tok = (p.getString('token') ?? '').trim();
      _vp = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
        httpHeaders: tok.isEmpty ? const {} : {'x-th-token': tok},
      );
      await _vp!.initialize();
      _chewie = ChewieController(
        videoPlayerController: _vp!,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: Theme.of(context).colorScheme.primary,
          handleColor: Theme.of(context).colorScheme.primary,
        ),
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('播放失败')}: $e');
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _vp?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      backgroundColor: Colors.black,
      body: Center(
        child: _err.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_err, style: const TextStyle(color: Colors.white70)),
              )
            : (_chewie == null
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio:
                        _vp!.value.aspectRatio == 0 ? 16 / 9 : _vp!.value.aspectRatio,
                    child: Chewie(controller: _chewie!),
                  )),
      ),
    );
  }
}
