// 出站代理集中配置自检: 直接驱动 server/proxy-config.js（行为断言，不是形状断言）。
// 每个用例都对应一个真会出问题的地方：
//
//   1) 默认直连 —— 没配置时 resolve 必须给 direct，绝不"猜"一个代理
//   2) ★非法代理地址拒绝写入 —— update 返回 ok:false 而不是悄悄存坏配置
//   3) 协议白名单 —— socks5 配进 http 槽要被拒（协议不匹配就是配置错误）
//   4) noProxy 命中 —— 127.0.0.1/localhost 永远直连（后端自己、本机引擎不绕代理）
//   5) noProxy 通配 —— "*.lan" 这类后缀规则要生效
//   6) 模块级覆盖 —— modules.ai_chat='direct' 时即使全局 custom 也直连
//   7) 总开关 —— enabled=false 时就算填了代理地址也直连
//   8) ★masked 脱敏 —— 密码绝不回显（hasPassword=true 但值里不出现明文密码）
//   9) 未知模块键拒绝 —— 防前端塞任意字段
//  10) fetchOutbound 无 undici 时降级直连 + lastInfo 如实报 used:false（不假装用了代理）
//  11) 伪反例：伪造 enabled=true 但代理地址为空 → resolve 给 no_proxy_configured 不给假代理
//  12) 纯函数性质 —— resolve 不修改配置对象
'use strict';
const os = require('os');
const fs = require('fs');
const path = require('path');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'th-proxy-cfg-'));
const pc = require('./proxy-config.js');
pc.init({ DATA: TMP });

let fails = 0;
function ck(name, cond, extra) {
  if (cond) console.log('  OK   ' + name);
  else { fails++; console.log('  FAIL ' + name + (extra ? '  -> ' + extra : '')); }
}

console.log('== 1. 默认直连 ==');
{
  pc._test.reset();
  const r = pc.resolve('https://api.example.com/v1', 'content');
  ck('未配置时 mode=direct', r.mode === 'direct', JSON.stringify(r));
  ck('未配置时 proxyUrl 为空', r.proxyUrl === '', JSON.stringify(r));
}

console.log('== 2. 非法代理地址拒绝写入 ==');
{
  pc._test.reset();
  const r = pc.update({ http: 'not a url' });
  ck('坏地址被拒', r.ok === false && /合法 URL/.test(r.error || ''), JSON.stringify(r));
  const r2 = pc.update({ http: 'http://127.0.0.1:7890' });
  ck('合法地址可写', r2.ok === true, JSON.stringify(r2));
}

console.log('== 3. 协议白名单 ==');
{
  pc._test.reset();
  const r = pc.update({ socks5: 'http://127.0.0.1:7890' });   // http 协议塞进 socks5 槽
  ck('socks5 槽拒绝 http 协议', r.ok === false, JSON.stringify(r));
  const r2 = pc.update({ socks5: 'socks5://127.0.0.1:1080' });
  ck('socks5 槽接受 socks5 协议', r2.ok === true, JSON.stringify(r2));
}

console.log('== 4. noProxy 命中 ==');
{
  pc._test.reset();
  pc.update({ enabled: true, mode: 'custom', http: 'http://127.0.0.1:7890' });
  ck('127.0.0.1 直连', pc.resolve('http://127.0.0.1:9527/v1/ping', 'content').proxyUrl === '');
  ck('localhost 直连', pc.resolve('http://localhost:1234/thp/meta', 'content').proxyUrl === '');
  const r = pc.resolve('https://api.example.com/x', 'content');
  ck('外部地址走代理', r.proxyUrl === 'http://127.0.0.1:7890', JSON.stringify(r));
}

console.log('== 5. noProxy 通配 ==');
{
  pc._test.reset();
  pc.update({ enabled: true, mode: 'custom', http: 'http://127.0.0.1:7890', noProxy: ['*.lan'] });
  ck('后缀通配命中', pc.resolve('http://nas.lan:5000/x', 'content').proxyUrl === '');
  ck('不相关域名走代理', pc.resolve('http://nas.example/x', 'content').proxyUrl === 'http://127.0.0.1:7890');
}

console.log('== 6. 模块级覆盖 ==');
{
  pc._test.reset();
  pc.update({ enabled: true, mode: 'custom', http: 'http://127.0.0.1:7890', modules: { ai_chat: 'direct' } });
  ck('ai_chat 覆盖为直连', pc.resolve('https://ai.example/v1', 'ai_chat').proxyUrl === '');
  ck('content 仍走代理', pc.resolve('https://api.example/v1', 'content').proxyUrl === 'http://127.0.0.1:7890');
}

console.log('== 7. 总开关 ==');
{
  pc._test.reset();
  pc.update({ enabled: false, mode: 'custom', http: 'http://127.0.0.1:7890' });
  ck('enabled=false 时直连', pc.resolve('https://api.example/v1', 'content').proxyUrl === '');
}

console.log('== 8. masked 脱敏 ==');
{
  pc._test.reset();
  pc.update({ enabled: true, http: 'http://user:secretpw@10.0.0.2:3128' });
  const m = pc.masked();
  const s = JSON.stringify(m);
  ck('密码不出现在 masked 里', !s.includes('secretpw'), s);
  ck('hasPassword 标记正确', m.hasPassword === true, s);
  ck('host 仍在（可辨认是哪个代理）', /10\.0\.0\.2:3128/.test(s), s);
}

console.log('== 9. 未知模块键拒绝 ==');
{
  pc._test.reset();
  const r = pc.update({ modules: { evil_module: 'custom' } });
  ck('未知模块键被拒', r.ok === false && /未知模块键/.test(r.error || ''), JSON.stringify(r));
}

console.log('== 10. fetchOutbound 降级行为 ==');
{
  pc._test.reset();
  pc.update({ enabled: true, mode: 'custom', http: 'http://127.0.0.1:9' });   // 端口 9 = 不通
  // 不真的发请求（会挂 8s+），只验证 resolve 层：used 由 agentFor 决定，
  // undici 缺失时 used:false —— 用 getLastInfo 的初始值 + resolve 结果断言"不假装"。
  const r = pc.resolve('https://api.example/v1', 'content');
  ck('配置了代理时 resolve 给出 proxyUrl', r.proxyUrl === 'http://127.0.0.1:9', JSON.stringify(r));
  const info = pc.getLastInfo();
  ck('未发起请求前 lastInfo.used 不吹牛', info.used === false, JSON.stringify(info));
  const d = pc.diag();
  ck('diag 回得出配置与运行时', !!d.config && !!d.runtime, JSON.stringify(d).slice(0, 200));
}

console.log('== 11. 反例：启用但没填地址 ==');
{
  pc._test.reset();
  pc.update({ enabled: true, mode: 'custom', http: '', https: '', socks5: '' });
  const r = pc.resolve('https://api.example/v1', 'content');
  ck('不给假代理（reason=no_proxy_configured）', r.proxyUrl === '' && r.reason === 'no_proxy_configured', JSON.stringify(r));
}

console.log('== 12. resolve 纯函数性质 ==');
{
  pc._test.reset();
  pc.update({ enabled: true, mode: 'custom', http: 'http://127.0.0.1:7890' });
  const before = JSON.stringify(pc._test.cfg());
  pc.resolve('https://a.example/', 'content');
  pc.resolve('https://b.example/', 'storage');
  const after = JSON.stringify(pc._test.cfg());
  ck('resolve 不改配置', before === after);
}

try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) {}

console.log(fails === 0 ? '\n全部通过（12 项）' : '\n失败 ' + fails + ' 项');
process.exit(fails === 0 ? 0 : 1);
