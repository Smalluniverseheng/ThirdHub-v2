// 酒馆角色卡的**导出编解码**（纯 Dart，零 Flutter 依赖）。
//
// 为什么单独一个文件：`tavern.dart` 依赖 flutter/material，`dart run` 跑不起来，
// 于是"导出的 JSON 到底长什么样"就只能靠人眼在手机上验。这里把信封拼装抽成
// 纯函数，`tool/tavern_export_selfcheck.dart` 就能直接断言字段、断言能被
// `TavernChar.tryImport` 读回来 —— 形状断言 + 往返断言，两头都钉住。
//
// 为什么是 SillyTavern **V2** 信封（`{spec, spec_version, data}`）而不是扁平格式：
//   社区里分发的卡、以及各大酒馆前端导出的卡，V2 已是事实标准；扁平格式是旧版。
//   我们**导入**两种都认（见 `TavernChar.tryImport`），**导出**只出 V2 ——
//   出一份"谁都能读"的，比出两份让人挑更省事。
//
// 字段名的坑：V2 里是 `first_mes` / `system_prompt`（下划线），不是我们内部的
// `firstMessage` / `systemPrompt`。拼错了不会报错，只会导出成一张"没有开场白、
// 没有系统提示"的空卡 —— 所以自检里对这两个键名有专门断言。

import 'dart:convert';

/// 版本号：卡里 `character_version` 与 `extensions.thirdhub_*` 统一从这里取，
/// 别在两个文件里各写一遍。
const String kCardSpec = 'chara_card_v2';
const String kCardSpecVersion = '2.0';

/// 拼 V2 信封。
///
/// [f] 用我们内部的字段名（`firstMessage` / `systemPrompt` / `avatar`），
/// 输出时才翻译成 V2 的下划线写法 —— 只在这一处做映射。
Map<String, dynamic> cardV2(Map<String, Object?> f) {
  String s(String k) => '${f[k] ?? ''}'.trim();
  final rawTags = f['tags'];
  final tags = rawTags is List
      ? rawTags.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList()
      : <String>[];
  final id = s('id');

  return <String, dynamic>{
    'spec': kCardSpec,
    'spec_version': kCardSpecVersion,
    'data': <String, dynamic>{
      'name': s('name'),
      'description': s('description'),
      // 这四个我们暂时没有独立输入框，但仍要写全：读取方普遍按 V2 全字段反序列化，
      // 缺键在部分实现里会直接判成"不是 V2 卡"。
      'personality': '',
      'scenario': '',
      'mes_example': '',
      'creator_notes': '',
      'first_mes': s('firstMessage'),
      'system_prompt': s('systemPrompt'),
      'post_history_instructions': '',
      'alternate_greetings': <String>[],
      'character_book': null,
      'tags': tags,
      'creator': 'ThirdHub',
      'character_version': s('characterVersion').isEmpty ? '1.0' : s('characterVersion'),
      'extensions': <String, dynamic>{
        if (id.isNotEmpty) 'thirdhub_id': id,
        'thirdhub_avatar': s('avatar'),
      },
    },
  };
}

/// 带缩进的 JSON —— 给人看、给别的 App 直接拖进去用。
/// 缩进两格：手机上也能一眼看出层级，体积对一张卡无所谓。
String cardV2Json(Map<String, Object?> f) =>
    const JsonEncoder.withIndent('  ').convert(cardV2(f));

/// PNG tEXt 里存的内容：**紧凑 JSON 的 base64**。
///
/// 两层转换缺一不可：JSON 里有中文（3 字节 UTF-8），tEXt 只收 Latin-1，
/// 所以必须先 utf8 编码再 base64；反过来导入时 base64 解码 → utf8 解码。
String cardV2Base64(Map<String, Object?> f) =>
    base64Encode(utf8.encode(jsonEncode(cardV2(f))));

/// 从 PNG 里读出来的 base64 还原成卡（也就是 SillyTavern 的读法）。
/// 解不开返回 null —— 调用方据此提示"这张图不是角色卡"。
Map<String, dynamic>? decodeCardBase64(String b64) {
  try {
    final obj = jsonDecode(utf8.decode(base64Decode(b64.trim())));
    return obj is Map<String, dynamic> ? obj : null;
  } catch (_) {
    return null;
  }
}

/// 导出文件名：角色名 → 安全文件名。
///
/// 名字里的 `/ \ : * ? " < > |` 和换行会让写入失败（Windows 上是**静默**失败，
/// 表现为"点了导出没反应"）。这里统一换成下划线，压缩空白，并限长 40 字
/// （安卓文件系统的单段上限是 255 **字节**，中文按 3 字节算，40 字足够安全）。
String cardFileName(String name, String ext) {
  var s = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) s = 'character';
  if (s.length > 40) s = s.substring(0, 40);
  return '$s.$ext';
}
