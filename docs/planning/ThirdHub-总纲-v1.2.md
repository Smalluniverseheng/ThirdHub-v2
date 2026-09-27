# ⚠️ 架构修正令（最高优先级·覆盖全书相关旧表述）

**真架构=前端矩阵+后端自部署软件**：
前端矩阵=纯壳(网页PWA/小程序/App全平台/iOS安卓WinMacLinux)，功能100%一致样式适配各端，零数据主权一切走后端API。
后端=自部署软件(Linux/Docker/旧手机APK/CF Workers皆可跑)，数据唯一居所，API与前端模块一一对应。
CF小号(CF-B)=你部署的后端实例，授权制给家人同学用(后台发令牌/配额/撤销)，积分按调用量扣。
iOS=前端形态之一(非纯播放器)；安全三件套=防扒代码(混淆/核心逻辑全后端)+网络加密(TLS1.3/HSTS/AES-GCM信封)+防暴力(限流/验证码/WAF/请求签名)。
全文涉及"四线五端/iOS纯播放器"的旧表述以此令为准。

**三层终版（第23部分修正）**：云账号层=只做认证+配对牵线，绝不转发数据；后端=用户自部署数据唯一居所；前端=core壳+可选全量库（安卓/桌面≈完全体，前端不连后端也能全功能AI Agent）。配对：前后端同账号登录→云给连接候选(IPv6/穿透/反代)→直连。



---

# ThirdHub 总纲（全档案合一版）

> 版本：v1.2 · 2026-09-27（修正令+三层架构/前端分级/全量库） · 由 docs/planning/ 全部11份文档合成，内容零删减
> ⚠️ 保密提醒：本文档含完整产品战略，所在仓库为公开仓——如需保密应移至私有仓

---

## 使用说明（AI省上下文读法）

**不要全文通读！** 按任务类型跳章：

| 你要干什么 | 只读这些 |
|-----------|----------|
| 领任务/干活 | 卷四-第2篇《宪法》(铁律+SOP) → 卷二对应模块施工图纸 → 对应manifest |
| 改架构/云端配置 | 卷一《总会话档案》对应节（目录见下） |
| 写引擎/插件 | 卷三-第1篇《THP-2.1》+卷三-第3篇《清单规范》 |
| 做交互/动效 | 卷四-第3篇《交互技能13模式》 |
| 发版 | 卷一·第十六部分 R0-R3整改表 + 卷四宪法第9/10条 |
| 交接 | 卷四宪法·七步SOP第⑦步 |

## 总目录

**卷一 · 决策档案**（总会话档案v7.3，20+1部分）
- 一~二 产品定义/五线五端 → 三 仓库全图36仓 → 四 模块树7+1 → 五 OS内核层
- 六 QAuth → 七 云端架构(**含CF②中转站授权制**) → 八 用户分档 → 九 协议体系
- 十 AI体系 → 十一 引擎隔离 → 十二 L3商业 → 十三 积分支付 → 十四 文档治理
- 十五 审计结论 → 十六 R0-R3整改表 → 十七 Linux迁移 → 十八 待办 → 十九 版本全史(四代173版) → 二十 版本补遗 → 二十一 09-27晚增补

**卷二 · 施工图纸**
- 第1篇 模块详细设计全书v1.3（10章+4补篇+深描二三层：手势级/字段级/参数级）
- 第2篇 施工指令书：AI模型分化+双端统一(R0.5)
- 第3篇 功能规划v3.0

**卷三 · 协议与规范**
- 第1篇 THP-2.1协议对齐版 → 第2篇 完全规格书v1.0(21节+§25修正案) → 第3篇 AI开发总清单规范(manifest)

**卷四 · 守则与参考**
- 第1篇 项目宪法(十二铁律+七步SOP+反模式) → 第2篇 宪法(施工AI必读) → 第3篇 交互技能13模式 → 第4篇 调研报告
- 附录 会话总清单(旧版存档,内容已并入卷一)

## 中转站v2语义（2026-09-27晚用户确认）

CF②中转站 = **API转发网关+账号授权**：
```
同学/亲人注册账号 → 管理员(我)在后台给他的账号打授权标记
→ 他的网页/软件端登录后,模型列表自动出现可用模型(免填API)
→ 请求: 他的端 → CF②中转站(带他的用户令牌) → 真实模型API(密钥只存在中转站)
→ 全程不暴露API密钥; 授权可随时撤销
```
参照实现：**new-api**(MIT,可直接部署:多Key轮询/用户令牌/模型列表下发);CF② Workers做轻转发层。此机制=积分体系(卷一·十三)的消费落点:按调用量扣积分。

---



# 卷一 · 决策档案（总会话档案v7.5）

# ThirdHub 总会话档案（终极详细版 v7）

> 版本：v7.5 · 2026-09-27 · 由本会话全部讨论+两次全项目审计合并而成
> 定位：**本文件是ThirdHub一切决策的最详细存档**。任何AI进场先读本文件；任何变更追加"变更日志"节，不改写历史节。
> 姊妹文件（均在 docs/planning/）：项目宪法与执行手册-给AI.md / ThirdHub-完全规格书-v1.0.md（已被本文件吸收合并，后续以本文件为准）

---

# 第一部分 · 产品定义

## 1.1 一句话定义
ThirdHub = **模块即App的手机OS**。

## 1.2 产品哲学（四条）
1. 模块是大模块的分支功能，不是独立小App（7大业务模块+OS内核，消灭碎片模块）
2. 全部设置**只给推荐值不给限制值**（超限弹性能警告，不禁止）
3. 内容扩展=IR新分支，不是新模块
4. "家庭"不是模块，是各模块的模式开关

## 1.3 参照系
- 产品形态：腾讯**WorkBuddy**（电脑版全功能+手机版轻客户端）
- iOS过审：Infuse/Plex/Jellyfin 客户端模式（纯播放器连用户自填的服务器）
- 私有云：Immich（相册备份机制）/ Nextcloud（模块化）/ Syncthing（差量同步）——只学设计，AGPL/GPL严禁拷贝

---

# 第二部分 · 产品线（五线五端）

| 线 | 仓 | 形态 | 职责 | 版本体系 |
|----|----|------|------|----------|
| ①网页端 | ThirdHub-Web（拆自v2） | PWA | 云端托管轻入口，打开即用 | 独立CHANGELOG |
| ②手机版 | flutter_app（v2仓内） | Flutter | 纯播放器+AI控制；Android/iOS/Win/Mac/Linux | 独立（现4.52.0） |
| ③电脑版/后端 | server+backend-android（v2仓内） | Node+Web | 全功能管理界面+数据中枢+编排+插件；**可出Android APK（Node内嵌），旧手机变服务器** | 0.8.7 |
| ④完全体 | ThirdHub-Full | 一体化App | 内置后端能力，直接下载书源/直接搜索；给无后端的人，主要自用 | 独立 |
| ⑤小程序 | ThirdHub-MiniProgram | Taro/uni-app | 播放器+AI控制连用户后端 | 独立 |

**现状（2026-09-27）**：实际为**单仓全家桶**——ThirdHub-v2内含 flutter_app 4.52.0 + server 0.8.7 + 后端APK工程 + docs；ThirdHub-Flutter独立仓0.4.4旁支搁置；老站ThirdHub转生为**官方下载中心**v3.35.3。

**iOS红线**：App Store只上②（零书源零规则、通用服务器地址栏、话术"个人媒体中心客户端"、TestFlight先行）；④完全体与引擎永不入App Store。

---

# 第三部分 · 仓库全图（36仓，逐个）

## 3.1 现役（GH-A商用组织 Smalluniverseheng）

| 仓 | 语言/形态 | 当前版本 | 职责 |
|----|-----------|----------|------|
| ThirdHub-v2 | Dart+JS全家桶 | v4.52.0 | ★主线：flutter_app+server+后端APK工程+docs/planning |
| ThirdHub | JS | v3.35.3 | 转生=官方下载中心（分发后端包/APK/引擎包） |
| ThirdHub-Flutter | Dart | 0.4.4 | 旁支搁置（主线已并入v2） |
| ThirdHub-Android | JS/Kotlin壳 | 3.0.16 | 备用轻壳 |
| ReadingEngine | Kotlin | v1.5.5 | ⚠️自用书源引擎（THP，端口1234）——**待迁GH-B** |
| ThirdHub-Downloader | Kotlin | — | 官方下载器App |
| ThirdHub-Update | — | — | 应用内更新通道 |
| ThirdHub-Admin | — | — | 管理后台 |
| AI-WorkLog | MD | — | AI工作日志（⚠️9-18后停更，R0④激活） |
| ai-handbook(私有) | — | — | AI交接手册+密钥库 |
| wrap-up-notes | JSON | — | 留言板（⚠️空转，启用或归档二选一） |

## 3.2 待归档（8）
ThirdHub-Android（备用壳，确认无用后归档）、ThirdHub-Engine（包名重命名路线已死）、legado-thirdhub（同上）、OmniHub、OmniHub-Update、OmniHub-Android（二代产品）、AI-Backup、ThirdHub-Portal。

## 3.3 参考只读（18，打reference标签）
legado(上游)、yidaRule、keep-alive(音源)、any-reader、wuji-tauri、Mineradio-LX-qs、VideoWorld_Android、JustAuth、fqnovel-unidbg、Fanqie-novel-Downloader、videdown、res-downloader、Bili23-Downloader、TVAPP、Lyrico、infinite-canvas、LearnPrompt、Legado-Tauri-Release。

## 3.4 待建（GH-B个人组织，小号）
ReadingEngine（迁入）、书源工具、实验仓。**小号token待用户提供**——这是引擎组织级隔离的最后一步。

---

# 第四部分 · 模块树（7大业务+OS内核，分支全列）

| 大模块 | 分支功能全列 |
|--------|--------------|
| 1.阅读 | 小说、漫画、听书(系统TTS)、有声书、播客文字稿、读书摘抄、换源(健康度权重自动)、追更检查(定时作业→通知)、全书缓存(作业化batch+jobs+进度推送)、阅读批注(→笔记)、阅读统计(时长/字数周报)、本地书导入(元数据解析) |
| 2.影音 | 音乐、视频、直播、播客、广播、短剧/漫剧、歌词(extra端点)、字幕(extra)、投屏DLNA、画中画、后台音频、倍速记忆、睡眠定时、均衡器、统一最近播放、下载归一(进下载中心) |
| 3.AI | Chat(离线优先/幂等上行/无缝续跑)、Work作业中心(列表/详情步骤回放/确认队列/定时调度/结果归档/模板/权限scope/断点续跑)、悬浮球(四态+角标)、工具体系(T0-T3分级)、记忆/偏好、技能(10个) |
| 4.个人数据 | 笔记(承接对话导出/批注/摘录/AI归档)、待办(AI提取/购物清单/日历联动)、录音(转写+摘要=作业)、日记(AI周回顾)、记账(AI分类/月报)、健康记录(AI趋势)、剪贴板(跨设备)、通讯录备份(加密)、短信备份 |
| 5.浏览器 | 网页、书签(多端同步)、历史、阅读模式、网页翻译、隐私模式、长截图→相册、UA按站记忆、手势、强制夜间、多搜索引擎、广告域名拦截(用户自导入规则，官方不分发) |
| 6.系统与文件 | 设置、模块管理(安装/隐藏/排序)、下载中心(统一/离线下载=作业)、相册(WiFi自动备份ContentObserver/哈希秒传/时间轴地图/释放空间/人脸归档本地模型/加密柜SQLCipher/版本历史/分享链/存储分析/整理作业)、文件、数据迁移(作业) |
| 7.工具箱 | 翻译(文本/截图/文档)、扫描OCR、二维码、计算器/换算、白板、文本工具箱(JSON格式化/编解码)、传感器小工具(尺子/水平仪/取色器)、文件互传、远程打印、悬浮便签、代码片段、Markdown编辑器 |
| 8.OS内核 | 模块生命周期、杀后台三档、事件总线、通知中心、全局搜索、QAuth、离线语义、数据所有权、性能预算、错误/空态/加载态规范、全平台适配层 |

---

# 第五部分 · OS内核层（全细节）

## 5.1 模块生命周期
运行中(前台)→后台保活→已冻结(内存快照)→已回收。每模块=独立微应用：自己的状态机+数据流；模块间唯一通信=事件总线（发事件如download.complete，订阅者收；禁止直接读写对方状态；AI编排也走事件总线）。

## 5.2 杀后台三档（用户设置）
- 不杀后台：全保活（A搜书切B搜音乐真同时跑）
- 智能LRU（推荐）：最大同时在线N（推荐4，**可设任意值**），超限杀最久未用
- 切出即杀（省电极速）
铁律：**不设任何上限，只做推荐值**。

## 5.3 三平台后台语义（写死，用户无感）
Android=真后台(前台Service，音乐系统级后台播放)；iOS=冻结+秒恢复(完整保存搜索词/列表/滚动位置/播放进度，切回毫秒内还原；音乐借系统音频特权)；Web/桌面=真后台(Web Worker/独立进程)；Web多标签=多模块天然并行。

## 5.4 通知中心
各模块通知统一入口：悬浮球红点角标+通知列表(按模块筛选)+点击跳转对应内容；模块通知全走此通道，禁止各弹各的。

## 5.5 全局搜索
框架层跨模块搜索(书/音乐/笔记/书签一次出，分组展示)；模块内搜索归各模块；全局搜索同时是AI工具入口。

## 5.6 离线语义
每模块声明离线能力级别：只读缓存/队列写(操作排队联网重放)/不可用；断网时UI明确标识当前可用范围。

## 5.7 模块数据所有权
每个数据集合唯一owner模块（书架=阅读，书签=浏览器，笔记=个人数据）；其他模块经API只读/按授权写；禁止跨模块直连数据表。

## 5.8 性能推荐值（只推荐不限制）
模块冷启动<300ms、存活模块内存<150MB/个、事件总线延迟<16ms；超限弹性能警告卡一键清理，不强制。

## 5.9 错误/空态/加载态规范
加载=骨架屏+流式追加；空态=插画+一句引导+主操作按钮；错误=错误码+重试+上报入口；三态由框架组件提供，模块只填内容。

---

# 第六部分 · QAuth扫码认证体系

原理：任何端要登录→出二维码→已登录的前端扫→确认→免密通过（类QQ）。底座=OAuth2 Device Flow变体，码内只有device_code，凭证明文在已登录端。
三场景：①前端登录后端（后端出码→App扫→确认→获token）②前端登录网站（网页出码→App扫→确认页显示"登录到xxx？"）③设备互授权（新设备出码→老设备扫→授权接入，L3引擎同通道）。
安全：码token一次性+2分钟过期；确认页显示目标设备名；异地/IP异常风险提示；**任何前端（含轻量）必须带扫码器**。

---

# 第七部分 · 云端架构（终版+实测数据）

## 7.1 资产分配

| 资产 | 职责 | 选区 |
|------|------|------|
| CF-A | 网站+网站配套(公告/更新检查/公共目录查询) | APAC |
| CF-B | 边缘数据面：Workers+KV(设置/锚点)+D1(设备清单/配额计数)+R2(头像/备份)+/v2/verify | APAC(SIN) |
| Supabase(每组织2免费项目) | **仅Auth**（users/sessions/profile≤10KB字段） | Singapore |
| Neon | B类用户云端托管库(书架/进度/笔记元数据) | Tokyo |
| GitHub-A/B | 代码组织/发行文档 | — |

## 7.2 免费额度实测（2026-09）
CF Workers 10万请求/天(00:00 UTC重置)；R2 10GB+100万写/月+出站免费(**=1000用户×10MB**，800用户时发公告引导清理)；D1 5GB+500万行读/天+10万行写/天；KV 100万读/**仅1000写/天**(禁当计数器)；Pages 500构建/月无限带宽；Tunnel免费。
Supabase：500MB库/5万MAU(只算当月登录)/1GB文件/5GB流量/Edge Functions 50万/月；**坑：7天无活动自动暂停→GitHub Action定时ping保活**。
Neon：0.5GB+100 CU-小时/月(2025-10起翻倍)，闲置5分钟归零，冷启动300-800ms配连接池。
GitHub：公开仓Actions无限；私有2000分钟/月。

## 7.3 多账号安全
官方无数量线；2-3个各干各的=无感；禁止同属性拆账号接力额度、禁止跨账号CNAME(报1014)、注册间隔+固定登录IP。现有GitHub token 2026-11-17过期。

## 7.4 延迟口径
适量可接受不追极致：热路径CF边缘(5-30ms)、登录Supabase(60-200ms可接受，登录才用)、数据走用户局域网。**Neon不当热查询**（100-400ms+冷启动）。

## 7.5 云端10MB配额表
昵称签名4KB/头像200KB(强制压缩)/账号设置16KB/设备节点清单32KB/同步锚点16KB/L3公钥+授权8KB/可选加密备份(默认关)占剩余/可选进度KB级。超限：拒写+提示清理。

---

# 第八部分 · 用户分档与数据流

A类(自托管)：前端→自己Node后端→SQLite本地。
B类(云端托管：管理员/家人/同学/会员)：前端→CF-B Workers→Neon。
**后端存储层=可替换driver(SQLite↔Postgres)，一套代码换driver**（也是Linux迁移接缝）。
数据流：登录→Supabase发JWT→CF-B KV拉设置/锚点→A类连用户后端/B类走CF-B→Neon→可选加密备份→R2(Worker计数,超限拒写)。
冲突策略：LWW(hash+ts)；笔记类5版本历史；changes游标单调不回退；删除=tombstone。

---

# 第九部分 · 协议体系

## 9.1 THP/2.1（对外生态）
信封 `{ok:true,data,meta}`/`{ok:false,error:{code,message,upstream}}`；失败只看ok:false；HTTP状态码正常语义；X-TH-Request-Id回显。
角色：前端纯播放器/后端编排器/官方应用(原版+API)/内置沙箱(drpy·venera·musicfree)/第三方peer/云。
IR归一：novel-ir✅video-ir✅music-ir✅comic-ir✅；v-next:podcast-ir/article-ir。
发现：mDNS为主+UDP为辅；零配置(自启+广播+零输入握手)；心跳30s×3失败降级degraded自动恢复；BYE优雅下线；唤醒立即重播；手动添加UI兜底。
安全：三模式权限(家庭/认识的朋友/陌生设备)；SSRF仅内网/Tailscale段；L1配对token/L2自签TLS指纹/L3持有证明；广域网必TLS+风险提示；可选AES-256-GCM。
搜索：现状`/v1/search?type=`；演进`/v1/m/{ir}/search`(新旧并行)。
错误码：UPSTREAM_FAIL/NOT_FOUND/UNSUPPORTED/RATE_LIMIT/AUTH_REQUIRED/PAYMENT_REQUIRED/SOURCE_BANNED/RULE_BROKEN/TIMEOUT/PAYLOAD_TOO_LARGE/CAP_UNAVAILABLE。
军规：只增不减/未知字段忽略透传/未知能力忽略/可选端点成文降级/新枚举只追加/退役经meta.deprecated预告≥2次版本。
v-next端点：blob(8MB分块+SHA-256秒传+Range)、changes(cursor+tombstone)+SSE events、jobs(queued|running|waiting-confirm|paused|done|error|canceled)、NDJSON批量、/v1/tools。
数值：limit默认20最大100/单响应≤5MB/NDJSON单行1MB/changes≤500条/SSE退避1s→60s/搜索fan-out并发8源超时8s聚合10s。

## 9.2 THA/1（Agent，已落地v4.43）
full/fallback双模式：DSH(DeepSeek Harness)只跑服务端/局域网设备，Flutter纯控制面(发起/渲染事件流/批准高危/看审计)；后端在+探到DSH=全量(多步工具/沙箱/MCP/插件/上下文预算)；无DSH=本地轻量降级(聊天+本机白名单工具)，协议不变不假装有沙箱；入口`GET /agent/health`先探模式再发任务；事件append-only溯源；确认队列；审计；MCP注册表；三档profile；88+140断言；`/agent/*`在X-TH-Token后。

## 9.3 CHAT/1（已落地）
离线优先；幂等上行(cid去重)；服务端分配seq；本地权威；12断言。

## 9.4 双信封立法（修正案）
THP=对外生态ok信封；/v1家族+THA/1+CHAT/1=内部object信封(历史兼容，断言已固化)；新协议默认归内部家族；**禁止统一式返工**。

## 9.5 thp-check
信封格式/状态码一致/未知字段容忍/心跳状态机/降级行为/SSRF约束；官方插件与适配器发版必过。

---

# 第十部分 · AI体系（全细节）

控制优先级：功能工具→声明式UI指令(navigate/highlight/toast/dialog/refresh/pending)→语义树读屏兜底(ui.state/scroll/action)→问用户。**永不模拟触屏**。
工具分级：T0只读自动/T1导航自动/T2交互自动+审计/T3危险(删除/支付/授权/改设置)只弹确认卡必须人工。
双运行时：Chat=前端Harness；Work=后端Agent(作业=job持久化，前端可杀作业不死；waiting-confirm挂起-重连补批；paused断点续跑)。
悬浮球四态：idle/thinking/acting(显示动作文字)/waiting-confirm(抖动高标)；Work进展=角标。
C-17对话无缝续跑：会话状态实时入后端，生成中前端被杀→后端接管→重连断点续聊。
审计日志：每次调用记录(时间/工具/参数/结果/是否人工确认)，本地存储，「我的→AI日志」。
MCP双向桥(MCP Server↔THP peer，JSON Schema统一)。
技能10个：翻译/联网搜索/日历系统指令/记忆/代码/调试/文件/交付检查/交互设计。

## 交互设计技能13模式（英文Prompt已固化）
1 Radial Theme Transition(深色切换,点击点为圆心) 2 Drag-to-Reorder(空槽+弹簧追赶) 3 Staggered Bulk Selection(错峰弹性) 4 Velocity-Based Slider Snap(速度过冲回弹) 5 Animated Text Disclosure(真实高度过渡) 6 Spring Stepper Progress(过冲回弹) 7 Ripple Feedback for Related Switches(邻近只震不变) 8 Curved Card Deletion(曲线路径+先动画后删数据) 9 Stacked Card Scroll(顶部钉住压栈) 10 Expanding Tag Selection(放大让位) 11 Fan Menu Expansion(悬浮球扇形:错峰弹出/当前高亮/遮罩/长按拖吸附/键盘上移) 12 Reader Page Curl(折痕锚点/**翻页完成才更新进度**) 13 Cross-Module Drag(悬浮缩放/目标高亮/先动画后数据)。
输出四段式：Selected interaction/Why it fits/Interaction behavior/Copyable prompt(纯英文)。判断四问：变化从哪开始/落在哪/谁跟着动/周围让不让位。负面清单：不许"加高级动画"式回答/不混输出多模式/不把视觉反馈写成真实状态变化/不用固定时长掩盖状态定义缺失。

---

# 第十一部分 · 引擎隔离与法律防火墙

## 11.1 三层隔离
组织级：GH-A商用/GH-B个人（ReadingEngine待迁，小号token待用户给）；商用仓零书源/零规则/零引擎代码/零依赖/零git历史；只引用THP协议文档。
代码级：引擎只以THP HTTP接口存在（独立软件互操作）；编排非集成（Legado/Komga/ABS/Jellyfin官方原版+官方API，禁止包名重命名/壳中壳，legado-thirdhub路线已死）。
发布级：商用Release永不捆绑引擎APK；引擎APK只走个人渠道；引擎仓README写"个人学习用途"。

## 11.2 沙箱规则引擎（规则+沙箱，非集成）
drpy(影视)/venera(漫画)/musicfree(音源) QuickJS进程内沙箱；规则不出仓库；统一审核源；AS IS分发；选择性忽略机制。

## 11.3 干净源定性（修正案2）
后端包内置15条白名单源=人工审核的公版/正版源，与用户自导入源**分轨管理**；清单公开可查、可整体撤销（已有10条撤销机制）；写入用户协议。

## 11.4 四不红线
不分发引擎/不做推荐位/不审核内容/免责文本明示。iOS仅纯播放器上架。

---

# 第十二部分 · L3商业生态（全细节）

引擎开发者自己收款/自己存会员/自己判定。云只加：`POST /v2/verify`无状态验签(不存记录不存证明)+账号公钥字段。
设备密钥对：安全区生成(Keystore/Secure Enclave)，私钥不出机；换机新钥覆盖旧钥自动吊销。
证明JWT：{sub账号标识,aud引擎标识,nonce,exp≤5分钟}+私钥签名。防分享(无私钥签不出)/防重放(nonce一次一换+5分钟)/防串用(aud绑定)。
流程：绑定(付费时扫码→verify→开发者存{accountId:会员})；引擎启动(新nonce→新证明→verify→查自家会员表)。
PAYMENT_REQUIRED→跳meta.ext.paymentUrl。
配套E-1~E-9：verify端点/出示身份弹窗/授权管理/远程引擎手动添加/风险提示/Engine SDK三语言/Client+Server SDK/开发者指南+示例引擎。

---

# 第十三部分 · 积分体系与支付（新增）

积分=平台唯一货币（会员/空间/远期打赏全花积分）。
合规三铁律：单向充值**不可提现**/**不可转账**/仅限平台内消费。
1元=10积分(推荐值)；充值=微信支付(正式)+个人收款过渡(无商户号期手动发放)；消耗=会员积分/月、空间积分/GB/月。
账本=D1 credits_ledger不可变流水(时间/数额/类型/余额快照)+KV余额快读。
微信支付模块：独立模块交给AI按七步SOP；商户号需营业执照，无主体先用过渡；回调验签+幂等+先记账后发货。
小程序虚拟支付：iOS禁、安卓需虚拟支付接口，与积分打通时再处理。

---

# 第十四部分 · 文档治理与AI工作法

## 14.1 manifest.yaml八段式
id/name/icon/status(planned|dev|stable|deprecated)/version/routes/features[{id,name,status,note}]/settings_schema[{key,type,default,scope:cloud|backend|local}]/logic[业务规则文字含边界]/data_collections[{name,sync,owner}]/tools[{name,level:T0-T3,params}]/dependencies/changelog[{date,change,why}]。
## 14.2 三层文档
机器层manifest(唯一事实源,AI每次改必更新)/索引层MASTER.md(CI自动生成,禁手写)/变更层MASTER-CHANGELOG(每次必追加)。
## 14.3 七步SOP
读(手册+总清单+WorkLog+manifest)→述(目标≤5行,等确认)→划(改动清单+影响面,等确认)→做(只改确认范围)→记(manifest+CHANGELOG)→测(thp-check过)→交(三句话摘要进AI-WorkLog)。
## 14.4 十二铁律
引擎隔离最高/双账号隔离/auth唯一(Supabase)/云端零内容/协议只增不减/改代码必改清单/意图确认制/优先级冻结(只有用户能改)/版本号单一来源/CHANGELOG独立/前端纯播放器/编排非集成。
## 14.5 协作系统现状
仓库内：HANDOVER-AI.md(#26轮)/PROMPT-FOR-NEXT-AI.md/TASKS.md(A-E组)/.workbuddy/memory(0-12)/docs/planning/(本体系)。**双轨制待并轨(R0⑩)：把清单规则写进PROMPT-FOR-NEXT-AI。**

---

# 第十五部分 · 审计结论（2026-09-27，300提交/14天/22轮）

精力分布：发版机械35%(106条)/UI 28%(83)/i18n 7%/性能**仅7%**(21)/同步32条是修坏循环(9-24 v4.44打通→9-25 v4.47"点了没反应/云端被抹"→9-26 v4.49静默失败；根因=两端各读各的表，§11契约从未实施)。
零动工清单：OS内核层/QAuth/性能预算/keystore处置/双信封立法(本次已立法)/干净源定性(本次已定性)/GH-B隔离/iOS与桌面适配。
制度空转：AI-WorkLog 9-18停更；wrap-up-notes空转；双AI体系互不知情。
亮点：THA/1+CHAT/1落地/鉴权黑洞修复/听书悬浮球/7语言i18n/后端包四通道+digest校验。
安全高危：**keystore已泄露**（伪造更新包风险，R0①）。

---

# 第十六部分 · 整改规划表（R0-R3，无时间线按完成交付）

| 批次 | 任务 | 验收标准 | 依赖 |
|------|------|----------|------|
| R0止血 | ①keystore更换+更新接口签名白名单 | 旧签名包不能再获取更新 | 用户签发 |
| | ②同步按§11契约重建 | 两端同读同写一套表；9-24三连bug不复现 | 无 |
| | ③网站Lighthouse实测+迁CF-A+缓存规则 | 首屏<3s(4G)、性能分>80 | CF-A |
| | ④AI-WorkLog制度激活 | 72小时内日志有更新 | 施工AI |
| R1体验 | ⑤模块OS层(保活三档/事件总线/通知中心/全局搜索) | 切走再回状态在；两模块真并行 | ②后 |
| | ⑥Flutter WS长连接替轮询 | 聊天/AI事件流实时到达 | 无 |
| | ⑦性能预算进CI | 超预算PR标红 | 无 |
| R2基建 | ⑧GH-B隔离 | ReadingEngine迁出商用组织 | 用户给token |
| | ⑨双AI体系并轨 | 对方提交带manifest更新 | ④ |
| R3增长 | ⑩商业L3/积分体系/小程序端 | 按§12/§13 | R2后 |

---

# 第十七部分 · Linux服务器迁移（纯设计约束，现在不建不迁）

路线A(首选)：CF边缘不动→Cloudflare Tunnel(免费)→自有服务器当源站，零数据搬迁。
路线B(终极)：自托管Supabase(pg_dump迁auth，JWT secret必带走，storage走S3同步)。
三条硬规矩(现在执行)：KV/D1键全带uid前缀；Workers只做读缓存→转发，业务逻辑不进CF；每月Action自动导出KV/D1快照到Release。

---

# 第十八部分 · 待办（按危险度排序）

| 项 | 状态 |
|----|------|
| keystore泄露处置 | 🔴 最高危，等用户签发新key |
| GH-B小号token | 🔴 等用户提供 |
| 网站卡顿 | 🔴 R0③先Lighthouse实测（托管位置两仓Pages均未启用，待确认） |
| 同步修坏循环 | 🔴 R0②按§11契约重建 |
| AI-WorkLog停更 | 🔴 R0④制度激活 |
| GitHub token 11-17过期 | ⏰ 7周内更换 |
| ReadingEngine协议版本号(1.0→2.1) | 并入R0⑧ |
| wrap-up-notes | 启用或归档二选一 |
| 搜索路由演进/老PWA移植/iOS TestFlight | R3后再议 |

---

# 变更日志
- v7(09-27)：吸收审计报告+R0-R3；新增§9.2/9.3(THA/CHAT)；双信封与干净源立法；Neon定性=云端托管库；仓库现状修正(单仓全家桶/老站转生下载中心/Flutter旁支搁置)；第五部分OS内核补全细节。
- v6(09-27早)：审计结论+R0-R3首版入总清单G节。
- v3(09-24晚)：云端终版(CF-A/B+Supabase仅Auth+Neon托管)；用户分档A/B类；storage driver。
- v2(09-24)：四线架构(WorkBuddy参照)；双CF账号；后端APK上手机。
- v1(09-24早)：THP/模块树/优先级初版。

---

# 第十九部分 · 版本全史与文档全录（2026-09-27完整性核查后补入）

## 19.1 四代版本总账

| 代 | 名称 | 时间 | 版本数 | 性质 |
|----|------|------|--------|------|
| 一 | aiBeta | 2026-06-10起 | 58 (v1.0.0→v1.19.2) | 纯AI助手应用时代：AI对话/联网/上下文管理/技能注入雏形 |
| 二 | OmniHub | 6月 | 20 (v2.0.0→v2.2.8) | 聚合枢纽：模块化+悬浮球导航（今日OS层思想源头） |
| 三 | ThirdHub 3.x | 08-23起 | ~35 (v3.0.0→v3.35.3) | 全平台聚合站成熟体→转生官方下载中心 |
| 四 | ThirdHub v4 | 08-23起 | ~60 (v4.0.0-draft→v4.52.0) | 局域网设备编排架构，当前主线 |
| 合计 | — | 118天 | **约173个版本，日均1.47版** | — |

## 19.2 第四代关键版本公告链（v4.0→v4.52）
v4.0.0-draft 编排架构定型(三大铁律/IR归一/编排非集成) → v4.3-4.6 设备协议/心跳/插件零配置 → v4.7-4.12 能力路由+聚合搜索雏形 → v4.13-4.27 M1/M2冲刺(四大链路/Legado三自动/v4.27 AI智能体+作业中心做实) → v4.28-4.33 PLAN-v3六组落地/CI门禁 → v4.34-4.42 88断言/媒体归一/THA架构/版本号收归单一来源 → **v4.43 THA/1协议实现** → v4.44 端网+插件体系+离线前端 → **v4.45 主线全家桶定型**(flutter_app并入/老站转生下载中心/Flutter旁支搁置) → v4.46-4.51 搜索逐条上屏/**鉴权黑洞修复**/APK半残包修复/同步修坏循环(4.47/4.49)/i18n六语言/14轮发版流/**keystore泄露登记** → **v4.52.0 当前**：阅读器底栏5格+听书可拖动悬浮球+22轮交接。

## 19.3 文档全录（两仓86+43个md，全部过一遍的结论）

**ThirdHub-v2（43个md）**：协议类5（THP/THA/CHAT/THP-SDK/PLUGIN-SDK全精读）；架构规划类5；变更志类4（全部完整读取）；协作流3；设计类6；引擎类4；发布类4；我们的planning档8；privacy/terms/legal已就位（合规文档在位✅）；sources-preset/health-book.json 27KB=15条白名单干净源（与修正案2一致✅）。

**ThirdHub老站仓（86个md）**：**"消失的9个文档"全部在此仓**——DEVICE-PROTOCOL/CAPABILITY-ROUTER/BUILTIN-ENGINES/ADAPTER-LEGADO/FRONTEND-MATRIX/FRONTEND-DUAL等（9-25转生时协议文档归入老站docs/，未丢失✅）；另有M1-SPRINT/MIGRATION/ROLLBACK/family-server全套文档/ARCHITECTURE-V2/PROJECT_MEMORY等。

## 19.4 完整性核查修正记录
1. **上回合"9文档消失"系误报**：实际在老站仓docs/，文档地图更新为"两仓分布"
2. **legado-patch/存在于商用仓**：系编排工具（官方Legado自启补丁），非引擎代码，登记入隔离白名单
3. GEN1共58版/GEN2共20版已全量列出；GEN3约35版（关键里程碑v3.0.0聚合站/v3.18.15/v3.20-v3.27.x系列/v3.29.2-v3.35.3下载中心17连发）
4. v4.45-4.52部分版本无独立公告文档，内容取自提交记录与HANDOVER（已标注来源）

## 19.5 版本史暴露的节奏结论
四代173版/118天：第一代练AI、第二代练模块化、第三代练聚合站、第四代练编排+发版流。**发版机械占比过高的根因在版本史里可见——第四代60个版本中约1/3是发版流本身**（与审计的35%一致）。第五代（v5.x建议）的主题应是"体验定型"：OS层/性能预算/同步契约，而不是继续堆版本号。

---

## 变更日志（追加）
- v7.1(09-27)：新增第十九部分（版本全史+文档全录+完整性核查修正）；修正"9文档消失"误报；legado-patch入隔离白名单登记。

---

# 第二拾部分 · 版本全史补遗（v7.2完整性终版）

## 20.1 GEN1 aiBeta 完整叙事（58版全文读完）
内部原编号v4.x-5.x（即记忆中的"aiBeta v5.7-v5.8会员体系"），gen1日志统一改编号为v1.x。
关键节点：v1.0.0(06-10,项目起点:AI对话/联网/上下文管理) → v1.4-v1.6(技能注入) → v1.7.0-v1.7.8(Kimi式底部工具抽屉/悬浮返回按钮/三端导航设置/Mermaid渲染/SSE30秒熔断) → v1.8.0(模型库272个/tool_calls工具卡片/Token用量统计/翻译独立空间) → v1.9.0(小说+漫画阅读器上线:书源导入/书架/搜索/章节阅读) → v1.10.0(书源智能识别混杂JSON/粘贴链接自动下载/可用性验证) → v1.11-v1.19.2(持续迭代至7月末)。
**性质定论：第一代=AI助手+书源阅读器的合体应用，悬浮球/抽屉/tool_cards等今天仍用的交互全部诞生于此。**

## 20.2 GEN2 OmniHub 完整叙事（20版全文读完）
v2.0.0(07-30,模块化重构:悬浮球导航/我的模块/阅读模块Venera引擎/Gallery+连续滚动) → v2.0.2(AI对话10厂商/绘画/Kimi左滑历史) → v2.0.3(Legado书源引擎全流程) → v2.0.6(五种翻页/番茄式目录) → v2.0.8(会员中心:六级宇宙等级/卡密激活) → v2.1.0(阅读模块全面升级/发现页/会员三档按年8折/头像系统/设备日志) → v2.2.x-v2.2.8(设备管理10/20上限/EventBus+Store防抖500ms/三端DeviceDetector/悬浮球扇形分页FLIP排序/RTL/后端三件套:**CF omnihub-proxy+Supabase error_logs/user_devices+Neon omnihub-ops运营库**)。
**性质定论：第二代=模块化+悬浮球+会员体系定型；后端三件套(CF+Supabase+Neon)在二代就已确立——本次规划中的Neon不是新引入，是回归二代格局。**

## 20.3 GEN4 末段精确化（v4.45-4.52提交正文全文核出）
v4.45.0(09-24 sync:打通"软件↔网页"数据互通) → v4.46.0/v4.47.0(设置同步+5处不可用修复+Agent降级路径落地+服务端版本号收归) → v4.48.0(修"点了同步没反应/云端设置被抹") → v4.49.0-v4.51.0(**APK半残包三连修**:armeabi-v7a/x86_64缺Flutter引擎) → v4.52.0(补齐23个漏推文件+CI真编译失败根因)。
注：v4.45"打通互通"与9-25的同步bug并存——首次打通做的是"能跑"，契约层(changes/tombstone/LWW)仍未实施，印证R0②的必要性。

## 20.4 发布资产全录
GitHub Releases共20个：主线v4.45.0-4.52.0(8个,各1资产) + flutter旁支v0.4.3/0.4.4 + backend-v0.8.6/0.8.7(各2资产) + 更早的v4.37-4.44系列。
版本号单一来源核实：flutter_app/pubspec.yaml=4.52.0 / server/package.json=0.8.7 ✅与附六一致。

## 20.5 老站仓（ThirdHub）86文档分布全录
- docs/reports: **51个**（历轮报告堆积——建议定期归档收敛）
- docs/: 16个（含"消失的9文档"实在此处的DEVICE-PROTOCOL/CAPABILITY-ROUTER/BUILTIN-ENGINES/ADAPTER-LEGADO/FRONTEND-MATRIX/FRONTEND-DUAL + CONNECTOR/M1-SPRINT/MIGRATION/ROLLBACK/PROJECT-INTRO）
- root: 9个（README/ARCHITECTURE-V2/PROJECT_MEMORY/REPO_SCOPE/REQUIREMENTS_TRACKING/STYLE_GUIDE/HANDOFF/**Yao-Agents-调研与互鉴.md**/**ThirdHub-升级规划报告.md**）
- backend/family-server+local-server: 5个（家庭后端文档）

## 20.6 编号混乱史存档（防未来考古翻车）
- 一代内部曾用v4.x-5.x编号（后改v1.x存档）
- 二代内部曾用v7.x-8.x编号（后改v2.x存档）
- 三代v3.x与四代v4.x并存期间，flutter旁支用0.4.x、后端包用0.8.x——**三条版本线并行**
- v4.43起版本号收归单一来源(42000+minor*100+patch)，此后混乱终结
结论：当前唯一真相源=flutter_app pubspec + server package.json + GitHub Releases tag。

## 变更日志（追加）
- v7.2(09-27)：GEN1/GEN2全文读完补叙事；v4.45-4.52精确化；Releases 20个入录；版本号单一来源核实；老站仓86文档分布全录；Neon更正为"回归二代格局"；编号混乱史存档。

---

# 第二十一部分 · 2026-09-27晚增补（云端分配修正版+新问题清单）

## 21.1 云端资产分配（用户当晚确认,取代第七部分旧表）
| 资产 | 用途 |
|------|------|
| CF① | 网站部署 |
| CF② | **中转站**(自用+可授权他人;凭据+配额=积分体系天然落点) |
| Supabase① | 账号认证(Auth唯一源) |
| Supabase② | 存储 |
| Neon | 服务器后台(业务库/作业/B类托管) |

## 21.2 AI模型板块问题清单（用户实测,施工指令书见docs/planning/施工指令书-AI模型分化与双端统一.md）
1. 所有模型类型(TTS/ASR/绘画/视频)共用对话输入样式——必须按model_type分化输入UI
2. 模型数据过时——模型目录改云端可更新JSON(CF-B托管,etag+24h TTL+90天过时角标)
3. 能力声明与实际不符——capabilities数组过滤入口

## 21.3 双端统一硬标准
网页端建书→App可见;App改字号→网页同步;一端配密钥另一端可用。插入R0.5优先级,先于OS层。

---

# 第二十二部分 · 架构修正令（2026-09-27 23:00，最高优先级，覆盖此前一切含混表述）

## 22.1 真正的架构（用户原话映射）
**前端矩阵 = 纯壳框架**：一个产品逻辑，多端形态——网页PWA / 微信小程序 / App(iOS/Android/Windows/macOS/Linux)。
- 每端都有：模块切换、悬浮球、通知中心、全局搜索——**功能100%一致，只是样式适配各端**
- 前端零数据主权：一切数据读写走后端API，任何端不落地用户数据
- iOS不是"纯播放器"，就是前端形态之一（此前表述作废；上架审核策略属执行层细节，不改架构）

**后端 = 自部署软件，数据唯一居所**：
- 部署形态：Linux服务器 / Docker / 旧手机APK / CF Workers
- 内含：数据层(SQLite/Neon driver) + 设备编排 + 插件体系 + THA Agent运行时
- 后端API与前端模块一一对应

**CF小号(CF-B) = 用户部署的一个后端实例**：
- 授权制：家人/同学注册账号 → 用户在后台管理发令牌/设配额/可撤销
- 被授权者的前端连CF-B实例，数据存在该实例
- 此机制=积分体系消费落点（调用量扣积分）

## 22.2 安全需求（与架构同优先级，先做好）
1. **前端代码防扒**：构建产物混淆+压缩 / 禁sourcemap / 核心逻辑全在后端(前端只渲染) / 产物零密钥零内部注释 / 静态资源CDN带防盗链
2. **网络层加密**：全站TLS 1.3 + HSTS / API可选AES-256-GCM信封(X-TH-Enc已有设计) / 敏感操作二次签名
3. **防暴力攻击**：登录限流(5次/5分钟)+验证码+指数退避 / 敏感端点(rate limit+IP信誉) / CF WAF规则(免费档) / 后端请求签名防重放(nonce+timestamp) / 蜜罐端点(记录扫描行为)
4. **密钥纪律**：一切API密钥只存后端(或CF-B中转站)，前端永不接触明文

## 22.3 修正清单（文档勘误）
| 旧表述 | 修正为 |
|--------|--------|
| 四线五端(网页/Flutter/后端/完全体/小程序) | 前端矩阵(多端壳)+后端(自部署软件)+CF-B实例 |
| iOS仅纯播放器上架 | iOS=前端形态之一，全功能，数据在后端；审核策略单列执行层 |
| CF②=中转站 | CF-B=用户自部署后端实例+授权制(含API转发职能) |
---

# 第二十三部分 · 三层架构终版 + 前端能力分级 + 全量库（2026-09-27 23:20，覆盖此前两层表述）

## 23.1 三层架构
第一层·云账号层（我控制的中央服务器）：职责只有两个——①账号认证 ②配对牵线（前端和后端登录同一账号后，云登记双方设备节点并告知彼此怎么找到对方）。**绝不转发用户数据，数据流量不过云。**
第二层·后端（用户自部署软件）：Linux/Docker/旧手机APK/CF Workers；数据唯一居所+编排+插件+Agent运行时；与前端直连（IPv6/内网穿透/代理/反代，自动协商，不经云）。
第三层·前端矩阵（纯壳）：网页/小程序/App全平台；功能一致样式适配；零数据主权；可加载全量库。

## 23.2 连接建立流程（配对制）
后端启动→登录云→云登记节点(ID/能力/在线/地址候选)。前端登录同账号→云返回后端节点列表+连接候选地址+一次性配对令牌。前端按候选顺序直连(局域网→IPv6→穿透→反代)，握手后数据全程直连。云只见证配对，不见证数据。

## 23.3 前端能力分级矩阵
| 能力 | 安卓 | iOS | 桌面 | 网页PWA | 小程序 |
|------|:---:|:---:|:---:|:---:|:---:|
| 基础浏览/模块切换 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 连后端全功能 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 本地全量Agent(不连后端) | ✅ | ⚠️后台受限 | ✅ | ⚠️ | ❌ |
| 本地TTS/ASR | ✅ | ✅ | ✅ | ⚠️ | ❌ |
| 本地存储 | ✅SQLite | ✅ | ✅ | ⚠️IndexedDB | ⚠️ |
| 离线内容缓存 | ✅ | ✅ | ✅ | ⚠️ | ❌ |
| 本地沙箱(用户自导入规则) | ✅ | ⚠️ | ✅ | ⚠️ | ❌ |
| 结论 | ≈完全体 | 近全量 | 全量 | 中量壳 | 轻量壳 |

## 23.4 前端全量库（front-full-kit，独立框架）
目的：前端分层防编码混乱——core壳(最小必带) + full-kit(可选下载,前端不连后端也强大)。
内容：DSH-light(Agent循环+工具白名单本地版,API key用户自配或CF-B授权) / 本地工具集(TTS/ASR/剪贴板/通知/文件封装,平台自动降级) / 本地KV缓存(SQLite,与changes契约同构,连后端时无缝迁移) / 离线IR缓存 / 可选本地沙箱(QuickJS,红线不变:库只给沙箱能力,规则用户自导入,官方零内置)。
分发：按端打包(aar/framework/dll/wasm),按需下载,core保持轻小。

## 23.5 勘误
云=认证+配对牵线(不转发数据,旧"云存数据"表述作废)；前端=core+可选全量库(旧"纯壳必须连后端"作废)。



# 卷二 · 施工图纸

## 第1篇 模块详细设计全书v1.3

# ThirdHub 模块详细设计全书 v1.3

> v1.2 · 2026-09-27 · 细化级别：手势/交互级 · v1.1补:个人数据/浏览器/系统架构深描+工具箱手势级全表+我的模块+家庭模式 · 每个模块含：最终形态/交互手势全表/功能清单/架构实现/参照项目(标清"可抄代码"vs"只学设计")
> 许可证铁律：MIT/Apache/BSD/Unlicense=可直接抄；GPL/AGPL=只学设计严禁拷贝（独立APK引擎适配器除外）

---

# 第0章 · 现状核对结论：AI到底在干什么

## 0.1 已核对范围
两仓129个md全部过一遍+四代173版版本史+300条提交+HANDOVER#26+TASKS看板+Releases 20个+密钥库。结论均来自文档实证。

## 0.2 AI实际在做的事（按文档证据）
| 在做什么 | 证据 | 评价 |
|----------|------|------|
| THA/1 Agent协议 | docs/AGENT-PROTOCOL.md+4.43落地 | ✅规格书P2核心已提前实现，full/fallback双模式 |
| CHAT/1离线优先 | docs/CHAT-PROTOCOL.md+12断言 | ✅ |
| 发版流水线 | 14轮发布/digest校验/版本号收归 | ⚠️过度投入(35%火力) |
| 内容链路打磨 | 搜索逐条上屏/鉴权黑洞修复 | ✅ |
| i18n七语言 | I18N-CHECKLIST | ✅ |
| 同步修坏循环 | 4.45打通→4.47→4.49连修 | ❌没按§11契约重建 |
| OS内核层 | 无提交 | ❌零动工 |
| QAuth | 无提交 | ❌零动工 |

## 0.3 规划索引
整改按R0-R3（总会话档案第十六部分）；本书是R1⑤（模块OS层）+P3板块的**施工图纸级**细化。

---

# 第1章 · OS内核/框架层

## 1.1 最终形态
ThirdHub壳=手机OS：悬浮球导航+多模块保活+事件总线+通知中心+全局搜索。

## 1.2 交互手势全表
| 手势 | 行为 |
|------|------|
| 单击悬浮球 | 扇形菜单错峰弹出（Fan Menu Expansion模式11），当前模块高亮，遮罩可关 |
| 长按悬浮球 | 进入拖动，松手吸附最近屏幕边缘（左右） |
| 双击悬浮球 | 回主页/我的（可自定义） |
| 菜单内点图标 | 切模块（动画：旧模块向下滑出冻结快照，新模块从图标位放大进入） |
| 菜单左右滑 | 翻页（手表端每页4图标/手机端8+） |
| 长按菜单图标 | 抖动+删除角标（编辑模式），拖动排序（FLIP动画，OmniHub v2.2.7已做过） |
| 全局边缘右滑 | 返回上一级（Android手势+返回键双适配） |
| 全局下拉 | 通知中心 |
| 全局上滑悬停 | 全局搜索 |

## 1.3 功能清单
模块生命周期四态（运行/保活/冻结/回收）；杀后台三档（不杀/LRU推荐4/切出即杀）；事件总线（模块唯一通信方式）；通知中心（角标+列表+跳转）；全局搜索（跨模块分组展示）；性能推荐值（冷启动<300ms/模块<150MB）；离线语义三级。

## 1.4 架构实现
模块=注册表+独立状态机；Flutter侧用Navigator 2.0多栈（每模块一个栈）；保活用AppLifecycle+自定义ModuleManager；事件总线用EventBus（Dart stream）带防抖500ms（OmniHub v2.2.5已验证）；通知中心=全局NotificationService。

## 1.5 参照项目
| 项目 | 协议 | 怎么用 |
|------|------|--------|
| Venera的Scaffold覆盖层 | 自有(GPL?只学) | 悬浮球菜单/阅读器覆盖层设计 |
| OmniHub v2.2.x(自己的) | 自有 | 悬浮球扇形/FLIP排序直接继承 |
| iOS SpringBoard | — | 只学概念：保活/冻结/回收语义 |

---

# 第2章 · 阅读模块（小说/漫画/听书/有声书）

## 2.1 最终形态
一个阅读器内核，四种内容形态：小说文本流、漫画画廊、听书TTS悬浮球、有声书音频。书架统一，进度统一，换源自动。

## 2.2 交互手势全表（细化到每次触摸）
| 区域/手势 | 行为 |
|-----------|------|
| 点击-屏幕右1/3 | 下一页（curl仿真翻页，模式12） |
| 点击-屏幕左1/3 | 上一页 |
| 点击-屏幕中1/3 | 呼出/隐藏菜单（上下滑入） |
| 点击-顶部状态栏区 | 呼出设置（字号/主题/翻页模式） |
| 左右快速滑动 | 整章跳转（滑到底=下一章动画） |
| **音量键** | 翻页（原生拦截，OmniHub v5.3已验证可行） |
| 长按文字 | 选择文字→复制/批注/查词翻译/搜索本书内 |
| 长按空白 | 临时禁用点击翻页（防误触） |
| 下滑（菜单打开时） | 收起菜单 |
| 底栏拖动 | 章节进度条拖动（拖动时显示章节名+预览） |
| 双指捏合 | 字号缩放（漫画=缩放画面） |
| 漫画-双击 | 智能放大（首次适应宽，双击放大100%） |
| 漫画-长条模式 | 垂直滚动+惯性+预加载下一话 |
| 漫画-日漫源 | 自动右翻模式 |
| 听书悬浮球 | 拖动移位；点按播放/暂停；长按弹出面板(语速0.5-3x/音色/定时/章节跳转) |
| 书架-长按 | 多选（Staggered Bulk Selection模式3） |
| 书架-左滑 | 缓存/删除（Curved Card Deletion模式8） |
| 书架-拖动 | 排序（Drag-to-Reorder模式2） |

## 2.3 功能清单
换源(健康度权重)；追更检查(作业)；全书缓存(作业)；批注→笔记；阅读统计；本地书导入(EPUB/TXT解析)；TTS(系统引擎+备用在线)；字幕式歌词?否(影音)；阅读进度跨端同步(0.5秒粒度)。

## 2.4 架构实现
IR渲染层：novel-ir→段落分页器(按字号/屏高计算页码，页面缓存LRU)；comic-ir→图片预加载(前后各2页,低清占位→高清替换)；TTS=平台系统引擎(Android TextToSpeech/iOS AVSpeechUtterance)前端调,后端可选Edge-TTS；翻页引擎：覆盖式curl(自绘Canvas)/平移式(自绘)/滚动式三模式可切。正文缓存三层：内存LRU→本地DB→后端blob。

## 2.5 参照项目
| 项目 | 协议 | 怎么用 |
|------|------|--------|
| Readium (Swift/Kotlin) | BSD | **可抄**：EPUB解析/分页渲染架构 |
| Legado | GPL | 只学设计：书源管理/换源交互/发现页 |
| Venera | GPL | 只学设计：漫画Gallery/手势(自己的v2.0已做过Gallery可继承) |
| Foliate(桌面) | GPL | 只学设计 |
| flutter_markdown | BSD | 可抄：Markdown渲染(批注笔记用) |

---

# 第3章 · 影音模块（音乐/视频/直播/播客/广播/短剧）

## 3.1 交互手势全表
| 场景/手势 | 行为 |
|-----------|------|
| 视频-双击左/右 | 快退/快进10s（带方向动画） |
| 视频-左右滑动 | 精细seek（±进度，松手生效，显示缩略时间） |
| 视频-左半上下滑 | 亮度调节 |
| 视频-右半上下滑 | 音量调节 |
| 视频-双指放大 | 画面缩放（平移拖动） |
| 视频-单击 | 播放/暂停+控制条显隐 |
| 视频-锁定按钮 | 锁定全部手势（防误触） |
| 视频-下滑（全屏时） | 退出全屏（或PiP） |
| 音乐-歌词长按拖动行 | seek到该行 |
| 音乐-封面左右滑 | 切上/下首 |
| 音乐-播放条下拉 | 展开全屏播放器 |
| 音乐-全屏下拉 | 收起迷你条 |
| 锁屏/通知栏 | 系统媒体会话（封面/控制/进度） |
| 短剧(竖屏)-上滑 | 下一集（短视频流式体验） |

## 3.2 功能清单
睡眠定时/均衡器/倍速记忆(每片独立)/字幕歌词外挂(extra端点)/投屏DLNA/PiP/后台音频/统一最近播放/音质选择(variants)/下载归一。

## 3.3 架构实现
统一播放内核=media3/ExoPlayer(Apache,直接用)；音频焦点管理(来电自动暂停)；媒体会话(MediaSession)全平台；字幕烧录/外挂选择器；DLNA用DLNA投屏库(cling或自实现SSDP)；PiP=平台原生。播客/广播=IR新分支(music-ir扩展)不是新模块。

## 3.4 参照项目
| 项目 | 协议 | 怎么用 |
|------|------|--------|
| ExoPlayer/media3 | Apache | **直接用**，播放内核 |
| ViMusic | GPL | 只学设计：音乐流式体验 |
| NewPipe | GPL | 只学设计：播放器手势/后台 |
| Symphonium(闭源参考) | — | 只学概念 |
| AntennaPod | GPL | 只学设计：播客订阅/断点续听 |

---

# 第4章 · AI模块（Chat/Work/悬浮球/工具/记忆）

## 4.1 最终形态
双运行时：Chat=前端Harness；Work=后端Agent作业中心。THA/1+CHAT/1已落地，本章为体验层细化。

## 4.2 交互手势全表
| 手势 | 行为 |
|------|------|
| 长按消息 | 复制/重新生成/分支/导出(进笔记) |
| 双击消息 | 全文朗读(TTS) |
| 下拉对话顶部 | 加载更早历史 |
| 右滑对话列表项 | 删除/归档 |
| 输入框长按麦克风 | 语音输入(松开发送/上滑取消) |
| 作业卡片点击 | 进Work详情(步骤回放) |
| 悬浮球waiting-confirm | 抖动高亮，点击弹确认卡 |
| 任意界面手指触碰 | 立即暂停AI操作（接管权永远在人） |
| AI操作进行中 | 悬浮球acting态显示当前动作文字 |

## 4.3 功能清单
Chat: 分支分叉/文件夹/全局搜索/多模态(图片/PDF)/导出/语音播报/C-17无缝续跑。
Work: 作业列表/详情步骤回放/确认队列/定时调度(cron)/结果归档/模板/权限scope/断点续跑/通知(webhook/ntfy)。
控制优先级：功能工具→UI指令→语义树兜底→问用户。T0-T3分级。审计日志。

## 4.4 架构实现
已落地协议不重复；体验层：Chat页=ListView+流式渲染(增量diff)；工具卡片折叠展开；确认卡全局Overlay(任何页面可弹)；Work页=作业状态机可视化(queued→running→waiting-confirm→paused→done/error)；定时调度=后端cron表+唤醒。

## 4.5 参照项目
ChatGPT/Claude App交互（闭源参考）；MCP官方SDK(MIT,可抄)。

---

# 第5章 · 个人数据模块（笔记/待办/日记/录音/记账/健康/剪贴板）

## 5.1 交互手势全表
| 模块/手势 | 行为 |
|-----------|------|
| 笔记-下拉 | 新建笔记 |
| 笔记-左滑 | 删除(可撤销,5秒) |
| 笔记-长按 | 多选/移动文件夹 |
| 待办-长按 | 拖动排序/多选完成 |
| 待办-左滑 | 快速改期(今天/明天/下周) |
| 录音-按住麦克风 | 录音(上滑锁定,下滑取消) |
| 记账-主按钮 | 一笔一记(金额→分类→完成,3步内) |
| 日记-日历点日期 | 当天日记(无则新建) |
| 剪贴板-通知栏常驻 | 复制即记录,点通知快速粘贴 |

## 5.2 功能清单+参照
| 分支 | 功能 | 参照(用法) |
|------|------|-----------|
| 笔记 | Markdown/AI摘要/承接对话导出/批注归档/5版本历史 | Simplenote(GPL只学设计)/flutter_markdown(BSD可抄) |
| 待办 | AI提取/购物清单变体/日历联动/重复任务 | Tasks.org(GPL只学) |
| 录音 | 转写+摘要=Work作业/波形显示 | Fossify录音(GPL只学) |
| 日记 | 心情标签/AI周回顾 | — |
| 记账 | AI自动分类/月报=作业 | — |
| 健康 | 手动记录/AI趋势图 | — |
| 剪贴板 | 跨设备同步/敏感内容不入库开关 | — |

## 5.3 架构
全部存后端(collections:notes/todos/diaries/bills/health/clips)；changes游标同步；AI能力=工具注册进Harness(note.create等已实现协议)。

---

# 第6章 · 浏览器模块

## 6.1 交互手势全表
| 手势 | 行为 |
|------|------|
| 左右滑 | 前进/后退(手势距离=动画进度) |
| 下拉 | 刷新 |
| 长按链接 | 新标签/后台打开/下载/复制/分享 |
| 长按图片 | 保存(→相册)/分享/识图(AI) |
| 底栏左右滑 | 切换标签 |
| 地址栏下拉 | 历史/书签/建议 |
| 多标签-长按 | 关闭/锁定 |

## 6.2 功能清单
阅读模式/网页翻译/隐私模式/长截图→相册/UA按站/手势开关/强制夜间/多搜索引擎/广告域名拦截(用户自导入)/书签同步后端/下载接管进下载中心。

## 6.3 架构+参照
flutter_inappwebview(MIT?实际Apache-2.0,可抄)或webview_flutter(Apache)；广告拦截=本地规则匹配(用户自导入,官方零规则)；书签=collection同步。
参照：FOSS Browser(GPL只学)/Via(闭源参考)。

---

# 第7章 · 系统与文件模块（设置/下载/相册/文件/迁移）

## 7.1 交互手势全表
| 场景/手势 | 行为 |
|-----------|------|
| 相册-双指缩放 | 时间轴粒度切换(年→月→日) |
| 相册-下滑 | 关闭查看器(返回网格原位) |
| 查看器-左右滑 | 切换照片(预加载前后各2张) |
| 照片-双指放大/拖动 | 缩放平移(松手回弹) |
| 文件-长按 | 多选/移动/压缩 |
| 下载-左滑 | 暂停/删除 |
| 设置-搜索 | 全局设置搜索(关键词直达) |

## 7.2 功能清单+参照
| 分支 | 功能 | 参照(用法) |
|------|------|-----------|
| 相册 | WiFi自动备份(作业)/哈希秒传/时间轴/地图模式/释放空间/人脸归档(本地模型)/加密柜(SQLCipher,BSD可抄)/版本历史/分享链/整理作业 | Immich(AGPL只学机制)/Aves(GPL只学交互) |
| 文件 | 分类视图/远程访问/加密柜 | Material Files(GPL只学)/rclone(MIT可抄FS抽象) |
| 下载 | 统一队列/离线下载=作业/断点续传 | yt-dlp(Unlicense可用)/Seal(GPL只学) |
| 迁移 | 换后端一键搬家=作业 | — |
| 设置 | 三层scope(cloud/backend/local)+搜索 | — |

## 7.3 架构
blob体系(8MB分块/SHA-256秒传/Range)；changes同步；相册人脸=端上模型(MediaPipe,Apache)不出机。

---

# 第8章 · 工具箱模块（翻译/扫描/二维码/计算器/白板/文本工具/传感器/互传/打印）

## 8.1 交互与参照速查
| 分支 | 核心交互 | 参照(用法) |
|------|----------|-----------|
| 翻译 | 输入即译/截图翻译(圈选)/文档翻译 | 调AI模块(自有) |
| 扫描OCR | 拍照→自动裁边→增强→PDF→存笔记 | ML Kit(免费)/Tesseract(Apache) |
| 二维码 | 扫→智能动作(链接/连后端/加书签) | zxing-android-embedded(Apache可抄) |
| 计算器 | 单位汇率换算 | 自研 |
| 白板 | 画笔/便签存图库 | 自研Canvas |
| 文本工具 | JSON格式化/编解码 | 自研 |
| 传感器 | 尺子/水平仪/取色器 | 平台传感器API |
| 文件互传 | 手机↔后端↔电脑(blob) | 自有 |
| 远程打印 | 后端接打印机 | CUPS协议 |

---


---

# 补篇A · 个人数据架构深描

## 5.4 各分支架构实现
**笔记**：本地DB(Isar/hive)→后端collection(notes)→changes同步；Markdown编辑器自绘(工具栏/快捷符号栏)；AI摘要=调Harness工具note.summarize；版本历史=每条笔记附versions数组(保留5份)；与对话/批注/摘录的汇入走统一import管道(带source标签:chat/reader/browser)。
**待办**：快速添加输入框常驻顶部("+任务 回车即存")；重复任务=RRULE简化版(每天/每周/每月/每年/自定义)；购物清单变体=勾选置底不打折排序；日历联动=到期前30分钟本地通知(Android AlarmManager/iOS本地通知)。
**录音**：按住录音手势(按压 MicButton 实现：onTapDown开始计时/onVerticalDragUp锁定/onTapUp<500ms取消)；波形实时渲染(录音振幅流)；转写=Work作业(ASR先端上whisper.cpp可选,云端API兜底)；转写结果自动建笔记(关联音频blob)。
**记账**：三步记账(金额键盘→分类九宫格→完成)；分类AI学习(用户改分类3次后自动归类)；月报=Work作业(图表:饼图分类+柱状趋势)；数据导出CSV。
**健康**：手动录入(体重/血压/步数)；趋势图(fl_chart)；AI解读=提示词模板,不下诊断结论(合规)。
**剪贴板**：前台Service监听(Android)/UIPasteboard监听(iOS)；敏感模式(银行类正则匹配不入库)；跨端同步走clips collection。

---

# 补篇B · 浏览器架构深描

## 6.4 架构实现
内核选型：**flutter_inappwebview**(功能全:拦截/注入/手势回调)为主,webview_flutter为备选。
**请求拦截栈**：onLoadResource→广告域名匹配(用户自导入的规则文件,本地Trie树匹配,O(1))→拦截返回空响应；_tracker类追踪参数剥离(utm等)。
**阅读模式**：服务端提取(trafilatura,MIT,可抄)或端上Readability.js注入→novel-ir渲染进阅读器(与阅读模块共享排版引擎)。
**长截图**：滚动截图合成(Canvas拼接)→相册blob入库。
**书签/历史**：collections同步;历史保留时长用户设置(默认30天,只推荐不限制)。
**标签系统**：懒加载(未激活标签不建WebView,只留快照);内存超预算时LRU回收WebView保快照。

---

# 补篇C · 系统与文件架构深描

## 7.4 相册备份全流程（招牌）
①前端ContentObserver监听MediaStore→②新照片入队(WiFi+充电条件判断)→③算SHA-256→④问后端"有此哈希?"→⑤无则8MB分块上传(blob)→⑥入库(album collection+缩略图生成,服务端生成三档:256px网格/1024px预览/原图)→⑦多端相册拉changes增量→⑧"释放空间"作业:云端校验哈希一致→删本地→本地留缩略图占位。
**人脸归档**：端上MediaPipe Face Detection(Apache)提特征→本地聚类→用户确认命名→人脸标签入album元数据(特征向量不出机)。
**加密柜**：用户独立密码→SQLCipher(BSD)加密第二库→忘记密码=数据不可恢复(明示风险)。
**文件FS抽象**：学rclone(MIT)的FsDriver接口(本地/后端/远程三实现)→文件管理器/相册/下载中心共用。
**存储分析**：后端按mime/目录聚合→饼图+大文件Top50列表。

---

# 补篇D · 工具箱手势级全表（原速查表升级为逐支交互）

| 分支 | 交互手势全表 |
|------|--------------|
| 翻译 | 输入即译(300ms防抖)；源语言自动检测；截图翻译=截图→圈选区域→OCR→译→悬浮结果卡可拖动；历史左滑删除；收藏上滑置顶 |
| 扫描OCR | 拍照/相册导入→自动裁边(四角手柄可微调)→增强(黑白/原图/增强三档滑动切换)→多页合成PDF→命名→存笔记或分享；连续模式=拍一张自动退格距拍下一页 |
| 二维码 | 扫码对准即识别(震动反馈)；相册导入识别；结果智能动作(链接→浏览器/服务器地址→连后端/文本→复制/WiFi码→直连)；生成码=输入文本实时生成可换色 |
| 计算器 | 上滑出科学键盘；计算历史下拉查看(点击回填)；汇率换算=金额+币种双向；单位换算=类别Tab+左右选择器 |
| 白板 | 双指移动画布/捏合缩放/双击复位；画笔粗细颜色底部栏；长按画布出便签；三指点击撤销/三指双击重做；保存=缩略图+入图库 |
| 文本工具 | JSON格式化(粘贴或导入)→错误行标红点击定位；编码转换Tab(Base64/URL/Unicode/时间戳)；正则测试=实时匹配高亮+分组捕获展示 |
| 传感器 | 尺子=屏幕标尺双单位拖动；水平仪=气泡+数字角度；取色器=取色后显示HEX/RGB/HSL,点击复制 |
| 文件互传 | 发送端:选文件→出二维码/局域网码→接收端扫→直连传输(进度条+速度)；拖拽进窗口(Web端) |
| 远程打印 | 后端CUPS发现打印机→列表选→预览→打印；支持PDF/图片直接打 |

---

# 第9章 · 我的模块（账号中心，补章·手势级）

## 9.1 最终形态
所有端的账号中枢：登录/扫码器/资料/授权/设备/AI日志。

## 9.2 交互手势全表
| 手势 | 行为 |
|------|------|
| 登录页-扫码按钮 | 调起扫码器(QAuth)——**不用输账号密码** |
| 扫一扫 | 全屏取景框(四角动画)+手电筒开关+相册导入识别 |
| 扫码确认页 | 显示"你将登录到：xxx设备/网站"+IP+时间+【确认登录】【拒绝】 |
| 资料页-点头像 | 拍照/相册/恢复默认,上传自动压缩200KB内 |
| 授权列表-左滑 | 撤销该授权(引擎/设备/网站) |
| 设备列表-长按 | 重命名/移除节点 |
| 设置项-点数值 | 输入任意值(推荐值灰字提示,不限制) |
| AI日志-长按条目 | 查看完整工具调用参数(JSON) |

## 9.3 功能清单
登录(Supabase)/QAuth三场景/资料/账号设置三层/授权管理/设备节点管理/AI日志/存储用量显示/会员入口(远期)。

## 9.4 架构
登录=Supabase JWT;QAuth=device_code流程(§6);授权记录存前端本地(KV镜像备份);设备节点=云D1+后端mDNS双源。

---

# 第10章 · 家庭模式（补章）

## 10.1 最终形态
任意模块可开"家庭空间"开关：数据进入共享集合(全家可见可编辑)vs个人集合。

## 10.2 交互手势全表
| 手势 | 行为 |
|------|------|
| 模块内-点家庭图标 | 切换个人/家庭空间(顶部横幅提示当前空间) |
| 共享相册-成员头像行 | 看谁在共享/邀请新成员(出QAuth码) |
| 共享清单-左滑条目 | 认领(标记我买了) |
| 家庭日历-点日期 | 全家日程(个人日程叠加显示,家庭条目红色描边) |
| 权限管理-点成员 | 设权限(只读/可编辑/管理员三级) |

## 10.3 架构
共享集合=后端独立schema(family_*前缀);成员关系=邀请制(QAuth扫码+管理员批准);权限三层在collection层校验。


---

# 深描第二层 · 页面结构/状态机/接口（v1.2）

## D1. OS内核层
**页面结构**：壳(Scaffold: 悬浮球Overlay+通知中心Overlay+全局搜索Overlay) → 模块容器(ModuleHost: 每模块一个Navigator栈) → 模块页。
**核心状态机**：ModuleManager维护 Map<moduleId, ModuleInstance>{state: running|paused|frozen|killed, lastActiveAt, memoryBytes}；事件: onModuleShown/onModuleHidden/onMemoryPressure(LRU淘汰)/onUserKill；状态迁移规则: running→hidden超N分钟(按用户档位)→frozen(快照)→killed。
**对外接口**：ModuleHost.open(moduleId, route?, params?) / ModuleHost.freezeSnapshot(moduleId)→Snapshot / EventBus.emit(topic, payload) / EventBus.subscribe(topic, handler)→unsubscribe / NotifyCenter.push(moduleId, title, body, deepLink) / GlobalSearch.query(q)→GroupedResults。

## D2. 阅读模块
**页面结构**：书架页(搜索栏+分组Tab+网格) → 书籍详情页(封面/简介/目录预览/继续阅读) → 阅读器(正文区+上下滑入菜单+底栏进度) → 漫画阅读器(画廊/长条) → 听书悬浮球(全局Overlay)。
**核心状态机**：书籍状态: unread|reading|finished；阅读器状态: loading|rendering|ready|error；翻页状态机: idle→touchDown(记锚点)→dragging(curl跟随)→release→{settleNext|settlePrev|cancel}；缓存状态: none|metadata|toc|partial(当前章)|full(全书作业中)→full。
**对外接口**：novel.open(bookId, chapterIndex?) / novel.search(q) / reader.getProgress(bookId)→{chapter, offset, percent} / reader.setProgress(...)(0.5s粒度同步) / comic.open(comicId, episode) / tts.start(bookId, chapter)/tts.control(pause|resume|speed|voice) / cache.createJob(bookId)→jobId(THA Work)。

## D3. 影音模块
**页面结构**：音乐页(播放条+歌单+歌词) / 视频播放页(全屏手势层+控制条) / 直播页 / 播客订阅页 / 统一"正在播放"抽屉。
**核心状态机**：播放器: idle→loading→ready→playing|paused|buffering|ended|error；PiP状态: inline→fullscreen→pip(平台回调驱动)；音频焦点: gained→focusLost(短暂duck|永久lost停播)；后台任务: foregroundService(Android)/audioSession(iOS)。
**对外接口**：media.play(ir, quality?) / media.queue.add/remove/reorder / media.seek(ms)/media.rate(x) / lyric.get(trackId) / subtitle.get(videoId, lang) / cast.start(deviceId) / download.createJob(ir)→jobId。

## D4. AI模块
**页面结构**：Chat页(消息流+输入区+工具卡) / Work页(作业列表+详情时间线) / 确认卡Overlay(全局) / 悬浮球(全局)。
**核心状态机**：Chat会话: local(本地权威)→syncing(uplink cid幂等)→synced(seq服务端)；Agent作业: queued→running→{waiting-confirm→(用户批)→running}|paused→done|error|canceled；DSH探活: unknown→full|fallback(60s缓存)。
**对外接口**：chat.send(sessionId, content, cid)→stream / chat.sync(cursor) / agent.createTask(prompt, scope)→jobId / agent.approve(confirmId, allow) / agent.events(jobId)→SSE / tools.invoke(name, params)→result(T0-T2自动,T3弹卡)。

## D5. 我的模块
**页面结构**：未登录页(扫码登录为主按钮) / 已登录页(头像资料+功能列表: 授权管理/设备管理/AI日志/存储用量/设置)。
**核心状态机**：登录态: anonymous→authenticating(JWT校验)→authed(token+refresh)；授权项: granted→revoked(可再授权)；设备节点: online|degraded(心跳30s×3)|offline。
**对外接口**：auth.loginWithQAuth(deviceCode) / auth.refresh(refreshToken) / auth.revoke(target) / devices.list() / profile.update(patch)。

## D6. 系统与文件（相册）
**页面结构**：相册网格(时间轴) → 查看器 → 相册设置(备份开关/释放空间/整理作业)。
**核心状态机**：备份作业: idle→watching(监听)→uploading(分块)→deduped|done|failed；释放空间: scanning→verifying(云端哈希校验)→deleting(本地)→done。
**对外接口**：album.list(cursor)/album.upload(chunk)/album.releaseSpace()→jobId / album.faces()→clusters / blob.create(sha256,size)→{id,chunks}|{id,dedup:true} / blob.chunk(id,n,data) / blob.get(id, range?)。

# 附 · 全书施工顺序

按R0-R3：②同步契约→⑤OS内核(第1章)→阅读/影音(第2/3章,**双主线**)→AI体验层(第4章)→个人数据/浏览器/工具箱(第5/6/8章)→系统与文件深层(第7章)。每个模块开工=先建manifest→按本书施工→更新CHANGELOG。

# 深描第三层 · 实现就绪级（v1.3）

> 在v1.2(手势/结构/状态机/接口)之下再钻一层：数据模型列级/接口字段级/动画参数级/状态机迁移规则表/配置项全表/错误边界。
> 所有数值=工程推荐值(可配置不限制)；所有结构遵守manifest八段式与THP/2.1。

---

# U1 · 全局数据模型（列级定义）

## U1.1 业务collections（后端SQLite/Neon同构）
**shelf**(书架): {id:uuid, bookId:string(IR源ID), title:string, author:string, coverUrl:string, sourceRef:{instanceId,module,id}, group:string(默认"默认"), sortWeight:int, lastReadAt:ts, addedAt:ts, hash:string, owner:backend, sync:cursor}
**reading_progress**: {bookId:string, chapterIndex:int, charOffset:int, percent:float(0-1), updatedAt:ts, owner:cloud(可选同步), sync:cursor} — 0.5s粒度写入,批量1分钟上行
**notes**: {id:uuid, title:string, text:markdown, tags:string[], source:string(chat|reader|browser|manual|agent), refId:string?, versions:[{text,ts}](保5), ts:ts, hash, owner:backend, sync:cursor}
**todos**: {id:uuid, task:string, done:bool, due:ts?, repeat:string(none|daily|weekly|monthly|yearly), priority:int(0-2), list:string(默认|购物), ts, hash, sync:cursor}
**bookmarks**: {id:uuid, url:string, title:string, folder:string, favicon?:string, ts, sync:cursor}
**clips**(剪贴板): {id:uuid, text:string(≤4KB), sensitive:bool(银行正则自动标), ts, ttl:ts(默认30天), sync:cursor}
**connectors**: {id:uuid, type:string(engine|sandbox|official), name:string, endpoint:string, caps:string[], enabled:bool, health:{status:ok|degraded|fail, failCount:int, lastCheck:ts}, priority:int, ts}
**jobs**(作业): {id:uuid, type:string, title:string, status:queued|running|waiting-confirm|paused|done|error|canceled, progress:float, scope:{modules:string[], maxRounds:int, maxMinutes:int}, steps:[{tool,params,result,ts}](append-only), resultRef:string?, createdAt:ts, updatedAt:ts}
**album**(相册): {id:uuid(=blob id), sha256:string(唯一索引), width:int, height:int, takenAt:ts, addedAt:ts, faces:string[](聚类标签), path:string(云blob引用), thumb256:string, thumb1024:string, owner:backend, sync:cursor}
**credits_ledger**(积分流水): {id:uuid, uid:string, delta:int, balanceAfter:int, type:string(recharge|spend|reward|refund), ref:string?, ts} — 不可变,只追加

## U1.2 云KV/D1键规（迁移硬规矩落地）
KV键: `u:{uid}:settings`(JSON≤16KB) / `u:{uid}:anchor:{collection}`(cursor) / `u:{uid}:quota`(R2已用字节)
D1表: devices(id, uid, name, pubkey, caps, online, lastSeen) / verify_log(可选,只记hash+ts不记内容)
R2键: `u:{uid}/avatar.jpg` / `u:{uid}/backup/{yyyy-mm}/{uuid}.enc`

---

# U2 · 配置项全表（settings_schema字段级，scope: cloud|backend|local）

## U2.1 OS内核(framework)
| key | type | default | scope | 说明 |
|-----|------|---------|-------|------|
| killPolicy | enum | lru | local | none不杀/lru/tokill |
| maxAliveModules | int | 4 | local | LRU上限,任意值 |
| ballPosition | enum | right-bottom | local | 悬浮球初始位 |
| ballEdgeSnap | bool | true | local | 吸附边缘 |
| reduceMotion | bool | false(跟随系统) | cloud | 全局减动效 |

## U2.2 阅读(reader)
| key | default | 说明 |
|-----|---------|------|
| fontSize | 18 (14-40任意) | 字号 |
| fontFamily | system | 字体 |
| lineHeight | 1.6 (1.2-2.4) | 行距 |
| pageMode | curl (curl\|slide\|scroll) | 翻页引擎 |
| bgTheme | paper (paper\|dark\|green\|custom) | 背景 |
| volumeKeyPage | true | 音量键翻页 |
| tapZones | thirds (thirds\|half) | 点击分区 |
| ttsSpeed | 1.0 (0.5-3.0) | 语速 |
| ttsTimerMin | 0(关) | 定时停 |
| preloadChapters | 3 (1-10) | 前后预载章数 |

## U2.3 影音(media)
| key | default | 说明 |
|-----|---------|------|
| defaultQuality | auto (auto\|最高) | 画质 |
| playRateMemory | true | 每片记忆倍速 |
| brightnessGesture | true | 左半亮度滑 |
| volumeGesture | true | 右半音量滑 |
| seekStepSec | 10 | 双击步长 |
| sleepTimerMin | 0 | 音乐定时 |
| pipOnExit | true | 退全屏进PiP |

## U2.4 AI
| key | default | 说明 |
|-----|---------|------|
| defaultProfile | standard | 三档profile |
| confirmTimeoutPolicy | deny (deny\|allow-list) | T3超时降级 |
| contextCarry | 20 (任意) | 上下文条数(推荐20) |
| ttsReply | false | 自动播报 |

（个人数据/浏览器/系统配置项同格式展开,各约8-12项,施工时随manifest登记）

---

# D2' · 阅读器实现参数级

## D2'.1 翻页动画参数（curl模式）
- 折痕锚点: 触摸点P(x,y); 翻起角A=以P为圆心的页面翻转模拟,角度θ由拖拽水平距离dx决定: θ = clamp(dx / 屏宽 × 110°, 0°, 105°)
- 背面渲染: 浅色底(#E8E4DC)+内容镜像(水平翻转)+随θ渐隐(不透明度=1-θ/120°)
- 阴影: 折痕处渐变宽=屏宽×0.08,不透明度0.25;翻起页投影随θ增强
- **松手阈值**: |dx| > 屏宽×0.35 → settle翻页;否则→spring回弹
- settle动画: 240ms easeOutCubic 完成剩余角度;回弹: spring(stiffness 400, damping 22)
- reduced-motion: 降级为150ms交叉淡叠
- **数据更新时机**: settle动画onComplete才提交progress(防翻一半存进度)

## D2'.2 分页器算法
输入: 章节纯文本+排版参数(字号/行距/屏宽/屏高/上下边距) → 按\n分段→段内折行(贪心)→高度累加→页边界数组pages[int] → 屏数N。缓存: 当前章分页结果内存常驻,前后章预分页(每章约<10ms)。
## D2'.3 预加载矩阵
当前页±3页图片(漫画) / 当前章±preloadChapters章正文 / 封面懒加载(网格可见区+缓存50)。
## D2'.4 TTS
queue按句子切分(句号/叹号/问号/换行); 每句onBoundary回调高亮当前句; 打断策略: 切章=清队列重灌; 来电=暂停onFocusLost恢复。

## D2'.5 阅读器状态机迁移规则表
| event | from | guard | action | to |
|-------|------|-------|--------|----|
| tapRight | idle | menuHidden | 启动settleNext | animating |
| settleDone | animating | θ≥105°完成 | commit progress(chapter+1) | idle |
| release | dragging | \|dx\|<35%宽 | spring回弹 | idle |
| volumeUp | idle | volumeKeyPage=true | 同tapRight | animating |
| longPressText | idle | — | 进入选择模式 | selecting |
| copy | selecting | 选区非空 | 写剪贴板 | idle |
| annotate | selecting | 选区非空 | 建note(source=reader,ref=书内定位) | idle |

---

# D3' · 影音实现参数级

## D3'.1 手势参数
- 双击检测: 两次点击间隔≤300ms且位移<24px → 左半快退/右半快进,seekStepSec=10,动画: seek指示器(±10s浮标)600ms淡入淡出
- 精细seek: 水平位移dx映射 Δt = dx/屏宽 × 90s;实时显示目标时间+关键帧缩略;松手后seek+缓冲圈
- 亮度/音量滑: 起始需>48px位移防误触;步进=位移/屏高×满量程;实时系统级调节;显示浮标+百分比
- 快进惯性: 滑动速度>1200px/s时映射增益×1.5
## D3'.2 音频焦点
AUDIOFOCUS_GAIN→resume; LOSS_TRANSIENT→pause(duck); LOSS→pause+通知; 电话=瞬态.
## D3'.3 播放状态机迁移表(节选)
| event | from | action | to |
|-------|------|--------|----|
| userTap | ready\|paused | media3.play() | playing |
| bufferStarve | playing | 显示缓冲圈 | buffering |
| buffered | buffering | 隐藏 | playing |
| userBack(全屏) | fullscreen | 退全屏→pipOnExit?进PiP:inline | — |
| focusLost | playing | pause | paused |

---

# D1' · OS内核实现参数级
- LRU淘汰伪代码: onMemoryPressure → 取state==paused且lastActiveAt最旧 → snapshot(保存路由栈参数+滚动偏移+输入草稿) → kill模块(释放Widget树) → 保留snapshot于内存LRU(最多10份,超则序列化落盘)
- 快照字段: {moduleId, route, params, scrollOffset, draft, at} — 恢复时onModuleShown反序列化
- 事件总线topic清单: download.progress/complete/fail · note.created/updated · shelf.changed · media.playing(trackId) · agent.job.updated · album.backup.progress · auth.changed
- 通知deepLink格式: thirdhub://{module}/{route}?id={id} — 点击经框架路由直达

# D4' · AI实现参数级
- 确认卡字段: {confirmId, tool, level:T3, params摘要(人类可读), riskText, expiresAt(默认10分钟), options:[允许一次|允许同类|拒绝]}
- SSE事件类型: agent.step{tool,status} / agent.confirm{confirmId} / agent.done{resultRef} / agent.error{code} / chat.seq{seq}
- 工具调用超时: 单次60s(可配); 作业maxRounds默认20,maxMinutes默认30(用户可改任意)
- C-17续跑: 会话状态{messages最后50条摘要,contextCarry,activeTask}每10s快照入后端;前端复活→先拉快照→再拉SSE续传

---

# U3 · 错误边界全表(模块级)
| 模块 | 错误场景 | 处理 |
|------|----------|------|
| 阅读 | 章节拉取失败 | toast+重试按钮;连错3次提示换源 |
| 阅读 | 书源全失效 | 标degraded+自动搜索替代源(作业) |
| 影音 | 播放地址403 | 自动走variants下一档画质;全失败报SOURCE_BANNED |
| AI | DSH掉线(作业中) | 作业转paused+通知;恢复后续跑(断点=steps数组) |
| 同步 | 冲突(两端同改) | LWW展示"已按最后修改合并"提示;笔记类提供版本对比入口 |
| 相册备份 | 云端配额满 | 暂停作业+通知"配额不足,请清理或扩容" |
| QAuth | 码过期 | 确认页提示"二维码已过期请刷新" |

---

# 施工检查单（每模块完工自检,全勾才算done）
□ manifest八段式已更新 □ 本v1.3对应节已实现(数据模型/配置项/动画参数/迁移表) □ 手势全表逐条过 □ 错误边界全表过 □ thp-check过 □ CHANGELOG已追加 □ 性能预算无红 □ 离线语义标注


## 第2篇 施工指令书（AI模型分化+双端统一）

# 施工指令书：AI模型板块分化 + 双端数据统一

> 2026-09-27 晚 · 优先级：插入R0与R1之间(标为R0.5) · 验收标准见文末

---

## 任务一：AI模型板块问题清单（用户实测反馈）

### 问题1：所有模型类型共用对话输入样式 ❌
现状：TTS模型/音频模型(ASR)/绘画模型/视频模型全都用对话式文本框输入——**明显不符合各自输入方式**。
整改：**按model_type分化输入界面**，模型注册表增加字段：

```yaml
model_entry:
  id: string
  type: chat | tts | asr | image | video | embedding
  input_schema:          # 按类型定义输入表单(自动生成,同settings_schema机制)
    chat:    [文本框, 附件(图/PDF)]
    tts:     [文本框(多行), 音色选择, 语速0.5-3.0, 音调, 情感]
    asr:     [音频上传/录音, 语言选择, 时间戳开关]
    image:   [提示词, 尺寸, 风格, 张数, 参考图上传]
    video:   [提示词, 时长, 比例, 首帧图]
  output_render: chat文本 | 音频播放器 | 图片网格 | 视频播放器
```

### 问题2：模型数据过时 ❌
现状：各厂商模型清单长期未更新（新模型缺失/旧模型已下线仍挂着）。
整改：
1. 内置模型目录改为**云端可更新JSON**（CF-B中转站托管,版本号+更新时间字段）
2. 前端每次进模型页**懒拉取增量**（etag缓存,24h TTL）
3. 手动"检查更新"按钮
4. 模型条目标注更新时间,超90天未核验的显示"可能过时"角标

### 问题3（隐含）：模型能力声明与实际不符
整改：模型条目带capabilities数组(text/image-in/audio-out...),前端按能力过滤可用入口(如不能识图的模型不出现在发图入口)。

---

## 任务二：网页端 ↔ 软件端 真正统一（用户指令原文级）

**要求：数据真正互通，不是只同步账号名。**

| 数据 | 现状 | 整改目标 |
|------|------|----------|
| 账号资料(头像/昵称) | 两端各自存 | 云端唯一,登录即全量拉取 |
| 模型配置/密钥 | 两端各自配 | 存后端settings,两端读写同一份 |
| AI对话历史 | 断点 | CHAT/1协议两端共用(已落地,接通即可) |
| 书源/连接器 | 两端各自管 | 后端/v1/connectors统一管理 |
| 书架/进度 | 不通 | changes契约(R0②)落地后两端同步 |
| 播放器设置 | 两端不同 | 归后端,scope=backend |

**验收硬标准**：在网页端建一本书进书架→打开App,书架里有；App改字号→网页端阅读器字号同步；一端配的API密钥另一端直接可用。

---

## 云端资产分配（用户2026-09-27晚确认版,取代此前分配）

| 资产 | 用途 | 说明 |
|------|------|------|
| CF账号① | **网站部署** | 网页端托管 |
| CF账号② | **中转站** | 给自己用;**可授权给别人用**(授权机制=发访问凭据,后续设计) |
| Supabase账号① | 账号认证 | Auth唯一源(不动) |
| Supabase账号② | 存储 | 用户数据/文件类 |
| Neon账号 | 服务器后台 | 业务库/作业/B类用户托管 |

**CF-B中转站的两个设计要点**：
1. 自用：Workers做API中转(模型API/源站请求经它转发,隐藏真实后端)
2. 授权他人：凭据体系(参照L3 but更轻——生成访问令牌+配额限制),他人经你的中转站消费你自己的额度——**这是会员/积分体系的天然落点**(积分扣在中转站,§13积分体系挂这里)

---

## 施工顺序(插单)
R0②同步契约 → **R0.5本指令书(模型分化+双端统一)** → R0③网站性能 → R1 OS层
原因：模型分化是天天用的体验;双端统一是用户当前最强痛感(比OS层优先)。

## 验收清单
□ model_type分化输入UI上线(5类输入形态可截图验证)
□ 模型目录云端可更新(改云端JSON→前端24h内可见)
□ 双端互通硬标准三条全过(书架/字号/密钥)
□ CF-B中转站Workers跑通自用转发
□ manifest+CHANGELOG已更新


## 第3篇 功能规划v3.0

# ThirdHub 功能规划 v3.0

> 对齐日期：2026-09-21 · 对应：ThirdHub-v2 **v4.32.0（v4.0.0-draft）**
> 定位：仓库 `docs/TASKS.md` 管理 **M1-M5 冲刺看板**（五组并行）；本文档管理 **M5 之后的扩展路线** 与横向功能全景
> 优先级总方针：**前端优先（体感最明显）→ 自用引擎联调 → 资源库数据层 → AI 最后总攻**

---

## 目录

0. [当前状态快照](#0-当前状态快照v4320)
1. [执行优先级总表](#1-执行优先级总表)
2. [M5 之后阶段路线](#2-m5-之后阶段路线)
3. [功能全景与状态](#3-功能全景与状态)
4. [新增模块规划](#4-新增模块规划)
5. [AI 体系深化（最后总攻）](#5-ai-体系深化最后总攻)
6. [商业生态配套](#6-商业生态配套)
7. [附录：参照对象总表](#7-附录参照对象总表)

---

## 0. 当前状态快照（v4.32.0）

**已完成（M1/M2 + 后续迭代）：**

| 领域 | 状态 |
|------|------|
| 四条内容链路 | ✅ 小说/漫画/视频/音乐全流程跑通（Venera/drpy/MusicFree沙箱） |
| 聚合搜索 | ✅ 多源并联 + IR 合并去重 + 动态权重降级 |
| Legado 接入 | ✅ 三自动补丁（自启/mDNS/零输入握手） |
| AI 助手 | ✅ 智能体化（工具调用/MCP/三级上下文注入） |
| 作业中心 | ✅ 已从占位做实 |
| 系统 | ✅ 反馈中心/日志中心/修复面板 |
| 自用引擎 | ✅ **ReadingEngine**（独立书源引擎，THP ok:true/false 信封，端口1234，novel/comic/music/video）——前端测试桩就位 |
| Flutter 主线 | 🚧 ThirdHub-Flutter 阶段0地基 |

**M3-M5（in-flight，见仓库 docs/TASKS.md）：** M3 内置引擎全通 / M4 五端安装包 / M5 多节点互联+BYOC。

## 1. 执行优先级总表

| 优先级 | 阶段 | 内容 | 说明 |
|--------|------|------|------|
| **P0** | M1-M5 冲刺 | 仓库 `docs/TASKS.md` 五组看板（设备协议/Legado适配/能力路由/双前端/内置引擎） | **以仓库看板为唯一进度真相源** |
| **P1** | 前端模块体感 | 五端前端上的模块全面铺开：阅读器细节/播放器细节/浏览器增强/相册UI/下载中心UI/笔记/待办 | **前端优先**，用户看得见 |
| **P2** | 引擎联调 | 用 **ReadingEngine（主）+ ThirdHub-Engine** 跑通前端全链路；打磨 THP/2.1 适配 | 自用引擎=测试桩 |
| **P3** | 资源库数据层 | 后端 blob 传输 + changes/events 同步三件套 + 相册自动备份**真正闭环** | 相册灵魂功能依赖此层 |
| **P4** | 模块大扩展 | 内容类（播客/有声书/短剧）+ 家庭类 + 工具类批量上线（详见§4） | 协议层加 podcast-ir/article-ir |
| **P5** | 商业生态 | L3 身份层（verify端点）+ 授权管理 + 远程引擎接入 + PAYMENT_REQUIRED 交互 | 生态是果不是因 |
| **P6** | **AI 总攻（最后）** | Chat 双模式 + Work 作业中心深化 + 模块工具全注册 + 语义树兜底 + MCP 桥 + 对话无缝续跑 | 工程量大，届时基建全部就位 |
| **P7** | 生态打磨 | Engine SDK / 开发者指南 / 付费墙示例引擎 | 仅自用+验证 |

**派发规则**：每次只领最高未完成优先级；P2 必须在 P1 后；P6 内部顺序：库端 Agent 运行时 → Work 前端 → Chat 调优。

## 2. M5 之后阶段路线

| 阶段 | 版本 | 内容 |
|------|------|------|
| Phase A | v4.4x | P1 前端模块铺开 + P2 引擎联调（ReadingEngine 全链路） |
| Phase B | v4.5x | P3 资源库数据层：blob/同步三件套/相册自动备份闭环/数据迁移 |
| Phase C | v4.6x | P4 模块大扩展（podcast-ir/article-ir 进协议，播客/资讯引擎沙箱或官方应用编排） |
| Phase D | v4.7x | P5 商业生态开放（L3 跑通第一个真实第三方引擎） |
| Phase E | v4.8x | P6 AI 总攻：Work/Chat 双运行时全量落地 |
| Phase F | v4.9x+ | P7 生态打磨；THP 只增不减 |

## 3. 功能全景与状态

### 3.1 阅读（小说/漫画）

| # | 功能 | 状态/归属 | 说明 |
|---|------|-----------|------|
| R-1 | 阅读统计 | 📋 前端+后端 | 时长/字数周报 |
| R-2 | 换源 | 📋 后端路由 | 健康度权重自动换源 |
| R-3 | 阅读批注 | 📋 前端+后端 | 想法→笔记模块 |
| R-4 | 听书TTS | 📋 前端 | 系统TTS |
| R-5 | 漫画双页 | 📋 前端 | 平板横屏 |
| R-6 | 书架批量管理 | 📋 前端 | |
| R-7 | 追更检查 | 📋 后端作业 | 定时→通知（依赖§5 Work） |
| R-8 | 本地书导入 | 📋 前端 | 元数据解析 |
| R-9 | 全书缓存作业化 | 📋 后端作业 | batch+jobs |
| R-10 | 读书摘抄 | 📋 前端+后端 | 划线归档笔记 |

### 3.2 影音（音乐/视频/直播）

| # | 功能 | 状态/归属 | 说明 |
|---|------|-----------|------|
| M-1 | 睡眠定时/均衡器 | 📋 前端 | |
| M-2 | 歌词 extra | 📋 沙箱+前端 | music-ir 歌词字段 |
| M-3 | PiP/后台音频 | 📋 前端 | |
| M-4 | 统一最近播放 | 📋 前端+后端 | |
| M-5 | 投屏DLNA | 📋 前端 | |
| M-6 | 下载归一 | 📋 前端+后端 | 进下载中心 |
| M-7 | 倍速记忆 | 📋 前端 | |
| M-8 | 字幕 extra | 📋 沙箱+前端 | |

### 3.3 浏览器

| # | 功能 | 状态/归属 | 说明 |
|---|------|-----------|------|
| B-1 | 阅读模式 | 📋 前端 | |
| B-2 | 网页翻译 | 📋 前端 | 调AI |
| B-3 | 隐私模式 | 📋 前端 | |
| B-4 | 长截图→相册 | 📋 前端+后端 | 依赖 blob |
| B-5 | 书签同步 | 📋 后端 | bookmark 模块 |
| B-6~B-9 | UA记忆/手势/夜间/多引擎 | 📋 前端 | |
| B-10 | 广告域名拦截 | 📋 前端 | 用户自导入规则，官方不分发 |

### 3.4 相册/文件（招牌区，闭环点在 P3）

| # | 功能 | 状态/归属 | 说明 |
|---|------|-----------|------|
| F-1 | WiFi自动备份 | 📋 后端作业 | ContentObserver→blob；前端被杀照跑 |
| F-2 | 哈希秒传 | 📋 后端 | SHA-256 去重 |
| F-3 | 时间轴/地图 | 📋 前端 | |
| F-4 | 释放空间 | 📋 后端作业 | 校验后清本地 |
| F-5 | 人脸归档 | 📋 前端 | 本地模型 |
| F-6~F-9 | 加密柜/版本历史/分享链/存储分析 | 📋 后端+前端 | |

### 3.5 系统

| # | 功能 | 状态/归属 | 说明 |
|---|------|-----------|------|
| S-1 | 模块市场 | 📋 前端 | 安装/隐藏/排序 |
| S-2 | 多后端/多节点 | 📋 后端 | M5 多节点互联延伸 |
| S-3 | 数据迁移 | 📋 后端作业 | 依赖同步三件套 |
| S-4~S-6 | 深色/长辈儿童模式/模块锁 | 📋 前端 | |
| S-7 | 授权管理 | 📋 前端 | L3 配套 |

## 4. 新增模块规划

| # | 模块 | 接入方式 | 说明 |
|---|------|----------|------|
| N-1 | 笔记 | 后端模块 | 承接批注/摘录/对话导出/AI归档 |
| N-2 | 待办 | 后端模块 | AI提取任务；购物清单 |
| N-3 | 下载中心 | 后端作业 | 统一下载/离线下载 |
| N-4 | 播客 | podcast-ir + 沙箱/编排 | AntennaPod 设计参考 |
| N-5 | 有声书 | audiobook-ir（music-ir扩展） | Audiobookshelf 官方应用编排候选 |
| N-6 | 短剧 | shortplay-ir | drpy 沙箱扩展 |
| N-7 | 资讯 | article-ir | RSSHub(MIT) 生态 |
| N-8 | 家庭共享相册/清单 | 后端 | 多人共用一后端 |
| N-9 | 录音/日记/记账/健康 | 后端模块 | AI转写/回顾=作业 |
| N-10 | 天气/快递/壁纸/菜谱/学习 | 前端 | 公开API型 |
| N-11 | 翻译/扫描/OCR/二维码/白板/工具箱 | 前端 | ML Kit/zxing 可直接用 |
| N-12 | 家庭影院/音乐库/摄像头/智能家居 | 编排+模块 | Jellyfin/HA 官方应用编排候选 |

## 5. AI 体系深化（最后总攻）

| # | 功能 | 说明 |
|---|------|------|
| AI-1 | 模块工具全注册 | 每模块注册功能工具（THP §11） |
| AI-2 | Chat/Work 双运行时 | 前端对话 + 后端作业；对话无缝续跑（会话状态入后端） |
| AI-3 | T3 确认队列 | 作业挂起-重连补批-Chat可批 |
| AI-4 | 声明式UI指令 | navigate/highlight/toast/dialog |
| AI-5 | 语义树兜底 | 未注册模块的读屏控制 |
| AI-6 | AI悬浮球四态+角标 | idle/thinking/acting/waiting-confirm |
| AI-7 | MCP 双向桥 | MCP Server↔THP peer |
| AI-8 | AI审计日志 | 双端统一视图 |
| AI-9 | 定时Agent | "每天7点摘要新闻" |
| AI-10 | 记忆/偏好库 | 跨会话 |

## 6. 商业生态配套

| # | 功能 | 说明 |
|---|------|------|
| E-1 | `/v2/verify` 无状态验签端点 | 云唯一新增 |
| E-2 | 出示身份确认弹窗 + 设备密钥 | Keystore/Secure Enclave |
| E-3 | 授权管理页 | 存前端本地 |
| E-4 | 远程引擎手动添加 + 风险提示 | 官方零分发 |
| E-5 | PAYMENT_REQUIRED 交互 | 跳 meta.ext.paymentUrl |
| E-6 | Engine SDK / 开发者指南 / 示例引擎 | 生态开放时配套 |

**红线（永久）**：不分发引擎、不做推荐位、不审核内容；用户协议第三方免责。

## 7. 附录：参照对象总表

> AGPL/GPL 只学设计严禁拷贝；MIT/Apache/BSD/Unlicense 可直接用。

### A.1 可直接用

| 功能 | 参照 | 协议 |
|------|------|------|
| 播放内核 | media3/ExoPlayer | Apache-2.0 |
| 音乐 | just_audio | BSD |
| Markdown | flutter_markdown | BSD |
| 二维码 | zxing-android-embedded | Apache-2.0 |
| OCR | ML Kit/Tesseract/PaddleOCR | Apache-2.0 |
| FS抽象 | rclone | MIT |
| 加密 | SQLCipher | BSD |
| 下载 | yt-dlp（Unlicense，站点ToS用户自担） | Unlicense |
| RSS生态 | RSSHub | MIT |
| 直播源 | IPTV-org | MIT |

### A.2 官方应用编排（Legado/Komga/Audiobookshelf/Jellyfin/Navidrome/HA）

| 应用 | 协议 | 编排方式 |
|------|------|----------|
| Legado | GPL-3.0 | 官方原版+Web API |
| Komga | MIT | 官方原版+REST API |
| Audiobookshelf | GPL-3.0 | 官方原版+API |
| Jellyfin | GPL-3.0 | 官方原版+API |
| Navidrome | GPL-3.0 | Subsonic 开放标准 |

**红线**：零编译集成、零包名重命名、官方渠道升级。

### A.3 内置引擎沙箱（规则+沙箱，非集成）

| 沙箱 | 来源生态 |
|------|----------|
| drpy | TVBox/drpy 规则 |
| venera | Venera 图源规则 |
| musicfree | MusicFree 音源插件 |

### A.4 只学设计（AGPL/GPL）

Immich（相册备份机制）/ Nextcloud（模块化）/ Syncthing（差量同步）/ Tasks.org / Etar / AntennaPod / Aves / Material Files / FOSS Browser

---

*ThirdHub 功能规划 v3.0 · 与仓库 docs/TASKS.md + docs/THP.md + ARCHITECTURE.md 配套 · THP 只增不减*


# 卷三 · 协议与规范

## 第1篇 THP-2.1协议对齐版

# THP 协议规范 · v2.1 对齐版

> 对齐日期：2026-09-21 · 对应仓库状态：ThirdHub-v2 **v4.32.0（v4.0.0-draft 局域网设备编排架构）**
> **单一事实源**：仓库内 `docs/THP.md`（THP/2.1 共识格式）。本文档为离线主副本 + 规范扩展层，与仓库冲突时以仓库为准，并将差异回写。
> 状态：主版本冻结，此后只增不减。

---

## 目录

1. [定位与铁律](#1-定位与铁律)
2. [角色模型](#2-角色模型)
3. [IR 归一层](#3-ir-归一层)
4. [统一信封](#4-统一信封)
5. [搜索与能力路由](#5-搜索与能力路由)
6. [发现层](#6-发现层)
7. [安全分层](#7-安全分层)
8. [文件传输 blob（v-next）](#8-文件传输-blobv-next)
9. [同步三件套（v-next）](#9-同步三件套v-next)
10. [任务与批量（v-next）](#10-任务与批量v-next)
11. [AI 控制平面](#11-ai-控制平面)
12. [第三方商业引擎与身份层](#12-第三方商业引擎与身份层)
13. [非功能性要求](#13-非功能性要求)
14. [只增不减军规](#14-只增不减军规)
15. [thp-check 一致性测试](#15-thp-check-一致性测试)
16. [法律防火墙与合规](#16-法律防火墙与合规)

---

## 1. 定位与铁律

THP（ThirdHub Protocol）是 ThirdHub 局域网设备编排体系中设备/插件/引擎与后端、后端与前端之间的开放协议。**任何实现 THP 的设备或服务，无需注册、无需审核即可被接入**——广播即连接。

**产品铁律（README 三大铁律，不可违背）：**

1. **前端 = 纯播放器**：永不感知引擎存在，永不接触源格式
2. **能力制搜索路由**：前端只发"我要什么"，后端决定"从哪拿"
3. **全模块化**：游戏/社区/论坛/智能家居等非核心功能全部做成模块

**隐私与安全铁律：**

- 云端只存：账号、头像、设置、身份公钥。**永不存用户内容数据**
- 引擎/插件：规则不出仓库、统一审核源、AS IS 分发、选择性忽略机制
- 搜索聚合页：**无结果不显示引擎名**——只在有结果时标注来源

## 2. 角色模型

| 角色 | 职责 | 状态 |
|------|------|------|
| **前端** | 纯播放器 + IR 渲染器（PWA/Capacitor/Electron/Flutter 四端） | 无状态 |
| **后端** | 编排器：能力路由、并行 fan-out、IR 合并去重、短缓存、设备管理、日志 | 有状态 |
| **官方应用** | Legado / Komga / Audiobookshelf 等**官方原版应用**，后端经其官方 API 编排 | 各自独立 |
| **内置引擎沙箱** | drpy（影视）/ venera（漫画）/ musicfree（音源）QuickJS 沙箱，进程内运行 | 无状态 |
| **第三方设备/引擎** | 实现 THP 的任何 peer（如 ReadingEngine） | 无状态只读 |
| **云** | 认证中心（账号/头像/设置/公钥/verify） | 极轻 |

**核心公理：后端是全部内容能力的聚合面。** 前端只面对后端（或经后端发现的直连通道），永不直接感知引擎差异。

**编排红线（ARCHITECTURE.md）**：与开源应用只做**局域网编排**，不做编译集成——不做壳中壳、不做包名重命名、零合并地狱、各自官方渠道升级。

## 3. IR 归一层

一切来源输出统一转译为中间表示，前端永不感知来源：

| IR | 归一内容 | 现状 |
|----|----------|------|
| `novel-ir` | 书籍元数据/章节列表/正文 | ✅ 已落地 |
| `video-ir` | 影视元数据/剧集/播放地址 | ✅ 已落地 |
| `music-ir` | 曲目/专辑/播放地址/歌词 | ✅ 已落地 |
| `comic-ir` | 漫画元数据/话数/图片列表 | ✅ 已落地 |
| `podcast-ir` | 播客元数据/单集/音频地址 | 📋 v-next（复用 music-ir 扩展） |
| `article-ir` | 资讯/文章正文 | 📋 v-next |

- 方言→IR 映射由**适配器**承担（如 `mapping.ts` 对拍测试），IR 契约是唯一跨组约定
- 新增 IR 类型只追加；未知类型前端显示"暂不支持预览"

## 4. 统一信封

THP/2.1 共识格式，**所有 JSON 响应仅此两种形态**：

```json
{ "ok": true,  "data": ..., "meta": { } }
{ "ok": false, "error": { "code": "...", "message": "...", "upstream": "可选" } }
```

- 失败判断唯一依据：`ok:false`；HTTP 状态码恢复正常语义（200/400/404/429/5xx）
- `meta` 标准字段：`source / latency / cursor / hasMore / deprecated / ext`
- 每响应带 `X-TH-Request-Id` 回显
- 全部 UTF-8；gzip/br；时间戳 ISO 8601 UTC

## 5. 搜索与能力路由

**现状（v4.x）**：`GET /v1/search?type=novel&q=三体&page=1`

- 后端 routes 表 + **并行 fan-out + IR 合并去重** + **动态权重（健康度）自动禁用/恢复** + 短缓存 + request_log 观测
- 前端只声明 `type`，路由决策在后端
- 管理面板"源健康"页可视化

**规范演进建议（不在本期改动）**：`type` 查询参数演进为 `/v1/m/{ir}/search` 路径化——更符合只增不减精神（新端点可并行提供，旧端点保持）。

## 6. 发现层

- **mDNS 为主 + UDP 广播为辅**；插件/设备自启即广播（含端口、caps、instanceId、name）
- **零配置铁律**：下载→安装→后台托管，自启 + mDNS + 零输入握手（插件零配置、零配对）
- 后端维护 devices 表：握手/capabilities 注册
- **心跳状态机**：30s 间隔，3 次失败降级 `degraded`，恢复自动回升
- 优雅下线报文（BYE）+ 唤醒立即重播
- 手动添加 UI 兜底（无 mDNS 环境）

## 7. 安全分层

| 层 | 机制 | 适用 |
|----|------|------|
| **三模式权限**（现状） | 家庭 / 认识的朋友 / 陌生设备，逐级收紧 | 局域网设备接入 |
| **SSRF 防护** | 仅内网/Tailscale 网段可编排 | 后端出向请求硬约束 |
| L1 | 配对 token（`X-TH-Token`） | 敏感设备可选 |
| L2 | 自签 TLS + 指纹确认 | 广域网远程 peer 必选 |
| L3 | 持有证明（见第12章） | 第三方商业引擎 |

- 广域网（非 RFC1918/非 Tailscale）连接必须 TLS + 前端弹风险提示
- 传输加密（可选）：AES-256-GCM，`X-TH-Enc` 头，默认不加密（局域网信任）

## 8. 文件传输 blob（v-next）

相册备份/文件管理的地基，建议随资源库数据层落地：

```
POST   /v1/blob              { sha256, size, mime } → 命中秒传 / 返回分块计划
POST   /v1/blob/{id}/chunks/{n}   分块上传（8MB，校验失败整块重传）
GET    /v1/blob/{id}              下载（HTTP Range）
```

blob 与条目分离：文件是文件，元数据是元数据。

## 9. 同步三件套（v-next）

多端同步最小原子（CouchDB changes feed 思想）：

```
GET /v1/changes?ir=note&cursor=<opaque>&limit=500
→ { data:[{op:"upsert"|"delete", id, item?, hash, ts}], meta:{cursor, hasMore} }
GET /v1/events   (SSE：shelf.ready / sync.cursor / 作业进度)
```

- cursor 不透明且单调；删除为 tombstone；每条目带 hash+ts

## 10. 任务与批量（v-next）

```
/v1/jobs/*        异步任务（queued|running|waiting-confirm|paused|done|error|canceled）
POST /v1/m/{ir}/content:batch   NDJSON 流式批量（单条失败不影响整批）
```

为离线下载、全书缓存、相册整理、Agent 作业铺路。

## 11. AI 控制平面

AI（Harness Agent）通过工具体系控制前端/后端/引擎。**原则：AI 永不模拟触屏，能调功能就调功能。**

**控制优先级（逐级降级）：**
1. **模块功能工具**（`novel.open`/`music.play`…）——首选
2. **声明式 UI 指令**（`navigate`/`highlight`/`toast`/`dialog`/`refresh`/`pending`，经 meta.ext.ui）
3. **语义树读屏兜底**（`ui.state`/`ui.scroll`/`ui.action`）——模块未注册工具时
4. **询问用户**

**双运行时**：Chat = 前端 Harness（交互对话，T3即时确认）；Work = 资源库/后端 Agent 运行时（长任务作业化，前端可杀作业不死，结果落库）。

**工具分级**：T0只读/T1导航/T2交互（自动+审计）/T3危险（删除/支付/授权——只弹确认卡，必须人工点）。

**MCP 互通**：`/v1/tools` 与 MCP tools/list+tools/call 同构；schema 统一 JSON Schema；双向桥（MCP Server 可包成 THP peer；THP peer 可暴露为 MCP Server）。

**审计**：每次工具调用记录（本地存储，「我的→AI日志」）。

## 12. 第三方商业引擎与身份层

- 引擎开发者自己收款、自己存会员、自己判定；ThirdHub 云**只提供无状态验签机** `POST /v2/verify`
- 设备密钥对（安全区生成，私钥不出机），公钥存账号资料；证明 JWT = `{sub, aud, nonce, exp≤5min}` + 私钥签名，防分享/防重放/防串用
- 非会员调付费功能返回 `PAYMENT_REQUIRED`，前端跳 `meta.ext.paymentUrl`
- **红线**：官方不分发引擎、不做推荐位、不审核内容；授权确认页列明"将获得/不会获得"

## 13. 非功能性要求

| 项 | 值 |
|----|-----|
| 心跳 | 30s，3次失败降级，恢复自动回升 |
| 搜索 fan-out | 后端并发请求各源，动态权重，IR 合并去重，短缓存 |
| 日志 | 结构化日志 + request_log 观测 + 日志中心模块 |
| 时间戳 | ISO 8601 UTC |
| 信封体积 | 单响应建议 ≤5MB，超限走 batch 流 |
| SSE 重连 | 指数退避 1s→max 60s |

## 14. 只增不减军规

1. 新增能力 = 加 caps/加字段，永不改已有字段含义
2. 未知字段忽略并透传；未知能力忽略
3. 可选端点必须成文降级行为
4. 新 IR 类型/新错误码/新 caps 只追加进注册表
5. 退役须经 meta.deprecated 预告，≥2个次版本周期
6. 实现本协议即自动接入，无注册无审核——**协议是生态唯一的约定**

## 15. thp-check 一致性测试

输入 peer 地址自动验证：信封格式/状态码一致性/未知字段容忍/心跳状态机/降级行为/SSRF 约束。官方插件与适配器每次发版必过。

## 16. 法律防火墙与合规

- 规则不出仓库；统一审核源；AS IS 分发；选择性忽略机制
- 用户协议明示第三方免责；SELF-HOST 合规声明（docs/TERMS.md + docs/PRIVACY.md）
- 编排红线：只经官方渠道原版应用 + 官方 API，不集成代码
- 身份层（L3）云侧无记录、无注册、不经手钱

---

*THP v2.1 对齐版 · ThirdHub Protocol · 与仓库 docs/THP.md 配套*


## 第2篇 完全规格书v1.0

# ThirdHub 完全规格书（全细节整合版）

> 版本：v1.0 · 2026-09-24 · 整合自：本会话全部讨论（THP协议/功能规划/总体规划/云架构/宪法/模块树/OS层/QAuth/交互技能）
> 原则：本文不做内容精简，所有数字/流程/清单完整保留

---

## 0. 产品定义

ThirdHub = **模块即App的手机OS**。四线产品、七大业务模块+OS内核、全部设置**只给推荐值不给限制值**（超限弹性能警告，不禁止）。

## 1. 四线四仓

| 线 | 仓 | 职责 | 版本体系 |
|----|----|------|----------|
| ①网页端 | ThirdHub-Web | PWA轻入口，云端托管，打开即用 | 独立CHANGELOG |
| ②手机版 | ThirdHub-Flutter | 纯播放器+AI控制；Android/iOS/Win/Mac/Linux一套代码 | 独立 |
| ③电脑版/后端 | ThirdHub-Backend | Node+Web全功能管理界面（参照腾讯WorkBuddy：电脑版全功能+手机版轻客户端）；**可出Android APK（Node内嵌），旧手机变服务器** | 独立 |
| ④完全体 | ThirdHub-Full | 一体化App，内置后端能力，直接下载书源/直接搜索；给没有后端的人，主要自用；旧手机/NAS/电脑都能跑 | 独立 |

iOS红线：App Store只上②（纯播放器，Infuse模式：通用服务器地址栏、零书源零规则、话术"个人媒体中心客户端"）；TestFlight先行；④和引擎永不入App Store。

## 2. 仓库处置（36仓）

现役(GH-A商用)：Backend/Web/Flutter/Full（拆出后）、Downloader、Update、Admin、AI-WorkLog、ai-handbook、wrap-up-notes。
个人(GH-B)：ReadingEngine（从GH-A迁出）、书源工具、实验仓。
归档9：ThirdHub(v3，先移植AI对话/绘画模块再归档)、ThirdHub-Android、ThirdHub-Engine、legado-thirdhub、OmniHub×3、AI-Backup、ThirdHub-Portal。
参考18：打reference标签（legado、yidaRule、keep-alive、any-reader、wuji-tauri、Mineradio-LX-qs、VideoWorld_Android、JustAuth、fqnovel-unidbg、Fanqie-novel-Downloader、videdown、res-downloader、Bili23-Downloader、TVAPP、Lyrico、infinite-canvas、LearnPrompt、Legado-Tauri-Release）。

## 3. 模块树（7大业务模块+OS内核）

| 大模块 | 分支小功能（全部列出） |
|--------|------------------------|
| 1.阅读 | 小说、漫画、听书(TTS)、有声书、播客文字稿、读书摘抄、换源、追更检查、全书缓存、阅读批注、阅读统计、本地书导入 |
| 2.影音 | 音乐、视频、直播、播客、广播、短剧/漫剧、歌词、字幕、投屏、画中画、后台音频、倍速记忆、睡眠定时、均衡器、统一最近播放 |
| 3.AI | Chat、Work作业中心、悬浮球、工具体系、记忆/偏好、技能(10个) |
| 4.个人数据 | 笔记、待办、日记、记账、健康记录、剪贴板 |
| 5.浏览器 | 网页、书签、历史、阅读模式、网页翻译、隐私模式、长截图→相册、UA按站、手势、强制夜间、多搜索引擎、广告域名拦截(用户自导入规则) |
| 6.系统与文件 | 设置、模块管理、下载中心、相册、文件、存储分析、数据迁移 |
| 7.工具箱 | 翻译(文本/截图/文档)、扫描OCR、二维码、计算器/换算、白板、文本工具箱(JSON格式化/编解码)、传感器小工具(尺子/水平仪/取色器)、文件互传、远程打印、悬浮便签、代码片段、Markdown编辑器 |
| 8.OS内核（非业务） | 模块生命周期、事件总线、QAuth扫码认证、通知中心、全局搜索、全平台适配层、设置中心 |

家庭=各模块的"家庭空间"模式开关（共享数据集合），不是模块。内容扩展（播客/有声书/短剧/广播/资讯）=IR新分支，不是新模块。

## 4. OS内核层（本次补全的细节）

### 4.1 模块生命周期
运行中(前台) → 后台保活 → 已冻结(内存快照) → 已回收。每个模块是独立微应用：自己的状态机、自己的数据流、模块间经事件总线通信。

### 4.2 杀后台三档（用户设置）
- 不杀后台：所有打开过的模块全保活（A搜书切B搜音乐真同时跑）
- 智能LRU（推荐）：最大同时在线数N（推荐4，可设任意值），超限杀最久未用
- 切出即杀（省电极速）
**铁律：不设任何上限，只做推荐值。**

### 4.3 三平台后台语义（写死，用户无感）
- Android：真后台（前台Service），音乐可系统级后台播放
- iOS：系统禁止真后台 → 冻结+秒恢复（完整保存搜索词/列表/滚动位置/播放进度，切回毫秒内还原）；音乐借系统音频特权真后台
- Web/桌面：真后台（Web Worker/独立进程）

### 4.4 事件总线（模块间唯一通信方式）
模块A发事件（如 download.complete / note.created），订阅者收；禁止模块间直接读写对方状态。AI编排也走事件总线。

### 4.5 通知中心（本次新增）
各模块通知统一入口：角标（悬浮球红点）、通知列表（按模块筛选）、点击跳转到对应模块对应内容。模块通知全走此通道，禁止各弹各的。

### 4.6 全局搜索（本次新增）
框架层提供跨模块搜索（搜书/搜音乐/搜笔记/搜书签一次出，分组展示）；模块内搜索归各模块。全局搜索同时是AI工具的入口之一。

### 4.7 离线语义（本次新增）
每个模块声明离线能力级别：只读缓存（浏览已缓存内容）/队列写（操作排队联网重放）/不可用。断网时UI明确标识当前可用范围。

### 4.8 模块数据所有权（本次新增）
每个数据集合有唯一owner模块（书架=阅读，书签=浏览器，笔记=个人数据）；其他模块经API只读/按授权写入，禁止跨模块直连数据表。

### 4.9 性能推荐值（本次新增，只推荐不限制）
模块冷启动<300ms、存活模块内存推荐<150MB/个、事件总线延迟<16ms。超限弹"性能警告"卡，一键清理后台，不强制。

### 4.10 错误/空态/加载态规范（本次新增）
全模块统一：加载=骨架屏+流式追加；空态=插画+一句引导+主操作按钮；错误=错误码+重试按钮+上报入口。三种状态由框架组件提供，模块只填内容。

## 5. QAuth扫码认证体系

**原理**：任何端要登录→出二维码→已登录的前端扫→确认→免密通过（类QQ扫码）。技术底座：OAuth2 Device Flow变体，码内只有device_code，凭证明文在已登录端。

| 场景 | 流程 |
|------|------|
| 前端登录后端 | 后端管理界面出码→App"我的→扫一扫"→确认→后端获token |
| 前端登录网站 | 网页出码→App扫→确认页显示"登录到 thirdhub.com？"→网页登录 |
| 设备互授权 | 新设备出码→老设备扫→授权接入（L3引擎授权同通道） |

安全：码token一次性+2分钟过期；确认页显示目标设备名；异地/IP异常加风险提示；任何前端（含轻量）必须带扫码器。

## 6. "我的"模块（账号中心，独立大模块）

登录/注册(Supabase) · 扫码认证器 · 账号资料/头像/设置 · 授权管理(引擎/设备/网站，可撤销，存前端本地) · 设备管理(后端节点/在线状态) · AI日志 · 存储用量 · 会员(远期)

## 7. 全平台适配规范

**Android**：状态栏/导航栏沉浸、手势+返回键双适配、前台Service、动态权限、OEM后台白名单引导（小米/华为/oppo各有自启动入口，做引导页）。
**iOS**：安全区(刘海/灵动岛/圆角)、触控优先级、动态字体、冻结恢复、TestFlight分发、Store话术合规。
**Windows/macOS/Linux**：可缩放窗口、最小化托盘、键盘快捷键、系统媒体键。
**Web/PWA**：标签页即模块、安装到主屏、离线包(v4.44已有)、多标签=多模块并行(天然契合OS层)。

## 8. 云端资产终版 + 免费额度实测

| 资产 | 职责 | 免费额度（2026-09实测） | 关键坑 |
|------|------|------------------------|--------|
| CF-A | 网站+网站配套(公告/更新检查/公共目录查询) | Pages 500构建/月无限带宽；Workers 10万请求/天 | 与CF-B物理分开，不接力额度 |
| CF-B | 边缘数据面：Workers+KV(设置/锚点)+D1(设备清单/配额)+R2(头像/备份)+/v2/verify | Workers 10万/天；R2 10GB+出站免费(=1000用户×10MB)；D1 500万读/10万写每天；KV 100万读/**仅1000写/天** | KV不能当计数器(计数放D1)；1000用户时R2顶格→提前缩可选备份到5MB |
| Supabase(新加坡) | 仅Auth | 500MB库、5万MAU、1GB文件、5GB流量、Edge Functions 50万/月、每账号2个免费项目 | **7天无活动自动暂停**→GitHub Action定时ping保活；auth唯一禁止他处建用户表 |
| Neon | B类用户云端托管库(书架/进度/笔记元数据) | 0.5GB存储+100 CU-小时/月，闲置5分钟归零 | 冷启动300-800ms，配连接池 |
| GitHub-A | 代码组织 | 公开仓库Actions无限 | — |
| GitHub-B | 发行/文档/个人 | 私有2000分钟/月 | — |

存储选区：CF→APAC(SIN/NRT)、Supabase→Singapore、Neon→Tokyo。延迟口径：适量可接受，热路径CF边缘/登录Supabase/数据用户局域网。

多账号安全：无官方数量线；2-3个各干各的=无感；禁止同属性拆账号接力额度、禁止跨账号CNAME(报1014)、注册间隔+固定登录IP。R2到800用户时发公告引导清理。

## 9. 用户分档与数据流

A类(自托管)：前端→自己Node后端→SQLite本地。
B类(云端托管：你/家人/同学/会员)：前端→CF-B Workers→Neon。
**后端存储层=可替换driver(SQLite↔Postgres)，一套代码换driver。**
数据流：登录→Supabase发JWT→CF-B KV拉设置/锚点→A类连用户后端/B类走CF-B→Neon→可选加密备份→R2(超限拒写)。

## 10. THP协议要点（2.1共识版）

信封：`{ok:true,data,meta}` / `{ok:false,error:{code,message,upstream}}`；失败只看ok:false；X-TH-Request-Id回显。
角色：前端纯播放器/后端编排器/官方应用(原版+API)/内置沙箱(drpy·venera·musicfree)/第三方peer/云。
IR归一：novel-ir✅ video-ir✅ music-ir✅ comic-ir✅；v-next: podcast-ir/article-ir。
发现：mDNS为主+UDP为辅；零配置(自启+广播+零输入握手)；心跳30s×3失败降级degraded自动恢复；BYE优雅下线；唤醒立即重播；手动添加UI兜底。
安全：三模式权限(家庭/朋友/陌生)+SSRF仅内网/Tailscale；L1配对token/L2自签TLS指纹/L3持有证明；广域网必TLS+风险提示；可选AES-256-GCM。
搜索：现状`/v1/search?type=`，演进`/v1/m/{ir}/search`(新旧并行)。
错误码：UPSTREAM_FAIL/NOT_FOUND/UNSUPPORTED/RATE_LIMIT/AUTH_REQUIRED/PAYMENT_REQUIRED/SOURCE_BANNED/RULE_BROKEN/TIMEOUT/PAYLOAD_TOO_LARGE/CAP_UNAVAILABLE。
军规：只增不减/未知忽略/可选端点成文降级/ext字段兜底。
v-next：blob(8MB分块+SHA-256秒传+Range)、changes(cursor单调+tombstone)+SSE events、jobs(queued|running|waiting-confirm|paused|done|error|canceled)、NDJSON批量、/v1/tools。
thp-check：信封/状态码/未知字段容忍/心跳/降级/SSRF，发版必过。

## 11. 数据同步

LWW(hash+ts)默认；笔记类5版本历史；changes游标同步；同步锚点存CF-B KV；冲突时后写胜出+可回滚。

## 12. AI体系

双运行时：Chat=前端Harness(交互对话)；Work=后端Agent运行时(作业=job，前端可杀作业不死，waiting-confirm挂起重连补批，paused断点续跑)。
控制优先级：功能工具→声明式UI指令(navigate/highlight/toast/dialog/refresh/pending)→语义树读屏兜底→问用户。**永不模拟触屏**。
工具分级：T0只读自动/T1导航自动/T2交互自动+审计/T3危险(删除/支付/授权/改设置)只弹卡必须人工。
悬浮球四态：idle/thinking/acting(显示动作文字)/waiting-confirm(抖动高标)；Work进展=角标。
C-17对话无缝续跑：会话状态实时入后端，生成中前端被杀→后端接管→重连断点续聊。
MCP双向桥(MCP Server↔THP peer，JSON Schema统一)。
审计日志：每次工具调用记录(时间/工具/参数/结果/是否人工确认)，本地存储，「我的→AI日志」。
技能10个：翻译/联网搜索/日历系统指令/记忆/代码/调试/文件/交付检查/交互设计。

## 13. 交互设计技能（13模式，全英文Prompt已固化）

1 Radial Theme Transition(深色切换) 2 Drag-to-Reorder 3 Staggered Bulk Selection(批量管理) 4 Velocity-Based Slider Snap 5 Animated Text Disclosure 6 Spring Stepper Progress 7 Ripple Feedback for Related Switches 8 Curved Card Deletion(左滑删) 9 Stacked Card Scroll 10 Expanding Tag Selection 11 Fan Menu Expansion(悬浮球扇形) 12 Reader Page Curl(翻页完才更新进度) 13 Cross-Module Drag(跨模块拖拽)。
输出四段式：Selected interaction/Why it fits/Interaction behavior/Copyable prompt(纯英文)。判断四问：变化从哪开始/落在哪/谁跟着动/周围让不让位。

## 14. 引擎隔离（组织级+代码级+发布级）

GH-A商用仓：零书源/零规则/零引擎代码/零依赖引用/零git历史；只引用THP协议**文档**；Release永不捆绑引擎APK。
GH-B个人仓：ReadingEngine+引擎+实验；README写"个人学习用途"。
通信只经THP HTTP（独立软件互操作）。
归档处置见第2节。

## 15. L3商业生态（全细节）

引擎开发者：自己收款/自己存会员/自己判定。
云只加：`POST /v2/verify`无状态验签（不存记录不存证明）+账号公钥字段。
设备密钥对：安全区生成(Keystore/Secure Enclave)，私钥不出机；换机新钥覆盖旧钥自动吊销旧设备。
证明JWT：{sub账号标识, aud引擎标识, nonce, exp≤5分钟}+私钥签名。防分享(无私钥签不出)/防重放(5分钟+nonce一次一换)/防串用(aud绑定)。
流程：绑定(付费时扫码→verify→开发者存{accountId:会员})；引擎启动验证(新nonce→新证明→verify→查自家会员表)。
PAYMENT_REQUIRED→前端跳meta.ext.paymentUrl。
四不红线：不分发引擎/不做推荐位/不审核内容/免责文本。

## 16. 娱乐板块功能全清单

阅读：R-1阅读统计(时长/字数周报) R-2换源(健康度权重自动) R-3阅读批注→笔记 R-4听书TTS(系统) R-5漫画双页(平板) R-6书架批量管理 R-7追更检查(定时作业→通知) R-8本地书元数据解析 R-9全书缓存作业化(batch+jobs+进度推送) R-10读书摘抄(归档笔记)
影音：M-1睡眠定时/均衡器 M-2歌词extra M-3 PiP/后台音频 M-4统一最近播放 M-5投屏DLNA M-6下载归一(进下载中心) M-7倍速记忆 M-8字幕extra

## 17. 其他板块功能全清单

个人数据：笔记(承接对话导出/批注/摘录/AI归档) 待办(AI提取/购物清单/日历联动) 录音(转写+摘要=作业) 日记(AI周回顾) 记账(AI分类/月报) 健康(AI趋势) 剪贴板(跨设备) 通讯录备份(加密) 短信备份
系统与文件：模块市场(安装/隐藏/排序) 多后端/多节点 数据迁移(作业) 深色自动 长辈/儿童模式 模块级应用锁 授权管理 Chat/Work模式设置+作业scope+确认超时策略 下载中心(统一/离线下载=作业) 相册(WiFi自动备份ContentObserver/哈希秒传/时间轴地图/释放空间/人脸归档本地/加密柜SQLCipher/版本历史/分享链/存储分析/整理作业) 文件
工具箱/家庭/内容分支：见第3节模块树。

## 18. 文档治理与AI工作法

manifest.yaml八段式(id/name/icon/status/version/routes/features/settings_schema[scope:cloud|backend|local]/logic/data_collections/tools/dependencies/changelog)。
MASTER.md由manifest自动生成(禁手写)；MASTER-CHANGELOG每次改动必追加。
七步SOP：读(手册+总清单+WorkLog+manifest)→述(目标≤5行等确认)→划(改动清单等确认)→做(只改确认范围)→记(manifest+CHANGELOG)→测(thp-check过)→交(三句话摘要进AI-WorkLog)。
十二铁律见项目宪法（引擎隔离最高/auth唯一/云端零内容/协议只增不减/改代码必改清单/意图确认制/优先级冻结/版本号单一来源/CHANGELOG独立/前端纯播放器/编排非集成/推荐值不限制值）。

## 19. 优先级v5（双主线同进度，无时间线）

P0 引擎隔离+仓库归档收缩+四仓拆分+清单体系
P1 数据互通(账号全量/设置三层/书架进度同步)
P2 双主线：M-A1阅读链路↔M-B1 Chat → M-A2影音链路↔M-B2 Work → M-A3内容分支↔M-B3 AI控制全模块
P3 个人数据/浏览器/工具箱分支
P4 系统与文件深层(blob/同步三件套/相册闭环/后端APK/storage driver)
P5 商业L3 → P6 引擎SDK(自用验证)

## 20. Linux迁移路线（设计约束，现在不建不迁）

路线A(首选)：CF边缘不动→Cloudflare Tunnel(免费)→自有服务器当源站，零数据搬迁。
路线B(终极)：自托管Supabase(开源Apache-2.0)，pg_dump迁auth+JWT secret必带走+storage S3同步。
现在三条硬规矩：KV/D1键全带uid前缀；Workers只做读缓存→转发，业务逻辑不进CF；每月Action自动导出KV/D1快照到Release。

## 21. 遗留项清单

ReadingEngine协议版本号统一(自称1.0→2.1)｜老PWA的AI对话/绘画模块移植｜搜索路由演进(新旧并行)｜iOS TestFlight先行｜R2 800用户时配额公告策略｜Supabase保活Action｜四仓拆分后的版本号起号

## 22. 积分体系（新增）

**定位**：平台内唯一货币。买会员、买扩展空间、远期打赏引擎开发者，全部花积分。

**铁律（合规红线）**：单向充值不可提现 / 不可转账（用户间禁止）/ 仅限平台内消费。做到=合法会员积分。

**规则**：1元=10积分（推荐值）；充值渠道=微信支付(正式)+个人收款过渡(无商户号期手动发放)；消耗=会员积分/月、空间扩展积分/GB/月；账本=D1 credits_ledger不可变流水+KV余额快读；远期=签到/任务/AI作业奖励。

**微信支付模块**：独立模块，交给AI按七步SOP实现。商户号需营业执照，无主体前用过渡方案；回调验签+幂等+先记账后发货。

## 23. ⑤号线：微信小程序端（新增）

仓=ThirdHub-MiniProgram；技术=Taro或uni-app(复用manifest渲染层)；定位=播放器+AI控制连用户后端；独立CHANGELOG。**五线终版=网页/Flutter/后端/完全体/小程序**。审核预期：阅读类+外部内容审核极严，定位"个人媒体中心"，被拒不意外，预留裁剪版(纯播放器+笔记)。小程序虚拟支付：iOS禁、安卓需虚拟支付接口，与积分体系打通时再处理。

## 24. 账号核查记录（2026-09-24）

记忆中GitHub仅1个(Smalluniverseheng，token 2026-11-17过期)→GH-B小号凭证待用户提供；腾讯云/Supabase/CF各1套在位。待办：11-17前换token；GH-B到位后执行引擎隔离。

## 25. 立法修正案（2026-09-27审计后入宪）

**修正案1·双信封边界**：THP=对外生态信封 `{ok,data}`（引擎/设备/第三方实现）；`/v1`家族+THA/1+CHAT/1=内部信封 `{object,data}`（理由：历史兼容，两处断言数已固化）。新协议默认归内部家族。禁止以"统一"为目的的返工。

**修正案2·干净源定性**：后端包内置的15条白名单源=人工审核的公版/正版源，与用户自导入源**分轨管理**；白名单清单公开可查、可整体撤销（已有10条撤销机制）；定性写入用户协议与法律防火墙章节。

**审计结论存档**（300提交/14天）：发版机械35%/性能7%；同步根因=§11契约未实施（两端各读各的表）；整改按R0-R3执行（见会话总清单G节）。


## 第3篇 AI开发总清单规范

# ThirdHub AI 开发总清单规范（MASTER Inventory）

> 定版：2026-09-24 · 配套：ARCHITECTURE.md / docs/THP.md / docs/TASKS.md
> 目的：任何AI/创作者接手时，**只读这一份清单就能知道每个模块有什么、设置什么、逻辑是什么、改到哪了**。

---

## 一、三层文档体系（谁是真相源）

| 层 | 文件 | 性质 | 谁维护 |
|----|------|------|--------|
| 机器层（唯一事实源） | `modules/{id}/manifest.yaml` | 模块声明：功能/设置schema/工具/数据集合 | **AI每次改动必须更新** |
| 索引层（人读） | `docs/MASTER.md` | 从 manifest 自动生成，禁止手写 | CI 生成，AI不直接改 |
| 变更层 | `docs/MASTER-CHANGELOG.md` | 每次变更一条：日期/模块/改了什么/为什么 | AI每次改动必须追加 |

**规则：AI改代码不改清单 = 任务未完成。** 新AI接手顺序：MASTER-CHANGELOG → MASTER.md → ARCHITECTURE.md → TASKS.md。

---

## 二、manifest.yaml 标准模板

```yaml
# modules/novel/manifest.yaml
id: novel                      # 全局唯一，禁止改名（改名=新模块）
name: 小说
icon: 📖
status: stable                 # planned | dev | stable | deprecated
version: 4.44                  # 模块自身版本

routes:                        # 前端路由声明（Web/Flutter按此生成入口）
  - { path: shelf, name: 书架 }
  - { path: reader, name: 阅读器 }

features:                      # 功能清单（AI逐项打勾，接手者一眼看懂完成度）
  - { id: shelf_sync, name: 书架同步, status: done, note: changes游标同步 }
  - { id: tts, name: 听书, status: planned }
  - { id: batch_cache, name: 全书缓存, status: dev, note: 依赖后端jobs }

settings_schema:               # 设置项schema——两端按此自动生成设置页
  - { key: font_size, type: number, default: 18, scope: backend, label: 字号 }
  - { key: page_turn, type: enum, options: [slide, curl, none], scope: backend }
  # scope: cloud=账号级(云) / backend=设备级(后端) / local=会话级(前端)

logic:                         # 业务逻辑要点（AI用文字写清特殊规则/边界）
  - 换源规则: 健康度权重自动选择，连续3次失败降权至degraded
  - 正文归一: 一律经 novel-ir，前端永不接触源格式
  - 边界: 单章正文>5MB时截断并提示

data_collections:              # 本模块的数据集合（同步管道自动覆盖）
  - { name: shelf, sync: cursor, owner: backend }
  - { name: reading_progress, sync: cursor, owner: cloud }   # 进度小，可入云

tools:                         # AI工具注册（THP §11）
  - { name: novel.open, level: T1, params: { bookId: string, chapterIndex?: int } }

dependencies:                  # 依赖关系
  modules: [note, download]
  protocol: [/v1/m/novel/search, /v1/jobs]

changelog:                     # 模块级变更（每次改必加一行）
  - { date: 2026-09-21, change: 换源接入动态权重, why: M2验收要求 }
```

## 三、AI 工作守则（每次任务）

1. 开工前：读 `docs/MASTER-CHANGELOG.md` 最近20条 + 本模块 manifest
2. 改动后：**必须**更新对应 manifest（features状态/settings_schema/logic/changelog）
3. **必须**追加 `docs/MASTER-CHANGELOG.md` 一条：`[日期] [模块] 改了什么 → 为什么 → 影响面`
4. 新模块 = 新建 `modules/{id}/manifest.yaml` + MASTER.md 自动收录
5. 设置项新增 = 只加 schema 字段，禁止手改两端设置页代码
6. 任务结束输出交接摘要（供写入 AI-WorkLog 仓库）：
   `完成项 / 未完成项 / 给下一个AI的三句话`

## 四、云端 10MB 配额分配表（数据分级唯一口径）

| 存哪 | 内容 | 上限建议 |
|------|------|----------|
| ☁️ 云（CF） | 昵称/签名 | 4KB |
| ☁️ 云 | 头像（服务端强制压缩） | 200KB |
| ☁️ 云 | 账号设置（主题/语言/主页/模块开关） | 16KB |
| ☁️ 云 | 设备节点清单（名称/公钥/caps/状态） | 32KB |
| ☁️ 云 | 同步锚点（各集合cursor） | 16KB |
| ☁️ 云 | L3公钥+授权记录 | 8KB |
| ☁️ 云(可选,默认关) | 笔记/待办/书签加密文本备份 | 占剩余配额 |
| ☁️ 云(可选) | 阅读/播放进度 | KB级，含在上面 |
| 🏠 用户后端 | 一切媒体文件(blob)、书架主体、连接器/书源、播放器细粒度设置、审计日志、AI记忆、作业历史 | 不限 |
| ❌ 永不 | 用户内容明文上云 | — |

超限处理：拒绝写入+提示清理；头像服务端校验尺寸。

## 五、多端冲突策略（预设，勿临时发挥）

- 默认 LWW：同条数据 `hash+ts` 最后写入胜出
- 笔记类额外保留 5 个历史版本（可回滚）
- 同步锚点（cursor）单调不回退

---

*MASTER Inventory · AI与创作者的共同契约*


# 卷四 · 守则与参考

## 第1篇 项目宪法与执行手册

# ThirdHub 项目宪法与执行手册（给AI）

> 版本：v1.0 · 2026-09-24 · **任何AI（包括本AI）在任何会话开始时必须先读本手册全文**
> 配套：《调研报告-给王珩宇》/《会话总清单》/ THP-2.1 / 总体规划v2.0修订2

---

## 第0条 · 阅读顺序（每次新会话）

```
1. 本手册（宪法）
2. ThirdHub-会话总清单.md（最新状态锚点）
3. AI-WorkLog 仓库最近3条交接摘要
4. 被指派任务涉及的模块 manifest
```

## 第1条 · 十二铁律（违反任何一条=任务作废）

1. **【引擎隔离·最高】** 商用线仓库（GH-A组织下所有仓）禁止出现：书源/影视规则/音源插件/任何"源"内容、引擎实现代码、对上述内容的引用（依赖/子模块/git历史）。引擎只以 **THP协议HTTP接口** 的形式存在。发现历史遗留立即上报，禁止"顺手清理"不报告。
2. **【双账号隔离】** GH-A=商用线；GH-B=个人线（引擎/实验）。任何代码、文档、Release不得跨流。本AI没有GH-B的操作授权时，只讨论不执行。
3. **【auth唯一】** 认证只在 Supabase（新加坡区）。禁止在任何其他地方建用户表/会话/密码逻辑。CF-B 只存"登录后"数据，验人靠Supabase JWT。
4. **【云端零内容】** CF-B只存：设置/锚点/头像(≤200KB)/设备清单/配额计数/L3公钥/可选加密备份（10MB/用户）。任何书籍/漫画/音视频/照片正文永不入云。Neon只存B类用户的元数据（书架/进度/笔记），同样零媒体。
5. **【协议只增不减】** THP/2.1共识格式 `{ok:true/false}`。新增只加字段/caps，禁止改已有结构。
6. **【改代码必改清单】** 动了任何模块 → 更新其 manifest.yaml + 追加 MASTER-CHANGELOG.md 一条。没改清单=任务未完成。
7. **【意图确认制】** 接到任务先输出"我理解的目标是：…"（≤5行），**用户确认后才动手**。禁止自作主张扩展范围。
8. **【优先级冻结】** 任务优先级以《会话总清单·G节》为唯一依据。AI禁止重排、禁止"顺手先做别的"。发现冲突→上报，不执行。
9. **【版本号单一来源】** 版本只在一处定义（各仓 package.json/worker.toml 的唯一VERSION常量 + CHANGELOG），禁止散写。
10. **【四仓CHANGELOG独立】** Backend/Web/Flutter/Full各写各的，禁止合并叙述。
11. **【前端纯播放器】** 前端永不感知引擎；能力制路由（前端只发"我要什么"）；IR归一（novel-ir/video-ir/music-ir/comic-ir）。
12. **【编排非集成】** 开源应用（Legado/Komga/ABS/Jellyfin）只经官方原版+官方API编排。禁止包名重命名/代码合并/壳中壳（legado-thirdhub路线已死）。

## 第2条 · 架构事实（不得凭记忆发挥，以本节为准）

### 四线四仓
| 线 | 仓 | 职责 |
|----|----|------|
| ①网页端 | ThirdHub-Web | PWA轻入口，云端托管 |
| ②手机版 | ThirdHub-Flutter | 纯播放器+AI控制，跨五平台 |
| ③电脑版/后端 | ThirdHub-Backend | Node+Web管理界面+编排+插件体系，**可出Android APK（Node内嵌）** |
| ④完全体 | ThirdHub-Full | 一体化App（内置后端能力），给无后端的人，主要自用 |

参照：腾讯WorkBuddy（电脑版全功能+手机版轻客户端）。

### 用户分档
- A类（自托管）：前端→自己的Node后端→SQLite本地
- B类（云端托管：管理员/家人/同学/会员）：前端→CF-B Workers→Neon
- **工程要求：后端存储层=可替换driver（SQLite ↔ Postgres），同一套代码换driver部署**

### 云端资产（最终分配）
| 资产 | 职责 |
|------|------|
| CF-A | 网站+网站配套（公告/更新检查/公共目录） |
| CF-B | Workers+KV(设置/锚点)+D1(设备清单/配额)+R2(头像/备份10MB)+/v2/verify |
| Supabase | 仅Auth（开源Apache-2.0，可自托管，迁移路线B：pg_dump+JWT secret必带走） |
| Neon | B类用户云端托管库（书架/进度/笔记元数据） |

### 数据流
```
登录→Supabase发JWT
→CF-B KV拉设置/锚点
→A类: 连用户Node后端(Neon不介入)
→B类: CF-B Workers→Neon
→可选加密备份→CF-B R2(10MB配额,Worker计数,超限拒写)
```

### 延迟口径
适量延迟可接受，不追极致。热路径走CF边缘、登录走Supabase、数据走用户局域网/云近区。存储选区：CF→APAC(SIN)、Supabase→Singapore。

## 第3条 · 仓库地图与代码流向

| 流向 | 规则 |
|------|------|
| GH-A（商用） | ThirdHub-Backend / -Web / -Flutter / -Full / ReadingEngine⚠️待迁出 / -Downloader / -Update / -Admin / AI-WorkLog / ai-handbook / wrap-up-notes |
| GH-B（个人） | ReadingEngine(迁入) / ThirdHub-Engine(归档前) / 书源工具 / 实验仓 |
| 待归档 | ThirdHub(v3) / ThirdHub-Android / ThirdHub-Engine / legado-thirdhub / OmniHub×3 / AI-Backup / ThirdHub-Portal（先移植AI对话/绘画模块再归档） |
| 参考只读(18个) | 见会话总清单B节，打reference标签 |

**代码复用铁规**：
- 协议客户端SDK：TS一份（Web/Backend用），Dart一份（Flutter用），逻辑同源同构，改协议两处同步改
- IR定义（novel-ir等）：单一schema文件，两端生成类型
- 模块manifest：两端按schema渲染设置页，**禁止手写两套设置页**

## 第4条 · 模块manifest规范（每次动模块必须更新）

```yaml
id / name / icon / status / version
routes: [{path, name}]
features: [{id, name, status: planned|dev|done, note}]
settings_schema: [{key, type, default, scope: cloud|backend|local}]
logic: [业务规则文字描述，含边界与异常]
data_collections: [{name, sync: cursor, owner}]
tools: [{name, level: T0-T3, params}]
dependencies: {modules, protocol}
changelog: [{date, change, why}]
```

AI输出代码前，先确认对应 manifest 的 features 状态；完成后更新。

## 第5条 · 任务执行SOP（每任务必走七步）

```
① 读：手册+总清单+WorkLog最近摘要+相关manifest
② 述：输出"我理解的目标是…"（≤5行）→ 等用户确认
③ 划：给出改动文件清单+影响面（≤10行）→ 等确认
④ 做：只改确认过的范围，不扩展
⑤ 记：更新manifest + MASTER-CHANGELOG
⑥ 测：thp-check / 构建通过
⑦ 交：输出交接摘要（完成项/未完成项/给下一个AI的三句话）→ 用户写入AI-WorkLog
```

## 第6条 · AI控制平面（P2核心体验的实现依据）

- 控制优先级：功能工具→声明式UI指令→语义树读屏兜底→问用户（**永不模拟触屏**）
- 工具分级：T0只读/T1导航/T2交互(自动+审计)/T3危险(删除/支付/授权——只弹确认卡，必须人工)
- 双运行时：Chat=前端Harness；Work=后端Agent运行时（作业=job，前端可杀作业不死，waiting-confirm挂起-重连补批）
- 悬浮球四态：idle/thinking/acting/waiting-confirm
- MCP双向桥；审计日志本地
- 技能9+1：翻译/联网/日历/系统指令/记忆/代码/调试/文件/交付检查 + 交互设计(13模式库)

## 第7条 · 当前优先级（冻结版，见总清单G节v3版）

P0 引擎隔离+仓库收缩+清单体系 → P1 数据互通 → **P2 AI核心体验** → P3 板块铺开 → P4 后端数据层+后端APK → P5 内容扩展 → P6 商业L3 → P7 引擎SDK
**变更权只在用户。**

## 第8条 · 反模式清单（看到立即停止）

- 想把书源/规则"临时"放进商用仓调试 → 停止，去GH-B
- 想给前端加"直接请求某个源站"的逻辑 → 停止，违反前端纯播放器
- 想把数据"先存云再说" → 停止，对照第2条数据分级
- 觉得"这个改动太小不用更新清单" → 停止，没有小改动
- 想顺手重构无关代码 → 停止，只改确认范围
- 发现优先级冲突 → 上报用户，不自行裁决

## 第9条 · 后端配置拓扑（防止理解漂移）

```
用户设备(旧手机/电脑/NAS/Linux服务器)
└── Node后端(可APK形态)
    ├── 存储driver: SQLite(A类) | Postgres-Neon(B类)
    ├── 设备编排: mDNS发现/心跳30s×3降级/THP握手
    ├── 插件体系: 沙箱(QuickJS: drpy/venera/musicfree规则)
    ├── 官方应用编排: Legado(Web API)/Komga/ABS(官方原版,零集成)
    └── 日志: 结构化+request_log

云端
├── CF-A: Pages(网站)+Workers(公告/更新/目录查询)
├── CF-B: Workers(API)+KV+D1+R2+verify
├── Supabase(新加坡): Auth唯一
└── Neon: B类用户库(东京/新加坡)
```

---

*本手册由用户批准生效。任何AI自称"读完并理解"后仍违反第1条任一款，该会话全部产出作废。*


## 第3篇 交互技能13模式

# Skill: interaction-design · ThirdHub 高级交互动效设计

> 收编日期：2026-09-24 · 来源：Advanced Interaction Design 模式库
> 接入方式：AI系统内置技能（技能注入体系第9个），用户输入 `@交互设计` 或描述界面交互需求时自动启用
> 维护规则：新增模式只追加进模式库清单，不改已有模式定义

---

## 作用

当用户描述一个APP/网页/小程序的界面交互时，先判断这个需求真正适合哪一种交互模式，再把需求整理成可以直接交给AI的实现指令（英文提示词）。

这不是一个视频制作Skill，也不是让AI随便给界面加动画。重点是判断：

- 变化从哪里发生；
- 用户的操作最后落在哪里；
- 哪些元素需要跟着变化；
- 周围内容是否需要主动让位；
- 动画结束后，用户应该看到什么结果。

## 使用规则

1. 先理解用户要完成的任务，再选择交互类型，不要看到"动画"两个字就直接添加通用淡入淡出。
2. 默认选择一个最匹配的主交互。如果一个需求确实包含多个交互，拆成主交互和辅助交互，并说明两者的关系。
3. 保留用户已有的视觉风格、组件结构和技术栈，不要改写无关页面。
4. 描述交互时必须写清楚触发方式、开始状态、变化过程、结束状态和失败或取消状态。
5. 需要实现代码时，再根据用户指定的技术栈输出代码；用户只要提示词时，不要擅自输出完整项目代码。
6. 所有 Copyable prompt 必须使用英文，方便用户直接复制给其他 AI。不要在英文提示词中混入中文。
7. 不要把"更高级""更有质感""更顺滑"当作完整需求，必须翻译成具体的状态变化、位置变化、尺寸变化或反馈方式。
8. 如果关键信息缺失但仍能合理判断，先做一个明确假设并继续，不要连续追问。

## 判断方法

先用下面四个问题定位需求：

| 判断问题 | 重点关注的交互 |
|----------|----------------|
| 变化应该从哪里开始？ | Radial Theme Transition、Drag-to-Reorder、Fan Menu Expansion（扇形菜单展开） |
| 操作最后应该停在哪里？ | Staggered Bulk Selection、Velocity-Based Slider Snap |
| 这次变化需要谁跟着回应？ | Spring Stepper Progress、Ripple Feedback for Related Switches |
| 周围内容要不要一起让位？ | Curved Card Deletion、Stacked Card Scroll、Expanding Tag Selection、Cross-Module Drag（跨模块拖拽） |

如果是内容本身从隐藏变为显示，优先检查 Animated Text Disclosure。

---

## 模式库（13种）

### 1. Radial Theme Transition | 圆形主题切换

**适用场景**：用户点击主题切换按钮，需要从浅色模式切换到深色模式，或在两套完整页面之间切换。

**必须保留**：以真实点击或触摸位置为圆心；圆的半径覆盖到最远的屏幕角落；两套页面保持相同尺寸和位置；只裁切上层页面，不缩放页面内容。

```
Implement a radial theme transition for an app interface. When the user presses the theme toggle, reveal the new theme from the exact pointer or touch position as the center of an expanding circle. Calculate the circle radius based on the distance from the touch point to the farthest viewport corner. Keep both theme layers at the same scale and position, and clip only the top layer with a circular mask instead of scaling the page. Support mouse and touch input, respect prefers-reduced-motion, and use a simple fallback transition when needed.
```

### 2. Drag-to-Reorder | 拖拽排序

**适用场景**：用户拖动列表、卡片或任务项，重新决定它们的顺序。

**必须保留**：拖动项暂时脱离普通列表流；每一帧重新计算落点索引；其他项目形成明确的空槽；每一项独立追赶新位置；用户中途停下时，布局也停在当前状态。

```
Create a draggable sortable list. When the user holds and drags one row, temporarily remove it from the normal list flow and calculate the insertion index continuously from the pointer position. The other rows should create a visible empty slot and move out of the way. Animate each row independently with a spring motion so the layout feels soft and staggered. Keep the dragged item attached to the pointer, prevent layout jumps, and support both touch and keyboard interactions.
```

### 3. Staggered Bulk Selection | 批量勾选

**适用场景**：用户点击全选或批量操作，需要让多条内容依次进入选中状态。

**必须保留**：状态可以立即更新，但视觉反馈从第一项开始错峰执行；每个勾选出现时有轻微弹性放大；不能让动画阻塞用户继续操作。

```
Implement a select-all interaction for a list of four items. When the user activates select all, update the selection state immediately but animate the checkmarks one by one with a short staggered delay from the first item to the last. Add a subtle elastic scale effect when each checkmark appears, then return each item to its normal size. Make the sequence feel deliberate without slowing down the actual state update, and support keyboard and screen-reader accessibility.
```

### 4. Velocity-Based Slider Snap | 滑杆惯性吸附

**适用场景**：用户拖动带有刻度的滑杆选择数值、档位或目标值。

**必须保留**：记录释放速度；松手后允许滑块短距离过冲；再通过弹簧回到最近的有效刻度；最终值必须被限制在合法范围内。

```
Create a stepped slider for selecting a target value. Track the pointer velocity while the user drags. When the user releases the slider, let the thumb continue slightly past the release point based on the release velocity, then use a spring animation to pull it back to the nearest valid tick. Clamp the final value to the available range, make the overshoot subtle, and support mouse, touch, keyboard control, and reduced-motion preferences.
```

### 5. Animated Text Disclosure | 文本展开

**适用场景**：一段说明文字、详情内容或帮助信息需要在折叠和展开之间切换。

**必须保留**：根据真实内容高度调整容器；从当前高度连续过渡到目标高度；箭头或图标旋转180度；不能让文字突然出现或造成布局跳动。

```
Create an animated text disclosure component for a collapsible description. When the user opens it, measure the real content height and animate the container from its current height to the measured height instead of suddenly revealing the text. When it closes, animate back to the collapsed height. Rotate the trailing chevron by 180 degrees to represent the two states, keep the content accessible to screen readers, and avoid layout jumps.
```

### 6. Spring Stepper Progress | 步骤条回弹

**适用场景**：用户完成表单、购买或设置流程中的一个步骤，需要推进到下一步。

**必须保留**：进度段先略微超过目标位置，再回弹到准确位置；完成、当前和未完成状态要清晰区分；动画不能改变真实步骤状态。

```
Create a multi-step progress indicator. When the user completes a step, animate the next progress segment so it slightly overshoots its target and then settles back with a soft spring motion. Update the completed, current, and upcoming states clearly, keep the progress value accurate throughout the animation, and make the transition feel responsive without delaying navigation. Support keyboard accessibility and prefers-reduced-motion.
```

### 7. Ripple Feedback for Related Switches | 开关联动反馈

**适用场景**：一组相互关联的设置中，用户切换其中一个开关，需要提醒用户它属于同一组设置。

**必须保留**：当前开关正常改变状态；邻近开关只产生轻微震动或涟漪反馈；邻近开关的真实开关状态不能被改变。

```
Create a settings group with multiple toggle switches. When the user changes one switch, trigger a subtle ripple-like feedback effect that spreads to the neighboring switches. The neighboring switches may slightly shake or translate, but their actual on and off states must not change. The source switch should update normally, while the ripple remains purely visual feedback. Keep the effect contained within the group, support touch and keyboard input, and disable the motion for reduced-motion users.
```

### 8. Curved Card Deletion | 卡片曲线删除

**适用场景**：用户滑动删除卡片、消息或任务，希望让删除动作有明确的去向。

**必须保留**：卡片沿曲线路径移动到删除图标或回收区域；移动过程中逐渐缩小、旋转和变淡；未达到删除阈值时可以取消并回到原位；动画结束后再从数据源移除。

```
Create a swipe-to-delete card interaction. When the user swipes a card past the delete threshold, animate the card along a curved path toward the delete icon or trash area. While moving, gradually reduce its scale, rotate it slightly, and fade its opacity. Remove the card from the data source after the exit animation completes. If the user releases before the threshold, smoothly return the card to its original position. Support touch, mouse, keyboard deletion, and reduced-motion preferences.
```

### 9. Stacked Card Scroll | 卡片堆叠滚动

**适用场景**：用户滚动一组有顺序的卡片、记录或历史内容，需要保留已经看过内容的空间线索。

**必须保留**：顶部卡片到达边界后暂时固定；后续卡片向上移动并把前面的卡片压成一摞；压缩程度、缩放和层级根据后方卡片数量变化；内容不能突然消失。

```
Create a vertically scrollable card stack. When the top card reaches the top boundary, keep it pinned temporarily while the cards behind it move upward and compress into a visible stack. Calculate each card's vertical offset, scale, and depth based on how many cards are behind it. The more cards that move forward, the deeper and smaller the previous cards should become. Preserve the user's scroll context, avoid abrupt disappearance, and support touch, mouse wheel, and keyboard scrolling.
```

### 10. Expanding Tag Selection | 标签挤开

**适用场景**：用户从一行标签、筛选项或分类项中选择一个选项，需要突出当前选择。

**必须保留**：当前标签稍微放大；邻近标签平滑向两侧让位；元素不能互相重叠或突然跳动；小屏幕下要正确处理换行。

```
Create a selectable tag list with animated layout reflow. When the user selects a tag, slightly enlarge the active tag and make the neighboring tags move aside to create enough space. The surrounding tags should smoothly translate rather than overlap or jump. Clearly show the selected state, preserve the original order of the tags, handle wrapping on smaller screens, and support mouse, touch, keyboard navigation, and reduced-motion preferences.
```

### 11. Fan Menu Expansion | 悬浮球扇形展开（ThirdHub专属）

**适用场景**：用户点击右下角悬浮球，需要展开模块菜单（扇形/圆形排列），再次点击或点遮罩收起。

**必须保留**：菜单项从球心沿弧线弹出（错峰、带弹簧回弹）；当前所在模块图标高亮；背景加半透明遮罩，点击遮罩收起；长按球可拖动换位、松手吸附边缘；键盘弹出时球自动上移；动画结束后焦点的第一项可被键盘/手柄选中。

```
Implement a floating action ball in the bottom corner of a mobile app. When the user taps it, expand a fan-shaped radial menu from the ball center with staggered item pop-in and spring overshoot. Highlight the icon of the currently active module. Add a semi-transparent backdrop; tapping the backdrop collapses the menu. Long-pressing the ball allows drag repositioning, snapping to screen edges on release. When the keyboard opens, move the ball upward to avoid occlusion. After the menu animation completes, make the first item focusable for keyboard or remote control navigation. Respect prefers-reduced-motion with an instant fallback.
```

### 12. Reader Page Curl | 阅读器仿真翻页（ThirdHub专属）

**适用场景**：小说阅读器中用户点击/滑动翻页，需要纸张卷曲仿真动画（覆盖模式）。

**必须保留**：以触摸点为折痕锚点；翻起页背面显示浅色背面+轻微阴影；角度跟随手指连续变化；松手后根据位置决定完成翻页或回弹；平移模式下降级为滑动+阴影过渡；动画不得改变真实章节位置，翻页完成才更新阅读进度。

```
Implement a realistic page-curl page turn for a novel reader in overlay mode. Use the touch point as the fold anchor and render the lifted page with a light-colored back face, soft shadows, and a continuous angle following the finger. On release, complete the turn or spring back based on pointer position. In scroll mode, degrade to a slide transition with shadow. The animation must never change the real chapter position; only update reading progress after the turn completes. Support tap zones, horizontal swipe, and prefers-reduced-motion.
```

### 13. Cross-Module Drag | 卡片跨模块拖拽（ThirdHub专属）

**适用场景**：用户把书籍/音乐卡片从书架拖到分类文件夹、或拖入下载队列（跨模块移动）。

**必须保留**：拖动全程卡片悬浮跟随手指（缩放1.05+阴影）；经过可接收目标时目标高亮并轻微扩大；松手后卡片沿短曲线路径飞入目标容器；源列表和目标列表同步更新（先动画后数据）；不可接收的目标不响应；取消时弹簧回原位。

```
Implement a cross-module drag interaction. While dragging a card (book, song, or comic), keep it floating under the pointer with a slight scale-up and elevated shadow. Highlight and gently enlarge any valid drop target as the card passes over it; invalid targets give no response. On release, animate the card along a short curved path into the target container, then update both the source and target lists after the animation completes. If the user cancels, spring the card back to its origin. Support touch, mouse, keyboard move operations, and prefers-reduced-motion.
```

---

## 输出格式

当用户描述一个具体界面需求时，按下面格式回答：

### Selected interaction
写出最合适的英文名称和中文名称。

### Why it fits
用简短中文说明它解决的是"从哪里发生""落在哪里""谁跟着变化"还是"周围是否让位"。

### Interaction behavior
用中文说明触发方式、开始状态、变化过程、最终状态、取消或失败状态，以及移动端需要注意的触控区域。

### Copyable prompt
只输出一段英文提示词。提示词必须包含：
- 具体组件或界面对象；
- 触发方式；
- 开始状态和结束状态；
- 位移、尺寸、透明度、裁切、弹簧或过冲等具体变化；
- 数据状态和视觉状态之间的关系；
- 响应式、键盘、触控和reduced-motion要求；
- 不要改写无关组件。

```
Use the selected interaction pattern in my existing interface. Preserve the current visual style, layout language, and component structure. Do not rewrite unrelated components. Implement the trigger, state changes, start and end states, motion behavior, responsive behavior, keyboard accessibility, touch support, and reduced-motion fallback described below:

[Insert the selected English interaction prompt here]
```

## 不要这样回答

- 不要只说"加一个高级动画"。
- 不要把13种模式全部混在一起输出。
- 不要把视觉反馈误写成真实功能变化，例如让邻近开关跟着改变状态。
- 不要用固定时长掩盖没有定义开始状态和结束状态的问题。
- 不要输出视频剪辑、配音、字幕或视频制作流程。
- 不要生成中英文双栏提示词图；需要图片时，只提供适合做信息浓缩图的结构和文案。


## 第4篇 调研报告

# ThirdHub 项目现状调研与重置报告（给王珩宇）

> 日期：2026-09-24 · 本报告回答三个问题：为什么会变成这样？你真正想要什么？怎么重置？

---

## 一、你的疑问·直接回答

**Q1：为什么账号认证牵扯到另一个CF账号？之前不是在Supabase吗？**
认证从头到尾都在 **Supabase（新加坡区）**，没有动过、也不该动。另一个CF账号（B）做的是**认证之后的事**：存你的设置、同步锚点、头像、设备清单。分工是：
- Supabase = 验人（你是谁）
- CF-B = 记住你（你的偏好和数据指针）
- CF-A = 给所有人看的网站
两家各管一段，互不重叠。

**Q2：为什么引擎隔离不够严肃？**
之前只把隔离当"架构原则"（协议分层、零内置），但**没有做到组织层面**：引擎仓和你的商用仓挤在同一个GitHub账号下，一旦将来商用，律师看的是"这些代码是不是同一个主体发布的"——仓库在一个账号里就是风险。重置方案里用**两个GitHub账号做物理隔离**（见第五节）。

---

## 二、现状全景（审计结果）

### 版本线现状

| 线 | 仓库 | 状态 | 问题 |
|----|------|------|------|
| 网站+后端（v4新架构） | ThirdHub-v2 | v4.44.0，M1/M2完成，M3-M5在看板 | 未拆仓，身兼Web+后端两职 |
| 软件端（新主线） | ThirdHub-Flutter | v0.4.2 | 8模块 but 与Web端各自为政 |
| 网站（v3老线） | ThirdHub | 停在v3.x | 未归档，AI模块还没移植 |
| 软件端（老线） | ThirdHub-Android | v3.0.0 | 未归档 |
| 引擎（自用） | ReadingEngine | v1.5.5 | **与商用仓同账号**⚠️ |
| 引擎（旧线） | ThirdHub-Engine | 废弃路线 | 未归档⚠️ |

### 六 diagnosed 病灶

| # | 病灶 | 后果 | 根因 |
|---|------|------|------|
| 1 | **版本爆炸** | 36个仓库、4条版本线，新AI接手读不完 | 每次架构转向都开新仓而不是收旧仓 |
| 2 | **意图漂移** | 你最想要的AI体验被排到P8"最后攻坚" | 我按"工程依赖"排期，没按"你的产品灵魂"排期 |
| 3 | **代码复用差** | Web一套、Flutter一套，模块/设置/逻辑写两遍 | 没有"模块声明层"，两端各自实现 |
| 4 | **数据互通缺失** | 账号只同步名字，书架/头像/设置全断 | 云端只做了auth，数据层一直没建 |
| 5 | **引擎隔离停留在口头** | 引擎仓与商用仓同账号、同主体 | 没有组织级隔离方案 |
| 6 | **后端理解不足** | 配置拓扑没文档化，讨论来回漂移 | 后端配置从没写进清单 |

---

## 三、意图还原（你自己说过的话，重新排序）

把你历次表达按"强调次数×情绪强度"还原真实优先级：

| 你的原意 | 现在的位置 | 应该是 |
|----------|-----------|--------|
| "AI智能体验是我最想做的" | P8（最后攻坚） | **P2** |
| "各个板块/模块" | 散落在P3-P6 | **P3**（紧跟AI） |
| "网站和软件端都要做、数据互通" | 只做了登录 | **P1** |
| "相册备份是招牌" | P5 | P4（排在AI后） |
| "引擎必须严肃隔离，不能沾商用" | 口头原则 | **P0组织级隔离** |
| "后端要能装手机上" | 没排 | P4 |

---

## 四、重置方案

### 4.1 组织级引擎隔离（P0，最重要）

| 措施 | 说明 |
|------|------|
| **双GitHub账号隔离** | GH-A（现有）= 商用线：四线四仓+基础设施，**永不出现引擎**；GH-B（你的第二个号）= 个人线：ReadingEngine/书源工具/实验仓 |
| 引擎迁移 | ReadingEngine 等移入 GH-B；GH-A 侧删除（保留下载包不保留代码？——不，代码完全迁走，GH-A留fork痕迹反而说不清，应删除并注明迁移） |
| 协议是唯一接触点 | 商用代码只引用 THP 协议**文档**，永不引用引擎仓代码/子模块/依赖 |
| 发布隔离 | 商用 Release 永不捆绑引擎；引擎APK只在个人渠道发布 |
| 引擎自证 | 引擎仓 README 写明"个人学习用途，与任何商业产品无关" |

### 4.2 仓库大收缩（P0）

- 归档9个废弃仓（清单在会话总清单B节）
- **四线拆四仓**：Backend / Web / Flutter / Full
- GH-B 承接全部引擎类+私人实验

### 4.3 优先级重排（冻结版）

| 优先级 | 内容 | 为什么在这 |
|--------|------|-----------|
| **P0** | 引擎隔离+仓库收缩+清单体系 | 法律风险最高、地基 |
| **P1** | 数据互通：账号全量同步+设置三层+书架进度同步 | 你天天感知到的痛 |
| **P2** | **AI核心体验**：Chat工具调用深化+Work作业中心+悬浮球四态+AI控制模块 | **你的产品灵魂，不再延后** |
| **P3** | 板块铺开：笔记/待办/下载中心/相册UI/浏览器增强 | 体验厚度 |
| **P4** | 后端数据层：blob+同步三件套+相册备份闭环+后端APK | 招牌能力 |
| **P5** | 内容扩展+家庭系列 | 生态 |
| **P6** | 商业生态L3 | 模式验证后再做 |
| **P7** | 引擎SDK/开发者指南 | 自用验证 |

### 4.4 流程改革（防止再走样）

1. **意图确认制**：AI接任务必须先复述"我理解你要的是…"，你确认后才动手
2. **优先级冻结**：上面这张表只有你能改，AI禁止"顺手重排"
3. **改代码必改清单**：已是规则，加入CI校验
4. **交接协议**：每次会话结束AI写三句话摘要进AI-WorkLog

---

## 五、30/60/90天

| 时段 | 交付 |
|------|------|
| 30天 | P0完成（隔离+收缩+四仓拆完）；P1完成（互通）；AI读新手册上岗 |
| 60天 | P2 AI核心体验全量（你能日常用AI控制App干活） |
| 90天 | P3板块铺开+P4相册备份闭环——回到"你最想要的产品" |

---

*本报告是"给你看的"。配套《项目宪法与执行手册》是给AI看的，两份一起生效。*


# 附录 · 会话总清单（旧版存档）

# ThirdHub 会话总清单（Session Master）

> 生成：2026-09-24 · 修订：2026-09-27（全项目审计后）· 用途：**全会话决策唯一锚点**，每轮讨论后更新
> 配套文件：总体规划v2.0修订2 / THP-2.1协议对齐版 / 功能规划v3.0 / AI开发总清单规范 / 技能-交互动效设计

---

## A. 架构总表

| 项 | 决策 | 状态 |
|----|------|------|
| 产品线 | **四线**：①网页端(PWA云端托管) ②Flutter端(手机版纯播放器+AI控制) ③后端(Node+Web管理界面=电脑版) ④完全体(一体化App，给没后端的人，主要自用) | ✅定稿 |
| 参照 | 腾讯**WorkBuddy**（电脑版全功能+手机版轻客户端）；iOS过审参照Infuse/Plex（纯播放器连用户服务器） | ✅定稿 |
| 仓库 | 拆四仓：Backend / Web / Flutter / Full，**各自独立CHANGELOG+独立版本号** | ✅定稿 |
| 后端上手机 | ③后端出**Android APK（Node内嵌）**，旧手机变服务器 | ✅定稿 |
| 云端 | **最终分配**：CF-A=网站+网站配套(公告/更新检查/公共目录查询)；CF-B=边缘数据面(KV设置/锚点+D1设备清单/配额+R2头像/备份10MB/用户+verify)；Supabase(新加坡)=只做Auth(**开源Apache-2.0可自托管**)；**Neon=云端托管库**(无后端用户的书架/进度/笔记：管理员/家人/同学/会员) | ✅最终版v3 |
| 数据互通 | 账号走A云、数据走③后端、模块走manifest、媒体永留用户设备 | ✅定稿 |
| 冲突策略 | LWW(hash+ts)；笔记类留5版本 | ✅定稿 |
| 设备覆盖 | 网页端=全平台浏览器；Flutter=Android/iOS/Win/Mac/Linux；后端=Node/APK；完全体=旧手机/NAS/电脑 | ✅定稿 |
| 协议 | THP/2.1共识格式 `{ok:true/false}`；REST+WS+SSE；只增不减 | ✅仓库已落地 |
| 引擎哲学 | **编排非集成**：Legado/Komga/ABS官方原版+官方API；不做包名重命名（legado-thirdhub路线已死） | ✅已定 |
| 自用引擎 | ReadingEngine=前端测试桩(THP/1.0自称，**版本号待与2.1统一**)；沙箱=drpy/venera/musicfree | ✅在用 |
| 用户分档 | A类=自托管(自己跑后端/SQLite)；B类=云端托管(免后端，Neon，面向管理员/家人/同学/会员) | ✅定稿 |

## B. 仓库处置表（36仓）

| 处置 | 仓库 |
|------|------|
| ✅现役(9) | ThirdHub-v2、ThirdHub-Flutter、ReadingEngine、AI-WorkLog、ai-handbook、wrap-up-notes、ThirdHub-Downloader、ThirdHub-Update、ThirdHub-Admin |
| 🗄️归档(8) | ThirdHub-Android、ThirdHub-Engine、legado-thirdhub、OmniHub×3、AI-Backup、ThirdHub-Portal |
| 📥转生(1) | **ThirdHub老站=官方下载中心**（v3.35.3，分发后端包/APK，不归档；README待更新） |
| 😴搁置(1) | ThirdHub-Flutter独立仓(0.4.4)——主线flutter_app已并入ThirdHub-v2，旁支搁置 |
| 📚参考(18) | legado、yidaRule、keep-alive、any-reader、wuji-tauri、Mineradio-LX-qs、VideoWorld_Android、JustAuth、fqnovel-unidbg、Fanqie-novel-Downloader、videdown、res-downloader、Bili23-Downloader、TVAPP、Lyrico、infinite-canvas、LearnPrompt、Legado-Tauri-Release |

## C. 四线数据互通矩阵

| 数据 | 存哪 | 四端表现 |
|------|------|----------|
| 账号资料(云B) | R2头像+KV设置/设备清单/锚点+L3公钥 | 登录即一致 |
| 书架/进度/收藏/笔记/待办/连接器（A类：有后端用户） | ③后端本地SQLite | 网页端存，App打开就有 |
| 书架/进度/收藏/笔记（B类：无后端用户=你/家人/同学/会员） | **CF-B Workers→Neon云端托管** | 免装后端，登录即用 |
| 模块功能/设置/逻辑/工具 | manifest仓 | 改一处四端生效 |
| 媒体文件(书/漫画/音视频/照片) | 用户设备 | 永不入云 |

## D. 云端10MB配额（CF-B）

| 内容 | 上限 |
|------|------|
| 昵称/签名 | 4KB |
| 头像(强制压缩) | 200KB |
| 账号设置 | 16KB |
| 设备节点清单 | 32KB |
| 同步锚点 | 16KB |
| L3公钥+授权记录 | 8KB |
| 可选加密备份(默认关) | 剩余配额 |
| 可选进度 | KB级 |

**存储选区**：CF D1/R2→APAC(SIN)；Supabase→Singapore。

**Linux服务器迁移（纯设计约束，现在不建不迁）**：
- 路线A（将来首选）：CF边缘不动→Cloudflare Tunnel(免费)→自有服务器当源站，零数据搬迁
- 路线B（终极自立）：自托管Supabase，pg_dump迁auth，JWT secret必带走，storage走S3同步
- 现在执行的3条硬规矩：① KV/D1键全带uid前缀 ② Workers只做"读缓存→转发"，业务逻辑不进CF ③ 每月Action自动导出KV/D1快照到Release
- **后端存储层可替换driver**（SQLite / Postgres-Neon）：A类用户本地跑SQLite，B类用户云端Neon——同一套代码换driver，也是将来Linux服务器路线A的接缝
- Supabase开源确认：Apache-2.0/MIT，Docker可全栈自托管，路线B(pg_dump迁auth+JWT secret)可行性坐实

## E. 文档治理体系

| 文档 | 位置 | 性质 |
|------|------|------|
| ARCHITECTURE/TASKS/PLAN-v3/THP.md | ThirdHub-v2仓库 | 工程真相源 |
| manifest+MASTER-CHANGELOG | 仓库 | AI改代码必改 |
| AI-WorkLog | 独立仓 | 会话交接摘要 |
| 总体规划v2.0修订2 / THP-2.1对齐版 / 功能规划v3.0 / 总清单规范 / 交互技能 | 本地，待入库 | 规划层 |

## F. AI体系

| 项 | 决策 |
|----|------|
| 双运行时 | Chat=前端Harness(交互对话)；Work=后端Agent运行时(长任务作业化，前端可杀作业不死) |
| 控制优先级 | 功能工具→声明式UI指令→语义树读屏兜底→问用户（永不模拟触屏） |
| 工具分级 | T0只读/T1导航/T2交互(自动+审计)/T3危险(只弹卡，必须人工) |
| 技能 | 内置9个：翻译/联网/日历/系统指令/记忆/代码/调试/文件/交付检查 + 新增**交互设计(13模式)** |
| MCP | 双向桥：MCP Server↔THP peer |
| 审计 | 每次工具调用记录，「我的→AI日志」 |
| AI守则 | 改代码不改清单=未完成；交接输出三句话摘要 |

## G. 执行优先级（v6·2026-09-27审计后重置）

**审计结论**（300提交/14天/22轮交接）：
- 精力分布：发版机械35%、UI 28%、i18n 7%、**性能仅7%**；同步=修坏循环（两端各读各的表，§11契约从未实施）
- 零动工：OS内核层/QAuth/性能预算/keystore处置/双信封立法/干净源定性/GH-B隔离/iOS适配/桌面适配
- 制度空转：AI-WorkLog 9-18后停更；wrap-up-notes空转；双AI体系互不知情
- 产品现状：单仓全家桶（flutter_app 4.52.0+server 0.8.7+后端APK工程）；THA/1(full/fallback)+CHAT/1(离线优先)已落地

| 批次 | 任务 | 验收标准 | 依赖 |
|------|------|----------|------|
| **R0止血** | ①keystore更换+更新接口签名白名单 | 旧签名包不能再获取更新 | 用户签发 |
| | ②同步按§11契约重建(changes+tombstone+hash+LWW) | 两端同读同写一套表；9-24三连bug不复现 | 无 |
| | ③网站Lighthouse实测+迁CF-A+缓存规则 | 首屏<3s(4G)、性能分>80 | CF-A |
| | ④AI-WorkLog制度激活 | 72小时内日志有更新 | 施工AI |
| **R1体验** | ⑤模块OS层(保活三档/事件总线/通知中心/全局搜索) | 切走再回状态在；两模块任务真并行 | ②后 |
| | ⑥Flutter WS长连接替轮询 | 聊天/AI事件流实时到达 | 无 |
| | ⑦性能预算进CI | 超预算PR标红 | 无 |
| **R2基建** | ⑧GH-B隔离 | ReadingEngine迁出商用组织 | **用户给token** |
| | ⑨双信封立法+干净源定性入宪法 | 宪法新增两条款 | 无 |
| | ⑩双AI体系并轨 | 对方提交带manifest更新 | ④ |
| **R3增长** | ⑪商业L3/积分体系/小程序端 | 按§15/§22/§23 | R2后 |

## H. 红线（永久）

1. 前端纯播放器/能力制路由/IR归一
2. 零编译集成官方应用（不做包名重命名/壳中壳）
3. 云端零内容+CF-A/B分权(A纯网站/B纯数据)+auth只在Supabase+Neon=云端托管库(B类用户)
4. iOS仅纯播放器上架；完全体/引擎永不入App Store
5. 法律防火墙四不 + 干净源定性（白名单源与用户自导入源分轨，清单公开可撤销）
6. AI改代码必改清单
7. THP只增不减；**双信封立法**（THP=ok信封对外，/v1家族+THA/1+CHAT/1=object信封对内，禁止统一式返工）
8. 单仓多部件CHANGELOG独立（主线全家桶+下载中心站）

## I. 待办（2026-09-27审计后）

| 项 | 状态 |
|----|------|
| keystore泄露处置 | 🔴 R0①，等用户签发新key——**当前最高危** |
| GH-B小号token | 🔴 R0⑧前置，等用户提供 |
| 网站卡顿 | 🔴 R0③：先Lighthouse实测再定方案（托管位置未确认） |
| 同步修坏循环 | 🔴 R0②：按§11契约重建 |
| AI-WorkLog停更 | 🔴 R0④：制度激活，每轮交接必写 |
| GitHub token 11-17过期 | ⏰ 7周内更换 |
| ReadingEngine协议版本号(1.0→2.1) | 并入R0⑧ |
| 搜索路由演进/老PWA移植/iOS TestFlight | R3后再议 |
| wrap-up-notes空转 | 并入R0④（作为留言板启用或归档二选一） |
