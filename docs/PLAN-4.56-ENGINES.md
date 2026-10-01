# 下一轮（4.56.0）施工图：四个独立引擎 + 模块归并 + 引擎更新通道

> 本文写于 4.55.0 发版当天（2026-10-01），用途是**把用户口述的需求钉成可施工的条目**，
> 避免再出现"理解偏了、做错方向"。所有内容以用户原话为准，逐条标注出处。
> 4.55.0 已完成的是：引擎免激活密码、搜索不截断、返回键修复、模块内横滑。**本文是剩下的部分。**

---

## 一、四个引擎改成"基于各自上游的独立 App"（用户诉求 1、2）

### 用户原话（关键三句）
1. 「不要改引擎本身的图标。各引擎应保留其原有图标（例如开源阅读就用它原生图标，
   漫画引擎、音乐引擎、tvbox 等各自沿用自己原本的图标），不要统一替换成我的图标。」
2. 「这些引擎要基于它们各自的原始软件做独立改造，**不要把开源阅读拆分成的四个模块当成我要的引擎**；
   它们是彼此完全不同的独立软件，改造后应做到开箱即用、即点即用。」
3. 「引擎最好有让这个软件同时调用**多个**引擎：比如阅读模块可以做好几个引擎，
   小说模块做好几个、音乐模块也可以做好几个引擎……以后还要做**直播引擎**。」

### 现状（为什么不符合）
`D:/ai/reading-engine` 是**一个 Legado 分支**，用 `productFlavors` 切 5 个产物
（app/novel/comic/music/video）。5 个产物**共用同一份源码、同一个启动图标**、
同一个 `applicationId` 前缀 `com.legado.app`。这在用户眼里就是"同一个软件切了四份"，
正是他说的"不要把开源阅读拆成的四个模块当成我要的引擎"。

### 目标形态
| 引擎 | 上游（建议） | 包名（建议） | 保留的原生图标 |
|---|---|---|---|
| 小说 | 开源阅读 Legado（`gedoor/legado`） | `com.thirdhub.engine.novel` | Legado 原生 |
| 漫画 | Venera（`venera-app/venera`） | `com.thirdhub.engine.comic` | Venera 原生 |
| 音乐 | 落雪 LX Music（`lyswhut/lx-music-mobile`） | `com.thirdhub.engine.music` | 落雪原生 |
| 影视 | TVBox（`q215613905/TVBoxOS` 系） | `com.thirdhub.engine.video` | TVBox 原生 |
| 直播 | 待定（用户确认后加） | `com.thirdhub.engine.live` | 上游原生 |

> 上游选择依据用户授权：「你尽可能找比较成熟的上游，比如落雪音乐、可以找 tvbox 做视频」。
> 若某上游不存在 Flutter/Android 版或已停止维护，**先报给用户确认再换**。

### 每个引擎必须做到的三件事
1. **保留原生图标**：各仓 `res/mipmap-*` 用上游原图标，不做统一换标。
   （唯一例外：应用内展示时可加一个"来源"角标，但不能覆盖原生图标。）
2. **开箱即用**：内置源打进包里，安装后无需任何配置即可搜索/播放。
   用户已明确授权：「这种引擎里面是可以内置源的，因为我不打算（公开）这种引擎都是我自用……
   等我以后想要分享的时候我会让你把源删掉」。
   ⇒ 内置源必须放在**一个可一键剔除的目录**（如 `assets/builtin-sources/`），
   并提供 `tools/strip-sources.mjs` 一键移除后再出"分享版"。**这是分享前的强制前置。**
3. **接 THP/1**：每个引擎暴露 `/thp/meta`、`/thp/m/{module}/{search|toc|content|discover}`，
   让前端能"发现即用"。

### 工程路径（分三步，每步都可单独验收）
- **S1 骨架**：为 4 个上游各建一个仓（或一个 monorepo 的 4 个目录），先做到"能编译出 APK"。
  验收：`aapt2 dump badging` 的 `applicationId` 与上表一致、图标为上游原生。
- **S2 内置源 + THP**：把该类型的源包打进 assets，接上 THP 端点。
  验收：装到设备后**不输任何密码**即可搜到内容（真机，或至少引擎侧自检 + 服务端探针）。
- **S3 前端多引擎**：前端同一内容类型支持挂**多个**引擎（并发搜索 + 结果归并去重 + 单引擎故障不影响整体）。
  验收：`engine_direct.dart` 的搜索路径支持 `List<Engine>`，单类型多引擎并发。

---

## 二、模块归并：按归属并入现有大模块，不是"全并成一个"（用户诉求 6）

### 用户原话
「不是让你整合到某一个大模块，而是这些很多（的小模块）其实是可以整理到（各自所属的）模块，
就是整理到**多个**模块。比如说 AI 类的东西你可以整合到原来的模块里面，自己做好入口、
自己做好分支；然后那些其他跟阅读有关的（并）到一块去。这样而不是下落成很多个模块。」

### 现状（2026-10-01 核实，别再看旧描述）
**"聚合入口"已经建了 6 个**，都在 `kModules` 里用 `ModuleHubPage` 承载：

| 聚合模块 | 已并入的子模块 | 个数 |
|---|---|---|
| 工具箱 | 翻译 / 扫描仪 / 二维码 / 悬浮便签 / 计算器 / 白板 / 文本工具箱 / 传感器 / 文件互传 / 远程打印 | 10 |
| 家庭中心 | 共享相册 / 共享清单 / 家庭影院 / 家庭音乐库 / 摄像头 / 智能家居 / 设备互联 / 家庭日历 | 8 |
| 记录中心 | 笔记 / 日记 / 悬浮便签 / Markdown / 代码片段 / 书签 / 剪贴板 | 7 |
| 音频中心 | 播客 / 有声书 / 广播 | 3 |
| 学习中心 | 记忆卡 / 课程表 | 2 |
| 备份迁移 | 通讯录备份 / 短信备份 | 2 |

### ★ 但"归并没真正生效"——这是必须补的那一步
`kModules` 里**同时存在**「工具箱」和「翻译」。而模块列表是三处都遍历 `kModules` 全量：
- `_Ob._modStep()`（引导页"选择模块"）—— `for (final e in kModules.entries)`
- `NavSettingsPage`（「我的 → 功能管理」的模块勾选）
- 「切换模块」宫格（读 `enabled`，而 `enabled` 又来自上面两处）

⇒ 结果：**只是多了一个聚合入口，顶层模块数一个没少**。用户说的"下落成很多个模块"
指的正是这个 —— 他要的是**列表变短**，不是多一个入口。

### 施工方案（下一步照此做，含数据迁移）
1. `ModuleDef` 增加 `final String? hubOf;`（归属的聚合模块名；null = 本身就是顶层）。
2. 给上表里的子模块标上 `hubOf`（每个子模块**只能有一个归属**）。
3. 加 `List<String> get kTopModules => [for (final e in kModules.entries) if (e.value.hubOf == null) e.key];`
4. 三处列表渲染改用 `kTopModules`（引导页 / 功能管理 / 宫格）。
5. **`enabled` 迁移（关键，别丢功能）**：老用户的 `nav_modules` 里可能有「翻译」而没有
   「工具箱」。迁移规则：**只要启用了任一子模块，就自动启用其所属聚合模块**，
   再把子模块 key 从 `enabled` 里剔除。迁移后回写（照 `_load()` 现有做法）。
   验证：拿一份"只有翻译"的 nav_modules 走一遍，确认「工具箱」出现在导航里、
   「翻译」仍能在工具箱内打开。
6. 自检：`modules_selfcheck` 加"每个 hubOf 都指向真实存在的聚合模块"与
   "kTopModules 里不含任何 hubOf != null 的 key"；`changelog_selfcheck` 的 65 模块
   双向核对需同步改成"对 kModules 全量核对，但顶层展示用 kTopModules"。

### ★ 4.58.0 施工完成记录（2026-10-01）
按上面方案落地，**实际改动比方案预想的更小** —— 关键发现：
`migrateModuleKeys()`（`core/module_registry.dart`）已经是**所有** nav_modules 读取的
必经之路（本地加载 / 首启引导 / 导航设置 / ProBridge / 云端上行前，共 6 处），
所以归并**只改这一个函数就处处生效**，不必去改 6 个调用点。

- **归属表落点**：`core/module_registry.dart` 的 `kModuleHubOf`（31 条）+ `kHubModuleKeys`（6 个）。
  **刻意不放在 `main.dart` 的 `ModuleDef` 里** —— 那个文件纯 Dart 自检读不到，
  归属表打错一个 value 只有把 App 装起来点进去才会发现。放 `core/` 才能被自检拦住。
- **顶层过滤**：新增 `topModuleKeys(allKeys)`；显示层 4 处改用它 ——
  首启引导 `_Ob._modStep()` / 导航设置 `showNavSettings` 的分类树 /
  导航管理 `_cats` + `_modulesOf` / 模块市场 `ProBridge.moduleKeys`。
- **数据迁移**：`migrateModuleKeys` 在「改名」之后追加「归并」（子模块 → 所属聚合模块，
  **占用原子模块的位次**以保序）。老用户 `nav_modules` 里只有「翻译」而没有「工具箱」时，
  归并结果是「工具箱」顶上「翻译」原来的位置 —— 既不凭空消失、顺序感觉也不变。
- **自检**：`module_registry_selfcheck` 38 → **53** 项，新增的全是**行为断言**
  （不只数据结构断言）。最要命的一条：「只启用『翻译』的老用户升级后拿到『工具箱』而不是空白」。
- **真机核验**：模拟器装 4.57.0 包走查「我的 → 语音朗读 → 小米」三屏截图取证
  （`D:/ai/_emu4570/`）。附带发现：Flutter 应用 `uiautomator dump` 拿不到文本节点
  （渲染到 canvas，a11y 语义树默认不喂系统），`settings put secure accessibility_enabled 1`
  在无 root 模拟器上读回仍是 0 → **只能靠截图实测坐标定位**。

**未做（第二批）**：下方"仍未归并的顶层散页"那一批**等用户拍板去向** ——
合并方向是产品决策，「哪个模块进哪个中心」直接决定他找东西的手感，先说清再动。

### 仍未归并的顶层散页（第二批，等第一批落地后再做）
自动化任务、待办、录音机、日历、提醒中心、记账、健康记录、短剧、壁纸、资讯、
天气与快递、菜谱 —— 建议去向：待办+提醒中心 → 「事务中心」；壁纸+资讯+天气+菜谱
→ 「生活中心」；录音机 → 并入「音频中心」；其余逐个判断，**宁缺毋滥**
（别为了合并又造出一堆平级模块）。

---

## 三、各模块"对标顶级"提质（用户诉求 5）

### 用户原话
「你看人家的计算器和我们的计算器对比，你就知道差距。别人的计算器都可以换汇率、各种计算，
而我们的计算器有啥用？一点用都没有。所以你要对标市面上最近顶级的软件，把我们每一个模块都做到最顶级。」

### 施工顺序（按"差距最大 / 收益最高"排）
1. **计算器**（`mini_modules.dart` 的 `CalcPage`）：加科学函数、单位换算、汇率换算、
   历史记录、表达式即时求值、百分比/括号。
2. **封面布局**（`pro_gallery.dart` / 各 `*Section`）：统一网格尺寸、圆角、阴影、
   图片占位与失败兜底、懒加载。
3. **阅读器**：翻页模式（仿真/覆盖/平移/上下）已就绪，补齐字号/行距/背景/护眼的一致体验。
4. 其余模块逐个对齐"同类的顶级 App"，**每个模块单独提交 + 单独验收**，
   避免"一次性大改、看不出改了哪".

---

### ★ 封面布局统一：现状实测与施工方案（2026-10-01 核实）

**现状**（grep 实测，不是印象）：`Image.network` 在全仓出现 **20+ 处**，封面相关至少 13 处
（`main.dart` 3858 / 4484 / 4919 / 5109 / 5400 / 5881 / 6146 / 6159 / 6310 / 6427 /
7027 / 7387 / 7519 / 13009 / 13344 / 13374，`core/engine_direct_page.dart:544`，
`core/mini_modules4.dart:105`、`mini_modules5.dart:294/341` …），每处**各写各的兜底**：

- 有的 `loadingBuilder` + `errorBuilder` 都写，有的只写一个，有的**一个都没有**
  → 表现是"网断时有的地方灰块、有的地方裂图图标、有的地方一片空白"；
- 网格规格不统一：`childAspectRatio` 出现 **0.52 / 0.62 / 0.65 / 0.75 / 0.85 / 1.15 /
  1.2 / 1.3 / 1.4 / 1.5 / 2.2** —— **十一种**；间距出现 2 / 4 / 6 / 8 / 12 五种；
- 封面圆角是 **10**，而 `STYLE_GUIDE.md` 规定卡片圆角 **12**。

**施工方案**
1. 新建 `core/ui_cover.dart`（纯 Flutter、无业务依赖）：
   - `CoverImage(url, {fit, radius, fallbackText})` —— **在 API 层强制**带
     `loadingBuilder`（骨架占位）与 `errorBuilder`（渐变底 + 书名首字），
     从机制上杜绝"漏写兜底"。
   - `GridSpec` 常量：`radius = 12`（对齐 STYLE_GUIDE）、`gap = 10`、
     封面比例按内容类型定（书 3:4.4≈0.68 / 视频 16:9 / 专辑 1:1），
     `delegateFor(kind)` 返回统一 `SliverGridDelegate`。
2. 替换顺序（**每步单独提交 + 单独验收**，避免"一次性大改、看不出改了哪"）：
   ① 小说书架 → ② 漫画 → ③ 视频 → ④ 音乐 → ⑤ 直播 → ⑥ 搜索结果 →
   ⑦ 详情页封面 → ⑧ 相册 / 壁纸等图墙 → ⑨ `engine_direct_page` / `mini_modules*`。
3. 自检：新建 `tool/ui_cover_selfcheck.dart`（纯 Dart）——
   - 断言 `GridSpec` 的数值、`delegateFor` 的返回、比例合法、**圆角 == 12**；
   - ★**grep 式断言**：直接读 `lib/main.dart` 等源码字符串，断言"封面相关的
     `Image.network` 调用点已经全部换成 `CoverImage`、没有裸遗留"。
     这条能纯 Dart 做（`File(...).readAsStringSync()` + 计数），且**正是防"改一半"
     最有效的一条** —— 逐模块替换最容易漏掉某处，而漏掉的那处不会有任何报错。
   - `CoverImage` 的**渲染**行为断言不了（要 Flutter）→ 用模拟器截图取证兜。

### ★ 4.59.0 施工完成记录（2026-10-01）

**新增两个文件（职责分离是关键）**
- `lib/core/cover_spec.dart` —— **零 Flutter 依赖**的规格层：`CoverKind`（7 个用途分类）
  + `CoverSpec`（radius=12 / gap=8 / pad=8 / thumbRadius=4 / photoRadius=2
  + `aspect` 表 + `columns` 表 + `declared` 常量清单）。
  拆出来的原因：`ui_cover.dart` import 了 flutter → 依赖 `dart:ui`，
  纯 Dart VM 下**连编译都过不去**，自检根本 import 不了。规格放这里就能真断言。
- `lib/core/ui_cover.dart` —— 渲染层：`CoverImage`（构造时**强制**注入 loading
  骨架 + error 兜底，调用者没有"忘记写兜底"这个选项）、`CoverThumb`（列表行 40×56）、
  `CoverFallback`（六色哈希调色板 + 名字首字）、`coverDelegate(kind)`、`coverPad`。

**实际替换落点（13 处）**
| 位置 | 原状 | 现状 |
|---|---|---|
| 小说书架网格 | 3 列 / 0.52 / gap 12 / 圆角 10 | `coverDelegate(bookGrid)` + 圆角 12 |
| 小说封面图 | 裸 `Image.network` + 私有兜底 | `CoverImage`（`clip:false`，外层已裁） |
| 直播频道网格 | 3 列 / 0.75 / 无间距 | `coverDelegate(liveGrid)` + `coverPad` |
| 引擎直连结果墙 | 3 列 / 0.62 / 圆角 8 | `coverDelegate(coverGrid)` + 圆角 12 |
| 壁纸图墙 | 3 列 / 0.65 / gap 4 / 圆角 8 | `coverDelegate(wallGrid)` + 圆角 12 |
| 菜谱网格 + 详情大图 | 2 列 / 0.85 / gap 6 | `coverDelegate(cardGrid)` + `CoverImage` |
| 书目列表小封面 ×5 | **同一段代码复制了 5 遍**（40×56 / 圆角 4 / 只有 errorBuilder） | `CoverThumb` |
| 专辑列表小封面 ×2 | 44×44 / 圆角 4（同样复制两遍） | `CoverThumb(width:44,height:44)` |
| 音乐播放页封面 | 230×230 / 圆角 16 | `CoverImage` |
| 信息头小封面 | 72×96 / 圆角 8 | `CoverImage` |
| 已同步照片墙 | 手写 `headers` + 黑底裂图 | `CoverImage(radius: photoRadius)` |

**有意保留（不算"漏换"）**：阅读器正文大图 4 处（`main.dart`，前缀必为
`Api.img(images[` / `images[`）、壁纸预览大图、`novel_reader` 正文插图 ——
它们是"看图"不是"封面网格"。自检用**前缀判定**把这条钉死：
凡 `main.dart` 里新出现的非 `images[` 前缀的 `Image.network` 一律报红。

**自检 `tool/ui_cover_selfcheck.dart`（49 项）**
① 规格数值；② 表体完整性（`declared` vs `aspect`/`columns` 三表键集必须一致
—— 拦"加了 kind 常量忘记登记 → 悄悄退回正方"）；③ 查表兜底；
④ **口径守卫**：`bookGrid` 必须比 `coverGrid` 更瘦高（带书名条的格子要装下
书名 2 行 + 副标题，调到 >= 就说明封面会被压扁/书名被裁）；
⑤⑥⑦ 源码层 grep 断言（裸封面图清零 / 网格走统一下发 / import 齐备 / 兜底色彩）。

**反证（证明闸门真能拦）**：临时把 `main.dart` 第一处 `CoverImage(` 改回
`Image.network(` → 自检立刻
`FAIL ★ main.dart 剩余的 Image.network 全部是阅读器正文图 [bad=1 reader=4 total=5]`，
并打印行号；还原后 sha256 与改前**逐字节一致**（无残留）。

---

## 四、引擎更新通道（用户诉求 8 的后半）

### 用户原话
「最好让这个（引擎）也会收到更新公告……引擎也要更新嘛。放到管理后台那个里面，那我能够下载。」

### 做法
1. `downloads/engine/engines.json` 增加 `changelog` / `releasedAt` / `minAppVersion` 字段；
   管理台「引擎中心」渲染出"当前版本 / 最新版本 / 更新说明 / 下载"。
2. 引擎 App 启动时拉一次引擎清单，发现比自己新则提示更新（可跳管理台，或直接下载）。
3. 与现有客户端更新通道（`latest-app.json`）**分开**，互不干扰
   —— 这是既有的设计（见 `js/admin.js` 引擎中心注释）。

---

## 五-A、统一密钥库（4.60.0 新增诉求）

### 用户原话
「很多 AI 厂商的 TTS 模型和 API 密钥是通用的。在 AI 模块输入的 Key，TTS
模块也能用，不用重复输入。你要弄好一点，做好各个厂商的登记。」

### 现状（2026-10-01 核实）
- AI 模块的 Key 存 `aikey_<providerId>`（`ai.dart:136/138`）；
  语音模块存 `tts_key_<vendorId>`（`tts_online.dart:73`）——**两套键两套厂商标识**，
  同一家公司的同一把 Key 要填两遍。
- 两边对同一家公司的**叫法还不一样**：AI 35 家 vs 语音 32 家，
  其中 **10 家同名可直通**，但 **2 家同公司不同名**：
  AI `aliyun` ↔ 语音 `dashscope`；AI `bytedance` ↔ 语音 `volc`。

### 做法（已落地）
- `lib/core/api_keys.dart` —— **零 Flutter 依赖**的规则层：
  `KeyUse`（用途）/ `KeyVendor`（别名归一 + `canonical`/`same`）/
  `KeySharing`（★通用性登记：默认通用，百度这类"对话与语音是两套凭证"的显式标 false）/
  `ApiKeyKeys`（键名 + **回落顺序 `apikey_ → aikey_ → tts_key_`**）/ `maskKey`。
- `lib/core/api_keys_store.dart` —— 存储层：`find`（回落读）/ `set`（**只写统一库**）/
  `migrate`（把旧键并入，**已存在则不覆盖**）/ `dump` / `keychainCount`。
- `lib/core/api_keys_page.dart` —— 「我的 → 设置 → API 密钥库」：
  列出已填厂商、掩码、来源徽标、用途说明，可改可删，顶部一键并入历史 Key。
- 接线：`ai.dart` 的 `keyOf/setKey` 与 `tts_online.dart` 的
  `configOf/saveConfig` 全部改走密钥库；TTS 设置页在 Key 来自别处时
  显示「已从 AI 模块自动带出，无需重填」。
- 自检 `tool/api_keys_selfcheck.dart`（54 项）。**重点是"不该合的没合"**：
  别名无交叉 + 反向断言（openai≠azure、xiaomi≠zhipu 等 6 对），
  因为把 A 公司的 Key 发去 B 公司的端点会**泄露凭据**且静默难查。
  归一后跨模块可复用厂商 **12 家**：aliyun azure baidu bytedance groq
  minimax openai openrouter siliconflow stepfun xiaomi zhipu。

### 未做（下一版）
- **语音引擎一键自动配对**：遍历厂商 + 计费方案发最小探测请求，
  命中即自动保存 Key/planId/模型；并尝试拉 `/models` 补全模型列表。
- **书架真正的离线下载**：`Book.add(target:'local')` 目前**只写元数据**
  （`shelf_<kind>`），正文一个字都不下 —— 所以"下载到本机"名不副实，
  打开仍需引擎。要做成"抓全章节 → 落本地 → 由 `LocalNovelReader` 读"。

---

## 五、必须记住的约束（来自用户口述，累计）
- 引擎图标：**保留各自原生**，不得统一替换。
- 引擎：自用版允许**内置源**；分享前必须能一键删源。
- 密码：**当前不要**，但框架要留（4.55.0 已按此做：一个常量开关）。
- 账号：先用大号 `Smalluniverseheng`，以后迁小号（用户说"以后再给"）。
- 滑动：**模块之间不许左右滑；模块内部可以左右滑切子功能**（4.55.0 已按此做）。
- 返回：**回到上一次打开的那个页面/模块**（4.55.0 已修）。
- 下载：保持现有**直链下载**方式；网页端点引擎应能直接跳转并自动互通（诉求 7）。
