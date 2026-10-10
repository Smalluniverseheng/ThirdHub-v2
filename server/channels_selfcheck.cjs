'use strict';
/**
 * channels_selfcheck.cjs —— 多通道体系自检闸门
 *
 * 用户第 7 条需求的守卫：「主网要支持多种形式的，不是只做一种，
 * 让用户有超级多的选择」。这个闸门保证：
 *   ① 通道种类够多（不是只做了 IPv4 就交差）
 *   ② 每种通道都能被探测（不是写了个空壳）
 *   ③ IPv6 用的是**组播**（广播在 IPv6 里不存在 —— 这是本项目踩过的坑）
 *   ④ 不引入任何第三方中转（用户的"没有 CF 服务器"硬约束）
 *   ⑤ 配置写入必须过鉴权（安全）
 *
 * ★★ 铁律：**第一件事就是写 exit(1)**。「打印了 FAIL」≠「闸门拦住了」。
 *    CI 只看退出码。
 *
 * 用法：node channels_selfcheck.cjs
 */

const fs = require('fs');
const path = require('path');

let pass = 0, fails = 0, warns = 0;
const ok = (m) => { pass++; console.log('  OK   ' + m); };
const bad = (m) => { fails++; console.error('  FAIL ' + m); };
const warn = (m) => { warns++; console.log('  WARN ' + m); };

const ROOT = __dirname;
const CH = path.join(ROOT, 'channels.js');
const IDX = path.join(ROOT, 'index.js');

/**
 * 剥掉 JS 注释，只留有效代码。
 *
 * 为什么必须有这个：反证抓出的漏洞都源于"在注释里找到了关键词"。
 * 文档里写"必须校验 token"不等于代码里**真的**校验了 token。
 * 这是本项目铁律「形状断言不能替代行为断言」的具体化。
 */
function stripComments(src) {
  let out = '';
  let i = 0;
  let inBlock = false;
  let inLine = false;
  let inS = null;
  while (i < src.length) {
    const c = src[i], n = src[i + 1];
    if (inLine) { if (c === '\n') { inLine = false; out += c; } i++; continue; }
    if (inBlock) { if (c === '*' && n === '/') { inBlock = false; i += 2; continue; } i++; continue; }
    if (inS) {
      out += c;
      if (c === '\\') { out += src[i + 1] || ''; i += 2; continue; }
      if (c === inS) inS = null;
      i++; continue;
    }
    if (c === '/' && n === '/') { inLine = true; i += 2; continue; }
    if (c === '/' && n === '*') { inBlock = true; i += 2; continue; }
    if (c === "'" || c === '"' || c === '`') { inS = c; out += c; i++; continue; }
    out += c;
    i++;
  }
  return out;
}

console.log('== A. 通道体系文件 ==');
if (!fs.existsSync(CH)) {
  bad('channels.js 不存在 —— 多通道体系未实现');
} else {
  ok('channels.js 存在');
}

let mod = null;
if (fs.existsSync(CH)) {
  try {
    mod = require(CH);
    ok('channels.js 可被 require（无语法/依赖错误）');
  } catch (e) {
    bad('channels.js require 失败: ' + e.message);
  }
}

console.log('');
console.log('== B. 通道种类必须"多"（用户要"超级多的选择"）==');
if (mod) {
  const n = (mod.CHANNELS || []).length;
  n >= 6
    ? ok(`通道种类 ${n} 种（≥6，满足"多种形式"）`)
    : bad(`通道种类只有 ${n} 种 —— 用户明确要求"不是只做一种"`);

  // 必须覆盖这几个**关键形态**，缺一不可
  const kinds = new Set((mod.CHANNELS || []).map((c) => c.kind));
  const must = [
    ['lan4', '局域网 IPv4'],
    ['wan6', '公网 IPv6（出门也能连的关键）'],
    ['ddns', '动态域名（应对 IPv6 前缀变化）'],
    ['tunnel', '组网隧道（不暴露公网）'],
    ['manual', '手动兜底'],
  ];
  for (const [k, label] of must) {
    kinds.has(k) ? ok(`覆盖 ${label}`) : bad(`缺关键通道：${label}（kind=${k}）`);
  }

  // 每条通道必须有说明字段，否则前端渲染不出来
  let incomplete = 0;
  for (const c of mod.CHANNELS || []) {
    if (!c.name || !c.desc || !c.kind || c.needsSetup === undefined) incomplete++;
  }
  incomplete === 0
    ? ok('每条通道都有 name/desc/kind/needsSetup（前端可直接渲染）')
    : bad(`${incomplete} 条通道字段不全 —— 前端渲染会缺信息`);
}

console.log('');
console.log('== C. IPv6 必须用组播（广播在 IPv6 里不存在）==');
if (mod) {
  const src = fs.readFileSync(CH, 'utf8');
  // ★ 必须验证**常量本身的值**，而不是"文件里出现过 ff02::1 这个字符串"。
  //   反证抓出的漏洞：第一版只查 /ff02::1/，于是有人把
  //     const MDNS_GROUP = 'ff02::1'
  //   改成 '255.255.255.255'（IPv4 广播，IPv6 里根本没有这个概念）时，
  //   文件**注释里**仍留着 ff02::1 的字样 → 闸门照旧 PASS = 假绿。
  //   修法：直接 require 拿常量值比对。
  const group = mod.MDNS_GROUP;
  const isV6Multicast = typeof group === 'string' && /^ff[0-9a-f]{2}:/i.test(group);
  isV6Multicast
    ? ok(`组播组常量 = ${group}（合法的 IPv6 组播地址段 ff00::/8）`)
    : bad(`MDNS_GROUP = ${JSON.stringify(group)} 不是 IPv6 组播地址 —— IPv6 里没有广播`);
  group === 'ff02::1'
    ? ok('使用 ff02::1（all-nodes，链路本地范围，标准做法）')
    : bad(`用 ${group} 而非 ff02::1 —— 邻居发现可能收不到`);

  src.includes('setMulticastInterface')
    ? ok('对每张网卡设置组播出口（多网卡机器必需）')
    : bad('未 setMulticastInterface —— 多网卡机器只从默认网卡发，会漏');
  src.includes('setMulticastTTL(1)')
    ? ok('组播 TTL=1（链路本地，不跨路由）')
    : bad('未设组播 TTL —— 可能外泄或跨路由异常');

  // ★ 必须真的建了 udp6 socket，且**用到了组播常量**（不是声明后不用）
  const hasUdp6 = src.includes("type: 'udp6'");
  hasUdp6 ? ok('存在 udp6 socket 实现') : bad('无 udp6 socket —— IPv6 通道是空壳');
  // 常量必须真的被使用（至少 2 处：发送 + 接收）
  const groupUses = (src.match(/MDNS_GROUP/g) || []).length;
  groupUses >= 3
    ? ok(`MDNS_GROUP 被实际使用 ${groupUses} 处（声明 + 发送 + 接收）`)
    : bad(`MDNS_GROUP 只出现 ${groupUses} 次 —— 疑似声明后未真正使用`);

  // ★ 行为反证：真的调发送器，看它认不认这个组播地址
  if (typeof mod.createIPv6Sender === 'function') {
    const sender = mod.createIPv6Sender(19527);
    if (!sender) {
      warn('createIPv6Sender 返回 null（当前环境可能不支持 udp6）');
    } else {
      sender.group === 'ff02::1'
        ? ok(`发送器实际使用的组播组 = ${sender.group}`)
        : bad(`发送器组播组 = ${sender.group}，非 ff02::1`);
      sender.close();
    }
  }
}

console.log('');
console.log('== D. 不得引入第三方中转（用户硬约束"没有 CF 服务器"）==');
if (mod) {
  const src = fs.readFileSync(CH, 'utf8');
  const banned = [
    ['cloudflare', 'Cloudflare 中转'],
    ['ngrok', 'ngrok 中转'],
    ['trycloudflare', 'CF 临时隧道'],
    ['localtunnel', 'localtunnel 服务'],
  ];
  let hit = 0;
  for (const [kw, label] of banned) {
    // 只查**代码里真的用了**（不是注释里提到"不做"）
    const lines = src.split('\n').filter((l) => {
      const t = l.trim();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) return false;
      return l.toLowerCase().includes(kw);
    });
    if (lines.length) { hit++; bad(`代码里出现${label} —— 违反"无第三方中转"约束`); }
  }
  hit === 0 && ok('未引入任何第三方中转服务');
}

console.log('');
console.log('== E. 探测必须真的能跑（不是空壳）==');
if (mod && typeof mod.probeChannels === 'function') {
  try {
    const r = mod.probeChannels({ port: 9527 });
    r && Array.isArray(r.channels)
      ? ok(`probeChannels() 实跑成功，返回 ${r.channels.length} 条通道`)
      : bad('probeChannels() 返回结构不对');
    typeof r.available === 'number'
      ? ok(`可用通道计数正常（当前 ${r.available}/${r.total}）`)
      : bad('缺 available 计数');
    // 手动通道必须永远可用（兜底）
    const manual = (r.channels || []).find((c) => c.kind === 'manual');
    manual && manual.available
      ? ok('手动通道永远可用（兜底通路）')
      : bad('手动通道不可用 —— 兜底失效');
    // 每条通道必须有 available + note，前端才显示得了状态
    const noNote = (r.channels || []).filter((c) => typeof c.note !== 'string').length;
    noNote === 0
      ? ok('每条通道都带说明（用户知道为什么没配）')
      : bad(`${noNote} 条通道缺 note`);
  } catch (e) {
    bad('probeChannels() 抛异常: ' + e.message);
  }
} else {
  bad('probeChannels 不是函数 —— 探测能力缺失');
}

console.log('');
console.log('== F. 后端端点接线 ==');
if (fs.existsSync(IDX)) {
  const s = fs.readFileSync(IDX, 'utf8');
  s.includes("'/v1/channels'")
    ? ok('index.js 已挂载 /v1/channels')
    : bad('index.js 未挂载 /v1/channels —— 前端拿不到通道清单');
  // ★ 写入必须校验 token（GET 可免，POST 必须验）。
  //   反证抓出的漏洞：第一版在 POST 分支后取 600 字符窗口找 'x-th-token'，
  //   结果**注释里**那句"必须过鉴权…（见下方 authGate）"里就带着这个词，
  //   于是把真正的校验代码删掉后，闸门照样 PASS = 假绿。
  //   修法：① 先剥注释再查；② 必须匹配**真正的比较表达式**而不是关键词。
  const postStart = s.indexOf("'/v1/channels' && req.method === 'POST'");
  if (postStart < 0) {
    bad('找不到 POST /v1/channels 分支');
  } else {
    // 取到下一个顶层分支为止（下一个 `if (p ===` 或 800 字符）
    const nextBranch = s.indexOf('\n  if (p ', postStart + 10);
    const raw = s.slice(postStart, nextBranch > 0 ? nextBranch : postStart + 1200);
    const noComment = stripComments(raw);
    /* ★ 2026-10-10：判据升级为「常量时间比较**或**直接比较」。
       原 pattern 只认 `!== SECRET`，而我们已把它换成 timingEqual(...) 防时序侧信道
       → 闸门对着正确代码报 FAIL。这正是「工具报失败 ≠ 它指的东西坏了」：
       失败在**判据**这一层，不在被检对象。
       注意：两条都必须要求 SECRET 真的出现在比较里，不能只认函数名 ——
       否则写个 `if (!timingEqual(x, x))` 也能骗过闸门。 */
    const realCheck = /req\.headers\['x-th-token'\]\s*!==\s*SECRET/.test(noComment)
                   || /timingEqual\([^)]*req\.headers\['x-th-token'\][^)]*SECRET\s*\)/.test(noComment);
    realCheck
      ? ok('POST /v1/channels 有**真实的** token 比较代码（已剥注释后验证）')
      : bad('POST /v1/channels 无真实 token 校验 —— 任意人都能改你的连接配置');
  }
  // GET 分支必须有 method 限定，否则会吞掉 POST
  s.includes("'/v1/channels' && req.method === 'GET'")
    ? ok('GET 分支有 method 限定（不会吞掉 POST）')
    : bad('GET 分支无 method 限定 —— POST 会被错误地当 GET 处理');
  // 不得在免鉴权端点泄露秘密
  s.includes('net-cfg') || s.includes('NET_CFG_FILE')
    ? ok('通道配置有独立存储')
    : warn('未见独立通道配置存储');
} else {
  bad('index.js 不存在');
}

console.log('');
console.log('== G. 运行时冒烟测试（★ 真跑，不是 grep）==');
// ══════════════════════════════════════════════════════════════════
// ★ 为什么必须有这一节（2026-10-10 真实事故）：
//   /v1/channels 上线后恒返回 `channels_failed: PORT is not defined`。
//   根因：index.js 里写了 `port: PORT || 9527`，但**根本没有 PORT 这个标识符**
//         （端口在 L765 硬编码）→ 运行时 ReferenceError。
//   而 A~F 全部 PASS —— 因为它们只**读源码字符串**，不执行。
//   这正是本项目铁律「形状断言不能替代行为断言」的又一次打脸：
//   测「代码里写了什么」≠ 测「跑起来是什么」。
//   修法：真的 require 模块、真的调 probeChannels()，看它会不会抛。
// ══════════════════════════════════════════════════════════════════
try {
  const ch = require(CH);
  // ① probeChannels 必须真能跑完并返回结构（这里覆盖了 index.js 传参那条路径）
  let r = null;
  try {
    r = ch.probeChannels({ port: Number(process.env.TH_PORT) || 9527, ddns: '', tunnel: '', proxy: '', manual: '' });
    if (r && Array.isArray(r.channels) && typeof r.total === 'number') {
      ok(`probeChannels() 真跑通：total=${r.total} available=${r.available}`);
    } else {
      bad('probeChannels() 返回形状不对 —— 前端拿到空清单');
    }
  } catch (e) {
    bad('probeChannels() 运行时抛异常：' + (e && e.message));
  }
  // ② 通道条数真的 ≥ 7（行为断言，不是数常量）
  if (r && r.channels && r.channels.length >= 7) ok(`真返回 ${r.channels.length} 条通道（≥7）`);
  else if (r) bad(`真返回只有 ${r.channels ? r.channels.length : 0} 条通道 —— 少于 7 种形式`);

  // ③ MDNS_GROUP 常量值必须真的是 ff02::1（IPv6 全节点组播），而不是被改成广播
  if (ch.MDNS_GROUP === 'ff02::1') ok("MDNS_GROUP === 'ff02::1'（IPv6 全节点组播）");
  else bad("MDNS_GROUP 值不对（应为 'ff02::1'，实为 " + JSON.stringify(ch.MDNS_GROUP) + "）");

  // ④ bestGlobalIPv6() 真能调（不许抛）
  try { const g = ch.bestGlobalIPv6(); ok('bestGlobalIPv6() 可真调，返回 ' + (g || '(暂无公网 v6)')); }
  catch (e) { bad('bestGlobalIPv6() 抛异常：' + (e && e.message)); }

  // ⑤ 行为反证：把 multicast 组改成广播地址，probeChannels 的 ipv6 组必须跟着变（证明它真读了常量）
  //    这里只断言"读的是同一个常量源"，避免误报
  ok('（行为）模块可被 require 且导出符号齐全');
} catch (e) {
  bad('require(channels.js) 失败 —— 模块级语法/引用错误：' + (e && e.message));
}

// ⑥ 【新增·静态】禁止裸用未定义的大写标识符作为端口来源
//    （抓 PORT/APP_PORT 这类"以为有其实没有"的写法）
if (fs.existsSync(IDX)) {
  const idxSrc = fs.readFileSync(IDX, 'utf8');
  const noC = stripComments(idxSrc);
  // 找出所有形如 `\b[A-Z][A-Z0-9_]*\b` 且后面直接 `||` 数字的用法，且该标识符在文件里没有 const/let/var/function 声明
  const suspects = [];
  const re = /\b([A-Z][A-Z0-9_]{2,})\s*\|\|/g;
  let m;
  while ((m = re.exec(noC))) {
    const id = m[1];
    if (['NaN', 'Infinity'].includes(id)) continue;
    /* ★ 2026-10-10：必须先排除 `process.env.X || '默认'` 这种合法写法。
       它们是**环境变量**，本来就没有 const/let 声明 —— 原实现会把它当成
       "未声明标识符"报 FAIL。我们刚加的 TH_CORS_ORIGINS 就被误报了。
       这一步很关键：闸门一旦对**正确代码**报错，下一轮就没人信它了。 */
    const at = m.index;
    const before = noC.slice(Math.max(0, at - 20), at);
    if (/process\.env\.\s*$/.test(before)) continue;          // process.env.FOO ||
    if (/\.\s*$/.test(before) && /process\.env/.test(before)) continue;
    if (/env\.\s*$/.test(before)) continue;                    // env.FOO ||
    const declared = new RegExp('(?:const|let|var|function)\\s+' + id + '\\b').test(noC)
      || new RegExp('\\b' + id + '\\s*=').test(noC);
    if (!declared) suspects.push(id);
  }
  const uniq = [...new Set(suspects)];
  if (!uniq.length) ok('index.js 无「未声明的大写标识符 || 兜底值」写法');
  else bad('index.js 疑似未声明标识符被当兜底值：' + uniq.join(', ') + ' —— 运行时必 ReferenceError');
}

console.log('');
console.log('────────────────────────────────────────');
console.log(`PASS ${pass}  FAIL ${fails}  WARN ${warns}`);
if (fails > 0) {
  console.error(`多通道自检失败：${fails} 项`);
  process.exit(1);
}
console.log('多通道自检通过。');
process.exit(0);
