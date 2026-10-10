// 术语统一替换（红队交付物）—— 把「内容来源层」的引擎语汇改成「资料库」心智模型。
//
// ★ 为什么用脚本而不是手工改 146 处：
//   ① 同一句话在多处出现（"未连接引擎" 出现 5 次），手工改必漏；
//   ② 改法要**可复核**：脚本本身就是规则文档，下次新增文案可再跑一遍；
//   ③ 只替换**字符串字面量内部**的文本，绝不碰标识符/注释 → 不会改坏代码。
//
// 规则（仅作用于字符串字面量）：
//   引擎直连 → 资料库直连          THP 引擎 → 资料库
//   引擎 App → 资料库应用           引擎地址 → 资料库地址
//   引擎 → 资料库（保底，仅在来源语境）
//   书源/图源/影视源/音乐源 → 内容源
//   换源 → 换一来源
//
// 用法: dart run tool/rename_terms.dart [--dry]
import 'dart:io';

/// 有序规则：先长后短，避免"引擎直连"被"引擎"先吃掉。
const rules = <List<String>>[
  ['引擎直连', '资料库直连'],
  ['THP 引擎', '资料库'],
  ['引擎 App', '资料库应用'],
  ['引擎地址', '资料库地址'],
  ['引擎书源数量', '内容源数量'],
  ['引擎设备', '资料库设备'],
  ['局域网引擎', '局域网资料库'],
  ['远程引擎', '远程资料库'],
  ['第三方引擎', '第三方资料库'],
  ['发现引擎', '发现资料库'],
  ['连接引擎', '连接资料库'],
  ['引擎连接', '资料库连接'],
  ['未连接引擎', '未连接资料库'],
  ['未发现引擎', '未发现资料库'],
  ['引擎不', '资料库不'],
  ['引擎当', '资料库当'],
  ['引擎已', '资料库已'],
  ['引擎可能', '资料库可能'],
  ['引擎未', '资料库未'],
  ['引擎响应', '资料库响应'],
  ['引擎返回', '资料库返回'],
  ['引擎里', '资料库'],
  ['引擎中', '资料库'],
  ['引擎侧', '资料库侧'],
  ['引擎的', '资料库的'],
  ['个引擎', '个资料库'],
  ['引擎', '资料库'],
  // 源类
  ['引擎书源', '内容源'],
  ['书源', '内容源'],
  ['图源', '内容源'],
  ['影视源', '内容源'],
  ['音乐源', '内容源'],
  ['音源', '内容源'],
  // 换源
  ['换源', '换一来源'],
];

String stripLineComment(String line) {
  for (var i = 0; i < line.length - 1; i++) {
    if (line[i] == '/' && line[i + 1] == '/') {
      if (i >= 1 && line[i - 1] == ':') continue;
      return line.substring(0, i);
    }
  }
  return line;
}

/// 只改字符串字面量内部；返回 (新行, 改动数)。
(String, int) rewrite(String line) {
  final buf = StringBuffer();
  var i = 0;
  var changes = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == "'" || c == '"') {
      final q = c;
      final sb = StringBuffer();
      i++;
      while (i < line.length && line[i] != q) {
        if (line[i] == r'\' && i + 1 < line.length) {
          sb.write(line[i]);
          sb.write(line[i + 1]);
          i += 2;
          continue;
        }
        sb.write(line[i]);
        i++;
      }
      i++; // 收尾引号
      var body = sb.toString();
      for (final r in rules) {
        if (body.contains(r[0])) {
          body = body.replaceAll(r[0], r[1]);
          changes++;
        }
      }
      buf.write(q);
      buf.write(body);
      buf.write(q);
    } else {
      buf.write(c);
      i++;
    }
  }
  return (buf.toString(), changes);
}

/// 豁免文件：TTS 合成域与浏览器/AI 专有名词——那里的"引擎"是通用技术名词，
/// 替换是**破坏**。与 tool/branding_audit.dart 的 exemptFiles 必须一致。
const exemptFiles = <String>[
  'tts_engines_page.dart',
  'tts_engines_logic.dart',
  'tts_online.dart',
  'tts_direct.dart',
  'tts_settings_page.dart',
  'tts_vendors.dart',
  'tts_presets.dart',
  'tts.dart',
  'tts_autopair_page.dart',
  'ai.dart',
  'ai_intros.dart',
  'pro_ai.dart',
  'pro_browser.dart',
  'browser_page.dart',
  'photo_map.dart', // "图源" = 地图瓦片源，同名异物
];

void main(List<String> args) {
  final dry = args.contains('--dry');
  final files = <File>[];
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (f.path.endsWith('.dart')) files.add(f);
  }
  var totalFiles = 0;
  var totalChanges = 0;
  final skipped = <String>[];
  for (final f in files) {
    if (exemptFiles.contains(f.uri.pathSegments.last)) {
      skipped.add(f.uri.pathSegments.last);
      continue;
    }
    final src = f.readAsLinesSync();
    final out = <String>[];
    var fileChanges = 0;
    for (final line in src) {
      final (nl, c) = rewrite(line);
      fileChanges += c;
      out.add(nl);
    }
    if (fileChanges > 0) {
      totalFiles++;
      totalChanges += fileChanges;
      stdout.writeln('${f.path}  →  $fileChanges 处');
      if (!dry) f.writeAsStringSync(out.join('\n') + '\n');
    }
  }
  stdout.writeln('');
  stdout.writeln('${dry ? "[DRY-RUN] " : ""}共 $totalFiles 个文件、$totalChanges 处替换');
  if (skipped.isNotEmpty) {
    stdout.writeln('已豁免（TTS/专有名词/地图图源）：${skipped.join(", ")}');
  }
}
