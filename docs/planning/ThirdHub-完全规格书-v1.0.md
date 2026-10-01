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
