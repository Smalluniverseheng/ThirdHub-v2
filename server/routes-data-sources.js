// 数据源分层（全盘升级 #208 / #209，2026-11-07）
//
// 用户要求：移动端面向大众 / 准备上架苹果，只接厂商官方公开、免费开放的 API；
// 不适合公开的内容源全部放桌面端 / NAS 的管理后台，只给管理员或管理员授权的人用。
//
// 本模块提供两类端点，权限边界在**服务端**（不是前端藏按钮）：
//   · GET  /v1/public-sources           免鉴权，挂在 x-th-token 闸门之前
//                                       只回官方公开清单，绝不含任何第三方内容源
//   · GET  /v1/admin/source-registry    需配对 token（管理员设备），回敏感源注册表
//   · GET  /v1/admin/source-grants      需配对 token，回被授权账号
//   · POST /v1/admin/source-grants     需配对 token，管理员授权/撤销某账号
//
// ★ 只存「名称 / 类别 / 备注」这类元信息，不内置任何抓取规则或脚本内容。
//   实际源配置仍由管理员在自己设备上自行添加（走既有 /v1/sources 路由）。
'use strict';
const fs = require('fs');
const path = require('path');

// 与 flutter_app/lib/core/public_data_sources.dart 的 kPublicDataSources 逐条对应。
// server/test_data_sources.cjs 会解析 Dart 表逐 id 比对，防止两端漂移。
const PUBLIC = [
  { id: 'open_meteo', name: 'Open-Meteo', category: 'weather', needsKey: false },
  { id: 'nominatim', name: 'OpenStreetMap Nominatim', category: 'geo', needsKey: false },
  { id: 'open_library', name: 'Open Library', category: 'metadata', needsKey: false },
  { id: 'google_books', name: 'Google Books API', category: 'metadata', needsKey: false },
  { id: 'musicbrainz', name: 'MusicBrainz', category: 'metadata', needsKey: false },
  { id: 'wikidata', name: 'Wikidata / Wikipedia', category: 'search', needsKey: false },
  { id: 'github_rest', name: 'GitHub REST API', category: 'search', needsKey: false },
  { id: 'anilist', name: 'AniList GraphQL', category: 'metadata', needsKey: false },
  { id: 'aliyun_tts', name: 'Alibaba Cloud Speech', category: 'tts', needsKey: true },
  { id: 'volc_tts', name: 'Volcengine Speech', category: 'tts', needsKey: true },
  { id: 'azure_speech_free', name: 'Azure Speech (F0)', category: 'tts', needsKey: true },
  { id: 'tmdb', name: 'TMDB', category: 'metadata', needsKey: true },
  { id: 'omdb', name: 'OMDb API', category: 'metadata', needsKey: true },
  { id: 'lastfm', name: 'Last.fm', category: 'metadata', needsKey: true },
  { id: 'deepl_free', name: 'DeepL API Free', category: 'translate', needsKey: true },
  { id: 'aliyun_bailian', name: 'Alibaba Cloud Bailian', category: 'ai', needsKey: true },
  { id: 'volc_doubao', name: 'Volcengine Doubao', category: 'ai', needsKey: true },
  { id: 'zhipu_glm', name: 'Zhipu GLM', category: 'ai', needsKey: true },
  { id: 'moonshot_kimi', name: 'Moonshot Kimi', category: 'ai', needsKey: true },
  { id: 'xiaomi_mimo', name: 'Xiaomi MiMo', category: 'ai', needsKey: true },
  { id: 'tencent_hunyuan', name: 'Tencent Hunyuan', category: 'ai', needsKey: true },
];

// 桌面端管理后台可见的「敏感源类别」注册表（只有元信息，不含规则正文）。
const ADMIN_REGISTRY = [
  { id: 'third_party_comic', name: 'Third-party comic sources', category: 'comic', note: 'Admin-added only; never shipped to mobile' },
  { id: 'third_party_novel', name: 'Third-party novel sources', category: 'novel', note: 'Admin-added only; never shipped to mobile' },
  { id: 'third_party_media', name: 'Third-party media sources', category: 'video', note: 'Admin-added only; never shipped to mobile' },
  { id: 'self_hosted_engines', name: 'Self-hosted engine config', category: 'engine', note: 'Local / NAS only' },
  { id: 'proxy_rules', name: 'Proxy and collection rules', category: 'engine', note: 'Admin console only' },
];

const BANNED = ['copy_manga', 'baozi', 'komiic', '书源', '图源', '换源', '采集', '破解', '盗版'];

function grantsFile(DATA) { return path.join(DATA, 'source-grants.json'); }

function readGrants(DATA) {
  try {
    const j = JSON.parse(fs.readFileSync(grantsFile(DATA), 'utf8'));
    return Array.isArray(j.accounts) ? j.accounts.filter(a => typeof a === 'string' && a.trim()) : [];
  } catch (e) { return []; }
}

function writeGrants(DATA, accounts) {
  const f = grantsFile(DATA);
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, JSON.stringify({ updated: new Date().toISOString(), accounts }, null, 2), 'utf8');
}

/** 公开端点：移动端 / 公开网页端匿名可读，只回官方清单。 */
async function handlePublic(req, res, p, send) {
  if (p === '/v1/public-sources' && req.method === 'GET') {
    send(200, {
      object: 'list', scope: 'public', count: PUBLIC.length,
      note: 'Official public APIs only. Third-party content sources are admin-console only.',
      data: PUBLIC,
    });
    return true;
  }
  return false;
}

/** 管理端点：必须挂在 x-th-token 闸门之后调用。 */
async function handleAdmin(req, res, body, p, send, ctx) {
  const DATA = ctx.DATA;
  if (p === '/v1/admin/source-registry' && req.method === 'GET') {
    send(200, {
      object: 'list', scope: 'admin', count: ADMIN_REGISTRY.length,
      grantedAccounts: readGrants(DATA),
      note: 'Metadata only. Actual source configs live on this device and are added by the admin.',
      data: ADMIN_REGISTRY,
    });
    return true;
  }
  if (p === '/v1/admin/source-grants' && req.method === 'GET') {
    send(200, { object: 'list', scope: 'admin', data: readGrants(DATA) });
    return true;
  }
  if (p === '/v1/admin/source-grants' && req.method === 'POST') {
    let d = {};
    try { d = JSON.parse(body || '{}'); } catch (e) {}
    const account = String(d.account || '').trim();
    if (!account || account.length > 120) {
      send(400, { object: 'error', data: { type: 'invalid_request', message: '需 account' } });
      return true;
    }
    const list = readGrants(DATA);
    const revoke = d.revoke === true || d.action === 'revoke';
    const next = revoke ? list.filter(a => a !== account)
      : (list.includes(account) ? list : [...list, account]);
    writeGrants(DATA, next);
    send(200, { object: 'meta', scope: 'admin', data: { account, granted: !revoke, accounts: next } });
    return true;
  }
  return false;
}

/** 公开清单准入断言：任何一条不满足就不许下发到移动端。 */
function isPublicClean() {
  const blob = JSON.stringify(PUBLIC).toLowerCase();
  for (const t of BANNED) if (blob.includes(t.toLowerCase())) return false;
  return PUBLIC.every(s => s.id && s.name && s.category && typeof s.needsKey === 'boolean');
}

module.exports = { handlePublic, handleAdmin, PUBLIC, ADMIN_REGISTRY, BANNED, isPublicClean, readGrants };
