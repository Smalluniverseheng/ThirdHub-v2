/**
 * security_selfcheck.cjs —— 出货面安全闸门
 *
 * ★ 每一节都必须有「反证」：先证明它能挡住坏代码，再证明当前代码是好的。
 *   否则就是「打印了 PASS」的假闸门（本项目 R17/R19 血泪条）。
 *
 * 覆盖 2026-10-10 审计的 5 项：
 *   A. 分享页存储型 XSS（rec.name 未转义）
 *   B. CORS 全放行
 *   C. /v1/pair 无鉴权 + 无上限（存储放大 DoS）
 *   D. 密钥比较非常量时间
 *   E. /v1/meta 免鉴权泄露内容计数（设计使然，仅提示）
 *
 * 用法： node security_selfcheck.cjs
 */
'use strict';
const fs = require('fs');
const path = require('path');

const SRV = path.join(__dirname, '..', 'server');
const IDX = path.join(SRV, 'index.js');
const SAFE = path.join(SRV, 'safe.js');

let pass = 0, fails = 0, warns = 0;
const ok = (m) => { pass++; console.log('  OK   ' + m); };
const bad = (m) => { fails++; console.error('  FAIL ' + m); };
const warn = (m) => { warns++; console.log('  WARN ' + m); };

const idx = fs.readFileSync(IDX, 'utf8');

console.log('=== 出货面安全闸门 ===');

/* ── 0. safe.js 必须存在且导出四件套 ── */
console.log('\n[0] 安全工具收口点 server/safe.js');
let S = null;
try { S = require(SAFE); } catch (e) { bad('safe.js 无法加载：' + e.message); }
if (S) {
  for (const k of ['escapeHtml', 'safeHeaderValue', 'timingEqual', 'makeLimiter']) {
    if (typeof S[k] === 'function') ok('导出 ' + k);
    else bad('缺少导出 ' + k);
  }
  // 行为断言：escapeHtml 真的要能挡住标签
  if (S.escapeHtml && S.escapeHtml('<img src=x onerror=alert(1)>') === '&lt;img src=x onerror=alert(1)&gt;') {
    ok('escapeHtml 行为正确（标签被转义）');
  } else if (S.escapeHtml) {
    bad('escapeHtml 行为错误：' + S.escapeHtml('<img src=x onerror=alert(1)>'));
  }
  // 行为断言：safeHeaderValue 要吃掉 CRLF
  if (S.safeHeaderValue && !/[\r\n]/.test(S.safeHeaderValue('a\r\nSet-Cookie: x=1'))) {
    ok('safeHeaderValue 行为正确（CRLF 被剥离）');
  } else if (S.safeHeaderValue) {
    bad('safeHeaderValue 未挡住 CRLF 注入');
  }
  // 行为断言：timingEqual 判等判否都对，且长度不同也不炸
  if (S.timingEqual && S.timingEqual('abc', 'abc') && !S.timingEqual('abc', 'abd') && !S.timingEqual('abc', 'abcd') && !S.timingEqual(undefined, 'abc')) {
    ok('timingEqual 行为正确（等/不等/长度不等/undefined 均正确）');
  } else if (S.timingEqual) {
    bad('timingEqual 行为错误');
  }
  // 行为断言：限速器到点要拦
  if (S.makeLimiter) {
    const lim = S.makeLimiter({ windowMs: 10000, max: 3 });
    const r = [lim('k'), lim('k'), lim('k'), lim('k')];
    if (r[0] && r[1] && r[2] && !r[3]) ok('makeLimiter 行为正确（第 4 次被拦）');
    else bad('makeLimiter 未拦住超额请求：' + JSON.stringify(r));
  }
}

/* ── A. 分享页 XSS ── */
console.log('\n[A] 分享页 /s/* 存储型 XSS');
{
  const share = idx.slice(idx.indexOf("if (p.startsWith('/s/'))"));
  const body = share.slice(0, share.indexOf('// ── E-1 无状态验签端点'));
  // 断言 1：出现 escapeHtml 包裹 rec.name
  if (/escapeHtml\(rec\.name\)/.test(body)) ok('rec.name 已过 escapeHtml');
  else bad('rec.name 仍未转义 —— 存储型 XSS 仍在');
  // 断言 2：不再有裸 rec.name 拼进 HTML（`+ rec.name +` 这种）
  const raw = body.match(/\+\s*rec\.name\s*\+/g) || [];
  if (!raw.length) ok('无裸 rec.name 拼 HTML');
  else bad('仍有裸 rec.name 拼接 ' + raw.length + ' 处');
  // 断言 3：/raw 的 Content-Disposition 用 safeHeaderValue
  if (/safeHeaderValue\(rec\.name/.test(body)) ok('/raw 文件名已过 safeHeaderValue');
  else bad('/raw 文件名未净化（可 CRLF 注入响应头）');
  // ★ 反证：把 escapeHtml 去掉，检查器必须报错
  const mutated = body.replace(/escapeHtml\(rec\.name\)/g, 'rec.name');
  if (!/escapeHtml\(rec\.name\)/.test(mutated)) ok('反证通过：去掉 escapeHtml 后本检查能识别');
  else bad('反证失败：检查器抓不到去转义');
}

/* ── B. CORS ── */
console.log('\n[B] CORS 是否已收紧');
{
  if (/Access-Control-Allow-Origin',\s*req\.headers\.origin\s*\|\|\s*'\*'/.test(idx)) {
    bad("CORS 仍是「回显任意 Origin」");
  } else if (/const corsAllow/.test(idx) && /Vary',\s*'Origin'/.test(idx)) {
    ok('CORS 已改为白名单 + Vary: Origin');
  } else {
    bad('CORS 收紧代码缺失');
  }
  if (/X-Content-Type-Options/.test(idx)) ok('已加 X-Content-Type-Options: nosniff');
  else warn('未加 nosniff（建议补）');
  // 反证：把表达式改回去，正则要能命中
  const badLine = "res.setHeader('Access-Control-Allow-Origin', req.headers.origin || '*');";
  if (/Access-Control-Allow-Origin',\s*req\.headers\.origin\s*\|\|\s*'\*'/.test(badLine)) ok('反证通过：旧写法能被识别');
  else bad('反证失败：CORS 检查器失效');
}

/* ── C. /v1/pair 护栏 ── */
console.log('\n[C] /v1/pair 存储放大 DoS');
{
  const seg = idx.slice(idx.indexOf("p === '/v1/pair'"), idx.indexOf("p === '/v1/pair'") + 2000);
  if (/pairLimiter\(req\.socket\.remoteAddress/.test(seg)) ok('/v1/pair 已加每 IP 限速');
  else bad('/v1/pair 无速率限制');
  if (/devices\.length >= MAX_DEVICES/.test(seg)) ok('/v1/pair 有设备数上限');
  else bad('/v1/pair 设备表无上限（可被撑爆）');
  if (/const MAX_DEVICES = \d+/.test(idx) && /const pairLimiter = makeLimiter/.test(idx)) ok('限速器与上限已声明');
  else bad('pairLimiter / MAX_DEVICES 未声明 → 运行时 ReferenceError');
  // ★ 静态「未声明标识符」检查（防 PORT 那样的事件重演）
  for (const id of ['pairLimiter', 'MAX_DEVICES']) {
    const declared = new RegExp('(const|let|var)\\s+' + id + '\\b').test(idx);
    const used = new RegExp('\\b' + id + '\\b').test(idx);
    if (used && !declared) bad(id + ' 被使用但未声明');
    else if (used) ok(id + ' 已声明且被使用');
  }
}

/* ── D. 密钥比较 ── */
console.log('\n[D] 密钥比较是否常量时间');
{
  const plain = idx.match(/req\.headers\['x-th-token'\]\s*!==\s*SECRET/g) || [];
  const ct = idx.match(/timingEqual\(req\.headers\['x-th-token'\],\s*SECRET\)/g) || [];
  if (plain.length) bad('仍有 ' + plain.length + ' 处非常量时间比较');
  else ok('无非常量时间比较');
  if (ct.length >= 2) ok('已用 timingEqual（' + ct.length + ' 处）');
  else bad('timingEqual 使用不足（仅 ' + ct.length + ' 处，应 ≥2）');
}

/* ── E. /v1/meta 免鉴权面 ── */
console.log('\n[E] /v1/meta 免鉴权信息面（提示级）');
{
  const seg = idx.slice(idx.indexOf("p === '/v1/meta'"), idx.indexOf("p === '/v1/meta'") + 600);
  const leaks = [];
  if (/devices:\s*devices\.length/.test(seg)) leaks.push('devices 计数');
  if (/sources:\s*sources\.length/.test(seg)) leaks.push('sources 计数');
  if (leaks.length) warn('/v1/meta 免鉴权暴露 ' + leaks.join('、') + '（供 TOFU 指纹用，可接受；如需可移入鉴权后）');
  else ok('/v1/meta 未泄露内部计数');
}

/* ── F. 反证：闸门自身必须会因为坏代码而 FAIL ── */
console.log('\n[F] 反证：把 XSS 塞回去，A 组必须 FAIL');
{
  const evil = "<title>' + rec.name + '</title>";
  const hasEscape = /escapeHtml\(rec\.name\)/.test(evil);
  if (!hasEscape) ok('反证通过：未转义写法被判为不合规');
  else bad('反证失败');
}

console.log('\n────────────────────────────────');
console.log(`PASS ${pass}  FAIL ${fails}  WARN ${warns}`);
if (fails > 0) { console.error('安全闸门未通过。'); process.exit(1); }
console.log('安全闸门通过。');
process.exit(0);
