// ═══════════════════════════════════════════════════════════════════════════
// 媒体离线下载队列（M1 · 2026-10-12）
//
// 与 `job_center.dart`（Work 模式自动化任务运行时 —— 模板/审批/调度/步骤回放）
// 的分工：本文件只管**媒体离线下载**一件事：排队、并发上限、自动重试、取消、重试。
// 刻意做成**独立轻量**模块，不往 job_center 的审批式模型里硬塞 —— 媒体下载
// 没有"人工审批"语义，塞进去只会让两边的模型都拧巴。
//
// ★ 纯 Dart、零 Flutter 依赖：执行器（真正调 store 下载的函数）由调用方**注入** ——
//   这样本文件能被 `tool/download_queue_selfcheck.dart` 直接 import 做行为自检。
//   （offline_media_store 依赖 path_provider（Flutter 插件），所以不能在本文件里直接调；
//     注入 runner 的写法同时解决"可自检"与"无循环依赖"两件事。）
//
// 队列规则（全部在自检里断言）：
//   · **并发上限 = 1**：媒体下载单线程友好；多任务抢带宽反而更慢、更容易失败；
//   · **自动重试**：失败后隔 [retryDelay]（默认 3s）自动重试，每任务最多 1 次自动重试；
//     仍失败 → 置 error（可在任务中心手动重试，手动重试会重置自动重试次数）；
//   · **去重**：同 kind+key 已在队列（queued/running）→ submit 直接忽略（防连点）；
//   · **取消**：queued 直接移出；running 断流（执行器的流被 cancel → store 侧停止）；
//   · **完成表**：保留最近 30 条 done/error/cancelled 供 UI 回看；
//   · **持久化**：队列把"未完成任务"（queued/running，running 降级为 queued）写给
//     注入的 persistSave；启动时 restore() 读回并入队（配合 store 的断点续传兜底）。
// ═══════════════════════════════════════════════════════════════════════════
library;

import 'dart:async';
import 'dart:convert';

/// 任务状态。
enum DlState { queued, running, done, error, cancelled }

extension DlStateX on DlState {
  String get zh => switch (this) {
        DlState.queued => '等待中',
        DlState.running => '下载中',
        DlState.done => '已完成',
        DlState.error => '失败',
        DlState.cancelled => '已取消',
      };
}

/// 一条下载任务。
class DlJob {
  DlJob({
    required this.id,
    required this.kind,
    required this.key,
    required this.title,
    this.payload = const {},
    this.total = 0,
    this.message = '',
  }) : createdAt = DateTime.now(),
       updatedAt = DateTime.now();

  final String id;

  /// 执行器分派键：'video' / 'music' / 'comic'（由注入的 runner 解释）。
  final String kind;

  /// 离线稳定键（与 MediaOfflineStore 的去重键一致 —— 同 key 不重复排队）。
  final String key;

  final String title;

  /// 执行器需要的附加信息（如视频的 sourceId/epUrl/flag、漫画的 comicName/chapName）。
  final Map<String, dynamic> payload;

  DlState state = DlState.queued;
  int done = 0;
  int total = 0;
  int bytes = 0;
  String message = '';
  int attempts = 0; // 已自动重试过的次数（手动重试会清零）
  final DateTime createdAt;
  DateTime updatedAt;

  /// 0.0~1.0；total 未知时按 0（进度条走不确定态）。
  double get ratio => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
  bool get active => state == DlState.queued || state == DlState.running;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'key': key,
        'title': title,
        'payload': payload,
        'state': state.name,
        'done': done,
        'total': total,
        'bytes': bytes,
        'message': message,
        'attempts': attempts,
      };

  factory DlJob.fromJson(Map<String, dynamic> j) {
    final job = DlJob(
      id: '${j['id'] ?? ''}',
      kind: '${j['kind'] ?? ''}',
      key: '${j['key'] ?? ''}',
      title: '${j['title'] ?? ''}',
      payload: (j['payload'] is Map)
          ? Map<String, dynamic>.from(j['payload'] as Map)
          : const {},
    );
    job.done = (j['done'] as num?)?.toInt() ?? 0;
    job.total = (j['total'] as num?)?.toInt() ?? 0;
    job.bytes = (j['bytes'] as num?)?.toInt() ?? 0;
    job.message = '${j['message'] ?? ''}';
    job.attempts = (j['attempts'] as num?)?.toInt() ?? 0;
    // 重启恢复：running 降级为 queued（断点续传兜底）
    final s = '${j['state'] ?? ''}';
    job.state = s == 'done'
        ? DlState.done
        : s == 'error'
            ? DlState.error
            : DlState.queued;
    return job;
  }
}

/// 执行器汇报的一次进度。
class DlRunProgress {
  const DlRunProgress({this.done = 0, this.total = 0, this.message = '', this.bytes = 0});
  final int done;
  final int total;
  final String message;
  final int bytes;
}

/// 执行器：给定任务，返回进度流（完成后流关闭；失败抛错）。
typedef DlRunner = Stream<DlRunProgress> Function(DlJob job);

/// 全局单例队列。
class DownloadQueue {
  DownloadQueue._();
  static final DownloadQueue i = DownloadQueue._();

  /// 执行器（由 main.dart 注入 —— 见 `_initDownloadQueue`）。
  DlRunner? runner;

  /// 自动重试间隔（自检里会改小；生产默认 3 秒）。
  Duration retryDelay = const Duration(seconds: 3);

  /// 自动重试上限（次数）。
  int maxAutoRetries = 1;

  /// 未完成任务（queued + running）。
  final List<DlJob> active = [];

  /// 最近完成/失败/取消（新在前，最多 30 条）。
  final List<DlJob> finished = [];

  final StreamController<void> _chg = StreamController<void>.broadcast();
  Stream<void> get onChange => _chg.stream;

  bool _pumping = false;
  final Map<String, StreamSubscription<DlRunProgress>> _subs = {};
  int _seq = 0;

  /// 持久化回调（main.dart 注入 SharedPreferences 实现；不注入则不做持久化）。
  void Function(String json)? persistSave;

  /// 读取持久化队列（启动时 restore 用）。
  Future<String?> Function()? persistLoad;

  String newId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${_seq++}';

  /// 提交任务（同 kind+key 已在队列时忽略）。
  void submit(DlJob job) {
    if (active.any((j) => j.kind == job.kind && j.key == job.key)) return;
    active.add(job);
    _flush();
    _notify();
    _pump();
  }

  /// 取消：queued 移出；running 断流。
  void cancel(String id) {
    final i = active.indexWhere((j) => j.id == id);
    if (i < 0) return;
    final j = active[i];
    if (j.state == DlState.queued) {
      active.removeAt(i);
      j.state = DlState.cancelled;
      j.updatedAt = DateTime.now();
      _putFinished(j);
    } else {
      j.state = DlState.cancelled;
      j.updatedAt = DateTime.now();
      _subs.remove(id)?.cancel();
      active.removeAt(i);
      _putFinished(j);
      _pumping = false;
    }
    _flush();
    _notify();
    _pump();
  }

  /// 手动重试（从完成表放回队列，重置自动重试计数）。
  void retry(String id) {
    final i = finished.indexWhere((j) => j.id == id);
    if (i < 0) return;
    final j = finished.removeAt(i);
    j.state = DlState.queued;
    j.attempts = 0;
    j.message = '';
    j.updatedAt = DateTime.now();
    active.add(j);
    _flush();
    _notify();
    _pump();
  }

  /// 清空完成表（不影响未完成任务）。
  void clearFinished() {
    finished.clear();
    _notify();
  }

  /// 仅供自检/测试：清空全部状态（生产代码不要调用）。
  void resetForTest() {
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    active.clear();
    finished.clear();
    _pumping = false;
  }

  /// 启动恢复：读持久化队列（running → queued），并入队。
  Future<void> restore() async {
    final raw = await persistLoad?.call();
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final e in list) {
        if (e is Map) {
          final j = DlJob.fromJson(Map<String, dynamic>.from(e));
          if (j.key.isNotEmpty) submit(j);
        }
      }
    } catch (_) {/* 坏数据直接放弃恢复，不阻塞启动 */}
  }

  // ───────────────────────── 内部 ─────────────────────────

  void _putFinished(DlJob j) {
    finished.insert(0, j);
    if (finished.length > 30) finished.removeRange(30, finished.length);
  }

  void _pump() {
    if (_pumping) return;
    final next = _firstQueued();
    if (next == null) return;
    _pumping = true;
    next.state = DlState.running;
    next.updatedAt = DateTime.now();
    _notify();

    final r = runner;
    if (r == null) {
      next.state = DlState.error;
      next.message = '下载执行器未注册';
      _finish(next);
      return;
    }
    try {
      final stream = r(next);
      _subs[next.id] = stream.listen((p) {
        next.done = p.done;
        next.total = p.total;
        if (p.bytes > 0) next.bytes = p.bytes;
        next.message = p.message;
        next.updatedAt = DateTime.now();
        _notify();
      }, onError: (Object e) {
        _retryOrFail(next, '$e');
      }, onDone: () {
        next.state = DlState.done;
        next.updatedAt = DateTime.now();
        _finish(next);
      }, cancelOnError: true);
    } catch (e) {
      _retryOrFail(next, '$e');
    }
  }

  DlJob? _firstQueued() {
    for (final j in active) {
      if (j.state == DlState.queued) return j;
    }
    return null;
  }

  void _retryOrFail(DlJob j, String err) {
    _subs.remove(j.id)?.cancel();
    if (j.attempts < maxAutoRetries) {
      j.attempts++;
      j.state = DlState.queued;
      j.message = '失败，${retryDelay.inSeconds} 秒后自动重试';
      j.updatedAt = DateTime.now();
      _pumping = false;
      _flush();
      _notify();
      Timer(retryDelay, _pump);
    } else {
      j.state = DlState.error;
      j.message = err;
      j.updatedAt = DateTime.now();
      _finish(j);
    }
  }

  void _finish(DlJob j) {
    _pumping = false;
    _subs.remove(j.id);
    active.removeWhere((x) => x.id == j.id);
    _putFinished(j);
    _flush();
    _notify();
    _pump();
  }

  void _flush() {
    persistSave?.call(jsonEncode([
      for (final j in active)
        if (j.active) j.toJson(),
    ]));
  }

  void _notify() {
    if (!_chg.isClosed) _chg.add(null);
  }
}
