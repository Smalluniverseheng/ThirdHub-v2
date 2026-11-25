// 本机 DSH 的启动参数与就绪识别 —— 纯逻辑，不碰平台 API。
//
// 为什么单独拆出来：这些字符串一旦写错，用户看到的是「装了运行包但点进去白屏」，
// 而编译、analyze、甚至跑起来都不会报错（proot 只会在 stderr 里丢一句没人看的
// 错误）。所以把它们放进一个没有 flutter 依赖的文件，让
// `tool/dsh_local_selfcheck.dart` 能在纯 Dart VM 里逐条钉死。
//
// 配方出处：开源项目 dsh-Go 的 runtime manifest（PRoot + Ubuntu rootfs 跑 dsh web）。
// 有三个参数是 Termux 版 proot 的补丁能力，换成别的 proot 就没有，不能省：
//   --kill-on-exit   父 proot 退出时收割所有 tracee（否则 node 变孤儿占端口）
//   --link2symlink   用符号链接模拟硬链接（Android 私有目录不支持硬链接）
//   --sysvipc        给 guest 提供 SysV IPC（pnpm/某些 node 模块要）
class DshLocalLaunch {
  DshLocalLaunch._();

  /// 就绪信号：`dsh web` 起来后只会打印这一行，token 43 个 base64url 字符。
  /// **不能靠探端口判断就绪** —— 端口通了但没 cookie 一律 401。
  static final RegExp tokenLine =
      RegExp(r'dsh web:\s*(http://127\.0\.0\.1:(\d+)/)\?token=([A-Za-z0-9_\-]+)');

  /// 从 `dsh web:` 那行里取 token 地址（拿不到返回 null）
  static String? tokenFrom(String line) {
    final m = tokenLine.firstMatch(line);
    if (m == null) return null;
    final path = m.group(1);
    final tok = m.group(3);
    if (path == null || tok == null || tok.isEmpty) return null;
    return '$path?token=$tok';
  }

  /// WebView 地址：没有 token 时只能拿到首页（会 401），有 token 才能进
  static String consoleUrl(String base, String token) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final t = token.trim();
    return t.isEmpty ? '$b/' : '$b/?token=${Uri.encodeQueryComponent(t)}';
  }

  /// rootfs 里的 pid 文件内容 → pid（proot 不虚拟 PID，这里就是真 pid）
  static int? pidFrom(String text) {
    final p = int.tryParse(text.trim());
    return (p != null && p > 1) ? p : null;
  }

  /// PRoot 启动命令。
  /// [nativeLib] = applicationInfo.nativeLibraryDir（放 libproot.so 等）
  /// [rootfs] = filesDir/dsh/rootfs
  /// [tmp] = cacheDir/dsh-tmp（PROOT_TMP_DIR）
  static List<String> argv({
    required String nativeLib,
    required String rootfs,
    required String tmp,
    required int port,
  }) =>
      [
        '$nativeLib/libproot.so',
        '--kill-on-exit',
        '--link2symlink',
        '--sysvipc',
        '-L',
        '-0',
        '--rootfs=$rootfs',
        '--cwd=/root',
        // /dev 与 /proc 必须是真机的（node 要 epoll/inotify/urandom）
        '-b', '/dev',
        '-b', '/dev/urandom:/dev/random',
        '-b', '/proc',
        '-b', '/proc/self/fd:/dev/fd',
        '-b', '/proc/self/fd/0:/dev/stdin',
        '-b', '/proc/self/fd/1:/dev/stdout',
        '-b', '/proc/self/fd/2:/dev/stderr',
        '-b', '/sys',
        // guest 里这些路径必须存在，否则 apt/glibc 探测会报一堆噪声
        '-b', '$rootfs/var/lib/dsh-app/empty:/sys/fs/selinux',
        '-b', '$rootfs/var/lib/dsh-app/shm:/dev/shm',
        '-b', '/system',
        '-b', '/apex',
        '/usr/bin/env', '-i',
        'HOME=/root',
        'USER=root',
        'LOGNAME=root',
        'SHELL=/bin/bash',
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'LANG=C.UTF-8',
        'TERM=xterm-256color',
        'TMPDIR=/tmp',
        'DSH_HOME=/root/.dsh',
        // Android 的字体都在 /system（上面已 bind），Linux 侧字体发现会追加 /fonts
        'XDG_DATA_DIRS=/usr/local/share:/usr/share:/system',
        'NODE_OPTIONS=--dns-result-order=ipv4first',
        'UV_USE_IO_URING=0',
        '/bin/sh', '-c',
        // $$ 必须原样进 guest：它是 shell 自己的 pid，写进 pid 文件供停止时使用
        r'echo $$ > /tmp/dsh-web.pid; exec /usr/local/bin/dsh web --host 127.0.0.1 --port '
            '$port --no-open',
      ];

  /// 启动时传给 proot 进程本身的环境（不是 guest 的）
  static Map<String, String> env({
    required String nativeLib,
    required String rootfs,
    required String tmp,
  }) =>
      {
        // loader 必须走 nativeLibraryDir：APK 里的 .so 只有这里可执行
        'PROOT_LOADER': '$nativeLib/libproot-loader.so',
        'PROOT_TMP_DIR': tmp,
        'PROOT_L2S_DIR': '$rootfs/root/.l2s',
        'LD_LIBRARY_PATH': nativeLib,
        'PATH': '/system/bin:/system/xbin',
      };
}
