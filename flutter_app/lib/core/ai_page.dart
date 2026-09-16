// AI 模块: 1:1 复刻网站(thirdhub.pages.dev) AI 页
// 顶栏(菜单/模型胶囊/新对话) · 左侧抽屉(历史会话/AI模型/智能体/灵感广场 + Work/Chat)
// 手势: 边缘右滑开抽屉·抽屉左滑关闭·跟手拖动·松手≥40%吸附 · 输入栏贴底 · 流式渐进渲染
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'ai.dart';
import 'ai_agents_snapshot.dart';
import 'ai_rankings_snapshot.dart';
import 'ai_providers_page.dart';
import 'mcp_page.dart';
import 'vendor_icons.dart';

// 边缘滑动识别器: 按下即抢占(外层 PageView 抢不走), 与网站边缘30px右滑开抽屉一致
class _EdgeSwipeRecognizer extends OneSequenceGestureRecognizer {
  double sx = 0; double sy = 0; bool active = false;
  void Function(double dx)? onUpdate; void Function(double dx, double vx)? onEnd;
  @override String get debugDescription => 'edgeSwipe';
  @override void addAllowedPointer(PointerDownEvent e) {
    sx = e.position.dx; sy = e.position.dy; active = true;
    resolve(GestureDisposition.accepted); // 立即抢占, PageView 纵向/横向都抢不走
    startTrackingPointer(e.pointer);
  }
  @override void handleEvent(PointerEvent e) {
    if (!active) return;
    if (e is PointerMoveEvent) onUpdate?.call(e.position.dx - sx);
    if (e is PointerUpEvent || e is PointerCancelEvent) {
      active = false; stopTrackingPointer(e.pointer);
      onEnd?.call(e is PointerUpEvent ? e.position.dx - sx : 0, 0);
    }
  }
  @override void didStopTrackingLastPointer(int pointer) {}
}
// 非对话模型过滤(与网站 NON_CHAT_RE 一致)
final _nonChatRe = RegExp(r'embed|whisper|tts|transcri|speech|audio|dall-e|image|imagen|moderation|rerank|babbage|davinci|clip|sora|veo|wanx|cogview|cogvideo|kolors|stable-diffusion|seedream|seedance|hailuo|sensemirage', caseSensitive: false);
// 音频模型(语音合成/音乐生成)与识别模型(语音识别/转写)分类
final _audioRe = RegExp(r'tts|speech|audio|voice|sound|music|suno|udio|song|melo', caseSensitive: false);
final _recogRe = RegExp(r'whisper|transcri|asr|sensevoice|recogn|paraformer|funasr', caseSensitive: false);

class AiSession {
  String id, title, providerId, model; String? agentId;
  List<Map<String, String>> messages;
  AiSession({required this.id, required this.title, required this.providerId, required this.model, this.agentId, required this.messages});
  factory AiSession.from(Map<String, dynamic> j) => AiSession(id: j['id'], title: j['title'] ?? '新对话',
    providerId: j['providerId'] ?? '', model: j['model'] ?? '', agentId: j['agentId'],
    messages: (j['messages'] as List? ?? []).map((e) => Map<String, String>.from(e)).toList());
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'providerId': providerId, 'model': model, 'agentId': agentId, 'messages': messages};
}

class AiStore {
  static List<AiSession> sessions = [];
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    try { sessions = (jsonDecode(p.getString('ai_sessions') ?? '[]') as List).map((e) => AiSession.from(e)).toList(); } catch (_) { sessions = []; }
  }
  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ai_sessions', jsonEncode(sessions.map((e) => e.toJson()).toList()));
  }
  static AiSession create(String providerId, String model, {String? agentId, String? system}) {
    final s = AiSession(id: DateTime.now().millisecondsSinceEpoch.toString(), title: '新对话',
      providerId: providerId, model: model, agentId: agentId,
      messages: system != null ? [{'role': 'system', 'content': system}] : []);
    sessions.insert(0, s); save(); return s;
  }
  static Future<void> remove(String id) async { sessions.removeWhere((s) => s.id == id); await save(); }
}

// 入口: 直接就是 AI 对话页(与网站一致)
class AiSection extends StatefulWidget { const AiSection({super.key}); @override State<AiSection> createState() => _AiSec(); }
class _AiSec extends State<AiSection> {
  AiSession? session; bool sending = false; String streaming = '';
  final input = TextEditingController(); final scroll = ScrollController();
  bool pinned = false; // 上拉钉住(回到底部按钮)
  // 抽屉状态
  double _drawerP = 0; bool _drawerOpen = false; String _drawerTab = 'history'; String _drawerFilter = 'all'; String _historyQuery = '';
  String _rankCat = 'overall'; bool _webSearchOn = false; bool _mcpOn = true;
  StreamSubscription? _regSub;

  double _drawerW(BuildContext c) => (MediaQuery.of(c).size.width * 0.8).clamp(0.0, 340.0);

  @override void initState() { super.initState(); _boot();
    _regSub = AiRegistry.onChange.listen((_) { if (mounted) setState(() {}); });
    scroll.addListener(() {
      final dist = scroll.position.maxScrollExtent - scroll.position.pixels;
      final p = dist > 60;
      if (p != pinned) setState(() => pinned = p);
    });
  }
  @override void dispose() { _regSub?.cancel(); input.dispose(); scroll.dispose(); super.dispose(); }
  Future<void> _boot() async {
    await AiStore.load();
    await Mcp.init();
    final prefs = await SharedPreferences.getInstance();
    _webSearchOn = prefs.getBool('ai_websearch_on') ?? false;
    _mcpOn = prefs.getBool('ai_mcp_on') ?? true;
    final (p, m) = await AiRegistry.lastModel();
    if (AiStore.sessions.isEmpty) { session = AiStore.create(p, m); }
    else { session = AiStore.sessions.first; }
    if (mounted) setState(() {});
  }

  // ── 抽屉手势(1:1: 边缘30px右滑开·跟手·≥0.4吸附; 抽屉上左滑关) ──
  double _cum = 0;
  void _applyDrag(double dx) {
    final w = _drawerW(context);
    final base = _drawerOpen ? w : 0.0;
    setState(() => _drawerP = ((base + dx) / w).clamp(0.0, 1.0));
  }
  void _settleDrag(double dx) {
    _applyDrag(dx);
    final open = _drawerP >= 0.4;
    setState(() { _drawerOpen = open; _drawerP = open ? 1.0 : 0.0; });
  }
  void _openDrawer() => setState(() { _drawerOpen = true; _drawerP = 1.0; });
  void _closeDrawer() => setState(() { _drawerOpen = false; _drawerP = 0.0; });

  void _newChat({String? agentId, String? system}) {
    setState(() { session = AiStore.create(session?.providerId ?? 'deepseek', session?.model ?? 'deepseek-chat', agentId: agentId, system: system); streaming = ''; });
    _closeDrawer();
  }

  Future<void> _send() async {
    final text = input.text.trim(); if (text.isEmpty || sending || session == null) return;
    final prov = AiRegistry.byId(session!.providerId);
    if (prov == null) return;
    if ((await AiRegistry.keyOf(prov.id)).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('当前模型未配置 API Key · 点抽屉顶部设置去配置 ${prov.name}')));
      return;
    }
    input.clear();
    setState(() {
      session!.messages.add({'role': 'user', 'content': text});
      if (session!.title == '新对话') session!.title = text.length > 18 ? '${text.substring(0, 18)}…' : text;
      sending = true; streaming = '';
    });
    AiStore.save();
    _jumpBottom();
    // 联网搜索: 先检索再把结果注入上下文(会话里只保留用户原文)
    var msgs = session!.messages;
    if (_webSearchOn) {
      try {
        if (await WebSearch.configured()) {
          setState(() => streaming = '🔍 正在联网搜索…');
          final items = await WebSearch.search(text);
          if (items.isNotEmpty) {
            msgs = [...msgs.sublist(0, msgs.length - 1),
              {'role': 'user', 'content': WebSearch.toContext(text, items)}, msgs.last];
          }
          setState(() => streaming = '');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('联网搜索未配置 · 点输入框左侧 + → 联网搜索 去配置')));
        }
      } catch (e) {
        setState(() => streaming = '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('联网搜索失败: $e')));
      }
    }
    try {
      final full = await AiChat.chat(provider: prov, model: session!.model, messages: msgs,
        mcpTools: _mcpOn ? Mcp.allTools() : null,
        onToolCall: (name) { setState(() => streaming = '🛠 正在调用工具 $name…'); },
        onDelta: (d) { setState(() { if (streaming.startsWith('🔍') || streaming.startsWith('🛠')) streaming = ''; streaming += d; }); if (!pinned) _jumpBottom(); });
      setState(() { session!.messages.add({'role': 'assistant', 'content': full}); streaming = ''; });
    } catch (e) {
      setState(() { session!.messages.add({'role': 'assistant', 'content': '出错了: $e'}); streaming = ''; });
    }
    AiStore.save();
    setState(() => sending = false);
    _jumpBottom();
  }
  void _jumpBottom() { WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent); }); }

  @override Widget build(BuildContext c) {
    final w = _drawerW(c);
    final dark = Theme.of(c).brightness == Brightness.dark;
    return Scaffold(body: Stack(children: [
      // 主内容(抽屉打开时整体右移, 与网站一致)
      Transform.translate(offset: Offset(_drawerP * w, 0), child: _mainBody(c, dark)),
      // 遮罩(右侧露出1/5, 点击关闭)
      if (_drawerP > 0) Positioned.fill(child: GestureDetector(onTap: _closeDrawer,
        child: Container(color: Colors.black.withValues(alpha: 0.35 * _drawerP)))),
      // 抽屉(打开时其上左滑可关: 普通手势即可, 抽屉在最上层)
      Transform.translate(offset: Offset(-w * (1 - _drawerP), 0),
        child: SizedBox(width: w, child: GestureDetector(
          onHorizontalDragStart: _drawerOpen ? (_) => _cum = 0 : null,
          onHorizontalDragUpdate: _drawerOpen ? (d) { _cum += d.delta.dx; _applyDrag(_cum); } : null,
          onHorizontalDragEnd: _drawerOpen ? (_) { _settleDrag(_cum); } : null,
          child: _drawer(c, dark)))),
      // 边缘热区: 按下即抢占(网站30px), 关闭态右滑开抽屉
      if (!_drawerOpen) Positioned(left: 0, top: 0, bottom: 0, width: 30,
        child: RawGestureDetector(gestures: { _EdgeSwipeRecognizer: GestureRecognizerFactoryWithHandlers<_EdgeSwipeRecognizer>(
          () => _EdgeSwipeRecognizer(),
          (r) { r.onUpdate = (dx) { if (dx > 0) _applyDrag(dx); };
                r.onEnd = (dx, vx) { if (dx > 0) _settleDrag(dx); }; }) },
          child: Container(color: Colors.transparent))),
    ]));
  }

  // ── 主区: 顶栏 + 消息 + 输入栏 ──
  Widget _mainBody(BuildContext c, bool dark) {
    final s = session;
    return Scaffold(
      appBar: AppBar(leading: IconButton(icon: const Icon(Icons.menu), onPressed: _openDrawer),
        title: GestureDetector(onTap: () { _openDrawer(); setState(() => _drawerTab = 'models'); },
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: Theme.of(c).cardTheme.color, borderRadius: BorderRadius.circular(18)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(s == null || s.model.isEmpty ? '选择模型' : s.model,
                style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              const Icon(Icons.arrow_drop_down, size: 18)]))),
        actions: [IconButton(icon: const Icon(Icons.add), tooltip: '新对话', onPressed: () => _newChat())]),
      body: Column(children: [
        Expanded(child: s == null ? const Center(child: CircularProgressIndicator())
          : (s.messages.where((m) => m['role'] != 'system').isEmpty && streaming.isEmpty)
            ? _emptyHint(c) : _msgList(c, s)),
        _inputBar(c, dark),
      ]));
  }

  Widget _emptyHint(BuildContext c) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.smart_toy_outlined, size: 56, color: Colors.grey),
    const SizedBox(height: 10),
    Text('${AiRegistry.providers.length} 家厂商 · ${AiRegistry.providers.fold<int>(0, (a, b) => a + b.models.length)} 个模型',
      style: const TextStyle(color: Colors.grey, fontSize: 12)),
    const SizedBox(height: 4),
    const Text('左滑边缘或点菜单打开抽屉: 历史/模型/智能体/灵感', style: TextStyle(color: Colors.grey, fontSize: 11)),
  ]));

  Widget _msgList(BuildContext c, AiSession s) {
    final list = s.messages.where((m) => m['role'] != 'system').toList();
    return Stack(children: [
      ListView.builder(controller: scroll, padding: const EdgeInsets.all(14),
        itemCount: list.length + (streaming.isNotEmpty ? 1 : 0), itemBuilder: (_, i) {
          final m = i < list.length ? list[i] : {'role': 'assistant', 'content': streaming};
          final me = m['role'] == 'user';
          final accent = Theme.of(c).colorScheme.primary;
          final dark = Theme.of(c).brightness == Brightness.dark;
          final bubble = GestureDetector(onLongPress: () { Clipboard.setData(ClipboardData(text: m['content'] ?? ''));
              ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已复制'))); },
            child: Container(margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(maxWidth: MediaQuery.of(c).size.width * 0.76),
              decoration: BoxDecoration(
                gradient: me ? LinearGradient(colors: [accent, accent.withValues(alpha: 0.78)]) : null,
                color: me ? null : (dark ? const Color(0xFF1E2230) : Colors.white),
                border: me ? null : Border.all(color: dark ? Colors.white10 : const Color(0xFFE8E6F0)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6, offset: const Offset(0, 2))],
                borderRadius: BorderRadius.only(topLeft: const Radius.circular(16), topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(me ? 16 : 4), bottomRight: Radius.circular(me ? 4 : 16))),
              child: Text(m['content'] ?? '', style: TextStyle(fontSize: 14, height: 1.6,
                color: me ? Colors.white : null))));
          final avatar = CircleAvatar(radius: 14,
            backgroundColor: me ? accent.withValues(alpha: 0.15) : const Color(0xFFEDE9FE),
            child: Icon(me ? Icons.person_outline : Icons.smart_toy_outlined, size: 15,
              color: me ? accent : const Color(0xFF7C6CFF)));
          return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(
            mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start, children: me
              ? [Flexible(child: bubble), const SizedBox(width: 8), avatar]
              : [avatar, const SizedBox(width: 8), Flexible(child: bubble)]));
        }),
      if (pinned) Positioned(right: 16, bottom: 12, child: FloatingActionButton.small(
        onPressed: () { setState(() => pinned = false); _jumpBottom(); },
        child: const Icon(Icons.arrow_downward, size: 18))),
    ]);
  }

  Widget _inputBar(BuildContext c, bool dark) => SafeArea(child: Padding(
    padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      IconButton(icon: const Icon(Icons.add_circle_outline), tooltip: '更多功能', onPressed: () => _plusSheet(c)),
      Expanded(child: TextField(controller: input, minLines: 1, maxLines: 5,
        decoration: InputDecoration(hintText: '输入消息…', isDense: true, filled: true,
          fillColor: Theme.of(c).cardTheme.color,
          border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(22)), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
        onSubmitted: (_) => _send())),
      IconButton(icon: const Icon(Icons.mic_none), tooltip: '语音输入(准备开放)',
        onPressed: () => ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('语音输入准备开放')))),
      sending ? const SizedBox(width: 40, height: 40, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
        : IconButton.filled(onPressed: _send, icon: const Icon(Icons.send, size: 18)),
    ])));

  void _plusSheet(BuildContext c) {
    showModalBottomSheet(context: c, builder: (c2) => SafeArea(child: Padding(padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          for (final e in [('拍照', Icons.photo_camera), ('相册', Icons.image_outlined), ('文件', Icons.insert_drive_file_outlined), ('绘画', Icons.brush_outlined), ('视频', Icons.videocam_outlined)])
            Column(children: [IconButton.filledTonal(icon: Icon(e.$2), onPressed: () { Navigator.pop(c2);
                ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('准备开放'))); }),
              Text(e.$1, style: const TextStyle(fontSize: 11))]),
        ]),
        const Divider(height: 24),
        StatefulBuilder(builder: (c3, setS) => SwitchListTile(dense: true,
          secondary: Icon(Icons.travel_explore, color: _webSearchOn ? Colors.blueAccent : null),
          title: const Text('联网搜索', style: TextStyle(fontSize: 14)),
          subtitle: const Text('先检索再把结果注入模型上下文', style: TextStyle(fontSize: 11)),
          value: _webSearchOn, onChanged: (v) async {
            setState(() => _webSearchOn = v); setS(() {});
            final p = await SharedPreferences.getInstance(); await p.setBool('ai_websearch_on', v); })),
        ListTile(dense: true, leading: const Icon(Icons.settings_ethernet), title: const Text('联网搜索服务配置', style: TextStyle(fontSize: 14)),
          subtitle: const Text('Tavily / Brave / SerpAPI / SearXNG', style: TextStyle(fontSize: 11)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2); _searchConfigSheet(c); }),
        StatefulBuilder(builder: (c3, setS) => SwitchListTile(dense: true,
          secondary: Icon(Icons.hub_outlined, color: _mcpOn ? Colors.blueAccent : null),
          title: const Text('MCP 工具', style: TextStyle(fontSize: 14)),
          subtitle: Text('已连接 ${Mcp.servers.where((s) => s.enabled && s.status == 'connected').length} 个服务 · 对话中自动调用', style: const TextStyle(fontSize: 11)),
          value: _mcpOn, onChanged: (v) async {
            setState(() => _mcpOn = v); setS(() {});
            final p = await SharedPreferences.getInstance(); await p.setBool('ai_mcp_on', v); })),
        ListTile(dense: true, leading: const Icon(Icons.cable), title: const Text('MCP 服务管理', style: TextStyle(fontSize: 14)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2);
            Navigator.push(c, MaterialPageRoute(builder: (_) => const McpPage())); }),
        ListTile(dense: true, leading: const Icon(Icons.smart_toy_outlined), title: const Text('厂商与 Key 管理', style: TextStyle(fontSize: 14)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2);
            Navigator.push(c, MaterialPageRoute(builder: (_) => const AiProvidersPage())); }),
      ]))));
  }

  // 联网搜索服务配置(与网站 web-search.js 一致)
  void _searchConfigSheet(BuildContext c) async {
    final cfg = await WebSearch.config();
    var svc = cfg['service']!; final keyC = TextEditingController(text: cfg['key']); final urlC = TextEditingController(text: cfg['url']);
    if (!c.mounted) return;
    await showModalBottomSheet(context: c, isScrollControlled: true, builder: (c2) => StatefulBuilder(builder: (c2, setD) {
      final cur = WebSearch.serviceOf(svc);
      return Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(c2).viewInsets.bottom + 16), child: SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('联网搜索服务', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final s in WebSearch.services)
          RadioListTile<String>(dense: true, value: s.id, groupValue: svc, title: Text(s.name, style: const TextStyle(fontSize: 13)),
            subtitle: Text(s.desc, style: const TextStyle(fontSize: 10)), onChanged: (v) => setD(() => svc = v!)),
        if (cur != null && !cur.needUrl) TextField(controller: keyC, obscureText: true,
          decoration: InputDecoration(labelText: 'API Key', hintText: cur.keyHint, isDense: true, border: const OutlineInputBorder())),
        if (cur != null && cur.needUrl) ...[
          TextField(controller: urlC, decoration: const InputDecoration(labelText: '实例地址', hintText: 'https://searx.example.com', isDense: true, border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: keyC, obscureText: true, decoration: const InputDecoration(labelText: 'API Key(可留空)', isDense: true, border: OutlineInputBorder())),
        ],
        const SizedBox(height: 12),
        FilledButton(onPressed: () async { await WebSearch.setConfig(svc, keyC.text, urlC.text);
          if (c2.mounted) Navigator.pop(c2);
          if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已保存联网搜索配置'))); },
          child: const Text('保存')),
      ]))));
    }));
  }

  // ── 抽屉(与网站一致: 头部 / AI模型入口 / Work·Chat / 四页签 / 底部搜索+新建) ──
  Widget _drawer(BuildContext c, bool dark) {
    final bg = dark ? const Color(0xFF181B22) : Colors.white;
    // 整个左侧抽屉一列到底, 可上下滑动
    return Material(color: bg, elevation: 8, child: SafeArea(child: ListView(children: [
      // 头部: 头像+名称+设置
      ListTile(dense: true, leading: const CircleAvatar(radius: 16, child: Icon(Icons.smart_toy, size: 16)),
        title: const Text('ThirdHub AI', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        trailing: const Icon(Icons.settings_outlined, size: 18),
        onTap: () { _closeDrawer(); Navigator.push(c, MaterialPageRoute(builder: (_) => const AiProvidersPage())); }),
      ListTile(dense: true, leading: const Icon(Icons.memory, size: 20), title: const Text('AI模型', style: TextStyle(fontSize: 14)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => setState(() => _drawerTab = 'models')),
      const SizedBox(height: 4),
      ..._chatBox(c),
    ])));
  }


  List<Widget> _chatBox(BuildContext c) => [
    ListTile(dense: true, leading: const Icon(Icons.add, size: 20), title: const Text('新对话', style: TextStyle(fontSize: 14)),
      onTap: () => _newChat()),
    // 四页签
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
      for (final t in [('history', '历史会话'), ('models', 'AI模型'), ('agents', '智能体'), ('inspire', '灵感'), ('rank', '排行榜')])
        Expanded(child: GestureDetector(onTap: () => setState(() => _drawerTab = t.$1),
          child: Container(padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(width: 2,
              color: _drawerTab == t.$1 ? Theme.of(c).colorScheme.primary : Colors.transparent))),
            child: Text(t.$2, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: _drawerTab == t.$1 ? Theme.of(c).colorScheme.primary : Colors.grey))))),
    ])),
    if (_drawerTab == 'models') Padding(padding: const EdgeInsets.only(top: 6), child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      for (final f in [('all', '全部'), ('chat', '聊天'), ('image', '图片'), ('video', '视频'), ('audio', '音频'), ('recog', '识别')])
        Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: ChoiceChip(
          label: Text(f.$2, style: const TextStyle(fontSize: 11)), selected: _drawerFilter == f.$1,
          onSelected: (_) => setState(() => _drawerFilter = f.$1), visualDensity: VisualDensity.compact)),
    ]))),
    const SizedBox(height: 4),
    _drawerTab == 'history' ? _historyList(c)
      : _drawerTab == 'models' ? _modelsList(c)
      : _drawerTab == 'agents' ? _agentsList(c)
      : _drawerTab == 'rank' ? _rankList(c) : _inspireList(c),
    if (_drawerTab == 'history') Padding(padding: const EdgeInsets.all(10), child: Row(children: [
      Expanded(child: TextField(decoration: const InputDecoration(hintText: '搜索历史会话', isDense: true,
        prefixIcon: Icon(Icons.search, size: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none),
        filled: true), onChanged: (v) => setState(() => _historyQuery = v))),
      const SizedBox(width: 8),
      IconButton.filledTonal(icon: const Icon(Icons.add, size: 20), onPressed: () => _newChat()),
    ])),
  ];

  Widget _historyList(BuildContext c) {
    var list = AiStore.sessions;
    if (_historyQuery.isNotEmpty) list = list.where((s) => s.title.contains(_historyQuery)).toList();
    if (list.isEmpty) return const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('暂无会话', style: TextStyle(color: Colors.grey, fontSize: 12))));
    return ListView(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), children: [ for (final s in list)
      Dismissible(key: Key(s.id), direction: DismissDirection.endToStart,
        background: Container(color: Colors.redAccent, alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete_outline, color: Colors.white)),
        onDismissed: (_) { AiStore.remove(s.id); if (session?.id == s.id) _newChat(); setState(() {}); },
        child: ListTile(dense: true, selected: session?.id == s.id,
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          subtitle: Text('${s.model} · ${s.messages.where((m) => m['role'] == 'user').length} 条', style: const TextStyle(fontSize: 10)),
          onTap: () { setState(() => session = s); _closeDrawer(); })) ]);
  }

  Widget _modelsList(BuildContext c) => ListView(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), children: [ for (final p in AiRegistry.all) () {
    var models = switch (_drawerFilter) {
      'chat' => p.models.where((m) => !_nonChatRe.hasMatch(m)).toList(),
      'image' => p.image, 'video' => p.video,
      'audio' => p.models.where((m) => _audioRe.hasMatch(m) && !_recogRe.hasMatch(m)).toList(),
      'recog' => p.models.where((m) => _recogRe.hasMatch(m)).toList(),
      _ => p.models };
    if (models.isEmpty) return const SizedBox();
    return ExpansionTile(dense: true, initiallyExpanded: AiRegistry.providers.length <= 3,
      leading: VendorIcon(p.id, size: 24),
      title: Text(p.name, style: const TextStyle(fontSize: 13)),
      subtitle: Text('${models.length} 个模型', style: const TextStyle(fontSize: 10)),
      children: [ for (final m in models)
        ListTile(dense: true, title: Text(m, style: const TextStyle(fontSize: 12)),
          trailing: session?.providerId == p.id && session?.model == m ? const Icon(Icons.check, size: 16, color: Colors.blueAccent) : null,
          onTap: () async { await AiRegistry.setLastModel(p.id, m);
            if (session != null) { session!.providerId = p.id; session!.model = m; }
            setState(() {}); AiStore.save(); _closeDrawer(); }),
        // 历史模型(默认折叠, 与网站一致)
        if (p.deprecated.isNotEmpty && _drawerFilter != 'image' && _drawerFilter != 'video' && _drawerFilter != 'audio' && _drawerFilter != 'recog')
          ExpansionTile(dense: true, tilePadding: const EdgeInsets.only(left: 30, right: 16),
            title: Text('历史模型 (${p.deprecated.length})', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            children: [ for (final m in p.deprecated)
              ListTile(dense: true, title: Text(m, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                trailing: session?.providerId == p.id && session?.model == m ? const Icon(Icons.check, size: 16, color: Colors.blueAccent) : null,
                onTap: () async { await AiRegistry.setLastModel(p.id, m);
                  if (session != null) { session!.providerId = p.id; session!.model = m; }
                  setState(() {}); AiStore.save(); _closeDrawer(); }) ]) ]);
  }() ]);

  Widget _agentsList(BuildContext c) => GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: 2, padding: const EdgeInsets.all(10), childAspectRatio: 1.5, children: [
    for (final a in kAiAgents)
      Card(child: InkWell(borderRadius: BorderRadius.circular(12), onTap: () => _newChat(agentId: a['id'], system: a['system']),
        child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a['name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(a['desc'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ])))),
  ]);

  // 排行榜(与网站 ai-rankings.js 一致: 分类榜 + 综合分)
  Widget _rankList(BuildContext c) {
    final rows = kRankings[_rankCat] ?? const <Map<String, dynamic>>[];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(height: 34, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
        for (final cat in kRankCategories)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: ChoiceChip(
            label: Text(cat.$2, style: const TextStyle(fontSize: 10)), selected: _rankCat == cat.$1,
            onSelected: (_) => setState(() => _rankCat = cat.$1), visualDensity: VisualDensity.compact)),
      ])),
      const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text('数据综合自公开榜单约值快照 · 随版本更新',
        style: TextStyle(fontSize: 10, color: Colors.grey))),
      ListView(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), children: [
        for (var i = 0; i < rows.length; i++) () {
          final r = rows[i];
          final medal = i == 0 ? '🥇' : i == 1 ? '🥈' : i == 2 ? '🥉' : '${i + 1}';
          return ListTile(dense: true,
            leading: SizedBox(width: 56, child: Row(children: [
              SizedBox(width: 26, child: Text(medal, style: const TextStyle(fontSize: 12))),
              VendorIcon('${r['p']}', size: 22) ])),
            title: Text('${r['m']}', style: const TextStyle(fontSize: 13)),
            trailing: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Text('${r['s']}', style: const TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.bold))));
        }() ]),
    ]);
  }

  Widget _inspireList(BuildContext c) {
    final cats = <String>{ for (final i in kAiInspirations) i['cat'] ?? '' };
    return ListView(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), children: [ for (final cat in cats) ...[
      Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4), child: Text(cat, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey))),
      for (final i in kAiInspirations.where((e) => e['cat'] == cat))
        ListTile(dense: true, title: Text(i['title'] ?? '', style: const TextStyle(fontSize: 13)),
          subtitle: Text(i['prompt'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          onTap: () { input.text = i['prompt'] ?? ''; _closeDrawer();
            ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已填入输入框'))); }),
    ] ]);
  }
}
