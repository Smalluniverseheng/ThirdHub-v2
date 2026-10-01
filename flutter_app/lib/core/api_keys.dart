// 统一密钥库 —— **零 Flutter 依赖**的规则层
//
// 用户诉求：「很多 AI 厂商的 TTS 模型和 API 密钥是通用的 …… 在 AI 模块输入的
// Key，TTS 模块也能用，不用重复输入。你也要弄好一点，做好各个厂商的登记。」
//
// 现状（2026-10-01 核实，不是印象）：
//   · AI 模块的 Key 存在 `aikey_<providerId>`     （`ai.dart:136/138`）
//   · 语音模块的 Key 存在 `tts_key_<vendorId>`    （`tts_online.dart:73`）
//   两套键、两套厂商标识 —— 同一家公司的同一把 Key 要填两遍，
//   而且两边对同一家公司的**叫法还不一样**（AI 叫 aliyun，语音叫 dashscope）。
//
// 本层只放**规则**：厂商归一化 / 键名规则 / 回落顺序 / 通用性登记。
// 实际读写放在 `api_keys_store.dart`（依赖 SharedPreferences）——
// 与 `cover_spec.dart` ↔ `ui_cover.dart` 同一手法：
// 规则层零依赖 → 纯 Dart 自检可以逐条断言；实现层依赖 Flutter → 只做字符串断言。

/// 密钥的用途。同一把 Key 可能覆盖其中多个。
class KeyUse {
  const KeyUse._();
  static const String llm = 'llm'; // 对话 / 文本
  static const String tts = 'tts'; // 语音合成
  static const String image = 'image'; // 绘图
  static const String search = 'search'; // 联网搜索

  static const List<String> all = [llm, tts, image, search];

  static String label(String use) {
    switch (use) {
      case llm:
        return '对话';
      case tts:
        return '语音';
      case image:
        return '绘图';
      case search:
        return '搜索';
    }
    return use;
  }
}

/// 厂商归一化。
class KeyVendor {
  const KeyVendor._();

  /// 别名表：**键是规范 id，值是可以归一过来的其它叫法**。
  ///
  /// 为什么必须要有它：AI 模块的 providerId 与语音模块的 vendorId 是两套命名
  /// （2026-10-01 实测：AI 35 家 / 语音 32 家，其中 **10 家同名可直接复用**，
  ///  但 **2 家同公司不同名** —— 不归一，"通用 Key 复用"就无从谈起）：
  ///   · AI `aliyun`   ↔ 语音 `dashscope`（阿里云百炼 = 通义 = dashscope）
  ///   · AI `bytedance` ↔ 语音 `volc`（火山引擎 = 字节）
  static const Map<String, List<String>> aliases = {
    'aliyun': ['dashscope', 'qwen', 'tongyi', 'bailian'],
    'bytedance': ['volc', 'volcengine', 'doubao', 'huoshan'],
    'xiaomi': ['mimo', 'xiaomimimo'],
    'zhipu': ['glm', 'bigmodel', 'zhipuai'],
    'moonshot': ['kimi'],
    'baidu': ['wenxin', 'qianfan'],
    'tencent': ['hunyuan', 'tencentcloud'],
    'minimax': ['hailuo'],
    'openai': ['azure-openai'],
  };

  /// 规范 id：命中别名返回规范值，否则返回**小写去空白**的原值。
  /// 未知厂商**不抛异常、也不丢弃** —— 直接原样小写返回（界面不能因为
  /// 来了个没登记的厂商就崩或把它藏起来）。
  static String canonical(String id) {
    final k = id.trim().toLowerCase();
    if (k.isEmpty) return '';
    for (final e in aliases.entries) {
      if (e.key == k) return e.key;
      if (e.value.contains(k)) return e.key;
    }
    return k;
  }

  /// 两个 id 是否同一家厂商（AI 的 `aliyun` 与语音的 `dashscope` → true）。
  static bool same(String a, String b) {
    final ca = canonical(a);
    return ca.isNotEmpty && ca == canonical(b);
  }

  /// 该厂商的所有已知叫法（含规范 id 自身），用于 UI 显示"也叫 …"。
  static List<String> allNames(String id) {
    final c = canonical(id);
    if (c.isEmpty) return const [];
    return [c, ...?aliases[c]];
  }
}

/// ★ 通用性登记：**哪些厂商的 Key 真能跨用途共用**。
///
/// 这一层不能想当然 —— 同名不等于通用：
///   · 多数厂商（OpenAI / 智谱 / 硅基流动 / MiniMax / 小米…）一把 Key 覆盖全部产品线；
///   · 但**百度**的「文心」与「语音技术」是**两个独立应用**，Key 各发各的；
///   · **阿里云**的 DashScope 与部分语音服务也分属不同控制台产品。
/// 所以默认 `true`（通用），对确知要分开的厂商显式登记 `false`。
/// UI 会据此把"从密钥库带出"的提示改成"该厂商各用途需要各自的 Key"。
class KeySharing {
  const KeySharing._();

  /// false = 该厂商的各用途**各要一把 Key**，不要跨模块自动带出。
  static const Map<String, bool> notShared = {
    'baidu': true,
    'azure': true,
  };

  static bool isShared(String vendorId) =>
      !(notShared[KeyVendor.canonical(vendorId)] ?? false);
}

/// 键名规则与读取回落顺序。
class ApiKeyKeys {
  const ApiKeyKeys._();

  /// 统一库主键（4.60.0 起的新位置）。
  static String main(String vendorId) =>
      'apikey_${KeyVendor.canonical(vendorId)}';

  /// 旧键：AI 模块（`ai.dart`）。**只保留读**，老用户不必重填。
  static String legacyLlm(String providerId) => 'aikey_$providerId';

  /// 旧键：语音模块（`tts_online.dart`）。**只保留读**。
  static String legacyTts(String vendorId) => 'tts_key_$vendorId';

  /// 读一把 Key 时的回落顺序：**统一库 → 旧 AI → 旧语音**。
  ///
  /// 顺序有讲究：统一库优先（它会是最新的），两个旧键兜底 ——
  /// 于是「用户以前在 AI 模块填过小米 Key」这件事，语音模块能直接受益，
  /// 而用户**不需要重新填一遍**（这是本诉求的核心体验）。
  ///
  /// 传入的 id **同时**用于生成两个旧键：因为 AI 的 providerId 与语音的
  /// vendorId 在归一化之后往往就是同一个串，`aikey_` / `tts_key_` 前缀
  /// 天然把它们分开了，不会串味。
  static List<String> resolveOrder(String id) => [
        main(id),
        legacyLlm(id),
        legacyTts(id),
      ];

  /// 判断一个真实键名属于哪一层（UI 用它显示 Key 的来源徽标）。
  static String layerOf(String storageKey) {
    if (storageKey.startsWith('apikey_')) return 'keychain';
    if (storageKey.startsWith('aikey_')) return 'ai';
    if (storageKey.startsWith('tts_key_')) return 'tts';
    return 'unknown';
  }

  static String layerLabel(String layer) {
    switch (layer) {
      case 'keychain':
        return '密钥库';
      case 'ai':
        return 'AI 模块';
      case 'tts':
        return '语音模块';
    }
    return '未知来源';
  }
}

/// 掩码显示：只留头尾，中间打点。空串返回空串。
///
/// 注意：Dart 的 String **没有** `*` 运算符（那是 Python），必须用
/// `List.filled(n, '*').join()`。取首字符用 `substring` 而非 `[0]` ——
/// 下标切片会把代理对切成半个字符。
String maskKey(String key) {
  final k = key.trim();
  if (k.isEmpty) return '';
  if (k.length <= 8) {
    return k.substring(0, 1) + List.filled(k.length - 1, '*').join();
  }
  return k.substring(0, 4) +
      List.filled(6, '*').join() +
      k.substring(k.length - 4);
}
