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
