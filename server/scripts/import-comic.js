// Venera漫画图源批量导入: 从 venera-app/venera-configs 仓库拉图源JS → 入后端
// 用法: node scripts/import-comic.js [--list] [关键词...]
// 图源生态: 官方源列表仓库(持续更新), 本脚本通过GitHub API拉取
const fs = require('fs'); const path = require('path');
const DATA = path.join(__dirname, '..', 'data');
const COMIC_FILE = path.join(DATA, 'comic-sources.json');
const REPO = 'venera-app/venera-configs';
const GH_TOKEN = process.env.GITHUB_TOKEN || '';

async function ghJson(url) {
  const headers = { 'Accept': 'application/vnd.github+json' };
  if (GH_TOKEN) headers['Authorization'] = 'token ' + GH_TOKEN;
  const r = await fetch(url, { headers, signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error('GitHub ' + r.status);
  return await r.json();
}

// 递归收集仓库内 .js 文件(最多2层, 防目录过深)
async function collectJs(dir = '', depth = 0) {
  if (depth > 2) return [];
  const items = await ghJson(`https://api.github.com/repos/${REPO}/contents/${dir}?ref=main`);
  if (!Array.isArray(items)) return [];
  let out = [];
  for (const f of items) {
    if (f.type === 'file' && f.name.endsWith('.js') && !f.name.includes('template')) out.push(f);
    else if (f.type === 'dir' && !['.github', 'icons', 'doc', 'docs'].includes(f.name)) {
      out = out.concat(await collectJs(f.path, depth + 1));
    }
  }
  return out;
}

async function main() {
  fs.mkdirSync(DATA, { recursive: true });
  const args = process.argv.slice(2);
  console.log('扫描 venera-configs 仓库图源...');
  const files = await collectJs();
  console.log(`发现 ${files.length} 个图源JS`);
  if (args[0] === '--list') {
    for (const f of files) console.log(`  ${f.path}  (${Math.round(f.size / 1024)}KB)`);
    return;
  }
  let existing = [];
  try { existing = JSON.parse(fs.readFileSync(COMIC_FILE, 'utf8')); } catch (e) {}
  const seen = new Set(existing.map(s => s.id));
  const targets = args.length ? files.filter(f => args.some(a => f.path.includes(a))) : files.slice(0, 30);
  console.log(`本次导入: ${targets.length} 个`);
  let added = 0, failed = 0;
  for (const f of targets) {
    const id = 'comic_' + f.path.replace(/\//g, '_').replace(/\.js$/, '');
    if (seen.has(id)) continue;
    try {
      const r = await fetch(f.download_url, { signal: AbortSignal.timeout(15000) });
      const code = await r.text();
      if (!code.includes('ComicSource')) { failed++; continue; }
      existing.push({ id, name: f.path.replace(/\.js$/, ''), code });
      seen.add(id); added++;
      if (added % 10 === 0) console.log(`  已导 ${added}...`);
      await new Promise(r2 => setTimeout(r2, 300));
    } catch (e) { failed++; }
  }
  fs.writeFileSync(COMIC_FILE, JSON.stringify(existing));
  console.log(`完成: 新增 ${added}, 失败/跳过 ${failed}, 库内共 ${existing.length} 条`);
}
main().catch(e => { console.error('导入失败:', e.message); process.exit(1); });
