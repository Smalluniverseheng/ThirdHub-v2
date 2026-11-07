// server/source_scanner.js — 24 小时自动源扫描器
// 自动测源、抓元数据、标记可用/不可用，结果持久化到 data/source-health.json
// 跑在后端进程内，每隔一段时间自动扫一遍。
//
// 元数据尽量抓全：标题、作者、封面、标签、简介、评分、更新时间等。
// 不可用的源也保留记录（标记为 dead），方便管理页展示和后续复检。
'use strict';
const fs = require('fs');
const path = require('path');

const DATA = process.env.TH_DATA_DIR || path.join(__dirname, 'data');
const HEALTH_FILE = path.join(DATA, 'source-health.json');
const META_FILE = path.join(DATA, 'source-metadata.json');

// 扫描间隔：每 30 分钟一轮，每轮内每源间隔 200ms（避免打太猛）
const ROUND_INTERVAL_MS = 30 * 60 * 1000;
const PROBE_INTERVAL_MS = 200;
const PROBE_TIMEOUT_MS = 12 * 1000;
const SEARCH_QUERIES = ['三体', '火影', '周杰伦', '海贼王', '斗罗大陆'];

// 元数据抓取用的关键词 → 字段映射（从搜索结果 JSON 里尽量抽取）
function extractMeta(item) {
  const meta = {};
  meta.name = item.name || item.title || item.bookName || item.novelName || '';
  meta.author = item.author || item.writer || item.artist || '';
  meta.cover = item.cover || item.coverUrl || item.pic || item.img || item.image || '';
  meta.desc = item.desc || item.description || item.intro || item.summary || '';
  meta.tags = item.tags || item.tag || item.genre || item.categories || item.group || '';
  meta.rating = item.rating || item.score || item.star || '';
  meta.latest = item.latestChapter || item.lastChapter || item.updateTime || item.update || '';
  meta.url = item.url || item.bookUrl || item.articleUrl || item.id || '';
  meta.sourceId = item.sourceId || item.source || '';
  meta.type = item.type || '';
  return meta;
}

// 测试单个源：用搜索查询看能不能返回结果
function probeSource(engine, type, source, query) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      resolve({ ok: false, latency: PROBE_TIMEOUT_MS, error: 'timeout' });
    }, PROBE_TIMEOUT_MS + 2000);

    try {
      let p;
      if (type === 'comic') {
        p = engine.runSource(source.code, 'search', [query, 1]);
      } else if (type === 'music') {
        p = engine.runPlugin(source.code, 'search', [query, 1]);
      } else if (type === 'video') {
        p = engine.runSource(source.code, 'search', [query]);
      } else {
        // book
        p = engine.search(source, query);
      }

      const start = Date.now();
      Promise.resolve(p).then((result) => {
        clearTimeout(timer);
        const latency = Date.now() - start;
        let items = [];
        if (Array.isArray(result)) items = result;
        else if (result && Array.isArray(result.data)) items = result.data;
        else if (result && Array.isArray(result.items)) items = result.items;

        const metas = items.slice(0, 5).map(extractMeta);
        resolve({ ok: items.length > 0, latency, count: items.length, metas, error: items.length === 0 ? 'empty' : null });
      }).catch((e) => {
        clearTimeout(timer);
        resolve({ ok: false, latency: Date.now() - start, error: String(e && e.message || e).slice(0, 100) });
      });
    } catch (e) {
      clearTimeout(timer);
      resolve({ ok: false, latency: 0, error: String(e && e.message || e).slice(0, 100) });
    }
  });
}

class SourceScanner {
  constructor(ctx) {
    this.ctx = ctx; // { sources, drpySources, comicSources, musicSources, engine, comic, music, lx, drpy }
    this.health = this._loadJson(HEALTH_FILE, {});
    this.metadata = this._loadJson(META_FILE, {});
    this.running = false;
    this.round = 0;
    this._timer = null;
  }

  _loadJson(file, fallback) {
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return fallback; }
  }

  _saveJson(file, data) {
    try { fs.writeFileSync(file, JSON.stringify(data, null, 2)); } catch (e) { /* 磁盘满等 */ }
  }

  start() {
    if (this.running) return;
    this.running = true;
    console.log('[scanner] 启动，间隔 ' + (ROUND_INTERVAL_MS / 60000) + ' 分钟');
    this._tick();
    this._timer = setInterval(() => this._tick(), ROUND_INTERVAL_MS);
  }

  stop() {
    this.running = false;
    if (this._timer) { clearInterval(this._timer); this._timer = null; }
    console.log('[scanner] 已停止');
  }

  async _tick() {
    if (!this.running) return;
    this.round++;
    console.log('[scanner] 第 ' + this.round + ' 轮开始');

    const allSources = [];
    const ctx = this.ctx;

    // 书源
    if (ctx.sources) {
      for (const s of ctx.sources) {
        allSources.push({ type: 'book', id: s.bookSourceUrl || s.id, name: s.bookSourceName || s.name, source: s });
      }
    }
    // 影视/直播
    if (ctx.drpySources) {
      for (const s of ctx.drpySources) {
        allSources.push({ type: 'video', id: s.id, name: s.name, source: s });
      }
    }
    // 漫画
    if (ctx.comicSources) {
      for (const s of ctx.comicSources) {
        allSources.push({ type: 'comic', id: s.id, name: s.name, source: s });
      }
    }
    // 音乐
    if (ctx.musicSources) {
      for (const s of ctx.musicSources) {
        allSources.push({ type: 'music', id: s.id, name: s.name, source: s });
      }
    }

    console.log('[scanner] 本轮共 ' + allSources.length + ' 个源');

    // 逐个测，每源间隔 PROBE_INTERVAL_MS
    let ok = 0, fail = 0;
    for (let i = 0; i < allSources.length; i++) {
      if (!this.running) break;
      const { type, id, name, source } = allSources[i];

      // 轮换查询词
      const query = SEARCH_QUERIES[i % SEARCH_QUERIES.length];

      // 选对应引擎
      let engine;
      if (type === 'comic') engine = ctx.comic;
      else if (type === 'music') engine = ctx.music;
      else if (type === 'video') engine = ctx.drpy;
      else engine = ctx.engine;
      if (!engine) continue;

      const result = await probeSource(engine, type, source, query);

      // 记录健康
      const key = type + ':' + id;
      const prev = this.health[key] || {};
      this.health[key] = {
        type, id, name,
        ok: result.ok,
        latency: result.latency,
        count: result.count || 0,
        error: result.error,
        lastCheck: new Date().toISOString(),
        totalChecks: (prev.totalChecks || 0) + 1,
        okChecks: (prev.okChecks || 0) + (result.ok ? 1 : 0),
        deadSince: result.ok ? null : (prev.deadSince || new Date().toISOString()),
      };

      // 记录元数据（只在有结果时更新）
      if (result.metas && result.metas.length > 0) {
        const metaKey = type + ':' + id;
        const existing = this.metadata[metaKey] || {};
        this.metadata[metaKey] = {
          type, id, name,
          ...existing,
          items: result.metas,
          itemCount: result.count,
          updatedAt: new Date().toISOString(),
        };
      }

      if (result.ok) ok++; else fail++;

      // 节流
      await new Promise(r => setTimeout(r, PROBE_INTERVAL_MS));
    }

    // 持久化
    this._saveJson(HEALTH_FILE, this.health);
    this._saveJson(META_FILE, this.metadata);

    const summary = {
      round: this.round,
      time: new Date().toISOString(),
      total: allSources.length,
      ok, fail,
      byType: {},
    };
    for (const key of Object.keys(this.health)) {
      const h = this.health[key];
      if (!summary.byType[h.type]) summary.byType[h.type] = { total: 0, ok: 0, dead: 0 };
      summary.byType[h.type].total++;
      if (h.ok) summary.byType[h.type].ok++; else summary.byType[h.type].dead++;
    }
    console.log('[scanner] 第 ' + this.round + ' 轮完成: ' + ok + ' 可用 / ' + fail + ' 不可用 / 共 ' + allSources.length);
    this._saveJson(path.join(DATA, 'source-scan-summary.json'), summary);
  }

  // API 查询接口
  getHealth(type) {
    const result = {};
    for (const [k, v] of Object.entries(this.health)) {
      if (!type || v.type === type) result[k] = v;
    }
    return result;
  }

  getMetadata(type) {
    const result = {};
    for (const [k, v] of Object.entries(this.metadata)) {
      if (!type || v.type === type) result[k] = v;
    }
    return result;
  }

  getSummary() {
    try { return this._loadJson(path.join(DATA, 'source-scan-summary.json'), {}); } catch (e) { return {}; }
  }
}

module.exports = SourceScanner;
