# 示例插件：示例下载器

这是给插件作者的**照抄模板**。它演示了一个 ThirdHub 插件该有的每一样东西，
并且被 `plugins/selftest-plugin-e2e.js` 第 10 节**以子进程真跑**——所以它不会腐烂。

完整教程见 [`docs/PLUGIN-SDK.md`](../../docs/PLUGIN-SDK.md)。

## 它做了什么

| 工具 | 作用 |
|---|---|
| `dl.add` | 加一个下载任务（磁力 / 直链 / 种子地址） |
| `dl.list` | 列出全部任务 |
| `dl.cancel` | 取消一个任务 |

另外：响应 `topic=download` 的端间消息 → 自动按消息内容建任务；
首次运行把默认保存目录写进**统一密钥** `dl.saveDir`（会同步到所有端）；
每 2 秒推进一次任务进度并播报出去。

## 跑起来

```bash
# 1. 先把 ThirdHub 后端跑起来（见 server/ 的说明，默认 :9527）
# 2. 起插件
node plugins/example-downloader/plugin.js

# 3. 打开 App →「端网」模块
#    · 应该在「在线」里看到「示例下载器」（若显示"待登录"，说明账号口令不对）
#    · 点 dl.add 调一次，看它接不接活
```

## 配置（全部走环境变量，代码里不落任何密钥）

| 变量 | 默认 | 说明 |
|---|---|---|
| `TH_HUB` | 空（自动扫描局域网） | 后端地址，如 `https://192.168.1.5:9527` |
| `TH_ACCOUNT` | `admin` | 接入账号 |
| `TH_PASSWORD` | `123456` | 账号口令 |
| `TH_PORT` | `8801` | 插件监听端口 |
| `TH_ADVERTISE` | 空（自动取本机 IP） | 对外通告的主机地址（容器/NAT 才需要） |
| `TH_IPV6` | 空 | 可达 IPv6，如 `http://[2001:db8::5]:8801`（无后端直连用） |
| `TH_TUNNEL` | 空 | 内网穿透地址，如 `https://xxx.trycloudflare.com`（无后端直连用） |

## 验证

```bash
node plugins/selftest-plugin-e2e.js    # 其中第 10 节会真起这个插件
```

## 想改成自己的插件

1. 拷一份 `plugins/example-downloader/` 到别处；
2. 把 `th-plugin.js`（SDK，在上一层目录）一起拷过去，或把 SDK 内联进单文件；
3. 改 `CFG.name` 与 `CFG.iid`（**iid 就是身份，定了别再改**）；
4. 改工具名、`caps`、`inputSchema`；
5. 把 `addTask()` 里假装下载的逻辑换成真活儿（比如调 aria2，或干脆
   只用一句话让**后端**去下——后端已经内置了 aria2）。
