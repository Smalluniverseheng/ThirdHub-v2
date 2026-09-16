# ThirdHub 引擎 SDK（THP-SDK · 对齐 THP/1.0）

> 让任何内容引擎 **5 分钟接入 ThirdHub 生态**：接入方只需实现本 SDK 描述的引擎侧，
> 前端 App 与资源库 **零改动** 自动发现、自动接入、自动聚合。
>
> 协议单一事实来源：[THP.md](THP.md)（THP/1.0 正式规范，主版本冻结、只增不减）。
> 本文档是面向引擎开发者的上手手册；如与 THP.md 冲突，以 THP.md 为准。

## 0. 定位：你的引擎是"用户自制的协议插件"

ThirdHub 官方**不分发、不推荐、不审核**任何引擎与内容源（THP.md §17 法律防火墙）。
你的引擎在用户设备上就是一个**支持 THP 开放协议的独立软件**：

- 引擎与 ThirdHub 无品牌绑定、无账号关系、无数据回传；
- 前端/资源库通过协议自动发现引擎，UI 上展示的是**你在 meta 里自己声明的名称**，
  不出现"官方""内置"字样；
- 用户随时可以断开、删除你的引擎，一切数据留在用户自己的资源库。

## 1. 接入要做的事（一共 5 件）

```
① 持久化一个 instanceId（UUID，重启不变）
② 每 30 秒（10–300s 可调）广播 UDP HELLO 到 19527，退出时发 BYE
③ 起一个 HTTP 服务，实现必选端点：
     GET  /thp/meta
     POST /thp/m/{module}/search   （或 GET 版 + caps 不声明 post-query）
     POST /thp/m/{module}/toc
     POST /thp/m/{module}/content
④ 全部响应用统一信封：成功 {"ok":true,"data":...,"meta":{}} / 失败 {"ok":false,"error":{"code","message"}}
⑤ 遵守兼容性军规：未知字段忽略、新能力只加 caps、protocol 报 "THP/1.0"
```

完成度自检用仓库自带工具：`thp-check <你的地址> --role engine`（见 THP.md §16）。

## 2. 快速开始（Node.js 最小参考实现）

```js
// my-engine.js —— 一个最小可运行的 THP/1.0 小说引擎
const http = require('http');
const dgram = require('dgram');
const crypto = require('crypto');
const fs = require('fs');

const PORT = 12001;
const MODULE = 'novel';                    // 模块: novel/comic/video/music/live/audiobook...
const IID_FILE = './instance-id';

// ① instanceId：重启不变
let iid;
try { iid = fs.readFileSync(IID_FILE, 'utf8').trim(); }
catch { iid = crypto.randomUUID(); fs.writeFileSync(IID_FILE, iid); }

// ② UDP 心跳 + 优雅下线
const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
const hello = `THP/1 HELLO ${PORT} ${iid} engine m:${MODULE} 我的引擎`;
sock.bind(() => { sock.setBroadcast(true);
  setInterval(() => sock.send(hello, 19527, '255.255.255.255'), 30000); });
process.on('SIGINT', () => { sock.send(`THP/1 BYE ${iid}`, 19527, '255.255.255.255', () => process.exit(0)); });

// ③④ HTTP 端点（统一信封）
const ok  = (res, data, meta = {}) => { res.writeHead(200, {'content-type':'application/json'}); res.end(JSON.stringify({ ok: true, data, meta })); };
const err = (res, code, message, status = 200) => { res.writeHead(status, {'content-type':'application/json'}); res.end(JSON.stringify({ ok: false, error: { code, message } })); };

http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const body = req.method === 'POST' ? JSON.parse(await new Promise(r => { let s=''; req.on('data', c => s+=c); req.on('end', () => r(s || '{}')); })) : Object.fromEntries(u.searchParams);

  if (u.pathname === '/thp/meta')
    return ok(res, { protocol: 'THP/1.0', instanceId: iid, role: 'engine', name: '我的引擎',
      version: '1.0.0', vendor: 'me', caps: [`m:${MODULE}`, 'post-query'],
      auth: ['none'], remote: false, endpoints: ['search','toc','content'], deprecated: [], ext: {} });

  if (u.pathname === `/thp/m/${MODULE}/search`)
    return ok(res, [{ id: 'book-1', name: '示例书', author: '作者', coverUrl: '', intro: '', ref: 'https://site/book/1' }],
      { source: iid, cursor: '', hasMore: false });

  if (u.pathname === `/thp/m/${MODULE}/toc`)
    return ok(res, [{ id: 'c1', name: '第1章', index: 0 }], { source: iid, cursor: '', hasMore: false });

  if (u.pathname === `/thp/m/${MODULE}/content`)
    return ok(res, { text: '正文……' }, { source: iid });

  err(res, 'NOT_FOUND', 'unknown endpoint', 404);
}).listen(PORT);
```

启动后：ThirdHub 前端 → 我的 → 引擎直连，即可看到你在 meta 里声明的引擎名；连上资源库则自动参与全局搜索聚合。

## 3. 关键规约速查

| 主题 | 要点 |
|---|---|
| 信封 | 只有两种形态；失败唯一判据 `ok:false`；HTTP 状态码仅作传输语义（404=端点/资源不存在） |
| 模块路径 | `/thp/m/{module}/...`，模块注册表见 THP.md §6.1；未知模块返回 404 |
| 分页 | cursor 分页：`{q, limit, cursor}` → `meta{cursor, hasMore}`；不用 page |
| ID | 不透明字符串、peer-local；原始 URL 放 `ref` 字段，禁止把 URL 当 ID |
| 请求头 | 回显 `X-TH-Request-Id`（有则原样返回） |
| caps | `m:{module}` 声明模块；`post-query`/`batch-content`/`jobs`/`events`/`tools`/`discover` 按需追加；未知 caps 会被忽略 |
| 错误码 | `UPSTREAM_FAIL / NOT_FOUND / UNSUPPORTED / RATE_LIMIT / SOURCE_BANNED / RULE_BROKEN / TIMEOUT`，自定义允许 |
| 可选端点 | extra（歌词/字幕）/content:batch（NDJSON 流）/jobs/events/tools 全部可选，404 即降级 |
| 只读 | **engine 禁止实现任何写端点**（items/blob/changes 属 library 角色） |
| 加密 | 传输加密只发生在前端⇄资源库之间；引擎侧永远明文 HTTP、不感知 |

## 4. 超时与性能

- 单端点响应建议 ≤ 15s；本地 peer 四基础端点目标 P50 < 200ms
- 资源库聚合搜索：最多并发 8 个 peer、单 peer 超时 8s——你的引擎慢了只会被跳过，不影响别人
- 引擎崩溃重启后 instanceId 不变，前端无感

## 5. 与现有实现的关系

| 实现 | 形态 | 说明 |
|---|---|---|
| 阅读引擎（Legado 底仓） | 独立 App | 社区用户按 THP 制作的引擎实现之一 |
| 漫画引擎（venera JS 沙箱） | 独立 App | 同上 |
| 落雪 / TVBox 适配器 | 资源库进程内沙箱 | 资源库侧适配，非引擎标准形态 |
| **你的引擎** | 任意语言任意形态 | 实现本 SDK 第 1 节的 5 件事即可 |

> 这些实现都只是"支持 THP 协议的用户自制软件"，与 ThirdHub 官方无隶属关系。

## 6. 自测清单（对齐 thp-check）

- [ ] `curl http://127.0.0.1:<port>/thp/meta` 返回合法信封，protocol = "THP/1.0"，含 instanceId/role/caps/auth
- [ ] `curl -X POST .../thp/m/novel/search -d '{"q":"测试","limit":20,"cursor":""}'` 返回 `{ok:true,data:[...],meta:{cursor,hasMore}}`
- [ ] toc → content 链路可用，content 结构符合模块注册表
- [ ] 未知路径返回 404 + `{ok:false,error:{code:"NOT_FOUND"}}`
- [ ] UDP 19527 能抓到 `THP/1 HELLO <port> <iid> engine m:novel <名称>`；退出时发 BYE
- [ ] 注入未知字段不报错；响应中携带的未知字段被调用方忽略
- [ ] 前端「引擎直连」可见你声明的引擎名，可搜索、可阅读/播放
