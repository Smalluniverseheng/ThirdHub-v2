// `.charx`（zip 角色卡）导入链路的纯 Dart 自检。
//
// 覆盖两件事：
//   ① `zip_reader.dart` 能不能正确解出条目 —— 自己**造** zip（store + deflate 各一份），
//      断言内容逐字节相等，而不是"能不能跑通不报错"；
//   ② `cardFromCharx()` 的挑法 —— card.json 的位置优先级、头像选择、缺件时的返回。
//
// 为什么必须自己造 zip：手边没有真实的 `.charx` 样本，而"能读别人做的包"这件事
// 恰恰只能靠格式层面的断言来保证。自己造的包走的是同一套中央目录/本地头结构，
// 格式错了自检就红。
//
// 运行：`dart run tool/charx_selfcheck.dart`（退出码非 0 = 有断言失败）

import 'dart:convert';
import 'dart:io' show ZLibEncoder, exitCode;
import 'dart:typed_data';

import 'package:thirdhub_app/core/tavern_card_codec.dart';
import 'package:thirdhub_app/core/zip_reader.dart';

int pass = 0, fail = 0;
void ok(bool cond, String what) {
  if (cond) {
    pass++;
  } else {
    fail++;
    print('FAIL  $what');
  }
}

// ───────────────── 造 zip 的小工具 ─────────────────

void _u16(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

void _u32(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 24) & 0xFF);
}

/// 造一个 zip。[deflate] 为 true 时用 deflate（方法 8），否则 store（方法 0）。
Uint8List makeZip(Map<String, List<int>> files, {bool deflate = false}) {
  final central = BytesBuilder();
  final local = BytesBuilder();
  var offset = 0;
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final raw = Uint8List.fromList(e.value);
    final comp = deflate ? ZLibEncoder(raw: true).convert(raw) : raw;
    final method = deflate ? 8 : 0;
    final start = offset;

    _u32(local, 0x04034b50);
    _u16(local, 20);
    _u16(local, 0x800); // 文件名 UTF-8
    _u16(local, method);
    _u16(local, 0); // time
    _u16(local, 0); // date
    _u32(local, 0); // crc（本读取器不校验）
    _u32(local, comp.length);
    _u32(local, raw.length);
    _u16(local, name.length);
    _u16(local, 0);
    local.add(name);
    local.add(comp);

    _u32(central, 0x02014b50);
    _u16(central, 20);
    _u16(central, 20);
    _u16(central, 0x800);
    _u16(central, method);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, comp.length);
    _u32(central, raw.length);
    _u16(central, name.length);
    _u16(central, 0); // extra
    _u16(central, 0); // comment
    _u16(central, 0); // disk
    _u16(central, 0); // int attr
    _u32(central, 0); // ext attr
    _u32(central, start);
    central.add(name);
    offset += 30 + name.length + comp.length;
  }
  final cd = central.toBytes();
  final out = BytesBuilder();
  out.add(local.toBytes());
  out.add(cd);
  _u32(out, 0x06054b50);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, files.length);
  _u16(out, files.length);
  _u32(out, cd.length);
  _u32(out, offset);
  _u16(out, 0);
  return out.toBytes();
}

/// 一张最小 PNG（只要签名够 `isPng` 认；头像内容不参与断言）。
final Uint8List fakePng = Uint8List.fromList(<int>[
  137, 80, 78, 71, 13, 10, 26, 10, //
  0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
]);

final String cardJson = jsonEncode(<String, dynamic>{
  'spec': 'chara_card_v2',
  'spec_version': '2.0',
  'data': <String, dynamic>{
    'name': '测试角色',
    'description': '一句话简介',
    'first_mes': '你好',
    'tags': <String>['测试'],
  },
});

void main() {
  // ── 1. 魔数 ──
  final z = makeZip(<String, List<int>>{'a.txt': utf8.encode('hello')});
  ok(isZip(z), 'isZip 认自己造的 zip');
  ok(!isZip(fakePng), 'isZip 不把 PNG 当 zip');
  ok(!isZip(utf8.encode('{"name":"x"}')), 'isZip 不把 JSON 文本当 zip');
  ok(!isZip(<int>[0x50, 0x4B]), 'isZip 对超短输入不越界');
  ok(unzip(fakePng) == null, 'unzip 遇到 PNG 返回 null 而不是抛异常');

  // ── 2. store 解包 ──
  final files = unzip(z);
  ok(files != null, 'store zip 能解开');
  ok(files?['a.txt'] != null, 'store zip 里能拿到 a.txt');
  ok(utf8.decode(files?['a.txt'] ?? <int>[]) == 'hello', 'store 内容逐字节一致');

  // ── 3. deflate 解包（★真实 .charx 基本都是 deflate）──
  final dz = makeZip(<String, List<int>>{
    'card.json': utf8.encode(cardJson),
    'assets/a.png': fakePng,
  }, deflate: true);
  final dfiles = unzip(dz);
  ok(dfiles != null, 'deflate zip 能解开');
  ok(dfiles?.length == 2, 'deflate zip 条目数为 2');
  ok(utf8.decode(dfiles?['card.json'] ?? <int>[]) == cardJson,
      'deflate 的 card.json 解压后与原文一致（中文不乱码）');
  ok((dfiles?['assets/a.png'] ?? <int>[]).length == fakePng.length,
      'deflate 的二进制条目长度一致');

  // ── 4. cardFromCharx：根目录 card.json + 头像 ──
  final c = cardFromCharx(dz);
  ok(c != null, 'cardFromCharx 能从 deflate charx 取到卡');
  final data = c?.card['data'];
  ok(data is Map && data['name'] == '测试角色', 'cardFromCharx 保住了角色名（中文）');
  ok(c?.avatar != null, 'cardFromCharx 取到了头像');
  ok(c?.avatarExt == 'png', '头像扩展名识别为 png');
  ok((c?.avatar?.length ?? 0) == fakePng.length, '头像字节完整');

  // ── 5. 根目录 card.json 优先于子目录 ──
  final nested = makeZip(<String, List<int>>{
    'old/card.json': utf8.encode(cardJson.replaceAll('测试角色', '旧角色')),
    'card.json': utf8.encode(cardJson),
  });
  ok(cardFromCharx(nested)?.card['data']['name'] == '测试角色',
      '根目录 card.json 优先于子目录同名文件');

  // ── 6. 没有卡片 / 不是 zip ──
  final noCard = makeZip(<String, List<int>>{'readme.txt': utf8.encode('x')});
  ok(cardFromCharx(noCard) == null, '没有 card.json 时返回 null');
  ok(cardFromCharx(fakePng) == null, '喂 PNG 时返回 null');
  ok(cardFromCharx(Uint8List.fromList(<int>[1, 2, 3])) == null,
      '喂垃圾字节时返回 null（不崩）');

  // ── 7. card.json 不是 JSON 对象 ──
  final badCard =
      makeZip(<String, List<int>>{'card.json': utf8.encode('[1,2,3]')});
  ok(cardFromCharx(badCard) == null, 'card.json 是数组时返回 null');

  // ── 8. 没有头像也照常导入 ──
  final noAvatar =
      makeZip(<String, List<int>>{'card.json': utf8.encode(cardJson)});
  final na = cardFromCharx(noAvatar);
  ok(na != null && na.avatar == null, '无头像的 charx 仍能取到卡、头像为 null');
  ok(na?.avatarExt == null, '无头像时扩展名为 null');

  // ── 9. 截断的 zip 不崩 ──
  final truncated = Uint8List.fromList(dz.sublist(0, dz.length ~/ 2));
  var threw = false;
  try {
    cardFromCharx(truncated);
  } catch (_) {
    threw = true;
  }
  ok(!threw, '截断的 zip 抛异常（应为"返回 null 不崩"）');

  // ── 10. 文件名大小写与路径 ──
  final upper = makeZip(<String, List<int>>{
    'CARD.JSON': utf8.encode(cardJson),
    'avatar.JPG': fakePng,
  });
  final u = cardFromCharx(upper);
  ok(u != null, '大写 CARD.JSON 也认');
  ok(u?.avatarExt == 'jpg', '扩展名统一转小写');

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exitCode = 1;
}
