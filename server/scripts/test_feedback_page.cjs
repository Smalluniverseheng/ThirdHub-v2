'use strict';
// D-E3 管理台反馈页 —— 端到端验证（打真实运行中的后端，不是读源码猜）
//
// 为什么要有这个脚本：
//   反馈页的四个环节**每一个单独看都像对的**，但串起来才成立：
//     ① 页面能抓到新版（server 每请求 readFileSync，不是启动时缓存）
//     ② 列表端点要过 401 闸门（带 X-TH-Token 才 200）
//     ③ 图片端点**也**在闸门之后 —— 所以 <img src> 必然 401，
//        页面里的 apiBlob() 才是唯一可行路径。这条不测就发现不了：
//        页面上「查看图片」永远转圈，而控制台里看不到任何报错。
//     ④ 用户正文会被拼进 innerHTML → 必须转义，否则一条 `<img onerror=...>`
//        反馈就能在管理台里执行脚本。
//   把 ①②③④ 一次性断言掉，比在浏览器里手点强，也不会随会话丢失。
//
// 用法：node server/scripts/test_feedback_page.cjs            （默认 https://127.0.0.1:9527）
//       node server/scripts/test_feedback_page.cjs https://host:9527
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// 自签证书 → 关掉校验证书（只针对本脚本的 loopback 测试）
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const BASE = process.argv[2] || 'https://127.0.0.1:9527';
const SECRET_FILE = path.join(__dirname, '..', 'data', 'secret');

let pass = 0, fail = 0;
function ck(name, ok, extra) {
  if (ok) { pass++; console.log('  PASS  ' + name); }
  else { fail++; console.log('  FAIL  ' + name + (extra ? '  → ' + extra : '')); }
}
async function req(p, opt) {
  const r = await fetch(BASE + p, opt || {});
  const buf = Buffer.from(await r.arrayBuffer());
  const ct = r.headers.get('content-type') || '';
  let json = null;
  if (ct.includes('json')) { try { json = JSON.parse(buf.toString('utf8')); } catch (e) {} }
  return { status: r.status, ct, buf, text: buf.toString('utf8'), json };
}

(async () => {
  console.log('== D-E3 管理台反馈页 e2e ==  ' + BASE);

  if (!fs.existsSync(SECRET_FILE)) { console.log('  FAIL  找不到 ' + SECRET_FILE + '（后端还没启动过？）'); process.exit(1); }
  const TOK = fs.readFileSync(SECRET_FILE, 'utf8').trim();
  const H = { 'X-TH-Token': TOK };

  // ── ① 页面本身 ──
  const page = await req('/');
  ck('① GET / → 200 且是 html', page.status === 200 && page.ct.includes('text/html'), 'status=' + page.status + ' ct=' + page.ct);
  ck('① 页面含「反馈」tab 注册', page.text.includes("['feedback','反馈']"));
  ck('① 页面含 loadFeedback()', page.text.includes('async function loadFeedback()'));
  ck('① 页面含 apiBlob()（图片必须走 blob，因为 <img> 带不了请求头）', page.text.includes('async function apiBlob('));
  ck('① 页面含 esc() 转义（反馈正文是用户输入，直拼 innerHTML = XSS）', page.text.includes('function esc('));
  const emo = page.text.match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{1F000}-\u{1F2FF}\u{2B00}-\u{2BFF}]/gu);
  ck('① 页面零 UI emoji（D-H2）', !emo, emo ? emo.join(' ') : '');
  ck('① 反馈正文已转义后再拼（esc(f.text)）', page.text.includes('esc(f.text)'));

  // ── ② 鉴权闸门 ──
  const noTok = await req('/v1/feedback');
  ck('② 无 token GET /v1/feedback → 401（不能裸奔）', noTok.status === 401, 'status=' + noTok.status);
  const noTokImg = await req('/v1/feedback/img?f=x.jpg');
  ck('② 无 token GET /v1/feedback/img → 401（★所以 <img src> 必然失败）', noTokImg.status === 401, 'status=' + noTokImg.status);

  // ── ③ 写 → 读 往返，含图片 ──
  const PNG1x1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  const marker = 'e2e-' + crypto.randomBytes(4).toString('hex');
  const post = await req('/v1/feedback', {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...H },
    body: JSON.stringify({ text: '自动化验证 ' + marker, contact: 'tester', device: 'node-e2e', version: '4.test', images: [PNG1x1] }),
  });
  ck('③ POST /v1/feedback → 200 且 saved', post.status === 200 && post.json && post.json.data && post.json.data.saved === true, 'status=' + post.status);
  ck('③ 服务端确认存下 1 张图', !!(post.json && post.json.data && post.json.data.images === 1), JSON.stringify(post.json && post.json.data));

  const list = await req('/v1/feedback', { headers: H });
  ck('③ 带 token GET → 200 list 结构', list.status === 200 && list.json && list.json.object === 'list' && Array.isArray(list.json.data), 'status=' + list.status);
  const mine = (list.json && list.json.data || []).find(m => String(m.text || '').includes(marker));
  ck('③ 刚写入的那条能读回来（写入→列表闭环）', !!mine);
  ck('③ 列表按时间倒序（最新在最前）', !!(list.json && list.json.data && list.json.data.length > 1 && list.json.data[0].at >= list.json.data[1].at));

  if (mine) {
    ck('③ 记录字段齐全（device/version/contact/at）', mine.device === 'node-e2e' && mine.version === '4.test' && mine.contact === 'tester' && typeof mine.at === 'number', JSON.stringify(mine).slice(0, 160));
    ck('③ 图片名已落到 images 数组', Array.isArray(mine.images) && mine.images.length === 1, JSON.stringify(mine.images));

    // ── ④ 图片真的取得到（模拟页面里的 apiBlob）──
    if (mine.images && mine.images.length) {
      const img = await req('/v1/feedback/img?f=' + encodeURIComponent(mine.images[0]), { headers: H });
      ck('④ 带 token 取图片 → 200', img.status === 200, 'status=' + img.status);
      ck('④ 图片 content-type 是 image/jpeg', img.ct.includes('image/jpeg'), img.ct);
      ck('④ 图片字节非空（>0）', img.buf.length > 0, 'len=' + img.buf.length);
      ck('④ 图片字节与上传的 PNG 完全一致（没有二次编码损坏）',
        crypto.createHash('sha256').update(img.buf).digest('hex') === crypto.createHash('sha256').update(Buffer.from(PNG1x1, 'base64')).digest('hex'));
    }
    // 路径穿越：f 会被 path.basename 剥离，取不到就应是 404 而不是 200
    const trav1 = await req('/v1/feedback/img?f=' + encodeURIComponent('../../secret'), { headers: H });
    ck('④ 路径穿越 ../../secret → 不是 200（basename 兜住）', trav1.status !== 200, 'status=' + trav1.status);
    const trav2 = await req('/v1/feedback/img?f=nope_' + marker + '.jpg', { headers: H });
    ck('④ 不存在的图 → 404', trav2.status === 404, 'status=' + trav2.status);
  }

  // ── ⑤ 输入校验（空/超长不该被静默接收）──
  const empty = await req('/v1/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json', ...H }, body: JSON.stringify({ text: '   ' }) });
  ck('⑤ 空正文 → 400', empty.status === 400, 'status=' + empty.status);
  const huge = await req('/v1/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json', ...H }, body: JSON.stringify({ text: 'x'.repeat(8001) }) });
  ck('⑤ 超长正文(>8000) → 413', huge.status === 413, 'status=' + huge.status);

  console.log('\n== PASS ' + pass + ' / FAIL ' + fail + ' ==');
  if (fail > 0) process.exit(1);
})().catch(e => { console.log('  FAIL  脚本异常: ' + (e && e.stack || e)); process.exit(1); });
