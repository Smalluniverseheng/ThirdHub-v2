/**
 * emoji_selfcheck.cjs —— 出货面 emoji 闸门
 *
 * ★ 已知的坑（本文件就是为防它们而写）：
 *   1) 只扫「字符串字面量」，不扫注释 —— 注释里的 ✓ / ★ / → 是工程标记，
 *      不是给用户看的 emoji。R17 教训：闸门一旦产生噪音就没人看了。
 *   2) 不扫第三方 vendored 代码（gh-src/）与生成物（source-audit.html）——
 *      源名里的 emoji 是数据不是设计，硬管会造成大量误报。
 *   3) 按 Unicode 码点判定，不用正则范围 —— `[\u{1F300}-\u{1FAFF}]` 会在
 *      某些 JS 引擎里抛 Range out of order（本项目踩过）。
 *
 * 用法： node emoji_selfcheck.cjs [--web=<网页端根>]
 *   不传 --web 时只扫 flutter_app。
 */
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const WEB = (args.find((x) => x.startsWith('--web=')) || '').slice(6) || '';
const ROOT = path.resolve(__dirname, '..');

let pass = 0, fails = 0, warns = 0;
const ok = (m) => { pass++; console.log('  OK   ' + m); };
const bad = (m) => { fails++; console.error('  FAIL ' + m); };
const warn = (m) => { warns++; console.log('  WARN ' + m); };

/**
 * ★★ 2026-10-10 加固：把「装饰 emoji」与「功能性字形」分开，否则闸门会
 * 一边报 FAIL 一边没人改（噪音 → 假绿）。
 *
 *   装饰 emoji（必须清）   ：🎉 表示庆祝、📰 表示新闻栏目……纯粹为了好看
 *   功能性字形（豁免）      ：★ → ↑ ☆ ↩ ⬇ ☰ ⚠ ✓ ✗ —— 承担**工程/交互语义**
 *                            （排序标记、按钮图标、方向、警告前缀），
 *                            和 STYLE_GUIDE 放行 → 是同一个道理。
 *
 *   另有「历史归档豁免」：changelog.js / CHANGELOG 类文件是**只增不改**的
 *   历史记录，改它等于篡改发布史 —— 按项目铁律「历史条目只增不改」豁免。
 */
const FUNC_GLYPHS = new Set([
  ...'★☆✦→←↑↓↩⇧⇩⬇⬆☰≡⚠⚡⌘⌥⇥⏎·•',
]);
const isFuncGlyph = (cp) =>
  FUNC_GLYPHS.has(String.fromCodePoint(cp)) ||
  (cp >= 0x2190 && cp <= 0x21ff) ||   // 箭头
  (cp >= 0x2300 && cp <= 0x23ff) ||   // 技术符号 ⌘⌥⏎
  (cp >= 0x25a0 && cp <= 0x25ff) ||   // 几何图形
  (cp >= 0x2b00 && cp <= 0x2bff);     // 补充箭头/星

/** 历史归档文件：只增不改，豁免扫描 */
const isArchiveFile = (p) => /(^|[\\/])changelog(\.min)?\.js$/i.test(p);

/** 装饰性 emoji 判定（与 emoji_scan.cjs 同口径，两处必须一致） */
function isEmoji(cp) {
  // 先排除功能性字形 —— 它们不是「低级表情」
  if (isFuncGlyph(cp)) return false;
  if (cp >= 0x1f300 && cp <= 0x1f5ff) return true;
  if (cp >= 0x1f600 && cp <= 0x1f64f) return true;
  if (cp >= 0x1f680 && cp <= 0x1f6ff) return true;
  if (cp >= 0x1f900 && cp <= 0x1f9ff) return true;
  if (cp >= 0x1fa70 && cp <= 0x1faff) return true;
  if (cp >= 0x1f1e6 && cp <= 0x1f1ff) return true;
  if (cp === 0xfe0f || cp === 0x200d) return true;
  if (cp >= 0x2700 && cp <= 0x27bf) return true;
  if (cp >= 0x1f004 && cp <= 0x1f0cf) return true;
  return false;
}

/** 剥注释、保留字符串字面量 */
function keepStrings(src, ext) {
  if (ext === '.html' || ext === '.htm') return src.replace(/<!--[\s\S]*?-->/g, '');
  if (ext === '.css') return src.replace(/\/\*[\s\S]*?\*\//g, '');
  let out = '', i = 0, st = 0;
  while (i < src.length) {
    const c = src[i], d = src[i + 1];
    if (st === 0) {
      if (c === '/' && d === '/') { st = 4; i += 2; continue; }
      if (c === '/' && d === '*') { st = 5; i += 2; continue; }
      if (c === "'") { st = 1; out += c; i++; continue; }
      if (c === '"') { st = 2; out += c; i++; continue; }
      if (c === '`') { st = 3; out += c; i++; continue; }
      out += c; i++; continue;
    }
    if (st === 1 || st === 2 || st === 3) {
      const q = st === 1 ? "'" : st === 2 ? '"' : '`';
      out += c;
      if (c === '\\') { out += src[i + 1] || ''; i += 2; continue; }
      if (c === q) st = 0;
      i++; continue;
    }
    if (st === 4) { if (c === '\n') { st = 0; out += c; } i++; continue; }
    if (st === 5) { if (c === '*' && d === '/') { st = 0; i += 2; } else { if (c === '\n') out += c; i++; } continue; }
  }
  return out;
}

/** 收集待扫文件 */
function collect(dir, ext, out, skipRe) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (skipRe && skipRe.test(p)) continue;
    if (e.isDirectory()) { collect(p, ext, out, skipRe); continue; }
    if (!ext.includes(path.extname(e.name).toLowerCase())) continue;
    out.push(p);
  }
}

console.log('=== 出货面 emoji 闸门 ===');

/* ── A. Flutter 端（自己的 lib/）── */
console.log('\n[A] Flutter lib/ （禁装饰 emoji）');
const dash = [];
collect(path.join(ROOT, 'flutter_app', 'lib'), ['.dart'], dash, /(^|[\\/])(build|\.dart_tool)([\\/]|$)/);
let dBad = [];
for (const f of dash) {
  const src = fs.readFileSync(f, 'utf8');
  const cooked = keepStrings(src, '.dart');
  const lines = cooked.split(/\r?\n/);
  lines.forEach((l, i) => {
    const e = [];
    for (const ch of l) if (isEmoji(ch.codePointAt(0))) e.push(ch);
    if (e.length) dBad.push(`${path.relative(ROOT, f)}:${i + 1} [${[...new Set(e)].join('')}]`);
  });
}
if (!dBad.length) ok(`Flutter lib/ 无装饰 emoji（扫 ${dash.length} 文件）`);
else { bad(`Flutter lib/ 有 ${dBad.length} 处装饰 emoji：`); dBad.slice(0, 12).forEach((x) => console.error('        ' + x)); }

/* ── B. 网页端（只扫自家 js/ 与根 html，排除 vendored / 生成物）── */
if (WEB) {
  console.log('\n[B] 网页端 自家 js/ 与根 html');
  const webFiles = [];
  const skipWeb = /(^|[\\/])(gh-src|node_modules|thirdhub-agent|desktop|tools|\.tmp|\.rollback|sources|sources-packs|vendor)([\\/]|$)/;
  collect(path.join(WEB, 'js'), ['.js', '.mjs'], webFiles, skipWeb);
  // 根目录 html（排除生成报表）
  try {
    for (const e of fs.readdirSync(WEB, { withFileTypes: true })) {
      if (e.isFile() && /\.html?$/i.test(e.name) && !/source-audit|audit/i.test(e.name)) webFiles.push(path.join(WEB, e.name));
    }
  } catch (e) { /* 忽略 */ }

  // i18n 字典文件里出现 emoji 也算（它们是直接展示的文案）
  // ★ chagelog 是历史归档 → 豁免（只增不改）
  let wBad = [], wArchive = 0;
  for (const f of webFiles) {
    if (isArchiveFile(f)) { wArchive++; continue; }
    const src = fs.readFileSync(f, 'utf8');
    const cooked = keepStrings(src, path.extname(f).toLowerCase());
    const lines = cooked.split(/\r?\n/);
    lines.forEach((l, i) => {
      const e = [];
      for (const ch of l) if (isEmoji(ch.codePointAt(0))) e.push(ch);
      if (e.length) wBad.push(`${path.relative(WEB, f)}:${i + 1} [${[...new Set(e)].join('')}]`);
    });
  }
  if (!wBad.length) ok(`网页端 无装饰 emoji（扫 ${webFiles.length - wArchive} 文件，豁免历史归档 ${wArchive} 个）`);
  else {
    bad(`网页端 有 ${wBad.length} 处装饰 emoji：`);
    wBad.slice(0, 15).forEach((x) => console.error('        ' + x));
    if (wBad.length > 15) console.error(`        …另有 ${wBad.length - 15} 处`);
  }
  // 提示被豁免的归档文件（WARN 级，不拦发布）
  if (wArchive) warn(`已豁免 ${wArchive} 个历史归档文件（changelog 类，只增不改，不判 FAIL）`);
} else {
  warn('未传 --web=<网页端根>，跳过网页端检查（CI 里必须传，否则是假绿）');
}

/* ── C. 自检器自身必须能拦住（反证）── */
console.log('\n[C] 反证：注入 emoji 后闸门必须 FAIL');
{
  const tmp = path.join(ROOT, 'flutter_app', 'lib', '_probe_emoji.dart');
  try {
    fs.writeFileSync(tmp, "const s = '完成 🎉 了';\n", 'utf8');
    const src = fs.readFileSync(tmp, 'utf8');
    const cooked = keepStrings(src, '.dart');
    const hit = [...cooked].some((ch) => isEmoji(ch.codePointAt(0)));
    if (hit) ok('反证通过：伪装的 🎉 被检出（说明 A 组判定有效）');
    else bad('反证失败：注入 emoji 未被检出 —— 闸门是假绿！');
  } catch (e) {
    warn('反证无法执行：' + e.message);
  } finally {
    try { fs.unlinkSync(tmp); } catch (e) { /* 忽略 */ }
  }
}

console.log('\n────────────────────────────────');
console.log(`PASS ${pass}  FAIL ${fails}  WARN ${warns}`);
if (fails > 0) { console.error('emoji 闸门未通过。'); process.exit(1); }
console.log('emoji 闸门通过。');
process.exit(0);
