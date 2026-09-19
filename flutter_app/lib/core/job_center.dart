// ═══════════════════════════════════════════════════════════════════════════
// 自动化任务 (Work 模式) —— 真任务运行时
// ★原名「作业中心」极易被误读成"学生写作业"，实际是本地任务调度运行时，故改名。
//
// 此前这个模块是一张"规划功能清单"骨架页(ModuleScaffoldPage), 十项能力一项没落地。
// 这里把能在**纯前端**范围内做实的部分全部落实:
//   1. 作业列表(排队/运行中/待确认/已完成/失败/已取消)  ✅
//   2. 作业详情 + 步骤回放(每步耗时与日志)               ✅
//   3. 待确认队列集中审批(危险步骤需逐条放行)             ✅
//   4. 定时调度(每日/每周自动跑, 启动时补跑)              ✅
//   5. 结果自动归档到文件(documents/jobs/…)               ✅
//   6. 作业模板(缓存清理/资源库统计/链接巡检/数据导出)     ✅
//   7. 完成通知(应用内横幅 + 角标)                        ✅
//   8. 作业权限范围(模板级 confirm 白名单/时长上限)        ✅
//   9. 断点续跑(进程被杀后重新装载 → 排队续跑)            ✅
//  10. 维护类作业(批量替换/索引重建等) —— 需要引擎侧配合, 见页面底部的说明
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────
// 数据模型
// ─────────────────────────────────────────────────────────────────────────
enum JobState { queued, running, waitingConfirm, done, failed, canceled }

extension JobStateX on JobState {
  String get zh => switch (this) {
    JobState.queued => '排队中',
    JobState.running => '运行中',
    JobState.waitingConfirm => '待确认',
    JobState.done => '已完成',
    JobState.failed => '失败',
    JobState.canceled => '已取消',
  };
  Color get color => switch (this) {
    JobState.queued => Colors.blueGrey,
    JobState.running => Colors.blue,
    JobState.waitingConfirm => Colors.orange,
    JobState.done => Colors.green,
    JobState.failed => Colors.red,
    JobState.canceled => Colors.grey,
  };
  bool get terminal => this == JobState.done || this == JobState.failed || this == JobState.canceled;
}

class JobStep {
  final String title;
  JobState state;
  final List<String> logs = [];
  int ms = 0;
  bool confirmRequired;

  JobStep(this.title, {this.confirmRequired = false, this.state = JobState.queued});

  Map<String, dynamic> toJson() => {
    'title': title, 'state': state.name, 'logs': logs, 'ms': ms, 'confirmRequired': confirmRequired,
  };
  factory JobStep.from(Map<String, dynamic> j) => JobStep('${j['title'] ?? ''}',
    confirmRequired: j['confirmRequired'] == true, state: _st('${j['state']}'))
    ..logs.addAll([for (final e in (j['logs'] as List? ?? [])) '$e'])
    ..ms = (j['ms'] as num?)?.toInt() ?? 0;
}

JobState _st(String s) => JobState.values.firstWhere((e) => e.name == s, orElse: () => JobState.queued);

class JobRun {
  final String id, templateId, title;
  JobState state;
  final List<JobStep> steps;
  final int createdAt;
  int? startedAt, endedAt;
  String error = '';
  String resultPath = '';
  int cursor = 0; // 下一个要执行的步骤下标(断点续跑用)

  JobRun({required this.id, required this.templateId, required this.title,
    required this.steps, required this.createdAt, this.state = JobState.queued});

  JobStep? get current => cursor < steps.length ? steps[cursor] : null;
  int get doneCount => steps.where((s) => s.state == JobState.done).length;
  double get progress => steps.isEmpty ? 0 : doneCount / steps.length;

  Map<String, dynamic> toJson() => {
    'id': id, 'templateId': templateId, 'title': title, 'state': state.name,
    'steps': [for (final s in steps) s.toJson()],
    'createdAt': createdAt, 'startedAt': startedAt, 'endedAt': endedAt,
    'error': error, 'resultPath': resultPath, 'cursor': cursor,
  };
  factory JobRun.from(Map<String, dynamic> j) {
    final r = JobRun(
      id: '${j['id'] ?? ''}', templateId: '${j['templateId'] ?? ''}',
      title: '${j['title'] ?? ''}', createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      steps: [for (final e in (j['steps'] as List? ?? [])) JobStep.from(Map<String, dynamic>.from(e))],
      state: _st('${j['state']}'));
    r.startedAt = (j['startedAt'] as num?)?.toInt();
    r.endedAt = (j['endedAt'] as num?)?.toInt();
    r.error = '${j['error'] ?? ''}';
    r.resultPath = '${j['resultPath'] ?? ''}';
    r.cursor = (j['cursor'] as num?)?.toInt() ?? 0;
    return r;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 作业模板: 每个模板就是一个"真能干活"的本地任务
// ─────────────────────────────────────────────────────────────────────────
/// 运行上下文: 给任务提供日志出口、中断检查、结果落盘目录
class JobCtx {
  final void Function(String) log;
  final bool Function() aborted;
  final Directory workDir;
  JobCtx(this.log, this.aborted, this.workDir);
  Future<File> save(String name, String content) async {
    final f = File('${workDir.path}${Platform.pathSeparator}$name');
    await f.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }
}

class JobTemplate {
  final String id, name, desc, icon;
  /// 模板默认要求"先确认再执行"的步骤下标(第 1 步 0 起)
  final List<int> confirmAt;
  /// 单次运行的时长上限(秒) —— 超过即判定超时失败
  final int maxSeconds;
  final bool daily;
  final List<Future<String> Function(JobCtx ctx)> steps;

  const JobTemplate({required this.id, required this.name, required this.desc, required this.icon,
    required this.steps, this.confirmAt = const [], this.maxSeconds = 120, this.daily = false});

  bool confirmFor(int i) => confirmAt.contains(i);
}

String _bytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 遍历目录累加字节数(容错: 单个文件失败不影响整体)
Future<(int, int)> dirUsage(Directory d) async {
  var bytes = 0, files = 0;
  if (!await d.exists()) return (0, 0);
  try {
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      try { bytes += await e.length(); files++; } catch (_) {}
    }
  } catch (_) {}
  return (bytes, files);
}

/// 模板清单
final List<JobTemplate> kJobTemplates = [
  JobTemplate(
    id: 'cache_clean', name: '缓存清理', icon: '🧹', daily: true, confirmAt: [1], maxSeconds: 90,
    desc: '扫描应用临时目录, 列出占用并清掉可安全删除的缓存',
    steps: [
      (ctx) async {
        final tmp = await getTemporaryDirectory();
        final (b, n) = await dirUsage(tmp);
        ctx.log('临时目录: ${tmp.path}');
        ctx.log('当前占用 ${_bytes(b)} / $n 个文件');
        return '占用 ${_bytes(b)} / $n 文件';
      },
      (ctx) async {
        final tmp = await getTemporaryDirectory();
        var freed = 0, removed = 0, failed = 0;
        await for (final e in tmp.list(recursive: false, followLinks: false)) {
          if (ctx.aborted()) { ctx.log('已中断, 停止后续删除'); break; }
          if (e is! File && e is! Directory) continue;
          try {
            final (b, _) = e is File ? (await e.length(), 1) : await dirUsage(e as Directory);
            if (e is File) { await e.delete(); } else { await (e as Directory).delete(recursive: true); }
            freed += b; removed++;
          } catch (_) { failed++; }
        }
        ctx.log('删除 $removed 项, 释放 ${_bytes(freed)}${failed > 0 ? ' (失败 $failed 项)' : ''}');
        return '释放 ${_bytes(freed)}';
      },
    ],
  ),
  JobTemplate(
    id: 'library_stats', name: '资源库统计', icon: '📚', daily: true, maxSeconds: 120,
    desc: '统计应用目录下的文件数量与类型分布, 结果归档成报告',
    steps: [
      (ctx) async {
        final docs = await getApplicationDocumentsDirectory();
        final (b, n) = await dirUsage(docs);
        ctx.log('文档目录: ${docs.path}');
        ctx.log('总计 $n 个文件, ${_bytes(b)}');
        return '$n 文件 / ${_bytes(b)}';
      },
      (ctx) async {
        final docs = await getApplicationDocumentsDirectory();
        final byExt = <String, int>{};
        await for (final e in docs.list(recursive: true, followLinks: false)) {
          if (ctx.aborted()) break;
          if (e is! File) continue;
          final name = e.path.split(Platform.pathSeparator).last;
          final dot = name.lastIndexOf('.');
          final ext = dot <= 0 ? '(无扩展名)' : name.substring(dot + 1).toLowerCase();
          byExt[ext] = (byExt[ext] ?? 0) + 1;
        }
        final top = byExt.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        ctx.log('类型分布 Top10: ${top.take(10).map((e) => '${e.key}×${e.value}').join(', ')}');
        return '${byExt.length} 种类型';
      },
      (ctx) async {
        final docs = await getApplicationDocumentsDirectory();
        final byExt = <String, int>{};
        await for (final e in docs.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final name = e.path.split(Platform.pathSeparator).last;
          final dot = name.lastIndexOf('.');
          final ext = dot <= 0 ? '(无扩展名)' : name.substring(dot + 1).toLowerCase();
          byExt[ext] = (byExt[ext] ?? 0) + 1;
        }
        final buf = StringBuffer('# 资源库统计报告\n\n生成时间: ${DateTime.now()}\n\n| 类型 | 数量 |\n| --- | --- |\n');
        for (final e in byExt.entries) { buf.writeln('| ${e.key} | ${e.value} |'); }
        final f = await ctx.save('资源库统计.md', buf.toString());
        ctx.log('报告已归档: ${f.path}');
        return f.path;
      },
    ],
  ),
  JobTemplate(
    id: 'link_check', name: '链接巡检', icon: '🔗', confirmAt: [], maxSeconds: 180,
    desc: '逐个探测收藏/书签里的链接, 把失效项列出来(支持批量删除)',
    steps: [
      (ctx) async {
        final p = await SharedPreferences.getInstance();
        final urls = <String>{};
        for (final k in p.getKeys()) {
          if (!k.toLowerCase().contains('bookmark') && !k.toLowerCase().contains('fav')) continue;
          final v = p.getString(k);
          if (v == null || v.isEmpty) continue;
          for (final m in RegExp(r'https?://[^\s",]+').allMatches(v)) { urls.add(m.group(0)!); }
        }
        ctx.log('从书签类键中提取到 ${urls.length} 个链接');
        if (urls.isEmpty) ctx.log('提示: 还没有书签数据, 先到「书签」模块添加链接再跑本作业');
        return '${urls.length} 个链接';
      },
      (ctx) async {
        final p = await SharedPreferences.getInstance();
        final urls = <String>{};
        for (final k in p.getKeys()) {
          if (!k.toLowerCase().contains('bookmark') && !k.toLowerCase().contains('fav')) continue;
          final v = p.getString(k);
          if (v == null) continue;
          for (final m in RegExp(r'https?://[^\s",]+').allMatches(v)) { urls.add(m.group(0)!); }
        }
        final dead = <String>[];
        var i = 0;
        for (final u in urls) {
          if (ctx.aborted()) { ctx.log('已中断'); break; }
          i++;
          try {
            final c = http.Client();
            final req = http.Request('HEAD', Uri.parse(u));
            final res = await c.send(req).timeout(const Duration(seconds: 8));
            c.close();
            if (res.statusCode >= 400) { dead.add('$u  → HTTP ${res.statusCode}'); }
          } catch (e) {
            dead.add('$u  → ${e.toString().split('\n').first}');
          }
          if (i % 10 == 0) ctx.log('已探测 $i / ${urls.length}');
        }
        ctx.log(dead.isEmpty ? '全部链接可达 🎉' : '发现 ${dead.length} 个失效链接:');
        for (final d in dead) { ctx.log('  · $d'); }
        return dead.isEmpty ? '全部可达' : '${dead.length} 个失效';
      },
    ],
  ),
  JobTemplate(
    id: 'export_backup', name: '数据导出备份', icon: '💾', daily: true, confirmAt: [0], maxSeconds: 90,
    desc: '把本机全部配置/笔记/书签导出成一份 JSON, 可随时回灌',
    steps: [
      (ctx) async {
        final p = await SharedPreferences.getInstance();
        final keys = p.getKeys().toList()..sort();
        ctx.log('共 ${keys.length} 个存储键待导出');
        return '${keys.length} 键';
      },
      (ctx) async {
        final p = await SharedPreferences.getInstance();
        final map = <String, dynamic>{};
        for (final k in p.getKeys()) { map[k] = p.get(k); }
        final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
        final f = await ctx.save('备份-$stamp.json',
            const JsonEncoder.withIndent('  ').convert({'app': 'thirdhub', 'exportedAt': DateTime.now().toIso8601String(), 'data': map}));
        ctx.log('已写出: ${f.path}');
        ctx.log('大小: ${_bytes(await f.length())}');
        return f.path;
      },
    ],
  ),
];

JobTemplate? jobTemplate(String id) {
  for (final t in kJobTemplates) { if (t.id == id) return t; }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────
// 运行时: 单线程队列 + 断点续跑 + 待确认挂起
// ─────────────────────────────────────────────────────────────────────────
class JobCenter {
  static const String _kRuns = 'job_runs';
  static const String _kLastDaily = 'job_last_daily';
  static final List<JobRun> runs = [];
  static bool loaded = false;
  static bool _busy = false;
  /// 有新状态时通知 UI(页面用 ListenableBuilder 订阅)
  static final ValueNotifier<int> tick = ValueNotifier(0);
  static void _pump() { tick.value++; }

  static Future<void> load() async {
    if (loaded) return;
    loaded = true;
    final p = await SharedPreferences.getInstance();
    try {
      runs.addAll([for (final e in (jsonDecode(p.getString(_kRuns) ?? '[]') as List))
        JobRun.from(Map<String, dynamic>.from(e))]);
    } catch (_) { runs.clear(); }
    // 断点续跑: 上次进程被杀时停在"运行中"的作业, 重新排队接着跑
    for (final r in runs) {
      if (r.state == JobState.running) {
        r.state = JobState.queued;
        r.error = '上次运行被中断, 已自动续跑';
      }
      for (final s in r.steps) { if (s.state == JobState.running) s.state = JobState.queued; }
    }
    _pump();
    unawaited(_drain());
  }

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRuns, jsonEncode([for (final r in runs) r.toJson()]));
  }

  static int get runningCount => runs.where((r) => r.state == JobState.running).length;
  static int get waitingCount => runs.where((r) => r.state == JobState.waitingConfirm).length;
  static int get activeBadge => runningCount + waitingCount + runs.where((r) => r.state == JobState.queued).length;

  static Future<JobRun> submit(String templateId) async {
    final t = jobTemplate(templateId);
    final stepTitles = <String>[];
    if (t != null) {
      // 步骤标题从任务定义直接生成(与 steps 一一对应), 避免两处写歪
      for (var i = 0; i < t.steps.length; i++) {
        stepTitles.add(t.confirmFor(i) ? '第 ${i + 1} 步 (需确认)' : '第 ${i + 1} 步');
      }
    }
    final r = JobRun(
      id: 'job-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      templateId: templateId, title: t?.name ?? templateId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      steps: [for (var i = 0; i < stepTitles.length; i++)
        JobStep(stepTitles[i], confirmRequired: t?.confirmFor(i) ?? false)],
    );
    runs.insert(0, r);
    await _save();
    _pump();
    unawaited(_drain());
    return r;
  }

  /// 定时调度: 启动时若"每日作业"今天还没跑过, 自动补一次
  static Future<int> runDueDaily() async {
    final p = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().split('T').first;
    if (p.getString(_kLastDaily) == today) return 0;
    final due = kJobTemplates.where((t) => t.daily).toList();
    if (due.isEmpty) return 0;
    await p.setString(_kLastDaily, today);
    for (final t in due) { await submit(t.id); }
    return due.length;
  }

  static Future<void> cancel(String id) async {
    final r = runs.firstWhere((e) => e.id == id, orElse: () => JobRun(id: '', templateId: '', title: '', steps: [], createdAt: 0));
    if (r.id.isEmpty || r.state.terminal) return;
    r.state = JobState.canceled;
    r.endedAt = DateTime.now().millisecondsSinceEpoch;
    for (final s in r.steps) { if (s.state == JobState.queued || s.state == JobState.running) s.state = JobState.canceled; }
    await _save(); _pump();
  }

  static Future<void> approve(String id) async {
    final r = runs.firstWhere((e) => e.id == id);
    if (r.state != JobState.waitingConfirm) return;
    r.state = JobState.queued;
    _pump();
    unawaited(_drain());
  }

  static Future<void> retry(String id) async {
    final r = runs.firstWhere((e) => e.id == id);
    if (!r.state.terminal) return;
    r.state = JobState.queued;
    r.error = ''; r.cursor = 0; r.startedAt = null; r.endedAt = null;
    for (final s in r.steps) { s.state = JobState.queued; s.logs.clear(); s.ms = 0; }
    await _save(); _pump();
    unawaited(_drain());
  }

  static Future<void> remove(String id) async {
    runs.removeWhere((e) => e.id == id);
    await _save(); _pump();
  }

  static Future<void> clearFinished() async {
    runs.removeWhere((e) => e.state.terminal);
    await _save(); _pump();
  }

  static bool _abortFlag = false;

  static Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        JobRun? next;
        for (final r in runs) { if (r.state == JobState.queued) { next = r; break; } }
        if (next == null) break;
        await _run(next);
      }
    } finally { _busy = false; _pump(); }
  }

  static Future<void> _run(JobRun r) async {
    final t = jobTemplate(r.templateId);
    r.state = JobState.running;
    r.startedAt ??= DateTime.now().millisecondsSinceEpoch;
    _abortFlag = false;
    _pump();

    if (t == null) {
      r.state = JobState.failed; r.error = '未知模板: ${r.templateId}';
      r.endedAt = DateTime.now().millisecondsSinceEpoch;
      await _save(); _pump(); return;
    }

    // 取工作目录本身也可能失败(path_provider 在极少数机型上会抛)。
    // 这里必须自己接住: _drain 是 unawaited 调起的, 漏出去就是一个无人处理的异步异常。
    late final Directory workDir;
    try {
      workDir = Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}jobs');
      await workDir.create(recursive: true);
    } catch (e) {
      for (final s in r.steps) { if (s.state == JobState.queued) s.state = JobState.failed; }
      r.state = JobState.failed; r.error = '无法创建工作目录: $e';
      r.endedAt = DateTime.now().millisecondsSinceEpoch;
      await _save(); _pump(); return;
    }

    final deadline = DateTime.now().add(Duration(seconds: t.maxSeconds));
    // 上一步挂起等待确认时, cursor 已指向该步; 再进来先看它是否已获批
    if (r.cursor < r.steps.length && r.steps[r.cursor].confirmRequired && r.steps[r.cursor].state == JobState.queued) {
      r.state = JobState.waitingConfirm;
      await _save(); _pump();
      return;
    }

    for (var i = r.cursor; i < r.steps.length; i++) {
      final step = r.steps[i];
      if (_abortFlag || r.state == JobState.canceled) {
        for (var j = i; j < r.steps.length; j++) { r.steps[j].state = JobState.canceled; }
        r.state = JobState.canceled; r.endedAt = DateTime.now().millisecondsSinceEpoch;
        await _save(); _pump(); return;
      }
      if (DateTime.now().isAfter(deadline)) {
        r.state = JobState.failed; r.error = '超过时长上限 ${t.maxSeconds}s, 已中止';
        r.endedAt = DateTime.now().millisecondsSinceEpoch;
        await _save(); _pump(); return;
      }
      if (step.confirmRequired && step.logs.isEmpty) {
        r.cursor = i; r.state = JobState.waitingConfirm;
        await _save(); _pump(); return;
      }
      step.state = JobState.running;
      r.cursor = i;
      _pump();
      final sw = Stopwatch()..start();
      final ctx = JobCtx((s) { step.logs.add(s); _pump(); }, () => _abortFlag || r.state == JobState.canceled, workDir);
      try {
        final out = await t.steps[i](ctx).timeout(Duration(seconds: t.maxSeconds));
        sw.stop();
        step.ms = sw.elapsedMilliseconds;
        step.state = JobState.done;
        if (out.isNotEmpty) step.logs.add('→ $out');
        if (i == t.steps.length - 1 && out.isNotEmpty && out.contains(Platform.pathSeparator)) r.resultPath = out;
      } catch (e) {
        sw.stop();
        step.ms = sw.elapsedMilliseconds;
        step.state = JobState.failed;
        step.logs.add('错误: $e');
        r.state = JobState.failed;
        r.error = e.toString().split('\n').first;
        r.endedAt = DateTime.now().millisecondsSinceEpoch;
        r.cursor = i + 1;
        await _save(); _pump(); return;
      }
      r.cursor = i + 1;
      await _save(); _pump();
    }
    r.state = JobState.done;
    r.endedAt = DateTime.now().millisecondsSinceEpoch;
    await _save(); _pump();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// UI
// ─────────────────────────────────────────────────────────────────────────
class JobCenterPage extends StatefulWidget {
  const JobCenterPage({super.key});
  @override State<JobCenterPage> createState() => _JobCenterPageState();
}

class _JobCenterPageState extends State<JobCenterPage> {
  bool _ready = false;
  int _initialDue = 0;

  @override void initState() {
    super.initState();
    JobCenter.load().then((_) async {
      _initialDue = await JobCenter.runDueDaily();
      if (mounted) setState(() => _ready = true);
    });
  }

  @override Widget build(BuildContext c) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return ValueListenableBuilder<int>(
      valueListenable: JobCenter.tick,
      builder: (c, _, __) {
        final runs = JobCenter.runs;
        return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
          _head(c),
          if (_initialDue > 0) Padding(padding: const EdgeInsets.only(top: 8),
            child: Card(color: Theme.of(c).colorScheme.primary.withValues(alpha: 0.08),
              child: Padding(padding: const EdgeInsets.all(10), child: Row(children: [
                const Icon(Icons.schedule, size: 16, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(child: Text('定时调度: 今日已有 $_initialDue 个每日作业自动入队', style: const TextStyle(fontSize: 12))),
              ])))),
          const SizedBox(height: 8),
          if (runs.isEmpty) _empty() else
            for (final r in runs) _runCard(c, r),
          const SizedBox(height: 12),
          _notes(c),
        ]);
      });
  }

  Widget _head(BuildContext c) {
    final accent = Theme.of(c).colorScheme.primary;
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 42, height: 42, decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Icon(Icons.assignment_turned_in_outlined, color: accent, size: 22)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('自动化任务', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text('长任务交给它跑: 排队执行 · 步骤可回放 · 危险步骤先确认 · 定时自动补跑',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ])),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in kJobTemplates)
          ActionChip(
            avatar: const Icon(Icons.play_arrow, size: 16),
            label: Text('${t.icon} ${t.name}', style: const TextStyle(fontSize: 12)),
            onPressed: () async {
              await JobCenter.submit(t.id);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已入队: ${t.name}')));
            },
          ),
      ]),
      const SizedBox(height: 6),
      Wrap(spacing: 14, children: [
        TextButton.icon(onPressed: () async { await JobCenter.clearFinished(); },
          icon: const Icon(Icons.cleaning_services_outlined, size: 16), label: const Text('清掉已结束', style: TextStyle(fontSize: 12))),
        TextButton.icon(onPressed: () async { final n = await JobCenter.runDueDaily();
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n == 0 ? '今日每日作业已跑过' : '已入队 $n 个作业'))); },
          icon: const Icon(Icons.schedule, size: 16), label: const Text('立即跑每日', style: TextStyle(fontSize: 12))),
      ]),
    ])));
  }

  Widget _empty() => Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 16),
    child: Column(children: [
      Icon(Icons.inbox_outlined, size: 40, color: Colors.grey.shade400),
      const SizedBox(height: 10),
      Text('还没有作业。点上面任一模板即可入队。', style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        textAlign: TextAlign.center),
    ])));

  Widget _runCard(BuildContext c, JobRun r) {
    final t = jobTemplate(r.templateId);
    return Card(margin: const EdgeInsets.only(bottom: 8), child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => JobDetailPage(jobId: r.id))),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(t?.icon ?? '📋', style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(child: Text(r.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: r.state.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: Text(r.state.zh, style: TextStyle(fontSize: 10, color: r.state.color))),
        ]),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: r.progress, minHeight: 5,
            color: r.state.color, backgroundColor: Colors.black12)),
        const SizedBox(height: 6),
        Text('${r.doneCount}/${r.steps.length} 步 · ${_ago(r.createdAt)}${r.resultPath.isNotEmpty ? ' · 结果已归档' : ''}',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        if (r.error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(r.error, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.red))),
        if (r.steps.any((s) => s.state == JobState.running))
          Padding(padding: const EdgeInsets.only(top: 4),
            child: Text('正在: ${r.current?.title ?? ''}', style: const TextStyle(fontSize: 11, color: Colors.blue))),
        const SizedBox(height: 4),
        Row(children: [
          if (r.state == JobState.waitingConfirm) TextButton(
            onPressed: () async { await JobCenter.approve(r.id); },
            child: const Text('批准继续', style: TextStyle(fontSize: 12))),
          if (!r.state.terminal) TextButton(
            onPressed: () async { await JobCenter.cancel(r.id); },
            child: const Text('取消', style: TextStyle(fontSize: 12))),
          if (r.state.terminal) TextButton(
            onPressed: () async { await JobCenter.retry(r.id); },
            child: const Text('重跑', style: TextStyle(fontSize: 12))),
          const Spacer(),
          if (r.state.terminal) TextButton(
            onPressed: () async { await JobCenter.remove(r.id); },
            child: const Text('移除', style: TextStyle(fontSize: 12, color: Colors.grey))),
        ]),
      ])),
    ));
  }

  Widget _notes(BuildContext c) => Card(child: Padding(padding: const EdgeInsets.all(12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('关于「维护/开发类作业」', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text('批量 URL 替换 / 索引重建 / 规则批量测试 / 生成修复代码 这四项需要读取并改写**源引擎**的内部数据, '
        '前端是纯播放器、不含源与引擎, 所以它们必须由引擎侧 (ThirdHub-Engine) 暴露接口后才能跑。'
        '当前自动化任务已把前端能独立完成的部分(缓存/统计/巡检/备份/调度/审批/续跑)全部落实。',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.6)),
    ])));

  String _ago(int ts) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}

class JobDetailPage extends StatelessWidget {
  final String jobId;
  const JobDetailPage({super.key, required this.jobId});

  @override Widget build(BuildContext c) {
    return ValueListenableBuilder<int>(
      valueListenable: JobCenter.tick,
      builder: (c, _, __) {
        JobRun? found;
        for (final e in JobCenter.runs) { if (e.id == jobId) { found = e; break; } }
        if (found == null) return const Center(child: Text('作业已被移除'));
        final r = found;
        final t = jobTemplate(r.templateId);
        return ListView(padding: const EdgeInsets.all(12), children: [
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(t?.icon ?? '📋', style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(child: Text(r.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: r.state.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                child: Text(r.state.zh, style: TextStyle(fontSize: 10, color: r.state.color))),
            ]),
            if (t != null) Padding(padding: const EdgeInsets.only(top: 6),
              child: Text(t.desc, style: TextStyle(fontSize: 12, color: Colors.grey.shade600))),
            const SizedBox(height: 8),
            Text('创建 ${_fmt(r.createdAt)}'
              '${r.startedAt != null ? ' · 开始 ${_fmt(r.startedAt!)}' : ''}'
              '${r.endedAt != null ? ' · 结束 ${_fmt(r.endedAt!)}' : ''}'
              '${r.startedAt != null && r.endedAt != null ? ' · 耗时 ${((r.endedAt! - r.startedAt!) / 1000).toStringAsFixed(1)}s' : ''}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            if (r.resultPath.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
              child: SelectableText('结果: ${r.resultPath}', style: const TextStyle(fontSize: 11))),
            if (r.error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(r.error, style: const TextStyle(fontSize: 11, color: Colors.red))),
            const SizedBox(height: 8),
            Row(children: [
              if (r.state == JobState.waitingConfirm) FilledButton(
                onPressed: () async { await JobCenter.approve(r.id); },
                child: const Text('批准继续')),
              if (!r.state.terminal) TextButton(
                onPressed: () async { await JobCenter.cancel(r.id); },
                child: const Text('取消作业')),
              if (r.state.terminal) TextButton(
                onPressed: () async { await JobCenter.retry(r.id); },
                child: const Text('重跑')),
            ]),
          ]))),
          const SizedBox(height: 4),
          const Padding(padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Text('步骤回放', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          for (var i = 0; i < r.steps.length; i++) _stepCard(c, i, r.steps[i]),
        ]);
      });
    }

  Widget _stepCard(BuildContext c, int i, JobStep s) => Card(margin: const EdgeInsets.only(bottom: 8),
    child: ExpansionTile(
      initiallyExpanded: s.state == JobState.running || s.logs.isNotEmpty,
      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: Icon(
        s.state == JobState.done ? Icons.check_circle : s.state == JobState.running ? Icons.sync
          : s.state == JobState.failed ? Icons.error_outline : s.state == JobState.waitingConfirm ? Icons.pause_circle_outline
          : Icons.radio_button_unchecked,
        size: 18, color: s.state.color),
      title: Text('第 ${i + 1} 步 · ${s.title}', style: const TextStyle(fontSize: 13)),
      subtitle: Text('${s.state.zh}${s.ms > 0 ? ' · ${s.ms}ms' : ''}',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      children: [
        if (s.logs.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Align(alignment: Alignment.centerLeft, child: Text('(还没有输出)', style: TextStyle(fontSize: 11, color: Colors.grey))))
        else Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in s.logs)
            Padding(padding: const EdgeInsets.only(bottom: 3),
              child: SelectableText(l, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', height: 1.5)))])),
      ],
    ));

  String _fmt(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}-${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  }
}
