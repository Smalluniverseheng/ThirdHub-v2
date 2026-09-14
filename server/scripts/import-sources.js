// 书源导入器: 支持 本地文件/URL, 自动识别 单个书源/数组/Legado备份({data:[...]})/TXT多条
// 用法:
//   node scripts/import-sources.js ./书源.json
//   node scripts/import-sources.js https://example.com/sources.json
//   node scripts/import-sources.js --demo   (生成一条演示书源便于冒烟测试)
const fs = require('fs'); const path = require('path');
const DATA = path.join(__dirname, '..', 'data');
const SOURCES_FILE = path.join(DATA, 'sources.json');

function normalize(item) {
  // Legado 书源必需字段
  if (!item || !item.bookSourceUrl || !item.bookSourceName) return null;
  return {
    bookSourceUrl: item.bookSourceUrl, bookSourceName: item.bookSourceName,
    bookSourceGroup: item.bookSourceGroup || '', searchUrl: item.searchUrl || '',
    ruleSearch: item.ruleSearch || {}, ruleBookInfo: item.ruleBookInfo || {},
    ruleToc: item.ruleToc || {}, ruleContent: item.ruleContent || {},
    header: item.header || '', enabled: true
  };
}

function extract(json) {
  if (Array.isArray(json)) return json;
  if (json && Array.isArray(json.data)) return json.data;
  if (json && json.bookSourceUrl) return [json];
  return [];
}

async function main() {
  fs.mkdirSync(DATA, { recursive: true });
  const args = process.argv.slice(2);
  let items = [];
  if (args[0] === '--demo') {
    items = [{
      bookSourceUrl: 'https://demo.thirdhub.local', bookSourceName: '冒烟演示源',
      searchUrl: 'https://www.baidu.com/s?wd={{key}}',
      ruleSearch: { bookList: '.result', name: 'tag.h3@text', bookUrl: 'tag.a@href' },
      ruleBookInfo: {}, ruleToc: {}, ruleContent: {}
    }];
    console.log('已生成演示书源(仅验证引擎链路, 真实源请导入合集)');
  } else if (!args[0]) {
    console.log('用法: node scripts/import-sources.js <文件或URL> [--merge]');
    console.log('合集推荐: github.com/aoaostar/legado 与 github.com/XIU2/Yuedu 仓库内的 .json');
    process.exit(0);
  } else {
    const src = args[0];
    let text;
    if (/^https?:/.test(src)) {
      const r = await fetch(src, { signal: AbortSignal.timeout(15000) });
      text = await r.text();
    } else {
      text = fs.readFileSync(src, 'utf8');
    }
    // 可能是多条 JSON 拼接/TXT 一行一条
    try { items = extract(JSON.parse(text)); }
    catch (e) {
      const lines = text.split('\n').map(l => l.trim()).filter(l => l.startsWith('{') && l.endsWith('}'));
      for (const l of lines) { try { items.push(...extract(JSON.parse(l))); } catch (e2) {} }
    }
  }
  const norm = items.map(normalize).filter(Boolean);
  let existing = [];
  try { existing = JSON.parse(fs.readFileSync(SOURCES_FILE, 'utf8')); } catch (e) {}
  const before = existing.length;
  const seen = new Set(existing.map(s => s.bookSourceUrl));
  let added = 0;
  for (const s of norm) {
    if (seen.has(s.bookSourceUrl)) continue;
    existing.push(s); seen.add(s.bookSourceUrl); added++;
  }
  fs.writeFileSync(SOURCES_FILE, JSON.stringify(existing, null, 2));
  console.log(`导入完成: 新增 ${added} 条, 跳过重复 ${norm.length - added} 条, 库内共 ${existing.length} 条`);
}
main().catch(e => { console.error('导入失败:', e.message); process.exit(1); });
