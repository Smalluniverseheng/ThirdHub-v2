// 最小 ZIP 读取器 —— 纯 Dart（只依赖 dart:io 的 zlib），零 Flutter、零新依赖。
//
// 为什么要自己写：
//   `.charx`（Risu 系的角色卡）本质是个 zip：里面 `card.json` + 若干图片。
//   仓库里虽然有 `archive` 包，但它是 **flutter_app 的依赖**，而本文件要能被
//   `dart run tool/xxx_selfcheck.dart` 直接跑起来做断言；同时本机 `PUB_CACHE` 为空，
//   任何"再引一个包"的路子都等于把能不能编译押在没验过的东西上。
//   zip 的读取其实只有三段（EOCD → 中央目录 → 本地头），写清楚比引依赖更可靠。
//
// 支持范围（够读角色卡，且写明了边界）：
//   · 压缩方法 0（store）与 8（deflate）—— 这两种覆盖了 99% 的实际 zip；
//   · 文件名 UTF-8（通用标志位 bit 11）与 Latin-1 两种编码；
//   · 加密条目、ZIP64、分卷 —— **不支持**，遇到就返回 null（当作"不是我们能读的 zip"）。
//
// ★三个容易写错的地方（自检里都有对应断言）：
//   ① 数据起点要按**本地文件头自己的** nameLen/extraLen 算，不能用中央目录里的
//      —— 两者可以不同（中央目录常带扩展时间戳，本地头没有）。
//   ② 长度要用**中央目录里的** compSize/uncompSize，不能信本地头：带 data descriptor
//      （标志位 bit 3）时本地头的长度字段是 0，照着读会得到空内容。
//   ③ EOCD 后面可以挂最多 64KB 的注释，所以要从尾部**向前扫**签名，不能假设在末尾。

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

/// zip 的四个签名。
const int _sigLocal = 0x04034b50;
const int _sigCentral = 0x02014b50;
const int _sigEnd = 0x06054b50;

/// 是不是一个 zip（按魔数判断，不解包）。
///
/// `PK\x05\x06` 是**空包**的签名（只有 EOCD）——真实角色卡不会是空包，
/// 但判"这是不是 zip"时把它算进来，路径分派才不会把空包当 JSON 去解析。
bool isZip(List<int> bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
  final b2 = bytes[2], b3 = bytes[3];
  return (b2 == 0x03 && b3 == 0x04) ||
      (b2 == 0x05 && b3 == 0x06) ||
      (b2 == 0x07 && b3 == 0x08);
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// 解开一个 zip，返回「路径 → 内容」。不是合法 zip / 不支持的变体返回 null。
///
/// 目录条目（名字以 `/` 结尾）会被跳过 —— 调用方要的是文件。
/// 单个条目解压失败**不**放弃整包：跳过它继续，剩下的照样能读
/// （一张卡里有一个损坏的附加图，不该导致整张卡导入失败）。
Map<String, Uint8List>? unzip(Uint8List data) {
  if (!isZip(data)) return null;
  final eocd = _findEocd(data);
  if (eocd < 0) return null;

  final count = _u16(data, eocd + 10);
  // EOCD 布局：sig(+0) / 盘号(+4) / 中央目录所在盘(+6) / 本盘条目数(+8) /
  //   总条目数(+10) / **中央目录大小(+12)** / **中央目录偏移(+16)** / 注释长度(+20)
  // ★这两个字段一样是 4 字节、紧挨着，写反了不会报错，只会"什么也解不出来"。
  final cdSize = _u32(data, eocd + 12);
  final cdOffset = _u32(data, eocd + 16);
  // ZIP64：字段被填成 0xFFFFFFFF 就在别处（这部分我们不支持）。
  if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) return null;
  if (cdOffset < 0 || cdOffset + cdSize > data.length) return null;

  final out = <String, Uint8List>{};
  var p = cdOffset;
  for (var i = 0; i < count; i++) {
    if (p + 46 > data.length || _u32(data, p) != _sigCentral) break;
    final flags = _u16(data, p + 8);
    final method = _u16(data, p + 10);
    final compSize = _u32(data, p + 20);
    final nameLen = _u16(data, p + 28);
    final extraLen = _u16(data, p + 30);
    final commentLen = _u16(data, p + 32);
    final localOffset = _u32(data, p + 42);
    if (p + 46 + nameLen > data.length) break;
    final nameBytes = data.sublist(p + 46, p + 46 + nameLen);
    final name = (flags & 0x800) != 0
        ? utf8.decode(nameBytes, allowMalformed: true)
        : latin1.decode(nameBytes);
    p += 46 + nameLen + extraLen + commentLen;

    if (name.endsWith('/')) continue; // 目录
    if ((flags & 0x1) != 0) continue; // 加密条目，跳过
    if (localOffset + 30 > data.length || _u32(data, localOffset) != _sigLocal) {
      continue;
    }
    // ★① 本地头自己的 nameLen/extraLen 决定数据起点
    final lNameLen = _u16(data, localOffset + 26);
    final lExtraLen = _u16(data, localOffset + 28);
    final start = localOffset + 30 + lNameLen + lExtraLen;
    final end = start + compSize;
    if (start < 0 || end > data.length) continue;
    final raw = data.sublist(start, end);
    try {
      if (method == 0) {
        out[name] = Uint8List.fromList(raw);
      } else if (method == 8) {
        final r = ZLibDecoder(raw: true).convert(raw);
        out[name] = Uint8List.fromList(r);
      }
      // 其它压缩方法（bzip2/lzma 等）：跳过，不报错。
    } catch (_) {
      continue; // ★单条坏掉不影响整包
    }
  }
  return out.isEmpty ? null : out;
}

/// 从尾部向前找 EOCD。注释最长 65535 字节，所以最多往回扫 65557。
int _findEocd(Uint8List b) {
  final least = b.length - 22 - 65535;
  final from = least < 0 ? 0 : least;
  for (var i = b.length - 22; i >= from; i--) {
    if (b[i] == 0x50 &&
        b[i + 1] == 0x4B &&
        b[i + 2] == 0x05 &&
        b[i + 3] == 0x06) {
      return i;
    }
  }
  return -1;
}

/// 按「根目录优先、其次路径最短、最后字典序」挑一个条目。
///
/// 为什么不是"随便第一个"：`card.json` 可能出现在 `card.json` 与
/// `sub/card.json` 两个位置（有人把整个旧包塞进子目录），根目录那份才是
/// 作者真正在用的那张。
Uint8List? pickEntry(Map<String, Uint8List> files, bool Function(String) test) {
  final names = files.keys.where(test).toList();
  if (names.isEmpty) return null;
  names.sort((a, b) {
    final da = '/'.allMatches(a).length, db = '/'.allMatches(b).length;
    if (da != db) return da - db;
    return a.compareTo(b);
  });
  return files[names.first];
}

/// 同 [pickEntry]，但要拿到被选中条目的名字（导入头像时要按扩展名存盘）。
String? pickEntryName(Map<String, Uint8List> files, bool Function(String) test) {
  final names = files.keys.where(test).toList();
  if (names.isEmpty) return null;
  names.sort((a, b) {
    final da = '/'.allMatches(a).length, db = '/'.allMatches(b).length;
    if (da != db) return da - db;
    return a.compareTo(b);
  });
  return names.first;
}
