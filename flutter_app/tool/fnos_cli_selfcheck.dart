// 飞牛 NAS 工具闸门（fnos-cli 接入）
//
// 为什么要这条：fnos-cli 是官方 MIT 项目，我们把 NAS 的文件/照片/下载/Docker
// 能力接进 AI。这类「接外部 CLI」的东西最容易悄悄退化 —— 路径变了、工具名
// 改了、描述被删了，AI 就突然「不会管 NAS 了」，而且不会报错。
//
// 所以钉三件事：
//   ① 封装层存在且能跑（FnosCli 类、方法齐全）
//   ② 两处注册都到位（LocalTools.all + localAgentTools）
//   ③ 工具描述不夹带第三方内容源标识（合规护栏）
//
// 用法：dart --disable-dart-dev tool/fnos_cli_selfcheck.dart
// 任一 FAIL → exit(1)。

import 'dart:io';

int pass = 0;
int fail = 0;
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

void main() {
  final core = Directory.current.path.endsWith('flutter_app')
      ? '${Directory.current.path}/lib/core'
      : '${Directory.current.path}/flutter_app/lib/core';

  // ── 1. 封装层 ──
  final cli = File('$core/fnos_cli.dart');
  ok(cli.existsSync(), 'fnos_cli.dart 存在');
  if (cli.existsSync()) {
    final s = cli.readAsStringSync();
    ok(s.contains('class FnosCli'), '有 FnosCli 类');
    ok(s.contains('--tls-insecure'), '默认跳过自签证书校验（fnOS 是自签）');
    for (final m in ['systemInfo', 'listDir', 'searchFiles', 'photoFolders', 'dockerList', 'downloadList', 'mediaLibraries']) {
      ok(s.contains(m), '封装了 $m');
    }
    ok(s.contains('192.168.31.200'), '默认指向本机 NAS IP');
  }

  // ── 2. LocalTools 注册 ──
  final lt = File('$core/local_tools.dart');
  ok(lt.existsSync(), 'local_tools.dart 存在');
  if (lt.existsSync()) {
    final s = lt.readAsStringSync();
    ok(s.contains("import 'fnos_cli.dart'"), 'local_tools 引入了 fnos_cli');
    for (final t in ['nas_status', 'nas_ls', 'nas_search', 'nas_photos', 'nas_docker', 'nas_download', 'nas_media']) {
      ok(s.contains("LocalTool('$t'"), 'LocalTools 注册了 $t');
    }
  }

  // ── 3. 本机 Agent 注册 ──
  final la = File('$core/local_agent.dart');
  ok(la.existsSync(), 'local_agent.dart 存在');
  if (la.existsSync()) {
    final s = la.readAsStringSync();
    for (final t in ['nas_status', 'nas_ls', 'nas_search', 'nas_photos', 'nas_docker', 'nas_download', 'nas_media']) {
      ok(s.contains("name: '$t'"), '本机 Agent 暴露了 $t');
    }
  }

  // ── 4. 合规护栏：描述不夹带第三方内容源 ──
  const banned = <String>['copy_manga', 'baozi', '书源', '图源', '换源'];
  for (final f in [cli, lt, la]) {
    if (!f.existsSync()) continue;
    final s = f.readAsStringSync();
    for (final b in banned) {
      ok(!s.contains(b), '${f.path.split('/').last} 不含「$b」');
    }
  }

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) {
    for (final f in failures) {
      print('  · $f');
    }
    exit(1);
  }
}
