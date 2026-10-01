'use strict';
// D-E3 补充：DOM 层行为验证
//
// 为什么还要这一层（上一支 test_feedback_page.cjs 已经 PASS 24）：
//   上一支证的是**接口契约**（401/往返/字节一致）。但页面里 loadFeedback()
//   是**字符串拼 HTML**，拼错了接口全绿、页面照样白 —— 典型如：
//     · 漏了闭合引号 → 按钮点了没反应（不报错，只是没反应）
//     · esc() 漏用在某一处 → XSS
//     · 忘了 window.__fb=list → 「查看图片」永远 undefined
//   这些只有把脚本真跑一遍、看它吐出来的标记才能发现。
//   所以这里用最小 DOM 桩 + 真实 fetch 跑真函数，断言产出的 HTML 与 DOM 操作。
//
// 用法：node server/scripts/test_feedback_dom.cjs [https://host:9527]
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const fs = require('fs');
const path = require('path');

const BASE = process.argv[2] || 'https://127.0.0.1:9527';
const TOK = fs.readFileSync(path.join(__dirname, '..', 'data', 'secret'), 'utf8').trim();

// ★ 先把原生 fetch 抓在手里，再包一层：不要在 global 上覆盖 fetch，
//   否则 wrapper 里再读 globalThis.fetch 就会读到自己 → 无限递归。
//   这里干脆不碰 global.fetch，只把 wrapper 作为参数传进沙箱（body 里的
//   fetch 会被形参遮蔽）。
const nativeFetch = globalThis.fetch.bind(globalThis);
const lanFetch = (p, opt) => nativeFetch(BASE + p, opt || {});

let pass = 0, fail = 0;
const ck = (n, ok, ex) => { ok ? (pass++, console.log('  PASS  ' + n)) : (fail++, console.log('  FAIL  ' + n + (ex ? '  → ' + ex : ''))); };

// ── 最小 DOM 桩：只要够跑这个页面的那几条路径 ──
class El {
  constructor(tag) { this.tagName = (tag || 'div').toUpperCase(); this.children = []; this.style = { cssText: '' }; this.dataset = {}; this._text = ''; this._html = ''; }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() { return this._text; }
  set innerHTML(v) { this._html = String(v); }
  get innerHTML() { return this._html; }
  appendChild(c) { this.children.push(c); return c; }
  querySelector() { return null; }
}
const registry = {};
const mk = id => registry[id] || (registry[id] = new El('div'));
const docStub = {
  querySelector: s => (s.startsWith('#') ? mk(s.slice(1)) : null),
  getElementById: id => registry[id] || null,
  createElement: t => new El(t),
  querySelectorAll: () => [],
};
const urlStub = { createObjectURL: () => 'blob:fake' };
const lsStub = { th_lang: 'zh', th_token: TOK };
const winStub = {};

function build(win) {
  const html = fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');
  // 抽出真实 <script> 体；去掉会自动开跑的最后一行（我们要自己控节奏）
  const body = html.match(/<script>([\s\S]*?)<\/script>/)[1]
    .replace(/^T\?boot\(\):lock\(true\);$/m, '');
  return new Function('document', 'window', 'localStorage', 'fetch', 'URL',
    body + '\nreturn { loadFeedback, toggleFbImg, esc, fmtTime };'
  )(docStub, win, lsStub, lanFetch, urlStub);
}

(async () => {
  const mk1 = 'dom-' + Date.now().toString(36);
  const post = (t, extra) => nativeFetch(BASE + '/v1/feedback', {
    method: 'POST', headers: { 'X-TH-Token': TOK, 'Content-Type': 'application/json' },
    body: JSON.stringify(Object.assign({ text: t, device: 'node', version: '1.2.3' }, extra || {})),
  });
  const r1 = await post('正常反馈 ' + mk1, { contact: 'a@b.c' });
  const xssText = '<img src=x onerror=alert(1)>' + mk1;
  const r2 = await post(xssText, { images: ['iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='] });
  ck('前置：两条测试反馈写入成功', r1.status === 200 && r2.status === 200, r1.status + '/' + r2.status);

  const a = build(winStub);
  ck('esc() 把 < > " & 都转义', a.esc('<img onerror="x">&\'') === '&lt;img onerror=&quot;x&quot;&gt;&amp;&#39;', a.esc('<img onerror="x">&\''));
  ck('fmtTime() 产出 yyyy-MM-dd HH:mm', /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(a.fmtTime(Date.now())), a.fmtTime(Date.now()));

  const box = mk('fblist');
  await a.loadFeedback();
  const out = box._html || box._text;

  ck('loadFeedback() 真的把列表写进了容器', out.length > 50, 'len=' + out.length);
  ck('产出含刚写入的正常反馈', out.includes('正常反馈 ' + mk1));
  ck('★ XSS 载荷被转义（输出里没有裸的 <img ... onerror）', !/<img[^>]*onerror/i.test(out));
  ck('★ 转义后仍可读（保留 &lt;img 形态）', out.includes('&lt;img'));
  ck('含「查看图片」按钮（有图那条）', out.includes('toggleFbImg(') && out.includes('查看图片'));
  ck('含联系方式 / 设备 / 版本元信息', out.includes('a@b.c') && out.includes('node') && out.includes('v1.2.3'));
  ck('最新在最前（XSS 那条后写，应排在正常那条前面）', out.indexOf('&lt;img') < out.indexOf('正常反馈 ' + mk1));
  ck('window.__fb 已挂（否则「查看图片」永远 undefined）', Array.isArray(winStub.__fb) && winStub.__fb.length > 0);

  const idx = (winStub.__fb || []).findIndex(m => String(m.text).startsWith('<img'));
  const holder = mk('fbimg' + idx);
  const btn = new El('button');
  ck('数据里能找到带图那条（用来测展开）', idx >= 0, 'idx=' + idx);
  if (idx >= 0) {
    await a.toggleFbImg(idx, btn);
    ck('toggleFbImg() 展开后 display=block', holder.style.display === 'block');
    ck('toggleFbImg() 按钮文案变「收起图片」', String(btn.textContent).startsWith('收起图片'), String(btn.textContent));
    ck('toggleFbImg() 取到 blob 并塞进了 <img> 子节点', holder.children.length >= 1 && holder.children[0].tagName === 'IMG', 'n=' + holder.children.length);
    ck('展开的 <img> 有 src', !!holder.children[0].src);
    // 再点一次应收回
    await a.toggleFbImg(idx, btn);
    ck('再点一次 → 收回（display=none 且文案复位）', holder.style.display === 'none' && String(btn.textContent).startsWith('查看图片'), holder.style.display + '/' + btn.textContent);
  }

  console.log('\n== PASS ' + pass + ' / FAIL ' + fail + ' ==');
  if (fail > 0) process.exit(1);
})().catch(e => { console.log('  FAIL  脚本异常: ' + (e && e.stack || e)); process.exit(1); });
