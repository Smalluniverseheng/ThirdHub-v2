// 本机 Agent 运行时自检（Local Agent Runtime）
//
// 为什么要有这条闸门：本机 Agent 是「手机不在局域网、不装电脑端 EXE 时也能干活」
// 的唯一路径。它一旦悄悄坏掉，用户看到的是「AI 突然只会聊天了」，而不是报错。
// 所以这里把三个最容易退化的地方钉死：
//   ① 模型输出解析（三种写法都要认，认不出就当结论，不能把用户卡死）
//   ② 事件流语义（seq 单调、类型顺序、审批中断、取消、回合上限）
//   ③ 观察结果裁剪（保留头尾，不能把关键的分页/报错信息掐掉）
//
// 用法：dart --disable-dart-dev tool/local_agent_selfcheck.dart
// 任一 FAIL → exit(1)。

import 'dart:io';

import '../lib/core/agent_models.dart';
import '../lib/core/agent_policy.dart';
import '../lib/core/local_agent.dart';

int pass = 0;
int fail = 0;
final List<String> failures = <String>[];

void ok(bool cond, String what) {
  if (cond) {
    pass++;
  } else {
    fail++;
    failures.add(what);
    print('FAIL $what');
  }
}

void eq(Object? a, Object? b, String what) => ok('$a' == '$b', '$what（实际 $a，期望 $b）');

/// 按脚本返回固定文本的假模型；脚本用完后一律返回结论。
LocalModelFn scripted(List<String> replies) {
  int i = 0;
  return (List<Map<String, dynamic>> _) async {
    if (i < replies.length) return replies[i++];
    return '{"final":"完成"}';
  };
}

List<String> typesOf(List<AgentEvent> evs) => evs.map((e) => e.type).toList();

Future<List<AgentEvent>> collect(Stream<AgentEvent> s) async {
  final List<AgentEvent> out = <AgentEvent>[];
  await for (final e in s) {
    out.add(e);
  }
  return out;
}

Future<void> main() async {
  // ── 1. parseAction：三种写法 + 回落 ──
  {
    final a = LocalAgentEngine.parseAction('{"tool":"engine_search","args":{"type":"novel","query":"剑来"}}');
    ok(!a.isFinal, '解析出工具调用');
    eq(a.tool, 'engine_search', '工具名');
    eq(a.args['query'], '剑来', '工具参数');

    final b = LocalAgentEngine.parseAction('{"thought":"已找到","final":"《剑来》在资料库里"}');
    ok(b.isFinal, 'final 当结论');
    eq(b.answer, '《剑来》在资料库里', '结论文本');
    eq(b.thought, '已找到', '结论里的 thought');

    final c = LocalAgentEngine.parseAction('{"answer":"用 answer 字段也行"}');
    eq(c.answer, '用 answer 字段也行', 'answer 字段兼容');

    final d = LocalAgentEngine.parseAction('```json\n{"tool":"app_state"}\n```');
    eq(d.tool, 'app_state', '代码块包裹的 JSON');

    final e = LocalAgentEngine.parseAction('我就是先说一句人话');
    ok(e.isFinal, '非 JSON 当结论');
    eq(e.answer, '我就是先说一句人话', '原文当结论');

    final f = LocalAgentEngine.parseAction('   ');
    eq(f.answer, '', '空白输入不崩');

    final g = LocalAgentEngine.parseAction('{"tool":"x"}');
    eq(g.args.isEmpty, true, 'args 缺省为空表');

    final h = LocalAgentEngine.parseAction('{"action":"note_add","arguments":{"text":"hi"}}');
    eq(h.tool, 'note_add', 'action/arguments 别名');
    eq(h.args['text'], 'hi', 'arguments 别名参数');
  }

  // ── 2. 观察裁剪：短的原样、长的保留头尾 ──
  {
    final eng = LocalAgentEngine(model: scripted(<String>[]), execTool: (_, __) async => '');
    eq(eng.clampObservation('短的'), '短的', '短观察不裁剪');
    // 默认上限 2000 字：拿 1006 字去测「会被裁」是错的（它本来就没超），
    // 所以这里显式把上限压到 100，让边界可测。
    final small = LocalAgentEngine(
        model: scripted(<String>[]), execTool: (_, __) async => '', observationLimit: 100);
    final long = List<String>.filled(300, 'A').join() + 'MIDDLE' + List<String>.filled(300, 'B').join();
    eq(eng.clampObservation(long), long, '默认上限内不裁剪（1006 < 2000）');
    final cut = small.clampObservation(long);
    ok(cut.length < long.length, '超上限被裁剪');
    ok(cut.length <= 100, '裁剪后不超过上限（实际 ${cut.length}）');
    ok(cut.startsWith('A'), '保留开头');
    ok(cut.endsWith('B'), '保留结尾');
    ok(cut.contains('省略'), '标明省略量');
    ok(!cut.contains('MIDDLE'), '被掐掉的确实是中间');
  }

  // ── 3. 单工具成功路径：事件顺序 + seq 单调 ──
  {
    final eng = LocalAgentEngine(
      model: scripted(<String>[
        '{"thought":"先看状态","tool":"app_state","args":{}}',
        '{"final":"当前在阅读模块"}',
      ]),
      execTool: (n, a) async => '模块=reading 版本=4.81.48',
      tools: localAgentTools,
    );
    final evs = await collect(eng.run(sessionId: 's1', input: '我现在在哪'));
    final t = typesOf(evs);
    eq(t.first, AgentEventType.userMessage, '首事件是 user_message');
    eq(t.last, AgentEventType.done, '末事件是 done');
    ok(t.contains(AgentEventType.toolCall), '有 tool_call');
    ok(t.contains(AgentEventType.toolResult), '有 tool_result');
    ok(t.indexOf(AgentEventType.toolCall) < t.indexOf(AgentEventType.toolResult), '调用在结果之前');
    bool seqOk = true;
    for (int i = 0; i < evs.length; i++) {
      if (evs[i].seq != i + 1) seqOk = false;
      if (!evs[i].id.startsWith('s1-')) seqOk = false;
    }
    ok(seqOk, 'seq 从 1 单调递增且 id 带会话前缀');
    eq(eng.auditLog.length, 1, '一次工具调用一条审计');
    eq(eng.auditLog.first['decision'], 'allow', '审计记录 allow');
    final done = evs.last.payload;
    eq(done['stopped'], 'final', 'done 标记正常收尾');
  }

  // ── 4. 读工具不弹确认；写工具必须确认 ──
  {
    int asked = 0;
    final eng = LocalAgentEngine(
      model: scripted(<String>[
        '{"tool":"goto_module","args":{"module":"reading"}}',
        '{"final":"已切到阅读"}',
      ]),
      execTool: (n, a) async => '已切换',
      tools: localAgentTools,
      confirm: (tool, risk, args) async {
        asked++;
        return true;
      },
    );
    final evs = await collect(eng.run(sessionId: 's2', input: '切到阅读'));
    eq(asked, 1, '写工具触发一次确认');
    ok(typesOf(evs).contains(AgentEventType.confirmRequest), '有 confirm_request');
    ok(typesOf(evs).contains(AgentEventType.confirmResult), '有 confirm_result');
    ok(typesOf(evs).contains(AgentEventType.toolCall), '批准后真的执行');
  }
  {
    int asked = 0;
    final eng = LocalAgentEngine(
      model: scripted(<String>[
        '{"tool":"app_state"}',
        '{"final":"好"}',
      ]),
      execTool: (n, a) async => 'ok',
      tools: localAgentTools,
      confirm: (t, r, a) async {
        asked++;
        return true;
      },
    );
    await collect(eng.run(sessionId: 's3', input: '看状态'));
    eq(asked, 0, '只读工具不打扰用户');
  }

  // ── 5. 用户拒绝 → 不执行，但循环继续 ──
  {
    bool executed = false;
    final eng = LocalAgentEngine(
      model: scripted(<String>[
        '{"tool":"set_setting","args":{"key":"a","value":"b"}}',
        '{"final":"那就不改"}',
      ]),
      execTool: (n, a) async {
        executed = true;
        return '改了';
      },
      tools: localAgentTools,
      confirm: (t, r, a) async => false,
    );
    final evs = await collect(eng.run(sessionId: 's4', input: '改设置'));
    ok(!executed, '拒绝后没有执行');
    final results = evs.where((e) => e.type == AgentEventType.toolResult).toList();
    eq(results.length, 1, '仍有一条 tool_result 交代原因');
    eq(results.first.payload['ok'], false, '结果标记失败');
    eq(typesOf(evs).last, AgentEventType.done, '循环没有卡死');
  }

  // ── 6. 危险工具且没有确认入口 → 直接拒绝 ──
  {
    const List<LocalAgentTool> tools = <LocalAgentTool>[
      LocalAgentTool(name: 'wipe', description: '删光数据', risk: AgentRisk.danger),
    ];
    bool executed = false;
    final eng = LocalAgentEngine(
      model: scripted(<String>['{"tool":"wipe"}', '{"final":"不删了"}']),
      execTool: (n, a) async {
        executed = true;
        return 'done';
      },
      tools: tools,
    );
    final evs = await collect(eng.run(sessionId: 's5', input: '清空'));
    ok(!executed, '危险操作没有执行');
    ok(typesOf(evs).contains(AgentEventType.audit), '留下拒绝审计');
    eq(eng.auditLog.first['decision'], 'deny', '审计记录 deny');
  }

  // ── 7. 未知工具：报错但不中断 ──
  {
    final eng = LocalAgentEngine(
      model: scripted(<String>['{"tool":"nope"}', '{"final":"换个办法"}']),
      execTool: (n, a) async => '不该跑到这里',
      tools: localAgentTools,
    );
    final evs = await collect(eng.run(sessionId: 's6', input: 'x'));
    final r = evs.firstWhere((e) => e.type == AgentEventType.toolResult);
    eq(r.payload['ok'], false, '未知工具标记失败');
    ok('${r.payload['observation']}'.contains('没有这个工具'), '提示可用工具');
    eq(typesOf(evs).last, AgentEventType.done, '仍然正常收尾');
  }

  // ── 8. 回合上限：不会无限自转 ──
  {
    final eng = LocalAgentEngine(
      model: scripted(List<String>.generate(50, (i) => '{"tool":"app_state"}')),
      execTool: (n, a) async => 'ok',
      tools: localAgentTools,
      maxSteps: 3,
    );
    final evs = await collect(eng.run(sessionId: 's7', input: '一直转'));
    final calls = evs.where((e) => e.type == AgentEventType.toolCall).length;
    eq(calls, 3, '最多执行 maxSteps 次');
    final done = evs.last;
    eq(done.type, AgentEventType.done, '上限后收尾');
    ok('${done.payload['stopped']}'.contains('最大回合数'), '说明为什么停');
  }

  // ── 9. 取消：不调工具、直接收尾 ──
  {
    final cancel = LocalAgentCancel()..cancel('用户按了停止');
    final eng = LocalAgentEngine(
      model: scripted(<String>['{"tool":"app_state"}']),
      execTool: (n, a) async => 'ok',
      tools: localAgentTools,
    );
    final evs = await collect(eng.run(sessionId: 's8', input: 'x', cancel: cancel));
    eq(evs.where((e) => e.type == AgentEventType.toolCall).length, 0, '取消后没有工具调用');
    ok('${evs.last.payload['stopped']}'.contains('用户按了停止'), '带上取消原因');
  }

  // ── 10. 模型抛异常：报错但给用户交代 ──
  {
    final eng = LocalAgentEngine(
      model: (msgs) async => throw StateError('网络断了'),
      execTool: (n, a) async => 'ok',
    );
    final evs = await collect(eng.run(sessionId: 's9', input: 'x'));
    ok(typesOf(evs).contains(AgentEventType.error), '有 error 事件');
    ok(evs.any((e) => e.type == AgentEventType.assistantMessage), '仍给用户一句话');
    eq(typesOf(evs).last, AgentEventType.done, '仍然收尾');
  }

  // ── 11. 本机工具清单自身要合规 ──
  {
    ok(localAgentTools.isNotEmpty, '本机工具清单非空');
    final names = localAgentTools.map((t) => t.name).toSet();
    eq(names.length, localAgentTools.length, '工具名不重复');
    ok(localAgentTools.every((t) => t.description.trim().isNotEmpty), '每个工具都有说明');
    ok(localAgentTools.every((t) => <String>[AgentRisk.read, AgentRisk.write, AgentRisk.danger].contains(t.risk)),
        '风险级别都在三级之内');
    final banned = <String>['copy_manga', 'baozi', '书源', '图源'];
    for (final t in localAgentTools) {
      for (final b in banned) {
        ok(!t.description.contains(b) && !t.name.contains(b), '工具不含第三方内容源标识「$b」');
      }
    }
  }

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) {
    print('本机 Agent 运行时有问题，已拦下：');
    for (final f in failures) {
      print('  · $f');
    }
    exit(1);
  }
}
