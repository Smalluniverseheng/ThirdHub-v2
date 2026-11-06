// Neon（PostgreSQL）访问层 —— 数据中心的数据后端。
//
// 为什么单独一个文件（2026-10-23）：
//   原来的账号/同步数据写在 `data/account-state.json` 里，单机单文件，
//   多设备并发写会互相覆盖，也没法在网页端/管理台查。
//   现在数据层统一走 Neon，文件存储仍留在 Supabase（**两类东西分开放，不挤一个项目**）。
//
// 设计原则：
//   · 没配 `NEON_DATABASE_URL` 时**自动降级**为不启用（调用方回退到本地 JSON），
//     保证老部署、单机场景不会因为缺库直接起不来；
//   · 连接用单例池，空闲 10 秒回收；Neon 免费版连接数很少，池子必须小；
//   · 所有函数**不抛**到路由层以外（外面统一 try/catch），失败返回 null。
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

let Pool = null;
try { ({ Pool } = require('pg')); } catch (e) { Pool = null; }

function envOf(k) {
  if (process.env[k]) return process.env[k];
  try {
    // 本机开发兼容：从用户目录读 .env；容器 / CI 一律用 process.env 注入，
    // 找不到就降级为「未配置数据层」，绝不把连接串写进源码或镜像。
    const p = path.join(os.homedir(), 'WorkBuddy', '第三方聚合平台', '.env');
    const t = fs.readFileSync(p, 'utf8');
    const m = t.match(new RegExp('^' + k + '\\s*=\\s*(.+)$', 'm'));
    return m ? m[1].trim().replace(/^["']|["']$/g, '') : '';
  } catch (e) { return ''; }
}

const URL_ = envOf('NEON_DATABASE_URL');
let pool = null;

function enabled() { return !!URL_ && !!Pool; }

function getPool() {
  if (!enabled()) return null;
  if (pool) return pool;
  pool = new Pool({
    connectionString: URL_,
    ssl: { rejectUnauthorized: false },
    max: 3,
    idleTimeoutMillis: 10000,
    connectionTimeoutMillis: 8000,
  });
  pool.on('error', (e) => console.log('[neon] 池错误', e.message));
  return pool;
}

async function q(sql, params) {
  const p = getPool();
  if (!p) return null;
  try {
    const r = await p.query(sql, params || []);
    return r.rows;
  } catch (e) {
    console.log('[neon] 查询失败', e.message);
    return null;
  }
}

/* ---------- 账号同步（th_sync） ---------- */
async function syncGet(account, ns) {
  const rows = await q('select data, rev, device, updated_at from th_sync where account=$1 and ns=$2', [account, ns]);
  if (!rows || !rows.length) return null;
  const r = rows[0];
  return { data: r.data, rev: r.rev, device: r.device || '', updatedAt: r.updated_at ? new Date(r.updated_at).getTime() : 0 };
}

async function syncGetAll(account) {
  const rows = await q('select ns, data, rev, device, updated_at from th_sync where account=$1', [account]);
  if (!rows) return null;
  const out = {};
  for (const r of rows) {
    out[r.ns] = { data: r.data, rev: r.rev, device: r.device || '', updatedAt: r.updated_at ? new Date(r.updated_at).getTime() : 0 };
  }
  return out;
}

/** 写入并返回新记录（rev 自增，最后写入者获胜）。 */
async function syncPut(account, ns, data, device) {
  const rows = await q(
    `insert into th_sync (account, ns, data, rev, device, updated_at)
     values ($1,$2,$3::jsonb,1,$4,now())
     on conflict (account, ns) do update
       set data = excluded.data, rev = th_sync.rev + 1,
           device = excluded.device, updated_at = now()
     returning data, rev, device, updated_at`,
    [account, ns, JSON.stringify(data), device || '']);
  if (!rows || !rows.length) return null;
  const r = rows[0];
  return { data: r.data, rev: r.rev, device: r.device || '', updatedAt: new Date(r.updated_at).getTime() };
}

/* ---------- 更新日志（th_changelog） ---------- */
async function changelogGet(id) {
  const rows = await q('select payload, updated from th_changelog where id=$1', [id]);
  if (!rows || !rows.length) return null;
  return rows[0].payload;
}

async function changelogPut(id, payload) {
  const rows = await q(
    `insert into th_changelog (id, payload, updated) values ($1,$2::jsonb,now())
     on conflict (id) do update set payload = excluded.payload, updated = now()
     returning id`,
    [id, JSON.stringify(payload)]);
  return !!(rows && rows.length);
}

/* ---------- 公告（th_announce） ---------- */
async function announceList(limit) {
  const rows = await q('select id, title, body, kind, created_at from th_announce where active order by created_at desc limit $1',
    [Number(limit) > 0 ? Number(limit) : 20]);
  return rows || [];
}

async function announceCreate(title, body, kind) {
  const rows = await q('insert into th_announce (title, body, kind) values ($1,$2,$3) returning id, created_at',
    [String(title || '').slice(0, 200), String(body || '').slice(0, 4000), String(kind || 'info').slice(0, 16)]);
  return (rows && rows[0]) || null;
}

/* ---------- 资料（th_profiles） ---------- */
async function profileGet(id) {
  const rows = await q('select * from th_profiles where id=$1', [id]);
  return (rows && rows[0]) || null;
}

async function profileUpsert(p) {
  const rows = await q(
    `insert into th_profiles (id, email, nickname, avatar, updated_at)
     values ($1,$2,$3,$4,now())
     on conflict (id) do update
       set email = coalesce(excluded.email, th_profiles.email),
           nickname = coalesce(excluded.nickname, th_profiles.nickname),
           avatar = coalesce(excluded.avatar, th_profiles.avatar),
           updated_at = now()
     returning id`,
    [p.id, p.email || null, p.nickname || null, p.avatar || null]);
  return !!(rows && rows.length);
}


/* ---------- 通用业务数据（th_data）----------
 * Supabase 只放认证与资料，业务数据全部走这里。
 * 表名/行主键都做白名单校验，避免拼 SQL。
 */
const DATA_TABLES = new Set(['bookshelf', 'history', 'favorites', 'progress', 'settings', 'devices', 'shared']);

function tableOk(t) { return DATA_TABLES.has(String(t || '')); }

async function dataList(account, tbl, since) {
  if (!tableOk(tbl)) return null;
  const rows = since
    ? await q('select row_id, data, updated_at from th_data where account=$1 and tbl=$2 and updated_at > $3 order by updated_at desc', [account, tbl, new Date(Number(since))])
    : await q('select row_id, data, updated_at from th_data where account=$1 and tbl=$2 order by updated_at desc', [account, tbl]);
  return rows;
}

async function dataPut(account, tbl, rowId, data) {
  if (!tableOk(tbl) || !rowId) return null;
  const rows = await q(
    `insert into th_data (account, tbl, row_id, data, updated_at)
     values ($1,$2,$3,$4::jsonb,now())
     on conflict (account, tbl, row_id) do update
       set data = excluded.data, updated_at = now()
     returning row_id, updated_at`,
    [account, tbl, String(rowId), JSON.stringify(data)]);
  return (rows && rows[0]) || null;
}

async function dataDelete(account, tbl, rowId) {
  if (!tableOk(tbl)) return null;
  const rows = await q('delete from th_data where account=$1 and tbl=$2 and row_id=$3 returning row_id',
    [account, tbl, String(rowId)]);
  return rows !== null;
}

async function dataStats(account) {
  const rows = await q('select tbl, count(*) c from th_data where account=$1 group by tbl order by 1', [account]);
  return rows || [];
}

module.exports = {
  enabled, getPool,
  syncGet, syncGetAll, syncPut,
  changelogGet, changelogPut,
  announceList, announceCreate,
  profileGet, profileUpsert,
  DATA_TABLES, tableOk, dataList, dataPut, dataDelete, dataStats,
};
