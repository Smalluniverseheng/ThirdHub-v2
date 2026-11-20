// AI 厂商能力记忆（图片 / 视频 / 工具调用 / 思考链）
//
// 用户原话：「根据各家厂商不同的 AI 模型做好适配……识别不出来就默认都开启，
// 所有权限都给它，当发送图片失败了之后才关掉；下次再点发送图片的时候提醒他，
// 但**不强制不允许**他发送 —— 即使这个模型没这个功能也行，提醒他自己判断」。
//
// 所以这个类的语义必须精确：
//   · 默认全 true（不认识 = 假设能），绝不预先拦人；
//   · 只有**真的发失败**才写一条降级记录；
//   · 降级记录只用来"下一次提醒一句"，永远不返回"禁止发送"。
//
// 为什么不用写死的能力表：同一个模型放在不同中转站上，能力经常不一样
// （官方不支持看图，中转站自己接了 OCR 也能用）。预判必然错，实测才准。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AiCaps {
  const AiCaps._();

  static const String visionKey = 'vision';
  static const String videoKey = 'video';

  static const String _storeKey = 'ai_caps_v1';

  static String _id(String providerId, String model) => '$providerId|$model';

  static Future<Map<String, dynamic>> _all() async {
    final p = await SharedPreferences.getInstance();
    try {
      final raw = p.getString(_storeKey);
      if (raw == null || raw.isEmpty) return {};
      final v = jsonDecode(raw);
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (_) {
      return {};
    }
  }

  /// 是否认为支持某个能力。**没有记录就是支持** —— 这是本类最重要的一条。
  static Future<bool> supports(String providerId, String model, String cap) async {
    final all = await _all();
    final rec = all[_id(providerId, model)];
    if (rec is! Map) return true;
    final c = rec[cap];
    if (c is! Map) return true;
    return c['ok'] != false;
  }

  /// 上次失败的原因（给提醒文案用）。没失败过返回 null。
  static Future<String?> lastFail(String providerId, String model, String cap) async {
    final all = await _all();
    final rec = all[_id(providerId, model)];
    if (rec is! Map) return null;
    final c = rec[cap];
    if (c is! Map || c['ok'] != false) return null;
    final why = '${c['reason'] ?? ''}'.trim();
    return why.isEmpty ? '上次没成功' : why;
  }

  /// 记一次失败（只记录，不封禁）。
  static Future<void> markFail(String providerId, String model, String cap, String reason) async {
    final all = await _all();
    final id = _id(providerId, model);
    final rec = Map<String, dynamic>.from((all[id] is Map) ? all[id] as Map : {});
    rec[cap] = {
      'ok': false,
      'reason': reason.length > 160 ? '${reason.substring(0, 160)}…' : reason,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    all[id] = rec;
    await _save(all);
  }

  /// 记一次成功：把该能力的降级标记清掉（用户换了个好用的中转站就该恢复）
  static Future<void> markOk(String providerId, String model, String cap) async {
    final all = await _all();
    final id = _id(providerId, model);
    final raw = all[id];
    if (raw is! Map) return;
    final rec = Map<String, dynamic>.from(raw);
    if (!rec.containsKey(cap)) return;
    rec.remove(cap);
    if (rec.isEmpty) {
      all.remove(id);
    } else {
      all[id] = rec;
    }
    await _save(all);
  }

  /// 失败信息算不算"这模型不吃这种输入"（而不是网络问题/额度问题）。
  ///
  /// 判断得保守一点：只有明确指向输入形状的错误才降级，
  /// 网络超时/401/429 都不该被记成"不支持看图" —— 否则用户下次会看到
  /// 一条与事实无关的提醒，反而更迷惑。
  static bool looksLikeUnsupported(String err, String cap) {
    final e = err.toLowerCase();
    if (e.contains('timeout') || e.contains('超时')) return false;
    if (e.contains('401') || e.contains('403') || e.contains('429')) return false;
    if (e.contains('insufficient') || e.contains('balance') || e.contains('quota')) return false;
    final words = <String>[
      'image', 'vision', 'multimodal', 'modal', 'content type', 'unsupported',
      'not support', 'does not support', 'invalid_request', 'invalid content',
      '不支持', '无法处理', '格式', '图片',
    ];
    for (final w in words) {
      if (e.contains(w)) return true;
    }
    return false;
  }

  /// 只在本机用，不做跨端同步：不同设备连的可能是不同中转站。
  static Future<void> _save(Map<String, dynamic> all) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_storeKey, jsonEncode(all));
  }
}
