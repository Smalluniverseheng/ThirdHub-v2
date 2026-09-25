// request-log 单测（不落盘：不调 init()，纯内存）
// 跑法: node server/test_request_log.cjs
'use strict';
const assert = require('assert');
const log = require('./request-log.js');

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + e.message); }
}

t('record 返回带 seq/at 的条目', () => {
  log.clear();
  const e = log.record({ kind: 'search', source: 'SrcA', ok: true, ms: 120, count: 7 });
  assert.strictEqual(e.seq, 1);
  assert.ok(e.at > 0);
  assert.strictEqual(e.count, 7);
});

t('list 默认最新在前', () => {
  log.clear();
  log.record({ kind: 'search', source: 'A', ok: true });
  log.record({ kind: 'search', source: 'B', ok: true });
  const l = log.list();
  assert.strictEqual(l.length, 2);
  assert.strictEqual(l[0].source, 'B');
});

t('按 kind 过滤', () => {
  log.clear();
  log.record({ kind: 'search', source: 'A', ok: true });
  log.record({ kind: 'img', target: 'http://x/y.png', ok: true });
  assert.strictEqual(log.list({ kind: 'img' }).length, 1);
  assert.strictEqual(log.list({ kind: 'search' }).length, 1);
});

t('按 ok 过滤', () => {
  log.clear();
  log.record({ kind: 'search', source: 'A', ok: true });
  log.record({ kind: 'search', source: 'B', ok: false, error: 'timeout' });
  assert.strictEqual(log.list({ ok: false }).length, 1);
  assert.strictEqual(log.list({ ok: false })[0].source, 'B');
});

t('limit 生效且上限被夹住', () => {
  log.clear();
  for (let i = 0; i < 50; i++) log.record({ kind: 'search', source: 'S' + i, ok: true });
  assert.strictEqual(log.list({ limit: 5 }).length, 5);
  assert.strictEqual(log.list({ limit: 10, kind: 'search' }).length, 10);
});

t('环形缓冲不超过容量（有界，不会把进程撑死）', () => {
  log.clear();
  // 注意：`seq` 是模块级自增、**不随 clear() 归零**（它是全局序号，语义上就该单调）。
  // 所以基准要现取，不能假设从 1 开始 —— 第一版测试就栽在这里。
  const base = log.stats().seq;
  const droppedBefore = log.stats().droppedFromRing;
  for (let i = 0; i < log.MEM_MAX + 300; i++) log.record({ kind: 'search', source: 'S', ok: true });
  const s = log.stats();
  assert.strictEqual(s.total, log.MEM_MAX);
  assert.strictEqual(s.droppedFromRing - droppedBefore, 300);
  // 丢的是最老的：内存里最新一条的 seq 应该是 base + MEM_MAX + 300
  assert.strictEqual(log.list({ limit: 1 })[0].seq, base + log.MEM_MAX + 300);
});

t('stats 按 kind / source 聚合出 ok/fail/avgMs', () => {
  log.clear();
  log.record({ kind: 'search', source: 'A', ok: true, ms: 100 });
  log.record({ kind: 'search', source: 'A', ok: true, ms: 300 });
  log.record({ kind: 'search', source: 'B', ok: false, ms: 50, error: 'boom' });
  const s = log.stats();
  assert.strictEqual(s.byKind.search.total, 3);
  assert.strictEqual(s.byKind.search.ok, 2);
  assert.strictEqual(s.byKind.search.fail, 1);
  assert.strictEqual(s.byKind.search.avgMs, 150);
  assert.strictEqual(s.bySource.A.avgMs, 200);
  assert.strictEqual(s.bySource.B.lastError, 'boom');
});

t('长字段被截断（不把内存吃光）', () => {
  log.clear();
  const e = log.record({ kind: 'search', target: 'x'.repeat(2000), source: 'y'.repeat(500), error: 'z'.repeat(900), ok: false });
  assert.strictEqual(e.target.length, 300);
  assert.strictEqual(e.source.length, 120);
  assert.strictEqual(e.error.length, 200);
});

t('timer() 自动计时', () => {
  log.clear();
  const tm = log.timer();
  const e = tm.done({ kind: 'img', target: 'http://a/b.png', ok: true });
  assert.ok(e.ms === null || e.ms >= 0);
  assert.strictEqual(log.list({ kind: 'img' }).length, 1);
});

t('非法输入不崩', () => {
  log.clear();
  assert.strictEqual(log.record(null), null);
  assert.strictEqual(log.record('x'), null);
  assert.strictEqual(log.list({ limit: -5 }).length, 0);
});

t('since/until 时间窗过滤', () => {
  log.clear();
  // 两条记录可能落在**同一毫秒**，那样 since/until 就区分不开 —— 得把时间拉开。
  // 用忙等到毫秒进位，避免把 sleep 引进单测（跑得要快）。
  log.record({ kind: 'search', source: 'A', ok: true });
  const t1 = Date.now();
  while (Date.now() === t1) { /* 等 1ms 进位 */ }
  log.record({ kind: 'search', source: 'B', ok: true });
  const t2 = Date.now();
  assert.strictEqual(log.list({ since: t2 }).length, 1);
  assert.strictEqual(log.list({ since: t2 })[0].source, 'B');
  assert.strictEqual(log.list({ until: t1 }).length, 1);
  assert.strictEqual(log.list({ until: t1 })[0].source, 'A');
  assert.strictEqual(log.list({ since: t1, until: t2 }).length, 2);
});

console.log(`\n结果: pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
