// 语音引擎「一键自动配对」的 **IO 层**：照 `tts_autopair.dart` 的判定发探测、
// 保存结果。判定规则全在纯规则层，这里只负责"发请求、存配置"。
//
// ★ 三条不变量：
//   ① **拉模型列表失败绝不能影响配对**。它是顺手补全，配对结论已经拿到了；
//      为了补模型把整个配对标成失败，是最糟的取舍。
//   ② **保存走统一密钥库**（`ApiKeys.set`）+ `TtsOnline.saveConfig`，
//      不自己另写一套存储 —— 否则 AI 模块与语音模块又要各填一遍。
//   ③ **响应体必须正确解码成字符串**。厂商的中文提示（"余额不足""额度已用完"）
//      正是判定"这把 Key 是这家的"的依据；按字节硬转字符串会把 UTF-8 多字节
//      拆坏，表现是"明明 Key 对却判成不匹配"，而且只在中文响应上犯、极难发现。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_keys_store.dart';
import 'tts_autopair.dart';
import 'tts_online.dart';
import 'tts_vendors.dart';

class TtsAutoPair {
  /// 探测一把 Key 属于哪家厂商。
  ///
  /// [onStep] 每试完一个候选回调一次（已试数 / 总数 / 当前候选标签），
  /// UI 据此画进度。返回按厂商去重后的结果列表。
  ///
  /// 命中即停：一把 Key 通常只属于一家，没必要把剩下的全打一遍白扣费。
  /// [stopOnFirst] 传 false 才会把所有候选试完（用于"这把 Key 可能多家通用"）。
  static Future<List<TtsProbeResult>> probe(
    String key, {
    void Function(int tried, int total, String label)? onStep,
    bool stopOnFirst = true,
    Duration timeout = const Duration(seconds: TtsAutoPairRules.probeTimeoutSec),
  }) async {
    final vendors = await TtsOnline.allVendors();
    final cands = TtsAutoPairRules.candidates(vendors, key);
    final results = <TtsProbeResult>[];
    if (cands.isEmpty) return results;

    final total = cands.length > TtsAutoPairRules.maxAttempts
        ? TtsAutoPairRules.maxAttempts
        : cands.length;
    var tried = 0;

    for (final c in cands) {
      if (tried >= TtsAutoPairRules.maxAttempts) break;
      tried++;
      onStep?.call(tried, total, c.label);

      final v = _vendorOf(vendors, c.vendorId);

      // 形态不符就别发了 —— 这次请求必败，只会白扣一次费/白等一次超时。
      final shape = TtsAutoPairRules.shapeProblem(v, c.planId, key);
      if (shape != null) {
        results.add(TtsProbeResult(
            candidate: c, outcome: TtsProbeOutcome.wrongShape, detail: shape));
        continue;
      }

      TtsProbeResult r;
      try {
        r = await _probeOne(v, c, key, timeout);
      } catch (e) {
        r = TtsProbeResult(
            candidate: c, outcome: TtsProbeOutcome.unreachable, detail: '$e');
      }
      results.add(r);
      if (r.isHit && stopOnFirst) break;
    }

    // 模型列表补全：只对命中项做，且失败不影响结论
    final out = TtsAutoPairRules.dedupeByVendor(results);
    final withModels = <TtsProbeResult>[];
    for (final r in out) {
      withModels.add(r.isHit
          ? await _fillModels(r, v: _vendorOf(vendors, r.candidate.vendorId))
          : r);
    }
    return withModels;
  }

  static TtsVendor _vendorOf(List<TtsVendor> vs, String id) {
    for (final v in vs) {
      if (v.id == id) return v;
    }
    // 到不了这里（候选就是从这张表展开的）；真到了也不要抛 —— 配对过程
    // 绝不能因为一张表的边缘情况整个崩掉。
    return vs.first;
  }

  /// 单个候选的最小探测：合成 [TtsAutoPairRules.probeText] 这一个字。
  static Future<TtsProbeResult> _probeOne(
      TtsVendor v, TtsProbeCandidate c, String key, Duration timeout) async {
    final req = planTtsRequest(
      v,
      TtsVars(
        text: TtsAutoPairRules.probeText,
        key: key,
        planUrl: c.planId.isEmpty ? '' : ttsEffectiveUrl(v, c.planId),
      ),
    );
    final uri = Uri.parse(req.url);
    if (!uri.hasScheme || uri.host.isEmpty) {
      return TtsProbeResult(
          candidate: c,
          outcome: TtsProbeOutcome.unknown,
          detail: '这家的请求地址不完整：${req.url}');
    }

    http.Response resp;
    try {
      resp = req.method == 'GET'
          ? await http.get(uri, headers: req.headers).timeout(timeout)
          : await http
              .post(uri, headers: req.headers, body: req.body)
              .timeout(timeout);
    } catch (e) {
      return TtsProbeResult(
          candidate: c, outcome: TtsProbeOutcome.unreachable, detail: '$e');
    }

    final body = _decode(resp.bodyBytes, resp.headers['content-type'] ?? '');
    return TtsProbeResult(
      candidate: c,
      outcome: TtsAutoPairRules.classify(resp.statusCode, body),
      httpStatus: resp.statusCode,
      detail: body.length > 200 ? body.substring(0, 200) : body,
    );
  }

  /// 顺手拉一次模型列表。**任何失败都吞掉**，只把结果填进 r.models。
  static Future<TtsProbeResult> _fillModels(TtsProbeResult r,
      {required TtsVendor v}) async {
    final url = TtsAutoPairRules.modelsUrlOf(r.candidate.url);
    if (url == null) return r;
    try {
      final req = planTtsRequest(
        v,
        TtsVars(text: '', key: '', planUrl: r.candidate.url),
      );
      final resp = await http
          .get(Uri.parse(url), headers: req.headers)
          .timeout(const Duration(seconds: TtsAutoPairRules.probeTimeoutSec));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return r;
      final models =
          TtsAutoPairRules.extractModels(_decode(resp.bodyBytes, resp.headers['content-type'] ?? ''));
      return models.isEmpty ? r : r.copyWith(models: models);
    } catch (_) {
      return r;
    }
  }

  /// 落盘：命中项写进统一密钥库 + 语音厂商配置。
  ///
  /// 两处都要写，缺一处的表现是"配对成功了但试听还是提示要填 Key"。
  /// 返回真正保存下来的厂商数。
  static Future<int> saveHits(List<TtsProbeResult> hits, String key) async {
    var n = 0;
    for (final r in hits) {
      if (!r.isHit) continue;
      await ApiKeys.set(r.candidate.vendorId, key);
      await TtsOnline.saveConfig(r.candidate.vendorId,
          key: key, planId: r.candidate.planId);
      n++;
    }
    return n;
  }

  /// 按 Content-Type 里的 charset 解码；没声明就按 UTF-8。
  ///
  /// ★ 这里必须正确解码（见文件头 ③）：厂商的中文提示是判定依据之一。
  static String _decode(Uint8List b, String contentType) {
    final m = RegExp(r'charset=([\w-]+)', caseSensitive: false).firstMatch(contentType);
    final enc = m == null ? utf8 : Encoding.getByName(m.group(1)!) ?? utf8;
    try {
      return enc.decode(b);
    } catch (_) {
      return utf8.decode(b, allowMalformed: true);
    }
  }
}
