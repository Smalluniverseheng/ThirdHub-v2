# ThirdHub 交接文档（给下一个 AI · 唯一权威版）

> 生成：2026-09-25 | 主线仓：`Smalluniverseheng/ThirdHub-v2`（public）
> 本文件替代已过时的 `docs/HANDOVER.md`（停在 2026-09-15）与 `docs/PROMPT-FOR-NEXT-AI.md`（停在 9-15，仍在讲「后端APK」那套旧架构）。
> **动手前必读本文 + `.workbuddy/memory/YYYY-MM-DD.md` 的「进度看板」小节。**

---

## 0. 第一件事：确认你没改错产品线（这是历史上真出过的事故）

账号 `Smalluniverseheng` 下有**四条安卓产品线**，互相极易混淆。曾因为两个仓的 README 都自称「主线」，导致 AI 改了 105MB 的旁支，而用户手机上装的是 28MB 的主线。

| 产品线 | 仓 / 源码 | 包名 | 版本 | 体积 | 更新清单写在 |
|---|---|---|---|---|---|
| **★ 第三方聚合 V4（唯一主线）** | `ThirdHub-v2` → `flutter_app/` | `com.thirdhub.app` | **4.46.0 / 50533** | **~28 MB** | Supabase `latest-app.json` |
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
│   └── package.json      ★ 后端版本号唯一来源（现 0.8.3）
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
| V4 前端 APK | **4.46.0 / 50533** | 代码已推 `8ea3bd0d`，CI `#64 build-apk` 构建中 | Supabase `latest-app.json` + 桶三通道 + Release |
| 网页端主站 | **3.34.0** | 已上线（`thirdhub.pages.dev`，推 `25a3b478`） | — |
| 家庭后端 | **0.8.3** | 已发三通道 | ① `downloads/thirdhub-backend-0.8.3.zip` ② `downloads/thirdhub/thirdhub-backend.zip` ③ Release `backend-v0.8.3` |
| 旁支（完全体） | 0.4.4 | **已搁置，不要动** | — |

### 4.46.0 本轮做了什么
- **数据互通（P1）**：客户端 `lib/core/cloud.dart` 从 141 行扩到 300 行，补齐网页端一致的 6 张同步表 + 38 个设置键。
  - 修了一个真 bug：账号资料原本读 `profiles`（旧 OmniHub 遗留表），应为 **`th_profiles`**。
  - 新增 `tableUp/tableDown`、`settingsUp/settingsDown`、`progressUp/Down`、`shelfUp/Down`、`favUp/Down`、`historyUp/Down`、`syncAll({push})`。
- `lib/core/pro_system.dart` 新增「账号数据互通（与网页端）」入口卡片（同步按钮 + 同步范围说明弹窗）。
- 版本号五处同步：`core/app_version.dart`、`pubspec.yaml`、`server/mcp-registry.js`、`server/routes-data.js`×2。

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
| 1 | V4 4.46.0 出包 | 🚧 CI `#64` 构建中 | 绿 → 按 §8 四通道发布；红 → 拉日志修 |
| 2 | 4.46.0 发布（含别名通道） | ⏸ 等 #1 | 别名通道 `downloads/thirdhub/thirdhub-app.apk` **必须手工刷**（无自动化） |
| 3 | 两端数据同步端到端实测 | ⏸ 等 #1 | 可用 Supabase service role 直连做服务端侧验证，不依赖真机 |
| 4 | **Agent 接入实测** | 🚧 代码层已核验 | 完整 Agent 必须配对家庭后端；后端包已可下载，待真机配对验证 |
| 5 | **娱乐性（内容线可用）** | ❌ 未做 | 根因=源包陈旧（148 条抽测仅 20 条真出结果）。方案：把 `tools/source-health.cjs` 产出的健康源包接进内容线 |
| 6 | **阅读模块逐页可用** | ❌ 未做 | 同 #5 |
| 7 | 两个 CF 用起来 | ❌ 未做 | **R2 未开通（10042）是硬前置**，需用户绑支付方式；在开通前先落地 D1/KV 能做的部分 |
| 8 | 两个 Supabase 用起来 | ❌ 未做 | 大号 ref 在孟买与宪法「新加坡」冲突 → **需用户拍板**：迁区 or 改宪法 |
| 9 | P3 板块铺开（笔记/待办/下载中心/相册UI/浏览器增强） | ❌ 未做 | 按优先级，P1/P2 之后 |
| 10 | P4 后端数据层 + 后端 Android APK | ❌ 未做 | — |
| 11 | N-1~N-12 新增模块、AI-1~AI-10、E-1~E-6 | ❌ 未做 | 见 `docs/planning/ThirdHub-功能规划-v3.0.md` |
| 12 | `docs/` 里的过程文档归并（`M1-SPRINT.md` / `PLAN-v3.md`） | ❌ 未做 | 低优 |
| 13 | 源健康流水线接入日常 | ❌ 未做 | 与 #5 合并做 |

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

改版本号 → 出包 → **四通道全刷**：

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
   `.mjs` 里用 `require` → 加载即死零输出 → 验证脚本用 `.cjs`；Edit 锚点**别选注释行**。
7. **adb daemon 每个沙箱调用都被回收** → 同一条命令里 `start-server → 轮询到 device → forward → 干活`。
8. **查 CF token 一律打 `/accounts`，别打 `/user/tokens/verify`**（账户级 token 打 verify 会假报 401）。
9. Sandbox 的 `fetch` 打不通的域会**一直挂到工具超时** → 必须自己上 `AbortController` + 短超时。

---

## 10. 提交前实际闸门（本机 `dart analyze` 已废）

1. `dart format --output=none`（挡语法错误）
2. 纯 Dart 自检七连：`nav_swipe 57 / local_tools 135 / agent_proto 191 / modules 202 / agent_selfcheck 120 / peer_hub_selfcheck 327 / changelog_selfcheck 52`
3. 服务端：`test_agent_proto.cjs`（118/118）、`test_chat_proto.cjs`、`scripts/selftest-peer-hub.js`（174/0）
4. 插件：`selftest-plugin-e2e.js`（78/0）
5. **版本号残留 grep**
6. **新增/改动依赖 flutter 的 lib 文件时，以上全绿也 ≠ 能编译 → 必须推 CI 真编译一轮。**

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
