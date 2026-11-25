// 本机 DSH（PRoot 方案）自检 —— 纯 Dart：`dart run tool/dsh_local_selfcheck.dart`
//
// 为什么需要它：
//   4.81.99 那版"完全体"装进 APK 后，用户点进去是白屏 —— 事后复盘发现真正的
//   原因是两件纯字符串层面的事：① 启动后就绪信号是 `dsh web: http://…/?token=…`
//   这一行，而不是"端口能连"；② WebView 打开的地址必须带 token，否则 DSH 一律
//   401。这两条**都不会让编译或 analyze 报错**，只会在真机上白屏。
//   所以把「启动命令长什么样」「token 怎么认」「URL 怎么拼」「停止发哪两枪」
//   全部钉成断言，谁改坏了立刻红。
//
// 断言分四类：
//   ① 配方：Termux 三个专有参数一个都不能少；占位符必须全部展开
//   ② 就绪：真实样本能抓到 token；无 token 的 URL 不能误判；43 字符样本
//   ③ 地址/停止：consoleUrl 带 token 且编码；pid 文件解析边界
//   ④ 接线：dsh_pack.dart 真的用了这套实现（防止改回内联字符串）
//
// 反证（2026-11-25 本机跑过）：
//   · 从 argv 里删掉 '--kill-on-exit' → 配方断言 FAIL
//   · 把 tokenLine 的 `\?token=` 改成 `\?tok=` → 就绪断言 FAIL
//   · 把 consoleUrl 的 token 分支删掉（只返回首页）→ 地址断言 FAIL
import 'dart:io';

import '../lib/core/dsh_local_argv.dart';

int _pass = 0;
final List<String> _fail = [];

void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail.add('$name${extra.isEmpty ? '' : '  ($extra)'}');
  }
}

void eq(String name, Object? got, Object? want) =>
    ck(name, got == want, 'got=$got want=$want');

String _read(String rel) => File(rel).readAsStringSync();

Future<void> main() async {
  const nativeLib = '/data/app/~~x/com.thirdhub.app-y/lib/arm64';
  const rootfs = '/data/user/0/com.thirdhub.app/files/dsh/rootfs';
  const tmp = '/data/user/0/com.thirdhub.app/cache/dsh-tmp';

  final argv = DshLocalLaunch.argv(
      nativeLib: nativeLib, rootfs: rootfs, tmp: tmp, port: 3825);
  final joined = argv.join(' ');

  // ── 1. 配方 ─────────────────────────────────────────────────────────
  ck('启动器就是 nativeLibraryDir 里的 libproot.so',
      argv.first == '$nativeLib/libproot.so', argv.first);
  for (final flag in ['--kill-on-exit', '--link2symlink', '--sysvipc', '-0']) {
    ck('Termux proot 专有参数 $flag 不能少', argv.contains(flag));
  }
  ck('rootfs 指向运行包解压目录', argv.contains('--rootfs=$rootfs'));
  ck('guest 工作目录是 /root', argv.contains('--cwd=/root'));
  ck('TMP 目录已展开（不能留占位符）', !joined.contains('{'), joined.substring(0, 60));
  ck('/dev 与 /proc 是真机绑定',
      argv.contains('/dev') && argv.contains('/proc'));
  ck('/dev/shm 指向 rootfs 内的可写目录',
      argv.contains('$rootfs/var/lib/dsh-app/shm:/dev/shm'));
  ck('guest 环境里 DSH_HOME 落在 /root/.dsh',
      argv.contains('DSH_HOME=/root/.dsh'));
  ck('PATH 含 /usr/local/bin（dsh 装在那）',
      argv.any((a) => a.startsWith('PATH=') && a.contains('/usr/local/bin')));

  // 真正拉起 dsh 的那一行：$$ 必须原样进 guest（Dart 插值会把它吃掉）
  final shIndex = argv.indexOf('/bin/sh');
  ck('用 /bin/sh -c 启动（要写 pid 文件）', shIndex > 0);
  final script = shIndex > 0 ? argv[shIndex + 2] : '';
  ck('脚本里有 echo 当前 pid 写 pid 文件', script.contains(r'echo $$ >'), script);
  ck('pid 文件路径与停止逻辑一致', script.contains('/tmp/dsh-web.pid'), script);
  ck('用的是 exec（不留 shell 中间层，SIGTERM 直达 node）',
      script.contains('exec /usr/local/bin/dsh web'), script);
  ck('端口写进命令行', script.contains('--port 3825 --no-open'), script);
  ck('只监听回环', script.contains('--host 127.0.0.1'), script);

  // proot 进程自身的环境
  final env = DshLocalLaunch.env(
      nativeLib: nativeLib, rootfs: rootfs, tmp: tmp);
  eq('PROOT_LOADER 指向 nativeLibraryDir', env['PROOT_LOADER'],
      '$nativeLib/libproot-loader.so');
  eq('PROOT_TMP_DIR 指向 cache', env['PROOT_TMP_DIR'], tmp);
  eq('LD_LIBRARY_PATH 用于找 libtalloc', env['LD_LIBRARY_PATH'], nativeLib);
  ck('PROOT_L2S_DIR 在 rootfs 内（--link2symlink 要用）',
      (env['PROOT_L2S_DIR'] ?? '').startsWith(rootfs));

  // ── 2. 就绪信号 ─────────────────────────────────────────────────────
  // 真机实测样本（DSH 0.2.2-rc.1，43 个 base64url 字符）
  const real =
      'dsh web: http://127.0.0.1:3825/?token=iXj_6R9OQvrju0zc5MF3BSnjLO7yJ-9cY7ANb8Clw-0';
  eq('真实样本能抓到 token 地址', DshLocalLaunch.tokenFrom(real),
      'http://127.0.0.1:3825/?token=iXj_6R9OQvrju0zc5MF3BSnjLO7yJ-9cY7ANb8Clw-0');
  final m = DshLocalLaunch.tokenLine.firstMatch(real);
  eq('样本里的端口解析正确', m?.group(2), '3825');
  eq('样本里的 token 长度', m?.group(3)?.length, 43);
  ck('没有 token 的行不能当就绪（端口通了也还是 401）',
      DshLocalLaunch.tokenFrom('dsh web: http://127.0.0.1:3825/') == null);
  ck('启动失败的日志不能误判为就绪',
      DshLocalLaunch.tokenFrom('dsh: startup failed: 1 required plugin did not activate') ==
          null);
  ck('前面的噪声不影响识别',
      DshLocalLaunch.tokenFrom('[dsh-app] launching … $real') == real.length.toString() ||
          DshLocalLaunch.tokenFrom('[dsh-app] launching … ${real}') != null);
  ck('换端口也能认', DshLocalLaunch.tokenFrom(
          'dsh web: http://127.0.0.1:3845/?token=abc_DEF-123') ==
      'http://127.0.0.1:3845/?token=abc_DEF-123');

  // ── 3. 地址与停止 ───────────────────────────────────────────────────
  eq('有 token 时地址带 token',
      DshLocalLaunch.consoleUrl('http://127.0.0.1:3825', 'abc'), 
      'http://127.0.0.1:3825/?token=abc');
  eq('base 带尾斜杠不多拼一个',
      DshLocalLaunch.consoleUrl('http://127.0.0.1:3825/', 'abc'),
      'http://127.0.0.1:3825/?token=abc');
  eq('没有 token 只能给首页（会 401，用于健康检查）',
      DshLocalLaunch.consoleUrl('http://127.0.0.1:3825', ''),
      'http://127.0.0.1:3825/');
  eq('token 里有需编码字符要编码',
      DshLocalLaunch.consoleUrl('http://127.0.0.1:3825', 'a+b/c='),
      'http://127.0.0.1:3825/?token=a%2Bb%2Fc%3D');
  eq('pid 文件内容解析', DshLocalLaunch.pidFrom('  12345\n'), 12345);
  ck('pid 为 0 不接受', DshLocalLaunch.pidFrom('0') == null);
  ck('pid 为 1 不接受（init 不能杀）', DshLocalLaunch.pidFrom('1') == null);
  ck('垃圾内容不接受', DshLocalLaunch.pidFrom('not-a-pid') == null);

  // ── 4. 接线（防止改回内联字符串）─────────────────────────────────────
  final pack = _read('lib/core/dsh_pack.dart');
  ck('dsh_pack 引用了统一配方', pack.contains("import 'dsh_local_argv.dart';"));
  ck('启动命令走 DshLocalLaunch.argv', pack.contains('DshLocalLaunch.argv('));
  ck('环境走 DshLocalLaunch.env', pack.contains('DshLocalLaunch.env('));
  ck('就绪走 DshLocalLaunch.tokenFrom', pack.contains('DshLocalLaunch.tokenFrom('));
  ck('地址走 DshLocalLaunch.consoleUrl',
      pack.contains('DshLocalLaunch.consoleUrl('));
  ck('停止走 pid 文件', pack.contains("dsh-web.pid"));
  ck('停止要发 SIGTERM 给 guest node', pack.contains('ProcessSignal.sigterm'));
  ck('兜底要发 SIGQUIT 给 proot（它忽略 SIGTERM）',
      pack.contains('ProcessSignal.sigquit'));
  ck('解压走流式 tar（内存解压会 OOM）', pack.contains('extractTarGzToDisk'));

  final page = _read('lib/core/ai_page.dart');
  ck('AI 页用带 token 的地址开 WebView',
      page.contains('DshPack.I.consoleUrl'));
  ck('WebView 随 url 重建（换 token 要换页面）',
      page.contains('key: ValueKey(_dshUrl)'));

  // ── 汇总 ────────────────────────────────────────────────────────────
  print('─' * 44);
  print('PASS $_pass   FAIL ${_fail.length}');
  if (_fail.isEmpty) {
    print('\n✅ 本机 DSH 配方完整：启动参数 / 就绪识别 / 停止两枪 / 接线，全部钉住');
  } else {
    print('\n❌ 失败项：');
    for (final f in _fail) {
      print('  - $f');
    }
    exitCode = 1;
  }
}
