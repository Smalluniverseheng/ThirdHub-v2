// ThirdHub v4 源管理路由: 四类源删除/启停/导出 + 设备列表 + 图片代理 + 状态
// 从 index.js 拆出(2026-09 模块化), 路由逻辑逐字保留。
// 约定: 命中路由后 send() 会 end 响应, 主路由以 res.writableEnded 判定"已处理"。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
// ★第十六轮：出站地址准入（SSRF 防护）。图片代理的 `url` 参数**完全由调用方给**，
// 是把本后端当"请求跳板"最顺手的一个口子，必须逐跳校验。
const ssrf = require('./ssrf-guard.js');

// ctx: 共享状态注入(引用类型, 与 index.js 互通)
async function handle(req, res, body, u, p, send, ctx) {
  const { sources, saveSources, drpySources, saveDrpy, comicSources, saveComic, musicSources, saveMusic, devices, health, DATA, requestLog } = ctx;
  // ── 四类源统一删除/启停 ──
  const srcCollections = {
    book:   { get: () => sources,       save: saveSources, idField: 'bookSourceUrl' },
    video:  { get: () => drpySources,   save: saveDrpy,    idField: 'id' },
    comic:  { get: () => comicSources,  save: saveComic,   idField: 'id' },
    music:  { get: () => musicSources,  save: saveMusic,   idField: 'id' }
  };
  if (p.startsWith('/v1/src/')) {
    const parts = p.split('/');           // /v1/src/{type}/{action}
    const type = parts[3], action = parts[4];
    const col = srcCollections[type];
    if (!col) return send(404, { object:'error', data:{ type:'not_found', message:'未知源类型' }});
    const id = u.searchParams.get('id');
    const list = col.get();
    const item = list.find(x => x[col.idField] === id);
    if (!item) return send(404, { object:'error', data:{ type:'not_found', message:'源不存在' }});
    if (action === 'export') {
      const fname = { book: 'book-sources', video: 'video-sources', comic: 'comic-sources', music: 'music-sources' }[type] || 'sources';
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8',
        'Content-Disposition': `attachment; filename="${fname}.json"` });
      return res.end(JSON.stringify(list, null, 2));
    }
    if (action === 'delete') {
      list.splice(list.indexOf(item), 1); col.save(list);
      return send(200, { object:'meta', data: { deleted: id }});
    }
    if (action === 'toggle') {
      item.enabled = item.enabled === false ? true : false; col.save(list);
      return send(200, { object:'meta', data: { id, enabled: item.enabled }});
    }
    return send(400, { object:'error', data:{ type:'invalid_request', message:'action须为delete/toggle' }});
  }
  if (p === '/v1/sources/export') return send(200, { object:'list', data: sources, meta: { exported_at: Date.now(), count: sources.length } });
  if (p === '/v1/devices') return send(200, { object:'list', data: devices });
  if (p.startsWith('/v1/img')) {
    // 图片代理: 前端走自签HTTPS证书问题+图床防盗链, 统一走后端转发
    const imgUrl = u.searchParams.get('url'); const referer = u.searchParams.get('referer') || '';
    if (!imgUrl || !/^https?:/.test(imgUrl)) return send(400, { object:'error', data:{ type:'invalid_request', message:'无效图片地址' }});
    // 观测计时：图片代理是**最高频**的出站路径，没有它的话日志里看不到"图为什么出不来"
    const _t0 = Date.now();
    const _logImg = (ok, err) => { try { requestLog && requestLog.record({ kind:'img', target: imgUrl, ok, ms: Date.now()-_t0, error: err }); } catch (_) {} };
    // 磁盘缓存(24h): key=md5(url), 命中直接返
    const CACHE_DIR = path.join(DATA, 'imgcache'); fs.mkdirSync(CACHE_DIR, { recursive: true });
    const ckey = crypto.createHash('md5').update(imgUrl).digest('hex');
    const cpath = path.join(CACHE_DIR, ckey);
    try {
      const st = fs.statSync(cpath);
      if (Date.now() - st.mtimeMs < 86400000) {
        _logImg(true, '');
        res.writeHead(200, { 'Content-Type': 'image/jpeg', 'X-TH-Cache': 'hit' });
        return res.end(fs.readFileSync(cpath));
      }
    } catch (e) {}
    try {
      // safeFetch 而非原生 fetch：每一跳重定向都会重新跑地址准入，
      // 挡住 `Location: http://169.254.169.254/...` 这类"首跳公网、次跳内网"的绕过。
      const r2 = await ssrf.safeFetch(imgUrl, { timeoutMs: 10000, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36',
        'Referer': referer || new URL(imgUrl).origin
      } });
      if (!r2.ok) { _logImg(false, '上游' + r2.status); return send(502, { object:'error', data:{ type:'source_error', message:'上游' + r2.status }}); }
      const buf = Buffer.from(await r2.arrayBuffer());
      try { fs.writeFileSync(cpath, buf); } catch (e) {}
      _logImg(true, '');
      res.writeHead(200, { 'Content-Type': r2.headers.get('content-type') || 'image/jpeg',
        'Cache-Control': 'public, max-age=86400', 'X-TH-Cache': 'miss' });
      return res.end(buf);
    } catch (e) {
      // 被准入拦掉时给一个**可辨认**的 403，别让它看起来像"图挂了"：
      // 这类拦截要能一眼看出是策略行为，否则排查时会被误判成源站故障。
      if (ssrf.isSsrfBlocked(e)) {
        _logImg(false, 'SSRF拦截: ' + e.reason);
        return send(403, { object:'error', data:{ type:'blocked_by_policy', message: String(e.message) }});
      }
      _logImg(false, String(e.message));
      return send(502, { object:'error', data:{ type:'source_error', message: String(e.message) }});
    }
  }
  // ★第十六轮：观测日志查询端点（组C C3「观测日志 request_log」）。
  // 排查"搜不出来"时的第一站：谁在什么时候、用多久、返回几条、错在哪。
  //   GET /v1/request-log?limit=100&kind=search&ok=false&since=<ms>
  //   GET /v1/request-log?view=stats   → 按 kind/source 聚合概览
  if (p === '/v1/request-log') {
    if (!requestLog) return send(503, { object:'error', data:{ type:'unavailable', message:'观测日志未初始化' }});
    if (u.searchParams.get('view') === 'stats')
      return send(200, { object:'meta', data: requestLog.stats() });
    const okRaw = u.searchParams.get('ok');
    const data = requestLog.list({
      limit: Number(u.searchParams.get('limit')) || 100,
      kind: u.searchParams.get('kind') || undefined,
      ok: okRaw === null ? undefined : (okRaw === 'true' || okRaw === '1'),
      since: Number(u.searchParams.get('since')) || undefined,
      until: Number(u.searchParams.get('until')) || undefined,
    });
    return send(200, { object:'list', data, meta: { total: data.length, stats: requestLog.stats() } });
  }
  if (p === '/v1/status') return send(200, { object:'meta', data: {
    uptime: Math.floor(process.uptime()), version: require('./package.json').version,
    sources: { total: sources.length, enabled: sources.filter(s => s.enabled !== false).length },
    health: Object.fromEntries([...health.entries()].map(([k, v]) => [k, { ...v, rate: v.ok + v.fail ? Math.round(v.ok / (v.ok + v.fail) * 100) + '%' : '-' }])),
    memory: Math.round(process.memoryUsage().rss / 1048576) + 'MB' }});
  if (p === '/v1/sources' && req.method === 'GET') return send(200, { object:'list', data: sources.map(s => ({ id: s.bookSourceUrl, name: s.bookSourceName, enabled: s.enabled !== false })) });
  if (p.startsWith('/v1/sources/toggle') && req.method === 'POST') {
    const id = u.searchParams.get('id');
    const s = sources.find(x => x.bookSourceUrl === id);
    if (!s) return send(404, { object:'error', data:{ type:'not_found', message:'书源不存在' }});
    s.enabled = s.enabled === false ? true : false; saveSources(sources);
    return send(200, { object:'meta', data: { id, enabled: s.enabled }});
  }
  if (p === '/v1/sources' && req.method === 'POST') {
    const arr = JSON.parse(body || '[]');
    const added = [];
    for (const s of arr) {
      if (!s.bookSourceUrl || sources.some(x => x.bookSourceUrl === s.bookSourceUrl)) continue;
      sources.push(s); added.push(s.bookSourceName || s.bookSourceUrl);
    }
    saveSources(sources);
    return send(200, { object:'meta', data:{ added, total: sources.length }});
  }
  return false; // 未命中, 交回主路由
}

module.exports = { handle };
