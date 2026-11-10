// server/services/gateway.js — 服务网关：把「多个开源容器」聚成一个调用面
//
// 前后端契约（App 与网页端都只认这一层）：
//   GET  /v1/gateway/services           → 有哪些服务、在不在线、要不要配凭证
//   GET  /v1/gateway/search?q=&kinds=   → 一次搜，跨所有服务，结果分组返回
//   GET  /v1/gateway/detail?service=&id=→ 单个条目详情（含播放地址）
//   GET  /v1/gateway/downloads          → 下载任务列表
//   POST /v1/gateway/download           → 丢给下载器
//
// 三条铁律：
//   ① 一个服务超时/报错，**不影响**其它服务的结果（各自独立 Promise + 超时）
//   ② 结果统一成同一种"媒体条目"，前端不认服务，只认 kind
//   ③ 凭证与内网地址**不出后端**，前端拿到的是已脱敏的在线状态
'use strict';
const registry = require('./registry');

const SEARCH_TIMEOUT = 12000;

// 只有这些类型参与内容搜索（download/storage/info 不参与）
const CONTENT_KINDS = ['movie', 'tv', 'music', 'book', 'comic'];

function adapterSearchable(ad) {
  return !!(ad && typeof ad.search === 'function');
}

/**
 * 跨服务统一搜索
 * @param {string} q 关键词
 * @param {{kinds?: string, limitPerService?: number}} opts
 */
async function search(q, opts = {}) {
  const qq = String(q || '').trim();
  if (!qq) return { q: '', groups: [], total: 0 };

  const want = opts.kinds ? String(opts.kinds).split(',').map((x) => x.trim()).filter(Boolean) : CONTENT_KINDS;
  const limit = Math.max(1, Math.min(50, Number(opts.limitPerService) || 20));

  // 先拿在线列表（15 秒缓存，避免每次搜索都把每个服务打一遍）
  const rows = await registry.list(false);
  const onlineIds = new Set(rows.filter((r) => r.online).map((r) => r.id));

  const targets = registry.enabled().filter((svc) => {
    if (!CONTENT_KINDS.includes(svc.kind) && svc.kind !== 'info') return false;
    if (!want.includes(svc.kind)) return false;
    if (!onlineIds.has(svc.id)) return false;
    return adapterSearchable(registry.adapterOf(svc));
  });

  const groups = await Promise.all(targets.map(async (svc) => {
    const t0 = Date.now();
    const ad = registry.adapterOf(svc);
    try {
      const items = await Promise.race([
        Promise.resolve(ad.search(svc, qq, { limit })),
        new Promise((_, rej) => setTimeout(() => rej(new Error('服务响应超时')), SEARCH_TIMEOUT)),
      ]);
      return {
        serviceId: svc.id, serviceName: svc.name || svc.id, kind: svc.kind,
        ok: true, latency: Date.now() - t0,
        items: (items || []).slice(0, limit),
      };
    } catch (e) {
      return {
        serviceId: svc.id, serviceName: svc.name || svc.id, kind: svc.kind,
        ok: false, latency: Date.now() - t0, items: [],
        error: String((e && e.message) || e).slice(0, 160),
      };
    }
  }));

  // 有内容的排前面，其次按延迟
  groups.sort((a, b) => (b.items.length - a.items.length) || (a.latency - b.latency));
  const total = groups.reduce((n, g) => n + g.items.length, 0);
  return { q: qq, groups, total, services: targets.length };
}

/** 单个条目详情（含播放/直链） */
async function detail(serviceId, id) {
  const svc = registry.get(serviceId);
  if (!svc) return { error: '服务不存在: ' + serviceId };
  const ad = registry.adapterOf(svc);
  if (!ad || typeof ad.detail !== 'function') return { error: '该服务不支持详情' };
  try {
    return await ad.detail(svc, id);
  } catch (e) {
    return { error: String((e && e.message) || e) };
  }
}

/** 所有下载器的任务汇总（前端"我的下载"页） */
async function downloads() {
  const list = [];
  const svcs = registry.enabled().filter((s) => s.kind === 'download');
  for (const svc of svcs) {
    const ad = registry.adapterOf(svc);
    if (!ad || typeof ad.list !== 'function') continue;
    try {
      const arr = await ad.list(svc);
      for (const x of arr) list.push({ ...x, serviceId: svc.id });
    } catch (e) {
      list.push({ serviceId: svc.id, error: String((e && e.message) || e).slice(0, 120) });
    }
  }
  return list;
}

/** 统一下载入口：给一个链接/磁力，丢给第一个可用的下载器 */
async function addDownload(url, opts = {}) {
  const svcs = registry.enabled().filter((s) => s.kind === 'download');
  const tried = [];
  for (const svc of svcs) {
    const ad = registry.adapterOf(svc);
    if (!ad || typeof ad.addTorrent !== 'function') continue;
    try {
      const r = await ad.addTorrent(svc, url, opts);
      if (r && r.ok) return { ok: true, via: svc.id, ...r };
      tried.push(svc.id + ': ' + (r && r.raw) || 'failed');
    } catch (e) {
      tried.push(svc.id + ': ' + String((e && e.message) || e).slice(0, 80));
    }
  }
  return { ok: false, error: '没有可用的下载器', tried };
}

module.exports = { search, detail, downloads, addDownload, CONTENT_KINDS };
