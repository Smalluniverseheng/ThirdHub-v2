// 「搜索类型选择器按资料库能力过滤」（任务 #195）的纯 Dart 自检。
//
// 覆盖三件事：
//   ① 规则层：没连资料库时不过滤、判不出能力时不过滤、「全部」永远保留、
//      当前选中项被砍掉时回落；
//   ② 接线：main.dart 真的调用规则层，而不是只放了个没人用的文件；
//   ③ 版本号：本轮改动必须伴随 bump（同版本号不同字节是历史事故）。
//
// 运行：`dart run tool/search_type_filter_selfcheck.dart`（FAIL 必须让退出码非 0）

import 'dart:io';

import 'package:thirdhub_app/core/search_type_filter.dart';

int pass = 0, fail = 0;
void ok(bool cond, String what) {
  if (cond) {
    pass++;
  } else {
    fail++;
    print('FAIL  $what');
  }
}

const android = [0, 1, 2, 3, 4];
const ios = [1, 2, 4];

void main() {
  print('== 1. 常量与能力声明解析 ==');
  ok(kSearchTypeKeys.length == 5, '5 个类型下标');
  ok(kSearchTypeKeys[0].isEmpty, '0 号是「全部」（空 type）');
  ok(kSearchTypeKeys.contains('novel') && kSearchTypeKeys.contains('comic') &&
      kSearchTypeKeys.contains('video') && kSearchTypeKeys.contains('music'),
      '四个模块键齐全');
  ok(declaredModules(['m:comic', 'stream-search', 'search-mode']).join(',') == 'comic',
      '只认 m: 前缀，其它能力不算模块');
  ok(declaredModules(['m:novel', 'm:novel']).length == 1, '重复声明去重');
  ok(declaredModules(['m:all', 'm:library']).isEmpty, 'm:all / 未知模块不算');
  ok(declaredModules([]).isEmpty, '空 caps 不产能力');

  print('== 2. 可用模块 = caps ∪ 多资料库路由 ==');
  ok(availableModules(['m:comic'], ['novel']).join(',') == 'comic,novel',
      '主连接 + 局域网另一台的能力取并集');
  ok(availableModules(['m:comic'], ['comic']).length == 1, '并集去重');
  ok(availableModules([], ['music', 'library']).join(',') == 'music',
      '路由表里的非模块键被丢掉');
  ok(availableModules([], []).isEmpty, '两者都空 → 判不出能力');

  print('== 3. 可见类型下标 ==');
  List<int> vis({
    List<int> platform = android,
    bool connected = true,
    List<String> caps = const ['m:comic'],
    List<String> routes = const [],
  }) =>
      visibleTypeIndexes(
        platform: platform,
        engineConnected: connected,
        caps: caps,
        routeModules: routes,
      );
  ok(vis(connected: false).join(',') == '0,1,2,3,4',
      '没连资料库（走资源库聚合）→ 一个都不砍');
  ok(vis().join(',') == '0,2', '只连漫画资料库 → 全部 + 漫画');
  ok(vis(platform: ios).join(',') == '2', 'iOS 平台放行与能力取交集 → 只留漫画');
  ok(vis(caps: const ['m:novel', 'm:music']).join(',') == '0,1,4',
      '多模块资料库：顺序保持平台顺序，不按 caps 顺序重排');
  ok(vis(caps: const [], routes: const []).join(',') == '0,1,2,3,4',
      '★老资料库不带能力标签 → 保守不过滤（不能把整行砍空）');
  ok(vis(caps: const [], routes: const ['video']).join(',') == '0,3',
      '主连接没标签但路由表认出视频 → 只显示视频');
  ok(vis(platform: ios, caps: const ['m:video']).join(',') == '1,2,4',
      '★交集为空（iOS 无视频、资料库只有视频）→ 退回平台列表，不空');
  ok(vis(platform: [-1, 99, 2]).join(',') == '2',
      '越界下标被跳过；规则只在平台放行项里筛，不会凭空加「全部」');
  ok(vis().length == 2 && vis()[0] == 0, '「全部」永远保留');
  final a = vis(), b = vis();
  ok(a.join(',') == b.join(','), '同样输入结果稳定（不依赖返回顺序）');

  print('== 4. 选中项回落 ==');
  ok(resolveTypeFilter(4, [0, 2]) == 0, '选中音乐但只剩漫画 → 回落到「全部」');
  ok(resolveTypeFilter(2, [0, 2]) == 2, '选中项仍可见 → 原样保留');
  ok(resolveTypeFilter(3, [2]) == 2, 'iOS 只剩漫画 → 回落到漫画');
  ok(resolveTypeFilter(4, []) == 1, '可见列表为空时兜底小说下标，不越界');

  print('== 5. 「全部」逐类搜索实际要问的模块 ==');
  ok(allSearchModules([0, 2]).join(',') == 'comic', '只问漫画，不再白发三条');
  ok(allSearchModules([0, 1, 2, 3, 4]).join(',') == 'novel,comic,video,music',
      '全能力时四模块齐全且顺序与 UI 一致');
  ok(allSearchModules([0]).isEmpty, '只剩「全部」时不发具体模块请求');
  ok(allSearchModules([1, 2, 4]).join(',') == 'novel,comic,music',
      'iOS 平台列表也能正确推导');

  print('== 6. 接线（防「只写了一半」） ==');
  final mainSrc = File('lib/main.dart').readAsStringSync();
  final ed = File('lib/core/engine_direct.dart').readAsStringSync();
  final rule = File('lib/core/search_type_filter.dart').readAsStringSync();
  ok(mainSrc.contains("import 'core/search_type_filter.dart';"),
      'main.dart 已引入规则层');
  ok(mainSrc.contains('visibleTypeIndexes('), '_typeIdx 真的调用规则层');
  ok(mainSrc.contains('resolveTypeFilter(typeFilter, _typeIdx)'),
      '_effectiveType getter 存在');
  ok(mainSrc.contains('allSearchModules(_typeIdx)'),
      '老资料库逐类搜索与 _typeTotal 都按能力过滤');
  ok(mainSrc.contains('setState(() => typeFilter = t);'),
      '连接状态变化时会收敛选中类型');
  ok(!mainSrc.contains('typeNames[typeFilter]'),
      'hintText 不再直读未收敛的 typeFilter');
  ok(!mainSrc.contains("typeKeys[typeFilter]"),
      '请求参数不再直读未收敛的 typeFilter');
  ok(ed.contains('static bool supportsType(') && ed.contains('supportedTypes'),
      '能力闸门（4.81.39）仍在，UI 与后端判据同源');
  ok(rule.contains('if (!engineConnected)'), '规则层保留「未连接不过滤」');
  ok(rule.contains('if (mods.isEmpty)'), '规则层保留「判不出能力不过滤」');

  print('== 7. 版本号 ==');
  final ver = File('lib/core/app_version.dart').readAsStringSync();
  ok(ver.contains("kAppVersion = '4.81.43'"), 'kAppVersion 已 bump 到 4.81.43');
  ok(ver.contains('kAppCode = 50714'), 'kAppCode 只增不减 → 50714');
  ok(File('pubspec.yaml').readAsStringSync().contains('version: 4.81.43+50714'),
      'pubspec 与 Dart 常量一致');

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exit(1);
}
