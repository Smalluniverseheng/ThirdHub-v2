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

  // ── 5. 后台保活（4.81.107）───────────────────────────────────────────
  // 这一节守的是「切出去回来 AI 就断」那个坑。它同样是编译期抓不到的：
  // 少一个权限、少一个 foregroundServiceType、服务起了但没释放唤醒锁，
  // analyze / build 全都会绿，只有真机在后台待一会儿才暴露。
  final mf = _read('android/app/src/main/AndroidManifest.xml');
  ck('清单声明了前台服务类型权限（targetSdk 34+ 缺它 startForeground 直接抛）',
      mf.contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'));
  ck('清单声明了 WAKE_LOCK', mf.contains('android.permission.WAKE_LOCK'));
  ck('清单声明了忽略电池优化（国产 ROM 那一层）',
      mf.contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'));
  ck('保活服务已注册', mf.contains('.DshKeepAliveService'));
  ck('服务类型是 dataSync（漏了服务起不来）',
      mf.contains('android:foregroundServiceType="dataSync"'));
  ck('服务不导出', RegExp(r'DshKeepAliveService"[^>]*android:exported="false"').hasMatch(mf));

  final svc = _read(
      'android/app/src/main/kotlin/com/thirdhub/app/DshKeepAliveService.kt');
  ck('服务真的调了 startForeground', svc.contains('startForeground(NOTI_ID'));
  ck('用的是 PARTIAL 唤醒锁（只保 CPU 不保屏）',
      svc.contains('PARTIAL_WAKE_LOCK'));
  ck('唤醒锁一定会释放（漏放会留一条永不消失的持锁记录）',
      svc.contains('l.isHeld) l.release()'));
  ck('通知栏有停止按钮', svc.contains('ACTION_STOP'));
  // 刻意不用 START_STICKY：服务被重拉时 PRoot 里的 node 已经没了，
  // 硬顶着"运行中"的通知等于对用户撒谎。
  ck('服务被重拉时不假装还在跑（用 NOT_STICKY）',
      svc.contains('START_NOT_STICKY') && !svc.contains('return START_STICKY'));

  final ma = _read('android/app/src/main/kotlin/com/thirdhub/app/MainActivity.kt');
  ck('原生通道名与 Dart 侧一致', ma.contains('"thirdhub/keepalive"'));
  ck('服务持有了 channel（通知栏停止按钮的回传出口）',
      ma.contains('DshKeepAliveService.channel = keepCh'));
  ck('能查电池优化白名单', ma.contains('isIgnoringBatteryOptimizations'));
  ck('能弹系统授权对话框',
      ma.contains('ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'));

  final ka = _read('lib/core/dsh_keepalive.dart');
  ck('Dart 桥接用同一个通道名', ka.contains("MethodChannel('thirdhub/keepalive')"));
  ck('非 Android 平台直接短路（不炸桌面/网页端）', ka.contains('Platform.isAndroid'));
  ck('通知栏停止回调挂在 DshPack 上', pack.contains('DshKeepAlive.onUserStop'));
  ck('保活只在本机真的起来之后开',
      pack.indexOf('DshKeepAlive.start(') > pack.indexOf('if (await _alive())'));
  ck('停止时先收保活（进程没了不该还挂"运行中"）',
      pack.indexOf('await DshKeepAlive.stop();') <
          pack.indexOf('    if (p == null) return;'));
  ck('有健康检查供回前台自愈', pack.contains('Future<bool> healthOk()'));
  // 只看「函数在不在」是假绿灯：把 body 直接 return true 也照样过。
  // 所以钉住判断条件本身 —— 三个条件缺一个都会漏掉"进程半死"的情况。
  ck('健康检查真的看了进程/token（不是恒真）',
      pack.contains('_proc == null || _exited || token.isEmpty'));

  ck('AI 页监听生命周期', page.contains('WidgetsBindingObserver'));
  ck('回到前台检查本机运行是否还活着', page.contains('healthOk()'));
  ck('死了才重起（活着无脑重起会换 token 白闪）',
      page.contains('await DshPack.I.healthOk()) return;'));
  ck('监听器有摘除（否则 State 泄漏）',
      page.contains('removeObserver(this)'));

  // ── 6. Kotlin 语法地雷（4.81.107 踩过一次，白烧一轮 7 分钟 CI）──────
  // 表达式体（`= try { ... }` / `= run { ... }`）里不允许 return。写了就是
  // `e: Returns are prohibited in functions with expression body`，
  // 而 dart analyze 完全看不到 —— 只有 :app:compileReleaseKotlin 会红。
  for (final f in [
    'android/app/src/main/kotlin/com/thirdhub/app/MainActivity.kt',
    'android/app/src/main/kotlin/com/thirdhub/app/DshKeepAliveService.kt',
  ]) {
    ck('$f 表达式体里没有 return', _noReturnInExpressionBody(_read(f)), f);
  }

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

/// 扫出「表达式体函数里写了 return」这种 Kotlin 硬错误。
/// 判定很朴素但够用：`fun ... = try {` / `= run {` 开头，按大括号配平往下扫，
/// 配平结束前出现独立的 `return` 就是错。误报风险：字符串字面量里出现 return
/// （本项目没有），可接受。
bool _noReturnInExpressionBody(String src) {
  final lines = src.split('\n');
  final re = RegExp(r'^\s*(?:private |internal |public )?fun\s+[\w<>]+\(.*\)\s*(?::\s*[\w<>?. ]+)?\s*=\s*(?:try|run|with|let)\s*\{');
  for (var i = 0; i < lines.length; i++) {
    if (!re.hasMatch(lines[i])) continue;
    var depth = 0;
    for (var j = i; j < lines.length; j++) {
      for (final ch in lines[j].split('')) {
        if (ch == '{') depth++;
        if (ch == '}') depth--;
      }
      if (j > i && RegExp(r'^\s*return\b').hasMatch(lines[j])) return false;
      if (depth <= 0 && j > i) break;
    }
  }
  return true;
}
