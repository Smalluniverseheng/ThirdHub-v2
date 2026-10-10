// ═══════════════════════════════════════════════════════════════════════════
// desktop-host —— 桌面宿主插件（「手机控电脑」的电脑侧一半）
//
// 解决什么问题（阶段5「后端网关 + 立体互连」）：
//   手机（App「端网」页）→ 后端 /agent/peer/invoke → 本插件 /peer/exec → 电脑干活。
//   电脑跑起本插件后，手机上就能：看系统状态、推送剪贴板、打开链接、弹通知、
//   锁屏、截屏、列目录、执行**白名单内**的命令。
//
// ★ 安全设计（这条比功能重要）：
//   ① 命令执行只认**白名单**（前缀匹配），白名单由电脑主人在配置文件里写，
//      默认只有只读诊断命令；`host.exec` 拒绝一切不在白名单里的命令。
//   ② 调用方必须先在后端 join 拿 peerToken，后端转发时出示本插件签发的
//      execToken（X-TH-Peer-Exec）—— 局域网里任何进程不能直接指挥本机。
//   ③ 截屏/剪贴板内容属于敏感数据：只回给调用方，不落盘、不进消息环。
//
// 跑法：
//   1. ThirdHub 后端跑起来（server/）
//   2. node plugins/desktop-host/plugin.js
//   3. 手机 App →「端网」→ 看到「电脑控制台」→ 接入 → 调用工具
//
// 配置文件（可选，没有就用默认）：plugins/desktop-host/desktop-host.json
//   { "allowExec": ["ipconfig", "ping", "systeminfo"], "roots": ["C:/Users"] }
// ═══════════════════════════════════════════════════════════════════════════
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

// ─────────────────────────────────────────────────────────────────────────
// 纯逻辑（可单测）：白名单判定 / 各平台命令构造 / 信息脱敏
// ─────────────────────────────────────────────────────────────────────────

/**
 * 命令白名单判定。allowlist 每项是一个**命令前缀**（按空白切分后逐段匹配），
 * 防止 `ping` 放行后 `ping x && rm -rf /` 搭便车：这里只比对 argv 前缀段，
 * 且**整条命令里出现 shell 元字符一律拒**（本插件用 execFile 不经 shell，
 * 元字符没有意义，出现即视为可疑）。
 */
function checkExec(cmd, allowlist) {
  const raw = String(cmd || '').trim();
  if (!raw) return { ok: false, error: 'EMPTY_COMMAND' };
  if (/[;&|><`$]/.test(raw)) return { ok: false, error: 'SHELL_METACHAR' };
  const argv = raw.split(/\s+/);
  for (const rule of allowlist || []) {
    const ruleParts = String(rule).trim().split(/\s+/).filter(Boolean);
    if (!ruleParts.length) continue;
    if (ruleParts.length > argv.length) continue;
    let hit = true;
    for (let i = 0; i < ruleParts.length; i++) {
      if (ruleParts[i].toLowerCase() !== argv[i].toLowerCase()) { hit = false; break; }
    }
    if (hit) return { ok: true, argv };
  }
  return { ok: false, error: 'NOT_IN_ALLOWLIST' };
}

/** 打开 URL：只放行 http/https（file:// 与任意路径由 roots 另行约束）。 */
function checkOpen(target) {
  const s = String(target || '').trim();
  if (!s) return { ok: false, error: 'EMPTY_TARGET' };
  if (/^https?:\/\//i.test(s)) return { ok: true, kind: 'url', value: s };
  return { ok: false, error: 'ONLY_HTTPS_URL' };
}

/** 构造截屏命令（返回 {argv, file} 或 {error}）。 */
function shotPlan(platform, outFile) {
  const p = String(platform || process.platform);
  if (p === 'win32') return { argv: ['powershell', ['-NoProfile', '-Command',
    `Add-Type -AssemblyName System.Windows.Forms,System.Drawing;` +
    `$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds;` +
    `$img=New-Object System.Drawing.Bitmap $b.Width,$b.Height;` +
    `$g=[System.Drawing.Graphics]::FromImage($img);` +
    `$g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size);` +
    `$img.Save('${String(outFile).replace(/'/g, "''")}');`]], file: outFile };
  if (p === 'darwin') return { argv: ['screencapture', ['-x', outFile]], file: outFile };
  if (p === 'linux') {
    // 优先 grim（Wayland），回落 import（ImageMagick/X11）
    return { argv: ['sh', ['-c', `grim "${outFile}" 2>/dev/null || import -window root "${outFile}"`]], file: outFile };
  }
  return { error: 'UNSUPPORTED_PLATFORM' };
}

/** 剪贴板读写命令。 */
function clipPlan(platform, op, text) {
  const p = String(platform || process.platform);
  if (op === 'get') {
    if (p === 'win32') return { argv: ['powershell', ['-NoProfile', '-Command', 'Get-Clipboard -Raw']] };
    if (p === 'darwin') return { argv: ['pbpaste', []] };
    if (p === 'linux') return { argv: ['sh', ['-c', 'xclip -selection clipboard -o 2>/dev/null || xsel --clipboard --output 2>/dev/null || wl-paste 2>/dev/null']] };
    return { error: 'UNSUPPORTED_PLATFORM' };
  }
  if (op === 'set') {
    const t = String(text == null ? '' : text);
    if (p === 'win32') return { argv: ['powershell', ['-NoProfile', '-Command', 'Set-Clipboard -Value @\'\n' + t + '\n\'@']] };
    if (p === 'darwin') return { argv: ['pbcopy', []], stdin: t };
    if (p === 'linux') return { argv: ['sh', ['-c', 'xclip -selection clipboard 2>/dev/null || xsel --clipboard 2>/dev/null || wl-copy 2>/dev/null']], stdin: t };
    return { error: 'UNSUPPORTED_PLATFORM' };
  }
  return { error: 'BAD_OP' };
}

/** 系统信息脱敏：hostname 保留（认得出是自己电脑），其余只给指标不给内容。 */
function sysInfo() {
  const mem = os.totalmem(), free = os.freemem();
  return {
    hostname: os.hostname(),
    platform: process.platform,
    osRelease: os.release(),
    arch: os.arch(),
    cpu: (os.cpus()[0] || {}).model || 'unknown',
    cpuCount: os.cpus().length,
    memTotalMB: Math.round(mem / 1048576),
    memFreeMB: Math.round(free / 1048576),
    uptimeSec: Math.floor(os.uptime()),
    loadAvg: os.loadavg().map((x) => Math.round(x * 100) / 100),
    nodeVersion: process.version,
  };
}

/** 目录列举（限条数、去路径穿越）。 */
function listDir(dir, roots, max = 200) {
  let target = path.resolve(String(dir || os.homedir()));
  // 路径穿越防线：解析后不允许跳出 roots（roots 为空则限定用户主目录）
  const rs = (roots && roots.length ? roots : [os.homedir()]).map((r) => path.resolve(r));
  const inRoot = rs.some((r) => target === r || target.startsWith(r + path.sep));
  if (!inRoot) return { ok: false, error: 'OUTSIDE_ROOTS' };
  let entries;
  try { entries = fs.readdirSync(target, { withFileTypes: true }); } catch (e) {
    return { ok: false, error: 'READ_FAILED: ' + String((e && e.message) || e) };
  }
  const items = entries.slice(0, max).map((d) => ({
    name: d.name, dir: d.isDirectory(), file: d.isFile(),
  }));
  return { ok: true, path: target, items, total: entries.length, truncated: entries.length > max };
}

// ─────────────────────────────────────────────────────────────────────────
// 工厂：createTools() 把工具集注册进 ctx（runner 可注入 → 自检不 fork 真进程）
// ─────────────────────────────────────────────────────────────────────────
function defaultRunner(argv, opts = {}) {
  return new Promise((resolve) => {
    execFile(argv[0], argv[1] || [], {
      timeout: opts.timeoutMs || 15000,
      maxBuffer: 8 * 1024 * 1024,
      ...(opts.stdin ? { input: opts.stdin } : {}),
    }, (err, stdout, stderr) => {
      resolve({
        code: err ? (err.code || 1) : 0,
        stdout: String(stdout || ''), stderr: String(stderr || ''),
        error: err ? String(err.message || err) : '',
      });
    });
  });
}

function createTools(ctx, opts = {}) {
  const runner = opts.runner || defaultRunner;
  const platform = opts.platform || process.platform;
  const allowExec = Array.isArray(opts.allowExec) ? opts.allowExec : [];
  const roots = Array.isArray(opts.roots) ? opts.roots : [];
  const shotDir = opts.shotDir || os.tmpdir();

  ctx.tool('host.sysinfo', '查看电脑系统状态（CPU / 内存 / 运行时间）', {
    type: 'object', properties: {},
  }, async () => sysInfo(), { cap: 'desktop' });

  ctx.tool('host.open', '用系统默认浏览器打开一个网址', {
    type: 'object',
    properties: { url: { type: 'string', description: 'http/https 网址' } },
    required: ['url'],
  }, async (a) => {
    const chk = checkOpen(a && a.url);
    if (!chk.ok) return { ok: false, error: { code: chk.error, message: '只允许 http/https 网址' } };
    let argv;
    if (platform === 'win32') argv = ['cmd', ['/c', 'start', '', chk.value]];
    else if (platform === 'darwin') argv = ['open', [chk.value]];
    else argv = ['xdg-open', [chk.value]];
    const r = await runner(argv);
    return { ok: r.code === 0, opened: chk.value, code: r.code, error: r.error || undefined };
  }, { cap: 'desktop' });

  ctx.tool('host.clip.get', '读取电脑剪贴板文本', {
    type: 'object', properties: {},
  }, async () => {
    const plan = clipPlan(platform, 'get');
    if (plan.error) return { ok: false, error: { code: plan.error, message: '本平台不支持剪贴板' } };
    const r = await runner(plan.argv);
    return { ok: r.code === 0, text: r.stdout.slice(0, 200000), error: r.error || undefined };
  }, { cap: 'desktop' });

  ctx.tool('host.clip.set', '把文本写入电脑剪贴板', {
    type: 'object',
    properties: { text: { type: 'string', description: '要写入的文本' } },
    required: ['text'],
  }, async (a) => {
    const plan = clipPlan(platform, 'set', a && a.text);
    if (plan.error) return { ok: false, error: { code: plan.error, message: '本平台不支持剪贴板' } };
    const r = await runner(plan.argv, { stdin: plan.stdin });
    return { ok: r.code === 0, error: r.error || undefined };
  }, { cap: 'desktop' });

  ctx.tool('host.notify', '在电脑上弹出一条系统通知', {
    type: 'object',
    properties: {
      title: { type: 'string' },
      body: { type: 'string' },
    },
    required: ['title'],
  }, async (a) => {
    const title = String((a && a.title) || '').slice(0, 200);
    const body = String((a && a.body) || '').slice(0, 2000);
    let argv;
    if (platform === 'win32') {
      argv = ['powershell', ['-NoProfile', '-Command',
        `[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;` +
        `$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent('ToastText02');` +
        `$n=$t.GetElementsByTagName('text');` +
        `$n.Item(0).AppendChild($t.CreateTextNode('${title.replace(/'/g, "''")}')) | Out-Null;` +
        `$n.Item(1).AppendChild($t.CreateTextNode('${body.replace(/'/g, "''")}')) | Out-Null;` +
        `[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('ThirdHub').Show([Windows.UI.Notifications.ToastNotification]::new($t))`]];
    } else if (platform === 'darwin') {
      argv = ['osascript', ['-e', `display notification "${body.replace(/"/g, '\\"')}" with title "${title.replace(/"/g, '\\"')}"`]];
    } else {
      argv = ['notify-send', ['--app-name=ThirdHub', title, body]];
    }
    const r = await runner(argv);
    return { ok: r.code === 0, error: r.error || undefined };
  }, { cap: 'desktop' });

  ctx.tool('host.lock', '锁定电脑屏幕', {
    type: 'object', properties: {},
  }, async () => {
    let argv;
    if (platform === 'win32') argv = ['rundll32.exe', ['user32.dll,LockWorkStation']];
    else if (platform === 'darwin') argv = ['pmset', ['displaysleepnow']];
    else argv = ['sh', ['-c', 'loginctl lock-sessions 2>/dev/null || gnome-screensaver-command -l 2>/dev/null']];
    const r = await runner(argv);
    return { ok: r.code === 0, error: r.error || undefined };
  }, { cap: 'desktop' });

  ctx.tool('host.shot', '截取电脑屏幕（返回 PNG base64）', {
    type: 'object', properties: {},
  }, async () => {
    const outFile = path.join(shotDir, 'th-shot-' + Date.now() + '.png');
    const plan = shotPlan(platform, outFile);
    if (plan.error) return { ok: false, error: { code: plan.error, message: '本平台不支持截屏' } };
    const r = await runner(plan.argv);
    if (r.code !== 0) return { ok: false, error: { code: 'SHOT_FAILED', message: r.error || r.stderr.slice(0, 300) } };
    let buf;
    try { buf = fs.readFileSync(outFile); } catch (e) {
      return { ok: false, error: { code: 'SHOT_READ_FAILED', message: String((e && e.message) || e) } };
    }
    try { fs.unlinkSync(outFile); } catch (_) {}   // 敏感数据不落盘留存
    // 尺寸上限 6MB（base64 后约 8MB），防撑爆消息通道
    if (buf.length > 6 * 1024 * 1024) return { ok: false, error: { code: 'SHOT_TOO_LARGE', message: '截图超过 6MB' } };
    return { ok: true, png: buf.toString('base64'), bytes: buf.length };
  }, { cap: 'desktop' });

  ctx.tool('host.fs.list', '列一个目录（受限于配置的 roots）', {
    type: 'object',
    properties: { dir: { type: 'string', description: '目录路径，缺省为用户主目录' } },
  }, async (a) => {
    const r = listDir(a && a.dir, roots);
    if (!r.ok) return { ok: false, error: { code: r.error, message: '目录不可访问（roots 之外或读取失败）' } };
    return { ok: true, ...r };
  }, { cap: 'desktop' });

  ctx.tool('host.exec', '执行白名单内的命令（默认只有只读诊断命令）', {
    type: 'object',
    properties: { cmd: { type: 'string', description: '如 "ping 127.0.0.1"' } },
    required: ['cmd'],
  }, async (a) => {
    const chk = checkExec(a && a.cmd, allowExec);
    if (!chk.ok) {
      return {
        ok: false,
        error: {
          code: chk.error,
          message: chk.error === 'NOT_IN_ALLOWLIST'
            ? '命令不在白名单内。请电脑主人在 desktop-host.json 的 allowExec 里添加'
            : '命令非法',
        },
      };
    }
    const r = await runner([chk.argv[0], chk.argv.slice(1)]);
    return {
      ok: r.code === 0, code: r.code,
      stdout: r.stdout.slice(0, 100000), stderr: r.stderr.slice(0, 20000),
      error: r.error || undefined,
    };
  }, { cap: 'desktop' });

  return ctx;
}

// ─────────────────────────────────────────────────────────────────────────
// 配置装载
// ─────────────────────────────────────────────────────────────────────────
function loadPluginConfig() {
  const f = path.join(__dirname, 'desktop-host.json');
  try {
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    return {
      allowExec: Array.isArray(j.allowExec) ? j.allowExec.map(String) : [],
      roots: Array.isArray(j.roots) ? j.roots.map(String) : [],
    };
  } catch (_) {
    // 默认白名单：只读诊断（Windows + POSIX 都留一点），不留任何写/删/执行类
    return {
      allowExec: ['ipconfig', 'ping', 'systeminfo', 'ifconfig', 'uname', 'uptime', 'df', 'free', 'whoami', 'date'],
      roots: [],
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 入口：被直接运行时接入端网；被 require 时只导出纯逻辑（供自检）
// ─────────────────────────────────────────────────────────────────────────
function register(ctx, opts) {
  const cfg = Object.assign(loadPluginConfig(), opts || {});
  return createTools(ctx, cfg);
}

if (require.main === module) {
  const { THPlugin } = require('../th-plugin');
  const cfg = loadPluginConfig();
  THPlugin.run({
    name: '电脑控制台',
    iid: 'desktop-host',
    version: '1.0.0',
    hub: process.env.TH_HUB || '',
    account: process.env.TH_ACCOUNT || 'admin',
    password: process.env.TH_PASSWORD || '123456',
    port: parseInt(process.env.TH_PORT || '8802', 10),
    advertiseHost: process.env.TH_ADVERTISE || '',
    caps: ['desktop'],
    ipv6: process.env.TH_IPV6 || '',
    tunnel: process.env.TH_TUNNEL || '',
  }, async (ctx) => {
    register(ctx, cfg);
    ctx.log('桌面宿主就绪 · 工具 ' + ctx.tools.length + ' 个 · 命令白名单 ' + cfg.allowExec.length + ' 条');
  });
}

module.exports = {
  checkExec, checkOpen, shotPlan, clipPlan, sysInfo, listDir,
  createTools, register, loadPluginConfig,
};
