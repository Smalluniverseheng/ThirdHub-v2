// ─────────────────────────────────────────────────────────────────────────────
// request-log.js — 出站请求的观测日志（环形缓冲 + 可选 JSONL 落盘）
//
// 为什么要有这个文件（`docs/TASKS.md` 组C「短缓存 + 观测日志(request_log)」长期未完成）：
//   后端一直在**记账**（`health` Map 记 ok/fail、缓存记命中），但从来不**留痕** ——
//   也就是说，"哪个源在什么时候、用多久、返回了几条、为什么失败"这些**事后无法回答**。
//   于是所有"搜不出东西"的排查都只能靠现场复现，用户一说"搜不出来"，
//   这边就只能让他再搜一次看看 —— 而现场早就没了。
//
// 三个设计约束（都是为了让它真的被用起来，而不是又一个没人读的日志文件）：
//   ① **有界**：内存环形缓冲固定 500 条。日志最怕把自家进程撑死（本后端还要跟
//      "旧手机变服务器"的 2GB 内存场景共存）——所以宁可丢老数据，绝不无界增长。
//   ② **可查询**：`list()` 支持 kind / ok / 时间 / 条数过滤，直接喂给
//      `/v1/request-log` 端点，前端/控制台/我自己都能直接问。
//   ③ **落盘可选且带轮转**：默认写到 `data/request-log.jsonl`，超过 2MB 就切一份 `.1`。
//      没有落盘的话，进程一重启，"昨天为什么搜不出"就永远查不到了。
//
// 只记**摘要**，不记正文 —— 正文可能很大，而且可能含用户搜索词之外的内容。
'use strict';

const fs = require('fs');
const path = require('path');

const MEM_MAX = 500;              // 内存环形缓冲条数
const FILE_MAX_BYTES = 2 * 1024 * 1024; // 单文件 2MB 就轮转

/** 内存环形缓冲，最新的在最后 */
const ring = [];
let seq = 0;
let filePath = null;
let dropped = 0;                  // 因缓冲满而只在文件里、不在内存里的条数（供 stats 用）

/** 初始化落盘路径（可选）。不调用就是纯内存模式。 */
function init(dataDir) {
  try {
    if (!dataDir) return;
    fs.mkdirSync(dataDir, { recursive: true });
    filePath = path.join(dataDir, 'request-log.jsonl');
  } catch (_) { filePath = null; }
}

function rotateIfNeeded() {
  if (!filePath) return;
  try {
    const st = fs.statSync(filePath);
    if (st.size < FILE_MAX_BYTES) return;
    fs.renameSync(filePath, filePath + '.1'); // 覆盖上一份 .1，只留一代
  } catch (_) { /* 文件不存在或权限问题 → 直接跳过 */ }
}

/**
 * 记一条。
 * @param {{kind:string, target?:string, source?:string, ok:boolean,
 *          ms?:number, count?:number, error?:string, extra?:object}} e
 */
function record(e) {
  if (!e || typeof e !== 'object') return null;
  const entry = {
    seq: ++seq,
    at: Date.now(),
    kind: String(e.kind || 'other'),
    target: e.target ? String(e.target).slice(0, 300) : '',
    source: e.source ? String(e.source).slice(0, 120) : '',
    ok: e.ok !== false,
    ms: Number.isFinite(e.ms) ? Math.round(e.ms) : null,
    count: Number.isFinite(e.count) ? e.count : null,
    error: e.error ? String(e.error).slice(0, 200) : '',
    extra: (e.extra && typeof e.extra === 'object') ? e.extra : undefined,
  };
  ring.push(entry);
  if (ring.length > MEM_MAX) { ring.shift(); dropped++; }
  if (filePath) {
    try { rotateIfNeeded(); fs.appendFileSync(filePath, JSON.stringify(entry) + '\n'); } catch (_) {}
  }
  return entry;
}

/**
 * 查询。
 * @param {{limit?:number, kind?:string, ok?:boolean, since?:number, until?:number}} [f]
 */
function list(f = {}) {
  let out = ring;
  if (f.kind) out = out.filter(r => r.kind === f.kind);
  if (typeof f.ok === 'boolean') out = out.filter(r => r.ok === f.ok);
  if (Number.isFinite(f.since)) out = out.filter(r => r.at >= f.since);
  if (Number.isFinite(f.until)) out = out.filter(r => r.at <= f.until);
  const limit = Number.isFinite(f.limit) ? Math.max(1, Math.min(2000, f.limit)) : 100;
  // 最新的在前（排查时想先看刚发生的）
  return out.slice(-limit).reverse();
}

/** 按 kind/source 聚合的概览 —— 排查时第一眼要看的就是这个。 */
function stats() {
  const byKind = {};
  const bySource = {};
  for (const r of ring) {
    const k = byKind[r.kind] || (byKind[r.kind] = { total: 0, ok: 0, fail: 0, avgMs: 0, _sum: 0 });
    k.total++; k.ok += r.ok ? 1 : 0; k.fail += r.ok ? 0 : 1;
    if (Number.isFinite(r.ms)) { k._sum += r.ms; k.avgMs = Math.round(k._sum / k.total); }
    if (r.source) {
      const s = bySource[r.source] || (bySource[r.source] = { total: 0, ok: 0, fail: 0, avgMs: 0, _sum: 0, lastError: '' });
      s.total++; s.ok += r.ok ? 1 : 0; s.fail += r.ok ? 0 : 1;
      if (Number.isFinite(r.ms)) { s._sum += r.ms; s.avgMs = Math.round(s._sum / s.total); }
      if (!r.ok && r.error) s.lastError = r.error;
    }
  }
  for (const v of Object.values(byKind)) delete v._sum;
  for (const v of Object.values(bySource)) delete v._sum;
  return {
    total: ring.length, capacity: MEM_MAX, seq, droppedFromRing: dropped,
    oldest: ring.length ? ring[0].at : null, newest: ring.length ? ring[ring.length - 1].at : null,
    persisted: !!filePath, byKind, bySource,
  };
}

function clear() { const n = ring.length; ring.length = 0; return n; }

/** 记录用的一次性计时器：`const t = timer(); ... t.done({...})` */
function timer() {
  const t0 = Date.now();
  return {
    elapsed: () => Date.now() - t0,
    done: (e) => record({ ...e, ms: e && Number.isFinite(e.ms) ? e.ms : Date.now() - t0 }),
  };
}

module.exports = { init, record, list, stats, clear, timer, MEM_MAX, FILE_MAX_BYTES };
