// ssrf-guard 单测（纯函数 + 注入式假解析器，不产生任何真实网络 IO）
// 跑法: node server/test_ssrf_guard.cjs   （退出码 0=全过）
'use strict';
const assert = require('assert');
const g = require('./ssrf-guard.js');

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + e.message); }
}

console.log('── ssrf-guard :: isBlockedIp (IPv4) ──');
const blocked4 = [
  '127.0.0.1', '127.1.2.3', '0.0.0.0', '10.0.0.1', '10.255.255.255',
  '172.16.0.1', '172.31.255.254', '192.168.1.1', '169.254.169.254', // 云元数据
  '100.64.0.1', '192.0.0.1', '198.18.0.1', '224.0.0.1', '240.0.0.1', '255.255.255.255',
];
for (const ip of blocked4) t('拦 ' + ip, () => assert.strictEqual(g.isBlockedIp(ip), true));

const allowed4 = ['1.1.1.1', '8.8.8.8', '223.5.5.5', '13.107.42.12', '104.16.0.1'];
for (const ip of allowed4) t('放 ' + ip, () => assert.strictEqual(g.isBlockedIp(ip), false));

t('172.32.0.1 不在 172.16/12 内 → 放', () => assert.strictEqual(g.isBlockedIp('172.32.0.1'), false));
t('11.0.0.1 不在 10/8 内 → 放', () => assert.strictEqual(g.isBlockedIp('11.0.0.1'), false));

console.log('── ssrf-guard :: isBlockedIp (IPv6) ──');
const blocked6 = ['::1', '::', 'fc00::1', 'fd12:3456::1', 'fe80::1', 'ff02::1', '2001:db8::1', '::ffff:127.0.0.1', '::ffff:192.168.1.1'];
for (const ip of blocked6) t('拦 ' + ip, () => assert.strictEqual(g.isBlockedIp(ip), true));
const allowed6 = ['2606:4700::1111', '2001:4860:4860::8888', '::ffff:1.1.1.1'];
for (const ip of allowed6) t('放 ' + ip, () => assert.strictEqual(g.isBlockedIp(ip), false));

console.log('── ssrf-guard :: 非法输入 fail-closed ──');
for (const bad of ['', 'not-an-ip', '999.999.999.999', null, undefined, '1.2.3'])
  t('拦非法 ' + JSON.stringify(bad), () => assert.strictEqual(g.isBlockedIp(bad), true));

console.log('── ssrf-guard :: isLanOrTailscaleIp（端网互联的另一套语义）──');
const lan = ['10.1.2.3', '172.20.0.9', '192.168.31.7', '100.101.102.103', '169.254.10.10', '127.0.0.1', 'fd7a:115c:a1e0::1', 'fe80::abcd'];
for (const ip of lan) t('LAN/Tailscale 允许 ' + ip, () => assert.strictEqual(g.isLanOrTailscaleIp(ip), true));
for (const ip of ['1.1.1.1', '8.8.8.8', '2606:4700::1111'])
  t('公网不算 LAN ' + ip, () => assert.strictEqual(g.isLanOrTailscaleIp(ip), false));
t('两套语义确实相反（100.64/10）', () => {
  assert.strictEqual(g.isBlockedIp('100.64.0.1'), true);        // 出站：拦
  assert.strictEqual(g.isLanOrTailscaleIp('100.64.0.1'), true); // 端网：允
});

console.log('── ssrf-guard :: 主机名黑名单 ──');
for (const h of ['localhost', 'LOCALHOST', 'foo.localhost', 'nas.local', 'x.internal', 'metadata.google.internal', 'metadata'])
  t('拦主机名 ' + h, () => assert.strictEqual(g.isBlockedHostname(h), true));
for (const h of ['example.com', 'a.b.cdn.net', 'localhost.evil.com'])
  t('放主机名 ' + h, () => assert.strictEqual(g.isBlockedHostname(h), false));

console.log('── ssrf-guard :: assertPublicUrl（注入假解析器）──');
const fakeResolver = (map) => (host) => {
  if (!(host in map)) { const e = new Error('ENOTFOUND'); e.code = 'ENOTFOUND'; return Promise.reject(e); }
  return Promise.resolve(map[host]);
};
const PUB = { address: '93.184.216.34', family: 4 };

(async () => {
  const cases = [];
  const run = async (name, fn) => { try { await fn(); pass++; console.log('  ok  ' + name); } catch (e) { fail++; console.log('  FAIL ' + name + ' → ' + e.message); } };

  await run('协议非 http(s) → 拒', async () => {
    const r = await g.assertPublicUrl('file:///etc/passwd');
    assert.strictEqual(r.ok, false); assert.match(r.reason, /scheme_not_allowed/);
  });
  await run('非法 URL → 拒', async () => {
    const r = await g.assertPublicUrl('not a url');
    assert.strictEqual(r.ok, false); assert.strictEqual(r.reason, 'invalid_url');
  });
  await run('IP 字面量私网 → 拒', async () => {
    const r = await g.assertPublicUrl('http://169.254.169.254/latest/meta-data/');
    assert.strictEqual(r.ok, false); assert.match(r.reason, /blocked_ip/);
  });
  await run('IP 字面量公网 → 允', async () => {
    const r = await g.assertPublicUrl('https://1.1.1.1/x');
    assert.strictEqual(r.ok, true);
  });
  await run('localhost 主机名 → 拒', async () => {
    const r = await g.assertPublicUrl('http://localhost:9527/v1/status');
    assert.strictEqual(r.ok, false);
  });
  await run('域名解析到私网 → 拒（DNS rebinding 变体）', async () => {
    const r = await g.assertPublicUrl('http://evil.example/x', { resolver: fakeResolver({ 'evil.example': [{ address: '192.168.1.10', family: 4 }] }) });
    assert.strictEqual(r.ok, false); assert.match(r.reason, /blocked_ip:192\.168\.1\.10/);
  });
  await run('域名多 A 记录里含一个私网 → 拒（必须全部公网）', async () => {
    const r = await g.assertPublicUrl('http://mixed.example/x', { resolver: fakeResolver({ 'mixed.example': [PUB, { address: '127.0.0.1', family: 4 }] }) });
    assert.strictEqual(r.ok, false);
  });
  await run('域名全公网 → 允', async () => {
    const r = await g.assertPublicUrl('https://ok.example/img.png', { resolver: fakeResolver({ 'ok.example': [PUB] }) });
    assert.strictEqual(r.ok, true); assert.deepStrictEqual(r.ips, ['93.184.216.34']);
  });
  await run('DNS 失败 → 拒', async () => {
    const r = await g.assertPublicUrl('http://nx.example/x', { resolver: fakeResolver({}) });
    assert.strictEqual(r.ok, false); assert.match(r.reason, /dns_failed/);
  });
  await run('allowPrivate=true 放行私网（自建用户放自己 NAS 的逃生阀）', async () => {
    const r = await g.assertPublicUrl('http://192.168.1.5:8080/api', { allowPrivate: true, resolver: fakeResolver({}) });
    assert.strictEqual(r.ok, true);
  });
  await run('isSsrfBlocked 识别拦截错误', async () => {
    let caught = null;
    try { await g.safeFetch('http://127.0.0.1:1/x', { timeoutMs: 500 }); } catch (e) { caught = e; }
    assert.ok(caught, '应抛错'); assert.strictEqual(g.isSsrfBlocked(caught), true);
    assert.strictEqual(g.isSsrfBlocked(new Error('普通错误')), false);
  });

  console.log(`\n结果: pass=${pass} fail=${fail}`);
  process.exit(fail ? 1 : 0);
})();
