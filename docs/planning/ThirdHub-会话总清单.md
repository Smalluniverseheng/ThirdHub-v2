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
