// server/services/registry.js — 服务插件注册表
//
// 设计目标（用户 2026-11-10 的要求）：
//   App/网页端**只连一个地址**（ThirdHub 主容器），后面挂了哪些开源服务、
//   各在哪个端口、要不要凭证，前端一律不需要知道。主容器按这张表去调。
//
// 两个关键约束：
//   ① **凭证不出后端**：`list()` 只回「已配置/未配置」，绝不回明文；
//      只有后端内部调适配器时才 `get()` 取完整配置。
//   ② **一个适配器坏了不许拖死全部**：require 与 probe 全部 try/catch，
//      某个适配器文件不存在或抛异常，只标记该服务不可用，其余照常。
//
// 表位置：data/services.json（容器内 /app/data/services.json，宿主机可直接改，重启生效）
'use strict';
const fs = require('fs');
const path = require('path');

const DATA = process.env.TH_DATA_DIR || path.join(__dirname, '..', 'data');
const FILE = path.join(DATA, 'services.json');

/** 探活结果缓存：15 秒内不重复打，避免前端刷新一次就把每个服务问一遍 */
const probeCache = new Map();
const PROBE_TTL = 15000;

function loadRaw() {
  try {
    const j = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    const list = Array.isArray(j) ? j : (j.services || []);
    return list.filter((x) => x && x.id);
  } catch (e) {
    return [];
  }
}

function saveRaw(list) {
  try {
    let doc = { services: list };
    try {
      const old = JSON.parse(fs.readFileSync(FILE, 'utf8'));
      if (!Array.isArray(old)) doc = { ...old, services: list }; // 保留 _说明 等注释字段
    } catch (_) {}
    fs.writeFileSync(FILE, JSON.stringify(doc, null, 2), 'utf8');
    return true;
  } catch (e) {
    return false;
  }
}

/** 把 auth 里的明文换成「已配置(长度)」，供前端展示 */
function maskAuth(auth) {
  const out = {};
  for (const [k, v] of Object.entries(auth || {})) {
    const s = v == null ? '' : String(v);
    out[k] = s ? ('已配置·' + s.length + '位') : '';
  }
  return out;
}

/** 懒加载适配器；文件不存在/语法错都只返回 null，不抛 */
function adapterOf(svc) {
  if (!svc || !svc.adapter) return null;
  try {
    return require(path.join(__dirname, 'adapters', svc.adapter + '.js'));
  } catch (e) {
    return null;
  }
}

/**
 * 探活一个服务。返回 { ok, ms, info, error }
 * 适配器自己实现 probe（能拿到版本号、库数量等）；没有适配器时退回「HTTP 可达」。
 */
async function probeOne(svc, timeoutMs = 6000) {
  const t0 = Date.now();
  const ad = adapterOf(svc);
  if (!ad || typeof ad.probe !== 'function') {
    try {
      const r = await fetch(svc.baseUrl, {
        method: 'GET',
        signal: AbortSignal.timeout(timeoutMs),
        redirect: 'manual',
      });
      return { ok: r.status < 500, ms: Date.now() - t0, info: { http: r.status, bare: true } };
    } catch (e) {
      return { ok: false, ms: Date.now() - t0, error: String((e && e.message) || e) };
    }
  }
  try {
    const r = await ad.probe(svc, timeoutMs);
    return { ...r, ms: r.ms != null ? r.ms : Date.now() - t0 };
  } catch (e) {
    return { ok: false, ms: Date.now() - t0, error: String((e && e.message) || e) };
  }
}

/**
 * 对外列表：脱敏 + 带最近一次探活结果。
 * @param {boolean} refresh 是否强制重新探活
 */
async function list(refresh = false) {
  const all = loadRaw();
  const out = [];
  await Promise.all(all.map(async (svc) => {
    let p = probeCache.get(svc.id);
    if (refresh || !p || Date.now() - p.at > PROBE_TTL) {
      if (svc.enabled === false) {
        p = { at: Date.now(), ok: false, info: null, error: '未启用' };
      } else {
        const r = await probeOne(svc);
        p = { at: Date.now(), ...r };
      }
      probeCache.set(svc.id, p);
    }
    out.push({
      id: svc.id,
      name: svc.name || svc.id,
      kind: svc.kind || '',
      adapter: svc.adapter || '',
      enabled: svc.enabled !== false,
      note: svc.note || '',
      auth: maskAuth(svc.auth),
      online: !!p.ok,
      latency: p.ms || 0,
      info: p.info || null,
      error: p.error || '',
    });
  }));
  // 稳定顺序：enabled 在前，再按 kind 名
  out.sort((a, b) => (b.enabled - a.enabled) || String(a.kind).localeCompare(String(b.kind)) || a.id.localeCompare(b.id));
  return out;
}

/** 取完整配置（含明文凭证）—— **仅限后端内部调用** */
function get(id) {
  return loadRaw().find((x) => x.id === id) || null;
}

/** 取所有启用的服务（含凭证），供网关编排使用 */
function enabled() {
  return loadRaw().filter((x) => x.enabled !== false);
}

/** 只改指定字段（比如填上凭证）；不改的保持原样 */
function update(id, patch) {
  const all = loadRaw();
  const i = all.findIndex((x) => x.id === id);
  if (i < 0) return null;
  all[i] = { ...all[i], ...patch, auth: { ...(all[i].auth || {}), ...((patch && patch.auth) || {}) } };
  saveRaw(all);
  probeCache.delete(id);
  return all[i];
}

/** 清掉探活缓存（改完配置后调） */
function invalidate(id) {
  if (id) probeCache.delete(id); else probeCache.clear();
}

/** 按 kind 过滤出在线的服务 */
async function online(kind) {
  const rows = await list(false);
  return rows.filter((r) => r.online && (!kind || r.kind === kind))
    .map((r) => get(r.id))
    .filter(Boolean);
}

module.exports = {
  FILE, loadRaw, saveRaw, list, get, enabled, update, invalidate, online,
  adapterOf, probeOne, maskAuth,
};
