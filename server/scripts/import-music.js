// MusicFree音源批量导入: 从公开插件仓库拉取 → 入后端
// 用法: node scripts/import-music.js [--list] [关键词...]
// 生态: github.com/maotoumao/MusicFree(官方示例+社区插件)
const fs = require('fs'); const path = require('path');
const DATA = path.join(__dirname, '..', 'data');
const MUSIC_FILE = path.join(DATA, 'music-sources.json');
const GH_TOKEN = process.env.GITHUB_TOKEN || '';

async function ghJson(url) {
  const headers = { 'Accept': 'application/vnd.github+json' };
  if (GH_TOKEN) headers['Authorization'] = 'token ' + GH_TOKEN;
  const r = await fetch(url, { headers, signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error('GitHub ' + r.status);
  return await r.json();
}
async function collectJs(repo, dir = '', depth = 0) {
  if (depth > 2) return [];
  const items = await ghJson(`https://api.github.com/repos/${repo}/contents/${dir}?ref=main`);
  if (!Array.isArray(items)) return [];
  let out = [];
  for (const f of items) {
    if (f.type === 'file' && f.name.endsWith('.js') && !f.name.includes('test')) out.push({ ...f, repo });
    else if (f.type === 'dir' && !['.github', 'docs', 'doc', 'img', 'images', 'assets'].includes(f.name))
      out = out.concat(await collectJs(repo, f.path, depth + 1));
  }
  return out;
}

async function main() {
  fs.mkdirSync(DATA, { recursive: true });
  const args = process.argv.slice(2);
  // MusicFree 官方仓库的插件示例在仓库各处, 扫描主仓库 + 已知社区集合
  const repos = ['maotoumao/MusicFree'];
  let files = [];
  for (const repo of repos) {
    try { files = files.concat(await collectJs(repo)); } catch (e) { console.log(`${repo}: ${e.message}`); }
  }
  console.log(`发现 ${files.length} 个音源JS`);
  if (args[0] === '--list') { for (const f of files) console.log(`  ${f.repo}/${f.path}`); return; }
  let existing = [];
  try { existing = JSON.parse(fs.readFileSync(MUSIC_FILE, 'utf8')); } catch (e) {}
  const seen = new Set(existing.map(s => s.id));
  const targets = args.length ? files.filter(f => args.some(a => (f.repo + f.path).includes(a))) : files.slice(0, 20);
  console.log(`本次导入: ${targets.length} 个`);
  let added = 0, failed = 0;
  for (const f of targets) {
    const id = 'music_' + f.path.replace(/\//g, '_').replace(/\.js$/, '');
    if (seen.has(id)) continue;
    try {
      const r = await fetch(f.download_url, { signal: AbortSignal.timeout(15000) });
      const code = await r.text();
      if (!code.includes('module.exports') && !code.includes('exports.')) { failed++; continue; }
      const platform = (code.match(/platform\s*[:=]\s*['"`]([^'"`]+)/) || [])[1] || f.name;
      existing.push({ id, name: platform, platform, code });
      seen.add(id); added++;
      await new Promise(r2 => setTimeout(r2, 300));
    } catch (e) { failed++; }
  }
  fs.writeFileSync(MUSIC_FILE, JSON.stringify(existing));
  console.log(`完成: 新增 ${added}, 失败/跳过 ${failed}, 库内共 ${existing.length} 条`);
}
main().catch(e => { console.error('导入失败:', e.message); process.exit(1); });
