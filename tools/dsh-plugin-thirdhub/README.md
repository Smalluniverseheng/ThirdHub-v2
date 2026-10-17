# dsh-plugin-thirdhub

**让手机上的 ThirdHub App 通过同一账号，自动发现并连接本机 DSH。**

装好并重启 DSH 之后，这台电脑会持续出现在手机端的设备列表里（在线状态、局域网地址、
`dsh` 能力全部自报）；App 端**自动配对**——不用扫码、不用手输地址、不用公网/隧道。

## 安装

### 方式一：在 DSH 里直接装（推荐 —— 不用命令行）

在 DSH 的**对话里**发这一句，DSH 会自己完成安装：

> 帮我安装这个 DSH 插件：
> https://github.com/Smalluniverseheng/ThirdHub-v2/tree/main/tools/dsh-plugin-thirdhub

装完按 DSH 提示重启即可。

### 方式二：命令行（有 dsh CLI 时）

```bash
dsh plugin --profile desktop add github:Smalluniverseheng/ThirdHub-v2#main&path:/tools/dsh-plugin-thirdhub
```

> profile 按需替换：桌面端通常是 `desktop`，也可是 `web` / `headless`
> （看你平时用哪个；`~/.dsh/profiles/` 下有几个就是哪几个）。
>
> 本地目录安装：`dsh plugin --profile desktop add ./tools/dsh-plugin-thirdhub`

## 配置（填账号）

**不要改本包的 `cordis.patch.yml`**（升级会覆盖）。在 profile 层按 id 覆盖：

```yaml
# ~/.dsh/profiles/desktop/cordis.patch.yml  —— 追加到文件末尾
- id: thirdhub-bridge
  config:
    account: 你的账号
    password: 你的密码
```

再重启 DSH。之后终端/日志里会出现：

```
[thirdhub-bridge] 已接入中枢 · 设备名「我的电脑」· 在线端=2 · 地址=http://192.168.1.5:3080
```

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `hubUrl` | `http://127.0.0.1:9527` | ThirdHub 中枢（桌面端后端）地址 |
| `account` / `password` | 空 | **与手机 App 登录的同一账号** —— 自动配对的关键 |
| `name` | 主机名 | 手机端显示的名字 |
| `lanUrl` | 自动探测 | 本机对局域网暴露的 DSH 地址 |
| `dshPort` | `3080` | 本机 DSH 端口（仅用于拼默认地址） |
| `intervalMs` | `30000` | 心跳间隔 |

## 手机上怎么用

1. 手机 App 用**同一账号**登录；
2. 打开「设备」页 —— 电脑自动出现在**在线**分组（能力显示 `dsh`）；
3. AI 面板里连上它即可（App 端 `autoConfigureFromPeers` 会自动选中）。

## 卸载

```bash
dsh plugin --profile desktop remove dsh-plugin-thirdhub
```

插件注册的定时器走 `ctx.effect`，卸载即清理，不留残余进程。

## 排查

| 现象 | 检查 |
| --- | --- |
| 日志出现「未配置 account」 | profile patch 里的 account 是否填了 |
| 「join 失败/异常」 | 中枢地址对不对；桌面端后端是否在跑（浏览器开 `hubUrl + /api/v1/health`） |
| 手机端看不到电脑 | 两边**账号是否一致**；插件日志是否显示「已接入中枢」 |
| 地址探测错了 | 配 `lanUrl` 手动指定 |

## 备注

- 插件以**你本机的权限**运行（DSH 插件都如此）——本插件只做三件事：
  读本机网卡取局域网地址、向中枢 POST（join/beat）、把 iid/token 存到
  `$DSH_HOME/thirdhub-bridge/`。不读文件内容、不上传任何数据。
- 与 ThirdHub 桌面端后端（中枢）的关系：中枢只维护「同一账号下的端列表」，
  手机与电脑之间的内容传输是**局域网直连**，不经中枢。
