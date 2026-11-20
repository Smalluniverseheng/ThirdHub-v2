// 应用内 AI 自驱动 + 深链的单元测试
//
// 这两块都是「没人盯着也要正确」的东西：
//   · 决策解析错了 → AI 会乱点用户手机；
//   · 深链解析错了 → "点链接跳到小说"跳到别处，且没人会发现。
// 所以它们必须是纯函数、可断言，而不是只能靠真机试。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/agent/agent_deeplink.dart';
import 'package:thirdhub_app/core/agent/agent_llm.dart';

void main() {
  group('AgentDecision.parse', () {
    test('裸 JSON 能解析出动作', () {
      final d = AgentDecision.parse(
          '{"thought":"看到红果","say":"切红果","action":{"op":"platform","name":"红果"}}');
      expect(d.cmd, isNotNull);
      expect(d.cmd!.op, 'platform');
      expect(d.cmd!.str('name'), '红果');
      expect(d.thought, '看到红果');
      expect(d.say, '切红果');
      expect(d.done, isFalse);
    });

    test('markdown 代码块围栏能剥掉', () {
      final d = AgentDecision.parse('''
这是我要做的：
```json
{"thought":"x","say":"点一下","action":{"op":"tap","text":"短剧"}}
```
''');
      expect(d.cmd!.op, 'tap');
      expect(d.cmd!.str('text'), '短剧');
    });

    test('前面带解释文字也能抠出第一个完整对象', () {
      final d = AgentDecision.parse(
          '我先看一眼。{"say":"等一下","action":{"op":"wait","ms":800}} 然后就继续');
      expect(d.cmd!.op, 'wait');
      expect(d.cmd!.integer('ms'), 800);
    });

    test('action 写成字符串 done = 结束', () {
      final d = AgentDecision.parse('{"thought":"都好了","say":"全部正常","action":"done"}');
      expect(d.done, isTrue);
      expect(d.isTerminal, isTrue);
      expect(d.say, '全部正常');
    });

    test('done 布尔写法也认', () {
      final d = AgentDecision.parse('{"say":"完成","done":true}');
      expect(d.done, isTrue);
    });

    test('fail 会带出原因', () {
      final d = AgentDecision.parse(
          '{"say":"漫画加载不出来","action":{"op":"fail","reason":"漫画页是空白"}}');
      expect(d.done, isFalse);
      expect(d.fail, '漫画页是空白');
      expect(d.isTerminal, isTrue);
    });

    test('白名单外的 op 必须被拒绝（防 RPC 后门）', () {
      final d = AgentDecision.parse('{"action":{"op":"shell","cmd":"rm -rf /"}}');
      expect(d.cmd, isNull);
      expect(d.fail, contains('不支持'));
    });

    test('不是 JSON 就失败，不瞎猜', () {
      final d = AgentDecision.parse('我觉得应该点击那个按钮');
      expect(d.cmd, isNull);
      expect(d.fail, isNotNull);
      expect(d.raw, isNotEmpty);
    });

    test('JSON 坏了但不抛异常', () {
      final d = AgentDecision.parse('{"action":{"op":"tap"');
      expect(d.cmd, isNull);
      expect(d.fail, isNotNull);
    });

    test('嵌套对象里的花括号不会截断', () {
      final d = AgentDecision.parse(
          '{"say":"点","action":{"op":"tap","xy":[0.5,0.25],"meta":{"a":{"b":1}}}}');
      expect(d.cmd!.op, 'tap');
      expect(d.cmd!.xy, [0.5, 0.25]);
    });
  });

  group('请求体形状', () {
    final png = Uint8List.fromList([1, 2, 3, 4]);

    test('openai：图片走 image_url + data URI', () {
      final b = AgentLlm.openaiBody(
          model: 'gpt-4o', sys: 's', user: 'u', png: png);
      final msgs = b['messages'] as List;
      final content = (msgs[1] as Map)['content'] as List;
      expect(content.any((e) => (e as Map)['type'] == 'image_url'), isTrue);
      final img = content.firstWhere((e) => (e as Map)['type'] == 'image_url') as Map;
      expect('${(img['image_url'] as Map)['url']}',
          startsWith('data:image/png;base64,'));
    });

    test('openai：没截图时不塞图片段', () {
      final b = AgentLlm.openaiBody(model: 'm', sys: 's', user: 'u', png: null);
      final content = ((b['messages'] as List)[1] as Map)['content'] as List;
      expect(content.any((e) => (e as Map)['type'] == 'image_url'), isFalse);
    });

    test('anthropic：图片走 base64 source', () {
      final b = AgentLlm.anthropicBody(
          model: 'claude-x', sys: 's', user: 'u', png: png);
      final content = (((b['messages'] as List)[0] as Map)['content']) as List;
      final img = content.firstWhere((e) => (e as Map)['type'] == 'image') as Map;
      expect((img['source'] as Map)['type'], 'base64');
      expect((img['source'] as Map)['media_type'], 'image/png');
    });

    test('系统提示词里列出了全部可用 op', () {
      final s = AgentLlm.buildSystemPrompt();
      for (final op in ['nav', 'platform', 'tap', 'swipe', 'deeplink', 'done', 'fail']) {
        expect(s.contains('"$op"'), isTrue, reason: '提示词缺 $op');
      }
    });
  });

  group('AgentDeeplink.parse', () {
    List<Map<String, dynamic>> p(String s) => AgentDeeplink.parse(s);

    test('识别协议', () {
      expect(AgentDeeplink.looksLike('thirdhub://video'), isTrue);
      expect(AgentDeeplink.looksLike('https://x.com'), isFalse);
    });

    test('视频 + 平台', () {
      final s = p('thirdhub://video?platform=hongguo');
      expect(s.length, 2);
      expect(s[0], {'op': 'nav', 'module': '视频'});
      expect(s[1], {'op': 'platform', 'name': '红果'});
    });

    test('bili 宿主自动补视频页', () {
      final s = p('thirdhub://bili');
      expect(s[0]['module'], '视频');
      expect(s[1]['name'], '哔哩哔哩');
    });

    test('平台写在路径里', () {
      final s = p('thirdhub://video/hongguo');
      expect(s[1]['name'], '红果');
    });

    test('小说 + 搜索词', () {
      final s = p('thirdhub://novel?q=斗破苍穹');
      expect(s[0]['module'], '小说');
      expect(s[1]['op'], 'eval');
      expect(s[1]['name'], 'search');
      expect(s[1]['q'], '斗破苍穹');
    });

    test('搜索 + 类型', () {
      final s = p('thirdhub://search?q=周杰伦&kind=music');
      expect(s[0]['module'], '搜索');
      expect(s[1]['kind'], 'music');
    });

    test('open?module= 中文模块名', () {
      final s = p('thirdhub://open?module=漫画');
      expect(s.single, {'op': 'nav', 'module': '漫画'});
    });

    test('do?action= 传参', () {
      final s = p('thirdhub://do?action=refresh&force=1');
      expect(s.single['op'], 'eval');
      expect(s.single['name'], 'refresh');
      expect(s.single['force'], '1');
    });

    test('子页签', () {
      final s = p('thirdhub://bili?sub=番剧');
      expect(s.any((e) => e['op'] == 'subtab' && e['tab'] == '番剧'), isTrue);
    });

    test('不认识的宿主 / 非本协议 → 空数组，不抛', () {
      expect(p('thirdhub://whatever-zzz'), isEmpty);
      expect(p('https://example.com'), isEmpty);
      expect(p(''), isEmpty);
    });

    test('所有产出的 op 都在白名单里', () {
      const allowed = {'nav', 'platform', 'subtab', 'eval'};
      for (final u in [
        'thirdhub://video?platform=hongguo',
        'thirdhub://bili?sub=直播',
        'thirdhub://novel?q=x',
        'thirdhub://search?q=y&kind=comic',
        'thirdhub://do?action=z',
      ]) {
        for (final s in p(u)) {
          expect(allowed.contains(s['op']), isTrue,
              reason: '$u 产出了非白名单 op ${s['op']}');
        }
      }
    });

    test('解析结果能被 JSON 编解码（要过 HTTP 桥）', () {
      final s = p('thirdhub://video?platform=bilibili&sub=番剧');
      final round = jsonDecode(jsonEncode(s)) as List;
      expect(round.length, s.length);
    });
  });
}
