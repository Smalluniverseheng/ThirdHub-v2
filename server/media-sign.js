// ─────────────────────────────────────────────────────────────────────────────
// media-sign.js — 9528 媒体代理的「地址签名」纯函数层
//
// 为什么要有这个文件（`docs/TASKS.md` 组A「9528 无鉴权开放代理」）：
//   `routes-thp.js` 为了修 B 站黑屏，把播放地址改写成
//     http://<nas>:9528/thp/stream?u=<原始地址>
//   然后 `srv.listen(MEDIA_PORT, '0.0.0.0')`（容器是 host 网络 → 暴露在所有网卡）。
//   handler 里 `fetch(target, { redirect: 'follow' })` —— **无 token、无白名单、
//   无私网过滤**，还回 `Access-Control-Allow-Origin: *`。
//   实测（不带任何凭据）：
//     GET :9528/thp/stream?u=http://10.0.0.1/        → 200 / 小米路由器后台 HTML
//     GET :9528/thp/stream?u=http://10.0.0.156:5666/ → 200 / fnOS 管理首页
//   也就是**任何人只要能连到这台 NAS，就能拿它当跳板摸整条内网**。
//   （`file://` 是当时唯一有效的防护，因为正则只放 http/https。）
//
// 为什么不能直接关端口：ExoPlayer 不走 Dart 的 HttpOverrides，不认我们的自签证书，
//   所以播放链路必须留在明文 HTTP + 可达地址上。**功能与这个端口强耦合。**
//
// 解法：给每个下发出去的地址签名。App 拿到的是
//     ?u=…&r=…&e=<过期秒>&s=<HMAC-SHA256 base64url(u\nr\ne)>
// 校验端用 timingSafeEqual 比。这样：
//   · App 播放完全不受影响（URL 是服务端生成后原样给它的，它照播）；
//   · 外部扫描器构造的任意 `?u=` 一律 403 —— 没有 secret 就签不出来；
//   · 地址不会永久有效（默认 48h，够长视频 + 客户端缓存 playlist）。
//
// 注意：签名**不等于**准入。签名只证明「这个地址是我们自己下发的」，
//   不证明「这个地址该被访问」。所以校验完签名**仍然**要过 ssrf-guard 的
//   `assertPublicUrl` —— 万一某条源站规则里写了内网地址，也不能因为我们签过就放行。
//
// 本文件是**纯函数**（除 crypto 外无副作用），可直接单测，见 `test_media_sign.cjs`。
'use strict';

const crypto = require('crypto');

/** 默认有效期：48 小时。长到覆盖「看完一部电影 + 中途切后台再回来」。 */
const DEFAULT_TTL_SEC = 48 * 3600;

/** 时钟往前容忍（设备与服务端时间不同步时，宁可多给一点，别把播放打死）。 */
const SKEW_SEC = 120;

function mac(secret, u, r, e) {
  return crypto
    .createHmac('sha256', String(secret))
    .update(String(u) + '\n' + String(r || '') + '\n' + String(e))
    .digest('base64url');
}

/**
 * 生成签名参数。
 * @param {string} u  目标地址（原始源站地址，不是包装后的）
 * @param {string} r  Referer（可空；进了签名就不能被改成任意值）
 * @param {string} secret
 * @param {number} ttlSec
 * @param {number} nowMs 便于单测注入
 * @returns {{e: string, s: string}}
 */
function sign(u, r, secret, ttlSec = DEFAULT_TTL_SEC, nowMs = Date.now()) {
  const e = String(Math.floor(nowMs / 1000) + Math.max(1, ttlSec | 0));
  return { e, s: mac(secret, u, r, e) };
}

/**
 * 校验签名。返回 `{ok:true}` 或 `{ok:false, reason}`。
 * reason 取值：missing / bad_exp / expired / bad_sig
 */
function verify(params, secret, nowMs = Date.now()) {
  const u = params && params.u;
  const r = (params && params.r) || '';
  const e = params && params.e;
  const s = params && params.s;
  if (!u || !e || !s) return { ok: false, reason: 'missing' };

  const exp = Number(e);
  if (!Number.isFinite(exp) || exp <= 0) return { ok: false, reason: 'bad_exp' };
  if (exp * 1000 + SKEW_SEC * 1000 < nowMs) return { ok: false, reason: 'expired' };

  const want = mac(secret, u, r, e);
  const a = Buffer.from(String(s));
  const b = Buffer.from(want);
  // 长度不同时 timingSafeEqual 会抛，必须先比长度（长度本身不敏感）
  if (a.length !== b.length) return { ok: false, reason: 'bad_sig' };
  if (!crypto.timingSafeEqual(a, b)) return { ok: false, reason: 'bad_sig' };
  return { ok: true };
}

/**
 * 把签名参数拼到「已构造好的代理地址」后面。
 *
 * ★ 签的是地址里的 `u` / `r` **参数值**，不是整个 URL ——
 *   因为校验端（routes-thp.js 的 handler）就是从 searchParams 里取 u、r 再算 HMAC 的。
 *   第一版这里签的是整串 URL，单测立刻抓到「拼出来的地址自己校验不过」。
 */
function appendSignature(url, secret, ttlSec = DEFAULT_TTL_SEC, nowMs = Date.now()) {
  const q = new URL(url).searchParams;
  const u = q.get('u') || '';
  const r = q.get('r') || '';
  const { e, s } = sign(u, r, secret, ttlSec, nowMs);
  const sep = url.includes('?') ? '&' : '?';
  return url + sep + 'e=' + encodeURIComponent(e) + '&s=' + encodeURIComponent(s);
}

module.exports = { sign, verify, appendSignature, DEFAULT_TTL_SEC, SKEW_SEC };
