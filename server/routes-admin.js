// ThirdHub v4 管理台路由: 引擎总览 + 存储服务 + 下载任务
// 从 index.js 拆出(2026-09 模块化), 路由逻辑逐字保留。
// 约定: 命中路由后 send() 会 end 响应, 主路由以 res.writableEnded 判定"已处理"。
const fs = require('fs');
const path = require('path');

// ctx: 共享状态注入(引用类型, 与 index.js 互通)
async function handle(req, res, body, u, p, send, ctx) {
  const { health, devices, sources, musicSources, comicSources, drpySources, storageState } = ctx;
  // ── 引擎总览(前后端的"后端管理台"数据源) ──
  if (p === '/v1/engines') {
    const hget = (id) => { const h = health.get(id); return h ? { ...h, rate: (h.ok + h.fail) ? Math.round(h.ok / (h.ok + h.fail) * 100) : 100 } : null; };
    const builtin = [
      { id: 'engine-book', name: '书源引擎', kind: 'builtin', icon: '📖', caps: ['novel.search', 'novel.detail', 'novel.toc', 'novel.content'],
        status: 'online', sources: sources.filter(s => s.enabled !== false).length, health: hget('__book__') },
      { id: 'engine-drpy', name: '影视引擎 (drpy)', kind: 'builtin', icon: '🎬', caps: ['video.search', 'video.detail', 'video.play'],
        status: fs.existsSync(path.join(__dirname, 'vendor/drpy/drpy2.min.js')) ? 'online' : 'error', sources: drpySources.length },
      { id: 'engine-comic', name: '漫画引擎 (Venera)', kind: 'builtin', icon: '🎨', caps: ['comic.search', 'comic.info', 'comic.pages'],
        status: 'online', sources: comicSources.length },
      { id: 'engine-music', name: '音源引擎 (MusicFree)', kind: 'builtin', icon: '🎵', caps: ['music.search', 'music.play', 'music.lyric'],
        status: 'online', sources: musicSources.length },
      { id: 'engine-storage', name: '存储服务', kind: 'builtin', icon: '☁️', caps: ['disk.file', 'download.task'],
        status: storageState.cloudreve === 'running' || storageState.aria2 === 'running' ? 'online' : 'standby',
        detail: `cloudreve:${storageState.cloudreve} aria2:${storageState.aria2}` },
    ];
    const now = Date.now();
    const network = devices.map(d => ({
      id: d.device_url, name: `${d.device_type || 'device'}@${(d.device_url || '').replace(/^https?:\/\//, '')}`,
      kind: 'network', icon: '🔌', caps: (d.caps || []).map(c => c + '.search'),
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
  if (p === '/v1/download/tasks') {
    // 代理aria2 RPC
    if (storageState.aria2 !== 'running') return send(503, { object:'error', data:{ type:'server_error', message:'aria2未运行(放vendor/aria2/aria2c后重启)' }});
    try {
      const r2 = await fetch('http://127.0.0.1:6800/jsonrpc', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 'th', method: 'aria2.tellActive' }), signal: AbortSignal.timeout(5000) });
      const act = (await r2.json()).result || [];
      const r3 = await fetch('http://127.0.0.1:6800/jsonrpc', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 'th2', method: 'aria2.tellWaiting', params: [0, 20] }), signal: AbortSignal.timeout(5000) });
      const wait = (await r3.json()).result || [];
      const fmt = (t) => ({ gid: t.gid, name: (t.files[0] && t.files[0].path.split('/').pop()) || t.gid,
        progress: t.totalLength > 0 ? Math.round(t.completedLength / t.totalLength * 100) : 0,
        speed: t.downloadSpeed, size: t.totalLength, status: t.status });
      return send(200, { object:'list', data: { active: act.map(fmt), waiting: wait.map(fmt) }});
    } catch (e) { return send(502, { object:'error', data:{ type:'server_error', message: 'aria2 RPC失败: ' + e.message }}); }
  }
  if (p === '/v1/download/add' && req.method === 'POST') {
    if (storageState.aria2 !== 'running') return send(503, { object:'error', data:{ type:'server_error', message:'aria2未运行' }});
    const d = JSON.parse(body || '{}'); const urls = Array.isArray(d.urls) ? d.urls : [d.url].filter(Boolean);
    const added = [];
    for (const u of urls) {
      const r2 = await fetch('http://127.0.0.1:6800/jsonrpc', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 'add', method: 'aria2.addUri', params: [[u]] }), signal: AbortSignal.timeout(5000) });
      const j = await r2.json(); if (j.result) added.push(j.result);
    }
    return send(200, { object:'meta', data: { added: added.length, gids: added }});
  }
  return false; // 未命中, 交回主路由
}

module.exports = { handle };
