'use strict';
// 交付令牌：把「成品文件」临时授权给手机端拉取。
//
// 设计要点
// --------
// · 令牌**自包含**（id + 过期时间 + HMAC），服务端不存会话，重启不失效。
// · 有效期默认 10 分钟 —— 手机与桌面在同一局域网，够用了；
//   过期后要重新申请，泄露的 URL 不会长期可用。
// · 签名用 HMAC-SHA256，密钥来自环境变量，没有则随机生成并落盘。
// · 路径里只放 base64url 的令牌，**不放文件名**，避免路径穿越。
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function b64u(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function unb64u(s) {
  const t = String(s).replace(/-/g, '+').replace(/_/g, '/');
  return Buffer.from(t + '='.repeat((4 - (t.length % 4)) % 4), 'base64');
}

class Signer {
  /** @param {string} secret @param {number} ttlSec */
  constructor(secret, ttlSec) {
    this.secret = secret;
    this.ttlSec = ttlSec || 600;
  }

  static fromEnvOrFile(dataDir) {
    let s = process.env.TH_HANDOFF_SECRET || '';
    if (!s) {
      const f = path.join(dataDir, 'handoff.key');
      try {
        s = fs.readFileSync(f, 'utf8').trim();
      } catch (_) {
        /* 没有就生成 */
      }
      if (!s) {
        s = crypto.randomBytes(32).toString('hex');
        try {
          fs.mkdirSync(dataDir, { recursive: true });
          fs.writeFileSync(f, s, { mode: 0o600 });
        } catch (_) {
          /* 只读挂载时退化成进程内密钥：重启后旧链接失效，可接受 */
        }
      }
    }
    const ttl = parseInt(process.env.TH_HANDOFF_TTL || '600', 10);
    return new Signer(s, Number.isFinite(ttl) && ttl > 0 ? ttl : 600);
  }

  _mac(payload) {
    return b64u(crypto.createHmac('sha256', this.secret).update(payload).digest());
  }

  /** @returns {{token: string, expiresAt: number}} */
  issue(id) {
    const exp = Math.floor(Date.now() / 1000) + this.ttlSec;
    const payload = `${id}.${exp}`;
    return { token: `${payload}.${this._mac(payload)}`, expiresAt: exp };
  }

  /** @returns {null | {id: string, exp: number}} */
  verify(token) {
    const parts = String(token || '').split('.');
    if (parts.length !== 3) return null;
    const [id, expStr, sig] = parts;
    const exp = parseInt(expStr, 10);
    if (!id || !Number.isFinite(exp)) return null;
    const expect = this._mac(`${id}.${exp}`);
    // 定长比较，避免计时侧信道
    const a = Buffer.from(sig);
    const b = Buffer.from(expect);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    if (exp < Math.floor(Date.now() / 1000)) return { id, exp, expired: true };
    return { id, exp };
  }
}

module.exports = { Signer, b64u, unb64u };
