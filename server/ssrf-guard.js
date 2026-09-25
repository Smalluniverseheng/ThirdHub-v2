// ─────────────────────────────────────────────────────────────────────────────
// ssrf-guard.js — 出站请求的「地址准入」纯函数层
//
// 为什么要有这个文件（`docs/TASKS.md` 组A「SSRF 防护」长期未完成）：
//   本后端有两个地方**拿外部给的 URL 直接去 fetch**：
//     ① 图片代理 `/v1/img?url=...`（`routes-sources.js`）—— `url` 完全由调用方给；
//     ② 引擎抓取（`engine.js`）—— URL 来自导入的书源规则（`searchUrl` / `tocUrl` …）。
//   两者此前**没有任何网段校验**。于是任何人（app 内浏览器里的一段脚本、
//   一个从网上导进来的书源、或 AI 工具）都能让这台后端去请求：
//     · `http://127.0.0.1:9527/v1/...`  → 绕过鉴权摸本机其它服务；
//     · `http://169.254.169.254/latest/meta-data/iam/...` → 云主机元数据（拿到临时凭证）；
//     · `http://192.168.x.x:xxxx/`      → 内网横向扫描。
//   这就是教科书式的 SSRF，且**这台机器的定位正好是"放在家里/云服务器上的常驻后端"**，
//   命中面比普通 Web 应用更大。
//
// 两种「内网」语义必须分清（很容易做错，做错就是功能被砍掉）：
//   · **出站抓取**（本文件默认）：目标是"互联网上的某个源站" → **禁止**私网/回环/链路本地/
//     元数据地址。这正是 `assertPublicUrl()`。
//   · **端网互联**（设备发现、配对、THP 握手）：目标**就是**局域网里的另一台设备 →
//     **必须允许**私网与 Tailscale 网段。这是 `isLanOrTailscale()`。
//   把两者混成一个判断，就会出现"要么把内网穿透打死、要么给 SSRF 留门"。
//
// 逃生阀：自建用户确实会把源放在自己的 NAS 上（那是本项目的主流用法之一），
//   所以提供 `TH_SSRF_ALLOW_PRIVATE=1` 显式放行私网。**默认关**——安全默认值必须是安全的那一侧。
//
// 本文件是**纯函数**（除 DNS 解析外无副作用），可直接单测，见 `test_ssrf_guard.cjs`。
'use strict';

const dns = require('dns');
const net = require('net');

/** 私网 / 特殊用途 IPv4 网段：[网络地址, 前缀长度, 说明] */
const V4_BLOCKED = [
  ['0.0.0.0', 8, 'this-network'],
  ['10.0.0.0', 8, 'RFC1918 私网'],
  ['100.64.0.0', 10, 'CGNAT（Tailscale 也用这段）'],
  ['127.0.0.0', 8, '回环'],
  ['169.254.0.0', 16, '链路本地 / 云元数据 169.254.169.254'],
  ['172.16.0.0', 12, 'RFC1918 私网'],
  ['192.0.0.0', 24, 'IETF 协议分配'],
  ['192.0.2.0', 24, 'TEST-NET-1'],
  ['192.88.99.0', 24, '6to4 中继'],
  ['192.168.0.0', 16, 'RFC1918 私网'],
  ['198.18.0.0', 15, '基准测试'],
  ['198.51.100.0', 24, 'TEST-NET-2'],
  ['203.0.113.0', 24, 'TEST-NET-3'],
  ['224.0.0.0', 4, '组播'],
  ['240.0.0.0', 4, '保留 / 广播'],
];

/** 私网 / 特殊用途 IPv6 网段 */
const V6_BLOCKED = [
  ['::', 128, '未指定'],
  ['::1', 128, '回环'],
  ['64:ff9b::', 96, 'NAT64 前缀'],
  ['100::', 64, '丢弃前缀'],
  ['2001:db8::', 32, '文档用'],
  ['fc00::', 7, 'ULA（唯一本地地址）'],
  ['fe80::', 10, '链路本地'],
  ['ff00::', 8, '组播'],
];

const BLOCKED_HOSTNAMES = new Set([
  'localhost', 'localhost.localdomain', 'ip6-localhost', 'ip6-loopback',
  'metadata', 'metadata.google.internal', 'metadata.goog',
]);

const ALLOW_PRIVATE = process.env.TH_SSRF_ALLOW_PRIVATE === '1';

/** IPv4 点分十进制 → 32 位无符号整数；非法返回 null。 */
function ip4ToInt(ip) {
  const parts = String(ip).split('.');
  if (parts.length !== 4) return null;
  let v = 0;
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p)) return null;
    const n = Number(p);
    if (n > 255) return null;
    v = (v * 256) + n;
  }
  return v >>> 0;
}

/** 判断一个 IPv4 是否落在某网段内。 */
function v4InCidr(ip, base, bits) {
  const a = ip4ToInt(ip), b = ip4ToInt(base);
  if (a === null || b === null) return false;
  if (bits === 0) return true;
  const mask = bits === 32 ? 0xFFFFFFFF : (~((1 << (32 - bits)) - 1)) >>> 0;
  return (a & mask) === (b & mask);
}

/** 把 IPv6 展开成 8 组 16 位（只做我们需要的程度：够比对前缀）。 */
function expandV6(ip) {
  let s = String(ip).trim().toLowerCase();
  if (s.startsWith('[') && s.endsWith(']')) s = s.slice(1, -1);
  const zone = s.indexOf('%');
  if (zone >= 0) s = s.slice(0, zone);
  // IPv4-mapped ::ffff:1.2.3.4 → 转成 v4 处理
  const m = s.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (m) return { mappedV4: m[1] };
  const halves = s.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const fill = 8 - head.length - tail.length;
  if (halves.length === 1 && head.length !== 8) return null;
  if (fill < 0) return null;
  const groups = [...head, ...Array(halves.length === 2 ? fill : 0).fill('0'), ...tail];
  if (groups.length !== 8) return null;
  const out = [];
  for (const g of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
    out.push(parseInt(g, 16));
  }
  return { groups: out };
}

function v6InCidr(ip, base, bits) {
  const a = expandV6(ip), b = expandV6(base);
  if (!a || !b || !a.groups || !b.groups) return false;
  let remaining = bits;
  for (let i = 0; i < 8 && remaining > 0; i++) {
    const take = Math.min(16, remaining);
    const mask = take === 16 ? 0xFFFF : (~((1 << (16 - take)) - 1)) & 0xFFFF;
    if ((a.groups[i] & mask) !== (b.groups[i] & mask)) return false;
    remaining -= take;
  }
  return true;
}

/**
 * 这个 IP 是否属于「私网 / 回环 / 链路本地 / 元数据 / 保留」等不可出站的目标。
 * 纯函数，无 IO。非法输入一律视为「不可出站」（fail-closed，宁严不松）。
 * @param {string} ip
 * @returns {boolean}
 */
function isBlockedIp(ip) {
  const s = String(ip || '').trim();
  if (!s) return true;
  if (net.isIPv4(s)) {
    for (const [base, bits] of V4_BLOCKED) {
      if (v4InCidr(s, base, bits)) return true;
    }
    return false;
  }
  if (net.isIPv6(s)) {
    const ex = expandV6(s);
    if (ex && ex.mappedV4) return isBlockedIp(ex.mappedV4); // ::ffff:a.b.c.d 按 v4 判
    for (const [base, bits] of V6_BLOCKED) {
      if (v6InCidr(s, base, bits)) return true;
    }
    return false;
  }
  return true; // 不是合法 IP → 拦
}

/**
 * 这个 IP 是否属于「局域网 / Tailscale」——即**端网互联**该允许、出站抓取该禁止的范围。
 * 与 `isBlockedIp` 的区别：这里把 RFC1918 与 CGNAT(100.64/10) 视为「允许」。
 */
function isLanOrTailscaleIp(ip) {
  const s = String(ip || '').trim();
  if (net.isIPv4(s)) {
    return v4InCidr(s, '10.0.0.0', 8)
      || v4InCidr(s, '172.16.0.0', 12)
      || v4InCidr(s, '192.168.0.0', 16)
      || v4InCidr(s, '100.64.0.0', 10)   // Tailscale / CGNAT
      || v4InCidr(s, '169.254.0.0', 16)  // 链路本地（设备直连/热点常见）
      || v4InCidr(s, '127.0.0.0', 8);    // 同机调试
  }
  if (net.isIPv6(s)) {
    const ex = expandV6(s);
    if (ex && ex.mappedV4) return isLanOrTailscaleIp(ex.mappedV4);
    return v6InCidr(s, 'fc00::', 7) || v6InCidr(s, 'fe80::', 10) || v6InCidr(s, '::1', 128);
  }
  return false;
}

/** 常见的内网/元数据主机名（DNS 解析前先拦一道，防解析绕过）。 */
function isBlockedHostname(host) {
  const h = String(host || '').toLowerCase().replace(/\.$/, '');
  if (!h) return true;
  if (BLOCKED_HOSTNAMES.has(h)) return true;
  if (h.endsWith('.localhost') || h.endsWith('.local') || h.endsWith('.internal')) return true;
  return false;
}

/** 从 URL 里取主机名（URL 解析失败返回 null）。 */
function hostOf(url) {
  try { return new URL(String(url)).hostname; } catch (_) { return null; }
}

/**
 * 出站抓取前的**地址准入**校验（含 DNS 解析 + 逐 IP 判定）。
 *
 * 解析出的**每一个** IP 都必须是公网 —— 只要有一个落在禁止段就拒绝。
 * 为什么要求全部：攻击者可以让域名同时解析出 1.2.3.4 与 127.0.0.1，
 * fetch 走哪个不由我们决定（这就是 DNS rebinding 的常见变体）。
 *
 * @param {string} url 待抓取地址（仅允许 http/https）
 * @param {{allowPrivate?: boolean, resolver?: Function}} [opts]
 *        resolver 注入点：单测里换成假解析器，避免真的走 DNS。
 * @returns {Promise<{ok: true, ips: string[]} | {ok: false, reason: string}>}
 */
async function assertPublicUrl(url, opts = {}) {
  const allowPrivate = opts.allowPrivate === undefined ? ALLOW_PRIVATE : !!opts.allowPrivate;
  let parsed;
  try { parsed = new URL(String(url)); } catch (_) { return { ok: false, reason: 'invalid_url' }; }
  const proto = parsed.protocol;
  if (proto !== 'http:' && proto !== 'https:') return { ok: false, reason: 'scheme_not_allowed:' + proto };
  const host = parsed.hostname;
  if (!host) return { ok: false, reason: 'no_host' };

  // 1) 直接就是 IP 字面量：不用解析，直接判
  const literal = host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host;
  if (net.isIP(literal)) {
    if (allowPrivate) return { ok: true, ips: [literal] };
    if (isBlockedIp(literal)) return { ok: false, reason: 'blocked_ip:' + literal };
    return { ok: true, ips: [literal] };
  }

  // 2) 主机名黑名单（解析前）
  if (isBlockedHostname(host)) {
    if (allowPrivate) return { ok: true, ips: [] };
    return { ok: false, reason: 'blocked_hostname:' + host };
  }

  // 3) DNS 解析，逐个 IP 判
  const resolve = opts.resolver || dns.promises.lookup;
  let addrs;
  try {
    const r = await resolve(host, { all: true, verbatim: true });
    addrs = Array.isArray(r) ? r : [r];
  } catch (e) {
    return { ok: false, reason: 'dns_failed:' + (e && e.code ? e.code : 'error') };
  }
  const ips = addrs.map(a => (a && a.address) || String(a)).filter(Boolean);
  if (!ips.length) return { ok: false, reason: 'dns_empty' };
  if (!allowPrivate) {
    for (const ip of ips) {
      if (isBlockedIp(ip)) return { ok: false, reason: 'blocked_ip:' + ip };
    }
  }
  return { ok: true, ips };
}

/**
 * 带地址准入的 `fetch`：**逐跳**校验（每一跳重定向都重新判一次）。
 *
 * 为什么不能只判初始 URL：只判第一跳的话，`http://pub.example/x` 只要回一个
 * `302 Location: http://169.254.169.254/` 就绕过去了 —— 这是 SSRF 最常见的绕过手法。
 * 所以这里手动跟随重定向（`redirect: 'manual'`），每次跳转前再跑一遍 `assertPublicUrl`。
 *
 * @param {string} url
 * @param {RequestInit & {timeoutMs?: number, maxRedirects?: number, allowPrivate?: boolean}} [init]
 */
async function safeFetch(url, init = {}) {
  const { timeoutMs = 10000, maxRedirects = 5, allowPrivate, ...rest } = init;
  let current = String(url);
  for (let hop = 0; hop <= maxRedirects; hop++) {
    const gate = await assertPublicUrl(current, { allowPrivate });
    if (!gate.ok) {
      const err = new Error('SSRF 拦截: ' + gate.reason);
      err.code = 'TH_SSRF_BLOCKED';
      err.reason = gate.reason;
      throw err;
    }
    const r = await fetch(current, { ...rest, redirect: 'manual', signal: AbortSignal.timeout(timeoutMs) });
    const isRedirect = r.status >= 300 && r.status < 400 && r.headers.get('location');
    if (!isRedirect) return r;
    const loc = new URL(r.headers.get('location'), current).toString();
    current = loc;
  }
  const err = new Error('SSRF 拦截: too_many_redirects');
  err.code = 'TH_SSRF_BLOCKED';
  err.reason = 'too_many_redirects';
  throw err;
}

/** 给业务层统一判定"这次报错是不是被准入拦了"。 */
function isSsrfBlocked(e) {
  return !!(e && (e.code === 'TH_SSRF_BLOCKED' || String(e.message || '').includes('SSRF 拦截')));
}

module.exports = {
  isBlockedIp,
  isLanOrTailscaleIp,
  isBlockedHostname,
  hostOf,
  assertPublicUrl,
  safeFetch,
  isSsrfBlocked,
  ALLOW_PRIVATE,
  // 导出常量便于单测与文档引用
  V4_BLOCKED,
  V6_BLOCKED,
};
