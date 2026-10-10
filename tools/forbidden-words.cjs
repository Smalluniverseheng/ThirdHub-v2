#!/usr/bin/env node
/**
 * forbidden-words.cjs —— 「违规词」出货面门禁
 *
 * 为什么要有这个文件：
 *   用户明确要求：前端 / 后端 / 网页端**不得出现**容易触发版权纠纷的措辞
 *   （引擎、换源、书源、图源、音源…），统一改用「资料库 / 来源 / 内容来源」。
 *
 * ★ 这个检查曾经做不准，根因是**没有区分"出货面"与"合法用途"**：
 *     1) 注释里出现 → 不出货，但仍不该有（本脚本以 WARN 形式点名，不进失败计数）；
 *     2) i18n 字典的 **key** → 合法，它是翻译查找表（删了旧文本就翻不出来）；
 *     3) changelog / 更新日志文本 → 合法，那是**历史记录**，改了就是篡改历史；
 *     4) 旧引擎返回文本的**匹配串**（如 novel_reader 的 '未找到内容源'）→ 合法，删了就匹配不上旧引擎；
 *     5) 文件名含 "engine" 的**兼容层**（js/admin.js.bak-engine）→ 合法，是备份文件。
 *
 * ★★ 第二轮补上的三个真缺陷（都是"远端核查"抓出来的，本地假绿）：
 *   D-1  `--scope=all` **根本不含网页端**（D:/ai/deep seek）→ 网页端 7 处从未被扫过；
 *   D-2  `isCommentLine()` 只认注释**起始行**，`/* ... *\/` 块内的**续行**漏判
 *        → 4 处 JSDoc 注释里的词被误当出货面文案（反向：也说明块注释漏扫）；
 *   D-3  没有"注释块状态机"，跨行注释无法识别。
 *   修法：加 inBlockComment 状态机（`/*`…`*\/`、`<!--`…`-->`、三引号 `"""`），
 *        并新增 --web 根参数，把网页端纳入 all。
 *
 * 用法：
 *   node tools/forbidden-words.cjs <项目根>                       # 只查前端
 *   node tools/forbidden-words.cjs <项目根> --scope=all           # 前端+后端+后端管理台
 *   node tools/forbidden-words.cjs <项目根> --scope=all --web=<网页端根>
 *                                                                 # ↑ 推荐：三端一起查
 *
 * ★★ 第一件事就是写 exit(1)：本项目血泪教训「打印了 FAIL ≠ 闸门拦住了」，
 *   CI 只看退出码。下面任何一处发现问题都直接 process.exit(1)。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const WORDS = ['换源', '书源', '图源', '音源', '影视源'];
const WORD_RE = new RegExp('(' + WORDS.join('|') + ')');

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
  // 门禁自身的词表 / 白名单正则（自指豁免）
  /const WORDS\s*=/,
  /LEGAL_PATTERNS\s*=/,
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
  // 门禁自身
  'forbidden-words.cjs', '_verify_remote_branding.cjs',
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

/** 去掉行尾注释后再判（先剥 /* ... *\/ 再剥 //，够用且不误伤 URL） */
function stripComments(line) {
  let s = line.replace(/\/\*[\s\S]*?\*\//g, '');   // 同行块注释
  s = s.replace(/([^:'"`])\/\/.*$/, '$1');          // 行尾 // 注释（避开 https://）
  s = s.replace(/([^:'"`])#\s.*$/, '$1');           // 行尾 # 注释（避开 #hash / shebang 已由起始行处理）
  return s;
}

function scan(file, hits, warns) {
  let src;
  try { src = fs.readFileSync(file, 'utf8'); } catch (e) { return; }
  const lines = src.split(/\r?\n/);

  // ── 注释块状态机 ──
  let inBlock = null;   // '/*' | '<!--' | '"""' | null
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const trimmed = raw.trim();
    let effective;       // 本行"有效代码"部分；null 表示整行都在注释里

    if (inBlock) {
      effective = null;
      const close = inBlock === '/*' ? raw.indexOf('*/')
                  : inBlock === '<!--' ? raw.indexOf('-->')
                  : raw.indexOf('"""');
      if (close >= 0) {
        const tail = inBlock === '/*' ? raw.slice(close + 2)
                   : inBlock === '<!--' ? raw.slice(close + 3)
                   : raw.slice(close + 3);
        inBlock = null;
        effective = tail;                     // 注释结束后的同余代码
      }
    } else {
      effective = raw;
      // 起始行整体是注释
      if (trimmed.startsWith('//') || trimmed.startsWith('///')
        || trimmed.startsWith('#') || trimmed.startsWith('<!--')
        || trimmed.startsWith('*') && !trimmed.startsWith('*/')) {
        // JSDoc 内部行（* 开头）
        if (trimmed.startsWith('<!--')) { if (!raw.includes('-->')) inBlock = '<!--'; }
        effective = null;
      } else if (trimmed.startsWith('/*')) {
        if (!raw.includes('*/', raw.indexOf('/*') + 2)) inBlock = '/*';
        effective = null;
      } else if (/^"""/.test(trimmed)) {
        const cnt = (raw.match(/"""/g) || []).length;
        if (cnt === 1) inBlock = '"""';
        effective = null;
      }
    }

    if (!WORD_RE.test(raw)) continue;

    if (effective === null) {
      // 纯注释行：只做 WARN（不出货），但仍点名，便于逐步清零
      warns.push({ file, line: i + 1, text: trimmed.slice(0, 160) });
      continue;
    }

    const code = stripComments(effective);
    if (!WORD_RE.test(code)) {
      warns.push({ file, line: i + 1, text: trimmed.slice(0, 160) });
      continue;
    }
    // 打击面：必须是"字面量里出现"，否则只是变量名/路径，不算出货文案
    if (!/['"`][^'"`]*(换源|书源|图源|音源|影视源)/.test(code)) continue;
    if (LEGAL_PATTERNS.some((re) => re.test(code))) continue; // 合法用途
    hits.push({ file, line: i + 1, text: raw.trim().slice(0, 160) });
  }
}

// ── main ──
const argv = process.argv.slice(2);
const webArg = argv.find((a) => a.startsWith('--web='));
const root = argv.find((a) => !a.startsWith('--'));
if (!root) {
  console.error('用法: node forbidden-words.cjs <项目根> [--scope=all] [--web=<网页端根>]');
  process.exit(1);
}
const all = argv.includes('--scope=all');
if (!fs.existsSync(root)) { console.error('路径不存在: ' + root); process.exit(1); }

const targets = [];
// 前端（Flutter Dart）
targets.push({ dir: path.join(root, 'flutter_app', 'lib'), exts: ['.dart'], label: '前端 lib' });
if (all) {
  targets.push({ dir: path.join(root, 'server'), exts: ['.js', '.cjs'], label: '后端' });
  targets.push({ dir: path.join(root, 'server', 'public'), exts: ['.html', '.js'], label: '后端管理台' });
}
// ★ D-1 修复：网页端（独立仓库 D:/ai/deep seek），不在 ThirdHub-v2 里，必须显式传入
if (webArg) {
  const webRoot = webArg.slice('--web='.length);
  if (!fs.existsSync(webRoot)) {
    console.error('[forbidden-words] FAIL — --web 路径不存在: ' + webRoot);
    process.exit(1);   // ★ 传了就**必须**扫到，否则是假绿
  }
  targets.push({ dir: path.join(webRoot, 'js'), exts: ['.js'], label: '网页端 js' });
  targets.push({ dir: path.join(webRoot, 'css'), exts: ['.css'], label: '网页端 css' });
  const htmlDir = path.join(webRoot, 'html');
  if (fs.existsSync(htmlDir)) targets.push({ dir: htmlDir, exts: ['.html'], label: '网页端 html' });
  for (const f of ['index.html']) {
    const fp = path.join(webRoot, f);
    if (fs.existsSync(fp)) targets.push({ dir: fp, exts: ['.html'], label: '网页端根' });
  }
}

const hits = [];
const warns = [];
const scanned = [];
for (const t of targets) {
  if (!fs.existsSync(t.dir)) continue;
  const files = fs.statSync(t.dir).isFile() ? [t.dir] : walk(t.dir, t.exts);
  for (const f of files) scan(f, hits, warns);
  scanned.push(`${t.label}:${files.length}`);
}

console.log('[forbidden-words] 扫描目标 → ' + scanned.join('  '));

if (hits.length === 0) {
  console.log('[forbidden-words] PASS — 出货面无违规词（i18n key/changelog/旧引擎匹配串 已按规则放行）');
  if (warns.length) {
    console.log('[forbidden-words] WARN — 注释内仍残留 ' + warns.length + ' 处（不出货，建议顺手清）：');
    for (const w of warns.slice(0, 30)) {
      console.log('  ' + path.relative(root, w.file) + ':' + w.line + '  ' + w.text);
    }
    if (warns.length > 30) console.log('  … 另有 ' + (warns.length - 30) + ' 处');
  }
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
