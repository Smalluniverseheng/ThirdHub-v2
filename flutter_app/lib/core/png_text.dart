// PNG 文本块（tEXt）读写 —— 纯 Dart，零 Flutter 依赖，可被 `dart run` 直接自检。
//
// 为什么需要它：
//   酒馆角色卡在社区里分发时用的是「把卡片 JSON 塞进 PNG 的 tEXt 块」这个约定
//   （SillyTavern 认的关键字是 `chara`，值是 base64 后的 JSON）。图片本身只是外壳，
//   导入方读的永远是那段 base64。App 端想导出「别人能直接拖进去用」的卡，
//   就必须自己会写这个块。
//
// 为什么不用 `image` 包：
//   本机 `PUB_CACHE` 是空的（0 个包），加一个新依赖等于把「能不能编译」押在
//   没在本机验过的 API 上。而 tEXt 的格式只有三段（长度 / 类型 / 数据 + CRC32），
//   几十行就能写对，还能被纯 Dart 自检逐字节覆盖 —— 比引依赖更稳。
//
// 格式（PNG 规范 §11.3.4.3，tEXt）：
//   data = keyword(1~79 字节 Latin-1) + 0x00 + text(Latin-1，不含 0x00)
//   块   = 长度(4, 大端) + "tEXt"(4) + data + CRC32(4, 覆盖"类型+data")
//
// ★两个容易写错的点：
//   ① CRC 覆盖的是 **类型 + 数据**，不含长度字段；
//   ② tEXt 的 text 是 **Latin-1**，中文塞不进去（latin1.encode 会抛）。
//      所以卡 JSON 必须先 utf8 → base64，不能直接把中文写进去。

import 'dart:convert';
import 'dart:typed_data';

/// PNG 文件头 8 字节。
const List<int> pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

bool isPng(List<int> bytes) {
  if (bytes.length < pngSignature.length) return false;
  for (var i = 0; i < pngSignature.length; i++) {
    if (bytes[i] != pngSignature[i]) return false;
  }
  return true;
}

/// 把一个或多个 tEXt 块写进 PNG，插在 IHDR 之后（规范要求 IHDR 必须是首块）。
///
/// - 同名关键字**先删后插**：拿一张别人的卡当底图时，不能留两份 `chara`
///   （不同解析器取第一份还是最后一份并不统一，会读到你不想给的那张卡）。
/// - 只做「加文本块」，不解码/重编码像素 —— 图片内容一字节不动。
Uint8List embedTextChunks(Uint8List png, Map<String, String> chunks) {
  if (!isPng(png)) {
    throw const FormatException('不是 PNG（文件头不对），不能写文本块');
  }
  if (chunks.isEmpty) return png;

  final out = BytesBuilder(copy: true);
  out.add(pngSignature);

  var pos = pngSignature.length;
  var inserted = false;
  var sawIhdr = false;

  while (pos + 12 <= png.length) {
    final len = _readU32(png, pos);
    final type = String.fromCharCodes(png, pos + 4, pos + 8);
    final total = 12 + len;
    if (pos + total > png.length) {
      throw FormatException('PNG 块越界：$type 声明 $len 字节，文件只剩 ${png.length - pos - 12}');
    }

    // 同名 tEXt 丢掉（见上：避免一张图里两份 chara）
    var skip = false;
    if (type == 'tEXt') {
      final key = _tEXtKeyword(png, pos + 8, len);
      if (chunks.containsKey(key)) skip = true;
    }
    if (!skip) out.add(Uint8List.sublistView(png, pos, pos + total));

    if (type == 'IHDR') {
      sawIhdr = true;
      chunks.forEach((k, v) => out.add(_buildTextChunk(k, v)));
      inserted = true;
    }
    pos += total;
    if (type == 'IEND') break;
  }

  if (!sawIhdr) throw const FormatException('PNG 里没有 IHDR 块');
  if (!inserted) throw const FormatException('没找到插入位置（IHDR 缺失？）');
  return out.toBytes();
}

/// 读出一个 PNG 里所有 tEXt 块（关键字 → 文本）。非 PNG 返回空表，不抛 ——
/// 调用方通常是在"用户随手选了个文件"的路径上，抛异常没有意义。
Map<String, String> readTextChunks(Uint8List png) {
  final out = <String, String>{};
  if (!isPng(png)) return out;
  var pos = pngSignature.length;
  while (pos + 12 <= png.length) {
    final len = _readU32(png, pos);
    final type = String.fromCharCodes(png, pos + 4, pos + 8);
    final total = 12 + len;
    if (pos + total > png.length) break;
    if (type == 'tEXt') {
      final data = Uint8List.sublistView(png, pos + 8, pos + 8 + len);
      final zero = data.indexOf(0);
      if (zero > 0) {
        out[latin1.decode(data.sublist(0, zero))] =
            latin1.decode(data.sublist(zero + 1));
      }
    }
    pos += total;
    if (type == 'IEND') break;
  }
  return out;
}

/// 只读一个关键字，省得为了一次查找把整张图的文本块都解出来。
String? readTextChunk(Uint8List png, String keyword) => readTextChunks(png)[keyword];

String _tEXtKeyword(Uint8List png, int start, int len) {
  final end = start + len;
  for (var i = start; i < end; i++) {
    if (png[i] == 0) return latin1.decode(Uint8List.sublistView(png, start, i));
  }
  return latin1.decode(Uint8List.sublistView(png, start, end));
}

/// Latin-1 编码，但**先自己判一遍**再编。
///
/// 为什么不直接 `try { latin1.encode(...) } on ArgumentError`：
/// dart:convert 在不同版本里抛的是 ArgumentError 还是 FormatException 并不一致，
/// `on` 写窄了会漏、写宽了会盖住真 bug。这里逐字符判 >0xFF，抛什么完全由我定。
List<int> _latin1OrThrow(String s, String what) {
  for (final c in s.codeUnits) {
    if (c > 0xFF) {
      throw FormatException(
          '$what 必须是 Latin-1（U+${c.toRadixString(16).toUpperCase()} 超出范围）。'
          '中文请先 utf8 → base64 再写');
    }
  }
  return latin1.encode(s);
}

Uint8List _buildTextChunk(String keyword, String text) {
  final k = _latin1OrThrow(keyword, 'tEXt 关键字');
  if (k.isEmpty || k.length > 79) {
    throw FormatException('tEXt 关键字长度必须在 1~79 字节之间：$keyword');
  }
  if (k.contains(0)) throw FormatException('tEXt 关键字不能含 0x00：$keyword');

  final t = _latin1OrThrow(text, 'tEXt 文本');

  final data = Uint8List(k.length + 1 + t.length);
  data.setRange(0, k.length, k);
  data[k.length] = 0;
  data.setRange(k.length + 1, data.length, t);

  final chunk = Uint8List(12 + data.length);
  _writeU32(chunk, 0, data.length);
  chunk.setRange(4, 8, 'tEXt'.codeUnits);
  chunk.setRange(8, 8 + data.length, data);
  _writeU32(chunk, 8 + data.length, crc32(Uint8List.sublistView(chunk, 4, 8 + data.length)));
  return chunk;
}

int _readU32(List<int> b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

void _writeU32(Uint8List b, int at, int v) {
  b[at] = (v >> 24) & 0xff;
  b[at + 1] = (v >> 16) & 0xff;
  b[at + 2] = (v >> 8) & 0xff;
  b[at + 3] = v & 0xff;
}

/// PNG 标准 CRC32（多项式 0xEDB88320，反射式）。表只建一次。
final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

int crc32(List<int> bytes, [int? start, int? end]) {
  final s = start ?? 0;
  final e = end ?? bytes.length;
  var c = 0xFFFFFFFF;
  for (var i = s; i < e; i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
