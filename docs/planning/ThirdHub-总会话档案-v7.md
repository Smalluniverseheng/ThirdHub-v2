# ThirdHub 总会话档案（终极详细版 v7）

> 版本：v7.2 · 2026-09-27 · 由本会话全部讨论+两次全项目审计合并而成
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
