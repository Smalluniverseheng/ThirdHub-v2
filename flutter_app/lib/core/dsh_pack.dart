// DSH 完全体 · 可选数据包（4.81.97）
//
// 产品语义（用户拍板）：
//   AI 模块有两种跑法 ——
//     · 连家里服务：手机只当屏幕，算力在家里 NAS（默认，最省手机资源）
//     · 本机运行：把「完全体」数据包装到手机，断网也能用（可随时拆掉）
//   两种形态同一个入口，切换在「AI 运行位置」里一脚踩过去。
//
// 包结构（zip，App 只管解压，不在包里做任何假设之外的解析）：
//   app/                  DSH 本体（node_modules + 启动脚本）
//   home/                 初始工作目录（会话/技能/配置的落点，首次运行会写入）
//   meta.json             {version, build, note}
//
// 运行时（node）为什么不放数据包里：
//   targetSdk 36 起，应用私有目录里的可执行文件**禁止 exec**（W^X）。所以 node
//   必须由 APK 的 nativeLibraryDir 提供（libnode-bin.so），数据包只放纯 JS +
//   资源。这样数据包可以随时删，运行时跟着 APK 走，两边解耦。
//
// 原生 addon 的处置（4.81.99 本地实测：15 个 .node 全移除后仍可启动）：
//   DSH 强依赖 node-addon-require-builtin 访问 Node 内部 loader。手机上没有
//   android-arm64 的 .node，改用纯 JS 替身 + `--expose-internals`：内部 loader
//   由 Node 原生暴露，替身只做转发。其余 14 个 .node（koffi/sharp/node-pty/
//   sherpa-onnx/node-addon-system）是桌面扩展，移除后 Web 服务正常起来，
//   仅对应扩展不激活。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/app_log.dart';
import 'kv.dart' show aiStore;

/// 数据包状态
enum DshPackState {
  /// 没装（也没在装）
  none,

  /// 正在下载
  downloading,

  /// 正在解压
  unpacking,

  /// 装好了，运行时也在 → 可以「本机运行」
  ready,

  /// 数据包装好了，但缺 node 运行时（APK 侧还没随包发）
  noRuntime,

  /// 出过错
  error,
}

class DshPackInfo {
  final String version;
  final int size;
  final String note;
  const DshPackInfo({required this.version, required this.size, required this.note});
}

class DshPack {
  DshPack._();
  static final DshPack I = DshPack._();

  /// 清单地址（与安装包同一个桶，换了地址只改这里）
  static const String manifestUrl =
      'https://onhmosehcwyrqgxadjvb.supabase.co/storage/v1/object/public/downloads/thirdhub/dsh/latest-dsh.json';

  static const String _kEnable = 'dsh_local_enabled';

  DshPackState state = DshPackState.none;
  String version = '';
  int installedBytes = 0;
  String message = '';

  double progress = 0;
  String progressText = '';

  Process? _proc;
  String _root = '';
  String _nativeLib = '';
  int port = 3825;

  /// 本机模式是否被用户选中且真的可用
  bool get usable => state == DshPackState.ready;
  bool _wantLocal = false;
  bool get enabled => _wantLocal && usable;

  /// 本机控制台地址（带 token 由 DSH 自己生成到 home 下，首次启动后读回）
  String get localBase => 'http://127.0.0.1:$port';

  Future<void> load() async {
    try {
      final paths = await _paths();
      _root = '${paths['files'] ?? ''}/dsh-pack';
      _nativeLib = '${paths['nativeLib'] ?? ''}';
      final d = Directory(_root);
      if (!await d.exists()) {
        state = DshPackState.none;
        return;
      }
      final meta = File('$_root/meta.json');
      if (await meta.exists()) {
        final j = jsonDecode(await meta.readAsString());
        if (j is Map) {
          version = '${j['version'] ?? ''}';
          installedBytes = (j['size'] is num) ? (j['size'] as num).toInt() : 0;
        }
      }
      final hasApp = await Directory('$_root/app').exists();
      if (!hasApp) {
        state = DshPackState.none;
        return;
      }
      _wantLocal = (await aiStore.getString(_kEnable)) == '1';
      state = await runtimeReady() ? DshPackState.ready : DshPackState.noRuntime;
      message = state == DshPackState.ready
          ? ''
          : '已装好数据包，但这版安装包还没带本机运行组件，暂时请继续用家里服务。';
    } catch (e) {
      state = DshPackState.error;
      message = '$e';
      AppLog.add('dsh', 'warn', '数据包读取失败: $e');
    }
  }

  Future<Map<String, String>> _paths() async {
    try {
      final r = await const MethodChannel('thirdhub/app_paths')
          .invokeMapMethod<String, String>('paths');
      if (r != null) return Map<String, String>.from(r);
    } catch (_) {}
    final d = await getApplicationSupportDirectory();
    return {'files': d.path, 'nativeLib': '', 'cache': d.path};
  }

  /// node 运行时是否就位（nativeLibraryDir 下的 libnode-bin.so）
  Future<bool> runtimeReady() async {
    if (_nativeLib.isEmpty) return false;
    for (final n in ['libnode-bin.so', 'libnode.so']) {
      final f = File('$_nativeLib/$n');
      if (await f.exists()) {
        try {
          await Process.run('chmod', ['755', f.path]);
        } catch (_) {}
        return true;
      }
    }
    return false;
  }

  /// 拉远端清单；没有发布过就返回 null（不是错误）
  Future<DshPackInfo?> remote() async {
    try {
      final r = await http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map) return null;
      return DshPackInfo(
        version: '${j['version'] ?? ''}',
        size: (j['size'] is num) ? (j['size'] as num).toInt() : 0,
        note: '${j['note'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// 下载 + 解压（进度回调）
  Future<bool> install({void Function()? onTick}) async {
    if (state == DshPackState.downloading || state == DshPackState.unpacking) {
      return false;
    }
    state = DshPackState.downloading;
    progress = 0;
    progressText = '准备下载';
    onTick?.call();
    final tmp = File('$_root.download.zip');
    try {
      final j = jsonDecode(
          await http.read(Uri.parse(manifestUrl)).timeout(const Duration(seconds: 15)));
      if (j is! Map) throw '清单格式不对';
      final url = '${j['url'] ?? ''}';
      if (url.isEmpty) throw '清单里没有下载地址';
      final parts = j['parts'] is List ? List<dynamic>.from(j['parts'] as List) : null;
      await Directory(_root).create(recursive: true);
      await _fetch(url, tmp, parts, onTick);
      state = DshPackState.unpacking;
      progressText = '正在解压';
      onTick?.call();
      // 6.5 万个文件同步解压会卡住 UI isolate 数分钟，丢到独立 isolate 跑。
      await Isolate.run(() => _unzipSync(tmp.path, _root, version));
      await tmp.delete();
      await load();
      if (state == DshPackState.noRuntime) {
        // 数据包已就位，只差运行时 —— 让用户看到真实原因
        return true;
      }
      return state == DshPackState.ready;
    } catch (e) {
      state = DshPackState.error;
      message = '安装失败：$e';
      progressText = '';
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      onTick?.call();
      return false;
    }
  }

  /// 下载数据包。清单带 parts 时逐段下载 + 逐段校验 + 顺序合并；否则整包。
  /// Supabase 单对象上限 50MB，完全体包必然走分片。
  Future<void> _fetch(String url, File to, List<dynamic>? parts,
      void Function()? onTick) async {
    if (parts != null && parts.isNotEmpty) {
      final segs = <File>[];
      try {
        for (var i = 0; i < parts.length; i++) {
          final m = parts[i];
          if (m is! Map) throw '清单第 ${i + 1} 段格式不对';
          final segUrl = '${m['url'] ?? ''}';
          if (segUrl.isEmpty) throw '清单第 ${i + 1} 段没有地址';
          final seg = File('${to.path}.seg$i');
          segs.add(seg);
          progress = i / parts.length;
          progressText = '下载第 ${i + 1}/${parts.length} 段';
          onTick?.call();
          await _fetchOne(segUrl, seg, base: i / parts.length,
              scale: 1 / parts.length, onTick: onTick);
          final want = '${m['sha256'] ?? ''}'.trim().toLowerCase();
          if (want.isNotEmpty && await _fileSha256(seg) != want) {
            throw '第 ${i + 1} 段校验不符';
          }
        }
        progressText = '正在合并分段';
        onTick?.call();
        final sink = to.openWrite();
        for (final s in segs) {
          await sink.addStream(s.openRead());
        }
        await sink.close();
      } catch (_) {
        for (final s in segs) {
          try {
            if (await s.exists()) await s.delete();
          } catch (_) {}
        }
        rethrow;
      }
      for (final s in segs) {
        try {
          if (await s.exists()) await s.delete();
        } catch (_) {}
      }
      progress = 1;
      onTick?.call();
      return;
    }
    await _fetchOne(url, to, onTick: onTick);
  }

  Future<void> _fetchOne(String url, File to,
      {double base = 0, double scale = 1, void Function()? onTick}) async {
    final req = http.Request('GET', Uri.parse(url));
    final resp = await http.Client().send(req).timeout(const Duration(seconds: 180));
    if (resp.statusCode != 200) throw '下载失败 HTTP ${resp.statusCode}';
    final total = resp.contentLength ?? 0;
    var got = 0;
    final sink = to.openWrite();
    await for (final chunk in resp.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) progress = base + scale * got / total;
      progressText = total > 0
          ? '${(got / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB'
          : '${(got / 1048576).toStringAsFixed(1)} MB';
      onTick?.call();
    }
    await sink.close();
  }

  Future<String> _fileSha256(File f) async {
    // 与 main.dart 的分片校验保持同一套实现（cryptography，流式不占内存）
    final sink = Sha256().newHashSink();
    await for (final chunk in f.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final h = await sink.hash();
    return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 顶层函数（Isolate.run 不能捕获 this / 实例成员）
  void _unzipSync(String zipPath, String root, String version) {
    Directory(root).createSync(recursive: true);
    final af = ZipDecoder().decodeBuffer(InputFileStream(zipPath));
    extractArchiveToDisk(af, root);
    // 记一份 meta，卸载后也能看出装过什么版本
    File('$root/meta.json').writeAsStringSync(
        jsonEncode({'version': version, 'at': DateTime.now().millisecondsSinceEpoch}));
  }

  /// 启动本机 DSH（只在 usable 时允许）
  Future<bool> start() async {
    if (!await runtimeReady()) {
      message = '本机运行组件未就绪';
      return false;
    }
    if (_proc != null) return true;
    try {
      final node = '$_nativeLib/libnode-bin.so';
      final entry = '$_root/app/boot.mjs';
      if (!await File(entry).exists()) {
        message = '数据包里没找到启动入口';
        return false;
      }
      // --expose-internals 是手机端替身的关键：让纯 JS 替身能直接 require Node
      // 内部 loader，无需任何原生 addon。
      _proc = await Process.start(
        node,
        [
          '--expose-internals',
          entry,
          'web',
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
          '--no-open',
        ],
        environment: {
          'LD_LIBRARY_PATH': _nativeLib,
          'HOME': '$_root/home',
          'DSH_HOME': '$_root/home/.dsh',
          'TMPDIR': '$_root/tmp',
          'NODE_ENV': 'production',
        },
        workingDirectory: '$_root',
      );
      _proc!.stdout.transform(utf8.decoder).listen((s) {
        if (s.trim().isNotEmpty) AppLog.add('dsh', 'info', s.trim());
      });
      _proc!.stderr.transform(utf8.decoder).listen((s) {
        if (s.trim().isNotEmpty) AppLog.add('dsh', 'warn', s.trim());
      });
      // 最多等 12 秒起服务
      for (var i = 0; i < 24; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (await _alive()) return true;
      }
      message = '本机运行没起来（详见日志 dsh-local）';
      return false;
    } catch (e) {
      message = '本机运行启动失败：$e';
      return false;
    }
  }

  Future<bool> _alive() async {
    try {
      final s = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 600));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      _proc?.kill();
    } catch (_) {}
    _proc = null;
  }

  /// 拆除数据包（回到「连家里服务」形态），运行时不动
  Future<void> remove() async {
    await stop();
    try {
      final d = Directory(_root);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      message = '删除失败：$e';
    }
    state = DshPackState.none;
    version = '';
    installedBytes = 0;
    await setEnabled(false);
  }

  Future<void> setEnabled(bool v) async {
    _wantLocal = v;
    await aiStore.setString(_kEnable, v ? '1' : '0');
    if (!v) await stop();
  }
}
