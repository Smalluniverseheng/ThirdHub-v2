# ThirdHub v4 — 安卓主客户端 + 家庭后端

> **本仓就是用户手机上正在用的那条产品线。**
> 客户端包名 `com.thirdhub.app`，当前版本 **4.48.0**（versionCode 50535），安装包约 **28 MB**。
> 仓库名里的 `-v2` 是历史遗留（第二代聚合平台 OmniHub 之后的第二个仓），与版本号 `4.x` 无关 —— 不要按仓名推断版本。

---

## 一、先读这一段：四条产品线，别搞混

本项目同时存在多条 Flutter / Android 产品线，**它们不是同一条线**。
接手前请先确认自己改的是哪一条 —— 曾经有改动落在旁支上、而用户用的是本仓，白做一轮。

| 产品线 | 源码位置 | 仓库 | 包名 | 当前版本 | 体积 | 谁是主力 |
|---|---|---|---|---|---|---|
| **第三方聚合 V4** | `flutter_app/` | **本仓 `ThirdHub-v2`** | `com.thirdhub.app` | **4.48.0** | ~28 MB | **★ 用户在用的主线** |
| Android 轻壳版 | `ThirdHub-Android` | `ThirdHub-Android`（私有） | `com.thirdhub.android` | 3.0.16 | ~10 MB | 备用 |
| 完全体客户端（旁支） | `D:/ai/thirdhub-flutter` | `ThirdHub-Flutter`（私有） | `com.thirdhub.thirdhub_flutter` | 0.4.4 | ~105 MB | **旁支，已搁置** |
| 漫画稳定版（第二代） | `OmniHub-Android` | `OmniHub-Android`（私有） | — | 2.4.0 | ~60 MB | 历史存档 |

**只改 V4，就只碰本仓的 `flutter_app/` 与 `server/`。**

判别技巧（三条里任一条对上就是本仓）：

1. 包名 `com.thirdhub.app`；
2. 安装包 28 MB 左右（旁支是 105 MB，轻壳是 10 MB）；
3. 应用内「检查更新」读的是 Supabase 桶里的 `latest-app.json`（旁支读的是网页端 `app-versions.json`）。

---

## 二、本仓包含什么

```
flutter_app/          ★ V4 主客户端（Flutter 3.47.4）
  lib/main.dart         入口 + 全部模块注册（单文件，约 6300 行）
  lib/core/             80 个模块文件（下节逐类说明）
  android/              Android 工程（Kotlin 侧扩展）
  assets/branding/      品牌图标（与网页端逐字节同源）
  tool/                 纯 Dart 自检脚本

server/               ★ 家庭后端（Node.js ≥ 20，HTTPS :9527）
  index.js              服务入口
  engine*.js            四类内容引擎（详见 §四）
  agent-dsh.js          THA/1 Agent 运行时（DSH）
  agent-profiles.json   Agent 权限档位（服务端权威）
  peer-hub.js           PH/1 端网中枢
  mcp-registry.js       MCP 服务注册表
  routes-*.js           各能力路由
  test_*.cjs            协议自检

plugins/              插件体系
  th-plugin.js          插件 SDK（具名 apply(ctx)，禁 export default）
  example-downloader/   示例插件
  selftest-plugin-e2e.js 真进程端到端自检

docs/                 19 份文档 —— 索引见 §五
deploy/               一键部署（install-linux.sh / install-windows.ps1 / thirdhub.service）
legado-patch/         Legado 零配对补丁（AutoPairer.kt）
tools/                thp-check.js（THP 契约校验）· rebuild-env.sh
build-out/            分模块 changelog 数据（changelog.json / changelog-full.json）

ARCHITECTURE.md       架构总纲
STYLE_GUIDE.md        UI 规范（铁律：禁用 emoji）
```

### `flutter_app/lib/core/` 模块分类（80 个文件）

| 类别 | 文件 |
|---|---|
| Agent / AI | `ai_agent` · `ai_agent_page` · `agent_dsh_client` · `agent_models` · `agent_policy` · `ai` · `ai_page` · `ai_skills` · `ai_store_prefs` · `pro_ai` · `chat` |
| 阅读 | `novel_reader` · `pro_reading` · `reader_fonts` · `read_stats` · `tts` · `tts_presets` · `local_import` |
| 引擎 | `engine_direct` · `engine_direct_page` |
| 媒体 | `pro_media` · `media_formats` · `pro_gallery` · `gallery_page` · `pro_browser` · `browser_page` · `photo_map` · `pip` |
| 端网 | `peer_hub` · `peer_hub_logic` · `peer_page` · `native_net` |
| MCP / 工具 | `mcp_page` · `local_tools` · `local_tools_logic` |
| 系统 | `app_version`（**版本号唯一来源**） · `cloud` · `home_io` · `changelog` · `changelog_logic` · `module_clog_page` · `notify` · `app_log` · `log_page` |
| UI 基建 | `neu`（拟态） · `nav_swipe` · `nav_swipe_logic` · `pro_kit` · `pro_system` · `share_card` · `vendor_icons` |
| 业务模块 | `mini_modules` ~ `mini_modules11` · `lab_*` · `job_center` · `discover` · `files_page` · `feedback_page` · `backend_admin_page` · `auto_scan_page` · `sensor_page` · `play_tag` · `recents` |

---

## 三、变更前必读的三条铁律

### 1. 版本号只改一个地方，但要同步 5 处

唯一来源：`flutter_app/lib/core/app_version.dart` 的 `kAppVersion` / `kAppCode`。
改完必须手工同步：

- `flutter_app/pubspec.yaml` 的 `version: x.y.z+code`
- `server/mcp-registry.js`
- `server/routes-data.js`（**两处**）

改完 `grep` 全仓确认无残留旧版本字面量，**且必须重新出包**（改的是 Dart 代码，不是配置）。

> 曾漏改导致「装了新版仍被判旧版、反复弹升级」。

### 2. 提交前必须过的门

本机 `dart analyze` 不可用（见 §六 环境坑）。实际闸门是：

```
dart format --output=none            # 只当语法门，不格式化
纯 Dart 自检七连                      # nav_swipe / local_tools / agent_proto / modules /
                                     # agent_selfcheck / peer_hub_selfcheck / changelog_selfcheck
server/test_agent_proto.cjs
server/test_chat_proto.cjs
server/selftest-peer-hub.js
plugins/selftest-plugin-e2e.js
版本号残留 grep
```

**新增或改动依赖 Flutter 的 `lib/` 文件时，以上全绿 ≠ 能编译 —— 必须推 CI 真编译一轮。**

### 3. 发版是四条通道，漏一条就串版

| 通道 | 位置 | 谁更新它 |
|---|---|---|
| ① 版本化包 | 桶 `downloads/thirdhub-app-<ver>.apk` | 发布脚本 |
| ② 清单 | 桶 `downloads/thirdhub/latest-app.json` | 发布脚本（端内「检查更新」读它） |
| ③ 无版本别名 | 桶 `downloads/thirdhub/thirdhub-app.apk` | **没有任何自动化，必须手工覆盖** |
| ④ Release | GitHub `v<ver>` | CI |

> ③ 漏刷 → 网页端显示的体积是上一版的，下到手的也可能是旧包。

---

## 四、能力现状

### 内容引擎（`server/engine*.js`）

| 引擎 | 文件 | 覆盖 |
|---|---|---|
| Legado 书源 | `engine.js` | 小说（含图片章节 / 净化 / 进度） |
| Venera 图源 | `engine-comic.js` + `venera.js` + `venera-runtime.js` | 漫画 / 画廊 |
| drpy 影视源 | `engine-drpy.js` | 视频 / 选集 |
| LX 音源 | `engine-music.js` / `engine-lx.js` | 音乐 / 歌单 / 歌词 |

另有 `engine-tvbox.js`（TVBox 影视源适配）。

### Agent（THA/1 协议）

- 协议文档：**`docs/AGENT-PROTOCOL.md` —— 改协议先改它。**
- 分工：Flutter 侧只做**控制面**（发起任务 / 渲染事件流 / 处理确认 / 展示审计）；Agent 内核（上下文装配 / 插件 / 沙箱 / MCP）在 **server 侧 DSH**。
- **没有 DSH 时降级为轻量 Agent，但事件协议不变**，所以控制面不需要改。
- 权限：`server/agent-profiles.json` 为权威，`flutter_app/lib/core/agent_policy.dart` 是本地镜像（用于 UI 提前把按钮画成「需确认 / 已禁用」，并在无后端时先拦一道）。
- 自检：`server/test_agent_proto.cjs`（118 项）+ `flutter_app/tool/agent_proto_selfcheck.dart`（191 项），**与服务端 JSON 逐项对拍，漂移即红**。

### 端网（PH/1）

后端中枢 `server/peer-hub.js`，前端内核 `core/peer_hub_logic.dart`（零依赖）。
**三条铁律**：

1. 发现 ≠ 接入 —— UDP 只登记「待登录」，须 `POST /agent/peer/join` 换 token 才算在线；
2. 匿名探针 `/agent/peer/ping` 在鉴权闸门之前，且只回身份；
3. `execToken` 是第三道门，**端列表绝不返回它**。

自检：`server/selftest-peer-hub.js`（174 项）。

### 插件体系

- SDK：`plugins/th-plugin.js`；示例：`plugins/example-downloader/`；教程：`docs/PLUGIN-SDK.md`。
- 照 DSH / Cordis 范式：具名 `apply(ctx)`、禁 `export default`、`setInterval` 必须进 `ctx.effect()`。
- **插件走 IPv6 / 内网穿透可无后端直连前端。**
- 自检：`plugins/selftest-plugin-e2e.js`（78 项，真进程）。

### 前端离线可用

`local_tools_logic.dart`（零依赖工具箱）+ 上下文快照注入 + 离线能力清单进 prompt；
`peer_list` / `peer_invoke` 进本机工具表（`peer_invoke` 归 `_dangerous`）。

---

## 五、文档索引

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 架构总纲（设计哲学 / 架构图 / 路由 / 路线图） |
| [STYLE_GUIDE.md](STYLE_GUIDE.md) | UI 规范（**禁 emoji**，改 UI 前必读） |
| [docs/AGENT-PROTOCOL.md](docs/AGENT-PROTOCOL.md) | **THA/1 Agent 协议（改协议先改它）** |
| [docs/CHAT-PROTOCOL.md](docs/CHAT-PROTOCOL.md) | 对话协议 |
| [docs/THP.md](docs/THP.md) / [docs/THP-SDK.md](docs/THP-SDK.md) | THP 传输协议及其 SDK |
| [docs/PLUGIN-SDK.md](docs/PLUGIN-SDK.md) | 插件开发教程 |
| [docs/FEATURES.md](docs/FEATURES.md) | 功能清单 |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | 变更日志 |
| [docs/PROJECT-INTRO.md](docs/PROJECT-INTRO.md) | 项目介绍 |
| [docs/TASKS-ROADMAP.md](docs/TASKS-ROADMAP.md) | 路线图 |
| [docs/HANDOVER.md](docs/HANDOVER.md) | 交接说明 |
| [docs/PROMPT-FOR-NEXT-AI.md](docs/PROMPT-FOR-NEXT-AI.md) | **给下一个 AI 的提示词** |
| [docs/PRIVACY.md](docs/PRIVACY.md) / [docs/TERMS.md](docs/TERMS.md) | 隐私 / 条款 |

---

## 六、环境坑（本机每会话必撞）

1. **`CreateFile failed 231`（管道池耗尽）** → `dart analyze` / `dart compile` / `flutter test` 全废。
   绕法：`dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json <script.dart>` 走 VM 跑纯 Dart 自检。
   脚本传**绝对路径**（Bash shim 的 cwd 不可靠，相对路径会假报「缺文件」）。
2. **`github.com:443` 不可达** → `git push` 全废，提交走 GitHub Git Data REST API。
3. **Bash 退出码会被吞**（`node --check` 对坏文件也返回 0）→ 用写结果文件的方式判定成败。
4. **本机没有 `kotlinc`** → Kotlin 改动只能靠 CI 编译验证（曾因此漏掉 `Conflicting overloads`）。
5. `flutter test` 报 `WebSocketException: Invalid WebSocket upgrade request` = 本机代理劫持 loopback → 先设 `NO_PROXY=localhost,127.0.0.1,::1`。
6. Flutter 用 `D:/ai/flutter-3.47.4/flutter/bin/flutter`（**勿用 `D:/ai/flutter` 的 3.24.5**），`PUB_CACHE=D:/ai/pc`。

---

## 七、快速开始

### 客户端

```bash
cd flutter_app
flutter pub get
# 出包走 CI（本机 dart 无法建子进程）；本地调试：
flutter run
```

### 家庭后端

```bash
cd server
node index.js          # 起在 https://<本机IP>:9527
```

或一键部署（Linux / macOS：`deploy/install-linux.sh`，Windows：`deploy/install-windows.ps1`）。

首次启动会自签 HTTPS 证书（`scripts/gencert.js`）；客户端首次连接需确认证书指纹。

### 用 Docker 起后端

```bash
cd server && docker build -t thirdhub-backend . && docker run -p 9527:9527 -v th-data:/data thirdhub-backend
```

---

## 八、安全注意事项

- `android/keystore.properties` 与 `android/thirdhub.jks.b64` **已在公开仓出现于 git 历史，视为已泄露**。是否轮换签名密钥由项目所有者决定（轮换后旧版将无法覆盖安装）。
- CI 出包**不读仓内文件**，走 `secrets.TH_KEYSTORE_BASE64` + `TH_STORE_FILE` / `TH_STORE_PASSWORD`。
- 任何密钥不得硬编码进源码或出货面。

---

## 九、协议

MIT License，见 [LICENSE](LICENSE)。

主站：<https://thirdhub.pages.dev> · 下载中心：<https://thirdhub.pages.dev/#/download>
