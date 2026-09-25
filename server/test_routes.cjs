// routes.js 单测（纯逻辑，无 IO、无引擎依赖）
// 跑法: node server/test_routes.cjs
'use strict';
const assert = require('assert');
const { ROUTES, route, pickSources, HealthGate } = require('./routes.js');

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + e.message); }
}

console.log('── 路由表 ──');
t('四类搜索各有一条路由', () => {
  for (const ty of ['novel', 'comic', 'video', 'music'])
    assert.ok(ROUTES.find(r => r.match === 'search' && r.type === ty), '缺 ' + ty);
});
t('route() 支持按 id 与按 match 查', () => {
  assert.strictEqual(route('search.comic').type, 'comic');
  assert.strictEqual(route('search').id, 'search.novel'); // 回落第一个同类
  assert.strictEqual(route('nope'), null);
});
t('取内容类路由 limit=1（单源，不 fan-out）', () => {
  assert.strictEqual(route('toc').limit, 1);
  assert.strictEqual(route('content').limit, 1);
});

console.log('── HealthGate :: 记账与静默 ──');
t('无样本时 rate=1（不歧视新源），但 weight 用中性先验 0.5', () => {
  const g = new HealthGate();
  assert.strictEqual(g.rate('new'), 1);
  assert.ok(g.weight('new') > 0);
  // ★ 这条是被第一版单测抓出来的设计缺陷：无样本曾按"rate 1 + avg 0"算成权重 1.0，
  //   于是**从没用过的源排在已验证又快又稳的源前面**。现在固定为中性先验。
  assert.strictEqual(g.weight('new'), HealthGate.PRIOR_UNKNOWN);
  assert.strictEqual(g.isSuppressed('new'), false);
});
t('★ 权重次序：已验证的好源 > 未知新源 > 已验证的差源 > 静默源', () => {
  const g = new HealthGate({ failStreakToSuppress: 10, suppressMs: 60000 });
  for (let i = 0; i < 5; i++) g.note('good', true, 50);     // 稳且快
  for (let i = 0; i < 5; i++) g.note('bad', false);          // 稳地失败
  const wGood = g.weight('good'), wNew = g.weight('unknown-src'), wBad = g.weight('bad');
  assert.ok(wGood > wNew, `好源(${wGood}) 应 > 新源(${wNew})`);
  assert.ok(wNew > wBad, `新源(${wNew}) 应 > 差源(${wBad})`);
  const g2 = new HealthGate({ failStreakToSuppress: 1, suppressMs: 60000 });
  g2.note('dead', false);
  assert.strictEqual(g2.weight('dead'), 0);
});
t('连续失败达阈值 → 静默', () => {
  const g = new HealthGate({ failStreakToSuppress: 3 });
  assert.strictEqual(g.note('bad', false, 10, 'e1').state, 'ok');
  assert.strictEqual(g.note('bad', false, 10, 'e2').state, 'ok');
  const r = g.note('bad', false, 10, 'e3');
  assert.strictEqual(r.state, 'suppressed');
  assert.strictEqual(g.isSuppressed('bad'), true);
  assert.strictEqual(g.weight('bad'), 0);
});
t('中途成功会把连续失败计数清零（不累计）', () => {
  const g = new HealthGate({ failStreakToSuppress: 3 });
  g.note('x', false); g.note('x', false);
  g.note('x', true);           // 清零
  g.note('x', false);
  assert.strictEqual(g.isSuppressed('x'), false);
});
t('静默期满 → probeDue，成功一次即恢复', () => {
  const g = new HealthGate({ failStreakToSuppress: 1, suppressMs: 5 });
  g.note('y', false);
  assert.strictEqual(g.isSuppressed('y'), true);
  assert.strictEqual(g.isProbeDue('y'), false);
  const waitUntil = Date.now() + 8;
  while (Date.now() < waitUntil) { /* 等静默期过 */ }
  assert.strictEqual(g.isSuppressed('y'), false);
  assert.strictEqual(g.isProbeDue('y'), true);
  assert.strictEqual(g.note('y', true, 20).state, 'restored');
  assert.strictEqual(g.isSuppressed('y'), false);
  assert.strictEqual(g.isProbeDue('y'), false);
});
t('恢复后再次连续失败会重新静默', () => {
  const g = new HealthGate({ failStreakToSuppress: 1, suppressMs: 1 });
  g.note('z', false); g.note('z', true);
  assert.strictEqual(g.isSuppressed('z'), false);
  g.note('z', false);
  assert.strictEqual(g.isSuppressed('z'), true);
});
t('avgMs 会算平均，lastError 会留痕', () => {
  const g = new HealthGate();
  g.note('a', true, 100); g.note('a', true, 300);
  assert.strictEqual(g.avgMs('a'), 200);
  g.note('a', false, 0, 'boom');
  assert.strictEqual(g.rate('a'), 2 / 3);
  assert.strictEqual(g.snapshot()['a'] ? true : false, true);
  assert.strictEqual(g.map.get('a').lastError, 'boom');
});
t('snapshot 的形状稳定（给 /v1/status 用）', () => {
  const g = new HealthGate();
  g.note('k', true, 50);
  const s = g.snapshot()['k'];
  for (const f of ['ok', 'fail', 'rate', 'avgMs', 'weight', 'streakFail', 'suppressed', 'probeDue', 'lastError', 'lastAt'])
    assert.ok(f in s, '缺字段 ' + f);
});

console.log('── pickSources :: 取源 ──');
const mk = (n) => Array.from({ length: n }, (_, i) => ({ id: 's' + i, bookSourceName: 'S' + i, enabled: true }));

t('候选数 ≤ limit → 原样返回', () => {
  assert.strictEqual(pickSources(mk(2), { limit: 3 }).length, 2);
});
t('无 gate → 退化为前 N 个（保持旧行为可比对）', () => {
  const out = pickSources(mk(6), { limit: 3 });
  assert.deepStrictEqual(out.map(s => s.id), ['s0', 's1', 's2']);
});
t('enabled=false 的源被排除', () => {
  const list = mk(5); list[1].enabled = false;
  const out = pickSources(list, { limit: 5 });
  assert.ok(!out.some(s => s.id === 's1'));
});
t('健康度高的排前面', () => {
  const g = new HealthGate();
  for (let i = 0; i < 5; i++) { g.note('s0', false); g.note('s1', false); g.note('s2', false); }
  for (let i = 0; i < 5; i++) g.note('s3', true, 50);
  const out = pickSources(mk(6), { limit: 3, gate: g });
  assert.strictEqual(out[0].id, 's3');
});
t('静默中的源被排除', () => {
  const g = new HealthGate({ failStreakToSuppress: 1, suppressMs: 60000 });
  g.note('s0', false);
  const out = pickSources(mk(6), { limit: 3, gate: g });
  assert.ok(!out.some(s => s.id === 's0'));
});
t('★ 全部源都被静默时 → 全部放回（宁可问死源，也不能搜不出东西）', () => {
  const g = new HealthGate({ failStreakToSuppress: 1, suppressMs: 60000 });
  for (let i = 0; i < 4; i++) g.note('s' + i, false);
  const out = pickSources(mk(4), { limit: 3, gate: g });
  assert.strictEqual(out.length, 3);
});
t('★ 探索位：最少被用到的源能挤进来（否则新导的源永远没机会）', () => {
  const g = new HealthGate();
  // s0/s1/s2 已被用过 99 次，s3/s4 从没用过 → 探索位必须落在 s3/s4 上。
  const usage = new Map([['s0', 99], ['s1', 99], ['s2', 99], ['s3', 0], ['s4', 0]]);
  const out = pickSources(mk(5), { limit: 3, gate: g, usage });
  assert.strictEqual(out.length, 3);
  assert.ok(out.some(s => s.id === 's3' || s.id === 's4'),
    '探索位应落在 usage 最低的源上，实际=' + out.map(s => s.id).join(','));
});
t('limit=1 时没有探索位（取内容必须用最优源）', () => {
  const g = new HealthGate();
  g.note('s5', true, 10);
  const out = pickSources(mk(6), { limit: 1, gate: g });
  assert.strictEqual(out.length, 1);
});
t('返回值不重复', () => {
  const g = new HealthGate();
  const out = pickSources(mk(6), { limit: 3, gate: g });
  assert.strictEqual(new Set(out.map(s => s.id)).size, out.length);
});
t('list 为非法输入不崩', () => {
  assert.deepStrictEqual(pickSources(null, { limit: 3 }), []);
  assert.deepStrictEqual(pickSources(undefined, { limit: 3 }), []);
});

console.log(`\n结果: pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
