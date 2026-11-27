// 流式 tar.gz → 磁盘（本机 DSH 运行时包专用）
//
// 为什么要自己解而不是用 archive 包：
//   · archive 的 extractArchiveToDisk 需要先把整个 Archive 读进内存 ——
//     rootfs 解开 800MB，手机必 OOM；
//   · 系统 tar 靠 ROM 的 toybox，各家裁剪不一致，不能赌；
//   · gzip 用 dart:io 自带的（原生 zlib，快）；tar 结构极简单，512 字节头而已。
//
// 支持：普通文件、目录、符号链接、硬链接（退化成复制）、GNU 长名（'L'）、
//      pax 扩展头（'x'/'g' 里的 path=/linkpath=/size=）、设置 mode（非 root 失败就跳过）。
// 跳过：块/字符设备、FIFO —— 手机上 proot 用 bind 提供 /dev，不需要真设备节点。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// 解压结果
class TarExtractResult {
  final int files;
  final int dirs;
  final int links;
  final int skipped;
  const TarExtractResult(this.files, this.dirs, this.links, this.skipped);

  @override
  String toString() => '文件 $files / 目录 $dirs / 链接 $links / 跳过 $skipped';
}

/// 同步执行（在 Isolate.run 里调用；内部是 async，但 Isolate.run 接受 Future）
Future<TarExtractResult> extractTarGzToDisk(
  String archivePath,
  String destDir, {
  void Function(int files, int bytes)? onProgress,
}) async {
  final r = _Reader(StreamIterator<List<int>>(
      File(archivePath).openRead().transform(gzip.decoder)));
  final root = Directory(destDir);
  if (!await root.exists()) await root.create(recursive: true);

  var files = 0, dirs = 0, links = 0, skipped = 0, bytes = 0;
  // chmod 一次进程开销 ~7ms，6 万个文件逐个调就是 7 分钟 —— 收集后按 mode 批量执行
  final modes = <(String, int, bool)>[];
  String? longName;
  String? longLink;
  Map<String, String> pax = const {};

  while (true) {
    final head = await r.readBytes(512);
    if (head.isEmpty) break;
    if (head.length < 512) break;
    // 全 0 块 = 归档结束（后面可能还有 padding）
    var zero = true;
    for (final b in head) {
      if (b != 0) {
        zero = false;
        break;
      }
    }
    if (zero) break;

    final rawName = _str(head, 0, 100);
    final prefix = _str(head, 345, 155);
    var name = longName ?? (prefix.isEmpty ? rawName : '$prefix/$rawName');
    longName = null;
    final mode = _octal(head, 100, 8);
    // 常规 tar 的 size 是八进制；pax 头里的 size= 是十进制，优先级更高
    final paxSize = pax['size'];
    final size = paxSize != null
        ? (int.tryParse(paxSize.trim()) ?? 0)
        : _octal(head, 124, 12);
    final type = head[156] == 0 ? 0x30 : head[156];
    var linkName = longLink ?? _str(head, 157, 100);
    longLink = null;
    if (pax.containsKey('path')) name = pax['path']!;
    if (pax.containsKey('linkpath')) linkName = pax['linkpath']!;
    pax = const {};

    // 规范化：去掉前导 ./，拒绝 .. 逃逸
    name = name.replaceFirst(RegExp(r'^\./'), '');
    if (name.isEmpty || name == '.') {
      await r.skip(_pad512(size));
      continue;
    }
    if (name.contains('..')) {
      await r.skip(_pad512(size));
      skipped++;
      continue;
    }
    final path = '$destDir/$name';

    switch (type) {
      case 0x4C: // 'L' GNU long name
        longName = _cstr(await r.readBytes(size));
        await r.skip(_pad512(size) - size);
        continue;
      case 0x4B: // 'K' GNU long link name
        longLink = _cstr(await r.readBytes(size));
        await r.skip(_pad512(size) - size);
        continue;
      case 0x78: // 'x' pax 扩展头（作用于下一个条目）
      case 0x67: // 'g' pax 全局头
        pax = _parsePax(await r.readBytes(size));
        await r.skip(_pad512(size) - size);
        continue;
      case 0x35: // '5' 目录
        await Directory(path).create(recursive: true);
        if (mode != 0) modes.add((path, mode, false));
        dirs++;
        await r.skip(_pad512(size));
        continue;
      case 0x32: // '2' 符号链接
        final f = Link(path);
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
        await Directory(_parent(path)).create(recursive: true);
        try {
          await f.create(linkName);
          links++;
        } catch (_) {
          skipped++;
        }
        await r.skip(_pad512(size));
        continue;
      case 0x31: // '1' 硬链接：包里是先出现的目标，直接复制一份最稳
        try {
          final target = File('$destDir/${linkName.replaceFirst(RegExp(r'^\./'), '')}');
          if (await target.exists()) {
            await Directory(_parent(path)).create(recursive: true);
            await target.copy(path);
            links++;
          } else {
            skipped++;
          }
        } catch (_) {
          skipped++;
        }
        await r.skip(_pad512(size));
        continue;
      case 0x33: // '3' 字符设备
      case 0x34: // '4' 块设备
      case 0x36: // '6' FIFO
        await r.skip(_pad512(size));
        skipped++;
        continue;
    }

    // 普通文件（'0' / '\0'）
    await Directory(_parent(path)).create(recursive: true);
    final sink = File(path).openWrite();
    await r.copyTo(sink, size);
    await sink.close();
    files++;
    bytes += size;
    if (mode != 0) modes.add((path, mode, true));
    if (size % 512 != 0) await r.skip(512 - (size % 512));
    if (onProgress != null && files % 500 == 0) onProgress(files, bytes);
  }
  await _applyModes(modes);
  onProgress?.call(files, bytes);
  return TarExtractResult(files, dirs, links, skipped);
}

/// 整块字节里取 C 字符串（GNU 长名块结尾带 \0）
String _cstr(List<int> b) {
  var end = b.indexOf(0);
  if (end < 0) end = b.length;
  return utf8.decode(b.sublist(0, end), allowMalformed: true);
}

String _parent(String p) {  final i = p.lastIndexOf('/');
  return i <= 0 ? p : p.substring(0, i);
}

int _pad512(int n) => (n % 512 == 0) ? n : n + (512 - n % 512);

String _str(List<int> b, int off, int len) {
  var end = off;
  final max = off + len;
  while (end < max && b[end] != 0) {
    end++;
  }
  return utf8.decode(b.sublist(off, end), allowMalformed: true);
}

int _octal(List<int> b, int off, int len) {
  final s = _str(b, off, len).trim();
  if (s.isEmpty) return 0;
  return int.tryParse(s, radix: 8) ?? 0;
}

/// pax 记录：`<len> path=<value>\n`，长度含自身
Map<String, String> _parsePax(List<int> b) {
  final out = <String, String>{};
  var i = 0;
  while (i < b.length) {
    var sp = i;
    while (sp < b.length && b[sp] != 0x20) {
      sp++;
    }
    if (sp >= b.length) break;
    final len = int.tryParse(String.fromCharCodes(b.sublist(i, sp))) ?? 0;
    if (len <= 0 || i + len > b.length) break;
    final rec = utf8.decode(b.sublist(sp + 1, i + len - 1), allowMalformed: true);
    final eq = rec.indexOf('=');
    if (eq > 0) out[rec.substring(0, eq)] = rec.substring(eq + 1);
    i += len;
  }
  return out;
}

/// 把 (path, mode) 按 mode 分桶，每桶一条 chmod 命令（每条最多 400 个路径，
/// 避开命令行长度与 ARG_MAX）。失败不致命：proot 里以 root 跑，只关心 x 位。
Future<void> _applyModes(List<(String, int, bool)> items) async {
  if (items.isEmpty) return;
  final byMode = <int, List<String>>{};
  for (final (p, m, _) in items) {
    (byMode[m] ??= <String>[]).add(p);
  }
  for (final e in byMode.entries) {
    final mode = e.key.toRadixString(8);
    final list = e.value;
    for (var i = 0; i < list.length; i += 400) {
      final end = (i + 400) < list.length ? i + 400 : list.length;
      try {
        await Process.run('chmod', [mode, ...list.sublist(i, end)]);
      } catch (_) {
        // 忽略：Android 上 /system/bin/chmod 一定在，失败也不影响 rootfs 可用
      }
    }
  }
}

class _Reader {
  _Reader(this._it);
  final StreamIterator<List<int>> _it;
  List<int> _cur = const [];
  int _pos = 0;

  Future<bool> _fill() async {
    while (true) {
      if (!await _it.moveNext()) return false;
      if (_it.current.isNotEmpty) {
        _cur = _it.current;
        _pos = 0;
        return true;
      }
    }
  }

  /// 读最多 n 字节（不足则返回已有的）
  Future<List<int>> readBytes(int n) async {
    final out = <int>[];
    while (out.length < n) {
      if (_pos >= _cur.length) {
        if (!await _fill()) break;
      }
      final take = (n - out.length) < (_cur.length - _pos)
          ? (n - out.length)
          : (_cur.length - _pos);
      out.addAll(_cur.sublist(_pos, _pos + take));
      _pos += take;
    }
    return out;
  }

  /// 恰好 n 字节写进 sink，多的丢弃
  Future<void> copyTo(IOSink sink, int n) async {
    var left = n;
    while (left > 0) {
      if (_pos >= _cur.length) {
        if (!await _fill()) throw const FormatException('归档提前结束');
      }
      final take = left < (_cur.length - _pos) ? left : (_cur.length - _pos);
      sink.add(_cur.sublist(_pos, _pos + take));
      _pos += take;
      left -= take;
    }
  }

  Future<void> skip(int n) async {
    var left = n;
    while (left > 0) {
      if (_pos >= _cur.length) {
        if (!await _fill()) return;
      }
      final take = left < (_cur.length - _pos) ? left : (_cur.length - _pos);
      _pos += take;
      left -= take;
    }
  }
}

/// 在**独立 isolate** 里解压，并把进度回传给 UI（4.81.119）。
///
/// 为什么不能直接 `Isolate.run(extractTarGzToDisk)`：Isolate.run 只回最终值，
/// 中间一个字节都传不出来 —— 界面上就只能是「转圈 + 一句话」，
/// 用户不知道还要等 10 秒还是 3 分钟（实测 170MB gz → 696MB、6 万文件，1~3 分钟）。
///
/// 这里用 Isolate.spawn + SendPort：每 500 个文件回一条 `[files, bytes]`，
/// 调用方据此画确定进度条。bytes 是**已写出的解压后字节数**。
Future<TarExtractResult> extractTarGzInIsolate(
  String archivePath,
  String destDir, {
  void Function(int files, int bytes)? onProgress,
}) async {
  final rp = ReceivePort();
  final errRp = ReceivePort();
  final iso = await Isolate.spawn(_extractWorker, [archivePath, destDir, rp.sendPort],
      onError: errRp.sendPort);
  TarExtractResult? result;
  Object? failure;
  final done = Completer<void>();
  rp.listen((m) {
    if (m is List && m.length == 2) {
      onProgress?.call(m[0] as int, m[1] as int);
    } else if (m is List && m.length == 4) {
      result = TarExtractResult(m[0] as int, m[1] as int, m[2] as int, m[3] as int);
      if (!done.isCompleted) done.complete();
    }
  });
  errRp.listen((m) {
    failure = m;
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  iso.kill(priority: Isolate.immediate);
  rp.close();
  errRp.close();
  if (failure != null) throw Exception('解压失败：$failure');
  return result ?? const TarExtractResult(0, 0, 0, 0);
}

Future<void> _extractWorker(List<Object> args) async {
  final path = args[0] as String;
  final dir = args[1] as String;
  final sp = args[2] as SendPort;
  final r = await extractTarGzToDisk(path, dir, onProgress: (f, b) {
    sp.send([f, b]);
  });
  sp.send([r.files, r.dirs, r.links, r.skipped]);
}
