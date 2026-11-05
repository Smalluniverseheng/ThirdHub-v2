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
import 'dart:typed_data';

import 'png_text.dart';
import 'zip_reader.dart';
import 'zip_writer.dart';

/// 版本号：卡里 `character_version` 与 `extensions.thirdhub_*` 统一从这里取，
/// 别在两个文件里各写一遍。
const String kCardSpec = 'chara_card_v2';
const String kCardSpecVersion = '2.0';

/// 扁平旧格式里**值得带走**的字段。
///
/// 只白名单、不做"除已建模以外全带走"：扁平卡的根层除了内容字段，还混着
/// `chat`（整段聊天记录）、`talkativeness`、`fav` 这类运行时状态，全量搬会把
/// "导出角色卡"变成"导出聊天记录"，包体和隐私都不该这么走。
///
/// V2/V3 信封则相反 —— 那里的 `data` 就是卡片内容的全部，按"未建模即带走"
/// 处理，将来规范加了新字段（V3 的 `assets`、`nickname` 都是这么来的）也不会丢。
const List<String> kCarriedKeys = <String>[
  'personality',
  'scenario',
  'mes_example',
  'creator_notes',
  'post_history_instructions',
  'alternate_greetings',
  'character_book',
  'extensions',
  'nickname',
  'creator_notes_multilingual',
  'group_only_greetings',
  'assets',
];

/// 我们已经建模、会由用户输入或本机状态决定的键 —— 不作为"外来字段"搬运，
/// 否则旧值会把手改后的内容盖回去。
const Set<String> _modeledKeys = <String>{
  'name',
  'description',
  'first_mes',
  'firstMessage',
  'first_message',
  'system_prompt',
  'systemPrompt',
  'tags',
  'avatar',
};

/// 值能不能安全走一趟 JSON（不能的话留在内存里只会在 `jsonEncode` 时炸）。
bool _jsonSafe(Object? v) {
  if (v == null || v is String || v is num || v is bool) return true;
  if (v is List) return v.every(_jsonSafe);
  if (v is Map) {
    return v.keys.every((k) => k is String) && v.values.every(_jsonSafe);
  }
  return false;
}

/// 从外来卡里取出「我们没有建模」的字段（导入时留存、导出时原样写回）。
///
/// 这是 4.81.32 补的一条**数据保真**链路。此前的问题很隐蔽：
/// 导入别人的卡 → 只存了名字/设定/开场白/系统提示/标签 → 再导出时
/// `personality` / `scenario` / `mes_example` / `creator_notes` /
/// `alternate_greetings` / `character_book` 全被**写成空值**。
/// 卡片能导入、能导出、能再导入，看不出任何报错 —— 只是内容悄悄少了一半。
/// 对写卡的人来说这是毁数据，比报错严重得多。
///
/// 返回的 Map 直接进 `TavernChar.extras`，由 [cardV2] 写回 `data`。
Map<String, dynamic> carriedData(Object? raw) {
  final out = <String, dynamic>{};
  if (raw is! Map) return out;

  final data = raw['data'];
  if (data is Map) {
    for (final e in data.entries) {
      final k = '${e.key}';
      if (_modeledKeys.contains(k)) continue;
      if (!_jsonSafe(e.value)) continue;
      out[k] = e.value;
    }
    return out;
  }

  for (final k in kCarriedKeys) {
    if (raw.containsKey(k) && _jsonSafe(raw[k])) out[k] = raw[k];
  }
  return out;
}

/// 拼 V2 信封。
///
/// [f] 用我们内部的字段名（`firstMessage` / `systemPrompt` / `avatar`），
/// 输出时才翻译成 V2 的下划线写法 —— 只在这一处做映射。
///
/// 顺序很关键：**先铺 [carriedData] 搬来的未建模字段 → 再用自己的字段覆盖 →
/// 最后补默认值**。倒过来的话，导入时留下的旧 `description` 会把手改的内容盖回去，
/// 表现为"编辑完角色，设定又变回原样了"。
Map<String, dynamic> cardV2(Map<String, Object?> f) {
  String s(String k) => '${f[k] ?? ''}'.trim();
  final rawTags = f['tags'];
  final tags = rawTags is List
      ? rawTags.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList()
      : <String>[];
  final id = s('id');

  final carried = f['extras'];
  final data = <String, dynamic>{
    if (carried is Map)
      for (final e in carried.entries)
        if (e.key is String && _jsonSafe(e.value)) e.key as String: e.value,
  };

  final ver = s('characterVersion');
  final carriedVer = '${data['character_version'] ?? ''}'.trim();
  data.addAll(<String, dynamic>{
    'name': s('name'),
    'description': s('description'),
    'first_mes': s('firstMessage'),
    'system_prompt': s('systemPrompt'),
    'tags': tags,
    'character_version': ver.isNotEmpty ? ver : (carriedVer.isEmpty ? '1.0' : carriedVer),
  });

  // 这四个我们暂时没有独立输入框：卡里带过就沿用，没带过也要写全 ——
  // 读取方普遍按 V2 全字段反序列化，缺键在部分实现里会直接判成"不是 V2 卡"。
  data.putIfAbsent('creator', () => 'ThirdHub');
  for (final k in const <String>[
    'personality',
    'scenario',
    'mes_example',
    'creator_notes',
    'post_history_instructions',
  ]) {
    data.putIfAbsent(k, () => '');
  }
  data.putIfAbsent('alternate_greetings', () => <String>[]);
  data.putIfAbsent('character_book', () => null);

  final oldExt = data['extensions'];
  data['extensions'] = <String, dynamic>{
    if (oldExt is Map)
      for (final e in oldExt.entries)
        if (e.key is String) e.key as String: e.value,
    if (id.isNotEmpty) 'thirdhub_id': id,
    'thirdhub_avatar': s('avatar'),
  };

  return <String, dynamic>{
    'spec': kCardSpec,
    'spec_version': kCardSpecVersion,
    'data': data,
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

/// 纯 JSON 文本 → 卡片对象。手粘的文本、`.json` 文件都走这里。
///
/// 与 [decodeCardBase64] 分开是为了两条路都能**各自给出准确的失败原因**：
/// "base64 解不开"和"JSON 有语法错"对用户是两件事，混在一个 try 里就说不清了。
Map<String, dynamic>? decodeCardJson(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  try {
    final obj = jsonDecode(t);
    return obj is Map<String, dynamic> ? obj : null;
  } catch (_) {
    return null;
  }
}

/// 从一张 PNG 里取回卡片（导入路径的入口，对称于 [cardV2Base64] 的写出）。
///
/// 关键字按 `ccv3` → `chara` 的顺序试：
///   · `ccv3` 是 V3 规范的关键字，内容依然是 base64(JSON)，字段与 V2 同源，
///     交给 `TavernChar.tryImport` 能读出大部分（新字段读不到，但不至于整张卡丢掉）；
///   · 同一张图里两张都写且内容不同极少见，按新规范优先是更安全的默认。
///
/// 还有一个真实存在的变体：某些工具把**原始 JSON** 直接塞进 tEXt（不做 base64）。
/// tEXt 只收 Latin-1，所以这种卡一定不含中文；但既然碰得到，就不该判成"不是角色卡"。
/// 两种都试，都失败才返回 null。
Map<String, dynamic>? cardFromPng(Uint8List png) {
  final chunks = readTextChunks(png);
  for (final k in const <String>['ccv3', 'chara']) {
    final raw = chunks[k];
    if (raw == null) continue;
    final t = raw.trim();
    if (t.isEmpty) continue;
    final card = decodeCardJson(t) ?? decodeCardBase64(t);
    if (card != null) return card;
  }
  return null;
}

// ─────────────────────── .charx（zip 卡）───────────────────────

/// `.charx` 内嵌素材的**容量闸门**。
///
/// `.charx` 里除了卡片和头像，还可能带一堆素材图（V3 规范的 `assets/` 目录：
/// 立绘、背景、表情…）。这些东西我们既不渲染也不理解，但**丢了就是丢数据**：
/// 卡里写着 `embeded://assets/icon/main.png`，包却不带这张图，对方打开就是裂图。
///
/// 但也不能无限收：`unzip` 是整包解进内存的，一张几百 MB 的包足以把手机打爆。
/// 超限**静默跳过**（不失败整张卡）—— 宁可少带几张大图，也要把卡片本身导进来。
const int kMaxAssetFile = 8 * 1024 * 1024; // 单文件 8MB
const int kMaxAssetTotal = 24 * 1024 * 1024; // 合计 24MB
const int kMaxAssetCount = 64; // 条目数

/// 把 zip 条目名规范化成「包内相对路径」；不安全的返回 null。
///
/// 这段存在的唯一理由是**安全**：zip 条目名是压缩包作者写的，`../../` 之类
/// 的路径在解包落盘时会写到应用目录之外（zip-slip）。遇到就整条丢弃，
/// 不做"消解成合法路径"——把恶意条目洗成合法文件，反而放行了它。
///
/// 另外 `\\` 统一成 `/`：Windows 上打的包常有反斜杠，照原样当路径用会建出
/// 一个名叫 `a\b.png` 的文件（不是目录），Mac/安卓上表现又不一样。
String? safeEntryPath(String name) {
  var n = name.replaceAll('\\', '/').trim();
  while (n.startsWith('./')) {
    n = n.substring(2);
  }
  while (n.startsWith('/')) {
    n = n.substring(1);
  }
  if (n.isEmpty) return null;
  final out = <String>[];
  for (final s in n.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') return null; // ★路径穿越
    if (s.contains(':')) return null; // Windows 盘符 / NTFS ADS
    out.add(s);
  }
  if (out.isEmpty) return null;
  return out.join('/');
}

/// 从解开的包里挑出**素材**（`assets/` 下的文件），按容量闸门过滤。
///
/// 只认 `assets/` 前缀：根层的 `card.json`、`avatar.*` 不是素材，包里夹带的
/// `readme.txt` 之类也不该跟着我们走（那是别人的说明文件，不是卡片数据）。
Map<String, Uint8List> cardAssetsOf(Map<String, Uint8List> files) {
  final out = <String, Uint8List>{};
  var total = 0;
  final names = files.keys.toList()..sort(); // 稳定顺序，保证导出可复现
  for (final n in names) {
    final p = safeEntryPath(n);
    if (p == null) continue;
    if (!p.toLowerCase().startsWith('assets/')) continue;
    final b = files[n]!;
    if (b.isEmpty) continue;
    if (b.length > kMaxAssetFile) continue;
    if (out.length >= kMaxAssetCount) break;
    if (total + b.length > kMaxAssetTotal) break;
    total += b.length;
    out[p] = b;
  }
  return out;
}

/// `.charx` 解出来的东西：卡片 + 头像字节 + 头像扩展名 + 内嵌素材。
///
/// 为什么不直接返回卡片：`.charx` 把头像**放在压缩包里**（不像 PNG 卡那样
/// 图就是文件本身），不把它落盘的话，导进来的角色永远只有首字占位。
class CharxCard {
  CharxCard(this.card, this.avatar, this.avatarExt,
      [this.assets = const <String, Uint8List>{}]);
  final Map<String, dynamic> card;
  final Uint8List? avatar;
  final String? avatarExt;

  /// 包内 `assets/` 下的素材，键是**已规范化**的包内相对路径。
  final Map<String, Uint8List> assets;
}

/// 从 `.charx`（zip）里取卡片。
///
/// 结构上只认两样东西：
///   · `card.json` —— 卡片本体，位置按「根目录优先、层级最浅」挑；
///   · 一张图片 —— 当头像。
///
/// 头像不走 `data.assets` 的索引表（Risu 用自己的 `ccdefault:` 约定，各家实现
/// 还不一致，照抄容易读错位）：改成「根目录优先 → 体积最大」的启发式。
/// 一张角色卡里放多张图的极少，误选也只是头像不对，卡片数据不会丢。
///
/// 解不开、没有 `card.json`、或 `card.json` 不是 JSON 对象 → 返回 null，
/// 调用方据此提示"这不是 .charx 角色卡"。
CharxCard? cardFromCharx(Uint8List zip) {
  final files = unzip(zip);
  if (files == null) return null;

  final cardName = pickEntryName(
      files, (n) => n.toLowerCase().split('/').last == 'card.json');
  if (cardName == null) return null;
  final card = decodeCardJson(utf8.decode(files[cardName]!, allowMalformed: true));
  if (card == null) return null;

  // 头像候选：常见图片扩展名，且不是 card.json 自己。
  const exts = <String>['png', 'jpg', 'jpeg', 'webp'];
  bool isImg(String n) {
    final lower = n.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return false;
    return exts.contains(lower.substring(dot + 1));
  }

  final names = files.keys.where((n) => n != cardName && isImg(n)).toList();
  names.sort((a, b) {
    final da = '/'.allMatches(a).length, db = '/'.allMatches(b).length;
    if (da != db) return da - db; // 根目录优先
    final sa = files[a]!.length, sb = files[b]!.length;
    if (sa != sb) return sb - sa; // 同层取大的
    return a.compareTo(b);
  });

  // 素材（`assets/` 下的图等）单独收一份：卡片 JSON 里只写着 uri，
  // 图本身不带的话，对方打开永远是裂图。
  final assets = cardAssetsOf(files);

  if (names.isEmpty) return CharxCard(card, null, null, assets);
  final avatarName = names.first;
  final ext = avatarName
      .substring(avatarName.toLowerCase().lastIndexOf('.') + 1)
      .toLowerCase();
  return CharxCard(card, files[avatarName], ext, assets);
}

/// 拼一个 `.charx`（zip 角色卡）—— 导入的逆运算，也是本文件里唯一"写"的方向。
///
/// 包内结构（与 [cardFromCharx] 的读法对称，也是 Risu 系的通行结构）：
///   · `card.json` —— V2 信封全文，**必须放根目录**（读取方普遍按根名找）；
///   · `avatar.<ext>` —— 头像原图；
///   · `assets/…` —— 内嵌素材（V3 的立绘/背景/表情），**路径原样保留**：
///     卡里的 uri 写的就是 `embeded://assets/icon/main.png`，路径一改就指不到了。
///
/// 4.81.33 起才带素材。此前导入带 `assets/` 的卡，字段（`assets` 数组）被
/// 原样搬走了，**图却没跟着走** —— 导回去是一张指向空目录的卡，对方全是裂图。
/// 字段保真做了一半，比不保真更糟：看得出有素材，就是加载不出来。
///
/// 为什么头像可以缺：PNG 卡**必须**有外壳图（数据藏在图里），所以导出 PNG 时
/// 拿不到头像只能用应用图标兜底；`.charx` 不是 —— 没有头像时就真的不该写图，
/// 塞一张 logo 会让对方以为那就是角色长相。缺图时 [cardFromCharx] 返回
/// `avatar == null`，导入端会退回首字占位，这条链路本来就是通的。
///
/// 扩展名只放行 `png/jpg/jpeg/webp`，其余一律按 `png` 写 —— 拼错的扩展名会让
/// 对方的图片加载器直接放弃（不是"解码失败"，是"根本不尝试"）。
Uint8List charxZip(
  Map<String, Object?> f, {
  Uint8List? avatar,
  String? avatarExt,
  Map<String, List<int>>? assets,
}) {
  const allowed = <String>{'png', 'jpg', 'jpeg', 'webp'};
  var ext = '${avatarExt ?? ''}'.trim().toLowerCase();
  if (!allowed.contains(ext)) ext = 'png';

  // 素材先过同一道闸门（路径规范化 + 容量上限），再决定要不要另写一份头像。
  final packed = <String, List<int>>{};
  var total = 0;
  if (assets != null) {
    final keys = assets.keys.toList()..sort(); // 稳定顺序 → 同样输入同样字节
    for (final k in keys) {
      final p = safeEntryPath(k);
      if (p == null) continue;
      if (!p.toLowerCase().startsWith('assets/')) continue;
      final v = assets[k]!;
      if (v.isEmpty || v.length > kMaxAssetFile) continue;
      if (packed.length >= kMaxAssetCount) break;
      if (total + v.length > kMaxAssetTotal) break;
      total += v.length;
      packed[p] = v;
    }
  }

  final u8 = (avatar != null && avatar.isNotEmpty) ? avatar : null;
  // 头像与某个素材**字节相同**时不另写 `avatar.<ext>`：同一张图在包里出现两次
  // 只是把包体翻倍，而读取方本来就是照 `assets` 的 uri 取那张。
  // 这条还保证了往返的字节稳定性：导出的包再导回来，素材仍在原位，
  // 下一次导出依旧不会多出头像条目。
  final dup = u8 != null && packed.values.any((v) => sameBytes(v, u8));

  return zipStore(<String, List<int>>{
    'card.json': utf8.encode(cardV2Json(f)),
    if (u8 != null && !dup) 'avatar.$ext': u8,
    ...packed,
  });
}

/// 逐字节比较（`List<int>` 的 `==` 是引用比较，用它做去重会永远失败）。
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 导出文件名：角色名 → 安全文件名。
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
