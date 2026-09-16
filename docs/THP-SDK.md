# ThirdHub 引擎 SDK（THP-SDK v1）

> 让任何内容引擎 **5 分钟接入 ThirdHub**：接入方只需要实现本 SDK 描述的引擎侧，
> 前端 App 与后端资源库 **零改动** 自动发现、自动接入、自动聚合。
>
> 协议细节见 [THP.md](THP.md)；本文档是面向引擎开发者的 SDK 使用手册。

## 1. SDK 是什么

THP-SDK 不是一个大依赖库，而是 **一份契约 + 一个最小参考实现**：

```
引擎开发者要做的事（一共 4 件）：
  ① 每 5~30 秒广播一次 UDP HELLO（端口 19527）
  ② 起 1 个 HTTP 服务，实现 4 个 GET 端点（/thp/meta /thp/search /thp/chapters /thp/content）
  ③ 按类型返回归一化 JSON（novel/comic/video/music/audio）
  ④ 遵守前向兼容规则（未知字段忽略、新能力加 caps）
```

前端/后端 **永远不需要为某个引擎改代码**：

- 后端监听 UDP 19527，收到 HELLO 即把引擎加入在线表，搜索时并发调用所有引擎、聚合去重；
- 前端只跟后端（或局域网内的引擎直链）通信，渲染层按 `type` 走统一的播放器/阅读器，新类型自动落入「更多能力」。

## 2. 快速开始（Node.js 参考实现，30 行）

```js
// my-engine.js —— 一个最小可运行的小说引擎
const http = require('http');
const dgram = require('dgram');

const PORT = 12001;                       // 引擎 HTTP 端口（任意空闲端口）
const CAPS = 'novel';                     // 能力: novel,comic,video,music,audio,live,discover

// ① UDP 心跳广播（前端与后端都在监听 19527）
const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
sock.bind(() => {
  sock.setBroadcast(true);
  setInterval(() => sock.send(`THP/1 HELLO ${PORT} ${CAPS}`, 19527, '255.255.255.255'), 5000);
});

// ② HTTP 接口
http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const send = (o) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(o)); };

  if (u.pathname === '/thp/meta')
    return send({ protocol: 'THP/1.1', name: '我的引擎', version: '1.0.0', caps: CAPS.split(','), vendor: 'me' });

  if (u.pathname === '/thp/search')
    return send({ object: 'list', data: [        // 统一信封（THP v2）
      { id: 'https://site/book/1', name: '示例书', author: '作者', coverUrl: '', intro: '', type: 'novel' },
    ], meta: { source: 'my-engine' } });

  if (u.pathname === '/thp/chapters')
    return send({ object: 'list', data: [ { name: '第1章', url: 'https://site/book/1/c1', index: 0 } ] });

  if (u.pathname === '/thp/content')
    return send({ object: 'item', data: { text: '正文……' } });   // novel 归一结构

  send({ object: 'error', data: { message: 'unknown endpoint', code: 'NOT_FOUND' } });
}).listen(PORT);
```

启动后：打开 ThirdHub 前端 → 我的 → 引擎直连，即可看到「我的引擎」；连上后端资源库则自动参与全端搜索聚合。

## 3. 引擎生命周期

```
启动 ──▶ 广播 HELLO(5~30s/次) ──▶ 被后端/前端发现 ──▶ 接收调用(search/chapters/content)
 │                                                    │
 └──▶ 90 秒无心跳 = 自动下线（无需注销消息） ◀── 停止广播/进程退出
```

- **无注册、无审核、无配对**：广播即接入；
- **匿名**：引擎不知道 ThirdHub 账号体系，也不应索取任何用户凭据；
- **无状态**：引擎只做「规则解析 + 抓取」，用户数据（书架/进度/缓存）全部在资源库。

## 4. 能力声明（caps）

| cap | 含义 | content 归一结构 |
|---|---|---|
| `novel` | 小说/文字 | `{ "text": "..." }` |
| `comic` | 漫画/图片 | `{ "images": ["url", ...] }` |
| `video` | 影视 | `{ "url": "m3u8/mp4", "header": {} }` |
| `music` | 音乐 | `{ "url": "...", "lyric": "LRC 文本（可选）" }` |
| `audio` | 有声/听书 | 同 music |
| `live` | 直播流 | `{ "url": "m3u8" }` |
| `discover` | 支持可选端点 `/thp/discover`（发现页/榜单） | — |

**新型内容（如 game、rss、播客）= 直接广播新 cap 即可接入**，前后端无需改协议：
未知 cap 被展示为「更多能力」，未知 content.type 在前端显示「暂不支持预览，可浏览器打开」。

## 5. 规约（所有实现必须遵守）

1. **统一信封**：`{ object: "list|item|error", data, meta }`；错误 `{"object":"error","data":{"message","code"}}`，code 建议 `UPSTREAM_FAIL / NOT_FOUND / UNSUPPORTED / RATE_LIMIT`；
2. **未知字段容忍**：收到不认识的字段原样忽略，不报错；
3. **次版本只增不减**：`/thp/meta` 返回 `protocol: "THP/1.x"`，调用方按主版本 `THP/1` 判兼容；
4. **可选端点**：除 meta/search/chapters/content 外全部可选，404 或 error 时调用方自行降级；
5. **超时友好**：单端点响应建议 ≤ 15s；后端聚合调用超时自动放弃该引擎，不影响其他引擎；
6. **传输加密与引擎无关**：加密（none / aes-gcm / TLS）只发生在前端⇄后端之间，引擎侧永远明文 HTTP、不感知。

## 6. 与现有引擎的关系

| 引擎 | 形态 | 接入方式 |
|---|---|---|
| ThirdHub 阅读引擎（Legado 底仓） | 独立 App（com.thirdhub.legado） | THP 广播 + /thp/* |
| ThirdHub 漫画引擎（venera） | 独立 App（com.thirdhub.venera，内嵌 Node + vm 沙箱） | THP 广播 + /thp/* + /thp/sources 图源管理 |
| 落雪音乐 / TVBox | 后端内置适配器 | 后端进程内沙箱 |
| **你的引擎** | 任意语言任意形态 | 实现本 SDK 第 1 节的 4 件事 |

## 7. 自测清单

- [ ] `curl "http://127.0.0.1:<port>/thp/meta"` 返回 protocol/name/version/caps
- [ ] `curl ".../thp/search?type=novel&q=测试"` 返回统一信封 list
- [ ] chapters → content 链路可用，type 归一结构正确
- [ ] 错误路径返回 `object:"error"` 而不是 HTTP 500 页面
- [ ] UDP 19527 能抓到 `THP/1 HELLO <port> <caps>` 广播
- [ ] 前端「引擎直连」可见、可搜索、可阅读/播放
