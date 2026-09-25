// ─────────────────────────────────────────────────────────────────────────────
// verify-instance-sources.cjs — 实例源的「端到端验收」
//
// 为什么必须单独有这个：`docs/AI-任务总清单-逐项对账.md` 里把 drpy/venera/musicfree
// 三条链路判为"部分"，原因写得很直白 ——「页面齐、引擎齐，但**无实例源入库**」。
// 也就是说"有引擎"不等于"能用"：`data/*-sources.json` 里到底有没有**能跑出结果**的源，
// 只能真跑一遍才知道。这个脚本就是干这件事，并把结果分成三态：
//   · RUN_OK      真的拉回了条目（引擎+源+网络三者都通）
//   · RUN_EMPTY   跑通了但 0 条（源站改了/关键词没命中 —— 属于"源的问题"，不是引擎坏）
//   · RUN_ERROR   抛错（沙箱里没跑起来 —— 属于"引擎/环境的问题"）
// 这个区分很重要：混在一起看就会得出"引擎不行"的错误结论。
//
// 用法: node server/verify-instance-sources.cjs [--limit 6]
'use strict';
const fs = require('fs');
const path = require('path');
const drpy = require('./engine-drpy.js');
const lx = require('./engine-lx.js');
const music = require('./engine-music.js');

const DATA = path.join(__dirname, 'data');
const limitArg = process.argv.indexOf('--limit');
const ALL = process.argv.includes('--all');
const LIMIT = ALL ? Infinity : (limitArg > -1 ? Number(process.argv[limitArg + 1]) || 6 : 6);
const KEYWORD = process.env.TH_VERIFY_KEYWORD || '斗罗';

function load(f) { try { return JSON.parse(fs.readFileSync(path.join(DATA, f), 'utf8')); } catch (_) { return null; } }

// 出错时把沙箱里源的 print/console 日志尾巴打出来 —— 否则只剩一句
// 干巴巴的 err，根本分不清是"选择器过期"还是"网络被墙"还是"引擎缺能力"。
function tailLogs(logs) {
  if (!logs || !logs.length) return '';
  return '\n        ┆ ' + logs.slice(-3).map(l => String(l).slice(0, 160)).join('\n        ┆ ');
}

async function verifyDrpy(list) {
  console.log(`\n══ drpy 影视源（${list.length} 条，${ALL ? '全量实跑' : '抽前 ' + LIMIT + ' 条实跑'}）══`);
  const rows = [];
  for (const s of (ALL ? list : list.slice(0, LIMIT))) {
    if (s.enabled === false) {
      rows.push({ source: s.name, state: 'SKIP_ACTION', n: 0, ms: 0, err: '导入时已标记不可用' });
      console.log(`  ⏭ ${'SKIP_ACTION'.padEnd(10)}   0条        0ms  ${s.name}`);
      continue;
    }
    const t0 = Date.now();
    let state = 'RUN_ERROR', n = 0, err = '', logs = null;
    try {
      const raw = await drpy.runSource(s.code, 'search', [KEYWORD]);
      logs = raw && raw.logs;
      const ir = drpy.irSearch(raw);
      if (ir.error) { err = ir.error; state = 'RUN_ERROR'; }
      else { n = (ir.items || []).length; state = n > 0 ? 'RUN_OK' : 'RUN_EMPTY'; }
    } catch (e) { err = String(e.message || e); }
    rows.push({ source: s.name, state, n, ms: Date.now() - t0, err: err.slice(0, 90) });
    const tag = state === 'RUN_OK' ? '✅' : state === 'RUN_EMPTY' ? '⚪' : '❌';
    console.log(`  ${tag} ${state.padEnd(10)} ${String(n).padStart(3)}条 ${String(Date.now() - t0).padStart(6)}ms  ${s.name}${err ? '  ← ' + err.slice(0, 70) : ''}${state === 'RUN_ERROR' || state === 'RUN_EMPTY' ? tailLogs(logs) : ''}`);
  }
  return rows;
}

async function verifyMusic(list) {
  console.log(`\n══ 音源（${list.length} 条，${ALL ? '全量实跑' : '抽前 ' + LIMIT + ' 条实跑'}）══`);
  const rows = [];
  for (const s of (ALL ? list : list.slice(0, LIMIT))) {
    // 只声明 musicUrl 的音源**本来就不负责搜歌**，对它们跑 search 得出的"错误"
    // 是假阳性。这里如实标成 SKIP_ACTION，让"音源搜不出歌"这个结论不再被误导。
    const act = s.format === 'lx' ? lx.searchAction(s.actions) : 'search';
    if (!s.enabled || !act) {
      rows.push({ source: s.name, state: 'SKIP_ACTION', n: 0, ms: 0, err: s.enabled ? '未声明搜索能力(仅 ' + (s.actions || []).join('/') + ')' : '导入时探测即失败' });
      console.log(`  ⏭ ${'SKIP_ACTION'.padEnd(10)}   0条        0ms  ${s.name}  ← ${rows[rows.length - 1].err}`);
      continue;
    }
    const t0 = Date.now();
    let state = 'RUN_ERROR', n = 0, err = '', logs = null;
    try {
      const raw = s.format === 'lx'
        ? lx.irSearch(await lx.runLX(s.code, act, { searchKey: KEYWORD, page: 1, limit: 20, type: 'music' }))
        : music.irSearch(await music.runPlugin(s.code, 'search', [KEYWORD, 1, 'music']));
      logs = raw && raw.logs;
      if (raw.error) { err = raw.error; state = 'RUN_ERROR'; }
      else { n = (raw.items || []).length; state = n > 0 ? 'RUN_OK' : 'RUN_EMPTY'; }
    } catch (e) { err = String(e.message || e); }
    rows.push({ source: s.name, state, n, ms: Date.now() - t0, err: err.slice(0, 90) });
    const tag = state === 'RUN_OK' ? '✅' : state === 'RUN_EMPTY' ? '⚪' : '❌';
    console.log(`  ${tag} ${state.padEnd(10)} ${String(n).padStart(3)}条 ${String(Date.now() - t0).padStart(6)}ms  ${s.name}${err ? '  ← ' + err.slice(0, 70) : ''}${state === 'RUN_ERROR' || state === 'RUN_EMPTY' ? tailLogs(logs) : ''}`);
  }
  return rows;
}

(async () => {
  const ds = load('drpy-sources.json');
  const ms = load('music-sources.json');
  const cs = load('comic-sources.json');
  console.log('── data/ 现状 ──');
  console.log('  drpy-sources.json  :', ds ? ds.length + ' 条' : '文件不存在');
  console.log('  music-sources.json :', ms ? ms.length + ' 条' : '文件不存在');
  console.log('  comic-sources.json :', cs ? cs.length + ' 条' : '文件不存在');
  if (!ds || !ms) { console.log('\n先跑 node server/import-instance-sources.cjs'); process.exit(1); }

  const d = await verifyDrpy(ds);
  const m = await verifyMusic(ms);

  const sum = (rows) => ({
    RUN_OK: rows.filter(r => r.state === 'RUN_OK').length,
    RUN_EMPTY: rows.filter(r => r.state === 'RUN_EMPTY').length,
    RUN_ERROR: rows.filter(r => r.state === 'RUN_ERROR').length,
    SKIP_ACTION: rows.filter(r => r.state === 'SKIP_ACTION').length,
  });
  console.log('\n── 汇总 ──');
  console.log('  drpy :', JSON.stringify(sum(d)));
  console.log('  music:', JSON.stringify(sum(m)));
  const anyOk = d.some(r => r.state === 'RUN_OK') || m.some(r => r.state === 'RUN_OK');
  console.log(anyOk ? '\n结论: 至少一条源能真正拉回条目 → 引擎与源链路是通的（RUN_EMPTY/RUN_ERROR 属单源质量，交给健康度自动摘除处理）'
                    : '\n结论: 抽样里没有一条拉回条目 —— 需要看是网络被拦还是引擎问题（RUN_ERROR 的 err 会说明）');
})();
