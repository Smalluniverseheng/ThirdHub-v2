#!/usr/bin/env node
/**
 * forbidden-words.cjs —— 「违规词」出货面门禁
 *
 * 为什么要有这个文件：
 *   用户明确要求：前端 / 后端 / 网页端**不得出现**容易触发版权纠纷的措辞
 *   （引擎、换源、书源、图源、音源…），统一改用「资料库 / 来源 / 内容来源」。
 *
 *   ★ 但这个检查一直做不准，根因是**没有区分"出货面"与"合法用途"**：
 *     1) 注释里出现 → 无害（但也不该有，逐步清）；
 *     2) i18n 字典的 **key** → 合法，它是翻译查找表（删了旧文本就翻不出来）；
 *     3) changelog / 更新日志文本 → 合法，那是**历史记录**，改了就是篡改历史；
 *     4) 旧引擎返回文本的**匹配串**（如 novel_reader 的 '未找到内容源'）→ 合法，删了就匹配不上旧引擎；
 *     5) 文件名含 "engine" 的**兼容层**（js/admin.js.bak-engine）→ 合法，是备份文件。
 *
 *   所以本脚本只拦 **①字面量里出现 ②且不在上述合法白名单里** 的用例。
 *   —— 这正是用户问「你确定前端都没有违禁词了吧」时要的那个判据。
 *
 * 用法：
 *   node tools/forbidden-words.cjs <项目根>            # 默认查前端
 *   node tools/forbidden-words.cjs <项目根> --scope=all # 前端+后端+网页端
 *
 * ★★ 第一件事就是写 exit(1)：本项目血泪教训「打印了 FAIL ≠ 闸门拦住了」，
 *   CI 只看退出码。下面任何一处发现问题都直接 process.exit(1)。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const WORDS = ['换源', '书源', '图源', '音源', '影视源'];

/** 合法用途：命中任一即跳过（说明见文件头） */
const LEGAL_PATTERNS = [
  // i18n 翻译查找表：形如  '书源': 'Sources de livres',
  /['"][^'"]*(换源|书源|图源|音源|影视源)['"]\s*:\s*['"`]/,
  // changelog 归类同义词表：  '搜索': <String>['搜源', '资料库', '内容源', ...],
  /<String>\s*\[/,
  // 归类映射里的裸数组项（changelog_logic 的词表）
  /^\s*['"][^'"]*(换源|书源|图源|音源|影视源)['"]\s*,?\s*$/,
  // 旧引擎/旧版本返回文本的匹配串
  /\.contains\(/,
  /indexOf\(/,
  /includes\(/,
  // 后端控制台自检项（只打印给运行者看，不经 API 出货）
  /checks\.push\(/,
  // 依赖说明（index.js 的 require 检查表，纯描述性）
  /\['cheerio',/,
];

/** 需要跳过的路径片段 */
const SKIP_PATH = [
  'node_modules', '.dart_tool', 'build/', 'build\\',
  '.bak', 'changelog.js', 'changelog.json', 'changelog-full.json',
  'CHANGELOG', 'changelog.md', 'CHANGELOG.md',
  '.g.dart', '.freezed.dart',
  // 导入脚本 / 测试：不是出货面
  //   · scripts/import-*.js、import-instance-sources.cjs —— 运维脚本，只打 console.log
  //     （给"正在导源的人"看），不经任何 API 出货；
  //   · test_*.cjs —— **断言里的违规词表**，那是"检测工具"本身，删了工具就废了。
  'scripts\\import-', 'scripts/import-', 'import-instance-sources.cjs',
  'test_branding.cjs', 'test_engine_plugin.cjs',
];

function walk(dir, exts, out = []) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return out; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (SKIP_PATH.some((s) => p.includes(s))) continue;
    if (e.isDirectory()) { walk(p, exts, out); continue; }
    if (!exts.some((x) => e.name.endsWith(x))) continue;
    out.push(p);
  }
  return out;
}

function isCommentLine(line) {
  const t = line.trim();
  return t.startsWith('//') || t.startsWith('///') || t.startsWith('*')
    || t.startsWith('/*') || t.startsWith('#') || t.startsWith('<!--');
}

/** 去掉行尾注释后再判（只处理 // 形式，够用且不误伤 URL） */
function stripTrailingComment(line) {
  return line.replace(/([^:'"`])\/\/.*$/, '$1');
}

function scan(file, hits) {
  let src;
  try { src = fs.readFileSync(file, 'utf8'); } catch (e) { return; }
  const lines = src.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    if (!WORDS.some((w) => raw.includes(w))) continue;
    if (isCommentLine(raw)) continue;                       // 注释：放行（另有清理计划）
    const code = stripTrailingComment(raw);
    if (!WORDS.some((w) => code.includes(w))) continue;      // 只剩注释 → 放行
    // 打击面：必须是"字面量里出现"，否则只是变量名/路径，不算出货文案
    if (!/['"`][^'"`]*(换源|书源|图源|音源|影视源)/.test(code)) continue;
    if (LEGAL_PATTERNS.some((re) => re.test(code))) continue; // 合法用途
    hits.push({ file, line: i + 1, text: raw.trim().slice(0, 160) });
  }
}

// ── main ──
const root = process.argv[2];
if (!root) { console.error('用法: node forbidden-words.cjs <项目根> [--scope=all]'); process.exit(1); }
const all = process.argv.includes('--scope=all');
if (!fs.existsSync(root)) { console.error('路径不存在: ' + root); process.exit(1); }

const targets = [];
// 前端（Flutter Dart）
targets.push({ dir: path.join(root, 'flutter_app', 'lib'), exts: ['.dart'], label: '前端 lib' });
if (all) {
  targets.push({ dir: path.join(root, 'server'), exts: ['.js', '.cjs'], label: '后端' });
  targets.push({ dir: path.join(root, 'server', 'public'), exts: ['.html', '.js'], label: '后端管理台' });
}

const hits = [];
for (const t of targets) {
  if (!fs.existsSync(t.dir)) continue;
  for (const f of walk(t.dir, t.exts)) scan(f, hits);
}

if (hits.length === 0) {
  console.log('[forbidden-words] PASS — 出货面无违规词（注释/i18n key/changelog 已按规则放行）');
  process.exit(0);
}

console.error('[forbidden-words] FAIL — 发现 ' + hits.length + ' 处出货面违规词：\n');
for (const h of hits) {
  console.error('  ' + path.relative(root, h.file) + ':' + h.line);
  console.error('      ' + h.text);
}
console.error('\n改法：改用「资料库 / 来源 / 内容来源 / 已接入来源」。');
console.error('若判定为合法用途（i18n key / changelog / 旧引擎匹配串），请扩充 LEGAL_PATTERNS 并写明理由。');
process.exit(1);
