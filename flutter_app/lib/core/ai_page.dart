// AI 模块: 1:1 复刻网站(thirdhub.pages.dev) AI 页
// 顶栏(菜单/模型胶囊/新对话) · 左侧抽屉(历史会话/AI模型/智能体/灵感广场 + Work/Chat)
// 手势: 边缘右滑开抽屉·抽屉左滑关闭·跟手拖动·松手≥40%吸附 · 输入栏贴底 · 流式渐进渲染
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai.dart';
import 'ai_agents_snapshot.dart';
import 'ai_providers_page.dart';

// 非对话模型过滤(与网站 NON_CHAT_RE 一致)
final _nonChatRe = RegExp(r'embed|whisper|tts|transcri|speech|audio|dall-e|image|imagen|moderation|rerank|babbage|davinci|clip|sora|veo|wanx|cogview|cogvideo|kolors|stable-diffusion|seedream|seedance|hailuo|sensemirage', caseSensitive: false);

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
  double _drawerP = 0; bool _drawerOpen = false; String _drawerTab = 'history'; String _drawerFilter = 'all'; bool _workMode = false;
  String _historyQuery = '';
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
    final (p, m) = await AiRegistry.lastModel();
    if (AiStore.sessions.isEmpty) { session = AiStore.create(p, m); }
    else { session = AiStore.sessions.first; }
    if (mounted) setState(() {});
  }

  // ── 抽屉手势(1:1: 边缘30px右滑开, 跟手, ≥0.4吸附, 抽屉上左滑关) ──
  double _dragStart = 0; bool _dragging = false;
  void _onDragStart(DragStartDetails d) { _dragStart = d.localPosition.dx; _dragging = true; }
  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final w = _drawerW(context);
    final base = _drawerOpen ? w : 0.0;
    setState(() => _drawerP = ((base + (d.localPosition.dx - _dragStart)) / w).clamp(0.0, 1.0));
  }
  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return; _dragging = false;
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
    try {
      final full = await AiChat.chat(provider: prov, model: session!.model, messages: session!.messages,
        onDelta: (d) { setState(() => streaming += d); if (!pinned) _jumpBottom(); });
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
    return Scaffold(body: GestureDetector(
      // 整页手势: 关闭态只响应从左边30px发起的右滑(网站一致), 打开态任意左滑关
      onHorizontalDragStart: (d) { if (_drawerOpen || d.localPosition.dx <= 30) _onDragStart(d); },
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: Stack(children: [
        // 主内容(抽屉打开时整体右移, 与网站一致)
        Transform.translate(offset: Offset(_drawerP * w, 0), child: _mainBody(c, dark)),
        // 遮罩(右侧露出1/5, 点击关闭)
        if (_drawerP > 0) Positioned.fill(child: GestureDetector(onTap: _closeDrawer,
          child: Container(color: Colors.black.withValues(alpha: 0.35 * _drawerP)))),
        // 抽屉
        Transform.translate(offset: Offset(-w * (1 - _drawerP), 0),
          child: SizedBox(width: w, child: _drawer(c, dark))),
      ])));
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
        ListTile(dense: true, leading: const Icon(Icons.smart_toy_outlined), title: const Text('厂商与 Key 管理', style: TextStyle(fontSize: 14)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2);
            Navigator.push(c, MaterialPageRoute(builder: (_) => const AiProvidersPage())); }),
      ]))));
  }

  // ── 抽屉(与网站一致: 头部 / AI模型入口 / Work·Chat / 四页签 / 底部搜索+新建) ──
  Widget _drawer(BuildContext c, bool dark) {
    final bg = dark ? const Color(0xFF181B22) : Colors.white;
    return Material(color: bg, elevation: 8, child: SafeArea(child: Column(children: [
      // 头部: 头像+名称+设置
      ListTile(dense: true, leading: const CircleAvatar(radius: 16, child: Icon(Icons.smart_toy, size: 16)),
        title: const Text('ThirdHub AI', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        trailing: const Icon(Icons.settings_outlined, size: 18),
        onTap: () { _closeDrawer(); Navigator.push(c, MaterialPageRoute(builder: (_) => const AiProvidersPage())); }),
      ListTile(dense: true, leading: const Icon(Icons.memory, size: 20), title: const Text('AI模型', style: TextStyle(fontSize: 14)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => setState(() => _drawerTab = 'models')),
      // Work / Chat 切换(仿Kimi)
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Container(
        decoration: BoxDecoration(color: dark ? const Color(0xFF0F1115) : const Color(0xFFF2F3F7), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          for (final m in [('work', 'Work', Icons.work_outline), ('chat', 'Chat', Icons.chat_bubble_outline)])
            Expanded(child: GestureDetector(onTap: () => setState(() => _workMode = m.$1 == 'work'),
              child: Container(padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
                  color: (m.$1 == 'work') == _workMode ? bg : Colors.transparent),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(m.$3, size: 15), const SizedBox(width: 4), Text(m.$2, style: const TextStyle(fontSize: 12))])))),
        ]))),
      const SizedBox(height: 4),
      Expanded(child: _workMode ? _workBox(c) : _chatBox(c)),
    ])));
  }

  Widget _workBox(BuildContext c) => GridView.count(crossAxisCount: 3, padding: const EdgeInsets.all(12), childAspectRatio: 1.1, children: [
    for (final e in [('新建任务', Icons.add), ('任务看板', Icons.grid_view), ('工作区', Icons.work_outline), ('插件', Icons.extension_outlined), ('定时', Icons.timer_outlined), ('远程', Icons.memory), ('应用', Icons.apps)])
      Card(child: InkWell(onTap: () => ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Work 模式准备开放'))),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(e.$2, size: 22), const SizedBox(height: 6), Text(e.$1, style: const TextStyle(fontSize: 11))]))),
  ]);

  Widget _chatBox(BuildContext c) => Column(children: [
    ListTile(dense: true, leading: const Icon(Icons.add, size: 20), title: const Text('新对话', style: TextStyle(fontSize: 14)),
      onTap: () => _newChat()),
    // 四页签
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
      for (final t in [('history', '历史会话'), ('models', 'AI模型'), ('agents', '智能体'), ('inspire', '灵感广场')])
        Expanded(child: GestureDetector(onTap: () => setState(() => _drawerTab = t.$1),
          child: Container(padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(width: 2,
              color: _drawerTab == t.$1 ? Theme.of(c).colorScheme.primary : Colors.transparent))),
            child: Text(t.$2, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: _drawerTab == t.$1 ? Theme.of(c).colorScheme.primary : Colors.grey))))),
    ])),
    if (_drawerTab == 'models') Padding(padding: const EdgeInsets.only(top: 6), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      for (final f in [('all', '全部'), ('chat', '聊天'), ('image', '图片'), ('video', '视频')])
        Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: ChoiceChip(
          label: Text(f.$2, style: const TextStyle(fontSize: 11)), selected: _drawerFilter == f.$1,
          onSelected: (_) => setState(() => _drawerFilter = f.$1), visualDensity: VisualDensity.compact)),
    ])),
    const SizedBox(height: 4),
    Expanded(child: _drawerTab == 'history' ? _historyList(c)
      : _drawerTab == 'models' ? _modelsList(c)
      : _drawerTab == 'agents' ? _agentsList(c) : _inspireList(c)),
    if (_drawerTab == 'history') Padding(padding: const EdgeInsets.all(10), child: Row(children: [
      Expanded(child: TextField(decoration: const InputDecoration(hintText: '搜索历史会话', isDense: true,
        prefixIcon: Icon(Icons.search, size: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none),
        filled: true), onChanged: (v) => setState(() => _historyQuery = v))),
      const SizedBox(width: 8),
      IconButton.filledTonal(icon: const Icon(Icons.add, size: 20), onPressed: () => _newChat()),
    ])),
  ]);

  Widget _historyList(BuildContext c) {
    var list = AiStore.sessions;
    if (_historyQuery.isNotEmpty) list = list.where((s) => s.title.contains(_historyQuery)).toList();
    if (list.isEmpty) return const Center(child: Text('暂无会话', style: TextStyle(color: Colors.grey, fontSize: 12)));
    return ListView(children: [ for (final s in list)
      Dismissible(key: Key(s.id), direction: DismissDirection.endToStart,
        background: Container(color: Colors.redAccent, alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete_outline, color: Colors.white)),
        onDismissed: (_) { AiStore.remove(s.id); if (session?.id == s.id) _newChat(); setState(() {}); },
        child: ListTile(dense: true, selected: session?.id == s.id,
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          subtitle: Text('${s.model} · ${s.messages.where((m) => m['role'] == 'user').length} 条', style: const TextStyle(fontSize: 10)),
          onTap: () { setState(() => session = s); _closeDrawer(); })) ]);
  }

  Widget _modelsList(BuildContext c) => ListView(children: [ for (final p in AiRegistry.providers) () {
    var models = switch (_drawerFilter) {
      'chat' => p.models.where((m) => !_nonChatRe.hasMatch(m)).toList(),
      'image' => p.image, 'video' => p.video, _ => p.models };
    if (models.isEmpty) return const SizedBox();
    return ExpansionTile(dense: true, initiallyExpanded: AiRegistry.providers.length <= 3,
      title: Text(p.name, style: const TextStyle(fontSize: 13)),
      subtitle: Text('${models.length} 个模型', style: const TextStyle(fontSize: 10)),
      children: [ for (final m in models)
        ListTile(dense: true, title: Text(m, style: const TextStyle(fontSize: 12)),
          trailing: session?.providerId == p.id && session?.model == m ? const Icon(Icons.check, size: 16, color: Colors.blueAccent) : null,
          onTap: () async { await AiRegistry.setLastModel(p.id, m);
            if (session != null) { session!.providerId = p.id; session!.model = m; }
            setState(() {}); AiStore.save(); _closeDrawer(); }) ]);
  }() ]);

  Widget _agentsList(BuildContext c) => GridView.count(crossAxisCount: 2, padding: const EdgeInsets.all(10), childAspectRatio: 1.5, children: [
    for (final a in kAiAgents)
      Card(child: InkWell(borderRadius: BorderRadius.circular(12), onTap: () => _newChat(agentId: a['id'], system: a['system']),
        child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a['name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(a['desc'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ])))),
  ]);

  Widget _inspireList(BuildContext c) {
    final cats = <String>{ for (final i in kAiInspirations) i['cat'] ?? '' };
    return ListView(children: [ for (final cat in cats) ...[
      Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4), child: Text(cat, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey))),
      for (final i in kAiInspirations.where((e) => e['cat'] == cat))
        ListTile(dense: true, title: Text(i['title'] ?? '', style: const TextStyle(fontSize: 13)),
          subtitle: Text(i['prompt'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          onTap: () { input.text = i['prompt'] ?? ''; _closeDrawer();
            ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已填入输入框'))); }),
    ] ]);
  }
}
