// routes-search.js 的 /v1/search 路径：THP 引擎按内容类型分发 —— 单测（纯逻辑，无 IO）
// 跑法: node server/test_search_routes.cjs
//
// 为什么要有这条测试：
//   2026-10-02 之前，/v1/search 里写死 `thpOnline('novel')` + `type: 'novel'`，
//   于是**漫画 / 音乐 / 影视引擎即使在线也永远收不到请求、永远返回空**。
//   这个缺陷不会抛异常、不会写错误日志 —— 前端只表现为"引擎连上了却搜不出东西"，
//   事后完全查不出来。所以必须有条断言把"到底问了谁、问的什么类型"钉死。
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { handle } = require('./routes-search.js');

let pass = 0, fail = 0;
async function t(name, fn) {
  try { await fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + e.message); }
}

function mkDev(url, caps) {
  return { device_url: url, device_type: 'thp', caps, interval: 30000, last_seen: Date.now() };
}

// 与 server/index.js 的 thpOnline 同一口径：cap 命中 'm:<cap>' 或裸 cap。
// 文件末尾另有源码守卫断言 index.js 里这条规则还在，防止两处定义漂移。
function thpOnlineOf(devices) {
  return (cap) => devices.filter((d) => {
    if (d.device_type !== 'thp') return false;
    if ((Date.now() - (d.last_seen || 0)) >= Math.max(3 * (d.interval || 30000), 30000)) return false;
    if (!cap) return true;
    const caps = d.caps || [];
    return caps.includes(cap) || caps.includes('m:' + cap);
  });
}

function mkCtx(devices, calls, extra) {
  return Object.assign({
    aggCache: new Map(), sources: [],
    engine: {},
    pool: async (list, n, fn) => { const o = []; for (const s of list) o.push(await fn(s)); return o; },
    comicSources: [], drpySources: [], musicSources: [],
    devices,
    thpOnline: thpOnlineOf(devices),
    thpCall: async (dev, p, params) => {
      calls.push({ url: dev.device_url, path: p, type: params.type });
      return { items: [{ id: dev.device_url + '#' + params.type, name: 'r-' + params.type }] };
    },
    library: [], health: new Map(), healthHit: () => {},
    requestLog: { record: () => {} },
    routeTable: null, healthGate: null, srcUsage: null, bumpUsage: null,
  }, extra || {});
}
// 有一本书源在场 —— 用来把路径钉在"有引擎/有源"的主链路上，
// 否则 q 非空且无任何在线源时会走「回落本地书库」的早退分支（那是另一条路径）。
const ONE_SOURCE = [{ bookSourceUrl: 's1', bookSourceName: 'S1', enabled: true }];

async function callSearch(p, devices, calls, extra) {
  let captured = null;
  const u = new URL('http://example.test' + p);
  const res = { writableEnded: false };
  const send = (code, obj) => { captured = { code, obj }; res.writableEnded = true; };
  const done = await handle({}, res, '', u, u.pathname, send, mkCtx(devices, calls, extra));
  assert.strictEqual(done, undefined, '命中 /v1/search 后不应回落主路由');
  assert.ok(captured, '未产生响应');
  return captured;
}

async function main() {
console.log('── /v1/search 的 THP 分发 ──');

await t('★ 回归：只声明漫画的引擎，在 /v1/search 上必须真被问到（此前恒定退化为只问 novel）', async () => {
  const calls = [];
  const devs = [mkDev('http://10.0.0.2:9528', ['m:comic'])];
  const r = await callSearch('/v1/search?q=' + encodeURIComponent('斗破'), devs, calls);
  assert.strictEqual(calls.length, 1, '应当恰好发 1 次 THP 调用，实际 ' + calls.length);
  assert.strictEqual(calls[0].type, 'comic', '应当问 comic 类型，实际 ' + calls[0].type);
  assert.strictEqual(r.code, 200);
  const srcs = r.obj.data.map((x) => x.source).join('|');
  assert.ok(/\[comic\]/.test(srcs), '结果里应带 [comic] 标签，实际 ' + srcs);
});

await t('四类引擎各只被问自己声明的类型，且四类都被问到', async () => {
  const calls = [];
  const devs = [
    mkDev('http://10.0.0.1:9528', ['m:novel']),
    mkDev('http://10.0.0.2:9528', ['m:comic']),
    mkDev('http://10.0.0.3:9528', ['m:video']),
    mkDev('http://10.0.0.4:9528', ['m:music']),
  ];
  const r = await callSearch('/v1/search?q=abc', devs, calls);
  assert.deepStrictEqual(calls.map((c) => c.type).sort(), ['comic', 'music', 'novel', 'video']);
  assert.strictEqual(r.obj.meta.thp, 4, 'meta.thp 应为在线引擎台数 4');
  assert.strictEqual(r.obj.meta.thpQueries, 4, 'meta.thpQueries 应为实际查询次数 4');
});

await t('声明四类能力的单引擎会被问四次（能力不设限 → 一次搜索覆盖全部内容类型）', async () => {
  const calls = [];
  const devs = [mkDev('http://10.0.0.9:9528', ['m:novel', 'm:comic', 'm:video', 'm:music'])];
  const r = await callSearch('/v1/search?q=abc', devs, calls);
  assert.strictEqual(calls.length, 4, '应当被问 4 次，实际 ' + calls.length);
  assert.deepStrictEqual(calls.map((c) => c.type).sort(), ['comic', 'music', 'novel', 'video']);
  assert.strictEqual(r.obj.meta.thp, 1, '同一台设备只算 1 个引擎');
  assert.strictEqual(r.obj.meta.thpQueries, 4);
});

await t('没有声明任何模块的引擎不会被问（不广播模块 = 前端直接跳过）', async () => {
  const calls = [];
  const devs = [mkDev('http://10.0.0.5:9528', [])];
  const r = await callSearch('/v1/search?q=abc', devs, calls);
  assert.strictEqual(calls.length, 0, '不应发任何 THP 调用');
  assert.strictEqual(r.obj.meta.thp, 0);
});

await t('离线引擎（last_seen 超 TTL）不被问', async () => {
  const calls = [];
  const d = mkDev('http://10.0.0.6:9528', ['m:novel']);
  d.last_seen = Date.now() - 10 * 60 * 1000;
  const r = await callSearch('/v1/search?q=abc', [d], calls, { sources: ONE_SOURCE });
  assert.strictEqual(calls.length, 0);
  assert.strictEqual(r.obj.meta.thp, 0);
});

await t('无任何在线引擎时回落本地书库（不是"搜不到"，是走了另一条路）', async () => {
  const calls = [];
  const r = await callSearch('/v1/search?q=abc', [], calls);
  assert.strictEqual(calls.length, 0);
  assert.strictEqual(r.obj.meta.via, 'local-library');
});

await t('失败引擎不污染其他类型的成功结果', async () => {
  const calls = [];
  const devs = [mkDev('http://10.0.0.7:9528', ['m:novel', 'm:music'])];
  const ctx = mkCtx(devs, calls);
  const orig = ctx.thpCall;
  ctx.thpCall = async (dev, p, params) => {
    if (params.type === 'novel') throw new Error('boom');
    return orig(dev, p, params);
  };
  let captured = null;
  const u = new URL('http://example.test/v1/search?q=abc');
  const res = { writableEnded: false };
  await handle({}, res, '', u, u.pathname, (c, o) => { captured = { c, o }; return true; }, ctx);
  const okTypes = captured.o.data.filter((x) => x.ok).map((x) => (x.source.match(/\[(\w+)\]/) || [])[1]);
  assert.deepStrictEqual(okTypes, ['music'], '只有 music 这一组成功，实际 ' + JSON.stringify(okTypes));
});

console.log('── 源码守卫（防止两处口径漂移） ──');
await t('server/index.js 的 thpOnline 仍按 m:<cap> 匹配', () => {
  const src = fs.readFileSync(path.join(__dirname, 'index.js'), 'utf8');
  assert.ok(/caps\.includes\('m:' \+ cap\)/.test(src), "index.js 里 'm:' + cap 的匹配规则丢失");
});
await t('routes-search.js 不再出现写死的 type: \'novel\'', () => {
  const raw = fs.readFileSync(path.join(__dirname, 'routes-search.js'), 'utf8');
  // 去掉注释行再断言：注释里为了说明"修了什么"会引用旧写法，那是文档不是代码。
  const src = raw.split('\n').filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n');
  assert.ok(!/type:\s*'novel'/.test(src), "routes-search.js 里仍有写死的 type: 'novel' —— 类型分发退化");
  assert.ok(!/thpOnline\('novel'\)/.test(src), "routes-search.js 里仍有 thpOnline('novel') 单类型取引擎");
  assert.ok(/const THP_TYPES = \['novel', 'comic', 'video', 'music'\]/.test(src), '四类型常量缺失');
});

console.log('\n结果: ' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail ? 1 : 0);
}
main().catch((e) => { console.error('ERR ' + e.stack); process.exit(1); });
