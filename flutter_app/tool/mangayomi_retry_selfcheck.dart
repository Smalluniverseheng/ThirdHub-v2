// Mangayomi 下载限速 / 重试退避规则 移植自检（纯 Dart VM，零 Flutter 依赖）
//
//   dart run tool/mangayomi_retry_selfcheck.dart
//
// 为什么必须有这条闸门：#205 第 20 轮把 Mangayomi 的
// lib/services/download_manager/download_retry.dart 逐字搬进移动端，接进
// core/download_queue.dart。错了不报错、不崩，只会静默退化成「遇 429 还按
// 固定 3 秒猛试」，而 analyze / 编译 / 台账闸门全绿。四类病：
//   ① 照印象重写：把 500ms 起翻倍写成固定值、漏掉 Retry-After 的 60s 封顶；
//   ② 搬来摆着：文件在、队列没接，限速行为一点没变；
//   ③ 把 package:mangayomi / riverpod / Isar 模型带进来，移动端编译不过；
//   ④ 破坏既有队列语义：普通失败从「最多 1 次」变成「最多 6 次」。
//
// 分层断言：§1 出处 / §2 上游正文逐字（内嵌全文，CI 不依赖本地镜像）/
//           §3 依赖白名单 / §4 上游规则行为探针 / §5 队列接线 /
//           §6 队列行为探针（真跑）/ §7 台账与镜像 / §8 CI /
//           §9 版本一致性（动态读取，不硬编码版本号）/ §10 changelog /
//           §11 合规（零第三方内容源标识）。
// ★ 末尾 exit(1)：CI 只看退出码，打印 FAIL 不等于拦住了。
// ★ 版本断言一律从唯一来源 app_version.dart 动态读取（第 18 轮修掉的复发坑）。
// ★ 接线断言按「方法块 + import 行首」精确判定，不用全文 contains
//   —— 第 17/18 轮变异测试抓到过「注掉后注释里残留同名字符串骗过 contains」。
import 'dart:convert';
import 'dart:io';

import '../lib/core/download_queue.dart';
import '../lib/vendor/mangayomi/download_retry.dart' as up;

int pass = 0, fail = 0;
final List<String> failures = <String>[];

void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    failures.add(name);
    print('  FAIL  $name');
  }
}

/// 只读归一：仓库文件可能为 CRLF，闸门锚点一律按 LF 写。
String readOr(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync().replaceAll('\r\n', '\n') : '';
}

/// 只看行首的 import 声明（注释里的同名字符串不算）。
List<String> importLinesOf(String src) => const LineSplitter()
    .convert(src)
    .where((l) => l.startsWith('import ') || l.startsWith('export '))
    .map((l) => l.trim())
    .toList();

/// 上游正文（kodjodevf/mangayomi@91bda20a9235，逐字内嵌；本地镜像缺失也拦得住）。
const String kUpstreamFull = r'''import 'dart:io';
import 'dart:math';

/// A server asked the download to slow down: 429 Too Many Requests, or 503
/// Service Unavailable. [retryAfter] is how long it asked to wait, when it
/// said.
class RateLimitedException implements Exception {
  final int statusCode;
  final Duration? retryAfter;

  const RateLimitedException(this.statusCode, {this.retryAfter});

  /// The exception for a response with [statusCode] and a `Retry-After`
  /// header of [retryAfter], or null when the status is not one that asks
  /// to slow down.
  static RateLimitedException? fromResponse(
    int statusCode,
    String? retryAfter,
  ) {
    if (statusCode != 429 && statusCode != 503) return null;
    return RateLimitedException(
      statusCode,
      retryAfter: parseRetryAfter(retryAfter),
    );
  }

  @override
  String toString() =>
      'RateLimitedException: status $statusCode'
      '${retryAfter == null ? '' : ', retry after ${retryAfter!.inSeconds} s'}';
}

/// The wait a `Retry-After` header asks for, given in seconds or as an HTTP
/// date; null when there is none or it cannot be read.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) return null;
  final trimmed = value.trim();
  final seconds = int.tryParse(trimmed);
  if (seconds != null) return Duration(seconds: max(0, seconds));
  try {
    final wait = HttpDate.parse(trimmed).difference(now ?? DateTime.now());
    return wait.isNegative ? Duration.zero : wait;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

/// Attempts allowed when the server asks to slow down: more than for other
/// failures, since waiting is what fixes it.
const rateLimitedAttempts = 6;

/// The longest wait between two attempts, whatever the server asks.
const maxRetryDelay = Duration(seconds: 60);

/// How long to wait before attempt [attempt] + 1: what the server asked
/// for, else half a second doubling with each attempt, up to 16 s.
Duration retryDelay(int attempt, {Duration? retryAfter}) {
  if (retryAfter != null) {
    return retryAfter > maxRetryDelay ? maxRetryDelay : retryAfter;
  }
  final ms = 500 * pow(2, max(0, attempt - 1)).toInt();
  return Duration(milliseconds: min(ms, 16000));
}
''';

Future<void> waitUntil(bool Function() cond, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> main() async {
  const local = 'lib/vendor/mangayomi/download_retry.dart';
  const queueRel = 'lib/core/download_queue.dart';
  const manifestRel = '../vendor/MANIFEST.json';
  const ciRel = '../.github/workflows/dart-selfcheck.yml';

  final src = readOr(local);
  String body = ''; // 上游正文（从首个 import 行起），头注释不参与依赖判定
  final queue = readOr(queueRel);
  final manifest = readOr(manifestRel);
  final ci = readOr(ciRel);
  final appVersion = readOr('lib/core/app_version.dart');
  final pubspec = readOr('pubspec.yaml');
  final readme = readOr('../README.md');
  final changelog = readOr('../build-out/changelog.json');

  // ── §1 文件与出处 ──────────────────────────────────────────────
  ck('[1] vendor 文件存在', src.isNotEmpty);
  final head = const LineSplitter().convert(src).take(14).join('\n');
  ck('[1] 头部有「上游:」出处行', head.contains('上游:'));
  ck('[1] 头部有「许可证:」', head.contains('许可证:'));
  ck('[1] 头部 repo 指向 kodjodevf/mangayomi', head.contains('kodjodevf/mangayomi'));
  ck('[1] 头部写明上游 commit', head.contains('91bda20a9235'));
  ck('[1] 头部写明上游路径', head.contains('lib/services/download_manager/download_retry.dart'));
  ck('[1] 头部写明台账 id', head.contains('mangayomi_retry_rules'));

  // ── §2 上游正文逐字 ────────────────────────────────────────────
  final lines = const LineSplitter().convert(src);
  final start = lines.indexWhere((l) => l.startsWith('import '));
  ck('[2] 能定位首个 import 行', start >= 0);
  if (start >= 0) {
    body = src.substring(src.indexOf(lines[start]));
    ck('[2] 上游正文与内嵌全文逐字一致（66 行 / 2241 字节）', body == kUpstreamFull);
    ck('[2] 正文没有被偷偷改写（字节数）', body.length == kUpstreamFull.length);
  }

  // ── §3 依赖白名单 ──────────────────────────────────────────────
  final imports = importLinesOf(src);
  ck('[3] import 恰好 2 条', imports.length == 2);
  ck('[3] 只有 dart:io', imports.contains("import 'dart:io';"));
  ck('[3] 只有 dart:math', imports.contains("import 'dart:math';"));
  ck('[3] 零 package: 自有包', imports.every((l) => !l.contains('package:')));
  for (final banned in ['riverpod', 'isar', 'shiori', 'photo_view', 'package:mangayomi']) {
    ck('[3] 上游正文不含 $banned', !body.contains(banned));
  }

  // ── §4 上游规则行为探针（真跑算法，不只看文本）────────────────
  ck('[4] rateLimitedAttempts = 6', up.rateLimitedAttempts == 6);
  ck('[4] maxRetryDelay = 60s', up.maxRetryDelay == const Duration(seconds: 60));
  ck('[4] parseRetryAfter(null) = null', up.parseRetryAfter(null) == null);
  ck('[4] parseRetryAfter("12") = 12s', up.parseRetryAfter('12') == const Duration(seconds: 12));
  ck('[4] parseRetryAfter("-3") = 0', up.parseRetryAfter('-3') == Duration.zero);
  ck('[4] parseRetryAfter("junk") = null', up.parseRetryAfter('junk') == null);
  final fixedNow = DateTime.utc(2026, 1, 1, 0, 0, 0);
  ck('[4] parseRetryAfter(HTTP-date) 按 now 差值',
      up.parseRetryAfter(HttpDate.format(fixedNow.add(const Duration(seconds: 30))), now: fixedNow) ==
          const Duration(seconds: 30));
  final r429 = up.RateLimitedException.fromResponse(429, '7');
  ck('[4] fromResponse(429,"7") 命中且 7s', r429 != null && r429!.retryAfter == const Duration(seconds: 7));
  ck('[4] fromResponse(503,null) 命中', up.RateLimitedException.fromResponse(503, null) != null);
  ck('[4] fromResponse(200,null) = null', up.RateLimitedException.fromResponse(200, null) == null);
  ck('[4] fromResponse(404,null) = null', up.RateLimitedException.fromResponse(404, null) == null);
  ck('[4] toString 含 status 429', r429.toString().contains('status 429'));
  ck('[4] retryDelay(1) = 500ms', up.retryDelay(1) == const Duration(milliseconds: 500));
  ck('[4] retryDelay(2) = 1s', up.retryDelay(2) == const Duration(seconds: 1));
  ck('[4] retryDelay(3) = 2s', up.retryDelay(3) == const Duration(seconds: 2));
  ck('[4] retryDelay(7) 封顶 16s', up.retryDelay(7) == const Duration(seconds: 16));
  ck('[4] retryDelay(0) 不越界', up.retryDelay(0) == const Duration(milliseconds: 500));
  ck('[4] Retry-After 优先', up.retryDelay(1, retryAfter: const Duration(seconds: 2)) == const Duration(seconds: 2));
  ck('[4] Retry-After 封顶 60s',
      up.retryDelay(1, retryAfter: const Duration(seconds: 120)) == const Duration(seconds: 60));

  // ── §5 队列接线（行首精确 + 方法块）─────────────────────────────
  final qImports = importLinesOf(queue);
  ck('[5] download_queue.dart 引入 vendor 文件',
      qImports.contains("import '../vendor/mangayomi/download_retry.dart' as retry_rules;"));
  ck('[5] 上限取上游 rateLimitedAttempts', queue.contains('int rateLimitedMaxRetries = retry_rules.rateLimitedAttempts;'));
  ck('[5] 等待规则取上游 retryDelay', queue.contains('retry_rules.retryDelay;'));
  ck('[5] DlJob 记录 Retry-After', queue.contains('Duration? rateLimitedAfter;'));
  ck('[5] 限速判定调用上游 fromResponse', queue.contains('retry_rules.RateLimitedException.fromResponse('));
  ck('[5] 限速走上游退避规则', queue.contains('rateLimitedDelay(j.attempts, retryAfter: limited.retryAfter)'));
  ck('[5] 普通失败仍走既有 retryDelay', queue.contains(': retryDelay;'));
  ck('[5] 定时器使用计算出的等待', queue.contains('Timer(wait, _pump);'));
  final passedError = "_retryOrFail(next, '\$e', e);";
  ck('[5] onError 与 catch 都传原始错误对象（恰好 2 处）',
      queue.split(passedError).length - 1 == 2);
  ck('[5] 手动重试清空限速等待', queue.contains('j.rateLimitedAfter = null;'));
  final methodIdx = queue.indexOf('void _retryOrFail(');
  ck('[5] 能定位 _retryOrFail 方法块', methodIdx >= 0);
  if (methodIdx >= 0) {
    final block = queue.substring(methodIdx, (methodIdx + 1400).clamp(0, queue.length));
    ck('[5] 方法块内区分限速/普通上限', block.contains('final cap = limited != null ? rateLimitedMaxRetries : maxAutoRetries;'));
    ck('[5] 方法块内记录 retryAfter', block.contains('j.rateLimitedAfter = limited?.retryAfter;'));
  }

  // ── §6 队列行为探针（真跑，注入短间隔）─────────────────────────
  final q = DownloadQueue.i;
  q.resetForTest();
  q.retryDelay = const Duration(milliseconds: 5);
  q.rateLimitedMaxRetries = 2;
  q.rateLimitedDelay = (int a, {Duration? retryAfter}) => const Duration(milliseconds: 5);
  int calls = 0;
  q.runner = (DlJob j) {
    calls++;
    return Stream<DlRunProgress>.error(
        const up.RateLimitedException(429, retryAfter: Duration(seconds: 9)));
  };
  q.submit(DlJob(id: 'p1', kind: 'comic', key: 'p1', title: 'p1'));
  await waitUntil(() => q.finished.isNotEmpty);
  ck('[6] 限速失败按上游上限重试（注入 2 次 → 共 3 次调用）', calls == 3);
  ck('[6] attempts=2 且最终 error',
      q.finished.isNotEmpty && q.finished.first.attempts == 2 && q.finished.first.state == DlState.error);
  ck('[6] Retry-After=9s 被记录',
      q.finished.isNotEmpty && q.finished.first.rateLimitedAfter == const Duration(seconds: 9));

  q.resetForTest();
  q.retryDelay = const Duration(milliseconds: 5);
  q.rateLimitedMaxRetries = 2;
  int calls2 = 0;
  q.runner = (DlJob j) {
    calls2++;
    return Stream<DlRunProgress>.error(Exception('普通失败'));
  };
  q.submit(DlJob(id: 'p2', kind: 'music', key: 'p2', title: 'p2'));
  await waitUntil(() => q.finished.isNotEmpty);
  ck('[6] 普通失败仍是既有「最多 1 次」语义', calls2 == 2 && q.finished.first.attempts == 1);

  q.resetForTest();
  q.retryDelay = const Duration(milliseconds: 5);
  q.rateLimitedMaxRetries = 2;
  q.rateLimitedDelay = (int a, {Duration? retryAfter}) => const Duration(milliseconds: 5);
  int calls3 = 0;
  q.runner = (DlJob j) {
    calls3++;
    return Stream<DlRunProgress>.error(Exception('HTTP 429 Retry-After: 4'));
  };
  q.submit(DlJob(id: 'p3', kind: 'video', key: 'p3', title: 'p3'));
  await waitUntil(() => q.finished.isNotEmpty);
  ck('[6] 错误文本里的 429 也能被上游规则识别', calls3 == 3);
  ck('[6] 错误文本里的 Retry-After: 4 被解析成 4s',
      q.finished.first.rateLimitedAfter == const Duration(seconds: 4));
  q.resetForTest();

  // ── §7 台账与本地镜像 ──────────────────────────────────────────
  ck('[7] 台账登记 mangayomi_retry_rules', manifest.contains('"id": "mangayomi_retry_rules"'));
  ck('[7] 台账 upstream_path 指向真实上游文件',
      manifest.contains('"upstream_path": "lib/services/download_manager/download_retry.dart"'));
  ck('[7] 台账 local 指向 vendor 文件',
      manifest.contains('"local": "flutter_app/lib/vendor/mangayomi/download_retry.dart"'));
  ck('[7] 台账 Apache-2.0', manifest.contains('"license": "Apache-2.0"'));
  ck('[7] 台账第 20 轮实测结论', manifest.contains('第 20 轮'));
  // 上游本地镜像按纪律不推远端：CI 里不存在时跳过，但正文已由 §2 内嵌全文逐字钉死，
  // 不依赖镜像才是硬闸门（第 15 轮结论）。
  final mirror = File('../vendor/_upstream/mangayomi/lib/services/download_manager/download_retry.dart');
  if (mirror.existsSync()) {
    ck('[7] 本地上游镜像与内嵌全文逐字一致',
        mirror.readAsStringSync().replaceAll('\r\n', '\n') == kUpstreamFull);
  } else {
    print('  SKIP  [7] 上游本地镜像未随仓库携带（CI 不依赖镜像，§2 已内嵌全文）');
  }

  // ── §8 CI 步骤 ─────────────────────────────────────────────────
  // 按行精确匹配：`.dart.bak` 这类「前缀相同」的改坏写法骗不过（第 20 轮变异 M10）。
  final ciRunLines = const LineSplitter()
      .convert(ci)
      .where((l) => l.trimLeft().startsWith('run: '))
      .map((l) => l.trim())
      .toList();
  final ciNameLines = const LineSplitter()
      .convert(ci)
      .where((l) => l.trimLeft().startsWith('- name: '))
      .map((l) => l.trim())
      .toList();
  ck('[8] CI 有 mangayomi_retry 步骤名',
      ciNameLines.any((l) => l.contains('name: mangayomi_retry（')));
  ck('[8] CI 真的跑这条闸门',
      ciRunLines.contains('run: dart run tool/mangayomi_retry_selfcheck.dart'));

  // ── §9 版本一致性（动态读取，不写死版本号）──────────────────────
  final vMatch = RegExp(r"kAppVersion\s*=\s*'([^']+)'").firstMatch(appVersion);
  final cMatch = RegExp(r'kAppCode\s*=\s*(\d+)').firstMatch(appVersion);
  ck('[9] 能解析 app_version.dart', vMatch != null && cMatch != null);
  if (vMatch != null && cMatch != null) {
    final v = vMatch.group(1)!;
    final c = cMatch.group(1)!;
    ck('[9] pubspec.yaml 版本与唯一来源一致', pubspec.contains('version: $v+$c'));
    ck('[9] README.md 版本与唯一来源一致', readme.contains('**$v**'));
    ck('[9] README.md versionCode 与唯一来源一致', readme.contains('versionCode $c'));
    ck('[9] changelog.latest 与唯一来源一致', changelog.contains('"latest": "$v"'));
    ck('[9] changelog 首条 v 与唯一来源一致', changelog.contains('"v": "$v"'));
    ck('[9] 台账 since 与唯一来源一致', manifest.contains('"since": "$v"'));
  }

  // ── §10 changelog 历史只增不改 ─────────────────────────────────
  try {
    final cl = jsonDecode(changelog) as Map<String, dynamic>;
    final entries = (cl['entries'] as List?) ?? <dynamic>[];
    ck('[10] changelog 至少 2 条历史', entries.length >= 2);
    ck('[10] note 字段保留', (cl['note'] as String?)?.isNotEmpty == true);
  } catch (_) {
    ck('[10] changelog.json 可解析', false);
  }

  // ── §11 合规（移动端零第三方内容源）──────────────────────────────
  for (final t in ['copy_manga', 'baozi', 'jmcomic', '禁漫', '书源', '图源']) {
    ck('[11] vendor 文件不含第三方内容源标识「$t」', !src.contains(t));
  }

  print('');
  print('mangayomi_retry_selfcheck: $pass 通过 / $fail 失败');
  if (fail > 0) {
    print('首条失败: ${failures.first}');
    exit(1);
  }
}
