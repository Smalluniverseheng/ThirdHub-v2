# 任务总清单 · 逐项对账（唯一进度真相版）

> 生成：2026-09-25 · 第十五轮 | 主线仓 `Smalluniverseheng/ThirdHub-v2`
> **为什么有这份文件**：任务清单长期"只勾不核"——`docs/TASKS.md` 的复选框停在 2026-09-14，
> 早已与代码脱节；于是出现「看板说没做、其实做了」与「看板说做了、其实只是名字像」两种失真。
> 本文把四份清单**逐项拿代码核了一遍**，每项都给「文件:行」级证据，并明确三态判定。
>
> 判定口径（重要）：
> - **[完成]** 代码在、并且**真的被调用**；
> - **[部分]** 半成品或"名字像而契约缺"（例：表建了但没路由用、前端有页而后端无端点）；
> - **[未完成]** 找不到实现，或只有占位注释。
> - 一律**以代码为准，不以复选框为准**；引用行号取自本轮（2026-09-25）的实际文件。

---

## 〇、一页总览

| 清单 | 条目数 | 完成 | 部分 | 未完成 |
|---|---|---|---|---|
| `docs/TASKS.md` 组A–E（含里程碑 M1 验货） | 16 | 2 | 10 | 4 |
| `BUILD-M1.md` 验货清单（M1 8 + M2 5 + 音乐 4 = 17 条） | 17 | 11 | 6 | 0 |
| `功能规划-v3.0` R/M/B/F/S/N + 新增模块 N-1..N-12 | 64 | 26 | 30 | 8 |
| **用户本轮点名的 6 件事** | 6 | **6** | 0 | 0 |
| 本轮新修（非清单内，实测发现） | 2 | 2 | 0 | 0 |

**一句话结论**：你点名的 6 件事在代码里**确实都落地了**（§一 逐条给了行号），
问题不在"改没改"，而在"你手上那台设备有没有真的跑到这份代码"——所以第十五轮的第一件事
就是把它装进 Android 模拟器**实测**（§一.7）。
真正意义上的欠账集中在三处：**组A/B/C/E 的契约层**（§二）、**"假完成"四项**（§五）、
以及**四条产品线里只有一条被维护**（组D 的网页/Electron/Capacitor 轨道）。

---

## 一、用户点名的 6 件事（最高优先，逐条给证据）

| # | 要求 | 判定 | 代码证据 |
|---|---|---|---|
| 1 | **模块之间禁止左右滑动切换** | ✅ 完成 | `lib/main.dart:346` `static bool get navSwipe => false;`（常量，只读）<br>`lib/main.dart:353` `enforceNavSwipeOff()`；`init()` 于 `:269` 调用 —— 幂等地把老盘里的 `nav_swipe=true` 清成 false<br>`lib/main.dart:363` `setNavSwipe(v)` **丢弃入参恒写 false**；`:3734` AI 工具写同一设置时同样丢弃<br>`lib/main.dart:3892-3894` 导航 `PageView(physics: NeverScrollableScrollPhysics())`；`:3883` 导航层**不注册任何横向拖拽识别器**<br>`lib/core/nav_swipe.dart:39` 旧识别器 `NavSwipeRecognizer` 仍在仓里但**已无人 import**（`main.dart:25` 注释确认）= 留档死代码 |
| 2 | **搜索要有暂停/停止键** | ✅ 完成 | `main.dart:2029` `_searching => loading \|\| _autoPull`；`:2097-2102` 转圈变**红色方块停止键**；`:1936` `_askStop()` 先弹「停止搜索？」再 `_seq++` 作废在途请求、**保留已收结果**；`:2161` 底部续拉区另有停止出口 |
| 3 | **搜索要"一条条蹦出来"** | ✅ 完成（粒度见备注） | `main.dart:1898` `_pumpShown()` 逐帧递增 `_shown`（`:1905`），`_pumpStep = 40`（`:1826`）、每帧 16ms（`:1907`）；`main.dart:1916` `_autoPullLoop` 自动连续翻页、间隔 200ms（`:1828`）<br>**备注**：粒度是「每帧 +40 条」而非严格「每帧 1 条」——因为列表用的是非懒加载 `ListView(children:[…])`（`:2132`），一次性挂 1000+ 个 tile 会掉帧，所以用分帧铺开。若你要的是**肉眼可见的一条一条**，把 `_pumpStep` 调成 1–2 即可（一行改动，见 §六.1） |
| 4 | **详情页补全**（换源/简介/目录懒加载） | ✅ 完成 | 换源 `main.dart:6078 _switchSource()`（拿书名回引擎重搜、按源去重）、入口 `:6171` + 来源行 `:6211`、`_canSwitch` `:6049`；简介默认 4 行可展开 `:6220-6227`；目录 `CustomScrollView + SliverList.builder` 懒加载 `:6186/:6236`，默认只列 30 章 `_chapPreview` `:5990` |
| 5 | **阅读界面底栏 8→5 格 + 更多 + 听书悬浮球** | ✅ 完成 | `lib/core/novel_reader.dart:792-796` 底栏 5 格（目录/书签/搜索/夜间/更多）；`_moreSheet()` `:681`；听书悬浮球 `_ttsBall()` `:641`、位置 `_ballPos()` `:634`、归一化坐标 `ballX/ballY` `:59`、松手贴边 `:661`、不受菜单显隐影响 `:786` |
| 6 | **番茄式阅读菜单结构** | ✅ 完成 | `novel_reader.dart:1-6` 文件头自述对齐番茄；长按段落菜单 `_paraMenu()` `:293`（复制/朗读本段/从此段听书/加书签）；更多面板 `:681`；设置面板 `:448`（亮度/护眼/字号/字体/字色/背景/翻页/皮肤）；翻页 5 模式 `:507` + `_FlipPager` `:809` |

### 1.7 那为什么"看着像没改好"？——本轮实测排查

排查了三条可能，结论如下：

1. **更新通道是好的**（已实测）：`latest-app.json` 现为 `version=4.52.0 / code=50539`，
   `sha256=aa5409ca…` 与 GitHub Release `v4.52.0` 的资产一致；端内「检查更新」读的那个
   JSON 与用户真正点击的别名 URL `downloads/thirdhub/thirdhub-app.apk` 都返回 200。
   → **不是"发不出去"，是要在 App 里点一次更新并装上去**。
2. **穷举了"第二条横滑切模块"的路径**（怀疑对象全查了）：全仓 `PageView` 8 处、
   `TabBarView` 3 处、`HorizontalDragGestureRecognizer` 1 处，逐个看过来——
   导航层那处已是 `NeverScrollableScrollPhysics`；`main.dart:5276` 那个没写 physics 的
   `PageView` 是**本地漫画阅读器**（子页，不切模块）；`ai_page.dart:506-508` 的横向拖拽
   只服务于"抽屉已打开时拖回去"。→ **源码层面找不到第二条横滑切模块的路径。**
3. **真正被实测抓出来的设备侧缺陷是"半残包"**（见 §三）：CI 只给 arm64 出 Flutter 引擎，
   而 APK 里却留着 `lib/armeabi-v7a/`、`lib/x86_64/` 两个空壳目录 →
   **32 位 arm 手机与 x86_64 模拟器能装上、启动即崩**。
   如果那台手机是 32 位 ARM，表现就是"打开就闪退/白屏" → 自然"看着像没改好"。

---

## 二、组A–E（`docs/TASKS.md`）逐项

> 注：组A/B/C/E 依赖的四份设计文档
> `DEVICE-PROTOCOL.md` / `CAPABILITY-ROUTER.md` / `BUILTIN-ENGINES.md` / `ADAPTER-LEGADO.md`
> **在仓库里都不存在**（只有 `docs/planning/THP-2.1-协议对齐版.md` 有愿景描述）。
> 也就是说这几组是"照着文档实现"，而文档本身没入库 → 这是它们长期"看着在动、永远做不完"的结构性原因。

### 组A 设备协议骨架
| 项 | 判定 | 证据 / 缺口 |
|---|---|---|
| A1 发现服务(mDNS) | 部分 | `server/index.js:188-194` 只 `bonjour.publish`，**没有 browse/find**；实际发现靠 UDP 19527 收 HELLO（`:120-186`）+ 前端主动扫描（`flutter_app/lib/core/discover.dart:154-273`）。手动添加 UI 有：`engine_direct_page.dart:66-94`、`pro_system.dart:604` |
| A2 握手/capabilities + devices 表 | 完成 | `server/data/devices.json`（`index.js:270-283`）、`/v1/pair`（`:428-439`）、UDP HELLO 带 caps 登记（`:147-170`）、`/v1/meta`（`:417-421`）、`server/thp1.js:26-29 CAPS`。注：是 JSON 文件不是 DB |
| A3 心跳状态机 | 部分 | 30s 周期广播 `index.js:182` + `:206-207` 的 `3×` 判离线、`peer-hub.js:40 ONLINE_MS=45000`；**没有 degraded 三态、没有连续失败计数器**（只有 online/offline 二分） |
| A4 SSRF 防护 | **未完成** | 全仓无网段校验：图片代理可直接抓任意 http（`routes-sources.js:45-71`）、引擎抓取无限制（`engine.js:246-264`）。只有**客户端**扫描限私网（`discover.dart:276-283`） |

### 组B Legado 适配器
| 项 | 判定 | 证据 / 缺口 |
|---|---|---|
| B1 ADAPTER-LEGADO.md 8 项清单 | **未完成** | 该文档不存在；实际只桥接了 4 个 API（search 走 WS `routes-search.js:79-101`；detail/toc/content 走 HTTP `routes-library.js:24,35,65`） |
| B2 fixtures 真实样本入库 | **未完成** | 仓内无 fixtures 目录/文件 |
| B3 方言→IR 映射 + 对拍测试 | 部分 | 无独立 `mapping.ts`；映射**内联**在 `engine.js`（`xpathToCheerio:7` / `parseChain:32` / `splitPost:85`）与各 `engine-*.js` 的 `ir*` 函数；**无对拍测试** |
| B4 首次接入引导弹窗 | 部分 | 首启引导 `main.dart:816-929`、指纹 TOFU 弹窗 `:963-988`、端网弹窗 `peer_page.dart:79-102`；**缺 Legado 接入的图文教程** |

### 组C 能力路由
| 项 | 判定 | 证据 / 缺口 |
|---|---|---|
| C1 routes 表 + fan-out + IR 合并 | 部分 | **无 routes 表**（硬编码 if 链：`routes-search.js:12/58/138`）；fan-out 有（`Promise.all` + 并发池 `index.js:550-556`）；IR 合并去重有（`routes-search.js:122-131` 按 `name\|author`）。缺口：源数被 `slice(0,3)/(0,2)` 写死（`routes-search.js:21,29,37,44`），非能力/权重驱动 |
| C2 动态权重 + 自动禁用/恢复 | 部分 | `health` Map + `healthHit`（`index.js:363-368`）**只用于排序**（`routes-search.js:115-121`，成功率差 >30% 才置前）；**无自动禁用/恢复** |
| C3 短缓存 + request_log | 部分 | 缓存齐（聚合 60s `index.js:362`、TOC 10min `:364`、正文 30min `routes-library.js:72`、详情 5min `engine.js:393`、图片 24h `routes-sources.js:49-59`）；**`request_log` 完全不存在** |
| C4 管理面板"源健康"页 | 部分 | 后端控制台只有 5 个页签（`server/public/index.html:61`）；`/v1/status` 只把 health 塞进 JSON（`routes-sources.js:73-77`）。前端有**客户端**健康度页 `pro_reading.dart:16-62`/`:307-362` |

### 组D 双前端
| 项 | 判定 | 证据 / 缺口 |
|---|---|---|
| D1 build:web + Chrome74 门禁 | **未完成** | 本仓无 web 构建产物；`server/public/index.html` 只有 115 行后端控制台，与 3.x 网页端不是一回事 |
| D1 Electron 三平台 | **未完成** | 全仓无 electron 目录/依赖 |
| D1 Capacitor Android+iOS | **未完成** | 全仓无 capacitor 目录/依赖 |
| D1 tag 触发并行出包 | 部分 | `build-m1.yml:6` 按 `v4*/v5*` 触发（flutter-android `:156` + 桌面三平台矩阵 `:198`）；**无 web/Electron/Capacitor 目标** |
| D2 core 对接 v2 后端 | 部分 | `Api`/`postEncrypted`(AES-256-GCM) `main.dart:241/249`、`pro_kit.dart:82`、`peer_hub.dart`、THP 信封拆包 `peer_hub_logic.dart:850`；**缺 WS 长连接**（`pubspec.yaml` 无 `web_socket_channel`，事件靠 HTTP 轮询） |
| D2 模块对等表 | 完成 | 书架/阅读器/搜索/播放器(音乐+视频+直播)/AI chat/相册/work区 全部有对等页 |
| D2 悬浮球 Dart 实现 | 完成 | `main.dart:6434 NavOrb` + `:6361 FsExitOrb`；位置持久化 `orbPos:367`；吸边开关 `:313`；模块面板可拖排序 `:6472` |
| D2 低端机模式 + 7 语言 | **部分（1 真 1 假）** | 7 语言：`i18n.dart:11` 声明 7 种、入口 `main.dart:832`；**但 fr/ru/es/ar 每语言只有 ~10 个词**（`i18n.dart:234-273`），切过去大面积回落中文 → 属"假多语言"。低端机模式：**零实现**（全仓仅 `engine_direct.dart:433` 一句注释） |
| D2 CI 出包 | 完成 | `build-m1.yml:156` + `build-apk.yml`；**本轮又修掉两个出包缺陷**（见 §三） |

### 组E 内置引擎
| 项 | 判定 | 证据 / 缺口 |
|---|---|---|
| E1 EnginePlugin 统一接口 | **未完成** | 全仓无 `EnginePlugin`；各引擎各自为政（`engine.js` 导出 search/detail/catalog/content；`engine-drpy.js` 等各导出 `runSource/runPlugin` + `ir*`），无统一接口/注册表 |
| E2 drpy 沙箱 | 部分 | 用的是 **Node `vm` 不是 QuickJS**（`engine-drpy.js:3,29,42,57`）；且 `server/data/drpy-sources.json` **不存在** → "真实源点播跑通"不成立 |
| E3 venera/musicfree 沙箱 | 部分 | 兼容层已写（`engine-comic.js:13,93`、`engine-music.js:6,14`、`engine-lx.js:54,62`）；但 `data/comic-sources.json`、`data/music-sources.json` **都不存在** → 无实例源 |
| E4 首启导入 + sync | 完成 | `index.js:302-326`（内容哈希判据 + 撤销通道）、纯函数 `preset-sync.js:59-120` + 单测 `test_preset_sync.cjs`、预置包 `sources-preset/health-book.json`（15 源 / 10 撤销）、导入脚本 4 个 |

### 里程碑 M1 验货（`BUILD-M1.md`，实为 17 条）
完成 11：通知栏就绪+地址+指纹 / 首启引导+指纹确认 / 点书→目录→正文（剥脚本）/ 下一章连翻 / 目录页加入书架 / 杀进程后书架与继续阅读 / 首页聚合四组 / 图片二次加载 `X-TH-Cache: hit` / 启动自检横幅无 fail / 播放过自动入歌单 / 后端启动自检。
部分 6：**搜索结果显示延迟 ms**（后端有 `latency` `routes-search.js:109`，前端列表没渲染 `main.dart:2189-2199`）/ **目录页书源延迟统计**（只在 `pro_reading.dart` 的 R-2 页）/ 视频·漫画·音乐三条链路"页面齐、引擎齐，但**无实例源入库**"/ **自检横幅缺音源计数**（`index.js:620-622` 只有书/漫/影）。

---

## 三、本轮新修（不在任何清单里，是实测发现的真缺陷）

### ① APK「半残包」——32 位 arm 手机与 x86_64 模拟器**装上即崩**（P0）
- **现象**（x86_64 模拟器实测）：安装成功（`versionName=4.52.0 versionCode=50539`），一启动就
  `UnsatisfiedLinkError: dlopen failed: "/data/data/com.thirdhub.app/app_lib/libflutter.so" is for EM_AARCH64 (183) instead of EM_X86_64 (62)`。
- **根因**：CI 恒定 `-Ptarget-platform=android-arm64` → Flutter 只给 arm64 出
  `libflutter.so`/`libapp.so`；但插件仓库里的**预编译 jniLibs 是全 ABI 的**，
  于是包里仍留着 `lib/armeabi-v7a/`、`lib/x86_64/` 两个目录，**各只有 2 个插件 .so、没有引擎**。
  4.50.0 / 4.51.0 / 4.52.0 三版**都是这样**。
- **修法**（本轮已推 `674ded78`）：
  1. `flutter_app/android/app/build.gradle.kts` —— 按 `target-platform` **精确剔除**未声明的 ABI 目录
     （宁可「装不上」，系统会明确说不兼容；绝不允许「装上就崩」这种用户侧黑洞）。未传该属性时行为不变。
  2. `build-apk.yml` 默认改 `android-arm,android-arm64` —— 覆盖全部真机 ABI。
  3. 新增硬闸门：**APK 内每个 `lib/<abi>/` 必须同时含 `libflutter.so` 与 `libapp.so`**，否则直接 fail。

### ② 同一版本号重复出包会**顶掉线上资产**（P0·流程）
- **历史事故**：4.49.0 先后跑了两个 run，两个都 success、都发 `v4.49.0` Release，
  后完成的那个把线上资产从 `e7fb53dd…` 换成 `50bba599…`，**体积还一样**（29803914 B）→
  `latest-app.json` 的 sha256 与 Release 资产对不上。
- **修法**：加闸门「**`Release v<ver>` 已存在则跳过发布**」，并在日志里明确提示
  「要出新包请递增版本号（版本号铁律：只增不减）」。

### ③ 本地出不了包这件事本身（环境）
本机 `dart` **无法 spawn 任何子进程**——最小复现：`dart` 起个 `cmd.exe /c echo` 都失败，
报 `CreateFile failed 231（所有的管道范例都在使用中）`（`process_win.cc:744`）。
`dart analyze` / `dart compile kernel` / `flutter assemble` 全部卡在这。
→ 因此**本机无法出 APK、无法做类型检查**；正式做法改成：
**借 CI 出包**（`workflow_dispatch` 加 `abis`/`publish` 入参，可出任意 ABI 的测试包且绝不发 Release），
下回用 `api.github.com` 取 artifact，装进模拟器做真机级验证。

---

## 四、"部分"里最该优先的（按用户可见度排序）

| 序 | 项 | 现状 | 一句话修法 |
|---|---|---|---|
| 1 | **fr/ru/es/ar 词典** | 每种 ~10 词，切过去大面积中文 | 把 `i18n.dart:234-273` 补到与 `en` 同量级（约 180 键 ×4） |
| 2 | **低端机模式** | 零实现 | `AppSettings` 加 local-only `liteMode`，接到动画/模糊/分帧步长 |
| 3 | **`request_log` 观测** | 全无 | `routes-search.js`/`routes-sources.js` 落环形日志 + `/v1/request-log` |
| 4 | **SSRF 防护** | 全无 | 抽纯函数 `ssrf-guard.js`，图片代理与引擎抓取前置校验内网/`100.64/10` |
| 5 | **`C1` routes 表** | 源数被 `slice(0,3)` 写死 | 落 routes 表 + 按权重取前 N，替换硬编码 |
| 6 | **`C2` 自动禁用/恢复** | 只排序不摘 | 健康度低于阈值自动摘除，恢复期回填 |
| 7 | **F-1 真后台备份** | 前台才跑 | 接 WorkManager/ContentObserver，做到被杀照跑 |
| 8 | **`E1` EnginePlugin 接口** | 无统一接口 | 定义接口 + 注册表，四个引擎适配 |
| 9 | **`E2/E3` 实例源入库** | `data/{drpy,comic,music}-sources.json` 不存在 | 入库真实源并补端到端验收 |

**"假完成"四项（最容易骗过看板，须优先纠正）**：7 语言 / F-1 后台备份（前台触发冒充）/ F-5 人脸归档（手动标记冒充本地模型）/ OCR（明确占位未接）。

---

## 五、下一步排期（按"一口气做完"的原则分批，每批都能独立验收）

- **批 1（本轮收尾）**：模拟器实测 6 件事 + 半残包修复验证（§一.7 / §三.①）
- **批 2（前端体感）**：7 语言补齐 · 低端机模式 · `_pumpStep` 粒度可选 · M1 两条延迟显示
- **批 3（后端契约）**：SSRF 防护 · `request_log` · routes 表 · 健康度自动摘除
- **批 4（引擎与源）**：`EnginePlugin` 接口 · 真实影视/漫画/音源入库 · 组B 文档 + fixtures + 对拍
- **批 5（轨道决策，需你拍板）**：组D 的 web/Electron/Capacitor 是做还是从看板移除；
  WS 长连接要不要上；`E2` 是否真上 QuickJS 替换 Node `vm`。
