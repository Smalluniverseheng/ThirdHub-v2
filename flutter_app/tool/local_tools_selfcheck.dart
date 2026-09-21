// 本地能力工具箱自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/local_tools_selfcheck.dart
import '../lib/core/local_tools_logic.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) { pass++; } else { fail++; print('  FAIL  $name'); }
}
void eq(String name, Object? got, Object? want) =>
    ck('$name  (got=$got want=$want)', got == want);

void main() {
  // ── 1. 表达式计算 ──
  print('== 1. 表达式计算 ==');
  eq('1+2', LocalCalc.calc('1+2'), '3');
  eq('2*3+4', LocalCalc.calc('2*3+4'), '10');
  eq('2+3*4', LocalCalc.calc('2+3*4'), '14');
  eq('优先级 左结合 (10-2-3)', LocalCalc.calc('10-2-3'), '5');
  eq('括号 (1+2)*3', LocalCalc.calc('(1+2)*3'), '9');
  eq('嵌套括号 ((1+2)*(3-1))', LocalCalc.calc('((1+2)*(3-1))'), '6');
  eq('小数 1.5*2', LocalCalc.calc('1.5*2'), '3');
  eq('除 7/2', LocalCalc.calc('7/2'), '3.5');
  eq('一元负 -5+3', LocalCalc.calc('-5+3'), '-2');
  eq('双重负 --5', LocalCalc.calc('--5'), '5');
  eq('幂 2^10', LocalCalc.calc('2^10'), '1024');
  eq('幂右结合 2^3^2', LocalCalc.calc('2^3^2'), '512');
  eq('幂优先级 2*3^2', LocalCalc.calc('2*3^2'), '18');
  eq('百分比 350*20%', LocalCalc.calc('350*20%'), '70');
  eq('百分比 100+10%', LocalCalc.calc('100+10%'), '100.1'); // 后缀百分比按 0.1 算
  eq('科学计数 1e3', LocalCalc.calc('1e3'), '1000');
  eq('科学计数 1e-2*100', LocalCalc.calc('1e-2*100'), '1');
  eq('空格容忍 1 + 2', LocalCalc.calc('  1 + 2  '), '3');
  eq('除零 → null', LocalCalc.calc('1/0'), null);
  eq('空串 → null', LocalCalc.calc(''), null);
  eq('纯空白 → null', LocalCalc.calc('   '), null);
  eq('非法字符 → null', LocalCalc.calc('1+abc'), null);
  eq('多余右括号 → null', LocalCalc.calc('(1+2))'), null);
  eq('缺少右括号 → null', LocalCalc.calc('(1+2'), null);
  eq('只有运算符 → null', LocalCalc.calc('+'), null);
  eq('两个数字没运算符 → null', LocalCalc.calc('1 2'), null);
  ck('格式化去尾零', LocalCalc.fmt(1.5000) == '1.5');
  ck('格式化整数', LocalCalc.fmt(3.0) == '3');
  ck('大数不崩', LocalCalc.calc('99999999*99999999') != null);

  // ── 2. 文本统计 ──
  print('== 2. 文本统计 ==');
  {
    final e = TextStats.of('');
    eq('空串 chars', e['chars'], 0);
    eq('空串 lines（不是 1）', e['lines'], 0);
    final s = TextStats.of('你好世界\nhello world\n第二行');
    eq('chars', s['chars'], '你好世界\nhello world\n第二行'.length);
    eq('lines', s['lines'], 3);
    eq('nonEmptyLines', s['nonEmptyLines'], 3);
    eq('cjk 计数', s['cjk'], 4 + 3);
    eq('latin 计数', s['latin'], 10);
    final s2 = TextStats.of('a\n\n\n b');
    eq('空行也算行', s2['lines'], 4);
    eq('nonEmptyLines 排除空行', s2['nonEmptyLines'], 2);
  }
  {
    final t = TextStats.topWords('apple banana apple cherry apple banana', n: 3, gram: 0);
    ck('词频首位是 apple', t.isNotEmpty && t.first.key == 'apple' && t.first.value == 3);
    ck('词频次位是 banana', t.length > 1 && t[1].key == 'banana' && t[1].value == 2);
    final c = TextStats.topWords('人工智能改变世界人工智能', n: 5, gram: 2);
    ck('中文 2-gram 能出「人工」', c.any((e) => e.key == '人工'));
    ck('空文本词频为空', TextStats.topWords('', gram: 2).isEmpty);
  }
  {
    final ll = TextStats.longestLine('a\nbbbb\ncc');
    ck('最长行行号', ll != null && ll.$1 == 2);
    ck('最长行内容', ll != null && ll.$2 == 'bbbb');
    ck('空文本最长行为 null', TextStats.longestLine('') == null);
  }

  // ── 3. JSON ──
  print('== 3. JSON ==');
  ck('valid 正常', JsonTool.valid('{"a":1}'));
  ck('valid 数组', JsonTool.valid('[1,2]'));
  ck('invalid 正常拒绝', !JsonTool.valid('{a:1}'));
  ck('invalid 空串', !JsonTool.valid(''));
  ck('pretty 成功', (JsonTool.pretty('{"a":1}') ?? '').contains('"a"'));
  ck('pretty 失败 → null', JsonTool.pretty('nope') == null);
  eq('minify 压平', JsonTool.minify('{ "a" : 1 , "b" : [1,2] }'), '{"a":1,"b":[1,2]}');
  eq('at 嵌套', JsonTool.at('{"a":{"b":[10,20]}}', 'a.b.1'), 20);
  eq('at 缺失 → null', JsonTool.at('{"a":1}', 'x.y'), null);
  eq('at 越界 → null', JsonTool.at('[1]', '5'), null);
  eq('at 路径过深 → null', JsonTool.at('{"a":1}', 'a.b.c'), null);
  ck('keys 递归出路径', JsonTool.keys('{"a":{"b":1}}').contains('a.b'));
  ck('keys 空对象为空', JsonTool.keys('{}').isEmpty);

  // ── 4. 编解码 ──
  print('== 4. 编解码 ==');
  eq('b64 往返（中文）', Codec.b64d(Codec.b64e('你好, world!')), '你好, world!');
  eq('b64 往返（空串）', Codec.b64d(Codec.b64e('')), '');
  eq('b64 无 padding 也能解', Codec.b64d('aGk'), 'hi');
  eq('b64 URL-safe 也能解', Codec.b64d('5L2g5aW9'), '你好');
  eq('b64 非法 → null', Codec.b64d('!!!!'), null);
  eq('url 往返', Codec.urlD(Codec.urlE('a b&c=中')), 'a b&c=中');
  eq('url 非法转义 → null', Codec.urlD('%ZZ'), null);
  eq('hex 往返', Codec.hexD(Codec.hexE('TH')), 'TH');
  eq('hex 奇数长度 → null', Codec.hexD('abc'), null);
  eq('hex 非法字符 → null', Codec.hexD('zz'), null);

  // ── 5. 摘要（用 FNV 官方测试向量核） ──
  print('== 5. 摘要 ==');
  eq('fnv1a32 空串', Hashing.fnv1a32(''), '811c9dc5');
  eq('fnv1a32 "a"', Hashing.fnv1a32('a'), 'e40c292c');
  eq('fnv1a64 空串', Hashing.fnv1a64(''), 'cbf29ce484222325');
  eq('fnv1a64 "a"', Hashing.fnv1a64('a'), 'af63dc4c8601ec8c');
  ck('fnv1a32 不同输入不同值', Hashing.fnv1a32('x') != Hashing.fnv1a32('y'));
  ck('fnv1a64 长度固定 16', Hashing.fnv1a64('任意中文').length == 16);

  // ── 6. ID 生成（★回归：同毫秒连续调用不得撞车） ──
  print('== 6. ID 生成 ==');
  {
    IdGen.reset();
    final set = <String>{};
    for (var i = 0; i < 500; i++) { set.add(IdGen.next('note')); }
    eq('★同毫秒连发 500 个 id 全不重复', set.length, 500);
    IdGen.reset();
    ck('前缀生效', IdGen.next('todo').startsWith('todo-'));
    ck('自增序可见', IdGen.seq == 1);
    final a = IdGen.next('x');
    final b = IdGen.next('x');
    ck('连发两个不同', a != b);
  }

  // ── 7. 时间 ──
  print('== 7. 时间 ==');
  eq('ymd 补零', TimeTool.ymd(DateTime(2026, 1, 5)), '2026-01-05');
  eq('hms 补零', TimeTool.hms(DateTime(2026, 1, 5, 3, 4, 5)), '03:04:05');
  eq('dur 全 0', TimeTool.dur(0), '0 秒');
  eq('dur 负值当 0', TimeTool.dur(-100), '0 秒');
  eq('dur 秒', TimeTool.dur(45000), '45 秒');
  eq('dur 分秒', TimeTool.dur(63000), '1 分 3 秒');
  eq('dur 天级', TimeTool.dur(90061000), '1 天 1 小时 1 分 1 秒');
  eq('clock 分秒', TimeTool.clock(65), '01:05');
  eq('clock 小时', TimeTool.clock(3665), '1:01:05');
  eq('clock 负值', TimeTool.clock(-5), '00:00');
  {
    final base = DateTime(2026, 9, 21, 12, 0, 0);
    eq('rel 刚刚', TimeTool.rel(base, base.subtract(const Duration(seconds: 10))), '刚刚');
    eq('rel 分钟', TimeTool.rel(base, base.subtract(const Duration(minutes: 5))), '5 分钟前');
    eq('rel 小时', TimeTool.rel(base, base.subtract(const Duration(hours: 3))), '3 小时前');
    eq('rel 天', TimeTool.rel(base, base.subtract(const Duration(days: 4))), '4 天前');
    eq('rel 月', TimeTool.rel(base, base.subtract(const Duration(days: 65))), '2 个月前');
    eq('rel 未来', TimeTool.rel(base, base.add(const Duration(minutes: 9))), '9 分钟后');
  }
  ck('fromEpoch 秒', TimeTool.fromEpoch(0) == null);
  eq('fromEpoch 秒级识别', TimeTool.fromEpoch(1700000000)?.year, 2023);
  eq('fromEpoch 毫秒级识别', TimeTool.fromEpoch(1700000000000)?.year, 2023);

  // ── 8. 单位换算 ──
  print('== 8. 单位换算 ==');
  eq('1 km → m', UnitConv.convert('length', 'km', 'm', 1), 1000.0);
  eq('100 cm → m', UnitConv.convert('length', 'cm', 'm', 100), 1.0);
  eq('2 斤 → kg', UnitConv.convert('mass', '斤', 'kg', 2), 1.0);
  eq('1 GB → MB', UnitConv.convert('data', 'GB', 'MB', 1), 1024.0);
  eq('未知类别 → null', UnitConv.convert('nope', 'a', 'b', 1), null);
  eq('未知单位 → null', UnitConv.convert('length', 'zz', 'm', 1), null);
  ck('温度 C→F', (UnitConv.convert('temperature', 'C', 'F', 100)! - 212).abs() < 1e-9);
  ck('温度 F→C', (UnitConv.convert('temperature', 'F', 'C', 32)! - 0).abs() < 1e-9);
  ck('温度 K→C', (UnitConv.convert('temperature', 'K', 'C', 273.15)! - 0).abs() < 1e-9);
  eq('温度未知单位 → null', UnitConv.convert('temperature', 'X', 'C', 1), null);
  eq('humanBytes 小值', UnitConv.humanBytes(512), '512 B');
  eq('humanBytes KB', UnitConv.humanBytes(1536), '1.50 KB');
  eq('humanBytes 负值', UnitConv.humanBytes(-1), '0 B');

  // ── 9. 正则 ──
  print('== 9. 正则 ==');
  eq('提取邮箱个数', RegexTool.all(r'[\w.]+@[\w.]+', 'a@b.com 和 c@d.cn').length, 2);
  eq('指定分组', RegexTool.first(r'(\d+)-(\d+)', '2026-09', group: 2), '09');
  ck('test 命中', RegexTool.test(r'\d{4}', 'ab2026cd'));
  ck('test 未命中', !RegexTool.test(r'^\d+$', 'ab2026'));
  ck('大小写不敏感', RegexTool.test('abc', 'ABC', caseSensitive: false));
  eq('replace 全部', RegexTool.replace(r'\s+', 'a  b   c', ' '), 'a b c');
  eq('replace 首个', RegexTool.replace(r'\d', 'a1b2', 'X', all: false), 'aXb2');
  ck('非法正则 all → 空表', RegexTool.all('(', 'abc').isEmpty);
  ck('非法正则 test → false', !RegexTool.test('(', 'abc'));
  ck('非法正则 check 报错', RegexTool.check('(').$1 == false);
  ck('合法正则 check 通过', RegexTool.check(r'\d+').$1 == true);
  eq('limit 生效', RegexTool.all(r'\d', '1234567890', limit: 3).length, 3);

  // ── 10. 文本差异 ──
  print('== 10. 文本差异 ==');
  {
    final d = TextDiff.byLine('a\nb\nc', 'a\nx\nc');
    // LCS 回溯产出的行数 = 公共行 + 删除行 + 新增行 = 2 + 1 + 1 = 4
    eq('行数', d.length, 4);
    eq('首行 same', d[0].kind, 'same');
    eq('末行 same', d[3].kind, 'same');
    // 中间两条顺序由 LCS 回溯决定，用集合语义断言（List 的 == 是引用比较，不能直比）
    final mids = d.sublist(1, 3).map((e) => e.kind).toList()..sort();
    eq('中间一增一删', mids.join(','), 'add,del');
    final st = TextDiff.stat(d);
    eq('统计 add', st.$1, 1);
    eq('统计 del', st.$2, 1);
  }
  {
    final d = TextDiff.byLine('x', 'x');
    eq('完全相同 → 单行 same', d.length, 1);
    ck('相同文本 similarity=1', TextDiff.similarity('a\nb', 'a\nb') == 1.0);
  }
  {
    final d = TextDiff.byLine('', 'a\nb');
    eq('从空到两行 → 两条 add', d.where((e) => e.kind == 'add').length, 2);
    final d2 = TextDiff.byLine('a\nb', '');
    eq('从两行到空 → 两条 del', d2.where((e) => e.kind == 'del').length, 2);
  }
  ck('空对空 similarity=1', TextDiff.similarity('', '') == 1.0);
  ck('超长文本走退路不卡（>maxLines）',
      TextDiff.byLine(List.filled(TextDiff.maxLines + 5, 'a').join('\n'),
                      List.filled(TextDiff.maxLines + 5, 'b').join('\n')).isNotEmpty);
  ck('same() 直判', TextDiff.same('x', 'x') && !TextDiff.same('x', 'y'));

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ 全部通过');
}
