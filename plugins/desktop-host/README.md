# desktop-host —— 电脑控制台（手机控电脑的电脑侧）

手机（App「端网」）→ 后端 `/agent/peer/invoke` → 本插件 `/peer/exec` → 电脑干活。

## 跑起来

```bash
# 1. 先把家庭后端跑起来（server/，端口 9527）
# 2. 启动本插件
node plugins/desktop-host/plugin.js
# 3. 手机 App →「端网」→ 看到「电脑控制台」→ 接入 → 调用工具
```

环境变量（都有默认值）：`TH_HUB`（后端地址，不填自动扫描局域网）、
`TH_ACCOUNT` / `TH_PASSWORD`（登录后端的账号口令）、`TH_PORT`（本插件监听端口，默认 8802）、
`TH_IPV6` / `TH_TUNNEL`（无后端直连时的自报地址）。

## 提供的工具（9 个）

| 工具 | 作用 |
|---|---|
| `host.sysinfo` | 看 CPU / 内存 / 运行时间 |
| `host.open` | 用系统默认浏览器打开网址（只放行 http/https） |
| `host.clip.get` / `host.clip.set` | 读 / 写电脑剪贴板 |
| `host.notify` | 弹系统通知 |
| `host.lock` | 锁屏 |
| `host.shot` | 截屏（PNG base64，读完即删、不落盘留存） |
| `host.fs.list` | 列目录（限配置的 roots） |
| `host.exec` | 执行**白名单内**的命令 |

## 安全边界（比功能重要）

1. **命令执行只认白名单**：`host.exec` 拒绝一切不在 `allowExec` 里的命令，
   且整条命令出现 shell 元字符（`;&|><\`$`）一律拒 —— 防 `ping x && rm -rf /` 搭便车。
   默认白名单只有只读诊断（ipconfig / ping / systeminfo / ifconfig / uname / uptime / df / free / whoami / date）。
2. **调用方必须先登录后端**（join 换 peerToken），转发时出示本插件签发的 `execToken` ——
   局域网里任何进程不能直接指挥本机。
3. **截屏/剪贴板只回给调用方**，不落盘、不进消息环。
4. **目录浏览限 roots**（缺省限用户主目录），路径穿越（`../`）被拒。

## 自定义白名单

在 `plugins/desktop-host/desktop-host.json`（没有就用默认）：

```json
{ "allowExec": ["ipconfig", "ping", "systeminfo"], "roots": ["C:/Users/你的名字"] }
```

## 自检

```bash
node plugins/desktop-host/selftest.cjs
```

30 项行为断言（runner 注入，不 fork 真进程），含白名单越权、shell 元字符、
路径穿越、截图不落盘等反例。
