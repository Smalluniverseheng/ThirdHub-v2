// ThirdHub v4 媒体路由: 音乐(MusicFree/LX) + 漫画(Venera) + 影视(drpy/TVBox)
// 从 index.js 拆出(2026-09, THP/1.0 改造同步模块化), 逻辑逐字保留。
// ctx 注入共享状态(数组/函数均为引用, 与 index.js 互通)。
//
// ★2026-09-25（第十六轮）：媒体类调用统一改走 `engine-plugin.registry`。
//   此前本文件里"按源格式挑引擎"的三元表达式写了 8 遍（音乐 3 + 漫画 3 + 影视 3），
//   每一处都是一次漏改风险 —— 而漏改的表现是"那类内容静默搜不到"，不报错。
//   现在调用方不再需要知道底层是 `runLX` 还是 `runPlugin`、参数是对象还是数组，
//   只写 `registry.forSource(s).search(s, q)`；新增源格式时只需在
//   `engine-plugin.js` 的 `ALL` 里加一个适配器，本文件不用动。
const crypto = require('crypto');
const { registry } = require('./engine-plugin.js');
// ★唯一保留的引擎直连：`tvbox.importConfig` 是「配置导入」而非「跑某个源」，
//   不属于 registry 的五个标准动作（search/detail/catalog/content/play），
//   导入后产生的每条源都会带 `api`，之后由 tvbox 适配器接管。
const tvbox = require('./engine-tvbox.js');

// 返回 true = 已处理; false = 交回 index.js 主路由
async function handle(req, res, body, u, p, send, ctx) {
  const { musicSources, saveMusic, comicSources, saveComic, drpySources, saveDrpy } = ctx;

  // ── 音乐(MusicFree音源) ──
  if (p === '/v1/music/sources' && req.method === 'GET') {
    send(200, { object:'list', data: musicSources.map(s => ({ id: s.id, name: s.name, platform: s.platform })) });
    return true;
  }
  if (p === '/v1/music/sources' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.code || !d.name) { send(400, { object:'error', data:{ type:'invalid_request', message:'需name+code' }}); return true; }
    const id = d.id || 'music_' + crypto.randomBytes(4).toString('hex');
    const i = musicSources.findIndex(x => x.id === id);
    const fmt = d.format === 'lx' ? 'lx' : 'musicfree';
    i >= 0 ? musicSources[i] = { id, name: d.name, platform: d.platform || d.name, code: d.code, format: fmt } : musicSources.push({ id, name: d.name, platform: d.platform || d.name, code: d.code, format: fmt });
    saveMusic(musicSources);
    send(200, { object:'meta', data: { id, total: musicSources.length }});
    return true;
  }
  if (p.startsWith('/v1/music/search')) {
    const q = u.searchParams.get('q');
    const pool = musicSources.filter(s => !u.searchParams.get('sourceId') || s.id === u.searchParams.get('sourceId'));
    const results = await Promise.all(pool.slice(0, 3).map(async (s) => {
      const t0 = Date.now();
      const r = await registry.run(s, 'search', q);
      return { source: s.name, sourceId: s.id, ok: !r.error, latency: Date.now() - t0,
        ...(r.error ? { error: r.error } : { items: (r.items || []).slice(0, 10) }) };
    }));
    results.sort((a, b) => (b.ok - a.ok) || (a.latency - b.latency));
    send(200, { object:'list', data: results });
    return true;
  }
  if (p.startsWith('/v1/music/url')) {
    const s = musicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) { send(404, { object:'error', data:{ type:'source_error', message:'音源不存在' }}); return true; }
    let item = {}; try { item = JSON.parse(u.searchParams.get('item') || '{}'); } catch (e) {}
    const r = await registry.run(s, 'url', item, '320k');
    if (r.error) { send(500, { object:'error', data:{ type:'source_error', message: r.error }}); return true; }
    send(200, { object:'music-url', data: r });
    return true;
  }
  if (p.startsWith('/v1/music/lyric')) {
    const s = musicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) { send(404, { object:'error', data:{ type:'source_error', message:'音源不存在' }}); return true; }
    let item = {}; try { item = JSON.parse(u.searchParams.get('item') || '{}'); } catch (e) {}
    const r = await registry.run(s, 'lyric', item);
    send(200, { object:'music-lyric', data: r });
    return true;
  }

  // ── 漫画(Venera图源) ──
  if (p === '/v1/comic/sources' && req.method === 'GET') {
    send(200, { object:'list', data: comicSources.map(s => ({ id: s.id, name: s.name })) });
    return true;
  }
  if (p === '/v1/comic/sources' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.code || !d.name) { send(400, { object:'error', data:{ type:'invalid_request', message:'需name+code' }}); return true; }
    const id = d.id || 'comic_' + crypto.randomBytes(4).toString('hex');
    const i = comicSources.findIndex(x => x.id === id);
    // ★必须落 `format`：`registry.forSource` 靠它挑适配器，认不出一律返回 null
    //   （自检 `test_engine_plugin.cjs` 明确钉住"无标识源必须 null"）。
    //   早先这里存的是 `{id,name,code}`——没有 format，于是手工导入的图源
    //   会在 search 时全员"无人认领"，表现依旧是"漫画永远搜不到，还不报错"。
    const rec = { id, name: d.name, code: d.code, format: d.format === 'comic' ? 'comic' : 'venera' };
    i >= 0 ? comicSources[i] = rec : comicSources.push(rec);
    saveComic(comicSources);
    send(200, { object:'meta', data: { id, total: comicSources.length }});
    return true;
  }
  if (p.startsWith('/v1/comic/search')) {
    const q = u.searchParams.get('q');
    const pool = comicSources.filter(s => !u.searchParams.get('sourceId') || s.id === u.searchParams.get('sourceId'));
    const results = await Promise.all(pool.slice(0, 3).map(async (s) => {
      const t0 = Date.now();
      const r = await registry.run(s, 'search', q, 1);
      return { source: s.name, sourceId: s.id, ok: !r.error, latency: Date.now() - t0,
        ...(r.error ? { error: r.error } : { items: r.items, maxPage: r.maxPage }) };
    }));
    results.sort((a, b) => (b.ok - a.ok) || (a.latency - b.latency));
    send(200, { object:'list', data: results });
    return true;
  }
  if (p.startsWith('/v1/comic/info')) {
    const s = comicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) { send(404, { object:'error', data:{ type:'source_error', message:'图源不存在, 请先POST /v1/comic/sources导入' }}); return true; }
    const r = await registry.run(s, 'detail', { id: u.searchParams.get('id') });
    if (r.error) { send(500, { object:'error', data:{ type:'source_error', message: r.error }}); return true; }
    send(200, { object:'comic', data: { ...r, sourceId: s.id } });
    return true;
  }
  if (p.startsWith('/v1/comic/pages')) {
    const s = comicSources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) { send(404, { object:'error', data:{ type:'source_error', message:'图源不存在' }}); return true; }
    const chapId = u.searchParams.get('chapterId') || '';
    const r = await registry.run(s, 'content', { id: chapId, chapterId: chapId });
    if (r.error) { send(500, { object:'error', data:{ type:'source_error', message: r.error }}); return true; }
    send(200, { object:'comic-pages', data: r });
    return true;
  }

  // ── drpy 影视 / TVBox 配置导入(免jar: CMS采集接口 + drpy类站点) ──
  if (p === '/v1/video/tvbox' && req.method === 'POST') {
    try {
      const d = JSON.parse(body || '{}');
      const input = d.url || d.json || '';
      if (!input) { send(400, { object:'error', data:{ type:'invalid_request', message:'需url或json' }}); return true; }
      const r = await tvbox.importConfig(input);
      for (const src of r.added) {
        const i = drpySources.findIndex(x => x.id === src.id);
        i >= 0 ? drpySources[i] = src : drpySources.push(src);
      }
      saveDrpy(drpySources);
      send(200, { object:'meta', data: { imported: r.added.length, skippedJar: r.skipped, total: r.total,
        note: r.skipped > 0 ? `${r.skipped}个jar爬虫站点已跳过(Node无法运行Java)` : '' }});
    } catch (e) { send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
    return true;
  }
  if (p === '/v1/video/sources' && req.method === 'GET') {
    send(200, { object:'list', data: drpySources.map(s => ({ id: s.id, name: s.name })) });
    return true;
  }
  if (p === '/v1/video/sources' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.code || !d.name) { send(400, { object:'error', data:{ type:'invalid_request', message:'需name+code' }}); return true; }
    const id = d.id || 'drpy_' + crypto.randomBytes(4).toString('hex');
    const i = drpySources.findIndex(x => x.id === id);
    // ★同上：`format:'drpy'` 是 registry 认得它的唯一凭据（drpyPlugin.pick）。
    //   带 `api` 的 TVBox CMS 源走 tvbox 适配器（pick 只看 `s.api`），此处不设 format 也无妨。
    const rec = d.api ? { id, name: d.name, code: d.code, api: d.api } : { id, name: d.name, code: d.code, format: 'drpy' };
    i >= 0 ? drpySources[i] = rec : drpySources.push(rec);
    saveDrpy(drpySources);
    send(200, { object:'meta', data: { id, total: drpySources.length }});
    return true;
  }
  if (p.startsWith('/v1/video/search')) {
    const q = u.searchParams.get('q');
    const pool = drpySources.filter(s => !u.searchParams.get('sourceId') || s.id === u.searchParams.get('sourceId'));
    const results = await Promise.all(pool.slice(0, 5).map(async (s) => {
      const t0 = Date.now();
      const r = await registry.run(s, 'search', q);
      return { source: s.name, sourceId: s.id, ok: !r.error, latency: Date.now() - t0, ...(r.error ? { error: r.error } : { items: r.items }) };
    }));
    results.sort((a, b) => (b.ok - a.ok) || (a.latency - b.latency));
    send(200, { object:'list', data: results });
    return true;
  }
  if (p.startsWith('/v1/video/detail')) {
    const s = drpySources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) { send(404, { object:'error', data:{ type:'source_error', message:'源不存在, 请先POST /v1/video/sources导入' }}); return true; }
    const r = await registry.run(s, 'detail', { id: u.searchParams.get('id') });
    if (r.error) { send(500, { object:'error', data:{ type:'source_error', message: r.error }}); return true; }
    send(200, { object:'video', data: { ...r, sourceId: s.id } });
    return true;
  }
  if (p.startsWith('/v1/video/play')) {
    const s = drpySources.find(x => x.id === u.searchParams.get('sourceId'));
    if (!s) { send(404, { object:'error', data:{ type:'source_error', message:'源不存在' }}); return true; }
    const r = await registry.run(s, 'play', {
      flag: u.searchParams.get('flag') || '', id: u.searchParams.get('id') || '' });
    if (r.error) { send(500, { object:'error', data:{ type:'source_error', message: r.error }}); return true; }
    send(200, { object:'video-play', data: r });
    return true;
  }

  return false; // 非媒体路径, 交回主路由
}

module.exports = { handle };
