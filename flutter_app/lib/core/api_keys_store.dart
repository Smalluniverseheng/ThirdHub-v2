// 统一密钥库 —— 存储层（依赖 Flutter 的 SharedPreferences）
//
// 规则层在 `api_keys.dart`（零依赖、可被纯 Dart 自检逐条断言），本文件只负责
// 真正落盘。三层的关系：
//   统一库 `apikey_<规范id>`   ← 现在唯一会**写**的地方
//   旧 AI  `aikey_<providerId>` ← 只读兜底 + 被 migrate() 搬走
//   旧语音 `tts_key_<vendorId>` ← 只读兜底 + 被 migrate() 搬走
//
// 于是对用户而言：**以前填过的 Key 一个都不用重填**，而且从今往后
// 在任意模块填一次，别的模块直接就能用。

import 'package:shared_preferences/shared_preferences.dart';

import 'api_keys.dart';

/// 一次查找的结果：值 + 它存在哪个键里 + 属于哪一层。
class KeyHit {
  const KeyHit(this.key, this.storageKey, this.layer);

  final String key;
  final String storageKey;
  final String layer;

  bool get isEmpty => key.isEmpty;
  bool get isNotEmpty => key.isNotEmpty;

  /// 是否来自统一密钥库（UI 用它决定显示"密钥库"还是"AI 模块/语音模块"徽标）。
  bool get fromKeychain => layer == 'keychain';

  /// 给用户看的一句话来源，如「来自 AI 模块（已并入密钥库）」。
  String get sourceLabel {
    if (isEmpty) return '未填写';
    if (fromKeychain) return '来自密钥库';
    return '来自${ApiKeyKeys.layerLabel(layer)}（已自动并入）';
  }

  static const KeyHit none = KeyHit('', '', '');
}

class ApiKeys {
  const ApiKeys._();

  /// 统一库里的键名集合（读盘后过滤）。
  static const List<String> _prefixes = ['apikey_', 'aikey_', 'tts_key_'];

  /// 读一把 Key：按 `resolveOrder` 依次回落。
  static Future<KeyHit> find(String vendorId) async {
    final p = await SharedPreferences.getInstance();
    for (final k in ApiKeyKeys.resolveOrder(vendorId)) {
      final v = (p.getString(k) ?? '').trim();
      if (v.isNotEmpty) return KeyHit(v, k, ApiKeyKeys.layerOf(k));
    }
    return KeyHit.none;
  }

  /// 只要值（多数调用点用这个）。
  static Future<String> get(String vendorId) async =>
      (await find(vendorId)).key;

  /// **唯一会写的地方**：统一库。
  /// 传空串 = 删除该厂商的 Key（而不是写入空值 —— 否则回落链会被空串截断）。
  static Future<void> set(String vendorId, String key) async {
    final p = await SharedPreferences.getInstance();
    final k = ApiKeyKeys.main(vendorId);
    final v = key.trim();
    if (v.isEmpty) {
      await p.remove(k);
    } else {
      await p.setString(k, v);
    }
  }

  /// 把旧键（`aikey_` / `tts_key_`）搬进统一库。**同一规范 id 只搬一次**。
  ///
  /// 冲突处理：若统一库已有该厂商的值，**不覆盖**（以新库为准），
  /// 只把旧键留着（不删）—— 删除属于破坏性操作，让用户自己在密钥库页决定。
  /// 返回真正搬过去的条数。
  static Future<int> migrate() async {
    final p = await SharedPreferences.getInstance();
    var moved = 0;
    for (final raw in p.getKeys().toList()) {
      String? id;
      if (raw.startsWith('aikey_')) {
        id = raw.substring('aikey_'.length);
      } else if (raw.startsWith('tts_key_')) {
        id = raw.substring('tts_key_'.length);
      }
      if (id == null || id.isEmpty) continue;
      final v = (p.getString(raw) ?? '').trim();
      if (v.isEmpty) continue;
      final main = ApiKeyKeys.main(id);
      if (main == raw) continue;
      final exist = (p.getString(main) ?? '').trim();
      if (exist.isNotEmpty) continue; // 已有更新的值，不动
      await p.setString(main, v);
      moved++;
    }
    return moved;
  }

  /// 读出**所有**已填过的厂商（三层合并，统一库优先）。
  /// 供「密钥库」页面展示。
  static Future<Map<String, KeyHit>> dump() async {
    final p = await SharedPreferences.getInstance();
    // 先收集出现过的厂商 id（保留原始写法，用于展示）
    final ids = <String, String>{}; // 规范id → 展示用原始id
    for (final raw in p.getKeys()) {
      if (!_prefixes.any(raw.startsWith)) continue;
      final id = _strip(raw);
      if (id.isEmpty) continue;
      final c = KeyVendor.canonical(id);
      if (c.isEmpty) continue;
      ids.putIfAbsent(c, () => id);
    }
    final out = <String, KeyHit>{};
    for (final c in ids.keys) {
      final h = await find(c);
      if (h.isNotEmpty) out[c] = h;
    }
    return out;
  }

  static String _strip(String raw) {
    for (final pre in _prefixes) {
      if (raw.startsWith(pre)) return raw.substring(pre.length);
    }
    return '';
  }

  /// 统一库里的原始条数（不合并、不含回落）—— 自检与"密钥库"页头用它。
  static Future<int> keychainCount() async {
    final p = await SharedPreferences.getInstance();
    return p
        .getKeys()
        .where((k) =>
            k.startsWith('apikey_') && (p.getString(k) ?? '').trim().isNotEmpty)
        .length;
  }
}
