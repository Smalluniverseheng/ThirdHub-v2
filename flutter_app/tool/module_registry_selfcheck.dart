// 共享模块注册表自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/module_registry_selfcheck.dart
//
// 覆盖：表体完整性 / 上行压缩（read 组五键→'read'）/ 下行展开（组开关+记忆子集）/
//       旧 id 兼容（novel 等按 read 组处理）/ 合并写不踩踏（不认识≠删除）/
//       **两端往返模拟**：App 改→网页改→App 改，各自不认识的 id 全程存活、
//       布局幂等稳定 —— 这是「网页改导航 App 跟着变、且互不抹掉对方配置」的机械保障。
//
// ★ 断言一律用 join(',') 比较 —— Dart 的 List == 是引用比较，直接 == [...] 恒假。
import '../lib/core/module_registry.dart';
import 'dart:io';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) { pass++; } else { fail++; print('  FAIL  $name'); }
}

/// 模拟网页端认识的 id 集合（BOARDS 20 id + profile，照抄 js/boards.js）
const List<String> webBoardIds = <String>[
  'ai', 'tavern', 'search', 'read', 'novel', 'comic', 'music', 'audio', 'video',
  'game', 'storage', 'community', 'navstation', 'toolbox', 'compute',
  'cloudphone', 'album', 'clouddrive', 'grade', 'plugins', 'profile',
];

void main() {
  // ── 1. 表体完整性 ──
  print('== 1. 表体完整性 ==');
  final allAppKeys = <String>[for (final e in kModuleRegistry) ...e.appKeys];
  final issues = ModuleRegistry.selfcheck(allAppKeys: allAppKeys);
  ck('selfcheck 零问题', issues.isEmpty);
  for (final i in issues) {
    print('    $i');
  }
  ck('条目数 = 74', kModuleRegistry.length == 74);
  ck('id 全部唯一',
      kModuleRegistry.map((e) => e.id).toSet().length == kModuleRegistry.length);
  ck(
      'read 行的五键 = kReadGroupAppKeys',
      kModuleRegistry
              .firstWhere((e) => e.id == kReadGroupId)
              .appKeys
              .join(',') ==
          kReadGroupAppKeys.join(','));

  // ── 2. 上行压缩：navIdsOf ──
  print('== 2. 上行压缩 navIdsOf ==');
  ck('read 组五键压缩成一个 read',
      ModuleRegistry.navIdsOf(['小说', '漫画', '音乐', '视频', '有声书']).join(',') == 'read');
  ck('read 组混排占首次出现位',
      ModuleRegistry.navIdsOf(['搜索', '小说', '漫画', 'AI']).join(',') == 'search,read,ai');
  ck('「我的」不进数组',
      ModuleRegistry.navIdsOf(['我的', '搜索']).join(',') == 'search');
  ck('read 组内 1 个键也算 read 开',
      ModuleRegistry.navIdsOf(['小说']).join(',') == 'read');
  ck('App 独有键映射自造 id',
      ModuleRegistry.navIdsOf(['自动化任务', '端网']).join(',') == 'jobs,peer');
  ck('双端共通键映射 board id',
      ModuleRegistry.navIdsOf(['工具箱', '相册']).join(',') == 'toolbox,album');

  // ── 3. 下行展开：applyNavIds ──
  print('== 3. 下行展开 applyNavIds ==');
  ck('read 默认展开五键',
      ModuleRegistry.applyNavIds(['read']).join(',') == '小说,漫画,音乐,视频,有声书,我的');
  ck('read 按记忆子集展开',
      ModuleRegistry.applyNavIds(['read'], readGroup: ['小说', '漫画']).join(',') == '小说,漫画,我的');
  ck('记忆子集里的非法键被滤掉',
      ModuleRegistry.applyNavIds(['read'], readGroup: ['小说', '搜索']).join(',') == '小说,我的');
  ck('记忆为空列表 = 组内全关（不是回落默认）',
      ModuleRegistry.applyNavIds(['read'], readGroup: []).join(',') == '我的');
  ck('read 不在数组 → 五个全隐',
      ModuleRegistry.applyNavIds(['search', 'ai']).join(',') == '搜索,AI,我的');
  ck('旧 id（novel 等）按 read 组展开',
      ModuleRegistry.applyNavIds(['novel']).join(',') == '小说,漫画,音乐,视频,有声书,我的');
  ck('旧 id 与 read 并存不重复展开',
      ModuleRegistry.applyNavIds(['read', 'comic']).join(',') == '小说,漫画,音乐,视频,有声书,我的');
  ck('网页独有 id 跳过（不认识≠删除，合并时带回去）',
      ModuleRegistry.applyNavIds(['tavern', 'grade', 'plugins']).join(',') == '我的');
  ck('App 独有 id 正常投影',
      ModuleRegistry.applyNavIds(['jobs', 'notes']).join(',') == '自动化任务,笔记,我的');
  ck('「我的」在数组里也只出现一次、在尾部',
      ModuleRegistry.applyNavIds(['profile', 'search']).join(',') == '搜索,我的');

  // ── 4. 合并写：mergeNavIds ──
  print('== 4. 合并写 mergeNavIds ==');
  final appKnown = ModuleRegistry.appKnownIds;
  ck('appKnownIds 含 read 与 profile、不含 tavern',
      appKnown.contains('read') && appKnown.contains('profile') && !appKnown.contains('tavern'));
  final m1 = ModuleRegistry.mergeNavIds(
      ['search', 'read'], ['tavern', 'search', 'grade'], knownIds: appKnown);
  ck('本端新顺序优先', m1.take(2).join(',') == 'search,read');
  ck('不认识的 id 保序追加尾部', m1.sublist(2).join(',') == 'tavern,grade');
  ck('认识的旧位置被丢弃（以新顺序为准）', m1.where((x) => x == 'search').length == 1);
  final m2 = ModuleRegistry.mergeNavIds(['jobs'], null, knownIds: appKnown);
  ck('云端数组为空时只留本端', m2.join(',') == 'jobs');
  final m3 = ModuleRegistry.mergeNavIds(
      ['read', 'read', 'jobs'], ['jobs', 'peer'], knownIds: appKnown);
  ck('本端输入去重', m3.where((x) => x == 'read').length == 1);
  ck('本端认识的不从云端尾部重复回来', m3.where((x) => x == 'jobs').length == 1);

  // ── 5. 两端往返模拟（核心回归：互不踩踏 + 幂等）──
  print('== 5. 两端往返模拟 ==');
  final webKnown = webBoardIds.toSet();
  // 初始：网页写布局 [ai, search, read, tavern]（网页用户配置）
  var cloudArr = <String>['ai', 'search', 'read', 'tavern'];
  // ① App 用户把导航改成 [搜索, 小说, 自动化任务, 我的] → 上行合并写
  final appUp = ModuleRegistry.navIdsOf(['搜索', '小说', '自动化任务', '我的']);
  cloudArr = ModuleRegistry.mergeNavIds(appUp, cloudArr, knownIds: appKnown);
  ck('App 上行后：App 的 id 在前', cloudArr.take(2).join(',') == 'search,read');
  ck('App 上行后：App 独有 id 进数组', cloudArr.contains('jobs'));
  ck('★ App 上行后：网页独有 id 全存活', cloudArr.contains('tavern'));
  // ② 网页用户在导航栏管理改成 [ai, game, read]（关掉 tavern）→ 合并写
  cloudArr = ModuleRegistry.mergeNavIds(['ai', 'game', 'read'], cloudArr, knownIds: webKnown);
  ck('网页改动后：网页新顺序在前', cloudArr.take(3).join(',') == 'ai,game,read');
  ck('★ 网页改动后：App 独有 id 全存活', cloudArr.contains('jobs'));
  ck('网页关掉的板块真的被删', !cloudArr.contains('tavern'));
  // ③ App 下行：投影出自己认识的（read 子集记忆 = 只开小说）
  final appDown = ModuleRegistry.applyNavIds(cloudArr, readGroup: ['小说']);
  ck('★ App 下行：read 子集生效（read 在 → 小说展开、漫画不展开）',
      appDown.contains('小说') && !appDown.contains('漫画'));
  ck('App 下行：App 独有模块回来了', appDown.contains('自动化任务'));
  // ④ App 再上行（幂等：不动布局时数组逐位不变）
  final appUp2 = ModuleRegistry.mergeNavIds(
      ModuleRegistry.navIdsOf(appDown), cloudArr, knownIds: appKnown);
  ck('★ 幂等：App 不改布局再上行，数组逐位不变',
      appUp2.join(',') == cloudArr.join(','));
  // ⑤ 网页再上行（幂等：网页只看得见自己认识的，但合并后数组不变）。
  //    网页侧 navIdsOf 是「网页 id 数组→canonical」（JS 版）：剔 profile、旧 id 归一 read。
  final webIds = cloudArr
      .where((x) => webBoardIds.contains(x) && x != 'profile')
      .map((x) => kLegacyReadIds.contains(x) ? kReadGroupId : x)
      .toList();
  final webUp2 =
      ModuleRegistry.mergeNavIds(webIds, cloudArr, knownIds: webKnown);
  ck('★ 幂等：网页不改布局再上行，数组逐位不变',
      webUp2.join(',') == cloudArr.join(','));
  // ⑥ 网页把 read 勾掉（内容组总开关）→ App 下行五个内容模块全隐
  final cloudNoRead =
      cloudArr.where((x) => x != 'read' && !kLegacyReadIds.contains(x)).toList();
  final appDown2 = ModuleRegistry.applyNavIds(cloudNoRead, readGroup: ['小说']);
  ck('★ 网页勾掉 read → App 内容五模块全隐',
      !['小说', '漫画', '音乐', '视频', '有声书'].any(appDown2.contains));

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ 全部通过');
  /* ★失败必须让进程**非零退出**：CI 的 dart-selfcheck 只看退出码，
     只打印 FAIL 而 return 0 的话，闸门形同虚设（2026-09-28 实测：
     8/10 个自检都没有 exit()，打印 FAIL 但 CI 一律绿灯）。*/
  if (fail > 0) exit(1);
}
