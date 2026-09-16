# THP — ThirdHub Protocol v1.0 正式规范

定版日期：2026-09-16 · 状态：**主版本冻结，此后只增不减**
本文档是 THP 生态的单一事实来源。任何实现（前端/资源库/引擎/第三方）以本文档为准。

## 目录

1. 概述与设计原则
2. 角色模型
3. 统一信封与 HTTP 语义
4. 发现层
5. 认证与安全分层（L0–L3）
6. 模块命名空间
7. 端点规范
8. 分页与游标
9. ID 模型
10. 错误码注册表
11. caps 注册表
12. ext 扩展字段（协议保险丝）
13. 第三方商业引擎与身份层（L3）
14. 非功能性要求
15. 兼容性军规（只增不减）
16. thp-check 一致性测试
17. 法律防火墙与引擎行为准则
18. AI 控制平面

## 1. 概述与设计原则

THP（ThirdHub Protocol）是 ThirdHub 生态中"peer（对等进程）"之间的开放协议。任何开发者按本协议实现的引擎或资源库，可被 ThirdHub 前端/后端自动发现、自动调用，**无注册、无审核**。

**五条铁律：**

1. **前端 = 纯播放器**：零源、零规则、零解析逻辑，只处理归一化后的纯格式（MP3/EPUB/TXT/JPG/MP4…）
2. **资源库 = 纯数据中心**：只存用户自己的数据，可聚合引擎，可写入
3. **引擎 = 无状态转换器**：只做"规则解析 + 数据抓取"，不存用户数据，输出纯格式
4. **下载 = 导入**：用户点"下载"得到的纯文件，与"本地导入"走同一条入库路径，到库后一视同仁
5. **协议只增不减**：见第15节军规

## 2. 角色模型

每个 peer 通过 /thp/meta 声明自己的角色：

| 角色 | 职责 | 状态 | 读写 |
| --- | --- | --- | --- |
| engine | 外部世界 → 纯格式的无状态转换器 | 无状态 | **只读** |
| library | 用户私有数据中心（存储/备份/同步/聚合） | 有状态 | 读 + 写 |

**核心公理：library 是 engine 能力的超集。** library 必须实现 engine 的全部读端点（其 search = 在线引擎并发结果 ∪ 本地库）。因此"前端直连引擎"与"前端直连资源库"走**完全相同的代码路径**。

**硬约束：engine 禁止实现任何写端点。** 后端发现 engine 角色实现了写端点，应在管理界面告警（这是法律防火墙的机器可检版本）。

## 3. 统一信封与 HTTP 语义

### 3.1 信封（唯一的两种形态）

所有 JSON 响应必须是以下两种信封之一，**禁止任何裸 JSON 响应**：

成功：

```json
{
  "ok": true,
  "data": {},
  "meta": {}
}
```

失败：

```json
{
  "ok": false,
  "error": { "code": "NOT_FOUND", "message": "人类可读描述", "upstream": "可选：上游原始错误" }
}
```

- data：list 类型时为数组，item 类型时为对象
- meta：见 3.3；无分页信息时可为 {}
- 每个响应带响应头 X-TH-Request-Id（调用方生成、peer 原样回显，用于日志追踪）

### 3.2 HTTP 状态码（恢复正常语义）

| 状态码 | 场景 |
| --- | --- |
| 200 | 成功（含业务空结果，如搜索无命中 → ok:true, data:[]） |
| 400 | 参数错误（缺参数、cursor 非法等） |
| 404 | 模块未声明、端点不存在、资源不存在 |
| 405 | 方法不允许 |
| 429 | 限流 |
| 5xx | peer 内部错误 |

body 信封与状态码不得矛盾。**失败判断唯一依据：ok:false**，状态码仅供传输层重试决策。

### 3.3 meta 标准字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| source | string | 产生数据的 peer 的 instanceId 或 "library" |
| latency | number | 毫秒，可选 |
| cursor / hasMore / total | — | 分页三件套，见第8节 |
| deprecated | string[] | 该 peer 即将停止返回的字段，格式 "字段名@起始版本" |
| ext | object | 扩展出口，见第12节 |

## 4. 发现层

### 4.1 UDP 广播（必选）

peer 启动后每 30 秒（可调，范围 10–300s）向局域网广播：

```
THP/1 HELLO <httpPort> <instanceId> <role> <caps> [name]
例: THP/1 HELLO 1122 f47ac10b-58cc-4372-5675-e69b059e7f3c engine m:novel,m:comic 阅读引擎
```

| 字段 | 说明 |
| --- | --- |
| instanceId | UUID，**重启不变**。同一 instanceId 多次报文去重，后到覆盖 |
| role | engine / library |
| caps | 逗号分隔，见第11节；含模块能力（m:xxx） |
| name | 可选，人类可读显示名 |

优雅下线（必选）：

```
THP/1 BYE <instanceId>
```

超时剔除：收到 HELLO 后 ttl = 3 × 该 peer 最后声明的广播间隔，非固定值。引擎休眠唤醒后**立即重播 HELLO**，不等下个周期。

### 4.2 mDNS（必选）

- 服务类型：`_thp._tcp.local.`
- TXT 记录键：port、iid（instanceId）、role、caps、name
- **双通道互备**：UDP 与 mDNS 至少实现其一，官方实现两者全开；IPv6 环境 mDNS 必选（UDP 广播无 v6 语义）

### 4.3 中继/远程发现（可选）

peer 不在同一局域网时，由第三方发现通道（如云目录、用户手动填写 URL）提供 endpoint。协议层不规定中继实现，但经中继的连接必须满足第5节的加密要求。meta 声明：

```json
{ "remote": true, "endpoint": "https://api.example.com/thp" }
```

## 5. 认证与安全分层（L0–L3）

| 层 | 机制 | 身份 | 适用 |
| --- | --- | --- | --- |
| **L0** | 无（默认） | 不知道也不关心 | 局域网引擎 |
| **L1** | 配对 token：X-TH-Token | 不知道 | 用户自托管远程 peer |
| **L2** | 自签 TLS + 指纹确认 | 不知道 | 高安全场景 |
| **L3** | 持有证明（Proof-of-Possession） | **知道账号标识** | 第三方商业引擎，见第13节 |

规则：

- meta 的 auth 数组声明本 peer 支持的层，如 ["none","token","tls"]
- 调用方自动协商双方都支持的最高层
- 引擎同时广播多层能力，按场景启用；**匿名性（L0）对任何引擎永远可用，不得移除**
- remote:true 的 peer 必须 TLS，且不支持 none
- 广域网（非 RFC1918）连接时，前端必须弹安全提示
- 可选传输加密（peer 之间，与发现无关）：`X-TH-Enc: aes-gcm`，AES-256-GCM，密钥 = 配对 secret，body = base64(nonce‖cipher‖tag)；默认不加密（局域网信任）

## 6. 模块命名空间

**内容类型不再是查询参数，而是路径中的模块。** 统一端点模板：

```
/thp/m/{module}/search   搜索/列表
/thp/m/{module}/toc      目录/结构（书的章节、歌单、相册文件夹）
/thp/m/{module}/content  内容本体
/thp/m/{module}/extra    附属资源（歌词/字幕/缩略图），可选
```

### 6.1 模块注册表 v1

| 模块 | 实现方 | data 结构 | 说明 |
| --- | --- | --- | --- |
| novel | engine | { "text": "..." } | 正文 |
| comic | engine | { "images": ["url", ...] } | 图片列表 |
| video | engine | { "url": "m3u8/mp4", "header": {}, "variants": [{"quality","url"}] } | 播放地址 |
| music | engine | { "url": "...", "variants": [...] } | 音频地址 |
| live | engine | { "url": "...", "header": {} } | 直播流 |
| audiobook | engine | { "url", "duration", "index" } | 有声书分集 |
| podcast | engine | { "url", "duration", "pubDate", "shownotes" } | 播客单集 |
| article | engine | { "title", "text", "pubDate", "images": [] } | 资讯/文章 |
| shortplay | engine | { "url", "duration", "index" } | 短剧分集 |
| album | library | blob + 元数据 | 相册 |
| file | library | blob + 元数据 | 文件 |
| note | library | { "title", "text", "tags": [] } | 笔记 |
| todo | library | { "task", "done", "due", "priority" } | 待办 |
| bookmark | library | { "url", "title", "folder" } | 书签 |
| feed | engine/library | 同 article | 订阅源 |

- 引擎在 caps 声明 m:novel,m:comic；library 声明 m:library,m:album,m:note,...
- **未知模块一律忽略**；调用未知模块返回 404
- content 的未知类型：前端显示"该类型暂不支持预览"并允许用浏览器打开原始地址
- 新增模块只追加进本表，不改已有行

## 7. 端点规范

### 7.1 端点完备性矩阵

| 端点 | engine | library | 级别 |
| --- | --- | --- | --- |
| GET /thp/meta | ✅ | ✅ | 必选 |
| /thp/m/{cap}/search toc content | 按 caps | ✅（本地库+聚合） | 必选 |
| GET /thp/m/{module}/extra | 可选 | 可选 | 可选 |
| POST /thp/m/{module}/content:batch | 可选 | 可选 | 可选 |
| /thp/jobs/* | 可选 | 可选 | 可选 |
| GET /thp/events（SSE） | 可选 | 可选 | 可选 |
| GET /thp/changes | ❌ | ✅ | library 必选 |
| POST /thp/m/{module}/items 等写路径 | ❌ | ✅ | library 必选 |
| /thp/blob/* | ❌ | ✅ | library 必选 |
| GET /thp/tools | 可选 | 可选 | 可选 |
| POST /thp/agent | ❌ | ✅（Agent作业，见18.6b） | library 可选 |

**降级链必须成文**：每个可选端点在本文档中写明调用方收到 404 / ok:false 时的标准降级行为。

### 7.2 GET /thp/meta

```json
{
  "ok": true,
  "data": {
    "protocol": "THP/1.0",
    "instanceId": "f47ac10b-...",
    "role": "engine",
    "name": "阅读引擎",
    "version": "1.0.0",
    "vendor": "your-name",
    "caps": ["m:novel", "m:comic", "batch-content", "tools"],
    "auth": ["none", "token"],
    "remote": false,
    "endpoints": ["search", "toc", "content", "extra"],
    "deprecated": [],
    "ext": {}
  }
}
```

### 7.3 搜索 / 目录 / 内容

```
POST /thp/m/novel/search
{ "q": "关键词", "limit": 20, "cursor": "" }
→ data: [{ "id", "name", "author", "coverUrl", "intro", "ref" }]

POST /thp/m/novel/toc
{ "id": "xxx", "cursor": "" }
→ data: [{ "id", "name", "index" }]

POST /thp/m/novel/content
{ "id": "xxx", "chapterId": "yyy" }
→ data: { "text": "正文…" }
```

- 引擎可只实现 GET 版（?q=&cursor=）；caps 声明 post-query 表示支持 POST
- 调用方策略：**优先 POST，404/UNSUPPORTED 回落 GET**
- ref：资源的原始 URL，仅供调试/浏览器兜底，**禁止当 ID 使用**

### 7.4 GET /thp/m/{module}/extra

```
GET /thp/m/music/extra?id=xxx&what=lyric
GET /thp/m/video/extra?id=xxx&what=subtitle&lang=zh
→ data: { "format": "lrc|srt|vtt", "text": "..." }
```

不支持 → 404，调用方降级为"无歌词/字幕"。

### 7.5 POST /thp/m/{module}/content:batch（可选，caps: batch-content）

请求：`{ "id": "xxx", "items": ["id1","id2",...] }`

响应：**NDJSON 流**（Content-Type: application/x-ndjson），每行一个信封，单章失败不影响整批：

```
{"ok":true,"data":{"item":"id1","text":"..."},"meta":{"source":"..."}}
{"ok":false,"error":{"code":"UPSTREAM_FAIL","message":"..."},"meta":{"source":"..."}}
```

### 7.6 /thp/jobs（可选，caps: jobs）

```
POST /thp/jobs → { "jobId": "j1", "status": "queued" }
GET /thp/jobs/{id} → { "status": "running", "progress": 0.42, "result": null }
DELETE /thp/jobs/{id} → 取消
```

status 枚举：queued | running | waiting-confirm | paused | done | error | canceled。waiting-confirm 用于 Agent 作业遇 T3 确认而前端不在线（见18.6b）；paused 用于资源库重启后的断点续跑。用于离线下载、全书缓存、Agent 作业等异步任务。

### 7.7 GET /thp/events（可选，SSE，caps: events）

```
event: shelf.ready
data: {"bookId":"xxx","cached":120,"failed":2}

event: sync.cursor
data: {"module":"note","cursor":"2026-09-16T14:00:00Z"}
```

- 前端订阅后：缓存完成通知、相册同步进度、**其他设备写入后本端即时刷新**
- 未实现 → 前端回落轮询（含 /thp/changes），协议不强迫

### 7.8 GET /thp/changes（library 必选）——同步三件套

```
GET /thp/changes?module=note&cursor=<opaque>&limit=500
→ {
  "ok": true,
  "data": [
    { "op": "upsert", "id": "n1", "item": {...}, "hash": "...", "ts": "2026-09-16T14:00:00Z" },
    { "op": "delete", "id": "n2", "ts": "2026-09-16T14:05:00Z" }
  ],
  "meta": { "cursor": "abc123", "hasMore": true }
}
```

- cursor 为不透明字符串，**必须单调**（允许跳变，不允许回退）
- 删除一律为 tombstone（软删记录，含 ts）
- 所有 library 条目带 hash（内容寻址）与 ts（ISO 8601 UTC）
- 引擎无需实现（无状态）

### 7.9 library 写路径（library 必选）

```
POST   /thp/m/{module}/items        新建条目
PUT    /thp/m/{module}/items/{id}   更新
DELETE /thp/m/{module}/items/{id}   删除（软删）
GET    /thp/m/{module}/items/{id}   读取
```

### 7.10 /thp/blob（library 必选）——文件传输

```
POST /thp/blob { "sha256": "...", "size": 12345, "mime": "image/jpeg" }
→ 命中已有 → { "id": "b1", "dedup": true }（秒传）
→ 未命中 → { "id": "b1", "chunks": 3, "chunkSize": 8388608 }
POST /thp/blob/{id}/chunks/{n}   上传分块（8MB，失败整块重传）
GET  /thp/blob/{id}              下载（支持 HTTP Range）
```

- **blob 与条目分离**：文件是文件，元数据是元数据
- 分块大小可配，由创建响应的元数据声明

### 7.11 GET /thp/tools（可选，caps: tools）——AI 工具发现

```json
{
  "ok": true,
  "data": [
    { "name": "refresh_rule", "description": "更新书源规则",
      "params": { "type": "object", "properties": {} }, "module": "novel" }
  ]
}
```

前端 Harness 启动时扫描所有在线 peer 的 tools → AI 自动获得引擎暴露的能力，无需硬编码。

**前端各模块也按同一套 schema 在本地注册功能工具（见第18章）——本地工具表与远程工具表合并为同一张 function-calling 表，AI 不区分被控对象是前端、后端还是引擎。**

## 8. 分页与游标

- **cursor 分页，不用 page**：源站翻页漂移/聚合场景下 page 会错位
- 请求：limit（默认 20，最大 100，超限自动截断不报错）+ cursor（首轮为空串）
- 响应 meta：cursor（下轮游标，空串表示没有更多）+ hasMore + total（可为 null，调用方只依赖 hasMore）
- cursor 为不透明字符串：时间戳/offset/哈希均可，实现方自定

## 9. ID 模型

- search/toc 返回的 id：**不透明字符串，peer-local，仅在该 peer 内有效**
- 禁止把 URL 当 ID（URL 放 ref 字段）
- 前端缓存主键 = { instanceId, module, id } 三元组
- 跨 peer 的引用（如书签指向某引擎的书）必须记录 {instanceId, module, id} 全量

## 10. 错误码注册表

调用方**只依赖 ok:false 判断失败**；code 用于 UI 展示与标准降级。

| code | 场景 | 标准降级行为 |
| --- | --- | --- |
| UPSTREAM_FAIL | 上游站点失败 | 换引擎/重试 |
| NOT_FOUND | 资源不存在 | 提示+移除本地引用 |
| UNSUPPORTED | 不支持该操作/端点 | 回落替代方案 |
| RATE_LIMIT | 被限流 | 退避重试 |
| AUTH_REQUIRED | 缺少/过期凭证（L1/L3） | 前端弹登录/授权 |
| PAYMENT_REQUIRED | 非会员调付费功能 | 前端跳 meta.ext.paymentUrl |
| SOURCE_BANNED | 源站反爬/封 IP | 提示换源 |
| RULE_BROKEN | 解析规则失效 | 提示更新引擎规则 |
| TIMEOUT | 上游超时 | 重试 |
| PAYLOAD_TOO_LARGE | 超出上限 | 减小 limit/走 batch |
| CAP_UNAVAILABLE | caps 声明的能力实际不可用 | 视为 UNSUPPORTED |

自定义 code 允许；新 code 只追加进本表。

## 11. caps 注册表

| cap | 含义 |
| --- | --- |
| m:{module} | 支持某模块（如 m:novel） |
| post-query | search/toc/content 支持 POST |
| batch-content | 支持批量内容端点 |
| jobs | 支持异步任务 |
| events | 支持 SSE 推送 |
| tools | 支持 AI 工具发现 |
| library | 资源库身份声明（library 角色必含） |
| discover | 支持发现页（可选内容） |

规则：未知 caps 一律忽略并展示为"更多能力"；新 caps 只追加登记，防重名。

## 12. ext 扩展字段（协议保险丝）

信封 meta、meta 响应、每个 item 均可携带 `ext: {}`。**任何协议未预见的需求，一律走 ext，不动主干。**

官方约定示例（第三方引擎常用，将来可收编为标准）：

```json
"ext": {
  "paymentUrl": "https://example.com/vip",
  "loginHint": "需要ThirdHub账号验证",
  "identity": "thirdhub-pop"
}
```

## 13. 第三方商业引擎与身份层（L3）

### 13.1 定位

- 引擎开发者自己收款、自己存会员、自己判定；ThirdHub 云**只提供一台"验签机器"**，不存授权记录、不存引擎资料、不做会员判断
- 付费流程完全发生在引擎开发者与用户之间，ThirdHub 不经手钱

### 13.2 密钥基础设施

- 用户 App 首次使用：在系统安全区（Android Keystore / iOS Secure Enclave）生成非对称密钥对
- **私钥永不出设备，不可导出**
- 公钥上传至 ThirdHub 云，存于该账号资料（账号设置的一部分）
- 换机：新密钥对覆盖旧公钥，旧设备自动失效

### 13.3 证明（Attestation）

证明(JWT) = { sub: 账号标识, aud: 引擎client标识, nonce: 引擎生成的随机数, iat, exp(≤5分钟) } + 手机私钥签名

### 13.4 流程

**绑定（用户付费时）：**

1. 开发者网站生成 nonce 并显示二维码
2. 用户 App 扫码 → 确认弹窗（明确列出"将获得：账号标识；不会获得：密码、手机号、内容数据"）→ 生成证明
3. 开发者服务器调 POST /v2/verify（无状态端点）→ 云验证签名 → 返回 `{ "ok": true, "data": { "accountId": "xxx" } }`
4. 开发者确认"付款者真实握有该账号" → 自家库记录 {accountId: 会员, 到期}

**引擎启动验证：**

1. 引擎生成 nonce → 用户 App 确认 → 获得带 nonce 的新证明（5分钟有效）
2. 引擎发送给开发者服务器 → 调 /v2/verify → 得 accountId → 查自家会员表 → 放行或限制

### 13.5 安全性质

| 攻击 | 防御 |
| --- | --- |
| 会员分享身份码 | 码本身无用，无私钥签不出证明 |
| 证明被截获重放 | 5分钟过期 + nonce 一次一换 |
| 跨引擎串用证明 | aud 绑定引擎标识 |
| 多设备白嫖 | 开发者可自行限制同 accountId 并发数 |

### 13.6 云侧新增（仅此两项）

| 新增 | 性质 |
| --- | --- |
| POST /v2/verify | 无状态验签端点；不存证明、不存记录；对任何人开放调用 |
| 账号资料增加公钥字段 | 账号设置的一部分 |

**没有开发者注册、没有授权表、没有中继、没有内容数据。**

## 14. 非功能性要求

### 14.1 数值限制

| 项 | 值 |
| --- | --- |
| limit 默认 / 最大 | 20 / 100 |
| 单响应 body 建议上限 | 5MB（超限走 batch 流） |
| NDJSON 单行上限 | 1MB |
| blob 分块大小 | 8MB（可配，创建响应声明） |
| changes 单次返回 | ≤500 条 |
| HELLO 心跳间隔 | 30s 默认，10–300s 可调 |
| peer 超时下线 | 3 × 最后声明的间隔 |
| SSE 重连 | 指数退避 1s→2s→4s…max 60s |
| 后端聚合搜索 | 最多并发 8 个 peer；单 peer 超时 8s；聚合等待 10s |

### 14.2 传输与编码

- 全部 UTF-8 JSON；支持 gzip/br（标准 Content-Encoding 头）
- 所有时间戳 ISO 8601 UTC（2026-09-16T14:00:00Z），禁止 epoch

### 14.3 性能与体验

- meta/search/toc/content 四基础端点 P50 < 200ms（本地 peer）
- 后端聚合搜索：**先返回最快 peer 的结果，慢 peer 结果经 SSE 增量推送**，不等齐
- 前端列表必须 skeleton 占位 + 流式追加
- 引擎崩溃重启后 instanceId 不变则前端无感

### 14.4 一致性

- 每个响应带 X-TH-Request-Id 回显
- HTTP 状态码语义正确，body 与状态码不矛盾
- 未知字段忽略并透传；未知模块/caps 忽略；降级行为成文

## 15. 兼容性军规（只增不减）

**从 THP/1.0 发布之日起冻结主版本，此后一切变更只增不减。新增引擎/新能力 = 只加 caps 与字段，永远不改已有字段的含义与结构。**

1. **协议版本**：/thp/meta 返回 "protocol": "THP/1.x"；实现方按主版本 "THP/1" 判断兼容，忽略次版本细节
2. **能力协商**：一切新能力通过 caps 声明；未知 cap 一律忽略
3. **未知字段容忍**：任何 JSON 响应中不认识的字段必须原样忽略，不得报错；转发时尽量透传
4. **可选端点**：除 meta/search/toc/content/blob/changes/items 外均为可选；调用方遇 404 或 ok:false 必须按本文档降级
5. **数据类型扩展**：content 类型允许新增取值；未知类型显示"暂不支持预览"并允许浏览器打开
6. **第三方接入**：实现本协议即自动接入（广播即连接，无注册无审核）；同协议可实现替代后端/替代前端——**协议是生态唯一的约定**
7. **错误归一**：只依赖 ok:false 判断失败；code 建议值见第10节
8. **退役通道**：peer 通过 meta.deprecated 预告字段退役；退役周期 ≥ 2 个次版本

## 16. thp-check 一致性测试

仓库附带 thp-check 工具：输入 peer 地址 + role，自动验证：

- ☐ 全部必选端点存在且返回合法信封
- ☐ HTTP 状态码与信封一致
- ☐ 未知字段容忍测试（注入未知字段不得报错）
- ☐ cursor 分页行为（cursor 单调性、hasMore 正确性）
- ☐ 404/降级行为符合第7节各端点规定
- ☐ engine 角色无写端点
- ☐ NDJSON 流格式（如声明 batch-content）
- ☐ SSE 事件格式（如声明 events）

官方引擎/资源库每次发版必须通过 thp-check；规范文档内每个端点附正反两个示例报文。

## 17. 法律防火墙与引擎行为准则

### 17.1 ThirdHub 侧红线（永久）

1. **不分发**：官方仓库/官网/安装包零引擎、零源、零规则；远程引擎只能用户自行添加
2. **不推荐**：无官方精选/推荐位；目录仅展示用户自行提交的信息
3. **免责文本**：用户协议明确"引擎为第三方独立开发，ThirdHub 不提供、不审查、不担保引擎内容"
4. **风险提示**：连接任何远程引擎/出示身份前，前端弹确认提示

### 17.2 引擎行为准则（写入开发者文档）

- 引擎不得将用户查询内容记录/上传至第三方
- 引擎不得索取与功能无关的权限
- 违反准则的引擎由用户自行弃用；ThirdHub 不提供内容层面的审核

### 17.3 身份层免责

/v2/verify 仅验证密码学签名并返回账号标识，不含任何内容、会员判断或记录。授权行为发生在用户与引擎开发者之间。

## 18. AI 控制平面

本章定义 AI（TH-Harness Agent）如何通过 THP 统一控制**前端、资源库、引擎**三类对象。核心思想：**一切可控制能力都自描述为"工具"，注册进同一张工具表，AI 只做编排，不做硬编码。**

### 18.1 控制模型

| 被控对象 | 工具来源 | 传输 |
| --- | --- | --- |
| **前端模块**（novel/music/album/note…） | **模块自注册的功能工具**（18.2，进程内注册表） | 进程内调用 |
| 资源库 library | GET /thp/tools + 写路径/jobs/changes | HTTP（经配对加密） |
| 引擎 engine | GET /thp/tools | HTTP（局域网/直连） |

Harness 启动时聚合：**前端各模块注册表 ∪ 各在线 peer 的 /thp/tools** → **合并为一张 function-calling 表**。AI 看到的只是工具名和 schema，不区分被控对象是模块、后端还是引擎。

**原则：AI 永不模拟触屏。AI 调用"功能"，UI 由模块自己渲染。**

**控制优先级（从高到低，逐级降级）：**

1. **模块功能工具**（novel.open、music.play…）——首选，AI 直接调功能
2. **声明式 UI 指令**（navigate/highlight/toast…）——次选，AI 下渲染指令
3. **语义树读屏兜底**（ui.state/ui.scroll/ui.action…）——仅当模块未注册功能工具时启用
4. **询问用户**——以上皆不可用，AI 弹卡片说明需要什么

模块开发者应优先注册功能工具；读屏兜底保证**任何模块（含第三方未适配模块）AI 都能控制**，只是体验降级。

### 18.2 模块原生工具注册

**每个模块在初始化时向 Harness 注册自己的功能工具**——不是通用 UI 操作，而是业务级能力。AI 直接调用功能，模块自己完成渲染。

注册 schema（与 /thp/tools 完全同构）：

```json
{
  "name": "novel.open",
  "module": "novel",
  "description": "打开指定书籍到阅读器，可定位章节",
  "level": "T1",
  "params": {
    "type": "object",
    "properties": {
      "bookId": { "type": "string" },
      "chapterIndex": { "type": "integer" }
    },
    "required": ["bookId"]
  }
}
```

前端工具注册表标准集（各模块按业务扩展）：

| 工具 | 所属模块 | 说明 |
| --- | --- | --- |
| app.navigate | 框架 | 切换模块：{module}——**"跳转到模块某某某"的直接实现** |
| novel.open / novel.search | 小说 | 打开书籍/搜索 |
| comic.open | 漫画 | 打开漫画定位话数 |
| music.play / music.queue | 音乐 | 播放/排队 |
| video.play | 视频 | 播放指定剧集 |
| album.show / album.backupNow | 相册 | 打开照片/立即触发备份 |
| note.create / note.search | 笔记 | 建笔记/搜索笔记 |
| todo.add / todo.complete | 待办 | 加任务/完成任务 |
| browser.open | 浏览器 | 打开URL |
| download.add | 下载中心 | 添加下载任务 |
| settings.get / settings.set | 我的 | 读写设置（set 为 T3） |

### 18.2a 声明式 UI 指令（工具结果的渲染协议）

工具返回的 meta.ext 里可携带 **ui 指令**，由模块渲染器执行——AI 只下指令，不操作控件：

```json
{
  "ok": true,
  "data": { "found": 3 },
  "meta": { "ext": { "ui": {
    "action": "navigate",
    "module": "novel",
    "route": "reader",
    "params": { "bookId": "x", "chapterIndex": 3, "highlight": "第3章 大雪" }
  } } }
}
```

| ui.action | 效果 |
| --- | --- |
| navigate | 切模块+路由（app.navigate 的声明式版本） |
| highlight | 模块内高亮指定元素/条目 |
| toast / dialog | 弹提示/弹卡片（含 T3 确认卡） |
| refresh | 刷新当前模块数据 |
| pending | 挂起等待用户操作（如翻书），配合 observe 恢复 |

执行链：**AI 决策 → 调功能工具 → 模块执行并返回 ui 指令 → 框架渲染器执行 → 用户看到界面变化**。

### 18.2b 兜底：语义树工具（非主路径）

以下工具仅用于模块**未注册功能工具**时的兜底与调试，不进入主控制流：

| 工具 | 说明 |
| --- | --- |
| ui.state | 语义快照 {module, route, elements:[{id,type,label}]} |
| ui.scroll / ui.action / ui.input | 兜底交互（优先级低于模块功能工具） |
| ui.observe | 订阅界面变化 |

### 18.3 工具安全分级（Harness 强制执行）

| 级别 | 工具类型 | 执行策略 |
| --- | --- | --- |
| T0 只读 | ui.state / ui.read / changes / search | 自动执行 |
| T1 导航 | ui.navigate / ui.scroll | 自动执行，悬浮球显示动作 |
| T2 交互 | ui.action / ui.input / items 写入 / jobs 创建 | 自动执行，记入审计日志 |
| T3 危险 | 删除 / 分享 / 授权 / 支付 / 设置修改 | **AI 只能弹出确认卡片，必须用户手动点击确认**，AI 无法绕过 |

- 工具在注册/声明时自带 level 字段；**Harness 是唯一执行入口，任何 peer 不得自我提权**
- 确认卡片内容 = 工具名 + 参数摘要（"删除笔记《xxx》？"）

### 18.4 AI 悬浮球

前端导航悬浮球的双态扩展：

| 状态 | 视觉 | 触发 |
| --- | --- | --- |
| idle | 普通导航球 | AI 空闲 |
| thinking | 呼吸灯/转圈 | Agent 循环运行中 |
| acting | 显示当前动作文字（"正在打开《三体》"） | 执行 T1/T2 工具时 |
| waiting-confirm | 高亮+抖动 | 有 T3 确认卡片待处理，点击展开 |

AI 激活时 AI 球置顶；用户手指触碰屏幕任意处即暂停 AI 操作（交接权永远在人手）。

### 18.5 跨 peer 编排示例

用户: "把这本书缓存了，cache完告诉我"

AI 编排（全部走工具表，无硬编码）:

1. library.search → 找到书籍
2. engine.content:batch → 后端经引擎拉取全书
3. library.items(写入) → 入书库
4. events 订阅 → 进度推送
5. 返回 ui 指令: navigate(novel.reader, highlight) → 自动翻到该书并高亮
6. 返回 ui 指令: toast → "已缓存完成"

### 18.5b THP 与 MCP 的互通

THP 工具层与 MCP（Model Context Protocol）**同构**：/thp/tools ≈ MCP tools/list，工具调用 ≈ tools/call，信封 ≈ MCP 结果信封。据此定义双向桥接：

- **MCP → THP**：任何 MCP Server 可被包装为一个 THP peer（桥接器实现 /thp/meta + /thp/tools + 调用转发），MCP 生态的能力直接进 ThirdHub 工具表
- **THP → MCP**：任何 THP peer 可暴露为 MCP Server，Claude/Cursor 等 MCP 客户端可直接调用 ThirdHub 引擎/资源库

工具 schema 一律采用 **JSON Schema**（与 MCP/OpenAI function-calling 相同），一套定义三处通用。

### 18.6b 双运行时架构：前端 Harness 与资源库 Agent 运行时

**前端是随时进后台的客户端，资源库是永远在线的服务端。** Agent 任务按生命周期分流：

| 任务类型 | 运行位置 | 理由 |
| --- | --- | --- |
| 交互式短对话（几轮内完成） | 前端 Harness | 低延迟，需要 T3 确认卡即时弹窗 |
| 长任务 Agent（缓存全书、批量整理、深度研究） | **资源库 Agent 运行时** | 前端切后台/被杀不中断 |
| 定时 Agent（"每天早上7点摘要新闻"） | **资源库 Agent 运行时** | 前端根本不在线 |
| 依赖 UI 展示的步骤 | 前端 Harness | 只有前端能渲染 |

**Agent 作业 = job**：资源库收到 Agent 请求后创建 /thp/jobs 作业，Harness 循环（plan-act-observe）在资源库内执行：

```
前端: POST /thp/agent { prompt, scope, maxRounds }
→ 返回 { jobId }，前端可立即关闭
资源库: 循环执行（可用工具 = 库工具 ∪ 在线引擎工具）
→ 进度/步骤经 events SSE 推送
→ ui 指令暂存为"待执行 UI 动作"，前端重连后补放
→ 结果写入 note/todo 等模块（items 写路径）
→ 作业状态 done，前端重连后看到结果躺在笔记里
```

- Agent 作业**持久化于资源库**，资源库重启后可恢复（paused 状态续跑）
- 确认策略：作业中遇到 T3 工具而前端不在线 → 作业转 waiting-confirm 挂起，前端重连弹卡；用户可设超时降级策略（默认拒绝/自动批准按工具白名单）
- 可用范围：库端 Agent **只能用库工具与引擎工具**，不能调用前端 UI 工具（资源库无界面）；需要 UI 的步骤以 ui 指令形式排队等前端
- 主动通知（可选）：资源库支持 webhook/ntfy（用户自配），作业完成推送到用户选择的通知服务
- 密钥：LLM API Key 加密存于资源库（用户自己的设备），前端经配对加密通道同步；云端不存任何密钥

**审计**：库端 Agent 的调用日志存资源库（用户数据），前端远程查看。

### 18.6 AI 审计日志

- 每一次工具调用记录：时间 / 工具名 / 参数摘要 / 结果 / 是否用户确认
- 存储：**前端本地**（不上云，符合数据铁律），用户可在「我的→AI日志」查看、筛选、清空
- 审计日志是 AI 信任的基础，也是 T3 确认链的证据

---

*THP/1.0 · ThirdHub Protocol · MIT License · 本文档随仓库与安装包分发*
