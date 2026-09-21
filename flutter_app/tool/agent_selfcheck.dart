// ═══════════════════════════════════════════════════════════════════════════
// TH-Agent 核心自检（纯 Dart，不需要 flutter_tester）
//
// 用法: dart run tool/agent_selfcheck.dart
//
// 为什么需要它: 本机 flutter_tester 起不来时(引擎/环境问题), flutter test 全部
// 无法运行。ai_agent.dart 已刻意不依赖 Flutter，所以可以用纯 Dart VM 直接验证
// 智能体注册 / 工具授权 / 风险分级 / 上下文装配 / 压缩 / 记忆 / 钉注 / 任务清单。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';

import 'package:thirdhub_app/core/ai_agent.dart';

int _pass = 0;
int _fail = 0;
final List<String> _fails = [];

void _ok(bool cond, String name, [String extra = '']) {
  if (cond) {
    _pass++;
    print('  \u2713 $name');
  } else {
    _fail++;
    _fails.add(name);
    print('  \u2717 $name${extra.isEmpty ? '' : '  -> $extra'}');
  }
}

void _eq(Object? a, Object? b, String name) =>
    _ok(a == b, name, 'expected=${_s(b)} actual=${_s(a)}');

String _s(Object? v) => v is String ? '"${v.length > 120 ? '${v.substring(0, 120)}…' : v}"' : '$v';

Future<void> main() async {
  print('══ TH-Agent core self-check ══\n');

  // ── 1. 智能体注册 ────────────────────────────────────────────────────
  print('1) AiAgents 智能体注册与授权');
  await AiAgents.load();
  _ok(AiAgents.builtin.length >= 8, '内置智能体数量 >= 8', '${AiAgents.builtin.length}');
  final r = AiAgents.byId('researcher');
  _ok(r != null, 'byId("researcher") 命中');
  _eq(r!.name, '研究员', 'researcher.name');
  _ok(r.maxRounds > 8, 'researcher.maxRounds > 8', '${r.maxRounds}');
  _ok(r.allow.contains('local_web_search'), 'researcher 授权含 local_web_search');
  _ok(r.system.isNotEmpty, 'researcher 有 system 人格');
  _eq(AiAgents.byId('不存在的id'), null, 'byId 未命中返回 null');
  _eq(AiAgents.byId(''), null, 'byId("") 返回 null');
  _eq(AiAgents.byId(null), null, 'byId(null) 返回 null');
  _eq(AiAgents.all.length, AiAgents.builtin.length, '初始 all == builtin');

  // 自定义智能体: 排在内置之前 + 可改名覆盖 + 可删
  final nid = AiAgents.newId();
  _ok(nid.startsWith('agent-'), 'newId 前缀 agent-');
  await AiAgents.saveCustom(AiAgentDef(id: nid, name: '我的助手', desc: '自定义',
      system: '你是我的私人助手。', allow: ['local_web_search'], maxRounds: 3, builtin: false));
  _ok(AiAgents.isCustom(nid), 'isCustom 认得自定义智能体');
  _eq(AiAgents.all.first.id, nid, '自定义排在最前');
  await AiAgents.saveCustom(AiAgentDef(id: nid, name: '改过的名字', builtin: false));
  _eq(AiAgents.byId(nid)!.name, '改过的名字', 'saveCustom 同 id 覆盖而非追加');
  _eq(AiAgents.all.where((a) => a.id == nid).length, 1, '同 id 只有一条');
  await AiAgents.removeCustom(nid);
  _ok(!AiAgents.isCustom(nid), 'removeCustom 生效');

  // 授权描述
  _eq(AiAgents.byId('device')!.grant, '本机工具', 'device.grant');
  _ok(AiAgents.byId('general')!.grant.contains('全部'), 'general.grant 含「全部」');
  _ok(AiAgents.byId('writer')!.grant.contains('禁用'), 'writer.grant 显示禁用项');

  // ── 2. 工具命名空间 / 风险 / 授权过滤 ────────────────────────────────
  print('\n2) AiTools 命名空间·风险分级·授权过滤');
  _eq(AiTools.ns({'name': 'x', 'serverId': 'local'}), 'local', 'ns(local)');
  _eq(AiTools.ns({'name': 'x', 'serverId': 'mcp-foo'}), 'mcp', 'ns(非 local → mcp)');
  _eq(AiTools.ns({'name': 'x'}), 'mcp', 'ns(缺 serverId → mcp)');

  _eq(AiTools.risk('local_file_delete'), ToolRisk.confirm, 'risk(file_delete)=confirm');
  _eq(AiTools.risk('local_file_read'), ToolRisk.safe, 'risk(file_read)=safe');
  _eq(AiTools.risk('mcp__anything'), ToolRisk.safe, 'risk(MCP 工具)=safe');

  _ok(AiTools.match(['local'], 'local_file_read', 'local'), 'match 命名空间');
  _ok(AiTools.match(['local_file_read'], 'local_file_read', 'local'), 'match 精确名');
  _ok(AiTools.match(['local_file_*'], 'local_file_write', 'local'), 'match 前缀通配');
  _ok(!AiTools.match(['local_file_*'], 'mcp_file_write', 'mcp'), '通配不越命名空间');
  _ok(!AiTools.match(['local'], 'local_file_read', 'mcp'), '命名空间不匹配即拒');

  final tools = <Map<String, dynamic>>[
    {'name': 'local_web_search', 'serverId': 'local', 'description': '联网搜索',
      'inputSchema': {'properties': {'q': {}}}},
    {'name': 'local_file_write', 'serverId': 'local', 'description': '写文件'},
    {'name': 'local_file_read', 'serverId': 'local', 'description': '读文件'},
    {'name': 'mcp_remote_thing', 'serverId': 'mcp-x', 'description': '远端工具'},
  ];
  _eq(AiTools.filter(tools, null).length, 4, 'agent=null → 全放行');
  // researcher 授权 = local_web_search / local_open_url / local_clipboard_read / local_file_* / mcp
  final rNames = AiTools.filter(tools, AiAgents.byId('researcher')).map((t) => t['name']).toSet();
  _eq(rNames.length, 4, 'researcher 保留 4 项(local_file_* 通配 + mcp 命名空间)');
  _ok(rNames.contains('local_file_write') && rNames.contains('mcp_remote_thing'),
      'researcher 的 local_file_* 通配与 mcp 命名空间均放行');
  _eq(AiTools.filter(tools, AiAgents.byId('translator')).length, 0, 'translator 不调任何工具');
  _eq(AiTools.filter(tools, AiAgents.byId('writer')).length, 4, 'writer allow 为空 → 放行全部');
  _eq(AiTools.filter(tools, AiAgents.byId('device')).length, 3, 'device 只放行 local 命名空间(3 项)');
  // coder 走"逐条列举 + mcp"白名单, 未列举的本机工具必须被拦下
  final probe = <Map<String, dynamic>>[
    {'name': 'local_tts_speak', 'serverId': 'local'},   // 不在 coder 白名单
    {'name': 'local_file_read', 'serverId': 'local'},   // 在白名单
    {'name': 'mcp_remote_thing', 'serverId': 'mcp-x'},  // 命中 mcp 命名空间
  ];
  final cNames = AiTools.filter(probe, AiAgents.byId('coder')).map((t) => t['name']).toSet();
  _eq(cNames.length, 2, 'coder 白名单过滤掉未授权工具');
  _ok(!cNames.contains('local_tts_speak'), 'coder 未授权的本机工具被拦下');

  // manifest / 文本协议
  final man = AiTools.manifest(tools);
  _ok(man.contains('local_web_search(q)'), 'manifest 列出工具名与参数');
  _ok(man.contains('<tool_call>'), 'manifest 声明文本协议');
  final parsed = AiTools.parseTextCalls(
      '好的，我先查一下。<tool_call>{"name":"local_web_search","arguments":{"q":"深圳天气"}}</tool_call>');
  _eq(parsed.length, 1, 'parseTextCalls 解析出 1 个调用');
  _eq(parsed.first['name'], 'local_web_search', '解析出的工具名');
  _eq((parsed.first['arguments'] as Map)['q'], '深圳天气', '解析出的参数');
  _eq(AiTools.parseTextCalls('没有工具调用').length, 0, '无标签 → 0');
  _eq(AiTools.parseTextCalls('<tool_call>{坏JSON}</tool_call>').length, 0, '坏 JSON 不抛异常');
  _eq(AiTools.stripTextCalls('甲<tool_call>{"name":"a"}</tool_call>乙'), '甲乙', 'stripTextCalls 只留正文');
  _ok(AiTools.toolResult('t1', '结果A').contains('结果A'), 'toolResult 回灌包含结果');

  // ── 3. 指令 / 记忆 / 钉注 ───────────────────────────────────────────
  print('\n3) AiInstruct · AiMemory · AiPins');
  await AiInstruct.load();
  _ok(AiInstruct.personas.containsKey('rigorous'), '预设人格含 rigorous');
  await AiInstruct.setPersona('concise');
  await AiInstruct.setCustom('永远用中文回答。');
  _eq(AiInstruct.personaId, 'concise', 'setPersona 生效');
  final ib = AiInstruct.build();
  _ok(ib.contains('【对话风格】'), 'build 含对话风格段');
  _ok(ib.contains('【用户全局指令】'), 'build 含用户全局指令段');
  _ok(ib.contains('永远用中文回答。'), 'build 含自定义指令正文');
  _ok(AiInstruct.active, 'active = true');
  await AiInstruct.setPersona('default');
  await AiInstruct.setCustom('');
  _ok(!AiInstruct.active, '清空后 active = false');

  await AiMemory.load();
  AiMemory.entries.clear();
  await AiMemory.add('我不吃香菜');
  await AiMemory.add('我住在杭州');
  _eq(AiMemory.entries.length, 2, 'add 累积 2 条');
  _eq(AiMemory.entries.first.text, '我住在杭州', '新记忆插在最前');
  final mid = AiMemory.entries.last.id;
  await AiMemory.update(mid, '我不吃香菜和折耳根');
  _eq(AiMemory.entries.last.text, '我不吃香菜和折耳根', 'update 改写正文');
  _eq(AiMemory.entries.length, 2, 'update 不增条目');
  final mb = AiMemory.build();
  _ok(mb.contains('【已装配记忆】'), 'build 有记忆段标题');
  _ok(mb.contains('杭州'), 'build 含记忆内容');
  await AiMemory.remove(mid);
  _eq(AiMemory.entries.length, 1, 'remove 生效');

  // ★ 回归(id 唯一性): 只用时间戳做 id 时, 同一毫秒内连加两条会撞成同一个 id ——
  //   update 改到错的那条、remove 把两条一起删掉。Windows 时钟粒度粗, 这条路必现。
  AiMemory.entries.clear();
  await AiMemory.add('甲');
  await AiMemory.add('乙');
  await AiMemory.add('丙');
  final mIds = {for (final e in AiMemory.entries) e.id};
  _eq(mIds.length, AiMemory.entries.length, '连加三条记忆: id 互不相同');
  await AiMemory.remove(AiMemory.entries.last.id);
  _eq(AiMemory.entries.length, 2, 'remove 只删目标那一条, 不误伤别的');
  await AiMemory.update(AiMemory.entries.first.id, '改过');
  _eq(AiMemory.entries.first.text, '改过', 'update 改的是目标那一条');
  _eq(AiMemory.entries.length, 2, 'update 不改条目数');

  // ★ 回归: 自定义智能体 id 同理, 连建两个不能互相覆盖
  final aIds = {AiAgents.newId(), AiAgents.newId(), AiAgents.newId()};
  _eq(aIds.length, 3, '连取三个 newId() 互不相同');

  // 单条超长截断
  AiMemory.entries.clear();
  await AiMemory.add('甲' * 900);
  final trunc = AiMemory.build();
  _ok(trunc.contains('…'), '超 maxEntryChars 的记忆被截断');
  _ok(!trunc.contains('甲' * (AiMemory.maxEntryChars + 1)), '截断长度符合上限');

  // 总量上限
  AiMemory.entries.clear();
  for (var i = 0; i < 20; i++) { await AiMemory.add('条目$i' + '乙' * 400); }
  final capped = AiMemory.build();
  _ok(capped.length <= AiMemory.maxBlockChars + 400, '记忆总量受 maxBlockChars 约束',
      'len=${capped.length}');
  AiMemory.entries.clear();

  await AiPins.set('s1', []);
  await AiPins.add('s1', '这份合同甲方是深圳某公司');
  await AiPins.add('s1', '用户要求按中文合同格式评审');
  final pins = await AiPins.get('s1');
  _eq(pins.length, 2, 'AiPins.add/get');
  _eq(pins.first, '这份合同甲方是深圳某公司', '钉注保持插入顺序');
  await AiPins.removeAt('s1', 0);
  _eq((await AiPins.get('s1')).length, 1, 'removeAt 生效');
  await AiPins.set('s1', [for (var i = 0; i < 30; i++) '钉$i']);
  _eq((await AiPins.get('s1')).length, AiPins.maxItems, '钉注数量上限 maxItems');
  _eq((await AiPins.get('')).length, 0, '空 sessionId → 无钉注');
  await AiPins.set('', ['x']);
  _eq((await AiPins.get('')).length, 0, '空 sessionId 不可写');
  final pb = AiPins.build(['A', 'B']);
  _ok(pb.contains('[钉注1] A') && pb.contains('[钉注2] B'), 'build 给钉注编号');
  _eq(AiPins.build([]), '', '无钉注 → 空串');

  // ── 4. 上下文装配顺序 ──────────────────────────────────────────────
  print('\n4) AiContext.systemStack 装配顺序');
  await AiInstruct.setPersona('rigorous');
  await AiInstruct.setCustom('回复末尾署名「许」。');
  AiMemory.entries.clear();
  await AiMemory.add('用户叫小明');
  final stack = await AiContext.systemStack(
    agent: AiAgents.byId('researcher'),
    skillSystem: '【技能】联网检索技能已装载',
    pins: ['本次讨论限定在 A 股'],
    toolManifest: true,
    tools: tools,
  );
  // 注：4.31.0 起 systemStack 恒定在最弱位加一段「输出格式」声明
  // （告诉模型客户端能渲染完整 Markdown，别自我阉割成纯文本）。
  // 所以这里是最弱位 1 段 + 6 段按需注入 = 7 段；本自检原先按 6 段写，
  // 自 4.31.0 起一直是红的 —— 已按实现修正。
  _eq(stack.length, 7, '7 段 system(输出格式/指令/身份/技能/记忆/钉注/工具)');
  _ok(stack.every((m) => m['role'] == 'system'), '全部 role=system');
  _ok(stack[0]['content']!.contains('【输出格式】'), '第 0 段 = 输出格式声明(最弱位)');
  _ok(stack[1]['content']!.contains('【对话风格】'), '第 1 段 = 全局指令');
  _ok(stack[2]['content']!.contains('【当前身份】') && stack[2]['content']!.contains('研究员'),
      '第 2 段 = 当前智能体身份');
  _ok(stack[3]['content']!.contains('技能已装载'), '第 3 段 = 技能');
  _ok(stack[4]['content']!.contains('【已装配记忆】'), '第 4 段 = 长期记忆');
  _ok(stack[5]['content']!.contains('【本次会话固定上下文】'), '第 5 段 = 会话钉注');
  _ok(stack[6]['content']!.contains('【可用工具】'), '第 6 段 = 工具清单(最靠后)');

  // 先清干净全局注入, 再验证"什么都不注入时只剩那段输出格式声明"
  await AiInstruct.setPersona('default');
  await AiInstruct.setCustom('');
  AiMemory.entries.clear();
  final minimal = await AiContext.systemStack();
  _eq(minimal.length, 1, '无注入时只剩输出格式声明');
  _ok(minimal[0]['content']!.contains('【输出格式】'), '剩下那段确实是输出格式声明');

  // ── 5. 上下文预算压缩 ──────────────────────────────────────────────
  print('\n5) AiCompress 预算压缩');
  final small = <Map<String, String>>[
    {'role': 'system', 'content': 'sys'},
    {'role': 'user', 'content': 'hi'},
    {'role': 'assistant', 'content': 'hello'},
  ];
  _eq(AiCompress.compress(small).length, 3, '未超预算 → 原样返回');

  final big = <Map<String, String>>[
    {'role': 'system', 'content': 'sys'},
    for (var i = 0; i < 20; i++)
      {'role': i.isEven ? 'user' : 'assistant', 'content': '第$i条 ' + '丙' * 2000},
    {'role': 'user', 'content': '最后的问题'},
  ];
  _ok(AiCompress.sizeOf(big) > AiCompress.defaultBudget, '构造的对话确实超预算');
  final comp = AiCompress.compress(big);
  _ok(AiCompress.sizeOf(comp) < AiCompress.sizeOf(big), '压缩后体积下降');
  _eq(comp.where((m) => m['role'] == 'system').length, 2, '保留原 system + 1 条摘要');
  _eq(comp.last['content'], '最后的问题', '最近一条原文保留在末尾');
  _eq(comp.where((m) => m['role'] != 'system').length, AiCompress.keepTail, '非 system 保留 keepTail 条');
  _ok(comp.any((m) => m['content']!.contains('【早期对话摘要】')), '生成早期对话摘要');
  _eq(AiCompress.compress(big).length, comp.length, '压缩结果确定(可重复)');

  // ── 6. 任务清单 ────────────────────────────────────────────────────
  print('\n6) AiTodo 任务清单');
  AiTodo.reset(['拉取源站列表', '去重', '写回配置']);
  _eq(AiTodo.items.length, 3, 'reset 装载 3 项');
  _ok(AiTodo.active, 'active = true');
  _eq(AiTodo.progress, 0, '初始进度 0');
  AiTodo.complete(0);
  AiTodo.complete(2);
  _eq(AiTodo.progress, 2, 'complete 后进度 2');
  AiTodo.complete(-1);
  AiTodo.complete(99);
  _eq(AiTodo.progress, 2, '越界 complete 不崩不改数');
  AiTodo.clear();
  _ok(!AiTodo.active, 'clear 后 inactive');

  // ── 7. 存储抽象 ────────────────────────────────────────────────────
  print('\n7) AiStore 存储抽象(核心与 Flutter 解耦)');
  resetAiStoreForTest();
  await aiStore.setString('k', 'v');
  _eq(await aiStore.getString('k'), 'v', '默认内存实现可读写');
  _eq(await aiStore.getString('不存在'), null, '未设置键返回 null');
  resetAiStoreForTest();
  _eq(await aiStore.getString('k'), null, 'reset 后内存清空');

  // 序列化往返(自定义智能体持久化格式)
  const sample = AiAgentDef(id: 'z', name: '往返测试', icon: '🧪', desc: 'd', system: 's',
      allow: ['local_web_search', 'prefix_*'], deny: ['local_file_delete'],
      maxRounds: 7, autoApprove: true, builtin: false);
  final round = AiAgentDef.from(jsonDecode(jsonEncode(sample.toJson())) as Map<String, dynamic>);
  _eq(round.id, sample.id, 'toJson/from 往返 id');
  _eq(round.name, sample.name, '往返 name');
  _eq(round.maxRounds, 7, '往返 maxRounds');
  _eq(round.autoApprove, true, '往返 autoApprove');
  _eq(round.allow.join(','), 'local_web_search,prefix_*', '往返 allow 列表');
  _eq(round.deny.join(','), 'local_file_delete', '往返 deny 列表');
  _ok(!round.builtin, '反序列化出来的都是自定义(builtin=false)');

  print('\n════════════════════════════════════════');
  print('PASS $_pass   FAIL $_fail');
  if (_fail > 0) {
    print('\n失败项:');
    for (final f in _fails) { print('  - $f'); }
  }
  print(_fail == 0 ? '\n\u2705 全部通过' : '\n\u274c 有失败');
}
