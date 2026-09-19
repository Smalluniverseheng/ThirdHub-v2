// ═══════════════════════════════════════════════════════════════════════════
// TH-Agent v1 · 智能体运行时（ThirdHub v4 自研）
//
// 设计参考了当前开源界几个成熟 Agent 框架的**范式**（不拷代码，语言栈不同）:
//   · DeepSeek Harness(MIT)  —— "一切皆插件"、会话事件可溯源、上下文分级装配
//   · smolagents / ReAct    —— plan → act → observe 工具循环
//   · Claude Code 范式       —— 指令分层(全局指令 / 项目指令 / 会话钉注)、工具审批
// 本文件把它们落成移动端可行子集, 提供四件事:
//   1. AiAgentDef / AiAgents        可授权、可自定义的智能体(不再是"一段提示词")
//   2. AiInstruct / AiMemory / AiPins  三级上下文注入(全局指令 / 长期记忆 / 会话钉注)
//   3. AiContext.systemStack()      把上面所有东西装配成有序 system 消息栈
//   4. AiTools / AiCompress         工具授权过滤 + 风险分级 + 上下文预算压缩
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';

// ── 存储抽象 ───────────────────────────────────────────────────────────────
// TH-Agent 核心刻意**不依赖 Flutter**: 键值读写只走 [AiStore]。
//   · App 运行时由 `ai_store_prefs.dart` 注入 SharedPreferences 实现;
//   · 单元测试 / CLI 自检用默认内存实现 → 纯 Dart VM 就能验证核心逻辑。
abstract class AiStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
}

class _MemAiStore implements AiStore {
  final Map<String, String> _m = {};
  @override Future<String?> getString(String key) async => _m[key];
  @override Future<void> setString(String key, String value) async { _m[key] = value; }
}

/// 全局存储实例(默认内存实现; App 启动时由 [installAiStorePrefs] 替换)
AiStore aiStore = _MemAiStore();

/// 测试用: 换一个干净的内存存储并允许重新装载
void resetAiStoreForTest() { aiStore = _MemAiStore(); }

/// 进程内单调计数器 —— 给 id 用。
///
/// 为什么不能只用时间戳: Windows 的时钟粒度很粗, 同一毫秒内连续调用
/// `microsecondsSinceEpoch` 会拿到**完全相同**的值。于是"连着加两条记忆"或
/// "连着建两个自定义智能体"就会得到同一个 id:
///   · `AiMemory.update(id,…)` 会改到错的那条;
///   · `AiMemory.remove(id)` 会把两条一起删掉;
///   · `AiAgents.saveCustom` 会把新智能体覆盖掉刚建的那个。
/// 时间戳 + 自增序号才真正唯一(跨进程重启靠时间戳拉开)。
int _idSeq = 0;
String _nextId(String prefix) =>
    '$prefix${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${(++_idSeq).toRadixString(36)}';

/// 工具风险分级(沙箱分级): safe = 直接执行; confirm = 需用户点确认; blocked = 拒绝
enum ToolRisk { safe, confirm, blocked }

// ─────────────────────────────────────────────────────────────────────────
// 1. 智能体定义
// ─────────────────────────────────────────────────────────────────────────

/// 智能体 = 人格(system) + 工具授权(allow/deny) + 轮数上限 + 审批策略
///
/// [allow] / [deny] 的匹配规则(见 [AiTools.match]):
///   · `'local'` / `'mcp'`         → 整个命名空间
///   · `'local_web_search'`        → 精确工具名
///   · `'local_file_*'`            → 前缀通配
/// allow 为空 = 放行全部(仍受 deny 约束)。
class AiAgentDef {
  final String id, name, icon, desc, system;
  final List<String> allow, deny;
  final int maxRounds;
  final bool autoApprove; // true = confirm 级工具也直接执行
  final bool builtin;

  const AiAgentDef({
    required this.id, required this.name, this.icon = '🤖', this.desc = '',
    this.system = '', this.allow = const [], this.deny = const [],
    this.maxRounds = 8, this.autoApprove = false, this.builtin = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'icon': icon, 'desc': desc, 'system': system,
    'allow': allow, 'deny': deny, 'maxRounds': maxRounds, 'autoApprove': autoApprove,
  };

  factory AiAgentDef.from(Map<String, dynamic> j) => AiAgentDef(
    id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}', icon: '${j['icon'] ?? '🤖'}',
    desc: '${j['desc'] ?? ''}', system: '${j['system'] ?? ''}',
    allow: [for (final e in (j['allow'] as List? ?? [])) '$e'],
    deny: [for (final e in (j['deny'] as List? ?? [])) '$e'],
    maxRounds: (j['maxRounds'] as num?)?.toInt() ?? 8,
    autoApprove: j['autoApprove'] == true, builtin: false);

  AiAgentDef copyWith({String? name, String? icon, String? desc, String? system,
      List<String>? allow, List<String>? deny, int? maxRounds, bool? autoApprove}) =>
    AiAgentDef(id: id, name: name ?? this.name, icon: icon ?? this.icon,
      desc: desc ?? this.desc, system: system ?? this.system,
      allow: allow ?? this.allow, deny: deny ?? this.deny,
      maxRounds: maxRounds ?? this.maxRounds,
      autoApprove: autoApprove ?? this.autoApprove, builtin: builtin);

  /// 当前授权描述(给 UI 展示用)
  String get grant {
    if (allow.isEmpty && deny.isEmpty) return '全部工具';
    if (allow.contains('local') && allow.contains('mcp')) return '全部工具';
    final p = <String>[];
    if (allow.contains('local')) p.add('本机工具');
    if (allow.contains('mcp')) p.add('MCP 工具');
    p.addAll(allow.where((e) => e != 'local' && e != 'mcp'));
    final s = p.isEmpty ? '无工具' : p.join(' · ');
    return deny.isEmpty ? s : '$s (禁用 ${deny.length} 项)';
  }
}

class AiAgents {
  /// 内置智能体: 每个都带工具授权与轮数上限, 不是"换一段提示词"而已
  static const List<AiAgentDef> builtin = [
    AiAgentDef(id: 'general', name: '通用助理', icon: '🤖',
      desc: '什么都能问 · 可按需调用工具',
      system: '你是 ThirdHub 内置助理，回答准确、简洁、有条理。有工具可用时优先用工具核实事实，不要凭记忆编造。',
      maxRounds: 8),
    AiAgentDef(id: 'researcher', name: '研究员', icon: '🔬',
      desc: '联网检索 → 交叉验证 → 带来源作答',
      system: '你是严谨的研究员。回答任何需要事实支撑的问题时，先用联网搜索工具检索，必要时打开链接原文核对；给出结论时标注来源编号，遇到互相矛盾的信息要指出分歧而不是和稀泥。分点作答，先给结论再给依据。',
      allow: ['local_web_search', 'local_open_url', 'local_clipboard_read', 'local_file_*', 'mcp'],
      maxRounds: 12),
    AiAgentDef(id: 'coder', name: '代码工程师', icon: '💻',
      desc: '读文件 / 写文件 / 跑验证 · 多轮修到对',
      system: '你是资深全栈工程师。拿到需求先确认边界，再给可直接运行的代码。能用工具读文件就读，不要猜文件内容；改完代码要说明改了什么、怎么验证。发现需求本身有坑要先指出。',
      allow: ['local_file_read', 'local_file_write', 'local_file_list', 'local_clipboard_read', 'local_clipboard_write', 'local_web_search', 'local_open_url', 'mcp'],
      maxRounds: 16),
    AiAgentDef(id: 'device', name: '设备管家', icon: '📱',
      desc: '读写本机文件 / 剪贴板 / 朗读 / 分享',
      system: '你是本机设备管家。用户要操作手机上的东西时，直接调用本机工具完成（读写文件、剪贴板、朗读、分享、打开链接），完成后用一句话汇报结果，不要输出工具调用的原始 JSON。',
      allow: ['local'], maxRounds: 6),
    AiAgentDef(id: 'analyst', name: '数据分析师', icon: '📊',
      desc: '读文件 → 算 → 出结论',
      system: '你是数据分析师。先确认数据口径，再动手算。中间过程用工具完成，最后给出：结论 → 关键数字 → 局限与假设。不要在没有数据支撑时给结论。',
      allow: ['local_file_read', 'local_file_write', 'local_file_list', 'local_web_search'],
      maxRounds: 10),
    AiAgentDef(id: 'writer', name: '写作官', icon: '✍️',
      desc: '长文创作 · 只读不删',
      system: '你是资深中文写作助手。写作前先问清读者与目的（若用户已说明则不必再问）。输出直接可用，不要写"以下是"这类废话前缀。',
      deny: ['local_file_delete'], maxRounds: 4),
    AiAgentDef(id: 'translator', name: '翻译官', icon: '🌐',
      desc: '中英互译 · 不调工具',
      system: '你是专业翻译。直译与意译结合，术语前后一致；只输出译文，除非用户要求解释。不要调用任何工具。',
      allow: ['__none__'], maxRounds: 1),
    AiAgentDef(id: 'librarian', name: '资源库管家', icon: '🗂️',
      desc: '整理本机与云端资源',
      system: '你是资源库管家。用户要整理/查找资源时，先列出你能看到的目录结构再动手，任何删除类操作前必须先复述要删什么并等用户确认。',
      allow: ['local_file_read', 'local_file_write', 'local_file_list', 'local_file_delete', 'mcp'],
      maxRounds: 10),
  ];

  static List<AiAgentDef> _custom = [];
  static bool _loaded = false;

  /// 内置 + 自定义(自定义排前)
  static List<AiAgentDef> get all => [..._custom, ...builtin];

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await aiStore.getString('ai_agents_custom');
    try {
      _custom = [for (final e in (jsonDecode(raw ?? '[]') as List))
        AiAgentDef.from(Map<String, dynamic>.from(e))];
    } catch (_) { _custom = []; }
  }

  static Future<void> _save() async {
    await aiStore.setString('ai_agents_custom', jsonEncode([for (final a in _custom) a.toJson()]));
  }

  static AiAgentDef? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final a in all) { if (a.id == id) return a; }
    return null;
  }

  static Future<void> saveCustom(AiAgentDef a) async {
    final i = _custom.indexWhere((x) => x.id == a.id);
    if (i >= 0) { _custom[i] = a; } else { _custom.insert(0, a); }
    await _save();
  }

  static Future<void> removeCustom(String id) async {
    _custom.removeWhere((x) => x.id == id);
    await _save();
  }

  static bool isCustom(String id) => _custom.any((x) => x.id == id);

  static String newId() => _nextId('agent-');
}

// ─────────────────────────────────────────────────────────────────────────
// 2. 三级上下文注入
// ─────────────────────────────────────────────────────────────────────────

/// 全局指令 / 人格 —— 作用于**所有**会话(相当于 Claude Code 的全局指令、GPTs 的 Custom Instructions)
class AiInstruct {
  /// 预设人格: id → (名称, 提示词)
  static const Map<String, (String, String)> personas = {
    'default': ('默认', ''),
    'concise': ('简洁直给', '回答尽量短。能一句话说清就不要写一段。不要复述问题，不要写开场白和总结。'),
    'rigorous': ('严谨求证', '不确定的事情明确说"不确定"。区分事实、推断与猜测。给出可核查的依据。'),
    'friendly': ('温和耐心', '语气亲切自然，多用"我们"。一步一步来，不急。'),
    'humorous': ('幽默风趣', '可以适当玩梗和调侃，但信息本身必须准确，不为了好笑牺牲内容。'),
    'socratic': ('苏格拉底', '不要直接给答案。用追问引导用户自己发现，需要时再给最小的提示。'),
  };

  static String _personaId = 'default';
  static String _custom = '';

  static String get personaId => _personaId;
  static String get custom => _custom;

  static Future<void> load() async {
    _personaId = await aiStore.getString('ai_persona') ?? 'default';
    _custom = await aiStore.getString('ai_instructions') ?? '';
  }

  static Future<void> setPersona(String id) async {
    _personaId = id;
    await aiStore.setString('ai_persona', id);
  }

  static Future<void> setCustom(String text) async {
    _custom = text.trim();
    await aiStore.setString('ai_instructions', _custom);
  }

  /// 装配成一条 system(人格 + 自定义指令), 空则返回 ''
  static String build() {
    final parts = <String>[];
    final p = personas[_personaId]?.$2 ?? '';
    if (p.isNotEmpty) parts.add('【对话风格】$p');
    if (_custom.isNotEmpty) parts.add('【用户全局指令】\n$_custom');
    return parts.join('\n\n');
  }

  static bool get active => build().isNotEmpty;
}

/// 长期记忆 —— 跨会话生效的事实条目(相当于 Agent 的 persistent memory)
class AiMemoryEntry {
  final String id, text;
  final int ts;
  AiMemoryEntry({required this.id, required this.text, required this.ts});
  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'ts': ts};
  factory AiMemoryEntry.from(Map<String, dynamic> j) =>
    AiMemoryEntry(id: '${j['id'] ?? ''}', text: '${j['text'] ?? ''}', ts: (j['ts'] as num?)?.toInt() ?? 0);
}

class AiMemory {
  static List<AiMemoryEntry> entries = [];
  static bool _loaded = false;
  /// 单条记忆 + 【已装配记忆】段的字符上限, 防止把上下文撑爆
  static const int maxEntryChars = 500;
  static const int maxBlockChars = 2000;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await aiStore.getString('ai_memory');
    try {
      entries = [for (final e in (jsonDecode(raw ?? '[]') as List))
        AiMemoryEntry.from(Map<String, dynamic>.from(e))];
    } catch (_) { entries = []; }
  }

  static Future<void> _save() async {
    await aiStore.setString('ai_memory', jsonEncode([for (final e in entries) e.toJson()]));
  }

  static Future<void> add(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    entries.insert(0, AiMemoryEntry(
      id: _nextId('m-'), text: t,
      ts: DateTime.now().millisecondsSinceEpoch));
    await _save();
  }

  static Future<void> remove(String id) async {
    entries.removeWhere((e) => e.id == id);
    await _save();
  }

  static Future<void> update(String id, String text) async {
    final i = entries.indexWhere((e) => e.id == id);
    if (i < 0) return;
    entries[i] = AiMemoryEntry(id: id, text: text.trim(), ts: entries[i].ts);
    await _save();
  }

  /// 渲染成 system 片段; 超上限按"新的优先"裁剪
  static String build() {
    if (entries.isEmpty) return '';
    final buf = StringBuffer('【已装配记忆】以下是用户之前让你记住的长期事实，回答时默认遵守：\n');
    for (final e in entries) {
      var t = e.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.length > maxEntryChars) t = '${t.substring(0, maxEntryChars)}…';
      final line = '- $t\n';
      if (buf.length + line.length > maxBlockChars) break;
      buf.write(line);
    }
    return buf.toString().trimRight();
  }
}

/// 会话钉注 —— 钉在当前会话里、每一轮都随请求带上的内容(相当于 @ 引用固定上下文)
class AiPins {
  static const int maxItems = 12;
  static const int maxItemChars = 4000;

  static String _key(String sessionId) => 'ai_pins_$sessionId';

  static Future<List<String>> get(String sessionId) async {
    if (sessionId.isEmpty) return [];
    final raw = await aiStore.getString(_key(sessionId));
    try { return [for (final e in (jsonDecode(raw ?? '[]') as List)) '$e']; }
    catch (_) { return []; }
  }

  static Future<void> set(String sessionId, List<String> pins) async {
    if (sessionId.isEmpty) return;
    final clean = [for (final s in pins.take(maxItems)) s.length > maxItemChars ? s.substring(0, maxItemChars) : s];
    await aiStore.setString(_key(sessionId), jsonEncode(clean));
  }

  static Future<void> add(String sessionId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final cur = await get(sessionId);
    await set(sessionId, [...cur, t]);
  }

  static Future<void> removeAt(String sessionId, int i) async {
    final cur = await get(sessionId);
    if (i < 0 || i >= cur.length) return;
    cur.removeAt(i);
    await set(sessionId, cur);
  }

  /// 渲染成 system 片段
  static String build(List<String> pins) {
    if (pins.isEmpty) return '';
    final lines = <String>[];
    for (var i = 0; i < pins.length; i++) { lines.add('[钉注${i + 1}] ${pins[i]}'); }
    return '【本次会话固定上下文】以下内容每轮都会提供，请始终把它当作已知背景：\n${lines.join('\n\n')}';
  }
}

/// 上下文装配器 —— 把人格/指令、智能体人格、技能、记忆、钉注、工具清单
/// 按固定顺序压成有序 system 消息栈(front → back = 由弱到强)
class AiContext {
  static Future<List<Map<String, String>>> systemStack({
    AiAgentDef? agent,
    String skillSystem = '',
    List<String> pins = const [],
    bool toolManifest = false,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    await AiInstruct.load();
    await AiMemory.load();
    final out = <Map<String, String>>[];
    final base = AiInstruct.build();
    if (base.isNotEmpty) out.add({'role': 'system', 'content': base});
    if (agent != null && agent.system.isNotEmpty) {
      out.add({'role': 'system', 'content': '【当前身份】你是「${agent.name}」。${agent.system}'});
    }
    if (skillSystem.isNotEmpty) out.add({'role': 'system', 'content': skillSystem});
    final mem = AiMemory.build();
    if (mem.isNotEmpty) out.add({'role': 'system', 'content': mem});
    final pin = AiPins.build(pins);
    if (pin.isNotEmpty) out.add({'role': 'system', 'content': pin});
    if (toolManifest && tools.isNotEmpty) {
      out.add({'role': 'system', 'content': AiTools.manifest(tools)});
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 3. 工具授权过滤 + 风险分级
// ─────────────────────────────────────────────────────────────────────────
class AiTools {
  /// 本机工具里"动手改东西"的那几个: 默认需要用户点一下确认
  static const Set<String> _dangerous = {
    'local_file_delete', 'local_file_write', 'local_clipboard_write',
    'local_open_url', 'local_share_text', 'local_tts_speak',
  };

  /// 工具所属命名空间: serverId == 'local' → 'local', 其余一律 'mcp'
  static String ns(Map<String, dynamic> tool) =>
    '${tool['serverId'] ?? ''}' == 'local' ? 'local' : 'mcp';

  static ToolRisk risk(String name) {
    if (_dangerous.contains(name)) return ToolRisk.confirm;
    return ToolRisk.safe;
  }

  /// allow/deny 匹配(见 [AiAgentDef] 文档)
  static bool match(List<String> patterns, String toolName, String namespace) {
    for (final p in patterns) {
      if (p.isEmpty) continue;
      if (p == namespace) return true;
      if (p == toolName) return true;
      if (p.endsWith('*') && toolName.startsWith(p.substring(0, p.length - 1))) return true;
    }
    return false;
  }

  /// 按智能体授权过滤工具表; agent == null → 全部放行
  static List<Map<String, dynamic>> filter(List<Map<String, dynamic>> tools, AiAgentDef? agent) {
    if (agent == null) return tools;
    return [
      for (final t in tools)
        if (() {
          final name = '${t['name'] ?? ''}';
          final namespace = ns(t);
          if (match(agent.deny, name, namespace)) return false;
          if (agent.allow.isEmpty) return true;
          return match(agent.allow, name, namespace);
        }()) t
    ];
  }

  /// 文本工具清单 —— 给不支持原生 function-calling 的厂商兜底用
  static String manifest(List<Map<String, dynamic>> tools) {
    final lines = <String>[];
    for (final t in tools) {
      final schema = t['inputSchema'];
      var args = '';
      if (schema is Map && schema['properties'] is Map) {
        final props = Map<String, dynamic>.from(schema['properties'] as Map);
        args = props.keys.join(', ');
      }
      lines.add('- ${t['name']}($args): ${t['description'] ?? ''}');
    }
    return '【可用工具】你可以调用以下工具来获取信息或执行操作：\n${lines.join('\n')}\n\n'
        '需要调用工具时，只输出一行：<tool_call>{"name":"工具名","arguments":{...}}</tool_call>\n'
        '收到工具结果后继续作答。不需要工具时直接回答，不要输出该标签。';
  }

  /// 解析文本协议里的工具调用(兜底路径)
  static List<Map<String, dynamic>> parseTextCalls(String text) {
    final out = <Map<String, dynamic>>[];
    for (final m in RegExp(r'<tool_call>\s*([\s\S]*?)\s*</tool_call>').allMatches(text)) {
      try {
        final j = jsonDecode(m.group(1)!);
        if (j is Map && j['name'] != null) {
          out.add({'name': '${j['name']}',
            'arguments': j['arguments'] is Map ? Map<String, dynamic>.from(j['arguments']) : <String, dynamic>{}});
        }
      } catch (_) {}
    }
    return out;
  }

  /// 去掉文本协议标签, 只留正文
  static String stripTextCalls(String text) =>
    text.replaceAll(RegExp(r'<tool_call>[\s\S]*?</tool_call>'), '').trim();

  /// 文本协议下的工具结果回灌格式(与原生 tool 角色等价)
  static String toolResult(String name, String output) =>
    '【工具 $name 的返回结果】\n$output\n\n请基于以上结果继续作答；若还需调用工具，再输出 <tool_call> 标签。';
}

// ─────────────────────────────────────────────────────────────────────────
// 4. 上下文预算压缩
// ─────────────────────────────────────────────────────────────────────────
class AiCompress {
  /// 字符预算(约等于 12k~16k token, 移动端够用又不至于被厂商拒)
  static const int defaultBudget = 30000;
  static const int keepTail = 12;

  static int sizeOf(List<Map<String, String>> msgs) =>
    msgs.fold(0, (a, m) => a + ('${m['content'] ?? ''}').length);

  /// 超预算时把"早期消息"折叠成一条摘要 system, 保留最近 keepTail 条原文。
  /// 纯本地启发式: 不额外消耗 token, 结果确定可测。
  static List<Map<String, String>> compress(List<Map<String, String>> msgs,
      {int budget = defaultBudget, int tail = keepTail}) {
    if (sizeOf(msgs) <= budget) return msgs;
    final sys = [for (final m in msgs) if (m['role'] == 'system') m];
    final rest = [for (final m in msgs) if (m['role'] != 'system') m];
    if (rest.length <= tail) return msgs;
    final head = rest.sublist(0, rest.length - tail);
    final keep = rest.sublist(rest.length - tail);
    final buf = StringBuffer(
      '【早期对话摘要】本次会话前 ${head.length} 条消息已自动压缩(原文省略)，要点如下：\n');
    for (final m in head) {
      var c = '${m['content'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (c.isEmpty) continue;
      if (c.length > 140) c = '${c.substring(0, 140)}…';
      buf.writeln('- ${m['role'] == 'user' ? '用户' : '助手'}: $c');
    }
    return [...sys, {'role': 'system', 'content': buf.toString().trimRight()}, ...keep];
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 5. 任务清单(plan-act-observe 里的 plan, 让多步任务对用户可见)
// ─────────────────────────────────────────────────────────────────────────
class AiTodoItem {
  final String text;
  bool done;
  AiTodoItem(this.text, {this.done = false});
}

class AiTodo {
  static final List<AiTodoItem> items = [];

  static void reset(List<String> texts) {
    items
      ..clear()
      ..addAll([for (final t in texts) AiTodoItem(t)]);
  }

  static void complete(int i) { if (i >= 0 && i < items.length) items[i].done = true; }
  static void clear() => items.clear();
  static bool get active => items.isNotEmpty;
  static int get progress => items.isEmpty ? 0 : items.where((e) => e.done).length;
}
