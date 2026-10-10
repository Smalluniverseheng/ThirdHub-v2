/**
 * emoji_pass3.cjs —— 第三轮去 emoji（网页端 UI 层收尾）
 *
 * 前两轮已清掉 315+ 处。本轮针对**剩余 141 处 / 30 文件**的精确映射。
 *
 * 判定口径与 emoji_selfcheck.cjs 完全一致（含功能性字形豁免），
 * 所以本脚本改完，闸门 B 组应当直接转 OK。
 *
 * 用法： node emoji_pass3.cjs [--apply]
 */
const fs = require('fs');

const WEB = 'D:/ai/deep seek';
const APPLY = process.argv.includes('--apply');

/* ── 全局字符级替换（所有目标文件通用）── */
const CHAR = [
  // 组合变体选择符 / 零宽连接符：本身不可见，但残留会让闸门判为 emoji
  ['\uFE0F', ''],
  ['\u200D', ''],
  // 状态符号：由文字或 CSS 色点承担
  ['✓', ''],
  ['✗', ''],
  ['✔', ''],
  ['✘', ''],
  ['✅', ''],
  ['❌', ''],
  // 语义可保留的 → 换成文字
  ['🔞', '限制'],
  ['🚫', '禁止'],
  ['🔒', '锁定'],
  ['🔍', ''],
  ['📌', ''],
  ['✨', ''],
  ['💬', ''],
  ['🌸', ''],
  ['🍀', ''],
  ['🧡', ''],
  ['💙', ''],
  ['💚', ''],
  ['👤', ''],
  ['🌐', ''],
  ['🛡', ''],
  ['⛔', '禁止'],
  // 设备/平台 → 文字
  ['🍎', 'iOS'],
  ['🤖', 'Android'],
  ['🖥️', '桌面'],
  ['🖥', '桌面'],
  ['🇷🇺', 'RU'],
  ['🇸🇦', 'SA'],
  ['🇺🇸', 'US'],
  // 内容类型 emoji → 文字（legado-adapter 的分类示意）
  ['🎨', ''],
  ['🎬', ''],
  ['🎧', ''],
  // AI 分类前缀
  ['📰', ''],
  ['✍', ''],
  ['💼', ''],
  ['💻', ''],
  ['📚', ''],
  ['🏠', ''],
  ['🧠', ''],
  ['🎮', ''],
];

const TARGETS = [];
function walk(dir) {
  let es;
  try { es = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  for (const e of es) {
    const p = dir + '/' + e.name;
    if (/(^|[\\/])(gh-src|node_modules|thirdhub-agent|desktop|tools|\.tmp|\.rollback|sources|sources-packs|vendor)([\\/]|$)/.test(p)) continue;
    if (e.isDirectory()) { walk(p); continue; }
    if (!/\.(js|mjs|html?)$/i.test(e.name)) continue;
    if (/changelog(\.min)?\.js$/i.test(e.name)) continue; // 历史归档豁免
    if (/source-audit|audit/i.test(e.name)) continue;     // 生成报表豁免
    TARGETS.push(p);
  }
}
walk(WEB + '/js');
for (const e of fs.readdirSync(WEB, { withFileTypes: true })) {
  if (e.isFile() && /\.html?$/i.test(e.name) && !/audit/i.test(e.name)) TARGETS.push(WEB + '/' + e.name);
}

/* 收尾：清掉因删除 emoji 而留下的孤立空格。
   ★ 血泪教训（本文件第一版就把 js/admin.js 改坏过）：
      写 `t.replace(/\s+(['"`])\s*[,;)\]]/g, '$1$2')` —— **$2 根本不存在**，
      于是字面量 `$2` 被写进代码，产生 `'至'$2 + fmtDate(...)` 这种语法错误。
      替换串里只能引用**真实存在的**分组。删掉多余空格时用捕获组 $1 即可。 */
function tidy(s) {
  return s
    .split(/\r?\n/)
    .map((l) => {
      let t = l;
      t = t.replace(/(['"`])\s+\1/g, '$1$1');          // '' 里只有空格 → ''
      t = t.replace(/(['"`])\s+([,;)\]])/g, '$1$2');   // 串尾空格紧接 , ; ) ]
      t = t.replace(/^(\s*)(['"`])\s+/, '$1$2');       // 串首空格
      return t;
    })
    .join('\n');
}

let total = 0;
const report = [];
for (const f of TARGETS) {
  const src = fs.readFileSync(f, 'utf8');
  let out = src, n = 0;
  const hits = {};
  for (const [a, b] of CHAR) {
    const c = out.split(a).length - 1;
    if (c) { out = out.split(a).join(b); n += c; hits[a] = c; }
  }
  if (!n) continue;
  out = tidy(out);
  if (APPLY) {
    // 先备份，再改，改完立刻自检语法——坏了就当场回滚（不留半成品）
    const bak = f + '.bak-pass3';
    if (!fs.existsSync(bak)) fs.writeFileSync(bak, src, 'utf8');
    try {
      new Function(out); // 粗验：能编译才算过（对 ESM import/export 会跳过）
    } catch (e) {
      if (/import|export/.test(e.message) === false && !/await is only valid/.test(e.message)) {
        console.error('  [跳过] ' + f.replace(WEB + '/', '') + ' 改后语法异常：' + e.message.slice(0, 60));
        continue;
      }
    }
    fs.writeFileSync(f, out, 'utf8');
  }
  total += n;
  report.push({ f: f.replace(WEB + '/', ''), n, hits });
}

report.sort((a, b) => b.n - a.n);
for (const r of report) {
  console.log(String(r.n).padStart(4) + '  ' + r.f + '  [' + Object.keys(r.hits).join(' ') + ']');
}
console.log('\n' + (APPLY ? '已应用' : '试运行') + '：' + total + ' 处 / ' + report.length + ' 文件');
