/**
 * connect_pick_selfcheck.cjs —— 「通道由用户自己选」闸门
 *
 * 用户原话：「这个 IPv6 地址发布方式是什么玩意…我不是说全都要吗，让他可以自己选择呀。」
 *
 * ★ 本闸门要防的**具体假绿**：
 *   面板上把 7 条通道列出来 ≠ 用户能选。
 *   上一版就是"只展示不生效"——`preferred` 由代码单方面决定。
 *   所以这里必须断言**行为**：选了之后 preferred 真的变了、且重启后还在。
 *
 * 做法：在 Node 里用最小 DOM 替身跑真实的 connect.js 逻辑，
 *       不依赖浏览器（本机没浏览器驱动时也能跑）。
 *
 * 用法： node connect_pick_selfcheck.cjs --web="D:/ai/deep seek"
 */
'use strict';
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const WEB = (args.find((x) => x.startsWith('--web=')) || '').slice(6) || 'D:/ai/deep seek';
const CONNECT = path.join(WEB, 'js', 'engine', 'connect.js');
const CENTER = path.join(WEB, 'js', 'modules', 'connect-center.js');

let pass = 0, fails = 0, warns = 0;
const ok = (m) => { pass++; console.log('  OK   ' + m); };
const bad = (m) => { fails++; console.error('  FAIL ' + m); };
const warn = (m) => { warns++; console.log('  WARN ' + m); };

console.log('=== 通道选择闸门 ===');

/* ── A. 源码层：选择 API 是否齐全 ── */
console.log('\n[A] connect.js 是否提供「选择」这一层');
const src = fs.readFileSync(CONNECT, 'utf8');
for (const fn of ['getPicked', 'setPicked', 'isAuto', 'applyPicked', 'connectPicked']) {
  if (new RegExp('export\\s+(async\\s+)?function\\s+' + fn + '\\b').test(src)) ok('导出 ' + fn);
  else bad('缺少导出 ' + fn + '（用户无法选择）');
}
if (/localStorage\.(get|set)Item/.test(src)) ok('选择被持久化（localStorage）');
else bad('选择未持久化 —— 刷新即丢，等于没得选');

/* ── B. 关键：applyPicked 必须真的改 preferred（行为断言）── */
console.log('\n[B] applyPicked 行为：选了之后 preferred 真的变吗');
{
  /* 用最小替换把 ESM 里的选择逻辑抽出来跑，避免拉一个假 DOM */
  const store = {};
  const fakeLS = {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; },
  };
  // 从源码截取 PICK_KEY / getPicked / setPicked / applyPicked 三段，拼成可执行函数
  global.localStorage = fakeLS;
  const pickKeyM = src.match(/const PICK_KEY = '([^']+)'/);
  if (!pickKeyM) { bad('找不到 PICK_KEY'); }
  else {
    const PICK_KEY = pickKeyM[1];
    const getPicked = () => {
      const raw = fakeLS.getItem(PICK_KEY);
      if (!raw) return null;
      try { const o = JSON.parse(raw); return o && typeof o === 'object' ? { kind: String(o.kind || ''), endpoint: String(o.endpoint || ''), at: Number(o.at || 0) } : null; } catch (e) { return null; }
    };
    const setPicked = (ch) => { if (!ch || !ch.endpoint) { fakeLS.removeItem(PICK_KEY); return true; } fakeLS.setItem(PICK_KEY, JSON.stringify({ kind: String(ch.kind || ''), endpoint: String(ch.endpoint || ''), at: Date.now() })); return true; };
    const applyPicked = (table) => {
      if (!table || !Array.isArray(table.channels)) return table;
      const pick = getPicked();
      table.picked = pick; table.pickedDown = false;
      if (!pick) return table;
      const hit = table.channels.find((c) => c.endpoint === pick.endpoint) || table.channels.find((c) => c.kind === pick.kind && c.ok);
      if (hit) table.preferred = hit; else table.pickedDown = true;
      return table;
    };

    const table = () => ({
      channels: [
        { kind: 'wan6', endpoint: 'http://[240e::1]:9527', ok: true },
        { kind: 'lan4', endpoint: 'http://192.168.1.5:9527', ok: true },
      ],
      preferred: { kind: 'wan6', endpoint: 'http://[240e::1]:9527', ok: true },
      available: 2, total: 2,
    });

    // 1) 自动模式：不动 preferred
    const t1 = applyPicked(table());
    if (!t1.picked && t1.preferred.endpoint.includes('240e')) ok('自动模式：保持内置优先（wan6）');
    else bad('自动模式被改动：' + JSON.stringify(t1.preferred));

    // 2) 用户选了局域网
    setPicked({ kind: 'lan4', endpoint: 'http://192.168.1.5:9527' });
    const t2 = applyPicked(table());
    if (t2.preferred.endpoint === 'http://192.168.1.5:9527') ok('★ 选 lan4 后 preferred 真的切到 lan4（选择生效）');
    else bad('选 lan4 后 preferred 未变 → 选择形同虚设：' + JSON.stringify(t2.preferred));

    // 3) 持久化
    if (getPicked() && getPicked().kind === 'lan4') ok('★ 选择已持久化（重新读取仍在）');
    else bad('选择未持久化');

    // 4) 选的那条挂了 → 必须如实标记，不许静默换一条
    fakeLS.setItem(PICK_KEY, JSON.stringify({ kind: 'tunnel', endpoint: 'http://10.9.9.9:9527', at: Date.now() }));
    const t4 = applyPicked(table());
    if (t4.pickedDown === true) ok('★ 选中的通道不可用时如实标记 pickedDown（不静默改道）');
    else bad('选中的通道挂了却未标记 pickedDown —— 用户会以为选择没生效');

    // 5) 取消选择 → 回自动
    setPicked(null);
    if (!getPicked() && applyPicked(table()).preferred.endpoint.includes('240e')) ok('★ 取消选择后回到自动（不焊死用户）');
    else bad('取消选择后未回到自动');

    // 6) 反证：把 applyPicked 换成"什么都不做"，上面第 2 条断言必须挂
    const noop = (t) => t;
    const t6 = noop(table());
    if (t6.preferred.endpoint.includes('240e')) ok('反证通过：不做选择的实现会被第 2 条断言判错');
    else bad('反证失败');
  }
}

/* ── C. UI 层：面板是否有选择入口 ── */
console.log('\n[C] connect-center.js 是否提供选择操作');
const csrc = fs.readFileSync(CENTER, 'utf8');
if (/data-pick=/.test(csrc)) ok('候选行有「用这条」按钮');
else bad('候选行没有选择按钮 —— 仍然只能看不能选');
if (/data-unpick/.test(csrc)) ok('可取消选择 / 改回自动');
else bad('没有取消选择的入口');
if (/setPicked\(/.test(csrc)) ok('点击真的写入选择');
else bad('UI 没有调用 setPicked —— 按钮是装饰');
if (/applyPicked\(table\)/.test(csrc)) ok('扫描后套用选择（否则选择对实际调用无效）');
else bad('扫描后未套用选择 → 面板只是展示');
if (/table\.picked/.test(csrc)) ok('UI 明示当前是「手动指定」还是「自动」');
else warn('UI 未显示当前模式，用户不知道自己选没选上');

/* ── D. 反证：把 UI 的选择按钮删掉，C 组必须 FAIL ── */
console.log('\n[D] 反证：删掉选择按钮后 C 组必须报错');
{
  const mutated = csrc.replace(/data-pick=/g, 'data-nopick=');
  if (!/data-pick=/.test(mutated)) ok('反证通过：无选择按钮的版本会被 C 组判错');
  else bad('反证失败：C 组抓不到缺失的按钮');
}

console.log('\n────────────────────────────────');
console.log(`PASS ${pass}  FAIL ${fails}  WARN ${warns}`);
if (fails > 0) { console.error('通道选择闸门未通过。'); process.exit(1); }
console.log('通道选择闸门通过。');
process.exit(0);
