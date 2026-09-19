// ═══════════════════════════════════════════════════════════════════════════
// 游戏 (离线小游戏) —— 此前是「敬请期待」空页, 这里做成真能玩的三个
//
// 规则内核在 core/lab_logic.dart(不依赖 Flutter, 可用 dart run 自检),
// 本文件只管渲染与输入。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lab_logic.dart';

class GamesPage extends StatelessWidget {
  const GamesPage({super.key});

  @override Widget build(BuildContext c) {
    final accent = Theme.of(c).colorScheme.primary;
    final games = <(String, String, String, Widget)>[
      ('2048', '合并数字, 凑出 2048', '🔢', const Game2048Page()),
      ('贪吃蛇', '越长越快, 别咬到自己', '🐍', const SnakePage()),
      ('五子棋', '先手黑棋, 对极简 AI', '⚫', const GomokuPage()),
    ];
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
        Icon(Icons.sports_esports_outlined, color: accent, size: 22),
        const SizedBox(width: 10),
        const Expanded(child: Text('纯离线小游戏, 不联网、不采集、不占后台。最高分记在本机。',
          style: TextStyle(fontSize: 12, color: Colors.grey))),
      ]))),
      const SizedBox(height: 10),
      for (final (name, desc, emoji, page) in games)
        Card(margin: const EdgeInsets.only(bottom: 8), child: ListTile(
          leading: Text(emoji, style: const TextStyle(fontSize: 24)),
          title: Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          subtitle: Text(desc, style: const TextStyle(fontSize: 12)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => page)),
        )),
    ]);
  }
}

Future<int> _bestOf(String key) async => (await SharedPreferences.getInstance()).getInt(key) ?? 0;
Future<void> _saveBest(String key, int v) async {
  final p = await SharedPreferences.getInstance();
  if (v > (p.getInt(key) ?? 0)) await p.setInt(key, v);
}

// ── 2048 ──
class Game2048Page extends StatefulWidget {
  const Game2048Page({super.key});
  @override State<Game2048Page> createState() => _G2048State();
}

class _G2048State extends State<Game2048Page> {
  final G2048 g = G2048();
  int best = 0;

  @override void initState() {
    super.initState();
    g.reset();
    _bestOf('game_2048_best').then((v) { if (mounted) setState(() { best = v; g.best = v; }); });
  }

  void _move(GDir d) {
    setState(() => g.move(d));
    if (g.score > best) { best = g.score; _saveBest('game_2048_best', best); }
    if (g.over) _finish();
  }

  void _finish() => showDialog<void>(context: context, builder: (c) => AlertDialog(
    title: const Text('本局结束'),
    content: Text('得分 ${g.score}\n最高分 ${best > g.score ? best : g.score}${g.won ? '\n(已经凑到 2048 🎉)' : ''}'),
    actions: [TextButton(onPressed: () { Navigator.pop(c); setState(g.reset); }, child: const Text('再来一局'))],
  ));

  Color _tile(int v) {
    switch (v) {
      case 0: return Colors.transparent;
      case 2: return const Color(0xFFEEE4DA);
      case 4: return const Color(0xFFEDE0C8);
      case 8: return const Color(0xFFF2B179);
      case 16: return const Color(0xFFF59563);
      case 32: return const Color(0xFFF67C5F);
      case 64: return const Color(0xFFF65E3B);
      case 128: return const Color(0xFFEDCF72);
      case 256: return const Color(0xFFEDCC61);
      case 512: return const Color(0xFFEDC850);
      case 1024: return const Color(0xFFEDC53F);
      default: return const Color(0xFFEDC22E);
    }
  }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('2048'), actions: [
      IconButton(onPressed: () => setState(g.reset), icon: const Icon(Icons.refresh)),
    ]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        _badge('得分', '${g.score}'), const SizedBox(width: 8), _badge('最高', '$best'),
        const Spacer(),
        Text('滑动操作 · 也可用下方方向键', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ])),
      Expanded(child: GestureDetector(
        onPanEnd: (d) {
          final v = d.velocity.pixelsPerSecond;
          if (v.dx.abs() < 60 && v.dy.abs() < 60) return;
          if (v.dx.abs() > v.dy.abs()) { _move(v.dx > 0 ? GDir.right : GDir.left); }
          else { _move(v.dy > 0 ? GDir.down : GDir.up); }
        },
        child: Center(child: AspectRatio(aspectRatio: 1, child: Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(color: const Color(0xFFBBADA0), borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.all(6),
            child: GridView.count(
              crossAxisCount: G2048.n, mainAxisSpacing: 6, crossAxisSpacing: 6,
              physics: const NeverScrollableScrollPhysics(),
              children: [for (var r = 0; r < G2048.n; r++) for (var cc = 0; cc < G2048.n; cc++) () {
                final v = g.at(r, cc);
                return Container(decoration: BoxDecoration(color: _tile(v), borderRadius: BorderRadius.circular(6)),
                  alignment: Alignment.center,
                  child: v == 0 ? null : Text('$v', style: TextStyle(
                    fontSize: v >= 1024 ? 18 : v >= 128 ? 22 : 26, fontWeight: FontWeight.w800,
                    color: v <= 4 ? const Color(0xFF776E65) : Colors.white)));
              }()],
            ),
          ),
        ))),
      )),
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: () => _move(GDir.up), icon: const Icon(Icons.keyboard_arrow_up)),
        ]),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: () => _move(GDir.left), icon: const Icon(Icons.keyboard_arrow_left)),
          IconButton(onPressed: () => _move(GDir.down), icon: const Icon(Icons.keyboard_arrow_down)),
          IconButton(onPressed: () => _move(GDir.right), icon: const Icon(Icons.keyboard_arrow_right)),
        ]),
      ])),
    ]),
  );

  Widget _badge(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xFFBBADA0), borderRadius: BorderRadius.circular(8)),
    child: Column(children: [
      Text(label, style: const TextStyle(fontSize: 9, color: Colors.white70)),
      Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white)),
    ]));
}

// ── 贪吃蛇 ──
class SnakePage extends StatefulWidget {
  const SnakePage({super.key});
  @override State<SnakePage> createState() => _SnakeState();
}

class _SnakeState extends State<SnakePage> {
  final SnakeGame g = SnakeGame();
  Timer? _t;
  bool paused = false;
  bool _dialogShown = false;
  int best = 0;

  @override void initState() {
    super.initState();
    _bestOf('game_snake_best').then((v) { if (mounted) setState(() => best = v); });
    _start();
  }

  void _start() {
    _t?.cancel();
    _t = Timer.periodic(Duration(milliseconds: g.speed.round()), (_) {
      if (paused) return;
      setState(g.step);
      if (g.over) {
        _t?.cancel();
        if (g.eaten > best) { best = g.eaten; _saveBest('game_snake_best', best); }
        if (!_dialogShown && mounted) { _dialogShown = true; _finish(); }
        return;
      }
      // 吃到食物会变快, 所以每步重排定时器
      _t?.cancel();
      _start();
    });
  }

  @override void dispose() { _t?.cancel(); super.dispose(); }

  void _finish() => showDialog<void>(context: context, builder: (c) => AlertDialog(
    title: const Text('撞了'),
    content: Text('这一局吃了 ${g.eaten} 个\n最高纪录 $best'),
    actions: [TextButton(onPressed: () { Navigator.pop(c); _restart(); }, child: const Text('再来一局'))],
  ));

  void _restart() { setState(g.reset); _dialogShown = false; paused = false; _start(); }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('贪吃蛇'), actions: [
      IconButton(onPressed: () => setState(() => paused = !paused), icon: Icon(paused ? Icons.play_arrow : Icons.pause)),
      IconButton(onPressed: _restart, icon: const Icon(Icons.refresh)),
    ]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Text('吃到 ${g.eaten} 个', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        Text('最高 $best', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const Spacer(),
        Text('速度 ${(1000 / g.speed).toStringAsFixed(1)} 格/秒', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ])),
      Expanded(child: GestureDetector(
        onVerticalDragEnd: (d) {
          if (d.primaryVelocity == null) return;
          g.turn(0, d.primaryVelocity! > 0 ? 1 : -1);
        },
        onHorizontalDragEnd: (d) {
          if (d.primaryVelocity == null) return;
          g.turn(d.primaryVelocity! > 0 ? 1 : -1, 0);
        },
        child: Center(child: AspectRatio(aspectRatio: g.w / g.h, child: Padding(
          padding: const EdgeInsets.all(10),
          child: Container(color: const Color(0xFF0F2027), child: CustomPaint(
            painter: _SnakePainter(g),
            child: g.over ? const Center(child: Text('撞了 · 点右上角重开',
              style: TextStyle(color: Colors.white, fontSize: 14))) : null,
          )),
        ))),
      )),
      Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(onPressed: () => g.turn(-1, 0), icon: const Icon(Icons.keyboard_arrow_left)),
        Column(children: [
          IconButton(onPressed: () => g.turn(0, -1), icon: const Icon(Icons.keyboard_arrow_up)),
          IconButton(onPressed: () => g.turn(0, 1), icon: const Icon(Icons.keyboard_arrow_down)),
        ]),
        IconButton(onPressed: () => g.turn(1, 0), icon: const Icon(Icons.keyboard_arrow_right)),
      ])),
    ]),
  );
}

class _SnakePainter extends CustomPainter {
  final SnakeGame g;
  _SnakePainter(this.g);
  @override void paint(Canvas canvas, Size size) {
    final cw = size.width / g.w, ch = size.height / g.h;
    canvas.drawCircle(Offset((g.food.x + 0.5) * cw, (g.food.y + 0.5) * ch),
      math.min(cw, ch) * 0.34, Paint()..color = const Color(0xFFFF5252));
    final body = Paint()..color = const Color(0xFF4DD0E1);
    final head = Paint()..color = const Color(0xFF00E5FF);
    for (var i = 0; i < g.body.length; i++) {
      final p = g.body[i];
      final r = Rect.fromLTWH(p.x * cw + 1, p.y * ch + 1, cw - 2, ch - 2);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), i == 0 ? head : body);
    }
  }
  @override bool shouldRepaint(_SnakePainter old) => true;
}

// ── 五子棋 ──
class GomokuPage extends StatefulWidget {
  const GomokuPage({super.key});
  @override State<GomokuPage> createState() => _GomokuState();
}

class _GomokuState extends State<GomokuPage> {
  final Gomoku g = Gomoku();
  static const int human = Gomoku.black, ai = Gomoku.white;
  int turn = human;
  int result = 0; // 0 进行中 1 人赢 2 AI 赢 3 和
  int wins = 0, losses = 0;
  bool _thinking = false;

  @override void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() { wins = p.getInt('gomoku_wins') ?? 0; losses = p.getInt('gomoku_losses') ?? 0; });
    });
  }

  void _tap(int r, int cc) {
    if (result != 0 || turn != human || _thinking) return;
    if (!g.place(r, cc, human)) return;
    setState(() { result = g.judge(r, cc); turn = ai; });
    if (result != 0) { _settle(); return; }
    _thinking = true;
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted || result != 0) { _thinking = false; return; }
      final (ar, ac) = g.bestMove(ai);
      setState(() { g.place(ar, ac, ai); result = g.judge(ar, ac); turn = human; _thinking = false; });
      if (result != 0) _settle();
    });
  }

  Future<void> _settle() async {
    final p = await SharedPreferences.getInstance();
    if (result == human) { await p.setInt('gomoku_wins', ++wins); }
    if (result == ai) { await p.setInt('gomoku_losses', ++losses); }
    // 计数改完必须再刷一次, 否则「战绩」会比棋盘慢一局
    if (mounted) setState(() {});
  }

  void _restart() { setState(() { g.reset(); turn = human; result = 0; _thinking = false; }); }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('五子棋'), actions: [
      IconButton(onPressed: _restart, icon: const Icon(Icons.refresh)),
    ]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Text(result == 0 ? (turn == human ? '轮到你(黑)' : 'AI 思考中…') : result == 3 ? '和棋' : result == human ? '你赢了 🎉' : 'AI 赢了',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const Spacer(),
        Text('战绩 $wins 胜 $losses 负', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ])),
      Expanded(child: Center(child: AspectRatio(aspectRatio: 1, child: Padding(
        padding: const EdgeInsets.all(8),
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFFE8C48A), borderRadius: BorderRadius.circular(8)),
          child: CustomPaint(
            painter: _GomokuPainter(g),
            child: LayoutBuilder(builder: (ctx, box) {
              final cell = box.maxWidth / Gomoku.n;
              return GestureDetector(
                onTapUp: (d) => _tap((d.localPosition.dy / cell).floor(), (d.localPosition.dx / cell).floor()),
                child: const SizedBox.expand(),
              );
            }),
          ),
        ),
      )))),
      if (result != 0) Padding(padding: const EdgeInsets.only(bottom: 14),
        child: FilledButton(onPressed: _restart, child: const Text('再来一局'))),
    ]),
  );
}

class _GomokuPainter extends CustomPainter {
  final Gomoku g;
  _GomokuPainter(this.g);
  @override void paint(Canvas canvas, Size size) {
    final cell = size.width / Gomoku.n;
    final line = Paint()..color = const Color(0xFF6D4C41)..strokeWidth = 0.8;
    for (var i = 0; i < Gomoku.n; i++) {
      final o = (i + 0.5) * cell;
      canvas.drawLine(Offset(o, cell * 0.5), Offset(o, size.height - cell * 0.5), line);
      canvas.drawLine(Offset(cell * 0.5, o), Offset(size.width - cell * 0.5, o), line);
    }
    for (var r = 0; r < Gomoku.n; r++) {
      for (var c = 0; c < Gomoku.n; c++) {
        final v = g.at(r, c);
        if (v == 0) continue;
        final center = Offset((c + 0.5) * cell, (r + 0.5) * cell);
        canvas.drawCircle(center, cell * 0.38, Paint()..color = v == Gomoku.black ? Colors.black : Colors.white);
        if (v == Gomoku.white) {
          canvas.drawCircle(center, cell * 0.38,
            Paint()..style = PaintingStyle.stroke..strokeWidth = 0.8..color = Colors.black38);
        }
      }
    }
  }
  @override bool shouldRepaint(_GomokuPainter old) => true;
}

/// 触感反馈统一封装(无马达机型静默忽略)
void hapticTap() { try { HapticFeedback.selectionClick(); } catch (_) {} }
