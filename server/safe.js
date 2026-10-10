/**
 * safe.js —— 出货面安全小工具（后端唯一收口点）
 *
 * ★ 为什么必须有这个文件：
 *   2026-10-10 审计发现 /s/<sid> 分享页把 `rec.name` **原样拼进 HTML**
 *   （同一函数里 /raw 分支却用了 encodeURIComponent —— 典型「修一处漏一处」）。
 *   全仓当时没有 escapeHtml，于是"要转义"这件事没有任何统一入口，
 *   谁想起来了谁转义。这里把它做成**必须走**的单一函数。
 *
 * ── 用法 ────────────────────────────────────────────────────────────────
 *   const { escapeHtml, safeHeaderValue, timingEqual, makeLimiter } = require('./safe');
 *   res.end(`<h3>${escapeHtml(rec.name)}</h3>`);      // ← 所有插入 HTML 的值
 *   res.setHeader('X-Foo', safeHeaderValue(v));        // ← 所有拼进响应头的值
 *   if (!timingEqual(got, SECRET)) return deny();      // ← 所有密钥比较
 */

'use strict';

/**
 * HTML 文本转义。**任何**用户可控字符串插进 HTML 前必须过它。
 * 转义 & < > " ' / 与反引号，杜绝属性逃逸与标签注入。
 */
function escapeHtml(v) {
  if (v === null || v === undefined) return '';
  return String(v)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/`/g, '&#96;');
}

/**
 * 用于响应头/Content-Disposition 的净化：剥掉 CR/LF（防响应头注入）
 * 与非 ASCII 控制字符。
 */
function safeHeaderValue(v) {
  if (v === null || v === undefined) return '';
  return String(v).replace(/[\r\n\u0000-\u001f\u007f]/g, '').trim();
}

/**
 * 常量时间字符串比较 —— 防时序侧信道。
 * 长度不同也走完整轮比较，再单独判长度，避免提前 return 泄露长度。
 */
function timingEqual(a, b) {
  const A = Buffer.from(String(a === null || a === undefined ? '' : a), 'utf8');
  const B = Buffer.from(String(b === null || b === undefined ? '' : b), 'utf8');
  const len = Math.max(A.length, B.length, 1);
  let diff = A.length ^ B.length;
  for (let i = 0; i < len; i++) diff |= (A[i] || 0) ^ (B[i] || 0);
  return diff === 0;
}

/**
 * 固定窗口内存限速器（防存储放大 / 防爆破）。
 *   const lim = makeLimiter({ windowMs: 60_000, max: 30 });
 *   if (!lim(key)) return send(429, ...);
 * 说明：单进程内存实现，重启即清空 —— 对家庭后端够用；
 * 它只解决「同一来源短时间内狂打」这一类，不替代 WAF。
 */
function makeLimiter(opts) {
  const o = opts || {};
  const windowMs = Number(o.windowMs) || 60_000;
  const max = Number(o.max) || 60;
  const maxKeys = Number(o.maxKeys) || 5000;   // 键表上限，防内存被撑爆
  const hits = new Map();
  return function allow(key) {
    const now = Date.now();
    const k = String(key || '-');
    // 顺手清理过期项（摊还 O(1)）
    if (hits.size > maxKeys) {
      for (const [kk, vv] of hits) if (now - vv.t > windowMs) hits.delete(kk);
      // 仍然过大 → 直接清空（宁可放宽一次，也不让内存无上限增长）
      if (hits.size > maxKeys) hits.clear();
    }
    let e = hits.get(k);
    if (!e || now - e.t > windowMs) { hits.set(k, { t: now, n: 1 }); return true; }
    e.n += 1;
    return e.n <= max;
  };
}

/** 只允许 http/https 的 URL（用于把用户给的地址回显/转发前的最低校验） */
function isHttpUrl(s) {
  try {
    const u = new URL(String(s));
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch (e) { return false; }
}

module.exports = { escapeHtml, safeHeaderValue, timingEqual, makeLimiter, isHttpUrl };
