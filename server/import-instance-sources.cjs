// ─────────────────────────────────────────────────────────────────────────────
// import-instance-sources.cjs — 一次性把**真实实例源**导入 server/data/
//
// 为什么有这个脚本（`docs/TASKS.md` 组E「sources 数据包首启导入」、以及
// 《AI-任务总清单-逐项对账》§四 第 9 条「E2/E3 实例源入库」）：
//   此前后端四个引擎**代码都在**，但 `data/drpy-sources.json`、
//   `data/comic-sources.json`、`data/music-sources.json` **三个文件都不存在**
//   → 影视/漫画/音乐三条链路是"页面齐、引擎齐、**零实例源**"，
//     表现就是"点进去什么都没有"。这就是对账里判定为"部分"的原因。
//
// 数据来自本机已有的上游源包（不入 git 的大目录），只把**挑选后的源正文**写进仓库：
//   drpy  : <UPSTREAM>/dr-py/js/*.js             （drpy2 源脚本，`var rule = {...}`）
//   music : <FLUTTER>/assets/sources/music_lx/*.js （洛雪 LX 自定义音源）
//   comic : 无 —— 见文末说明
//
// 挑选规则（★ 2026-09-25 重写 —— 上一版挑出来的源**一条都搜不出东西**）：
//
//   上一版只检查 `代码里出现过 search 字样`。结果把 `310直播` 这种
//   `searchable:0, searchUrl:''` 的**不可搜索源**也收了进来 ——
//   40 条里绝大多数都是这类。实测引擎跑通后返回 `"{}"`（drpy 表示"无结果"），
//   用户看到的就是"导入了一堆源，一条都搜不出来"。
//   「代码里含 search」和「这个源支持搜索」是两件事，必须按 **rule 字段**判定：
//     · `searchUrl` 必须非空（drpy 的 searchParse 第一句就是 `if(!searchObj.searchUrl){return "{}"}`）
//     · `searchable` 不能是 0（0 = 作者主动关掉了搜索）
//     · 搜索解析规则（`搜索:`）必须存在 —— 否则即使拿到 HTML 也解析不出条目
//   另外 `模板: 'xxx'` 的源现在**可以收**了：`模板.js` 已 vendor 进
//   `server/vendor/drpy/muban.js` 并由引擎注入沙箱（引擎 init() 硬依赖它）。
//
//   音源（LX）也重写了：上一版完全没看音源**自己声明的能力**。
//   LX 音源在 init 时 `lx.send('inited', {sources:{wy:{actions:['musicUrl']}}})`
//   里写明支持哪些动作。实测本机 25 条里 **11 条只声明 musicUrl、仅 2 条声明 search**
//   —— 也就是说"音源搜不出歌"绝大部分是**我们问错了问题**，不是源坏了。
//   现在导入时逐条探测能力并写入 `actions` 字段，搜索路由只挑声明了 search 的源。
//   同时剔除依赖 LX 应用侧注入符号（`__PUBLIC_KEY__` / `require` / `module`）的源 ——
//   那些是洛雪官方签名源，脱离 App 环境根本起不来。
//
// 用法: node server/import-instance-sources.cjs [--dry]
'use strict';
// 音源是第三方脚本，在 vm 里跑。同步异常能被 try/catch 拦住，
// 但源里 `(async()=>{ fetch(...) })()` 这种**事件循环里**抛出的异常会脱离
// 一切 try/catch，Node 默认直接结束进程。实测导入过程就被一条源的
// `getaddrinfo ENOTFOUND` 打断了整个脚本 —— 所以这里同样要护栏。
process.on('unhandledRejection', (e) => {
  console.error('[guard] 未处理的 Promise 异常（已隔离）:', String((e && e.message) || e).slice(0, 160));
});
process.on('uncaughtException', (e) => {
  console.error('[guard] 未捕获异常（已隔离）:', String((e && e.message) || e).slice(0, 160));
});
const fs = require('fs');
const path = require('path');

const DRPY_DIR = 'D:/ai/deep seek/sources-packs/_upstream/dr-py/js';
const MUSIC_DIR = 'D:/ai/thirdhub-flutter/assets/sources/music_lx';
const OUT_DIR = path.join(__dirname, 'data');

const LIMITS = { drpyMaxFiles: 60, drpyMaxBytes: 900 * 1024, musicMaxFiles: 40, musicMaxBytes: 700 * 1024 };
const DRY = process.argv.includes('--dry');

function readDirSafe(d) { try { return fs.readdirSync(d); } catch (_) { return []; } }

// 从源脚本里取 `key: '值'` / `key: "值"` / `key: 裸值` 形式的 rule 字段。
// 不 eval 源（导入阶段不该执行第三方代码），只做文本抽取 —— 宁可漏判也不要误判。
function ruleField(code, key) {
  const re = new RegExp(key + '\\s*:\\s*([\'"])((?:\\\\.|(?!\\1)[\\s\\S])*)\\1');
  const m = code.match(re);
  if (m) return m[2];
  const re2 = new RegExp(key + '\\s*:\\s*([^,\\n}]+)');
  const m2 = code.match(re2);
  return m2 ? m2[1].trim() : null;
}

const strOf = (v) => (v == null ? '' : String(v).replace(/^['"]|['"]$/g, '').trim());

// ── drpy ─────────────────────────────────────────────────────────────────────
function pickDrpy() {
  const out = [];
  let bytes = 0;
  const files = readDirSafe(DRPY_DIR).filter(f => f.endsWith('.js')).sort();
  const cands = [];
  const stat = { noRule: 0, noSearchUrl: 0, searchableOff: 0, noParseRule: 0 };
  for (const f of files) {
    let code;
    try { code = fs.readFileSync(path.join(DRPY_DIR, f), 'utf8'); } catch (_) { continue; }
    if (!/var\s+rule\s*=/.test(code)) { stat.noRule++; continue; }
    if (!strOf(ruleField(code, 'searchUrl'))) { stat.noSearchUrl++; continue; }
    if (strOf(ruleField(code, 'searchable')) === '0') { stat.searchableOff++; continue; }
    // 搜索解析规则：`搜索: '...'`（drpy 惯例）；少数源写成 `search:`
    const hasParse = !!strOf(ruleField(code, '搜索')) || !!strOf(ruleField(code, 'search'));
    // `模板: 'mxpro'` 的源由 muban 字典补默认解析规则，也算有
    const hasMuban = !!strOf(ruleField(code, '模板'));
    if (!hasParse && !hasMuban) { stat.noParseRule++; continue; }
    cands.push({ file: f, code, size: Buffer.byteLength(code), muban: hasMuban });
  }
  // 不依赖模板的排前面（少一层解析风险），再按体积升序
  cands.sort((a, b) => (a.muban - b.muban) || (a.size - b.size));
  for (const c of cands) {
    if (out.length >= LIMITS.drpyMaxFiles) break;
    if (bytes + c.size > LIMITS.drpyMaxBytes) continue;
    const name = c.file.replace(/\.js$/, '');
    out.push({
      id: 'drpy:' + name,
      name,
      enabled: true,
      format: 'drpy',
      // 与 engine-drpy.runSource(code, ...) 的入参对应
      code: c.code,
      source: 'upstream:dr-py/js',
    });
    bytes += c.size;
  }
  return { list: out, bytes, totalCandidates: cands.length, stat };
}

// ── music (LX) ───────────────────────────────────────────────────────────────
function pickMusic() {
  const out = [];
  let bytes = 0;
  const files = readDirSafe(MUSIC_DIR).filter(f => f.endsWith('.js')).sort();
  const cands = [];
  const stat = { obfuscated: 0, appOnly: 0 };
  for (const f of files) {
    let code;
    try { code = fs.readFileSync(path.join(MUSIC_DIR, f), 'utf8'); } catch (_) { continue; }
    if (/jsjiami\.com/.test(code)) { stat.obfuscated++; continue; }   // 混淆脚本在 vm 里极易死循环
    // 依赖 LX 应用侧注入符号 → 脱离 App 必然起不来，收进来只会变成"死源"
    if (/__PUBLIC_KEY__/.test(code) || /\brequire\s*\(/.test(code) || /module\.exports/.test(code)) { stat.appOnly++; continue; }
    if (!/lx\.(on|send|request|EVENT_NAMES)/.test(code) && !/musicUrl|qualitys|音源/.test(code)) continue;
    cands.push({ file: f, code, size: Buffer.byteLength(code) });
  }
  cands.sort((a, b) => a.size - b.size);
  for (const c of cands) {
    if (out.length >= LIMITS.musicMaxFiles) break;
    if (bytes + c.size > LIMITS.musicMaxBytes) continue;
    const name = c.file.replace(/\.js$/, '').replace(/__/g, '·');
    out.push({
      id: 'lx:' + c.file.replace(/\.js$/, ''),
      name,
      enabled: true,
      format: 'lx',                                    // routes-search 用它决定走 lx.runLX
      code: c.code,
      source: 'upstream:lx-music-source',
      actions: null,                                   // 下面探测后回填
    });
    bytes += c.size;
  }
  return { list: out, bytes, totalCandidates: cands.length, stat };
}

// 逐条装载音源、读它声明的能力（只 init，不发起业务请求）
async function probeMusic(list) {
  const lx = require('./engine-lx.js');
  let ok = 0, dead = 0;
  for (const s of list) {
    const info = await lx.getSourceInfo(s.code);
    if (!info.ok) { s.enabled = false; s.actions = []; s.probeError = info.error.slice(0, 120); dead++; continue; }
    s.actions = info.actions;
    s.platforms = info.platforms.map(p => p.id);
    ok++;
  }
  return { ok, dead };
}

// ── comic ────────────────────────────────────────────────────────────────────
// ★ 这里**没有**导入任何漫画源，且是刻意的。
//   本机上下游源包里只找到 Venera **应用本体**（`_upstream/venera`，
//   Dart 工程 + `assets/init.js` 是它的 JS API 库），**没有任何一份 Venera 格式的
//   漫画源实例**。与其凭印象写几个"看着像"的源（跑起来必然报错，用户只会认为
//   "漫画模块是坏的"），不如留空并在这里写清楚：漫画源需要用户自己导入。
//   前端/控制台会把"0 条"如实显示出来，不会伪装成"有源但搜不到"。
function pickComic() { return { list: [], bytes: 0, totalCandidates: 0, note: '本机无 Venera 格式漫画源实例，未导入（不伪造）' }; }

function main() {
  const drpy = pickDrpy();
  const music = pickMusic();
  const comic = pickComic();

  const report = {
    drpy: { imported: drpy.list.length, candidates: drpy.totalCandidates, bytes: drpy.bytes, skipped: drpy.stat },
    music: { imported: music.list.length, candidates: music.totalCandidates, bytes: music.bytes, skipped: music.stat },
    comic: { imported: comic.list.length, note: comic.note },
  };
  console.log(JSON.stringify(report, null, 2));

  if (DRY) { console.log('(--dry: 未写文件)'); return; }

  return (async () => {
    // 音源能力探测：拿它自己声明的 actions 给搜索路由用
    const pr = await probeMusic(music.list);
    const withSearch = music.list.filter(s => (s.actions || []).includes('search')).length;
    console.log('\n音源能力探测: 可用 ' + pr.ok + ' 条 / 起不来 ' + pr.dead + ' 条；其中声明支持 search 的 ' + withSearch + ' 条');
    for (const s of music.list) {
      console.log('  ' + (s.enabled ? '·' : '×') + ' ' + String(s.name).slice(0, 34).padEnd(36) + JSON.stringify(s.actions || []) + (s.probeError ? '  ← ' + s.probeError : ''));
    }

    fs.mkdirSync(OUT_DIR, { recursive: true });
    fs.writeFileSync(path.join(OUT_DIR, 'drpy-sources.json'), JSON.stringify(drpy.list, null, 2));
    fs.writeFileSync(path.join(OUT_DIR, 'music-sources.json'), JSON.stringify(music.list, null, 2));
    // 漫画：写成空数组（存在但为空）——**不要删文件**，因为 loadComic() 读不到文件
    // 会静默返回 []，跟"文件存在但为空"在控制台上看起来完全一样，
    // 留着文件 + 这里是空数组，至少让"为什么漫画是 0 条"有据可查。
    if (comic.list.length === 0) {
      fs.writeFileSync(path.join(OUT_DIR, 'comic-sources.json'), JSON.stringify([], null, 2));
    } else {
      fs.writeFileSync(path.join(OUT_DIR, 'comic-sources.json'), JSON.stringify(comic.list, null, 2));
    }
    console.log('写入完成 →', OUT_DIR);
  })();
}

main();
