// ═══════════════════════════════════════════════════════════════════════════
// ThirdHub v4 · Agent MCP 注册表（服务端侧）
//
// 设计约束（见 docs/AGENT-PROTOCOL.md §7）：
//   · Flutter 端**不跑 stdio MCP**，也不直连 MCP server；
//     所有 MCP 连接与工具调用统一由 server/DSH 这一侧完成。
//   · Flutter 只做「展示 + 开关」，即本注册表的读写方。
//
// 传输：Streamable HTTP / SSE（与网站 mcp-client.js、Flutter 旧实现一致）。
// 存储：<DATA>/agent-mcp.json
// ═══════════════════════════════════════════════════════════════════════════
const fs = require('fs');
const path = require('path');

let REG = null;   // 内存缓存
let DATA_DIR = '';

function init(dataDir) {
  DATA_DIR = dataDir;
  try { fs.mkdirSync(DATA_DIR, { recursive: true }); } catch (_) {}
  REG = read();
  return REG;
}

function file() { return path.join(DATA_DIR, 'agent-mcp.json'); }

function read() {
  try {
    const j = JSON.parse(fs.readFileSync(file(), 'utf8'));
    if (j && Array.isArray(j.servers)) return j;
  } catch (_) {}
  return { version: 1, servers: [] };
}

function write() {
  try { fs.writeFileSync(file(), JSON.stringify(REG, null, 2), 'utf8'); } catch (_) {}
}

function list() {
  if (!REG) init(DATA_DIR || '.');
  return REG.servers.map((s) => ({
    id: s.id, name: s.name, url: s.url, enabled: !!s.enabled, status: s.status || 'idle',
    error: s.error || '', tools: s.tools || [], transport: s.transport || 'auto',
    addedAt: s.addedAt, lastChecked: s.lastChecked || 0,
    argsSchema: s.argsSchema || {},
  }));
}

function nextId() {
  let n = 1;
  const used = new Set(REG.servers.map((s) => s.id));
  while (used.has('mcp' + n)) n++;
  return 'mcp' + n;
}

function add(name, url, opts = {}) {
  if (!REG) init(DATA_DIR || '.');
  const u = String(url || '').trim();
  if (!/^https?:\/\//i.test(u)) throw new Error('服务地址必须是 http(s):// 开头');
  const dup = REG.servers.find((s) => s.url === u);
  if (dup) throw new Error('该地址已存在（id=' + dup.id + '）');
  const rec = {
    id: nextId(),
    name: String(name || '').trim() || '未命名 MCP 服务',
    url: u,
    enabled: opts.enabled !== false,
    transport: opts.transport || 'auto',
    tools: [],
    argsSchema: {},
    status: 'idle',
    error: '',
    addedAt: Date.now(),
    lastChecked: 0,
  };
  REG.servers.push(rec);
  write();
  return rec.id;
}

function remove(id) {
  if (!REG) init(DATA_DIR || '.');
  const i = REG.servers.findIndex((s) => s.id === id);
  if (i < 0) return false;
  REG.servers.splice(i, 1);
  write();
  return true;
}

function toggle(id, enabled) {
  if (!REG) init(DATA_DIR || '.');
  const s = REG.servers.find((x) => x.id === id);
  if (!s) return false;
  s.enabled = !!enabled;
  if (!s.enabled) { s.status = 'disabled'; s.error = ''; }
  write();
  return true;
}

// ── JSON-RPC over Streamable HTTP（与前端 ai.dart 的 Mcp._rpc 同协议） ──
async function rpc(url, method, params, timeoutMs = 12000) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params: params || {} }),
      signal: ctl.signal,
    });
    const text = await r.text();
    if (!r.ok) throw new Error('HTTP ' + r.status);
    // 兼容 SSE 响应：取 data: 行里的 JSON
    const payload = text.trim().startsWith('data:')
      ? text.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).join('')
      : text;
    const j = JSON.parse(payload);
    if (j.error) throw new Error(j.error.message || 'MCP error');
    return j.result || {};
  } finally { clearTimeout(t); }
}

async function connect(id) {
  if (!REG) init(DATA_DIR || '.');
  const s = REG.servers.find((x) => x.id === id);
  if (!s) return { ok: false, error: '未找到该 MCP 服务' };
  s.status = 'connecting'; s.error = '';
  try {
    const initRes = await rpc(s.url, 'initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'ThirdHub-v4', version: '4.45.0' },
    });
    const toolsRes = await rpc(s.url, 'tools/list', {});
    s.tools = (toolsRes.tools || []).map((t) => ({
      name: t.name,
      description: t.description || '',
      inputSchema: t.inputSchema || { type: 'object', properties: {} },
    }));
    s.argsSchema = {};
    for (const t of s.tools) s.argsSchema[t.name] = t.inputSchema;
    s.status = 'connected';
    s.lastChecked = Date.now();
    s.protocolVersion = initRes.protocolVersion || '';
    write();
    return { ok: true, tools: s.tools.length, protocolVersion: s.protocolVersion };
  } catch (e) {
    s.status = 'error';
    s.error = String((e && e.message) || e);
    s.tools = [];
    s.lastChecked = Date.now();
    write();
    return { ok: false, error: s.error };
  }
}

/** 已连接且启用的 MCP 工具，摊平成 Flutter 侧工具表格式（serverId 用 mcp:<id>）。 */
function allTools() {
  if (!REG) init(DATA_DIR || '.');
  const out = [];
  for (const s of REG.servers) {
    if (!s.enabled || s.status !== 'connected') continue;
    for (const t of (s.tools || [])) {
      out.push({
        serverId: 'mcp:' + s.id,
        serverName: s.name,
        name: t.name,
        description: t.description || '',
        inputSchema: t.inputSchema || { type: 'object', properties: {} },
      });
    }
  }
  return out;
}

async function callTool(serverRef, toolName, args) {
  if (!REG) init(DATA_DIR || '.');
  const id = String(serverRef || '').replace(/^mcp:/, '');
  const s = REG.servers.find((x) => x.id === id);
  if (!s) throw new Error('未注册的 MCP 服务: ' + serverRef);
  if (!s.enabled) throw new Error('该 MCP 服务已禁用: ' + s.name);
  const res = await rpc(s.url, 'tools/call', { name: toolName, arguments: args || {} });
  const parts = [];
  for (const c of (res.content || [])) {
    if (c && c.type === 'text') parts.push(String(c.text || ''));
    else parts.push(JSON.stringify(c));
  }
  return { text: parts.join('\n') || '(空结果)', isError: !!res.isError };
}

function snapshot() { if (!REG) init(DATA_DIR || '.'); return JSON.parse(JSON.stringify(REG)); }
function resetForTest() { REG = { version: 1, servers: [] }; }

module.exports = { init, list, add, remove, toggle, connect, allTools, callTool, snapshot, resetForTest, rpc };
