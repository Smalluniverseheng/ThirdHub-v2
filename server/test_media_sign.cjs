// ─────────────────────────────────────────────────────────────────────────────
// test_media_sign.cjs — 9528 媒体代理地址签名的单测
//
// 守的是什么（每一条都对应一个真实攻击面）：
//   1. 没签名 → 拒。          （`?u=http://10.0.0.1/` 拿 NAS 当内网跳板）
//   2. 改了 u → 拒。          （签名绑地址，不是绑会话）
//   3. 改了 r → 拒。          （Referer 也进签名）
//   4. 过期 → 拒。            （地址不能永久有效）
//   5. 未来有效期伪造 → 拒。  （改 e 必须重算 s，改不出来）
//   6. 正常签 → 过。          （播放链路不能被误伤）
//
// 跑法：node server/test_media_sign.cjs
'use strict';

const assert = require('assert');
const ms = require('./media-sign.js');

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; console.log('  PASS ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + (e && e.message)); }
}

const SECRET = 'thsec_test_0123456789abcdef';
const NOW = 1_760_000_000_000; // 固定时间，避免测试随真实时钟漂移
const U = 'https://v6.ppqrrs.com/a/b/index.m3u8';
const R = 'https://example.com/';

console.log('media-sign 单测');

t('没签名 → missing', () => {
  const v = ms.verify({ u: U }, SECRET, NOW);
  assert.strictEqual(v.ok, false);
  assert.strictEqual(v.reason, 'missing');
});

t('正常签名 → 通过', () => {
  const { e, s } = ms.sign(U, R, SECRET, 3600, NOW);
  const v = ms.verify({ u: U, r: R, e, s }, SECRET, NOW + 1000);
  assert.strictEqual(v.ok, true);
});

t('空 Referer 也能签能过', () => {
  const { e, s } = ms.sign(U, '', SECRET, 3600, NOW);
  assert.strictEqual(ms.verify({ u: U, e, s }, SECRET, NOW).ok, true);
});

t('改了 u → bad_sig', () => {
  const { e, s } = ms.sign(U, R, SECRET, 3600, NOW);
  const v = ms.verify({ u: 'http://10.0.0.1/', r: R, e, s }, SECRET, NOW);
  assert.strictEqual(v.ok, false);
  assert.strictEqual(v.reason, 'bad_sig');
});

t('改了 r → bad_sig', () => {
  const { e, s } = ms.sign(U, R, SECRET, 3600, NOW);
  const v = ms.verify({ u: U, r: 'https://evil.example/', e, s }, SECRET, NOW);
  assert.strictEqual(v.ok, false);
  assert.strictEqual(v.reason, 'bad_sig');
});

t('过期 → expired', () => {
  const { e, s } = ms.sign(U, R, SECRET, 60, NOW);
  // 60s 有效期 + 120s 时钟容忍 ⇒ 180s 后必过期
  const v = ms.verify({ u: U, r: R, e, s }, SECRET, NOW + 200_000);
  assert.strictEqual(v.ok, false);
  assert.strictEqual(v.reason, 'expired');
});

t('把 e 改大想续命 → bad_sig', () => {
  const { e, s } = ms.sign(U, R, SECRET, 60, NOW);
  const v = ms.verify({ u: U, r: R, e: String(Number(e) + 999999), s }, SECRET, NOW);
  assert.strictEqual(v.ok, false);
  assert.strictEqual(v.reason, 'bad_sig');
});

t('换个 secret 签 → bad_sig', () => {
  const { e, s } = ms.sign(U, R, 'another_secret', 3600, NOW);
  const v = ms.verify({ u: U, r: R, e, s }, SECRET, NOW);
  assert.strictEqual(v.ok, false);
  assert.strictEqual(v.reason, 'bad_sig');
});

t('s 长度被截断 → bad_sig 而不是抛异常', () => {
  const { e, s } = ms.sign(U, R, SECRET, 3600, NOW);
  const v = ms.verify({ u: U, r: R, e, s: s.slice(0, 10) }, SECRET, NOW);
  assert.strictEqual(v.ok, false);
  assert.strictEqual(v.reason, 'bad_sig');
});

t('e 不是数字 → bad_exp', () => {
  const v = ms.verify({ u: U, e: 'abc', s: 'x' }, SECRET, NOW);
  assert.strictEqual(v.reason, 'bad_exp');
});

t('appendSignature 拼出来的能被 verify 认', () => {
  const url = ms.appendSignature('http://h/thp/stream?u=' + encodeURIComponent(U), SECRET, 3600, NOW);
  const q = new URL(url).searchParams;
  const v = ms.verify({ u: q.get('u'), r: '', e: q.get('e'), s: q.get('s') }, SECRET, NOW);
  assert.strictEqual(v.ok, true, '拼出来的地址必须自洽');
});

t('同一秒签两次结果相同（幂等，不打乱播放器缓存）', () => {
  const a = ms.sign(U, R, SECRET, 3600, NOW);
  const b = ms.sign(U, R, SECRET, 3600, NOW);
  assert.deepStrictEqual(a, b);
});

console.log('\n结果：' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
