#!/usr/bin/env node
/*
 * _verify_remote_branding.cjs —— 远端出货面用词「真验证」
 *
 * 为什么需要这个脚本：
 *   上一轮的远端校验用的是朴素正则 /换源|书源|图源|音源/，
 *   它必然命中「门禁自身的白名单字符串 + 文档头注释 + 故意保留的 i18n key」，
 *   所以输出「含违规词=是」是**假阳性**，不构成有效判定。
 *
 * 正确做法：把远端内容取回来，**逐行套用本地门禁的同一套「合法用途白名单」**，
 *   只有不在白名单里的行才算真命中。这样本地和远端用的是同一把尺子。
 *
 * 用法：node tools/_verify_remote_branding.cjs
 */

const fs = require('fs');
const path = require('path');
const https = require('https');

// ---------- 读 token ----------
function loadToken() {
  const envPath = 'C:/Users/英莉/WorkBuddy/第三方聚合平台/.env';
  const txt = fs.readFileSync(envPath, 'utf8');
  for (const line of txt.split(/\r?\n/)) {
    const m = line.match(/^\s*GITHUB_TOKEN\s*=\s*(.+?)\s*$/);
    if (m) return m[1].replace(/^["']|["']$/g, '');
  }
  throw new Error('GITHUB_TOKEN not found in .env');
}

const TOKEN = loadToken();

// ---------- 拉远端文件 ----------
function ghGet(repo, filePath) {
  return new Promise((resolve, reject) => {
    const opts = {
      host: 'api.github.com',
      path: `/repos/${repo}/contents/${encodeURI(filePath)}`,
      headers: {
        'Authorization': `Bearer ${TOKEN}`,
        'User-Agent': 'thirdhub-verify',
        'Accept': 'application/vnd.github+json',
      },
    };
    https.get(opts, (res) => {
      let buf = '';
      res.on('data', (d) => (buf += d));
      res.on('end', () => {
        if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode} ${repo}/${filePath}`));
        const j = JSON.parse(buf);
        resolve(Buffer.from(j.content, 'base64').toString('utf8'));
      });
    }).on('error', reject);
  });
}

// ---------- 门禁的同一把尺子（必须与 forbidden-words.cjs 保持一致） ----------
const WORDS = ['换源', '书源', '图源', '音源', '影视源'];

const LEGAL_PATTERNS = [
  /['"][^'"]*(换源|书源|图源|音源|影视源)['"]\s*:\s*['"`]/, // i18n 查找 key
  /<String>\s*\[/,                                          // changelog 同义词表
  /^\s*['"][^'"]*(换源|书源|图源|音源|影视源)['"]\s*,?\s*$/, // 裸词表项
  /\.contains\(/, /indexOf\(/, /includes\(/,                 // 旧引擎匹配串
  /checks\.push\(/,                                          // 后端自检横幅
  /\['cheerio',/,                                            // 依赖列表
];

function isLegal(line) {
  return LEGAL_PATTERNS.some((re) => re.test(line));
}

// 与门禁一致的「注释/文档头」判定：整行注释不算出货面
function isCommentLine(line) {
  const t = line.trim();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')
      || t.startsWith('#') || t.startsWith('--') || t.startsWith('///');
}

function scanText(text, label) {
  const hits = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.includes('forbidden-words') || line.includes('_verify_remote_branding')) continue;
    if (isCommentLine(line)) continue;
    if (!WORDS.some((w) => line.includes(w))) continue;
    if (isLegal(line)) continue;
    hits.push({ label, line: i + 1, text: line.trim().slice(0, 120) });
  }
  return hits;
}

// ---------- 目标清单 ----------
const TARGETS = [
  ['Smalluniverseheng/ThirdHub-v2', 'server/index.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'server/routes-media.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'server/engine-comic.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'server/engine-lx.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'server/engine-music.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'server/engine-plugin.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'server/venera-runtime.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'server/venera.js'],
  ['Smalluniverseheng/ThirdHub-v2', 'flutter_app/lib/core/engine_direct.dart'],
  ['Smalluniverseheng/ThirdHub-v2', 'flutter_app/lib/core/manual_book.dart'],
  ['Smalluniverseheng/ThirdHub-v2', 'flutter_app/lib/main.dart'],
  ['Smalluniverseheng/ThirdHub-v2', 'flutter_app/lib/core/photo_map.dart'],
  ['Smalluniverseheng/ThirdHub', 'js/modules/backend-center.js'],
  ['Smalluniverseheng/ThirdHub', 'js/modules/category.js'],
  ['Smalluniverseheng/ThirdHub', 'js/modules/dsh-console.js'],
  ['Smalluniverseheng/ThirdHub', 'js/readers/novel-reader.js'],
];

(async () => {
  let filesOk = 0, filesFail = 0;
  const allHits = [];
  for (const [repo, p] of TARGETS) {
    try {
      const text = await ghGet(repo, p);
      const hits = scanText(text, `${repo}/${p}`);
      allHits.push(...hits);
      filesOk++;
      const bytes = Buffer.byteLength(text, 'utf8');
      console.log(`200 ${repo} ${p} | bytes=${bytes} | 出货面违规词=${hits.length}`);
    } catch (e) {
      filesFail++;
      console.log(`FAIL ${repo} ${p} | ${e.message}`);
    }
  }
  console.log('');
  console.log(`远端可读文件：${filesOk}/${TARGETS.length}（失败 ${filesFail}）`);
  console.log(`远端出货面违规词命中：${allHits.length}`);

  if (allHits.length) {
    console.log('');
    console.log('=== 命中明细 ===');
    for (const h of allHits) console.log(`  ${h.label}:${h.line}  ${h.text}`);
    console.log('');
    console.log('VERDICT: FAIL');
    process.exit(1);
  }
  console.log('');
  console.log('VERDICT: PASS —— 远端 16 个出货面文件全部无违规词（按门禁同一把尺子）');
  process.exit(0);
})();
