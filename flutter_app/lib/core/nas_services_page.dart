// 服务广场 —— 在 App 里直接使用 NAS 上的所有第三方能力，不用跳出去打开别的应用。
//
// 它解决的问题（2026-11-11 用户需求）：
//   「直接调用并集成第三方的各类功能（相当于通过 API 接口统一调用这些能力），
//     让用户无需点进对应应用即可在我这边使用这些功能。」
//
// 怎么做到的：
//   后端 /v1/gateway/* 把 Jellyfin（影视）、Navidrome（音乐）等统一成一个接口，
//   并且把封面、媒体流都做了**代理**（/v1/gateway/img、/v1/gateway/stream）。
//   所以本页只需要连 NAS 一个地址，就能搜索 + 直接播放，不需要知道后面是谁。
//
// 设计约定：
//   · 自包含：只读 SharedPreferences 里的 base/token，不依赖 Api/Cloud 的内部状态，
//     这样即使那两处以后改签名，这一页也不会跟着坏。
//   · 文案一律走 tr()，不硬编码中文（硬编码会让 i18n 扫描棘轮升高导致 CI 红）。
//   · 播放复用项目已有的 video_player/chewie（视频）与 just_audio（音乐），不新增依赖。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:just_audio/just_audio.dart';

import 'i18n.dart';

/// 一条统一媒体条目（后端 gateway 的返回结构）
class NasItem {
  final String id;
  final String title;
  final String subtitle;
  final String cover;
  final String kind; // movie | tv | music | book | comic
  final String playUrl;
  final String serviceId;
  const NasItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.kind,
    required this.playUrl,
    required this.serviceId,
  });

  factory NasItem.fromJson(Map<String, dynamic> j) {
    return NasItem(
      id: '${j['id'] ?? ''}',
      title: '${j['title'] ?? ''}',
      subtitle: '${j['subtitle'] ?? ''}',
      cover: '${j['cover'] ?? ''}',
      kind: '${j['kind'] ?? ''}',
      playUrl: '${j['playUrl'] ?? ''}',
      serviceId: '${j['serviceId'] ?? j['source'] ?? ''}',
    );
  }
}

/// 一个服务分组
class NasGroup {
  final String serviceId;
  final String serviceName;
  final bool ok;
  final int latency;
  final String error;
  final List<NasItem> items;
  const NasGroup({
    required this.serviceId,
    required this.serviceName,
    required this.ok,
    required this.latency,
    required this.error,
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
  /// 当前令牌：封面图走 /v1/gateway/img 也需要它，Image.network 得带上请求头
  String _token = '';

  @override
  void initState() {
    super.initState();
    // 进来先看服务清单，让用户知道现在有哪些能用
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadServices());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<({String base, String token})> _conn() async {
    final p = await SharedPreferences.getInstance();
    return (
      base: (p.getString('base') ?? '').trim(),
      token: (p.getString('token') ?? '').trim(),
    );
  }

  Future<void> _loadServices() async {
    final c = await _conn();
    if (c.base.isEmpty) {
      setState(() => _err = tr('还没连上后端，请先到「我的后端」完成连接'));
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
      _token = c.token;
    });
    try {
      final r = await http.get(
        Uri.parse('${c.base}/v1/gateway/services?refresh=1'),
        headers: {'x-th-token': c.token},
      ).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        setState(() => _err = tr('服务清单读取失败') + '(HTTP ${r.statusCode})');
      } else {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        final rows = (j is Map ? j['data'] : null) as List? ?? [];
        final online = rows.where((e) => e is Map && e['online'] == true).length;
        setState(() => _err = '');
        if (mounted && online > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${tr('在线服务')}: $online / ${rows.length}')),
          );
        }
      }
    } catch (e) {
      setState(() => _err = tr('连不上后端') + ': $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search() async {
    final kw = _q.text.trim();
    if (kw.isEmpty) return;
    final c = await _conn();
    if (c.base.isEmpty) {
      setState(() => _err = tr('还没连上后端，请先到「我的后端」完成连接'));
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
      _groups = <NasGroup>[];
      _total = 0;
      _token = c.token;
    });
    try {
      final r = await http.get(
        Uri.parse('${c.base}/v1/gateway/search?q=${Uri.encodeQueryComponent(kw)}'),
        headers: {'x-th-token': c.token},
      ).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        setState(() => _err = tr('搜索失败') + '(HTTP ${r.statusCode})');
        return;
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final data = (j is Map ? j['data'] : null) as List? ?? [];
      final meta = (j is Map ? j['meta'] : null) as Map? ?? {};
      final out = <NasGroup>[];
      for (final g in data) {
        if (g is! Map) continue;
        final items = <NasItem>[];
        for (final it in ((g['items'] as List?) ?? const [])) {
          if (it is Map) items.add(NasItem.fromJson(Map<String, dynamic>.from(it)));
        }
        out.add(NasGroup(
          serviceId: '${g['serviceId'] ?? ''}',
          serviceName: '${g['serviceName'] ?? g['serviceId'] ?? ''}',
          ok: g['ok'] == true,
          latency: (g['latency'] is num) ? (g['latency'] as num).toInt() : 0,
          error: '${g['error'] ?? ''}',
          items: items,
        ));
      }
      setState(() {
        _groups = out;
        _total = (meta['total'] is num) ? (meta['total'] as num).toInt() : 0;
      });
    } catch (e) {
      setState(() => _err = tr('搜索失败') + ': $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(NasItem it) {
    if (it.playUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('这个条目没有可播放的地址'))),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => it.kind == 'music'
          ? _MusicPlayerPage(item: it)
          : _VideoPlayerPage(item: it),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('服务广场')),
        actions: [
          IconButton(
            tooltip: tr('刷新服务状态'),
            onPressed: _busy ? null : _loadServices,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
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
                      hintText: tr('搜影视、音乐…'),
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
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(),
            ),
          Expanded(
            child: _groups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        tr('输入关键词搜索。结果来自你 NAS 上的影视库与音乐库，点一下就能在这里直接播放，不用跳出去。'),
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
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
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
              Text(g.serviceName,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text(
                g.ok ? '${g.latency}ms' : (g.error.isEmpty ? tr('失败') : g.error),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (g.items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tr('这个服务没有结果'),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          )
        else
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
                        // 封面走本站代理，需要带令牌（只读令牌即可看图）
                        headers: _token.isEmpty ? null : {'x-th-token': _token},
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

/// 视频播放页（走 /v1/gateway/stream 代理，支持拖动）
class _VideoPlayerPage extends StatefulWidget {
  final NasItem item;
  const _VideoPlayerPage({required this.item});
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
      // 流地址由后端给（已是代理地址）；把令牌放请求头，URL 里不出现密钥
      final uri = Uri.parse(widget.item.playUrl);
      _vp = VideoPlayerController.networkUrl(
        uri,
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
  const _MusicPlayerPage({required this.item});
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
      await _player.setUrl(widget.item.playUrl,
          headers: {'x-th-token': tok});
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
