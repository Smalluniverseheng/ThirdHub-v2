// 上游: kodjodevf/mangayomi@91bda20a9235 | repo kodjodevf/mangayomi
// 许可证: Apache-2.0
// 方式: 逐字搬运（仅加本出处头），上游正文未改一个字节
// 上游路径: lib/services/download_manager/download_retry.dart
// 台账 id: mangayomi_retry_rules
// 用途: ThirdHub 媒体离线下载队列的限速判定与重试退避规则。
//   上游仅 import dart:io 与 dart:math，零 riverpod / Isar / shiori / provider
//   依赖，可独立编译进移动端。接线见 core/download_queue.dart：执行器抛出的
//   429/503（或带 Retry-After）错误交给 RateLimitedException.fromResponse 判定，
//   重试上限用 rateLimitedAttempts、等待用 retryDelay；普通失败仍走原有
//   retryDelay，不改变既有队列行为。
import 'dart:io';
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
