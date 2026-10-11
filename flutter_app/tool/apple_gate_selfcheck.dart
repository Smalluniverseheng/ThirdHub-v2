// ═══════════════════════════════════════════════════════════════════════════
// apple_gate_selfcheck.dart —— Apple 过审平台门的行为自检（阶段6 闸门）
//
// 每条断言对应评估报告（outputs/ThirdHub-苹果过审可行性-实证评估-20261010.md）
// 的一个审查条目；不是形状断言，是**逐条行为断言 + 反例**：
//
//   1) iOS：批量下载必须关（5.2.3）
//   2) iOS：第三方影视源入口必须关（5.2.3）
//   3) iOS：可替换桌面必须关（2.1 —— 出现但不可用 = 拒）
//   4) iOS：引擎角色必须是 data-source（4.7.2，本报告最重要的结论）
//   5) iOS：引擎安装入口必须关（4.7.2）
//   6) Android：以上全部放开（平台差异化，不是一刀切砍功能）
//   7) 反例：iOS 与 Android 的结论必须**不同**（防止闸门恒真/恒假的假绿）
//   8) 4.8（条件触发）/5.1.1/5.1.2(i) 账号与披露要求
//   9) 2.1：不允许占位
//  10) toMap 与逐项 getter 一致（防 toMap 漏字段后自检仍绿）
//  11) currentGate() 可运行且返回合法值（接线冒烟）
//  12) 4.7.2 引擎端点运行时闸门（数据端点放行 / 非数据端点 iOS 拦截 + 反例）
//
// 跑法：dart --disable-dart-dev --packages=.dart_tool/package_config.json
//        tool/apple_gate_selfcheck.dart
// ═══════════════════════════════════════════════════════════════════════════
import '../lib/core/apple_gate.dart';

int pass = 0, fail = 0;
final List<String> fails = [];

void ck(String name, bool cond, [String? extra]) {
  if (cond) {
    pass++;
    print('  OK   $name');
  } else {
    fail++;
    fails.add(name);
    print('  FAIL $name${extra == null ? '' : '  -> $extra'}');
  }
}

void main() {
  const ios = AppleGate(ApplePlatform.ios);
  const android = AppleGate(ApplePlatform.android);
  const other = AppleGate(ApplePlatform.other);

  print('== 1-5. iOS 减配（§5.2/§5.3 + 4.7.2）==');
  ck('iOS 批量下载关闭', ios.allowBatchDownload == false);
  ck('iOS 第三方影视源关闭', ios.allowThirdPartyVideoSources == false);
  ck('iOS 可替换桌面关闭', ios.allowReplaceLauncher == false);
  ck('iOS 引擎角色 = data-source', ios.engineRole == 'data-source', ios.engineRole);
  ck('iOS 引擎安装关闭', ios.allowEngineInstall == false);

  print('== 6. Android 全放开（平台差异化）==');
  ck('Android 批量下载开', android.allowBatchDownload == true);
  ck('Android 第三方影视源开', android.allowThirdPartyVideoSources == true);
  ck('Android 可替换桌面开', android.allowReplaceLauncher == true);
  ck('Android 引擎角色 = full', android.engineRole == 'full', android.engineRole);
  ck('Android 引擎安装开', android.allowEngineInstall == true);

  print('== 7. 反例：两平台结论必须不同（防假绿）==');
  final iosMap = ios.toMap();
  final androidMap = android.toMap();
  final gates = [
    'allowBatchDownload',
    'allowThirdPartyVideoSources',
    'allowReplaceLauncher',
    'engineRole',
    'allowEngineInstall',
  ];
  for (final g in gates) {
    ck('$g 在 iOS/Android 结论不同', iosMap[g] != androidMap[g],
        'ios=${iosMap[g]} android=${androidMap[g]}');
  }

  print('== 8. 4.8 / 5.1.1 / 5.1.2(i) 账号与披露 ==');
  for (final g in [ios, android, other]) {
    final tag = g.platform.name;
    // 4.8 条件化：只有提供第三方/社交登录时才强制 Sign in with Apple。
    // 断言挂 kHasThirdPartyLogin 常量——常量翻 true 时此断言自动要求
    // needsSignInWithApple 跟着 true，漏改 getter 会在这里爆红。
    ck('[$tag] needsSignInWithApple == kHasThirdPartyLogin',
        g.needsSignInWithApple == kHasThirdPartyLogin);
    ck('[$tag] needsAccountDeletion', g.needsAccountDeletion == true);
    ck('[$tag] needsAiDisclosure', g.needsAiDisclosure == true);
  }

  print('== 9. 2.1 不允许占位 ==');
  ck('iOS 不允许占位', ios.allowsPlaceholders == false);
  ck('Android 不允许占位', android.allowsPlaceholders == false);

  print('== 10. toMap 与逐项一致 ==');
  ck('toMap 无漏项（10 键）', iosMap.length == 10, iosMap.keys.join(','));
  ck('toMap.allowBatchDownload 一致',
      iosMap['allowBatchDownload'] == ios.allowBatchDownload);
  ck('toMap.engineRole 一致', iosMap['engineRole'] == ios.engineRole);
  ck('toMap.needsAiDisclosure 一致',
      iosMap['needsAiDisclosure'] == ios.needsAiDisclosure);

  print('== 11. currentGate() 接线冒烟 ==');
  final g = currentGate();
  ck('currentGate 返回合法平台', ApplePlatform.values.contains(g.platform));
  ck('currentGate 判定自洽',
      g.allowBatchDownload == (g.platform != ApplePlatform.ios));

  print('== 12. 4.7.2 引擎端点运行时闸门（engineRole 的执行口）==');
  const dataPaths = [
    '/thp/meta',
    '/thp/search?type=novel&q=x',
    '/thp/chapters?id=1',
    '/thp/content?id=1&chapter=2',
    '/thp/discover?type=novel',
    '/thp/explore',
    '/thp/sources?count=1',
    '/thp/m/novel/content?id=1&chapter=2',
    '/thp/m/video/search?q=x',
    '/thp/m/music/info?id=1',
  ];
  const nonDataPaths = [
    '/thp/exec',
    '/thp/file/read?path=/etc',
    '/thp/m/novel/download?id=1',
    '/v1/account/delete',
    '/agent/peer/secrets',
  ];
  for (final p in dataPaths) {
    ck('iOS 放行数据端点 $p', ios.allowEngineEndpoint(p));
    ck('Android 放行数据端点 $p', android.allowEngineEndpoint(p));
  }
  for (final p in nonDataPaths) {
    ck('iOS 拦截非数据端点 $p', !ios.allowEngineEndpoint(p));
    ck('Android 放行非数据端点 $p（4.7 不约束）', android.allowEngineEndpoint(p));
  }
  ck('两平台对 /thp/exec 结论不同（防恒真/恒假）',
      ios.allowEngineEndpoint('/thp/exec') != android.allowEngineEndpoint('/thp/exec'));
  ck('isEngineDataEndpoint 与 allowEngineEndpoint(iOS) 一致',
      ios.allowEngineEndpoint('/thp/search') == isEngineDataEndpoint('/thp/search') &&
      ios.allowEngineEndpoint('/thp/exec') == isEngineDataEndpoint('/thp/exec'));

  print('');
  if (fail == 0) {
    print('全部通过（$pass 项）');
  } else {
    print('失败 $fail 项: ${fails.join(' / ')}');
  }
  // ★「打印 FAIL」≠「闸门拦住了」——CI 只看退出码，必须 exit(1)。
  if (fail > 0) {
    throw StateError('apple_gate_selfcheck: $fail 项失败');
  }
}
