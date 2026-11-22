# ThirdHub 桌面引擎

把**网页素材**转成**标准格式成品**，再交给手机端当成本地文件用的自建服务。

跑在你自己的电脑或 NAS 容器里，不上架、不对公网开放。

```
        桌面端（这个服务）                         移动端（ThirdHub App）
  ┌──────────────────────────────┐          ┌──────────────────────────┐
  │  下单：一组 URL + 标题         │          │  配对：地址 + 令牌         │
  │        ↓                     │          │        ↓                 │
  │  抓取（限并发 / 限量 / 防 SSRF）│          │  轮询任务进度             │
  │        ↓                     │          │        ↓                 │
  │  转标准格式                    │          │  取签名链接               │
  │   EPUB / CBZ / MP3 / MP4     │  ──────▶ │        ↓                 │
  │        ↓                     │  局域网   │  下载并落到本地库          │
  │  成品库 + HMAC 交付链接        │          │  （之后就是普通本地文件）   │
  └──────────────────────────────┘          └──────────────────────────┘
```

## 为什么拆成两端

| | 移动端 | 桌面端 |
| --- | --- | --- |
| 分发方式 | 要上架 / 要公开 | 自建、不上架 |
| 允许的内容来源 | 公有领域、开放许可、官方公开 API、自有内容 | 额外允许用户自行承担责任的抓取 |
| 是否含抓取代码 | **不含**（编译产物里没有） | 是 |
| 出问题谁负责 | 平台与开发者 | 部署者本人 |

所以「移动端全合规」不是一句免责声明，而是**代码层面的边界**：
`lib/core/free/free_policy.dart` 里的 `LicenseKind` 决定了哪些源能进移动端构建，
`tool/free_policy_selfcheck.dart` 在 CI 里盯着这条线。

## 快速开始

```bash
# ① 起服务（首次会生成访问令牌）
docker compose up -d
cat ./data/token          # 把这串填进 App 的「桌面引擎」页

# ② 看看活着没有
curl -s http://127.0.0.1:8421/v1/health | jq

# ③ 下一单：把一个公版网页转成 EPUB
curl -s -X POST http://127.0.0.1:8421/v1/tasks \
  -H "x-th-token: $(cat ./data/token)" \
  -H 'content-type: application/json' \
  -d '{
    "kind": "book",
    "title": "论语·学而",
    "author": "孔子",
    "origin": "https://ctext.org/analects/xue-er/zh",
    "chapters": [
      {"title": "学而第一", "url": "https://ctext.org/analects/xue-er/zh"}
    ]
  }'
# → {"id":"t-...","state":"queued","total":1}

# ④ 看进度 → 取链接 → 下载
curl -s http://127.0.0.1:8421/v1/tasks -H "x-th-token: $(cat ./data/token)" | jq '.tasks[0]'
curl -s -X POST http://127.0.0.1:8421/v1/handoff/lib-xxxx -H "x-th-token: $(cat ./data/token)" | jq
curl -OJ "$(上面的 url)"
```

浏览器打开 `http://<你的机器>:8421/` 还有一个成品库网页，看得见每件成品的格式、大小、生成时间。

## 接口

除 `GET /v1/health` 外，全部需要请求头 `x-th-token: <令牌>`。
交付链接 `/h/<token>` 走自包含 HMAC 签名，**不需要**令牌（手机端点链接就能下）。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/v1/health` | 探活。返回形态、版本、支持的类型与格式、队列状态 |
| POST | `/v1/tasks` | 下单。`kind` ∈ `book` / `comic` / `audio` / `video` |
| GET | `/v1/tasks` | 最近 60 条任务（含 `state` / `done` / `total` / `error`） |
| GET | `/v1/lib` | 成品列表 |
| POST | `/v1/handoff/:id` | 签发交付链接。默认 10 分钟有效 |
| GET | `/h/<token>` | 下载成品。支持 `Range` 断点续传 |
| DELETE | `/v1/lib/:id` | 删除成品（索引与文件一起删） |

### 下单参数

```jsonc
{
  "kind": "book",            // book | comic | audio | video
  "title": "书名",
  "author": "作者",           // 可选
  "language": "zh-CN",       // 可选，进 EPUB 的 dc:language
  "cover": "https://...",    // 可选，封面图地址
  "referer": "https://...",  // 可选，抓取时带的 Referer（有些站需要）
  "origin": "https://...",   // 建议填：成品元数据里留档，日后可追溯
  "note": "来源说明",         // 可选

  "chapters": [{"title": "第一章", "url": "https://..."}],  // book：正文页，会提取纯文本
  "pages":    ["https://.../001.jpg"],                     // comic：按顺序的图片
  "tracks":   [{"title": "曲名", "url": "https://...mp3"}], // audio：音轨
  "video":    "https://.../v.mp4"                          // video：单文件
}
```

### 产出格式

| kind | 产出 | 说明 |
| --- | --- | --- |
| `book` | `.epub` | EPUB 3.3：`mimetype` 首位不压缩、`container.xml`、`content.opf`、`nav.xhtml` + `toc.ncx` 双目录 |
| `comic` | `.cbz` | 页图定宽命名（`0001.jpg`）+ `ComicInfo.xml`，阅读器按名排页不会乱 |
| `audio` | `.zip` | 原格式保留（**不转码**）+ `playlist.m3u` |
| `video` | `.mp4` | 原样保留，不转码 |

不转码是刻意的：在这个链路上转码只带来二次损失和 CPU 占用，手机端解码能力足够。

## 安全

| 面 | 做法 |
| --- | --- |
| 鉴权 | `/v1/*` 全部要 `x-th-token`，定长比较（`timingSafeEqual`） |
| 交付链接 | HMAC-SHA256 自包含令牌，默认 600 秒过期；路径里只有令牌，不含文件名 → 无路径穿越 |
| SSRF | 只允许 http/https；**每一跳重定向都重新解析并拒绝内网/回环/链路本地/CGNAT 地址**；域名先 `dns.lookup` 全部 A/AAAA 记录再逐个判定 |
| 资源上限 | 单文件 24MB、单任务 400 项、抓取并发 3、整体超时 25s |
| 落盘 | 先写 `.part` 再 `rename`，永远不会留下半个文件让手机端拉到 |
| 运行身份 | 容器内以 `node` 用户跑，不是 root |
| 暴露面 | `docker-compose.yml` 只映射到宿主机，**不要**把 8421 直接开到公网 |

> 跨网段用法：走 WireGuard / Tailscale，别做端口转发。这个服务的接口能替你访问外网任意地址，
> 公开出去等于送人一个开放代理。

## 配置

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `TH_PORT` | `8421` | 监听端口 |
| `TH_BIND` | `0.0.0.0` | 监听地址（容器内保持 0.0.0.0，靠端口映射收窄） |
| `TH_DEVICE_NAME` | `ThirdHub 桌面引擎` | 手机端配对时显示的设备名 |
| `TH_DATA_DIR` | `/data` | 数据目录（成品库、令牌、任务记录） |
| `TH_DESKTOP_TOKEN` | 自动生成 | 固定访问令牌；留空则首次启动生成并写入 `$TH_DATA_DIR/token` |
| `TH_HANDOFF_SECRET` | 自动生成 | 交付链接签名密钥，写入 `$TH_DATA_DIR/handoff.key` |
| `TH_HANDOFF_TTL` | `600` | 交付链接有效期（秒） |
| `TH_MAX_FETCH_BYTES` | `25165824` | 单文件抓取上限 |
| `TH_FETCH_CONCURRENCY` | `3` | 任务内抓取并发 |
| `TH_MAX_ITEMS` | `400` | 单任务最多抓多少项 |

## 自检

```bash
node test/smoke.cjs            # 全量：转换内核 + 令牌 + 真起服务端到端（需外网）
node test/smoke.cjs --offline  # 无外网：只跑转换内核 + 令牌 + 鉴权
```

`smoke.cjs` 会真起一个服务、真抓一个公网页面、真下载回来校验字节数和 EPUB 首条目，
不是只跑纯函数。SSRF 那条会验证「内网地址被拦在抓取层，而不是碰巧失败」。

## 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| App 连不上 | 端口没映射 / 防火墙 | `curl http://<ip>:8421/v1/health` 先确认 |
| 401 | 令牌不对 | `cat ./data/token`，或设 `TH_DESKTOP_TOKEN` 固定下来 |
| 任务 `failed` 且 `error` 含「拒绝访问内网地址」 | SSRF 防护生效 | 目标是内网服务，本服务不代理内网 |
| 任务 `failed` 且 `error` 含「HTTP 403」 | 目标站要 Referer / 反爬 | 下单时带 `referer` 字段 |
| 下载中断 | 链接过期（10 分钟） | 在 App 里重新发起接收 |
| EPUB 在阅读器里打不开 | 章节全是「抓取失败」 | 说明源站拦了，成品是空壳，删掉重下 |

## 目录

```
desktop/
├── Dockerfile
├── docker-compose.yml
├── package.json            零第三方依赖
├── src/
│   ├── server.js           HTTP、鉴权、交付链接、首页
│   ├── pipeline.js         任务执行：抓取 → 转换 → 落库
│   ├── net.js              取件（SSRF 防护）+ HTML 取正文
│   ├── epub.js             EPUB 3 生成器
│   ├── convert.js          CBZ / 音频集合 / 视频
│   ├── zip.js              极简 ZIP 写入（CRC32 + deflate）
│   ├── sign.js             HMAC 交付令牌
│   └── store.js            成品库与任务持久化
└── test/smoke.cjs          18 项冒烟（含端到端）
```
