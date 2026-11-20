# AI 控制总线（真机测试通道）

> App 内建的控制通道：AI / 脚本可以**不触屏**地切模块、左右滑、点控件、读状态、截图。
> 不需要 adb、不需要数据线、不需要 root。代码在 `flutter_app/lib/core/agent/`。

## 1. 为什么不是 ADB / UI Automator

| | ADB + uiautomator | 本方案 |
|---|---|---|
| 需要电脑 + 数据线 + 调试开关 | 是 | 否（局域网即可） |
| 能读到"当前是第几个平台" | 否（只有像素） | 是（语义状态） |
| 能断言"这行字在屏幕上" | 要 OCR | 直接查控件树 |
| 换平台/翻页这类动作 | 只能模拟坐标 | 可以直接调平台切换 |
| 对 App 内部逻辑的可见性 | 零 | 完整 |

代价：控制端口是 App 自己开的，所以必须带 token，且默认关闭。

## 2. 打开

**入口**：我的 → 设置 → `AI 控制（真机测试）` → 打开「智能助手悬浮球」。

打开后：

- 屏幕上出现一个小球（可拖动），**绿色 = 桥在监听**
- 点球展开面板：地址、端口、token、最近 80 条指令日志
- 面板里的「运行自检」会在本机跑一遍：内部指令 + `127.0.0.1` 真实 HTTP，
  两条都绿才叫通 —— 这是唯一能让用户自己确认链路的东西

默认端口 `9777`，可在面板里改（App 会记住；被占用会自动回滚并说明原因）。

## 3. 从电脑连

```bash
export TH_AGENT_HOST=192.168.31.50     # 手机 IP（面板上显示）
export TH_AGENT_TOKEN=xxxxxxxx        # 面板上复制

python3 tools/th_agent.py health
```

或者一次性记住：`th_agent.py pair http://192.168.31.50:9777 <token>`（写 `~/.th_agent.json`）。

## 4. 指令表

所有指令都是 JSON，`POST /agent/exec`。参数直接摊在顶层。

| op | 参数 | 说明 |
|---|---|---|
| `ping` | – | 探活 |
| `state` | – | `{module, moduleIndex, tabs, routeDepth, fullscreen, loggedIn, backend}` |
| `tree` | `limit` | 屏幕上所有可寻址目标（文字 + 已注册 key + 矩形） |
| `nav` | `module` | 打开模块。别名表见 `main.dart` 的 `agentModuleAlias`（`b站`/`video`/`影视` 都指视频） |
| `tab` | `index` 或 `name` | 切底部导航 |
| `platform` | `index` 或 `name` | 视频页横向切平台（红果 / 哔哩哔哩 / 片库 / 历史 / 发现 / 搜索） |
| `subtab` | `page`,`tab` | 模块内子页签（B 站七栏目等） |
| `tap` | `key` / `text` / `xy:[x,y]` | 真实 PointerDown/Up，走命中测试 |
| `swipe` | `dir` + `dist` + `ms` | 真实手势滑动，`dir` = left/right/up/down |
| `input` | `text` | 往当前焦点输入框写入 |
| `back` | – | 返回一层 |
| `shot` | `pr` | 截图，返回 `png_b64` |
| `wait` | `ms` | 等待 |
| `assert` | `text`/`key`/`module` + `timeout` | 断言，失败返回 `ok:false` |
| `eval` | `name` + 自定义参数 | 调前端注册的具名动作 |
| `script` | `steps:[…]` | 批量执行，默认失败即停（`continueOnError` 可改） |

失败一定带 `error` + `hint`。**`ok:false` 不算通过** —— 这是本项目的铁律，
闸门只认 `ok:true`，不做"没报错就算过"。

### 例子

```bash
# 打开视频 → 切 B 站 → 断言当前模块
th_agent.py nav 视频
th_agent.py platform bilibili
th_agent.py do '{"op":"assert","module":"视频"}'

# 按屏幕文字点
th_agent.py tap --text 搜索

# 左右滑
th_agent.py swipe left

# 截图看看到底长什么样
th_agent.py shot -o /tmp/a.png
```

## 5. 跑用例

```bash
python3 tools/th_agent.py run tools/scenarios/video_switch.json --shots /tmp/shots
```

每步截图落到 `--shots` 目录，失败时直接能看当时的画面 —— 比读日志快得多。

用例就是 JSON 数组：`{"name": "...", "steps": [...]}`，额外支持 `note` 字段
（会被打印成人话，写给人看的）。

## 6. 坐标与单位

- `xy` 支持三种写法：`[0.5, 0.8]`（归一化）、`[540, 1536]`（逻辑像素）、`"0.5,0.8"`
- 归一化判定：两个分量都 ≤ 1 视为比例。所以想点左上角 1 像素处，请写像素值。

## 7. 已知边界

- **App 在后台时代码不跑帧**，指令会阻塞到回前台。这是 Android 的限制，不是桥的问题。
- 指令是**串行**的（内部队列）。并发手势会互相抢 Pointer，导致"点了没反应"。
- `findByText` 只认**当前屏幕内**的元素；列表项要先 `swipe` 出来。
- 截图经 `RepaintBoundary`，**某些 SurfaceView（原生视频层）会是黑块** —— 这是平台渲染限制，改用 `state` 读播放器状态更可靠。
- token 存在 `SharedPreferences`（`agent_token`），长期有效；换 token 需清数据。

## 8. 自测（不依赖真机）

```bash
cd flutter_app
flutter test test/agent_bus_test.dart
```

覆盖：协议解析、参数收敛、op 白名单、结果序列化、**真实手势点中控件**、
**滑动驱动 PageView 翻页**。最后两条是"不碰屏幕也能操控"的地基证据。
