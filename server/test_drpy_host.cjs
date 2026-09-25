// drpy-host 单测：覆盖 drpy 源脚本里实际出现的 pdfh/pdfa/pd 用法
// 跑法: node server/test_drpy_host.cjs
'use strict';
const assert = require('assert');
const h = require('./drpy-host.js');

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + e.message); }
}

// 一份贴近真实视频站结构的片段（含列表、图片懒加载属性、相对链接、广告位空节点）
const HTML = `
<div class="module-list">
  <div class="module-item">
    <a href="/vod/1.html" title="斗罗大陆">
      <img data-original="/img/1.jpg" src="/img/blank.gif" alt="斗罗大陆">
      <span class="module-item-note">第100集</span>
    </a>
  </div>
  <div class="module-item">
    <a href="https://cdn.example.com/vod/2.html">
      <img data-original="https://cdn.example.com/img/2.jpg" src="/img/blank.gif">
      <span class="module-item-note">第50集</span>
    </a>
  </div>
</div>
<div class="module-info-item"><span>导演</span>张三</div>
<div class="module-info-item">类型: 动画</div>
`;

console.log('── pdfh ──');
t('取文本（默认 Text）', () => {
  assert.strictEqual(h.pdfh(HTML, '.module-info-item&&Text'), '导演张三');
});
t('取文本（显式 Text）', () => {
  assert.strictEqual(h.pdfh(HTML, '.module-item-note&&Text'), '第100集');
});
t('取属性 href', () => {
  assert.strictEqual(h.pdfh(HTML, '.module-item a&&href'), '/vod/1.html');
});
t('取懒加载属性 data-original', () => {
  assert.strictEqual(h.pdfh(HTML, '.module-item img&&data-original'), '/img/1.jpg');
});
t('取属性 title', () => {
  assert.strictEqual(h.pdfh(HTML, '.module-item a&&title'), '斗罗大陆');
});
t('取 Html', () => {
  const v = h.pdfh(HTML, '.module-item-note&&Html');
  assert.strictEqual(v, '第100集');
});
t('取 OuterHtml', () => {
  const v = h.pdfh(HTML, '.module-item a&&OuterHtml');
  assert.ok(v.includes('href="/vod/1.html"'), '实际=' + v);
});
t('选择器不存在 → 空串（不抛）', () => {
  assert.strictEqual(h.pdfh(HTML, '.no-such&&Text'), '');
});
t('空 parse → 空串', () => {
  assert.strictEqual(h.pdfh(HTML, ''), '');
  assert.strictEqual(h.pdfh(HTML, null), '');
});
t('★ `;` 多候选：取第一个非空（源站改版容错）', () => {
  assert.strictEqual(h.pdfh(HTML, '.missing&&Text;.module-info-item&&Text'), '导演张三');
});
t('★ 多级 && 当选择器链', () => {
  assert.strictEqual(h.pdfh(HTML, '.module-list&&a&&href'), '/vod/1.html');
});
t('HTML 为 null/undefined 不崩', () => {
  assert.strictEqual(h.pdfh(null, '.a&&Text'), '');
  assert.strictEqual(h.pdfh(undefined, '.a&&Text'), '');
});

console.log('── pdfa ──');
t('★ 无 &&attr → outerHTML 数组（drpy 源脚本的惯用法）', () => {
  const arr = h.pdfa(HTML, '.module-item');
  assert.strictEqual(arr.length, 2);
  assert.ok(arr[0].includes('href="/vod/1.html"'), '实际=' + arr[0]);
  // 关键：返回的片段还要能继续喂给 pdfh —— 这正是 drpy 的用法
  assert.strictEqual(h.pdfh(arr[0], 'a&&href'), '/vod/1.html');
  assert.strictEqual(h.pdfh(arr[1], 'a&&href'), 'https://cdn.example.com/vod/2.html');
});
t('有 &&Text → 文本数组', () => {
  assert.deepStrictEqual(h.pdfa(HTML, '.module-item-note&&Text'), ['第100集', '第50集']);
});
t('有 &&href → 属性数组', () => {
  assert.deepStrictEqual(h.pdfa(HTML, '.module-item a&&href'), ['/vod/1.html', 'https://cdn.example.com/vod/2.html']);
});
t('有 &&data-original → 属性数组', () => {
  assert.deepStrictEqual(h.pdfa(HTML, '.module-item img&&data-original'), ['/img/1.jpg', 'https://cdn.example.com/img/2.jpg']);
});
t('选择器不存在 → 空数组（不抛）', () => {
  assert.deepStrictEqual(h.pdfa(HTML, '.nope'), []);
});
t('★ `;` 多候选也能用在 pdfa 上', () => {
  assert.strictEqual(h.pdfa(HTML, '.nope;.module-item').length, 2);
});
t('非 HTML 输入不崩', () => {
  assert.deepStrictEqual(h.pdfa('', '.a'), []);
  assert.deepStrictEqual(h.pdfa(null, '.a'), []);
});

console.log('── pd ──');
t('绝对地址原样返回', () => {
  assert.strictEqual(h.pd(HTML, '.module-item:nth-child(2) a&&href', 'https://x.com/'), 'https://cdn.example.com/vod/2.html');
});
t('相对地址按 base 补全', () => {
  assert.strictEqual(h.pd(HTML, '.module-item a&&href', 'https://x.com/page/1.html'), 'https://x.com/vod/1.html');
});
t('无 base 时返回原值', () => {
  assert.strictEqual(h.pd(HTML, '.module-item a&&href', ''), '/vod/1.html');
});
t('空 parse → 空串', () => {
  assert.strictEqual(h.pd(HTML, '.nope&&href', 'https://x.com/'), '');
});

console.log('── joinUrl（引擎 urljoin 依赖的宿主函数）──');
t('绝对地址原样返回', () => {
  assert.strictEqual(h.joinUrl('https://a.com/x/', 'https://b.com/y'), 'https://b.com/y');
});
t('以 / 开头 → 换 path 保留 origin', () => {
  assert.strictEqual(h.joinUrl('https://a.com/x/y.html', '/z/1.html'), 'https://a.com/z/1.html');
});
t('相对地址 → 相对目录解析', () => {
  assert.strictEqual(h.joinUrl('https://a.com/x/y.html', 'z.html'), 'https://a.com/x/z.html');
});
t('协议相对 // → 继承 scheme', () => {
  assert.strictEqual(h.joinUrl('https://a.com/x', '//b.com/y'), 'https://b.com/y');
});
t('from 为空 → 返回 to', () => {
  assert.strictEqual(h.joinUrl('', '/abc'), '/abc');
});
t('to 为空 → 返回 from', () => {
  assert.strictEqual(h.joinUrl('https://a.com/x', ''), 'https://a.com/x');
});

console.log('── jinja2（挂在 cheerio 上的模板渲染器）──');
t('{{rule.host}} 取值', () => {
  assert.strictEqual(h.jinja2('{{rule.host}}/vodshow/1', { rule: { host: 'https://a.com' } }), 'https://a.com/vodshow/1');
});
t('{{fl.area}} 取值', () => {
  assert.strictEqual(h.jinja2('?area={{fl.area}}', { fl: { area: '日本' } }), '?area=日本');
});
t('缺字段 → 空串（不是 undefined）', () => {
  assert.strictEqual(h.jinja2('?a={{fl.nope}}', { fl: {} }), '?a=');
});
t('|default 过滤器', () => {
  assert.strictEqual(h.jinja2('{{fl.a|default("all")}}', { fl: {} }), 'all');
});
t('|urlencode 过滤器', () => {
  assert.strictEqual(h.jinja2('{{k|urlencode}}', { k: '斗 罗' }), '%E6%96%97%20%E7%BD%97');
});
t('无 {{}} 时原样返回', () => {
  assert.strictEqual(h.jinja2('/plain/path', {}), '/plain/path');
});
t('表达式里 or 当 || 用', () => {
  assert.strictEqual(h.jinja2('{{a or "x"}}', { a: '' }), 'x');
});

console.log('── local（引擎 KV 存储）──');
t('set/get 带命名空间', () => {
  const L = h.makeLocal({ localStorePath: require('path').join(require('os').tmpdir(), 'th_test_local_' + Date.now() + '.json') });
  L.set('规则A', 'cookie', 'abc');
  assert.strictEqual(L.get('规则A', 'cookie'), 'abc');
  // 命名空间隔离：另一个规则读不到
  assert.strictEqual(L.get('规则B', 'cookie', 'dflt'), 'dflt');
});
t('delete 生效', () => {
  const L = h.makeLocal({ localStorePath: require('path').join(require('os').tmpdir(), 'th_test_local_del_' + Date.now() + '.json') });
  L.set('ns', 'k', 1);
  L.delete('ns', 'k');
  assert.strictEqual(L.get('ns', 'k', ''), '');
});
t('get 默认值语义与 drpy 一致（undefined → 默认）', () => {
  const L = h.makeLocal({ localStorePath: require('path').join(require('os').tmpdir(), 'th_test_local_d_' + Date.now() + '.json') });
  assert.strictEqual(L.get('ns', 'never', 'fb'), 'fb');
});

console.log('── gbkTool（引擎按 rule.编码 触发）──');
t('encode 返回百分号串（可直接拼 URL）', () => {
  const g = h.hostGlobals({ log: () => {} }).gbkTool();
  assert.strictEqual(g.encode('斗罗'), '%B6%B7%C2%DE');
});
t('encode 结果是字符串而不是字节数组', () => {
  const g = h.hostGlobals({ log: () => {} }).gbkTool();
  assert.strictEqual(typeof g.encode('斗罗'), 'string');
});
t('decode 吃二进制串', () => {
  const g = h.hostGlobals({ log: () => {} }).gbkTool();
  const bin = Buffer.from([0xd3, 0xd0, 0xc9, 0xf9, 0xd0, 0xa1, 0xcb, 0xb5]).toString('binary');
  assert.strictEqual(g.decode(bin), '有声小说');
});

console.log('── hostGlobals（注入沙箱的形态）──');
t('包含 drpy2 需要的全部宿主符号', () => {
  const g = h.hostGlobals({ log: () => {} });
  // 函数型：pdfh/pdfa/pd 是解析器，joinUrl/jinja2 是引擎工具，
  // req 是同步 HTTP，gbkTool 是**工厂**（引擎写的是 gbkTool() 再取方法），
  // print/log 是日志出口。
  for (const k of ['pdfh', 'pdfa', 'pd', 'joinUrl', 'jinja2', 'req', 'gbkTool', 'print', 'log'])
    assert.strictEqual(typeof g[k], 'function', '应为函数: ' + k);
  // local 例外：它是对象（引擎用法 `local.get(ns,k)`），不是工厂函数。
  assert.strictEqual(typeof g.local, 'object', 'local 应为对象');
  assert.strictEqual(typeof g.local.get, 'function', 'local.get 应为函数');
  assert.strictEqual(typeof g.local.set, 'function', 'local.set 应为函数');
});
t('print 走注入的 log 而不是直接 console', () => {
  const seen = [];
  const g = h.hostGlobals({ log: (...a) => seen.push(a.join(' ')) });
  g.print('hello', 'world');
  assert.deepStrictEqual(seen, ['hello world']);
});
t('req 对 GET 不携带 body（undici 会硬报错）', () => {
  // 只有真正发请求才能验证；这里用不可达地址验证"报的是网络错而不是 body 错"
  const g = h.hostGlobals({ log: () => {} });
  let msg = '';
  try { g.req('http://127.0.0.1:1/nope', { method: 'GET', body: '', headers: {} }); }
  catch (e) { msg = String(e.message || e); }
  assert.ok(msg.startsWith('req 失败'), '应是网络错误而非 body 错误，实际: ' + msg);
  assert.ok(!/cannot have body/i.test(msg), 'GET 不该带 body: ' + msg);
});

console.log('── splitSeg（解析语法拆分）──');
t('无 && → sel + Text', () => {
  assert.deepStrictEqual(h.splitSeg('.a'), { sel: '.a', attr: 'Text' });
});
t('单 && → sel + attr', () => {
  assert.deepStrictEqual(h.splitSeg('.a&&href'), { sel: '.a', attr: 'href' });
});
t('多 && → 前段拼成后代选择器', () => {
  assert.deepStrictEqual(h.splitSeg('.a&&b&&Text'), { sel: '.a b', attr: 'Text' });
});

console.log(`\n结果: pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
