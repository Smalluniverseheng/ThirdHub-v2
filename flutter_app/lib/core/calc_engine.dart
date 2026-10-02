// 计算器规则层 —— 纯 Dart，零 Flutter 依赖，自检可直接 import。
//
// 职责：表达式求值（含科学函数与百分比语义）/ 数字格式化 / 单位换算 / 汇率换算 / 金额大写。
// UI 只做输入与展示，一律调这里 —— 规则错了必须在 tool/calc_engine_selfcheck.dart 里被拦住，
// 而不是等用户按出来才发现。
//
// ★ 百分比语义（与顶级计算器一致，不是"% 一律 ÷100"）：
//   500 + 10%  = 550    （加/减右侧的 % 是"左边那个数的百分之几"）
//   500 - 10%  = 450
//   200 × 50%  = 100    （乘/除右侧的 % 就是普通百分数）
//   50%        = 0.5    （单独出现 = 普通百分数）
//   10% + 500  = 500.1  （左侧的 % 永远是普通百分数）
//   括号内强制求值：(10%) 视为 0.1
//   连续加减按左结合、每次取"当前左侧值"为基数：500+10%+20% = 660
import 'dart:convert';
import 'dart:math' as math;

class _Pv {
  final double v;
  final bool pct; // true = 这是一个"百分数记号"（v 是除 100 之前的量）
  const _Pv(this.v, this.pct);
  double get plain => pct ? v / 100 : v;
}

class CalcEngine {
  CalcEngine._();

  /// 求值。[raw] 是界面原文（含 ×÷π√ans 也认），语法错抛中文描述。
  static double eval(String raw, {bool degrees = true, double ans = 0}) {
    final s = _norm(raw);
    if (s.trim().isEmpty) throw '表达式为空';
    return _Parser(s, degrees: degrees, ans: ans).parse();
  }

  /// 边输边算用：出错回 null，不抛。
  static double? preview(String raw, {bool degrees = true, double ans = 0}) {
    try {
      return eval(raw, degrees: degrees, ans: ans);
    } catch (_) {
      return null;
    }
  }

  /// 界面字符 → 解析器认的形式。
  /// （曾兼容 U+2715 ✕ 变体，因其落在 ui_icons 扫描的装饰符号区已删——
  ///   界面键盘只产生 U+00D7 ×，不值得为粘贴变体破 STYLE_GUIDE 第 1 条。）
  static String _norm(String s) => s
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll('−', '-')
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('，', '')
      .replaceAll(',', '')
      .replaceAll('％', '%')
      .replaceAll('π', 'pi')
      .replaceAll('√', 'sqrt')
      .replaceAll('∛', 'cbrt');
}

class _Parser {
  final String s;
  final bool degrees;
  final double ans;
  int i = 0;
  _Parser(this.s, {this.degrees = true, this.ans = 0});

  double parse() {
    final v = _expr();
    _ws();
    if (i != s.length) throw '表达式有误';
    return v.plain; // 顶层收尾：光秃秃的 50% = 0.5
  }

  void _ws() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
  }

  _Pv _expr() {
    var left = _term();
    while (true) {
      _ws();
      if (i < s.length && (s[i] == '+' || s[i] == '-')) {
        final op = s[i++];
        final right = _term();
        final lv = left.plain; // 左侧的 % 永远是普通百分数
        final rv = right.pct ? lv * right.v / 100 : right.plain;
        left = _Pv(op == '+' ? lv + rv : lv - rv, false);
      } else {
        break;
      }
    }
    return left;
  }

  _Pv _term() {
    var left = _unary();
    while (true) {
      _ws();
      if (i < s.length && (s[i] == '*' || s[i] == '/')) {
        final op = s[i++];
        final right = _unary();
        final lv = left.plain;
        final rv = right.plain; // 乘/除右侧的 % 就是普通百分数
        if (op == '/') {
          if (rv == 0) throw '除数为 0';
          left = _Pv(lv / rv, false);
        } else {
          left = _Pv(lv * rv, false);
        }
      } else {
        break;
      }
    }
    return left;
  }

  _Pv _unary() {
    _ws();
    if (i < s.length && s[i] == '-') {
      i++;
      final x = _unary();
      return _Pv(-x.v, x.pct);
    }
    if (i < s.length && s[i] == '+') {
      i++;
      return _unary();
    }
    var base = _power();
    // 后缀：%（标百分数）与 !（阶乘，先把 % 收成普通数）
    while (true) {
      _ws();
      if (i < s.length && s[i] == '%') {
        i++;
        base = _Pv(base.pct ? base.v / 100 : base.v, true);
      } else if (i < s.length && s[i] == '!') {
        i++;
        base = _Pv(_fact(base.plain), false);
      } else {
        break;
      }
    }
    return base;
  }

  _Pv _power() {
    final base = _atom();
    _ws();
    if (i < s.length && s[i] == '^') {
      i++;
      final e = _unary();
      return _Pv(math.pow(base.plain, e.plain).toDouble(), false);
    }
    return base;
  }

  _Pv _atom() {
    _ws();
    if (i < s.length && s[i] == '(') {
      i++;
      final v = _expr();
      _ws();
      if (i >= s.length || s[i] != ')') throw '括号不配对';
      i++;
      return _Pv(v.plain, false); // 括号强制求值：(10%) = 0.1
    }
    // 函数名 / 常量名
    final m = RegExp(r'[a-zA-Z]+').matchAsPrefix(s, i);
    if (m != null) {
      final name = m.group(0)!.toLowerCase();
      i = m.end;
      if (name == 'pi') return _Pv(math.pi, false);
      if (name == 'e') return _Pv(math.e, false);
      if (name == 'ans') return _Pv(ans, false);
      final argPv = _atom(); // 函数取一个"原子"作参数，sin(30) 与 sin30 都能吃
      final arg = argPv.plain;
      final double a = degrees && _isTrig(name) ? arg * math.pi / 180 : arg;
      switch (name) {
        case 'sin':
          return _Pv(math.sin(a), false);
        case 'cos':
          return _Pv(math.cos(a), false);
        case 'tan':
          return _Pv(math.tan(a), false);
        case 'asin':
          if (arg < -1 || arg > 1) throw 'asin 只在 -1~1 有定义';
          final r = math.asin(arg);
          return _Pv(degrees ? r * 180 / math.pi : r, false);
        case 'acos':
          if (arg < -1 || arg > 1) throw 'acos 只在 -1~1 有定义';
          final r = math.acos(arg);
          return _Pv(degrees ? r * 180 / math.pi : r, false);
        case 'atan':
          final r = math.atan(arg);
          return _Pv(degrees ? r * 180 / math.pi : r, false);
        case 'ln':
          if (arg <= 0) throw 'ln 只对正数有定义';
          return _Pv(math.log(arg), false);
        case 'log':
          if (arg <= 0) throw 'log 只对正数有定义';
          return _Pv(math.log(arg) / math.ln10, false);
        case 'sqrt':
          if (arg < 0) throw '负数不能开平方';
          return _Pv(math.sqrt(arg), false);
        case 'cbrt':
          return _Pv(_cbrt(arg), false);
        case 'abs':
          return _Pv(arg.abs(), false);
        case 'exp':
          return _Pv(math.exp(arg), false);
        case 'floor':
          return _Pv(arg.floorToDouble(), false);
        case 'ceil':
          return _Pv(arg.ceilToDouble(), false);
        case 'round':
          return _Pv(arg.roundToDouble(), false);
      }
      throw '未知函数 $name';
    }
    // 数字（含 1e3 这种科学计数法）
    final n = RegExp(r'\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?')
        .matchAsPrefix(s, i);
    if (n == null) throw '表达式有误';
    i = n.end;
    return _Pv(double.parse(n.group(0)!), false);
  }

  bool _isTrig(String n) => n == 'sin' || n == 'cos' || n == 'tan';

  double _cbrt(double v) =>
      v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

  double _fact(double v) {
    if (v < 0 || v != v.roundToDouble() || v > 170) throw '阶乘只支持 0~170 的整数';
    var r = 1.0;
    for (var k = 2; k <= v.round(); k++) {
      r *= k;
    }
    return r;
  }
}

/// 数字 → 展示文本。整数不带小数点；循环小数保留 10 位有效数字后去尾零。
class CalcFmt {
  CalcFmt._();

  static String fmt(double v) {
    if (v.isNaN || v.isInfinite) return '错误';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
    return v
        .toStringAsPrecision(10)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }
}

/// 单位换算。`factor` = 该单位相对基准单位的倍率（温度不用它，单列）。
class CalcUnit {
  final String name;
  final double factor;
  const CalcUnit(this.name, this.factor);
}

class CalcUnits {
  CalcUnits._();

  static const Map<String, List<CalcUnit>> cats = {
    '长度': [
      CalcUnit('毫米', .001),
      CalcUnit('厘米', .01),
      CalcUnit('米', 1),
      CalcUnit('千米', 1000),
      CalcUnit('英寸', .0254),
      CalcUnit('英尺', .3048),
      CalcUnit('码', .9144),
      CalcUnit('英里', 1609.344),
      CalcUnit('市里', 500),
      CalcUnit('市尺', 1 / 3),
      CalcUnit('市寸', 1 / 30),
    ],
    '面积': [
      CalcUnit('平方厘米', .0001),
      CalcUnit('平方米', 1),
      CalcUnit('平方千米', 1000000),
      CalcUnit('公顷', 10000),
      CalcUnit('亩', 2000 / 3),
      CalcUnit('平方英尺', .09290304),
    ],
    '体积': [
      CalcUnit('毫升', .001),
      CalcUnit('升', 1),
      CalcUnit('立方米', 1000),
      CalcUnit('美制加仑', 3.785411784),
      CalcUnit('英制加仑', 4.54609),
    ],
    '重量': [
      CalcUnit('毫克', 1e-6),
      CalcUnit('克', .001),
      CalcUnit('千克', 1),
      CalcUnit('吨', 1000),
      CalcUnit('市斤', .5),
      CalcUnit('市两', .05),
      CalcUnit('磅', .45359237),
      CalcUnit('盎司', .028349523125),
    ],
    '速度': [
      CalcUnit('米/秒', 1),
      CalcUnit('千米/时', 1 / 3.6),
      CalcUnit('英里/时', .44704),
      CalcUnit('节', 1852 / 3600),
      CalcUnit('马赫', 340.3),
    ],
    '存储': [
      CalcUnit('字节', 1),
      CalcUnit('KB', 1024),
      CalcUnit('MB', 1024 * 1024),
      CalcUnit('GB', 1024 * 1024 * 1024),
      CalcUnit('TB', 1024 * 1024 * 1024 * 1024),
    ],
    '时间': [
      CalcUnit('毫秒', .001),
      CalcUnit('秒', 1),
      CalcUnit('分', 60),
      CalcUnit('时', 3600),
      CalcUnit('天', 86400),
      CalcUnit('周', 604800),
    ],
  };

  /// 温度：非线性，单列一类自己算。基准是摄氏度。
  static const List<String> tempUnits = ['摄氏度 °C', '华氏度 °F', '开尔文 K'];

  static double tempToC(double v, int from) {
    switch (from) {
      case 1:
        return (v - 32) * 5 / 9;
      case 2:
        return v - 273.15;
    }
    return v;
  }

  static double cToTemp(double c, int to) {
    switch (to) {
      case 1:
        return c * 9 / 5 + 32;
      case 2:
        return c + 273.15;
    }
    return c;
  }

  /// 非温度换算（[cat] 必须在 [cats] 里）。from/to 是该类单位表里的下标。
  static double convert(String cat, int from, int to, double v) {
    final list = cats[cat];
    if (list == null) throw '没有 $cat 这个换算类';
    if (from < 0 || from >= list.length || to < 0 || to >= list.length)
      throw '单位下标越界';
    return v * list[from].factor / list[to].factor;
  }
}

/// 汇率换算。基准币是人民币（CNY）—— 表里是"1 元人民币兑多少该币"。
///
/// 内置表是 2026-10-02 的真实参考值（exchangerate-api 当日数据），不是编的；
/// 汇率天天变，界面提供"联网更新"，拉不到就继续用内置表（并如实标注日期）。
class CurrencyRates {
  CurrencyRates._();

  static const String base = 'CNY';
  static const String builtinStamp = '2026-10-02';

  /// 1 CNY 兑多少该币。
  static const Map<String, double> builtinPerCNY = {
    'CNY': 1,
    'USD': 0.148931,
    'EUR': 0.132209,
    'JPY': 23.502685,
    'GBP': 0.112763,
    'HKD': 1.168522,
    'TWD': 4.750594,
    'KRW': 201.694232,
    'AUD': 0.21487,
    'CAD': 0.211737,
    'CHF': 0.123841,
    'SGD': 0.190474,
    'THB': 5.002802,
    'RUB': 12.5,
    'MYR': 0.606686,
    'IDR': 2680.965147,
    'NZD': 0.266343,
    'INR': 14.311065,
    'SAR': 0.558488,
    'AED': 0.546946,
    'TRY': 7.28863,
    'BRL': 0.775855,
    'MXN': 2.682403,
    'ZAR': 2.46504,
    'SEK': 1.495619,
    'NOK': 1.431836,
    'DKK': 0.986078,
    'PLN': 0.572574,
    'VND': 3875.968992,
    'PHP': 9.328358,
  };

  static const Map<String, String> names = {
    'CNY': '人民币',
    'USD': '美元',
    'EUR': '欧元',
    'JPY': '日元',
    'GBP': '英镑',
    'HKD': '港币',
    'TWD': '新台币',
    'KRW': '韩元',
    'AUD': '澳元',
    'CAD': '加元',
    'CHF': '瑞士法郎',
    'SGD': '新加坡元',
    'THB': '泰铢',
    'RUB': '卢布',
    'MYR': '林吉特',
    'IDR': '印尼盾',
    'NZD': '新西兰元',
    'INR': '卢比',
    'SAR': '沙特里亚尔',
    'AED': '迪拉姆',
    'TRY': '里拉',
    'BRL': '雷亚尔',
    'MXN': '比索',
    'ZAR': '兰特',
    'SEK': '瑞典克朗',
    'NOK': '挪威克朗',
    'DKK': '丹麦克朗',
    'PLN': '兹罗提',
    'VND': '越南盾',
    'PHP': '比索',
  };

  /// [rates] = "1 CNY 兑多少该币"的表（内置或联网拉的）。
  static double convert(
      double amount, String from, String to, Map<String, double> rates) {
    final f = rates[from], t = rates[to];
    if (f == null) throw '缺 $from 的汇率';
    if (t == null) throw '缺 $to 的汇率';
    if (f == 0) throw '$from 汇率为 0，无法换算';
    return amount / f * t;
  }

  /// 解析 open.er-api.com 的响应（{"base_code":"CNY","rates":{...}}）。
  /// 形状不对回 null —— 调用方继续用内置表，不许半新半旧混着来。
  static Map<String, double>? tryParseRates(String body) {
    try {
      final m = jsonDecode(body);
      if (m is! Map) return null;
      final r = m['rates'];
      if (r is! Map) return null;
      final out = <String, double>{};
      r.forEach((k, v) {
        final d = (v is num) ? v.toDouble() : double.tryParse('$v');
        if (d != null && d > 0) out[k.toString()] = d;
      });
      return out.length >= 5 ? out : null;
    } catch (_) {
      return null;
    }
  }
}

/// 金额大写。规则按财务惯例：零元也要写「零元……」，
/// 角分为 0 写「整」，中间空节补「零」（如 10005 → 壹万零伍）。
class RmbUpper {
  RmbUpper._();

  static String upper(double v) {
    if (v.isNaN || v.isInfinite) return '数值无效';
    const d = '零壹贰叁肆伍陆柒捌玖';
    const u = ['', '拾', '佰', '仟'];
    const g = ['', '万', '亿', '万亿'];
    final neg = v < 0;
    final n = v.abs();
    if (n >= 1e16) return '超出可表示范围';
    final intPart = n.floor();
    final cents = ((n - intPart) * 100).round();
    final segs = <int>[];
    var x = intPart;
    if (x == 0) {
      segs.add(0);
    } else {
      while (x > 0) {
        segs.add(x % 10000);
        x ~/= 10000;
      }
    }
    final sb = StringBuffer();
    if (intPart == 0) {
      sb.write('零');
    } else {
      for (var gi = segs.length - 1; gi >= 0; gi--) {
        final seg = segs[gi];
        if (seg == 0) {
          var later = false;
          for (var k = gi - 1; k >= 0; k--) {
            if (segs[k] != 0) {
              later = true;
              break;
            }
          }
          if (later && sb.isNotEmpty && !sb.toString().endsWith('零'))
            sb.write('零');
          continue;
        }
        if (seg < 1000 && sb.isNotEmpty && !sb.toString().endsWith('零'))
          sb.write('零');
        var s = seg;
        var unit = 0;
        var segStr = '';
        var pendingZero = false;
        while (s > 0) {
          final dig = s % 10;
          if (dig == 0) {
            if (segStr.isNotEmpty) pendingZero = true;
          } else {
            if (pendingZero) {
              segStr = '零$segStr';
              pendingZero = false;
            }
            segStr = '${d[dig]}${u[unit]}$segStr';
          }
          s ~/= 10;
          unit++;
        }
        sb.write(segStr);
        sb.write(g[gi]);
      }
    }
    // 不足一元省「元」：0.5 → 伍角、0.05 → 零伍分（银行大写惯例）；但 0 仍是「零元整」。
    var out = (intPart == 0 && cents > 0) ? '' : '${sb.toString()}元';
    if (cents == 0) {
      out += '整';
    } else {
      final jiao = cents ~/ 10, fen = cents % 10;
      if (jiao == 0) {
        out += '零${d[fen]}分';
      } else if (fen == 0) {
        out += '${d[jiao]}角';
      } else {
        out += '${d[jiao]}角${d[fen]}分';
      }
    }
    return neg ? '负$out' : out;
  }
}
