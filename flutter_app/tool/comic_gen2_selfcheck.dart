// 第2代 OmniHub 漫画阅读器对齐 + DSH 完全体内置 的守门自检（4.81.112）
//
// 这些改动跨越 main.dart 18000+ 行，最容易被后续「顺手清理」误删：
//   · DSH 完全体从外置下载改为 APK 内置（CI 拉 178MB → assets/dsh → 原生流式提取）
//   · 漫画阅读器新增亮度/夜间/目录抽屉/沉浸/设置底弹窗
// 纯静态检查，零依赖、零网络，CI 秒级跑完。
import 'dart:io';

int pass = 0;
int fail = 0;

void ok(String name, bool cond) {
  if (cond) {
    pass++;
    // print('  PASS $name');
  } else {
    fail++;
    print('  FAIL $name');
  }
}

void main() {
  final app = Directory.current.path.endsWith('flutter_app')
      ? Directory.current
      : Directory('flutter_app');
  String read(String rel) {
    final f = File('${app.path}/$rel');
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  final main = read('lib/main.dart');
  final dsh = read('lib/core/dsh_pack.dart');
  final kt = read(
      'android/app/src/main/kotlin/com/thirdhub/app/MainActivity.kt');
  final pubspec = read('pubspec.yaml');
  final ci = read('../.github/workflows/build-apk.yml');
  final bundler = read('tool/fetch_dsh_bundle.py');
  final i18n = read('lib/core/i18n_extra.dart');

  print('=== 1. DSH 完全体内置链路 ===');
  ok('pubspec 声明 assets/dsh/', pubspec.contains('- assets/dsh/'));
  ok('CI 调 fetch_dsh_bundle.py', ci.contains('tool/fetch_dsh_bundle.py'));
  ok('CI 校验 rootfs > 150MB', ci.contains('-gt 150000000'));
  ok('抓包脚本校验整包 sha256', bundler.contains('整包 sha256 不符'));
  ok('抓包脚本分片校验', bundler.contains('分片 sha256 不符'));
  ok('客户端优先提取内置包', dsh.contains('_copyBundled(tmp'));
  ok('内置包失败回退网络下载', dsh.contains('if (!bundled)'));
  ok('清单拉不到也能装（离线可用内置包）',
      dsh.contains('清单拉不到，改用安装包内置运行包'));
  ok('内置包走原生流式(不 OOM)',
      dsh.contains("invokeMethod<int>('extractAsset'"));
  ok('Dart 未调用 loadStream（无此 API，注释提及不算）',
      !dsh.contains('rootBundle.loadStream'));
  // ★4.81.113：这两条是「内置包到底能不能取出来」的命门，必须钉死。
  //   ① Dart 传的是 pubspec 键 assets/dsh/rootfs.tar.gz，APK 里实际落在
  //     assets/flutter_assets/…，原生不补前缀 → 永远 EXTRACT_MISS → 静默回退联网下载，
  //     用户看到的就是「完全体没放进安装包」。
  ok('原生补 flutter_assets 前缀（否则内置包取不到）',
      kt.contains('"flutter_assets/\$asset"'));
  ok('原生逐个候选路径尝试', kt.contains('for (c in candidates)'));
  ok('原生 AssetManager.open 流式写盘', kt.contains('assets.open(c)'));
  ok('原生用后台线程（避免 ANR）', kt.contains('Thread {'));
  ok('原生回传必须回主线程', kt.contains('runOnUiThread { result.success'));

  print('=== 2. 漫画阅读器 OmniHub 二代对齐 ===');
  ok('Scaffold key 接通目录抽屉', main.contains('key: _ecrKey'));
  ok('目录左侧抽屉 Drawer', main.contains('drawer: Drawer('));
  ok('目录当前章高亮', main.contains('selected: i == idx'));
  ok('目录底部上一话/下一话操作栏', main.contains("Text(tr('上一话'))"));
  ok('亮度状态字段', main.contains('double comicBright = 1.0;'));
  ok('亮度从设置恢复', main.contains("getDouble('comicBrightness')"));
  ok('亮度落盘', main.contains("setDouble('comicBrightness', v)"));
  ok('夜间模式落盘', main.contains("setBool('comicNight', v)"));
  ok('阅读设置底部弹窗', main.contains('void _openComicSettings(BuildContext c)'));
  ok('设置入口按钮', main.contains("tooltip: tr('阅读设置')"));
  ok('沉浸阅读切换', main.contains("tooltip: tr('沉浸阅读')"));
  ok('沉浸时 AppBar 隐藏', main.contains('appBar: _showChrome'));
  ok('沉浸时底栏隐藏', main.contains('bottomNavigationBar: _showChrome'));
  ok('亮度黑色遮罩', main.contains('alpha: (1 - comicBright) * 0.55'));
  ok('夜间暖色罩', main.contains('Color(0x18FFB74D)'));
  // 4.81.114 双击缩放：三条一起钉 —— 只钉「有这个函数」不钉落点算法，等于没钉
  // （照印象重写最容易把「围绕落点」写成围绕中心，用户感觉就是双开放大后看不到想看的半边）。
  ok('双击缩放：围绕落点换算', main.contains('translate(-at.dx * (s - 1)'));
  ok('双击缩放：控制器接进 InteractiveViewer',
      main.contains('transformationController: _zoomCtlOf(i)'));
  ok('双击只在中间区检测（翻页手感不变）',
      main.contains('if (now - _lastCenterTapMs < 300 && near)'));
  ok('双击缩放：再次双击还原', main.contains('getMaxScaleOnAxis() > 1.05'));

  print('=== 3. 六语言新键 ===');
  for (final k in [
    '夜间模式',
    '目录',
    '沉浸阅读',
    '翻页',
    '条漫滚动',
    '双页',
    '阅读设置',
    '共{n}话',
  ]) {
    ok('i18n $k', i18n.contains("'$k'"));
  }

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exit(1);
}
