// 三端统一账号绑定与设备互通同步契约 · 联合自检（全盘升级任务 #202）
//
//   dart run tool/device_sync_contract_selfcheck.dart [--no-web] [--web=<网页端根>]
//
// 验收口径（计划文档 outputs/ThirdHub全盘升级计划-20261107.md 交付物表）：
//   「三端字典逐键一致，自检 FAIL=0」。
//
// 为什么要有这条闸门（本轮核实的真实断层）：
//   6 张同步表此前在三个地方各写一份 —— App 的 cloud.dart、网页端的
//   js/supabase.js、桌面端 server/neon.js。三份都是**手抄**的，谁加一张表、
//   谁改一个短名，另外两端完全不会知道；这类漂移在编译/analyze/单测里全绿。
//   所以本闸门断言的是「同一份真源在三端逐键相等」+「契约真的被三端引用」，
//   不是「文件存在」「函数定义了」这种形状检查（见 sync_contract_selfcheck 的教训）。
//
// 四层断言：
//   ① 行为：Dart 契约函数真跑（冲突裁决 / 设备规范化 / 权限 / 通道 / 合并）；
//   ② 字典：contracts/unified_sync_v1.json ↔ Dart 常量 ↔ Node 源码常量 ↔
//            网页端 supabase.js ↔ 桌面端 neon.js，逐键比对；
//   ③ 接线：三端真的 import/require/引用契约，CI 里真的跑这条闸门；
//   ④ 边界：恶意 device_id / 非法 kind / 空账号一律整行丢弃，不洗白。
//
// --no-web：网页端是独立私有仓，CI 里不在本仓（$TH_WEB_ROOT 未配）。
//           与 skin_parity_selfcheck.dart 同一惯例：CI 跳过网页端比对并打印提示，
//           本机带 TH_WEB_ROOT 才做三方全量比对。**不能因为路径没配就变成假绿**
//           —— 本仓内的三份字典仍然逐键断言，一条不少。
//
// 纯 Dart VM 可跑：只 import dart:io / dart:convert 与三个零依赖 dart 文件。
import 'dart:convert';
import 'dart:io';

import '../lib/core/device_sync_contract.dart';
import '../lib/core/sync_contract.dart' as legacy;

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

String read(String p) => File(p).readAsStringSync();

/// 从 JS 源码里切出 `const NAME = [ ... ]` 的内容，再抽所有单引号字面量。
///
/// 结束符用「第一个 `]`」而不是 `];`：server/neon.js 写的是
/// `new Set([ ... ]);`，调用方把 `new Set([` 归一成 `[` 之后结尾仍是 `]);`，
/// 找 `];` 会一路找到文件末尾去（或干脆找不到），解析结果悄悄变成空数组。
/// 这几个数组的元素都是简单字符串，内部不可能出现 `]`，故第一个 `]` 即闭合。
List<String> jsArray(String src, String name) {
  final int s = src.indexOf('const $name = [');
  if (s < 0) return const <String>[];
  final int e = src.indexOf(']', s);
  if (e < 0) return const <String>[];
  final String body = src.substring(s, e);
  return RegExp(r"'([^']+)'")
      .allMatches(body)
      .map((RegExpMatch m) => m.group(1)!)
      .toList();
}

/// 从 JS 源码里切出 `const NAME = { ... };` 并抽 `key: 'value'` 对。
Map<String, String> jsObject(String src, String name) {
  final int s = src.indexOf('const $name = {');
  if (s < 0) return <String, String>{};
  final int e = src.indexOf('};', s);
  if (e < 0) return <String, String>{};
  final String body = src.substring(s, e);
  final Map<String, String> out = <String, String>{};
  for (final RegExpMatch m in RegExp(r"(\w+)\s*:\s*'?([^,}'\s]+)'?").allMatches(body)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

/// 网页端 TBL_MAP 写法：`const TBL_MAP = { th_bookshelf: 'bookshelf', ... };`
Map<String, String> jsWebMap(String src) {
  final int s = src.indexOf('const TBL_MAP = {');
  if (s < 0) return <String, String>{};
  final int e = src.indexOf('};', s);
  if (e < 0) return <String, String>{};
  final Map<String, String> out = <String, String>{};
  for (final RegExpMatch m
      in RegExp(r"(th_[a-z_]+)\s*:\s*'([^']+)'").allMatches(src.substring(s, e))) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

String mapKey(Map<String, String> m) {
  final List<String> ks = m.keys.toList()..sort();
  return ks.map((String k) => '$k=${m[k]}').join('|');
}

void main(List<String> args) {
  final bool noWeb = args.contains('--no-web');
  String webRoot = Platform.environment['TH_WEB_ROOT'] ?? '';
  for (final String a in args) {
    if (a.startsWith('--web=')) webRoot = a.substring('--web='.length);
  }

  print('== 1. 契约真源完整 ==');
  final Map<String, dynamic> c =
      jsonDecode(read('../contracts/unified_sync_v1.json')) as Map<String, dynamic>;
  ck('schema 标识', c['schema'] == kSyncSchema);
  ck('契约版本', c['version'] == kSyncContractVersion);
  final List<String> cTables =
      (c['sync_tables'] as List).map((dynamic e) => '$e').toList();
  final Map<String, String> cAlias = (c['table_aliases'] as Map)
      .map((dynamic k, dynamic v) => MapEntry<String, String>('$k', '$v'));
  final List<String> cKinds =
      (c['device']['kinds'] as List).map((dynamic e) => '$e').toList();
  final Map<String, int> cPriority = (c['device']['priority'] as Map)
      .map((dynamic k, dynamic v) => MapEntry<String, int>('$k', (v as num).toInt()));
  final List<String> cCaps = (c['device']['capabilities'] as List)
      .map((dynamic e) => '$e').toList();
  final List<String> cFields = (c['device']['required_fields'] as List)
      .map((dynamic e) => '$e').toList();
  final List<String> cChannels =
      (c['channels'] as List).map((dynamic e) => '$e').toList();
  final List<String> cTransports =
      (c['transports'] as List).map((dynamic e) => '$e').toList();
  final List<String> cSettings =
      (c['permission']['settings_tables'] as List).map((dynamic e) => '$e').toList();
  final List<String> cContent =
      (c['permission']['content_tables'] as List).map((dynamic e) => '$e').toList();

  ck('6 张同步表齐全且顺序固定', cTables.length == 6 &&
      cTables.join('|') == kSyncTables.join('|'));
  ck('表别名 6 项', cAlias.length == 6);
  ck('设备类型 4 种', cKinds.length == 4);
  ck('设备优先级 4 档', cPriority.length == 4);
  ck('会话/设备/发现/配对四张表名', c['session_table'] == kSessionTable &&
      c['device_table'] == kDeviceTable &&
      c['discovery_table'] == kDiscoveryTable && c['pair_table'] == kPairTable);
  ck('冲突策略 = 后写胜出 + 优先级 + 墓碑',
      c['conflict']['strategy'] == kConflictStrategy &&
      c['conflict']['tie_break'] == kTieBreak &&
      c['conflict']['delete'] == kDeleteRule);
  ck('权限要求与移动端口径一致',
      c['permission']['content_requires'] == 'member_or_self_hosted' &&
      c['permission']['session_requires'] == 'logged_in');

  print('== 2. 字典逐键一致：真源 ↔ 移动端 Dart ==');
  ck('同步表', cTables.join('|') == kSyncTables.join('|'));
  ck('设备类型', cKinds.join('|') == kDeviceKinds.join('|'));
  ck('设备优先级', mapKey(cPriority.map((String k, int v) => MapEntry(k, '$v'))) ==
      mapKey(kDevicePriority.map((String k, int v) => MapEntry(k, '$v'))));
  ck('设备能力', cCaps.join('|') == kDeviceCapabilities.join('|'));
  ck('设备必备字段', cFields.join('|') == kDeviceRequiredFields.join('|'));
  ck('双通道', cChannels.join('|') == kSyncChannels.join('|'));
  ck('传输方式', cTransports.join('|') == kSyncTransports.join('|'));
  ck('设置类表', cSettings.join('|') == kSettingsTables.join('|'));
  ck('内容类表', cContent.join('|') == kContentTables.join('|'));
  ck('表别名与 6 张表一一对应',
      cAlias.length == cTables.length && cTables.every(cAlias.containsKey));

  print('== 3. 字典逐键一致：真源 ↔ 桌面端 Node ==');
  final String nodeSrc = read('../server/device_sync_contract.js');
  final List<String> nTables = jsArray(nodeSrc, 'SYNC_TABLES');
  final Map<String, String> nAlias = jsObject(nodeSrc, 'TABLE_ALIASES');
  final List<String> nKinds = jsArray(nodeSrc, 'DEVICE_KINDS');
  final List<String> nCaps = jsArray(nodeSrc, 'DEVICE_CAPABILITIES');
  final List<String> nFields = jsArray(nodeSrc, 'DEVICE_REQUIRED_FIELDS');
  final List<String> nChannels = jsArray(nodeSrc, 'SYNC_CHANNELS');
  final List<String> nTransports = jsArray(nodeSrc, 'SYNC_TRANSPORTS');
  final List<String> nSettings = jsArray(nodeSrc, 'SETTINGS_TABLES');
  final List<String> nContent = jsArray(nodeSrc, 'CONTENT_TABLES');
  final Map<String, String> nPriority = jsObject(nodeSrc, 'DEVICE_PRIORITY');
  final Map<String, String> nStr = jsObject(nodeSrc, 'DEVICE_PRIORITY');
  ck('Node 同步表 6 张且顺序一致', nTables.join('|') == cTables.join('|'));
  ck('Node 表别名逐键一致', mapKey(nAlias) == mapKey(cAlias));
  ck('Node 设备类型', nKinds.join('|') == cKinds.join('|'));
  ck('Node 设备优先级逐键一致',
      mapKey(nPriority) == mapKey(cPriority.map((String k, int v) => MapEntry(k, '$v'))));
  ck('Node 优先级确实被解析到（非空）', nStr.isNotEmpty);
  ck('Node 设备能力', nCaps.join('|') == cCaps.join('|'));
  ck('Node 设备必备字段', nFields.join('|') == cFields.join('|'));
  ck('Node 双通道', nChannels.join('|') == cChannels.join('|'));
  ck('Node 传输方式', nTransports.join('|') == cTransports.join('|'));
  ck('Node 设置类表', nSettings.join('|') == cSettings.join('|'));
  ck('Node 内容类表', nContent.join('|') == cContent.join('|'));
  for (final String fn in <String>[
    'accountScopeOf', 'normalizeDeviceRow', 'resolveConflict', 'pickChannel',
    'canSyncTable', 'tombstoneKeyOf', 'isBackendTableAllowed',
    'canonicalTableOf', 'mergeDevices', 'mergeSessions',
  ]) {
    ck('Node 导出函数 $fn', nodeSrc.contains('function $fn(') &&
        nodeSrc.contains('$fn,'));
  }
  ck('Node 常量与 Dart 常量同名（防各写一套）',
      nodeSrc.contains("const SCHEMA = 'thirdhub.unified_sync/1'") &&
      nodeSrc.contains("const VERSION = '1.0.0'"));

  print('== 4. 桌面端短名表集合与契约别名一致 ==');
  final String neonSrc = read('../server/neon.js');
  final List<String> neonTables = jsArray(neonSrc.replaceAll('new Set([', '['), 'DATA_TABLES');
  final List<String> extra =
      (c['backend_extra_tables'] as List).map((dynamic e) => '$e').toList();
  ck('neon DATA_TABLES 解析到 7 张', neonTables.length == 7);
  ck('6 张别名短名全覆盖', cAlias.values.every(neonTables.contains));
  ck('后端自用表在契约里登记', extra.isNotEmpty && extra.every(neonTables.contains));
  ck('Node 放行规则覆盖别名',
      (() {
        // 静态断言：isBackendTableAllowed 同时看别名与 extra，不是只看其一
        return nodeSrc.contains('Object.values(TABLE_ALIASES).includes(short)') &&
            nodeSrc.contains('BACKEND_EXTRA_TABLES.includes(short)');
      })());

  print('== 5. 网页端字典（--no-web 时跳过并打印） ==');
  if (noWeb || webRoot.isEmpty) {
    print('  SKIP  网页端为独立私有仓，CI 未配 TH_WEB_ROOT；本机用 --web=<根> 做全量比对');
  } else {
    final String webSrc = read('$webRoot/js/supabase.js'.replaceAll('\\', '/'));
    final List<String> wTables = jsArray(webSrc, 'SYNC_TABLES');
    final Map<String, String> wMap = jsWebMap(webSrc);
    ck('网页端 SYNC_TABLES 与契约逐字一致', wTables.join('|') == cTables.join('|'));
    ck('网页端 TBL_MAP 与契约别名逐键一致', mapKey(wMap) == mapKey(cAlias));
  }

  print('== 6. 行为：冲突裁决 / 通道 / 权限 / 墓碑 ==');
  ck('后写胜出：本机新', resolveConflict(localTs: 20, cloudTs: 10,
      localKind: 'mobile', cloudKind: 'nas',
      localDeviceId: 'a', cloudDeviceId: 'b') == 'local');
  ck('后写胜出：云端新', resolveConflict(localTs: 10, cloudTs: 20,
      localKind: 'nas', cloudKind: 'mobile',
      localDeviceId: 'a', cloudDeviceId: 'b') == 'cloud');
  ck('同秒按设备优先级（NAS 压手机）', resolveConflict(localTs: 10, cloudTs: 10,
      localKind: 'nas', cloudKind: 'mobile',
      localDeviceId: 'a', cloudDeviceId: 'z') == 'local');
  ck('同秒同优先级按 device_id 定序', resolveConflict(localTs: 10, cloudTs: 10,
      localKind: 'web', cloudKind: 'web',
      localDeviceId: 'b', cloudDeviceId: 'a') == 'local');
  ck('完全相等返回 equal（不做无谓写入）', resolveConflict(localTs: 10, cloudTs: 10,
      localKind: 'web', cloudKind: 'web',
      localDeviceId: 'a', cloudDeviceId: 'a') == 'equal');
  ck('直连优先', pickChannel(directReachable: true, cloudReachable: true) == 'device_direct');
  ck('直连不通回落官方云端', pickChannel(directReachable: false, cloudReachable: true) == 'official_cloud');
  ck('双通道都不通 = 离线排队', pickChannel(directReachable: false, cloudReachable: false) == 'offline');
  ck('墓碑键按表隔离', tombstoneKeyOf('th_bookshelf', 'x') == 'th_bookshelf:x' &&
      tombstoneKeyOf('th_history', 'x') != tombstoneKeyOf('th_bookshelf', 'x'));
  ck('墓碑键与既有 sync_contract.tombKeyOf 逐字一致',
      tombstoneKeyOf('th_bookshelf', 'a') == legacy.tombKeyOf('th_bookshelf', 'a'));

  print('== 7. 权限：设置类全登录可同步，内容类需会员/自托管 ==');
  ck('未登录一律拒绝', !canSyncTable(table: 'th_settings', loggedIn: false,
      isMember: true, selfHosted: true));
  ck('未知表拒绝', !canSyncTable(table: 'th_unknown', loggedIn: true,
      isMember: true, selfHosted: true));
  ck('登录用户能同步设置', canSyncTable(table: 'th_settings', loggedIn: true,
      isMember: false, selfHosted: false));
  ck('登录用户能同步设备表', canSyncTable(table: 'th_user_devices', loggedIn: true,
      isMember: false, selfHosted: false));
  for (final String t in kContentTables) {
    ck('免费非自托管用户不能同步 $t', !canSyncTable(table: t, loggedIn: true,
        isMember: false, selfHosted: false));
    ck('会员可同步 $t', canSyncTable(table: t, loggedIn: true,
        isMember: true, selfHosted: false));
    ck('自托管可同步 $t（与官方等级无关）', canSyncTable(table: t, loggedIn: true,
        isMember: false, selfHosted: true));
  }
  ck('与 Cloud.canSyncTable 口径一致（源码级）',
      read('lib/core/cloud.dart').contains('isMember || selfHosted'));

  print('== 8. 设备行规范化边界（恶意输入整行丢弃） ==');
  ck('空账号拒绝', normalizeDeviceRow(<String, dynamic>{'device_id': 'd1', 'kind': 'web'},
      accountId: '  ') == null);
  ck('空 device_id 拒绝', normalizeDeviceRow(<String, dynamic>{'kind': 'nas'},
      accountId: 'u1') == null);
  ck('路径穿越 id 拒绝（不洗白）',
      normalizeDeviceRow(<String, dynamic>{'device_id': '../../etc', 'kind': 'nas'},
          accountId: 'u1') == null);
  ck('非法 kind 拒绝（不回落成 mobile）',
      normalizeDeviceRow(<String, dynamic>{'device_id': 'd1', 'kind': 'toaster'},
          accountId: 'u1') == null);
  final Map<String, dynamic>? row = normalizeDeviceRow(<String, dynamic>{
    'device_id': ' D-1 ',
    'kind': ' NAS ',
    'name': '  ',
    'capabilities': <String>['direct', 'bogus', 'relay', 'direct'],
    'last_seen': '1700000000000',
  }, accountId: ' U-1 ');
  ck('合法行被规范化', row != null);
  ck('账号归一化', row?['user_id'] == 'u-1');
  ck('kind 归一化', row?['kind'] == 'nas');
  ck('空名字回落为 kind（不是空串）', row?['name'] == 'nas');
  ck('能力白名单外丢弃 + 去重',
      (row?['capabilities'] as List).join('|') == 'direct|relay');
  ck('时间戳字符串转毫秒', row?['last_seen'] == 1700000000000);
  ck('空能力补 sync',
      (normalizeDeviceRow(<String, dynamic>{'device_id': 'd2', 'kind': 'web'},
          accountId: 'u1')?['capabilities'] as List).join('|') == 'sync');

  print('== 9. 多端设备/会话合并 ==');
  final List<Map<String, dynamic>> merged = mergeDevices(<Map<String, dynamic>>[
    <String, dynamic>{'device_id': 'b', 'last_seen': 1},
    <String, dynamic>{'device_id': 'a', 'last_seen': 1},
    <String, dynamic>{'device_id': 'b', 'last_seen': 9},
    <String, dynamic>{'device_id': '', 'last_seen': 99},
  ]);
  ck('按 id 去重且按 id 排序', merged.length == 2 &&
      merged[0]['device_id'] == 'a' && merged[1]['device_id'] == 'b');
  ck('同一台保留 last_seen 最新', merged[1]['last_seen'] == 9);
  final List<Map<String, dynamic>> sessions = mergeSessions(<Map<String, dynamic>>[
    <String, dynamic>{'id': 's1', 'updated_at': 10},
    <String, dynamic>{'id': 's2', 'updated_at': 30},
    <String, dynamic>{'id': 's1', 'updated_at': 20},
  ]);
  ck('会话去重且最新在前', sessions.length == 2 &&
      sessions[0]['id'] == 's2' && sessions[1]['updated_at'] == 20);

  print('== 10. 接线（防「只写了一半」） ==');
  final String cloudSrc = read('lib/core/cloud.dart');
  ck('移动端 cloud.dart 引用统一契约',
      cloudSrc.contains("import 'device_sync_contract.dart'"));
  ck('移动端真的调用契约函数（非死代码）',
      cloudSrc.contains('dsc.canSyncTable(') &&
      cloudSrc.contains('device_sync_contract'));
  final String indexSrc = read('../server/index.js');
  ck('桌面端 index.js require 统一契约',
      indexSrc.contains("require('./device_sync_contract.js')"));
  // 服务端是数据宿主，权限模型 = 配对 token + 账号隔离（敏感源在 /v1/admin/*）。
  // 这里验的是**真实生效**的那道闸门：/v1/data/:tbl 的契约白名单。
  // 不验「恒真的 canSyncTable 分支」——那种永远走不到的 if 是假闸门。
  ck('桌面端 /v1/data 真的过契约白名单（不是只在端点里展示）',
      indexSrc.contains('syncContract.isBackendTableAllowed(tbl)') &&
      indexSrc.contains("code: 'contract_table_mismatch'"));
  ck('桌面端契约端点真的算逐表权限 + 短名反查',
      indexSrc.contains('syncContract.canSyncTable({') &&
      indexSrc.contains('syncContract.canonicalTableOf(') &&
      indexSrc.contains('/v1/sync/contract'));
  final String ci = read('../.github/workflows/dart-selfcheck.yml');
  ck('CI 真的跑这条闸门',
      ci.contains('dart run tool/device_sync_contract_selfcheck.dart'));
  ck('CI 用 --no-web（网页端独立仓，不能变成假红）',
      ci.contains('device_sync_contract_selfcheck.dart --no-web'));
  ck('CI 步骤排在 branding 之前（否则 branding 红会被 skip）',
      ci.indexOf('run: dart run tool/device_sync_contract_selfcheck.dart') <
          ci.indexOf('name: branding'));
  // 只改契约真源 / 服务端镜像时也必须触发这条闸门，否则「改了一边忘了另一边」
  // 连 CI 都不会跑，闸门等于不存在。
  ck('CI push paths 覆盖契约真源与服务端镜像',
      ci.contains("'contracts/**'") &&
      ci.contains("'server/device_sync_contract.js'") &&
      ci.contains("'server/index.js'"));

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exit(1);
}
