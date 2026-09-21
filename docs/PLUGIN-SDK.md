# ThirdHub 插件 SDK（TH-PLUGIN/1 · 对齐 DSH/Cordis 插件规范）

> 把一个普通的 Node 进程变成"ThirdHub 认得的**一个端**"——它能在局域网里被发现、
> 用账号登录后接入、被前端/AI/其他插件调用，还能和所有端共享密钥与消息。
>
> **零依赖**：只用 Node 内置模块，插件作者不需要 `npm install` 任何东西。
> 参照实现：[`plugins/th-plugin.js`](../plugins/th-plugin.js)（SDK）
> · [`plugins/example-downloader/plugin.js`](../plugins/example-downloader/plugin.js)（照抄这个）
> · 契约锁定：[`server/peer-hub.js`](../server/peer-hub.js)（PH/1 中枢，174 条断言）
> · 真链路验收：`node plugins/selftest-plugin-e2e.js`（78 条断言，起真后端 + 真插件）

---

## 0. 先搞清楚：插件和"引擎"不是一回事

ThirdHub 生态里有两类扩展，别混：

| | **引擎**（THP/1.0） | **插件**（TH-PLUGIN/1，本文档） |
|---|---|---|
| 干什么 | 解析内容：搜索、目录、正文/图片/音频/视频 | 干**活**：下载、转码、读写文件、调本机程序、跑脚本 |
| 怎么被发现 | UDP 19527 广播 `THP/1 HELLO` | UDP 19527 广播 `TH-PEER/1 HELLO` |
| 接口 | `POST /thp/m/{module}/{search,toc,content}` | `POST /peer/exec`（按工具名分发） |
| 能力的粒度 | 模块（novel/comic/music/video） | 工具（`dl.add`、`fs.ls`…） |
| 谁能调 | 前端、资源库 | 前端、AI、其他插件、后端 |
| 文档 | [THP-SDK.md](THP-SDK.md) | 本文档 |

一句话：**引擎回答"有什么内容"，插件回答"帮我做这件事"。**

---

## 1. 四条硬规范（学 DSH 的地方，连同"为什么"）

这四条不是风格偏好，是 DSH/Cordis 用血换来的。SDK 按它们设计，你照着写就不会踩：

### ① 插件体必须是**具名导出**的 `apply(ctx)`，用 `export default` 会静默出事

DSH 的 loader 遇到 `export default` 时会把它折进 body，**并丢掉 `inject` 等元数据**——
依赖声明失效、加载顺序错乱，而且**不报错**。所以本 SDK 只接受 `apply(ctx)`：

```js
THPlugin.run(CFG, async (ctx) => { /* 你的插件体 */ });   // ✔
```

### ② **无模块级副作用**：一切定时器/监听器进 `ctx.effect`

```js
// ✘ 错：模块级定时器，热重载一次多一个幽灵任务，累积到进程卡死
setInterval(tick, 5000);

// ✔ 对：登记到 effect，返回 disposer，关停时会被调用
ctx.effect(() => {
  const t = setInterval(tick, 5000);
  return () => clearInterval(t);
});
```

验收方式很直接——`ctx.dispose()` 之后再等 150ms，计数器**一个都不许涨**
（`selftest-plugin-e2e.js` 第 9 节就是这一条）。

### ③ 依赖用 `inject` **声明**，不要在 apply 里凭运气去取

`THPlugin.run({ inject: ['secrets', 'relay'], ... })`。声明了才有确定的加载顺序。

### ④ 三种身份分清：Plugin（身份）/ Package（不可变代码）/ Run（本次激活）

- **身份**=`iid`，一旦定下就持久化在 `~/.th-plugin/<iid>.json`，重启不变；
- **代码**是可替换的，改了代码不该换身份；
- **本次激活**的临时状态（任务队列等）不持久、不假装持久。

所以：**别把运行时状态写进代码，也别把身份写死在代码之外的地方。**

---

## 2. 五分钟上手

### 2.1 最小插件（真能跑）

```js
// my-plugin.js
const { THPlugin } = require('./th-plugin');   // 从仓库 plugins/ 目录取

THPlugin.run({
  name: '我的插件',
  account: 'admin',
  password: '123456',        // 第一次接入用账号口令；之后自动复用 token
  port: 8801,                // 别的端要能连到你，别用 0
  caps: ['download'],        // 粗粒度能力标签
}, async (ctx) => {
  ctx.tool('hello', '打个招呼', {
    type: 'object',
    properties: { who: { type: 'string', description: '叫谁' } },
  }, async (a) => ({ said: '你好，' + (a.who || '世界') }));
});
```

```bash
node my-plugin.js
```

### 2.2 你会看到什么

```
[我的插件] 广播中（UDP :19527），等待后端发现
[我的插件] 找到后端: https://192.168.1.5:9527
[我的插件] 已接入 · 当前 3 个端在线 · 工具 1 个
[我的插件] 就绪 · 端口 8801 · 工具 hello
```

打开 App →「**端网**」模块，能看到：

- **在线**：已登录接入的端（能直接调用）
- **待登录**：只在局域网里被 UDP 发现、还没登录账号的端（**不可调用**）
- **离线**：曾经来过、现在不在

### 2.3 调它

在「端网」里点 `hello` 就能调；也可以直接打后端：

```bash
curl -k -X POST https://127.0.0.1:9527/agent/peer/invoke \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d '{"peerToken":"<你的 peerToken>","to":"<插件 iid>","tool":"hello","args":{"who":"小明"}}'
```

---

## 3. 生命周期全景

```
① apply(ctx)          注册工具与事件（必须先于对外暴露，否则第一次调用打到空工具表）
② 起 HTTP :port       GET /peer/manifest · POST /peer/exec · GET /health
③ UDP 广播            TH-PEER/1 HELLO <port> <iid> <caps> <name>  每 30s → 让后端"发现"你
④ 找后端              probe(host, 9527) → GET /agent/peer/ping （★匿名探针，见 §10.1）
⑤ join               POST /agent/peer/join（账号口令 → 换 peerToken + 交 execToken）
⑥ 心跳 15s           POST /agent/peer/beat → 45s 内无心跳判离线
⑦ 拉消息 3s          GET  /agent/peer/pull?since=<cursor>
⑧ 同步密钥 15s       GET  /agent/peer/secrets
⑨ 被调用             POST /agent/peer/invoke 经后端转发 → 打到你的 /peer/exec
⑩ dispose()          POST /agent/peer/leave → 逆序执行所有 effect → 关端口
```

> **为什么拉消息是 3s 而心跳是 15s**：把"一方输入，其他方都能用"绑在 15s 心跳上，
> 用户在 App 里打的字要 15 秒才到插件，体感就是坏的。两件事各有各的节奏。

**发现 ≠ 接入**。第 ③ 步只让后端"看得见你"，任何人伪造一条 UDP 广播都能做到；
第 ⑤ 步登录账号才算"接入"。没接入的端：不出现在端列表、不可被调用
（`PEER_NOT_LOGGED_IN`）。这正是"插件只需要登录对应的账号之后就可以连接"的实现。

---

## 4. API 参考：`ctx`

### 4.1 注册能力

| 方法 | 说明 |
|---|---|
| `ctx.tool(name, desc, inputSchema, handler, opts?)` | 注册工具。`opts.cap` 指定归属能力 |
| `ctx.on(event, fn)` | 监听事件：`'msg'` / `'joined'` / `'lost'` / `'call'` |
| `ctx.effect(fn)` | 登记副作用。`fn` 返回 disposer（或 `fn` 自己就是 disposer） |

> **`inputSchema` 一定要写**。前端和 AI 靠它知道怎么填参数；不写就只能靠人猜。
> 形状是标准 JSON Schema 的一小片（`type/properties/required`）。

### 4.2 运行时信息

| 属性 | 说明 |
|---|---|
| `ctx.iid` | 身份（持久化，重启不变） |
| `ctx.port` | 实际监听端口 |
| `ctx.hub` | 当前后端地址（未找到时为空串） |
| `ctx.token` | peerToken（未接入时为空串） |
| `ctx.online` | 是否已接入且心跳新鲜 |
| `ctx.tools` | 已注册工具名数组 |
| `ctx.caps` | 能力标签数组 |

### 4.3 主动做事

| 方法 | 说明 |
|---|---|
| `ctx.log(...)` | 打日志（`quiet:true` 时静默） |
| `ctx.secret(name)` | **读**统一密钥（本地缓存，启动与心跳时同步） |
| `await ctx.putSecret(name, value)` | **写**统一密钥 → 推到后端 → 下发给所有端 |
| `await ctx.relay(payload, topic?)` | 广播一条消息给所有端 |
| `ctx.diagnose()` | 把当前状态打成一段可读文本 |
| `await ctx.dispose()` | 优雅下线（leave + 逆序清理 effect + 关端口） |

自测/宿主专用：`ctx.joinNow()` / `ctx.beatNow()` / `ctx.syncNow()` / `ctx.pullNow()`。

### 4.4 `run(opts, apply)` 的全部参数

| 键 | 说明 |
|---|---|
| `name` | 插件显示名（UI 上显示的就是它；自己声明，不出现"官方"字样） |
| `iid` | 身份。不填则随机生成并持久化 |
| `version` | 版本号（manifest 里上报） |
| `hub` | 后端地址。不填则自动扫描局域网（慢，建议显式给或记住上次的） |
| `hosts` | 扫描时额外优先探测的主机 |
| `account` / `password` | 接入账号口令（口令可传明文或 sha256 十六进制） |
| `token` | 后端密钥（等价管理员身份；适合无人值守常驻插件） |
| `port` | 监听端口（默认 0=系统分配，**不推荐**：别的端要能连到你） |
| `advertiseHost` | 对外通告的主机地址（容器/NAT/自测场景用） |
| `caps` | 能力标签，如 `['download','files']` |
| `ipv6` | 对外可达的 IPv6 地址（见 §6） |
| `tunnel` | 内网穿透地址（见 §6） |
| `inject` | 依赖声明（规范 ③） |
| `quiet` | 不打印日志（自测用） |

---

## 5. 局域网发现与账号接入

### 5.1 广播格式（你不需要自己实现，SDK 已做）

```
TH-PEER/1 HELLO <port> <iid> <caps,逗号分隔> <名字>
→ UDP 19527，每 30 秒，同时发 255.255.255.255 和各网段定向 .255
```

后端收到后**只登记**，记成"待登录"，并在 App 的「端网」里显示出来。
用户看到后可以手动接入，或者你在旁边填 `account/password` 让它自己登录。

### 5.2 join 的两种凭据

```jsonc
// A. 账号口令（推荐给用户装的插件）
{ "kind":"plug", "iid":"...", "name":"...", "url":"http://192.168.1.7:8801",
  "caps":["download"], "tools":["dl.add"], "account":"admin", "password":"123456" }

// B. 后端密钥（无人值守；等价管理员）
{ ...同上..., "token":"<后端密钥>" }

// C. 续期（重启后免重新登录）
{ ...同上..., "peerToken":"<上次响应里的 peerToken>" }
```

成功响应：

```jsonc
{ "ok":true, "data":{ "joined":true, "peerToken":"<新 token>",
  "hub":{ "iid":"local-back", "name":"ThirdHub 后端", "version":"4.44.0" },
  "online":3 } }
```

> **token 只在这一次响应里出现**。落盘后下次 join 用它续期即可，不用再输密码。
> **每次 join 都会换发新 token，旧 token 立即失效**——所以别多个进程共用一个 iid。

---

## 6. 没有后端也能用：IPv6 / 内网穿透直连

后端不在的时候，前端会退化成**直连插件**。要做到这一点，插件必须在 join 时
自报一个"外面够得着"的地址：

```js
THPlugin.run({
  // …
  ipv6:   'http://[2001:db8::5]:8801',        // 有公网/可达 IPv6 时
  tunnel: 'https://xxx.trycloudflare.com',    // 或走内网穿透
}, apply);
```

后端会把它们放进端列表的 `direct` 字段（顺序：局域网 url → tunnel → ipv6）：

```jsonc
{ "iid":"...", "url":"http://192.168.1.7:8801",
  "direct":["http://192.168.1.7:8801","https://xxx.trycloudflare.com","http://[2001:db8::5]:8801"] }
```

前端 `PeerRouter` 的判定顺序是：**本地离线能力 → 有后端就走后端转发 →
没后端就按 `direct` 直连**。所以：

- 同一局域网：直连 `url` 最快；
- 跨网、后端不在：自动落到 tunnel / ipv6；
- 地址形态随便写（`[2001:db8::5]:8801` 这种裸写法也认，会自动补 `http://`）。

> **注意**：直连时前端手里没有 `execToken`（它只属于后端 ↔ 插件之间）。
> 所以想要"完全无后端的直连"，插件可以在 join 时**不要**交 execToken，
> 或者自己再开一条只读/低权限的直连通道。默认行为是"必须有令牌"——
> 宁可跨网用不了，也不要让局域网里任何人能指挥你的插件。

---

## 7. 密钥统一到所有端

"所有的密钥只要前端还是后端还是插件上有，都会统一到其他所有端"——就是这一节。

```js
// 读（启动与心跳时自动同步到本地缓存）
const key = ctx.secret('tmdb.key');

// 写（推给后端 → 下发给所有端）
await ctx.putSecret('proxy.url', 'http://127.0.0.1:7890');
```

后端存储形状（每条带 `rev` / `updatedAt` / `from`）：

```jsonc
{ "tmdb.key": { "value":"K-123", "rev":3, "updatedAt":1737…, "from":"example-downloader" } }
```

**冲突保护（重要）**：写入支持乐观并发。

```js
await request('POST', hub + '/agent/peer/secrets', {
  peerToken, set: { 'tmdb.key': 'NEW' }, ifRev: { 'tmdb.key': 3 }
});
```

`ifRev` 与实际 `rev` 不符时**不覆盖**，把冲突项原样回报。合并规则：
`rev` 大者新 → 相同比 `updatedAt` → 再相同且值一致=`same`、值不同=`conflict`（**绝不自动覆盖**）。

> **坑（自测抓到过）**：在 `apply()` 阶段就 `putSecret()` 时，此刻还没接入、
> `pushSecrets` 尚未就绪——旧版 SDK 直接 crash，修好绑定后又变成"本地存了但没推出去"。
> 现在 SDK 会把这些**攒进待推队列**，join 成功后补推。你不需要做什么，但要知道
> 这个语义：**apply 阶段写的密钥，会在接入那一刻才真正同步出去**。

---

## 8. 端间消息：一方输入，其他方都能用

```js
// 发
await ctx.relay({ text: '这段字是在插件里打的' }, 'download');

// 收
ctx.on('msg', (m) => {
  // m = { id, at, from, fromName, to, topic, payload }
  ctx.log('收到来自「' + m.fromName + '」的消息：', m.payload);
});
```

- `to` 为空 = 广播；填 iid = 点名（SDK 默认不回放自己发的）。
- `topic` 是自由标签：`input` / `download` / `clip` / `search` / `cmd` …
- 拉取用 cursor：`GET /agent/peer/pull?since=<上次的 id>`。
  **空结果时后端保留原 cursor**（不会让你每次从头拉）。

`fromName` 是后端填的——前端直接显示人话，不用自己查 iid → 名字的表。

---

## 9. 安全模型：三道门

| 门 | 拦什么 | 错了会怎样 |
|---|---|---|
| **① 发现 ≠ 接入** | 伪造 UDP 广播的进程 | 只在"待登录"里显示，**不可被调用**（`PEER_NOT_LOGGED_IN`） |
| **② peerToken** | 没登录的端读端列表/密钥/消息 | `401 UNAUTHORIZED` |
| **③ execToken** | **绕过后端直接打插件** | 插件回 `403 UNAUTHORIZED` |

第 ③ 道门容易被忽略，但它是"登录才能接入"的**最后一公里**：
没有它，局域网里任何进程 `curl -X POST http://你的插件:8801/peer/exec` 就能使唤你。
SDK 的做法：插件启动时生成 `execToken`，**只在 join 时交给后端**，
后端代它保管、invoke 时以 `X-TH-Peer-Exec` 头出示，插件校验。

- `execToken` **绝不会出现在端列表里**（自测有断言守这条）；
- `GET /peer/manifest` 保持匿名可读——前端要能预览"这插件能干什么"，
  但那只是只读元信息，**不给执行**。

---

## 10. 排障手册（都是真踩过的）

### 10.1 "插件永远找不到后端"

**根因**：拿一个**需要鉴权**的端点当身份探针。曾经的版本打 `/v1/meta`——该端点
根本不存在；换成 `/v1/ping` 也会拿到 401（它在鉴权闸门之后）。

**正确做法**：探 `GET /agent/peer/ping`。它是专门为此开的**匿名**端点
（在闸门之前），只回 `object/proto/name/iid/version/caps`，不泄露端列表与密钥。

```bash
curl -k https://127.0.0.1:9527/agent/peer/ping
# {"ok":true,"data":{"object":"peer-hub","proto":"PH/1","name":"ThirdHub 后端",…}}
```

**通用教训**：写发现协议时，探针端点**必须在网关之前**，且只回身份、不回情报。

### 10.2 "App 里能看到插件，但点调用报 NOT_LOGGED_IN"

那说明它只是被 UDP 发现了，**没登录**。看插件日志有没有 `已接入`；
空口令 / 错口令会打 `接入失败: UNAUTHORIZED: …`。

### 10.3 "调用报 UNAUTHORIZED，但插件明明在线"

那是 §9 第 ③ 道门：调用没带 `X-TH-Peer-Exec`。**只有后端转发才会带**。
如果你是在自己写前端并想直连插件，要么让插件别交 execToken，要么自己走后端转发。

### 10.4 "插件改了代码，行为还是老的"

身份 `iid` 是持久的，但**代码不是**——重启进程即可。若你改了 `iid`，
后端里会多出一个"离线"的旧端（不影响功能，可以在「端网」里清）。

### 10.5 "热重载之后越来越卡"

你一定在模块级起了定时器或 socket。全部搬进 `ctx.effect()`。
验收：`dispose()` 后 150ms 内计数器不许涨。

### 10.6 "在 Windows 上 Ctrl+C 没有优雅下线"

Windows 的 `SIGTERM` 是硬终止，跑不到 handler。要么用 Ctrl+C（`SIGINT`，能跑），
要么以 IPC 方式拉起插件然后 `child.send('shutdown')`——示例插件两种都实现了。

### 10.7 "改了端口就再也接不上了"

`~/.th-plugin/<iid>.json` 里记着 `hub` 和 `token`。后端换了地址/密钥后
先删掉这个文件重新登录一次。**这也是排查"莫名其妙的 401"的第一站。**

---

## 11. 打包与分发

插件就是一个 Node 目录，最小形态：

```
my-plugin/
├── plugin.js        ← THPlugin.run(...)
└── th-plugin.js     ← SDK（从仓库 plugins/ 拷一份，保持零依赖）
```

给用户的三条路：

1. **直接给目录** + 一句 `node plugin.js`（最简单，推荐）；
2. **打包成单文件**：把 SDK 内联进 `plugin.js`，用户只需要一个文件；
3. **常驻服务**：Windows 用 `start.cmd` + 计划任务，Linux 用 systemd unit。
   常驻插件建议用 `token`（后端密钥）接入，避免口令落进日志。

**分发纪律**（与主仓一致）：

- 插件里**不得硬编码任何密钥**——一律走 `ctx.secret()` / 环境变量；
- 推送前过一遍密钥扫描（`sb_secret_` / `sbp_` / 私钥块 一律硬拦）；
- 插件是**用户自制的独立软件**：UI 上显示的是插件自己在 `name` 里声明的名字，
  不出现"官方""内置"字样。官方不分发、不审核、不推荐任何插件。

---

## 12. 自检：怎么证明你的插件真的对

```bash
# SDK + 示例插件的真链路验收（起真后端 + 真插件 + 真 HTTP）
node plugins/selftest-plugin-e2e.js
# → PASS 78   FAIL 0

# PH/1 中枢本身的契约（含全部反向用例）
node server/scripts/selftest-peer-hub.js
# → PASS 174  FAIL 0
```

**改插件前先跑这两条**，它们会挡住 90% 的"看起来能跑其实契约错了"。
`selftest-plugin-e2e.js` 第 10 节会**真起一个子进程跑示例插件**——
模板一旦腐烂（忘 effect、工具名写错、启动即崩），那一节立刻红。

自查清单：

- [ ] `node --check plugin.js` 过
- [ ] 工具都写了 `inputSchema`
- [ ] 所有定时器/监听器都在 `ctx.effect()` 里，并返回 disposer
- [ ] `ctx.dispose()` 之后进程能干净退出（`node --trace-exit` 可验）
- [ ] 插件里没有明文密钥
- [ ] join 之后 App「端网」里能看到它，且状态是**在线**（不是"待登录"）
- [ ] 从 App 点一次你的工具，能拿到结果
