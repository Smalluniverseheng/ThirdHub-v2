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

import 'package:thirdhub_app/core/i18n_ui_words.dart';
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

  // ═══════════ 导出方向（4.81.31）：charxZip ═══════════
  //
  // 读的方向已经钉住，写的方向要用**往返**来钉：自己写的包，用自己的读器读回来，
  // 字段与头像字节必须一模一样。再加一层结构断言（EOCD 偏移/大小/条目数），
  // 因为"能读回来"可能只是读写两边犯同一个错，结构断言能把这种自洽错误顶出来。

  final fields = <String, Object?>{
    'id': 'abc123',
    'name': '测试角色',
    'description': '一句话简介',
    'firstMessage': '你好',
    'systemPrompt': '你是助手',
    'avatar': '',
    'tags': <String>['测试'],
  };

  final pack = charxZip(fields, avatar: fakePng, avatarExt: 'png');
  ok(isZip(pack), 'charxZip 写出的字节是合法 zip');
  final pf = unzip(pack);
  ok(pf != null && pf.length == 2, '导出的包恰好 2 个条目（card.json + 头像）');
  ok(pf?.containsKey('card.json') == true, 'card.json 在包根目录');
  ok(pf?.containsKey('avatar.png') == true, '头像命名为 avatar.png');
  ok(_bytesEqual(pf?['avatar.png'], fakePng), '包内头像字节逐字节一致');

  final back = cardFromCharx(pack);
  ok(back != null, '自己写的包能被 cardFromCharx 读回（往返不失败）');
  final bd = back?.card['data'];
  ok(back?.card['spec'] == 'chara_card_v2', '包内是 V2 信封（spec 键正确）');
  ok(bd is Map && bd['name'] == '测试角色', '往返后 name 一致（中文 UTF-8 无损）');
  ok(bd is Map && bd['first_mes'] == '你好', '往返后 first_mes 一致（V2 下划线键）');
  ok(bd is Map && bd['system_prompt'] == '你是助手', '往返后 system_prompt 一致');
  ok(back?.avatarExt == 'png', '往返后头像扩展名为 png');
  ok(_bytesEqual(back?.avatar, fakePng), '往返后头像字节一致');

  final pack2 = charxZip(fields, avatar: fakePng, avatarExt: 'png');
  ok(_bytesEqual(pack, pack2), '同样输入写出逐字节相同的包（时间戳固定，可比对）');

  ok(unzip(charxZip(fields))?.length == 1, '无头像时只有 card.json 一个条目');
  ok(cardFromCharx(charxZip(fields))?.avatar == null, '无头像的包读回来 avatar 为 null');
  ok(unzip(charxZip(fields, avatar: Uint8List(0)))?.length == 1,
      '空头像字节不写条目（不产生 0 字节图）');
  ok(
      unzip(charxZip(fields, avatar: fakePng, avatarExt: 'JPG'))
              ?.containsKey('avatar.jpg') ==
          true,
      '扩展名统一转小写');
  ok(
      unzip(charxZip(fields, avatar: fakePng, avatarExt: 'exe'))
              ?.containsKey('avatar.png') ==
          true,
      '非法扩展名回落 png（不让对方加载器卡住）');

  // ── 12. 包结构：EOCD 的两个字段没写反 ──
  var eo = -1;
  for (var i = pack.length - 22; i >= 0; i--) {
    if (_u32At(pack, i) == 0x06054B50) {
      eo = i;
      break;
    }
  }
  ok(eo > 0, 'EOCD 签名存在');
  var cdStart = -1;
  for (var i = 0; i < eo; i++) {
    if (_u32At(pack, i) == 0x02014B50) {
      cdStart = i;
      break;
    }
  }
  ok(cdStart > 0, '中央目录签名存在');
  ok(_u32At(pack, eo + 16) == cdStart, 'EOCD 的「中央目录偏移」( +16 ) 指向真实位置');
  ok(_u32At(pack, eo + 12) == eo - cdStart, 'EOCD 的「中央目录大小」( +12 ) 等于实际字节数');
  ok(_u16At(pack, eo + 10) == 2, 'EOCD 记录的总条目数为 2');
  ok(_u32At(pack, cdStart + 42) == 0, '第一个中央目录条目指向本地头偏移 0');
  ok(_u16At(pack, cdStart + 8) == 0x800, '中央目录置了 UTF-8 文件名标志位');
  ok(_u16At(pack, 6) == 0x800, '本地头置了 UTF-8 文件名标志位（+6：签名 4 + 版本 2）');

  // ═══════════ 内嵌素材（4.81.33）：`assets/` 保真 ═══════════
  //
  // V3 卡把立绘/背景/表情放在包内 `assets/`，卡片 JSON 里只写
  // `embeded://assets/…` 这样的 uri。此前我们只搬字段不搬图 —— 导回去是一张
  // "指向空目录的卡"：字段说有素材，实际一个文件也没有，对方全是裂图。
  // 这一节把「路径规范化」「双向搬运」「容量闸门」各自钉住。

  // ── 14.1 路径规范化（zip-slip 防线）──
  ok(safeEntryPath('assets/icon/main.png') == 'assets/icon/main.png',
      '普通素材路径原样保留');
  ok(safeEntryPath('/assets/a.png') == 'assets/a.png', '去掉前导斜杠');
  ok(safeEntryPath('./assets/a.png') == 'assets/a.png', '去掉 ./ 前缀');
  ok(safeEntryPath('assets\\icon\\a.png') == 'assets/icon/a.png', '反斜杠统一成正斜杠');
  ok(safeEntryPath('../../evil.png') == null, '拒绝纯路径穿越');
  ok(safeEntryPath('assets/../../evil.png') == null, '拒绝夹在中间的路径穿越');
  ok(safeEntryPath('C:/Windows/x.png') == null, '拒绝盘符（Windows 上会被当绝对路径）');
  ok(safeEntryPath('') == null && safeEntryPath('   ') == null, '空名返回 null');

  // ── 14.2 导入侧：收素材，坏条目与超大条目被挡在外面 ──
  final withAssets = makeZip(<String, List<int>>{
    'card.json': utf8.encode(cardJson),
    'assets/icon/main.png': <int>[1, 2, 3, 4],
    'assets/bg/room.jpg': <int>[9, 8, 7],
    'assets/empty.png': <int>[],
    'assets/huge.bin': Uint8List(kMaxAssetFile + 1),
    '../../evil.png': <int>[6, 6, 6],
    'readme.txt': utf8.encode('别人的说明'),
  });
  final wa = cardFromCharx(withAssets);
  ok(wa != null, '带素材的 charx 仍能取到卡');
  ok(wa?.assets.length == 2, '只收 assets/ 下的有效素材（2 个）');
  ok(wa?.assets.containsKey('assets/icon/main.png') == true, '素材在包内的路径就是键');
  ok(_bytesEqual(wa?.assets['assets/icon/main.png'], <int>[1, 2, 3, 4]),
      '素材字节逐字节一致');
  ok(!(wa?.assets.keys.any((k) => k.contains('..')) ?? true), '路径穿越条目没被收进来');
  ok(wa?.assets.containsKey('readme.txt') != true, '非 assets/ 的文件不当素材');
  ok(wa?.assets.containsKey('assets/empty.png') != true, '0 字节素材跳过');
  ok(wa?.assets.containsKey('assets/huge.bin') != true, '超过单文件上限的素材跳过');

  // ── 14.3 导出侧：素材跟着写进包，路径不改 ──
  final assetPack = charxZip(fields, assets: <String, List<int>>{
    'assets/icon/main.png': <int>[1, 2, 3, 4],
    'assets/bg/room.jpg': <int>[9, 8, 7],
  });
  final ap = unzip(assetPack);
  ok(ap?.containsKey('card.json') == true, '带素材的包仍有 card.json');
  ok(ap?.containsKey('assets/icon/main.png') == true, '素材路径在包内原样保留');
  ok(_bytesEqual(ap?['assets/bg/room.jpg'], <int>[9, 8, 7]), '包内素材字节一致');
  ok(ap?.length == 3, '无头像时三条目（card + 两个素材）');

  // ── 14.4 往返：导出 → 再导入，素材还在且字节不变 ──
  final artBack = cardFromCharx(assetPack);
  ok(artBack?.assets.length == 2, '往返后素材数量一致');
  ok(_bytesEqual(artBack?.assets['assets/icon/main.png'], <int>[1, 2, 3, 4]),
      '往返后素材字节一致');
  ok(
      _bytesEqual(
          assetPack,
          charxZip(fields, assets: <String, List<int>>{
            'assets/bg/room.jpg': <int>[9, 8, 7],
            'assets/icon/main.png': <int>[1, 2, 3, 4],
          })),
      '素材传入顺序不影响输出字节（按路径排序）');

  // ── 14.5 头像与素材重复时只写一份 ──
  final dp = unzip(charxZip(fields,
      avatar: Uint8List.fromList(<int>[1, 2, 3, 4]),
      avatarExt: 'png',
      assets: <String, List<int>>{
        'assets/icon/main.png': <int>[1, 2, 3, 4]
      }));
  ok(dp?.containsKey('avatar.png') != true, '头像与素材字节相同 → 不另写 avatar.png');
  ok(dp?.containsKey('assets/icon/main.png') == true, '去重后素材仍在原位');
  final keepBoth = unzip(charxZip(fields,
      avatar: fakePng,
      avatarExt: 'png',
      assets: <String, List<int>>{
        'assets/icon/main.png': <int>[1, 2, 3, 4]
      }));
  ok(keepBoth?.containsKey('avatar.png') == true && keepBoth?.length == 3,
      '头像与素材不同 → 两份都写');

  // ── 14.6 导出侧同样挡路径穿越 ──
  final evil = unzip(charxZip(fields, assets: <String, List<int>>{
    '../../evil.png': <int>[1],
    'assets/../x.png': <int>[2],
    'assets/ok.png': <int>[3],
  }));
  ok(evil?.containsKey('assets/ok.png') == true, '合法素材照常写入');
  ok(evil?.length == 2, '非法路径的素材被丢弃（只剩 card.json + 合法素材）');
  ok(!(evil?.keys.any((k) => k.contains('..')) ?? true), '包内没有 ../ 条目');

  // ── 14.7 条目数闸门 ──
  final many = <String, List<int>>{
    for (var i = 0; i < kMaxAssetCount + 5; i++)
      'assets/i$i.png': <int>[i & 0xFF],
  };
  final mp = unzip(charxZip(fields, assets: many));
  ok(mp?.length == kMaxAssetCount + 1,
      '素材条目数封顶（$kMaxAssetCount 个 + card.json）');

  // ── 13. 新增文案六语言齐备（防止只补中文）──
  const uiKeys = <String>[
    'CHARX 压缩包（含头像）',
    '卡片与头像分开装，改图不影响数据；Risu 系酒馆直接能读',
  ];
  for (final lang in <String>['en', 'ja', 'fr', 'ru', 'es', 'ar']) {
    final words = i18nUiWords12[lang];
    for (final k in uiKeys) {
      ok((words?[k] ?? '').trim().isNotEmpty, '[$lang] 第十二批译文缺失：$k');
    }
  }

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exitCode = 1;
}

bool _bytesEqual(List<int>? a, List<int>? b) {
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _u16At(List<int> b, int o) => b[o] | (b[o + 1] << 8);

int _u32At(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
