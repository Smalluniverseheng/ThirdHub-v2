// DSH 完全体 · 本机运行包（4.81.106 重做：改用 PRoot）
//
// 产品语义（用户拍板）：
//   AI 模块有两种跑法 ——
//     · 连家里服务：手机只当屏幕，算力在家里 NAS（最省手机资源）
//     · 本机运行：把「完全体」装到手机，断网也能用（可随时拆掉）
//
// ★4.81.106 为什么推倒重做：
//   4.81.99 那版是「Termux 的 bionic Node + 11 个 .so 改名 + 直接 exec」，
//   真机上属于赌博：Termux 的 node 是按 /data/data/com.termux 前缀编译的，
//   靠改 DT_NEEDED/RUNPATH 搬进 APK 能起是运气。而且原生 addon 一个都没有，
//   所谓"完全体"其实是残缺体。
//
//   现在换成移动端跑 Linux 用户态的标准答案 —— PRoot + Ubuntu rootfs：
//     · 运行时 = Ubuntu 24.04 base + **官方** node-linux-arm64（不用改任何 ELF）
//     · DSH 在 rootfs 里 npm 装好，原生 addon（sharp/koffi/pty/sherpa）全都在
//     · 启动器 = Termux 的 proot（--kill-on-exit/--link2symlink/--sysvipc 都已验证）
//   这套配方来自开源项目 dsh-Go 的实践，我们只学它的启动/就绪/停止细节。
//
// ★两个必须照抄的细节（都是真机上会直接白屏的坑）：
//   ① **就绪信号是 token，不是端口**。`dsh web` 起来后只打印一行
//      `dsh web: http://127.0.0.1:PORT/?token=xxx`，之后所有请求没带
//      `dsh-auth-*` cookie 一律 401。所以必须抓这行、拿 token 地址开 WebView，
//      光探端口通了就打首页 = 401 白屏（这是 4.81.99 版在真机上"看着装了却用不了"的主因）。
//   ② **停止要发两枪**。PRoot 自己忽略 SIGTERM，必须按 rootfs 里的 pid 文件
//      SIGTERM 那个 node 进程，必要时再 SIGQUIT proot；只 kill proot 会留下孤儿 node
//      继续占着 3825 端口，下次启动永远起不来。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import 'dsh_local_argv.dart';
import 'dsh_tar.dart';
import 'kv.dart' show aiStore;

/// 本机运行包状态
enum DshPackState {
  /// 没装（也没在装）
  none,

  /// 正在下载
  downloading,

  /// 正在解压（这一步最久，6 万文件）
  unpacking,

  /// 装好了，启动器也在 → 可以「本机运行」
  ready,

  /// 包装好了，但缺启动器（这版 APK 没带 proot）
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

  /// 启动后从 stdout 抓到的鉴权 token（每次启动都会换新的）
  String token = '';

  Process? _proc;
  /// 进程是否已经退出（Dart 的 Process 没有 isAlive，只能靠 exitCode 记账）
  bool _exited = true;
  String _root = '';
  String _rootfs = '';
  String _nativeLib = '';
  String _tmp = '';
  int port = 3825;

  /// 本机模式是否被用户选中且真的可用
  bool get usable => state == DshPackState.ready;
  bool _wantLocal = false;
  bool get enabled => _wantLocal && usable;

  bool get running => _proc != null;

  /// 本机控制台地址（不带 token 会 401，仅作健康检查用）
  String get localBase => 'http://127.0.0.1:$port';

  /// 给 WebView 用的地址：**必须带 token**，否则 DSH 一律 401。
  /// 打开一次后 DSH 会 303 下发 dsh-auth cookie，后续同站点请求都靠 cookie。
  String get consoleUrl => DshLocalLaunch.consoleUrl(localBase, token);

  Future<void> load() async {
    try {
      final paths = await _paths();
      final files = '${paths['files'] ?? ''}';
      _nativeLib = '${paths['nativeLib'] ?? ''}';
      _tmp = '${paths['cache'] ?? files}/dsh-tmp';
      _root = '$files/dsh';
      _rootfs = '$_root/rootfs';
      // 4.81.99 那版把 zip 数据包解在 files/dsh-pack（120MB），形态已废弃 ——
      // 不主动清掉，用户会白白多占一百多兆，且还以为"装过了"。
      try {
        final legacy = Directory('$files/dsh-pack');
        if (await legacy.exists()) {
          await legacy.delete(recursive: true);
          AppLog.add('dsh', 'info', '已清理旧版数据包目录');
        }
      } catch (_) {}
      final d = Directory(_rootfs);
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
      final hasDsh = await File('$_rootfs/usr/local/bin/dsh').exists();
      if (!hasDsh) {
        state = DshPackState.none;
        return;
      }
      _wantLocal = (await aiStore.getString(_kEnable)) == '1';
      state = await runtimeReady() ? DshPackState.ready : DshPackState.noRuntime;
      message = state == DshPackState.ready
          ? ''
          : '运行包已装好，但这版安装包没带本机启动组件，暂时继续用家里服务。';
    } catch (e) {
      state = DshPackState.error;
      message = '$e';
      AppLog.add('dsh', 'warn', '运行包读取失败: $e');
    }
  }

  Future<Map<String, String>> _paths() async {
    try {
      final r = await const MethodChannel('thirdhub/app_paths')
          .invokeMapMethod<String, String>('paths');
      if (r != null) return Map<String, String>.from(r);
    } catch (_) {}
    return {'files': Directory.systemTemp.path, 'nativeLib': '', 'cache': ''};
  }

  /// 启动器是否就位：proot + loader 都在 nativeLibraryDir
  Future<bool> runtimeReady() async {
    if (_nativeLib.isEmpty) return false;
    for (final n in ['libproot.so', 'libproot-loader.so', 'libtalloc.so']) {
      if (!await File('$_nativeLib/$n').exists()) return false;
    }
    return true;
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
    await stop();
    state = DshPackState.downloading;
    progress = 0;
    progressText = '准备下载';
    onTick?.call();
    final tmp = File('$_root.download.tar.gz');
    try {
      final j = jsonDecode(
          await http.read(Uri.parse(manifestUrl)).timeout(const Duration(seconds: 15)));
      if (j is! Map) throw '清单格式不对';
      final url = '${j['url'] ?? ''}';
      final parts = j['parts'] is List ? List<dynamic>.from(j['parts'] as List) : null;
      if (url.isEmpty && (parts == null || parts.isEmpty)) throw '清单里没有下载地址';
      final wantVer = '${j['version'] ?? ''}';
      final wantSha = '${j['sha256'] ?? ''}'.trim().toLowerCase();

      await Directory(_root).create(recursive: true);
      await _fetch(url, tmp, parts, onTick);

      if (wantSha.isNotEmpty) {
        progressText = '校验完整性';
        onTick?.call();
        if (await _fileSha256(tmp) != wantSha) throw '运行包校验不符，请重试';
      }

      // 6 万文件 + 800MB，必须离开 UI isolate
      state = DshPackState.unpacking;
      progressText = '正在解压（首次约 1-3 分钟）';
      onTick?.call();
      final target = _rootfs;
      // 旧目录先删干净，避免半旧半新
      try {
        final old = Directory(target);
        if (await old.exists()) await old.delete(recursive: true);
      } catch (_) {}
      await Directory(target).create(recursive: true);
      final tpath = tmp.path;
      await Isolate.run(() => extractTarGzToDisk(tpath, target));
      try {
        await tmp.delete();
      } catch (_) {}

      await _prepareRootfs(wantVer);
      await load();
      if (state == DshPackState.noRuntime) return true;
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

  /// 解压后的收尾：补目录、写 resolv.conf、记 meta
  Future<void> _prepareRootfs(String ver) async {
    for (final d in [
      '$_rootfs/var/lib/dsh-app/empty',
      '$_rootfs/var/lib/dsh-app/shm',
      '$_rootfs/root/.dsh',
      '$_rootfs/root/.l2s',
      '$_rootfs/tmp',
      '$_rootfs/etc',
    ]) {
      try {
        await Directory(d).create(recursive: true);
      } catch (_) {}
    }
    // Android 没有 /etc/resolv.conf，proot 里必须自己写，否则所有域名解析失败
    try {
      await File('$_rootfs/etc/resolv.conf').writeAsString(
          'nameserver 223.5.5.5\nnameserver 119.29.29.29\noptions timeout:2 attempts:2\n');
    } catch (_) {}
    final bytes = await _dirBytes(_rootfs);
    await File('$_root/meta.json').writeAsString(jsonEncode({
      'version': ver,
      'size': bytes,
      'at': DateTime.now().millisecondsSinceEpoch,
    }));
    installedBytes = bytes;
  }

  Future<int> _dirBytes(String dir) async {
    var total = 0;
    try {
      await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 下载。清单带 parts 时逐段下载 + 逐段校验 + 顺序合并；否则整包。
  /// Supabase 单对象上限 50MB，运行包必然走分片。
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
    final sink = Sha256().newHashSink();
    await for (final chunk in f.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final h = await sink.hash();
    return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 挑一个 loopback 端口（3825 起 20 个候选）
  Future<int> _pickPort() async {
    for (var p = 3825; p <= 3845; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {}
    }
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  /// PRoot 启动命令与环境（配方见 dsh_local_argv.dart，自检逐条钉死）
  List<String> _argv(int port) => DshLocalLaunch.argv(
        nativeLib: _nativeLib,
        rootfs: _rootfs,
        tmp: _tmp,
        port: port,
      );

  Map<String, String> _env() => <String, String>{
        ...DshLocalLaunch.env(
            nativeLib: _nativeLib, rootfs: _rootfs, tmp: _tmp),
        // proot 进程自己的工作目录（guest 里由 --cwd 决定）
        'HOME': _root,
        'TMPDIR': _tmp,
      };

  /// 启动本机 DSH（成功时 `token` 已就绪，可直接给 WebView）
  Future<bool> start({void Function()? onTick}) async {
    if (!await runtimeReady()) {
      message = '本机启动组件未就绪';
      return false;
    }
    if (_proc != null) return token.isNotEmpty;
    try {
      await Directory(_tmp).create(recursive: true);
      try {
        await Directory('$_rootfs/root/.l2s').create(recursive: true);
      } catch (_) {}
      // DSH 要求凭据文件只能自己读；上一次启动写下的若是 644，本次会直接拒绝启动
      try {
        final cred = File('$_rootfs/root/.dsh/.credentials.yaml');
        if (await cred.exists()) {
          await Process.run('chmod', ['600', cred.path]);
        }
      } catch (_) {}

      port = await _pickPort();
      token = '';
      message = '';
      final log = <String>[];
      _proc = await Process.start(
        '$_nativeLib/libproot.so',
        _argv(port),
        environment: _env(),
        workingDirectory: _root,
      );
      final proc = _proc!;
      _exited = false;
      // 拿不到 stdin 会让 proot 里的 node 在部分 ROM 上直接退出
      try {
        await proc.stdin.close();
      } catch (_) {}

      final ready = Completer<bool>();

      void scan(String line, bool isErr) {
        final s = line.trim();
        if (s.isEmpty) return;
        log.add(s);
        if (log.length > 40) log.removeAt(0);
        if (isErr) {
          AppLog.add('dsh', 'warn', s);
        } else {
          AppLog.add('dsh', 'info', s);
        }
        if (token.isEmpty) {
          final url = DshLocalLaunch.tokenFrom(s);
          if (url != null) {
            final m = DshLocalLaunch.tokenLine.firstMatch(s)!;
            port = int.tryParse(m.group(2) ?? '') ?? port;
            token = m.group(3) ?? '';
            if (!ready.isCompleted) ready.complete(true);
          }
        }
      }

      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (l) => scan(l, false));
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (l) => scan(l, true));
      unawaited(proc.exitCode.then((code) {
        _exited = true;
        AppLog.add('dsh', 'warn', '本机 DSH 退出 code=$code');
        if (identical(_proc, proc)) _proc = null;
        if (!ready.isCompleted) ready.complete(false);
      }));

      // 首次启动要展开 rootfs 里的 node（冷启动最长见 3 分钟），给 180 秒
      final ok = await ready.future.timeout(const Duration(seconds: 180),
          onTimeout: () => false);
      onTick?.call();
      if (!ok || token.isEmpty) {
        message = log.isEmpty ? '本机运行没起来（没有输出）' : '本机运行没起来：${log.last}';
        AppLog.add('dsh', 'warn', '启动失败: ${log.join(' | ')}');
        await stop();
        return false;
      }
      // 端口真能连上再算就绪（token 行是插件都加载完之后才打印的，一般已经可连）
      for (var i = 0; i < 20; i++) {
        if (await _alive()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      message = '端口 $port 没接受连接';
      await stop();
      return false;
    } catch (e) {
      message = '本机运行启动失败：$e';
      AppLog.add('dsh', 'warn', message);
      _proc = null;
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

  /// 停止：proot 忽略 SIGTERM，所以先 SIGTERM rootfs 里的 node（pid 文件），
  /// 再 SIGQUIT proot 收割所有 tracee。只 destroy() 会留下孤儿 node 占端口。
  Future<void> stop() async {
    final p = _proc;
    token = '';
    if (p == null) return;
    _proc = null;
    try {
      final pidFile = File('$_rootfs/tmp/dsh-web.pid');
      if (await pidFile.exists()) {
        final pid = DshLocalLaunch.pidFrom(await pidFile.readAsString());
        if (pid != null) {
          try {
            Process.killPid(pid, ProcessSignal.sigterm);
          } catch (_) {}
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            if (_exited) break;
          }
        }
      }
      if (!_exited) {
        try {
          p.kill(ProcessSignal.sigquit);
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (!_exited) p.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      await p.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// 拆除运行包（回到「连家里服务」形态）
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
    token = '';
    await setEnabled(false);
  }

  Future<void> setEnabled(bool v) async {
    _wantLocal = v;
    await aiStore.setString(_kEnable, v ? '1' : '0');
    if (!v) await stop();
  }
}
