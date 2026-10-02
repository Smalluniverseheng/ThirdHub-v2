// 计算器规则层自检 —— 纯 Dart（dart --disable-dart-dev tool/calc_engine_selfcheck.dart）。
//
// 重点不是"能算 1+1"，而是三条容易一改就崩、崩了还悄无声息的：
//   ① 百分比语义（500+10%=550，不是 500.1）—— 退回"% 一律÷100"必须被拦；
//   ② 温度换算非线性（-40°C=-40°F 这种拐点）；
//   ③ UI 与规则层的接线（防"改一半"：UI 里不许再长出自己的解析器）。
import 'dart:io';
import 'dart:math' as math;

import '../lib/core/calc_engine.dart';

int pass = 0, fail = 0;

void ck(bool cond, String msg) {
  if (cond) {
    pass++;
    stdout.writeln('PASS  $msg');
  } else {
    fail++;
    stdout.writeln('FAIL  $msg');
  }
}

bool near(double a, double b, [double eps = 1e-9]) => (a - b).abs() <= eps;

bool throws(void Function() f, String mustContain) {
  try {
    f();
    return false;
  } catch (e) {
    return '$e'.contains(mustContain);
  }
}

void main() {
  stdout.writeln('=== 1. 表达式求值（优先级 / 括号 / 幂 / 阶乘 / 函数 / 常量） ===');
  ck(CalcEngine.eval('1+2×3') == 7, '乘优先于加：1+2×3 = 7');
  ck(CalcEngine.eval('(1+2)×3') == 9, '括号改变优先级：(1+2)×3 = 9');
  ck(CalcEngine.eval('2^10') == 1024, '幂：2^10 = 1024');
  ck(CalcEngine.eval('2^3^2') == 512, '幂右结合：2^3^2 = 512');
  ck(CalcEngine.eval('5!') == 120, '阶乘：5! = 120');
  ck(CalcEngine.eval('√9') == 3, '√ 翻成 sqrt：√9 = 3');
  ck(near(CalcEngine.eval('π'), math.pi), 'π 常量');
  ck(near(CalcEngine.eval('sin30'), 0.5), 'sin30 = 0.5（度制，可省括号）');
  ck(near(CalcEngine.eval('cos(60)'), 0.5), 'cos(60) = 0.5');
  ck(near(CalcEngine.eval('sin(π/2)', degrees: false), 1), '弧度制：sin(π/2) = 1');
  ck(near(CalcEngine.eval('asin(1)'), 90), 'asin(1) = 90°（度制回代）');
  ck(near(CalcEngine.eval('ln(e)'), 1), 'ln(e) = 1');
  ck(near(CalcEngine.eval('log(1000)'), 3), 'log(1000) = 3');
  ck(CalcEngine.eval('cbrt(27)') == 3, 'cbrt(27) = 3');
  ck(CalcEngine.eval('cbrt(-8)') == -2, 'cbrt 负数：cbrt(-8) = -2');
  ck(CalcEngine.eval('floor(2.7)') == 2, 'floor');
  ck(CalcEngine.eval('ceil(2.1)') == 3, 'ceil');
  ck(CalcEngine.eval('round(2.5)') == 3, 'round');
  ck(CalcEngine.eval('abs(-3.5)') == 3.5, 'abs');
  ck(CalcEngine.eval('1e3+1') == 1001, '科学计数法：1e3+1 = 1001');
  ck(CalcEngine.eval('ans+1', ans: 41) == 42, 'ans 取上一次结果');
  ck(CalcEngine.eval('1,234+1') == 1235, '千分位逗号被清掉');
  ck(CalcEngine.eval('10÷4') == 2.5, '除号 ÷ 认得');
  ck(CalcEngine.eval('-2^2') == -4,
      '负号不吞幂：-2^2 = -4（数学/Google/Excel 惯例：-(2^2)）');

  stdout.writeln('\n=== 2. 百分比语义（★退回「一律÷100」必须被拦） ===');
  ck(CalcEngine.eval('500+10%') == 550, '★500+10% = 550（加减右侧是"左边的百分之几"）');
  ck(CalcEngine.eval('500-10%') == 450, '★500-10% = 450');
  ck(CalcEngine.eval('200×50%') == 100, '200×50% = 100（乘除右侧是普通百分数）');
  ck(CalcEngine.eval('200÷50%') == 400, '200÷50% = 400');
  ck(CalcEngine.eval('50%') == 0.5, '单独 50% = 0.5');
  ck(near(CalcEngine.eval('10%+500'), 500.1), '左侧的 % 是普通百分数：10%+500 = 500.1');
  ck(CalcEngine.eval('500+10%+20%') == 660, '左结合逐次取基数：500+10%+20% = 660');
  ck(near(CalcEngine.eval('500+(10%)'), 500.1), '括号强制求值：500+(10%) = 500.1');
  ck(near(CalcEngine.eval('50%%'), 0.005), '连续 % 再÷100：50%% = 0.005');
  ck(near(CalcEngine.eval('500+500×10%'), 550), '混合式：500+500×10% = 550');
  // 反证：naive 实现（% 一律÷100）会给出 500.1 —— 与上面的 550 不同，
  // 说明上面那条断言真能分辨两种语义，不是摆设。
  final naive50010 = 500 + 10 / 100;
  ck(naive50010 != CalcEngine.eval('500+10%'),
      '反证：naive(500+10%)=$naive50010 与真值不同 → 断言真能分辨语义');

  stdout.writeln('\n=== 3. 错误路径（错就是错，不许算出个数糊弄） ===');
  ck(throws(() => CalcEngine.eval('1÷0'), '除数为 0'), '除数为 0 要报');
  ck(throws(() => CalcEngine.eval('(1+2'), '括号不配对'), '括号不配对要报');
  ck(throws(() => CalcEngine.eval('foo(1)'), '未知函数'), '未知函数要报');
  ck(throws(() => CalcEngine.eval(''), '表达式为空'), '空表达式要报');
  ck(throws(() => CalcEngine.eval('ln(0)'), '正数'), 'ln(0) 要报');
  ck(throws(() => CalcEngine.eval('(-1)!'), '阶乘'), '负数阶乘要报');
  ck(throws(() => CalcEngine.eval('2++'), '表达式有误'), '残缺表达式要报');
  ck(CalcEngine.preview('1+') == null, 'preview 出错回 null 不抛');

  stdout.writeln('\n=== 4. 数字格式化 ===');
  ck(CalcFmt.fmt(2) == '2', '整数不带小数点');
  ck(CalcFmt.fmt(2.0) == '2', '2.0 → 2');
  ck(CalcFmt.fmt(1 / 3) == '0.3333333333', '1/3 保留 10 位有效数字');
  ck(CalcFmt.fmt(0.5) == '0.5', '0.5 不被尾零裁坏');
  ck(CalcFmt.fmt(double.nan) == '错误', 'NaN 显示"错误"');
  ck(CalcFmt.fmt(double.infinity) == '错误', 'Inf 显示"错误"');

  stdout.writeln('\n=== 5. 单位换算（含温度非线性） ===');
  ck(CalcUnits.convert('长度', 3, 2, 1) == 1000, '1 千米 = 1000 米');
  ck(near(CalcUnits.convert('长度', 4, 1, 1), 2.54), '1 英寸 = 2.54 厘米');
  ck(near(CalcUnits.convert('重量', 6, 2, 1), 0.45359237), '1 磅 = 0.45359237 千克');
  ck(CalcUnits.convert('存储', 3, 2, 1) == 1024, '1 GB = 1024 MB');
  ck(near(CalcUnits.cToTemp(CalcUnits.tempToC(32, 1), 1), 32), '32°F 往返回 32°F');
  ck(near(CalcUnits.cToTemp(0, 1), 32), '0°C = 32°F');
  ck(near(CalcUnits.cToTemp(100, 1), 212), '100°C = 212°F');
  ck(near(CalcUnits.cToTemp(-40, 1), -40), '★-40°C = -40°F（非线性拐点）');
  ck(near(CalcUnits.tempToC(0, 2), -273.15), '0K = -273.15°C');
  ck(near(CalcUnits.convert('速度', 1, 0, 3.6), 1), '3.6 千米/时 = 1 米/秒');
  ck(throws(() => CalcUnits.convert('不存在', 0, 1, 1), '没有'), '未知换算类要报');
  ck(throws(() => CalcUnits.convert('长度', 99, 0, 1), '越界'), '单位下标越界要报');

  stdout.writeln('\n=== 6. 汇率换算（内置真实表 + 联网解析） ===');
  ck(CurrencyRates.builtinPerCNY['CNY'] == 1, '基准币 CNY = 1');
  ck(CurrencyRates.builtinPerCNY.length >= 25, '内置币种不少于 25 个');
  ck(
      near(CurrencyRates.convert(1, 'CNY', 'CNY', CurrencyRates.builtinPerCNY),
          1),
      '同币往返 = 1');
  final usd =
      CurrencyRates.convert(100, 'CNY', 'USD', CurrencyRates.builtinPerCNY);
  ck(near(usd, 14.8931, 1e-6), '100 元 ≈ 14.89 美元（2026-10-02 真实表）');
  final back =
      CurrencyRates.convert(usd, 'USD', 'CNY', CurrencyRates.builtinPerCNY);
  ck(near(back, 100, 1e-6), 'CNY→USD→CNY 往返回到 100');
  ck(
      throws(
          () => CurrencyRates.convert(
              1, 'CNY', 'ZZZ', CurrencyRates.builtinPerCNY),
          '缺'),
      '缺币种要报');
  final parsed = CurrencyRates.tryParseRates(
      '{"base_code":"CNY","rates":{"CNY":1,"USD":0.15,"EUR":0.13,"JPY":23,"GBP":0.11}}');
  ck(parsed != null && parsed['USD'] == 0.15, '真实 API 形状能解析');
  ck(CurrencyRates.tryParseRates('不是 JSON') == null, '坏 JSON 回 null');
  ck(CurrencyRates.tryParseRates('{"rates":{"USD":1}}') == null,
      '币种太少（不足 5 个）回 null，不许半新半旧混着来');
  ck(CurrencyRates.names['USD'] == '美元', '币种中文名齐');

  stdout.writeln('\n=== 7. 金额大写 ===');
  ck(RmbUpper.upper(0) == '零元整', '0 → 零元整');
  ck(RmbUpper.upper(10005).contains('壹万零伍'), '10005 → 壹万零伍（空节补零）');
  ck(RmbUpper.upper(123.45) == '壹佰贰拾叁元肆角伍分', '123.45 → 壹佰贰拾叁元肆角伍分');
  ck(RmbUpper.upper(0.5) == '伍角', '0.5 → 伍角');
  ck(RmbUpper.upper(0.05) == '零伍分', '0.05 → 零伍分');
  ck(RmbUpper.upper(-1) == '负壹元整', '负数带"负"字');

  stdout.writeln('\n=== 8. 三层接线（防"改一半"：UI 不许再长出自己的解析器） ===');
  final scriptDir = File(Platform.script.toFilePath()).parent.path;
  final ui =
      File('$scriptDir/../lib/core/mini_modules.dart').readAsStringSync();
  ck(ui.contains("import 'calc_engine.dart'"),
      'mini_modules.dart 导入 calc_engine.dart');
  ck(ui.contains('CalcEngine.eval') || ui.contains('CalcEngine.preview'),
      '求值走 CalcEngine（不再自己算）');
  ck(!ui.contains('class _CalcParser'), 'UI 里没有残留的私有解析器');
  ck(ui.contains('CurrencyRates'), '汇率换算接进了界面');
  ck(ui.contains('CalcUnits.'), '单位换算走规则层');
  ck(ui.contains('RmbUpper.upper'), '金额大写走规则层');
  final engine =
      File('$scriptDir/../lib/core/calc_engine.dart').readAsStringSync();
  ck(!engine.contains('package:flutter'), '规则层零 Flutter 依赖');
  ck(!engine.contains('dart:ui'), '规则层零 dart:ui 依赖');

  stdout.writeln('\n=== 9. 反证（改坏规则层会被上面的断言抓住的证明） ===');
  // "500+10%=550" 那条就是变异测试的靶子：谁把百分比退回 naive，它立刻红。
  // 这里再补一条方向相反的断言，确认两头都钉死。
  ck(CalcEngine.eval('100+10%') == 110, '100+10% = 110（第二基数点）');
  ck(near(CalcEngine.eval('100+10%+10%'), 121),
      '100+10%+10% = 121（110 的 10% 是 11）');

  stdout.writeln('\n=== 计算器规则层自检：$pass 过 / $fail 挂 ===');
  stdout.writeln(fail == 0 ? 'OK' : 'NG');
  exit(fail == 0 ? 0 : 1);
}
