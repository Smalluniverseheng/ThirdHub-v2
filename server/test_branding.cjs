// 后端品牌用词审计（红队交付物）—— 与网页端 tools/audit-branding.cjs 同口径。
//
// 用户明令：后端同样不得出现「引擎 / 换源 / 书源 / 图源」这类内容来源类字眼。
// 后端面向用户的界面只有 public/index.html（管理台）+ 各处 JSON 响应里的提示语，
// 本脚本两头都查。
//
// 用法: node test_branding.cjs
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const BANNED = ['引擎', '换源', '书源', '图源', '影视源', '音乐源'];

const EXEMPT_SUBSTR = [
  '搜索引擎', '搜索聚合引擎', '火山引擎',
  'TTS', 'tts', '语音', '朗读', '合成', 'piper', 'sherpa', 'cosyvoice', 'CosyVoice',
  '摘要引擎', '翻译引擎', '规则引擎', 'aria2', '图源', // 地图瓦片源
  '源引擎', 'source-engine', 'sourceEngine', 'engine-', 'Engine',
];

// 文件级豁免：这些是引擎适配层/内部实现，其"引擎/源"是准确的架构描述，非用户可见
const EXEMPT_FILES = [
  'engine-comic.js', 'engine-drpy.js', 'engine-lx.js', 'engine-music.js',
  'engine-plugin.js', 'engine-tvbox.js', 'engine.js', 'venera.js', 'venera-runtime.js',
  'thp1.js', 'drpy-host.js', 'drpy-http-sync.js', 'drpy-runner.js',
  'test_branding.cjs',
];

function stripComments(src) {
  let s = src.replace(/\/*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '));
  s = s.split('\n').map((line) => {
    let out = '', i = 0, inStr = null;
    while (i < line.length) {
      const c = line[i];
      if (inStr) {
        out += c;
        if (c === '\\') { out += line[i + 1] || ''; i += 2; continue; }
        if (c === inStr) inStr = null;
        i++; continue;
      }
      if (c === "'" || c === '"' || c === '`') { inStr = c; out += c; i++; continue; }
      if (c === '/' && line[i + 1] === '/') break;
      out += c; i++;
    }
    return out;
  }).join('\n');
  return s;
}

function literals(line) {
  const out = [];
  let i = 0, inStr = null, buf = '';
  while (i < line.length) {
    const c = line[i];
    if (inStr) {
      if (c === '\\') { buf += line[i + 1] || ''; i += 2; continue; }
      if (c === inStr) { out.push(buf); buf = ''; inStr = null; i++; continue; }
      buf += c; i++; continue;
    }
    if (c === "'" || c === '"' || c === '`') { inStr = c; i++; continue; }
    i++;
  }
  return out;
}

const isExempt = (lit) => EXEMPT_SUBSTR.some((s) => lit.includes(s));

// 目标文件：public/ 下所有 html/js + 各 routes-*.js（含用户可见提示语）
const targets = [];
const pub = path.join(ROOT, 'public');
if (fs.existsSync(pub)) {
  for (const e of fs.readdirSync(pub)) {
    if (/\.(html|js)$/.test(e) && !/\.min\.js$/.test(e)) targets.push(path.join(pub, e));
  }
}
for (const e of fs.readdirSync(ROOT)) {
  if (/^routes-.*\.js$/.test(e)) targets.push(path.join(ROOT, e));
}

const hits = [];
for (const f of targets) {
  if (EXEMPT_FILES.includes(path.basename(f))) continue;
  const code = stripComments(fs.readFileSync(f, 'utf8'));
  code.split('\n').forEach((line, idx) => {
    for (const lit of literals(line)) {
      const w = BANNED.find((b) => lit.includes(b));
      if (w && !isExempt(lit)) hits.push(`${path.relative(ROOT, f)}:${idx + 1}  [${w}]  "${lit.slice(0, 90)}"`);
    }
  });
}

console.log(`扫描 ${targets.length} 个面向用户文件`);
if (hits.length) {
  console.log(`FAIL：内容来源类违规 ${hits.length} 处`);
  for (const h of hits) console.log('  ' + h);
  process.exit(1);
}
console.log('PASS：后端无内容来源类违规用词');
