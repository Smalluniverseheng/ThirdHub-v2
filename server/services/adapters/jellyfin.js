// server/services/adapters/jellyfin.js — Jellyfin 影视库适配器
//
// 统一接口（registry 只认这三个）：
//   probe(svc, timeoutMs) → { ok, ms, info, error }
//   search(svc, q)        → [媒体条目]
//   detail(svc, id)       → 媒体条目（含播放地址）
//
// 认证：两种都支持
//   · auth.apiKey  → 请求头 X-Emby-Token（在 Jellyfin 后台「API 密钥」里建）
//   · auth.username/password → POST /Users/AuthenticateByName 换 AccessToken
// 探活走 /System/Info/Public，**不需要任何认证**，所以没配凭证也能显示"服务在线"。
'use strict';

const UA = 'ThirdHub/1.0';

function base(svc) {
  return String(svc.baseUrl || '').replace(/\/+$/, '');
}

async function getJson(url, headers, timeoutMs = 8000) {
  const r = await fetch(url, {
    headers: { 'User-Agent': UA, Accept: 'application/json', ...(headers || {}) },
    signal: AbortSignal.timeout(timeoutMs),
  });
  const t = await r.text();
  if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + t.slice(0, 80));
  try { return JSON.parse(t); } catch (e) { throw new Error('返回不是 JSON'); }
}

// 缓存登录拿到的 token，避免每次搜索都登录一次
const tokenCache = new Map();

async function tokenOf(svc, timeoutMs = 8000) {
  const auth = svc.auth || {};
  if (auth.apiKey) return auth.apiKey;
  if (!auth.username || !auth.password) return '';
  const key = svc.id + '|' + auth.username;
  const hit = tokenCache.get(key);
  if (hit && Date.now() - hit.at < 30 * 60 * 1000) return hit.token;
  const r = await fetch(base(svc) + '/Users/AuthenticateByName', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': UA, 'X-Emby-Authorization':
      'MediaBrowser Client="ThirdHub", Device="NAS", DeviceId="thirdhub-nas", Version="1.0"' },
    body: JSON.stringify({ Username: auth.username, Pw: auth.password }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!r.ok) throw new Error('登录失败 HTTP ' + r.status);
  const j = await r.json();
  const tk = j.AccessToken || '';
  if (tk) tokenCache.set(key, { token: tk, at: Date.now() });
  return tk;
}

function itemToEntry(it, svc) {
  const id = it.Id || '';
  const isSeries = it.Type === 'Series';
  return {
    id,
    title: it.Name || '',
    subtitle: [it.ProductionYear, it.Type === 'Movie' ? '电影' : (isSeries ? '剧集' : it.Type)].filter(Boolean).join(' · '),
    cover: id ? (base(svc) + '/Items/' + id + '/Images/Primary?maxWidth=300&quality=90') : '',
    kind: isSeries ? 'tv' : 'movie',
    source: 'jellyfin',
    serviceId: svc.id,
    extra: {
      year: it.ProductionYear || null,
      overview: String(it.Overview || '').slice(0, 300),
      runtimeTicks: it.RunTimeTicks || 0,
      officialRating: it.OfficialRating || '',
      communityRating: it.CommunityRating || null,
    },
  };
}

module.exports = {
  async probe(svc, timeoutMs = 6000) {
    const t0 = Date.now();
    const j = await getJson(base(svc) + '/System/Info/Public', {}, timeoutMs);
    return {
      ok: true,
      ms: Date.now() - t0,
      info: {
        server: j.ServerName || '',
        version: j.Version || '',
        id: String(j.Id || '').slice(0, 8),
        // 有公网地址说明它自己也知道对外怎么连
        hasPublic: !!(j.LocalAddress && j.LocalAddress.length),
      },
    };
  },

  async search(svc, q, opts = {}) {
    const tk = await tokenOf(svc);
    if (!tk) return []; // 没凭证：只探活，不取内容
    const limit = opts.limit || 20;
    const params = new URLSearchParams({
      searchTerm: String(q || ''),
      IncludeItemTypes: 'Movie,Series',
      Recursive: 'true',
      Limit: String(limit),
      Fields: 'Overview,ProductionYear,CommunityRating,OfficialRating',
      SortBy: 'SortName',
      ImageTypeLimit: '1',
      EnableImageTypes: 'Primary',
    });
    const j = await getJson(base(svc) + '/Items?' + params.toString(), { 'X-Emby-Token': tk });
    return (j.Items || []).map((it) => itemToEntry(it, svc));
  },

  async detail(svc, id) {
    const tk = await tokenOf(svc);
    if (!tk) return null;
    const it = await getJson(base(svc) + '/Items/' + encodeURIComponent(id) +
      '?Fields=Overview,ProductionYear,MediaSources,MediaStreams', { 'X-Emby-Token': tk });
    const e = itemToEntry(it, svc);
    e.extra.mediaSources = (it.MediaSources || []).map((m) => ({
      id: m.Id, name: m.Name, container: m.Container, size: m.Size, path: m.Path,
    }));
    e.playUrl = base(svc) + '/Videos/' + encodeURIComponent(id) + '/stream?static=true&api_key=' + tk;
    return e;
  },
};
