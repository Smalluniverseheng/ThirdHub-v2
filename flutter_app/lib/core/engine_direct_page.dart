// 引擎直连 UI: 发现/选择/管理直连引擎 + 每模块发现页(连引擎的发现/搜索)
//
// ★ 2026-09-19 修复「连上了却显示未连接引擎 / 状态变化特别慢」：
//   本页与发现页改为订阅 EngineDirect.state(ValueNotifier)，
//   连接状态一变化立即重建；并显示失败原因（含明文 HTTP 被系统拦截的提示）。
import 'dart:async';
import 'package:flutter/material.dart';
import 'discover.dart';
import 'engine_direct.dart';
import 'ui_cover.dart';

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
      setState(() => msg = '已连接「${EngineDirect.name}」');
    } catch (e) {
      // connect() 已把原因写进 state.message，这里只补充动作提示
      setState(() => msg = '连接失败：${EngineDirect.lastError}');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _retry() async {
    setState(() { busy = true; msg = ''; });
    await EngineDirect.retry();
    if (mounted) setState(() { busy = false; msg = EngineDirect.connected ? '已重新连接' : ''; });
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
          : '发现 ${hits.length} 个：${hits.map((d) => '${d.host}:${d.port}').join('、')}'; });
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
      title: const Text('手动填写资料库地址', style: TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: ctl, autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '例：192.168.1.5  或  [240e::1]:1234',
            helperText: '省略端口默认 1234（资料库）',
            helperStyle: TextStyle(fontSize: 11),
            isDense: true)),
        const SizedBox(height: 8),
        const Text('资料库应用的「关于」页会显示本机地址；也可在路由器 DHCP 列表里找。',
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
      msg = err == null ? '已连接「${EngineDirect.name}」' : '连接失败：$err'; });
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
    EngineStatus.connecting => '正在连接资料库…',
    EngineStatus.failed => s.url.isEmpty ? '未连接资料库' : '资料库离线：${s.name}',
    EngineStatus.idle => '未连接资料库',
  };

  @override Widget build(BuildContext c) =>
    ValueListenableBuilder<EngineState>(
      valueListenable: EngineDirect.state,
      builder: (c, st, _) => Scaffold(
        appBar: AppBar(title: const Text('资料库直连'),
          actions: [ IconButton(icon: const Icon(Icons.refresh, size: 20),
            tooltip: '重新探测/连接', onPressed: busy ? null : _retry) ]),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          const Text('不经过后端, 前端直接连接局域网资料库搜索与发现(THP 协议)',
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
                  color: (msg.startsWith('已连接') || msg.startsWith('已重新连接') || msg.startsWith('发现')) ? Colors.green : Colors.redAccent))),
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
          Row(children: [ const Text('发现的资料库（广播 + 主动扫描）', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const Spacer(),
            if (busy) const SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)) ]),
          const SizedBox(height: 6),
          if (EngineDirect.available().isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Column(children: [
              const Text('暂未发现资料库',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              const Text('资料库应用启动后会广播(THP UDP 19527)；\n'
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

  // ═══════════════════════════════════════════════════════════════════════
  // UI（2026-10-15 重做：目标是"看起来像内容应用，而不是调试工具"）
  //
  // 旧版的问题：整页是「搜索框 + 一排 chip + 裸网格」，所有元素一个视觉重量，
  // 用户进来不知道该看哪。重做分四层，每层有自己的视觉角色：
  //   ① 头部   —— 品牌感（渐变 + 大标题 + 引擎在线徽章）
  //   ② 源条   —— 横向卡片（图标 + 名字，选中态用主色描边）
  //   ③ 标签   —— 胶囊按钮（选中填充/未选描边）
  //   ④ 内容   —— 卡片网格 + 骨架屏 + 空态引导
  // ═══════════════════════════════════════════════════════════════════════

  /// 模块名（给头部标题用）。
  String get _typeLabel => const {
        'novel': '小说', 'comic': '漫画', 'video': '影视', 'music': '音乐',
      }[widget.type] ?? widget.type;

  @override
  Widget build(BuildContext c) {
    if (!EngineDirect.connected) return _offlineView(c);
    final cs = Theme.of(c).colorScheme;
    final curTags = sources.isEmpty
        ? const <Map<String, dynamic>>[]
        : EngineDirect.validTags(sources.firstWhere(
            (s) => '${s['source']}' == selSource,
            orElse: () => sources.first));

    return Column(children: [
      _header(c, cs),
      if (sources.isNotEmpty) _sourceStrip(c, cs),
      if (curTags.isNotEmpty) _tagWrap(c, cs, curTags),
      if (notice.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
          child: Row(children: [
            const Icon(Icons.info_outline, size: 12, color: Colors.orangeAccent),
            const SizedBox(width: 4),
            Expanded(
              child: Text(notice,
                  style: const TextStyle(fontSize: 10.5, color: Colors.orangeAccent)),
            ),
          ]),
        ),
      if (loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(child: _content(c, cs)),
    ]);
  }

  // ── ① 头部：渐变 + 大标题 + 引擎徽章 + 搜索 ──
  Widget _header(BuildContext c, ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primaryContainer.withValues(alpha: 0.55),
            cs.primaryContainer.withValues(alpha: 0.18),
          ],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.explore_outlined, size: 20, color: cs.primary),
          const SizedBox(width: 6),
          Text('发现$_typeLabel',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const Spacer(),
          // 引擎在线徽章
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: cs.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 6, height: 6,
                decoration: const BoxDecoration(
                    color: Colors.green, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(
                EngineDirect.name.isEmpty ? '资料库' : EngineDirect.name,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ]),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text('内容来自资料库各源的推荐与分类，不用搜也能逛',
              style: TextStyle(
                  fontSize: 11, color: cs.onSurface.withValues(alpha: 0.55))),
        ),
        const SizedBox(height: 10),
        // 搜索框（填充式，圆角 22）
        TextField(
          controller: q,
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            hintText: '搜索$_typeLabel…',
            hintStyle: TextStyle(
                fontSize: 13, color: cs.onSurface.withValues(alpha: 0.38)),
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              onPressed: () => _search(q.text),
              tooltip: '搜索',
            ),
            isDense: true,
            filled: true,
            fillColor: cs.surface.withValues(alpha: 0.75),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(22),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
          ),
          onSubmitted: _search,
        ),
      ]),
    );
  }

  // ── ② 源条：横向卡片 ──
  Widget _sourceStrip(BuildContext c, ColorScheme cs) {
    return SizedBox(
      height: 62,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        itemCount: sources.length,
        itemBuilder: (_, i) {
          final s = sources[i];
          final key = '${s['source'] ?? ''}';
          final on = key == selSource;
          final name = '${s['sourceName'] ?? key}';
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(13),
              onTap: () {
                final tags = EngineDirect.validTags(s);
                setState(() {
                  selSource = key;
                  selTag = tags.isNotEmpty ? '${tags.first['url'] ?? ''}' : '';
                });
                if (selTag.isNotEmpty) _explore(reset: true);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: on
                      ? cs.primary.withValues(alpha: 0.12)
                      : cs.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    width: on ? 1.6 : 1,
                    color: on
                        ? cs.primary
                        : cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(children: [
                  Container(
                    width: 30, height: 30,
                    decoration: BoxDecoration(
                      color: on
                          ? cs.primary.withValues(alpha: 0.18)
                          : cs.surface.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      name.isEmpty ? '?' : String.fromCharCodes(name.runes.take(1)),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: on ? cs.primary : cs.onSurface.withValues(alpha: 0.6)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 92),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
                        Text('${(s['tags'] as List?)?.length ?? 0} 个分类',
                            style: TextStyle(
                                fontSize: 9.5,
                                color: cs.onSurface.withValues(alpha: 0.45))),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── ③ 标签：胶囊 ──
  Widget _tagWrap(BuildContext c, ColorScheme cs, List<Map<String, dynamic>> tags) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Wrap(
        spacing: 7,
        runSpacing: 6,
        children: [
          for (final t in tags)
            GestureDetector(
              onTap: () {
                setState(() => selTag = '${t['url'] ?? ''}');
                _explore(reset: true);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: selTag == '${t['url']}'
                      ? cs.primary
                      : cs.surfaceContainerHighest.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    width: 1,
                    color: selTag == '${t['url']}'
                        ? cs.primary
                        : cs.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
                child: Text('${t['name'] ?? ''}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: selTag == '${t['url']}' ? FontWeight.w700 : FontWeight.w500,
                        color: selTag == '${t['url']}'
                            ? cs.onPrimary
                            : cs.onSurface.withValues(alpha: 0.78))),
              ),
            ),
        ],
      ),
    );
  }

  // ── ④ 内容区：骨架屏 / 空态 / 网格 ──
  Widget _content(BuildContext c, ColorScheme cs) {
    if (err.isNotEmpty) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off_outlined, size: 38,
              color: cs.onSurface.withValues(alpha: 0.28)),
          const SizedBox(height: 10),
          Text(err, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12, height: 1.5)),
          const SizedBox(height: 10),
          FilledButton.tonal(
              onPressed: _load, child: const Text('重试', style: TextStyle(fontSize: 13))),
        ]),
      ));
    }
    if (loading && items.isEmpty) return const _SkeletonGrid();
    if (items.isEmpty) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.explore_off_outlined, size: 40,
              color: cs.onSurface.withValues(alpha: 0.25)),
          const SizedBox(height: 10),
          const Text('这个分类暂时没有内容',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 4),
          const Text('换个分类或源试试；内容来自各站点，偶尔会空',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ));
    }

    final more = !searching && hasMore;
    return GridView.builder(
      padding: coverPad,
      gridDelegate: coverDelegate(CoverKind.coverGrid),
      itemCount: items.length + (more ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= items.length) {
          return InkWell(
            borderRadius: BorderRadius.circular(CoverSpec.radius),
            onTap: loading ? null : () => _explore(),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(CoverSpec.radius),
                border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.4)),
              ),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_circle_outline,
                              size: 22,
                              color: cs.primary.withValues(alpha: 0.7)),
                          const SizedBox(height: 3),
                          Text('加载更多',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withValues(alpha: 0.55))),
                        ],
                      ),
              ),
            ),
          );
        }
        final it = items[i];
        return _Card(it: it, onTap: () => widget.onOpen(it));
      },
    );
  }

  // ── 未连接态（美化）──
  Widget _offlineView(BuildContext c) {
    final devs = EngineDirect.available();
    final st = EngineDirect.state.value;
    final cs = Theme.of(c).colorScheme;
    return Center(
        child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 76, height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                cs.primaryContainer.withValues(alpha: 0.8),
                cs.primaryContainer.withValues(alpha: 0.25),
              ],
            ),
          ),
          child: Icon(
            st.status == EngineStatus.failed
                ? Icons.cloud_off_rounded
                : Icons.extension_rounded,
            size: 34,
            color: st.status == EngineStatus.failed
                ? Colors.redAccent
                : cs.primary,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          switch (st.status) {
            EngineStatus.connecting => '正在连接资料库…',
            EngineStatus.failed => '资料库不可达',
            _ => '发现页需要先连接资料库',
          },
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        Text('连上后这里会自动展示各源的推荐内容',
            style: TextStyle(
                fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
        if (st.message.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(st.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 11, color: Colors.redAccent, height: 1.5)),
          ),
        ],
        if (st.working || loading)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        if (!loading && devs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('局域网发现的资料库',
              style: TextStyle(
                  fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5))),
          const SizedBox(height: 8),
          for (final d in devs)
            Card(
              elevation: 0,
              color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13)),
              child: ListTile(
                dense: true,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13)),
                leading: Icon(Icons.extension_rounded,
                    size: 20, color: cs.primary),
                title: Text(
                    d.name.isNotEmpty ? d.name : '${d.host}:${d.port}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text(d.caps.join(' / '),
                    style: const TextStyle(fontSize: 10)),
                trailing: FilledButton.tonal(
                    onPressed: () => _connect(d),
                    child: const Text('连接', style: TextStyle(fontSize: 12))),
              ),
            ),
        ],
        if (!loading && devs.isEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            '未发现资料库\n请确认资料库已启动，并与本机在同一局域网',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.6),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.tonal(
          onPressed: () => EngineDirect.retry(),
          child: const Text('重试连接'),
        ),
        TextButton(
          onPressed: () => Navigator.push(c,
              MaterialPageRoute(builder: (_) => const EngineDirectPage())),
          child: const Text('资料库直连管理', style: TextStyle(fontSize: 12)),
        ),
      ]),
    ));
  }
}

/// 发现页内容卡（封面 + 名条 + 悬浮反馈）。
class _Card extends StatelessWidget {
  const _Card({required this.it, required this.onTap});
  final Map<String, dynamic> it;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(CoverSpec.radius),
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(CoverSpec.radius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: CoverImage(
              it['coverUrl'],
              width: double.infinity,
              fallbackText: '${it['name'] ?? ''}',
              fallbackIcon: Icons.auto_stories_outlined,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 5, 2, 0),
          child: Text(
            '${it['name'] ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, height: 1.25),
          ),
        ),
        if ('${it['sourceName'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 1, 2, 0),
            child: Text(
              '${it['sourceName']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 9.5,
                  color: cs.onSurface.withValues(alpha: 0.42)),
            ),
          ),
      ]),
    );
  }
}

/// 骨架屏：加载时给"内容将至"的形状感，而不是一句干巴巴的"加载中"。
class _SkeletonGrid extends StatefulWidget {
  const _SkeletonGrid();
  @override
  State<_SkeletonGrid> createState() => _SkeletonGridState();
}

class _SkeletonGridState extends State<_SkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _ac,
      builder: (_, __) {
        final a = 0.35 + _ac.value * 0.25;
        return GridView.builder(
          padding: coverPad,
          gridDelegate: coverDelegate(CoverKind.coverGrid),
          itemCount: 9,
          itemBuilder: (_, i) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: a * 0.14),
                      borderRadius: BorderRadius.circular(CoverSpec.radius),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 9,
                  width: 60,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: a * 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ]),
        );
      },
    );
  }
}
