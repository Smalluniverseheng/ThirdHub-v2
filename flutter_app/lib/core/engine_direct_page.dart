// 引擎直连 UI: 发现/选择/管理直连引擎 + 每模块发现页(连引擎的发现/搜索)
import 'dart:async';
import 'package:flutter/material.dart';
import 'discover.dart';
import 'engine_direct.dart';

// ═══ 连接管理页(我的 → 引擎直连) ═══
class EngineDirectPage extends StatefulWidget { const EngineDirectPage({super.key}); @override State<EngineDirectPage> createState() => _Ed(); }
class _Ed extends State<EngineDirectPage> {
  StreamSubscription? _sub; bool busy = false; String msg = '';
  @override void initState() { super.initState(); ThpDiscovery.start();
    _sub = ThpDiscovery.onChange.listen((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { _sub?.cancel(); super.dispose(); }

  Future<void> _connect(ThpDevice d) async {
    setState(() { busy = true; msg = ''; });
    try { await EngineDirect.connect(d.url);
      setState(() => msg = '✓ 已连接「${EngineDirect.name}」 ${EngineDirect.caps.join('/')}'); }
    catch (e) { setState(() => msg = '连接失败: $e'); }
    setState(() => busy = false);
  }

  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('引擎直连')),
    body: ListView(padding: const EdgeInsets.all(12), children: [
      const Text('不经过后端, 前端直接连接局域网引擎搜索与发现(THP 协议)', style: TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: 10),
      // 当前连接
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(EngineDirect.connected ? Icons.link : Icons.link_off, size: 18,
            color: EngineDirect.connected ? Colors.blueAccent : Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Text(EngineDirect.connected ? '已连接: ${EngineDirect.name}' : '未连接引擎',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
          if (EngineDirect.connected) TextButton(onPressed: () async { await EngineDirect.disconnect(); setState(() {}); },
            child: const Text('断开', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
        ]),
        if (EngineDirect.connected) ...[
          const SizedBox(height: 4),
          Text(EngineDirect.url, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [ for (final cap in EngineDirect.caps)
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Text(cap, style: const TextStyle(fontSize: 10, color: Colors.blueAccent))) ]),
        ],
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
          child: Text(msg, style: TextStyle(fontSize: 11, color: msg.startsWith('✓') ? Colors.green : Colors.redAccent))),
      ]))),
      const SizedBox(height: 10),
      Row(children: [ const Text('局域网发现的引擎', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const Spacer(),
        if (busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) ]),
      const SizedBox(height: 6),
      if (EngineDirect.available().isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Text('暂未发现引擎\n阅读引擎 / venera 引擎启动后会自动广播(THP UDP 19527)',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)))
      else
        for (final d in EngineDirect.available())
          Card(child: ListTile(
            leading: const Icon(Icons.extension, color: Colors.blueAccent),
            title: Text('${d.host}:${d.port}', style: const TextStyle(fontSize: 13)),
            subtitle: Text(d.caps.join(' / '), style: const TextStyle(fontSize: 10)),
            trailing: FilledButton.tonal(onPressed: busy ? null : () => _connect(d),
              child: Text(EngineDirect.url == d.url ? '已连接' : '连接', style: const TextStyle(fontSize: 12))),
          )),
    ]));
}

// ═══ 模块发现页: 连接引擎的发现(不支持时回落到热词搜索) ═══
// onOpen: 打开条目(模块自己决定进阅读器/播放器)
class EngineDiscoverView extends StatefulWidget {
  final String type; // novel/comic/video/music
  final void Function(Map<String, dynamic> item) onOpen;
  const EngineDiscoverView({super.key, required this.type, required this.onOpen});
  @override State<EngineDiscoverView> createState() => _Edv();
}
class _Edv extends State<EngineDiscoverView> {
  List<Map<String, dynamic>> items = []; bool loading = false; String err = ''; final q = TextEditingController();
  StreamSubscription? _sub;
  static const hotwords = {'novel': ['玄幻', '都市', '仙侠', '科幻'], 'comic': ['热血', '恋爱', '冒险', '搞笑'],
    'video': ['电影', '剧集', '动漫', '综艺'], 'music': ['流行', '民谣', '摇滚', '古风']};
  @override void initState() { super.initState(); _boot();
    // 发现到新引擎 / 引擎下线时刷新界面
    _sub = ThpDiscovery.onChange.listen((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { _sub?.cancel(); q.dispose(); super.dispose(); }
  Future<void> _boot() async {
    if (EngineDirect.connected) { _load(); return; }
    // 未连接: 自动连接局域网发现的第一个引擎, 连上后立即加载
    setState(() => loading = true);
    await EngineDirect.autoConnect();
    if (!mounted) return;
    setState(() => loading = false);
    if (EngineDirect.connected) _load();
  }
  Future<void> _connect(ThpDevice d) async {
    setState(() { loading = true; err = ''; });
    try { await EngineDirect.connect(d.url); _load(); return; }
    catch (e) { err = '连接失败: $e'; }
    if (mounted) setState(() => loading = false);
  }
  Future<void> _load() async {
    if (!EngineDirect.connected) return;
    setState(() { loading = true; err = ''; items = []; });
    try { items = await EngineDirect.discover(widget.type); }
    catch (_) { // 引擎不支持发现 → 热词搜索回落
      try { items = await EngineDirect.search(widget.type, (hotwords[widget.type] ?? ['热门']).first); }
      catch (e) { err = '$e'; }
    }
    if (mounted) setState(() => loading = false);
  }
  Future<void> _search(String k) async {
    if (!EngineDirect.connected || k.trim().isEmpty) return;
    setState(() { loading = true; err = ''; items = []; });
    try { items = await EngineDirect.search(widget.type, k.trim()); }
    catch (e) { err = '$e'; }
    if (mounted) setState(() => loading = false);
  }
  @override Widget build(BuildContext c) {
    if (!EngineDirect.connected) {
      final devs = EngineDirect.available();
      return Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.extension_off, size: 44, color: Colors.grey),
        const SizedBox(height: 12),
        Text(loading ? '正在自动连接引擎…' : '发现页需要先连接引擎', style: const TextStyle(color: Colors.grey)),
        if (loading) const Padding(padding: EdgeInsets.only(top: 12),
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        // 已发现但未连上的引擎: 直接一键连接
        if (!loading && devs.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Text('局域网发现的引擎', style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 6),
          for (final d in devs)
            Card(child: ListTile(dense: true,
              leading: const Icon(Icons.extension, size: 20, color: Colors.blueAccent),
              title: Text(d.name.isNotEmpty ? d.name : '${d.host}:${d.port}', style: const TextStyle(fontSize: 13)),
              subtitle: Text(d.caps.join(' / '), style: const TextStyle(fontSize: 10)),
              trailing: FilledButton.tonal(onPressed: () => _connect(d), child: const Text('连接', style: TextStyle(fontSize: 12))))),
        ],
        if (!loading && devs.isEmpty) ...[
          const SizedBox(height: 8),
          const Text('未发现引擎: 请确认引擎已启动并与本机在同一局域网\n(引擎启动后会自动广播 THP UDP 19527)',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
        const SizedBox(height: 12),
        FilledButton.tonal(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const EngineDirectPage())),
          child: const Text('引擎直连管理')),
      ])));
    }
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 4), child: Row(children: [
        Expanded(child: TextField(controller: q, decoration: const InputDecoration(hintText: '在引擎中搜索…', isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20))), contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
          onSubmitted: _search)),
        IconButton(icon: const Icon(Icons.search), onPressed: () => _search(q.text)),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(children: [
        Icon(Icons.circle, size: 8, color: Colors.green), const SizedBox(width: 4),
        Text(EngineDirect.name, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        const SizedBox(width: 10),
        for (final w in (hotwords[widget.type] ?? []))
          Padding(padding: const EdgeInsets.only(right: 6), child: ActionChip(label: Text(w, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact, onPressed: () { q.text = w; _search(w); })),
      ])),
      if (loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(child: err.isNotEmpty
        ? Center(child: Text('出错: $err', style: const TextStyle(color: Colors.redAccent, fontSize: 12)))
        : items.isEmpty ? Center(child: Text(loading ? '加载中…' : '暂无内容', style: const TextStyle(color: Colors.grey)))
        : GridView.builder(padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.62, crossAxisSpacing: 8, mainAxisSpacing: 8),
          itemCount: items.length, itemBuilder: (_, i) {
            final it = items[i];
            return GestureDetector(onTap: () => widget.onOpen(it), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8),
                child: (it['coverUrl'] ?? '') != '' ? Image.network(it['coverUrl'], fit: BoxFit.cover, width: double.infinity,
                  errorBuilder: (_, __, ___) => Container(color: Colors.grey.withValues(alpha: 0.2), child: const Icon(Icons.image_not_supported_outlined)))
                  : Container(color: Colors.grey.withValues(alpha: 0.2), child: const Icon(Icons.book_outlined)))),
              Padding(padding: const EdgeInsets.only(top: 4),
                child: Text('${it['name'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))),
            ]));
          })),
    ]);
  }
}
