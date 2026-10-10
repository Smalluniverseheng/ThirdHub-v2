// 模块清单（module.json）一致性自检（纯 Dart VM 可跑）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/module_manifest_selfcheck.dart
//
// 阶段3 的收口闸门。清单唯一来源：仓库根 `design/modules/<id>.module.json`
// （每模块一份：id/name/icon/version/deps/entry）。本自检把四面钉在一起：
//   ① core/module_registry.dart 的 REGISTRY（canonical id 表）⇄ 清单集合/名称；
//   ② 清单 entry.app ⇄ main.dart kModules 键；entry.web ⇄ BOARDS 板块；
//   ③ 清单 ⇄ 网页端 js/module-market.js 聚合（id/名称/版本 逐项一致）；
//   ④ App 懒构造接线（ModuleDef.page 是懒 getter，kModules 存闭包）。
//
// ★ 网页端文件找不到 → 硬失败（exit 1）并打印找过的路径（不许假绿）。
//   本地只想跑单端时显式传 `--no-web`（CI 绝不传）。
import 'dart:convert';
import 'dart:io';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

List<String> webCandidates(String rel) {
  final List<String> out = <String>[];
  final String? env = Platform.environment['TH_WEB_ROOT'];
  if (env != null && env.trim().isNotEmpty) {
    out.add('${env.replaceAll(r'\', '/')}/$rel');
  }
  out.add('D:/ai/deep seek/$rel');
  final String? ws = Platform.environment['GITHUB_WORKSPACE'];
  if (ws != null && ws.trim().isNotEmpty) {
    out.add('${ws.replaceAll(r'\', '/')}/_web/$rel');
  }
  out.add('../deep seek/$rel');
  return out;
}

List<String> repoCandidates(String rel) {
  final String scriptDir =
      File(Platform.script.toFilePath()).parent.path.replaceAll(r'\', '/');
  return <String>['$scriptDir/../../$rel', '../$rel', '$rel'];
}

String? findFirst(List<String> candidates) {
  for (final String p in candidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

String mustRead(List<String> candidates, String what) {
  final String? p = findFirst(candidates);
  if (p == null) {
    print('FAIL 找不到$what，找过的路径：');
    for (final String c in candidates) {
      print('  - $c');
    }
    exit(1);
  }
  print('  读取 $what ← $p');
  return File(p).readAsStringSync();
}

String mustDir(List<String> candidates, String what) {
  for (final String p in candidates) {
    if (Directory(p).existsSync()) {
      print('  读取 $what ← $p');
      return p;
    }
  }
  print('FAIL 找不到$what，找过的路径：');
  for (final String c in candidates) {
    print('  - $c');
  }
  exit(1);
}

class RegRow {
  RegRow(this.id, this.name, this.appKeys, this.webBoard);
  final String id, name;
  final List<String> appKeys;
  final String? webBoard;
}

void main(List<String> args) {
  final bool noWeb = args.contains('--no-web');

  print('== 0. 读取定义 ==');
  final String regSrc = mustRead(
      repoCandidates('flutter_app/lib/core/module_registry.dart'),
      'module_registry.dart');
  final String mainSrc =
      mustRead(repoCandidates('flutter_app/lib/main.dart'), 'main.dart');
  final String dir = mustDir(repoCandidates('design/modules'), 'design/modules/');

  // ── 注册表 ──
  final List<RegRow> rows = <RegRow>[];
  for (final RegExpMatch m in RegExp(
          r"ModuleRegEntry\('([^']+)', '([^']+)', \[([^\]]*)\], (null|'[^']+')\)")
      .allMatches(regSrc)) {
    rows.add(RegRow(
      m.group(1)!,
      m.group(2)!,
      <String>[
        for (final RegExpMatch k in RegExp(r"'([^']+)'").allMatches(m.group(3)!))
          k.group(1)!,
      ],
      m.group(4) == 'null' ? null : m.group(4)!.replaceAll("'", ''),
    ));
  }

  // ── kModules 键 ──
  final int start = mainSrc.indexOf('final Map<String, ModuleDef> kModules = {');
  final int end = mainSrc.indexOf('\n};', start);
  final String region =
      (start >= 0 && end > start) ? mainSrc.substring(start, end) : '';
  final Set<String> kModuleKeys = <String>{
    for (final RegExpMatch m
        in RegExp(r"'([^']+)':\s*(?:const\s+)?ModuleDef\(").allMatches(region))
      m.group(1)!,
  };

  // ── 75 份清单 ──
  final Map<String, Map<String, dynamic>> manifests = {};
  final List<FileSystemEntity> files = Directory(dir).listSync();
  for (final FileSystemEntity f in files) {
    final String name = f.uri.pathSegments.last;
    if (!name.endsWith('.module.json')) continue;
    final Map<String, dynamic> m =
        jsonDecode(File(f.path).readAsStringSync()) as Map<String, dynamic>;
    manifests[m['id'] as String] = m;
  }

  print('== 1. 清单集合 ⇄ 注册表 ==');
  ck('注册表行数 = 75', rows.length == 75);
  ck('注册表 id 无重复',
      rows.map((r) => r.id).toSet().length == rows.length);
  ck('清单份数 = 注册表行数（每模块一份，不多不少）',
      manifests.length == rows.length);
  final Set<String> regIds = rows.map((r) => r.id).toSet();
  ck('清单 id 集合 = 注册表 id 集合',
      manifests.keys.toSet().difference(regIds).isEmpty &&
          regIds.difference(manifests.keys.toSet()).isEmpty);
  for (final RegRow r in rows) {
    final Map<String, dynamic>? m = manifests[r.id];
    if (m == null) {
      ck('缺清单 ${r.id}', false);
      continue;
    }
    ck('[${r.id}] name 一致（${r.name}）', m['name'] == r.name);
    ck('[${r.id}] 六字段齐全',
        ['id', 'name', 'icon', 'version', 'deps', 'entry']
            .every((k) => m.containsKey(k)));
    ck('[${r.id}] version 语义化（x.y.z）',
        RegExp(r'^\d+\.\d+\.\d+$').hasMatch('${m['version']}'));
    final List<dynamic> deps = m['deps'] as List<dynamic>;
    ck('[${r.id}] deps 引用合法（都在注册表 id 内）',
        deps.every((d) => regIds.contains(d)));
    final Map<String, dynamic> entry = m['entry'] as Map<String, dynamic>;
    final List<dynamic> app = entry['app'] as List<dynamic>;
    ck('[${r.id}] entry.app = 注册表 appKeys',
        app.join(',') == r.appKeys.join(','));
    ck('[${r.id}] entry.app 键都在 kModules 里',
        app.every((k) => kModuleKeys.contains(k)));
    ck('[${r.id}] entry.web = 注册表 webBoard',
        entry['web'] == r.webBoard);
    final bool hasWeb = r.webBoard != null;
    ck('[${r.id}] webLoad ${hasWeb ? "非空" : "为空"}与 webBoard 一致',
        (entry['webLoad'] != null) == hasWeb);
    ck('[${r.id}] webLoad 路径形态正确',
        !hasWeb || '${entry['webLoad']}'.startsWith('./modules/'));
  }

  // ── 注册表 appKeys 与 kModules 的互相覆盖 ──
  print('== 2. 注册表 ⇄ kModules ==');
  final Set<String> regKeys = <String>{
    for (final RegRow r in rows) ...r.appKeys,
  };
  ck('注册表 appKeys 全部存在于 kModules',
      regKeys.difference(kModuleKeys).isEmpty);
  ck('kModules 键全部在注册表有归属（唯一收口不漏）',
      kModuleKeys.difference(regKeys).isEmpty);

  // ── 懒构造接线 ──
  print('== 3. App 懒构造接线 ==');
  ck('ModuleDef.page 是懒 getter（首次进入才构造）',
      mainSrc.contains('Widget get page => _cached ??= _build();'));
  ck('ModuleDef 不再持有现成 Widget 字段（存闭包）',
      !RegExp(r'final Widget page;').hasMatch(mainSrc) &&
          mainSrc.contains('final Widget Function() _build;'));

  // ── 网页端聚合清单 ──
  if (!noWeb) {
    print('== 4. 网页端 js/module-market.js ==');
    final String webSrc =
        mustRead(webCandidates('js/module-market.js'), 'js/module-market.js');
    final RegExp arrRe =
        RegExp(r'export const MODULE_MANIFESTS = (\[[\s\S]*?\]);');
    final String? arr = arrRe.firstMatch(webSrc)?.group(1);
    ck('MODULE_MANIFESTS 可解析', arr != null);
    if (arr != null) {
      final List<dynamic> web =
          jsonDecode(arr) as List<dynamic>;
      ck('网页聚合条数 = 清单份数（${manifests.length}）',
          web.length == manifests.length);
      final Map<String, dynamic> byId = <String, dynamic>{
        for (final dynamic w in web) (w as Map<String, dynamic>)['id']: w,
      };
      bool mismatch = false;
      for (final MapEntry<String, Map<String, dynamic>> e in manifests.entries) {
        final dynamic w = byId[e.key];
        if (w == null ||
            w['name'] != e.value['name'] ||
            '${w['version']}' != '${e.value['version']}') {
          mismatch = true;
          print('    不一致: ${e.key}');
        }
      }
      ck('id/名称/版本 逐项一致（清单 ⇄ 网页聚合）', !mismatch);
      ck('newerVersion() 存在（热更新比较入口）',
          webSrc.contains('export function newerVersion'));
    }
  }

  print('模块清单一致性：$pass 通过 / $fail 失败');
  exit(fail > 0 ? 1 : 0);
}
