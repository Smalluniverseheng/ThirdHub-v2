// 在线 TTS 厂商注册表自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   cd flutter_app
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/tts_vendors_selfcheck.dart
//
// ★ 为什么这段契约非要自检不可：
//   各家的接口差异**不在协议上，而在字段名和位置上** —— 文本叫 `input` 还是
//   `text` 还是 `transcript`；音色放 body 还是塞 URL 路径还是放请求头；
//   鉴权是 `Bearer` 还是 `Token` 还是裸 key。
//   写错任何一处，**客户端不会报错，只会安静地拿到一个 400**，
//   用户看到的现象是"点了朗读没声音"。这类错误在真机上排查成本极高，
//   必须靠断言在本地拦住。
//
// ★ 本自检的核心手法：**用真实文本走一遍完整的请求构建，再断言构建结果**。
//   特别是「文本里带引号」这一条 —— 不转义的话 JSON 直接非法，
//   而这正是"本地看着好好的、真机上永远失败"的典型来源。
//
// ★ 失败必须非零退出（CI 只看退出码；只打印 FAIL 而 return 0 等于没拦）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/core/tts_vendors.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name${extra.isEmpty ? '' : '  → $extra'}');
  }
}

/// 一段"最恶劣"的正文：引号、反斜杠、换行、中文、XML 元字符齐全。
const String kEvilText = '他说：“你好”\\n第二行 <b>&amp;</b>\n第三行\t结束';

void main() {
  print('── 1. 厂商表完整性 ──');
  final ids = <String>{};
  for (final v in kTtsVendors) {
    ck('id 唯一：${v.id}', ids.add(v.id), '重复 id');
    ck('有 body 模板：${v.id}', v.bodyTpl.isNotEmpty);
    ck('有说明：${v.id}', v.note.isNotEmpty);
    ck('有文档出处：${v.id}', v.docUrl.isNotEmpty);
    if (v.tier == TtsTier.ready) {
      ck('ready 厂商 URL 非空：${v.id}', v.url.isNotEmpty);
      ck('ready 厂商 URL 是 http(s)：${v.id}',
          v.url.startsWith('http://') || v.url.startsWith('https://'), v.url);
      // 需要 key 的必须有鉴权头，否则会发出一个必然 401 的请求
      if (v.auth == TtsAuth.bearer || v.auth == TtsAuth.header) {
        ck('需要 key 的厂商给了鉴权头名：${v.id}', v.authHeader.isNotEmpty);
        ck('需要 key 的厂商给了值模板：${v.id}', v.authValue.isNotEmpty);
      }
      if (v.needRegion) ck('标了 needRegion 的 URL 含 {region}：${v.id}', v.url.contains('{region}'));
      if (v.needHost) ck('标了 needHost 的 URL 含 {host}：${v.id}', v.url.contains('{host}'));
    }
  }
  ck('分组非空', ttsGroups.isNotEmpty);
  ck('每个分组都有成员',
      ttsGroups.every((g) => vendorsInGroup(g).isNotEmpty));
  ck('分组无重复', ttsGroups.length == ttsGroups.toSet().length);

  print('── 2. 每家 ready 厂商：用恶劣文本构建请求，结果必须合法 ──');
  for (final v in kTtsVendors) {
    if (v.tier != TtsTier.ready) continue;
    final req = planTtsRequest(
      v,
      const TtsVars(
        text: kEvilText,
        key: 'TESTKEY123',
        region: 'eastasia',
        host: '192.168.1.5:8880',
      ),
    );
    // URL 里不许残留没被替换的占位符
    ck('${v.id}: URL 无残留占位符',
        !req.url.contains('{'), req.url);
    // 自托管必须真的把 {host} 填进去了
    if (v.needHost) {
      ck('${v.id}: {host} 已替换', req.url.contains('192.168.1.5:8880'), req.url);
    }
    if (v.needRegion) {
      ck('${v.id}: {region} 已替换', req.url.contains('eastasia'), req.url);
    }
    // 头里不许残留占位符
    for (final e in req.headers.entries) {
      ck('${v.id}: 头 ${e.key} 无残留占位符', !e.value.contains('{'), e.value);
    }
    ck('${v.id}: 有 Content-Type', req.headers.containsKey('Content-Type'));

    // ★ 最强的通用断言：按 body 类型，构建结果必须真的能被解析
    final b = req.body ?? '';
    switch (v.body) {
      case TtsBody.json:
        dynamic j;
        var ok = true;
        String err = '';
        try {
          j = jsonDecode(b);
        } catch (e) {
          ok = false;
          err = '$e';
        }
        ck('${v.id}: body 是合法 JSON', ok, err.isEmpty ? b.substring(0, b.length.clamp(0, 120)) : err);
        if (ok && j is Map) {
          // 文本必须原样（转义后又解回来）出现在某个位置
          ck('${v.id}: body 里能找回原始文本',
              _containsText(j, kEvilText), b.substring(0, b.length.clamp(0, 160)));
        }
      case TtsBody.form:
        final m = Uri.splitQueryString(b);
        ck('${v.id}: body 是合法表单', m.isNotEmpty, b);
        ck('${v.id}: 表单里能找回原始文本',
            m.values.any((x) => x == kEvilText));
      case TtsBody.ssml:
        ck('${v.id}: body 是 SSML', b.trimLeft().startsWith('<speak'), b);
        ck('${v.id}: SSML 含 voice 标签', b.contains('<voice name='), b);
        // XML 元字符必须被转义，否则 SSML 直接非法
        ck('${v.id}: SSML 未残留裸尖括号',
            !b.contains('<b>') && !b.contains('</b>'), b);
    }

    // 鉴权头必须真的带上了 key
    if (v.auth == TtsAuth.bearer || v.auth == TtsAuth.header) {
      ck('${v.id}: 鉴权头已带上',
          req.headers.containsKey(v.authHeader), v.authHeader);
      ck('${v.id}: 鉴权值含 key',
          (req.headers[v.authHeader] ?? '').contains('TESTKEY123'),
          req.headers[v.authHeader] ?? '');
    } else if (v.auth == TtsAuth.none) {
      ck('${v.id}: 无鉴权厂商不应有 Authorization 头',
          !req.headers.containsKey('Authorization'));
    }
  }

  print('── 3. 各家的"特有形状"逐条钉住（写错就会没声音的地方）──');
  TtsVendor v(String id) => ttsVendorOf(id)!;

  // ══ 小米 MiMo：形态最特殊的一家，必须逐条钉死 ══
  // 它不是 /audio/speech，而是 chat/completions；待合成文本放在 assistant
  // 消息里；音频以 base64 藏在 choices[0].message.audio.data。
  // 这是"照 OpenAI 形状写就会错、而且错得很安静"的典型。
  final xm = planTtsRequest(v('xiaomi'), const TtsVars(text: '你好', key: 'sk-x'));
  ck('小米: 端点是 chat/completions（不是 /audio/speech）',
      xm.url == 'https://api.xiaomimimo.com/v1/chat/completions', xm.url);
  ck('小米: 鉴权是 Bearer', xm.headers['Authorization'] == 'Bearer sk-x');
  final xmj = jsonDecode(xm.body!) as Map;
  ck('小米: 没有 input 字段（它不是 OpenAI 音频形状）', !xmj.containsKey('input'));
  final xmMsgs = xmj['messages'] as List;
  ck('小米: 有一条 assistant 消息', xmMsgs.length == 1 &&
      (xmMsgs[0] as Map)['role'] == 'assistant');
  ck('小米: 待合成文本在 assistant 的 content 里',
      (xmMsgs[0] as Map)['content'] == '你好');
  final xmAudio = xmj['audio'] as Map;
  ck('小米: 音色与格式在 audio 对象里',
      xmAudio.containsKey('voice') && xmAudio.containsKey('format'));

  // 用官方文档里的真实响应结构验证取值路径（不是编一个形状出来自证）
  const xmRespBody = '{"id":"6ebe","choices":[{"finish_reason":"stop","index":0,'
      '"message":{"content":"","role":"assistant","audio":{"id":"979a",'
      '"data":"QUJD","expires_at":null,"transcript":null}}}],'
      '"model":"mimo-v2.5-tts","object":"chat.completion"}';
  final xmOut = extractTtsAudio(v('xiaomi'), 'application/json',
      Uint8List.fromList(utf8.encode(xmRespBody)));
  ck('小米: 能从真实响应里取到音频', xmOut.ok && xmOut.bytes?.length == 3,
      '${xmOut.error}');
  ck('小米: 解出来正是 ABC 三个字节',
      xmOut.bytes != null &&
          xmOut.bytes![0] == 65 &&
          xmOut.bytes![1] == 66 &&
          xmOut.bytes![2] == 67);
  // 反证：audio 对象在但 data 缺失 —— 必须报错，不能静默存 0 字节
  final xmNoData = extractTtsAudio(
      v('xiaomi'),
      'application/json',
      Uint8List.fromList(utf8.encode(
          '{"choices":[{"message":{"audio":{"id":"x"}}}]}')));
  ck('小米: 响应里缺 data 要报错（不是静默空音频）', !xmNoData.ok);

  // ══ 计费方式：一个厂商两套端点、两套互不通用的 Key ══
  ck('小米: 登记了 4 套计费方案', v('xiaomi').plans.length == 4);
  ck('小米: 方案 id 与顺序正确',
      v('xiaomi').plans.map((p) => p.id).join(',') ==
          'payg,tokenplan-cn,tokenplan-sgp,tokenplan-ams');
  ck('小米: 每套方案都写明 Key 前缀要求',
      v('xiaomi').plans.every((p) => p.keyPrefixes.isNotEmpty));
  ck('小米: 每套方案都有自己的完整地址',
      v('xiaomi').plans.every((p) => p.url.startsWith('https://')));

  final xmPayg = planTtsRequest(
      v('xiaomi'),
      const TtsVars(
          text: 'x',
          key: 'sk-x',
          planUrl: 'https://api.xiaomimimo.com/v1/chat/completions'));
  ck('小米: 选按量 → 打 api.xiaomimimo.com',
      xmPayg.url.startsWith('https://api.xiaomimimo.com/'), xmPayg.url);
  // ★ 同一家厂商、同一份配置，只因为"选了套餐"就换域名 —— 这是核心断言
  final xmTp = planTtsRequest(
      v('xiaomi'),
      const TtsVars(
          text: 'x',
          key: 'tp-x',
          planUrl: 'https://token-plan-cn.xiaomimimo.com/v1/chat/completions'));
  ck('★ 小米: 选会员套餐 → 换成 token-plan-cn 域名',
      xmTp.url == 'https://token-plan-cn.xiaomimimo.com/v1/chat/completions',
      xmTp.url);
  ck('小米: 没选方案时回落厂商默认地址（照样能用）',
      planTtsRequest(v('xiaomi'), const TtsVars(text: 'x', key: 'k'))
          .url
          .startsWith('https://api.xiaomimimo.com/'));

  ck('ttsEffectiveUrl: 选了套餐就用套餐地址',
      ttsEffectiveUrl(v('xiaomi'), 'tokenplan-sgp') ==
          'https://token-plan-sgp.xiaomimimo.com/v1/chat/completions');
  ck('ttsEffectiveUrl: 没选就用厂商默认地址',
      ttsEffectiveUrl(v('xiaomi'), '') ==
          'https://api.xiaomimimo.com/v1/chat/completions');
  ck('ttsEffectiveUrl: 选了不存在的方案也不崩',
      ttsEffectiveUrl(v('xiaomi'), 'nope') ==
          'https://api.xiaomimimo.com/v1/chat/completions');
  ck('ttsDefaultPlan: 默认是按量付费（TTS 限时免费那条）',
      ttsDefaultPlan(v('xiaomi'))?.id == 'payg');
  ck('无方案厂商: ttsDefaultPlan 返回 null（不是崩）',
      ttsDefaultPlan(v('siliconflow')) == null);

  // ══ "两套 Key 不可混用"的落地：填错端点前就提醒 ══
  final xmPaygPlan = ttsPlanOf(v('xiaomi'), 'payg');
  final xmTpPlan = ttsPlanOf(v('xiaomi'), 'tokenplan-cn');
  ck('小米: sk- Key 配按量 → 不告警',
      keyPlanMismatchHint(v('xiaomi'), xmPaygPlan, 'sk-abc') == '');
  ck('小米: tp- Key 配套餐 → 不告警',
      keyPlanMismatchHint(v('xiaomi'), xmTpPlan, 'tp-abc') == '');
  ck('小米: ttp- Key（团队版）配套餐 → 不告警',
      keyPlanMismatchHint(v('xiaomi'), xmTpPlan, 'ttp-abc') == '');
  ck('★ 小米: tp- Key 配按量 → 必须告警',
      keyPlanMismatchHint(v('xiaomi'), xmPaygPlan, 'tp-abc').isNotEmpty);
  ck('★ 小米: sk- Key 配套餐 → 必须告警',
      keyPlanMismatchHint(v('xiaomi'), xmTpPlan, 'sk-abc').isNotEmpty);
  ck('小米: 还没填 Key 时不要告警（只是没填而已）',
      keyPlanMismatchHint(v('xiaomi'), xmTpPlan, '') == '');
  ck('无方案的厂商: 一律不告警（不猜）',
      keyPlanMismatchHint(v('siliconflow'), null, '随便什么') == '');

  // 硅基流动：OpenAI 形状，音频直接二进制
  final sf = planTtsRequest(
      v('siliconflow'), const TtsVars(text: '你好', key: 'k'));
  ck('硅基流动: URL', sf.url == 'https://api.siliconflow.cn/v1/audio/speech', sf.url);
  ck('硅基流动: 是 Bearer', sf.headers['Authorization'] == 'Bearer k');
  final sfj = jsonDecode(sf.body!) as Map;
  ck('硅基流动: 文本字段是 input（不是 text）', sfj.containsKey('input'));
  ck('硅基流动: 格式字段是 response_format', sfj.containsKey('response_format'));

  // 智谱 / 阶跃 / OpenAI / Groq / OpenRouter 都是 OpenAI 形状
  for (final id in ['zhipu', 'stepfun', 'openai', 'groq', 'openrouter']) {
    final j = jsonDecode(
        planTtsRequest(v(id), const TtsVars(text: 'x', key: 'k')).body!) as Map;
    ck('$id: OpenAI 形状（input / voice / response_format）',
        j.containsKey('input') && j.containsKey('voice') && j.containsKey('response_format'));
  }

  // 十一家的音色位置差异
  final el = planTtsRequest(v('elevenlabs'),
      const TtsVars(text: 'x', key: 'k', voice: 'VOICEID'));
  ck('ElevenLabs: 音色在 URL 路径里',
      el.url == 'https://api.elevenlabs.io/v1/text-to-speech/VOICEID', el.url);
  ck('ElevenLabs: 头名是 xi-api-key（不是 Authorization）',
      el.headers['xi-api-key'] == 'k' && !el.headers.containsKey('Authorization'));

  final dg = planTtsRequest(
      v('deepgram'), const TtsVars(text: 'x', key: 'k', voice: 'aura-luna-en'));
  ck('Deepgram: 音色在 URL 查询参数', dg.url.contains('?model=aura-luna-en'), dg.url);
  ck('Deepgram: 鉴权是 Token 前缀（不是 Bearer）',
      dg.headers['Authorization'] == 'Token k', dg.headers['Authorization'] ?? '');

  final fa = planTtsRequest(
      v('fishaudio'), const TtsVars(text: 'x', key: 'k', model: 's2.1-pro'));
  ck('Fish Audio: 模型放在请求头里', fa.headers['model'] == 's2.1-pro');
  final faj = jsonDecode(fa.body!) as Map;
  ck('Fish Audio: 音色字段是 reference_id',
      faj.containsKey('reference_id') && !faj.containsKey('voice'));

  final ca = planTtsRequest(v('cartesia'), const TtsVars(text: 'x', key: 'k'));
  final caj = jsonDecode(ca.body!) as Map;
  ck('Cartesia: 文本字段是 transcript（不是 input/text）',
      caj.containsKey('transcript') && !caj.containsKey('input'));
  ck('Cartesia: 带 Cartesia-Version 头', ca.headers.containsKey('Cartesia-Version'));

  final rs = planTtsRequest(v('resemble'), const TtsVars(text: 'x', key: 'k'));
  ck('Resemble: 鉴权是裸 key（无 Bearer 前缀）',
      rs.headers['Authorization'] == 'k', rs.headers['Authorization'] ?? '');

  final mf = planTtsRequest(v('murf'), const TtsVars(text: 'x', key: 'k'));
  ck('Murf: 头名是 api-key', mf.headers['api-key'] == 'k');
  ck('Murf: 音色字段是 voiceId',
      (jsonDecode(mf.body!) as Map).containsKey('voiceId'));

  final az = planTtsRequest(
      v('azure'), const TtsVars(text: 'x', key: 'k', region: 'eastasia'));
  ck('Azure: 鉴权头是 Ocp-Apim-Subscription-Key',
      az.headers['Ocp-Apim-Subscription-Key'] == 'k');
  ck('Azure: Content-Type 是 ssml+xml',
      az.headers['Content-Type'] == 'application/ssml+xml');

  final mm = planTtsRequest(
      v('minimax'), const TtsVars(text: 'x', key: 'k', voice: 'audiobook_male_1'));
  ck('MiniMax: 响应是 hex', v('minimax').resp == TtsResp.jsonHex);
  ck('MiniMax: 音色在 voice_setting.voice_id',
      (jsonDecode(mm.body!) as Map)['voice_setting']['voice_id'] == 'audiobook_male_1');

  ck('阿里百炼: 响应是音频地址不是二进制', v('dashscope').resp == TtsResp.jsonUrl);
  ck('阿里百炼: 取值路径 output.audio.url',
      v('dashscope').audioPath == 'output.audio.url');
  ck('阿里百炼: 文本在 input.text',
      (jsonDecode(planTtsRequest(v('dashscope'), const TtsVars(text: 'x', key: 'k'))
                  .body!) as Map)['input']['text'] ==
          'x');

  final vc = planTtsRequest(v('volc'), const TtsVars(text: 'x', key: 'k'));
  ck('火山: 用 X-Api-Key 头（不是 Authorization）',
      vc.headers['X-Api-Key'] == 'k' && !vc.headers.containsKey('Authorization'));
  ck('火山: 带 X-Api-Resource-Id', vc.headers.containsKey('X-Api-Resource-Id'));
  ck('火山: 响应是分块 JSON', v('volc').resp == TtsResp.jsonChunks);
  ck('火山: 文本在 req_params.text',
      (jsonDecode(vc.body!) as Map)['req_params']['text'] == 'x');

  // 百度：两步 + 表单
  ck('百度: 是 baidu 两步鉴权', v('baidu').auth == TtsAuth.baidu);
  final bdTok = planTokenRequest(v('baidu'), const TtsVars(text: '', key: 'AK1|SK2'));
  ck('百度: 生成了换 token 请求', bdTok != null);
  ck('百度: token 请求 URL', bdTok!.url == 'https://aip.baidubce.com/oauth/2.0/token');
  ck('百度: token 请求带上了 AK 与 SK',
      bdTok.body!.contains('client_id=AK1') && bdTok.body!.contains('client_secret=SK2'),
      bdTok.body ?? '');
  final bd = planTtsRequest(v('baidu'), const TtsVars(text: '你好', key: 'k'), token: 'TOK');
  ck('百度: 合成用换来的 token（不是原始 key）', bd.body!.contains('tok=TOK'), bd.body ?? '');
  ck('百度: 合成请求是表单', v('baidu').body == TtsBody.form);
  ck('百度: 表单里带上了文本',
      Uri.splitQueryString(bd.body!)['tex'] == '你好');

  print('── 4. JSON 转义（最容易"本地看着对、真机永远失败"的地方）──');
  // 含引号的文本不转义，JSON 直接非法 —— 反证一次
  ck('反证：未转义的引号文本会破坏 JSON', () {
    try {
      jsonDecode('{"input":"他说："你好""}');
      return false; // 居然解析成功了，说明这条反证不成立
    } catch (_) {
      return true;
    }
  }());
  ck('jsonEscape 后能解回原文',
      jsonDecode('"${jsonEscape(kEvilText)}"') == kEvilText);
  ck('jsonEscape 不含外层引号',
      !jsonEscape('abc').startsWith('"'));

  print('── 5. 响应解析：四种形态 + 错误分支 ──');
  Uint8List u(List<int> x) => Uint8List.fromList(x);

  final binOk = extractTtsAudio(v('siliconflow'), 'audio/mpeg', u([1, 2, 3]));
  ck('二进制：正常取出', binOk.ok && binOk.bytes!.length == 3);
  // ★ 反证：配置说二进制，但对面回了个 JSON 错误体 —— 不能把它当音频存下来
  final binBad = extractTtsAudio(
      v('siliconflow'), 'application/json', u(utf8.encode('{"error":"bad key"}')));
  ck('二进制：JSON 错误体不被当作音频', !binBad.ok);
  ck('二进制：错误信息里带上了原文', (binBad.error ?? '').contains('bad key'));

  final b64 = extractTtsAudio(v('resemble'), 'application/json',
      u(utf8.encode('{"audio_content":"${base64Encode(u([9, 8, 7]))}"}')));
  ck('base64：正常取出', b64.bytes?.length == 3 && b64.bytes![0] == 9);

  final b64Miss = extractTtsAudio(v('resemble'), 'application/json',
      u(utf8.encode('{"other":1}')));
  ck('base64：路径不存在要报错（不是静默空音频）', !b64Miss.ok);
  ck('base64：报错里带上取值路径', (b64Miss.error ?? '').contains('audio_content'));

  final hexOut = extractTtsAudio(v('minimax'), 'application/json',
      u(utf8.encode('{"data":{"audio":"0a0b0c"}}')));
  ck('hex：正常取出', hexOut.bytes?.length == 3 && hexOut.bytes![2] == 12);
  ck('hex 解码：非法字符返回 null', hexToBytes('zz') == null);
  ck('hex 解码：奇数长度返回 null', hexToBytes('abc') == null);

  final urlOut = extractTtsAudio(v('dashscope'), 'application/json',
      u(utf8.encode('{"output":{"audio":{"url":"https://x.com/a.mp3"}}}')));
  ck('音频地址：正常取出', urlOut.fetchUrl == 'https://x.com/a.mp3');
  final urlBad = extractTtsAudio(v('dashscope'), 'application/json',
      u(utf8.encode('{"output":{"audio":{"url":"not-a-url"}}}')));
  ck('音频地址：不是 URL 要报错', !urlBad.ok);

  // 火山：多段 base64 分块拼接
  final c1 = base64Encode(u([1, 2]));
  final c2 = base64Encode(u([3, 4]));
  final chunks = extractTtsAudio(v('volc'), 'text/plain',
      u(utf8.encode('{"data":"$c1"}{"data":"$c2"}')));
  ck('分块：多段按序拼接',
      chunks.bytes?.length == 4 && chunks.bytes!.join(',') == '1,2,3,4',
      '${chunks.bytes?.length}');
  final chunksBad = extractTtsAudio(
      v('volc'), 'text/plain', u(utf8.encode('{"data":"not base64!!"}')));
  ck('分块：没有有效音频要报错', !chunksBad.ok);

  ck('空响应要报错', !extractTtsAudio(v('openai'), 'audio/mpeg', u([])).ok);
  ck('base64 容错：换行与缺 padding 也能解',
      b64ToBytes('\n${base64Encode(u([5, 6, 7]))}\n')?.length == 3);

  print('── 6. 路径取值 ──');
  final sample = {
    'a': {'b': [1, {'c': 'hit'}]},
    'x': 'y',
  };
  ck('pickPath 普通路径', pickPath(sample, 'x') == 'y');
  ck('pickPath 数组下标 + 嵌套', pickPath(sample, 'a.b.1.c') == 'hit');
  ck('pickPath 缺层返回 null', pickPath(sample, 'a.zzz.c') == null);
  ck('pickPath 越界返回 null', pickPath(sample, 'a.b.9') == null);
  ck('pickPath 空路径返回 null', pickPath(sample, '') == null);
  ck('pickPath 非下标访问数组返回 null', pickPath(sample, 'a.b.c') == null);

  print('── 7. 自定义厂商：存进去再读出来必须一模一样 ──');
  var roundTripBad = 0;
  for (final v in kTtsVendors) {
    final back = vendorFromJson(vendorToJson(v));
    final same = back != null &&
        back.url == v.url &&
        back.method == v.method &&
        back.auth == v.auth &&
        back.body == v.body &&
        back.resp == v.resp &&
        back.bodyTpl == v.bodyTpl &&
        back.audioPath == v.audioPath &&
        back.authHeader == v.authHeader &&
        back.authValue == v.authValue &&
        back.voice == v.voice &&
        back.model == v.model &&
        back.format == v.format &&
        back.needRegion == v.needRegion &&
        back.needHost == v.needHost &&
        _sameMap(back.extraHeaders, v.extraHeaders) &&
        back.voices.join(',') == v.voices.join(',') &&
        back.models.join(',') == v.models.join(',') &&
        back.keyHint == v.keyHint &&
        // ★ 计费方案也要往返一致：丢了它 = 用户选的套餐重启后回到按量，
        //   表现就是"昨天还能用，今天突然 401"。
        back.plans.length == v.plans.length &&
        back.plans.every((bp) {
          final orig = v.plans.firstWhere(
              (p) => p.id == bp.id,
              orElse: () => const TtsPlan(id: '__none__', name: ''));
          return orig.url == bp.url &&
              orig.keyHint == bp.keyHint &&
              orig.keyPrefixes.join(',') == bp.keyPrefixes.join(',');
        });
    if (!same) roundTripBad++;
    ck('往返一致：${v.id}', same,
        back == null ? '反序列化返回 null' : '字段有丢失');
  }
  ck('全表往返无一处丢失', roundTripBad == 0, '$roundTripBad 家不一致');

  // 方案这一层单独再钉一遍：它是"重启后静默失效"的高危字段。
  final xmBack = vendorFromJson(vendorToJson(v('xiaomi')))!;
  ck('★ 小米的计费方案往返不丢（4 套都还在）', xmBack.plans.length == 4);
  ck('小米: 方案地址往返一字不差',
      xmBack.plans.map((p) => p.url).join('|') ==
          v('xiaomi').plans.map((p) => p.url).join('|'));
  ck('小米: 方案的 Key 前缀往返不丢',
      xmBack.plans[1].keyPrefixes.join(',') == 'tp-,ttp-');
  ck('小米: keyHint 往返不丢', xmBack.keyHint == v('xiaomi').keyHint);
  ck('无方案厂商往返后 plans 仍为空（别凭空造方案）',
      vendorFromJson(vendorToJson(v('siliconflow')))!.plans.isEmpty);
  ck('坏方案条目被单条丢弃，不牵连整家厂商',
      vendorFromJson({
        'id': 'xx',
        'url': 'https://a/b',
        'bodyTpl': '{}',
        'plans': [
          {'name': '没有 id 的坏条目'},
          {'id': 'ok', 'name': '有效', 'url': 'https://c/d'},
        ],
      })!.plans.length == 1);
  ck('整表编码再解码数量不变',
      decodeVendorList(encodeVendorList(kTtsVendors)).length == kTtsVendors.length);
  ck('空串解码为空表（不抛）', decodeVendorList('').isEmpty);
  ck('坏 JSON 解码为空表（不抛）', decodeVendorList('{oops').isEmpty);
  ck('顶层不是数组时返回空表（不抛）', decodeVendorList('{"a":1}').isEmpty);
  ck('缺 url 的配置被拒（不生成半个厂商）',
      vendorFromJson({'id': 'x', 'bodyTpl': '{}'}) == null);
  ck('缺 bodyTpl 的配置被拒',
      vendorFromJson({'id': 'x', 'url': 'https://a/b'}) == null);

  final cv = buildCustomVendor(name: 'My TTS', url: 'https://x/y');
  ck('自定义厂商 id 可生成', cv.id.startsWith('custom_my_tts_'), cv.id);
  ck('自定义厂商默认是 OpenAI 形状', cv.bodyTpl.contains('"input"'));
  ck('自定义厂商能直接构建出请求',
      planTtsRequest(cv, const TtsVars(text: 'hi', key: 'k'))
              .headers['Authorization'] ==
          'Bearer k');
  ck('自定义厂商（含中文名）id 里不含中文',
      !buildCustomVendor(name: '我的接口', url: 'https://a/b')
          .id
          .contains(RegExp(r'[\u4e00-\u9fa5]')));

  print('── 8. 未实现厂商必须被单独标注（不许混进可用列表）──');
  ck('待适配厂商非空', kTtsPendingVendors.isNotEmpty);
  ck('待适配厂商都写了原因',
      kTtsPendingVendors.every((m) => (m['why'] ?? '').isNotEmpty));
  final readyIds = kTtsVendors.map((e) => e.id).toSet();
  ck('腾讯不在可用列表里（还没实现签名）', !readyIds.contains('tencent'));
  ck('讯飞不在可用列表里（还没实现 WebSocket）', !readyIds.contains('xfyun'));

  print('');
  print(fail == 0
      ? '★ tts_vendors 自检全部通过（$pass 项）'
      : '✗ 有 $fail 项失败（通过 $pass 项）');
  exit(fail == 0 ? 0 : 1);
}

/// 在任意层级的 JSON 结构里找一段文本。
bool _containsText(dynamic j, String t) {
  if (j is String) return j == t;
  if (j is Map) return j.values.any((e) => _containsText(e, t));
  if (j is List) return j.any((e) => _containsText(e, t));
  return false;
}

bool _sameMap(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}
