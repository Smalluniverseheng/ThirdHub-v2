// 语音引擎「一键自动配对」的**规则层**（零 Flutter 依赖，纯 Dart 自检可直接断言）。
//
// 用户需求(2026-10-01)：「语音引擎一键自动配对」。
// 现状是：32 家厂商、10 家同名可直通、2 家同公司不同名，还有"套餐 vs 按量"两套
// 端点 —— 用户拿到一把 Key，要自己判断它是哪家的、该选哪套计费方式，判断错了
// 表现是"试听没声音"或"提示 Key 不对"，而 Key 其实没错。
//
// 这里要做的是把"判断它是哪家的"变成机器能做的事：
//   ① 按 Key 形态/厂商登记，把候选收窄（能少打一次无效请求就少打一次）；
//   ② 逐个发**最小探测**（合成一个字），按响应分类；
//   ③ 命中即保存 Key / 计费方案，并顺手拉一次模型列表补全。
//
// ★ 为什么判定规则必须是纯函数：分类写错的表现是"把对的 Key 判成错的"，
//   用户就会去重新申请 Key —— 排查半天。纯 Dart 自检可以拿真实响应样本逐条钉。
//
// ★ 分类里最容易写反的一条：**402 / 配额不足 也算命中**。
//   余额不足、免费额度用完，恰恰证明这把 Key 是被这家接受的（否则会是 401）。
//   按"只有 200 算成功"写的话，一把没钱的 Key 会被判成"哪家都不匹配"，
//   用户以为 Key 无效 —— 这是最容易发生、也最伤的一种误判。
library;

import 'dart:convert';

import 'tts_vendors.dart';

/// 一次探测的候选：某厂商的某套计费方案。
class TtsProbeCandidate {
  final String vendorId;
  final String vendorName;
  final String planId; // 空 = 这家只有一套端点
  final String planName;
  final String url; // 实际会打到的地址（已按计费方案解析）
  final String keyHint;

  const TtsProbeCandidate({
    required this.vendorId,
    required this.vendorName,
    required this.planId,
    required this.planName,
    required this.url,
    this.keyHint = '',
  });

  String get label => planName.isEmpty ? vendorName : '$vendorName · $planName';
}

/// 探测结果的判定口径。**只允许在这里定义**，不许各处各判一套。
class TtsProbeOutcome {
  /// 这把 Key 是这家的（2xx，或 402/配额不足 —— 后者恰恰证明 Key 被接受了）。
  static const String hit = 'hit';

  /// 这家不认这把 Key（401/403）。
  static const String badKey = 'badKey';

  /// Key 形态对不上（如百度要 AK|SK 两段）。**不发请求**，省一次必败的调用。
  static const String wrongShape = 'wrongShape';

  /// 网络不通/超时。**不能**据此判断 Key 对不对。
  static const String unreachable = 'unreachable';

  /// 其它（404/400/429/5xx）。不猜，如实标成不确定。
  static const String unknown = 'unknown';

  static const List<String> all = [hit, badKey, wrongShape, unreachable, unknown];
}

class TtsProbeResult {
  final TtsProbeCandidate candidate;
  final String outcome;
  final int httpStatus; // 0 = 请求没发出去（网络不通 / 形态不符被跳过）
  final String detail;
  final List<String> models;

  const TtsProbeResult({
    required this.candidate,
    required this.outcome,
    this.httpStatus = 0,
    this.detail = '',
    this.models = const [],
  });

  bool get isHit => outcome == TtsProbeOutcome.hit;

  TtsProbeResult copyWith({String? outcome, int? httpStatus, String? detail, List<String>? models}) =>
      TtsProbeResult(
        candidate: candidate,
        outcome: outcome ?? this.outcome,
        httpStatus: httpStatus ?? this.httpStatus,
        detail: detail ?? this.detail,
        models: models ?? this.models,
      );
}

class TtsAutoPairRules {
  /// 探测用的正文。**必须极短**：这是一次要真扣费的调用，不是压测。
  static const String probeText = '好';

  /// 探测超时（秒）。比正式合成短 —— 配对是"对不对"的问题，不是"音质"的问题。
  static const int probeTimeoutSec = 12;

  /// 一次配对最多打多少个候选。防"某家端点挂了导致顺序探测一直往前推"。
  static const int maxAttempts = 48;

  /// 展开候选表：每家厂商 × 它登记的计费方案。
  ///
  /// 没登记 `plans` 的厂商只出一条（planId 为空）——
  /// 不要凭空造一条"默认方案"，否则保存时会把一个不存在的 planId 写进配置。
  static List<TtsProbeCandidate> candidates(List<TtsVendor> vendors, String key) {
    final out = <TtsProbeCandidate>[];
    for (final v in vendors) {
      // 自托管（无鉴权）不参与配对：没有 Key 可言，地址是用户自己填的。
      if (v.auth == TtsAuth.none) continue;
      if (key.trim().isEmpty) continue;
      final ps = v.plans.isEmpty ? const [null] : v.plans;
      for (final p in ps) {
        out.add(TtsProbeCandidate(
          vendorId: v.id,
          vendorName: v.name,
          planId: p?.id ?? '',
          planName: p?.name ?? '',
          url: p == null ? ttsEffectiveUrl(v, '') : ttsEffectiveUrl(v, p.id),
          keyHint: p != null && p.keyHint.isNotEmpty ? p.keyHint : v.keyHint,
        ));
      }
    }
    return out;
  }

  /// Key 形态问题（复用 tts_vendors 已有的登记，不另写一套）。
  /// 非空 = 这把 Key 打这家必败，直接跳过、不发请求。
  static String? shapeProblem(TtsVendor v, String planId, String key) {
    final hint = keyPlanMismatchHint(v, ttsPlanOf(v, planId), key);
    return hint.trim().isEmpty ? null : hint;
  }

  /// 把 HTTP 响应判成 [TtsProbeOutcome] 之一。
  ///
  /// ★ 判定顺序不能换：
  ///   先看 402/配额（它虽然不是 2xx，但**证明 Key 被接受了**），
  ///   再看 401/403（Key 被拒），最后才是"看不出来"。
  ///   反过来写（先判 4xx 一律 badKey）就会把没钱的 Key 判成无效。
  static String classify(int status, String body) {
    if (status <= 0) return TtsProbeOutcome.unreachable;
    if (status >= 200 && status < 300) return TtsProbeOutcome.hit;
    if (status == 401 || status == 403) return TtsProbeOutcome.badKey;

    // 402 / 配额 / 余额 —— Key 被接受了，只是没钱。这是一次成功配对。
    if (status == 402) return TtsProbeOutcome.hit;
    if (_quotaExhausted(body)) return TtsProbeOutcome.hit;

    // 402 之外的 4xx / 5xx：不足以判断 Key 对不对
    return TtsProbeOutcome.unknown;
  }

  /// "额度用尽 / 余额不足" 的中英文说法。命中即视为 Key 被接受。
  static bool _quotaExhausted(String body) {
    final b = body.toLowerCase();
    const words = [
      'insufficient',
      'quota',
      'balance',
      'credit',
      'out of',
      'exceeded',
      '余额不足',
      '额度',
      '欠费',
      '用尽',
      '用完',
      '不足',
    ];
    return words.any((w) => b.contains(w));
  }

  /// 从响应体里抠模型列表。抠不出来返回空表（**不猜**）。
  ///
  /// 兼容三种常见形态：
  ///   {"data":[{"id":"..."}, ...]}      （OpenAI 兼容）
  ///   {"models":[{"id/name":"..."}]}
  ///   ["m1","m2"]                        （裸数组）
  static List<String> extractModels(String body) {
    final s = body.trim();
    if (s.isEmpty || !s.startsWith('{') && !s.startsWith('[')) return const [];
    final out = <String>[];
    void take(Object? v) {
      if (v is String && v.trim().isNotEmpty) {
        out.add(v.trim());
      } else if (v is Map) {
        for (final k in const ['id', 'name', 'model', 'model_id']) {
          final x = v[k];
          if (x is String && x.trim().isNotEmpty) {
            out.add(x.trim());
            return;
          }
        }
      }
    }

    // 逐层找 data / models / result，找不到就试根节点。
    // 用递归而非自己写 JSON 解析：body 可能是任意嵌套，手工解析漏一种就静默丢。
    void walk(Object? node, int depth) {
      if (depth > 6) return;
      if (node is List) {
        for (final e in node) {
          take(e);
        }
        return;
      }
      if (node is Map) {
        for (final k in const ['data', 'models', 'result', 'list', 'items']) {
          final v = node[k];
          // ★ Map 也要往下走：{"result":{"data":[...]}} 这种"先包一层对象"的形态
          //   很常见，只认 List 的话会漏掉，表现是某家厂商的模型列表永远是空的。
          if (v is List) {
            walk(v, depth + 1);
            return;
          }
          if (v is Map) {
            walk(v, depth + 1);
            return;
          }
        }
        take(node);
      }
    }

    final decoded = _tryDecode(s);
    if (decoded == null) return const [];
    walk(decoded, 0);
    // 去重、保持顺序
    final seen = <String>{};
    return [for (final m in out) if (seen.add(m)) m];
  }

  static Object? _tryDecode(String s) {
    try {
      return _jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  /// 模型列表端点：由合成端点推出（同源 `/models`）。
  /// 推不出来返回 null —— 调用方就不拉，不影响配对本身。
  ///
  /// ★ 用 authority 拼，不用 `Uri.replace(query: '')`：后者会把空查询保留成
  /// 一个裸的 `?`，得到 `https://x/models?#` —— 多数服务端会 404，
  /// 表现是"模型列表永远拉不到"。
  static String? modelsUrlOf(String endpointUrl) {
    final u = Uri.tryParse(endpointUrl.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) return null;
    return '${u.scheme}://${u.authority}/models';
  }

  /// 同一家厂商只留最优的一条结果（命中优先，其次"不确定"）。
  /// 小米那种两套端点会出两条候选，用户只想看到"这家对了/没对"。
  static List<TtsProbeResult> dedupeByVendor(List<TtsProbeResult> rs) {
    final order = <String>[];
    final best = <String, TtsProbeResult>{};
    for (final r in rs) {
      final k = r.candidate.vendorId;
      if (!best.containsKey(k)) {
        order.add(k);
        best[k] = r;
        continue;
      }
      if (_rank(r) > _rank(best[k]!)) best[k] = r;
    }
    return [for (final k in order) best[k]!];
  }

  static int _rank(TtsProbeResult r) {
    switch (r.outcome) {
      case TtsProbeOutcome.hit:
        return 4;
      case TtsProbeOutcome.unknown:
        return 3;
      case TtsProbeOutcome.unreachable:
        return 2;
      case TtsProbeOutcome.wrongShape:
        return 1;
      default:
        return 0;
    }
  }

  /// 给用户看的结论。**命中就明确说命中**，不确定就说不确定，不许含糊。
  static String summary(List<TtsProbeResult> rs) {
    if (rs.isEmpty) return '没有可尝试的厂商';
    final hits = rs.where((r) => r.isHit).toList();
    if (hits.isNotEmpty) {
      final names = hits.map((r) => r.candidate.label).toSet().join('、');
      return '已配对：$names';
    }
    final shape = rs.where((r) => r.outcome == TtsProbeOutcome.wrongShape).toList();
    if (shape.length == rs.length) {
      return '这把 Key 的形态与所有厂商都对不上（有的要 AK|SK 两段、有的要 sk- 开头）';
    }
    final offline = rs.where((r) => r.outcome == TtsProbeOutcome.unreachable).length;
    if (offline == rs.length) {
      return '一个厂商都连不上，先确认网络再试';
    }
    final rejected = rs.where((r) => r.outcome == TtsProbeOutcome.badKey).length;
    return '没有匹配到厂商：$rejected 家明确拒绝了这把 Key'
        '${offline > 0 ? '，$offline 家连不上' : ''}'
        '${shape.length > 0 ? '，${shape.length} 家形态不符' : ''}';
  }

  /// 拉模型列表是**顺手补全**，失败绝不能影响配对结果本身。
  static bool modelsAreOptional(List<TtsProbeResult> rs) => true;
}

/// 解析失败返回 null —— 抠不出模型列表不影响配对本身，绝不能抛出去打断流程。
///
/// ★ 用 `dart:convert`，不手写 JSON 解析：响应体是任意嵌套的厂商自由格式，
/// 手工解析漏一种就是"某个厂商的模型列表静默为空"，而且没人会发现。
Object? _jsonDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}
