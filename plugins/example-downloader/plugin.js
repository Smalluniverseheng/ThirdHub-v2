// ═══════════════════════════════════════════════════════════════════════════
// 示例插件：下载器（下载任务接入 ThirdHub 端网）
//
// 这个文件是给你**照抄的模板**。它演示了插件该有的每一样东西：
//   · 声明能力 caps 与工具 tool（别的端据此决定"这个活交给谁"）
//   · 用 ctx.effect 管理定时器（关停后不留幽灵任务）
//   · 读账号里统一的密钥（ctx.secret）
//   · 收到端间消息时响应（ctx.on('msg')）
//   · 干活时把进度主动播报出去（ctx.relay）
//
// 跑法：
//   1. 先把 ThirdHub 后端跑起来（见 server/ 的说明）
//   2. node plugins/example-downloader/plugin.js
//   3. 打开 App →「端网」模块，应该能看到「示例下载器」待登录 → 点接入
//      （或 直接填 account/password，插件会自己登录）
//   4. 在「端网」里点 dl.add 调一次，看它能不能接活
//
// ★ 注意：这里只演示"接入与调度"，不真去连 BT。真下载请把 addTask() 换成
//   调 aria2（后端已经内置了 aria2，插件也可以只说一句 dl.add 让后端去干）。
// ═══════════════════════════════════════════════════════════════════════════
'use strict';
const { THPlugin } = require('../th-plugin');

// ── 插件自己的配置（不放进代码里的一切都该从密钥/环境变量来）──
const CFG = {
  name: '示例下载器',
  iid: 'example-downloader',        // 固定 iid = 固定身份；改它等于换一个端
  version: '1.0.0',
  hub: process.env.TH_HUB || '',    // 不填则自动扫描局域网
  account: process.env.TH_ACCOUNT || 'admin',
  password: process.env.TH_PASSWORD || '123456',
  port: parseInt(process.env.TH_PORT || '8801', 10),
  // 局域网里别人该用哪个地址连我。一般不用填（会自动取本机 IP）；
  // 容器 / NAT / 自测场景才需要指定。
  advertiseHost: process.env.TH_ADVERTISE || '',
  caps: ['download'],               // 粗粒度能力标签
  // ★ 无后端直连：这两项填了，App 在后端不在时也能直接连到这个插件
  ipv6: process.env.TH_IPV6 || '',        // 如 'http://[2001:db8::5]:8801'
  tunnel: process.env.TH_TUNNEL || '',    // 如 'https://xxx.trycloudflare.com'
};

// ── 插件自己的内部状态（重启即清空，不假装持久）──
const tasks = new Map();
let seq = 0;

function addTask(link) {
  const id = 't' + (++seq);
  const t = { id, link, state: 'queued', pct: 0, at: Date.now() };
  tasks.set(id, t);
  return t;
}

THPlugin.run(CFG, async (ctx) => {
  // ───────────────────────────────────────────────────────────────────
  // 1) 声明工具。别的端（前端 / AI / 其他插件）通过
  //    POST {后端}/agent/peer/invoke  {to:'example-downloader', tool:'dl.add', args:{...}}
  //    调到这里。**inputSchema 一定要写** —— 前端和 AI 靠它知道怎么填参数。
  // ───────────────────────────────────────────────────────────────────
  ctx.tool('dl.add', '添加一个下载任务（磁力 / 直链 / 种子链接）', {
    type: 'object',
    properties: {
      link: { type: 'string', description: '磁力链接、http(s) 直链或 .torrent 地址' },
      saveDir: { type: 'string', description: '保存目录；不填用密钥 dl.saveDir' },
    },
    required: ['link'],
  }, async (a) => {
    const link = String(a.link || '').trim();
    if (!link) throw new Error('link 不能为空');
    const t = addTask(link);
    // 保存目录优先用调用方给的，其次用"统一密钥"里的（这正是密钥跨端统一的价值：
    // 你在 App 里设置一次，所有插件都能读到）
    t.saveDir = a.saveDir || ctx.secret('dl.saveDir') || '';
    ctx.log('接到任务 ' + t.id + ' → ' + link + (t.saveDir ? '  保存到 ' + t.saveDir : ''));
    // 主动播报：前端"端网"里的端间消息会立刻显示出来
    ctx.relay({ kind: 'task.added', id: t.id, link }, 'download');
    return { id: t.id, state: t.state, saveDir: t.saveDir };
  }, { cap: 'download' });

  ctx.tool('dl.list', '列出全部下载任务', { type: 'object', properties: {} },
    async () => ({ tasks: [...tasks.values()] }), { cap: 'download' });

  ctx.tool('dl.cancel', '取消一个下载任务', {
    type: 'object', properties: { id: { type: 'string' } }, required: ['id'],
  }, async (a) => {
    const t = tasks.get(String(a.id));
    if (!t) throw new Error('没有这个任务: ' + a.id);
    t.state = 'canceled';
    return { id: t.id, state: t.state };
  }, { cap: 'download' });

  // ───────────────────────────────────────────────────────────────────
  // 2) 响应别的端发来的消息：一端输入，其他端都能用
  //    （在 App 的「端网」里发一条 topic=download 的消息，就能指挥这个插件）
  // ───────────────────────────────────────────────────────────────────
  ctx.on('msg', (m) => {
    const text = m && m.payload && (m.payload.text || m.payload.link);
    ctx.log('收到来自「' + m.fromName + '」的消息：' + (text || JSON.stringify(m.payload)));
    if (m.topic === 'download' && text) {
      const t = addTask(String(text));
      ctx.log('  已按消息内容建任务 ' + t.id);
    }
  });

  // ───────────────────────────────────────────────────────────────────
  // 3) 后台推进（假装的下载）。★定时器必须进 ctx.effect ——
  //    这是 DSH 的"无模块级副作用"要求，也是插件能被安全热重载的前提。
  // ───────────────────────────────────────────────────────────────────
  ctx.effect(() => {
    const timer = setInterval(() => {
      let changed = false;
      for (const t of tasks.values()) {
        if (t.state === 'queued') { t.state = 'downloading'; changed = true; }
        else if (t.state === 'downloading') {
          t.pct += 10;
          changed = true;
          if (t.pct >= 100) { t.pct = 100; t.state = 'done'; }
        }
      }
      // 只在真有变化时播报，别刷屏
      if (changed && ctx.online) {
        const done = [...tasks.values()].filter((t) => t.state === 'done').length;
        ctx.relay({ kind: 'progress', total: tasks.size, done }, 'download');
      }
    }, 2000);
    return () => clearInterval(timer);   // ← 返回 disposer，关停时会被调用
  });

  // ───────────────────────────────────────────────────────────────────
  // 4) 接入成功 / 与后端失联 时做点事（可选）
  // ───────────────────────────────────────────────────────────────────
  ctx.on('joined', (d) => ctx.log('已接入后端，当前在线端数：' + d.online));
  ctx.on('lost', () => ctx.log('与后端失联了，插件仍在广播，后端回来会自动重连'));

  // ───────────────────────────────────────────────────────────────────
  // 5) 首次运行：把默认保存目录写进"统一密钥"（会同步到所有端）
  // ───────────────────────────────────────────────────────────────────
  if (!ctx.secret('dl.saveDir')) {
    await ctx.putSecret('dl.saveDir', '/sdcard/Download/ThirdHub');
    ctx.log('已写入默认保存目录到统一密钥 dl.saveDir');
  }

  // ───────────────────────────────────────────────────────────────────
  // 6) Ctrl+C 优雅下线：告诉后端"我走了"，别把我留成假在线
  //    （Windows 上 SIGTERM 是硬终止、跑不到 handler，所以再给宿主留一个
  //      IPC 口：以 IPC 方式拉起插件时，宿主 send('shutdown') 即可优雅关停）
  // ───────────────────────────────────────────────────────────────────
  const bye = async () => { await ctx.dispose(); process.exit(0); };
  process.on('SIGINT', bye);
  process.on('SIGTERM', bye);
  if (typeof process.send === 'function') {
    process.on('message', (m) => { if (m === 'shutdown') bye(); });
  }
});
