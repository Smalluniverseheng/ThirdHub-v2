// 语音引擎「一键自动配对」自检 —— 纯 Dart，零 Flutter 依赖。
//
// 这道闸门盯的是**判定规则**，不是网络。分类写错的表现是"把对的 Key 判成错的"，
// 用户会去重新申请 Key、排查半天，而 Key 其实没错。所以：
//   · 402 / 配额不足 必须算命中（它恰恰证明 Key 被接受了）
//   · 401 必须优先于 body 里的"余额不足"（不然一个被拒的 Key 会被判成命中）
//   · 抠不出模型列表要返回空表，不许猜
//   · 候选表展开不能凭空造 planId（存进去会指向一个不存在的计费方案）
//   · 命中即停 + 探测正文极短（这是要真扣费的调用）
//
// 真实端点的验证需要真 Key，本机没有凭证 —— 那部分只能在有 Key 的设备上跑，
// 这里不假装覆盖。

import 'dart:io';

import '../lib/core/tts_autopair.dart';
import '../lib/core/tts_vendors.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name${extra.isEmpty ? '' : '  -> $extra'}');
  }
}

String read(String rel) {
  final p = File(Platform.script.toFilePath()).parent.path.replaceAll('\\', '/');
  final f = File('$p/$rel');
  return f.existsSync() ? f.readAsStringSync() : '';
}

TtsVendor vOf({
  String id = 'demo',
  String name = '演示厂商',
  TtsAuth auth = TtsAuth.bearer,
  List<TtsPlan> plans = const [],
  String url = 'https://api.demo.com/v1/tts',
}) =>
    TtsVendor(
      id: id,
      name: name,
      group: '国内',
      note: '',
      url: url,
      method: 'POST',
      auth: auth,
      bodyTpl: '{"input":"{text}"}',
      audioPath: 'data.audio',
      encoding: 'base64',
      keyHint: 'sk- 开头',
      plans: plans,
    );

void main() {
  print('=== 语音引擎自动配对自检 ===\n');

  // ═══════════════════════════════════════════════════════════
  // 1. 候选表展开
  // ═══════════════════════════════════════════════════════════
  print('== 1. 候选表 ==');
  final vs = [
    vOf(id: 'a', name: '甲'),
    vOf(id: 'b', name: '乙', plans: const [
      TtsPlan(id: 'metered', name: '按量', url: 'https://m.demo.com/tts'),
      TtsPlan(id: 'member', name: '会员套餐', url: 'https://p.demo.com/tts'),
    ]),
    vOf(id: 'c', name: '丙', auth: TtsAuth.none),
  ];
  final cands = TtsAutoPairRules.candidates(vs, 'sk-test');
  ck('无 plans 的厂商只出 1 条', cands.where((c) => c.vendorId == 'a').length == 1);
  ck('无 plans 的厂商 planId 为空（不凭空造方案）',
      cands.firstWhere((c) => c.vendorId == 'a').planId.isEmpty);
  ck('有 2 套方案的厂商出 2 条', cands.where((c) => c.vendorId == 'b').length == 2);
  ck(
      '两条候选地址各按方案解析',
      cands.firstWhere((c) => c.planId == 'member').url == 'https://p.demo.com/tts',
      cands.firstWhere((c) => c.planId == 'member').url);
  ck('自托管（无鉴权）不参与配对', !cands.any((c) => c.vendorId == 'c'));
  ck('空 Key 不产出候选', TtsAutoPairRules.candidates(vs, '   ').isEmpty);
  ck(
      '候选 label 带方案名（用户看得出试到哪套了）',
      cands.firstWhere((c) => c.planId == 'member').label == '乙 · 会员套餐',
      cands.firstWhere((c) => c.planId == 'member').label);

  // ═══════════════════════════════════════════════════════════
  // 2. 响应分类（★ 本轮最容易写反的地方）
  // ═══════════════════════════════════════════════════════════
  print('== 2. 响应分类 ==');
  String cls(int s, [String b = '']) => TtsAutoPairRules.classify(s, b);
  ck('2xx → 命中', cls(200) == TtsProbeOutcome.hit && cls(299) == TtsProbeOutcome.hit);
  ck('401 → 不认这把 Key', cls(401) == TtsProbeOutcome.badKey);
  ck('403 → 不认这把 Key', cls(403) == TtsProbeOutcome.badKey);
  ck('★402 → 命中（余额不足恰恰证明 Key 被接受了）', cls(402) == TtsProbeOutcome.hit,
      cls(402));
  ck('★429 + 额度用尽 → 命中', cls(429, 'quota exceeded') == TtsProbeOutcome.hit,
      cls(429, 'quota exceeded'));
  ck('★中文「余额不足」→ 命中', cls(402, '余额不足') == TtsProbeOutcome.hit);
  ck('★中文「额度已用完」→ 命中', cls(400, '您的免费额度已用完') == TtsProbeOutcome.hit,
      cls(400, '您的免费额度已用完'));
  ck('网络不通(0) → unreachable', cls(0) == TtsProbeOutcome.unreachable);
  ck('404 → unknown（不猜 Key 对不对）', cls(404) == TtsProbeOutcome.unknown);
  ck('500 → unknown', cls(500) == TtsProbeOutcome.unknown);
  ck('400 无关键词 → unknown', cls(400, 'bad request') == TtsProbeOutcome.unknown);
  ck(
      '★401 即使 body 提到余额不足仍是 badKey（401 优先，body 不许翻案）',
      cls(401, 'insufficient balance') == TtsProbeOutcome.badKey,
      cls(401, 'insufficient balance'));
  ck('判定口径只有 5 种', TtsProbeOutcome.all.length == 5);

  // ═══════════════════════════════════════════════════════════
  // 3. 模型列表抽取
  // ═══════════════════════════════════════════════════════════
  print('== 3. 模型列表 ==');
  final m1 = TtsAutoPairRules.extractModels('{"data":[{"id":"tts-1"},{"id":"tts-2"}]}');
  ck('OpenAI 形态 {data:[{id}]}', m1.length == 2 && m1.first == 'tts-1', '$m1');
  final m2 = TtsAutoPairRules.extractModels('{"models":[{"name":"alloy"}]}');
  ck('{models:[{name}]}', m2.length == 1 && m2.first == 'alloy', '$m2');
  final m3 = TtsAutoPairRules.extractModels('["m1","m2","m1"]');
  ck('裸数组 + 去重保序', m3.length == 2 && m3.join() == 'm1m2', '$m3');
  ck('非 JSON 返回空表（不猜）', TtsAutoPairRules.extractModels('not json').isEmpty);
  ck('空串返回空表', TtsAutoPairRules.extractModels('').isEmpty);
  ck('深层嵌套也能找到',
      TtsAutoPairRules.extractModels('{"result":{"data":[{"id":"deep"}]}}').contains('deep'));
  ck('没有 id/name 的对象不硬凑', TtsAutoPairRules.extractModels('{"data":[{"x":1}]}').isEmpty);

  ck(
      '模型端点与合成端点同源',
      TtsAutoPairRules.modelsUrlOf('https://api.demo.com/v1/tts') ==
          'https://api.demo.com/models',
      '${TtsAutoPairRules.modelsUrlOf('https://api.demo.com/v1/tts')}');
  ck('非法地址返回 null（调用方就不拉，不影响配对）',
      TtsAutoPairRules.modelsUrlOf('') == null &&
          TtsAutoPairRules.modelsUrlOf('not a url') == null);

  // ═══════════════════════════════════════════════════════════
  // 4. 去重与结论
  // ═══════════════════════════════════════════════════════════
  print('== 4. 去重与结论 ==');
  TtsProbeResult res(String vid, String plan, String outcome) => TtsProbeResult(
      candidate: TtsProbeCandidate(
          vendorId: vid, vendorName: vid, planId: plan, planName: plan, url: 'https://x/y'),
      outcome: outcome);
  final dup = TtsAutoPairRules.dedupeByVendor([
    res('mi', 'metered', TtsProbeOutcome.badKey),
    res('mi', 'member', TtsProbeOutcome.hit),
    res('oai', '', TtsProbeOutcome.unknown),
  ]);
  ck('同厂商只留一条', dup.length == 2, '${dup.length}');
  ck('同厂商留命中那条（不是先到先得）',
      dup.first.outcome == TtsProbeOutcome.hit &&
          dup.first.candidate.planId == 'member');
  ck('保持首次出现的厂商顺序', dup.map((r) => r.candidate.vendorId).join() == 'mioai',
      dup.map((r) => r.candidate.vendorId).join());

  ck('结论：命中就明说',
      TtsAutoPairRules.summary([res('a', '', TtsProbeOutcome.hit)]).contains('已配对'));
  ck(
      '结论：全被拒说得清',
      TtsAutoPairRules.summary([
        res('a', '', TtsProbeOutcome.badKey),
        res('b', '', TtsProbeOutcome.badKey)
      ]).contains('明确拒绝'),
      TtsAutoPairRules.summary([
        res('a', '', TtsProbeOutcome.badKey),
        res('b', '', TtsProbeOutcome.badKey)
      ]));
  ck('结论：全连不上提示先查网络',
      TtsAutoPairRules.summary([
        res('a', '', TtsProbeOutcome.unreachable),
        res('b', '', TtsProbeOutcome.unreachable)
      ]).contains('连不上'));
  ck('结论：空结果不报错', TtsAutoPairRules.summary(const []).isNotEmpty);
  ck('拉模型列表是可选的（失败不影响配对）', TtsAutoPairRules.modelsAreOptional(const []));

  // ═══════════════════════════════════════════════════════════
  // 5. 成本护栏（这是要真扣费的调用）
  // ═══════════════════════════════════════════════════════════
  print('== 5. 成本护栏 ==');
  ck('探测正文极短（不是拿一篇课文去试）', TtsAutoPairRules.probeText.trim().length <= 2,
      '"${TtsAutoPairRules.probeText}"');
  ck('探测超时比正式合成短', TtsAutoPairRules.probeTimeoutSec <= 15,
      '${TtsAutoPairRules.probeTimeoutSec}s');
  ck('单次配对有尝试上限',
      TtsAutoPairRules.maxAttempts > 0 && TtsAutoPairRules.maxAttempts <= 64,
      '${TtsAutoPairRules.maxAttempts}');

  // ═══════════════════════════════════════════════════════════
  // 6. 形态预检（复用已有登记，不另写一套）
  // ═══════════════════════════════════════════════════════════
  print('== 6. 形态预检 ==');
  // 声明了 keyPrefixes 的方案才做形态检查（与 keyPlanMismatchHint 同一口径）
  final strict = vOf(id: 'strict', name: '两段式', plans: const [
    TtsPlan(id: 'aksk', name: 'AK|SK 两段', keyHint: 'AK|SK', keyPrefixes: ['ak-'])
  ]);
  ck(
      '形态不符会给出原因（且不发请求）',
      TtsAutoPairRules.shapeProblem(strict, 'aksk', 'sk-only-one-part') != null,
      '${TtsAutoPairRules.shapeProblem(strict, 'aksk', 'sk-only-one-part')}');
  ck(
      '形态对得上就没有问题提示',
      TtsAutoPairRules.shapeProblem(strict, 'aksk', 'ak-123') == null,
      '${TtsAutoPairRules.shapeProblem(strict, 'aksk', 'ak-123')}');
  ck('没声明前缀的方案不做形态检查（不猜）',
      TtsAutoPairRules.shapeProblem(vOf(), '', '随便什么') == null);

  // ═══════════════════════════════════════════════════════════
  // 7. 文案规范 + 源码接线
  // ═══════════════════════════════════════════════════════════
  print('== 7. 接线 ==');
  bool hasEmoji(String s) {
    for (final r in s.runes) {
      if (r >= 0x1F000 && r <= 0x1FAFF) return true;
      if (r == 0xFE0F || r == 0x200D) return true;
    }
    return false;
  }

  final rulesSrc = read('../lib/core/tts_autopair.dart');
  final runSrc = read('../lib/core/tts_autopair_run.dart');
  ck('规则层不含 emoji', !hasEmoji(rulesSrc));
  ck('IO 层不含 emoji', !hasEmoji(runSrc));
  ck('保存走统一密钥库（不是自己另写一套存储）', runSrc.contains('ApiKeys.set('));
  ck('保存同时写语音厂商配置（缺一处 = 配对成功但试听仍提示填 Key）',
      runSrc.contains('TtsOnline.saveConfig('));
  ck('拉模型列表失败不影响配对（独立 try/catch 吞掉）',
      runSrc.contains('catch (_) {') && runSrc.contains('_fillModels'));
  ck('响应体按 charset 解码（中文提示是判定依据，硬转会拆坏）',
      runSrc.contains('Encoding.getByName') || runSrc.contains('utf8.decode'));
  ck('命中即停，不把剩下厂商全打一遍白扣费', runSrc.contains('stopOnFirst'));
  ck('形态不符的候选不发请求（省一次必败的调用）',
      runSrc.contains('TtsProbeOutcome.wrongShape'));

  print('\n=== 自动配对自检：$pass 过 / $fail 挂 ===');
  if (fail > 0) {
    print('FAIL');
    exit(1);
  }
  print('OK');
}
