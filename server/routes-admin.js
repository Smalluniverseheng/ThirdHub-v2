// ThirdHub v4 管理台路由: 引擎总览 + 存储服务 + 下载任务
// 从 index.js 拆出(2026-09 模块化), 路由逻辑逐字保留。
// 约定: 命中路由后 send() 会 end 响应, 主路由以 res.writableEnded 判定"已处理"。
const fs = require('fs');
const path = require('path');
// 自身实例 ID：用于把"后端自己"从网络引擎列表中剔除（双保险，见 index.js 的 purgeSelfDevice）
const SELF_IID = require('./thp1').INSTANCE_ID;

// ctx: 共享状态注入(引用类型, 与 index.js 互通)
async function handle(req, res, body, u, p, send, ctx) {
  const { health, devices, sources, musicSources, comicSources, drpySources, storageState } = ctx;
  // ── 引擎总览(前后端的"后端管理台"数据源) ──
  if (p === '/v1/engines') {
    const hget = (id) => { const h = health.get(id); return h ? { ...h, rate: (h.ok + h.fail) ? Math.round(h.ok / (h.ok + h.fail) * 100) : 100 } : null; };
    const builtin = [
      { id: 'engine-book', name: '书源引擎', kind: 'builtin', icon: 'book', caps: ['novel.search', 'novel.detail', 'novel.toc', 'novel.content'],
        status: 'online', sources: sources.filter(s => s.enabled !== false).length, health: hget('__book__') },
      { id: 'engine-drpy', name: '影视引擎 (drpy)', kind: 'builtin', icon: 'movie', caps: ['video.search', 'video.detail', 'video.play'],
        status: fs.existsSync(path.join(__dirname, 'vendor/drpy/drpy2.min.js')) ? 'online' : 'error', sources: drpySources.length },
      { id: 'engine-comic', name: '漫画引擎 (Venera)', kind: 'builtin', icon: 'palette', caps: ['comic.search', 'comic.info', 'comic.pages'],
        status: 'online', sources: comicSources.length },
      { id: 'engine-music', name: '音源引擎 (MusicFree)', kind: 'builtin', icon: 'music', caps: ['music.search', 'music.play', 'music.lyric'],
        status: 'online', sources: musicSources.length },
      { id: 'engine-storage', name: '存储服务', kind: 'builtin', icon: 'cloud', caps: ['disk.file', 'download.task'],
        status: storageState.cloudreve === 'running' || storageState.aria2 === 'running' ? 'online' : 'standby',
        detail: `cloudreve:${storageState.cloudreve} aria2:${storageState.aria2}` },
    ];
    const now = Date.now();
    const network = devices
      .filter(d => !(d.instanceId && d.instanceId === SELF_IID)) // 不把后端自身当网络引擎
      .map(d => ({
      id: d.device_url, name: `${d.device_type || 'device'}@${(d.device_url || '').replace(/^https?:\/\//, '')}`,
      kind: 'network', icon: 'plug', caps: (d.caps || []).map(c => c + '.search'),
      status: (now - (d.last_seen || 0)) < 120000 ? 'online' : 'offline',
      lastSeen: d.last_seen, pairedAt: d.paired_at,
    }));
    return send(200, { object:'list', data: { builtin, network },
      meta: { builtinOnline: builtin.filter(e => e.status === 'online').length, builtinTotal: builtin.length,
              networkOnline: network.filter(e => e.status === 'online').length, networkTotal: network.length }});
  }
  // ── 存储服务状态+下载任务 ──
  if (p === '/v1/storage/status') return send(200, { object:'meta', data: {
    cloudreve: storageState.cloudreve, aria2: storageState.aria2,
    ports: { cloudreve: 5212, aria2: 6800 },
    downloadsDir: '/v1/storage/downloads',
    hint: storageState.cloudreve === 'running' ? '网盘: http://后端IP:5212 (Cloudreve管理页)' : '放入vendor/cloudreve/cloudreve二进制后重启' }});
  // ── 下载 / P2P 任务面（U5/U6）──
  // 后端把 aria2 当"P2P 内核"用：aria2 本身就是标准 BitTorrent/DHT 网络里的一个节点，
  // 所以"接入权威 P2P 网络"= 让它带着 DHT/LPD/PEX 跑起来（参数见 index.js startStorage）。
  // 定位是**通用下载器**：不内置任何资源索引，只执行用户自己给的 磁力/种子/直链。
  const AR = 'http://127.0.0.1:6800/jsonrpc';
  const AR_TOK = storageState.rpcSecret ? ['token:' + storageState.rpcSecret] : [];
  const AR_HINT = 'aria2 未运行：把 aria2c 放进 server/vendor/aria2/ 后重启后端（本仓已内置 Windows 版 aria2c.exe）';
  async function arCall(method, params) {
    const r = await fetch(AR, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 'th', method, params: [...AR_TOK, ...(params || [])] }),
      signal: AbortSignal.timeout(8000) });
    const j = await r.json();
    if (j.error) throw new Error(j.error.message || JSON.stringify(j.error));
    return j.result;
  }
  const fmtTask = (t) => {
    const btName = t.bittorrent && t.bittorrent.info && t.bittorrent.info.name;
    const f0 = t.files && t.files[0] && String(t.files[0].path || '').split(/[\\/]/).pop();
    const spd = Number(t.downloadSpeed || 0), total = Number(t.totalLength || 0), done = Number(t.completedLength || 0);
    return {
      gid: t.gid, name: btName || f0 || t.gid,
      progress: total > 0 ? Math.round(done / total * 100) : 0,
      speed: spd, size: total, done,
      status: t.status,
      peers: t.connections ? Number(t.connections) : 0,
      seeders: t.numSeeders ? Number(t.numSeeders) : 0,
      kind: t.bittorrent ? 'bt' : 'http',
      dir: t.dir || '',
      eta: (spd > 0 && total > done) ? Math.round((total - done) / spd) : 0, // 秒
    };
  };
  const arAll = async () => {
    const [act, wait, stop] = await Promise.all([
      arCall('aria2.tellActive'), arCall('aria2.tellWaiting', [0, 100]), arCall('aria2.tellStopped', [0, 50])]);
    return [...act, ...wait, ...stop].map(fmtTask);
  };
  const DL_ROOT = path.join(__dirname, 'data', 'downloads');
  // 任务列表（含 速度/ETA/peer/做种 与 三种状态分组）
  if (p === '/v1/dl/list' || p === '/v1/download/tasks') {
    if (storageState.aria2 !== 'running') return send(503, { object:'error', data:{ type:'server_error', message: AR_HINT, hint:'后端需带 vendor/aria2/aria2c 启动' }});
    try {
      const all = await arAll();
      return send(200, { object:'list', data: {
        active: all.filter(t => t.status === 'active'),
        waiting: all.filter(t => t.status === 'waiting' || t.status === 'paused'),
        stopped: all.filter(t => ['complete','error','removed'].includes(t.status)),
      }, meta: { total: all.length } });
    } catch (e) { return send(502, { object:'error', data:{ type:'server_error', message:'aria2 RPC 失败: ' + e.message }}); }
  }
  // 发布任务：磁力 / 直链 / .torrent(base64) 三合一（U6）
  if ((p === '/v1/dl/task' || p === '/v1/download/add') && req.method === 'POST') {
    if (storageState.aria2 !== 'running') return send(503, { object:'error', data:{ type:'server_error', message: AR_HINT }});
    let d = {}; try { d = JSON.parse(body || '{}'); } catch (e) {}
    const opts = {};
    if (d.dir) opts.dir = String(d.dir);                     // 每个任务可指定落盘目录（U4）
    if (d.seedTime != null) opts['seed-time'] = String(d.seedTime);
    const gids = [];
    try {
      if (d.torrent) gids.push(await arCall('aria2.addTorrent', [String(d.torrent), [], opts]));
      for (const one of (Array.isArray(d.urls) ? d.urls : [d.url]).filter(Boolean)) {
        const clean = String(one).trim(); if (!clean) continue;
        gids.push(await arCall('aria2.addUri', [[clean], opts]));   // 磁力链接同样走 addUri
      }
    } catch (e) { return send(502, { object:'error', data:{ type:'server_error', message:'发布任务失败: ' + e.message }}); }
    return send(200, { object:'meta', data: { added: gids.length, gids }});
  }
  if (p.startsWith('/v1/dl/status')) {
    if (storageState.aria2 !== 'running') return send(503, { object:'error', data:{ type:'server_error', message: AR_HINT }});
    try { return send(200, { object:'meta', data: fmtTask(await arCall('aria2.tellStatus', [u.searchParams.get('gid')])) }); }
    catch (e) { return send(404, { object:'error', data:{ type:'not_found', message:'任务不存在: ' + e.message }}); }
  }
  if (p.startsWith('/v1/dl/action') && req.method === 'POST') {
    if (storageState.aria2 !== 'running') return send(503, { object:'error', data:{ type:'server_error', message: AR_HINT }});
    const act = u.searchParams.get('act'), gid = u.searchParams.get('gid');
    const map = { pause:'aria2.pause', unpause:'aria2.unpause', remove:'aria2.remove', forcerm:'aria2.forceRemove' };
    if (!map[act]) return send(400, { object:'error', data:{ type:'invalid_request', message:'act 取值: ' + Object.keys(map).join('|') }});
    try { return send(200, { object:'meta', data: { act, gid: await arCall(map[act], [gid]) }}); }
    catch (e) { return send(502, { object:'error', data:{ type:'server_error', message: e.message }}); }
  }
  // ── 存储位置管理（U4）：读当前下载根 + 列出已落盘文件 + 改全局落盘目录 ──
  if (p === '/v1/storage/dirs') {
    let files = [];
    try {
      files = fs.readdirSync(DL_ROOT).map(n => {
        const st = fs.statSync(path.join(DL_ROOT, n));
        return { name: n, isDir: st.isDirectory(), size: st.isDirectory() ? 0 : st.size, at: st.mtimeMs };
      });
    } catch (e) {}
    let cur = DL_ROOT;
    if (storageState.aria2 === 'running') { try { cur = (await arCall('aria2.getGlobalOption')).dir || DL_ROOT; } catch (e) {} }
    return send(200, { object:'list', data: { downloadRoot: DL_ROOT, currentDir: cur, files: files.slice(0, 500) } });
  }
  if (p === '/v1/storage/setdir' && req.method === 'POST') {
    let d0 = {}; try { d0 = JSON.parse(body || '{}'); } catch (e) {}
    if (!d0.dir) return send(400, { object:'error', data:{ type:'invalid_request', message:'需 dir' }});
    try { fs.mkdirSync(String(d0.dir), { recursive: true }); }
    catch (e) { return send(400, { object:'error', data:{ type:'invalid_request', message:'目录不可用: ' + e.message }}); }
    let applied = false;
    if (storageState.aria2 === 'running') { try { await arCall('aria2.changeGlobalOption', [{ dir: String(d0.dir) }]); applied = true; } catch (e) {} }
    return send(200, { object:'meta', data: { dir: String(d0.dir), applied }});
  }
  return false; // 未命中, 交回主路由
}

module.exports = { handle };
