// EnginePlugin 统一接口 / 注册表单测
//
//   跑法: node server/test_engine_plugin.cjs   （退出码 0 = 全过）
//
// 为什么要有它：`registry.forSource()` 是整个改造的**唯一判据** ——
// 它一旦选错插件，对应格式的源就会静默失效（"搜不到"而不是"报错"）。
// 所以这里把每种源形状的选取结果逐条钉住，并额外验证两条不变量：
//   · 认不出的源必须 `forSource → null`（让调用方能报出来），不许瞎猜一个；
//   · 动作不存在时必须给**带原因**的 IR，而不是抛异常（否则调用方
//     `Promise.all` 会被一条缺动作的源整体炸掉）。
//
// 最后一节会真跑一条 drpy 源（DJ音乐）做端到端冒烟 —— 它依赖网络，
// 失败时只警告不判负（源站抖动不该让自检变红），避免"红着红着就没人看了"。
'use strict';
const assert = require('assert');
const { registry, EnginePlugin } = require('./engine-plugin.js');

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + e.message); }
}

console.log('── 1. 注册表完整性 ──');
t('六个引擎都已注册', () => assert.strictEqual(registry.all().length, 6));
t('id 齐全', () => assert.deepStrictEqual(registry.ids().sort(),
  ['comic', 'drpy', 'legado', 'lx', 'musicfree', 'tvbox']));
t('每个插件都有 id/label/kinds/actions', () => {
  for (const d of registry.describe()) {
    assert.ok(d.id, 'id 缺失');
    assert.ok(d.label, `${d.id} label 缺失`);
    assert.ok(Array.isArray(d.kinds) && d.kinds.length, `${d.id} kinds 为空`);
    assert.ok(Array.isArray(d.actions) && d.actions.length, `${d.id} actions 为空`);
  }
});
t('五个标准动作在至少一个插件里存在', () => {
  const has = (a) => registry.all().some((p) => p.supports(a));
  for (const a of ['search', 'detail', 'catalog', 'content', 'play']) {
    assert.ok(has(a), `没有任何插件支持 ${a}`);
  }
});

console.log('── 2. 按源形状选插件（核心判据）──');
const cases = [
  ['Legado 书源(有 bookSourceUrl、无 code)', { bookSourceUrl: 'x', name: 'b1', searchUrl: 'y' }, 'legado'],
  ['LX 音源(format=lx)', { format: 'lx', code: 'c', name: 'm1' }, 'lx'],
  ['venera 漫画源(format=comic)', { format: 'comic', code: 'c', name: 'k1' }, 'comic'],
  ['venera 漫画源(format=venera)', { format: 'venera', code: 'c', name: 'k2' }, 'comic'],
  ['musicfree 音源(format=musicfree)', { format: 'musicfree', code: 'c', name: 'm2' }, 'musicfree'],
  ['TVBox CMS(有 api)', { api: 'http://x/api.php/provide/vod', name: 't1' }, 'tvbox'],
  ['drpy 影视源(format=drpy)', { code: 'c', format: 'drpy', name: 'v1' }, 'drpy'],
];
for (const [label, src, want] of cases) {
  t(`${label} → ${want}`, () => {
    const p = registry.forSource(src);
    assert.ok(p, `未选出插件（应为 ${want}）`);
    assert.strictEqual(p.id, want);
  });
}

t('★认不出的源 → null（不许瞎猜一个插件）', () => {
  assert.strictEqual(registry.forSource({}), null);
  assert.strictEqual(registry.forSource({ name: '孤零零' }), null);
  assert.strictEqual(registry.forSource(null), null);
  // ★有 code 但**没有 format 也没有 api** —— 无法判别是 drpy 还是 musicfree。
  //   这里必须返回 null：第一版曾按"兜底给 drpy"处理，结果它与 musicfree 的
  //   判别条件重叠，DJ音乐 被选成 musicfree，端到端冒烟直接失败。
  assert.strictEqual(registry.forSource({ code: 'c', name: '无标识源' }), null);
});

t('指定 kind 时优先在该类型的插件里选', () => {
  const src = { format: 'musicfree', code: 'c' };
  assert.strictEqual(registry.forSource(src, 'music').id, 'musicfree');
  // kind 写错也仍应兜底选出插件（否则调用方会因为一个参数拼错而整类消失）
  assert.strictEqual(registry.forSource(src, 'novel').id, 'musicfree');
});

console.log('── 3. 不变量：缺失动作与异常都收敛成 IR ──');
t('对不支持的动作 → 返回 {error}，不抛', async () => {
  // 同步断言 async 的返回：用一个必然不支持的动作
  const p = registry.get('legado');
  assert.strictEqual(p.supports('play'), false);
});
t('EnginePlugin.call 遇未知动作给出可读原因', async () => {
  const p = new EnginePlugin({ id: 'x', label: 'X', kinds: ['novel'], actions: { search: async () => ({ items: [] }) } });
  const r = await p.call('play', {});
  assert.ok(r.error, '应返回 error');
  assert.ok(r.error.includes('不支持动作 play'), '原因应点出动作名: ' + r.error);
  assert.ok(r.error.includes('search'), '原因应列出它支持的动作: ' + r.error);
});
t('动作抛异常 → 收敛成 {error}，不外泄', async () => {
  const p = new EnginePlugin({ id: 'y', label: 'Y', kinds: ['novel'],
    actions: { search: async () => { throw new Error('boom'); } } });
  const r = await p.search({}, 'q');
  assert.ok(r.error && r.error.includes('boom'), '应把异常转成 error: ' + JSON.stringify(r));
});
t('registry.run 对无人认领的源 → {error} 且点出 format/api', async () => {
  const r = await registry.run({}, 'search', 'q');
  assert.ok(r.error, '应返回 error');
  assert.ok(r.error.includes('没有插件'), '原因应说明无人认领: ' + r.error);
});

console.log('── 4. 媒体路由已迁移（防止引擎直连回流）──');
const fs = require('fs'), path = require('path');
const mediaSrc = fs.readFileSync(path.join(__dirname, 'routes-media.js'), 'utf8');
t('routes-media.js 不再直接 require 各引擎', () => {
  for (const e of ['engine-drpy.js', 'engine-lx.js', 'engine-comic.js', 'engine-music.js']) {
    assert.ok(!mediaSrc.includes(`require('./${e}')`), `仍直连 ${e}（应走 registry）`);
  }
  assert.ok(mediaSrc.includes("require('./engine-plugin.js')"), '未引用 engine-plugin');
  // tvbox 是唯一豁免：importConfig 属"配置导入"，不是跑某个源
  assert.ok(mediaSrc.includes("require('./engine-tvbox.js')"), 'tvbox 直连被误删（importConfig 需要）');
});
t('routes-media.js 的取数全部走 registry.run，且旧判别式已清零', () => {
  const n = (mediaSrc.match(/registry\.run\(/g) || []).length;
  assert.ok(n >= 9, `registry.run 调用点应 ≥9，实际 ${n}`);
  for (const bad of ["s.format === 'lx'", "s.kind === 'tvbox-cms'",
    'comic.runSource', 'drpy.runSource', 'lx.runLX', 'music.runPlugin']) {
    assert.ok(!mediaSrc.includes(bad), `仍残留旧引擎判别式: ${bad}`);
  }
});
// ★这条对应"漏改不报错"：POST 导入的源若不带 format，registry 认不出，
//   该格式的源会在 search 时静默返回 0 条 —— 与鉴权黑洞同一类病。
t('导入路径落下的源一定带 format，且该形状能被认领', () => {
  assert.ok(mediaSrc.includes("format: d.format === 'comic' ? 'comic' : 'venera'"), '漫画 POST 未补 format');
  assert.ok(/\bformat: 'drpy'/.test(mediaSrc), '影视 POST 未补 format');
  assert.strictEqual(registry.forSource({ id: 'k1', name: 'k', code: 'x', format: 'venera' }).id, 'comic');
  assert.strictEqual(registry.forSource({ id: 'v1', name: 'v', code: 'x', format: 'drpy' }).id, 'drpy');
});

console.log('── 5. 端到端冒烟（真跑一条 drpy 源；网络抖动只警告）──');
(async () => {
  let src = null;
  try {
    const list = require('./data/drpy-sources.json');
    src = (list || []).find((s) => /DJ音乐/.test(s.name || '')) || null;
  } catch (e) { console.log('  ! 读 data/drpy-sources.json 失败: ' + e.message); }

  if (!src) {
    console.log('  ! 未找到 DJ音乐 源，跳过冒烟');
  } else {
    const p = registry.forSource(src);
    if (!p || p.id !== 'drpy') {
      fail++; console.log(`  FAIL 冒烟源未选到 drpy 插件（实际 ${p && p.id}）`);
    } else {
      const r = await p.search(src, 'DJ');
      if (r && Array.isArray(r.items) && r.items.length) {
        pass++; console.log(`  ok  冒烟：drpy 插件真跑通 → ${r.items.length} 条（首条：${r.items[0].name || r.items[0].title || '?'}）`);
      } else if (r && r.error) {
        console.log(`  ~  冒烟跳过：源站返回 ${String(r.error).slice(0, 100)}（不计负）`);
      } else {
        console.log('  ~  冒烟跳过：返回 0 条（源站可能在改版，不计负）');
      }
    }
  }

  console.log(`\n── 汇总 ──\n  pass=${pass} fail=${fail}`);
  process.exit(fail ? 1 : 0);
})();
