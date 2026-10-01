'use strict';
// D-H2 emoji 扫描器（分两档：UI 面 = 阻塞；文档/自检脚本 = 仅报告）
//
// 为什么必须分档而不是「一锅端」：
//   全仓扫出来 623 处，其中只有 **50 余处**在真正的 UI 面。另外 570 处在
//     · `docs/*.md` 的状态表（✅/❌/🚧 是表格语义符号，清掉反而看不懂）
//     · `tool/*_selfcheck.dart` 往**控制台**打印的 `✅ 全部通过`
//     · `docs/**` 的架构 ASCII 图（📖🎬🎨🎵 是图的组成部分）
//   把它们一起报成"113 处待清理"，结果就是**没人敢动** —— 这正是 D-H2 长期
//   停在 `[~]` 的真实原因。分档之后，"还剩几处"变成一个明确的、会归零的数字。
//
// 用法：
//   node tools/scan-ui-emoji.cjs            # 全量报告（UI 面 + 非 UI 面分列）
//   node tools/scan-ui-emoji.cjs --ui-only  # 只报 UI 面；有命中则 exit 2
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

const EMOJI = /[\u{1F000}-\u{1FAFF}\u{1F300}-\u{1F5FF}\u{1F600}-\u{1F64F}\u{1F680}-\u{1F6FF}\u{1F900}-\u{1F9FF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{1F1E6}-\u{1F1FF}]/gu;

// 允许保留的「几何/符号」类标记：它们是刻意的视觉锚点，不是 emoji 装饰。
// ★ 见 STYLE_GUIDE.md 第 1 条的例外说明。
// 注意 ✅/❌ **不在**白名单里 —— 它们只会出现在 docs 表格与自检脚本的
// 终端打印里（属"仅报告"档），UI 面照样不该有。
const ALLOWED = new Set(['★', '☆', '✦', '✧', '✓', '✗', '●', '○', '◆', '◇', '▲', '▼', '⚡',
  '→', '←', '↑', '↓', '·', '×', '—', '…']);

/**
 * UI 面：这里出现 emoji 会**直接显示给用户**，必须为 0。
 * 其余（docs / tool / README）只做报告，不阻塞。
 */
const UI_ROOTS = ['flutter_app/lib', 'server/public', 'server/routes-admin.js',
  'server/routes-data.js', 'server/engine.js', 'server/peer-hub.js'];
// `server/index.js` 与 `server/scripts/**` 的输出去**终端**，不是界面，故归此档
const TEXT_ROOTS = ['flutter_app/tool', 'docs', 'README.md', 'server/scripts', 'server/index.js'];

const SKIP_DIR = new Set(['node_modules', 'node_modules.msh-partial', '.git', 'build',
  '.dart_tool', 'vendor', 'assets', 'ios', 'web', 'android', 'windows', 'linux', 'macos']);
const EXT = new Set(['.dart', '.html', '.js', '.cjs', '.mjs', '.md']);

function walk(p, out) {
  const st = fs.statSync(p);
  if (!st.isDirectory()) { out.push(p); return out; }
  for (const e of fs.readdirSync(p, { withFileTypes: true })) {
    if (e.name.startsWith('.')) continue;
    if (e.isDirectory()) { if (!SKIP_DIR.has(e.name)) walk(path.join(p, e.name), out); }
    else out.push(path.join(p, e.name));
  }
  return out;
}

// 行内注释区间（Dart/JS: // 与 /* */）——注释里的 emoji 一律放行，
// 因为那些是作者写给自己看的标记，不会渲染到界面上。
function commentSpans(line) {
  const s = [];
  let i = 0;
  while (true) {
    const a = line.indexOf('/*', i); if (a < 0) break;
    const b = line.indexOf('*/', a + 2);
    if (b < 0) { s.push([a, line.length]); break; }
    s.push([a, b + 2]); i = b + 2;
  }
  const lc = line.indexOf('//');
  if (lc >= 0) s.push([lc, line.length]);
  return s;
}
const inSpan = (i, sp) => sp.some(([a, b]) => i >= a && i < b);

function scan(roots) {
  const files = [];
  for (const r of roots) {
    const p = path.join(ROOT, r);
    if (fs.existsSync(p)) walk(p, files);
  }
  const report = {};
  let total = 0;
  for (const f of files) {
    if (!EXT.has(path.extname(f))) continue;
    const rel = path.relative(ROOT, f).replace(/\\/g, '/');
    const lines = fs.readFileSync(f, 'utf8').split(/\r?\n/);
    const hits = [];
    lines.forEach((line, li) => {
      const sp = commentSpans(line);
      let m; EMOJI.lastIndex = 0;
      while ((m = EMOJI.exec(line)) !== null) {
        if (ALLOWED.has(m[0])) continue;
        if (inSpan(m.index, sp)) continue;
        hits.push({ line: li + 1, col: m.index + 1, ch: m[0], text: line.trim().slice(0, 110) });
      }
    });
    if (hits.length) { report[rel] = hits; total += hits.length; }
  }
  return { report, total };
}

function dump(title, { report, total }) {
  console.log('\n──────── ' + title + ' ────────');
  for (const [rel, hits] of Object.entries(report)) {
    console.log('\n' + rel + '  (' + hits.length + ')');
    for (const h of hits) console.log('   ' + h.line + ':' + h.col + '  ' + h.ch + '  |  ' + h.text);
  }
  console.log('\n' + title + ' 合计 = ' + total);
  return total;
}

const ui = scan(UI_ROOTS);
const text = scan(TEXT_ROOTS);

if (process.argv.includes('--ui-only')) {
  const t = dump('UI 面（阻塞）', ui);
  if (t > 0) { console.error('\n✗ UI 面仍有 ' + t + ' 处 emoji —— 见 STYLE_GUIDE.md 第 1 条'); process.exit(2); }
  console.log('\n✓ UI 面 emoji = 0');
  process.exit(0);
}

const a = dump('UI 面（阻塞：必须为 0）', ui);
const b = dump('文档 / 自检脚本（仅报告：✅❌ 是表格与终端语义，不清理）', text);
console.log('\n════ 汇总：UI ' + a + ' 处（阻塞） · 文面 ' + b + ' 处（不阻塞） ════');
process.exit(a > 0 ? 2 : 0);
