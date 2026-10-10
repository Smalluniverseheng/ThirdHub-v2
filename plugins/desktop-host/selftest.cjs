// desktop-host 自检: 驱动 plugin.js 的纯逻辑与 createTools（runner 注入 = 不 fork 真进程）。
// 每个用例对应一个真会出问题的地方（尤其是安全面）：
//
//   1) 白名单放行 —— 规则前缀匹配（'ping' 放行 'ping 127.0.0.1'）
//   2) ★白名单拒绝 —— 不在名单里的命令必须拒（否则"手机控电脑"= 任意远程执行后门）
//   3) ★shell 元字符拒绝 —— 'ping x && rm -rf /' 这种拼接必须在进白名单前就死
//   4) ★规则不能被参数越权 —— 规则 'ping 127.0.0.1' 不放行 'ping 8.8.8.8'（前缀逐段比对）
//   5) checkOpen 只放行 http/https —— file:// / javascript: 必须拒
//   6) shotPlan 三平台都有方案 + 不支持的平台如实报 UNSUPPORTED_PLATFORM
//   7) clipPlan get/set 三平台都有方案
//   8) sysInfo 形状 —— 有 hostname/cpu/mem，无环境变量/密钥泄露
//   9) listDir roots 约束 —— roots 之外的路径拒绝（防手机浏览整块盘）
//  10) listDir 路径穿越 —— '../../' 逃逸 roots 后必须被拒
//  11) createTools 注册 9 个工具 + host.exec 走白名单（注入 runner 断言"拒了就不执行"）
//  12) host.exec 放行时 argv 传给 runner 正确（行为断言）
//  13) host.shot 敏感数据不落盘 —— 截图文件读完即删
'use strict';
const os = require('os');
const fs = require('fs');
const path = require('path');

const mod = require('./plugin.js');
const { checkExec, checkOpen, shotPlan, clipPlan, sysInfo, listDir, createTools } = mod;

let fails = 0;
function ck(name, cond, extra) {
  if (cond) console.log('  OK   ' + name);
  else { fails++; console.log('  FAIL ' + name + (extra ? '  -> ' + extra : '')); }
}

console.log('== 1-4. 命令白名单 ==');
{
  const allow = ['ping', 'ipconfig /all', 'systeminfo'];
  ck('前缀放行', checkExec('ping 127.0.0.1', allow).ok === true);
  ck('全等放行', checkExec('systeminfo', allow).ok === true);
  ck('多段规则放行', checkExec('ipconfig /all', allow).ok === true);
  ck('名单外拒绝', checkExec('rm -rf /', allow).ok === false);
  const meta = checkExec('ping 127.0.0.1 && rm -rf /', allow);
  ck('shell 元字符拒绝', meta.ok === false && meta.error === 'SHELL_METACHAR', JSON.stringify(meta));
  const over = checkExec('ipconfig /renew', allow);
  ck('多段规则不被单段越权', over.ok === false, JSON.stringify(over));
  ck('空命令拒绝', checkExec('', allow).ok === false);
  ck('大小写不敏感放行', checkExec('PING 127.0.0.1', allow).ok === true);
}

console.log('== 5. 打开网址白名单 ==');
{
  ck('http 放行', checkOpen('http://a.example/').ok === true);
  ck('https 放行', checkOpen('https://a.example/').ok === true);
  ck('file:// 拒', checkOpen('file:///etc/passwd').ok === false);
  ck('javascript: 拒', checkOpen('javascript:alert(1)').ok === false);
  ck('空拒', checkOpen('').ok === false);
}

console.log('== 6-7. 平台命令构造 ==');
{
  ck('win32 截屏有方案', !!shotPlan('win32', 'C:/tmp/x.png').argv);
  ck('darwin 截屏有方案', !!shotPlan('darwin', '/tmp/x.png').argv);
  ck('linux 截屏有方案', !!shotPlan('linux', '/tmp/x.png').argv);
  ck('未知平台如实报错', !!shotPlan('plan9', '/x').error);
  ck('win32 剪贴板 get', !!clipPlan('win32', 'get').argv);
  ck('darwin 剪贴板 set 带 stdin', clipPlan('darwin', 'set', 'hi').stdin === 'hi');
  ck('linux 剪贴板 get', !!clipPlan('linux', 'get').argv);
  ck('坏 op 报错', !!clipPlan('win32', 'delete').error);
}

console.log('== 8. sysInfo 形状 ==');
{
  const s = sysInfo();
  ck('有 hostname', typeof s.hostname === 'string' && s.hostname.length > 0);
  ck('有 cpu/内存指标', typeof s.cpuCount === 'number' && typeof s.memTotalMB === 'number');
  const j = JSON.stringify(s);
  ck('不含环境变量/密钥字样', !/SECRET|TOKEN|PASSWORD|env/i.test(j), j.slice(0, 200));
}

console.log('== 9-10. 目录列举 roots 约束 ==');
{
  const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'th-dh-roots-'));
  const sub = path.join(TMP, 'inside');
  fs.mkdirSync(sub);
  fs.writeFileSync(path.join(sub, 'a.txt'), 'x');
  const okR = listDir(sub, [TMP]);
  ck('roots 内可列', okR.ok === true && okR.items.some((i) => i.name === 'a.txt'), JSON.stringify(okR).slice(0, 200));
  const outR = listDir(os.tmpdir(), [sub]);
  ck('roots 外拒绝', outR.ok === false && outR.error === 'OUTSIDE_ROOTS', JSON.stringify(outR));
  const escR = listDir(path.join(sub, '..', '..', '..'), [sub]);
  ck('路径穿越拒绝', escR.ok === false, JSON.stringify(escR));
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch (_) {}
}

console.log('== 11-12. createTools 行为（注入 runner）==');
(async () => {
  const calls = [];
  const fakeCtx = {
    _tools: new Map(),
    tool(name, desc, schema, handler, opts) { this._tools.set(name, { handler, opts }); return this; },
    get tools() { return [...this._tools.keys()]; },
  };
  const runner = async (argv, o) => { calls.push({ argv, o }); return { code: 0, stdout: 'PONG', stderr: '', error: '' }; };
  createTools(fakeCtx, { runner, platform: 'win32', allowExec: ['ping'], roots: [] });

  ck('注册了 9 个工具', fakeCtx.tools.length === 9, fakeCtx.tools.join(','));
  ck('全部标 desktop 能力', [...fakeCtx._tools.values()].every((t) => t.opts && t.opts.cap === 'desktop'));

  const execH = fakeCtx._tools.get('host.exec').handler;
  const rejected = await execH({ cmd: 'del /f /q C:\\*' });
  ck('host.exec 白名单外拒绝', rejected.ok === false && rejected.error.code === 'NOT_IN_ALLOWLIST', JSON.stringify(rejected));
  ck('拒绝时 runner 一次都没被调用', calls.length === 0, 'calls=' + calls.length);

  const allowed = await execH({ cmd: 'ping 127.0.0.1' });
  ck('host.exec 白名单内执行', allowed.ok === true && allowed.stdout === 'PONG', JSON.stringify(allowed));
  ck('runner 收到正确 argv', calls.length === 1 && calls[0].argv[0] === 'ping' && calls[0].argv[1][0] === '127.0.0.1', JSON.stringify(calls[0]));

  const openH = fakeCtx._tools.get('host.open').handler;
  const badOpen = await openH({ url: 'file:///c/windows/system32' });
  ck('host.open 拒非 http(s)', badOpen.ok === false, JSON.stringify(badOpen));

  console.log('== 13. 截图不落盘留存 ==');
  {
    // 用 linux 平台路径构造，runner 伪造"生成了文件"，断言 handler 读完即删
    const TMP2 = fs.mkdtempSync(path.join(os.tmpdir(), 'th-dh-shot-'));
    const fakeCtx2 = {
      _tools: new Map(),
      tool(n, d, s, h, o) { this._tools.set(n, { handler: h, opts: o }); return this; },
    };
    const shotRunner = async (argv) => {
      // 截屏命令里最后一个参数是输出文件（win32 是 PowerShell 字符串内嵌，这里用 darwin 便于断言）
      const outFile = argv[1][argv[1].length - 1];
      fs.writeFileSync(outFile, Buffer.alloc(1024, 7));
      return { code: 0, stdout: '', stderr: '', error: '' };
    };
    createTools(fakeCtx2, { runner: shotRunner, platform: 'darwin', allowExec: [], roots: [], shotDir: TMP2 });
    const shotH = fakeCtx2._tools.get('host.shot').handler;
    const r = await shotH({});
    ck('截图成功且带回 base64', r.ok === true && typeof r.png === 'string' && r.bytes === 1024, JSON.stringify(r).slice(0, 120));
    const left = fs.readdirSync(TMP2).filter((f) => f.endsWith('.png'));
    ck('截图临时文件已删（不落盘留存）', left.length === 0, left.join(','));
    try { fs.rmSync(TMP2, { recursive: true, force: true }); } catch (_) {}
  }

  console.log(fails === 0 ? '\n全部通过（30 项）' : '\n失败 ' + fails + ' 项');
  process.exit(fails === 0 ? 0 : 1);
})();
