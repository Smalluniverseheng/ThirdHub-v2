// 酒馆对话上下文（裁剪 / 首条对齐 / 重新生成截点）的自检 —— 纯 Dart VM，零 Flutter 依赖。
//
// 跑法（在 flutter_app/ 目录下）：
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//            tool/tavern_context_selfcheck.dart
//
// 为什么需要它：
//   这段逻辑的两个缺陷**都只在真机上聊够轮数才出现**，界面上没有任何提示：
//     · 上下文截到最近 24 条后，首条可能是 assistant → Anthropic / Gemini 整轮 400，
//       表现是"聊到十几轮突然报错"，重开 App 又好了（会话短了）；
//     · 只剩开场白时点「重新生成」→ 请求里只有 system → 报错文案长得像 Key 配错了。
//   把裁剪收口成纯函数（`lib/core/tavern_context.dart`）之后，这两条可以逐条断言。
import 'dart:io';

import 'package:thirdhub_app/core/tavern_context.dart';

int pass = 0, fail = 0;
final List<String> fails = <String>[];

void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
  } else {
    fail++;
    fails.add(name);
    print('  FAIL  $name${extra.isEmpty ? '' : '  ($extra)'}');
  }
}

TavernTurn u(String t) => TavernTurn('user', t);
TavernTurn a(String t) => TavernTurn('assistant', t);

/// 一问一答铺开：[opening?, u1,a1,u2,a2,…]
List<TavernTurn> dialog(int rounds, {bool opening = false}) {
  final out = <TavernTurn>[];
  if (opening) out.add(a('开场白'));
  for (var i = 1; i <= rounds; i++) {
    out.add(u('问题$i'));
    out.add(a('回答$i'));
  }
  return out;
}

List<String> rolesOf(List<Map<String, String>> m) =>
    [for (final e in m) e['role']!];
List<String> contentsOf(List<Map<String, String>> m) =>
    [for (final e in m) e['content']!];

void main() {
  print('== 酒馆对话上下文自检 ==');

  // ── 1. build 的基本形状 ────────────────────────────────────────────────
  {
    final m = TavernContext.build(system: '你是 A', turns: const []);
    ck('空会话只剩 system', m.length == 1 && m[0]['role'] == 'system');
    ck('system 内容原样', m[0]['content'] == '你是 A');
  }
  {
    final m = TavernContext.build(system: 'S', turns: [u('你好')]);
    ck('单条 user → system + user', m.length == 2);
    ck('第二条是 user 且文本一致', m[1]['role'] == 'user' && m[1]['content'] == '你好');
    ck('system 永远在最前', m.first['role'] == 'system');
  }
  {
    final m = TavernContext.build(system: 'S', turns: [
      u('多行\n文本'),
      a('带表情 😀 与「引号」'),
    ]);
    ck('多行/emoji/引号原样透传',
        m[1]['content'] == '多行\n文本' && m[2]['content'] == '带表情 😀 与「引号」');
    ck('顺序保持', rolesOf(m).join(',') == 'system,user,assistant');
  }

  // ── 2. 窗口截断 ───────────────────────────────────────────────────────
  {
    ck('默认窗口是 24', TavernContext.defaultWindow == 24);
    final turns = dialog(20); // 40 条
    final m = TavernContext.build(system: 'S', turns: turns);
    ck('40 条只带 24 条（+system）', m.length == 1 + 24, '${m.length}');
    ck('带的是最近的 24 条', m.last['content'] == '回答20');
    ck('窗口起点是 user（偶数索引正是问题）',
        m[1]['content'] == '问题9' && m[1]['role'] == 'user',
        '${m[1]['content']}');
  }
  {
    final m = TavernContext.build(system: 'S', turns: dialog(20), window: 0);
    ck('window=0 视为不带上文', m.length == 1 && m[0]['role'] == 'system');
  }
  {
    final m = TavernContext.build(system: 'S', turns: dialog(3), window: 999);
    ck('窗口大于总长时全带', m.length == 1 + 6, '${m.length}');
  }
  {
    // window=1：最后一条是 assistant → 对齐后什么都不剩，只能只剩 system。
    // 这不是 bug，而是「宁可少带也别发出非法请求」的取舍。
    final m = TavernContext.build(system: 'S', turns: dialog(2), window: 1);
    ck('window=1 且末条是 assistant → 只剩 system',
        m.length == 1 && m[0]['role'] == 'system', '${m.length}');
  }

  // ── 3. 首条非 system 必须是 user（4.81.21 的真实缺陷）────────────────
  {
    // 手工构造：截断点正好落在一问一答中间
    final turns = <TavernTurn>[];
    for (var i = 0; i < 30; i++) {
      turns.add(i.isEven ? a('旧回答$i') : u('旧问题$i'));
    }
    final m = TavernContext.build(system: 'S', turns: turns, window: 6);
    ck('截断点落在 assistant 上时会往后对齐到 user',
        m.length == 6 && m[1]['role'] == 'user', rolesOf(m).join(','));
    ck('对齐时丢掉的是 a24，不是把整段清空',
        m[1]['content'] == '旧问题25', '${m[1]['content']}');
    ck('对齐后仍不超过窗口', m.length <= 1 + 6);
  }
  {
    final m = TavernContext.build(
        system: 'S', turns: [a('a1'), a('a2'), a('a3'), u('u1'), a('a4')]);
    ck('开头连续多条 assistant 全部丢掉',
        m.length == 3 && m[1]['content'] == 'u1', rolesOf(m).join(','));
  }
  {
    final m = TavernContext.build(system: 'S', turns: [a('只有开场白')]);
    ck('只有开场白 → 只剩 system（不发出只有 system 的请求）',
        m.length == 1, '${m.length}');
  }
  {
    // 真实场景：有开场白 + 12 轮 = 25 条 > 24，截断后首条一定是 assistant。
    final turns = dialog(12, opening: true);
    ck('场景前提：25 条确实超窗', turns.length == 25);
    final m = TavernContext.build(system: 'S', turns: turns);
    ck('25 条截断后首条仍是 user（开场白被丢掉）',
        m.length > 1 && m[1]['role'] == 'user', rolesOf(m).take(3).join(','));
    ck('丢弃的是开场白，不是把整段清空', m.any((e) => e['content'] == '问题1') ||
        m.any((e) => e['content'] == '问题2'));
  }

  // ── 4. build 不得修改入参 ────────────────────────────────────────────
  {
    final turns = dialog(20, opening: true);
    final n = turns.length;
    final firstBefore = turns.first.text;
    TavernContext.build(system: 'S', turns: turns, window: 4);
    ck('build 不缩短入参', turns.length == n, '${turns.length} vs $n');
    ck('build 不丢弃入参元素', turns.first.text == firstBefore);
  }

  // ── 5. 重新生成的截点 ────────────────────────────────────────────────
  {
    ck('空会话 → 不能重生成', TavernContext.regenerateCutoff(const []) == -1);
    ck('只有开场白 → 不能重生成',
        TavernContext.regenerateCutoff([a('开场白')]) == -1);
    ck('只有 assistant 两条 → 不能重生成',
        TavernContext.regenerateCutoff([a('x'), a('y')]) == -1);
    ck('末条是 user（还没回复）→ 不能重生成',
        TavernContext.regenerateCutoff([u('u1')]) == -1);
    ck('[a,u] 末条是 user → 不能重生成',
        TavernContext.regenerateCutoff([a('开场白'), u('u1')]) == -1);
  }
  {
    ck('[u1,a1] → 截在 1', TavernContext.regenerateCutoff([u('u1'), a('a1')]) == 1);
    ck('[开场白,u1,a1] → 截在 2（开场白保留在会话里）',
        TavernContext.regenerateCutoff([a('开场白'), u('u1'), a('a1')]) == 2);
    ck('[u1,a1,a2] → 截在 1（尾部连续两条一起删）',
        TavernContext.regenerateCutoff([u('u1'), a('a1'), a('a2')]) == 1);
    ck('[u1,a1,u2,a2,a3] → 截在 3',
        TavernContext.regenerateCutoff([u('u1'), a('a1'), u('u2'), a('a2'), a('a3')]) ==
            3);
  }
  {
    // 返回值必须落在 1..length-1：0 会让 build 只剩 system，length 等于没删
    final cases = <List<TavernTurn>>[
      dialog(3),
      dialog(3, opening: true),
      [u('u1'), a('a1'), a('a2'), a('a3')],
    ];
    for (final c in cases) {
      final cut = TavernContext.regenerateCutoff(c);
      ck('截点落在合法区间（len=${c.length} → $cut）',
          cut >= 1 && cut < c.length, '$cut');
    }
  }

  // ── 6. 联动：截点 → 剩余会话 → 上下文 ───────────────────────────────
  {
    final chat = [a('开场白'), u('问题1'), a('回答1')];
    final cut = TavernContext.regenerateCutoff(chat);
    ck('场景前提：截点应 ≥1', cut >= 1, '$cut');
    final remain = cut < 0 ? <TavernTurn>[] : chat.sublist(0, cut);
    final m = TavernContext.build(system: 'S', turns: remain);
    ck('重生成后的上下文 = system + 问题1',
        m.length == 2 && m[1]['content'] == '问题1', contentsOf(m).join('|'));
    ck('旧回复不进上下文', !m.any((e) => e['content'] == '回答1'));
    ck('首条非 system 是 user', m.length > 1 && m[1]['role'] == 'user');
  }
  {
    // 停过两次：会话尾部堆了两条半截回复，重生成要把两条都清掉
    final chat = [u('u1'), a('半截1'), a('半截2')];
    final cut = TavernContext.regenerateCutoff(chat);
    ck('场景前提：截点应 ≥1（两条半截一起清）', cut >= 1, '$cut');
    final m = TavernContext.build(
        system: 'S', turns: cut < 0 ? <TavernTurn>[] : chat.sublist(0, cut));
    ck('多条半截回复一起清掉',
        m.length == 2 && !m.any((e) => '${e['content']}'.startsWith('半截')),
        contentsOf(m).join('|'));
  }
  {
    // 长会话重生成：截断 + 对齐 + 删回复 三者叠加仍要合法
    final chat = dialog(20, opening: true); // 41 条，末条 assistant
    final cut = TavernContext.regenerateCutoff(chat);
    ck('场景前提：长会话截点应 ≥1', cut >= 1, '$cut');
    final m = TavernContext.build(
        system: 'S', turns: cut < 0 ? <TavernTurn>[] : chat.sublist(0, cut));
    ck('长会话重生成：仍不超过窗口', m.length <= 1 + TavernContext.defaultWindow);
    ck('长会话重生成：首条非 system 是 user', m.length > 1 && m[1]['role'] == 'user');
    ck('长会话重生成：末条是 user（问题20）', m.last['content'] == '问题20');
    ck('长会话重生成：至少剩一轮', m.length >= 2);
  }

  // ── 7. 输出契约 ─────────────────────────────────────────────────────
  {
    final m = TavernContext.build(system: 'S', turns: dialog(2, opening: true));
    final allTwoKeys = m.every((e) => e.length == 2 && e.containsKey('role') && e.containsKey('content'));
    ck('每条 message 只有 role/content 两个键', allTwoKeys);
    final roles = rolesOf(m).toSet();
    ck('role 只出现 system/user/assistant',
        roles.difference({'system', 'user', 'assistant'}).isEmpty, roles.join(','));
  }

  print('\n== 结果：$pass 通过 / $fail 失败 ==');
  if (fail > 0) {
    print('失败项：');
    for (final f in fails) {
      print('  · $f');
    }
    exit(1);
  }
}
