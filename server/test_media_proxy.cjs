// ─────────────────────────────────────────────────────────────────────────────
// test_media_proxy.cjs — 9528 媒体代理的端到端验证（真起服务、真发请求）
//
// 为什么不能只测纯函数：真正要证明的是「攻击手法现在打不动了」，
// 而攻击面在 handler 里（签名校验 → 并发 → SSRF 准入 这条链）。
// 单测签名只能证明公式对，证明不了 handler 用上了它。
//
// 覆盖：
//   ① 无签名摸内网   → 403（以前是 200 + 路由器后台源码）
//   ② 伪造签名       → 403
//   ③ 签名对但目标是内网 → 403（说明准入没被签名顶掉）
//   ④ 签名对且目标是回环 → 403
//   ⑤ 签名对且目标是公网 → 200（说明播放链路没被误伤）
//   ⑥ wrapMedia 下发的地址自带 e/s
//
// 跑法：node server/test_media_proxy.cjs   （需要能出网）
'use strict';

const http = require('http');
const net = require('net');

const SECRET = 'thsec_e2e_' + Math.random().toString(16).slice(2);

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

async function main() {
  const port = await freePort();
  process.env.TH_MEDIA_PORT = String(port);
  process.env.TH_LAN_URL = 'http://127.0.0.1:' + port; // 让 mediaBase() 指向测试实例
  process.env.TH_MEDIA_SECRET = SECRET;
  process.env.TH_MEDIA_SIGN = '1';

  const thp = require('./routes-thp.js'); // require 即启动媒体代理
  const ms = require('./media-sign.js');
  await new Promise((r) => setTimeout(r, 600)); // 等 listen 完成

  const get = (path) => new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path, timeout: 20000 }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8').slice(0, 200) }));
    });
    req.on('error', (e) => resolve({ status: 0, body: String(e && e.message) }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: 'timeout' }); });
  });

  const q = (u, extra = '') => '/thp/stream?u=' + encodeURIComponent(u) + extra;

  let pass = 0, fail = 0;
  const t = async (name, fn) => {
    try { await fn(); pass++; console.log('  PASS ' + name); }
    catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + (e && e.message)); }
  };
  const eq = (got, want, what) => {
    if (got !== want) throw new Error((what || '') + ' 期望 ' + want + '，实得 ' + got);
  };

  console.log('媒体代理端到端（端口 ' + port + '）');

  await t('① 无签名摸内网 → 403（原来这里是 200）', async () => {
    const r = await get(q('http://10.0.0.1/'));
    eq(r.status, 403, '无签名内网请求');
    if (!/missing/.test(r.body)) throw new Error('应提示 missing，实得：' + r.body);
  });

  await t('② 伪造签名 → 403', async () => {
    const r = await get(q('http://10.0.0.1/', '&e=' + (Math.floor(Date.now() / 1000) + 600) + '&s=deadbeef'));
    eq(r.status, 403, '伪造签名');
    if (!/bad_sig/.test(r.body)) throw new Error('应提示 bad_sig，实得：' + r.body);
  });

  await t('③ 签名有效但目标是内网 → 403（准入没被签名顶掉）', async () => {
    const u = 'http://10.0.0.1/';
    const { e, s } = ms.sign(u, '', SECRET);
    const r = await get(q(u, '&e=' + e + '&s=' + encodeURIComponent(s)));
    eq(r.status, 403, '签名对+内网目标');
    if (!/SSRF|forbidden/.test(r.body)) throw new Error('应由准入拦下，实得：' + r.body);
  });

  await t('④ 签名有效但目标是回环 → 403', async () => {
    const u = 'http://127.0.0.1:9527/v1/meta';
    const { e, s } = ms.sign(u, '', SECRET);
    const r = await get(q(u, '&e=' + e + '&s=' + encodeURIComponent(s)));
    eq(r.status, 403, '签名对+回环目标');
  });

  await t('⑤ 签名有效 + 公网目标 → 200（播放链路没被误伤）', async () => {
    const u = 'https://api.github.com/zen';
    const { e, s } = ms.sign(u, '', SECRET);
    const r = await get(q(u, '&e=' + e + '&s=' + encodeURIComponent(s)));
    eq(r.status, 200, '正常转发的公网请求');
  });

  await t('⑥ wrapMedia 下发的地址自带 e/s 且自洽', async () => {
    const u = 'https://example.com/x.m3u8';
    const wrapped = thp.wrapMedia(u);
    const sp = new URL(wrapped).searchParams;
    eq(sp.get('u'), u, 'wrapMedia 的 u');
    if (!sp.get('e') || !sp.get('s')) throw new Error('wrapMedia 没带签名：' + wrapped);
    const v = ms.verify({ u: sp.get('u'), r: sp.get('r') || '', e: sp.get('e'), s: sp.get('s') }, SECRET);
    eq(v.ok, true, 'wrapMedia 的签名自洽');
  });

  await t('⑦ 过期地址 → 403 expired', async () => {
    const u = 'https://example.com/y.m3u8';
    const { e, s } = ms.sign(u, '', SECRET, 1, Date.now() - 10 * 3600 * 1000); // 10 小时前就过期
    const r = await get(q(u, '&e=' + e + '&s=' + encodeURIComponent(s)));
    eq(r.status, 403, '过期地址');
    if (!/expired/.test(r.body)) throw new Error('应提示 expired，实得：' + r.body);
  });

  console.log('\n结果：' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error('测试异常：', e); process.exit(1); });
