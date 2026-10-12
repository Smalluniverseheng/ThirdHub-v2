// 下载队列自检（纯 Dart，不依赖 Flutter）。
// 跑法：
//   dart --disable-dart-dev --packages=.dart_tool/package_config.json tool/download_queue_selfcheck.dart
// 断言不过 = 抛出退出（exit(1)）。全部为行为断言（真跑队列 + 假执行器）。
import 'dart:async';
import 'dart:convert';

import '../lib/core/download_queue.dart';

int fails = 0;
void ck(String what, bool ok) {
  if (ok) {
    print('OK   $what');
  } else {
    fails++;
    print('FAIL $what');
  }
}

Future<void> waitUntil(bool Function() cond,
    {int ms = 4000, int step = 10}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(Duration(milliseconds: step));
  }
}

/// 假执行器：可配置"某 key 前 N 次失败"、可门控（hold）、记录并发与顺序。
class FakeRunner {
  final Map<String, int> failTimes = {};
  final Map<String, int> calls = {};
  final List<String> order = [];
  int concurrent = 0;
  int maxConcurrent = 0;
  Completer<void>? gate;

  void reset() {
    failTimes.clear();
    calls.clear();
    order.clear();
    concurrent = 0;
    maxConcurrent = 0;
    gate = null;
  }

  Stream<DlRunProgress> run(DlJob job) async* {
    // ★用局部快照：流被取消后 generator 可能"残活"到 finally，
    //   此时全局表可能已被下一用例 reset —— 不能依赖"读时状态"。
    final call = (calls[job.key] ?? 0) + 1;
    calls[job.key] = call;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    order.add('start:${job.key}');
    try {
      final g = gate;
      if (g != null) await g.future;
      final f = failTimes[job.key] ?? 0;
      if (call <= f) throw Exception('模拟失败');
      yield const DlRunProgress(done: 1, total: 2, message: '一半');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      yield const DlRunProgress(done: 2, total: 2, message: '完成');
    } finally {
      concurrent--;
      order.add('end:${job.key}');
    }
  }
}

DlJob job(DownloadQueue q, String kind, String key, [String title = '']) =>
    DlJob(id: q.newId(), kind: kind, key: key, title: title.isEmpty ? key : title);

Future<void> main() async {
  final q = DownloadQueue.i;
  final fake = FakeRunner();

  // ── 1. 串行执行 + 提交顺序 ──
  q.resetForTest();
  fake.reset();
  q.runner = fake.run;
  q.retryDelay = const Duration(milliseconds: 80);
  q.submit(job(q, 'video', 'k1'));
  q.submit(job(q, 'video', 'k2'));
  q.submit(job(q, 'video', 'k3'));
  await waitUntil(() => q.finished.length == 3);
  ck('[1] 3 个任务全部完成', q.finished.length == 3);
  ck('[1] 并发恒 1（媒体下载单线程友好）', fake.maxConcurrent == 1);
  ck('[1] 执行顺序 = 提交顺序',
      fake.order.where((s) => s.startsWith('start')).join(',') ==
          'start:k1,start:k2,start:k3');
  ck('[1] 完成后 active 为空', q.active.isEmpty);

  // ── 2. 失败自动重试一次后成功 ──
  q.resetForTest();
  fake.reset();
  fake.failTimes['r1'] = 1;
  q.submit(job(q, 'music', 'r1'));
  await waitUntil(() => q.finished.isNotEmpty, ms: 6000);
  ck('[2] 自动重试后完成', q.finished.length == 1 && q.finished.first.state == DlState.done);
  ck('[2] 恰好调用 2 次（首发 + 1 次重试）', fake.calls['r1'] == 2);
  ck('[2] attempts = 1', q.finished.first.attempts == 1);

  // ── 3. 连续失败 → error（自动重试 1 次后不再试） ──
  q.resetForTest();
  fake.reset();
  fake.failTimes['f1'] = 9;
  q.submit(job(q, 'video', 'f1'));
  await waitUntil(() => q.finished.isNotEmpty, ms: 8000);
  ck('[3] 连续失败置 error', q.finished.length == 1 && q.finished.first.state == DlState.error);
  ck('[3] 调用 2 次后停手', fake.calls['f1'] == 2);
  ck('[3] 带失败信息', q.finished.first.message.isNotEmpty);

  // ── 4. 手动重试（重置自动重试计数） ──
  fake.failTimes.remove('f1'); // 这次让它成功
  final fid = q.finished.first.id;
  q.retry(fid);
  await waitUntil(() => q.finished.isNotEmpty);
  ck('[4] 手动重试后完成', q.finished.first.state == DlState.done);
  ck('[4] 手动重试重置 attempts', q.finished.first.attempts == 0);

  // ── 5. 同 key 去重 ──
  q.resetForTest();
  fake.reset();
  q.submit(job(q, 'comic', 'd1'));
  q.submit(job(q, 'comic', 'd1'));
  q.submit(job(q, 'comic', 'd1'));
  await waitUntil(() => q.finished.length == 1 && q.active.isEmpty);
  ck('[5] 同 key 只执行一次', fake.calls['d1'] == 1 && q.finished.length == 1);

  // ── 6. 取消 queued ──
  q.resetForTest();
  fake.reset();
  fake.gate = Completer<void>();
  q.submit(job(q, 'video', 'c1'));
  q.submit(job(q, 'video', 'c2'));
  await waitUntil(() => fake.concurrent == 1);
  final queued = q.active.firstWhere((j) => j.state == DlState.queued);
  q.cancel(queued.id);
  ck('[6] queued 取消 → 进完成表（cancelled）',
      q.finished.any((j) => j.state == DlState.cancelled) &&
          fake.calls['c2'] == null);

  // ── 7. 取消 running ──
  final running = q.active.firstWhere((j) => j.state == DlState.running);
  q.cancel(running.id);
  await waitUntil(() => q.finished.length == 2);
  ck('[7] running 取消 → 与 queued 取消都在完成表',
      q.finished.where((j) => j.state == DlState.cancelled).length == 2);
  fake.gate?.complete();
  fake.gate = null;

  // ── 8. 持久化 + 恢复往返 ──
  q.resetForTest();
  fake.reset();
  fake.gate = Completer<void>();
  String? saved;
  q.persistSave = (s) => saved = s;
  q.persistLoad = () async => saved;
  q.submit(job(q, 'comic', 'z1'));
  q.submit(job(q, 'comic', 'z2'));
  await waitUntil(() => fake.concurrent == 1);
  ck('[8] 未完成任务已持久化（2 条）',
      saved != null && (jsonDecode(saved!) as List).length == 2);
  q.resetForTest();
  q.persistSave = null;
  await q.restore();
  ck('[8] 恢复出 2 个任务', q.active.length == 2);
  ck('[8] 恢复的任务不处于 error/done',
      q.active.every((j) => j.state == DlState.queued || j.state == DlState.running));
  fake.gate?.complete();
  fake.gate = null;

  // ── 9. 完成表上限 30 ──
  q.resetForTest();
  fake.reset();
  q.persistSave = null;
  q.persistLoad = null;
  for (var i = 0; i < 35; i++) {
    q.submit(job(q, 'music', 'm$i'));
  }
  await waitUntil(() => q.finished.length >= 30 && q.active.isEmpty, ms: 15000);
  ck('[9] 完成表保留最近 30 条', q.finished.length == 30);

  print('');
  print(fails == 0
      ? 'download_queue_selfcheck: 全部通过'
      : 'download_queue_selfcheck: $fails 项失败');
  if (fails > 0) {
    throw Exception('download_queue_selfcheck 有 $fails 项失败');
  }
}
