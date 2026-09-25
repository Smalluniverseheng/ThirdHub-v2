// 预置源包「增量导入 + 撤销」自检: 直接驱动 server/preset-sync.js 的纯函数。
// 每个用例都对应一个真会出问题的地方（注释里写清「不这么做会怎样」）。
//
//   1) 全新安装 → 包里的源全部导入且 enabled
//   2) 幂等 → 同一份包跑两次，第二次什么都不做        ← 「每次重启都塞回来」的反面
//   3) 老标记迁移 → 数字标记（旧格式）能触发一次对齐，但不产生重复源
//   4) ★撤销 → 包声明不要的源被停用（本期 #19 的命门）
//   5) 撤销幂等 → 同一份撤销声明不会反复置位
//   6) 尊重用户 → 用户手动重新启用的源，包没变就不会被再次停用
//   7) ★恢复 → 源重新回到白名单时，enabled 与组名都要还原（不是只翻 enabled）
//   8) 脏条目（缺 url/缺 name）跳过而不是崩
//   9) 白名单优先 → 同一 url 既在 list 又在 revoked 时，以 list 为准
//  10) 纯函数 → 入参数组不被就地修改（否则调用方拿到的是半成品状态）
//  11) 撤销指向用户没有的源 → 静默跳过，不计数不抛
//  12) 撤销簿记不写进源对象 → data/sources.json 里不出现私有字段
'use strict';
const path = require('path');

// ★ 两种布局都要能跑：仓库内脚本在 `server/`（同目录），发布 zip 是平铺布局。
//   历史坑：解析错路径时这一项报 MODULE_NOT_FOUND，看着像「包坏了」，其实是测试找不到路。
const modPath = require('fs').existsSync(path.join(__dirname, 'preset-sync.js'))
  ? path.join(__dirname, 'preset-sync.js')
  : path.join(__dirname, '..', 'server', 'preset-sync.js');
const { planPresetSync, DISABLED_GROUP } = require(modPath);

let fails = 0;
function ck(name, cond, extra) {
  if (cond) console.log('  OK   ' + name);
  else { fails++; console.log('  FAIL ' + name + (extra ? '  -> ' + extra : '')); }
}
const J = (x) => JSON.stringify(x);

// 造源：只带本机制真正会看的字段
const src = (url, name, group) => ({ bookSourceUrl: url, bookSourceName: name, bookSourceGroup: group || '', enabled: true });
const pack = (file, list, text, revoked) => ({ file, text: text || file + '#' + list.length, list, revoked });

console.log('== 1. 全新安装 ==');
{
  const demo = 'http://preset.thirdhub.local/1';
  const good = { bookSourceUrl: 'http://ok.example/', bookSourceName: '好源', ruleSearch: {} };
  const entries = [
    pack('demo.json', [src(demo, '内置演示源', '占位')]),
    pack('health-book.json', [good], 'HB_V1'),
  ];
  const r = planPresetSync([], entries, {});
  ck('导入 2 条', r.sources.length === 2 && r.added === 2, J({ n: r.sources.length, added: r.added }));
  ck('都 enabled', r.sources.every((s) => s.enabled === true), J(r.sources));
  ck('changed = 两个包名', J(r.changed.sort()) === J(['demo.json', 'health-book.json']), J(r.changed));
  ck('标记写入 state.packs', !!r.state.packs['health-book.json'], J(r.state));
}

console.log('== 2. 幂等（同一份包再跑一次）==');
{
  const good = { bookSourceUrl: 'http://ok.example/', bookSourceName: '好源' };
  const demo = src('http://preset.thirdhub.local/1', '内置演示源');
  const entries = [pack('demo.json', [demo]), pack('health-book.json', [good], 'HB_V1')];
  const r1 = planPresetSync([], entries, {});
  const r2 = planPresetSync(r1.sources, entries, r1.state);
  ck('第二次 added = 0', r2.added === 0, J(r2.added));
  ck('第二次 changed 为空', r2.changed.length === 0, J(r2.changed));
  ck('源列表逐字节等价', J(r2.sources) === J(r1.sources), J(r2.sources));
}

console.log('== 3. 老标记（数字格式）迁移 ==');
{
  const good = { bookSourceUrl: 'http://ok.example/', bookSourceName: '好源' };
  const entries = [pack('health-book.json', [good], 'HB_V1')];
  const legacy = { 'demo.json': 1, 'health-book.json': 1 };   // 老格式：文件名 → 条目数
  const r = planPresetSync([Object.assign({}, good, { enabled: true })], entries, legacy);
  ck('触发一次对齐（changed 非空）', r.changed.length === 1, J(r.changed));
  ck('但不产生重复源', r.sources.length === 1 && r.added === 0, J({ n: r.sources.length, added: r.added }));
}

console.log('== 4. ★撤销：包声明不要的源必须被停用 ==');
{
  const keep = { bookSourceUrl: 'http://keep.example/', bookSourceName: '留着', bookSourceGroup: '校验可用' };
  const drop = { bookSourceUrl: 'http://drop.example/', bookSourceName: '🌸 烂源', bookSourceGroup: '校验可用' };
  const before = [Object.assign({}, keep, { enabled: true }), Object.assign({}, drop, { enabled: true })];
  // 新包只留 keep，并显式声明 drop 要停用（同一个文件里带 revoked）
  const entries = [pack('health-book.json', [keep], 'HB_V2', [{ bookSourceUrl: 'http://drop.example/', bookSourceName: '🌸 烂源', reason: '[content] 正文脏: 页面杂质' }])];
  const r = planPresetSync(before, entries, { packs: { 'health-book.json': 'HB_V1' } });
  const d = r.sources.find((s) => s.bookSourceUrl === 'http://drop.example/');
  const k = r.sources.find((s) => s.bookSourceUrl === 'http://keep.example/');
  ck('烂源 enabled=false', d.enabled === false, J(d));
  ck('烂源组名 = ' + DISABLED_GROUP, d.bookSourceGroup === DISABLED_GROUP, J(d));
  ck('好源不受影响（仍 enabled、组名未变）', k.enabled === true && k.bookSourceGroup === '校验可用', J(k));
  ck('disabled 计数 = 1', r.disabled === 1, J(r.disabled));
  ck('记录的旧组名进了 state（不是源对象）', r.state.revoked['http://drop.example/'].prevGroup === '校验可用', J(r.state.revoked));
  ck('源对象里没有私有字段', !('__presetPrevGroup' in d) && !('presetState' in d), J(d));
  ck('停用没有删除源', r.sources.length === 2, J(r.sources.length));
}

console.log('== 5. 撤销幂等（同一份声明再跑）==');
{
  const keep = { bookSourceUrl: 'http://keep.example/', bookSourceName: '留着' };
  const drop = { bookSourceUrl: 'http://drop.example/', bookSourceName: '烂源' };
  const entries = [pack('health-book.json', [keep], 'HB_V2', [{ bookSourceUrl: 'http://drop.example/', reason: 'x' }])];
  const r1 = planPresetSync([Object.assign({}, keep, { enabled: true }), Object.assign({}, drop, { enabled: true })], entries, {});
  const r2 = planPresetSync(r1.sources, entries, r1.state);
  ck('第二次 disabled = 0', r2.disabled === 0, J(r2.disabled));
  ck('第二次 changed 为空', r2.changed.length === 0, J(r2.changed));
  ck('源列表未变', J(r2.sources) === J(r1.sources), J(r2.sources));
}

console.log('== 6. 尊重用户：手动重新启用的源不被再次停用 ==');
{
  const drop = { bookSourceUrl: 'http://drop.example/', bookSourceName: '烂源' };
  const entries = [pack('health-book.json', [], 'HB_V2', [{ bookSourceUrl: 'http://drop.example/', reason: 'x' }])];
  const r1 = planPresetSync([Object.assign({}, drop, { enabled: true })], entries, {});
  ck('第一次被停用', r1.sources[0].enabled === false, J(r1.sources[0]));
  // 用户手动把它打开（组名也自己改回去）
  const userFixed = [Object.assign({}, r1.sources[0], { enabled: true, bookSourceGroup: '校验可用' })];
  const r2 = planPresetSync(userFixed, entries, r1.state);
  ck('包没变 → 不再被停用', r2.sources[0].enabled === true, J(r2.sources[0]));
}

console.log('== 7. ★恢复：源重新回到白名单 ==');
{
  const drop = { bookSourceUrl: 'http://drop.example/', bookSourceName: '烂源', bookSourceGroup: '校验可用' };
  const bad = [pack('health-book.json', [], 'HB_V2', [{ bookSourceUrl: 'http://drop.example/', reason: 'x' }])];
  const r1 = planPresetSync([Object.assign({}, drop, { enabled: true })], bad, {});
  ck('先被停用', r1.sources[0].enabled === false && r1.sources[0].bookSourceGroup === DISABLED_GROUP, J(r1.sources[0]));
  const good = [pack('health-book.json', [drop], 'HB_V3')];   // 内容变了 → 新 token
  const r2 = planPresetSync(r1.sources, good, r1.state);
  ck('enabled 恢复 true', r2.sources[0].enabled === true, J(r2.sources[0]));
  ck('组名还原为 校验可用（不是空串）', r2.sources[0].bookSourceGroup === '校验可用', J(r2.sources[0]));
  ck('state.revoked 里该条被清掉', !r2.state.revoked['http://drop.example/'], J(r2.state.revoked));
  ck('restored 计数 = 1', r2.restored === 1, J(r2.restored));
}

console.log('== 8. 脏条目跳过 ==');
{
  const entries = [pack('x.json', [{ bookSourceName: '没url' }, { bookSourceUrl: 'http://u.example/' }, null, src('http://ok.example/', '好源')], 'X1')];
  const r = planPresetSync([], entries, {});
  ck('只导入合法的那条', r.sources.length === 1 && r.sources[0].bookSourceUrl === 'http://ok.example/', J(r.sources));
}

console.log('== 9. 白名单优先（同 url 既在 list 又在 revoked）==');
{
  const s = src('http://both.example/', '两边都有');
  const entries = [pack('a.json', [s], 'A1'), pack('b.json', [], 'B1', [{ bookSourceUrl: 'http://both.example/', reason: 'x' }])];
  const r = planPresetSync([Object.assign({}, s, { enabled: true })], entries, {});
  ck('不被停用', r.sources[0].enabled === true, J(r.sources[0]));
  ck('disabled = 0', r.disabled === 0, J(r.disabled));
}

console.log('== 10. 纯函数：入参不被就地修改 ==');
{
  const before = [src('http://a.example/', 'A')];
  const snapshot = J(before);
  const entries = [pack('p.json', [src('http://b.example/', 'B')], 'P1')];
  planPresetSync(before, entries, {});
  ck('入参数组未被改', J(before) === snapshot, J(before));
}

console.log('== 11. 撤销指向用户没有的源 ==');
{
  const entries = [pack('h.json', [], 'H1', [{ bookSourceUrl: 'http://ghost.example/', reason: 'x' }])];
  const r = planPresetSync([src('http://real.example/', '真源')], entries, {});
  ck('不抛异常', true);
  ck('disabled = 0', r.disabled === 0, J(r.disabled));
  ck('源数不变', r.sources.length === 1 && r.sources[0].enabled === true, J(r.sources));
}

console.log('== 12. 撤销簿记不污染源对象 ==');
{
  const drop = src('http://drop.example/', '烂源', '校验可用');
  const entries = [pack('h.json', [], 'H1', [{ bookSourceUrl: 'http://drop.example/', reason: 'x' }])];
  const r = planPresetSync([drop], entries, {});
  const keys = Object.keys(r.sources[0]).sort();
  ck('字段只有原本那两个被改', J(keys) === J(['bookSourceGroup', 'bookSourceName', 'bookSourceUrl', 'enabled']), J(keys));
}

console.log('');
console.log(fails === 0 ? '全部通过 (0 失败)' : (fails + ' 项失败'));
process.exit(fails === 0 ? 0 : 1);
