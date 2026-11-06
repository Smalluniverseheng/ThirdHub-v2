// 三端统一账号绑定与设备互通同步契约 v1（全盘升级任务 #202）· 桌面端镜像
//
// 唯一真源：仓库根 contracts/unified_sync_v1.json。
// 移动端镜像：flutter_app/lib/core/device_sync_contract.dart。
// 三份字典逐键一致由 flutter_app/tool/device_sync_contract_selfcheck.dart 断言。
//
// 为什么字典要内联而不是运行时 require JSON：
//   server/index.js 会被 esbuild 全量 bundle 成单文件 SEA EXE，Docker 镜像也只带
//   server/ 目录；让运行时去读 ../contracts/*.json 在 EXE 里必然 ERR_MODULE_NOT_FOUND。
//   内联 + 闸门比对，既保住「三端不漂移」，又不给打包链路加一条隐性依赖。
//
// 术语：前端 = 移动端，后端 = 桌面端，资料库 = 用户自装的资料服务。
'use strict';

const SCHEMA = 'thirdhub.unified_sync/1';
const VERSION = '1.0.0';

const SYNC_TABLES = [
  'th_bookshelf',
  'th_reading_progress',
  'th_history',
  'th_favorites',
  'th_settings',
  'th_user_devices',
];

// 规范表名 -> 后端 /v1/data/:tbl 短名（与网页端 TBL_MAP、server/neon.js DATA_TABLES 一致）。
const TABLE_ALIASES = {
  th_bookshelf: 'bookshelf',
  th_reading_progress: 'progress',
  th_history: 'history',
  th_favorites: 'favorites',
  th_settings: 'settings',
  th_user_devices: 'devices',
};

// 后端自用、不进三端同步信封的表。
const BACKEND_EXTRA_TABLES = ['shared'];

const SESSION_TABLE = 'th_chats';
const DEVICE_TABLE = 'th_user_devices';
const DISCOVERY_TABLE = 'th_devices';
const PAIR_TABLE = 'th_device_pairs';

const DEVICE_KINDS = ['mobile', 'web', 'exe', 'nas'];
const DEVICE_REQUIRED_FIELDS = ['device_id', 'name', 'kind', 'capabilities', 'last_seen', 'user_id'];
const DEVICE_PRIORITY = { nas: 40, exe: 30, web: 20, mobile: 10 };
const DEVICE_CAPABILITIES = ['sync', 'direct', 'relay', 'notify'];
const SYNC_CHANNELS = ['official_cloud', 'device_direct'];
const SYNC_TRANSPORTS = ['lan', 'ipv6', 'p2p', 'relay'];
const SETTINGS_TABLES = ['th_settings', 'th_user_devices'];
const CONTENT_TABLES = ['th_bookshelf', 'th_reading_progress', 'th_history', 'th_favorites'];

const CONFLICT_STRATEGY = 'updated_at_lww';
const TIE_BREAK = 'device_priority_then_device_id';
const DELETE_RULE = 'tombstone';

function accountScopeOf(userId) {
  return String(userId == null ? '' : userId).trim().toLowerCase();
}

function isValidAccountScope(userId) {
  return accountScopeOf(userId).length > 0;
}

function epochMsOf(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v < 0 ? 0 : Math.trunc(v);
  if (typeof v === 'string') {
    const n = Number.parseInt(v.trim(), 10);
    return Number.isFinite(n) && n >= 0 ? n : 0;
  }
  return 0;
}

// 设备行规范化：不合法就整行丢弃，绝不「洗白」（见 zip-slip 与 NAS 回落成手机两个坑）。
function normalizeDeviceRow(raw, accountId) {
  const scope = accountScopeOf(accountId);
  if (!scope || !raw || typeof raw !== 'object') return null;
  const id = String(raw.device_id == null ? '' : raw.device_id).trim();
  if (!id || id.length > 128) return null;
  if (id.includes('/') || id.includes('\\') || id.includes('..')) return null;
  const kind = String(raw.kind == null ? '' : raw.kind).trim().toLowerCase();
  if (!DEVICE_KINDS.includes(kind)) return null;
  const caps = [];
  if (Array.isArray(raw.capabilities)) {
    for (const c of raw.capabilities) {
      const s = String(c == null ? '' : c).trim().toLowerCase();
      if (DEVICE_CAPABILITIES.includes(s) && !caps.includes(s)) caps.push(s);
    }
  }
  if (caps.length === 0) caps.push('sync');
  const name = String(raw.name == null ? '' : raw.name).trim();
  return {
    device_id: id,
    name: name || kind,
    kind,
    capabilities: caps,
    last_seen: epochMsOf(raw.last_seen),
    user_id: scope,
  };
}

// 冲突裁决：后写胜出 -> 同秒设备优先级 -> device_id 字典序（确定性）。
function resolveConflict(o) {
  const {
    localTs, cloudTs, localKind, cloudKind, localDeviceId, cloudDeviceId,
  } = o || {};
  if (localTs > cloudTs) return 'local';
  if (cloudTs > localTs) return 'cloud';
  const lp = DEVICE_PRIORITY[localKind] || 0;
  const cp = DEVICE_PRIORITY[cloudKind] || 0;
  if (lp > cp) return 'local';
  if (cp > lp) return 'cloud';
  const a = String(localDeviceId == null ? '' : localDeviceId);
  const b = String(cloudDeviceId == null ? '' : cloudDeviceId);
  if (a > b) return 'local';
  if (a < b) return 'cloud';
  return 'equal';
}

function pickChannel(o) {
  if (o && o.directReachable) return 'device_direct';
  if (o && o.cloudReachable) return 'official_cloud';
  return 'offline';
}

// 服务端表级权限校验：合规分层要求真校验，不是前端隐藏按钮。
function canSyncTable(o) {
  const { table, loggedIn, isMember, selfHosted } = o || {};
  if (!loggedIn) return false;
  if (!SYNC_TABLES.includes(table)) return false;
  if (CONTENT_TABLES.includes(table)) return !!(isMember || selfHosted);
  return true;
}

// 墓碑键：与移动端 tombstoneKeyOf / core/sync_contract.dart tombKeyOf 逐字一致。
function tombstoneKeyOf(table, rowId) {
  return table + ':' + rowId;
}

// 短名是否允许进 /v1/data/:tbl（后端自用 shared 也放行）。
function isBackendTableAllowed(short) {
  return Object.values(TABLE_ALIASES).includes(short) || BACKEND_EXTRA_TABLES.includes(short);
}

// 后端短名 -> 规范表名；后端自用的 shared 不在契约信封里，返回 null。
function canonicalTableOf(short) {
  for (const [canon, alias] of Object.entries(TABLE_ALIASES)) {
    if (alias === short) return canon;
  }
  return null;
}

function mergeDevices(rows) {
  const byId = new Map();
  for (const r of rows || []) {
    const id = String(r && r.device_id != null ? r.device_id : '').trim();
    if (!id) continue;
    const prev = byId.get(id);
    if (!prev || epochMsOf(r.last_seen) >= epochMsOf(prev.last_seen)) byId.set(id, r);
  }
  return [...byId.keys()].sort().map((k) => byId.get(k));
}

function mergeSessions(rows) {
  const byId = new Map();
  for (const r of rows || []) {
    const id = String(r && r.id != null ? r.id : '').trim();
    if (!id) continue;
    const prev = byId.get(id);
    if (!prev || epochMsOf(r.updated_at) >= epochMsOf(prev.updated_at)) byId.set(id, r);
  }
  return [...byId.values()].sort((a, b) => {
    const d = epochMsOf(b.updated_at) - epochMsOf(a.updated_at);
    return d !== 0 ? d : String(a.id).localeCompare(String(b.id));
  });
}

module.exports = {
  SCHEMA, VERSION, SYNC_TABLES, TABLE_ALIASES, BACKEND_EXTRA_TABLES,
  SESSION_TABLE, DEVICE_TABLE, DISCOVERY_TABLE, PAIR_TABLE,
  DEVICE_KINDS, DEVICE_REQUIRED_FIELDS, DEVICE_PRIORITY, DEVICE_CAPABILITIES,
  SYNC_CHANNELS, SYNC_TRANSPORTS, SETTINGS_TABLES, CONTENT_TABLES,
  CONFLICT_STRATEGY, TIE_BREAK, DELETE_RULE,
  accountScopeOf, isValidAccountScope, normalizeDeviceRow, resolveConflict,
  pickChannel, canSyncTable, tombstoneKeyOf, isBackendTableAllowed,
  canonicalTableOf, mergeDevices, mergeSessions,
};
