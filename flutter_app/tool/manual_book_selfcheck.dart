// 内置《使用说明书》自检 —— 纯 Dart，零 Flutter 依赖，可本地/CI 直接跑。
//
// 用户需求(2026-10-01)：「出场自带的说明书内容一点都不详细，白写了」。
// 所以这道闸门不只查"有没有"，更查"够不够详细"：
//   · 章节数与标题/正文一一对应（防加标题忘写正文）
//   · 每章正文有最低字数（防"白写了"复发 —— 空话半句也算一章）
//   · 关键操作词必须出现（用户在说明书里找得到的，才叫说明书）
//   · 不含 emoji（STYLE_GUIDE 明令禁止）
//   · 两端同步用的 hiddenKey 常量存在且值固定（改了会让"移除"记忆失效）
//
// 两端文本一致性（Dart vs 网页端 js）由 D:/ai/_compare_manual.mjs 负责 ——
// 网页端源码不在本仓，CI 里取不到，所以那一步不进 CI、改完说明书手动跑一次。

import '../lib/core/manual_book.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name${extra.isEmpty ? '' : '  -> $extra'}');
  }
}

void main() {
  print('=== 内置《使用说明书》自检 ===\n');

  final titles = ManualBook.chapters();
  final texts = <String>[for (var i = 0; i < titles.length; i++) ManualBook.textOf('$i')];

  // ── 1. 结构 ──
  ck('章节数 ≥ 14（本轮扩写目标）', titles.length >= 14, '实际 ${titles.length}');
  ck('每章都有标题', titles.every((c) => (c['name'] as String).trim().isNotEmpty));
  ck('每章 url 与下标一致',
      [for (var i = 0; i < titles.length; i++) titles[i]['url'] == '$i'].every((e) => e == true));
  ck('索引越界回落首章（不抛异常）', ManualBook.textOf('999') == texts[0]);
  ck('非数字 url 回落首章', ManualBook.textOf('abc') == texts[0]);

  // ── 2. 详细度（这是本轮的核心诉求，必须量化）──
  final lens = [for (final t in texts) t.length];
  final minLen = lens.reduce((a, b) => a < b ? a : b);
  final total = lens.fold<int>(0, (a, b) => a + b);
  ck('每章正文 ≥ 150 字（防"白写了"）', minLen >= 150, '最短 ${minLen} 字');
  ck('全书 ≥ 4000 字（8 章时代约 2500 字）', total >= 4000, '实际 $total 字');
  print('     全书共 $total 字，最短章 $minLen 字，最长章 ${lens.reduce((a, b) => a > b ? a : b)} 字');

  // 章节标题要"一眼看出讲什么"，不是"其他""杂项"这种
  final vague = titles.where((c) {
    final n = (c['name'] as String).trim();
    return n.length < 4;
  }).toList();
  ck('没有过于笼统的标题（长度 ≥ 4）', vague.isEmpty,
      vague.map((e) => e['name']).join(','));

  // ── 3. 关键操作必须写进说明书 ──
  // 用户最常问的几件事，说明书里必须有明确落点，否则用户问的问题它答不了。
  final all = texts.join('\n');
  const mustHave = <String, String>{
    '模块菜单入口': '⋯',
    '回收站（删除可恢复）': '回收站',
    'API 密钥库（跨模块复用）': '密钥库',
    '计费方式（套餐 vs 按量）': '计费方式',
    '搜索引擎慢的解释': '扫描',
    '家庭后端': '家庭后端',
    '本地导入': '本地导入',
    '引擎地址手填': '192.168',
  };
  for (final e in mustHave.entries) {
    ck('说明书提到「${e.key}」（${e.value}）', all.contains(e.value),
        all.contains(e.value) ? '' : '正文里找不到 "${e.value}"');
  }

  // 新增的三项（本轮实际改动）必须在说明书里有交代
  ck('说明书交代了封面兜底（首字占位）', all.contains('首字'));
  ck('说明书交代了说明书本身可移除', all.contains('移出') || all.contains('移除'));

  // ── 4. 风格规范 ──
  // STYLE_GUIDE：禁 emoji。说明书是最常被读的文本，尤其不能破例。
  // 不用 RegExp 的 `\u{...}` 范围 —— Dart 对多段增补平面范围会报
  // "Range out of order"，改用码点遍历，稳且直观。
  bool hasEmoji(String s) {
    for (final r in s.runes) {
      if (r >= 0x1F000 && r <= 0x1FAFF) return true; // 表情 / 补充符号
      if (r >= 0x2600 && r <= 0x27BF) return true; // 杂项符号与装饰符
      if (r == 0xFE0F || r == 0x200D) return true; // 变体选择符 / 零宽连接符
    }
    return false;
  }

  ck('正文不含 emoji', !hasEmoji(all));
  ck('正文不含全角空格占位（排版垃圾）', !all.contains('\u3000'));

  // ── 5. 存储键契约 ──
  ck('hiddenKey 值固定为 manual_hidden', ManualBook.hiddenKey == 'manual_hidden');
  ck('sourceId 固定为 manual', ManualBook.sourceId == 'manual');
  ck('bookUrl 固定为 manual://guide', ManualBook.bookUrl == 'manual://guide');

  print('\nPASS $pass   FAIL $fail');
  if (fail > 0) throw StateError('说明书自检未通过');
}
