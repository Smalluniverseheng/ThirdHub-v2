// TH-Agent v1 单元测试 —— 覆盖智能体注册、工具授权过滤、上下文装配、压缩、记忆/钉注
// 全部为纯逻辑测试, 不依赖网络与平台通道(shared_preferences 用 mock 注入)
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thirdhub_app/core/ai_agent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AiAgents 智能体注册', () {
    test('内置智能体可按 id 取到, 且带工具授权与轮数上限', () async {
      await AiAgents.load();
      final r = AiAgents.byId('researcher');
      expect(r, isNotNull);
      expect(r!.name, '研究员');
      expect(r.maxRounds, greaterThan(8));
      expect(r.allow, contains('local_web_search'));
      expect(r.system, isNotEmpty);
      // 未知 id 返回 null(不抛)
      expect(AiAgents.byId('__nope__'), isNull);
      expect(AiAgents.byId(''), isNull);
      expect(AiAgents.byId(null), isNull);
    });

    test('自定义智能体可增删改, 且排在内置之前', () async {
      await AiAgents.load();
      final base = AiAgents.all.length;
      final a = AiAgentDef(id: AiAgents.newId(), name: '我的助手', system: '只说实话',
          allow: ['local'], maxRounds: 3, builtin: false);
      await AiAgents.saveCustom(a);
      expect(AiAgents.all.length, base + 1);
      expect(AiAgents.all.first.id, a.id, reason: '自定义应排最前');
      expect(AiAgents.isCustom(a.id), isTrue);
      // 更新原地替换, 不新增
      await AiAgents.saveCustom(a.copyWith(name: '改名了'));
      expect(AiAgents.all.length, base + 1);
      expect(AiAgents.byId(a.id)!.name, '改名了');
      await AiAgents.removeCustom(a.id);
      expect(AiAgents.all.length, base);
    });

    test('授权描述可读', () {
      expect(const AiAgentDef(id: 'x', name: 'x').grant, '全部工具');
      expect(const AiAgentDef(id: 'x', name: 'x', allow: ['local', 'mcp']).grant, '全部工具');
      expect(const AiAgentDef(id: 'x', name: 'x', allow: ['__none__']).grant, contains('__none__'));
    });
  });

  group('AiTools 授权过滤与风险分级', () {
    final tools = <Map<String, dynamic>>[
      {'serverId': 'local', 'name': 'local_web_search', 'description': '联网搜索'},
      {'serverId': 'local', 'name': 'local_file_write', 'description': '写文件'},
      {'serverId': 'local', 'name': 'local_file_delete', 'description': '删文件'},
      {'serverId': 'mcp-1', 'name': 'github_create_issue', 'description': '建 issue'},
    ];

    test('命名空间按 serverId 判定', () {
      expect(AiTools.ns(tools[0]), 'local');
      expect(AiTools.ns(tools[3]), 'mcp');
    });

    test('危险工具为 confirm, 其余 safe', () {
      expect(AiTools.risk('local_file_delete'), ToolRisk.confirm);
      expect(AiTools.risk('local_file_write'), ToolRisk.confirm);
      expect(AiTools.risk('local_web_search'), ToolRisk.safe);
      expect(AiTools.risk('github_create_issue'), ToolRisk.safe);
    });

    test('allow 为空 = 放行全部; deny 优先', () {
      final open = AiTools.filter(tools, const AiAgentDef(id: 'a', name: 'a'));
      expect(open.length, 4);
      final denied = AiTools.filter(tools,
          const AiAgentDef(id: 'a', name: 'a', deny: ['local_file_delete']));
      expect(denied.map((t) => t['name']), isNot(contains('local_file_delete')));
      expect(denied.length, 3);
    });

    test('allow 支持命名空间 / 精确名 / 前缀通配', () {
      final nsOnly = AiTools.filter(tools,
          const AiAgentDef(id: 'a', name: 'a', allow: ['mcp']));
      expect(nsOnly.map((t) => t['name']).toList(), ['github_create_issue']);

      final exact = AiTools.filter(tools,
          const AiAgentDef(id: 'a', name: 'a', allow: ['local_web_search']));
      expect(exact.map((t) => t['name']).toList(), ['local_web_search']);

      final prefix = AiTools.filter(tools,
          const AiAgentDef(id: 'a', name: 'a', allow: ['local_file_*']));
      expect(prefix.map((t) => t['name']).toList(),
          ['local_file_write', 'local_file_delete']);
    });

    test('allow 为 __none__ 时一个工具都不给(纯聊天智能体)', () {
      final none = AiTools.filter(tools,
          const AiAgentDef(id: 'a', name: 'a', allow: ['__none__']));
      expect(none, isEmpty);
      // 内置翻译官就是这个策略
      expect(AiAgents.byId('translator')!.allow, ['__none__']);
    });

    test('null 智能体 = 不过滤', () {
      expect(AiTools.filter(tools, null).length, 4);
    });
  });

  group('AiTools 文本工具协议(不支持 function-calling 的厂商兜底)', () {
    test('manifest 列出名称/参数/说明, 并给出调用格式', () {
      final m = AiTools.manifest([
        {'name': 'local_web_search', 'description': '联网搜索',
          'inputSchema': {'type': 'object', 'properties': {'query': {'type': 'string'}}}},
      ]);
      expect(m, contains('local_web_search(query)'));
      expect(m, contains('联网搜索'));
      expect(m, contains('<tool_call>'));
    });

    test('parseTextCalls 能解出调用, 坏 JSON 不抛错', () {
      final calls = AiTools.parseTextCalls(
        '我想查一下 <tool_call>{"name":"local_web_search","arguments":{"query":"今天天气"}}</tool_call> 稍等。'
        '<tool_call>{bad json}</tool_call>');
      expect(calls.length, 1);
      expect(calls.first['name'], 'local_web_search');
      expect((calls.first['arguments'] as Map)['query'], '今天天气');
    });

    test('stripTextCalls 去掉标签只留正文', () {
      final s = AiTools.stripTextCalls('开始<tool_call>{"name":"x"}</tool_call>结束');
      expect(s, '开始结束');
      expect(s.contains('tool_call'), isFalse);
    });
  });

  group('AiCompress 上下文预算压缩', () {
    List<Map<String, String>> mk(int n, {int len = 10}) =>
      [for (var i = 0; i < n; i++) {'role': i.isEven ? 'user' : 'assistant', 'content': 'm$i${'x' * len}'}];

    test('未超预算时原样返回(不浪费)', () {
      final m = mk(5);
      expect(identical(AiCompress.compress(m, budget: 100000), m), isTrue);
    });

    test('超预算时折叠早期消息为一条摘要, 保留最近 tail 条原文', () {
      final m = mk(40, len: 200);
      final out = AiCompress.compress(m, budget: 500, tail: 12);
      expect(out.length, 13, reason: '1 条摘要 + 12 条原文');
      expect(out.first['role'], 'system');
      expect(out.first['content'], contains('早期对话摘要'));
      expect(out.first['content'], contains('28 条消息已自动压缩'));
      // 最近一条必须是原文
      expect(out.last['content'], m.last['content']);
      // 压缩后应显著变小
      expect(AiCompress.sizeOf(out), lessThan(AiCompress.sizeOf(m)));
    });

    test('system 消息永远保留在前(人格/指令不能被压掉)', () {
      final m = <Map<String, String>>[
        {'role': 'system', 'content': '【用户全局指令】叫我老板'},
        ...mk(40, len: 200),
      ];
      final out = AiCompress.compress(m, budget: 500, tail: 12);
      expect(out.first['content'], '【用户全局指令】叫我老板');
      expect(out.length, 14);
    });

    test('消息数少于 tail 时不压缩(避免把全文删光)', () {
      final m = mk(6, len: 500);
      expect(AiCompress.compress(m, budget: 100, tail: 12).length, 6);
    });
  });

  group('AiInstruct 全局指令 / 人格注入', () {
    test('默认无人格无指令 → 不产生 system', () async {
      await AiInstruct.load();
      expect(AiInstruct.build(), isEmpty);
      expect(AiInstruct.active, isFalse);
    });

    test('人格 + 自定义指令都会进 system, 且自定义在后(优先级更高)', () async {
      await AiInstruct.setPersona('concise');
      await AiInstruct.setCustom('  我是做后端的，少讲前端  ');
      await AiInstruct.load();
      final s = AiInstruct.build();
      expect(s, contains('对话风格'));
      expect(s, contains('回答尽量短'));
      expect(s, contains('用户全局指令'));
      expect(s, contains('我是做后端的，少讲前端'));
      expect(s.indexOf('对话风格'), lessThan(s.indexOf('用户全局指令')));
      expect(AiInstruct.custom, '我是做后端的，少讲前端', reason: '应 trim');
    });

    test('未知人格 id 不崩, 且仍保留自定义指令', () async {
      await AiInstruct.setPersona('__nope__');
      await AiInstruct.setCustom('保留我');
      await AiInstruct.load();
      expect(AiInstruct.build(), contains('保留我'));
    });
  });

  group('AiMemory 长期记忆', () {
    test('增删改 + 渲染, 且条数上限与字符上限生效', () async {
      await AiMemory.load();
      AiMemory.entries.clear();
      await AiMemory.add('我住在杭州');
      await AiMemory.add('   ');
      await AiMemory.add('我不吃香菜');
      expect(AiMemory.entries.length, 2, reason: '空白条目不入库');
      expect(AiMemory.build(), contains('我住在杭州'));
      expect(AiMemory.build(), contains('我不吃香菜'));
      expect(AiMemory.entries.first.text, '我不吃香菜', reason: '最新的排在最前');

      final hangzhou = AiMemory.entries.firstWhere((e) => e.text == '我住在杭州');
      await AiMemory.update(hangzhou.id, '我住在深圳');
      expect(AiMemory.build(), contains('我住在深圳'));
      expect(AiMemory.build(), isNot(contains('我住在杭州')));

      await AiMemory.remove(hangzhou.id);
      expect(AiMemory.entries.length, 1);
      expect(AiMemory.build(), isNot(contains('我住在深圳')));
      expect(AiMemory.build(), contains('我不吃香菜'));
    });

    test('记忆段有字符上限, 超长条目被截断不会撑爆上下文', () async {
      await AiMemory.load();
      await AiMemory.add('x' * 5000);
      final b = AiMemory.build();
      expect(b.length, lessThanOrEqualTo(AiMemory.maxBlockChars + 200));
      expect(b, contains('…'));
    });
  });

  group('AiPins 会话钉注', () {
    test('按会话隔离, 可增可删', () async {
      await AiPins.add('s1', '这次回答都用英文');
      await AiPins.add('s2', '这是另一个会话');
      await AiPins.add('s1', '参考资料: ABC');
      expect((await AiPins.get('s1')).length, 2);
      expect((await AiPins.get('s2')).length, 1);
      await AiPins.removeAt('s1', 0);
      expect((await AiPins.get('s1')).first, '参考资料: ABC');
      // 越界/空 id 不抛
      await AiPins.removeAt('s1', 99);
      expect(await AiPins.get(''), isEmpty);
      expect(await AiPins.get('never'), isEmpty);
    });

    test('钉注渲染带编号', () {
      final s = AiPins.build(['甲', '乙']);
      expect(s, contains('[钉注1] 甲'));
      expect(s, contains('[钉注2] 乙'));
      expect(AiPins.build(const []), isEmpty);
    });
  });

  group('AiContext 上下文装配(装配顺序 = 由弱到强)', () {
    // 上面几组测试改过全局静态状态(人格/记忆), 这里显式归零, 避免测试互相污染
    Future<void> reset() async {
      await AiInstruct.setPersona('default');
      await AiInstruct.setCustom('');
      AiMemory.entries.clear();
      await AiInstruct.load();
      await AiMemory.load();
    }

    test('空配置时栈为空, 不产生噪声 system', () async {
      await reset();
      final stack = await AiContext.systemStack();
      expect(stack, isEmpty);
    });

    test('人格→智能体→技能→记忆→钉注→工具清单 顺序装配', () async {
      await reset();
      await AiInstruct.setPersona('rigorous');
      await AiInstruct.load();
      await AiMemory.add('我的时区是 GMT+8');
      final stack = await AiContext.systemStack(
        agent: AiAgents.byId('researcher'),
        skillSystem: '你是专业翻译。',
        pins: ['本次只回答中文'],
        toolManifest: true,
        tools: [
          {'serverId': 'local', 'name': 'local_web_search', 'description': '联网搜索', 'inputSchema': {}},
        ],
      );
      expect(stack.length, 6);
      expect(stack[0]['content'], contains('对话风格'));
      expect(stack[0]['content'], contains('区分事实'));
      expect(stack[1]['content'], contains('研究员'));
      expect(stack[2]['content'], contains('专业翻译'));
      expect(stack[3]['content'], contains('GMT+8'));
      expect(stack[4]['content'], contains('本次只回答中文'));
      expect(stack[5]['content'], contains('local_web_search'));
      for (final m in stack) {
        expect(m['role'], 'system');
        expect(m['content'], isNotEmpty);
      }
    });

    test('toolManifest=true 但没有工具时, 不注入空清单', () async {
      await reset();
      final stack = await AiContext.systemStack(toolManifest: true, tools: const []);
      expect(stack, isEmpty);
      for (final m in stack) { expect(m['content'], isNot(contains('可用工具'))); }
    });
  });

  group('AiTodo 任务清单', () {
    test('重置 / 勾选 / 进度', () {
      AiTodo.reset(['读文件', '改代码', '跑测试']);
      expect(AiTodo.active, isTrue);
      expect(AiTodo.progress, 0);
      AiTodo.complete(1);
      expect(AiTodo.progress, 1);
      AiTodo.complete(99); // 越界不抛
      expect(AiTodo.progress, 1);
      AiTodo.clear();
      expect(AiTodo.active, isFalse);
    });
  });
}
