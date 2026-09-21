# ThirdHub 聊天协议（CHAT/1）

> 本文是聊天模块的**单一事实来源**。
> 两份实现与本文一一对应，改任何一处都必须同步另两处：
> - 前端：`flutter_app/lib/core/chat.dart`
> - 后端：`server/routes-data.js`（`/v1/chat/*` 段）
> - 自检：`server/test_chat_proto.cjs`（`node server/test_chat_proto.cjs`，12 条断言）
>
> 与 [THP.md](THP.md) 的关系：**两套独立协议**。THP 管"内容引擎/资源库"，
> 信封是 `{ok,data,meta}`；CHAT/1 走后端的 `/v1/` 家族，信封是 `{object,data}`。
> 不要混用。

## 0. 三条底线（先看这个）

聊天最容易在两个地方翻车，本协议的全部设计都是在防它们：

1. **离线优先**。本地是唯一权威：任何消息先落本机、立刻可见，
   网络只是"尽量把它送出去"。没有后端、后端挂了、断网、App 被杀——都不影响看历史。
2. **幂等上行**。客户端可能积压一整批没发出去的消息，重连后**整批重发**。
   服务端必须认出"这条我收过了"，并**回原来那个 seq**，否则会造出重复消息。
   识别键是客户端生成的 `cid`。
3. **单调整序**。会话内的顺序由**服务端分配的 `seq`** 决定，不由时间戳决定
   （多设备时钟不可信）。本地未发出的消息 `seq=0`，排序时统一排到最后。

## 1. 数据模型

### 1.1 ChatMsg（一条消息）

| 字段 | 类型 | 上行 | 说明 |
| --- | --- | --- | --- |
| `v` | int | ✓ | 协议版本，当前 `kChatProtoVersion = 1` |
| `cid` | string | ✓ | **幂等 id**，客户端生成。同一逻辑消息永远用同一个 cid（重试也用） |
| `sid` | string | ✓ | 会话 id |
| `seq` | int | 带但无效 | **会话内**单调递增序号，**由服务端分配**。客户端本地待发消息 = `0`；上行时会带上这个字段，但**服务端忽略它**，一律重新分配 |
| `ts` | int | ✓ | 客户端毫秒时间戳。仅用于展示，**不用于排序** |
| `from` | string | ✓ | 发送者标识。本机固定为 `'我'`（`_RoomState._me`） |
| `t` | string | ✓ | 消息类型：`text` / `image` / `file` / `system` / `ai` |
| `body` | string | ✓ | 正文。图片/文件消息里放 URL 或路径 |
| `ref` | string? | ✓ | 可选引用（回复某条、附件 id 等） |
| `name` | string? | ✓ | 可选显示名 |

**本地额外字段**（不上行，只在设备上）：

| 字段 | 含义 |
| --- | --- |
| `sent` | 是否已上行成功 |
| `read` | 本地是否已读 |

### 1.2 ChatSession（会话）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 会话 id |
| `title` | string | 标题 |
| `peer` | string | 对端标识（可空＝单机会话） |
| `lastSeq` | int | 服务端已知的最大 seq |
| `lastTs` | int | 最后一条消息的 ts（列表按它倒序） |
| `unread` | int | 本地未读数 |
| `count` | int | 服务端消息总数 |

## 2. 本地存储层

全部通过 `ProKit` 落本地，键名固定：

| 键 | 内容 |
| --- | --- |
| `chat_sessions` | 会话列表 |
| `chat_msgs_<sid>` | 某会话的消息列表 |
| `chat_outbox` | **发件箱**：已落本地但还没上行成功的消息 |

两条实现约束：

- **单会话保留上限 2000 条**。本地存储不是归档。超出时丢最旧的，
  真要留全量应该在后端（`chat-messages.json`）。
- **排序靠 `orderKey`，不靠 `ts`**：

  ```
  orderKey = seq > 0 ? seq : 1e15 + ts
  ```

  这个式子有两个作用：① 已确认的消息严格按服务端 seq 排，多设备一致；
  ② `seq=0` 的待发消息全部落到 `1e15` 以上，**永远排在最后**，
  不会因为本机时钟比别人快就插到中间去。

## 3. 上行协议

### 3.1 发送流程

```
用户点发送
  ├─ 生成 cid（时间戳 base36 + 随机后缀）
  ├─ 构造 ChatMsg（seq = 0, sent = false）
  ├─ 落本地（chat_msgs_<sid>）→ UI 立刻显示，带"待发"图标
  ├─ 入 outbox（chat_outbox）
  └─ 尝试 ChatApi.flush()
        ├─ 成功 → 写入服务端回的 seq，sent = true，出 outbox
        └─ 失败 → 留在 outbox，等下次 flush（进会话、30s 轮询、重连都会调）
```

### 3.2 flush 的语义

`ChatApi.flush()` 遍历 outbox 逐条 `POST /v1/chat/send`：

- 网络错 → 中止本轮（不删任何东西），剩余消息留在 outbox；
- 服务端回 `seq` → `dequeue(cid)`，把该消息标为已发并写入 seq；
- **成功一条删一条**，所以重复调用 flush 是安全的（幂等靠 cid，不靠"只调一次"）。

## 4. 后端端点

统一信封（后端 `/v1/` 家族约定，**不是 THP 的 `{ok}`**）：

```json
成功: { "object": "list"|"meta", "data": { ... } }
失败: { "object": "error", "data": { "type": "invalid_request", "message": "..." } }
```

### 4.1 `GET /v1/chat/sessions`

返回全部会话，按 `lastTs` 倒序。

```json
{ "object": "list", "data": { "sessions": [ { "id","title","peer","lastSeq","lastTs","count" } ] } }
```

### 4.2 `POST /v1/chat/sessions`

建/改会话。body：`{ "id", "title"?, "peer"? }`。
已存在时**只覆盖 title/peer，不动 lastSeq/lastTs/count**（那是服务端自己的计数）。
缺 `id` → `400 invalid_request`。

```json
{ "object": "meta", "data": { "saved": "<sid>" } }
```

### 4.3 `GET /v1/chat/messages?sid=&since=&limit=`

增量拉取。`since` 缺省 0 = 全量；`since=N` 只回 `seq > N` 的。
`limit` 默认 200、**上限 1000**（超出静默截断）。

```json
{ "object": "list", "data": { "messages": [ { "v","cid","sid","seq","ts","from","t","body","ref"?,"name"? } ] } }
```

### 4.4 `POST /v1/chat/send` —— 幂等上行

body：`{ "v", "cid", "sid", "ts", "from", "t", "body", "ref"?, "name"? }`

服务端逻辑：

1. 缺 `sid` 或 `cid` → `400 invalid_request`。
2. 在 `messages[sid]` 里按 `cid` 查。**查到就是重复**（客户端重发），
   直接回原 seq 并标 `dup:true`，**不新增消息**。
3. 没查到 → `seq = (该会话现有最大 seq) + 1`，追加消息并落盘。
4. 同步更新会话索引：`lastSeq = seq`、`lastTs = msg.ts`、`count = 消息数`。

```json
首次: { "object": "meta", "data": { "seq": 3, "id": "<cid>" } }
重复: { "object": "meta", "data": { "seq": 3, "dup": true } }
```

> **`dup:true` 是给调用方的提示，不是错误。** 客户端两种都当成功处理：
> 拿 `data.seq` 更新本地消息、出 outbox。

### 4.5 `POST /v1/chat/ack` —— 已读游标

body：`{ "sid", "seq" }`。服务端记 `acks[sid] = { seq, at }`。
缺 `sid` → `400 invalid_request`。

```json
{ "object": "meta", "data": { "seq": 3, "at": 1758432000000 } }
```

## 5. 同步时序

| 时机 | 动作 |
| --- | --- |
| 打开会话列表 | `flush()` 补发积压，再拉会话列表 |
| 进入会话 | `flush()` → `GET messages?sid=&since=<本地最大 seq>` → `merge()` |
| 会话内停留 | **每 30 秒** `Timer.periodic` 拉一次增量（`_RoomState._sync`） |
| 发消息 | 落本地 → 入 outbox → `flush()` |
| 拉到的远端消息 | `ChatStore.merge()` 写入：按 cid 合并，同 cid 以远端为准，**但 `read`/`sent` 取或**（`inc.sent \|\| old.sent`） |

`merge` 把 `read`/`sent` 取或的原因：这两个是**本机事实**，服务端不知道你在本机读没读过、
也不管你的发送状态。直接覆盖会把"已读"打回"未读"、把"已发"打回"待发"。
取或的方向是"一旦为真就不再变假"，符合这两个状态只单向演进的性质。

## 6. 版本与演进

- 版本号在每条消息的 `v` 字段里，当前 `1`。
- 新增字段**只增不改**，接收方忽略不认识的字段。
- 新增消息类型 = `t` 取新值，老客户端把它当未知类型渲染成纯文本（见
  `ChatRoomPage` 里 `m.type != kMsgText` 的图标分支），不得因此崩溃。
- 破坏性变更必须升 `v`，并在服务端按 `v` 分流。

## 7. 已知边界

- **没有端到端加密**。局域网信任模型，与 THP 一致（THP §5 L0）。
  需要私密性的场景应自行在 `body` 层加密后放入。
- **没有服务端推送**。靠 30 秒轮询，实时性以 30 秒为界。
- **没有多设备冲突消解**。同一 cid 只在服务端去重；不同设备各自生成 cid，
  同一语义消息从两台设备发会得到两条——这是设计选择（去重靠 cid 不靠内容 hash）。
- **`seq` 不做空洞检测**。客户端按 `> since` 增量拉，若服务端丢过消息，
  客户端不会发现。需要更强的保证时应在 `ChatApi.pull` 里比对连续性。

## 8. 自检

```bash
node server/test_chat_proto.cjs
```

12 条断言，**不需要后端服务在跑**（直接调路由处理函数、用临时目录做数据盘），
覆盖：建会话 / `seq` 连续为 `[1,2,3]` / **重发同 cid 回原 seq 且 `dup:true` 且总数不变** /
`since` 增量过滤 / 会话索引 `count`·`lastSeq` 同步 / 缺 `cid` 返回 400 /
未命中路径交回主路由 / `ack` 游标写入。

改动聊天相关代码后，**先跑它再出包**。
