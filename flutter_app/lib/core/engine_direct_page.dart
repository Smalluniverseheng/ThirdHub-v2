// 引擎直连 UI: 发现/选择/管理直连引擎 + 每模块发现页(连引擎的发现/搜索)
//
// ★ 2026-09-19 修复「连上了却显示未连接引擎 / 状态变化特别慢」：
//   本页与发现页改为订阅 EngineDirect.state(ValueNotifier)，
//   连接状态一变化立即重建；并显示失败原因（含明文 HTTP 被系统拦截的提示）。
import 'dart:async';
import 'package:flutter/material.dart';
import 'discover.dart';
import 'engine_direct.dart';

// ═══ 连接管理页(我的 → 引擎直连) ═══
class EngineDirectPage extends StatefulWidget {
  const EngineDirectPage({super.key});
  @override State<EngineDirectPage> createState() => _Ed();
}

class _Ed extends State<EngineDirectPage> {
  StreamSubscription? _sub;
  bool busy = false;
  String msg = '';
  @override void initState() {
    super.initState();
    ThpDiscovery.start();
    _sub = ThpDiscovery.onChange.listen((_) { if (mounted) setState(() {}); });
  }
  @override void dispose() { _sub?.cancel(); super.dispose(); }

  Future<void> _connect(ThpDevice d) async {
    setState(() { busy = true; msg = ''; });
    try {
      await EngineDirect.connect(d.url);
      setState(() => msg = '✓ 已连接「${EngineDirect.name}」');
    } catch (e) {
      // connect() 已把原因写进 state.message，这里只补充动作提示
      setState(() => msg = '连接失败：${EngineDirect.lastError}');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _retry() async {
    setState(() { busy = true; msg = ''; });
    await EngineDirect.retry();
    if (mounted) setState(() { busy = false; msg = EngineDirect.connected ? '✓ 已重新连接' : ''; });
  }

  /// 主动扫描（不依赖广播）。★覆盖广播必失效的四种环境：
  /// IPv6 单栈 / AP 隔离 / 引擎被 Doze 挂起 / 引擎就在本机。
  Future<void> _scan() async {
    setState(() { busy = true; msg = '正在扫描本机与局域网…'; });
    try {
      final hits = await ThpDiscovery.scan(subnetSweep: true, onProgress: (d, t) {
        if (mounted && d % 32 == 0) setState(() => msg = '正在扫描…（$d/$t）');
      });
      if (!mounted) return;
      setState(() { busy = false;
        msg = hits.isEmpty
          ? '扫描完成：${ThpDiscovery.lastScanProbed} 个探针 / ${ThpDiscovery.lastScanMs}ms，未发现 THP 服务'
          : '✓ 发现 ${hits.length} 个：${hits.map((d) => '${d.host}:${d.port}').join('、')}'; });
    } catch (e) {
      if (mounted) setState(() { busy = false; msg = '扫描失败：$e'; });
    }
  }

  /// 手动填地址。★为什么必须有：IPv6-only 网络、AP 隔离、引擎被 Doze 挂起广播时，
  /// 自动发现全线失效，但**用户知道地址**就能直连 —— 这是最后的兜底通路。
  Future<void> _manual() async {
    final ctl = TextEditingController(text: EngineDirect.url.isNotEmpty
        ? EngineDirect.url.replaceFirst(RegExp(r'^https?://'), '')
        : '');
    final input = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: const Text('手动填写引擎地址', style: TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: ctl, autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '例：192.168.1.5  或  [240e::1]:1234',
            helperText: '省略端口默认 1234（引擎）',
            helperStyle: TextStyle(fontSize: 11),
            isDense: true)),
        const SizedBox(height: 8),
        const Text('引擎 App 的「关于」页会显示本机地址；也可在路由器 DHCP 列表里找。',
          style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('连接')),
      ]));
    if (input == null || input.trim().isEmpty) return;
    setState(() { busy = true; msg = ''; });
    final err = await EngineDirect.connectManual(input);
    if (!mounted) return;
    setState(() { busy = false;
      msg = err == null ? '✓ 已连接「${EngineDirect.name}」' : '连接失败：$err'; });
  }

  /// 一键自检：把「连不上/搜不到」从玄学变成可读结论。
  /// 逐项判定 网络→服务→数据(源)，失败项直接给出修复指引。
  Future<void> _diag() async {
    setState(() { busy = true; msg = ''; });
    List<DiagItem> items;
    try {
      items = await EngineDirect.diagnose();
    } catch (e) {
      items = [DiagItem('自检异常', false, '$e')];
    }
    if (!mounted) return;
    setState(() => busy = false);
    await showModalBottomSheet(context: context, isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(expand: false,
        initialChildSize: 0.62, maxChildSize: 0.92, minChildSize: 0.35,
        builder: (c, sc) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          controller: sc, children: [
            Row(children: [
              const Text('连接自检', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              Text('${items.where((i) => i.ok).length}/${items.length} 通过',
                style: TextStyle(fontSize: 12,
                  color: items.every((i) => i.ok) ? Colors.green : Colors.orangeAccent)),
            ]),
            const SizedBox(height: 4),
            const Text('从网络层到数据层逐项检查；标红的那一项就是该修的地方。',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 12),
            for (final it in items) Card(margin: const EdgeInsets.only(bottom: 8),
              child: Padding(padding: const EdgeInsets.all(12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(it.ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 18, color: it.ok ? Colors.green : Colors.redAccent),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(it.detail, style: TextStyle(fontSize: 11, height: 1.5,
                      color: it.ok ? Colors.grey : Colors.redAccent)),
                  ])),
                ]))),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () { Navigator.pop(c); _manual(); },
                icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
                label: const Text('手动填地址', style: TextStyle(fontSize: 12)))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(
                onPressed: () { Navigator.pop(c); _retry(); },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新连接', style: TextStyle(fontSize: 12)))),
            ]),
          ])));
  }

  Color _c(EngineStatus st) => switch (st) {
    EngineStatus.connected => Colors.green,
    EngineStatus.connecting => Colors.orangeAccent,
    EngineStatus.failed => Colors.redAccent,
    EngineStatus.idle => Colors.grey,
  };
  IconData _i(EngineStatus st) => switch (st) {
    EngineStatus.connected => Icons.link,
    EngineStatus.connecting => Icons.sync,
    EngineStatus.failed => Icons.link_off,
    EngineStatus.idle => Icons.link_off,
  };
  String _t(EngineState s) => switch (s.status) {
    EngineStatus.connected => '已连接：${s.name}',
    EngineStatus.connecting => '正在连接引擎…',
    EngineStatus.failed => s.url.isEmpty ? '未连接引擎' : '引擎离线：${s.name}',
    EngineStatus.idle => '未连接引擎',
  };

  @override Widget build(BuildContext c) =>
    ValueListenableBuilder<EngineState>(
      valueListenable: EngineDirect.state,
      builder: (c, st, _) => Scaffold(
        appBar: AppBar(title: const Text('引擎直连'),
          actions: [ IconButton(icon: const Icon(Icons.refresh, size: 20),
            tooltip: '重新探测/连接', onPressed: busy ? null : _retry) ]),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          const Text('不经过后端, 前端直接连接局域网引擎搜索与发现(THP 协议)',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 10),
          // 当前连接
          Card(child: Padding(padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(_i(st.status), size: 18, color: _c(st.status)),
                const SizedBox(width: 8),
                Expanded(child: Text(_t(st),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                if (st.url.isNotEmpty) TextButton(
                  onPressed: () async { await EngineDirect.disconnect(); setState(() {}); },
                  child: const Text('断开', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
              ]),
              if (st.url.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(st.url, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
              if (st.caps.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: [ for (final cap in st.caps)
                  Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10)),
                    child: Text(cap, style: const TextStyle(fontSize: 10, color: Colors.blueAccent))) ]),
              ],
              // 失败/进行中的可读原因（旧版把原因吞掉，只显示"未连接"，无从排查）
              if (st.message.isNotEmpty && st.status != EngineStatus.connected)
                Padding(padding: const EdgeInsets.only(top: 8),
                  child: Container(width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _c(st.status).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8)),
                    child: Text(st.message,
                      style: TextStyle(fontSize: 11, color: _c(st.status), height: 1.5)))),
              if (st.status == EngineStatus.failed)
                Padding(padding: const EdgeInsets.only(top: 8),
                  child: Align(alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(onPressed: busy ? null : _retry,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重试连接', style: TextStyle(fontSize: 12))))),
              if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
                child: Text(msg, style: TextStyle(fontSize: 11,
                  color: msg.startsWith('✓') ? Colors.green : Colors.redAccent))),
            ]))),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: busy ? null : _manual,
              icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
              label: const Text('手动填地址', style: TextStyle(fontSize: 12)))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(
              onPressed: busy ? null : _diag,
              icon: const Icon(Icons.health_and_safety_outlined, size: 16),
              label: const Text('一键自检', style: TextStyle(fontSize: 12)))),
          ]),
          const SizedBox(height: 10),
          Row(children: [ const Text('发现的引擎（广播 + 主动扫描）', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const Spacer(),
            if (busy) const SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)) ]),
          const SizedBox(height: 6),
          if (EngineDirect.available().isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Column(children: [
              const Text('暂未发现引擎',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              const Text('引擎 App 启动后会广播(THP UDP 19527)；\n'
                  '若广播被网络环境屏蔽，点下面「主动扫描」直连探测：',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.5)),
              const SizedBox(height: 10),
              OutlinedButton.icon(onPressed: busy ? null : _scan,
                icon: const Icon(Icons.radar, size: 16),
                label: const Text('主动扫描本机与局域网', style: TextStyle(fontSize: 12))),
            ]))
          else
            for (final d in EngineDirect.available())
              Card(child: ListTile(
                leading: Icon(Icons.extension, color: _c(EngineStatus.connected)),
                title: Text('${d.host}:${d.port}', style: const TextStyle(fontSize: 13)),
                subtitle: Text(d.caps.join(' / '), style: const TextStyle(fontSize: 10)),
                trailing: FilledButton.tonal(onPressed: busy ? null : () => _connect(d),
                  child: Text(EngineDirect.url == d.url ? '已连接' : '连接',
                    style: const TextStyle(fontSize: 12))),
              )),
        ]))); 
}

// ═══ 模块发现页: 同步引擎的发现页(书源分组+分类标签), 点标签加载该分类的书籍列表 ═══
// onOpen: 打开条目(模块自己决定进阅读器/播放器)
class EngineDiscoverView extends StatefulWidget {
  final String type; // novel/comic/video/music
  final void Function(Map<String, dynamic> item) onOpen;
  const EngineDiscoverView({super.key, required this.type, required this.onOpen});
  @override State<EngineDiscoverView> createState() => _Edv();
}

class _Edv extends State<EngineDiscoverView> {
  List<Map<String, dynamic>> items = [];
  bool loading = false;
  String err = '';
  final q = TextEditingController();
  StreamSubscription? _disc;
  bool _connHooked = false;
  // 发现结构: 引擎各书源的分类标签(engine-v1.3.0+); 空=旧引擎不支持, 回落热词搜索
  List<Map<String, dynamic>> sources = [];
  String selSource = '';
  String selTag = '';
  int page = 1;
  bool hasMore = false;
  bool searching = false;
  String notice = '';
  static const hotwords = {
    'novel': ['玄幻', '都市', '仙侠', '科幻'],
    'comic': ['热血', '恋爱', '冒险', '搞笑'],
    'video': ['电影', '剧集', '动漫', '综艺'],
    'music': ['流行', '民谣', '摇滚', '古风'],
  };

  @override void initState() {
    super.initState();
    _boot();
    // 发现到新引擎 / 引擎下线时刷新界面
    _disc = ThpDiscovery.onChange.listen((_) { if (mounted) setState(() {}); });
    // ★连接状态变化时：一旦连上就立即加载发现页（旧版不订阅 → 连接成功也不刷新）
    EngineDirect.state.addListener(_onConn);
    _connHooked = true;
  }
  void _onConn() {
    if (!mounted) return;
    final wasEmpty = sources.isEmpty;
    setState(() {});
    if (EngineDirect.connected && wasEmpty && !loading) unawaited(_load());
  }
  @override void dispose() {
    _disc?.cancel();
    if (_connHooked) EngineDirect.state.removeListener(_onConn);
    q.dispose();
    super.dispose();
  }

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
    catch (e) { err = EngineDirect.lastError.isNotEmpty ? EngineDirect.lastError : '连接失败: $e'; }
    if (mounted) setState(() => loading = false);
  }

  // 加载发现结构(书源+标签); 旧引擎不支持 → 热词搜索回落
  Future<void> _load() async {
    if (!EngineDirect.connected) return;
    setState(() {
      loading = true; err = ''; items = []; sources = [];
      selSource = ''; selTag = ''; searching = false; notice = '';
    });
    try {
      sources = await EngineDirect.discover(widget.type);
      notice = EngineDirect.discoverNotice;
      if (sources.isNotEmpty) {
        // 默认选中第一个源里**第一个有 url 的标签**（空 url 的标签点了必然 400）
        final s0 = sources.first;
        final tags = EngineDirect.validTags(s0);
        selSource = '${s0['source'] ?? ''}';
        if (tags.isNotEmpty) selTag = '${tags.first['url'] ?? ''}';
        if (mounted) setState(() => loading = false);
        if (selTag.isNotEmpty) { _explore(reset: true); return; }
      }
    } catch (e) {
      sources = [];
      err = EngineDirect.lastError.isNotEmpty ? EngineDirect.lastError : '$e';
    }
    // 引擎不支持发现/没有可用源 → 热词搜索回落
    try {
      items = await EngineDirect.search(
        widget.type, (hotwords[widget.type] ?? ['热门']).first);
      searching = true;
    } catch (e) {
      err = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  // 加载选中标签的书籍列表(reset=true 换标签/换源; false=加载下一页)
  Future<void> _explore({bool reset = false}) async {
    if (!EngineDirect.connected || selSource.isEmpty || selTag.isEmpty) return;
    if (reset) { page = 1; items = []; }
    setState(() { loading = true; err = ''; searching = false; });
    try {
      final list = await EngineDirect.explore(widget.type, selSource, selTag, page);
      if (reset) { items = list; } else { items = [...items, ...list]; }
      hasMore = list.isNotEmpty;
      page++;
    } catch (e) { err = '$e'; }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _search(String k) async {
    if (!EngineDirect.connected || k.trim().isEmpty) return;
    setState(() { loading = true; err = ''; items = []; searching = true; hasMore = false; notice = ''; });
    try { items = await EngineDirect.search(widget.type, k.trim()); }
    catch (e) { err = '$e'; }
    if (mounted) setState(() => loading = false);
  }

  @override Widget build(BuildContext c) {
    if (!EngineDirect.connected) {
      final devs = EngineDirect.available();
      final st = EngineDirect.state.value;
      return Center(child: Padding(padding: const EdgeInsets.all(28),
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.extension_off, size: 44,
            color: st.status == EngineStatus.failed ? Colors.redAccent : Colors.grey),
          const SizedBox(height: 12),
          Text(switch (st.status) {
            EngineStatus.connecting => '正在连接引擎…',
            EngineStatus.failed => '引擎不可达',
            _ => '发现页需要先连接引擎',
          }, style: const TextStyle(color: Colors.grey)),
          if (st.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8)),
              child: Text(st.message, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.redAccent, height: 1.5))),
          ],
          if (st.working || loading) const Padding(padding: EdgeInsets.only(top: 12),
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          // 已发现但未连上的引擎: 直接一键连接
          if (!loading && devs.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('局域网发现的引擎', style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 6),
            for (final d in devs)
              Card(child: ListTile(dense: true,
                leading: const Icon(Icons.extension, size: 20, color: Colors.blueAccent),
                title: Text(d.name.isNotEmpty ? d.name : '${d.host}:${d.port}',
                  style: const TextStyle(fontSize: 13)),
                subtitle: Text(d.caps.join(' / '), style: const TextStyle(fontSize: 10)),
                trailing: FilledButton.tonal(onPressed: () => _connect(d),
                  child: const Text('连接', style: TextStyle(fontSize: 12))))),
          ],
          if (!loading && devs.isEmpty) ...[
            const SizedBox(height: 8),
            const Text('未发现引擎: 请确认引擎已启动并与本机在同一局域网\n(引擎启动后会自动广播 THP UDP 19527)',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: () => EngineDirect.retry(),
            child: const Text('重试连接')),
          const SizedBox(height: 6),
          TextButton(onPressed: () => Navigator.push(c,
            MaterialPageRoute(builder: (_) => const EngineDirectPage())),
            child: const Text('引擎直连管理', style: TextStyle(fontSize: 12))),
        ]))));
    }
    final curTags = sources.isEmpty
      ? const <Map<String, dynamic>>[]
      : EngineDirect.validTags(sources.firstWhere(
          (s) => '${s['source']}' == selSource, orElse: () => sources.first));
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        child: Row(children: [
          Expanded(child: TextField(controller: q,
            decoration: const InputDecoration(hintText: '在引擎中搜索…', isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
              contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
            onSubmitted: _search)),
          IconButton(icon: const Icon(Icons.search), onPressed: () => _search(q.text)),
        ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          const Icon(Icons.circle, size: 8, color: Colors.green),
          const SizedBox(width: 4),
          Text(EngineDirect.name, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          const SizedBox(width: 10),
          if (searching || sources.isEmpty)
            for (final w in (hotwords[widget.type] ?? []))
              Padding(padding: const EdgeInsets.only(right: 6),
                child: ActionChip(label: Text(w, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () { q.text = w; _search(w); })),
          if (searching && sources.isNotEmpty)
            ActionChip(label: const Text('返回发现', style: TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              onPressed: () { _explore(reset: true); }),
        ])),
      if (notice.isNotEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
          child: Align(alignment: Alignment.centerLeft,
            child: Text(notice, style: const TextStyle(fontSize: 10, color: Colors.orangeAccent)))),
      // 书源分组(横滑) + 分类标签(换行)
      if (sources.isNotEmpty) ...[
        SizedBox(height: 38, child: ListView(scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          children: [ for (final s in sources)
            Padding(padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text('${s['sourceName'] ?? ''}', style: const TextStyle(fontSize: 11)),
                selected: selSource == '${s['source']}',
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  final tags = EngineDirect.validTags(s);
                  setState(() {
                    selSource = '${s['source'] ?? ''}';
                    selTag = tags.isNotEmpty ? '${tags.first['url'] ?? ''}' : '';
                  });
                  if (selTag.isNotEmpty) _explore(reset: true);
                })) ])),
        Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
          child: Align(alignment: Alignment.centerLeft,
            child: Wrap(spacing: 6, runSpacing: 4, children: [ for (final t in curTags)
              ChoiceChip(label: Text('${t['name'] ?? ''}', style: const TextStyle(fontSize: 11)),
                selected: selTag == '${t['url']}',
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  setState(() => selTag = '${t['url'] ?? ''}');
                  _explore(reset: true);
                }) ]))),
      ],
      if (loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(child: err.isNotEmpty
        ? Center(child: Padding(padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('出错: $err', textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              const SizedBox(height: 10),
              TextButton(onPressed: _load, child: const Text('重试', style: TextStyle(fontSize: 12))),
            ])))
        : items.isEmpty
          ? Center(child: Text(loading ? '加载中…' : '暂无内容',
              style: const TextStyle(color: Colors.grey)))
          : GridView.builder(padding: const EdgeInsets.all(10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, childAspectRatio: 0.62,
                crossAxisSpacing: 8, mainAxisSpacing: 8),
              // 发现模式: 末尾多一格"加载更多"
              itemCount: items.length + (!searching && hasMore ? 1 : 0),
              itemBuilder: (_, i) {
                if (i >= items.length) {
                  return GestureDetector(onTap: loading ? null : () => _explore(),
                    child: const Center(child: Column(mainAxisSize: MainAxisSize.min,
                      children: [ Icon(Icons.expand_more, color: Colors.grey),
                        Text('加载更多', style: TextStyle(fontSize: 11, color: Colors.grey)) ])));
                }
                final it = items[i];
                return GestureDetector(onTap: () => widget.onOpen(it),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(8),
                      child: (it['coverUrl'] ?? '') != ''
                        ? Image.network(it['coverUrl'], fit: BoxFit.cover, width: double.infinity,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey.withValues(alpha: 0.2),
                              child: const Icon(Icons.image_not_supported_outlined)))
                        : Container(color: Colors.grey.withValues(alpha: 0.2),
                            child: const Icon(Icons.book_outlined)))),
                    Padding(padding: const EdgeInsets.only(top: 4),
                      child: Text('${it['name'] ?? ''}', maxLines: 2,
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))),
                  ]));
              })),
    ]);
  }
}
