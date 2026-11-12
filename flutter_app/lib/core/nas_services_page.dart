// 服务广场 —— 一个搜索框，把「本地有的」和「网上找的」一次搜完。
//
// 用户需求（2026-11-12）：
//   「搜索电影、搜索小说，当搜索的东西本地没有的时候，也自动搜索网络上的，
//     通过那些书源、音乐源去搜索。」
//
// 所以本页不再只调 /v1/gateway/search（那只有本地库），
// 而是调 **/v1/search/all** —— 后端那侧已经是「本地库 + 影视CMS源 + 书源 + 音源」
// 五路并行，一次返回：
//   locals  本地 Jellyfin / Navidrome
//   videos  网络影视源（CMS 采集接口，返回 JSON，源站换皮也不受影响）
//   books   网络书源（legado 规则）
//   comics  网络漫画源
//   musics  网络音源
//
// 设计约定：
//   · 自包含：只读 SharedPreferences 的 base/token，不依赖 Api/Cloud 内部状态
//   · 文案一律走 tr()，不硬编码中文（硬编码会让 i18n 扫描棘轮升高导致 CI 红）
//   · 播放复用已有 video_player/chewie（视频）与 just_audio（音乐），不新增依赖
//   · 本地条目后端已给 playUrl（代理地址）；网络影视条目要再问一次 detail 才拿得到播放地址

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';

import 'i18n.dart';

/// 一条统一媒体条目
class NasItem {
  final String id;
  final String title;
  final String subtitle;
  final String cover;
  final String kind; // movie | tv | music | novel | comic
  final String playUrl;
  final String serviceId;
  final String sourceId;
  const NasItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.kind,
    required this.playUrl,
    required this.serviceId,
    required this.sourceId,
  });

  /// 兼容三种来源的字段命名：
  ///   本地库（gateway）→ title / subtitle / cover / playUrl
  ///   网络影视（CMS）  → name / id / coverUrl
  ///   网络书籍（legado）→ name / author / coverUrl / bookUrl
  factory NasItem.fromJson(Map<String, dynamic> j, {String kindHint = ''}) {
    final rawCover = '${j['cover'] ?? j['coverUrl'] ?? ''}';
    return NasItem(
      id: '${j['id'] ?? j['bookUrl'] ?? ''}',
      title: '${j['title'] ?? j['name'] ?? ''}',
      subtitle: '${j['subtitle'] ?? j['author'] ?? ''}',
      cover: rawCover,
      kind: '${j['kind'] ?? kindHint}',
      playUrl: '${j['playUrl'] ?? ''}',
      serviceId: '${j['serviceId'] ?? j['source'] ?? ''}',
      sourceId: '${j['sourceId'] ?? ''}',
    );
  }
}

/// 一个来源分组
class NasGroup {
  final String serviceId;
  final String serviceName;
  final bool ok;
  final int latency;
  final String error;
  final bool isLocal;
  final List<NasItem> items;
  const NasGroup({
    required this.serviceId,
    required this.serviceName,
    required this.ok,
    required this.latency,
    required this.error,
    required this.isLocal,
    required this.items,
  });
}

class NasServicesPage extends StatefulWidget {
  const NasServicesPage({super.key});
  @override
  State<NasServicesPage> createState() => _NasServicesPageState();
}

class _NasServicesPageState extends State<NasServicesPage> {
  final _q = TextEditingController();
  bool _busy = false;
  String _err = '';
  List<NasGroup> _groups = <NasGroup>[];
  int _total = 0;
  String _token = '';
  String _base = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _primeConn());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _primeConn() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _base = (p.getString('base') ?? '').trim();
      _token = (p.getString('token') ?? '').trim();
      if (_base.isEmpty) {
        _err = tr('还没连上后端，请先到「我的后端」完成连接');
      }
    });
  }

  /// 把 search/all 的五个数组拍平成统一的分组列表（本地排最前）
  List<NasGroup> _flatten(Map<String, dynamic> d) {
    const order = <List<String>>[
      ['locals', 'local', ''],
      ['videos', 'net', 'video'],
      ['books', 'net', 'novel'],
      ['comics', 'net', 'comic'],
      ['musics', 'net', 'music'],
    ];
    final out = <NasGroup>[];
    for (final spec in order) {
      final key = spec[0];
      final isLocal = spec[1] == 'local';
      final hint = spec[2];
      final arr = (d[key] as List?) ?? const [];
      for (final g in arr) {
        if (g is! Map) continue;
        final rawItems = (g['items'] ?? g['books'] ?? const []) as List;
        final items = <NasItem>[];
        for (final it in rawItems) {
          if (it is Map) {
            items.add(NasItem.fromJson(
              Map<String, dynamic>.from(it),
              kindHint: hint.isNotEmpty ? hint : (isLocal ? 'movie' : ''),
            ));
          }
        }
        if (items.isEmpty) continue;
        out.add(NasGroup(
          serviceId: '${g['sourceId'] ?? g['serviceId'] ?? ''}',
          serviceName: '${g['source'] ?? g['serviceName'] ?? ''}',
          ok: g['ok'] != false,
          latency: (g['latency'] is num) ? (g['latency'] as num).toInt() : 0,
          error: '${g['error'] ?? ''}',
          isLocal: isLocal,
          items: items,
        ));
      }
    }
    return out;
  }

  Future<void> _search() async {
    final kw = _q.text.trim();
    if (kw.isEmpty) return;
    if (_base.isEmpty) {
      final p = await SharedPreferences.getInstance();
      _base = (p.getString('base') ?? '').trim();
      _token = (p.getString('token') ?? '').trim();
    }
    if (_base.isEmpty) {
      setState(() => _err = tr('还没连上后端，请先到「我的后端」完成连接'));
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
      _groups = <NasGroup>[];
      _total = 0;
    });
    try {
      // 一次搜全部：本地库 + 影视源 + 书源 + 漫画源 + 音源（后端并行，60s 内秒回缓存）
      final r = await http.get(
        Uri.parse('${_base}/v1/search/all?q=${Uri.encodeQueryComponent(kw)}'),
        headers: {'x-th-token': _token},
      ).timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) {
        setState(() => _err = '${tr('搜索失败')} (HTTP ${r.statusCode})');
        return;
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final d = (j is Map ? j['data'] : null);
      if (d is! Map) {
        setState(() => _err = tr('搜索返回格式不对'));
        return;
      }
      final groups = _flatten(Map<String, dynamic>.from(d));
      var tot = 0;
      for (final g in groups) {
        tot += g.items.length;
      }
      setState(() {
        _groups = groups;
        _total = tot;
        if (tot == 0) {
          _err = tr('本地和网络都没找到。影视源通常可用；书源/音源多数已过期，这部分还在修。');
        }
      });
    } catch (e) {
      setState(() => _err = '${tr('搜索失败')}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 网络影视条目没有现成播放地址，要点进去问一次详情
  Future<String> _resolvePlayUrl(NasItem it) async {
    if (it.playUrl.isNotEmpty) return it.playUrl;
    if (it.sourceId.isEmpty || it.id.isEmpty) return '';
    try {
      final r = await http.get(
        Uri.parse('${_base}/v1/video/detail?sourceId=${Uri.encodeQueryComponent(it.sourceId)}'
            '&id=${Uri.encodeQueryComponent(it.id)}'),
        headers: {'x-th-token': _token},
      ).timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return '';
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final d = (j is Map ? j['data'] : null);
      if (d is! Map) return '';
      final eps = (d['episodes'] ?? const []) as List;
      if (eps.isEmpty) return '';
      final first = eps.first;
      if (first is Map) return '${first['url'] ?? ''}';
      return '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _open(NasItem it) async {
    // 书 / 漫画：这一版只到「搜得到」，正文阅读走原有的书源阅读链路
    if (it.kind == 'novel' || it.kind == 'comic') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('书籍/漫画请在「书库」里打开阅读'))),
      );
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    final url = await _resolvePlayUrl(it);
    if (!mounted) return;
    setState(() => _busy = false);
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('这个条目暂时拿不到播放地址'))),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => it.kind == 'music'
          ? _MusicPlayerPage(item: it, url: url)
          : _VideoPlayerPage(item: it, url: url),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('服务广场'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: tr('搜电影、小说、音乐…'),
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _search,
                  child: Text(tr('搜索')),
                ),
              ],
            ),
          ),
          if (_err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_err,
                        style: TextStyle(color: cs.error, fontSize: 13)),
                  ),
                ],
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: CircularProgressIndicator(),
            ),
          Expanded(
            child: _groups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        tr('搜一个词试试。本地库(影视/音乐)有就直接出，没有再上网络源找。'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: _groups.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                          child: Text(
                            '${tr('共找到')} $_total ${tr('条')}',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                          ),
                        );
                      }
                      return _groupBlock(_groups[i - 1]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _groupBlock(NasGroup g) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              if (g.isLocal) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(tr('本地'),
                      style: TextStyle(fontSize: 10, color: cs.primary)),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(g.serviceName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Text(g.latency > 0 ? '${g.latency}ms' : '',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        SizedBox(
          height: 208,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: g.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (ctx, i) => _card(g.items[i]),
          ),
        ),
      ],
    );
  }

  Widget _card(NasItem it) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 124,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(it),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 160,
                width: 124,
                child: it.cover.isEmpty
                    ? Container(color: cs.surfaceContainerHighest)
                    : Image.network(
                        it.cover,
                        fit: BoxFit.cover,
                        headers:
                            _token.isEmpty ? null : {'x-th-token': _token},
                        errorBuilder: (_, __, ___) =>
                            Container(color: cs.surfaceContainerHighest),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(it.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500)),
            if (it.subtitle.isNotEmpty)
              Text(it.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// 视频播放页（本地走 gateway 代理，网络走源站直链）
class _VideoPlayerPage extends StatefulWidget {
  final NasItem item;
  final String url;
  const _VideoPlayerPage({required this.item, required this.url});
  @override
  State<_VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<_VideoPlayerPage> {
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
        httpHeaders: {'x-th-token': tok},
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
      appBar: AppBar(title: Text(widget.item.title)),
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
                    aspectRatio: _vp!.value.aspectRatio == 0
                        ? 16 / 9
                        : _vp!.value.aspectRatio,
                    child: Chewie(controller: _chewie!),
                  )),
      ),
    );
  }
}

/// 音乐播放页
class _MusicPlayerPage extends StatefulWidget {
  final NasItem item;
  final String url;
  const _MusicPlayerPage({required this.item, required this.url});
  @override
  State<_MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<_MusicPlayerPage> {
  final _player = AudioPlayer();
  String _err = '';
  String _token = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final tok = (p.getString('token') ?? '').trim();
      _token = tok;
      await _player.setUrl(widget.url, headers: {'x-th-token': tok});
      await _player.play();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('播放失败')}: $e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.item.title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.item.cover.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(widget.item.cover,
                      width: 220,
                      height: 220,
                      fit: BoxFit.cover,
                      headers:
                          _token.isEmpty ? null : {'x-th-token': _token},
                      errorBuilder: (_, __, ___) => SizedBox(
                          width: 220,
                          height: 220,
                          child: Container(color: cs.surfaceContainerHighest))),
                ),
              const SizedBox(height: 24),
              Text(widget.item.title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              if (widget.item.subtitle.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(widget.item.subtitle,
                    style: TextStyle(color: cs.onSurfaceVariant)),
              ],
              const SizedBox(height: 32),
              if (_err.isNotEmpty)
                Text(_err, style: TextStyle(color: cs.error, fontSize: 13))
              else
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (ctx, snap) {
                    final playing = snap.data?.playing ?? false;
                    return IconButton.filled(
                      iconSize: 40,
                      onPressed: () => playing ? _player.pause() : _player.play(),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
