// 开源 TTS 引擎接入（D-C3 / TTS-1）契约自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   cd flutter_app
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/tts_engines_selfcheck.dart
//
// 对应 `docs/TTS-PROTOCOL.md`。
//
// ★ 为什么这段契约非要自检不可：
//   判定逻辑错了**不会报错**，只会安静地把错误的东西当成引擎 ——
//     ① 只看 `ok: true` → 任何返回 `{"ok":true}` 的 REST 服务都会被认成引擎。
//        用户填的是阅读引擎的 :1234 或资源库的 :9527，界面照样显示"已连接"，
//        然后听书点了没声音。这个坑本项目在别处已经踩过一次（引擎/资源库混淆）。
//     ② `badUrl` / `unreachable` / `notJson` / `unhealthy` / `wrongProtocol`
//        五种失败各有各的处置办法；合并成一句"连接失败"等于没说，
//        用户唯一能做的就是反复重点同一个按钮。
//   两条都只能靠断言钉住。
//
// ★ 失败必须非零退出（CI 只看退出码；只打印 FAIL 而 return 0 等于没拦）。
import 'dart:io';

import '../lib/core/tts_engines_logic.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name${extra.isEmpty ? '' : '  → $extra'}');
  }
}

String health({
  bool ok = true,
  String protocol = 'tts/1',
  String engine = 'piper',
  String name = 'Piper 本地服务',
  int? sampleRate = 22050,
  List<String>? voices,
  String? defaultVoice,
  List<String>? formats,
}) {
  final b = <String, dynamic>{'ok': ok, 'engine': engine, 'name': name};
  if (protocol.isNotEmpty) b['protocol'] = protocol;
  if (sampleRate != null) b['sample_rate'] = sampleRate;
  if (voices != null) b['voices'] = voices;
  if (defaultVoice != null) b['default_voice'] = defaultVoice;
  if (formats != null) b['formats'] = formats;
  final s = b.entries
      .map((e) => '${_q(e.key)}:${_enc(e.value)}')
      .join(',');
  return '{$s}';
}

String _q(String s) => '"$s"';
String _enc(Object? v) {
  if (v is num || v is bool) return '$v';
  if (v is String) return '"${v.replaceAll('"', r'\"')}"';
  if (v is List) return '[${v.map(_enc).join(',')}]';
  return 'null';
}

Future<void> main() async {
  // ═══ 1. 引擎登记表 ═══
  print('== 1. 开源引擎登记表 ==');
  ck('登记了至少 5 个引擎', kTtsEngineProjects.length >= 5,
      'len=${kTtsEngineProjects.length}');
  ck('id 不重复',
      kTtsEngineProjects.map((e) => e.id).toSet().length ==
          kTtsEngineProjects.length);
  ck('默认端口不重复',
      kTtsEngineProjects.map((e) => e.defaultPort).toSet().length ==
          kTtsEngineProjects.length);
  ck('每个都有许可标注', kTtsEngineProjects.every((e) => e.license.isNotEmpty));
  ck('每个都有非空备注与启动命令',
      kTtsEngineProjects.every((e) => e.note.isNotEmpty && e.hint.isNotEmpty));
  // ★ 不许硬编码模型直链：上游一改版本就 404，而"一键下载 404"比让用户
  //   自己去发布页挑版本更糟。所以只允许放项目主页/发布页。
  final badHome = kTtsEngineProjects
      .where((e) => !e.home.startsWith('https://github.com/'))
      .map((e) => '${e.id}=${e.home}')
      .toList();
  ck('主页一律指向 github 项目页（不放模型直链）', badHome.isEmpty, badHome.join(', '));
  ck('projectOf 能按 engineKey 反查', projectOf('piper') != null);
  ck('projectOf 大小写不敏感', projectOf('Piper')?.id == 'piper');
  ck('projectOf 认不出时返回 null（不许瞎猜）', projectOf('nope-xyz') == null);

  // ═══ 2. 地址归一化 ═══
  print('\n== 2. 地址归一化 ==');
  ck('缺 scheme 补 http',
      normalizeTtsUrl('192.168.1.5:5100') == 'http://192.168.1.5:5100');
  ck('缺端口补默认',
      normalizeTtsUrl('192.168.1.5', fallbackPort: 5100) ==
          'http://192.168.1.5:5100');
  ck('已有端口不被覆盖',
      normalizeTtsUrl('http://1.2.3.4:9999') == 'http://1.2.3.4:9999');
  // ★ 这条是本自检抓出来的**真缺陷**：Dart 对 `https://x:443` 的 hasPort 是 false
  //   （默认端口被视为"没写端口"），照 hasPort 补端口会补成 :5100 —— 必然连不上。
  final https443 = normalizeTtsUrl('https://tts.example.com:443');
  ck('https 的 443 不被套成 fallback（否则拼出连不上的地址）',
      https443 != null &&
          https443.startsWith('https://tts.example.com') &&
          !https443.contains('5100'),
      '$https443');
  ck('https 不带端口时同样不套 fallback',
      normalizeTtsUrl('https://tts.example.com')?.contains('5100') == false);
  ck('尾斜杠被去掉（否则会拼出 //health）',
      normalizeTtsUrl('http://1.2.3.4:5100/') == 'http://1.2.3.4:5100');
  ck('空串 → null', normalizeTtsUrl('') == null);
  ck('纯空格 → null', normalizeTtsUrl('   ') == null);
  // ★ 这条也是抓出来的真缺陷：IPv6 的 Uri.host **不带方括号**，手工拼字符串
  //   会得到 http://fe80::1:5100（无法解析）。必须走 Uri.replace().toString()。
  ck('IPv6 方括号不被吃掉',
      normalizeTtsUrl('http://[fe80::1]:5100') == 'http://[fe80::1]:5100',
      '${normalizeTtsUrl('http://[fe80::1]:5100')}');
  ck('IPv6 缺端口时补默认端口且保住方括号',
      normalizeTtsUrl('http://[fe80::1]') == 'http://[fe80::1]:5100',
      '${normalizeTtsUrl('http://[fe80::1]')}');
  ck('带 Token 的 query 被保留（协议允许在 URL 里带鉴权）',
      normalizeTtsUrl('http://1.2.3.4:5100?token=abc')?.contains('token=abc') ==
          true);

  // ═══ 3. 合格响应 ═══
  print('\n== 3. 合格响应 → ok ==');
  final good = parseHealth(health(voices: ['zh_CN-huayan-medium', 'en_US-amy-low']));
  ck('kind 为 ok', good.kind == TtsProbe.ok, '${good.kind}');
  ck('解析出 engine', good.engine == 'piper');
  ck('解析出采样率', good.sampleRate == 22050);
  ck('解析出音色列表', good.voices.length == 2);
  ck('解析出展示名', good.name == 'Piper 本地服务');
  ck('默认音色缺省取 voices[0]', good.defaultVoice == 'zh_CN-huayan-medium');
  ck('显式 default_voice 优先',
      parseHealth(health(voices: ['a', 'b'], defaultVoice: 'b')).defaultVoice == 'b');
  ck('formats 缺省为 [wav]', good.formats.length == 1 && good.formats.first == 'wav');
  ck('formats 显式时被采纳',
      parseHealth(health(formats: ['wav', 'mp3'])).formats.length == 2);
  // 最小合法响应：可选字段全缺也要能连上（否则"能用的引擎"会被判死）
  final minimal = parseHealth('{"ok":true,"protocol":"tts/1","engine":"x"}');
  ck('可选字段全缺仍判合格（不许把能用的引擎判死）', minimal.kind == TtsProbe.ok);
  ck('缺 voices 时列表为空', minimal.voices.isEmpty);
  ck('缺 default_voice 且无 voices 时为空串', minimal.defaultVoice == '');
  ck('缺 sample_rate 时为 0', minimal.sampleRate == 0);

  // ═══ 4. ★ 核心：ok 为真但没有 protocol 必须判 wrongProtocol ═══
  print('\n== 4. ★ 只认 ok:true 是不够的 ==');
  final noProto = parseHealth('{"ok":true,"name":"阅读引擎","engine":"legado"}');
  ck('缺 protocol → wrongProtocol（不是 ok）', noProto.kind == TtsProbe.wrongProtocol,
      '${noProto.kind}');
  ck('wrongProtocol 的说明里点了 protocol 缺失',
      noProto.detail.contains('缺少 protocol'));
  final otherProto = parseHealth('{"ok":true,"protocol":"thp/1","engine":"engine"}');
  ck('protocol 是别的字面量 → wrongProtocol',
      otherProto.kind == TtsProbe.wrongProtocol, '${otherProto.kind}');
  ck('wrongProtocol 的说明里带上了实际值',
      otherProto.detail.contains('thp/1'), otherProto.detail);
  ck('protocol 为 null → wrongProtocol',
      parseHealth('{"ok":true,"protocol":null}').kind == TtsProbe.wrongProtocol);
  ck('protocol 为 1（数字）→ wrongProtocol（类型不对也算不对）',
      parseHealth('{"ok":true,"protocol":1}').kind == TtsProbe.wrongProtocol);
  // 反向：真正的 TTS/1 不能被误杀
  ck('正牌 TTS/1 不被误杀', parseHealth(health()).kind == TtsProbe.ok);

  // ═══ 5. 其余各种失败要**分开报** ═══
  print('\n== 5. 失败要分开报（合并成一句就等于没说）==');
  ck('ok:false → unhealthy（服务在但不健康）',
      parseHealth(health(ok: false)).kind == TtsProbe.unhealthy);
  ck('ok 缺失 → unhealthy',
      parseHealth('{"protocol":"tts/1"}').kind == TtsProbe.unhealthy);
  ck('ok 为字符串 "true" → unhealthy（不是布尔真）',
      parseHealth('{"ok":"true","protocol":"tts/1"}').kind == TtsProbe.unhealthy);
  ck('unhealthy 会带出服务端说明',
      parseHealth('{"ok":false,"message":"模型加载中"}').detail.contains('模型加载中'));
  ck('坏 JSON → notJson', parseHealth('{不是 json').kind == TtsProbe.notJson);
  ck('空串 → notJson', parseHealth('').kind == TtsProbe.notJson);
  ck('顶层是数组 → notObject', parseHealth('[1,2,3]').kind == TtsProbe.notObject);
  ck('顶层是字符串 → notObject', parseHealth('"hello"').kind == TtsProbe.notObject);
  ck('Content-Type 非 json → notJson（HTML 登录页不算引擎）',
      parseHealth(health(), wasJson: false).kind == TtsProbe.notJson);

  // 五种失败必须**互不相同**：如果两类合并，用户就分不清该改地址还是等模型
  final kinds = [
    parseHealth('{bad').kind,
    parseHealth('{"ok":true,"engine":"x"}').kind,
    parseHealth('[1]').kind,
    parseHealth(health(ok: false)).kind,
    const TtsProbeResult(kind: TtsProbe.badUrl, detail: '').kind,
  ];
  ck('五类失败互不重合', kinds.toSet().length == 5, '$kinds');

  // ═══ 6. 每个判定都要能产出"现象/原因/怎么办" ═══
  print('\n== 6. 结论文案必须可行动 ==');
  final allResults = <TtsProbeResult>[
    good,
    parseHealth('{bad'),
    parseHealth('[1]'),
    parseHealth(health(ok: false)),
    parseHealth('{"ok":true,"engine":"x"}'),
    const TtsProbeResult(kind: TtsProbe.badUrl, detail: '空地址'),
    const TtsProbeResult(kind: TtsProbe.unreachable, detail: 'SocketException: 拒绝连接'),
  ];
  for (final r in allResults) {
    final d = describeProbe(r);
    ck('${r.kind} 的结论非空', d.trim().isNotEmpty);
  }
  ck('unreachable 的结论包含"怎么办"（提到局域网/监听 0.0.0.0）',
      describeProbe(const TtsProbeResult(
              kind: TtsProbe.unreachable, detail: 'x'))
          .contains('0.0.0.0'));
  ck('wrongProtocol 的结论点名了"不是 TTS/1 引擎"',
      describeProbe(parseHealth('{"ok":true,"engine":"x"}')).contains('不是 TTS/1 引擎'));
  ck('badUrl 的结论给出了正确形态示例',
      describeProbe(const TtsProbeResult(kind: TtsProbe.badUrl, detail: 'x'))
          .contains('http://'));
  ck('ok 的结论带上了引擎名',
      describeProbe(good).contains('Piper 本地服务'), describeProbe(good));

  // ═══ 7. 协议字面量只在一处定义 ═══
  print('\n== 7. 协议版本字面量 ==');
  ck('kTtsProtocol == "tts/1"', kTtsProtocol == 'tts/1');
  // 判定用的必须是常量而不是各写一遍字面量（早先"两处各写一遍必然分叉"的教训）
  ck('把常量改掉时判定会跟着变（说明判定读的是常量）',
      parseHealth('{"ok":true,"protocol":"$kTtsProtocol"}').kind == TtsProbe.ok &&
          parseHealth('{"ok":true,"protocol":"tts/2"}').kind == TtsProbe.wrongProtocol);

  // ═══ 8. 文档与实现不许脱节 ═══
  print('\n== 8. 协议文档存在且端点与实现一致 ==');
  final doc = File('../docs/TTS-PROTOCOL.md');
  ck('docs/TTS-PROTOCOL.md 存在', doc.existsSync(), doc.absolute.path);
  if (doc.existsSync()) {
    final t = doc.readAsStringSync();
    ck('文档写了 /health', t.contains('/health'));
    ck('文档写了 /synthesize', t.contains('/synthesize'));
    ck('文档写了 protocol 字面量 $kTtsProtocol', t.contains(kTtsProtocol));
    ck('文档说明了为什么只看 ok:true 不够', t.contains('ok:true') || t.contains('`ok: true`'));
    ck('文档写了判定顺序', t.contains('判定顺序'));
  }

  print('\nPASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ 全部通过');
  if (fail > 0) exit(1);
}
