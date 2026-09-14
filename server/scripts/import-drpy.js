// drpy影视源批量导入: 从 hjdhnx/dr_py 仓库拉 js/ 目录源 → 入后端
// 用法:
//   node scripts/import-drpy.js                  # 拉仓库里全部源
//   node scripts/import-drpy.js 豆ban.js         # 拉指定文件
//   node scripts/import-drpy.js --list           # 只列清单不导入
// 说明: 通过 GitHub Contents API 拉取(无需git), 限流5000次/小时,
//       全量导入(数百文件)可能触发限流, 建议分批或挂token。
const fs = require('fs'); const path = require('path');
const DATA = path.join(__dirname, '..', 'data');
const DRPY_FILE = path.join(DATA, 'drpy-sources.json');
const REPO = 'hjdhnx/dr_py';
const GH_TOKEN = process.env.GITHUB_TOKEN || '';

async function ghJson(url) {
  const headers = { 'Accept': 'application/vnd.github+json' };
  if (GH_TOKEN) headers['Authorization'] = 'token ' + GH_TOKEN;
  const r = await fetch(url, { headers, signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error('GitHub ' + r.status);
  return await r.json();
}

async function main() {
  fs.mkdirSync(DATA, { recursive: true });
  const args = process.argv.slice(2);
  const list = await ghJson(`https://api.github.com/repos/${REPO}/contents/js?ref=main`);
  if (!Array.isArray(list)) { console.error('目录获取失败:', list.message || list); process.exit(1); }
  const files = list.filter(f => f.name.endsWith('.js'));
  console.log(`仓库共有 ${files.length} 个drpy源`);

  let existing = [];
  try { existing = JSON.parse(fs.readFileSync(DRPY_FILE, 'utf8')); } catch (e) {}
  const seen = new Set(existing.map(s => s.id));
  let added = 0, failed = 0;

  if (args[0] === '--list') {
    for (const f of files) console.log(`  ${f.name}  (${Math.round(f.size / 1024)}KB)`);
    console.log('导入请去掉 --list');
    return;
  }

  const targets = args.length ? files.filter(f => args.some(a => f.name.includes(a)))
                              : files.slice(0, 50); // 无参数默认前50个(防限流)
  console.log(`本次导入: ${targets.length} 个`);

  for (const f of targets) {
    const id = 'drpy_' + f.name.replace(/\.js$/, '');
    if (seen.has(id)) continue;
    try {
      const r = await fetch(f.download_url, { signal: AbortSignal.timeout(15000) });
      const code = await r.text();
      if (!code.includes('rule')) { failed++; continue; }
      existing.push({ id, name: f.name.replace(/\.js$/, ''), code });
      seen.add(id); added++;
      if (added % 10 === 0) console.log(`  已导 ${added}...`);
      await new Promise(r2 => setTimeout(r2, 300)); // 温和限流
    } catch (e) { failed++; }
  }
  fs.writeFileSync(DRPY_FILE, JSON.stringify(existing));
  console.log(`完成: 新增 ${added}, 失败/跳过 ${failed}, 库内共 ${existing.length} 条`);
  console.log('重启后端或等待下次加载生效');
}
main().catch(e => { console.error('导入失败:', e.message); process.exit(1); });
