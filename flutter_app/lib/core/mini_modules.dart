// 小模块做实第一批: 计算器 / 文本工具箱 / 二维码 / 待办 / 笔记 / 记账 / 剪贴板
// 全部纯本地实现(SharedPreferences 持久化), 不依赖后端与云端
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'calc_engine.dart';

// ── 通用本地存储 ──
class _Store {
  static Future<List<Map<String, dynamic>>> list(String key) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(String key, List<Map<String, dynamic>> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(items));
  }
}

// ═══ 计算器：标准 / 科学 / 换算 / 汇率 / 金额大写 ═══
//
// 求值、单位换算、汇率、金额大写的规则全部住在 calc_engine.dart（纯 Dart 规则层，
// tool/calc_engine_selfcheck.dart 把语义钉死）。这里只做界面与输入输出。
// ★ 不许在界面里再长出解析器/换算表/大写逻辑 —— 自检第 8 节专抓"改一半"。
class CalcPage extends StatefulWidget {
  const CalcPage({super.key});
  @override
  State<CalcPage> createState() => _Calc();
}

class _Calc extends State<CalcPage> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 5, vsync: this);

  String expr = '', result = '';
  bool isErr = false;
  bool degrees = true;
  double lastAns = 0;
  List<String> history = [];

  int convCat = 0;
  int convFrom = 2, convTo = 3; // 默认「米 → 千米」这种最常见的用法
  final convInput = TextEditingController(text: '1');

  // 汇率：内置表兜底，联网刷新是整表替换（不许半新半旧混着来）
  final rateInput = TextEditingController(text: '100');
  String rateFrom = 'CNY', rateTo = 'USD';
  Map<String, double> rates =
      Map<String, double>.of(CurrencyRates.builtinPerCNY);
  String ratesStamp = '内置 ${CurrencyRates.builtinStamp}';
  bool ratesLoading = false;

  final amtInput = TextEditingController();
  String amtOut = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    convInput.dispose();
    rateInput.dispose();
    amtInput.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() => history = p.getStringList('calc_history') ?? []);
  }

  void _tap(String k) => setState(() {
        switch (k) {
          case 'C':
            expr = '';
            result = '';
            isErr = false;
          case '⌫':
            if (expr.isNotEmpty) expr = expr.substring(0, expr.length - 1);
          case 'DEG':
            degrees = true;
          case 'RAD':
            degrees = false;
          case '=':
            if (expr.isEmpty) break;
            try {
              final v = CalcEngine.eval(expr, degrees: degrees, ans: lastAns);
              result = CalcFmt.fmt(v);
              lastAns = v;
              isErr = false;
              history.insert(0, '$expr = $result');
              if (history.length > 50) history = history.sublist(0, 50);
              SharedPreferences.getInstance()
                  .then((p) => p.setStringList('calc_history', history));
            } catch (e) {
              result = '$e';
              isErr = true;
            }
          default:
            expr += k;
        }
      });

  /// 实时预览：边输边算，省掉"按了等号才发现括号没配平"。
  String get _preview {
    if (expr.isEmpty) return '';
    final v = CalcEngine.preview(expr, degrees: degrees, ans: lastAns);
    if (v == null) return '';
    final s = CalcFmt.fmt(v);
    return s == result ? '' : s;
  }

  static const _stdKeys = [
    ['C', '(', ')', '÷'],
    ['7', '8', '9', '×'],
    ['4', '5', '6', '-'],
    ['1', '2', '3', '+'],
    ['0', '.', '⌫', '='],
  ];

  static const _sciKeys = [
    ['DEG', 'RAD', 'sin', 'cos', 'tan'],
    ['C', '(', ')', '%', '⌫'],
    ['ln', 'log', '√', '^', '÷'],
    ['7', '8', '9', 'π', '×'],
    ['4', '5', '6', 'e', '-'],
    ['1', '2', '3', 'ans', '+'],
    ['0', '.', '!', '', '='],
  ];

  Widget _calcView(bool sci) {
    final scheme = Theme.of(context).colorScheme;
    final keys = sci ? _sciKeys : _stdKeys;
    final pv = _preview;
    return Column(children: [
      Expanded(
          child: GestureDetector(
              onLongPress: () {
                if (result.isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: result));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('结果已复制')));
                }
              },
              child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  alignment: Alignment.bottomRight,
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (history.isNotEmpty)
                          Expanded(
                              child: ListView(reverse: true, children: [
                            for (final h in history)
                              Align(
                                  alignment: Alignment.centerRight,
                                  child: InkWell(
                                      onTap: () => setState(() {
                                            expr = h.split(' = ').first;
                                            result = '';
                                          }),
                                      child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 2),
                                          child: Text(h,
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey))))),
                          ])),
                        SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            reverse: true,
                            child: Text(expr.isEmpty ? '0' : expr,
                                style: const TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w300))),
                        if (pv.isNotEmpty)
                          Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text('= $pv',
                                  style: TextStyle(
                                      fontSize: 16,
                                      color: scheme.primary
                                          .withValues(alpha: .55)))),
                        const SizedBox(height: 6),
                        Text(result,
                            style: TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.w600,
                                color:
                                    isErr ? Colors.redAccent : scheme.primary)),
                      ])))),
      for (final row in keys)
        Row(children: [
          for (final k in row)
            Expanded(
                child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: k.isEmpty
                        ? const SizedBox(height: 52)
                        : SizedBox(
                            height: 52,
                            child: FilledButton(
                                style: FilledButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    backgroundColor: k == '='
                                        ? scheme.primary
                                        : (k == 'DEG' || k == 'RAD')
                                            ? (degrees == (k == 'DEG')
                                                ? scheme.primaryContainer
                                                : scheme.surfaceContainerLow)
                                            : RegExp(r'^[0-9.]$').hasMatch(k)
                                                ? scheme.surfaceContainerLow
                                                : scheme
                                                    .surfaceContainerHighest,
                                    foregroundColor: k == '='
                                        ? scheme.onPrimary
                                        : (k == 'DEG' || k == 'RAD')
                                            ? scheme.onPrimaryContainer
                                            : RegExp(r'^[0-9.]$').hasMatch(k)
                                                ? scheme.onSurface
                                                : scheme.primary,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12))),
                                onPressed: () => _tap(k),
                                child: Text(k,
                                    style: TextStyle(
                                        fontSize: k.length > 2 ? 12 : 19)))))),
        ]),
      const SizedBox(height: 6),
    ]);
  }

  Widget _convView() {
    final cats = [...CalcUnits.cats.keys, '温度'];
    final cat = cats[convCat];
    final units = cat == '温度'
        ? CalcUnits.tempUnits
        : CalcUnits.cats[cat]!.map((e) => e.name).toList();
    final a = convFrom.clamp(0, units.length - 1);
    final b = convTo.clamp(0, units.length - 1);
    double? out;
    final raw = double.tryParse(convInput.text.trim());
    if (raw != null) {
      out = cat == '温度'
          ? CalcUnits.cToTemp(CalcUnits.tempToC(raw, a), b)
          : CalcUnits.convert(cat, a, b, raw);
    }
    return ListView(padding: const EdgeInsets.all(14), children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (var i = 0; i < cats.length; i++)
          ChoiceChip(
              label: Text(cats[i], style: const TextStyle(fontSize: 12)),
              selected: convCat == i,
              onSelected: (_) => setState(() {
                    convCat = i;
                    convFrom = 0;
                    convTo = 1;
                  })),
      ]),
      const SizedBox(height: 14),
      TextField(
          controller: convInput,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w300),
          decoration: const InputDecoration(
              labelText: '数值', isDense: true, border: OutlineInputBorder()),
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: DropdownButtonFormField<int>(
                initialValue: a,
                isDense: true,
                decoration: const InputDecoration(
                    labelText: '从',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (var i = 0; i < units.length; i++)
                    DropdownMenuItem(
                        value: i,
                        child: Text(units[i],
                            style: const TextStyle(fontSize: 13)))
                ],
                onChanged: (v) => setState(() => convFrom = v ?? 0))),
        IconButton(
            onPressed: () => setState(() {
                  final t = convFrom;
                  convFrom = convTo;
                  convTo = t;
                }),
            tooltip: '互换',
            icon: const Icon(Icons.swap_horiz)),
        Expanded(
            child: DropdownButtonFormField<int>(
                initialValue: b,
                isDense: true,
                decoration: const InputDecoration(
                    labelText: '到',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (var i = 0; i < units.length; i++)
                    DropdownMenuItem(
                        value: i,
                        child: Text(units[i],
                            style: const TextStyle(fontSize: 13)))
                ],
                onChanged: (v) => setState(() => convTo = v ?? 0))),
      ]),
      const SizedBox(height: 20),
      Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Theme.of(context).cardTheme.color,
              borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('结果',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 6),
            SelectableText(out == null ? '—' : CalcFmt.fmt(out),
                style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary)),
            if (out != null)
              Text(
                  '${CalcFmt.fmt(raw!)} ${units[a]} = ${CalcFmt.fmt(out)} ${units[b]}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ])),
    ]);
  }

  Future<void> _refreshRates() async {
    setState(() => ratesLoading = true);
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6);
      final req = await client
          .getUrl(Uri.parse('https://open.er-api.com/v6/latest/CNY'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      final parsed = CurrencyRates.tryParseRates(body);
      if (parsed == null || !parsed.containsKey('CNY')) throw '返回数据不合用';
      if (!mounted) return;
      setState(() {
        rates = parsed;
        ratesStamp = '联网 ${DateTime.now().toString().substring(0, 16)}';
        ratesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => ratesLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('汇率刷新失败（$e），继续用内置表')));
    }
  }

  Widget _rateView() {
    final codes = rates.keys.toList();
    if (!codes.contains(rateFrom)) rateFrom = 'CNY';
    if (!codes.contains(rateTo) || rateTo == rateFrom) {
      rateTo = codes.firstWhere((c) => c != rateFrom, orElse: () => rateFrom);
    }
    double? out;
    String? err;
    final raw = double.tryParse(rateInput.text.trim());
    if (raw == null) {
      if (rateInput.text.trim().isNotEmpty) err = '数值不对';
    } else {
      try {
        out = CurrencyRates.convert(raw, rateFrom, rateTo, rates);
      } catch (e) {
        err = '$e';
      }
    }
    String label(String code) {
      final n = CurrencyRates.names[code];
      return n == null ? code : '$n $code';
    }

    return ListView(padding: const EdgeInsets.all(14), children: [
      const Text('汇率换算',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text('基准 1 元人民币。$ratesStamp，可点下方按钮联网刷新。',
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: 12),
      TextField(
          controller: rateInput,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w300),
          decoration: const InputDecoration(
              labelText: '金额', isDense: true, border: OutlineInputBorder()),
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: DropdownButtonFormField<String>(
                initialValue: rateFrom,
                isDense: true,
                decoration: const InputDecoration(
                    labelText: '从',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (final c in codes)
                    DropdownMenuItem(
                        value: c,
                        child: Text(label(c),
                            style: const TextStyle(fontSize: 13)))
                ],
                onChanged: (v) => setState(() => rateFrom = v ?? 'CNY'))),
        IconButton(
            onPressed: () => setState(() {
                  final t = rateFrom;
                  rateFrom = rateTo;
                  rateTo = t;
                }),
            tooltip: '互换',
            icon: const Icon(Icons.swap_horiz)),
        Expanded(
            child: DropdownButtonFormField<String>(
                initialValue: rateTo,
                isDense: true,
                decoration: const InputDecoration(
                    labelText: '到',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (final c in codes)
                    DropdownMenuItem(
                        value: c,
                        child: Text(label(c),
                            style: const TextStyle(fontSize: 13)))
                ],
                onChanged: (v) => setState(() => rateTo = v ?? 'CNY'))),
      ]),
      const SizedBox(height: 20),
      Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Theme.of(context).cardTheme.color,
              borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(err ?? '结果',
                style: TextStyle(
                    fontSize: 12,
                    color: err == null ? Colors.grey : Colors.redAccent)),
            const SizedBox(height: 6),
            SelectableText(out == null ? '—' : CalcFmt.fmt(out),
                style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary)),
            if (out != null)
              Text(
                  '${CalcFmt.fmt(raw!)} ${label(rateFrom)} = ${CalcFmt.fmt(out)} ${label(rateTo)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ])),
      const SizedBox(height: 12),
      OutlinedButton.icon(
          icon: ratesLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh, size: 18),
          label: Text(ratesLoading ? '刷新中…' : '联网刷新汇率'),
          onPressed: ratesLoading ? null : _refreshRates),
    ]);
  }

  Widget _amtView() => ListView(padding: const EdgeInsets.all(14), children: [
        const Text('数字 → 人民币大写',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('报销、开票、写收据时用。支持到万亿位，角分按财务惯例处理。',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 12),
        TextField(
            controller: amtInput,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w300),
            decoration: const InputDecoration(
                labelText: '金额（元）',
                hintText: '如 12345.67',
                isDense: true,
                border: OutlineInputBorder()),
            onChanged: (v) => setState(() {
                  final d = double.tryParse(v.trim());
                  amtOut = d == null ? '' : RmbUpper.upper(d);
                })),
        const SizedBox(height: 16),
        if (amtOut.isNotEmpty) ...[
          Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius: BorderRadius.circular(12)),
              child: SelectableText(amtOut,
                  style: const TextStyle(
                      fontSize: 20, height: 1.6, fontWeight: FontWeight.w500))),
          const SizedBox(height: 10),
          OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('复制大写'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: amtOut));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已复制')));
              }),
        ],
        const SizedBox(height: 24),
        const Text('常用示例', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in [
            '100',
            '1000.5',
            '10005',
            '100000000',
            '0.5',
            '12345.67'
          ])
            ActionChip(
                label: Text(s, style: const TextStyle(fontSize: 12)),
                onPressed: () => setState(() {
                      amtInput.text = s;
                      amtOut = RmbUpper.upper(double.parse(s));
                    })),
        ]),
      ]);

  @override
  Widget build(BuildContext c) => Column(children: [
        TabBar(
            controller: _tab,
            labelStyle: const TextStyle(fontSize: 13),
            tabs: const [
              Tab(text: '标准'),
              Tab(text: '科学'),
              Tab(text: '换算'),
              Tab(text: '汇率'),
              Tab(text: '金额'),
            ]),
        Expanded(
            child: TabBarView(controller: _tab, children: [
          _calcView(false),
          _calcView(true),
          _convView(),
          _rateView(),
          _amtView(),
        ])),
      ]);
}

// ═══ 文本工具箱: JSON / Base64 / URL / 时间戳 / 字数统计 ═══
class TextToolsPage extends StatefulWidget {
  const TextToolsPage({super.key});
  @override
  State<TextToolsPage> createState() => _Tt();
}

class _Tt extends State<TextToolsPage> {
  static const tools = [
    'JSON 格式化',
    'Base64 编码',
    'Base64 解码',
    'URL 编码',
    'URL 解码',
    '时间戳 → 时间',
    '时间 → 时间戳',
    '字数统计'
  ];
  String tool = tools.first;
  final input = TextEditingController();
  String output = '';

  void _run() => setState(() {
        final s = input.text;
        try {
          switch (tool) {
            case 'JSON 格式化':
              output =
                  const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
            case 'Base64 编码':
              output = base64Encode(utf8.encode(s));
            case 'Base64 解码':
              output = utf8.decode(base64Decode(s.trim()));
            case 'URL 编码':
              output = Uri.encodeComponent(s);
            case 'URL 解码':
              output = Uri.decodeComponent(s);
            case '时间戳 → 时间':
              var t = int.parse(s.trim());
              if (t < 1e12.toInt()) t *= 1000;
              output = DateTime.fromMillisecondsSinceEpoch(t)
                  .toLocal()
                  .toString()
                  .substring(0, 19);
            case '时间 → 时间戳':
              output =
                  '${DateTime.parse(s.trim().replaceAll('/', '-')).millisecondsSinceEpoch}';
            case '字数统计':
              final chars = s.length;
              final cn = RegExp(r'[一-鿿]').allMatches(s).length;
              final words = RegExp(r'[a-zA-Z]+').allMatches(s).length;
              final lines = s.isEmpty ? 0 : s.split('\n').length;
              output =
                  '总字符: $chars\n中文字: $cn\n英文单词: $words\n行数: $lines\n字节数(UTF-8): ${utf8.encode(s).length}';
          }
        } catch (e) {
          output = '处理失败: $e';
        }
      });

  @override
  Widget build(BuildContext c) =>
      ListView(padding: const EdgeInsets.all(12), children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in tools)
            ChoiceChip(
                label: Text(t, style: const TextStyle(fontSize: 12)),
                selected: tool == t,
                onSelected: (_) => setState(() {
                      tool = t;
                      output = '';
                    })),
        ]),
        const SizedBox(height: 10),
        TextField(
            controller: input,
            maxLines: 7,
            decoration: InputDecoration(
                hintText: tool == '时间戳 → 时间'
                    ? '输入秒或毫秒时间戳'
                    : tool == '时间 → 时间戳'
                        ? '如 2026-09-17 12:00:00'
                        : '在此输入文本…',
                border: const OutlineInputBorder(),
                isDense: true)),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('处理'),
              onPressed: _run),
          const SizedBox(width: 8),
          TextButton.icon(
              icon: const Icon(Icons.paste, size: 18),
              label: const Text('粘贴'),
              onPressed: () async {
                final d = await Clipboard.getData('text/plain');
                if (d?.text != null) input.text = d!.text!;
              }),
          const Spacer(),
          if (output.isNotEmpty)
            TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制结果'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: output));
                  ScaffoldMessenger.of(c)
                      .showSnackBar(const SnackBar(content: Text('已复制')));
                }),
        ]),
        if (output.isNotEmpty)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(output,
                      style: const TextStyle(
                          fontSize: 13, fontFamily: 'monospace')))),
      ]);
}

// ═══ 二维码: 生成 + 保存PNG + 历史 ═══
class QrPage extends StatefulWidget {
  const QrPage({super.key});
  @override
  State<QrPage> createState() => _Qr();
}

class _Qr extends State<QrPage> {
  final input = TextEditingController();
  String data = '';
  List<String> history = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() => history = p.getStringList('qr_history') ?? []);
  }

  void _gen() {
    final s = input.text.trim();
    if (s.isEmpty) return;
    setState(() {
      data = s;
      history.remove(s);
      history.insert(0, s);
      if (history.length > 30) history = history.sublist(0, 30);
    });
    SharedPreferences.getInstance()
        .then((p) => p.setStringList('qr_history', history));
  }

  Future<void> _savePng() async {
    try {
      final painter =
          QrPainter(data: data, version: QrVersions.auto, gapless: true);
      final img = await painter.toImage(600);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      final ext = await getExternalStorageDirectory();
      final dir = Directory('${ext!.path}/qrcodes');
      if (!await dir.exists()) await dir.create(recursive: true);
      final f =
          File('${dir.path}/qr-${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes);
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已保存: ${f.path}')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败: $e')));
    }
  }

  @override
  Widget build(BuildContext c) =>
      ListView(padding: const EdgeInsets.all(14), children: [
        TextField(
            controller: input,
            maxLines: 3,
            decoration: const InputDecoration(
                hintText: '输入文本 / 链接 / WiFi(WIFI:T:WPA;S:名称;P:密码;;)…',
                border: OutlineInputBorder(),
                isDense: true)),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton.icon(
              icon: const Icon(Icons.qr_code, size: 18),
              label: const Text('生成二维码'),
              onPressed: _gen),
          const SizedBox(width: 8),
          if (data.isNotEmpty)
            TextButton.icon(
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('保存 PNG'),
                onPressed: _savePng),
        ]),
        if (data.isNotEmpty)
          Center(
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Card(
                      color: Colors.white,
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: QrImageView(data: data, size: 220))))),
        if (history.isNotEmpty) ...[
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('生成历史(点按重现)',
                  style: TextStyle(fontSize: 12, color: Colors.grey))),
          Card(
              child: Column(children: [
            for (final h in history)
              ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 18),
                  title: Text(h,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                  onTap: () {
                    input.text = h;
                    _gen();
                  }),
          ])),
        ],
      ]);
}

// ═══ 待办: 增删勾选 · 分组 · 本地持久化 ═══
class TodoPage extends StatefulWidget {
  const TodoPage({super.key});
  @override
  State<TodoPage> createState() => _Todo();
}

class _Todo extends State<TodoPage> {
  List<Map<String, dynamic>> items = [];
  final input = TextEditingController();
  String group = '默认';
  static const groups = ['默认', '工作', '生活', '购物'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await _Store.list('todos');
    if (!mounted) return;
    setState(() => items = v);
  }

  Future<void> _save() async {
    await _Store.save('todos', items);
    setState(() {});
  }

  @override
  Widget build(BuildContext c) {
    final undone = items.where((e) => e['done'] != true).toList();
    final done = items.where((e) => e['done'] == true).toList();
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: input,
                    decoration: const InputDecoration(
                        hintText: '添加待办…',
                        isDense: true,
                        border: OutlineInputBorder()),
                    onSubmitted: (_) => _add())),
            const SizedBox(width: 6),
            DropdownButton<String>(
                value: group,
                items: [
                  for (final g in groups)
                    DropdownMenuItem(
                        value: g,
                        child: Text(g, style: const TextStyle(fontSize: 13)))
                ],
                onChanged: (v) => setState(() => group = v ?? '默认')),
            IconButton.filled(
                icon: const Icon(Icons.add, size: 20), onPressed: _add),
          ])),
      Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text('还没有待办\n输入内容回车即可添加',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)))
              : ListView(children: [
                  for (final e in undone) _tile(e),
                  if (done.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
                        child: Text('已完成 ${done.length}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey))),
                  for (final e in done) _tile(e),
                ])),
    ]);
  }

  void _add() {
    final t = input.text.trim();
    if (t.isEmpty) return;
    items.insert(0, {
      'title': t,
      'done': false,
      'group': group,
      'ts': DateTime.now().millisecondsSinceEpoch
    });
    input.clear();
    _save();
  }

  Widget _tile(Map<String, dynamic> e) {
    final isDone = e['done'] == true;
    return Dismissible(
        key: ValueKey('${e['ts']}_${e['title']}'),
        direction: DismissDirection.endToStart,
        background: Container(
            color: Colors.redAccent,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: const Icon(Icons.delete, color: Colors.white)),
        onDismissed: (_) {
          items.remove(e);
          _save();
        },
        child: ListTile(
            dense: true,
            leading: Checkbox(
                value: isDone,
                onChanged: (v) {
                  e['done'] = v == true;
                  _save();
                }),
            title: Text(e['title'] ?? '',
                style: TextStyle(
                    fontSize: 14,
                    decoration: isDone ? TextDecoration.lineThrough : null,
                    color: isDone ? Colors.grey : null)),
            subtitle: Text('${e['group'] ?? '默认'}',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
            onTap: () {
              e['done'] = !isDone;
              _save();
            }));
  }
}

// ═══ 笔记: Markdown 笔记列表 + 编辑/预览 + 搜索 ═══
class NotesPage extends StatefulWidget {
  const NotesPage({super.key});
  @override
  State<NotesPage> createState() => _Notes();
}

class _Notes extends State<NotesPage> {
  List<Map<String, dynamic>> notes = [];
  String query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await _Store.list('notes');
    if (!mounted) return;
    setState(() => notes = v);
  }

  @override
  Widget build(BuildContext c) {
    final shown = query.isEmpty
        ? notes
        : notes
            .where((n) => '${n['title']}${n['content']}'
                .toLowerCase()
                .contains(query.toLowerCase()))
            .toList();
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            Expanded(
                child: TextField(
                    decoration: const InputDecoration(
                        hintText: '搜索笔记…',
                        isDense: true,
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search, size: 18)),
                    onChanged: (v) => setState(() => query = v))),
            const SizedBox(width: 6),
            IconButton.filled(
                icon: const Icon(Icons.add, size: 20),
                tooltip: '新建笔记',
                onPressed: () => Navigator.push(c,
                        MaterialPageRoute(builder: (_) => const NoteEditPage()))
                    .then((_) => _load())),
          ])),
      Expanded(
          child: notes.isEmpty
              ? const Center(
                  child: Text('还没有笔记\n点右上角 + 新建',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)))
              : ListView(children: [
                  for (final n in shown)
                    ListTile(
                        title: Text(
                            (n['title'] ?? '').toString().isEmpty
                                ? '无标题'
                                : n['title'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '${(n['content'] ?? '').toString().replaceAll('\n', ' ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                        trailing: Text(_fmtTs(n['ts'] ?? 0),
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey)),
                        onTap: () => Navigator.push(
                                c,
                                MaterialPageRoute(
                                    builder: (_) => NoteEditPage(note: n)))
                            .then((_) => _load()),
                        onLongPress: () async {
                          final ok = await showDialog<bool>(
                              context: c,
                              builder: (c2) => AlertDialog(
                                      title: const Text('删除笔记'),
                                      content:
                                          Text('删除「${n['title'] ?? '无标题'}」?'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(c2, false),
                                            child: const Text('取消')),
                                        FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(c2, true),
                                            child: const Text('删除'))
                                      ]));
                          if (ok == true) {
                            notes.remove(n);
                            await _Store.save('notes', notes);
                            _load();
                          }
                        }),
                ])),
    ]);
  }

  static String _fmtTs(int ts) {
    if (ts == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}-${d.day}';
  }
}

// ── 笔记编辑页: 编辑/预览切换 ──
class NoteEditPage extends StatefulWidget {
  final Map<String, dynamic>? note;
  const NoteEditPage({super.key, this.note});
  @override
  State<NoteEditPage> createState() => _NoteEdit();
}

class _NoteEdit extends State<NoteEditPage> {
  late final TextEditingController title =
      TextEditingController(text: widget.note?['title'] ?? '');
  late final TextEditingController body =
      TextEditingController(text: widget.note?['content'] ?? '');
  bool preview = false;

  Future<void> _save() async {
    if (title.text.trim().isEmpty && body.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    final notes = await _Store.list('notes');
    if (widget.note != null) {
      notes.removeWhere((n) => n['ts'] == widget.note!['ts']);
    }
    notes.insert(0, {
      'title': title.text.trim(),
      'content': body.text,
      'ts': widget.note?['ts'] ?? DateTime.now().millisecondsSinceEpoch,
      'updated': DateTime.now().millisecondsSinceEpoch
    });
    await _Store.save('notes', notes);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar:
          AppBar(title: Text(widget.note == null ? '新建笔记' : '编辑笔记'), actions: [
        IconButton(
            icon: Icon(preview ? Icons.edit : Icons.visibility_outlined,
                size: 20),
            tooltip: preview ? '继续编辑' : '预览',
            onPressed: () => setState(() => preview = !preview)),
        IconButton(
            icon: const Icon(Icons.check, size: 20),
            tooltip: '保存',
            onPressed: _save),
      ]),
      body: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
                controller: title,
                decoration: const InputDecoration(
                    hintText: '标题', isDense: true, border: InputBorder.none),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700))),
        const Divider(height: 1),
        Expanded(
            child: preview
                ? ListView(
                    padding: const EdgeInsets.all(14),
                    children: [_mdPreview(body.text)])
                : TextField(
                    controller: body,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                        hintText: '支持 Markdown: # 标题 **加粗** - 列表…',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(14)))),
      ]));

  // 轻量 Markdown 渲染: 标题/加粗/列表/引用/代码行
  static Widget _mdPreview(String src) {
    final lines = src.split('\n');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final ln in lines) _mdLine(ln),
    ]);
  }

  static Widget _mdLine(String ln) {
    Widget styled(String t, TextStyle s) {
      // **bold** 处理
      final spans = <TextSpan>[];
      var rest = t;
      while (rest.contains('**')) {
        final i = rest.indexOf('**');
        final j = rest.indexOf('**', i + 2);
        if (j < 0) break;
        if (i > 0) spans.add(TextSpan(text: rest.substring(0, i)));
        spans.add(TextSpan(
            text: rest.substring(i + 2, j),
            style: const TextStyle(fontWeight: FontWeight.w700)));
        rest = rest.substring(j + 2);
      }
      spans.add(TextSpan(text: rest));
      return Text.rich(TextSpan(children: spans), style: s);
    }

    if (ln.startsWith('### '))
      return styled(
          ln.substring(4),
          const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, height: 1.8));
    if (ln.startsWith('## '))
      return styled(
          ln.substring(3),
          const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w700, height: 1.9));
    if (ln.startsWith('# '))
      return styled(
          ln.substring(2),
          const TextStyle(
              fontSize: 20, fontWeight: FontWeight.w800, height: 2.0));
    if (ln.startsWith('- ') || ln.startsWith('* '))
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('  • ', style: TextStyle(height: 1.6)),
        Expanded(
            child: styled(
                ln.substring(2), const TextStyle(fontSize: 14, height: 1.6)))
      ]);
    if (ln.startsWith('> '))
      return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.only(left: 8),
          decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: Colors.grey, width: 3))),
          child: styled(ln.substring(2),
              const TextStyle(fontSize: 14, height: 1.6, color: Colors.grey)));
    if (ln.startsWith('`') && ln.endsWith('`') && ln.length > 2)
      return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4)),
          child: Text(ln.substring(1, ln.length - 1),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13)));
    return styled(ln, const TextStyle(fontSize: 14, height: 1.6));
  }
}

// ═══ 记账: 快速记一笔 · 分类 · 月度统计 ═══
class LedgerPage extends StatefulWidget {
  const LedgerPage({super.key});
  @override
  State<LedgerPage> createState() => _Ledger();
}

class _Ledger extends State<LedgerPage> {
  List<Map<String, dynamic>> entries = [];
  static const cats = [
    '餐饮',
    '交通',
    '购物',
    '娱乐',
    '居家',
    '医疗',
    '学习',
    '工资',
    '其他收入',
    '其他'
  ];
  static const incomeCats = {'工资', '其他收入'};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await _Store.list('ledger');
    if (!mounted) return;
    setState(() => entries = v);
  }

  Future<void> _add() async {
    final amtC = TextEditingController();
    final noteC = TextEditingController();
    var cat = '餐饮';
    final ok = await showDialog<bool>(
        context: context,
        builder: (c2) => StatefulBuilder(
            builder: (c2, setD) => AlertDialog(
                    title: const Text('记一笔'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: amtC,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: '金额(元)',
                              isDense: true,
                              prefixText: '¥ ')),
                      const SizedBox(height: 8),
                      Wrap(spacing: 4, runSpacing: 4, children: [
                        for (final g in cats)
                          ChoiceChip(
                              label:
                                  Text(g, style: const TextStyle(fontSize: 11)),
                              selected: cat == g,
                              onSelected: (_) => setD(() => cat = g)),
                      ]),
                      TextField(
                          controller: noteC,
                          decoration: const InputDecoration(
                              labelText: '备注(可空)', isDense: true)),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c2, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(c2, true),
                          child: const Text('保存'))
                    ])));
    if (ok != true) return;
    final amt = double.tryParse(amtC.text.trim());
    if (amt == null || amt <= 0) return;
    entries.insert(0, {
      'amount': amt,
      'cat': cat,
      'note': noteC.text.trim(),
      'income': incomeCats.contains(cat),
      'ts': DateTime.now().millisecondsSinceEpoch
    });
    await _Store.save('ledger', entries);
    _load();
  }

  @override
  Widget build(BuildContext c) {
    final now = DateTime.now();
    final month = entries.where((e) {
      final d = DateTime.fromMillisecondsSinceEpoch(e['ts'] ?? 0);
      return d.year == now.year && d.month == now.month;
    }).toList();
    var inc = 0.0, exp = 0.0;
    for (final e in month) {
      if (e['income'] == true)
        inc += (e['amount'] as num);
      else
        exp += (e['amount'] as num);
    }
    return Column(children: [
      Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _sum('本月支出', exp, Colors.orange),
                    _sum('本月收入', inc, Colors.green),
                    _sum('结余', inc - exp,
                        inc - exp >= 0 ? Colors.green : Colors.redAccent),
                    IconButton.filled(
                        icon: const Icon(Icons.add, size: 20),
                        tooltip: '记一笔',
                        onPressed: _add),
                  ]))),
      Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text('还没有账目\n点上方 + 记一笔',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)))
              : ListView(children: [
                  for (final e in entries)
                    Dismissible(
                        key: ValueKey('${e['ts']}_${e['amount']}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                            color: Colors.redAccent,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            child:
                                const Icon(Icons.delete, color: Colors.white)),
                        onDismissed: (_) {
                          entries.remove(e);
                          _Store.save('ledger', entries).then((_) => _load());
                        },
                        child: ListTile(
                            dense: true,
                            leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: (e['income'] == true
                                        ? Colors.green
                                        : Colors.orange)
                                    .withValues(alpha: 0.12),
                                child: Icon(e['income'] == true ? Icons.south_west : Icons.north_east,
                                    size: 14,
                                    color: e['income'] == true
                                        ? Colors.green
                                        : Colors.orange)),
                            title: Text('${e['cat']}${(e['note'] ?? '').toString().isEmpty ? '' : ' · ${e['note']}'}',
                                style: const TextStyle(fontSize: 13)),
                            subtitle: Text(
                                DateTime.fromMillisecondsSinceEpoch(e['ts'] ?? 0)
                                    .toString()
                                    .substring(0, 16),
                                style: const TextStyle(fontSize: 10, color: Colors.grey)),
                            trailing: Text('${e['income'] == true ? '+' : '-'}¥${(e['amount'] as num).toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: e['income'] == true ? Colors.green : null)))),
                ])),
    ]);
  }

  Widget _sum(String label, double v, Color color) => Column(children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text('¥${v.toStringAsFixed(2)}',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w800, color: color)),
      ]);
}

// ═══ 剪贴板: 手动收藏当前剪贴板 + 历史 + 置顶 ═══
class ClipboardPage extends StatefulWidget {
  const ClipboardPage({super.key});
  @override
  State<ClipboardPage> createState() => _Clip();
}

class _Clip extends State<ClipboardPage> {
  List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await _Store.list('clipboard_history');
    if (!mounted) return;
    setState(() => items = v);
  }

  Future<void> _grab() async {
    final d = await Clipboard.getData('text/plain');
    final t = d?.text ?? '';
    if (t.isEmpty) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前剪贴板为空(或系统限制读取)')));
      return;
    }
    items.removeWhere((e) => e['text'] == t);
    items.insert(0,
        {'text': t, 'ts': DateTime.now().millisecondsSinceEpoch, 'pin': false});
    if (items.length > 100) items = items.sublist(0, 100);
    await _Store.save('clipboard_history', items);
    _load();
  }

  @override
  Widget build(BuildContext c) => Column(children: [
        Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                  child: FilledButton.icon(
                      icon: const Icon(Icons.content_paste_go, size: 18),
                      label: const Text('收藏当前剪贴板'),
                      onPressed: _grab)),
              const SizedBox(width: 8),
              Text('共 ${items.length} 条',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ])),
        Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text('还没有记录\n复制内容后点上方按钮收藏',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)))
                : ListView(children: [
                    for (final e in items)
                      Dismissible(
                          key: ValueKey('${e['ts']}_${e['text']}'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                              color: Colors.redAccent,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 16),
                              child: const Icon(Icons.delete,
                                  color: Colors.white)),
                          onDismissed: (_) {
                            items.remove(e);
                            _Store.save('clipboard_history', items)
                                .then((_) => _load());
                          },
                          child: ListTile(
                              dense: true,
                              leading: IconButton(
                                  icon: Icon(
                                      e['pin'] == true
                                          ? Icons.push_pin
                                          : Icons.push_pin_outlined,
                                      size: 18,
                                      color: e['pin'] == true
                                          ? Theme.of(c).colorScheme.primary
                                          : Colors.grey),
                                  onPressed: () {
                                    e['pin'] = e['pin'] != true;
                                    items.remove(e);
                                    if (e['pin'] == true) {
                                      items.insert(0, e);
                                    } else {
                                      items.add(e);
                                    }
                                    _Store.save('clipboard_history', items)
                                        .then((_) => _load());
                                  }),
                              title: Text(e['text'] ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(
                                  DateTime.fromMillisecondsSinceEpoch(
                                          e['ts'] ?? 0)
                                      .toString()
                                      .substring(0, 16),
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.grey)),
                              trailing: const Icon(Icons.copy,
                                  size: 16, color: Colors.grey),
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: e['text'] ?? ''));
                                ScaffoldMessenger.of(c).showSnackBar(
                                    const SnackBar(content: Text('已复制回剪贴板')));
                              })),
                  ])),
      ]);
}
