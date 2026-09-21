// ThirdHub v4 · Agent 路由（/agent/*）
// 从 index.js 拆出（2026-09 模块化），与 routes-data.js 同约定：
// 命中路由后 send() 会 end 响应，主路由以 res.writableEnded 判定「已处理」；
// 未命中的一律 return false 交回主路由。
//
// 协议见 docs/AGENT-PROTOCOL.md。响应信封沿用后端 /v1 家族：
//   { object: 'list' | 'meta' | 'error', data }
const agent = require('./agent-dsh');
const mcp = require('./mcp-registry');

function parse(body) { try { return JSON.parse(body || '{}') || {}; } catch (_) { return {}; } }

/** 行数：`"a\nb\n"` 是 2 行不是 3 行（末尾换行不额外算一行），空文本 0 行 */
function countLines(t) {
  if (!t) return 0;
  const n = String(t).split(/\r?\n/).length;
  return /[\r\n]$/.test(t) ? n - 1 : n;
}

// ── SSE 分发器 ──────────────────────────────────────────────────────────────
// 之前每个连接各自 setInterval：会话一多，定时器与「查一次 events」的次数线性增长。
// 改成全局单定时器 + 按会话分组：**同一会话有 N 个连接也只查一次**，查到的事件再
// 按各自 since 分发给 N 个连接。连接数只影响「写给谁」，不影响「查几次」。
const SSE_TICK_MS = 700;
const SSE_MAX_MS = 600000;
const SSE_SINKS = new Map();   // sid -> Set<{res, since, closed, timer}>
let SSE_TIMER = null;

function sseRemove(sid, sink) {
  const set = SSE_SINKS.get(sid);
  if (set) {
    set.delete(sink);
    if (!set.size) SSE_SINKS.delete(sid);
  }
  if (sink && sink.timer) { clearTimeout(sink.timer); sink.timer = null; }
  // 无人订阅就把定时器也停掉 —— 空闲后端不该一直醒着
  if (!SSE_SINKS.size && SSE_TIMER) { clearInterval(SSE_TIMER); SSE_TIMER = null; }
}

function sseClose(sid, sink, lastSeq) {
  try {
    sink.res.write(`event: close\ndata: ${JSON.stringify({ sessionId: sid, lastSeq: lastSeq == null ? sink.since : lastSeq })}\n\n`);
    sink.res.end();
  } catch (_) {}
  sink.closed = true;
  sseRemove(sid, sink);
}

function sseAdd(sid, sink) {
  let set = SSE_SINKS.get(sid);
  if (!set) { set = new Set(); SSE_SINKS.set(sid, set); }
  set.add(sink);
  if (!SSE_TIMER) {
    SSE_TIMER = setInterval(sseTick, SSE_TICK_MS);
    if (SSE_TIMER.unref) SSE_TIMER.unref();   // 不拖住进程退出
  }
}

function sseTick() {
  for (const [sid, set] of Array.from(SSE_SINKS.entries())) {
    const sinks = Array.from(set);
    if (!sinks.length) { SSE_SINKS.delete(sid); continue; }
    // 本会话只需查一次：从所有连接里最小的 since 起查，再按各自进度分发
    const minSince = sinks.reduce((m, s) => (s.since < m ? s.since : m), sinks[0].since);
    let r = null;
    try { r = agent.events(sid, { since: minSince, limit: 500 }); } catch (_) { r = null; }
    if (!r) {                       // 会话没了（被清理）→ 收尾，不留悬挂连接
      for (const s of sinks) sseClose(sid, s, null);
      continue;
    }
    for (const sink of sinks) {
      if (sink.closed) { sseRemove(sid, sink); continue; }
      const fresh = r.events.filter((e) => e.seq > sink.since);
      if (!fresh.length) {
        try { sink.res.write(': ping\n\n'); } catch (_) { sseRemove(sid, sink); }
        continue;
      }
      let done = false;
      try {
        for (const e of fresh) {
          sink.res.write(`id: ${e.seq}\nevent: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
          sink.since = e.seq;
          // 本轮结束 → 主动收尾，客户端不必自己猜
          if (e.type === 'done') done = true;
        }
      } catch (_) { sseRemove(sid, sink); continue; }
      if (done) sseClose(sid, sink, sink.since);
    }
  }
}

async function handle(req, res, body, u, p, send, ctx) {
  if (!p.startsWith('/agent')) return false;
  const DATA = (ctx && ctx.DATA) || '.';
  agent.init(DATA);
  mcp.init(DATA);
  const q = u.searchParams;
  const method = req.method;

  // ── 运行模式与能力 —— Flutter 靠这个决定走完整 Agent 还是降级 ──
  if (p === '/agent/health') {
    const deep = q.get('probe') === '1';
    const st = deep ? await agent.probe() : agent.status();
    return send(200, { object: 'meta', data: st });
  }

  if (p === '/agent/dsh/start' && method === 'POST') {
    const r = agent.start();
    return send(r.ok ? 200 : 400, { object: r.ok ? 'meta' : 'error', data: r.ok ? r : { type: 'dsh_start_failed', message: r.error } });
  }
  if (p === '/agent/dsh/stop' && method === 'POST') {
    return send(200, { object: 'meta', data: agent.stop() });
  }

  // ── 会话 ──
  if (p === '/agent/sessions' && method === 'GET') {
    return send(200, { object: 'list', data: agent.listSessions(Number(q.get('limit') || 50)) });
  }
  if (p === '/agent/session' && method === 'POST') {
    const d = parse(body);
    // 档位名必须显式合法：写错时直接拒绝，不能让它在后面被静默当成 default
    if (d.profile) {
      const ids = agent.status().profiles.map((x) => x.id);
      if (!ids.includes(String(d.profile))) {
        return send(400, {
          object: 'error',
          data: { type: 'invalid_request', message: '未知的权限档位: ' + d.profile + '（可选 ' + ids.join(' / ') + '）' },
        });
      }
    }
    const meta = agent.createSession({
      title: d.title, userId: d.userId, profile: d.profile, id: d.id,
    });
    return send(200, { object: 'meta', data: meta });
  }
  if (p.startsWith('/agent/session/') && method === 'GET') {
    const sid = decodeURIComponent(p.slice('/agent/session/'.length));
    const m = agent.getSession(sid);
    if (!m) return send(404, { object: 'error', data: { type: 'not_found', message: '会话不存在' } });
    return send(200, { object: 'meta', data: m });
  }

  // ── 事件流（append-only） ──
  if (p === '/agent/events' && method === 'GET') {
    const sid = q.get('sessionId') || '';
    if (!sid) return send(400, { object: 'error', data: { type: 'invalid_request', message: '需 sessionId' } });
    const r = agent.events(sid, { since: q.get('since'), limit: q.get('limit') });
    if (!r) return send(404, { object: 'error', data: { type: 'not_found', message: '会话不存在' } });
    return send(200, { object: 'list', data: r.events, meta: { lastSeq: r.lastSeq, total: r.total, mode: r.mode } });
  }

  // SSE 增量推送：长任务/断线重连用。客户端带 since= 续传，不重不漏。
  if (p === '/agent/events/stream' && method === 'GET') {
    const sid = q.get('sessionId') || '';
    if (!sid) return send(400, { object: 'error', data: { type: 'invalid_request', message: '需 sessionId' } });
    if (!agent.getSession(sid)) return send(404, { object: 'error', data: { type: 'not_found', message: '会话不存在' } });

    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    const sink = { res, since: Number(q.get('since') || 0), closed: false, timer: null };
    const mode = agent.snapshot().mode;
    res.write(`event: hello\ndata: ${JSON.stringify({ sessionId: sid, mode, lastSeq: sink.since })}\n\n`);

    req.on('close', () => { sink.closed = true; sseRemove(sid, sink); });
    sseAdd(sid, sink);
    // 兜底：SSE 最长挂 10 分钟，避免连接泄漏
    sink.timer = setTimeout(() => { try { res.end(); } catch (_) {} sink.closed = true; sseRemove(sid, sink); }, SSE_MAX_MS);
    if (sink.timer.unref) sink.timer.unref();
    return true;
  }

  // 客户端上报事件（fallback 模式下 Flutter 自己跑循环，把过程写回服务端事件流，
  // 这样「有没有 server」两种模式下都能看到同一份可溯源记录）
  if (p === '/agent/event' && method === 'POST') {
    const d = parse(body);
    if (!d.sessionId || !d.type) {
      return send(400, { object: 'error', data: { type: 'invalid_request', message: '需 sessionId/type' } });
    }
    try {
      const e = agent.appendEvent(d.sessionId, d.type, d.payload || {});
      return send(200, { object: 'meta', data: e });
    } catch (err) {
      return send(400, { object: 'error', data: { type: 'invalid_event', message: String(err.message || err) } });
    }
  }

  // ── 一轮对话入口：服务端只负责「事件落账 + 模式判定」，模型循环由 DSH 或 Flutter 跑 ──
  if (p === '/agent/send' && method === 'POST') {
    const d = parse(body);
    const sid = d.sessionId || '';
    if (!sid) return send(400, { object: 'error', data: { type: 'invalid_request', message: '需 sessionId' } });
    if (!agent.getSession(sid)) return send(404, { object: 'error', data: { type: 'not_found', message: '会话不存在' } });
    const evt = agent.appendEvent(sid, 'user_message', {
      text: String(d.text || ''),
      contextRefs: Array.isArray(d.contextRefs) ? d.contextRefs : [],
    });
    const st = agent.status();
    return send(200, {
      object: 'meta',
      data: {
        event: evt,
        mode: st.mode,
        fullAgentAvailable: st.fullAgentAvailable,
        hint: st.fullAgentAvailable
          ? '完整 Agent 可用：事件由 DSH 产出，请订阅 /agent/events/stream'
          : '未接上 DSH：请在客户端用轻量 Agent 循环，并把过程事件回填 /agent/event',
      },
    });
  }

  // ── 确认队列（高危工具闸门） ──
  if (p === '/agent/confirm' && method === 'GET') {
    return send(200, { object: 'list', data: agent.pendingConfirms(q.get('sessionId') || '') });
  }
  if (p === '/agent/confirm' && method === 'POST') {
    const d = parse(body);
    // 两种用法：① 发起确认（给 sessionId+tool）② 答复确认（给 confirmId+allow）
    if (d.confirmId) {
      const r = agent.resolveConfirm(d.confirmId, d.allow === true, d.by || 'user');
      return send(r.ok ? 200 : 404, {
        object: r.ok ? 'meta' : 'error',
        data: r.ok ? r : { type: 'not_found', message: r.error },
      });
    }
    if (d.sessionId && d.tool) {
      try {
        const r = agent.requestConfirm(d.sessionId, { tool: d.tool, args: d.args, reason: d.reason });
        return send(r.ok ? 200 : 403, {
          object: r.ok ? 'meta' : 'error',
          data: r.ok ? r : { type: 'tool_denied', message: r.reason },
        });
      } catch (err) {
        return send(400, { object: 'error', data: { type: 'invalid_request', message: String(err.message || err) } });
      }
    }
    return send(400, { object: 'error', data: { type: 'invalid_request', message: '需 confirmId，或 sessionId+tool' } });
  }

  // ── 审计 ──
  if (p === '/agent/audit' && method === 'GET') {
    return send(200, {
      object: 'list',
      data: agent.listAudit({ limit: q.get('limit') || 200, sessionId: q.get('sessionId') || '' }),
    });
  }
  if (p === '/agent/audit' && method === 'POST') {
    const d = parse(body);
    return send(200, { object: 'meta', data: agent.audit(d) });
  }

  // ── 产物文本（大 diff / 大日志的落地与回取） ──
  // 事件里只放预览（textTruncated=true），全文在这里取；也支持 POST 直接存。
  if (p === '/agent/artifact' && method === 'GET') {
    const id = agent.artifactIdOf(q.get('id') || q.get('uri') || '');
    if (!id) {
      return send(400, { object: 'error', data: { type: 'invalid_request', message: '需 id，或 uri=server://artifacts/<id>' } });
    }
    const text = agent.getArtifactText(id);
    if (text == null) return send(404, { object: 'error', data: { type: 'not_found', message: '产物不存在: ' + id } });
    if (q.get('raw') === '1') {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(text);
      return true;
    }
    return send(200, {
      object: 'meta',
      data: {
        id, text, uri: 'server://artifacts/' + id,
        bytes: Buffer.byteLength(text, 'utf8'),
        lines: countLines(text),
      },
    });
  }
  if (p === '/agent/artifact' && method === 'POST') {
    const d = parse(body);
    const text = typeof d.text === 'string' ? d.text : '';
    if (!text) return send(400, { object: 'error', data: { type: 'invalid_request', message: '需 text' } });
    const id = agent.putArtifactText(text);
    return send(200, {
      object: 'meta',
      data: { id, uri: 'server://artifacts/' + id, bytes: Buffer.byteLength(text, 'utf8') },
    });
  }

  // ── 权限档位与工具目录（判定结果由服务端算好，前端只做展示与预判） ──
  if (p === '/agent/profiles' && method === 'GET') {
    const P = JSON.parse(require('fs').readFileSync(require('path').join(__dirname, 'agent-profiles.json'), 'utf8'));
    return send(200, { object: 'list', data: P.profiles, meta: { risk: P.risk } });
  }
  if (p === '/agent/tools' && method === 'GET') {
    const prof = q.get('profile') || 'default';
    return send(200, { object: 'list', data: agent.toolCatalog(prof), meta: { profile: prof } });
  }
  if (p === '/agent/plugins' && method === 'GET') {
    const G = JSON.parse(require('fs').readFileSync(require('path').join(__dirname, 'agent-plugins.json'), 'utf8'));
    return send(200, { object: 'list', data: G.plugins, meta: { policy: G.policy } });
  }

  // ── MCP 注册表（Flutter 只展示/开关，不在本地跑 stdio） ──
  if (p === '/agent/mcp' && method === 'GET') {
    return send(200, { object: 'list', data: mcp.list(), meta: { tools: mcp.allTools().length } });
  }
  if (p === '/agent/mcp' && method === 'POST') {
    const d = parse(body);
    try {
      const id = mcp.add(d.name, d.url, { transport: d.transport, enabled: d.enabled });
      return send(200, { object: 'meta', data: { id, added: true } });
    } catch (err) {
      return send(400, { object: 'error', data: { type: 'invalid_request', message: String(err.message || err) } });
    }
  }
  if (p === '/agent/mcp/toggle' && method === 'POST') {
    const d = parse(body);
    const ok = mcp.toggle(d.id, d.enabled !== false);
    return send(ok ? 200 : 404, { object: ok ? 'meta' : 'error', data: ok ? { id: d.id, enabled: !!d.enabled } : { type: 'not_found', message: '未注册' } });
  }
  if (p === '/agent/mcp/remove' && method === 'POST') {
    const d = parse(body);
    const ok = mcp.remove(d.id);
    return send(ok ? 200 : 404, { object: ok ? 'meta' : 'error', data: ok ? { removed: d.id } : { type: 'not_found', message: '未注册' } });
  }
  if (p === '/agent/mcp/connect' && method === 'POST') {
    const d = parse(body);
    const r = await mcp.connect(d.id);
    return send(r.ok ? 200 : 400, { object: r.ok ? 'meta' : 'error', data: r });
  }
  if (p === '/agent/mcp/call' && method === 'POST') {
    const d = parse(body);
    const t = String(d.tool || '');
    const dec = agent.decide(d.profile || 'default', t);
    if (dec.decision === 'deny') {
      agent.audit({ sessionId: d.sessionId, tool: t, decision: 'deny', result: 'blocked', mcpServer: d.serverId, note: dec.reason });
      return send(403, { object: 'error', data: { type: 'tool_denied', message: dec.reason, risk: dec.risk } });
    }
    try {
      const r = await mcp.callTool(d.serverId, t, d.args || {});
      agent.audit({ sessionId: d.sessionId, tool: t, decision: dec.decision, result: r.isError ? 'error' : 'ok', mcpServer: d.serverId, plugin: 'core-mcp' });
      return send(200, { object: 'meta', data: r });
    } catch (err) {
      agent.audit({ sessionId: d.sessionId, tool: t, decision: dec.decision, result: 'error', mcpServer: d.serverId, note: String(err.message || err) });
      return send(400, { object: 'error', data: { type: 'mcp_call_failed', message: String(err.message || err) } });
    }
  }

  return false;   // 未命中，交回主路由
}

module.exports = { handle };
