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
│   └── package.json      ★ 后端版本号唯一来源（现 0.8.6；ping/MCP/clientInfo 均已改为运行时读它）
├── plugins/         th-plugin.js SDK + example-downloader 示例
├── docs/            协议与规划文档（planning/ 是宪法与总清单）
├── android/         安卓壳配置 + **后端 APK 工程**（`app/` 里是 `com.thirdhub.backend` 的 Kotlin 壳：首启把 assets 解压到 filesDir/runtime，再 exec node index.js 常驻前台 Service）。keystore 已泄露，见 §7
│                    · 版本号读 `../server/package.json`（**不要在 build.gradle.kts 里另写死**）
│                    · assets（node-arm64 运行时 + server 拷贝，~37MB）**不入库**，由 `server/scripts/fetch-node-android.sh` 注入
└── tools/           构建与发布工具
```

**铁律：前端是纯播放器。** 源管理、引擎、DSH Runtime 全部只在后端或独立引擎 App 上。往前端加源管理 = 违反宪法。

---

## 2. 当前版本状态（2026-09-25）

| 部件 | 版本 | 状态 | 下载通道 |
|---|---|---|---|
| V4 前端 APK | **4.49.0 / 50536** | ✅ **已四通道发布 + 五通道独立校验全 PASS**。构建源提交 `7bc57c73`，CI `build-apk 36054417044` success；APK sha256 `50bba599c003d0ec7cfa9315f831cdfb1d960218f27c9a069da2d8cfa5bfe922` / 29803914 B；`pickSettingsRow` 符号已在二进制中（4.48.0 二进制为 0 命中，见 §6 #3b） | Supabase `latest-app.json` + 桶三通道 + Release |
| 网页端主站 | **3.35.2** | 第十轮发版（`tools/release.cjs 3.35.2`）：把下载中心的后端包指向 **0.8.6**。`updated`/`releaseDate` 改为**本地日期**（原 UTC 写法会把上午发布标成前一天，见 §6 #17） | — |
| 家庭后端 | **0.8.6** | ✅ **已发三通道 + 解包冒烟 14/14 PASS**。zip 6030007 B / sha256 `bba034f3df69fee2384221bb14f91d2fe65d4f83d3f78705e61f052b2239eb95` | ① `downloads/thirdhub-backend-0.8.6.zip` ② `downloads/thirdhub/thirdhub-backend.zip` ③ **Release `backend-v0.8.6`（id `396151827`，资产已下载回算 sha256 逐字节一致）** |
| **家庭后端 APK**（`android/` 壳，包名 `com.thirdhub.backend`） | **0.8.6 / 42806** | ✅ **第十一轮重建并四通道发布**（此前一直是 4.2.0）。APK 32626957 B / sha256 `ea8ee56cbf94e1ab706b4e83d7b62418defd79245c4020821c0a2e514e6463d5`；内嵌 node-arm64 运行时（复用 4.2.0 包内已验证的那份）+ server 0.8.6（含 `public/` 与 `scripts/`）+ 12 条预置源。**版本号已改为读 `server/package.json`** | ① `downloads/thirdhub-backend-0.8.6.apk` ② 别名 `downloads/thirdhub/thirdhub-backend.apk` ③ **`latest-backend.json`**（客户端「下载中心」实时读它 → 显示「最新 v0.8.6」）④ Release `backend-v0.8.6` 资产。发布脚本 `D:/ai/_probe/_rel_backend_apk.mjs`（8/8 PASS） |
| 旁支（完全体） | 0.4.4 | **已搁置，不要动**（网站端介绍已重写并上线，见 §2） | — |

> **发版批次记**：4.49.0 的 CI 先后跑出两个 run（`36053636554` on `7d26d314`、`36054417044` on `7bc57c73`），
> 两个都 success 且都会发 `v4.49.0` Release。**最终资产被后完成的 `36054417044` 覆盖**：
> digest 由 `e7fb53dd…` 变为 `50bba599…`（体积同为 29803914 B —— 版本串等长抵消，**别用体积判断版本**）。
> 发布用的是覆盖后的 `50bba599…`。**教训：同一版本号有多个 run 时，认 digest、不认体积、不认 run 的先后。**

### 后端 APK 0.8.6 本轮做了什么（2026-09-25 · 第十一轮）— 把 4.2.0 那个陈年 APK 补齐
- **★ 版本号一直是假的（P0）**：`android/app/build.gradle.kts` 的默认值是写死的 `"4.2.0"`/`42000`，而
  `.github/workflows/build-m1.yml` 的 `backend-apk` 作业**从不传 `-PverName`** → 无论后端发到 0.8.x 哪一版，
  打出来的 APK 都自称 4.2.0，`latest-backend.json` 也就一年到头停在 4.2.0。
  已改为**直接读 `../server/package.json`**（CI 的 `$GITHUB_WORKSPACE/server` 与本地都成立），
  `versionCode = 42000 + minor*100 + patch`（0.8.6 → **42806**）；基数取 42000 是为了**单调不减**（Android 拒装更小的 versionCode）。
- **★ 构建脚本把「管理台」和「自签证书」删掉了（P1）**：`server/scripts/fetch-node-android.sh` 里
  `rm -rf "$OUT/server/scripts" "$OUT/server/public"` —— 而 `public/index.html` **就是** Web 控制台
  （`server/index.js:334` 的 `PUB`），`scripts/gencert.js` 是首启自签证书要 `execSync` 调的。
  **手机上这两样此前根本不在包里。** 已改为与发布包 `_pack_backend.mjs` 用**同一份排除清单**（只排 `data/` 与 `node_modules.msh-partial`），
  并加硬闸门：`public/index.html`、`scripts/gencert.js`、`index.js`、`package.json` 任一缺失直接 exit 1；
  组装前先 `rm -rf "$OUT/node" "$OUT/server"`（stale assets 极难发现）。
- **本机重建成功**：复用旧 4.2.0 APK 里那份**已验证能跑**的 node-arm64 运行时（`node.tar.xz` 21MB，免得再去清华源拉 termux 包）
  + 现 server 0.8.6（含 `public/` `scripts/`）→ Gradle 8.14.4（缓存里那份 launcher）+ JDK17 + `ANDROID_HOME=D:/ai/android-sdk`，
  **4m34s BUILD SUCCESSFUL** → APK **32626957 B** / sha256 `ea8ee56cbf94e1ab706b4e83d7b62418defd79245c4020821c0a2e514e6463d5`。
- **包内四验全过**：`aapt2` 版本串 = `0.8.6 / 42806 / com.thirdhub.backend`；`apksigner` 签名 DN 与旧包同一把
  （SHA-256 `7db37a41…`）；`zipalign -c -v 4` OK；Python `zipfile` 直接读包内 → `assets/server/package.json`=0.8.6、
  `sources-preset/health-book.json`=**12 条源**、`public/index.html` 与 `scripts/gencert.js` 都在、
  **`data/` 与 `msh-partial` 都不在**、`assets/server` 共 1540 条目。
- **四通道发布 8/8 PASS**（新脚本 `D:/ai/_probe/_rel_backend_apk.mjs`）：版本化桶 / 别名桶 / `latest-backend.json`（version+code+sha 三项回读一致）
  / Release `backend-v0.8.6` 资产（下载回算 sha256 一致）；**并且把「用户真正点的那个别名 URL」下回来算了一遍 sha256**。
  客户端「下载中心」读的就是 `latest-backend.json`（`main.dart:4345` → `cloud.dart:120`）→ 现在会显示「最新 v0.8.6」。
- 发版前按铁律备份了线上发布面（`D:/ai/_backup_publish_backendapk_20260925_074111/`，含两个前缀清单 + 两个 latest 清单 + 别名 HEAD），
  并核实在途版本 `thirdhub-backend-0.8.6.apk` **此前未进过桶**（避免重复资产顶掉 digest）。

### 0.8.6 本轮做了什么（2026-09-25 · 第十轮）— 把「搜得出书」补成「真的能读」
- **★ 目录永远只有 1 条章（阅读线 P0）**：`catalog()` 只取 `chapterList` 选择器链的**第一段**（`parseChain(listRule)[0].sel`），把 `@` 之后所有段丢掉。真实源几乎全是链式：`.box_con@dd` / `ul.detail-list-select@li` / `class.list@li@tag.a` / `#content@.page` → **拿容器当条目**，一本 500 章的书端内只显示 **1 个**「章节」，且章节名是全部子链接文本的**拼接**。改用与 bookList 同一个 `resolveList`，并补「选择器写两遍时自身匹配」兜底。
- **★ 正文不分段（阅读线 P1）**：Legado 语义里 `<br>` 就是换行，引擎此前不转换 → 整章切成 **1 段**（实测 365小说网 3707 字 / 1 段），端内是一坨文字墙。抽成纯函数 `extractParas()`：`<br>` → `\n`，并按**单换行**切段。
- **★ 兜底路径把脚本/导航当正文**：规则取不到正文时兜底「取最长文本块」是在**未清洗**文档上做的 → ① 内联 `<script>` 往往最长（实测酸奶漫画「正文」= 一坨 JS）；② 规则失效的源兜底出**整页站内导航**（实测笔趣阁 4 万字全是「玄幻奇幻/修真武侠…」）。抽成 `largestProseBlock()`：先剥脚本，再要求候选块链接稀疏（`<a>` < 8）。
- **新增权威闸门 `_probe/_read_e2e.cjs`（阅读逐页）**：走前端真正会调的 `/v1/book → /v1/toc → /v1/content`，取**首章 + 中段章**（第 1 章常是封面/公告页，只验首章会漏），并显式拦三类**假通过**：脚本残留 / 页面杂质 / 单章超 2 万字。
- **实测**：引擎规则单测 23 → **35 条全 PASS**；A/B 对照（修前 vs 修后引擎）**目录条数上升 3 源、下降 0 源，正文段数上升 2 源、下降 0 源 → 零回归**；全量 13 源：**完全干净可读 3 源**（小说 1926 章 / 365小说网 518 章 / 快眼看书优+ 258 章，正文 1.1k~7.1k 字、19~212 段），另有 1 源目录 1838 章、正文可取但夹带杂质（源自身规则过时）。
- **`_pack_backend.mjs` 加 3 道新闸门**（缺「目录链式展开」/「`<br>` 分段」/「兜底拒脚本拒导航」直接拒绝打包）；`_smoke_backend_zip.mjs` 加 `[5] 解包后走阅读逐页` → **14/14 PASS**。
- **#17 顺手修掉**：`_upd_av_server.mjs` 与网页端 `tools/release.cjs` 的 `updated`/`releaseDate` 由 **UTC 日期**改为**本地日期**（此前本地上午改清单会写成前一天）。
- 服务端三重自检不变：**118/118**、**0 失败**、**174/0**；`node --check` index/engine/routes-search/routes-library 全 OK。

### 4.49.0 那一轮做了什么（2026-09-25 · 第七轮 + 第八轮）
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

> 当前进度：**P0 完成**；**P1 数据互通 —— 客户端侧代码已推 + 端到端实测已完成（真 JWT + 真 RLS，见 §6 #3/#3b）**；
> **P2 AI 核心体验 —— Agent 控制面代码已接通（4.48.0）+ 缺件直达入口（4.49.0），真机那一轮待设备（#4）**；
> **娱乐性/内容线 —— 后端侧开箱可用（0.8.5 搜索 + 0.8.6 逐页阅读）**。P3 未动。

---

## 6. ★ 未完成清单（与当天日志「进度看板」同源，每轮更新）

| # | 事项 | 状态 | 下一步 / 阻塞 |
|---|---|---|---|
| 1 | V4 **4.49.0** 出包 | ✅ **已完成**：`build-apk 36054417044`（`7bc57c73`）success → 四通道发布 → `_verify_4490.mjs` **五通道全 PASS**（`publish_4490_out.txt` / `verify_4490_out.txt`）；changelog 亦已上传（public 51 / admin 366 条） | — |
| 2 | 4.48.0 发布（含别名通道） | ✅ **已完成并六项校验 PASS**（`publish_4480_out.txt` / `verify_4480_out.txt`） | — |
| 3 | 两端数据同步端到端实测 | ✅ **已完成（本轮）**：`_probe/b3_e2e.cjs` 用 service role 建临时用户 → 换**真实 anon key 取真 `authenticated` JWT** → 6 表按客户端原样的 insert/upsert/读回，含 RLS、嵌套+中文载荷、`th_settings` 形状与合并语义、多行歧义；**0 FAIL（连跑两次）**，跑完 6 表行数回到基线（0/13/44/0/5/6）且既有行逐字节未变 | 真机那一段（改本机 → 换端看到）仍留在 #4 里一起做；本机无设备 |
| 3b | **`th_settings` 取行缺陷（本轮新发现并修复）** | ✅ 代码已修并推 `7bc57c73`；自检 95 → **111**，八连 **PASS 1195 / FAIL 0** | 根因：`th_settings` 是「一用户多行」通用表，网页端把 `ai:key:<provider>` 也写进同一张表（`data` 是字符串/数组），而客户端 `select` 不带 `id` 且取 `list.first`，PostgREST 又不保证顺序 → 读空（「点了同步没反应」）+ 合并基线为空时覆盖掉云端其余 25 键与 `kv`。修法与网页端 `rows.find(r => r.id === u.id) \|\| rows[0]` 对齐 |
| 4 | **Agent 接入实测** | 🚧 **代码已接通 + 本轮补上缺件直达入口** | 仍需**真机**跑一轮（配对家庭后端 / 或只配本机模型走降级路径）；本机无设备故未做 |
| 5 | **娱乐性（内容线可用）** | 🚧→✅ **后端侧打通**（第九轮）：三层根因全修 —— ① 后端 0.8.4 的包**根本起不来**（`peerHub` 的 TDZ）；② 预置源包**永远导不进来**（判据恒真）；③ 引擎缺 Legado 的 `##` 后处理等 3 处规则语义。随包发 **12 条引擎实测可用源**，同一批源 **3/29 → 12/29** | 前端侧（真机打开阅读）留 #4；「开箱可用」已由 `_probe/_content_e2e.cjs` **12/12 PASS** 证明（真启动 + 真 `/v1/search` → 76 本书 / 3.8s） |
| 6 | **阅读模块逐页可用** | ✅ **本轮完成（第十轮）** | 新增 `_probe/_read_e2e.cjs` 走真接口逐页验；修掉三处引擎缺陷（目录链式选择器只取第一段 / `<br>` 不当换行 / 兜底把脚本·导航当正文）。全量 13 源：**完全干净可读 3 源**（小说 1926 章、365小说网 518 章、快眼看书优+ 258 章），1 源正文可取但夹带杂质（源规则过时），其余卡在源级问题（detail 500 / 目录 0 / 演示源）。A/B 零回归；随包 0.8.6 发布，解包后走阅读逐页 PASS | 前端侧「真机打开阅读」仍留 #4（本机无设备） |
| 7 | 两个 CF 用起来 | ❌ 未做 | **R2 未开通（10042）是硬前置**，需用户绑支付方式；在开通前先落地 D1/KV 能做的部分 |
| 8 | 两个 Supabase 用起来 | ❌ 未做 | 大号 ref 在孟买与宪法「新加坡」冲突 → **需用户拍板**：迁区 or 改宪法 |
| 9 | P3 板块铺开（笔记/待办/下载中心/相册UI/浏览器增强） | ❌ 未做 | 按优先级，P1/P2 之后 |
| 10 | P4 后端数据层 + 后端 Android APK | ❌ 未做 | — |
| 11 | N-1~N-12 新增模块、AI-1~AI-10、E-1~E-6 | ❌ 未做 | 见 `docs/planning/ThirdHub-功能规划-v3.0.md` |
| 12 | `docs/` 里的过程文档归并（`M1-SPRINT.md` / `PLAN-v3.md`） | ❌ 未做 | 低优 |
| 13 | 源健康流水线接入日常 | 🚧 **本轮建立并修正口径** | ① `tools/source-health.cjs` 的 `--out` 原先**只导 `{module,pack,name,host,url}`、没有源规则 → 导不进去**；已改为带完整 `source` 对象 + 新增 `--out-pack` 写纯 Legado 数组（`--out` 同时给则自动派生 `<name>.pack.json`）。② **代理口径高估可用性**（代理 29/300 vs 引擎真取 3/29）→ 新增 `_probe/engine_source_verify.cjs` 作为**引擎口径权威闸门**，日常以它为准。③ 待办：把这两个口径接进定时任务 |
| 14 | 后端 Android APK（内嵌 server）刷新 | ✅ **第十一轮已完成** | 见 #20。APK 现为 **0.8.6 / 42806**，与 zip 同号 |
| 15 | 网站静态清单部署 | ✅ **第九轮再做一次**：站点 3.35.0 → **3.35.1**（`tools/release.cjs` 六步，把 `server` 段指向 0.8.5） | 线上已核实 `server` = 0.8.5 / 6028828 |
| 18 | **家庭后端 0.8.5 发布（第九轮新增）** | ✅ **已完成**：`_pack_backend.mjs`（打包脚本化 + 5 道包内硬闸门）→ `_smoke_backend_zip.mjs` **13/13 PASS** → 三通道（版本化桶 / 别名桶 / Release `backend-v0.8.5` id `396116826`，资产下载回算 sha256 一致）→ 网站清单同步 | 参见当天日志第九轮 A9-2 |
| 16 | 娱乐线剩余缺陷 | 🚧 4.49.0 修掉 6 类（`positionStream` 泄漏、监听器不摘 + setState-after-dispose、共享清单静默失败、共享相册删除假成功、共享相册名实不符、论坛回帖裸时间戳） | **仍未做**：视频详情页无引擎兜底、资讯/播客硬编码源无兜底、14 处 `setState(() async ...)` 首屏竞态 |
| 17 | 网页端 `updated` 日期比本地日期早一天 | ✅ **第十轮已修** | `tools/release.cjs` 与 `_upd_av_server.mjs` 原来用 `new Date().toISOString().slice(0,10)`（**UTC**）写 `updated`/`releaseDate`，本地上午发布会被写成前一天。已改为按本地时区取 YYYY-MM-DD；3.35.2 实测 `updated=2026-09-25`（UTC 当时还是 09-24） |
| 19 | 内容线源级缺陷（非引擎） | 🚧 本轮量化 | `💰时阅文学`（用户已标注「搜索正文失-效」）、`凤凰网书城`（detail 500）、`🔖八零电子书`/`⌨52书库`/`总裁🎃`/`快眼看书botaodz`（目录 0 或选择器不匹配）、`🌸笔趣阁`（`.text` 规则已过时 → 正文夹带页面杂质，4 万字/章）。**这些要改的是源包（`sources-preset/health-book.json`），不是引擎**；下一轮可做「按引擎口径重挑一遍健康源」 |
| 20 | 后端 Android APK（内嵌 server）落后更多 | ✅ **第十一轮已完成** | 本机 Gradle 重建 → APK **32626957 B** / sha256 `ea8ee56cbf94e1ab706b4e83d7b62418defd79245c4020821c0a2e514e6463d5`，包名 `com.thirdhub.backend`，**0.8.6 / 42806**。四通道：① 版本化桶 `thirdhub-backend-0.8.6.apk` ② 别名桶 `thirdhub/thirdhub-backend.apk` ③ `latest-backend.json`（version 0.8.6 / code 42806 / sha 一致）④ Release `backend-v0.8.6` 资产（下载回算 sha256 一致）。**8/8 PASS**，客户端「下载中心」会显示「最新 v0.8.6」 |

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
11. **★ `/v1/*` 有 `x-th-token` 闸门（`index.js:492`）——不带密钥一律 401**，极易误判成「后端没起来」。
    探针的写法：`headers: { 'x-th-token': fs.readFileSync('server/data/secret','utf8').trim() }`。
    （`/v1/meta`、`/v1/pair`、`/agent/peer*`、`/thp/*`、静态页**免鉴权**，所以只看这几个会以为一切正常。）
12. **Windows `tar.exe -tf` 的输出是 CRLF**：`execFileSync(...).split('\n')` 后每行尾带 `\r`，
    `.endsWith('.json')` **全假** → 打包自检假失败。用 `split(/\r?\n/).map(s=>s.trim())`。
13. **发布 zip 是平铺布局**（`index.js` 与 `test_*.cjs`、`routes-data.js` 同级），
    而仓内脚本常写 `path.join(__dirname,'..','server','x.js')` → **解包里必挂 `MODULE_NOT_FOUND`**，
    看着像「包坏了」其实是测试自己找不到路。脚本一律「同目录优先、上跳兜底」。
14. **★ 模块 `require` 的位置会变成 TDZ 崩溃**：`server/index.js` 里 `peerHub.init()` 在 244 行、
    而 `const peerHub = require('./peer-hub')` 被放在 367 行的「路由模块分组」里 → 启动即抛
    `ReferenceError: Cannot access 'peerHub' before initialization`，**整个后端起不来**。
    规矩：**凡文件中部调用某模块的 `init()`，先确认它的 `require` 在同文件更早处**；
    且「路由模块分组」这种后来重排过位置的分组最容易埋这个坑（0.8.4 出货包就带着它）。
15. **★ 聚合搜索的条目顺序不稳定 → 闸门别只取「第一本」**：同一个源、同一个关键词，两次搜索
    返回的「第一本书」可能不同，而不同书的目录/正文质量可能差很多（实测 365小说网 一本 518 章、
    另一本 0 章）。冒烟/探针若只试第一本，会**随机假失败**。规矩：**每个源试最多 3 本、取最好的那本**，
    并把「试了几本」打进输出——否则你会以为是自己刚改坏了。
16. **★ Windows 上 `node --check` 不校验语义、只校验语法**：`engine.js` 这类带 `vm` 沙箱的模块，
    语法过了不代表规则语义对。本机 `dart analyze`/`dart compile` 已废、`flutter test` 也挂（§9.2）
    → **纯逻辑改动必须落到「能在 VM/Node 里直接跑的单测」上**（`_engine_rules_test.cjs` 就是这个思路：
    用 `vm.runInContext` 加载 `engine.js` 源码并导出内部函数来断言）。
17. **★ 后端 APK（`android/`）的三个必踩点（第十一轮实测）**：
    - **`aapt2` / `apksigner` / `zipalign` 都在 `D:/ai/android-sdk/build-tools/34.0.0/`**，
      但 `apksigner.bat` 是 Java 程序 —— **必须先 `export JAVA_HOME=D:/ai/android-jdk/jdk-17.0.2`**，
      否则报「JAVA_HOME is not set」而看起来像签名坏了。
    - **`android/` 里没有 `gradlew`**（CI 是靠 runner 预装的 `gradle` 兜底的）。
      本机直接用缓存里的 launcher：
      `~/.gradle/wrapper/dists/gradle-8.14.4-bin/92wwslzcyst3phie3o264zltu/gradle-8.14.4/bin/gradle`，
      环境给 `JAVA_HOME` + `ANDROID_HOME=D:/ai/android-sdk` 即可（AGP 8.5.2 与 Kotlin 2.0.20 都已在
      `~/.gradle/caches` 里，不需要联网）。**整包约 4.5 分钟。**
    - **assets 不在仓里**（.gitignore 已排除，~37MB）→ 重建前必须先组装：`assets/node/`（node-arm64 运行时）
      + `assets/server/`。**最快的路子是复用旧 APK 里那份已验证的运行时**：
      `unzip -o 旧APP.apk "assets/node/*" "assets/node/xz/*"`（`node.tar.xz` 21MB，解压即用，
      不必再跑 `fetch-node-android.sh` 去清华源拉 termux 包）。
    - **`android/thirdhub.jks` 不在仓里**，只有 `thirdhub.jks.b64` → `base64 -d thirdhub.jks.b64 > thirdhub.jks`
      （口令在 `android/keystore.properties`：`thirdhub2026`；用 `keytool -list` 可先自证）。
18. **★ 后端 APK 的版本号原先永远是 4.2.0**：`build.gradle.kts` 默认值写死 `"4.2.0"`/`42000`，而 CI 的
    `backend-apk` 作业**从不传 `-PverName`** → 无论后端发到哪版，打出来的 APK 都自称 4.2.0，清单也就一直停在 4.2.0。
    已改为**直接读 `../server/package.json`**（CI 与本地都成立），`versionCode = 42000 + minor*100 + patch`
    （0.8.6 → 42806）—— **基数取 42000 是为了单调不减**，Android 会拒绝安装比已装版本更小的 versionCode。
19. **★ `fetch-node-android.sh` 曾把 `public/` 与 `scripts/` 一起删掉**：后果是**手机上「管理台」打不开**
    （控制台就是 `public/index.html`，`index.js:334` 的 `PUB` 指向它）且**自签证书生成失败**
    （`index.js:80` 会 `execSync` 调 `scripts/gencert.js`）。现已改为与发布包 `_pack_backend.mjs` **同一份排除清单**
    （只排 `data/` 与 `node_modules.msh-partial`），并加了「`public/index.html` / `scripts/gencert.js` 必须在包里」的硬闸门。
    · 推论：**「打包脚本排除清单」是一处极易静默出错的地方** —— 加排除项前先问「运行期真的不需要它吗」。

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
7. **发布 zip 必须「解包冒烟」**（第九轮新增，两脚本都在 `D:/ai/_probe/`）：
   `_pack_backend.mjs`（打包 + **8 道包内硬闸门**：版本一致 / 预置源在包内且 ≥2 条 / **不许混进 `data/`（含密钥）** /
   回读包内 `index.js`·`engine.js` **关键修复必须在**（peerHub 上移、`##` 后处理、**目录链式展开、`<br>` 分段、兜底拒脚本拒导航**））
   → `_smoke_backend_zip.mjs`（解到干净目录 → 跑包内三重自检 → 真启动 → 走 `/v1/search` 真出书 →
   **`[5]` 走 `/v1/toc`+`/v1/content` 验阅读逐页**）。**本地 `server/` 的测试全绿 ≠ 包能用**
   —— 0.8.4 的包就是「测试全绿但装上打不开、且包里没有源」。后端发版四步：
   打包 → 解包冒烟 → 三通道（版本化桶 / 别名桶 / Release `_rel_backend.mjs` 读回校验）→ 网站清单 `_upd_av_server.mjs` + `tools/release.cjs`。
8. **阅读线权威闸门（第十轮新增）**：`_probe/_read_e2e.cjs`（逐页）+ `_probe/_engine_rules_test.cjs`（规则语义，35 条）
   + `_probe/_read_ab.cjs`（修前/修后 A/B，**证明无回归**）。
   **只有「搜索出书」不够** —— 第九轮就栽在这：`/v1/search` 12/12 PASS，而点进去一本都读不了。
9. **后端 APK 重建的闸门（第十一轮新增）**：
   组装 assets（`_probe/_stage_apk_assets.py`，含 10 项硬闸门：`server/index.js` · `engine.js` ·
   **`public/index.html`** · **`scripts/gencert.js`** · `sources-preset/` · `node_modules/cheerio` ·
   `node.tar.xz` · `xz/xz` · `liblzma.so.5` 必须齐；**`data/` 与 `node_modules.msh-partial` 必须不在**）
   → `gradle assembleRelease` → **包内四验**（`aapt2 dump badging` 看 `versionName/versionCode` +
   `apksigner verify --print-certs`（记得 `JAVA_HOME`）+ `zipalign -c -v 4` + **用 Python 的 `zipfile` 直接读包内
   `assets/server/package.json` 与 `sources-preset/health-book.json` 核对版本与源数**）
   → 四通道 `_probe/_rel_backend_apk.mjs`（**8/8 PASS**，含「把用户实际点的别名 URL 真下回来算 sha256」）。
   · **别只看「BUILD SUCCESSFUL」** —— 构建成功跟「包里装的是对的东西」是两件事（老包就是构建成功但内嵌了旧 server、且缺 public/）。

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
