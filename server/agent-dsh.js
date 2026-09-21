// ═══════════════════════════════════════════════════════════════════════════
// ThirdHub v4 · Agent Runtime（DSH 适配层）
//
// 设计立场（见 docs/AGENT-PROTOCOL.md）：
//   · DeepSeek Harness(DSH) 只跑在 server / 局域网设备上，**不进 Dart**；
//   · 本文件是 ThirdHub 自己的那一层：事件日志 / 确认队列 / 审计 / 策略判定 /
//     DSH 生命周期。**即使一台机器上根本没装 DSH，这一层也必须完整可用** ——
//     因为 Flutter 侧要靠它来判断「走完整 Agent 还是降级为轻量 Agent」。
//
// 于是本层的「能力」与「运行模式」是分开的两件事：
//   能力（永远在线）：append-only 事件日志、profile 风险判定、确认队列、审计
//   模式（探测决定）：full  = 接上了 DSH，事件由 DSH 产出
//                     fallback = 没接上，Flutter 自己用 ai.dart + local_tools 跑轻量循环
//
// 存储（全部 append-only，重启不丢）：
//   <DATA>/agent-sessions/index.json      会话索引
//   <DATA>/agent-sessions/<sid>.jsonl     单会话事件流（一行一个事件）
//   <DATA>/agent-audit.jsonl              审计流水（跨会话）
//   <DATA>/agent-confirms.json            挂起确认队列（重启不丢，见 §14）
//   <DATA>/agent-artifacts/<id>.txt       产物全文（大 diff / 大日志落这里，事件里只放预览）
// ═══════════════════════════════════════════════════════════════════════════
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, execFileSync } = require('child_process');

// ── 常量 ────────────────────────────────────────────────────────────────────
const EVENT_TYPES = [
  'user_message', 'assistant_delta', 'assistant_message', 'tool_call', 'tool_result',
  'confirm_request', 'confirm_result', 'audit', 'artifact', 'error', 'done',
];
const MODES = { FULL: 'full', FALLBACK: 'fallback' };
const DECISIONS = ['allow', 'confirm', 'deny'];

// artifact 文本落地阈值：小文本直接内联进事件（客户端即刻高亮，无需回取），
// 超过则全文落 <DATA>/agent-artifacts/，事件里只带前 N 行预览 + textTruncated 标记。
// 这样「大段内容不进对话流」的协议承诺才真正兑现 —— 事件流读起来永远是轻的。
const ARTIFACT_INLINE_MAX_LINES = 400;
const ARTIFACT_INLINE_MAX_CHARS = 24000;
const ARTIFACT_PREVIEW_LINES = 120;

// ── 内部状态 ────────────────────────────────────────────────────────────────
let DATA_DIR = '';
let PROFILES = null;            // agent-profiles.json 内容
let PLUGINS = null;             // agent-plugins.json 内容
const SESS = new Map();         // sid -> {meta, events:[], seq}
const PENDING = new Map();      // confirmId -> {sid, tool, args, risk, at}
let DSH_STATE = { mode: MODES.FALLBACK, kind: 'none', target: '', version: '', lastProbe: 0, error: '', proc: null };
let _seq = 0;
let _artSeq = 0;

// ── 工具与 id ───────────────────────────────────────────────────────────────
function nextEventId() {
  _seq += 1;
  return 'evt_' + Date.now().toString(36) + '_' + _seq.toString(36).padStart(4, '0');
}
function nextSessionId() {
  _seq += 1;
  return 'sess_' + Date.now().toString(36) + '_' + _seq.toString(36).padStart(3, '0');
}

function readJsonSafe(f, dflt) {
  try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { return dflt; }
}

function profilesPath() { return path.join(__dirname, 'agent-profiles.json'); }
function pluginsPath() { return path.join(__dirname, 'agent-plugins.json'); }

function loadProfiles() {
  if (!PROFILES) PROFILES = readJsonSafe(profilesPath(), { version: 1, profiles: {}, risk: {} });
  return PROFILES;
}
function loadPlugins() {
  if (!PLUGINS) PLUGINS = readJsonSafe(pluginsPath(), { version: 1, plugins: [], policy: {} });
  return PLUGINS;
}

function init(dataDir) {
  const next = dataDir || DATA_DIR || '.';
  const switched = next !== DATA_DIR;   // 数据目录变了才重载队列，否则每个请求都读一次盘
  DATA_DIR = next;
  try { fs.mkdirSync(path.join(DATA_DIR, 'agent-sessions'), { recursive: true }); } catch (_) {}
  try { fs.mkdirSync(path.join(DATA_DIR, 'agent-artifacts'), { recursive: true }); } catch (_) {}
  loadProfiles(); loadPlugins();
  if (switched) loadPending();   // 挂起确认队列跨重启恢复（见 §14 边界 3）
  return { ok: true };
}

function sessFile(sid) { return path.join(DATA_DIR, 'agent-sessions', sid + '.jsonl'); }
function indexFile() { return path.join(DATA_DIR, 'agent-sessions', 'index.json'); }
function auditFile() { return path.join(DATA_DIR, 'agent-audit.jsonl'); }
function confirmsFile() { return path.join(DATA_DIR, 'agent-confirms.json'); }
function artifactDir() { return path.join(DATA_DIR, 'agent-artifacts'); }
function artifactFile(id) { return path.join(artifactDir(), id + '.txt'); }

function appendJsonl(f, obj) {
  try { fs.appendFileSync(f, JSON.stringify(obj) + '\n', 'utf8'); } catch (_) {}
}

// ── 产物文本（大 diff / 大日志的落地与回取） ────────────────────────────────
// id 只允许 [A-Za-z0-9_]，写入与读取都走这一步 —— 否则「回取」就是个目录穿越洞。
function safeArtifactId(id) {
  const s = String(id || '');
  return /^[A-Za-z0-9_]{1,80}$/.test(s) ? s : '';
}

/** 落盘产物全文，返回 id。失败也返回 id（读回时给 null，不会假装成功）。 */
function putArtifactText(text) {
  _artSeq += 1;
  const id = 'art_' + Date.now().toString(36) + '_' + _artSeq.toString(36).padStart(4, '0');
  try {
    fs.mkdirSync(artifactDir(), { recursive: true });
    fs.writeFileSync(artifactFile(id), String(text), 'utf8');
  } catch (_) {}
  return id;
}

/** 按 id 取回全文；id 非法或不存在一律返回 null（调用方据此给 404）。 */
function getArtifactText(id) {
  const s = safeArtifactId(id);
  if (!s) return null;
  try { return fs.readFileSync(artifactFile(s), 'utf8'); } catch (_) { return null; }
}

/** 把 `server://artifacts/<id>` 或裸 id 归一成 id，取不出就返回 ''。 */
function artifactIdOf(ref) {
  const raw = String(ref || '').trim();
  if (!raw) return '';
  const m = raw.match(/^server:\/\/artifacts\/(.+)$/);
  return safeArtifactId(m ? m[1] : raw);
}

/**
 * artifact 载荷规范化（服务端权威，只在 appendEvent 里调一次）：
 *   · 无 text        → 原样返回（uri-only 的老形态继续可用，向后兼容）
 *   · 小 text        → 内联，textTruncated=false，补 bytes
 *   · 大 text        → 落盘全文，内联前 N 行预览，textTruncated=true + storedId/uri 指向全文
 * bytes 恒为**全文**字节数，客户端因此能显示「共多少」而不是「看到多少」。
 */
function normalizeArtifactPayload(payload) {
  const out = Object.assign({}, payload || {});
  const text = typeof out.text === 'string' ? out.text : '';
  if (!text) return out;
  out.bytes = Buffer.byteLength(text, 'utf8');
  const lineCount = text.split(/\r?\n/).length;
  if (lineCount <= ARTIFACT_INLINE_MAX_LINES && text.length <= ARTIFACT_INLINE_MAX_CHARS) {
    out.textTruncated = false;
    return out;
  }
  const id = putArtifactText(text);
  out.storedId = id;
  if (!out.uri) out.uri = 'server://artifacts/' + id;
  out.text = text.split(/\r?\n/).slice(0, ARTIFACT_PREVIEW_LINES).join('\n');
  out.textTruncated = true;
  return out;
}

// ── 会话 ────────────────────────────────────────────────────────────────────
function loadIndex() { return readJsonSafe(indexFile(), { version: 1, sessions: [] }); }

function saveIndex(idx) {
  try { fs.writeFileSync(indexFile(), JSON.stringify(idx, null, 2), 'utf8'); } catch (_) {}
}

function createSession(opts = {}) {
  const sid = opts.id || nextSessionId();
  const meta = {
    id: sid,
    title: String(opts.title || '新任务').slice(0, 120),
    userId: String(opts.userId || 'user_or_anon'),
    profile: opts.profile || 'default',
    createdAt: Date.now(),
    updatedAt: Date.now(),
    mode: DSH_STATE.mode,
    eventCount: 0,
    tokens: 0,
    cost: 0,
    status: 'open',
  };
  SESS.set(sid, { meta, events: [], seq: 0 });
  try { fs.writeFileSync(sessFile(sid), '', 'utf8'); } catch (_) {}
  const idx = loadIndex();
  idx.sessions.unshift({ ...meta });
  if (idx.sessions.length > 200) idx.sessions.length = 200;
  saveIndex(idx);
  appendEvent(sid, 'done', { taskStatus: 'created', note: '会话已建立' }, { silent: true });
  return meta;
}

function listSessions(limit = 50) {
  return loadIndex().sessions.slice(0, limit);
}

function getSession(sid) {
  if (SESS.has(sid)) return SESS.get(sid).meta;
  return loadIndex().sessions.find((s) => s.id === sid) || null;
}

/** 惰性装载某个会话的事件流（重启后仍可读历史） */
function ensureLoaded(sid) {
  if (SESS.has(sid)) return SESS.get(sid);
  const meta = loadIndex().sessions.find((s) => s.id === sid);
  if (!meta) return null;
  const rec = { meta: { ...meta }, events: [], seq: 0 };
  try {
    const txt = fs.readFileSync(sessFile(sid), 'utf8');
    for (const line of txt.split('\n')) {
      if (!line.trim()) continue;
      try {
        const e = JSON.parse(line);
        rec.events.push(e);
        if (typeof e.seq === 'number' && e.seq > rec.seq) rec.seq = e.seq;
      } catch (_) {}
    }
  } catch (_) {}
  SESS.set(sid, rec);
  return rec;
}

/** 追加一个事件（append-only）—— 全协议唯一的写入原语 */
function appendEvent(sid, type, payload = {}, opts = {}) {
  if (!EVENT_TYPES.includes(type)) throw new Error('未知事件类型: ' + type);
  const rec = ensureLoaded(sid);
  if (!rec) throw new Error('会话不存在: ' + sid);
  rec.seq += 1;
  // 规范化只发生在这一个写入原语里 —— 事件日志里存下来的永远是规范形态，
  // 所以回读历史事件不需要再判一次（两端对同一份 JSON 的解析结论必然一致）。
  const norm = type === 'artifact' ? normalizeArtifactPayload(payload) : (payload || {});
  const evt = {
    id: nextEventId(),
    sessionId: sid,
    seq: rec.seq,
    ts: Date.now(),
    type,
    payload: norm,
  };
  rec.events.push(evt);
  appendJsonl(sessFile(sid), evt);

  // 同步更新会话索引里的轻量字段（事件数 / 时间 / 状态）
  const idx = loadIndex();
  const m = idx.sessions.find((s) => s.id === sid);
  if (m) {
    m.eventCount = rec.events.length;
    m.updatedAt = evt.ts;
    if (type === 'done') {
      m.status = 'done';
      if (typeof payload.tokens === 'number') m.tokens = payload.tokens;
      if (typeof payload.cost === 'number') m.cost = payload.cost;
    }
    if (type === 'user_message' && m.title === '新任务' && payload.text) {
      m.title = String(payload.text).slice(0, 40);
    }
    saveIndex(idx);
  }
  rec.meta = m ? { ...m } : rec.meta;
  if (!opts.silent) auditFromEvent(evt);
  return evt;
}

function events(sid, opts = {}) {
  const rec = ensureLoaded(sid);
  if (!rec) return null;
  const since = Number(opts.since || 0);
  const limit = Math.min(Number(opts.limit || 500), 2000);
  const list = rec.events.filter((e) => e.seq > since).slice(0, limit);
  return { events: list, lastSeq: rec.seq, total: rec.events.length, mode: DSH_STATE.mode };
}

// ── 策略判定（服务端权威） ──────────────────────────────────────────────────
function riskOf(tool) {
  const P = loadProfiles();
  const t = String(tool || '');
  for (const [name, def] of Object.entries(P.risk || {})) {
    if ((def.tools || []).includes(t)) return name;
  }
  // 名字兜底：没登记的工具按高危处理（白名单制的必然推论）
  return 'danger';
}

function profileOf(id) {
  const P = loadProfiles();
  const key = String(id || '');
  const hit = (P.profiles || {})[key];
  // 刻意**不**回落到 default：档位名写错必须判 deny，不能静默放宽权限。
  return hit || null;
}

/**
 * 判定某个 profile 下能不能调某个工具。
 * 顺序：denyTools → 风险等级是否被 allowRisk 覆盖 → confirmTools → allow
 * 未登记的工具（risk=danger）必须被 profile 显式 allowRisk 覆盖才可能通过。
 */
function decide(profileId, tool) {
  const prof = profileOf(profileId);
  const t = String(tool || '');
  if (!prof) return { decision: 'deny', risk: riskOf(t), reason: '未知 profile: ' + profileId };

  const allowTools = prof.allowTools || [];
  const confirmTools = prof.confirmTools || [];
  const denyTools = prof.denyTools || [];
  const allowRisk = prof.allowRisk || [];

  if (denyTools.includes(t) || denyTools.includes('*')) {
    return { decision: 'deny', risk: riskOf(t), reason: 'profile「' + prof.label + '」显式禁用该工具' };
  }

  const risk = riskOf(t);
  const coverage = allowRisk.includes(risk) || allowTools.includes('*');

  // 没被风险等级覆盖，也没被 allowTools 显式点名 → 拒绝
  if (!coverage && !allowTools.includes(t)) {
    return {
      decision: 'deny', risk,
      reason: risk === 'danger'
        ? '高危工具默认禁用；需切换更高档位并逐次确认'
        : 'profile「' + prof.label + '」未授权该工具',
    };
  }

  if (confirmTools.includes(t)) {
    return { decision: 'confirm', risk, reason: '该工具会改动数据，需要一次明确确认' };
  }
  if (prof.denyFullAccess && risk === 'danger') {
    return { decision: 'confirm', risk, reason: '高危工具需逐次确认' };
  }
  return { decision: 'allow', risk, reason: 'profile「' + prof.label + '」已授权' };
}

// ── 确认队列 ────────────────────────────────────────────────────────────────
// 跨重启：挂起队列落盘。重启后未答复的确认仍能被答复、且挂起数不为 0 ——
// 否则「事件流完整、但确认全部消失」会让用户以为系统悄悄放行了高危操作。
function savePending() {
  try {
    const items = [];
    for (const [cid, p] of PENDING.entries()) items.push(Object.assign({ confirmId: cid }, p));
    fs.writeFileSync(confirmsFile(), JSON.stringify({ version: 1, items }, null, 2), 'utf8');
  } catch (_) {}
}

function loadPending() {
  const j = readJsonSafe(confirmsFile(), { version: 1, items: [] });
  PENDING.clear();
  for (const it of (j.items || [])) {
    if (!it || !it.confirmId) continue;
    const p = Object.assign({}, it);
    delete p.confirmId;
    PENDING.set(String(it.confirmId), p);
  }
  return PENDING.size;
}

function requestConfirm(sid, { tool, args, reason }) {
  const rec = ensureLoaded(sid);
  if (!rec) throw new Error('会话不存在: ' + sid);
  const d = decide(rec.meta.profile, tool);
  if (d.decision === 'deny') {
    appendEvent(sid, 'error', { code: 'TOOL_DENIED', message: d.reason, tool });
    // 被拒也必须留痕：审计里「没记录」和「记录了 allow」是两码事
    audit({
      sessionId: sid, userId: rec.meta.userId, profile: rec.meta.profile,
      tool, argsDigest: digestOf(args), decision: 'deny', result: 'blocked', note: d.reason,
    });
    return { ok: false, decision: 'deny', reason: d.reason };
  }
  const argsDigest = digestOf(args);
  const evt = appendEvent(sid, 'confirm_request', { tool, args, argsDigest, risk: d.risk, reason: reason || d.reason });
  PENDING.set(evt.id, { sid, tool, args, risk: d.risk, at: evt.ts, argsDigest });
  savePending();
  return { ok: true, confirmId: evt.id, decision: 'confirm', risk: d.risk };
}

function pendingConfirms(sid) {
  const out = [];
  for (const [cid, p] of PENDING.entries()) {
    if (sid && p.sid !== sid) continue;
    out.push({ confirmId: cid, ...p });
  }
  return out.sort((a, b) => a.at - b.at);
}

function resolveConfirm(confirmId, allow, by = 'user') {
  const p = PENDING.get(confirmId);
  if (!p) return { ok: false, error: '确认项不存在或已被处理' };
  const evt = appendEvent(p.sid, 'confirm_result', {
    confirmId, tool: p.tool, allow: !!allow, by, argsDigest: p.argsDigest,
  });
  PENDING.delete(confirmId);
  savePending();
  return { ok: true, allow: !!allow, eventId: evt.id };
}

// ── 审计 ────────────────────────────────────────────────────────────────────
function digestOf(args) {
  try {
    const crypto = require('crypto');
    return 'sha256:' + crypto.createHash('sha256')
      .update(typeof args === 'string' ? args : JSON.stringify(args || {})).digest('hex').slice(0, 32);
  } catch (_) { return 'sha256:unavailable'; }
}

function audit(rec) {
  const row = {
    ts: Date.now(),
    sessionId: rec.sessionId || '',
    userId: rec.userId || 'user_or_anon',
    profile: rec.profile || 'default',
    tool: rec.tool || '',
    argsDigest: rec.argsDigest || '',
    decision: DECISIONS.includes(rec.decision) ? rec.decision : 'allow',
    result: rec.result || '',
    plugin: rec.plugin || '',
    mcpServer: rec.mcpServer || '',
    note: rec.note || '',
  };
  appendJsonl(auditFile(), row);
  return row;
}

/** 关键事件自动落审计：工具调用 / 确认 / 权限判定 */
function auditFromEvent(evt) {
  const p = evt.payload || {};
  if (evt.type === 'tool_call') {
    const d = decide('default', p.tool);
    audit({ sessionId: evt.sessionId, tool: p.tool, argsDigest: digestOf(p.arguments), decision: d.decision, result: 'invoked', note: 'tool_call' });
  } else if (evt.type === 'confirm_result') {
    audit({ sessionId: evt.sessionId, tool: p.tool, argsDigest: p.argsDigest, decision: p.allow ? 'allow' : 'deny', result: 'confirmed', note: 'by=' + (p.by || 'user') });
  } else if (evt.type === 'confirm_request') {
    audit({ sessionId: evt.sessionId, tool: p.tool, argsDigest: p.argsDigest, decision: 'confirm', result: 'pending', note: 'risk=' + (p.risk || '') });
  }
}

function listAudit(opts = {}) {
  const limit = Math.min(Number(opts.limit || 200), 2000);
  const out = [];
  try {
    const lines = fs.readFileSync(auditFile(), 'utf8').split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      const l = lines[i];
      if (!l.trim()) continue;
      let row; try { row = JSON.parse(l); } catch (_) { continue; }
      if (opts.sessionId && row.sessionId !== opts.sessionId) continue;
      out.push(row);
      if (out.length >= limit) break;
    }
  } catch (_) {}
  return out;
}

// ── DSH 生命周期 ────────────────────────────────────────────────────────────
function dshConfigFile() { return path.join(DATA_DIR, 'agent-dsh.json'); }

function detect() {
  const cfg = readJsonSafe(dshConfigFile(), {});
  const url = String(process.env.TH_DSH_URL || cfg.url || '').trim();
  if (url) return { kind: 'http', target: url };
  const cmd = String(process.env.TH_DSH_CMD || cfg.cmd || '').trim();
  if (cmd) return { kind: 'spawn', target: cmd };
  // 退而求其次：PATH 上有没有 dsh
  try {
    const finder = process.platform === 'win32' ? 'where' : 'which';
    const out = execFileSync(finder, ['dsh'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 4000 });
    const first = out.split(/\r?\n/).map((s) => s.trim()).filter(Boolean)[0];
    if (first) return { kind: 'spawn', target: first };
  } catch (_) { /* 没装就是没装，这不是错误 */ }
  return { kind: 'none', target: '' };
}

/** 探活：HTTP 探测 /health；spawn 类型探测进程是否还在 */
async function probe(timeoutMs = 2500) {
  const d = detect();
  DSH_STATE.kind = d.kind;
  DSH_STATE.target = d.target;
  DSH_STATE.lastProbe = Date.now();

  if (d.kind === 'http') {
    const base = d.target.replace(/\/+$/, '');
    for (const ep of ['/health', '/v1/health']) {
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const r = await fetch(base + ep, { signal: ctl.signal });
        if (r.ok) {
          let j = {}; try { j = await r.json(); } catch (_) {}
          DSH_STATE = { ...DSH_STATE, mode: MODES.FULL, version: j.version || j.tag || '', error: '' };
          return status();
        }
      } catch (e) { DSH_STATE.error = String((e && e.message) || e); }
      finally { clearTimeout(t); }
    }
    DSH_STATE = { ...DSH_STATE, mode: MODES.FALLBACK, error: DSH_STATE.error || 'DSH HTTP 端点无响应' };
    return status();
  }

  if (d.kind === 'spawn' && DSH_STATE.proc && !DSH_STATE.proc.killed) {
    DSH_STATE = { ...DSH_STATE, mode: MODES.FULL, error: '' };
    return status();
  }

  DSH_STATE = {
    ...DSH_STATE, mode: MODES.FALLBACK, version: '',
    error: d.kind === 'none' ? '本机未安装 DSH（属正常：会自动降级为轻量 Agent）' : 'DSH 进程未运行',
  };
  return status();
}

function start() {
  const d = detect();
  if (d.kind !== 'spawn') {
    return { ok: false, error: d.kind === 'none' ? '未找到 DSH 可执行文件' : 'DSH 以 HTTP 方式配置，无需本进程启动' };
  }
  if (DSH_STATE.proc && !DSH_STATE.proc.killed) return { ok: true, already: true, pid: DSH_STATE.proc.pid };
  try {
    const parts = d.target.split(/\s+/);
    const p = spawn(parts[0], parts.slice(1), { stdio: ['ignore', 'pipe', 'pipe'], shell: false });
    DSH_STATE.proc = p;
    DSH_STATE.mode = MODES.FULL;
    DSH_STATE.error = '';
    p.on('exit', () => { DSH_STATE.proc = null; DSH_STATE.mode = MODES.FALLBACK; DSH_STATE.error = 'DSH 进程已退出'; });
    return { ok: true, pid: p.pid };
  } catch (e) {
    DSH_STATE.error = String((e && e.message) || e);
    return { ok: false, error: DSH_STATE.error };
  }
}

function stop() {
  if (DSH_STATE.proc && !DSH_STATE.proc.killed) {
    try { DSH_STATE.proc.kill(); } catch (_) {}
    DSH_STATE.proc = null;
  }
  DSH_STATE.mode = MODES.FALLBACK;
  return { ok: true };
}

function status() {
  const P = loadProfiles();
  const G = loadPlugins();
  // 降级原因必须永远可读：客户端只有拿到原因才能给用户一句人话，
  // 而不是干巴巴一个「不可用」。首次调用（还没 probe 过）也要有值。
  const reason = DSH_STATE.error || (DSH_STATE.mode === MODES.FALLBACK
    ? (DSH_STATE.kind === 'none'
      ? '本机未安装 DSH（属正常：会自动降级为轻量 Agent）'
      : 'DSH 未运行（可调用 /agent/dsh/start 启动）')
    : '');
  return {
    ok: true,
    mode: DSH_STATE.mode,
    fullAgentAvailable: DSH_STATE.mode === MODES.FULL,
    dsh: {
      detected: DSH_STATE.kind !== 'none',
      kind: DSH_STATE.kind,
      target: DSH_STATE.target,
      version: DSH_STATE.version,
      running: !!(DSH_STATE.proc && !DSH_STATE.proc.killed),
      pid: DSH_STATE.proc ? DSH_STATE.proc.pid : 0,
      lastProbe: DSH_STATE.lastProbe,
      error: reason,
    },
    capabilities: {
      eventLog: true,
      policy: true,
      confirmQueue: true,
      audit: true,
      mcpRegistry: true,
      nativePlugins: DSH_STATE.mode === MODES.FULL,
      sandbox: DSH_STATE.mode === MODES.FULL,
    },
    profiles: Object.entries(P.profiles || {}).map(([id, v]) => ({
      id, label: v.label, desc: v.desc, visibleToUser: v.visibleToUser !== false, denyFullAccess: !!v.denyFullAccess,
    })),
    plugins: (G.plugins || []).filter((x) => x.enabled).map((x) => ({ id: x.id, name: x.name, version: x.version, license: x.license, builtin: !!x.builtin })),
    platform: process.platform,
    host: os.hostname(),
    at: Date.now(),
    protocolVersion: 'THA/1',
  };
}

/** 面向 Flutter 的工具清单：把 profile 判定结果一并回传，前端不必自己算 */
function toolCatalog(profileId) {
  const P = loadProfiles();
  const out = [];
  for (const [riskName, def] of Object.entries(P.risk || {})) {
    for (const t of (def.tools || [])) {
      const d = decide(profileId, t);
      out.push({ name: t, risk: riskName, riskLabel: def.label, decision: d.decision, reason: d.reason });
    }
  }
  return out;
}

function snapshot() {
  return {
    mode: DSH_STATE.mode,
    sessions: SESS.size,
    pending: PENDING.size,
    profiles: Object.keys((loadProfiles().profiles) || {}),
    pendingIds: [...PENDING.keys()],
  };
}

function resetForTest() {
  SESS.clear(); PENDING.clear(); _seq = 0; _artSeq = 0;
  DSH_STATE = { mode: MODES.FALLBACK, kind: 'none', target: '', version: '', lastProbe: 0, error: '', proc: null };
  // DATA_DIR 一并清空，好让下一次 init(同一目录) 被判定成「切换目录」并重新载入队列 ——
  // 测试正是靠这一步模拟「进程重启后从盘上恢复挂起确认」。
  // 刻意**不写盘**：写完就把要验证的队列抹掉了。测试间隔离靠各自独立的 DATA_DIR。
  DATA_DIR = '';
}

module.exports = {
  init, status, start, stop, detect, probe,
  createSession, listSessions, getSession, appendEvent, events,
  decide, riskOf, profileOf, requestConfirm, pendingConfirms, resolveConfirm,
  audit, listAudit, toolCatalog, snapshot, resetForTest,
  putArtifactText, getArtifactText, artifactIdOf, normalizeArtifactPayload, loadPending,
  EVENT_TYPES, MODES, digestOf,
  ARTIFACT_INLINE_MAX_LINES, ARTIFACT_INLINE_MAX_CHARS, ARTIFACT_PREVIEW_LINES,
  get DSH_STATE() { return DSH_STATE; },
};
