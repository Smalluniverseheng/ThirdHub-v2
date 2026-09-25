// ThirdHub v4 搜索路由: 聚合搜索 + 书源搜索(限流/健康分/去重) + THP引擎搜索
// 从 index.js 拆出(2026-09 模块化), 路由逻辑逐字保留。
// 约定: 命中路由后 send() 会 end 响应, 主路由以 res.writableEnded 判定"已处理"。
const lx = require('./engine-lx');
const music = require('./engine-music');
const comic = require('./engine-comic');
const drpy = require('./engine-drpy');

// ctx: 共享状态注入(引用类型, 与 index.js 互通)
async function handle(req, res, body, u, p, send, ctx) {
  const { aggCache, sources, engine, pool, comicSources, drpySources, musicSources, devices, thpOnline, thpCall, library, health, healthHit, requestLog, routeTable, healthGate, srcUsage, bumpUsage } = ctx;

  /**
   * 按路由表 + 权重取源，替换此前写死的 `.slice(0, N)`。
   *
   * ★ 这里**刻意保持"取几个"的数量不变**（novel 3 / comic 2 / video 2 / music 2）：
   *   本次要解决的是"**问谁**"（永远只问排最前的那几个 → 第 4 个之后的好源永远用不到），
   *   不是"问几个"。顺手改数量会同时改掉结果总量，那属于另一件事、该单独评估。
   * 没有路由表时退回 `slice` —— 保证这个改动在任何异常下都不会让搜索整体挂掉。
   */
  function takeByRoute(routeId, list, fallbackN) {
    const r = routeTable ? routeTable.route(routeId) : null;
    const n = (r && r.limit) || fallbackN;
    if (!routeTable || !healthGate) return list.slice(0, n);
    const picked = routeTable.pickSources(list, {
      limit: n, gate: healthGate, usage: srcUsage,
      idOf: (s) => s.id || s.bookSourceUrl || s.name || '',
    });
    if (bumpUsage) for (const s of picked) bumpUsage(s.id || s.bookSourceUrl || s.name || '');
    return picked;
  }
  if (p.startsWith('/v1/search/all')) {
    const q = u.searchParams.get('q');
    // 60s短缓存(重复搜索秒回)
    const ac = aggCache.get(q);
    if (ac && Date.now() - ac.at < 60000) return send(200, { object:'meta', data: ac.data, meta: { cached: true }});
    // ★ 本聚合路径的失败结果此前被 `filter(r => r.ok)` 直接丢掉、也从不记账 ——
    //   于是"只在聚合搜索里失败的源"永远攒不够失败次数、永远不被摘除（C2 的前提就断了）。
    //   现在在每个回调里就地记一次（成功/失败都记），再把响应里的失败组过滤掉（响应形状不变）。
    const noteAgg = (id, ok, ms, err) => {
      try { if (healthGate) healthGate.note(id, !!ok, ms || 0, err ? String(err).slice(0, 120) : ''); } catch (_) {}
      try { if (requestLog) requestLog.record({ kind: 'search.agg', source: id, target: q,
        ok: !!ok, ms: ms || 0, error: err ? String(err).slice(0, 120) : '' }); } catch (_) {}
    };
    // 聚合搜索: 书+漫画+视频+音乐 并行
    const [books, comics, videos, musics] = await Promise.all([
      (async () => {
        const pool_list = sources.filter(s => s.enabled !== false);
        const rs = await pool(takeByRoute('search.novel', pool_list, 3), 3, async (s) => {
          const t0 = Date.now();
          try { const books = (await engine.search(s, q)).slice(0, 5);
            noteAgg(s.bookSourceUrl, true, Date.now() - t0);
            return { source: s.bookSourceName, sourceId: s.bookSourceUrl, ok: true, books }; }
          catch (e) { noteAgg(s.bookSourceUrl, false, Date.now() - t0, e.message);
            // 失败时也带上 sourceId —— 老代码漏了它，前端按源分组时会出现"无名组"
            return { source: s.bookSourceName, sourceId: s.bookSourceUrl, ok: false }; }
        });
        return rs.filter(r => r.ok);
      })(),
      (async () => {
        const rs = await Promise.all(takeByRoute('search.comic', comicSources, 2).map(async (s) => {
          const t0 = Date.now();
          const r = comic.irComicList(await comic.runSource(s.code, 'search', [q, 1]));
          noteAgg(s.id, !r.error, Date.now() - t0, r.error);
          return { source: s.name, sourceId: s.id, ok: !r.error, ...(r.error ? {} : { items: r.items.slice(0, 5) }) };
        }));
        return rs.filter(r => r.ok);
      })(),
      (async () => {
        const rs = await Promise.all(takeByRoute('search.video', drpySources, 2).map(async (s) => {
          const t0 = Date.now();
          const r = drpy.irSearch(await drpy.runSource(s.code, 'search', [q]));
          noteAgg(s.id, !r.error, Date.now() - t0, r.error);
          return { source: s.name, sourceId: s.id, ok: !r.error, ...(r.error ? {} : { items: r.items.slice(0, 5) }) };
        }));
        return rs.filter(r => r.ok);
      })(),
      (async () => {
        // ★ 只挑**声明支持搜索**的音源。实测本机 31 条可用音源里只有 4 条声明
        //   搜索能力（其余只有 `musicUrl`：它们的职责是"把歌曲 ID 换播放链接"，
        //   不负责搜歌）。此前不问声明一律调 search，满屏 `仅支持musicUrl操作`，
        //   看起来像"音源全坏了"，其实是路由问错了问题。
        const searchable = musicSources.filter(s => lx.searchAction(s.actions));
        if (!searchable.length) return [];
        const rs = await Promise.all(takeByRoute('search.music', searchable, 2).map(async (s) => {
          const t0 = Date.now();
          const act = lx.searchAction(s.actions) || 'search';
          const r = s.format === 'lx'
            ? lx.irSearch(await lx.runLX(s.code, act, { searchKey: q, page: 1, limit: 20, type: 'music' }))
            : music.irSearch(await music.runPlugin(s.code, 'search', [q, 1, 'music']));
          noteAgg(s.id, !r.error, Date.now() - t0, r.error);
          return { source: s.name, sourceId: s.id, ok: !r.error, ...(r.error ? {} : { items: r.items.slice(0, 5) }) };
        }));
        return rs.filter(r => r.ok);
      })(),
    ]);
    const aggData = { q, books, comics, videos, musics,
      stats: { bookSources: sources.length, comicSources: comicSources.length, videoSources: drpySources.length, musicSources: musicSources.length } };
    aggCache.set(q, { at: Date.now(), data: aggData });
    return send(200, { object:'meta', data: aggData });
  }
  if (p.startsWith('/v1/search')) {
    const q = u.searchParams.get('q'); const sid = u.searchParams.get('sourceId');
    // 无任何引擎/书源时: 回落搜索后端本地书库
    const anyEngine = sources.length > 0 || devices.some(d => (Date.now() - (d.last_seen || 0)) < 300000);
    if (!anyEngine && q) {
      const hits = library.filter(b => (b.name + (b.author || '')).toLowerCase().includes(q.toLowerCase()));
      return send(200, { object:'list', data: [{ source: '本地书库', sourceId: 'local', ok: true,
        books: hits.map(b => ({ name: b.name, author: b.author, bookUrl: 'local:' + b.id, sourceId: 'local', coverUrl: b.coverUrl || '' })) }],
        meta: { via: 'local-library' }});
    }
    // THP 引擎并行(异步合并进结果)
    const thpEngines = thpOnline('novel');
    const thpPromise = Promise.all(thpEngines.map(async (dev) => {
      const t0 = Date.now();
      try { const r = await thpCall(dev, '/thp/search', { type: 'novel', q });
        return { source: 'THP引擎@' + dev.device_url.replace(/^https?:\/\//, ''), sourceId: 'thp:' + dev.device_url,
          ok: !r.error, latency: Date.now() - t0, books: (r.items || []).slice(0, 10)
            .map(b => ({ name: b.name, author: b.author || '', coverUrl: b.coverUrl || '', intro: b.intro || '', bookUrl: b.id, sourceId: 'thp:' + dev.device_url })) };
      } catch (e) { return { source: dev.device_url, sourceId: 'thp:' + dev.device_url, ok: false, latency: Date.now() - t0, error: String(e.message || e) }; }
    }));
    // 原版引擎优先: 局域网Legado设备(官方Web服务)在→转发给它, 官方引擎自己解析规则(零适配), 后端只收结果
    const legadoDev = devices.find(d => d.device_type === 'legado' && (Date.now() - (d.last_seen || 0)) < 300000);
    if (legadoDev && !sid) {
      try {
        const t0 = Date.now();
        // 官方api.md: 搜索走WebSocket ws://设备:1235/searchBook, Message={key}, 流式返回每本结果
        // 引擎device_url带HTTP端口(1122), ws固定1235端口; 用URL解析避免 "host:1122:1235" 拼错
        const wsHost = new URL(legadoDev.device_url).hostname;
        const books = await new Promise((resolve, reject) => {
          const out = [];
          const ws = new WebSocket('ws://' + wsHost + ':1235/searchBook');
          const timer = setTimeout(() => { try { ws.close(); } catch (e) {} resolve(out); }, 12000);
          ws.onopen = () => ws.send(JSON.stringify({ key: q }));
          ws.onmessage = (ev) => { try { const b = JSON.parse(ev.data); if (b && b.name) out.push(b); } catch (e) {} };
          ws.onerror = () => { clearTimeout(timer); reject(new Error('ws error')); };
          ws.onclose = () => { clearTimeout(timer); resolve(out); };
        });
        const items = books.map(b => ({
          name: b.name, author: b.author || '', coverUrl: b.coverUrl || '',
          intro: (b.intro || '').slice(0, 200), bookUrl: b.bookUrl, sourceId: 'legado:' + legadoDev.device_url
        }));
        return send(200, { object:'list', data: [{ source: 'Legado(官方引擎)', sourceId: 'legado:' + legadoDev.device_url,
          ok: true, latency: Date.now() - t0, books: items }], meta: { engine: 'legado-native', via: 'websocket' }});
      } catch (e) { /* 不可达→内置引擎兜底 */ } }
    const pool_list = sources.filter(s => s.enabled !== false && (!sid || s.bookSourceUrl === sid));
    // 限流并行(最多3个源同时请求, 防小站被封)
    const results = await pool(pool_list, 6, async (s) => {
      const t0 = Date.now();
      try {
        const books = await engine.search(s, q);
        return { source: s.bookSourceName, sourceId: s.bookSourceUrl, ok: true,
                 latency: Date.now() - t0, books: books.slice(0, 10) };
      } catch (e) {
        return { source: s.bookSourceName, sourceId: s.bookSourceUrl, ok: false,
                 latency: Date.now() - t0, error: String(e.message || e).slice(0, 120) };
      }
    });
    // ★第十六轮：把每个源这次搜索的结果落进观测日志（组C C3）。
    //   为什么放在这里而不是 healthHit 里：搜索路径此前**根本没调 healthHit**，
    //   也就是说"哪个源在搜书时是死的"这件事，后端从来没记过 ——
    //   而搜书恰恰是最常出问题、最需要事后追问的一条链路。
    for (const g of results) {
      // 落观测日志
      try {
        if (requestLog) requestLog.record({ kind: 'search', source: g.source, target: q,
          ok: !!g.ok, ms: g.latency, count: g.ok ? (g.books || []).length : null,
          error: g.error || '' });
      } catch (_) {}
      // 喂「自动摘除」闸门：搜索路径此前**根本没调 healthHit**，等于没记账 ——
      // 于是"哪个源在搜书时是死的"后端从来不知道，死源永远被再问一遍。
      // 这里按 `sourceId` 记账（key 与 routes.js 取源时用的 idOf 一致，都是 bookSourceUrl）。
      try { if (healthGate) healthGate.note(g.sourceId, !!g.ok, g.latency || 0, g.error || ''); } catch (_) {}
    }
    // 健康度优先(成功率差>30%时健康排前), 然后成功优先, 然后延迟
    const rate = (id) => { const h = health.get(id); return h && (h.ok + h.fail) >= 3 ? h.ok / (h.ok + h.fail) : 1; };
    results.sort((a, b) => {
      const d = rate(b.sourceId) - rate(a.sourceId);
      if (Math.abs(d) > 0.3) return d;
      return (b.ok - a.ok) || (a.latency - b.latency);
    });
    // 跨源去重(书名+作者), 同书记录多源可用性
    const seen = new Map();
    for (const g of results) {
      if (!g.ok) continue;
      g.books = g.books.filter(b => {
        const k = ((b.name || '') + '|' + (b.author || '')).toLowerCase().replace(/\s+/g, '');
        if (seen.has(k)) { seen.get(k).push(g.source); return false; }
        seen.set(k, [g.source]); return true;
      });
    }
    const thpResults = await thpPromise.catch(() => []);
    const merged = [...thpResults.filter(r => r.ok && (r.books || []).length), ...results];
    return send(200, { object:'list', data: merged,
      meta: { total: merged.length, ok: merged.filter(r => r.ok).length, deduped: true, thp: thpEngines.length } });
  }
  // ── THP 引擎搜索(与内置/legado并行, 结果聚合) ──
  if (p.startsWith('/v1/thp/search')) {
    const q = u.searchParams.get('q'); const type = u.searchParams.get('type') || 'novel';
    const engines = thpOnline(type);
    if (!engines.length) return send(200, { object:'list', data: [], meta: { engines: 0 }});
    const results = await Promise.all(engines.map(async (dev) => {
      const t0 = Date.now();
      try { const r = await thpCall(dev, '/thp/search', { type, q });
        return { source: dev.device_url, sourceId: 'thp:' + dev.device_url, ok: !r.error,
          latency: Date.now() - t0, books: (r.items || []).slice(0, 20) };
      } catch (e) { return { source: dev.device_url, sourceId: 'thp:' + dev.device_url, ok: false, latency: Date.now() - t0, error: String(e.message || e) }; }
    }));
    return send(200, { object:'list', data: results, meta: { engines: engines.length, via: 'thp' }});
  }
  return false; // 未命中, 交回主路由
}

module.exports = { handle };
