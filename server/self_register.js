// server/self_register.js — 把自己（这台 NAS 后端）的访问地址自动登记到云端
//
// 为什么需要：
//   家里是动态 IPv6（隐私地址会变），把地址写死在 App 里既不安全也会失效。
//   正确做法：NAS 自己定期把「当前能连到我的地址」推到 Supabase th_shared，
//   App 登录后读最新地址 → 永远是最新的，且安装包里不含任何地址。
//
// 绑定谁：由环境变量 TH_OWNER_EMAIL 指定（服务端配置，不进安装包）。
// 需要：SUPABASE2_URL / SUPABASE2_SERVICE_ROLE_KEY（服务端密钥）
'use strict';
const os = require('os');

const SB = (process.env.SUPABASE2_URL || '').replace(/\/$/, '');
const KEY = process.env.SUPABASE2_SERVICE_ROLE_KEY || '';
const OWNER = (process.env.TH_OWNER_EMAIL || '').trim().toLowerCase();
const LAN_HINT = (process.env.TH_LAN_URL || '').trim();
const PORT = process.env.TH_PORT || '9527';
const INTERVAL = 5 * 60 * 1000;   // 5 分钟一次

function enabled() { return !!(SB && KEY && OWNER); }

// 收集本机所有「看起来能从外网路由」的 IPv6（GUA 2000::/3），排除链路本地/ULA
function globalIPv6() {
  const out = [];
  try {
    for (const [, addrs] of Object.entries(os.networkInterfaces())) {
      for (const a of addrs || []) {
        if (!a || a.family !== 'IPv6') continue;
        if (a.internal) continue;
        const ip = a.address.split('%')[0];
        const first = ip.split(':')[0].toLowerCase();
        // 只保留 2000::/3（公网）；排除 fe80::/10、fd00::/8
        if (/^2[0-9a-f]{3}$|^3[0-9a-f]{3}$/.test(first)) out.push(ip);
      }
    }
  } catch (e) {}
  // 去重 + 稳定优先：非隐私（后缀可预测）的排前面，随机后缀排后面
  const uniq = [...new Set(out)];
  uniq.sort((x, y) => {
    const px = x.split(':').pop() || '';
    const py = y.split(':').pop() || '';
    // 含较多随机字符的（16 进制长串）判为隐私地址，排后
    const scoreX = /^[0-9a-f]{4}$/.test(px) ? 1 : 0;
    const scoreY = /^[0-9a-f]{4}$/.test(py) ? 1 : 0;
    return scoreX - scoreY;
  });
  return uniq;
}

function lanIPv4() {
  if (LAN_HINT) return LAN_HINT;
  try {
    for (const [, addrs] of Object.entries(os.networkInterfaces())) {
      for (const a of addrs || []) {
        if (a && a.family === 'IPv4' && !a.internal && /^192\.168\.|^10\.|^172\.(1[6-9]|2\d|3[01])\./.test(a.address)) {
          return 'https://' + a.address + ':' + PORT;
        }
      }
    }
  } catch (e) {}
  return '';
}

async function findUserId(email) {
  const r = await fetch(SB + '/auth/v1/admin/users?page=1&per_page=200', {
    headers: { apikey: KEY, Authorization: 'Bearer ' + KEY },
  });
  if (!r.ok) throw new Error('查询用户失败 HTTP ' + r.status);
  const j = await r.json();
  const u = (j.users || []).find(x => (x.email || '').toLowerCase() === email);
  return u ? u.id : '';
}

async function push() {
  if (!enabled()) return;
  try {
    const ipv6s = globalIPv6();
    const payload = {
      lan: lanIPv4(),
      ipv6: ipv6s.map(ip => 'https://[' + ip + ']:' + PORT),
      port: PORT,
      host: os.hostname(),
      updatedAt: new Date().toISOString(),
    };
    const uid = await findUserId(OWNER);
    if (!uid) { console.log('[register] 找不到账号', OWNER); return; }
    const r = await fetch(SB + '/rest/v1/th_shared?on_conflict=user_id,kind,name', {
      method: 'POST',
      headers: {
        apikey: KEY, Authorization: 'Bearer ' + KEY,
        'Content-Type': 'application/json',
        Prefer: 'resolution=merge-duplicates,return=minimal',
      },
      body: JSON.stringify([{ user_id: uid, kind: 'backend', name: 'main', payload }]),
    });
    if (!r.ok) { console.log('[register] 上报失败 HTTP', r.status, (await r.text()).slice(0, 120)); return; }
    console.log('[register] 已上报 →', payload.lan || '(无内网)', '| IPv6', ipv6s.length, '个');
  } catch (e) {
    console.log('[register] 异常:', String((e && e.message) || e).slice(0, 120));
  }
}

function start() {
  if (!enabled()) { console.log('[register] 未配置（缺 TH_OWNER_EMAIL / SUPABASE2_*），跳过'); return; }
  console.log('[register] 启动，每 ' + (INTERVAL / 60000) + ' 分钟上报一次，绑定账号:', OWNER);
  setTimeout(push, 5000);
  setInterval(push, INTERVAL);
}

module.exports = { start, push, globalIPv6, lanIPv4 };
