// 5.1.1 删号链路行为自检（不是形状断言 —— 真起服务、真打请求、真看响应）。
//
// 为什么要起真服务：/v1/account/delete 与 DELETE /v1/pair 的过滤逻辑长在
// index.js 的请求处理器里，抽不出来单测；扫源码形状（"有这段字符串"）证明不了
// 「删得对不对」。这里复制一份服务端到临时目录起服（DATA 随 __dirname 走，
// 不碰真实的 server/data/devices.json），打完即关。
//
// 用例（每条都对应一个真会出问题的地方）：
//   1) 注册两台设备（一台带 user_id，一台不带）后，
//      错 token 调 /v1/account/delete 必须 401（删数据的端点不能裸奔）
//   2) 按 user_id 删号 → 只摘掉该账号的注册，无主注册必须活着（不误删）
//   3) DELETE /v1/pair 裸调必须 401（同上）
//   4) DELETE /v1/pair 按 device_url 注销 → 摘掉指定那台，别的不动
//   5) 伪反例：删一个不存在的 user_id → removed=0 且不报错（幂等，可重复删）
//   6) 缺参数（无 user_id/device_urls）→ 400 而不是"删光全部"
//   7) /v1/pair 的 DELETE 带 body.device_url 才删；不带 → 400
//
// 跑法：node test_account_delete.cjs   （退出码非 0 = 失败）
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const { spawn } = require('child_process');

const SRC = __dirname;
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'th-acctdel-'));
const PORT = 9527;

let fails = 0;
function ck(name, cond, extra) {
  if (cond) console.log('  OK   ' + name);
  else { fails++; console.log('  FAIL ' + name + (extra ? '  -> ' + extra : '')); }
}

// ── 复制服务端到临时目录（只搬代码，node_modules 走 NODE_PATH 指回原目录）──
function copyTree() {
  const skip = new Set(['node_modules', 'data', 'public', '.git']);
  (function walk(d, rel) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (skip.has(e.name)) continue;
      const s = path.join(d, e.name), t = path.join(TMP, rel, e.name);
      if (e.isDirectory()) { fs.mkdirSync(t, { recursive: true }); walk(s, path.join(rel, e.name)); }
      else fs.copyFileSync(s, t);
    }
  })(SRC, '');
}

function req(method, p, body, token) {
  return new Promise((resolve) => {
    const data = body ? JSON.stringify(body) : null;
    const r = https.request({
      host: '127.0.0.1', port: PORT, path: p, method,
      rejectUnauthorized: false,
      headers: {
        ...(token ? { 'x-th-token': token } : {}),
        ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}),
      },
    }, (res) => {
      let buf = '';
      res.on('data', (c) => buf += c);
      res.on('end', () => {
        let j = null;
        try { j = JSON.parse(buf); } catch (e) {}
        resolve({ status: res.statusCode, json: j, raw: buf });
      });
    });
    r.on('error', (e) => resolve({ status: 0, json: null, raw: String(e) }));
    if (data) r.write(data);
    r.end();
  });
}

async function main() {
  copyTree();
  const child = spawn(process.execPath, [path.join(TMP, 'index.js')], {
    cwd: TMP,
    env: { ...process.env, NODE_PATH: path.join(SRC, 'node_modules') },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  child.stdout.on('data', (c) => out += c);
  child.stderr.on('data', (c) => out += c);

  // 等「就绪」横幅（起不来就认输，不瞎等）
  const t0 = Date.now();
  while (Date.now() - t0 < 15000) {
    if (/就绪/.test(out)) break;
    if (child.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  if (!/就绪/.test(out)) {
    console.log('  FAIL 服务未启动 -> ' + out.slice(-400));
    child.kill('SIGKILL');
    fs.rmSync(TMP, { recursive: true, force: true });
    process.exit(1);
  }

  // 启动自检要读 secret（临时目录首启会自生成）
  const secret = fs.readFileSync(path.join(TMP, 'data', 'secret'), 'utf8').trim();

  console.log('== 1. 删号端点鉴权 ==');
  {
    const r = await req('POST', '/v1/account/delete', { user_id: 'u1' }, 'WRONG_TOKEN');
    ck('错 token 调 /v1/account/delete 被 401 拒', r.status === 401, JSON.stringify(r.json));
    const r0 = await req('POST', '/v1/account/delete', { user_id: 'u1' });
    ck('无 token 调 /v1/account/delete 被 401 拒', r0.status === 401, JSON.stringify(r0.json));
  }

  console.log('== 2. 按 user_id 删号只摘本人注册 ==');
  {
    await req('POST', '/v1/pair', { device_url: 'http://a:1', device_type: 'engine', user_id: 'u1' }, secret);
    await req('POST', '/v1/pair', { device_url: 'http://b:2', device_type: 'engine', user_id: 'u1' }, secret);
    await req('POST', '/v1/pair', { device_url: 'http://c:3', device_type: 'engine' }, secret); // 无主
    const r = await req('POST', '/v1/account/delete', { user_id: 'u1' }, secret);
    ck('删号回执 removed=2', r.json && r.json.data && r.json.data.removed === 2, JSON.stringify(r.json));
    const r2 = await req('POST', '/v1/account/delete', { user_id: 'no-such-user' }, secret);
    ck('删不存在的账号 removed=0 且幂等', r2.json && r2.json.data && r2.json.data.removed === 0, JSON.stringify(r2.json));
    // 无主注册必须还活着（反例：不许"删号=清空设备表"）
    const r3 = await req('POST', '/v1/account/delete', { device_urls: ['http://c:3'] }, secret);
    ck('无主注册在删号后仍在（能被单独注销）', r3.json && r3.json.data && r3.json.data.removed === 1, JSON.stringify(r3.json));
  }

  console.log('== 3. /v1/pair 的 DELETE 链路 ==');
  {
    const r = await req('DELETE', '/v1/pair', { device_url: 'http://x:9' }, 'WRONG_TOKEN');
    ck('错 token DELETE /v1/pair 被 401 拒', r.status === 401, JSON.stringify(r.json));
    await req('POST', '/v1/pair', { device_url: 'http://x:9', device_type: 'engine', user_id: 'u2' }, secret);
    await req('POST', '/v1/pair', { device_url: 'http://y:9', device_type: 'engine', user_id: 'u2' }, secret);
    const r2 = await req('DELETE', '/v1/pair', { device_url: 'http://x:9' }, secret);
    ck('按 device_url 注销 removed=1', r2.json && r2.json.data && r2.json.data.removed === 1, JSON.stringify(r2.json));
    const r3 = await req('DELETE', '/v1/pair', {}, secret);
    ck('缺 device_url → 400（不许误删全表）', r3.status === 400, JSON.stringify(r3.json));
  }

  console.log('== 4. 缺参数 ==');
  {
    const r = await req('POST', '/v1/account/delete', {}, secret);
    ck('无 user_id/device_urls → 400', r.status === 400, JSON.stringify(r.json));
  }

  child.kill('SIGKILL');
  fs.rmSync(TMP, { recursive: true, force: true });

  console.log('');
  if (fails) {
    console.log('失败 ' + fails + ' 项');
    process.exit(1);
  }
  console.log('全部通过');
}

main().catch((e) => {
  console.error(e);
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (e2) {}
  process.exit(1);
});
