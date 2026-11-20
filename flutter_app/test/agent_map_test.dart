// 模块地图的防漂移测试。
//
// 为什么值得单独写一组：这张表是**直接喂给模型**的，写错一个字，
// 模型就会一本正经地往一个不存在的页面跳，而且失败信息是"点了没反应"，
// 排查成本极高。所以用测试把三条硬约束钉死：
//   1) 每条深链都能被 AgentDeeplink 解析出非空步骤，且第一步是 nav；
//   2) 模块名在 knownModules 白名单里（否则解析器会拒绝）；
//   3) 提示词里必须真的出现每个模块（避免拼串时漏掉）。

import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/agent/agent_deeplink.dart';
import 'package:thirdhub_app/core/agent/agent_map.dart';

void main() {
  test('每个模块的深链都能解析成 nav 开头的非空步骤', () {
    for (final m in AgentMap.modules) {
      final steps = AgentDeeplink.parse(m.deeplink);
      expect(steps, isNotEmpty, reason: '${m.key} 的深链 ${m.deeplink} 解析为空');
      expect(steps.first['op'], 'nav', reason: '${m.key} 的第一步必须是 nav');
      expect(steps.first['module'], m.key,
          reason: '${m.key} 的深链落到了 ${steps.first['module']}');
    }
  });

  test('模块名都在 knownModules 白名单里且不重复', () {
    final seen = <String>{};
    for (final m in AgentMap.modules) {
      expect(AgentDeeplink.knownModules.contains(m.key), isTrue,
          reason: '${m.key} 不在 knownModules 里');
      expect(seen.add(m.key), isTrue, reason: '${m.key} 重复登记');
    }
  });

  test('页面级的"怎么到"必须有内容，别留空给人猜', () {
    for (final m in AgentMap.modules) {
      for (final p in m.pages) {
        expect(p.name.trim(), isNotEmpty);
        expect(p.how.trim(), isNotEmpty, reason: '${m.key}/${p.name} 缺入口');
        expect(p.what.trim(), isNotEmpty, reason: '${m.key}/${p.name} 缺内容说明');
      }
    }
  });

  test('带 q 的深链会额外产生一次 search 动作（不是只跳空页）', () {
    final steps = AgentDeeplink.parse('thirdhub://novel?q=斗破苍穹');
    expect(steps.length, greaterThanOrEqualTo(2));
    expect(steps.last['op'], 'eval');
    expect(steps.last['name'], 'search');
    expect(steps.last['q'], '斗破苍穹');
  });

  test('find 认得模块名、深链和口语别名', () {
    expect(AgentMap.find('视频')?.key, '视频');
    expect(AgentMap.find('thirdhub://music')?.key, '音乐');
    expect(AgentMap.find('不存在的东西'), isNull);
  });

  test('提示词里每个模块都出现了，紧凑版不比详细版更长', () {
    final full = AgentMap.prompt();
    final brief = AgentMap.compact();
    for (final k in AgentMap.keys) {
      expect(full.contains(k), isTrue, reason: '详细版漏了 $k');
      expect(brief.contains(k), isTrue, reason: '紧凑版漏了 $k');
    }
    expect(brief.length, lessThan(full.length));
    expect(full.contains('app_open'), isTrue);
  });

  test('模块地图不会把 subtab 当成万能 op 推销（未接线的能力不许写进去）', () {
    // B 站栏目走的是 subtab，但只有「视频」页接了这个钩子；
    // 表里如果出现对其它页面 subtab 的承诺，就是又一轮"说做了没做"。
    final txt = AgentMap.prompt();
    expect(txt.contains('"op":"subtab"'), isFalse);
  });
}
