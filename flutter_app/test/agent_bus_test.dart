// AI 控制总线 · 协议与手势注入单测
//
// 为什么这组测试重要：控制总线是"AI 用来判断功能好坏"的唯一通道。
// 如果它自己不可靠（解析错、坐标错、点了没生效），那 AI 跑出来的
// 「全部通过」就是假的 —— 比没有测试更糟。
//
// 这里不需要真机：手势注入走 GestureBinding，本地 widget test 里同样生效。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/agent/agent_protocol.dart';
import 'package:thirdhub_app/core/agent/agent_targets.dart';

void main() {
  group('AgentCmd 解析', () {
    test('op / id / 参数摊平到顶层', () {
      final c = AgentCmd.fromJson({'op': 'Tap', 'id': 7, 'text': '红果短剧'});
      expect(c.op, 'tap', reason: 'op 必须小写归一，否则白名单匹配不上');
      expect(c.id, 7);
      expect(c.str('text'), '红果短剧');
      expect(c.args.containsKey('op'), isFalse, reason: 'op 不该留在 args 里被当参数用');
    });

    test('没给 op 时退化成 state（无害探活，而不是抛异常）', () {
      expect(AgentCmd.fromJson({}).op, 'state');
      expect(AgentCmd.fromJson({'op': '   '}).op, 'state');
    });

    test('id 支持字符串形式的数字', () {
      expect(AgentCmd.fromJson({'op': 'ping', 'id': '12'}).id, 12);
      expect(AgentCmd.fromJson({'op': 'ping', 'id': 'x'}).id, 0);
    });
  });

  group('参数收敛', () {
    test('xy 三种写法都认', () {
      expect(AgentCmd.fromJson({'op': 'tap', 'xy': [0.5, 0.8]}).xy, [0.5, 0.8]);
      expect(AgentCmd.fromJson({'op': 'tap', 'xy': '0.5,0.8'}).xy, [0.5, 0.8]);
      expect(AgentCmd.fromJson({'op': 'tap', 'x': 100, 'y': 200}).xy, [100.0, 200.0]);
      expect(AgentCmd.fromJson({'op': 'tap', 'xy': ['12', '34']}).xy, [12.0, 34.0]);
      expect(AgentCmd.fromJson({'op': 'tap'}).xy, isNull);
    });

    test('dir 只认四个方向', () {
      expect(AgentCmd.fromJson({'op': 'swipe', 'dir': 'LEFT'}).dir, 'left');
      expect(AgentCmd.fromJson({'op': 'swipe', 'direction': 'up'}).dir, 'up');
      expect(AgentCmd.fromJson({'op': 'swipe', 'dir': 'sideways'}).dir, isNull);
    });

    test('bool / int 从字符串来也认（CLI 传参常是字符串）', () {
      expect(AgentCmd.fromJson({'op': 'tap', 'exact': 'true'}).bool_('exact'), isTrue);
      expect(AgentCmd.fromJson({'op': 'wait', 'ms': '500'}).integer('ms'), 500);
      expect(AgentCmd.fromJson({'op': 'wait'}).bool_('raw', def: true), isTrue);
    });
  });

  group('白名单', () {
    test('协议里声明过的 op 都是小写，且覆盖实现里的分支', () {
      for (final op in agentOps) {
        expect(op, op.toLowerCase());
      }
      // 这些是桥里 switch 处理的分支，少一个就变成"unknown op"
      for (final must in [
        'ping', 'state', 'tree', 'nav', 'tab', 'platform', 'subtab',
        'tap', 'swipe', 'input', 'back', 'shot', 'wait', 'assert', 'eval', 'script'
      ]) {
        expect(agentOps.contains(must), isTrue, reason: '漏了 $must');
      }
    });
  });

  group('结果序列化', () {
    test('成功带 data，失败带 error + hint（不混用）', () {
      final ok = AgentResult.ok({'x': 1}, ms: 12).toJson();
      expect(ok['ok'], isTrue);
      expect(ok['data'], {'x': 1});
      expect(ok.containsKey('error'), isFalse);
      expect(ok['ms'], 12);

      final err = AgentResult.err('key 不在屏上', hint: '先 wait').toJson();
      expect(err['ok'], isFalse);
      expect(err['error'], 'key 不在屏上');
      expect(err['hint'], '先 wait');
      expect(err.containsKey('data'), isFalse);
    });
  });

  group('真实手势注入（widget test 里等同于真机）', () {
    testWidgets('按文字找到控件并点中它', (tester) async {
      var hits = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('红果短剧'),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => hits++,
                child: const Text('开始播放'),
              ),
            ]),
          ),
        ),
      ));
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      AgentTargets.screenSize = size;
      addTearDown(() => AgentTargets.screenSize = Size.zero);

      final node = AgentTargets.findByText('开始播放');
      expect(node, isNotNull, reason: '屏幕上有这行字就该找到');
      expect(node!.rect.width, greaterThan(10));

      // 走真实 PointerDown/Up，命中测试 + 手势识别器全参与
      await tester.runAsync(() => AgentTargets.tap(node.rect.center));
      await tester.pumpAndSettle();
      expect(hits, 1, reason: '点一次必须只触发一次（重复触发说明注入序列有问题）');
    });

    testWidgets('找不存在的文字返回 null，而不是抛异常', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('只有这一行'))));
      AgentTargets.screenSize = const Size(400, 800);
      addTearDown(() => AgentTargets.screenSize = Size.zero);
      expect(AgentTargets.findByText('并不存在的按钮'), isNull);
    });

    testWidgets('滑动能驱动 PageView 翻页（左右切平台的底层机制）', (tester) async {
      final pc = PageController();
      addTearDown(pc.dispose);
      var page = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: pc,
            onPageChanged: (i) => page = i,
            children: const [Text('红果'), Text('B站'), Text('片库')],
          ),
        ),
      ));
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      AgentTargets.screenSize = size;
      addTearDown(() => AgentTargets.screenSize = Size.zero);

      final c = Offset(size.width / 2, size.height / 2);
      await tester.runAsync(() => AgentTargets.swipe(
            Offset(c.dx + size.width * 0.4, c.dy),
            Offset(c.dx - size.width * 0.4, c.dy),
            steps: 10,
            ms: 200,
          ));
      await tester.pumpAndSettle();
      expect(page, 1, reason: '左滑一次应该翻到第 2 页');
    });
  });
}
