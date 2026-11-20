// AI 控制总线 · 自驱动循环
//
// 把「看图 → 决策 → 执行」串成一个可中止的循环。这一层不做任何 UI，
// 只吐事件流，所以既能被设置页驱动，也能被未来的定时巡检驱动。
//
// 三个必须守住的边界（都是踩过的坑）：
//   1) 防死循环：同一条指令连续两次没效果就换，三次就停 ——
//      否则模型会对着一个被遮住的按钮点一整晚，把电耗完还报"执行中"。
//   2) 防幻觉：每步都重新截图。不要相信模型说的"已经打开了"，
//      只相信它**下一步看到的**截图。
//   3) 可中止：任何时候点停止都要在一步之内停下来。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'agent_bridge.dart';
import 'agent_llm.dart';
import 'agent_protocol.dart';
import 'agent_targets.dart';

/// 一步的记录（给 UI 用）。
class AgentStepView {
  final int index;

  /// 模型给的"这一步在干什么"
  final String say;
  final String thought;

  /// 实际下发的指令
  final Map<String, dynamic>? action;

  /// 执行结果
  final bool ok;
  final String? error;

  /// 决策时看到的画面（缩略图）
  final Uint8List? shot;

  final int ms;

  const AgentStepView({
    required this.index,
    this.say = '',
    this.thought = '',
    this.action,
    this.ok = true,
    this.error,
    this.shot,
    this.ms = 0,
  });
}

/// 整轮的结果。
class AgentRunResult {
  final bool ok;

  /// 给用户看的结论（模型说的最后一句话 / 中止原因）
  final String summary;
  final int steps;
  final String? fail;
  final List<AgentStepView> views;

  const AgentRunResult({
    required this.ok,
    required this.summary,
    required this.steps,
    this.fail,
    this.views = const [],
  });
}

class AgentRunner {
  bool _stopped = false;

  bool get stopped => _stopped;

  /// 中止。会在下一步之前生效（不会打断正在进行的点击）。
  void stop() => _stopped = true;

  /// 跑一轮。
  ///
  /// [onStep] 在**每步结束后**回调（含失败步），[onLog] 是给日志区的短文本。
  Future<AgentRunResult> run({
    required AgentLlm llm,
    required String goal,
    int maxSteps = 10,
    void Function(AgentStepView)? onStep,
    void Function(String)? onLog,
  }) async {
    _stopped = false;
    final views = <AgentStepView>[];
    final trace = <String>[];
    final bridge = AgentBridge.I;
    var lastKey = '';
    var sameCount = 0;

    if (!llm.ready) {
      return const AgentRunResult(
          ok: false, summary: '模型配置不完整（地址 / 模型名 / Key）', steps: 0);
    }

    for (var i = 1; i <= maxSteps; i++) {
      if (_stopped) {
        return AgentRunResult(
            ok: false, summary: '已手动停止', steps: views.length, views: views);
      }

      // ① 看
      final shot = await AgentTargets.shoot();
      final st = await bridge.exec(const AgentCmd('state', {}));
      final tree = await bridge.exec(const AgentCmd('tree', {'limit': 70}));
      final stateMap = st.ok && st.data is Map
          ? Map<String, dynamic>.from(st.data as Map)
          : <String, dynamic>{};
      final nodes = <Map<String, dynamic>>[];
      if (tree.ok && tree.data is Map) {
        final raw = (tree.data as Map)['nodes'];
        if (raw is List) {
          for (final e in raw) {
            if (e is Map) nodes.add(Map<String, dynamic>.from(e));
          }
        }
      }
      onLog?.call('第 $i 步：看画面（${shot?.length ?? 0} B，${nodes.length} 个控件）');

      // ② 想
      final d = await llm.decide(
        goal: goal,
        trace: trace.join('\n'),
        png: shot,
        state: stateMap,
        nodes: nodes,
      );
      if (_stopped) {
        return AgentRunResult(
            ok: false, summary: '已手动停止', steps: views.length, views: views);
      }
      if (d.done) {
        final v = AgentStepView(
            index: i, say: d.say.isEmpty ? '已完成' : d.say, thought: d.thought, shot: shot);
        views.add(v);
        onStep?.call(v);
        return AgentRunResult(
          ok: true,
          summary: d.say.isEmpty ? '已完成' : d.say,
          steps: views.length,
          views: views,
        );
      }
      if (d.cmd == null) {
        final why = d.fail ?? '模型没有给出可执行的动作';
        final v = AgentStepView(
            index: i, say: d.say, thought: d.thought, shot: shot, ok: false, error: why);
        views.add(v);
        onStep?.call(v);
        return AgentRunResult(
            ok: false, summary: d.say.isEmpty ? why : d.say,
            steps: views.length, fail: why, views: views);
      }

      final cmd = d.cmd!;
      final key = jsonEncode(cmd.toJson()..remove('id'));

      // ③ 做
      final t0 = DateTime.now();
      final r = await bridge.exec(cmd);
      final ms = DateTime.now().difference(t0).inMilliseconds;

      final v = AgentStepView(
        index: i,
        say: d.say,
        thought: d.thought,
        action: cmd.toJson()..remove('id'),
        ok: r.ok,
        error: r.ok ? null : (r.hint == null ? r.error : '${r.error}（${r.hint}）'),
        shot: shot,
        ms: ms,
      );
      views.add(v);
      onStep?.call(v);

      trace.add('${i ~/ 1}. ${_brief(cmd)} → ${r.ok ? '成功' : '失败：${r.error}'}');
      if (trace.length > 12) trace.removeAt(0);
      onLog?.call('第 $i 步：${_brief(cmd)} → ${r.ok ? 'ok' : 'ERR ${r.error}'}（${ms}ms）');

      // ④ 防死循环
      if (key == lastKey) {
        sameCount++;
        if (sameCount >= 2) {
          final why = '同一条指令连续执行 ${sameCount + 1} 次都没有推进，已停止（${_brief(cmd)}）';
          return AgentRunResult(
              ok: false, summary: why, steps: views.length, fail: why, views: views);
        }
      } else {
        sameCount = 0;
        lastKey = key;
      }

      await Future<void>.delayed(const Duration(milliseconds: 320));
    }

    final why = '达到步数上限 $maxSteps 仍未完成';
    return AgentRunResult(
        ok: false, summary: why, steps: views.length, fail: why, views: views);
  }

  static String _brief(AgentCmd c) {
    final m = c.toJson()..remove('id');
    final s = jsonEncode(m);
    return s.length > 110 ? '${s.substring(0, 110)}…' : s;
  }
}
