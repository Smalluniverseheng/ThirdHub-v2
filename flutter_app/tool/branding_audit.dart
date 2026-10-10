// 品牌用词审计（红队交付物）—— 只报「内容来源类」违规，不误伤通用技术名词。
//
// ★ 为什么必须分类：`引擎` 这个词在项目里同时指三件完全不同的事：
//   ① 内容来源层（"引擎直连"、"未连接引擎"、"书源"）—— 用户明令禁止，必须清掉；
//   ② TTS 语音合成服务（"开源 TTS 引擎"）—— 通用技术名词，业界通称，改掉反而看不懂；
//   ③ 浏览器/AI 的通用词（"搜索引擎"、"火山引擎"）—— 专有名词，不能改。
//   把 ②③ 一起改是**破坏**。所以审计只针对 ①，且逐条列出供人复核。
//
// 判定：先去掉 `//` 行尾注释（`://` 视为 URL 不算），再取字符串字面量，
//       命中「内容来源类」词表才算违规。
// 用法: dart run tool/branding_audit.dart [--all]
//   --all 额外打印被豁免的（TTS/浏览器/专有名词）行，便于人工复核豁免是否合理。
import 'dart:io';

/// 内容来源类违规词（用户明令禁止出现在前后端与网页端）。
const banned = <String>['引擎', '换源', '书源', '图源', '影视源', '音乐源'];

/// 豁免规则：字面量里含这些子串 → 属于通用技术名词或专有名词，不算违规。
const exempt = <String>[
  '搜索引擎', '搜索聚合引擎', '火山引擎', // 浏览器/AI 专有
  'TTS', 'tts', '语音', '朗读', '合成', 'piper', 'sherpa', 'cosyvoice', 'CosyVoice',
  'Fish-Speech', 'fish-speech', 'coqui', 'qwen3-tts', '网关', '音色',
  '摘要引擎', '翻译引擎', // LLM 提示词里的角色描述
  'aria2', '下载引擎',
  '源引擎', // job_center 里描述"源引擎内部数据"的开发文档用语（非终端用户可见）
  '图源', // ★ 注意：photo_map 里的"图源"指**地图瓦片源**，与漫画图源同名异物，必须豁免
];

/// 豁免文件：整份文件属于 TTS 语音合成域（那里的"引擎"是通用技术名词）。
const exemptFiles = <String>[
  'tts_engines_page.dart',
  'tts_engines_logic.dart',
  'tts_online.dart',
  'tts_direct.dart',
  'tts_settings_page.dart',
  'tts_vendors.dart',
  'tts_presets.dart',
  'tts.dart',
  'ai.dart', // WebSearchService 的"搜索引擎"描述
  'ai_intros.dart', // "火山引擎"
  'pro_ai.dart', // "摘要引擎" 提示词
  'pro_browser.dart', // "翻译引擎" 提示词
  'browser_page.dart', // "搜索引擎"/"切换搜索引擎"
];

String stripLineComment(String line) {
  for (var i = 0; i < line.length - 1; i++) {
    if (line[i] == '/' && line[i + 1] == '/') {
      if (i >= 1 && line[i - 1] == ':') continue; // http://
      return line.substring(0, i);
    }
  }
  return line;
}

List<String> literals(String line) {
  final out = <String>[];
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == "'" || c == '"') {
      final q = c;
      final sb = StringBuffer();
      i++;
      while (i < line.length && line[i] != q) {
        if (line[i] == r'\' && i + 1 < line.length) {
          sb.write(line[i + 1]);
          i += 2;
          continue;
        }
        sb.write(line[i]);
        i++;
      }
      i++;
      out.add(sb.toString());
    } else {
      i++;
    }
  }
  return out;
}

bool isExempt(String lit) => exempt.any(lit.contains);

/// i18n 字典文件：**键**是内部查找用的中文原文（不是显示内容），
/// 只有 **value**（各语言的译文）才面向用户。对这类文件只检查 value。
const i18nDictFiles = <String>['i18n.dart', 'i18n_extra.dart'];

/// 从一行里取出「值」：字面量成对出现（键, 值, 键, 值 …），值在奇数下标。
/// 若该行字面量个数为奇数（结构异常），则保守地全部返回。
List<String> i18nValueLiterals(String line) {
  final lits = literals(line);
  if (lits.length.isOdd) return lits;
  return [for (var i = 1; i < lits.length; i += 2) lits[i]];
}

void main(List<String> args) {
  final showAll = args.contains('--all');
  final dir = Directory('lib');
  if (!dir.existsSync()) {
    stderr.writeln('lib/ 不存在');
    exit(1);
  }
  final hits = <String>[];
  final skipped = <String>[];
  var scanned = 0;
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    scanned++;
    final fileName = f.uri.pathSegments.last;
    final fileExempt = exemptFiles.contains(fileName);
    final isDict = i18nDictFiles.contains(fileName);
    final lines = f.readAsLinesSync();
    for (var n = 0; n < lines.length; n++) {
      final code = stripLineComment(lines[n]);
      if (code.trim().isEmpty) continue;
      final lits = isDict ? i18nValueLiterals(code) : literals(code);
      for (final lit in lits) {
        if (lit.isEmpty) continue;
        final hitWord = banned.firstWhere((w) => lit.contains(w), orElse: () => '');
        if (hitWord.isEmpty) continue;
        final rec = '${f.path}:${n + 1}  [$hitWord]  "$lit"';
        if (fileExempt || isExempt(lit)) {
          skipped.add(rec);
        } else {
          hits.add(rec);
        }
      }
    }
  }
  stdout.writeln('扫描 .dart 文件 $scanned 个');
  stdout.writeln('');
  stdout.writeln('★ 内容来源类违规 ${hits.length} 处（必须修正）：');
  for (final h in hits) {
    stdout.writeln('  $h');
  }
  if (showAll) {
    stdout.writeln('');
    stdout.writeln('○ 已豁免 ${skipped.length} 处（通用技术名词/专有名词，请人工复核）：');
    for (final s in skipped) {
      stdout.writeln('  $s');
    }
  }
  if (hits.isNotEmpty) exit(1);
  stdout.writeln('');
  stdout.writeln('PASS：无内容来源类违规用词');
}
