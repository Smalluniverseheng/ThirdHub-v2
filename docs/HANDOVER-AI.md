# ThirdHub 交接文档（给下一个 AI · 唯一权威版）

> 生成：2026-09-25 | 主线仓：`Smalluniverseheng/ThirdHub-v2`（public）
> 本文件替代已过时的 `docs/HANDOVER.md`（停在 2026-09-15）与 `docs/PROMPT-FOR-NEXT-AI.md`（停在 9-15，仍在讲「后端APK」那套旧架构）。
> **动手前必读本文 + `.workbuddy/memory/YYYY-MM-DD.md` 的「进度看板」小节。**

---

## 0. 第一件事：确认你没改错产品线（这是历史上真出过的事故）

账号 `Smalluniverseheng` 下有**四条安卓产品线**，互相极易混淆。曾因为两个仓的 README 都自称「主线」，导致 AI 改了 105MB 的旁支，而用户手机上装的是 28MB 的主线。

| 产品线 | 仓 / 源码 | 包名 | 版本 | 体积 | 更新清单写在 |
|---|---|---|---|---|---|
| **★ 第三方聚合 V4（唯一主线）** | `ThirdHub-v2` → `flutter_app/` | `com.thirdhub.app` | **4.49.0 / 50536** | **~28 MB** | Supabase `latest-app.json` |
| Android 轻壳版 | `ThirdHub-Android`（私有） | `com.thirdhub.android` | 3.0.16 | ~10 MB | 网页端 `app-versions.json` |
| 完全体客户端（旁支·已搁置） | `ThirdHub-Flutter`（私有） | `com.thirdhub.thirdhub_flutter` | 0.4.4 | ~105 MB | 网页端 `app-versions.json` |
| 漫画稳定版（第二代） | `OmniHub-Android`（私有） | — | 2.4.0 | ~60 MB | — |

### 三个判别技巧（任取其一即可判对）
1. **看包名**：`com.thirdhub.app` = 主线；`com.thirdhub.thirdhub_flutter` = 旁支；`com.thirdhub.android` = 轻壳。
2. **看体积**：**28MB 是主线**（用户点名「100 多 MB 那个是完全体」= 旁支，已搁置，不要动）。
3. **看更新清单**：V4 走 **Supabase** 的 `latest-app.json`；另两条走**网页端**的 `app-versions.json`。

> 用户原话：「先把前端后端这一条线做好」——**这条线 = `ThirdHub-v2/flutter_app`（前端）+ `ThirdHub-v2/server`（家庭后端）**。旁支那条先放着。

---

## 1. 主线是什么（架构）

```
第三Hub V4
├── flutter_app/     Flutter 安卓前端（纯播放器，不含任何源/引擎管理）
│   └── lib/core/    80 个模块文件 + 66 个已注册模块页
├── server/          Node.js 家庭后端（:9527，自签 HTTPS）
│   ├── peer-hub.js       PH/1 端网中枢
│   ├── routes-*.js       各业务路由
│   ├── scripts/          自检脚本（注意：在 scripts/ 下，不在 server/ 根）
│   └── package.json      ★ 后端版本号唯一来源（现 0.8.4；ping/MCP/clientInfo 均已改为运行时读它）
├── plugins/         th-plugin.js SDK + example-downloader 示例
├── docs/            协议与规划文档（planning/ 是宪法与总清单）
├── android/         安卓壳配置（keystore 已泄露，见 §7）
└── tools/           构建与发布工具
```

**铁律：前端是纯播放器。** 源管理、引擎、DSH Runtime 全部只在后端或独立引擎 App 上。往前端加源管理 = 违反宪法。

---

## 2. 当前版本状态（2026-09-25）

| 部件 | 版本 | 状态 | 下载通道 |
|---|---|---|---|
| V4 前端 APK | **4.49.0 / 50536** | ✅ **已四通道发布 + 五通道独立校验全 PASS**。构建源提交 `7bc57c73`，CI `build-apk 36054417044` success；APK sha256 `50bba599c003d0ec7cfa9315f831cdfb1d960218f27c9a069da2d8cfa5bfe922` / 29803914 B；`pickSettingsRow` 符号已在二进制中（4.48.0 二进制为 0 命中，见 §6 #3b） | Supabase `latest-app.json` + 桶三通道 + Release |
| 网页端主站 | **3.35.0** | 已上线（`thirdhub.pages.dev`，含 GitHub 推送 `b91ba85e`）；V4 下载卡片**实时读** `latest-app.json`，无需为 V4 发版单独部署前端 | — |
| 家庭后端 | **0.8.4** | 已发三通道（zip 已重打并解包冒烟：118/118 + 174/0） | ① `downloads/thirdhub-backend-0.8.4.zip` ② `downloads/thirdhub/thirdhub-backend.zip` ③ **Release `backend-v0.8.4`（id `396047309`，资产 5860372 B，digest 与本地逐字节一致）—— 本轮补建** |
| 旁支（完全体） | 0.4.4 | **已搁置，不要动**（网站端介绍已重写并上线，见 §2） | — |

> **发版批次记**：4.49.0 的 CI 先后跑出两个 run（`36053636554` on `7d26d314`、`36054417044` on `7bc57c73`），
> 两个都 success 且都会发 `v4.49.0` Release。**最终资产被后完成的 `36054417044` 覆盖**：
> digest 由 `e7fb53dd…` 变为 `50bba599…`（体积同为 29803914 B —— 版本串等长抵消，**别用体积判断版本**）。
> 发布用的是覆盖后的 `50bba599…`。**教训：同一版本号有多个 run 时，认 digest、不认体积、不认 run 的先后。**

### 4.49.0 本轮做了什么（2026-09-25 · 第七轮 + 第八轮）
- **【第八轮】★ `th_settings` 取行缺陷（真实数据丢失类缺陷，本轮由端到端实测暴露）**：
  `th_settings` 是「一用户多行」的通用键值表，网页端 `js/ai/ai-api.js` 把各厂商 API Key 也写进同一张表
  （id = `ai:key:<provider>` / `ai:keys:<provider>`，`data` 是**字符串或数组**）。客户端 `_settingsRow()`
  却 `select=data,updated_at` 后取 `list.first`，而 PostgREST **不保证返回顺序** →
  ① 取到 Key 行时 `settingsDown()` 读不到 `settings`，写回 0 个键（表现：**点了同步没反应**）；
  ② 更糟：`settingsUp()` 的合并基线变空，只把认识的 13 键写回 `id=<uid>` 行，
  **云端另外 25 个键连同 `kv`（阅读锚点）一起被抹掉**。真实账号 `67fd9596…` 就同时存在这两行。
  修法：新增纯 Dart `SettingsBridge.pickSettingsRow()`（与网页端 `js/modules/settings-sync.js` 的
  `rows.find(r => r.id === u.id) || rows[0]` 对齐），`select` 补上 `id`；自检 95 → **111**；
  推送 `7bc57c73`，CI `dart-selfcheck 36054417120` success。
- **★ 轻量智能体的「缺件」提示变成可点**：降级路径缺模型 / 缺 API Key 时，原来只丢一句「去 AI 对话页选一个模型」——而「AI 对话」不是一个能直达的页。现在提示右侧直接给「去选模型 / 去填 Key」按钮，一键进 `AiProvidersPage`（厂商与密钥），回来还会复核并告诉你配好了没有；模式卡片上也常驻「模型与密钥」入口。
- **★ 轻量智能体的「缺件」提示变成可点**：降级路径缺模型 / 缺 API Key 时，原来只丢一句「去 AI 对话页选一个模型」——而「AI 对话」不是一个能直达的页。现在提示右侧直接给「去选模型 / 去填 Key」按钮，一键进 `AiProvidersPage`（厂商与密钥），回来还会复核并告诉你配好了没有；模式卡片上也常驻「模型与密钥」入口。
  - 实现：`ai_agent_page.dart` 的 `_say()` 增加 `action` / `onAction`，`_noteAction` 真的渲染成按钮；新增 `_openModelSetup()`；并修掉 3 处「直接给 `_note` 赋值、不清旧按钮」的残留。
- **★ 三处「静默失败」**（都是「看着成了、其实没成」）：
  - `cloud.dart` 的 `syncUp` 由 `Future<void>` + `catch (_) {}` 改为**如实回传 bool**（未登录也回 false）。
  - 共享清单 `syncMsg` 此前**只赋值、从不渲染**（页面上根本没这个控件）→ 现在真显示，并区分「已同步 / 只存到本机 / 未登录」；上传也不再 fire-and-forget。
  - 共享相册长按删除：失败时此前照样 `removeAt(i)`，缩略图消失但文件还在，下次重选文件夹又回来 → 现在失败保留在列表并说明原因。
- **两处订阅 / 监听器泄漏**：有声书与家庭音乐库每次 `_play` 都新开 `positionStream.listen`、旧的从不取消（改为单订阅 + dispose cancel）；短剧与家庭影院把匿名闭包监听器改为具名可摘，并补 `_load` 的 `mounted` 守卫 —— 进播放页立刻返回时异步完成后 `setState` 到已 dispose 的 State 会抛异常。
- **名实与可读性**：论坛回帖时间原来直接打印毫秒时间戳（`1758712345678`），抽 `fmtWhen()` 统一为相对时间（主题详情页头部一并改用）；共享相册 / 共享清单空态「云端家庭共享待资源库接口开放」是**误导**——共享清单的云端同步一直在跑（`th_shared` 表已验证存在且有数据），相册的跨端同步尚未实现，两边文案改准。
- **后端不变**：本轮未动 `server/`，仍是 **0.8.4**（Node 侧版本号已收归 `package.json` 单一来源，不需要跟着前端升）。
- 纯 Dart 自检八连：**PASS 1179 / FAIL 0**（与基线逐项一致）。

### 4.48.0 那一轮做了什么（2026-09-25 · 第六轮，已发布）
- **★ Agent 真正接通**（对应「Agent 也是能够调用的」）：`/agent/send` 只落一条 `user_message` 就返回，且 `AgentDshClient.appendEvent` 全仓无调用者 → 任务页长期「发了没反应」，而降级模式恰恰是多数人的状态。本轮把降级路径落地：
  - `core/agent_dsh_client.dart`：新增 `lastDshError`；`_accepted()` 修正「失败信封 `data` 本身就是 Map」被当成成功的误判（「没装 DSH」曾被报成「启动成功」）。
  - `core/ai_agent.dart`：新增 `online` / `offlineReason` / `useFullAgent` / `openConnector`；`bootstrap()/refresh()` 探测失败时**不再保留旧值**（原来会把从没连上的后端显示成「已降级」）。
  - `core/ai_agent_page.dart`：`_online` 改看 `AgentRuntime.online`；`_boot()` 去掉自锁；`_send()` 降级分支真正执行 `_runLite()`（本机模型 + 工具循环 + 逐步 `appendEvent` 回填）；新增 `_askLiteConfirm()`（confirm 级工具本地弹窗，档位语义与完整模式一致）。
  - `main.dart`：注册 `AgentRuntime.openConnector`（跳后端地址页，回来即重探）。
- **娱乐线 5 处修复**：菜谱空 catch、摄像头 rtsp/mjpeg 误导文案、壁纸三态空态、广播 0 条空白、`EngineItemPage` 无历史/无收藏入口（空态文案指着它、它却没入口）。
- **★ 服务端版本号收归单一来源**：`server/package.json` 0.8.3 → **0.8.4**；`routes-data.js` 的 `/v1/ping` 与 MCP serverInfo、`mcp-registry.js` 的 clientInfo 全部改为 `require('./package.json').version`。此前同一个后端从 `/v1/meta` 与 `/v1/ping` 报出两个不同版本。
  - **连带取消了 3 处「发版必须手工同步」的约定**（`app_version.dart` 里那条过时注释已改写）。
- **更新历史**：`changelog` 补 4.47.0 / 4.46.0 / 4.45.0 / **4.48.0**（public 50 条 / admin 365 条，均经「只有新增」闸门）。
- **网站清单**：`app-versions.json` 的 `server` 段升 0.8.4（含 size/sha256/changelog）；`flutter` 段修掉「version 0.4.3 vs notes 停更在 0.4.4」的自相矛盾。
- 为什么是 4.48.0 而不是复用 4.47.0：4.47.0 的 Release 已产出过一个**不含上述修复**的 APK，同号不同字节会让已装该版本的人永远收不到修复（4.40.0 已踩过）。
- **★ 4.48.0 发布与校验（已核验）**：四通道全 PASS（① 版本化包 ② `latest-app.json` 4.48.0/50535 ③ **无版本别名手工刷** ④ Release `v4.48.0`），外加「误传键位 `downloads/downloads/…` 应为非 200」断言；随后 `_verify_4480.mjs` 六项 PASS —— 与旧校验器的关键区别是**把线上文件真的下回来算 sha256**（旧版只比 content-length，4.40.0 那种「同版本号不同字节」会漏）。
- **网页端 3.34.0 → 3.35.0 已上线**：`server` 段 0.8.4 对线上生效；完全体客户端介绍重写（标注「已搁置」+ 列出 0.4.3/0.4.4 两个构建）已生效。

---

## 3. 云端分工（宪法定稿，别自己发明）

| 代号 | 是什么 | 干什么 | 实际账号 |
|---|---|---|---|
| **CF-A** | Cloudflare 账号 A（大号） | **网站面**：Pages（`thirdhub.pages.dev`）+ Workers（公告 / 更新检查 / 公共目录查询） | `43a379d1850a953981f2835a9d5ed683`（1829487897@qq.com） |
| **CF-B** | Cloudflare 账号 B（小号） | **数据面**：Workers + KV（设置/锚点）+ D1（设备清单/配额）+ R2（头像/备份 10MB） | `9e4f3e8880c3e6287e405e04e67c5253`（3585334489@qq.com） |
| **Supabase A** | 大号 Supabase | **仅 Auth**（Apache-2.0 可自托管，不做业务数据） | ref `mxvxlgjzeboktufumxbp`（**孟买**，与宪法要求的「新加坡」不符 → 待议项） |
| **Supabase B** | 小号 Supabase | 小号项目（已有 `grade-tracker` @ 新加坡） | 见 `.env` 的 `SUPABASE_ACCESS_TOKEN` |
| **Neon** | Postgres | B 类用户（无后端者）的云端托管库（书架/进度/笔记元数据） | 待接入 |

**已知阻塞：两个 CF 账号的 R2 都未开通**（API 返回 code `10042`，需绑支付方式）。R2 是「头像/备份 10MB」的硬前置 → 在 R2 开通前，这条能力只能降级（见 §6 未完成清单）。

### 两端数据表契约（网页端 `js/supabase.js` = 客户端 `lib/core/cloud.dart`）
```
SYNC_TABLES = ['th_bookshelf','th_reading_progress','th_history','th_favorites','th_settings','th_user_devices']
载荷 = { user_id, id, data, updated_at }
th_settings 特殊：{ id: <uid>, data: { settings: { s: {...38键} }, updatedAt } }
```
设置 38 键的定义在网页端 `js/store.js` 的 `DEFAULT_SETTINGS`，**客户端 `cloud.dart` 的 `settingKeys` 必须与之逐字一致**（改一边必须改另一边）。

---

## 4. 十二铁律（违反任一 = 任务作废）

1. **引擎隔离** —— 引擎代码零改动，前端不得含源管理。
2. **双账号隔离** —— CF-A / CF-B 各管各的，不交叉。
3. **Auth 唯一** —— 只走 Supabase Auth。
4. **云端零内容** —— 云端不存内容本体（只存元数据/设置）。
5. **协议只增不减** —— THP / THA / PH 协议字段只加不删。
6. **改代码必改清单** —— 动了什么就更新对应清单/文档。
7. **意图确认制** —— 用户没要求的不要自作主张改。
8. **优先级冻结** —— 见 §5，变更权只在用户。
9. **版本号单一来源** —— 前端 = `lib/core/app_version.dart`；后端 = `server/package.json`。改后必须 grep 全仓确认无残留字面量，且前端改版本号**必须重新出包**。
10. **四仓 CHANGELOG 独立**。
11. **前端纯播放器**。
12. **编排非集成**。

---

## 5. 已定稿的优先级（宪法第 7 条 + 会话总清单 G 节）

**P0** 引擎隔离 + 仓库收缩 + 清单体系 → **P1 数据互通** → **P2 AI 核心体验** → **P3 板块铺开** → **P4 后端数据层 + 后端 APK** → **P5 内容扩展** → **P6 商业 L3** → **P7 引擎 SDK**。

> 当前进度：**P0 完成**；**P1 数据互通 —— 客户端侧代码已完成并推送，待出包后端到端实测**；P2 未动。

---

## 6. ★ 未完成清单（与当天日志「进度看板」同源，每轮更新）

| # | 事项 | 状态 | 下一步 / 阻塞 |
|---|---|---|---|
| 1 | V4 **4.49.0** 出包 | ✅ **已完成**：`build-apk 36054417044`（`7bc57c73`）success → 四通道发布 → `_verify_4490.mjs` **五通道全 PASS**（`publish_4490_out.txt` / `verify_4490_out.txt`）；changelog 亦已上传（public 51 / admin 366 条） | — |
| 2 | 4.48.0 发布（含别名通道） | ✅ **已完成并六项校验 PASS**（`publish_4480_out.txt` / `verify_4480_out.txt`） | — |
| 3 | 两端数据同步端到端实测 | ✅ **已完成（本轮）**：`_probe/b3_e2e.cjs` 用 service role 建临时用户 → 换**真实 anon key 取真 `authenticated` JWT** → 6 表按客户端原样的 insert/upsert/读回，含 RLS、嵌套+中文载荷、`th_settings` 形状与合并语义、多行歧义；**0 FAIL（连跑两次）**，跑完 6 表行数回到基线（0/13/44/0/5/6）且既有行逐字节未变 | 真机那一段（改本机 → 换端看到）仍留在 #4 里一起做；本机无设备 |
| 3b | **`th_settings` 取行缺陷（本轮新发现并修复）** | ✅ 代码已修并推 `7bc57c73`；自检 95 → **111**，八连 **PASS 1195 / FAIL 0** | 根因：`th_settings` 是「一用户多行」通用表，网页端把 `ai:key:<provider>` 也写进同一张表（`data` 是字符串/数组），而客户端 `select` 不带 `id` 且取 `list.first`，PostgREST 又不保证顺序 → 读空（「点了同步没反应」）+ 合并基线为空时覆盖掉云端其余 25 键与 `kv`。修法与网页端 `rows.find(r => r.id === u.id) \|\| rows[0]` 对齐 |
| 4 | **Agent 接入实测** | 🚧 **代码已接通 + 本轮补上缺件直达入口** | 仍需**真机**跑一轮（配对家庭后端 / 或只配本机模型走降级路径）；本机无设备故未做 |
| 5 | **娱乐性（内容线可用）** | 🚧 已修 5 处（4.48.0）+ 5 处（4.49.0：订阅泄漏×2、监听器不摘×2、删除假成功、回帖时间戳、名实文案×2） | 根因仍在：源包陈旧（148 条抽测仅 20 条真出结果）。方案：把 `tools/source-health.cjs` 产出的健康源包接进内容线 |
| 6 | **阅读模块逐页可用** | ❌ 未做 | 同 #5 |
| 7 | 两个 CF 用起来 | ❌ 未做 | **R2 未开通（10042）是硬前置**，需用户绑支付方式；在开通前先落地 D1/KV 能做的部分 |
| 8 | 两个 Supabase 用起来 | ❌ 未做 | 大号 ref 在孟买与宪法「新加坡」冲突 → **需用户拍板**：迁区 or 改宪法 |
| 9 | P3 板块铺开（笔记/待办/下载中心/相册UI/浏览器增强） | ❌ 未做 | 按优先级，P1/P2 之后 |
| 10 | P4 后端数据层 + 后端 Android APK | ❌ 未做 | — |
| 11 | N-1~N-12 新增模块、AI-1~AI-10、E-1~E-6 | ❌ 未做 | 见 `docs/planning/ThirdHub-功能规划-v3.0.md` |
| 12 | `docs/` 里的过程文档归并（`M1-SPRINT.md` / `PLAN-v3.md`） | ❌ 未做 | 低优 |
| 13 | 源健康流水线接入日常 | ❌ 未做 | 与 #5 合并做 |
| 14 | 后端 Android APK（内嵌 server）刷新 | ❌ 未做 | `latest-backend.json` 仍是 **4.2.0**、内嵌 2026-09-20 的 server 代码 → 与 0.8.4 不一致。重建需 Android+Kotlin 工具链，本轮未做（**zip 包已是最新**，仅这个 APK 落后） |
| 15 | 网站静态清单部署 | ✅ **已完成**：站点 3.34.0 → **3.35.0** 已上线（`tools/release.cjs` 六步全通，含 GitHub 推送 `b91ba85e`）；线上已核实 `server` = 0.8.4 / 5860372、完全体段 mirrors=2 且含「已搁置」措辞 | — |
| 16 | 娱乐线剩余缺陷 | 🚧 4.49.0 修掉 6 类（`positionStream` 泄漏、监听器不摘 + setState-after-dispose、共享清单静默失败、共享相册删除假成功、共享相册名实不符、论坛回帖裸时间戳） | **仍未做**：视频详情页无引擎兜底、资讯/播客硬编码源无兜底、14 处 `setState(() async ...)` 首屏竞态 |
| 17 | 网页端 `updated` 日期比本地日期早一天 | ⚠ 已知小缺陷 | `tools/release.cjs` 用 `new Date().toISOString().slice(0,10)`（UTC）写 `updated`/`releaseDate`，本地凌晨发布时会写成前一天。修法：改本地日期。属站点脚本改动，未在本轮动 |

### 真机验证的硬约束（不是 bug）
`adb devices` 无设备 / 无模拟器 → **端网（#68）与插件体系（#69）的真机端到端本轮无法做**，源码级 e2e 与服务端 174 断言已全绿。不要因为「测不了」就以为功能没做。

---

## 7. 安全（重要）

- **`android/keystore.properties`（明文口令）+ `android/thirdhub.jks.b64` 曾躺在 public 仓**，已于 2026-09-21 备份（`D:/ai/_backup_thirdhub_keystore_20260921/`）并删远端，**但仍在 git 历史 → 视为已泄露**。是否轮换由用户定（轮换会让旧版无法覆盖安装）。
- CI 出包**不读仓内文件**，走 `secrets.TH_KEYSTORE_BASE64` + `TH_STORE_FILE/TH_STORE_PASSWORD`。
- **PAT 明文曾泄于 Flutter 仓 `.git/config`，token 仍未轮换 → 用户本人必须轮换**，轮换后同步 `.env` 的 `GITHUB_TOKEN`。
- 任何密钥不得硬编码进出货面；推送前必过 check-secrets（含 `sb_secret_` / `sbp_` 硬拦）。

---

## 8. 发版流程（四通道）

改版本号（**前端只需改 `core/app_version.dart` + `pubspec.yaml` + 根 `README.md`；Node 侧自后端 0.8.4 起不再需要跟着改**，见 §4 铁律 9）→ 出包 → **四通道全刷**：

| 通道 | 位置 | 备注 |
|---|---|---|
| ① 版本化包 | 桶 `downloads/thirdhub-app-<ver>.apk` | |
| ② 清单 | `latest-app.json`（Supabase 桶） | **发布后必须回读核对 notes 不串版** |
| ③ 无版本别名 | `downloads/thirdhub/thirdhub-app.apk` | **无任何自动化会更新它 → 必须手工刷** |
| ④ Release | GitHub `v<ver>` | |

**`changelog` 也是发版面**：改 `_build_changelog.mjs` 的 NEWS → 构建 → `_up_changelog.mjs`（整行覆盖写）→ **必须先 `_dump_changelog_backup.mjs` 存证 + `_verify_changelog_delta.mjs` 证明「只有新增」**，否则静默丢历史。

### 工具路径（本机）
```
node    C:/Users/英莉/.workbuddy/binaries/node/versions/22.22.2-3/node.exe
dart    D:/ai/flutter-3.47.4/flutter/bin/cache/dart-sdk/bin/dart.exe
flutter D:/ai/flutter-3.47.4/flutter/bin/flutter   （勿用 D:/ai/flutter，那是 3.24.5）
git     D:/ai/git/cmd/git.exe
推送    D:/ai/_push_rest_files.mjs --repo <owner/name> --root <dir> --msg @<msgFile> --files <a,b>
网页端发布 D:/ai/deep seek/tools/release.cjs
env     C:/Users/英莉/WorkBuddy/第三方聚合平台/.env
```
`.env` 键名：`CLOUDFLARE_API_TOKEN, GITHUB_TOKEN, SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL, TENCENTCLOUD_SECRET_ID, TENCENTCLOUD_SECRET_KEY`

---

## 9. 本机环境坑（每会话都会撞）

1. **Bash shim 的 PATH 常失效 → 优先用 PowerShell**；**stdout 常被吞 → 写文件再 Read**；中文输出必须走文件（管道按 GBK 解）。同一文件多次 Edit 只落第一个 → 单条发。
2. **`CreateFile failed 231`（管道池耗尽）→ `dart analyze`/`dart compile`/`flutter test` 全废**。根因是 `AndrowsStore.exe` 句柄泄漏。
   **★绕法**：`dart run` 会死在 native-assets 子进程 → 改用
   `dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json <script.dart>` 走 VM，纯 Dart 自检不必等 CI。
   **★脚本传相对路径会报「缺文件」（Bash shim 的 cwd 不可靠）→ 一律传绝对路径。**
3. **`github.com:443` 不可达**（`git push` 报 Connection reset）→ 提交一律走 `_push_rest_files.mjs`（GitHub Git Data REST）。
   另：`raw.githubusercontent.com` 也不可达，取仓库文件正文用 `/repos/{r}/contents/{path}` + base64 解码。
4. **`grep -r` 全仓会 SIGTERM/超时** → 用定点 grep。
5. `flutter test` 报 `WebSocketException: Invalid WebSocket upgrade request` = 本机代理劫持 loopback → 先设 `NO_PROXY=localhost,127.0.0.1,::1`。
6. **`_publish_v4.mjs` 的 notes 是裸路径**（带 `@` 会静默回落旧文案 → 清单串版）；只有 `_push_rest_files --msg` 用 `@file`。
   **模块格式两头都会踩**：`.cjs` 里写顶层 `await` → 语法错；`.mjs` 里写 `require` → 加载即死零输出。
   判据是「有没有顶层 `await`」：只用 `require` + 无顶层 await → `.cjs`；要顶层 await → `.mjs` 且全部 `import`。
   Edit 锚点**别选注释行**。
7. **adb daemon 每个沙箱调用都被回收** → 同一条命令里 `start-server → 轮询到 device → forward → 干活`。
8. **查 CF token 一律打 `/accounts`，别打 `/user/tokens/verify`**（账户级 token 打 verify 会假报 401）。
9. Sandbox 的 `fetch` 打不通的域会**一直挂到工具超时** → 必须自己上 `AbortController` + 短超时。
10. **★ 可能同时有另一个 AI 实例在同一个仓上干活**（本机曾实测到：一边在升 4.49.0，另一边在修 `th_settings` 取行）。这不是猜测 —— 判据是**文件 mtime 在本轮内持续前进**（`app_version.dart` → `HANDOVER-AI.md` → `build-out/changelog*.json` 依次被改）。
    **遇到时的规矩**：
    - **照常推自己的改动**。`_push_rest_files.mjs` 的 `base_tree` 取的是**推送那一刻的远端 head**、且 `force:false`，所以（a）不会覆盖对方已推的其它文件，(b) 万一撞上并发推送会**直接报非快进失败**而不是静默吞掉 —— 失败就重试，别改脚本。
    - **发版前先看「在途版本有没有被人发过」**：`GET /releases/tags/v<ver>` + 回读 `latest-app.json`。已被别人发过就别抢，改为升一版。
    - **产物认提交，不认版本号**：CI 里同一版本号可能同时有多个 run（不同 head）。发版要挑**含自己那次修复的那个 run** 的 artifact，否则同版本号不同字节 = 已装用户永远收不到更新。
    - 交接文档/日志是「最后写入者胜」，被覆盖了不致命；**代码进 git 才算数**，所以优先把改动推上去。

---

## 10. 提交前实际闸门（本机 `dart analyze` 已废）

1. `dart format --output=none`（挡语法错误；注意 `--set-exit-if-changed` 是 flag，不能带值）
2. 纯 Dart 自检**八连**（`_probe/run_checks.sh`）：`nav_swipe 57 / local_tools 135 / agent_proto 191 / modules 202 / agent_selfcheck 120 / peer_hub_selfcheck 327 / changelog_selfcheck 52 / settings_bridge_selfcheck 111` → 合计 **PASS 1195 / FAIL 0**
   （`settings_bridge` 95 → 111 是本轮为「`th_settings` 取行」加的 16 条断言；基线数字随断言增长会变，**以脚本实际输出为准**，别把这里的数字当成不可变的阈值。）
3. 服务端：`test_agent_proto.cjs`（118/118）、`test_chat_proto.cjs`、`scripts/selftest-peer-hub.js`（174/0）；改动 `server/*.js` 后再加一遍 `node --check`
4. 插件：`selftest-plugin-e2e.js`（78/0）
5. **版本号残留 grep**（前端 `kAppVersion/kAppCode` + `pubspec.yaml` + `README.md`；**Node 侧自 0.8.4 起不再需要跟着改**）
6. **新增/改动依赖 flutter 的 lib 文件时，以上全绿也 ≠ 能编译 → 必须推 CI 真编译一轮。**
   **★ 无法本地类型检查时的替代闸门**：逐个把新增调用点对到定义处（签名 + 参数名逐项核对），因为 `dart analyze` 在本机必死（见 §9.2）。

---

## 11. 诊断纪律

- **「工具报通过」≠ 真通过**（曾因 thp-check 默认 `--role engine` 跑到 library 上假绿）。
- **「工具报失败」≠ 它指的东西坏了** —— 先追问失败在哪一层（`selftest-peer-hub.js` 在 `scripts/` 下，我一度以为自检坏了）。
- 跨进程契约问题**必须两侧源码对读，别信注释**；修法要用真实数据反证一次。
- 审计器报「全 0」先确认是否扫到目标目录（假绿）。
- 判断「源站是否真死」要分两层：先探根路径存活，再探**搜索路径**；两者结论常常不同（根路径 200 + 搜索路径 404 = 源过期，不是引擎坏）。

---

## 12. 交接纪律（给下一个 AI 的硬要求）

1. **每做一步，就在 `.workbuddy/memory/YYYY-MM-DD.md` 追加一行** `【进度】HH:MM · 做了什么 · 结果/证据`。
2. 做完一段就更新本文 §6 未完成清单，并把状态从 🚧 改成 ✅ 或 ❌→🚧。
3. 用户的安排不要凭记忆，**先读本文 + 进度看板 + `docs/planning/` 里的宪法与总清单**。
4. 不确定「他在说哪个产品」时，**按 §0 的三个技巧判**，判不准就问，别猜。
