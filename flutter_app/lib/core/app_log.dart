// 日志中心核心层（D-06）：分类 + 级别 + 持久化 + 上限 + 自动清理。
// 目标：设备的数据运行"完全透明"——登录账号、打开模块、传输书籍、引擎调用、
// 播放、报错，全部可在这里回看。只存本机（可选同步到自己的后端），不上传任何第三方。
//
// 存储：应用文档目录 logs.jsonl（每行一条 JSON，追加写，读取时倒序）。
// 上限：默认 2000 条（设置里可调 500~20000），超出即丢弃最旧（环形）。
// 自动清理：默认保留 30 天，超龄条目在启动整理时删除。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLog {
  AppLog._();

  static const cats = <String, String>{
    'account': '账号',
    'module': '模块',
    'transfer': '传输',
    'engine': '引擎',
    'playback': '播放',
    'sync': '同步',
    'system': '系统',
    'error': '报错',
  };

  static List<Map<String, dynamic>> _mem = [];
  static bool _loaded = false;
  static File? _file;
  static final _c = StreamController<void>.broadcast();
  static Stream<void> get onChange => _c.stream;

  // ── 设置（可调） ──
  static Future<int> limit() async =>
      (await SharedPreferences.getInstance()).getInt('log_limit') ?? 2000;
  static Future<int> keepDays() async =>
      (await SharedPreferences.getInstance()).getInt('log_keep_days') ?? 30;
  static Future<void> setLimit(int v) async =>
      (await SharedPreferences.getInstance()).setInt('log_limit', v.clamp(500, 20000));
  static Future<void> setKeepDays(int v) async =>
      (await SharedPreferences.getInstance()).setInt('log_keep_days', v.clamp(1, 365));

  static Future<File> _f() async {
    if (_file != null) return _file!;
    final d = await getApplicationDocumentsDirectory();
    _file = File('${d.path}/logs.jsonl');
    return _file!;
  }

  static Future<void> _ensure() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _f();
      if (await f.exists()) {
        final lines = await f.readAsLines();
        _mem = [
          for (final l in lines)
            if (l.trim().isNotEmpty)
              (jsonDecode(l) as Map).cast<String, dynamic>(),
        ];
      }
    } catch (_) {
      _mem = [];
    }
    await _gc();
  }

  /// 自动清理：超龄 + 超上限。
  static Future<void> _gc() async {
    final lim = await limit();
    final days = await keepDays();
    final cutoff = DateTime.now().millisecondsSinceEpoch - days * 86400000;
    final before = _mem.length;
    _mem.removeWhere((e) => (e['at'] as int? ?? 0) < cutoff);
    if (_mem.length > lim) _mem = _mem.sublist(_mem.length - lim);
    if (_mem.length != before) await _persist();
  }

  static Future<void> _persist() async {
    try {
      final f = await _f();
      await f.writeAsString(_mem.map((e) => jsonEncode(e)).join('\n') + '\n');
    } catch (_) {}
  }

  /// 记一条日志。cat 见 [cats]；level: info/warn/error；detail 可选附加数据。
  static Future<void> add(String cat, String level, String msg,
      {Map<String, dynamic>? detail}) async {
    await _ensure();
    _mem.add({
      'at': DateTime.now().millisecondsSinceEpoch,
      'cat': cat,
      'lv': level,
      'msg': msg,
      if (detail != null) 'd': detail,
    });
    final lim = await limit();
    if (_mem.length > lim) _mem = _mem.sublist(_mem.length - lim);
    _c.add(null);
    // 写盘节流：攒 500ms 内的多条一起写
    _wTimer?.cancel();
    _wTimer = Timer(const Duration(milliseconds: 500), _persist);
  }

  static Timer? _wTimer;

  static Future<List<Map<String, dynamic>>> all() async {
    await _ensure();
    return _mem.reversed.toList();
  }

  static Future<List<Map<String, dynamic>>> byCat(String cat) async =>
      (await all()).where((e) => e['cat'] == cat).toList();

  static Future<List<Map<String, dynamic>>> errors() async =>
      (await all()).where((e) => e['lv'] == 'error' || e['cat'] == 'error').toList();

  static Future<void> clear() async {
    _mem = [];
    await _persist();
    _c.add(null);
  }

  /// 导出为文本（分享/存档用）。
  static Future<String> export() async {
    final list = await all();
    final b = StringBuffer();
    for (final e in list) {
      final t = DateTime.fromMillisecondsSinceEpoch(e['at'] as int)
          .toString()
          .substring(0, 19);
      b.writeln('$t [${cats[e['cat']] ?? e['cat']}/${e['lv']}] ${e['msg']}'
          '${e['d'] != null ? '  ${jsonEncode(e['d'])}' : ''}');
    }
    return b.toString();
  }

  // ── 常用快捷埋点 ──
  static Future<void> account(String msg, {Map<String, dynamic>? d}) => add('account', 'info', msg, detail: d);
  static Future<void> module(String msg, {Map<String, dynamic>? d}) => add('module', 'info', msg, detail: d);
  static Future<void> transfer(String msg, {Map<String, dynamic>? d}) => add('transfer', 'info', msg, detail: d);
  static Future<void> engine(String msg, {Map<String, dynamic>? d}) => add('engine', 'info', msg, detail: d);
  static Future<void> playback(String msg, {Map<String, dynamic>? d}) => add('playback', 'info', msg, detail: d);
  static Future<void> sync(String msg, {Map<String, dynamic>? d}) => add('sync', 'info', msg, detail: d);
  static Future<void> warn(String cat, String msg, {Map<String, dynamic>? d}) => add(cat, 'warn', msg, detail: d);
  static Future<void> error(String msg, {Object? err, StackTrace? st, String cat = 'error'}) =>
      add(cat, 'error', msg, detail: {
        if (err != null) 'err': '$err',
        if (st != null) 'stack': st.toString().split('\n').take(6).join('\n'),
      });
}
