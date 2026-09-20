// 小模块做实第三批: 提醒中心(系统通知定时) / 课程表 / 天气与快递
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';
import 'notify.dart';

class _Store3 {
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

// ═══ 提醒中心: 定时系统通知(离线也响) ═══
class RemindersPage extends StatefulWidget { const RemindersPage({super.key}); @override State<RemindersPage> createState() => _Rm(); }
class _Rm extends State<RemindersPage> {
  List<Map<String, dynamic>> items = []; // {id, title, at, done}
  static bool tzReady = false;

  @override void initState() {
    super.initState(); _load();
    if (!tzReady) { tzdata.initializeTimeZones(); tz.setLocalLocation(tz.getLocation('Asia/Shanghai')); tzReady = true; }
    Notify.init();
  }
  Future<void> _load() async => setState(() async => items = await _Store3.list('reminders'));

  Future<void> _schedule(Map<String, dynamic> e) async =>
    Notify.schedule(e['id'], e['title'] ?? '', DateTime.fromMillisecondsSinceEpoch(e['at']));
  Future<void> _cancel(int id) => Notify.cancel(id);

  Future<void> _add() async {
    final titleC = TextEditingController();
    var day = DateTime.now();
    var time = TimeOfDay.now();
    final ok = await showDialog<bool>(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: const Text('新建提醒'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: titleC, decoration: const InputDecoration(labelText: '提醒内容', isDense: true)),
        ListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text('日期 ${day.month}-${day.day}'), trailing: const Icon(Icons.calendar_today, size: 18),
          onTap: () async { final d = await showDatePicker(context: c2, initialDate: day,
            firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
            if (d != null) setD(() => day = d); }),
        ListTile(dense: true, contentPadding: EdgeInsets.zero,
          title: Text('时间 ${time.format(c2)}'), trailing: const Icon(Icons.schedule, size: 18),
          onTap: () async { final t = await showTimePicker(context: c2, initialTime: time);
            if (t != null) setD(() => time = t); }),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))])));
    if (ok != true || titleC.text.trim().isEmpty) return;
    final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (at.isBefore(DateTime.now())) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('时间已过, 请选将来的时间')));
      return;
    }
    final e = {'id': DateTime.now().millisecondsSinceEpoch % 100000 + 10000,
      'title': titleC.text.trim(), 'at': at.millisecondsSinceEpoch, 'done': false};
    items.insert(0, e);
    await _Store3.save('reminders', items);
    await _schedule(e);
    _load();
  }

  @override Widget build(BuildContext c) {
    final upcoming = items.where((e) => e['done'] != true).toList()
      ..sort((a, b) => (a['at'] as int).compareTo(b['at'] as int));
    final done = items.where((e) => e['done'] == true).toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
        child: FilledButton.icon(icon: const Icon(Icons.add_alarm, size: 18), label: const Text('新建提醒'), onPressed: _add))),
      Expanded(child: items.isEmpty
        ? const Center(child: Text('还没有提醒\n到点会弹系统通知, 关屏也响', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
        : ListView(children: [
            for (final e in upcoming) _tile(e, false),
            if (done.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(14, 8, 14, 2),
              child: Text('已完成', style: TextStyle(fontSize: 11, color: Colors.grey))),
            for (final e in done) _tile(e, true),
          ])),
    ]);
  }

  Widget _tile(Map<String, dynamic> e, bool isDone) {
    final at = DateTime.fromMillisecondsSinceEpoch(e['at']);
    final overdue = at.isBefore(DateTime.now()) && !isDone;
    return ListTile(dense: true,
      leading: Checkbox(value: isDone, onChanged: (v) async {
        e['done'] = v == true;
        if (e['done'] == true) await _cancel(e['id']); else await _schedule(e);
        await _Store3.save('reminders', items); _load(); }),
      title: Text(e['title'] ?? '', style: TextStyle(fontSize: 14,
        decoration: isDone ? TextDecoration.lineThrough : null, color: isDone ? Colors.grey : null)),
      subtitle: Text('${at.month}-${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}${overdue ? ' · 已过期' : ''}',
        style: TextStyle(fontSize: 11, color: overdue ? Colors.redAccent : Colors.grey)),
      trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18),
        onPressed: () async { await _cancel(e['id']); items.remove(e);
          await _Store3.save('reminders', items); _load(); }));
  }
}

// ═══ 课程表: 7天网格 + 点格子添加 ═══
class TimetablePage extends StatefulWidget { const TimetablePage({super.key}); @override State<TimetablePage> createState() => _Ttb(); }
class _Ttb extends State<TimetablePage> {
  List<Map<String, dynamic>> courses = []; // {name, day(1-7), start(节), len, place}
  static const sections = 8; // 每天8节
  static const dayNames = ['一', '二', '三', '四', '五', '六', '日'];
  static const palette = [0xFF5B8DEF, 0xFF4CAF50, 0xFFFF9800, 0xFF9C27B0, 0xFFE91E63, 0xFF00BCD4, 0xFFFFC107];

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async => setState(() async => courses = await _Store3.list('timetable'));

  Map<String, dynamic>? _at(int day, int sec) {
    for (final e in courses) {
      if (e['day'] == day && sec >= (e['start'] as int) && sec < (e['start'] as int) + (e['len'] as int)) return e;
    }
    return null;
  }

  Future<void> _edit(int day, int sec, [Map<String, dynamic>? exist]) async {
    final nameC = TextEditingController(text: exist?['name'] ?? '');
    final placeC = TextEditingController(text: exist?['place'] ?? '');
    var len = exist?['len'] ?? 2;
    final ok = await showDialog<bool>(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: Text('周${dayNames[day - 1]} 第$sec节'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameC, decoration: const InputDecoration(labelText: '课程名', isDense: true)),
        TextField(controller: placeC, decoration: const InputDecoration(labelText: '地点(可空)', isDense: true)),
        Row(children: [const Text('节数: ', style: TextStyle(fontSize: 13)),
          Expanded(child: Slider(value: len.toDouble(), min: 1, max: 4, divisions: 3, label: '$len 节',
            onChanged: (v) => setD(() => len = v.round())))]),
      ]),
      actions: [
        if (exist != null) TextButton(onPressed: () async {
          courses.remove(exist); await _Store3.save('timetable', courses);
          if (c2.mounted) Navigator.pop(c2, false); _load(); }, child: const Text('删除', style: TextStyle(color: Colors.redAccent))),
        TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))])));
    if (ok != true || nameC.text.trim().isEmpty) return;
    if (exist != null) courses.remove(exist);
    courses.add({'name': nameC.text.trim(), 'place': placeC.text.trim(), 'day': day, 'start': sec, 'len': len});
    await _Store3.save('timetable', courses);
    _load();
  }

  @override Widget build(BuildContext c) => Column(children: [
    const Padding(padding: EdgeInsets.all(8),
      child: Text('点空格子添加课程 · 点课程修改/删除', style: TextStyle(fontSize: 11, color: Colors.grey))),
    Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(
      width: MediaQuery.of(c).size.width, height: MediaQuery.of(c).size.height - 140,
      child: Row(children: [
        SizedBox(width: 26, child: Column(children: [
          const SizedBox(height: 22),
          for (var s = 1; s <= sections; s++) Expanded(child: Center(child: Text('$s', style: const TextStyle(fontSize: 10, color: Colors.grey)))),
        ])),
        for (var d = 1; d <= 7; d++) Expanded(child: Column(children: [
          SizedBox(height: 22, child: Center(child: Text(dayNames[d - 1],
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
              color: DateTime.now().weekday == d ? Theme.of(c).colorScheme.primary : null)))),
          for (var s = 1; s <= sections; s++) () {
            final e = _at(d, s);
            final isHead = e != null && e['start'] == s;
            final covered = e != null && !isHead;
            if (covered) return const SizedBox.shrink();
            return Expanded(
              flex: isHead ? e['len'] as int : 1,
              child: InkWell(onTap: () => _edit(d, s, isHead ? e : null),
                child: Container(margin: const EdgeInsets.all(0.5),
                  decoration: BoxDecoration(
                    color: isHead ? Color(palette[(e['name'] as String).hashCode % palette.length]).withValues(alpha: 0.25)
                      : Theme.of(c).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(4)),
                  child: isHead ? Center(child: Text('${e['name']}${(e['place'] ?? '').toString().isEmpty ? '' : '\n${e['place']}'}',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, height: 1.2),
                    maxLines: 4, overflow: TextOverflow.ellipsis)) : null)));
          }(),
        ])),
      ])))),
  ]);
}

// ═══ 天气与快递: wttr.in 公开接口 + 快递跳转查询 ═══
class WeatherPage extends StatefulWidget { const WeatherPage({super.key}); @override State<WeatherPage> createState() => _Wea(); }
class _Wea extends State<WeatherPage> {
  List<String> cities = [];
  String city = '';
  Map<String, dynamic>? data;
  bool loading = false;
  String err = '';
  final cityC = TextEditingController();
  final expressC = TextEditingController();
  // 地震速报(Wolfx 公共接口, 中国地震台网数据)
  List<Map<String, dynamic>> quakes = [];
  bool qLoading = false;
  String qErr = '';

  @override void initState() { super.initState(); _load(); _fetchQuakes(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    cities = p.getStringList('weather_cities') ?? ['北京'];
    city = p.getString('weather_city') ?? cities.first;
    setState(() {});
    if (city.isNotEmpty) _fetch(city);
  }

  Future<void> _fetch(String ct) async {
    setState(() { loading = true; err = ''; });
    try {
      final r = await http.get(Uri.parse('https://wttr.in/${Uri.encodeComponent(ct)}?format=j1&lang=zh'),
        headers: {'User-Agent': 'curl/8'}).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      data = jsonDecode(utf8.decode(r.bodyBytes));
      city = ct;
      final p = await SharedPreferences.getInstance();
      await p.setString('weather_city', ct);
      if (!cities.contains(ct)) { cities.add(ct); await p.setStringList('weather_cities', cities); }
    } catch (e) { err = '$e'; }
    if (mounted) setState(() => loading = false);
  }

  // 地震速报: api.wolfx.jp/cenc_eqlist.json(免费公共接口, 无需密钥, 台网速报数据)
  Future<void> _fetchQuakes() async {
    setState(() { qLoading = true; qErr = ''; });
    try {
      final r = await http.get(Uri.parse('https://api.wolfx.jp/cenc_eqlist.json'))
        .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final list = <Map<String, dynamic>>[];
      for (final k in m.keys) {
        final e = m[k];
        if (e is Map) list.add(Map<String, dynamic>.from(e));
      }
      // 按发震时间倒序(接口本身已按时间排, 这里兜底再排一次)
      list.sort((a, b) => '${b['time']}'.compareTo('${a['time']}'));
      quakes = list.take(10).toList();
    } catch (e) { qErr = '$e'; }
    if (mounted) setState(() => qLoading = false);
  }

  Color _magColor(double m) => m >= 6 ? Colors.red : m >= 4.5 ? Colors.deepOrange : m >= 3 ? Colors.orange : Colors.green;

  @override Widget build(BuildContext c) {
    final cur = data?['current_condition']?[0];
    final days = (data?['weather'] as List?) ?? [];
    String zh(Map e) => ((e['lang_zh'] as List?)?.first?['value'] ?? e['weatherDesc']?[0]?['value'] ?? '').toString();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        Expanded(child: TextField(controller: cityC, decoration: const InputDecoration(
          hintText: '输入城市(如 深圳 / Shenzhen)', isDense: true, border: OutlineInputBorder()),
          onSubmitted: (v) { if (v.trim().isNotEmpty) _fetch(v.trim()); })),
        const SizedBox(width: 6),
        IconButton.filled(icon: const Icon(Icons.search, size: 20), onPressed: () { if (cityC.text.trim().isNotEmpty) _fetch(cityC.text.trim()); }),
      ]),
      if (cities.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, children: [
        for (final ct in cities) InputChip(label: Text(ct, style: const TextStyle(fontSize: 12)),
          selected: ct == city, onSelected: (_) => _fetch(ct),
          onDeleted: cities.length > 1 ? () async { cities.remove(ct);
            final p = await SharedPreferences.getInstance(); await p.setStringList('weather_cities', cities);
            if (city == ct) { city = cities.first; _fetch(city); } setState(() {}); } : null),
      ])),
      if (loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
      if (err.isNotEmpty) Card(child: Padding(padding: const EdgeInsets.all(14),
        child: Text('天气获取失败: $err\n可换个城市名(中英文都行)', style: const TextStyle(fontSize: 12)))),
      if (!loading && cur != null) ...[
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          Text(city, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('${cur['temp_C']}°', style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w200)),
          Text('${zh(cur)} · 体感 ${cur['FeelsLikeC']}° · 湿度 ${cur['humidity']}% · 风 ${cur['windspeedKmph']}km/h',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]))),
        Row(children: [
          for (final d in days.take(3)) Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(10),
            child: Column(children: [
              Text((d['date'] ?? '').toString().substring(5), style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 4),
              Text('${d['mintempC']}° ~ ${d['maxtempC']}°', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              Text(zh((d['hourly'] as List)[4]), style: const TextStyle(fontSize: 10, color: Colors.grey),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            ])))),
        ]),
      ],
      const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text('快递查询', style: TextStyle(fontSize: 12, color: Colors.grey))),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Expanded(child: TextField(controller: expressC, decoration: const InputDecoration(
          hintText: '输入快递单号', isDense: true, border: OutlineInputBorder()))),
        const SizedBox(width: 6),
        FilledButton.tonalIcon(icon: const Icon(Icons.local_shipping_outlined, size: 16), label: const Text('查询'),
          onPressed: () {
            final no = expressC.text.trim();
            if (no.isEmpty) return;
            launchUrl(Uri.parse('https://www.kuaidi100.com/chaxun?nu=$no'), mode: LaunchMode.externalApplication);
          }),
      ]))),
      // ── 地震速报(公共 API) ──
      Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 6), child: Row(children: [
        const Text('地震速报 · 中国地震台网', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const Spacer(),
        InkWell(onTap: qLoading ? null : _fetchQuakes,
          child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.refresh, size: 16, color: Colors.grey))),
      ])),
      if (qLoading) const Padding(padding: EdgeInsets.all(16), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
      if (qErr.isNotEmpty) Card(child: Padding(padding: const EdgeInsets.all(12),
        child: Text('地震速报获取失败: $qErr', style: const TextStyle(fontSize: 12)))),
      if (!qLoading && quakes.isNotEmpty)
        Card(child: Column(children: [
          for (final q in quakes) () {
            final mag = double.tryParse('${q['magnitude']}') ?? 0;
            return ListTile(dense: true,
              leading: Container(width: 34, height: 34, alignment: Alignment.center,
                decoration: BoxDecoration(color: _magColor(mag).withValues(alpha: 0.14), shape: BoxShape.circle,
                  border: Border.all(color: _magColor(mag).withValues(alpha: 0.5))),
                child: Text(mag.toStringAsFixed(1), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _magColor(mag)))),
              title: Text('${q['location'] ?? q['placeName'] ?? '未知地点'}', style: const TextStyle(fontSize: 13),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${q['time'] ?? ''} · 震源深度 ${q['depth'] ?? '?'}km · 烈度 ${q['intensity'] ?? '-'}',
                style: const TextStyle(fontSize: 10, color: Colors.grey)));
          }(),
          const Padding(padding: EdgeInsets.only(bottom: 8),
            child: Text('数据源: Wolfx 公共接口 · 免费无需密钥', style: TextStyle(fontSize: 9, color: Colors.grey))),
        ])),
    ]);
  }
}
