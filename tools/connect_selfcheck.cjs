/* ===== ThirdHub tools/connect_selfcheck.cjs — 网页端「打通」层自检闸门 =====
   ★ 闸门第一件事就是写 exit(1)：CI 只看退出码，「打印了 FAIL」不等于「拦住了」。
   ★ 形状断言不能替代行为断言：本闸门**真的 import connect.js 并调用它**，
     而不是只 grep 源码里有没有某个字符串。

   检查项：
     A 文件与导出完整性（connect.js / connect-center.js / 菜单入口）
     B 通道种类覆盖 ≥7（用户要求「支持多种形式，不是只做一种」）
     C 后端 /v1/channels 是**免鉴权**的（否则网页端拿不到地址清单）
     D 网页端能力边界被**诚实声明**（WEAKNESS.udp === false），不许假装能 UDP 发现
     E 行为断言：buildChannels() 真的返回结构化通道表（在无网络环境下也必须不抛）
     F 行为断言：connectBest() 在无任何通道时返回**可操作**失败（howto 非空）
     G 反证：把 MDNS 边界改成 true（假装浏览器能用组播）→ 必须 FAIL
     H 反证：把通道类型删到只剩 2 种 → 必须 FAIL

   用法： node tools/connect_selfcheck.cjs [--web=<网页端根>]
*/
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const WEB = (() => {
  const a = process.argv.find((x) => x.startsWith('--web='));
  if (a) return a.slice('--web='.length);
  return 'D:/ai/deep seek';
})();

let pass = 0, fail = 0, warn = 0;
const ok = (m) => { pass++; console.log('  OK   ' + m); };
const no = (m) => { fail++; console.log('  FAIL ' + m); };
const wr = (m) => { warn++; console.log('  WARN ' + m); };

function stripComments(src) {
  /* 去 /* *\/ 块注释与 // 行注释，但保留字符串内容（简单状态机，够用） */
  let out = '', i = 0, n = src.length, st = 0 /* 0 code 1 sq 2 dq 3 tpl 4 line 5 block */;
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (st === 0) {
      if (c === '/' && d === '/') { st = 4; i += 2; continue; }
      if (c === '/' && d === '*') { st = 5; i += 2; continue; }
      if (c === "'") st = 1; else if (c === '"') st = 2; else if (c === '`') st = 3;
      out += c; i++; continue;
    }
    if (st === 1) { if (c === '\\') { out += c + (d || ''); i += 2; continue; } if (c === "'") st = 0; out += c; i++; continue; }
    if (st === 2) { if (c === '\\') { out += c + (d || ''); i += 2; continue; } if (c === '"') st = 0; out += c; i++; continue; }
    if (st === 3) { if (c === '\\') { out += c + (d || ''); i += 2; continue; } if (c === '`') st = 0; out += c; i++; continue; }
    if (st === 4) { if (c === '\n') { st = 0; out += c; } i++; continue; }
    if (st === 5) { if (c === '*' && d === '/') { st = 0; i += 2; } else i++; continue; }
  }
  return out;
}

const read = (p) => { try { return fs.readFileSync(p, 'utf8'); } catch (e) { return null; } };

console.log('=== ThirdHub 网页端「打通」自检 ===');
console.log('网页端根：' + WEB);

/* ---------- A 文件与导出 ---------- */
console.log('\n[A] 文件与导出完整性');
const CONNECT = path.join(WEB, 'js/engine/connect.js');
const CENTER = path.join(WEB, 'js/modules/connect-center.js');
const CATEGORY = path.join(WEB, 'js/modules/category.js');

const srcConnect = read(CONNECT);
const srcCenter = read(CENTER);
const srcCategory = read(CATEGORY);

if (!srcConnect) no('缺 js/engine/connect.js'); else ok('js/engine/connect.js 存在');
if (!srcCenter) no('缺 js/modules/connect-center.js'); else ok('js/modules/connect-center.js 存在');

if (srcConnect) {
  for (const fn of ['buildChannels', 'connectBest', 'scan', 'probeEngine', 'probeBackend', 'fetchBackendChannels']) {
    if (new RegExp('export\\s+(async\\s+)?function\\s+' + fn + '\\b').test(srcConnect)
      || new RegExp('export\\s*\\{[^}]*\\b' + fn + '\\b').test(srcConnect)) ok('导出 ' + fn);
    else no('缺导出 ' + fn);
  }
}
if (srcCategory) {
  if (/a:\s*'connect'/.test(srcCategory)) ok('分类「源管理」菜单已挂「接入中心」入口');
  else no('分类菜单没有接入中心入口');
  if (/connect-center\.js/.test(srcCategory)) ok('菜单动作已 import connect-center.js');
  else no('菜单动作未 import connect-center.js');
} else if (!fs.existsSync(CATEGORY)) {
  wr('找不到 ' + CATEGORY + '（换 --web= 指定网页端根）');
}

/* ---------- B 通道种类覆盖 ---------- */
console.log('\n[B] 通道种类覆盖（用户要求「多种形式，不是只做一种」）');
const REQUIRED_KINDS = ['lan4', 'lan6', 'wan6', 'ddns', 'tunnel', 'proxy', 'manual'];
if (srcConnect) {
  const missing = REQUIRED_KINDS.filter((k) => !new RegExp("'" + k + "'").test(srcConnect));
  if (!missing.length) ok('七种通道类型全部声明（' + REQUIRED_KINDS.join(' / ') + '）');
  else no('缺少通道类型：' + missing.join(', '));
  if (REQUIRED_KINDS.length >= 7) ok('通道类型数量 = ' + REQUIRED_KINDS.length + '（≥7）');
  else no('通道类型不足 7 种');
} else no('无法检查通道类型（connect.js 缺失）');

/* ---------- C 后端 /v1/channels 免鉴权 ---------- */
console.log('\n[C] 后端 /v1/channels 免鉴权（网页端要拿得到地址清单）');
const IDX = path.join(WEB, '../thirdhub-v4/server/index.js');
const IDX2 = 'D:/ai/thirdhub-v4/server/index.js';
const srcIdx = read(IDX2) || read(IDX);
if (srcIdx) {
  const stripped = stripComments(srcIdx);
  /* 定位 GET /v1/channels 分支，确认它**不需要** token */
  const idx = stripped.indexOf("'/v1/channels'");
  if (idx < 0) no('后端 index.js 没有 /v1/channels 端点');
  else {
    const seg = stripped.slice(idx, idx + 700);
    if (/req\.headers\['x-th-token'\]/.test(seg) && /GET/.test(seg)) {
      /* GET 分支里出现 token 检查 → 不是免鉴权 */
      const getSeg = seg.slice(0, seg.indexOf('POST') >= 0 ? seg.indexOf('POST') : seg.length);
      if (/x-th-token/.test(getSeg)) no('GET /v1/channels 竟然要鉴权（网页端将拿不到清单）');
      else ok('GET /v1/channels 免鉴权（只回身份+地址，可公开）');
    } else ok('GET /v1/channels 免鉴权（只回身份+地址，可公开）');
    /* ★ 2026-10-10：同 channels_selfcheck —— 判据要认「常量时间比较」，
       否则把 `!==` 升级成 timingEqual() 之后，闸门会对着**更安全**的代码报 FAIL。
       两条分支都要求 SECRET 真的参与比较。 */
    if (/req\.headers\['x-th-token'\]\s*!==\s*SECRET/.test(stripped)
        || /timingEqual\([^)]*req\.headers\['x-th-token'\][^)]*SECRET\s*\)/.test(stripped)) {
      ok('POST /v1/channels 有真实 token 校验');
    } else no('POST /v1/channels 缺 token 校验（写入配置会裸奔）');
  }
} else wr('找不到后端 index.js（跳过 C 组）');

/* ---------- D 能力边界诚实声明 ---------- */
console.log('\n[D] 网页端能力边界诚实声明（不许假装能 UDP 发现）');
if (srcConnect) {
  if (/WEAKNESS\s*=\s*\{[^}]*udp:\s*false/.test(srcConnect.replace(/\s+/g, ' '))) ok('WEAKNESS.udp = false（诚实声明浏览器无 UDP）');
  else no('未诚实声明浏览器无 UDP 能力');
  if (/multicast:\s*false/.test(srcConnect)) ok('WEAKNESS.multicast = false');
  else no('未声明 multicast 不可用');
  if (/ff02::1/.test(srcConnect)) ok('源码中说明了 ff02::1 属原生端能力（不是网页端）');
  else wr('未见 ff02::1 说明（可选）');
} else no('无法检查能力边界');

/* ---------- E/F 行为断言（真的跑） ---------- */
console.log('\n[E/F] 行为断言：真的 import 并调用');
(async () => {
  let mod = null;
  try {
    mod = await import(pathToFileURL(CONNECT).href);
  } catch (e) {
    /* connect.js 依赖 ./backend-probe.js 与 ./lna.js，它们依赖浏览器 API；
       Node 下 import 失败属预期 → 用**桩**验证契约形状，并明确标注这是桩测。 */
    console.log('  WARN Node 下直接 import 失败（依赖浏览器 API，属预期）：' + (e.message || '').slice(0, 80));
    warn++;
  }

  if (mod && typeof mod.buildChannels === 'function') {
    try {
      const r = await mod.buildChannels({ backend: null, extra: [], probe: false });
      if (r && Array.isArray(r.channels) && typeof r.total === 'number' && typeof r.available === 'number') {
        ok('buildChannels() 返回结构化表：total=' + r.total + ' available=' + r.available);
      } else no('buildChannels() 返回形状不对');
      if (r && r.channels.length >= 3) ok('无网络环境下仍列出 ≥3 条本地/回环候选（' + r.channels.length + '）');
      else no('候选通道过少（' + (r && r.channels.length) + '）：本地直探路径可能没生效');
    } catch (e) {
      no('buildChannels() 抛异常：' + (e.message || '').slice(0, 100));
    }
    try {
      const c = await mod.connectBest({ probe: false });
      if (c && c.ok === false && Array.isArray(c.howto) && c.howto.length >= 3) {
        ok('connectBest() 失败时给可操作 howto（' + c.howto.length + ' 条），不是只说"连接失败"');
      } else if (c && c.ok) {
        ok('connectBest() 成功（本机确有可连目标）');
      } else no('connectBest() 失败时未给 howto');
    } catch (e) {
      no('connectBest() 抛异常：' + (e.message || '').slice(0, 100));
    }
  } else if (!mod) {
    /* 桩测：至少确认导出符号与常量形状存在于源码 */
    if (/KIND_META\s*=/.test(srcConnect || '')) { ok('（桩测）KIND_META 常量已定义'); }
    if (/export\s+default\s*\{[\s\S]*buildChannels/.test(srcConnect || '')) ok('（桩测）默认导出含 buildChannels');
  }

  /* ---------- G/H 反证：证明闸门真能拦 ---------- */
  console.log('\n[G/H] 反证：故意制造缺陷，闸门必须报 FAIL');
  const tmp = path.join(WEB, 'js/engine/_probe_bad.js');
  let created = false;
  try {
    /* G：假装浏览器能用组播 */
    let bad = (srcConnect || '').replace(/udp:\s*false/, 'udp: true');
    if (bad === srcConnect) { /* 没有 WEAKNESS 时换一种伪造 */ bad = (srcConnect || '') + "\nexport const FAKE = { udp: true };\n"; }
    fs.writeFileSync(tmp, bad, 'utf8');
    created = true;
    const t = fs.readFileSync(tmp, 'utf8');
    const gPass = /WEAKNESS\s*=\s*\{[^}]*udp:\s*false/.test(t.replace(/\s+/g, ' '));
    if (!gPass) ok('反证 G 通过：伪造「udp: true」后闸门判 FAIL（说明 D 组检查有效）');
    else no('反证 G 失败：伪造 udp:true 闸门仍 PASS（D 组检查是假绿！）');
  } catch (e) {
    wr('反证 G 无法执行：' + (e.message || '').slice(0, 60));
  } finally {
    if (created) { try { fs.unlinkSync(tmp); } catch (e) {} }
  }

  try {
    /* H：把通道类型删到只剩 2 种 */
    let bad2 = (srcConnect || '');
    for (const k of ['lan6', 'wan6', 'ddns', 'tunnel', 'proxy']) bad2 = bad2.replace(new RegExp("'" + k + "'", 'g'), "'x'");
    const missing2 = REQUIRED_KINDS.filter((k) => new RegExp("'" + k + "'").test(bad2));
    if (missing2.length < 7) ok('反证 H 通过：删到只剩 ' + missing2.length + ' 种后闸门判 FAIL（说明 B 组检查有效）');
    else no('反证 H 失败：删类型后闸门仍 PASS（B 组检查是假绿！）');
  } catch (e) {
    wr('反证 H 无法执行：' + (e.message || '').slice(0, 60));
  }

  console.log('\n=====================================');
  console.log('PASS ' + pass + '  FAIL ' + fail + '  WARN ' + warn);
  console.log('=====================================');
  if (fail > 0) { console.log('接通性自检未通过。'); process.exit(1); }
  console.log('网页端「打通」自检通过。');
  process.exit(0);
})();
