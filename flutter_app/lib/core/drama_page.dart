// 红果短剧（4.81.94）——个人授权使用，管理员或激活码解锁。
//
// 数据源：openhongguo Flutter SDK（Go 原生库，匿名设备，无需登录红果账号）。
// 播放：media_kit 支持 CENC-AES-CTR 解密（contentKey 由 SDK 本地推导）。
// 门控：DramaGate —— 管理员账号或本地激活码二选一。
//
// 合规：不做内容分发、不内置片源、不提供下载，仅播放 SDK 返回的公开流。
import 'package:flutter/material.dart';
import 'package:openhongguo/openhongguo.dart';

import 'design_tokens.dart';
import 'drama_gate.dart';
import 'drama_player.dart';
import 'i18n.dart';

class DramaPage extends StatefulWidget {
  const DramaPage({super.key});

  @override
  State<DramaPage> createState() => _DramaPageState();
}

class _DramaPageState extends State<DramaPage> {
  bool _unlocked = false;
  final TextEditingController _codeCtrl = TextEditingController();
  String _codeErr = '';

  OpenhongguoClient? _client;
  int _tab = 0; // 0 发现 1 搜索
  final TextEditingController _searchCtrl = TextEditingController();
  List<SeriesSummary> _series = const [];
  String _err = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await DramaGate.I.load();
    if (!mounted) return;
    setState(() => _unlocked = DramaGate.I.unlocked);
    if (_unlocked) _initClient();
  }

  Future<void> _initClient() async {
    if (_client != null) return;
    try {
      _client = await OpenhongguoClient.create(const ClientOptions());
      await _discover();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  Future<void> _activate() async {
    final ok = await DramaGate.I.tryActivate(_codeCtrl.text);
    if (!mounted) return;
    if (ok) {
      setState(() => _unlocked = true);
      _initClient();
    } else {
      setState(() => _codeErr = tr('激活码不正确'));
    }
  }

  Future<void> _discover() async {
    final c = _client;
    if (c == null) return;
    setState(() => _loading = true);
    try {
      final page = await c.discover();
      if (!mounted) return;
      setState(() {
        _series = page.items;
        _err = '';
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _err = '$e'; _loading = false; });
    }
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty || _client == null) return;
    setState(() => _loading = true);
    try {
      final page = await _client!.search(q);
      if (!mounted) return;
      setState(() {
        _series = page.items;
        _err = '';
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _err = '$e'; _loading = false; });
    }
  }

  void _openSeries(SeriesSummary s) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DramaDetailPage(series: s, client: _client!)),
    );
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) return _gateView();
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('短剧')),
        bottom: TabBar(
          onTap: (i) => setState(() => _tab = i),
          tabs: [
            Tab(text: tr('发现')),
            Tab(text: tr('搜索')),
          ],
        ),
      ),
      body: _tab == 0 ? _discoverView() : _searchView(),
    );
  }

  Widget _gateView() => Scaffold(
        appBar: AppBar(title: Text(tr('短剧'))),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.lock_outline,
                        size: 48, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 14),
                    Text(tr('短剧功能'),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(tr('此功能仅对个人授权使用。管理员账号自动解锁；其他用户可输入激活码。'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, height: 1.6)),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _codeCtrl,
                      decoration: InputDecoration(
                        labelText: tr('激活码'),
                        border: const OutlineInputBorder(),
                        errorText: _codeErr.isEmpty ? null : _codeErr,
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: _activate,
                      child: Text(tr('解锁')),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _discoverView() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_err, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _discover, child: Text(tr('重试'))),
          ]),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(Gap.sm),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 8,
        mainAxisSpacing: 12,
      ),
      itemCount: _series.length,
      itemBuilder: (c, i) => _seriesCard(_series[i]),
    );
  }

  Widget _searchView() => Column(children: [
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: tr('搜索短剧'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _search, child: Text(tr('搜索'))),
          ]),
        ),
        Expanded(child: _discoverView()),
      ]);

  Widget _seriesCard(SeriesSummary s) => GestureDetector(
        onTap: () => _openSeries(s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: s.coverUrl.isEmpty
                    ? Container(color: Colors.grey.shade300)
                    : Image.network(
                        s.coverUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, __, ___) =>
                            Container(color: Colors.grey.shade300),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            Text(s.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            Text('${s.episodeCount} ${tr('集')}',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      );
}

// ── 剧集详情 + 选集 ──
class DramaDetailPage extends StatefulWidget {
  const DramaDetailPage({super.key, required this.series, required this.client});

  final SeriesSummary series;
  final OpenhongguoClient client;

  @override
  State<DramaDetailPage> createState() => _DramaDetailPageState();
}

class _DramaDetailPageState extends State<DramaDetailPage> {
  List<Episode> _episodes = const [];
  bool _loading = true;
  String _err = '';
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await widget.client.listEpisodes(widget.series.id);
      if (!mounted) return;
      setState(() {
        _episodes = page.items;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _err = '$e'; _loading = false; });
    }
  }

  Future<void> _play(int idx) async {
    if (idx < 0 || idx >= _episodes.length) return;
    final ep = _episodes[idx];
    setState(() => _current = idx);
    try {
      final r = await widget.client.resolvePlayback(ep.id);
      final pb = r.playback;
      if (pb.streams.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('这一集暂时拿不到播放地址'))),
          );
        }
        return;
      }
      // 选码率最高的流
      final stream = pb.streams.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DramaPlayerPage(
            url: stream.url,
            audioUrl: pb.audioUrl,
            decryptionKey: r.contentKey?.key ?? '',
            title: '${widget.series.title} · ${ep.title}',
            onNext: idx + 1 < _episodes.length ? () {
              Navigator.pop(context);
              _play(idx + 1);
            } : null,
            onPrev: idx > 0 ? () {
              Navigator.pop(context);
              _play(idx - 1);
            } : null,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('播放失败')}：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.series.title,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(child: Text(_err))
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Row(children: [
                      SizedBox(
                        width: 90,
                        height: 120,
                        child: widget.series.coverUrl.isEmpty
                            ? Container(color: Colors.grey.shade300)
                            : Image.network(widget.series.coverUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Container(color: Colors.grey.shade300)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.series.title,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Text('${_episodes.length} ${tr('集')}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                            if (widget.series.description.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(widget.series.description,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                    child: Row(children: [
                      Text(tr('选集'),
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(Gap.md),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        mainAxisExtent: 44,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: _episodes.length,
                      itemBuilder: (c, i) => OutlinedButton(
                        onPressed: () => _play(i),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: i == _current
                              ? Theme.of(context).colorScheme.primaryContainer
                              : null,
                          padding: EdgeInsets.zero,
                        ),
                        child: Text('${_episodes[i].number}',
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                  ),
                ]),
    );
  }
}
