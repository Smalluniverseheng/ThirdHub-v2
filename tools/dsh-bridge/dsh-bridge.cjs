#!/usr/bin/env node
/**
 * dsh-bridge.cjs —— 把电脑上的 DSH（DeepSeek Harness）接入 ThirdHub 的「端间互通」
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 它解决什么（用户诉求原话）：
 *   「只要两边都登录相同的账号就会自动连接」——手机 App 里已经有一套
 *   「端间互通」（PH/1）：同一账号下所有端会自动汇进同一张端列表。
 *   电脑这边缺的只是**一个持续在线的注册者**：把「这台电脑 + 它的 DSH 地址」
 *   登记进去。本脚本就是那个注册者，跑起来之后就再也不用管了。
 *
 * 跑起来后：
 *   · 手机 App 打开 → 自动在端列表里看见这台电脑 → 一键（或自动）连上它的 DSH
 *   · 电脑关机/断网 → 端列表里它变离线；重新跑起来 → 自动恢复
 *
 * 用法（电脑上，Node 18+；零依赖）：
 *   node dsh-bridge.cjs --hub http://<中枢地址> --account <账号> --password <密码> \
 *        [--name 我的电脑] [--dsh http://127.0.0.1:3080] [--url http://192.168.1.5:3080]
 *
 *   · --hub     中枢地址 = ThirdHub 后端的地址（手机 App 里「我的 → 连接资源库」
 *               看到的就是它；同机时通常是 http://127.0.0.1:9527）
 *   · --account/--password  与手机 App 登录的**同一账号** —— 这是自动配对的关键
 *   · --dsh     本机 DSH 的 HTTP 地址（默认 http://127.0.0.1:3080）
 *   · --url     本机对**局域网**暴露的地址（手机直连用）。不填则自动探测本机 IP
 *               + --dsh 的端口拼一个；探测不准时手动指定。
 *
 * 想让它开机自启：Windows 用「任务计划程序」新建「登录时运行」的任务，
 *   操作填 node 的完整路径 + 本脚本的完整路径 + 上面那串参数即可。
 * ═══════════════════════════════════════════════════════════════════════════
 */
'use strict';
const os = require('os');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ── 参数解析 ──
const argv = process.argv.slice(2);
const arg = (k, d = '') => {
  const i = argv.indexOf('--' + k);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};
const HUB = arg('hub', 'http://127.0.0.1:9527').replace(/\/+$/, '');
const ACCOUNT = arg('account', '');
const PASSWORD = arg('password', '');
const NAME = arg('name', os.hostname());
const DSH = arg('dsh', 'http://127.0.0.1:3080').replace(/\/+$/, '');
const URL_OVERRIDE = arg('url', '');

if (!ACCOUNT) {
  console.error('缺少 --account（要和手机 App 登录的是同一个账号）');
  console.error('用法: node dsh-bridge.cjs --hub http://127.0.0.1:9527 --account <账号> --password <密码>');
  process.exit(1);
}

const IID_FILE = path.join(__dirname, '.dsh-bridge-iid');
let iid;
try { iid = fs.readFileSync(IID_FILE, 'utf8').trim(); } catch (_) { iid = crypto.randomUUID(); }
try { fs.writeFileSync(IID_FILE, iid); } catch (_) {}
let peerToken = '';
try { peerToken = fs.readFileSync(IID_FILE + '.token', 'utf8').trim(); } catch (_) {}

/** 本机局域网 IP（排除回环）。 */
function lanIp() {
  const nets = os.networkInterfaces();
  for (const list of Object.values(nets)) {
    for (const n of list || []) {
      if (!n.internal && n.family === 'IPv4' && !n.address.startsWith('169.254.')) return n.address;
    }
  }
  return '';
}
const port = (() => { try { return new URL(DSH).port || '3080'; } catch (_) { return '3080'; } })();
const LAN = URL_OVERRIDE || (lanIp() ? `http://${lanIp()}:${port}` : '');

async function post(p, body) {
  const r = await fetch(HUB + p, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(peerToken ? { 'X-TH-Peer': peerToken } : {}) },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(9000),
  });
  const text = await r.text();
  let j = null;
  try { j = JSON.parse(text); } catch (_) {}
  return { ok: r.ok, code: r.status, j, text };
}

let joined = false;

async function join() {
  const body = {
    kind: 'dsa',                       // 「DSH Agent」端类型（与 App 侧认领口径一致）
    name: NAME,
    url: LAN,                          // 手机直连的首选地址（局域网）
    caps: ['dsh', `dsh:${DSH}`],       // ★能力声明：我做 DSH 桥接；顺带把本机 DSH 地址带上
    tools: [],
    iid,
    ...(peerToken ? { peerToken } : { account: ACCOUNT, password: PASSWORD }),
  };
  const r = await post('/agent/peer/join', body);
  if (!r.ok) {
    const msg = r.j?.error?.message || r.j?.error || r.text.slice(0, 120);
    console.log(`[join] 失败 HTTP ${r.code}: ${msg}`);
    return false;
  }
  const t = r.j?.data?.peerToken || r.j?.peerToken || '';
  if (t) {
    peerToken = t;
    try { fs.writeFileSync(IID_FILE + '.token', t); } catch (_) {}
  }
  const on = r.j?.data?.online ?? r.j?.online;
  console.log(`[join] 成功 · iid=${iid.slice(0, 8)}… · 在线端=${on ?? '?'}`);
  joined = true;
  return true;
}

async function beat() {
  const r = await post('/agent/peer/beat', {
    peerToken,
    url: LAN,
    caps: ['dsh', `dsh:${DSH}`],
  });
  if (!r.ok) {
    console.log(`[beat] 失败 HTTP ${r.code}（下轮重 join）`);
    joined = false;
  }
}

(async () => {
  console.log('═══ DSH ⟷ ThirdHub 桥接 ═══');
  console.log('  中枢:', HUB);
  console.log('  账号:', ACCOUNT);
  console.log('  DSH :', DSH);
  console.log('  局域网地址:', LAN || '(探测不到，手机需用 ipv6/tunnel 或手动 --url)');
  console.log('');

  // 首次 join（失败就重试）
  for (let i = 0; i < 5 && !(await join()); i++) {
    await new Promise((r) => setTimeout(r, 3000));
  }
  if (!joined) {
    console.log('★ 连不上中枢 —— 确认中枢地址、网络与账号后重跑。');
    // 不退出：中枢可能晚点起来，心跳循环里会重试
  }

  // 心跳：30 秒一次；断了自动重 join
  setInterval(async () => {
    if (!joined) { await join(); return; }
    await beat();
  }, 30000);
})();
