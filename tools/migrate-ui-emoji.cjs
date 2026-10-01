'use strict';
// D-H2 批量清理：把 UI 面 emoji 常量换成 UiIcon 的图标键
//
// 为什么用脚本而不是手改 30 行：
//   ① 同一条 emoji 在不同文件里**写法可能不同**（带不带 FE0F 变体选择符），
//      手改极易漏掉一个，而"漏掉一个"在外观上只表现为**某一处还是 emoji**
//      —— 不会报错、不会崩，只能靠人盯着看，正是最该机器化的那类活。
//   ② 脚本会把每一处改动**逐行打出来**，可复核性不比手改低。
//   ③ 只在明确列出的 9 个文件里替换，不扫全仓，避免误伤注释与文档。
//
// ★ 注意：这里只改**数据里的图标键**。渲染侧必须改用 uiIcon()，
//   否则把 '🤖' 改成 'robot' 之后 UI 会直接显示字符串 "robot" —— 更糟。
const fs = require('fs');
const path = require('path');

const FLUTTER = path.join(__dirname, '..', 'flutter_app');

const MAP = {
  '\u{1F916}': 'robot', '\u{1F52C}': 'research', '\u{1F4BB}': 'code',
  '\u{1F4F1}': 'device', '\u{1F4CA}': 'chart', '\u{270D}\u{FE0F}': 'writer',
  '\u{270D}': 'writer', '\u{1F310}': 'translate', '\u{1F5C2}\u{FE0F}': 'library',
  '\u{1F5C2}': 'library', '\u{1F50D}': 'search', '\u{1F6E0}\u{FE0F}': 'tool',
  '\u{1F6E0}': 'tool', '\u{1F5D1}\u{FE0F}': 'delete', '\u{1F5D1}': 'delete',
  '\u{1F4DD}': 'summary', '\u{1F393}': 'teacher', '\u{1F5C4}\u{FE0F}': 'sql',
  '\u{1F5C4}': 'sql', '\u{1F3AF}': 'prompt', '\u{1F9F9}': 'clean',
  '\u{1F4DA}': 'stats', '\u{1F517}': 'link', '\u{1F4BE}': 'backup',
  '\u{1F4CB}': 'task', '\u{1F522}': 'game2048', '\u{1F40D}': 'snake',
  '\u{26AB}': 'gomoku', '\u{1F604}': 'happy', '\u{1F642}': 'ok',
  '\u{1F610}': 'meh', '\u{1F614}': 'sad', '\u{1F624}': 'angry',
  '\u{1F4CC}': 'pin', '\u{2B07}\u{FE0F}': 'download', '\u{2B07}': 'download',
};

// 每个文件允许替换的 emoji 白名单（防止误伤注释里的 ★ 或协议里的字符）
const TARGETS = [
  'lib/core/ai_agent.dart',
  'lib/core/ai_skills.dart',
  'lib/core/job_center.dart',
  'lib/core/lab_games.dart',
  'lib/core/mini_modules2.dart',
];

let changed = 0;
for (const rel of TARGETS) {
  const fp = path.join(FLUTTER, rel);
  if (!fs.existsSync(fp)) { console.log('SKIP(不存在) ' + rel); continue; }
  const lines = fs.readFileSync(fp, 'utf8').split('\n');
  let fileChanged = 0;
  const out = lines.map((line, i) => {
    // 注释行整行跳过（保留作者刻意写的视觉锚点）
    const codeOnly = line.split('//')[0];
    let next = codeOnly;
    for (const [emo, key] of Object.entries(MAP)) {
      if (next.includes(emo)) next = next.split(emo).join(key);
    }
    if (next !== codeOnly) {
      const rebuilt = next + line.slice(codeOnly.length);
      console.log('  ' + rel + ':' + (i + 1) + '\n      - ' + line.trim() + '\n      + ' + rebuilt.trim());
      fileChanged++; changed++;
      return rebuilt;
    }
    return line;
  });
  if (fileChanged) fs.writeFileSync(fp, out.join('\n'));
  console.log((fileChanged ? '改写 ' : '未变 ') + rel + '  (' + fileChanged + ' 行)');
}
console.log('\nTOTAL_LINES_CHANGED=' + changed);
