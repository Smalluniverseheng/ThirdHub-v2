// 角色卡导出（PNG tEXt 隐写 + V2 JSON 信封）的自检 —— 纯 Dart VM，零 Flutter 依赖。
//
// 跑法（在 flutter_app/ 目录下）：
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//            tool/tavern_export_selfcheck.dart
//
// 为什么需要它：
//   导出这件事**失败起来是静默的**。拼错 `first_mes` → 卡能导出、别人也能导入，
//   只是开场白没了；CRC 写错一个字节 → 图还能看，但导入方报"这张图不是角色卡"；
//   文件名里带 `/` → 写文件直接抛/或静默不写。这些用肉眼看手机上的提示都看不出来，
//   只有逐字节断言能抓住。
//
// 两条基准:
//   · CRC32 用**位运算版**另写一遍（不用 lib 里那张表）—— 同一段代码算两次不算验证；
//   · 用仓库里真实的 `assets/branding/logo.png` 当底图，它自带的块 CRC 就是
//     一个"真实编码器"的答案，可以直接拿来校准我们的 CRC 实现。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:thirdhub_app/core/png_text.dart';
import 'package:thirdhub_app/core/tavern_card_codec.dart';

int pass = 0, fail = 0;
final List<String> fails = <String>[];

void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
  } else {
    fail++;
    fails.add(name);
    print('  FAIL  $name${extra.isEmpty ? '' : '  ($extra)'}');
  }
}

/// 独立实现的 CRC32（逐位算，不建表）—— 用来校验 lib 里那张表算得对不对。
int crcBitwise(List<int> bytes, [int start = 0, int? end]) {
  var c = 0xFFFFFFFF;
  final e = end ?? bytes.length;
  for (var i = start; i < e; i++) {
    c ^= bytes[i];
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class _Chunk {
  final String type;
  final int offset; // 块起点（长度字段）
  final int len; // data 长度
  _Chunk(this.type, this.offset, this.len);
  int get total => 12 + len;
}

List<_Chunk> walk(Uint8List b) {
  final out = <_Chunk>[];
  var pos = 8;
  while (pos + 12 <= b.length) {
    final len = (b[pos] << 24) | (b[pos + 1] << 16) | (b[pos + 2] << 8) | b[pos + 3];
    final type = String.fromCharCodes(b, pos + 4, pos + 8);
    out.add(_Chunk(type, pos, len));
    pos += 12 + len;
    if (type == 'IEND') break;
  }
  return out;
}

int storedCrc(Uint8List b, _Chunk c) {
  final at = c.offset + 8 + c.len;
  return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}

void main() {
  final File asset = File('assets/branding/logo.png');
  if (!asset.existsSync()) {
    print('  ! 找不到 assets/branding/logo.png —— 必须在 flutter_app/ 目录下运行本自检');
    exit(1);
  }
  final Uint8List base = asset.readAsBytesSync();

  print('== 1. 底图本身是合法 PNG，且我们的 CRC32 与真实编码器一致 ==');
  ck('文件头是 PNG', isPng(base));
  final baseChunks = walk(base);
  ck('块结构解析完整（有 IHDR 和 IEND）',
      baseChunks.isNotEmpty && baseChunks.first.type == 'IHDR' && baseChunks.last.type == 'IEND',
      baseChunks.map((c) => c.type).join(','));
  var crcAllOk = true;
  for (final c in baseChunks) {
    final got = crc32(Uint8List.sublistView(base, c.offset + 4, c.offset + 8 + c.len));
    final want = storedCrc(base, c);
    if (got != want) {
      crcAllOk = false;
      print('    ${c.type}: 算得 $got，文件里是 $want');
    }
    // 再和位运算版对一遍（表写错只有这一步能抓到）
    final bit = crcBitwise(Uint8List.sublistView(base, c.offset + 4, c.offset + 8 + c.len));
    if (bit != got) {
      crcAllOk = false;
      print('    ${c.type}: 查表版 $got ≠ 位运算版 $bit');
    }
  }
  ck('所有既有块的 CRC32 校验通过（且查表版 == 位运算版）', crcAllOk,
      '${baseChunks.length} 个块');

  print('\n== 2. 写入 tEXt：位置、CRC、图片数据不变 ==');
  final fields = <String, Object?>{
    'id': '1700000000000',
    'name': '测试角色 · Test',
    'description': '一个用来验证导出链路的角色。\n第二行也要保留。',
    'firstMessage': '你好，我是测试角色。',
    'systemPrompt': '保持角色。',
    'avatar': '',
    'tags': ['测试', '  ', 'demo'],
  };
  final b64 = cardV2Base64(fields);
  final out = embedTextChunks(base, <String, String>{'chara': b64});

  ck('输出仍是 PNG', isPng(out));
  final outChunks = walk(out);
  final ihdrIdx = outChunks.indexWhere((c) => c.type == 'IHDR');
  final textIdx = outChunks.indexWhere((c) => c.type == 'tEXt');
  ck('tEXt 插在 IHDR 之后', ihdrIdx == 0 && textIdx == 1,
      '顺序=${outChunks.map((c) => c.type).take(3).join(',')}');
  ck('块总数 = 原块数 + 1', outChunks.length == baseChunks.length + 1,
      '${baseChunks.length} → ${outChunks.length}');
  ck('末尾仍是 IEND', outChunks.last.type == 'IEND');

  // 新块的 CRC 必须同时过「位运算版」这一关
  final t = outChunks[textIdx];
  final tCrc = crc32(Uint8List.sublistView(out, t.offset + 4, t.offset + 8 + t.len));
  ck('新 tEXt 块的 CRC 正确', tCrc == storedCrc(out, t) &&
      tCrc == crcBitwise(Uint8List.sublistView(out, t.offset + 4, t.offset + 8 + t.len)));

  // 把 tEXt 那一块挖掉，其余字节必须与原始底图逐字节相同（图片内容没被重编码）
  final stripped = BytesBuilder(copy: true)
    ..add(Uint8List.sublistView(out, 0, t.offset))
    ..add(Uint8List.sublistView(out, t.offset + t.total));
  final strippedBytes = stripped.toBytes();
  var samePixels = strippedBytes.length == base.length;
  if (samePixels) {
    for (var i = 0; i < base.length; i++) {
      if (strippedBytes[i] != base[i]) {
        samePixels = false;
        break;
      }
    }
  }
  ck('除新块外与底图逐字节相同（像素未被重编码）', samePixels,
      '${strippedBytes.length} vs ${base.length}');

  print('\n== 3. 读回来：关键字、base64、中文都能还原 ==');
  final read = readTextChunks(out);
  ck('读到一个 chara 块', read.containsKey('chara'));
  ck('读到的值与写入的一致', read['chara'] == b64);
  final back = decodeCardBase64(read['chara'] ?? '');
  ck('base64 → JSON 解得开', back != null);
  final data = (back?['data'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
  ck('中文描述往返无损', data['description'] == fields['description'],
      '${data['description']}');
  ck('换行没有被吃掉', '${data['description']}'.contains('\n'));

  print('\n== 4. 同名关键字先删后插（不留两份 chara）==');
  final out2 = embedTextChunks(out, <String, String>{'chara': cardV2Base64({...fields, 'name': '第二个'})});
  final tCount = walk(out2).where((c) => c.type == 'tEXt').length;
  ck('图里仍然只有一个 tEXt 块', tCount == 1, '实际 $tCount');
  final read2 = decodeCardBase64(readTextChunks(out2)['chara'] ?? '');
  ck('留下的是后写的那份',
      ((read2?['data'] ?? const {}) as Map)['name'] == '第二个');

  print('\n== 5. 非法输入必须抛错（不能静默写出坏图）==');
  var threw = false;
  try {
    embedTextChunks(Uint8List.fromList(utf8.encode('{"a":1}')), {'chara': 'x'});
  } on FormatException {
    threw = true;
  }
  ck('非 PNG 输入抛 FormatException', threw);

  threw = false;
  try {
    // 中文直接写 tEXt 会超出 Latin-1 —— 必须提示先转 base64，而不是写出乱码
    embedTextChunks(base, <String, String>{'chara': '{"名字":"测试"}'});
  } on FormatException {
    threw = true;
  }
  ck('非 Latin-1 文本抛 FormatException', threw);

  print('\n== 6. V2 信封字段（拼错键名不会报错，只会丢内容）==');
  final jsonStr = cardV2Json(fields);
  ck('带 spec', jsonStr.contains('"spec": "chara_card_v2"'));
  ck('spec_version = 2.0', jsonStr.contains('"spec_version": "2.0"'));
  ck('开场白写在 first_mes（不是 firstMessage）',
      jsonStr.contains('"first_mes"') && !jsonStr.contains('"firstMessage"'));
  ck('系统提示写在 system_prompt', jsonStr.contains('"system_prompt"'));
  final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
  final pd = parsed['data'] as Map<String, dynamic>;
  ck('tags 里空白项被剔除', (pd['tags'] as List).length == 2,
      '${pd['tags']}');
  ck('tags 去空白', (pd['tags'] as List).first == '测试');
  ck('character_book 显式为 null（读取方要求有这个键）',
      pd.containsKey('character_book') && pd['character_book'] == null);
  ck('extensions 里带回了本机 id',
      (pd['extensions'] as Map)['thirdhub_id'] == fields['id']);

  print('\n== 7. 文件名安全化（Windows 上非法字符会让写入静默失败）==');
  ck('路径分隔符被替换',
      !cardFileName('a/b\\c', 'png').contains(RegExp(r'[/\\]')),
      cardFileName('a/b\\c', 'png'));
  ck('非法字符全被替换',
      cardFileName('a:b*c?d"e<f>g|h', 'json') == 'a_b_c_d_e_f_g_h.json',
      cardFileName('a:b*c?d"e<f>g|h', 'json'));
  ck('空名字有兜底', cardFileName('   ', 'png') == 'character.png');
  ck('换行被压掉', cardFileName('第一行\n第二行', 'png') == '第一行_第二行.png',
      cardFileName('第一行\n第二行', 'png'));
  ck('超长名字被截断（不超文件系统单段上限）',
      cardFileName('名' * 80, 'png').length <= 44,
      '${cardFileName('名' * 80, 'png').length}');
  ck('正常名字原样保留', cardFileName('Seraphina', 'png') == 'Seraphina.png');

  print('\n== 8. 导入路径：从 PNG 取回卡片（4.81.24）==');
  final got = cardFromPng(out);
  ck('从自己导出的卡里读回卡片', got != null);
  final gd = (got?['data'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
  ck('名字往返无损（中文 + 间隔号）', gd['name'] == fields['name'], '${gd['name']}');
  ck('开场白往返无损', gd['first_mes'] == fields['firstMessage'], '${gd['first_mes']}');
  ck('系统提示往返无损', gd['system_prompt'] == fields['systemPrompt']);
  ck('描述里的换行往返无损', gd['description'] == fields['description']);
  ck('标签往返、空白项仍被剔除',
      gd['tags'] is List && (gd['tags'] as List).length == 2, '${gd['tags']}');

  // 没有 chara 的普通图片：必须判成"不是角色卡"，而不是崩掉或读出一张空卡
  final noCard = embedTextChunks(base, <String, String>{'Software': 'ThirdHub'});
  ck('没有 chara 块的图返回 null', cardFromPng(noCard) == null);
  ck('chara 是垃圾数据返回 null',
      cardFromPng(embedTextChunks(base, <String, String>{'chara': '!!!not-base64!!!'})) ==
          null);
  ck('chara 是空串返回 null',
      cardFromPng(embedTextChunks(base, <String, String>{'chara': '   '})) == null);
  ck('非 PNG 字节返回 null（不抛异常）',
      cardFromPng(Uint8List.fromList(utf8.encode('{"name":"x"}'))) == null);
  ck('被截断的 PNG 返回 null（不抛异常）',
      cardFromPng(Uint8List.sublistView(base, 0, 64)) == null);

  // ccv3 与 chara 并存：按新规范优先。两张都写、内容不同的情况真实存在
  //（工具链升级后重写卡时，旧 chara 往往没被清掉）。
  final both = embedTextChunks(base, <String, String>{
    'chara': cardV2Base64({...fields, 'name': 'chara 里的'}),
    'ccv3': cardV2Base64({...fields, 'name': 'ccv3 里的'}),
  });
  ck('ccv3 与 chara 并存时取 ccv3',
      ((cardFromPng(both)?['data'] ?? const <String, dynamic>{}) as Map)['name'] ==
          'ccv3 里的',
      '${cardFromPng(both)}');

  // 少数工具把**原始 JSON** 直接塞进 tEXt（不 base64）。这种卡一定不含中文
  // （tEXt 只收 Latin-1），但既然碰得到就不该判成"不是角色卡"。
  final rawJson = embedTextChunks(base, <String, String>{'chara': '{"name":"Plain"}'});
  ck('tEXt 里是原始 JSON 也能读', cardFromPng(rawJson)?['name'] == 'Plain',
      '${cardFromPng(rawJson)}');

  // 导入的是别人的卡：V2 信封 + 扁平格式都要能过 tryImport 那一关的字段名
  ck('外部 V2 卡的 first_mes 能被认出来',
      '${(cardFromPng(out)?['data'] as Map)['first_mes']}' == fields['firstMessage']);

  print('\n== 结果：$pass 通过 / $fail 失败 ==');
  if (fail > 0) {
    print('失败项：');
    for (final f in fails) {
      print('  · $f');
    }
    exit(1);
  }
}
