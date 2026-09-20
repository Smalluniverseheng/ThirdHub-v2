// AI 模块: 1:1 复刻网站(thirdhub.pages.dev) AI 页
// 顶栏(菜单/模型胶囊/新对话) · 左侧抽屉(历史会话/AI模型/智能体/灵感广场 + Work/Chat)
// 手势: 边缘右滑开抽屉·抽屉左滑关闭·跟手拖动·松手≥40%吸附 · 输入栏贴底 · 流式渐进渲染
import '../main.dart' show RootNav;
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'ai.dart';
import 'ai_agent.dart';
import 'ai_agent_page.dart';
import 'ai_agents_snapshot.dart';
import 'ai_intros.dart';
import 'ai_rankings_snapshot.dart';
import 'ai_providers_page.dart';
import 'ai_skills.dart';
import 'local_tools.dart';
import 'mcp_page.dart';
import 'vendor_icons.dart';
import 'tts.dart';

// 边缘滑动识别器: 按下即抢占(外层 PageView 抢不走), 与网站边缘30px右滑开抽屉一致
class _EdgeSwipeRecognizer extends OneSequenceGestureRecognizer {
  double sx = 0; double sy = 0; bool active = false; bool claimed = false;
  final List<(int, double)> _trail = []; // (毫秒, dx) 速度估计
  void Function(double dx)? onUpdate; void Function(double dx, double vx)? onEnd;
  @override String get debugDescription => 'edgeSwipe';
  @override void addAllowedPointer(PointerDownEvent e) {
    sx = e.position.dx; sy = e.position.dy; active = true; claimed = false;
    startTrackingPointer(e.pointer);
  }
  @override void handleEvent(PointerEvent e) {
    if (!active) return;
    if (e is PointerMoveEvent) {
      final dx = e.position.dx - sx, dy = e.position.dy - sy;
      if (!claimed) {
        // 明确的横向右滑意图才认领(阈值12px且水平位移大于垂直), 避免误触/列表滚动误开抽屉
        if (dx > 12 && dx > dy.abs() * 1.5) { claimed = true; resolve(GestureDisposition.accepted); }
        else if (dy.abs() > 12 || dx < -8) { // 垂直滚动或左滑 → 放弃
          active = false; stopTrackingPointer(e.pointer); return;
        } else { return; }
      }
      _trail.add((e.timeStamp.inMilliseconds, dx));
      if (_trail.length > 8) _trail.removeAt(0);
      onUpdate?.call(dx);
    }
    if (e is PointerUpEvent || e is PointerCancelEvent) {
      final wasClaimed = claimed; final dx = e.position.dx - sx;
      // 用最近 100ms 的位移估算甩动速度(px/s), 提供惯性判定
      double vx = 0;
      if (_trail.length >= 2) {
        final now = e.timeStamp.inMilliseconds;
        final old = _trail.firstWhere((t) => now - t.$1 <= 100, orElse: () => _trail.first);
        final dt = now - old.$1;
        if (dt > 0) vx = (dx - old.$2) / dt * 1000;
      }
      _trail.clear();
      active = false; claimed = false; stopTrackingPointer(e.pointer);
      if (wasClaimed) onEnd?.call(e is PointerUpEvent ? dx : 0, vx);
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
    // 自动清理没有任何消息的空会话(不浪费空间)
    final before = sessions.length;
    sessions.removeWhere((s) => s.messages.isEmpty);
    if (sessions.length != before) await save();
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
class AiSection extends StatefulWidget {
  // 顶栏「新会话」按钮: +1 触发(RootNav 调用)
  static final ValueNotifier<int> newSessionTick = ValueNotifier(0); const AiSection({super.key}); @override State<AiSection> createState() => _AiSec(); }
class _AiSec extends State<AiSection> with SingleTickerProviderStateMixin {
  AiSession? session; bool sending = false; String streaming = '';
  // 思考链 + 工具步骤(当前正在生成的消息)
  String _reasoning = ''; final List<Map<String, String>> _steps = [];
  // 消息排队(Kimi 同款): 生成中继续发消息进入队列
  final List<String> _queue = []; bool queuePaused = false;
  // 技能注入 + 上下文管理
  String _skillId = ''; int _ctxTurns = 0; // 0=全部
  final input = TextEditingController(); final scroll = ScrollController();
  bool pinned = false; // 上拉钉住(回到底部按钮)
  // 抽屉状态
  double _drawerP = 0; bool _drawerOpen = false; String _drawerTab = 'history'; String _drawerFilter = 'all'; String _historyQuery = '';
  String _rankCat = 'overall'; bool _webSearchOn = false; bool _mcpOn = true;
  // TH-Agent v1: 文本工具协议兜底(不支持原生 function-calling 的厂商也能用工具) / MCP 工具是否需确认
  bool _toolFallback = true; bool _confirmMcp = false;
  StreamSubscription? _regSub;

  double _drawerW(BuildContext c) => (MediaQuery.of(c).size.width * 0.8).clamp(0.0, 340.0);

  @override void initState() { super.initState(); _boot();
    _regSub = AiRegistry.onChange.listen((_) { if (mounted) setState(() {}); });
    // 切模块时静默收起抽屉(修复: 切模块回来侧边栏莫名展开/遮罩残留)
    RootNav.moduleTick.addListener(_onModuleTick);
    // 右上角「新会话」按钮触发
    AiSection.newSessionTick.addListener(_onNewSessionTick);
    scroll.addListener(() {
      final dist = scroll.position.maxScrollExtent - scroll.position.pixels;
      final p = dist > 60;
      if (p != pinned) setState(() => pinned = p);
    });
  }
  @override void dispose() {
    _regSub?.cancel();
    RootNav.moduleTick.removeListener(_onModuleTick);
    AiSection.newSessionTick.removeListener(_onNewSessionTick);
    input.dispose(); scroll.dispose(); super.dispose(); }
  void _onModuleTick() { if (RootNav.currentModuleKey != 'AI') _closeDrawerSilent(); }
  Future<void> _onNewSessionTick() async {
    final (p, m) = await AiRegistry.lastModel(); // 与启动逻辑一致: 沿用上次用的模型
    setState(() { session = AiStore.create(p, m); _closeDrawerSilent(); });
    HapticFeedback.lightImpact();
  }
  Future<void> _boot() async {
    await AiStore.load();
    await Mcp.init();
    await AiAgents.load();
    await AiInstruct.load();
    await AiMemory.load();
    final prefs = await SharedPreferences.getInstance();
    _webSearchOn = prefs.getBool('ai_websearch_on') ?? false;
    _mcpOn = prefs.getBool('ai_mcp_on') ?? true;
    _skillId = prefs.getString('ai_skill') ?? '';
    _ctxTurns = prefs.getInt('ai_ctx_turns') ?? 0;
    _toolFallback = prefs.getBool('ai_tool_fallback') ?? true;
    _confirmMcp = prefs.getBool('ai_confirm_mcp') ?? false;
    final (p, m) = await AiRegistry.lastModel();
    if (AiStore.sessions.isEmpty) { session = AiStore.create(p, m); }
    else { session = AiStore.sessions.first; }
    if (mounted) setState(() {});
  }

  // ── 抽屉手势(边缘36px右滑开·跟手·速度/距离双判定·惯性动画·震动反馈) ──
  double _cum = 0;
  late final AnimationController _drawerAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  void _applyDrag(double dx) {
    final w = _drawerW(context);
    final base = _drawerOpen ? w : 0.0;
    setState(() => _drawerP = ((base + dx) / w).clamp(0.0, 1.0));
  }
  void _settleDrag(double dx, double vx) {
    _applyDrag(dx);
    // 速度优先(惯性): 快甩即开/关; 慢拖看距离阈值 0.4
    final open = vx > 350 ? true : vx < -350 ? false : _drawerP >= 0.4;
    _animateDrawerTo(open);
  }
  void _animateDrawerTo(bool open) {
    if (open && !_drawerOpen) HapticFeedback.mediumImpact(); // 滑出抽屉震动
    if (!open && _drawerOpen) HapticFeedback.lightImpact(); // 收起轻震
    _drawerOpen = open;
    final from = _drawerP;
    _drawerAnim.stop();
    _drawerAnim.removeListener(_drawerTick);
    void tick() => setState(() => _drawerP = from + ((open ? 1.0 : 0.0) - from) * Curves.easeOutCubic.transform(_drawerAnim.value));
    _drawerTick = tick;
    _drawerAnim.addListener(tick);
    _drawerAnim.forward(from: 0);
  }
  VoidCallback _drawerTick = () {};
  void _openDrawer() { _animateDrawerTo(true); }
  void _closeDrawer() => _animateDrawerTo(false);
  void _closeDrawerSilent() { // 切模块时静默收起(不震动不动画)
    _drawerAnim.stop();
    if (_drawerOpen || _drawerP > 0) setState(() { _drawerOpen = false; _drawerP = 0.0; });
  }

  // ── 模型快捷切换面板(Kimi 同款): 常用模型(可在抽屉长按模型设置) + 思考等级 + 对话长度 ──
  static final _thinkRe = RegExp(r'reason|thinking|qwq|\bo1|\bo3|\bo4|\br1|k1\.5|k2|glm-4\.5|hunyuan-t', caseSensitive: false);
  bool get _supportsThinking => session != null && _thinkRe.hasMatch(session!.model);
  Future<List<String>> _quickModels() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList('ai_quick_models') ?? [];
  }
  Future<void> _toggleQuick(String prov, String model) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList('ai_quick_models') ?? [];
    final e = '$prov|$model';
    if (list.contains(e)) { list.remove(e); } else { list.insert(0, e); if (list.length > 3) list.removeLast(); }
    await p.setStringList('ai_quick_models', list);
  }
  Future<String> _thinkLevel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('ai_think_${session?.model}') ?? '标准';
  }
  void _quickSheet() {
    HapticFeedback.selectionClick();
    showModalBottomSheet(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) {
      return FutureBuilder<List<String>>(future: _quickModels(), builder: (_, snap) {
        final list = snap.data ?? (session == null ? <String>[] : ['${session!.providerId}|${session!.model}']);
        return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(8, 16, 8, 16), child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in list) () {
            final parts = e.split('|'); final pid = parts.first; final mid = parts.length > 1 ? parts.sublist(1).join('|') : '';
            final prov = AiRegistry.byId(pid);
            final on = session?.providerId == pid && session?.model == mid;
            return ListTile(
              leading: VendorIcon(pid, size: 26),
              title: Text(mid, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Text(prov?.name ?? pid, style: const TextStyle(fontSize: 11)),
              trailing: on ? const Icon(Icons.check, color: Colors.blueAccent) : IconButton(icon: const Icon(Icons.star_border, size: 18),
                tooltip: '移出常用', onPressed: () async { await _toggleQuick(pid, mid); setD(() {}); }),
              onTap: () async { await AiRegistry.setLastModel(pid, mid);
                if (session != null) { session!.providerId = pid; session!.model = mid; }
                setState(() {}); AiStore.save(); if (c2.mounted) Navigator.pop(c2); });
          }(),
          if (list.isEmpty) const Padding(padding: EdgeInsets.all(20),
            child: Text('还没有常用模型 · 去抽屉模型列表长按任意模型设为常用', style: TextStyle(fontSize: 12, color: Colors.grey))),
          const Divider(),
          ListTile(dense: true, leading: const Icon(Icons.add_circle_outline, size: 20), title: const Text('新会话', style: TextStyle(fontSize: 14)),
            subtitle: const Text('快速对话, 即时响应', style: TextStyle(fontSize: 11)),
            onTap: () { Navigator.pop(c2); _newChat(); }),
          if (_supportsThinking)
            ListTile(dense: true, leading: const Icon(Icons.psychology_outlined, size: 20), title: const Text('思考等级', style: TextStyle(fontSize: 14)),
              trailing: FutureBuilder<String>(future: _thinkLevel(), builder: (_, s) => Text(s.data ?? '标准', style: const TextStyle(fontSize: 12, color: Colors.grey))),
              onTap: () async {
                final p = await SharedPreferences.getInstance();
                const lv = ['低', '标准', '高'];
                final cur = p.getString('ai_think_${session?.model}') ?? '标准';
                final nxt = lv[(lv.indexOf(cur) + 1) % 3];
                await p.setString('ai_think_${session?.model}', nxt);
                setD(() {});
              }),
          ListTile(dense: true, leading: const Icon(Icons.history_edu, size: 20), title: const Text('对话长度', style: TextStyle(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () { Navigator.pop(c2); _ctxSheet(context); }),
        ])));
      });
    }));
  }


  void _newChat({String? agentId, String? system}) {
    // 空对话复用: 当前会话一条消息都没有时直接沿用, 不产生垃圾会话
    if (session != null && session!.messages.isEmpty && agentId == null && system == null) {
      _closeDrawer(); return;
    }
    setState(() { session = AiStore.create(session?.providerId ?? 'deepseek', session?.model ?? 'deepseek-chat', agentId: agentId, system: system); streaming = ''; });
    _closeDrawer();
  }

  // ── 厂商能力自适应: 记住"这家不吃原生 tools 参数", 之后直接把工具清单写进 system 走文本协议 ──
  static const _kNoNative = 'ai_no_native_tools';
  Future<bool> _noNativeTools(String provId) async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kNoNative) ?? const []).contains(provId);
  }
  Future<void> _markNoNativeTools(String provId) async {
    final p = await SharedPreferences.getInstance();
    final l = p.getStringList(_kNoNative) ?? <String>[];
    if (l.contains(provId)) return;
    l.add(provId);
    await p.setStringList(_kNoNative, l);
  }

  // 工具审批闸门: confirm 级工具(改文件/删文件/写剪贴板/打开链接/分享/朗读)默认要用户点一下
  Future<bool> _approveTool(String name, Map<String, dynamic> args) async {
    if (!mounted) return false;
    var pretty = '';
    try { pretty = const JsonEncoder.withIndent('  ').convert(args); } catch (_) { pretty = '$args'; }
    if (pretty.length > 900) pretty = '${pretty.substring(0, 900)}…';
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Row(children: [const Icon(Icons.gpp_maybe_outlined, size: 20), const SizedBox(width: 8),
        const Expanded(child: Text('AI 想执行一个操作', style: TextStyle(fontSize: 15)))]),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(
          color: Theme.of(c).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8)),
          child: SelectableText(pretty.isEmpty ? '(无参数)' : pretty, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('拒绝')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('允许执行')),
      ]));
    return ok == true;
  }

  // 统一工具执行: 本机工具(local_*)走 LocalTools, 其余走 MCP
  Future<String> _runTool(String serverId, String name, Map<String, dynamic> args) async {
    final agent = AiAgents.byId(session?.agentId);
    final isLocal = serverId == 'local';
    final needConfirm = !(agent?.autoApprove ?? false) &&
      (AiTools.risk(name) == ToolRisk.confirm || (!isLocal && _confirmMcp));
    if (needConfirm && !await _approveTool(name, args)) return '用户拒绝了本次工具调用「$name」, 请改用其他方式或直接说明你无法完成。';
    if (isLocal) return LocalTools.call(name, args);
    final result = await Mcp.callTool(serverId, name, args);
    final out = [ for (final c in (result['content'] as List? ?? [])) '${c['text'] ?? c}' ].join('\n');
    return out.isEmpty ? jsonEncode(result) : out;
  }

  Future<void> _send() async {
    final text = input.text.trim(); if (text.isEmpty || session == null) return;
    // 生成中 → 进入排队(Kimi 同款)
    if (sending) { input.clear(); setState(() => _queue.add(text));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已加入排队, 上一条完成后自动发送')));
      return; }
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
      sending = true; streaming = ''; _reasoning = ''; _steps.clear();
    });
    AiStore.save();
    _jumpBottom();
    // 上下文管理: 系统消息 + 最近 N 轮(0=全部), 技能注入上下文
    var msgs = session!.messages;
    if (_ctxTurns > 0) {
      final sys = msgs.where((m) => m['role'] == 'system').toList();
      final rest = msgs.where((m) => m['role'] != 'system').toList();
      final keep = rest.length > _ctxTurns ? rest.sublist(rest.length - _ctxTurns) : rest;
      msgs = [...sys, ...keep];
    }
    // ── TH-Agent v1 上下文装配 ──
    // 顺序(由弱到强): 全局指令/人格 → 智能体人格 → 技能 → 长期记忆 → 会话钉注 → 工具清单
    final agent = AiAgents.byId(session!.agentId);
    final pins = await AiPins.get(session!.id);
    var skillSys = '';
    if (_skillId.isNotEmpty) {
      for (final s in kAiSkills) { if (s['id'] == _skillId) { skillSys = '${s['system']}'; break; } }
    }
    // 工具表: MCP + 本机, 并受当前智能体的授权(allow/deny)约束
    final toolTable = AiTools.filter(
      _mcpOn ? [...Mcp.allTools(), ...LocalTools.schemas()] : <Map<String, dynamic>>[], agent);
    // 工具清单只在"该厂商确实不吃原生 tools 参数"(前几轮探测出来的)时才注入 system —— 否则平白多烧 token
    final noNative = await _noNativeTools(prov.id);
    final stack = await AiContext.systemStack(agent: agent, skillSystem: skillSys, pins: pins,
      toolManifest: _toolFallback && noNative && toolTable.isNotEmpty, tools: toolTable);
    msgs = [...stack, ...msgs.where((m) => m['role'] != 'system')];
    // 上下文预算压缩: 超预算时把早期消息折叠成摘要, 保留最近若干轮原文
    msgs = AiCompress.compress(msgs);
    // 联网搜索: 先检索再把结果注入上下文(会话里只保留用户原文)
    if (_webSearchOn) {
      try {
        if (await WebSearch.configured()) {
          setState(() => _steps.add({'icon': '🔍', 'text': '联网搜索: $text', 'status': 'running'}));
          final items = await WebSearch.search(text);
          if (items.isNotEmpty) {
            msgs = [...msgs.sublist(0, msgs.length - 1),
              {'role': 'user', 'content': WebSearch.toContext(text, items)}, msgs.last];
          }
          setState(() { _steps.last['status'] = 'done'; _steps.last['text'] = '联网搜索完成 · ${items.length} 条结果'; });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('联网搜索未配置 · 点输入框左侧 + → 联网搜索 去配置')));
        }
      } catch (e) {
        setState(() { if (_steps.isNotEmpty) { _steps.last['status'] = 'error'; } });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('联网搜索失败: $e')));
      }
    }
    try {
      // 思考等级: 仅支持思考类模型时注入 reasoning_effort
      Map<String, dynamic>? extra;
      if (_thinkRe.hasMatch(session!.model)) {
        final lv = await _thinkLevel();
        if (lv != '标准') extra = {'reasoning_effort': lv == '低' ? 'low' : 'high'};
      }
      final full = await AiChat.chat(provider: prov, model: session!.model, messages: msgs,
        mcpTools: toolTable.isEmpty ? null : toolTable,
        toolExecutor: _runTool, extraBody: extra,
        // 智能体决定这轮最多能"想-做-看"几轮; 不支持原生 function-calling 的厂商走文本协议
        maxRounds: agent?.maxRounds ?? 8, textToolFallback: _toolFallback,
        onToolsUnsupported: () => _markNoNativeTools(prov.id),
        onReasoning: (r) { setState(() { _reasoning += r; }); if (!pinned) _jumpBottom(); },
        onToolCall: (name) { setState(() {
          for (final s in _steps) { if (s['status'] == 'running') s['status'] = 'done'; }
          _steps.add({'icon': '🛠', 'text': '正在调用工具 $name', 'status': 'running'});
        }); if (!pinned) _jumpBottom(); },
        onDelta: (d) { setState(() {
          for (final s in _steps) { if (s['status'] == 'running') s['status'] = 'done'; }
          streaming += d; }); if (!pinned) _jumpBottom(); });
      setState(() {
        for (final s in _steps) { if (s['status'] == 'running') s['status'] = 'done'; }
        session!.messages.add({'role': 'assistant', 'content': full,
          if (_reasoning.isNotEmpty) 'reasoning': _reasoning,
          if (_steps.isNotEmpty) 'steps': jsonEncode(_steps)});
        streaming = '';
      });
    } catch (e) {
      setState(() { session!.messages.add({'role': 'assistant', 'content': '出错了: $e',
        if (_reasoning.isNotEmpty) 'reasoning': _reasoning,
        if (_steps.isNotEmpty) 'steps': jsonEncode(_steps)}); streaming = ''; });
    }
    AiStore.save();
    setState(() { sending = false; _reasoning = ''; _steps.clear(); });
    _jumpBottom();
    // 队列下一条自动发送
    if (!queuePaused && _queue.isNotEmpty) { input.text = _queue.removeAt(0); _send(); }
  }

  // 排队面板: 立即发送/编辑/删除 + 暂停排队/清空排队
  void _queueSheet() {
    showModalBottomSheet(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 4), child: Row(children: [
        Text('排队中 (${_queue.length})', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const Spacer(),
        PopupMenuButton<String>(icon: const Icon(Icons.more_vert, size: 20), onSelected: (v) {
          if (v == 'pause') { setState(() => queuePaused = !queuePaused); setD(() {}); }
          if (v == 'clear') { setState(() => _queue.clear()); Navigator.pop(c2); }
        }, itemBuilder: (_) => [
          PopupMenuItem(value: 'pause', child: Text(queuePaused ? '▶ 继续排队' : '⏸ 暂停排队')),
          const PopupMenuItem(value: 'clear', child: Text('🗑 清空排队', style: TextStyle(color: Colors.redAccent))),
        ]),
      ])),
      Flexible(child: ListView(shrinkWrap: true, children: [
        for (var i = 0; i < _queue.length; i++)
          Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(radius: 10, child: Text('${i + 1}', style: const TextStyle(fontSize: 10))),
              const SizedBox(width: 8),
              Expanded(child: Text(_queue[i], maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
            ]),
            Row(children: [
              TextButton.icon(onPressed: () { final t = _queue.removeAt(i); input.text = t; Navigator.pop(c2); _send(); },
                icon: const Icon(Icons.send, size: 14), label: const Text('立即发送', style: TextStyle(fontSize: 12))),
              TextButton.icon(onPressed: () { input.text = _queue.removeAt(i); setState(() {}); Navigator.pop(c2); },
                icon: const Icon(Icons.edit_outlined, size: 14), label: const Text('编辑', style: TextStyle(fontSize: 12))),
              TextButton.icon(onPressed: () { setState(() => _queue.removeAt(i)); setD(() {}); if (_queue.isEmpty) Navigator.pop(c2); },
                icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent), label: const Text('删除', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
            ]),
          ]))),
      ])),
    ]))));
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
          onHorizontalDragEnd: _drawerOpen ? (d) { _settleDrag(_cum, d.velocity.pixelsPerSecond.dx); } : null,
          child: _drawer(c, dark)))),
      // 边缘热区: 按下即抢占(网站30px), 关闭态右滑开抽屉
      if (!_drawerOpen) Positioned(left: 0, top: 0, bottom: 0, width: 36,
        child: RawGestureDetector(gestures: { _EdgeSwipeRecognizer: GestureRecognizerFactoryWithHandlers<_EdgeSwipeRecognizer>(
          () => _EdgeSwipeRecognizer(),
          (r) { r.onUpdate = (dx) { if (dx > 0) _applyDrag(dx); };
                r.onEnd = (dx, vx) { if (dx > 0) _settleDrag(dx, vx); }; }) },
          child: Container(color: Colors.transparent))),
    ]));
  }

  // ── 主区: 顶栏 + 消息 + 输入栏 ──
  Widget _mainBody(BuildContext c, bool dark) {
    final s = session;
    return Scaffold(
      appBar: AppBar(leading: IconButton(icon: const Icon(Icons.menu), onPressed: _openDrawer),
        title: GestureDetector(onTap: _quickSheet,
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: Theme.of(c).cardTheme.color, borderRadius: BorderRadius.circular(18)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(s == null || s.model.isEmpty ? '选择模型' : s.model,
                style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              const Icon(Icons.arrow_drop_down, size: 18)]))),
        actions: [IconButton(icon: const Icon(Icons.add), tooltip: '新对话', onPressed: () => _newChat())]),
      body: Column(children: [
        // 排队提示条(Kimi 同款: ☰ 排队 | N 条消息排队中)
        if (_queue.isNotEmpty) InkWell(onTap: _queueSheet, child: Container(
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(color: Theme.of(c).cardTheme.color, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(queuePaused ? Icons.pause_circle_outline : Icons.playlist_play, size: 18, color: Colors.grey),
            const SizedBox(width: 8),
            Expanded(child: Text('排队 | ${_queue.length} 条消息排队中${queuePaused ? ' (已暂停)' : ''}',
              style: const TextStyle(fontSize: 13))),
            const Icon(Icons.keyboard_arrow_up, size: 18, color: Colors.grey),
          ]))),
        Expanded(child: s == null ? const Center(child: CircularProgressIndicator())
          : (s.messages.where((m) => m['role'] != 'system').isEmpty && streaming.isEmpty && _reasoning.isEmpty && _steps.isEmpty)
            ? _emptyHint(c) : _msgList(c, s)),
        _inputBar(c, dark),
      ]));
  }

  Widget _emptyHint(BuildContext c) {
    // 欢迎页问候(与网站一致): 「你好，我是 X」+ 该模型简介
    final s = session;
    final prov = s == null ? null : AiRegistry.byId(s.providerId);
    final hasModel = s != null && s.model.isNotEmpty;
    return Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 28), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.smart_toy_outlined, size: 56, color: Colors.grey),
      const SizedBox(height: 10),
      if (hasModel) ...[
        Text('你好，我是 ${s.model}', textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(modelIntro(s.providerId, s.model, prov?.name ?? ''), textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey, fontSize: 12, height: 1.5)),
        const SizedBox(height: 10),
      ],
      Text('${AiRegistry.providers.length} 家厂商 · ${AiRegistry.providers.fold<int>(0, (a, b) => a + b.models.length)} 个模型',
        style: const TextStyle(color: Colors.grey, fontSize: 12)),
      const SizedBox(height: 4),
      const Text('左滑边缘或点菜单打开抽屉: 历史/模型/智能体/灵感', style: TextStyle(color: Colors.grey, fontSize: 11)),
    ])));
  }

  // 思考链卡片(Kimi 同款: 思考已完成/思考中…, 可展开)
  Widget _thinkingCard(BuildContext c, String reasoning, bool done) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    return Container(margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(color: dark ? const Color(0xFF1A1D26) : const Color(0xFFF6F5FA),
        borderRadius: BorderRadius.circular(12)),
      child: Theme(data: Theme.of(c).copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
        dense: true, initiallyExpanded: !done,
        title: Row(children: [
          Icon(done ? Icons.check_circle_outline : Icons.psychology_outlined, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Text(done ? '思考已完成' : '思考中…', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        children: [Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Text(reasoning, style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.5)))],
      )));
  }

  // 工具步骤卡片(Kimi 同款: 步骤列表 + 状态)
  Widget _stepsCard(BuildContext c, List<Map<String, String>> steps, bool done) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    return Container(margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(color: dark ? const Color(0xFF1A1D26) : const Color(0xFFF6F5FA),
        borderRadius: BorderRadius.circular(12)),
      child: Theme(data: Theme.of(c).copyWith(dividerColor: Colors.transparent), child: ExpansionTile(
        dense: true, initiallyExpanded: !done,
        title: Row(children: [
          Icon(done ? Icons.playlist_add_check : Icons.handyman_outlined, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Text(done ? '工具调用完成 (${steps.length})' : steps.last['text'] ?? '工具调用中…',
            style: const TextStyle(fontSize: 12, color: Colors.grey), overflow: TextOverflow.ellipsis),
        ]),
        children: [ for (final s in steps) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Row(children: [
            Text(s['icon'] ?? '•', style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(child: Text(s['text'] ?? '', style: const TextStyle(fontSize: 12, color: Colors.grey), overflow: TextOverflow.ellipsis)),
            Icon(s['status'] == 'done' ? Icons.check : s['status'] == 'error' ? Icons.error_outline : Icons.hourglass_top,
              size: 13, color: s['status'] == 'error' ? Colors.redAccent : Colors.grey),
          ])) ],
      )));
  }

  Widget _msgList(BuildContext c, AiSession s) {
    final list = s.messages.where((m) => m['role'] != 'system').toList();
    final liveActive = streaming.isNotEmpty || _reasoning.isNotEmpty || _steps.isNotEmpty;
    return Stack(children: [
      ListView.builder(controller: scroll, padding: const EdgeInsets.all(14),
        itemCount: list.length + (liveActive ? 1 : 0), itemBuilder: (_, i) {
          final live = i >= list.length;
          final m = live ? {'role': 'assistant', 'content': streaming} : list[i];
          final reasoning = live ? _reasoning : (m['reasoning'] ?? '');
          List<Map<String, String>> steps = live ? _steps : [];
          if (!live && m['steps'] != null) {
            try { steps = [ for (final e in jsonDecode(m['steps']!) as List) Map<String, String>.from(e) ]; } catch (_) {}
          }
          final me = m['role'] == 'user';
          final accent = Theme.of(c).colorScheme.primary;
          final dark = Theme.of(c).brightness == Brightness.dark;
          final bubble = GestureDetector(onLongPress: () => _msgActions(c, m['content'] ?? ''),
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
          final row = Row(
            mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start, children: me
              ? [Flexible(child: bubble), const SizedBox(width: 8), avatar]
              : [avatar, const SizedBox(width: 8), Flexible(child: bubble)]);
          // 助手消息: 思考链 + 工具步骤卡片在气泡上方(Kimi 同款)
          if (!me && (reasoning.isNotEmpty || steps.isNotEmpty)) {
            return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              avatar, const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (reasoning.isNotEmpty) _thinkingCard(c, reasoning, !live || streaming.isNotEmpty || !sending),
                if (steps.isNotEmpty) _stepsCard(c, steps, !live || streaming.isNotEmpty || !sending),
                if (live && streaming.isEmpty) const Padding(padding: EdgeInsets.all(8),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)))
                else row.children[2], // 气泡(不带重复头像)
              ])) ]));
          }
          return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: row);
        }),
      if (pinned) Positioned(right: 16, bottom: 12, child: FloatingActionButton.small(
        onPressed: () { setState(() => pinned = false); _jumpBottom(); },
        child: const Icon(Icons.arrow_downward, size: 18))),
    ]);
  }

  // 长按消息: 复制 / 朗读(系统离线 TTS)
  void _msgActions(BuildContext c, String text) {
    if (text.isEmpty) return;
    showModalBottomSheet(context: c, builder: (c2) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.copy_outlined), title: const Text('复制'),
        onTap: () { Clipboard.setData(ClipboardData(text: text)); Navigator.pop(c2);
          ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已复制'))); }),
      ListTile(leading: const Icon(Icons.record_voice_over_outlined), title: const Text('朗读'),
        subtitle: const Text('系统离线语音引擎, 无需联网', style: TextStyle(fontSize: 11)),
        onTap: () { Navigator.pop(c2); TtsManager.speak(text); }),
      ListTile(leading: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent), title: const Text('停止朗读'),
        onTap: () { Navigator.pop(c2); TtsManager.stop(); }),
    ])));
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
          title: const Text('工具调用(Harness)', style: TextStyle(fontSize: 14)),
          subtitle: Text('本机工具 ${LocalTools.all.length} 个 + MCP ${Mcp.servers.where((s) => s.enabled && s.status == 'connected').length} 个服务 · 多轮自动调用', style: const TextStyle(fontSize: 11)),
          value: _mcpOn, onChanged: (v) async {
            setState(() => _mcpOn = v); setS(() {});
            final p = await SharedPreferences.getInstance(); await p.setBool('ai_mcp_on', v); })),
        ListTile(dense: true, leading: const Icon(Icons.phone_android), title: const Text('本机工具清单', style: TextStyle(fontSize: 14)),
          subtitle: const Text('设备信息/剪贴板/朗读/文件/分享/打开链接…', style: TextStyle(fontSize: 11)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2); _localToolsSheet(c); }),
        ListTile(dense: true, leading: const Icon(Icons.compress), title: const Text('上下文管理', style: TextStyle(fontSize: 14)),
          subtitle: Text(_ctxTurns == 0 ? '携带全部历史消息' : '只携带最近 $_ctxTurns 条消息', style: const TextStyle(fontSize: 11)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2); _ctxSheet(c); }),
        ListTile(dense: true, leading: const Icon(Icons.cable), title: const Text('MCP 服务管理', style: TextStyle(fontSize: 14)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2);
            Navigator.push(c, MaterialPageRoute(builder: (_) => const McpPage())); }),
        ListTile(dense: true, leading: const Icon(Icons.smart_toy_outlined), title: const Text('厂商与 Key 管理', style: TextStyle(fontSize: 14)),
          trailing: const Icon(Icons.chevron_right), onTap: () { Navigator.pop(c2);
            Navigator.push(c, MaterialPageRoute(builder: (_) => const AiProvidersPage())); }),
      ]))));
  }

  // 本机工具清单弹层
  void _localToolsSheet(BuildContext c) {
    showModalBottomSheet(context: c, builder: (c2) => SafeArea(child: SizedBox(height: 420, child: Column(children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('本机工具(开启工具调用后 AI 自动使用)', style: TextStyle(fontWeight: FontWeight.bold))),
      Expanded(child: ListView(children: [ for (final t in LocalTools.all)
        ListTile(dense: true, leading: const Icon(Icons.build_circle_outlined, size: 20),
          title: Text(t.name, style: const TextStyle(fontSize: 13)),
          subtitle: Text(t.description, style: const TextStyle(fontSize: 11, color: Colors.grey))) ])),
    ]))));
  }

  // 上下文管理弹层
  void _ctxSheet(BuildContext c) {
    showModalBottomSheet(context: c, builder: (c2) => StatefulBuilder(builder: (c2, setD) => SafeArea(child: Padding(padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('上下文管理', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('限制每次请求携带的历史消息条数, 省 token、防超长; 系统提示词始终携带',
          style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 8),
        for (final n in [0, 6, 10, 20, 40])
          RadioListTile<int>(dense: true, value: n, groupValue: _ctxTurns,
            title: Text(n == 0 ? '全部历史' : '最近 $n 条', style: const TextStyle(fontSize: 13)),
            onChanged: (v) async { setState(() => _ctxTurns = v!); setD(() {});
              final p = await SharedPreferences.getInstance(); await p.setInt('ai_ctx_turns', v!); }),
      ])))));
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
      ])));
    }));
  }



  // ── 抽屉(与网站一致: 头部 / AI模型入口 / Work·Chat / 四页签 / 底部搜索+新建) ──
  Widget _drawer(BuildContext c, bool dark) {
    final bg = dark ? const Color(0xFF181B22) : Colors.white;
    // 与网站一致: 头部 + 页签 + 内容滚动区 + 吸底栏(搜索历史对话 + 新对话)
    // 历史页签的搜索/新建固定在抽屉底部, 不再跟着列表一起滚走
    return Material(color: bg, elevation: 8, child: SafeArea(child: Column(children: [
      // 头部: 头像+名称+设置
      ListTile(dense: true, leading: const CircleAvatar(radius: 16, child: Icon(Icons.smart_toy, size: 16)),
        title: const Text('ThirdHub AI', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        trailing: const Icon(Icons.settings_outlined, size: 18),
        onTap: () { _closeDrawer(); Navigator.push(c, MaterialPageRoute(builder: (_) => const AiProvidersPage())); }),
      ListTile(dense: true, leading: const Icon(Icons.memory, size: 20), title: const Text('AI模型', style: TextStyle(fontSize: 14)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => setState(() => _drawerTab = 'models')),
      const SizedBox(height: 4),
      // 四页签(顶部, 固定不滚)
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
      // 内容滚动区
      Expanded(child: ListView(children: [
        _drawerTab == 'history' ? _historyList(c)
          : _drawerTab == 'models' ? _modelsList(c)
          : _drawerTab == 'agents' ? _agentsList(c)
          : _drawerTab == 'rank' ? _rankList(c) : _inspireList(c),
      ])),
      // 吸底栏(仅历史页签): 搜索历史对话 + 新对话 —— 与网站 ai-drawer-bottom 一致
      if (_drawerTab == 'history') Padding(padding: const EdgeInsets.all(10), child: Row(children: [
        Expanded(child: TextField(decoration: const InputDecoration(hintText: '搜索历史对话', isDense: true,
          prefixIcon: Icon(Icons.search, size: 18),
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none),
          filled: true), onChanged: (v) => setState(() => _historyQuery = v))),
        const SizedBox(width: 8),
        IconButton.filledTonal(icon: const Icon(Icons.add, size: 20), tooltip: '新对话', onPressed: () => _newChat()),
      ])),
    ])));
  }

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
          subtitle: Text(modelIntro(p.id, m, p.name) + (_thinkRe.hasMatch(m) ? ' · 支持思考等级' : ''),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Colors.grey, height: 1.35)),
          trailing: session?.providerId == p.id && session?.model == m ? const Icon(Icons.check, size: 16, color: Colors.blueAccent) : null,
          onLongPress: () async { await _toggleQuick(p.id, m); setState(() {});
            ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已更新常用模型(顶栏模型名下拉里可快速切换)'), duration: Duration(seconds: 1))); },
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

  Widget _agentsList(BuildContext c) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    // 智能体 = 人格 + 工具授权 + 轮数上限(不再只是"换一段提示词")
    GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: 2,
      padding: const EdgeInsets.all(10), childAspectRatio: 1.2, children: [
      for (final a in AiAgents.all)
        Card(
          color: session?.agentId == a.id ? Theme.of(c).colorScheme.primaryContainer : null,
          child: InkWell(borderRadius: BorderRadius.circular(12), onTap: () => _newChat(agentId: a.id, system: a.system),
          child: Padding(padding: const EdgeInsets.all(9), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(a.icon, style: const TextStyle(fontSize: 15)),
              const SizedBox(width: 5),
              Expanded(child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 4),
            Expanded(child: Text(a.desc, maxLines: 3, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.grey))),
            Text('${a.grant} · ≤${a.maxRounds}轮', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: Theme.of(c).colorScheme.primary)),
          ])))),
    ]),
    // 管理入口: 自定义智能体 / 全局指令人格 / 长期记忆 / 会话钉注 / 工具授权与审批
    ListTile(dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: const Icon(Icons.tune, size: 20),
      title: const Text('智能体 · 指令 · 记忆', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      subtitle: Text('人格与全局指令 / 长期记忆 / 工具授权审批'
        '${AiInstruct.active ? " · 已启用全局指令" : ""}${AiMemory.entries.isEmpty ? "" : " · ${AiMemory.entries.length} 条记忆"}',
        style: const TextStyle(fontSize: 10, color: Colors.grey)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () {
        final nav = Navigator.of(context);
        _closeDrawer();
        nav.push(MaterialPageRoute(builder: (_) => const AiAgentPage())).then((_) { if (mounted) setState(() {}); });
      }),
    // 技能(注入对话上下文, 单选, 再点取消)
    const Padding(padding: EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Text('技能(注入上下文)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey))),
    for (final sk in kAiSkills)
      ListTile(dense: true,
        leading: Text(sk['icon']!, style: const TextStyle(fontSize: 18)),
        title: Text(sk['name']!, style: const TextStyle(fontSize: 13)),
        subtitle: Text(sk['desc']!, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        trailing: _skillId == sk['id'] ? const Icon(Icons.check_circle, size: 18, color: Colors.blueAccent) : null,
        onTap: () async {
          setState(() => _skillId = _skillId == sk['id'] ? '' : sk['id']!);
          final p = await SharedPreferences.getInstance();
          await p.setString('ai_skill', _skillId);
          if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(
            _skillId.isEmpty ? '已取消技能' : '已启用技能「${sk['name']}」, 后续对话自动注入')));
        }),
    const SizedBox(height: 8),
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
