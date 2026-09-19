// ═══ 传感器与量具: 屏幕尺子 / 水平仪 / 指南针 / 取色器 ═══
// 水平仪 = 加速度计的重力分量; 指南针 = 磁力计 + 加速度计做倾斜补偿; 取色器为纯本地实现。
// (此前这四个里只有"屏幕尺子"是真的, 其余只是一段"将在下一批接入"的说明文字, 这里补齐。)
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ── 纯函数: 传感器数学抽出来, 便于单测(不依赖真机) ──

/// 加速度计 → (左右倾角, 前后倾角), 单位度。手机平放时两者都为 0。
(double, double) levelAngles(double ax, double ay, double az) =>
  (math.atan2(ax, az) * 180 / math.pi, math.atan2(-ay, az) * 180 / math.pi);

/// 磁力计 + 加速度计 → 倾斜补偿后的方位角(0..360, 0 = 北)。
double compassHeading({required double ax, required double ay, required double az,
                       required double mx, required double my, required double mz}) {
  final roll = math.atan2(ax, az);
  final pitch = math.atan2(-ay, math.sqrt(ax * ax + az * az));
  final xh = mx * math.cos(pitch) + mz * math.sin(pitch);
  final yh = mx * math.sin(roll) * math.sin(pitch) + my * math.cos(roll)
             - mz * math.sin(roll) * math.cos(pitch);
  var deg = math.atan2(-yh, xh) * 180 / math.pi;
  if (deg < 0) deg += 360;
  return deg;
}

/// 指数平滑角度(处理 0/360 跨界), a 越大跟得越紧。
double smoothAngle(double prev, double next, {double a = 0.18}) {
  var diff = next - prev;
  if (diff > 180) diff -= 360;
  if (diff < -180) diff += 360;
  final v = prev + diff * a;
  return v < 0 ? v + 360 : (v >= 360 ? v - 360 : v);
}

/// '#RRGGBB' → ARGB int; 非法输入返回 null(色卡数据被写坏时不至于崩)
int? parseHexColor(String hex) {
  final t = hex.replaceAll('#', '').trim();
  if (t.length != 6) return null;
  final v = int.tryParse(t, radix: 16);
  return v == null ? null : (0xFF000000 | v);
}

/// ARGB int → '#RRGGBB'
String hexOf(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class SensorPage extends StatefulWidget {
  const SensorPage({super.key});
  @override State<SensorPage> createState() => _Sen();
}

class _Sen extends State<SensorPage> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 4, vsync: this);
  @override void dispose() { _tab.dispose(); super.dispose(); }

  @override Widget build(BuildContext c) => Column(children: [
    TabBar(controller: _tab, isScrollable: true, tabAlignment: TabAlignment.start, tabs: const [
      Tab(text: '尺子'), Tab(text: '水平仪'), Tab(text: '指南针'), Tab(text: '取色器'),
    ]),
    Expanded(child: TabBarView(controller: _tab, children: const [
      _RulerTab(), _LevelTab(), _CompassTab(), _PickerTab(),
    ])),
  ]);
}

// ───────────────────────── 尺子 ─────────────────────────
class _RulerTab extends StatefulWidget {
  const _RulerTab();
  @override State<_RulerTab> createState() => _RulerTabState();
}
class _RulerTabState extends State<_RulerTab> {
  double scale = 1.0; bool _init = false;

  @override void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() { scale = p.getDouble('ruler_scale') ?? 1.0; _init = true; });
    });
  }

  Future<void> _save(double v) async =>
    (await SharedPreferences.getInstance()).setDouble('ruler_scale', v);

  @override Widget build(BuildContext c) {
    if (!_init) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.all(12), children: [
      const Text('屏幕尺子', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      _Ruler(pxPerCm: 38 * scale, onScale: (v) { setState(() => scale = v); _save(v); }),
      const Padding(padding: EdgeInsets.only(top: 10),
        child: Text('按标准屏幕密度估算。拿一张银行卡(标准宽 8.56cm)贴在屏幕上对比, 用滑块校准, 校准值会记住。',
          style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.6))),
    ]);
  }
}

class _Ruler extends StatelessWidget {
  final double pxPerCm; final ValueChanged<double> onScale;
  const _Ruler({required this.pxPerCm, required this.onScale});
  @override Widget build(BuildContext c) {
    final w = MediaQuery.of(c).size.width - 24;
    final cmCount = (w / pxPerCm).floor();
    return Column(children: [
      Container(height: 70, decoration: BoxDecoration(color: const Color(0xFFF5F0E0),
        borderRadius: BorderRadius.circular(8)),
        child: CustomPaint(size: Size(w, 70), painter: _RulerPainter(pxPerCm))),
      Row(children: [
        const Text('校准', style: TextStyle(fontSize: 10, color: Colors.grey)),
        Expanded(child: Slider(value: pxPerCm / 38, min: 0.8, max: 1.2, onChanged: onScale)),
        Text('x${(pxPerCm / 38).toStringAsFixed(2)}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ]),
      Text('约 $cmCount cm 宽', style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ]);
  }
}

class _RulerPainter extends CustomPainter {
  final double pxPerCm;
  _RulerPainter(this.pxPerCm);
  @override void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black87..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    var x = 0.0; var cm = 0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x, 24), paint);
      tp.text = TextSpan(text: '$cm', style: const TextStyle(fontSize: 9, color: Colors.black54));
      tp.layout(); tp.paint(canvas, Offset(x + 2, 26));
      for (var m = 1; m < 10; m++) {
        final mx = x + pxPerCm * m / 10;
        if (mx >= size.width) break;
        canvas.drawLine(Offset(mx, 0), Offset(mx, m == 5 ? 14 : 8), paint);
      }
      x += pxPerCm; cm++;
    }
  }
  @override bool shouldRepaint(_RulerPainter old) => old.pxPerCm != pxPerCm;
}

// ───────────────────────── 水平仪 ─────────────────────────
class _LevelTab extends StatefulWidget {
  const _LevelTab();
  @override State<_LevelTab> createState() => _LevelTabState();
}
class _LevelTabState extends State<_LevelTab> {
  StreamSubscription<AccelerometerEvent>? _sub;
  String? _err;
  double _roll = 0, _pitch = 0;       // 度: 左右 / 前后
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override void initState() {
    super.initState();
    try {
      _sub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
        // 一帧最多刷 20 次, 别让 60Hz 的传感器把 UI 打满
        final now = DateTime.now();
        if (now.difference(_last).inMilliseconds < 50) return;
        _last = now;
        final (roll, pitch) = levelAngles(e.x, e.y, e.z);
        if (mounted) setState(() { _roll = roll; _pitch = pitch; });
      }, onError: (Object e) { if (mounted) setState(() => _err = '$e'); });
    } catch (e) { _err = '$e'; }
  }

  @override void dispose() { _sub?.cancel(); super.dispose(); }

  @override Widget build(BuildContext c) {
    if (_err != null) return _Unsupported(name: '水平仪', err: _err!);
    final level = _roll.abs() < 1.0 && _pitch.abs() < 1.0;
    final accent = level ? Colors.green
      : ((_roll.abs() < 3 && _pitch.abs() < 3) ? Colors.orange : Theme.of(c).colorScheme.primary);
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(children: [
          SizedBox(width: 240, height: 240, child: CustomPaint(
            painter: _VialPainter(roll: _roll, pitch: _pitch, maxDeg: 30, accent: accent))),
          const SizedBox(height: 14),
          Text(level ? '已水平' : '未水平',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: accent)),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _angleChip('左右', _roll, accent),
            const SizedBox(width: 12),
            _angleChip('前后', _pitch, accent),
          ]),
        ]))),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: const [
        Text('怎么用', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        SizedBox(height: 6),
        Text('把手机平放在被测面上, 气泡进入中心小圈即水平。\n'
             '· 左右 / 前后 是相对"手机平放"的倾角, 单位度\n'
             '· 气泡永远往高处跑, 与真实水平仪一致\n'
             '· 想测 45° 之类的斜角, 直接读数字即可',
          style: TextStyle(fontSize: 11.5, height: 1.7, color: Colors.grey)),
      ]))),
    ]);
  }

  Widget _angleChip(String label, double v, Color accent) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      Text('${v.toStringAsFixed(1)}°', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accent)),
    ]));
}

class _VialPainter extends CustomPainter {
  final double roll, pitch, maxDeg; final Color accent;
  _VialPainter({required this.roll, required this.pitch, required this.maxDeg, required this.accent});
  @override void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF10161C));
    canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke
      ..strokeWidth = 2..color = Colors.white.withValues(alpha: 0.25));
    // 目标圈(气泡进这个圈就算水平)
    canvas.drawCircle(c, r * 0.28, Paint()..style = PaintingStyle.stroke
      ..strokeWidth = 1.5..color = accent.withValues(alpha: 0.85));
    final grid = Paint()..color = Colors.white.withValues(alpha: 0.18)..strokeWidth = 1;
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), grid);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), grid);
    for (final d in [10.0, 20.0, 30.0]) {
      canvas.drawCircle(c, r * (d / maxDeg).clamp(0.0, 1.0), Paint()..style = PaintingStyle.stroke
        ..strokeWidth = 1..color = Colors.white.withValues(alpha: 0.10));
    }
    // 气泡: 往高处跑 → 与倾角反向
    final dx = (-roll / maxDeg).clamp(-1.0, 1.0) * r * 0.78;
    final dy = (pitch / maxDeg).clamp(-1.0, 1.0) * r * 0.78;
    final bp = Offset(c.dx + dx, c.dy + dy);
    canvas.drawCircle(bp, r * 0.16, Paint()..color = accent.withValues(alpha: 0.25));
    canvas.drawCircle(bp, r * 0.12, Paint()..color = accent);
    canvas.drawCircle(bp, r * 0.12, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.6));
  }
  @override bool shouldRepaint(_VialPainter o) =>
    o.roll != roll || o.pitch != pitch || o.accent != accent;
}

// ───────────────────────── 指南针 ─────────────────────────
class _CompassTab extends StatefulWidget {
  const _CompassTab();
  @override State<_CompassTab> createState() => _CompassTabState();
}
class _CompassTabState extends State<_CompassTab> {
  StreamSubscription<AccelerometerEvent>? _a;
  StreamSubscription<MagnetometerEvent>? _m;
  String? _err;
  List<double>? _acc;      // 最近一次加速度(重力方向)
  double _heading = 0;     // 平滑后的朝向(度, 0=北)

  @override void initState() {
    super.initState();
    try {
      _a = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval)
        .listen((e) => _acc = [e.x, e.y, e.z],
          onError: (Object e) { if (mounted) setState(() => _err = '$e'); });
      _m = magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval)
        .listen(_onMag, onError: (Object e) { if (mounted) setState(() => _err = '$e'); });
    } catch (e) { _err = '$e'; }
  }

  void _onMag(MagnetometerEvent m) {
    final a = _acc;
    if (a == null) return;   // 还没拿到重力方向, 没法做倾斜补偿
    final raw = compassHeading(ax: a[0], ay: a[1], az: a[2], mx: m.x, my: m.y, mz: m.z);
    if (mounted) setState(() => _heading = smoothAngle(_heading, raw));
  }

  @override void dispose() { _a?.cancel(); _m?.cancel(); super.dispose(); }

  static const _dirs = ['北', '东北', '东', '东南', '南', '西南', '西', '西北'];

  @override Widget build(BuildContext c) {
    if (_err != null) return _Unsupported(name: '指南针', err: _err!);
    final dir = _dirs[(((_heading + 22.5) % 360) / 45).floor() % 8];
    final accent = Theme.of(c).colorScheme.primary;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Column(children: [
        SizedBox(width: 250, height: 250, child: CustomPaint(
          painter: _CompassPainter(heading: _heading, accent: accent))),
        const SizedBox(height: 12),
        Text('${_heading.toStringAsFixed(0)}°  $dir',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: accent)),
      ]))),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: const [
        Text('使用提示', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        SizedBox(height: 6),
        Text('· 远离磁铁、音箱、笔记本等干扰源, 否则指针会偏\n'
             '· 手机歪着拿也没关系, 已用重力方向做倾斜补偿\n'
             '· 觉得不准时, 拿手机在空中画几个"8"字重新校准',
          style: TextStyle(fontSize: 11.5, height: 1.7, color: Colors.grey)),
      ]))),
    ]);
  }
}

class _CompassPainter extends CustomPainter {
  final double heading; final Color accent;
  _CompassPainter({required this.heading, required this.accent});
  @override void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 6;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF12181F));
    canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.22));
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-heading * math.pi / 180); // 表盘反向转 = 指针始终指北
    final tick = Paint()..color = Colors.white.withValues(alpha: 0.30)..strokeWidth = 1;
    for (var d = 0; d < 360; d += 15) {
      final long = d % 45 == 0;
      canvas.save();
      canvas.rotate(d * math.pi / 180);
      canvas.drawLine(Offset(0, -r), Offset(0, -r + (long ? 14 : 7)), tick);
      canvas.restore();
    }
    for (final e in [('北', 0.0), ('东', 90.0), ('南', 180.0), ('西', 270.0)]) {
      final tp = TextPainter(textDirection: TextDirection.ltr);
      tp.text = TextSpan(text: e.$1, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
        color: e.$2 == 0 ? const Color(0xFFFF5252) : Colors.white.withValues(alpha: 0.75)));
      tp.layout();
      final rad = e.$2 * math.pi / 180;
      final pos = Offset(math.sin(rad) * (r - 34), -math.cos(rad) * (r - 34));
      tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
    }
    // 指针: 红头朝北, 白尾朝南
    final head = Path()
      ..moveTo(0, -r + 26)
      ..lineTo(-11, 12)..lineTo(0, 26)..lineTo(11, 12)..close();
    canvas.drawPath(head, Paint()..color = const Color(0xFFFF5252));
    final tail = Path()
      ..moveTo(0, r - 26)
      ..lineTo(-11, -12)..lineTo(0, -26)..lineTo(11, -12)..close();
    canvas.drawPath(tail, Paint()..color = Colors.white.withValues(alpha: 0.35));
    canvas.restore();
    canvas.drawCircle(c, 8, Paint()..color = accent);
    canvas.drawCircle(c, 8, Paint()..style = PaintingStyle.stroke..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.5));
  }
  @override bool shouldRepaint(_CompassPainter o) => o.heading != heading;
}

// ───────────────────────── 取色器 ─────────────────────────
class _PickerTab extends StatefulWidget {
  const _PickerTab();
  @override State<_PickerTab> createState() => _PickerTabState();
}
class _PickerTabState extends State<_PickerTab> {
  double h = 0, s = 1, v = 1;
  List<String> saved = [];

  @override void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => saved = p.getStringList('color_swatches') ?? []);
    });
  }

  Color get color => HSVColor.fromAHSV(1, h, s, v).toColor();
  String get hex => hexOf(color.toARGB32());
  String get rgb => 'rgb(${(color.r * 255).round()}, ${(color.g * 255).round()}, ${(color.b * 255).round()})';

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label 已复制: $text')));
  }

  Future<void> _saveSwatch() async {
    if (saved.contains(hex)) return;
    saved.insert(0, hex);
    if (saved.length > 24) saved.removeLast();
    (await SharedPreferences.getInstance()).setStringList('color_swatches', saved);
    if (mounted) setState(() {});
  }

  @override Widget build(BuildContext c) {
    return ListView(padding: const EdgeInsets.all(14), children: [
      Container(height: 88, decoration: BoxDecoration(color: color,
        borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.black12))),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: _value('HEX', hex, () => _copy(hex, 'HEX'))),
        const SizedBox(width: 8),
        Expanded(child: _value('RGB', rgb, () => _copy(rgb, 'RGB'))),
      ]),
      const SizedBox(height: 14),
      const Text('色相', style: TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 4),
      SizedBox(height: 26, child: LayoutBuilder(builder: (_, box) => GestureDetector(
        onPanDown: (d) => _setHue(d.localPosition.dx, box.maxWidth),
        onPanUpdate: (d) => _setHue(d.localPosition.dx, box.maxWidth),
        child: CustomPaint(size: Size(box.maxWidth, 26), painter: _HuePainter(h))))),
      const SizedBox(height: 12),
      const Text('饱和度 · 明度', style: TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 4),
      AspectRatio(aspectRatio: 1.6, child: LayoutBuilder(builder: (_, box) => GestureDetector(
        onPanDown: (d) => _setSV(d.localPosition, box.biggest),
        onPanUpdate: (d) => _setSV(d.localPosition, box.biggest),
        child: CustomPaint(size: box.biggest, painter: _SvPainter(h, s, v))))),
      const SizedBox(height: 14),
      Row(children: [
        OutlinedButton.icon(onPressed: _saveSwatch,
          icon: const Icon(Icons.bookmark_add_outlined, size: 18), label: const Text('存入色卡')),
        const SizedBox(width: 10),
        TextButton.icon(onPressed: () => _copy(hex, 'HEX'),
          icon: const Icon(Icons.copy, size: 18), label: const Text('复制色值')),
      ]),
      const SizedBox(height: 6),
      const Text('色卡(点一下复制, 长按删除)', style: TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: 8),
      if (saved.isEmpty)
        const Text('还没有色卡, 调好颜色点「存入色卡」', style: TextStyle(fontSize: 11, color: Colors.grey))
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final hx in saved) GestureDetector(
            onTap: () => _copy(hx, '色值'),
            onLongPress: () async {
              saved.remove(hx);
              (await SharedPreferences.getInstance()).setStringList('color_swatches', saved);
              if (mounted) setState(() {});
            },
            child: Container(width: 42, height: 42, decoration: BoxDecoration(
              color: Color(parseHexColor(hx) ?? 0xFF888888),
              borderRadius: BorderRadius.circular(9), border: Border.all(color: Colors.black12))),
          ),
        ]),
      const SizedBox(height: 14),
      const Text('取色器完全在本机运算, 不上传任何数据。',
        style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.6)),
    ]);
  }

  void _setHue(double dx, double w) {
    if (w <= 0) return;
    setState(() => h = (dx / w).clamp(0.0, 1.0) * 360);
  }

  void _setSV(Offset p, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    setState(() {
      s = (p.dx / size.width).clamp(0.0, 1.0);
      v = 1 - (p.dy / size.height).clamp(0.0, 1.0);
    });
  }

  Widget _value(String label, String text, VoidCallback onTap) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(10),
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Text('$label ', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis)),
        const Icon(Icons.copy, size: 14, color: Colors.grey),
      ])));
}

class _HuePainter extends CustomPainter {
  final double h; _HuePainter(this.h);
  @override void paint(Canvas canvas, Size size) {
    const n = 36;
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      paint.color = HSVColor.fromAHSV(1, i * 360 / n, 1, 1).toColor();
      canvas.drawRect(Rect.fromLTWH(size.width * i / n, 0, size.width / n + 1, size.height), paint);
    }
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = Colors.black12);
    final x = ((h / 360) * size.width).clamp(6.0, math.max(6.0, size.width - 6)).toDouble();
    canvas.drawCircle(Offset(x, size.height / 2), 9, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(x, size.height / 2), 9,
      Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.black26);
  }
  @override bool shouldRepaint(_HuePainter o) => o.h != h;
}

class _SvPainter extends CustomPainter {
  final double h, s, v;
  _SvPainter(this.h, this.s, this.v);
  @override void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(rect, Paint()..color = HSVColor.fromAHSV(1, h, 1, 1).toColor());
    canvas.drawRect(rect, Paint()..shader = const LinearGradient(
      colors: [Colors.white, Colors.transparent]).createShader(rect));
    canvas.drawRect(rect, Paint()..shader = const LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Colors.transparent, Colors.black]).createShader(rect));
    canvas.restore();
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = Colors.black12);
    final p = Offset(s * size.width, (1 - v) * size.height);
    canvas.drawCircle(p, 10, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5..color = Colors.white);
    canvas.drawCircle(p, 10, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = Colors.black38);
  }
  @override bool shouldRepaint(_SvPainter o) => o.h != h || o.s != s || o.v != v;
}

// 传感器不可用(模拟器常见 / 设备无此硬件)时的兜底视图
class _Unsupported extends StatelessWidget {
  final String name, err;
  const _Unsupported({required this.name, required this.err});
  @override Widget build(BuildContext c) => Center(child: Padding(padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.sensors_off_outlined, size: 56, color: Colors.grey),
      const SizedBox(height: 12),
      Text('$name 不可用', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      const Text('这台设备没有对应传感器, 或传感器读取被系统拒绝。真机一般都有。',
        textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.6)),
      const SizedBox(height: 10),
      SelectableText(err, style: const TextStyle(fontSize: 10, color: Colors.grey),
        textAlign: TextAlign.center),
    ])));
}
