// 统一密钥库自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   cd flutter_app
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/api_keys_selfcheck.dart
//
// 用户诉求：「很多 AI 厂商的 TTS 模型和 API 密钥是通用的 …… 在 AI 模块输入的
// Key，TTS 模块也能用，不用重复输入。做好各个厂商的登记。」
//
// 这件事最容易出的**两类事故**，本闸门就是为它们而写：
//   ① **该合的没合** → 用户明明填过小米 Key，语音里还得再填一遍（诉求落空）；
//   ② **不该合的合了** → 两家不同公司的 Key 被当成一家（`canonical` 映射写错），
//      后果是 A 公司的请求被拿 B 公司的 Key 去发 —— 401 还是一回事，
//      **把 A 的凭据泄露给 B 的端点**才是真事故，而且静默、难发现。
//   所以 ② 的守卫（别名无交叉 + 反向断言）比 ① 更重。
//
// ★ 本文件不 import `api_keys_store.dart`：那个文件 import
//   `shared_preferences` → 依赖 Flutter 插件通道，纯 Dart VM 下跑不了。
//   规则层拆在零依赖的 `api_keys.dart` 里，这里逐条断言。
import 'dart:io';

import '../lib/core/api_keys.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('  ok   $name');
  } else {
    fail++;
    print('  FAIL $name${extra.isEmpty ? '' : '  [$extra]'}');
  }
}

/// 2026-10-01 实测的两侧 id 清单（AI 35 家 / 语音 32 家）。
/// 写进自检是为了给"厂商登记"一个**可核对的基准** ——
/// 两边清单变化时会显式暴露"哪些厂商的 Key 现在能通用了"。
const aiIds = [
  'opencode-zen', 'openai', 'anthropic', 'google', 'xai', 'deepseek', 'xiaomi',
  'aliyun', 'tencent', 'baidu', 'bytedance', 'moonshot', 'zhipu', 'yi',
  'sensechat', 'minimax', 'siliconflow', 'baichuan', 'stepfun', 'spark',
  'tiangong', 'qihoo', 'mistral', 'cohere', 'perplexity', 'groq', 'together',
  'fireworks', 'replicate', 'stability', 'midjourney', 'openrouter', 'azure',
  'nvidia', 'cloudflare',
];

const ttsIds = [
  'xiaomi', 'siliconflow', 'zhipu', 'stepfun', 'minimax', 'dashscope', 'volc',
  'baidu', 'openai', 'groq', 'openrouter', 'deepgram', 'elevenlabs', 'cartesia',
  'fishaudio', 'azure', 'resemble', 'speechify', 'murf', 'kokoro', 'gpt-sovits',
  'fish-speech', 'openai-edge-tts', 'localai', 'alltalk', 'speaches', 'piper',
  'chattts',
];

void main() {
  // ═══════════════════════════════════════════════════════════════
  // 1. 厂商归一化
  // ═══════════════════════════════════════════════════════════════
  print('== 1. 厂商归一化 ==');
  ck('AI 的 aliyun 与语音的 dashscope 归一为同一家',
      KeyVendor.canonical('aliyun') == KeyVendor.canonical('dashscope'),
      '${KeyVendor.canonical('aliyun')} vs ${KeyVendor.canonical('dashscope')}');
  ck('AI 的 bytedance 与语音的 volc 归一为同一家',
      KeyVendor.canonical('bytedance') == KeyVendor.canonical('volc'),
      '${KeyVendor.canonical('bytedance')} vs ${KeyVendor.canonical('volc')}');
  ck('归一结果取规范 id（aliyun/dashscope → aliyun）',
      KeyVendor.canonical('dashscope') == 'aliyun' &&
          KeyVendor.canonical('aliyun') == 'aliyun');
  ck('大小写与空白不敏感',
      KeyVendor.canonical(' AliYun ') == 'aliyun' &&
          KeyVendor.canonical('DASHSCOPE') == 'aliyun');
  ck('空串归一为空串（不抛异常）', KeyVendor.canonical('') == '');
  ck('未知厂商原样小写返回（**不丢弃、不抛异常**）',
      KeyVendor.canonical('SomeNewVendor') == 'somenewvendor',
      KeyVendor.canonical('SomeNewVendor'));
  ck('same() 对同公司不同名返回 true',
      KeyVendor.same('aliyun', 'dashscope') &&
          KeyVendor.same('volc', 'bytedance') &&
          KeyVendor.same('kimi', 'moonshot'));
  ck('same() 对不同公司返回 false（小米 ≠ 智谱）',
      !KeyVendor.same('xiaomi', 'zhipu'));
  ck('same() 对空串返回 false（不能把"没填"当成"同一家"）',
      !KeyVendor.same('', '') && !KeyVendor.same('x', ''));
  ck('allNames 含规范 id 与全部别名',
      KeyVendor.allNames('dashscope').contains('aliyun') &&
          KeyVendor.allNames('dashscope').contains('dashscope'));
  ck('allNames 对空串返回空表', KeyVendor.allNames('').isEmpty);

  // ═══════════════════════════════════════════════════════════════
  // 2. ★ 别名无交叉（防"两家不同公司被并成一家"）
  //    这一条比"该合的没合"更要紧：合错了会把 A 的凭据发给 B 的端点。
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 2. ★ 别名无交叉（防误并）==');
  final owner = <String, String>{};
  var dup = <String>[];
  for (final e in KeyVendor.aliases.entries) {
    for (final n in [e.key, ...e.value]) {
      final pre = owner[n];
      if (pre != null && pre != e.key) dup.add('$n → $pre/$e.key');
      owner[n] = e.key;
    }
  }
  ck('★ 任一叫法只属于一个规范 id（无交叉别名）', dup.isEmpty, dup.join(' , '));
  ck('规范 id 自己不会被登记成别人的别名',
      KeyVendor.aliases.keys.every((k) => owner[k] == k));

  // 反向断言：已知的**不同**公司绝不能被归一到一起。
  const mustDiffer = [
    ['openai', 'azure'],
    ['xiaomi', 'zhipu'],
    ['deepseek', 'minimax'],
    ['zhipu', 'siliconflow'],
    ['aliyun', 'tencent'],
    ['bytedance', 'baidu'],
  ];
  for (final pair in mustDiffer) {
    ck('★ ${pair[0]} 与 ${pair[1]} 必须仍是两家（不被别名误并）',
        !KeyVendor.same(pair[0], pair[1]));
  }

  // ═══════════════════════════════════════════════════════════════
  // 3. 通用性登记（同名 ≠ Key 通用）
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 3. 通用性登记 ==');
  ck('小米的 Key 在 AI 与语音间通用（用户的直接诉求）',
      KeySharing.isShared('xiaomi'));
  ck('百度的各用途不通用（文心与语音技术是两个独立应用）',
      !KeySharing.isShared('baidu'));
  ck('未登记的厂商默认通用（保守展开，但不误报"要两把"）',
      KeySharing.isShared('some-new-vendor'));
  ck('通用性登记按**规范 id**判断（用别名问也一样）',
      !KeySharing.isShared('dashscope') == !KeySharing.isShared('aliyun'));

  // ═══════════════════════════════════════════════════════════════
  // 4. 键名规则与回落顺序
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 4. 键名与回落 ==');
  ck('★ 同一家公司的两种叫法落到**同一个主键**（复用的机械保障）',
      ApiKeyKeys.main('dashscope') == ApiKeyKeys.main('aliyun') &&
          ApiKeyKeys.main('aliyun') == 'apikey_aliyun',
      ApiKeyKeys.main('dashscope'));
  ck('主键带 apikey_ 前缀', ApiKeyKeys.main('xiaomi') == 'apikey_xiaomi');
  ck('旧 AI 键名不变（老数据仍可读）',
      ApiKeyKeys.legacyLlm('xiaomi') == 'aikey_xiaomi');
  ck('旧语音键名不变（老数据仍可读）',
      ApiKeyKeys.legacyTts('xiaomi') == 'tts_key_xiaomi');
  ck('★ 回落顺序 = 密钥库 → 旧AI → 旧语音',
      ApiKeyKeys.resolveOrder('xiaomi').join(',') ==
          'apikey_xiaomi,aikey_xiaomi,tts_key_xiaomi',
      ApiKeyKeys.resolveOrder('xiaomi').join(','));
  ck('回落链无重复项',
      ApiKeyKeys.resolveOrder('zhipu').toSet().length ==
          ApiKeyKeys.resolveOrder('zhipu').length);
  ck('layerOf 正确识别三层',
      ApiKeyKeys.layerOf('apikey_x') == 'keychain' &&
          ApiKeyKeys.layerOf('aikey_x') == 'ai' &&
          ApiKeyKeys.layerOf('tts_key_x') == 'tts' &&
          ApiKeyKeys.layerOf('other') == 'unknown');
  ck('layerLabel 每种来源都有人话',
      ['keychain', 'ai', 'tts'].every((l) =>
          ApiKeyKeys.layerLabel(l).isNotEmpty && ApiKeyKeys.layerLabel(l) != l));

  // ═══════════════════════════════════════════════════════════════
  // 5. ★ 两侧 id 清单交叉核对（"厂商登记"的可核对基准）
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 5. 两侧 id 交叉核对 ==');
  final aiCanon = aiIds.map(KeyVendor.canonical).toSet();
  final ttsCanon = ttsIds.map(KeyVendor.canonical).toSet();
  final shared = aiCanon.intersection(ttsCanon).toList()..sort();
  print('  归一后 Key 可复用的厂商（${shared.length} 家）: ${shared.join(' ')}');

  ck('两家清单都非空（防清单被误删空）',
      aiIds.isNotEmpty && ttsIds.isNotEmpty, '${aiIds.length}/${ttsIds.length}');
  ck('★ 归一后交集不少于 10 家（"Key 可复用"不能只是纸面承诺）',
      shared.length >= 10, '${shared.length}');
  // 逐家点名：这几家是**用户最可能用到**的，缺任何一家都要红。
  for (final must in [
    'xiaomi', 'siliconflow', 'zhipu', 'minimax', 'openai', 'groq',
    'openrouter', 'azure', 'baidu', 'stepfun',
  ]) {
    ck('跨模块可复用：$must', shared.contains(must));
  }
  ck('★ 别名生效：AI 的 aliyun 与语音的 dashscope 对上了',
      shared.contains('aliyun'));
  ck('★ 别名生效：AI 的 bytedance 与语音的 volc 对上了',
      shared.contains('bytedance'));
  ck('语音独有的厂商不会被 AI 的清单吞掉',
      ttsCanon.contains('elevenlabs') && ttsCanon.contains('fishaudio'));

  // ═══════════════════════════════════════════════════════════════
  // 6. 掩码
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 6. 掩码 ==');
  ck('空串 → 空串（不产生乱码占位）', maskKey('').isEmpty);
  ck('短串只露首字符', maskKey('abc') == 'a**', maskKey('abc'));
  ck('长串露头尾各 4 位',
      maskKey('sk-1234567890') == 'sk-1******7890', maskKey('sk-1234567890'));
  ck('掩码不把整串原样带出', maskKey('sk-1234567890') != 'sk-1234567890');
  final m = maskKey('sk-1234567890');
  ck('掩码隐藏了中段字符', !m.contains('234567'));

  // ═══════════════════════════════════════════════════════════════
  // 7. 用途标签
  // ═══════════════════════════════════════════════════════════════
  print('');
  print('== 7. 用途标签 ==');
  ck('用途列表非空且无重复',
      KeyUse.all.isNotEmpty && KeyUse.all.toSet().length == KeyUse.all.length);
  ck('每种用途都有人话标签',
      KeyUse.all.every((u) => KeyUse.label(u).isNotEmpty && KeyUse.label(u) != u));
  ck('含对话与语音两类（本诉求的两端）',
      KeyUse.all.contains(KeyUse.llm) && KeyUse.all.contains(KeyUse.tts));

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail > 0) exit(1);
}
