// AI 自驱动循环的端到端测试（不需要真机、不需要模型、不需要网络、不需要帧）
//
// 为什么要有这一组：前面几组测的是"解析对不对"，真正会出事的是**循环** ——
// 它决定什么时候再截一次图、什么时候停、失败了要不要重试。
//
// ★2026-11-20 教训：这一组最初写成 testWidgets，直接调 AgentBridge.I.exec 与
//   AgentTargets.shoot。这两个都挂在真实帧调度上（settle 等 postFrame、
//   shoot 等 toImage）。只要有一帧没推上来，测试就**永久挂在 await 上**，
//   实测卡满 10 分钟才被超时杀掉 —— 整个 `flutter test` 报废。
//   现在循环本身接受注入的 exec/shoot/stepGap，所以这里纯 Dart 跑，
//   毫秒级完成、结果确定。真手势注入那块由 agent_bus_test.dart 用 pump 覆盖。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/agent/agent_llm.dart';
import 'package:thirdhub_app/core/agent/agent_protocol.dart';
import 'package:thirdhub_app/core/agent/agent_runner.dart';

/// 假大脑：按剧本一句一句回答（走真实 JSON 解析，不绕过契约）。
class _FakeBrain implements AgentBrain {
  _FakeBrain(this.script);

  final List<String> script;
  int calls = 0;

  @override
  bool get ready => true;

  @override
  Future<AgentDecision> decide({
    required String goal,
    required String trace,
    required Uint8List? png,
    required Map<String, dynamic> state,
    required List<Map<String, dynamic>> nodes,
  }) async {
    final i = calls < script.length ? calls : script.length - 1;
    calls++;
    return AgentDecision.parse(script[i]);
  }
}

/// 假总线：记录收到的指令，按 op 返回成功/失败。不碰 UI、不碰帧。
class _FakeBus {
  _FakeBus({this.failOps = const {}});

  final Set<String> failOps;
  final List<AgentCmd> got = [];

  Future<AgentResult> exec(AgentCmd c) async {
    got.add(c);
    if (failOps.contains(c.op)) {
      return AgentResult.err('mock: ${c.op} failed', hint: '换个办法');
    }
    if (c.op == 'state') return AgentResult.ok({'module': '视频'});
    if (c.op == 'tree') return AgentResult.ok({'nodes': []});
    return AgentResult.ok({'ok': c.op});
  }

  /// 真正下发过的"动作"（排除每步固定取的状态/控件树）
  List<AgentCmd> get actions =>
      [for (final c in got) if (c.op != 'state' && c.op != 'tree') c];
}

void main() {
  AgentRunner runnerFor(_FakeBus bus) =>
      AgentRunner(exec: bus.exec, shoot: () async => null, stepGap: Duration.zero);

  test('模型让点就点，说 done 就停，并把总结带出来', () async {
    final bus = _FakeBus();
    final brain = _FakeBrain([
      '{"thought":"看见搜索框","say":"去搜斗破","action":{"op":"deeplink","url":"thirdhub://novel?q=斗破苍穹"}}',
      '{"thought":"正文出来了","say":"能读，三章都在","action":{"op":"done"}}',
    ]);
    final seen = <AgentStepView>[];
    final r = await runnerFor(bus).run(llm: brain, goal: '搜斗破并读一章', onStep: seen.add);

    expect(r.ok, isTrue);
    expect(r.summary, '能读，三章都在');
    expect(r.steps, 2);
    expect(seen.length, 2);
    expect(seen.first.action!['op'], 'deeplink');
    expect(bus.actions.length, 1);
    expect(bus.actions.first.args['url'], 'thirdhub://novel?q=斗破苍穹');
  });

  test('同一条指令连发三次会自己刹车（不会点一整晚）', () async {
    final bus = _FakeBus();
    const same = '{"say":"再点一次","action":{"op":"tap","text":"继续"}}';
    final r = await runnerFor(bus)
        .run(llm: _FakeBrain([same, same, same, same]), goal: '一直点', maxSteps: 8);

    expect(r.ok, isFalse);
    expect(r.fail, contains('没有推进'));
    // 第 3 次重复才刹车 —— 前两次给模型改正的机会
    expect(r.steps, 3);
    expect(bus.actions.length, 3);
  });

  test('换了指令就不算重复（换方法是被允许的）', () async {
    final bus = _FakeBus();
    final r = await runnerFor(bus).run(
      llm: _FakeBrain([
        '{"action":{"op":"tap","text":"A"}}',
        '{"action":{"op":"tap","text":"B"}}',
        '{"action":{"op":"tap","text":"A"}}',
        '{"action":{"op":"done"}}',
      ]),
      goal: '试几个入口',
      maxSteps: 6,
    );
    expect(r.ok, isTrue);
    expect(r.steps, 4);
  });

  test('模型给不出动作时立即停下并说明原因（不硬凑一条指令）', () async {
    final bus = _FakeBus();
    final r = await runnerFor(bus)
        .run(llm: _FakeBrain(['我想想……应该是那个按钮吧（没给 JSON）']), goal: 'x');
    expect(r.ok, isFalse);
    expect(r.fail, isNotNull);
    expect(r.steps, 1);
    expect(bus.actions, isEmpty, reason: '解析失败时绝不能瞎下发');
  });

  test('模型越权要 shell 会被拒绝（不会变成系统后门）', () async {
    final bus = _FakeBus();
    final r = await runnerFor(bus)
        .run(llm: _FakeBrain(['{"say":"我想调系统","action":{"op":"shell","cmd":"id"}}']), goal: 'x');
    expect(r.ok, isFalse);
    expect(r.fail, contains('不支持'));
    expect(bus.actions, isEmpty);
  });

  test('点停止能在一步之内停下（不是靠超时停的）', () async {
    final bus = _FakeBus();
    final runner = runnerFor(bus);
    final brain = _FakeBrain(List.filled(20, '{"action":{"op":"tap","text":"继续"}}'));
    final fut = runner.run(llm: brain, goal: '一直点', maxSteps: 20);
    runner.stop();
    final r = await fut;
    expect(r.summary, contains('停止'));
    expect(r.steps, 0);
  });

  test('配置不全时一步都不走（不发请求、不下指令）', () async {
    final bus = _FakeBus();
    final r = await runnerFor(bus).run(
      llm: AgentLlm(providerId: 'x', model: '', base: '', apiKey: ''),
      goal: 'x',
    );
    expect(r.ok, isFalse);
    expect(r.steps, 0);
    expect(bus.got, isEmpty);
  });

  test('走到步数上限会说清是"没跑完"而不是"成功"', () async {
    final bus = _FakeBus();
    final r = await runnerFor(bus).run(
      llm: _FakeBrain([
        '{"action":{"op":"tap","text":"A"}}',
        '{"action":{"op":"tap","text":"B"}}',
        '{"action":{"op":"tap","text":"C"}}',
      ]),
      goal: 'x',
      maxSteps: 2,
    );
    expect(r.ok, isFalse);
    expect(r.fail, contains('上限'));
    expect(r.steps, 2);
  });
}
