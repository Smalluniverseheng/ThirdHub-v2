// 最小 ZIP 写出器 —— 纯 Dart（零依赖，CRC32 复用 `png_text.dart`），可被 `dart run` 直接自检。
//
// 为什么需要它：
//   4.81.26 起支持**导入** `.charx`（zip 角色卡，`zip_reader.dart` 负责读）；
//   但导出只有 PNG（tEXt 隐写）和 JSON 两种。用户想把卡搬到 Risu 系酒馆时，
//   PNG/JSON 都带不走头像 —— `.charx` 才是那边的原生格式。读得进、写不出，
//   等于单向门。
//
// 为什么只用 **store（压缩方法 0）**：
//   包内只有两样东西 —— `card.json`（几 KB 文本）和一张头像图（本身已压缩过）。
//   对已压缩数据再 deflate 基本不减小，反而要引 `ZLibEncoder` 与 `dart:io`，
//   而本文件要能被纯 Dart 自检跑起来（`dart:io` 只提供 zlib，能用但不必要）。
//   store 是 zip 规范里最基础的方法，所有解压实现都支持。
//
// ★四个容易写错的地方（自检里逐条钉住）：
//   ① 中央目录里记的是**本地头的偏移**，不是数据偏移 —— 差 30 + 名字长度；
//   ② 本地头与中央目录的**长度字段必须与真实字节数一致**，否则解压器截断或越界；
//   ③ CRC32 算的是**未压缩**数据（store 下两者相同，所以这里不出错才说明算法对）；
//   ④ EOCD 的「中央目录大小」与「中央目录偏移」分别在 +12 / +16 —— 写反了不报错，
//      只表现为"这不是 zip"（4.81.26 踩过同款）。

import 'dart:convert';
import 'dart:typed_data';

import 'png_text.dart' show crc32;

/// EOCD 里的条目数、长度都是 16 位 —— 超过就必须上 ZIP64，本实现不支持。
const int _maxEntries = 0xFFFF;
const int _maxBytes = 0xFFFFFFFF;

/// 固定时间戳：2020-01-01 00:00:00。
///
/// 为什么不用 `DateTime.now()`：同一个角色卡每导出一次字节都不同，自检就无法
/// 断言"写出结果稳定"，也没法做逐字节比对。角色卡的时间戳没有语义，
/// 固定值反而更好排查。
const int _dosTime = 0;
const int _dosDate = 20513; // ((2020-1980) << 9) | (1 << 5) | 1

const int _sigLocal = 0x04034B50;
const int _sigCentral = 0x02014B50;
const int _sigEnd = 0x06054B50;

/// zip 的「通用标志位」：bit 11 = 文件名是 UTF-8。
/// 不置这一位，中文文件名会被按 CP437 读成乱码（`.charx` 里没有中文名，
/// 但 `cardFileName` 允许中文，所以照样要置）。
const int _flagUtf8 = 0x800;

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

/// 把若干文件打成一个 zip（store 模式）。键 = 包内路径，值 = 内容。
///
/// 路径分隔符统一用 `/`（zip 规范），调用方传 `\\` 也能用 —— 这里会替换。
/// 空内容条目、同名条目都不拦：前者合法，后者由解压方按"后者覆盖"处理，
/// 而本模块的所有调用点都不会产生同名条目。
///
/// 超过 65535 个条目或 4GB → 抛 [ArgumentError]（ZIP64 未实现，宁可显式失败，
/// 也不要写出一个解不开的包）。
Uint8List zipStore(Map<String, List<int>> files) {
  if (files.length > _maxEntries) {
    throw ArgumentError('条目数 ${files.length} 超过 65535，需要 ZIP64（未支持）');
  }

  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);

  for (final e in files.entries) {
    final name = utf8.encode(e.key.replaceAll('\\', '/'));
    if (name.length > 0xFFFF) {
      throw ArgumentError('文件名过长：${e.key}');
    }
    final data = e.value is Uint8List
        ? e.value as Uint8List
        : Uint8List.fromList(e.value);
    final crc = crc32(data);
    final start = local.length; // ★本地头偏移（中央目录要记这个）

    // ── 本地文件头 ──
    _u32(local, _sigLocal);
    _u16(local, 20); // 解压所需版本 2.0
    _u16(local, _flagUtf8);
    _u16(local, 0); // 方法 0 = store
    _u16(local, _dosTime);
    _u16(local, _dosDate);
    _u32(local, crc);
    _u32(local, data.length); // 压缩后大小（store 下相等）
    _u32(local, data.length); // 原始大小
    _u16(local, name.length);
    _u16(local, 0); // extra 长度：不写扩展字段
    local.add(name);
    local.add(data);

    // ── 中央目录条目 ──
    _u32(central, _sigCentral);
    _u16(central, 20); // 生成版本
    _u16(central, 20); // 解压所需版本
    _u16(central, _flagUtf8);
    _u16(central, 0); // 方法
    _u16(central, _dosTime);
    _u16(central, _dosDate);
    _u32(central, crc);
    _u32(central, data.length);
    _u32(central, data.length);
    _u16(central, name.length);
    _u16(central, 0); // extra
    _u16(central, 0); // 注释
    _u16(central, 0); // 起始磁盘号
    _u16(central, 0); // 内部属性
    _u32(central, 0); // 外部属性（不设 unix 权限位：安卓上写了反而更麻烦）
    _u32(central, start);
    central.add(name);
  }

  final localBytes = local.toBytes();
  final centralBytes = central.toBytes();
  if (localBytes.length + centralBytes.length + 22 > _maxBytes) {
    throw ArgumentError('包体超过 4GB，需要 ZIP64（未支持）');
  }

  final out = BytesBuilder(copy: false);
  out.add(localBytes);
  out.add(centralBytes);
  // ── EOCD ──
  _u32(out, _sigEnd);
  _u16(out, 0); // 本磁盘号
  _u16(out, 0); // 中央目录所在磁盘
  _u16(out, files.length); // 本磁盘条目数
  _u16(out, files.length); // 总条目数
  _u32(out, centralBytes.length); // ★中央目录大小（+12）
  _u32(out, localBytes.length); // ★中央目录偏移（+16）
  _u16(out, 0); // 注释长度
  return out.toBytes();
}
