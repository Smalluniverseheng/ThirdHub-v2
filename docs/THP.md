# THP — ThirdHub 通用引擎协议 v1

THP（ThirdHub Protocol）是 ThirdHub 后端与内容引擎之间的开放协议。
**任何开发者都可以按本协议实现自己的引擎**（小说/漫画/视频/音乐/直播…），后端会自动发现、自动接入、多引擎并行调用。

## 设计原则

1. **引擎匿名**：引擎不知道、也不需要知道 ThirdHub 账号体系；无身份验证、无配对密钥
2. **引擎无状态**：引擎只做"规则解析 + 数据抓取"，不存用户数据
3. **后端即资源库**：后端负责存储（书架/本地书籍/缓存），搜索时并发调用所有在线引擎，把结果归一化后给前端
4. **前端是播放器**：前端只跟后端通信，永远感知不到"源"的存在

## 一、局域网自动发现（UDP 广播）

引擎启动后，每 30 秒向局域网广播一次 UDP 报文（端口 **19527**）：

```
THP/1 HELLO <http_port> <caps>
例: THP/1 HELLO 1122 novel,comic,audio
```

后端监听 19527，收到 HELLO 即把引擎加入在线引擎表（90 秒无心跳自动下线）。
**引擎不需要知道后端的地址**，后端也不需要知道引擎的地址——广播即连接。

## 二、HTTP 接口（引擎实现）

引擎在广播的 `<http_port>` 上提供以下 REST 接口，全部 GET，JSON 响应：

### `GET /thp/meta`
```json
{ "protocol": "THP/1", "name": "我的引擎", "version": "1.0.0",
  "caps": ["novel", "comic"], "vendor": "your-name" }
```

### `GET /thp/search?type=novel&q=关键词`
```json
{ "items": [
  { "id": "书籍唯一ID或URL", "name": "书名", "author": "作者",
    "coverUrl": "封面", "intro": "简介", "type": "novel|comic|video|music|audio" }
]}
```

### `GET /thp/chapters?type=novel&id=书籍ID`
```json
{ "items": [ { "name": "第1章", "url": "章节地址", "index": 0 } ] }
```

### `GET /thp/content?type=novel&id=书籍ID&chapter=章节地址`
按类型返回：
```json
// 小说
{ "type": "text", "text": "正文…" }
// 漫画
{ "type": "images", "pages": ["https://…/1.jpg", "…"] }
// 视频
{ "type": "video", "url": "https://…/play.m3u8", "headers": {} }
// 音乐/音频
{ "type": "audio", "url": "https://…/a.mp3", "lyric": "[00:00]…" }
```

错误统一：`{ "error": "描述" }`（HTTP 200 即可，后端按 error 字段判断）。

## 三、后端行为（对引擎透明）

- 后端把多个同类型引擎**并发调用、结果聚合去重**（两个小说引擎同时搜，结果合并）
- 前端把书加入书架 → 后端自动通过引擎把全书章节缓存到本地库
- 无引擎在线时，搜索自动回落到后端本地书库
- 响应体可选加密（见下），引擎侧不感知

## 四、传输加密（前端⇄后端，与引擎无关）

默认**不加密**（局域网信任）。用户可在前端 设置→系统 选择：
- `none`（默认）
- `aes-gcm`：AES-256-GCM，密钥=配对 secret，请求头 `X-TH-Enc: aes-gcm`，body 为 base64(nonce‖cipher‖tag)
- TLS：后端本身即 HTTPS（自签证书，指纹随配对分发）

## 五、现有引擎适配

| 引擎 | 适配方式 |
|---|---|
| 阅读引擎（Legado） | 后端内置适配器：THP ⇄ Legado Web API |
| 落雪音乐 | 后端内置 LX 沙箱（engine-lx.js） |
| TVBox | 后端内置适配器（engine-tvbox.js，CMS/drpy 类） |
| 你的引擎 | 按本协议实现 4 个接口 + UDP 心跳即可 |

---

# THP v2（2026-09 补充）：统一通信信封

v2 把「前端⇄后端」「后端⇄引擎」「前端⇄引擎」三条链路统一成**同一套格式**（类似 OpenAI API 成为行业标准）：任何一端只实现一次，即可与所有角色互通。

## 1. 统一响应信封

所有端点（无论资源库还是引擎）返回同一信封：

```json
{
  "object": "list | item | error",
  "data":  ...,
  "meta": { "source": "engine-id 或 library", "latency": 123, "caps": ["novel"] }
}
```

错误统一：`{"object":"error","data":{"message":"...","code":"UPSTREAM_FAIL"}}`

## 2. 统一发现

- 引擎广播：`THP/1 HELLO <port> <caps>`（caps 如 `novel,comic`）
- 资源库广播：`THP/1 HELLO <port> library,novel,comic,video,music`（caps 必含 `library`）
- 前端与后端都监听 UDP 19527：识别到 `library` = 可连接的资源库；否则 = 引擎
- 前端在局域网内可**直接把引擎当资源库用**（同一套 REST 端点，见 v1 第二节）

## 3. 统一端点（三类角色全支持）

| 端点 | 资源库 | 引擎 | 说明 |
|---|---|---|---|
| GET /thp/meta | ✅ | ✅ | 身份与能力（匿名） |
| GET /thp/search?type=&q= | ✅ | ✅ | type: novel/comic/video/music |
| GET /thp/chapters?type=&id= | ✅ | ✅ | 目录/选集 |
| GET /thp/content?type=&id= | ✅ | ✅ | 正文/图片列表/播放地址/音频地址 |

资源库额外提供（引擎不需要）：`/v1/library`（本地库）、`/v1/shelf/add`（书架双写自动下载）。

## 4. 数据类型归一

`content` 的 `data` 按 type 归一，前端零分支：

| type | data 结构 |
|---|---|
| novel | `{ "text": "..." }` |
| comic | `{ "images": ["url", ...] }` |
| video | `{ "url": "m3u8/mp4", "header": {} }` |
| music | `{ "url": "...", "lyric": "..." }` |

## 5. 认证

- 引擎：**无认证**（局域网匿名，外观上与任何后端无关）
- 资源库：配对 secret（`X-TH-Token`），指纹随配对展示给用户确认
- 加密：见 v1 第四节（none 默认 / aes-gcm / TLS）
