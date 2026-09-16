// ThirdHub v4 书库路由: Legado转发 + book/toc/content + 本地书库 + 书架下载
// 从 index.js 拆出(2026-09 模块化), 路由逻辑逐字保留。
// 约定: 命中路由后 send() 会 end 响应, 主路由以 res.writableEnded 判定"已处理"。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ctx: 共享状态注入(引用类型, 与 index.js 互通)
async function handle(req, res, body, u, p, send, ctx) {
  const { sources, engine, devices, library, saveLib, LIB_DIR, tocCache, contentCache, tocGet, healthHit } = ctx;
  // ── Legado 原版引擎转发(引擎零改动: 官方Web服务→结果转IR) ──
  const legadoForward = async (dev, apiPath, url, extra) => {
    const r2 = await fetch(dev.device_url + '/' + apiPath + '?url=' + encodeURIComponent(url) + (extra || ''),
      { signal: AbortSignal.timeout(12000) });
    return await r2.json();
  };
  const legadoFromSourceId = (sid) => {
    if (!sid || !sid.startsWith('legado:')) return null;
    const durl = sid.slice(7);
    return devices.find(d => d.device_url === durl);
  };
  if (p.startsWith('/v1/book')) {
    const dev = legadoFromSourceId(u.searchParams.get('sourceId'));
    if (dev) { try { const d = await legadoForward(dev, 'getBookInfo', u.searchParams.get('url'));
      return send(200, { object:'novel', data: { name: d.name, author: d.author || '', coverUrl: d.coverUrl || '',
        intro: d.intro || '', kind: d.kind || '', tocUrl: d.tocUrl || u.searchParams.get('url'), sourceId: u.searchParams.get('sourceId') }});
    } catch (e) { return send(502, { object:'error', data:{ type:'source_error', message:'Legado不可达' }}); } }
    const s = sources.find(x => x.bookSourceUrl === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'书源不存在' }});
    try { return send(200, { object:'novel', data: await engine.detail(s, u.searchParams.get('url')) }); }
    catch (e) { return send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
  }
  if (p.startsWith('/v1/toc')) {
    const dev = legadoFromSourceId(u.searchParams.get('sourceId'));
    if (dev) { try { const list = await legadoForward(dev, 'getChapterList', u.searchParams.get('url'));
      const raw = Array.isArray(list) ? list : list.data || [];
      const bookUrl0 = u.searchParams.get('url');
      const chapters = raw.map((c, i) => ({ name: c.title || c.name, url: c.url || c.chapterUrl, index: i, bookUrl: bookUrl0 }));
      tocCache.set(dev.device_url + '|toc', { at: Date.now(), data: chapters });
      return send(200, { object:'list', data: chapters.filter(c => c.name && c.url) });
    } catch (e) { return send(502, { object:'error', data:{ type:'source_error', message:'Legado不可达' }}); } }
    const s = sources.find(x => x.bookSourceUrl === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'书源不存在' }});
    const ck = s.bookSourceUrl + '|' + u.searchParams.get('url');
    const cached = tocGet(ck); if (cached) return send(200, { object:'list', data: cached, meta: { cached: true }});
    const t0 = Date.now();
    try {
      const data = await engine.catalog(s, u.searchParams.get('url'));
      tocCache.set(ck, { at: Date.now(), data });
      healthHit(s.bookSourceUrl, true, Date.now() - t0);
      return send(200, { object:'list', data });
    } catch (e) { healthHit(s.bookSourceUrl, false, Date.now() - t0);
      return send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
  }
  if (p.startsWith('/v1/content')) {
    const dev = legadoFromSourceId(u.searchParams.get('sourceId'));
    if (dev) { try {
      // 官方api.md: getBookContent?url=书url&index=章节序号 → 从目录缓存反查index
      const chapUrl = u.searchParams.get('url');
      const tocKey = dev.device_url + '|toc';
      const tocList = tocCache.get(tocKey)?.data || [];
      let bookUrl = chapUrl, index = 0;
      const hit = tocList.find(c => c.url === chapUrl);
      if (hit) { bookUrl = hit.bookUrl || chapUrl; index = hit.index ?? 0; }
      const c = await legadoForward(dev, 'getBookContent', bookUrl, '&index=' + index);
      const text = c.content || c.text || '';
      return send(200, { object:'novel-content', data: { text: Array.isArray(text) ? text.join('\n\n') : String(text), chapterUrl: u.searchParams.get('url') }});
    } catch (e) { return send(502, { object:'error', data:{ type:'source_error', message:'Legado不可达' }}); } }
    const s = sources.find(x => x.bookSourceUrl === u.searchParams.get('sourceId'));
    if (!s) return send(404, { object:'error', data:{ type:'source_error', message:'书源不存在' }});
    const ck = s.bookSourceUrl + '|' + u.searchParams.get('url');
    const cached = contentCache.get(ck);
    if (cached && Date.now() - cached.at < 1800000) return send(200, { object:'novel-content', data: cached.data, meta: { cached: true }});
    try {
      const data = await engine.content(s, u.searchParams.get('url'));
      contentCache.set(ck, { at: Date.now(), data });
      return send(200, { object:'novel-content', data });
    } catch (e) { return send(500, { object:'error', data:{ type:'source_error', message: String(e.message||e) }}); }
  }
  // ── 本地书库(后端=资源库): 列表/导入/阅读/删除 ──
  if (p === '/v1/library' && req.method === 'GET')
    return send(200, { object:'list', data: library.map(b => ({ id: b.id, name: b.name, author: b.author,
      chapters: b.chapters, done: b.done, source: b.source || 'local', coverUrl: b.coverUrl || '' })) });
  if (p === '/v1/library/import' && req.method === 'POST') {
    // 本地书籍导入: {name, author?, text} 或 {name, chapters:[{name,text}]}
    try {
      const d = JSON.parse(body || '{}');
      if (!d.name) return send(400, { object:'error', data:{ type:'invalid_request', message:'缺name' }});
      const id = 'local_' + crypto.randomBytes(6).toString('hex');
      let chapters = [];
      if (Array.isArray(d.chapters)) chapters = d.chapters.map((c, i) => ({ name: c.name || '第' + (i+1) + '章', text: c.text || '' }));
      else if (d.text) {
        // 简单分章
        const parts = String(d.text).split(/(?=^\s*第[0-9零一二三四五六七八九十百千万两]+[章节卷回部篇集])/m).filter(x => x.trim());
        chapters = (parts.length ? parts : [d.text]).map((t, i) => {
          const first = t.trim().split('\n')[0].slice(0, 40);
          return { name: first || '第' + (i+1) + '章', text: t };
        });
      }
      const book = { id, name: d.name, author: d.author || '', chapters: chapters.length, done: true, source: 'local', coverUrl: d.coverUrl || '' };
      fs.writeFileSync(path.join(LIB_DIR, id + '.json'), JSON.stringify({ ...book, chapters }));
      library.push(book); saveLib(library);
      return send(200, { object:'meta', data: { id, chapters: chapters.length }});
    } catch (e) { return send(400, { object:'error', data:{ type:'invalid_request', message: String(e.message) }}); }
  }
  if (p.startsWith('/v1/library/book')) {
    const id = u.searchParams.get('id');
    try { const b = JSON.parse(fs.readFileSync(path.join(LIB_DIR, id + '.json'), 'utf8'));
      return send(200, { object:'novel', data: b });
    } catch (e) { return send(404, { object:'error', data:{ type:'not_found', message:'书不存在' }}); }
  }
  if (p.startsWith('/v1/library/chapter')) {
    const id = u.searchParams.get('id'); const idx = parseInt(u.searchParams.get('index') || '0');
    try { const b = JSON.parse(fs.readFileSync(path.join(LIB_DIR, id + '.json'), 'utf8'));
      const c = (b.chapters || [])[idx];
      if (!c) return send(404, { object:'error', data:{ type:'not_found', message:'章节不存在' }});
      return send(200, { object:'novel-content', data: { text: c.text || '', name: c.name }});
    } catch (e) { return send(404, { object:'error', data:{ type:'not_found', message:'书不存在' }}); }
  }
  if (p === '/v1/library/delete' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    library.splice(0, library.length, ...library.filter(b => b.id !== d.id)); saveLib(library);
    try { fs.unlinkSync(path.join(LIB_DIR, d.id + '.json')); } catch (e) {}
    return send(200, { object:'meta', data: { deleted: true }});
  }
  // ── 书架加入 → 后端自动下载全书(后台, 经引擎) ──
  if (p === '/v1/shelf/add' && req.method === 'POST') {
    const d = JSON.parse(body || '{}');
    if (!d.name || !d.bookUrl) return send(400, { object:'error', data:{ type:'invalid_request', message:'缺name/bookUrl' }});
    const id = 'shelf_' + crypto.createHash('md5').update(d.bookUrl).digest('hex').slice(0, 12);
    if (!library.find(b => b.id === id)) {
      const book = { id, name: d.name, author: d.author || '', chapters: 0, done: false, source: d.sourceId || '', coverUrl: d.coverUrl || '', bookUrl: d.bookUrl };
      library.push(book); saveLib(library);
      // 后台下载: 目录→逐章正文→存库
      (async () => {
        try {
          const sid = d.sourceId || '';
          const src = sources.find(x => x.bookSourceUrl === sid);
          let toc = [];
          if (src) toc = await engine.catalog(src, d.bookUrl);
          else { const dev = legadoFromSourceId(sid);
            if (dev) { const list = await legadoForward(dev, 'getChapterList', d.bookUrl);
              const raw = Array.isArray(list) ? list : list.data || [];
              toc = raw.map((c, i) => ({ name: c.title || c.name, url: c.url || c.chapterUrl, index: i })); } }
          const chapters = [];
          for (const ch of toc.slice(0, 2000)) {
            try {
              let text = '';
              if (src) { const c = await engine.content(src, ch.url); text = c.text || ''; }
              else if (sid.startsWith('legado:')) { const dev = legadoFromSourceId(sid);
                const c = await legadoForward(dev, 'getBookContent', d.bookUrl, '&index=' + (ch.index || 0));
                text = c.content || c.text || ''; if (Array.isArray(text)) text = text.join('\n\n'); }
              chapters.push({ name: ch.name, text: String(text) });
              book.chapters = chapters.length;
              if (chapters.length % 20 === 0) saveLib(library);
            } catch (e) { chapters.push({ name: ch.name, text: '' }); }
          }
          book.done = true; book.chapters = chapters.length;
          fs.writeFileSync(path.join(LIB_DIR, id + '.json'), JSON.stringify({ ...book, chapters }));
          saveLib(library);
          console.log('[shelf] 下载完成:', d.name, chapters.length, '章');
        } catch (e) { console.log('[shelf] 下载失败:', d.name, e.message); }
      })();
    }
    return send(200, { object:'meta', data: { id, downloading: true }});
  }
  return false; // 未命中, 交回主路由
}

module.exports = { handle };
