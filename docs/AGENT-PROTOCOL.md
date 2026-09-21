# THA/1 · ThirdHub Agent 协议

> 状态：已实现（v4.42.0）。服务端实现 `server/agent-dsh.js` + `server/routes-agent.js`，
> 客户端实现 `flutter_app/lib/core/agent_{models,policy,dsh_client}.dart`。
> 自检：`node server/test_agent_proto.cjs`（88 条）、
> `dart run tool/agent_proto_selfcheck.dart`（140 条）。
>
> 这份文档取代之前散在注释里的口头约定。**改协议先改这里，再改两端代码。**

---

## 0. 一句话立场

**Agent 内核不在 Dart 里。** DeepSeek Harness(DSH) 只跑在服务端/局域网设备上；
Flutter 是控制面：发起任务、渲染事件流、批准高危操作、看审计。
没有 DSH 时降级为轻量 Agent（复用既有的 `ai.dart` + `local_tools.dart`），
但**协议不变** —— 所以「有后端」和「没后端」两种模式共用同一套事件与审计格式。

---

## 1. 两种运行模式

| 模式 | 条件 | 事件来源 | 可用能力 |
|---|---|---|---|
| `full` | 后端在线 **且** 后端那侧探到 DSH | DSH 产出，服务端推给客户端 | 全部：多步工具、沙箱、MCP、插件、上下文预算 |
| `fallback` | 其余一切情况 | 客户端本地循环产出，可选回填服务端 | 聊天 + 本机白名单工具；**不假装**有沙箱/MCP |

判定入口：`GET /agent/health`。客户端**必须先探模式再发任务**，
不允许「先假装能跑，跑不动再说」。

`mode` 与「能力」是两件事，两者都要看：

```jsonc
{
  "mode": "fallback",              // full | fallback
  "fullAgentAvailable": false,
  "dsh": { "detected": false, "kind": "none", "running": false, "error": "本机未安装 DSH（属正常：会自动降级为轻量 Agent）" },
  "capabilities": {                // 永远在线的那一层
    "eventLog": true, "policy": true, "confirmQueue": true, "audit": true, "mcpRegistry": true,
    "sandbox": false,              // 只有 full 才为 true
    "nativePlugins": false
  }
}
```

`dsh.error` 必须始终可读（降级原因要能直接念给用户听），不能是空串。

---

## 2. 响应信封

`/agent/*` 沿用后端 `/v1` 家族的信封（**注意与 THP 不同**，THP 用 `{ok,data}`）：

```jsonc
{ "object": "list" | "meta" | "error", "data": …, "meta": { … } }
```

错误：

```jsonc
{ "object": "error", "data": { "type": "invalid_request", "message": "…" } }
```

鉴权：全部 `/agent/*` 都在 `X-TH-Token` 闸门之后（与 `/v1/*` 一致）。

---

## 3. 端点一览

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/agent/health` | 模式 + 能力 + 档位 + 插件。带 `?probe=1` 时真去探一次 DSH |
| POST | `/agent/dsh/start` \| `/agent/dsh/stop` | 启停服务端侧的 DSH 进程 |
| GET | `/agent/sessions` | 会话列表（`limit`，默认 50） |
| POST | `/agent/session` | 建会话 `{title,userId,profile,id?}`。**profile 写错返回 400**，不许静默回落 |
| GET | `/agent/session/<sid>` | 单个会话元信息 |
| GET | `/agent/events` | `?sessionId=&since=&limit=` 增量拉事件。`meta.lastSeq` 回带游标 |
| GET | `/agent/events/stream` | SSE 增量推送（见 §6） |
| POST | `/agent/event` | 客户端上报一个事件（降级模式回填用） |
| POST | `/agent/send` | 发起一轮：落一条 `user_message`，回带 `mode` / `hint` |
| GET | `/agent/confirm` | `?sessionId=` 挂起的确认项 |
| POST | `/agent/confirm` | 发起确认 `{sessionId,tool,args}` **或** 答复 `{confirmId,allow,by}` |
| GET | `/agent/audit` | `?limit=&sessionId=` 审计流水（倒序） |
| POST | `/agent/audit` | 手工补一条审计（一般不用，事件会自动落） |
| GET | `/agent/profiles` | 三档定义 + `meta.risk`（工具风险表） |
| GET | `/agent/tools` | `?profile=` 该档位下每个工具的 allow/confirm/deny（**判定由服务端算好**） |
| GET | `/agent/plugins` | 插件白名单 + 许可证策略 |
| GET/POST | `/agent/mcp` | 列出 / 注册 MCP 服务 |
| POST | `/agent/mcp/{toggle,remove,connect,call}` | 开关 / 删除 / 连接 / 调用 |
| POST | `/agent/mcp/call` | 调用前会过档位判定，被拒返回 403 并留审计 |

---

## 4. 事件协议

事件是**唯一的事实单位**：append-only，只追加，永不修改、永不删除。

```jsonc
{
  "id": "evt_<ts36>_<seq36>",   // 全局唯一
  "sessionId": "sess_<ts36>_<n>",
  "seq": 1,                      // 会话内单调递增，从 1 开始
  "ts": 1720000000000,           // 毫秒
  "type": "tool_call",
  "payload": { }
}
```

### 4.1 类型与载荷

| type | 载荷 | 谁产出 |
|---|---|---|
| `user_message` | `{text, contextRefs[]}` | 客户端 |
| `assistant_delta` | `{text}` | 任一侧（流式增量） |
| `assistant_message` | `{text}` | 任一侧（完整一句） |
| `tool_call` | `{tool, arguments, argsDigest?, risk?, decision?}` | 任一侧 |
| `tool_result` | `{tool, ok, summary}` | 任一侧。**只回摘要**，完整结果落服务端 |
| `confirm_request` | `{tool, args, argsDigest, risk, reason}` | 服务端 |
| `confirm_result` | `{confirmId, tool, allow, by, argsDigest?}` | 客户端/服务端 |
| `audit` | `{note, decision?, tool?, profile?, risk?}` | 任一侧 |
| `artifact` | `{kind: patch\|file\|diff\|log, uri, summary, requiresConfirm}` | 任一侧 |
| `error` | `{code, message, tool?}` | 任一侧 |
| `done` | `{taskStatus, tokens?, cost?, rounds?, mode?}` | 任一侧 |

未知类型：服务端 `POST /agent/event` 返回 **400**（不是 500），
客户端渲染时兜底成一行「未知事件」，不得因为一条脏数据中断整条流。

### 4.2 关键不变量（都写进自检了）

1. `seq` 在会话内严格单调；`since=<seq>` 只返回更新的。
2. `id` 全局唯一。
3. **有未答复的 `confirm_request` 时，这一轮视为阻塞** ——
   客户端不得继续推进（`AgentTimeline.blockedByConfirm`）。
4. `confirm_result` 以 `confirmId` 幂等：同一 id 答复两次，挂起数仍为 0。
5. 建会话时自动落一条 `done`（`taskStatus=created`），所以首个业务事件从 `seq=2` 起。

### 4.3 `contextRefs`：只传引用，不传大文本

Flutter **不拼超大 prompt**。它只上报「引用 + 优先级」，由服务端/DSH 解析成模型上下文。

```jsonc
{
  "contextRefs": [
    { "type": "selected_text", "ref": "clipboard",              "preview": "…" },
    { "type": "book",          "ref": "shelf:bookId" },
    { "type": "file",          "ref": "server:path#hash" },
    { "type": "kb",            "ref": "kb:docId#chunk" },
    { "type": "page",          "ref": "url#anchor" }
  ]
}
```

规则：文件/书籍先抽 chunk 再进上下文；工具结果默认只回摘要 + `artifactRef`，
完整结果落服务端、模型按需再取；老历史超预算折叠成摘要，**不整段丢弃**。

---

## 5. 权限档位与工具风险

服务端 `agent-profiles.json` 是权威；Flutter 侧 `agent_policy.dart` 是**本地镜像**，
只用于 UI 预判与断网拦截。两份表由自检**逐工具对拍**（漂移即红）。

### 5.1 风险三档

| risk | 含义 | 工具 |
|---|---|---|
| `read` | 只读安全 | `kb.search` `book.info` `file.readSelected` `clipboard.read` `text.diff` `device.info` `fs.list` |
| `write` | 受控写入 | `note.save` `download.export` `bookshelf.update` `reading.progress.write` `clipboard.write` `device.tts` `device.share` `fs.share` |
| `danger` | 高危 | `fs.write` `fs.delete` `shell.run` `package.install` `browser.open` `accessibility.tap` |

**未登记的工具一律按 `danger` 处理** —— 白名单制的必然推论：漏登记的表现是「用不了」，
而不是「悄悄放行」。

### 5.2 档位

| profile | 语义 | 结果 |
|---|---|---|
| `default` | 只读 + 保存草稿 + 书架阅读类写入 | 7 放行 / 4 确认 / 10 拒绝 |
| `acceptEdits` | 本次会话内确认过的写文件；**只解锁 `fs.write` 这一个高危** | 15 / 1 / 5 |
| `full-access` | 仅服务端管理侧，普通用户界面不展示 | 21 / 0 / 0 |

判定顺序（两端必须一致）：

```
档位存在性 → denyTools → 风险是否被 allowRisk/allowTools 覆盖 → confirmTools → allow
```

两条硬规则：

- **档位名写错 → 一律拒绝**（不许回落到 `default`）。建会话时也校验，写错直接 400。
- `denyTools` 优先于一切。

### 5.3 本机工具名 ↔ 策略工具名（bridge）

Flutter 的 `LocalTools` 用 `local_file_write` 这种名字，策略表用 `fs.write`。
两套名字必须显式对上 —— 否则会出现「策略放行了，实际调的却是另一个名字」，
这种错在 UI 上完全看不出来。

映射写在 `agent-profiles.json` 的 `bridge.map`，Dart 侧镜像在 `AgentPolicy.localBridge`，
由自检逐项对拍 + 覆盖度检查（`LocalTools` 的 13 个工具必须都能翻）。

几个语义上必须记住的：

| 本机工具 | 策略名 | 为什么 |
|---|---|---|
| `file_write` | `fs.write` | 高危，写文件 |
| `file_delete` | `fs.delete` | 高危 |
| `run_python` | `shell.run` | 在后端执行代码，等同 shell |
| `open_url` | `browser.open` | 高危 |
| `web_search` | `kb.search` | 只读 |

---

## 6. 事件流推送（SSE）

`GET /agent/events/stream?sessionId=&since=`

```
event: hello
data: {"sessionId":"…","mode":"full","lastSeq":12}

id: 13
event: tool_call
data: {…完整事件…}

: ping                       ← 心跳，每 ~700ms 若无新事件

event: close
data: {"sessionId":"…","lastSeq":18}   ← 本轮出现 done 后主动收尾
```

约定：

- 服务端每 **700ms** 推一次增量；无新事件发心跳注释行。
- 出现 `done` 就发 `close` 并 `res.end()` —— 客户端不必自己猜何时结束。
- 连接最长挂 **10 分钟**，到点强制断开，避免连接泄漏。
- 客户端断流/被中间设备掐掉时，**必须回落到轮询** `GET /agent/events?since=`。
- `since` 用客户端已收到的最大 `seq`，续传不重不漏。

---

## 7. 确认（高危闸门）

```
客户端                     服务端
  │  POST /agent/send         │
  │ ───────────────────────►  │  落 user_message
  │                           │  DSH 想调 fs.write
  │  ◄── confirm_request ───  │  落事件 + 挂起队列 + 审计(decision=confirm)
  │                           │
  │  POST /agent/confirm      │
  │   {confirmId, allow:true} │
  │ ───────────────────────►  │  落 confirm_result + 审计(allow/deny) + 出队
```

规则：

- `default` 档下请求高危工具 → **403**，且**不产生挂起项**（免得用户以为"点了就行"），但仍写审计。
- 确认项只在内存队列里；**答复会落成事件**，所以重启后事件流仍完整可溯。
- 重复答复 → 404（不是 500）。
- 客户端在 `default` 档下的受控写、更高档下的高危，都必须先弹一句确认，
  并把**将要传入的参数**原样展示给用户看。

---

## 8. 审计

流水落 `<DATA>/agent-audit.jsonl`，跨会话，一行一条：

```jsonc
{
  "ts": 1720000000000,
  "sessionId": "sess_…",
  "userId": "user_or_anon",
  "profile": "default",
  "tool": "fs.write",
  "argsDigest": "sha256:…",        // 只存摘要，不存参数原文
  "decision": "allow|deny|confirm",
  "result": "ok|error|blocked|pending|invoked|confirmed|user_approved",
  "plugin": "core-sandbox",         // 可空
  "mcpServer": "mcp1",              // 可空
  "note": "…"
}
```

自动落审计的时机：`tool_call`、`confirm_request`、`confirm_result`，
以及「请求被拒」这件事本身 —— **被拒也必须留痕**：审计里「没记录」和
「记录了 allow」是两码事。

参数不落原文只落 `sha256` 摘要：审计要能证明"调过什么"，但不必再存一份用户数据。

---

## 9. MCP

- **Flutter 不跑 stdio MCP**，也不直连 MCP server。连接与调用统一在服务端/DSH 侧。
- 客户端只读写服务端注册表（`/agent/mcp*`），做展示与开关。
- 注册表落 `<DATA>/agent-mcp.json`；工具摊平后 `serverId` 形如 `mcp:<id>`。
- 调用前先过档位判定；被拒 → 403 + 审计。连不上不抛异常，返回 400 + 可读原因。
- 传输：Streamable HTTP / SSE。地址必须是 `http(s)://`，重复地址 400。

---

## 10. 插件与许可证

`agent-plugins.json` 白名单制（未登记一律不加载，不做黑名单）：

- 白名单：MIT / Apache-2.0 / BSD-2/3-Clause / ISC
- 谨慎：LGPL / MPL（需法务确认后再进闭源分发）
- **禁入**：GPL-2.0/3.0 / AGPL-3.0 / SSPL-1.0 / BUSL-1.1
- 每条登记 `version` / `license` / `permissions` / `network` 端点
- 新插件先跑 `isolated` profile（无网络、只读 fs）试跑
- 升级 DSH 前必须跑 `server/test_agent_proto.cjs` + `tool/agent_selfcheck.dart`

---

## 11. 上下文预算

Flutter 只上报引用与优先级；预算与压缩由服务端/DSH 负责。
量级参考（`agent-profiles.json` 的 `budget` 段）：

```
system prompt 6k–12k | tool schemas 4k–10k | chat history 12k–32k
summary memory 2k–6k | kb/rag 4k–12k | selected files 4k–16k | 输出预留 15%–30%
```

优先级：**用户显式选中 > 当前阅读/当前页面 > 工具返回摘要 > KB/RAG > 会话摘要 > 老历史**

---

## 12. 降级语义（最容易做错的一节）

降级不是「什么都干不了」，也不是「假装什么都行」。准确表述：

| 能力 | 无后端 | 有后端无 DSH | 完整 |
|---|---|---|---|
| 聊天 | ✅ | ✅ | ✅ |
| 事件日志 / 审计 / 策略 / 确认队列 | ✅（本地） | ✅（服务端） | ✅ |
| 本机白名单工具 | ✅（见下） | ✅ | ✅ |
| MCP 工具 | ❌ | ✅ | ✅ |
| 沙箱 / 原生插件 / 上下文预算 | ❌ | ❌ | ✅ |

**离线白名单**（`AgentPolicy.fallbackWhitelist`）：
`kb.search` `book.info` `file.readSelected` `clipboard.read` `text.diff` `note.save` `download.export`

白名单外的工具在离线时一律拒绝；**高危在任何模式下都不许离线执行**。

客户端文案要求：说清「现在缺什么、为什么缺、怎么才行」，不要只说「不可用」。

---

## 13. 版本演进

- 协议版本 `THA/1`，在 `/agent/health` 的 `protocolVersion` 回带。
- 加事件类型：先在本文件登记 → 服务端的 `EVENT_TYPES` → 客户端 `AgentEventType`
  → 两端自检各加一条断言。**顺序不能反**。
- 加工具：先登记 `risk` 档，再登记 `bridge.map`（如果是本机工具），
  最后跑两端自检 —— bridge 漏登记会让工具在任何档位都调不动。
- 改档位语义：必须同时更新 `agent-profiles.json` 与 `agent_policy.dart`，
  否则对拍自检会红。

---

## 14. 已知边界（如实列出，不假装已解决）

1. **DSH 未内置**：本机/本仓不带 DSH。`/agent/health` 会如实报 `fallback`，
   并给出原因。`full` 模式需要用户在服务端装好 DSH 后
   `POST /agent/dsh/start`（或配 `TH_DSH_URL` / `TH_DSH_CMD` / `<DATA>/agent-dsh.json`）。
2. **补丁/差异展示**：`artifact` 的 `diff` / `patch` 目前只把 `summary` + `uri` 展示出来，
   没有做逐行 diff 高亮。
3. **确认项不跨重启**：挂起队列在内存里；重启后事件流完整，但未答复的确认需要重新发起。
4. **`/agent/events/stream` 单会话一份轮询定时器**：会话很多时以 SSE 长连接的代价换增量实时性，
   后续可换成单定时器 + 多连接分发。
5. **`argsDigest` 用 sha256 前 32 位**：用于比对，不作为口令学意义上的完整性证明。
