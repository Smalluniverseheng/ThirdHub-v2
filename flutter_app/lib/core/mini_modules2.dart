// 小模块做实第二批: 录音机 / 日历 / 日记 / 白板 / 悬浮便签(速记)
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store2 {
  static Future<List<Map<String, dynamic>>> list(String key) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try { return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e)).toList(); } catch (_) { return []; }
  }
  static Future<void> save(String key, List<Map<String, dynamic>> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(items));
  }
}

// ═══ 录音机: 录音/暂停/续录 + 列表回放 + 删除 ═══
class RecorderPage extends StatefulWidget { const RecorderPage({super.key}); @override State<RecorderPage> createState() => _Rec(); }
class _Rec extends State<RecorderPage> {
  final _rec = AudioRecorder();
  final _player = AudioPlayer();
  bool recording = false, paused = false;
  int seconds = 0;
  String? playingPath;
  List<Map<String, dynamic>> items = []; // {path, ts, secs}

  @override void initState() {
    super.initState(); _load();
    // 计时
    Stream.periodic(const Duration(seconds: 1)).listen((_) {
      if (recording && !paused && mounted) setState(() => seconds++);
    });
  }
  @override void dispose() { _rec.dispose(); _player.dispose(); super.dispose(); }
  Future<void> _load() async {
    final all = await _Store2.list('recordings');
    // 清掉文件已不存在的
    final alive = <Map<String, dynamic>>[];
    for (final e in all) { if (await File(e['path'] ?? '').exists()) alive.add(e); }
    if (mounted) setState(() => items = alive);
  }

  Future<void> _toggle() async {
    if (!recording) {
      if (!await _rec.hasPermission()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('需要麦克风权限')));
        return;
      }
      final ext = await getExternalStorageDirectory();
      final dir = Directory('${ext!.path}/recordings'); if (!await dir.exists()) await dir.create(recursive: true);
      final path = '${dir.path}/rec-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(const RecordConfig(), path: path);
      setState(() { recording = true; paused = false; seconds = 0; });
    } else {
      final path = await _rec.stop();
      setState(() { recording = false; paused = false; });
      if (path != null) {
        items.insert(0, {'path': path, 'ts': DateTime.now().millisecondsSinceEpoch, 'secs': seconds});
        await _Store2.save('recordings', items);
        setState(() {});
      }
    }
  }

  Future<void> _play(String path) async {
    if (playingPath == path) { await _player.stop(); setState(() => playingPath = null); return; }
    await _player.setFilePath(path);
    setState(() => playingPath = path);
    await _player.play();
    _player.playerStateStream.firstWhere((s) => s.playing == false).then((_) {
      if (mounted) setState(() => playingPath = null); });
  }

  @override Widget build(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    return Column(children: [
      Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        Text('${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
          style: TextStyle(fontSize: 36, fontWeight: FontWeight.w200,
            color: recording ? Colors.redAccent : scheme.onSurface)),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (recording) IconButton(icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 26),
            onPressed: () async { if (paused) { await _rec.resume(); } else { await _rec.pause(); }
              setState(() => paused = !paused); }),
          const SizedBox(width: 12),
          GestureDetector(onTap: _toggle, child: Container(width: 64, height: 64,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: recording ? Colors.redAccent : scheme.primary),
            child: Icon(recording ? Icons.stop : Icons.mic, color: Colors.white, size: 30))),
        ]),
        const SizedBox(height: 6),
        Text(recording ? (paused ? '已暂停 · 点红色停止保存' : '录音中 · 点红色停止保存') : '点按开始录音',
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ])),
      const Divider(height: 1),
      Expanded(child: items.isEmpty
        ? const Center(child: Text('还没有录音', style: TextStyle(color: Colors.grey)))
        : ListView(children: [
            for (final e in items) Dismissible(key: ValueKey(e['path']),
              direction: DismissDirection.endToStart,
              background: Container(color: Colors.redAccent, alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
              onDismissed: (_) async {
                try { await File(e['path']).delete(); } catch (_) {}
                items.remove(e); await _Store2.save('recordings', items); setState(() {});
              },
              child: ListTile(dense: true,
                leading: Icon(playingPath == e['path'] ? Icons.stop_circle : Icons.play_circle_outline,
                  size: 26, color: playingPath == e['path'] ? scheme.primary : null),
                title: Text('录音 ${DateTime.fromMillisecondsSinceEpoch(e['ts'] ?? 0).toString().substring(0, 16)}',
                  style: const TextStyle(fontSize: 13)),
                subtitle: Text('${e['secs'] ?? 0} 秒', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                onTap: () => _play(e['path']))),
          ])),
    ]);
  }
}

// ═══ 日历: 月视图 + 日程增删 + 今天高亮 ═══
class CalendarPage extends StatefulWidget { const CalendarPage({super.key}); @override State<CalendarPage> createState() => _Cal(); }
class _Cal extends State<CalendarPage> {
  DateTime view = DateTime.now();
  List<Map<String, dynamic>> events = []; // {date: yyyy-m-d, time: HH:mm, title}

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async => setState(() async => events = await _Store2.list('calendar_events'));

  static String _d(DateTime d) => '${d.year}-${d.month}-${d.day}';

  Future<void> _addEvent(DateTime day) async {
    final titleC = TextEditingController();
    TimeOfDay time = const TimeOfDay(hour: 9, minute: 0);
    final ok = await showDialog<bool>(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: Text('${day.month}月${day.day}日 新日程'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: titleC, decoration: const InputDecoration(labelText: '事项', isDense: true)),
        const SizedBox(height: 10),
        ListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text('时间 ${time.format(c2)}'),
          trailing: const Icon(Icons.schedule, size: 18),
          onTap: () async { final t = await showTimePicker(context: c2, initialTime: time);
            if (t != null) setD(() => time = t); }),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))])));
    if (ok != true || titleC.text.trim().isEmpty) return;
    events.add({'date': _d(day), 'time': '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
      'title': titleC.text.trim()});
    events.sort((a, b) => '${a['date']}${a['time']}'.compareTo('${b['date']}${b['time']}'));
    await _Store2.save('calendar_events', events);
    _load();
  }

  void _showDay(DateTime day) {
    final key = _d(day);
    final list = events.where((e) => e['date'] == key).toList();
    showModalBottomSheet(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => SafeArea(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text('${day.month}月${day.day}日', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          FilledButton.tonalIcon(icon: const Icon(Icons.add, size: 16), label: const Text('加日程'),
            onPressed: () { Navigator.pop(c2); _addEvent(day); }),
        ]),
        const SizedBox(height: 8),
        if (list.isEmpty) const Padding(padding: EdgeInsets.all(20),
          child: Text('这天没有日程', style: TextStyle(color: Colors.grey))),
        for (final e in list) ListTile(dense: true,
          leading: Text(e['time'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          title: Text(e['title'] ?? '', style: const TextStyle(fontSize: 14)),
          trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () { events.remove(e); _Store2.save('calendar_events', events).then((_) { _load(); setD(() {}); Navigator.pop(c2); }); })),
      ])))));
  }

  @override Widget build(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    final first = DateTime(view.year, view.month, 1);
    final daysInMonth = DateTime(view.year, view.month + 1, 0).day;
    final startWeekday = first.weekday % 7; // 周日开头
    final today = DateTime.now();
    final cells = <DateTime?>[
      for (var i = 0; i < startWeekday; i++) null,
      for (var d = 1; d <= daysInMonth; d++) DateTime(view.year, view.month, d),
    ];
    final eventDays = events.map((e) => e['date'] as String).toSet();
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: Row(children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => view = DateTime(view.year, view.month - 1))),
        Expanded(child: Center(child: Text('${view.year} 年 ${view.month} 月',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)))),
        TextButton(onPressed: () => setState(() => view = DateTime.now()), child: const Text('今天')),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setState(() => view = DateTime(view.year, view.month + 1))),
      ])),
      Row(children: [for (final w in ['日', '一', '二', '三', '四', '五', '六'])
        Expanded(child: Center(child: Text(w, style: const TextStyle(fontSize: 11, color: Colors.grey))))]),
      Expanded(child: GridView.count(crossAxisCount: 7, padding: const EdgeInsets.all(4),
        children: [for (final d in cells) d == null ? const SizedBox() : () {
          final isToday = d.year == today.year && d.month == today.month && d.day == today.day;
          final hasEvent = eventDays.contains(_d(d));
          return InkWell(borderRadius: BorderRadius.circular(10), onTap: () => _showDay(d),
            child: Container(margin: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
                color: isToday ? scheme.primary.withValues(alpha: 0.15) : null,
                border: isToday ? Border.all(color: scheme.primary, width: 1) : null),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('${d.day}', style: TextStyle(fontSize: 14,
                  fontWeight: isToday ? FontWeight.w800 : FontWeight.w400,
                  color: isToday ? scheme.primary : null)),
                if (hasEvent) Container(width: 5, height: 5, margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary)),
              ])));
        }() ])),
    ]);
  }
}

// ═══ 日记: 按日期 + 心情 + 时间轴 ═══
class DiaryPage extends StatefulWidget { const DiaryPage({super.key}); @override State<DiaryPage> createState() => _Diary(); }
class _Diary extends State<DiaryPage> {
  List<Map<String, dynamic>> entries = []; // {date, mood, content, ts}
  static const moods = ['😄', '🙂', '😐', '😔', '😤'];

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async => setState(() async => entries = await _Store2.list('diary'));

  Future<void> _edit([Map<String, dynamic>? e]) async {
    final contentC = TextEditingController(text: e?['content'] ?? '');
    var mood = e?['mood'] ?? '🙂';
    final date = e?['date'] ?? _today();
    final ok = await showDialog<bool>(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: Text('$date 的日记'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          for (final m in moods) GestureDetector(onTap: () => setD(() => mood = m),
            child: Container(padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(shape: BoxShape.circle,
                color: mood == m ? Theme.of(c2).colorScheme.primary.withValues(alpha: 0.15) : null),
              child: Text(m, style: const TextStyle(fontSize: 22)))),
        ]),
        const SizedBox(height: 10),
        TextField(controller: contentC, maxLines: 6,
          decoration: const InputDecoration(hintText: '今天发生了什么…', border: OutlineInputBorder(), isDense: true)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))])));
    if (ok != true) return;
    if (contentC.text.trim().isEmpty) return;
    entries.removeWhere((x) => x['date'] == date);
    entries.insert(0, {'date': date, 'mood': mood, 'content': contentC.text.trim(),
      'ts': DateTime.now().millisecondsSinceEpoch});
    entries.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
    await _Store2.save('diary', entries);
    _load();
  }

  static String _today() { final d = DateTime.now(); return '${d.year}-${d.month}-${d.day}'; }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.edit, size: 18),
        label: Text(entries.any((e) => e['date'] == _today()) ? '编辑今天的日记' : '写今天的日记'),
        onPressed: () {
          final exist = entries.where((e) => e['date'] == _today()).firstOrNull;
          _edit(exist);
        }))),
    Expanded(child: entries.isEmpty
      ? const Center(child: Text('还没有日记\n从今天开始记录吧', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView(children: [
          for (final e in entries) Card(margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: ListTile(
              leading: Text(e['mood'] ?? '🙂', style: const TextStyle(fontSize: 24)),
              title: Text(e['date'] ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              subtitle: Text(e['content'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
              onTap: () => _edit(e),
              onLongPress: () async {
                final ok = await showDialog<bool>(context: c, builder: (c2) => AlertDialog(
                  title: const Text('删除日记'), content: Text('删除 ${e['date']} 的日记?'),
                  actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('删除'))]));
                if (ok == true) { entries.remove(e); await _Store2.save('diary', entries); _load(); }
              })),
        ])),
  ]);
}

// ═══ 白板: 手绘 + 颜色/粗细 + 撤销 + 保存PNG ═══
class WhiteboardPage extends StatefulWidget { const WhiteboardPage({super.key}); @override State<WhiteboardPage> createState() => _Wb(); }
class _Stroke {
  final List<Offset> points; final Color color; final double width;
  _Stroke(this.points, this.color, this.width);
}
class _Wb extends State<WhiteboardPage> {
  final List<_Stroke> strokes = [];
  _Stroke? cur;
  Color color = Colors.white;
  double width = 3;
  final _key = GlobalKey();
  static const colors = [Colors.white, Colors.redAccent, Colors.orange, Colors.yellow, Colors.green, Colors.blue, Colors.purpleAccent];

  Future<void> _save() async {
    try {
      final boundary = _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 3);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      final ext = await getExternalStorageDirectory();
      final dir = Directory('${ext!.path}/whiteboard'); if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}/wb-${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存: ${f.path}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
    }
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(children: [
      for (final cl in colors) GestureDetector(onTap: () => setState(() => color = cl),
        child: Container(width: 26, height: 26, margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(color: cl, shape: BoxShape.circle,
            border: Border.all(color: color == cl ? Theme.of(c).colorScheme.primary : Colors.grey, width: color == cl ? 3 : 1)))),
      const Spacer(),
      SizedBox(width: 80, child: Slider(value: width, min: 1, max: 12, onChanged: (v) => setState(() => width = v))),
      IconButton(icon: const Icon(Icons.undo, size: 20), tooltip: '撤销',
        onPressed: strokes.isEmpty ? null : () => setState(() => strokes.removeLast())),
      IconButton(icon: const Icon(Icons.delete_outline, size: 20), tooltip: '清空',
        onPressed: () => setState(() => strokes.clear())),
      IconButton(icon: const Icon(Icons.save_alt, size: 20), tooltip: '保存 PNG', onPressed: _save),
    ])),
    Expanded(child: RepaintBoundary(key: _key, child: Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      decoration: BoxDecoration(color: const Color(0xFF14161C), borderRadius: BorderRadius.circular(14)),
      child: GestureDetector(
        onPanStart: (d) => setState(() { cur = _Stroke([d.localPosition], color, width); strokes.add(cur!); }),
        onPanUpdate: (d) => setState(() => cur!.points.add(d.localPosition)),
        onPanEnd: (_) => setState(() => cur = null),
        child: ClipRRect(borderRadius: BorderRadius.circular(14),
          child: CustomPaint(painter: _WbPainter(strokes), size: Size.infinite)),
      )))),
  ]);
}
class _WbPainter extends CustomPainter {
  final List<_Stroke> strokes;
  _WbPainter(this.strokes);
  @override void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()..color = s.color..strokeWidth = s.width
        ..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      for (var i = 1; i < s.points.length; i++) {
        canvas.drawLine(s.points[i - 1], s.points[i], paint);
      }
      if (s.points.length == 1) canvas.drawCircle(s.points[0], s.width / 2, paint..style = PaintingStyle.fill);
    }
  }
  @override bool shouldRepaint(_WbPainter old) => true;
}

// ═══ 悬浮便签(速记): 极速记录 + 置顶 + 复制 ═══
class QuickNotePage extends StatefulWidget { const QuickNotePage({super.key}); @override State<QuickNotePage> createState() => _Qn(); }
class _Qn extends State<QuickNotePage> {
  List<Map<String, dynamic>> items = [];
  final input = TextEditingController();

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async => setState(() async => items = await _Store2.list('quick_notes'));

  Future<void> _add() async {
    final t = input.text.trim();
    if (t.isEmpty) return;
    items.insert(0, {'text': t, 'pin': false, 'ts': DateTime.now().millisecondsSinceEpoch});
    input.clear();
    await _Store2.save('quick_notes', items);
    setState(() {});
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: Row(children: [
      Expanded(child: TextField(controller: input, autofocus: false,
        decoration: const InputDecoration(hintText: '速记: 想到什么写什么, 回车即存…', isDense: true, border: OutlineInputBorder()),
        onSubmitted: (_) => _add())),
      const SizedBox(width: 6),
      IconButton.filled(icon: const Icon(Icons.send, size: 18), onPressed: _add),
    ])),
    const Padding(padding: EdgeInsets.only(bottom: 6),
      child: Text('全局悬浮窗形式在规划中(需系统悬浮窗权限), 当前为极速速记', style: TextStyle(fontSize: 10, color: Colors.grey))),
    Expanded(child: items.isEmpty
      ? const Center(child: Text('还没有速记', style: TextStyle(color: Colors.grey)))
      : ListView(children: [
          for (final e in items) Dismissible(key: ValueKey('${e['ts']}_${e['text']}'),
            direction: DismissDirection.endToStart,
            background: Container(color: Colors.redAccent, alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
            onDismissed: (_) { items.remove(e); _Store2.save('quick_notes', items).then((_) => _load()); },
            child: ListTile(dense: true,
              leading: IconButton(icon: Icon(e['pin'] == true ? Icons.push_pin : Icons.push_pin_outlined, size: 18,
                color: e['pin'] == true ? Theme.of(c).colorScheme.primary : Colors.grey),
                onPressed: () { e['pin'] = e['pin'] != true; items.remove(e);
                  if (e['pin'] == true) items.insert(0, e); else items.add(e);
                  _Store2.save('quick_notes', items).then((_) => _load()); }),
              title: Text(e['text'] ?? '', style: const TextStyle(fontSize: 14)),
              subtitle: Text(DateTime.fromMillisecondsSinceEpoch(e['ts'] ?? 0).toString().substring(0, 16),
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
              trailing: const Icon(Icons.copy, size: 16, color: Colors.grey),
              onTap: () { Clipboard.setData(ClipboardData(text: e['text'] ?? ''));
                ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('已复制'))); })),
        ])),
  ]);
}
