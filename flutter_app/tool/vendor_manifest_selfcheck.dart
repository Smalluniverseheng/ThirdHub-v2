// 开源移植台账闸门（vendor/MANIFEST.json ↔ 实物）
//
// 为什么需要它：用户明确要求「优先搬现成开源项目，不重复造车轮」。但「说搬了」
// 和「真的搬了」之间差三件事，全靠这条闸门盯：
//   ① 台账里登记的文件必须真的存在；
//   ② 文件头部必须写明上游 repo@commit 与许可证（防「说是搬的、其实是自己写的」）；
//   ③ 名录里被判「不可搬」的项目（如 Namida 的 EULA）不得出现在已搬清单里。
//
// 上游原始镜像 vendor/_upstream 只在本地存在、不随 CI 携带，所以「上游文件在不在」
// 这一层缺失时打印 SKIP 并计数，不伪装成通过；本仓内的断言一条都不少。
//
// 用法：dart --disable-dart-dev tool/vendor_manifest_selfcheck.dart
// 有任何 FAIL → exit(1)。

import 'dart:convert';
import 'dart:io';

int pass = 0;
int fail = 0;
int skip = 0;
final List<String> failures = <String>[];

void ok(bool cond, String what) {
  if (cond) {
    pass++;
  } else {
    fail++;
    failures.add(what);
    print('FAIL $what');
  }
}

void skipped(String what) {
  skip++;
  print('SKIP $what');
}

/// 移动端不得出现的第三方内容源标识（与 public_sources 自检同一套黑名单语义）
const List<String> kMobileBannedTerms = <String>[
  'copy_manga',
  'baozi',
  'jmcomic',
  '禁漫',
  '书源',
  '图源',
];

void main() {
  final manifestFile = File('../vendor/MANIFEST.json');
  ok(manifestFile.existsSync(), '台账文件 vendor/MANIFEST.json 存在');
  if (!manifestFile.existsSync()) {
    print('\n$pass 通过 / $fail 失败 / $skip 跳过');
    exit(1);
  }

  final Map<String, dynamic> m =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  ok(m['schema'] == 'thirdhub.vendor_manifest/1', '台账 schema 版本正确');

  final Map<String, dynamic> upstreams =
      (m['upstreams'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
  final List<dynamic> ported = (m['ported'] as List?) ?? <dynamic>[];
  final List<dynamic> blocked = (m['blocked'] as List?) ?? <dynamic>[];

  ok(upstreams.isNotEmpty, '至少登记一个上游项目');
  ok(ported.isNotEmpty, '至少登记一个已搬文件');

  // ── 上游：必须有 repo / license，且许可证分层可判定 ──
  for (final e in upstreams.entries) {
    final v = e.value as Map<String, dynamic>;
    ok((v['repo'] as String?)?.contains('/') == true, '上游 ${e.key} 有 repo');
    final lic = (v['license'] as String?) ?? '';
    ok(lic.isNotEmpty, '上游 ${e.key} 标了许可证');
    final lc = lic.toLowerCase();
    final isProprietary = lc.contains('eula') || lc.contains('noassertion') ||
        lc.contains('未声明');
    if (isProprietary) {
      final b = blocked.any((x) =>
          (x as Map)['upstream'] == e.key);
      ok(b, '上游 ${e.key} 是专有/EULA 许可，必须进 blocked 名单');
    }
  }

  // ── 已搬：文件存在 + 头部有出处 + 不含第三方站点 ──
  for (final raw in ported) {
    final p = raw as Map<String, dynamic>;
    final id = (p['id'] as String?) ?? '(无 id)';
    final localRel = (p['local'] as String?) ?? '';
    final upstreamKey = (p['upstream'] as String?) ?? '';
    final f = File('../$localRel');
    ok(f.existsSync(), 'ported[$id] 本地文件存在: $localRel');
    if (!f.existsSync()) continue;

    final head = f.readAsLinesSync().take(14).join('\n');
    ok(head.contains('上游:'), 'ported[$id] 头部有「上游:」出处行');
    ok(head.contains('许可证:'), 'ported[$id] 头部有「许可证:」');
    final repo = ((upstreams[upstreamKey] as Map?)?['repo'] as String?) ?? '';
    ok(repo.isNotEmpty && head.contains(repo),
        'ported[$id] 头部出处与上游 $upstreamKey 的 repo 一致');

    // 上游实物核对（本地镜像存在才查）
    final mirror = Directory('../vendor/_upstream/$upstreamKey');
    final upPath = p['upstream_path'] as String?;
    if (!mirror.existsSync()) {
      skipped('vendor/_upstream/$upstreamKey 未随仓库携带，跳过上游实物核对');
    } else if (upPath != null) {
      ok(File('../vendor/_upstream/$upstreamKey/$upPath').existsSync(),
          'ported[$id] 上游源文件确实存在: $upPath');
    }

    final body = f.readAsStringSync();
    for (final t in kMobileBannedTerms) {
      ok(!body.contains(t), 'ported[$id] 不含第三方内容源标识「$t」');
    }

    // 「搬了但没接上」= 摆设。声明了 wired_in 的，接线文件必须真的引用它。
    final wired = (p['wired_in'] as List?) ?? const <dynamic>[];
    for (final wRaw in wired) {
      final wRel = '$wRaw';
      final wf = File('../$wRel');
      ok(wf.existsSync(), 'ported[$id] 接线文件存在: $wRel');
      if (!wf.existsSync()) continue;
      final wBody = wf.readAsStringSync();
      final base = localRel.split('/').last;
      ok(wBody.contains(base), 'ported[$id] 接线文件确实引用了 $base');
    }
  }

  // 至少有一个 Apache-2.0 上游真的落了文件（防「台账写得漂亮、仓库里没有」）
  final mangayomiPorted = ported.any((x) => (x as Map)['upstream'] == 'mangayomi');
  ok(mangayomiPorted, 'mangayomi（Apache-2.0）至少有一个已搬文件');

  // ── 被判不可搬的项目，不得出现在已搬清单 ──
  for (final raw in blocked) {
    final b = raw as Map<String, dynamic>;
    final key = b['upstream'] as String?;
    final used = ported.any((x) => (x as Map)['upstream'] == key);
    ok(!used, 'blocked[$key] 没有出现在 ported 里（许可证不允许搬）');
  }

  print('\n$pass 通过 / $fail 失败 / $skip 跳过');
  if (fail > 0) {
    print('台账与实物不一致，已拦下。');
    exit(1);
  }
}
