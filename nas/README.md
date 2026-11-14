# NAS 部署套件（ThirdHub 自托管侧）

> 目标：**换一台 NAS 也能照这个目录一步步重建出一样的服务**。
> 本目录是「NAS 上实际在跑的东西」的镜像，不是设计稿 —— 改线上就要回写这里。

## 一、这套东西是什么

```
手机 App / 网页端
      │
      │  /v1/*      → 第三方聚合后端（账号、同步、网关、媒体代理）
      │  /thp/*     → 同一台后端冒充「资料库」，给各模块做搜索/阅读
      ▼
┌──────────────────────────────────────────────┐
│ thirdhub-backend  容器   :9527 (HTTPS 自签)   │
│   · 2091 个书源 / 254 个实测可用              │
│   · Jellyfin(8097) / Navidrome 代理           │
│   · /v1/search/all 五路聚合                    │
│   · /v1/bili/* 代理 B 站下载（转 8098）        │
└──────────────────────────────────────────────┘
      │
      ├── bilidown 容器（B 站视频下载，:8098）
      ├── apps 容器组（9 个实用服务，见下表）
      ├── dsh 容器（AI Agent，:3800）
      └── tailscale 容器（外网通道，可选）
```

## 二、端口表

| 端口 | 服务 | 说明 |
|---|---|---|
| **9527** | thirdhub-backend | **核心**，HTTPS 自签证书（`CN=ThirdHub`） |
| 3800 | DSH Agent | token 每次重启变，看 `docker logs dsh` 最后一行 |
| 3000 | MoviePilot | 影视订阅，`API_TOKEN=thirdhub_nas_token_2026` |
| 3002 | Sun-Panel | 导航首页 |
| 5230 | Memos | 笔记 |
| 8082 | IT-Tools | 编码/JSON/哈希工具 |
| 8083 | Stirling-PDF | PDF 处理 |
| 8084 | MeTube | B站/YouTube 下载 |
| 8085 | qBittorrent | 飞牛自带 |
| 8086 | Vaultwarden | 密码管理器 |
| **8098** | **BiliDown** | **B 站视频下载**（网页须内网；App 走 `/v1/bili/*`） |
| 8097 | Jellyfin | 飞牛自带影视库 |
| 8384 | Syncthing | 文件同步 |
| 13378 | Audiobookshelf | 有声书 |

## 三、换机复刻（四步）

```bash
# 1) 把本目录拷到新 NAS（或 git clone 仓库后进 nas/）
cd nas

# 2) 改一下 IP / 路径（只需改这一处）
export TH_LAN_HOST=192.168.31.200        # 新 NAS 的局域网 IP
export TH_ROOT=/vol1/docker              # 编排文件放哪
export TH_DATA=/vol1/1000/Media/_配置     # 数据/配置放哪（建议外接盘）

# 3) 一键恢复
sudo -E bash restore.sh

# 4) 验证
curl -k https://$TH_LAN_HOST:9527/v1/meta      # 应返回 version
curl -k "https://$TH_LAN_HOST:9527/thp/meta"   # 应返回 caps 含 m:novel
```

`restore.sh` 会做：建目录 → 铺 compose → 初始化数据（源清单/证书/密钥）→ 起容器 → 打印端口表。
**重复执行安全**（已存在的东西不覆盖）。

## 四、数据从哪来（关键）

| 文件 | 作用 | 缺失时 |
|---|---|---|
| `data/sources.json` | 书源全量（2091 条，含 254 个标「已探活」） | 用 `server/book-sources.json` 兜底（254 条，能直接搜） |
| `data/comic-sources.json` | 漫画源 | 漫画搜不到 |
| `data/music-sources.json` | 音源 | 音乐搜不到 |
| `data/drpy-sources.json` | 影视源（drpy） | 影视搜不到 |
| `data/secret` | 后端主密钥 | **首次启动自动生成**，别手工造 |
| `data/bili.json` | B 站下载服务地址（`{"url":"http://<NAS IP>:8098"}`） | App 里「B 站下载」报连不上；`restore.sh` 会按 `TH_LAN_HOST` 自动写 |
| `data/cert.pem` / `key.pem` | 自签证书 | 首次启动自动生成 |

> `server/book-sources.json` 是「实测能搜出结果」的 254 个源，去掉 `exploreUrl` 后只有 0.4MB。
> 新机器用它就能立刻搜到书；之后让后端自己跑扫描器补全更多源。

## 五、编译/更新后端代码

`server/` 里是**线上容器内实际运行的源码**（不是旧快照）。改完这样上线：

```bash
# 在 NAS 上（容器不是挂载目录，必须 docker cp）
sudo docker cp index.js        thirdhub-backend:/app/index.js
sudo docker cp routes-thp.js   thirdhub-backend:/app/routes-thp.js
sudo docker cp engine.js       thirdhub-backend:/app/engine.js
sudo docker exec thirdhub-backend node --check /app/index.js
sudo docker restart thirdhub-backend
```

> ⚠️ `/app` **不是挂载卷**，是打进镜像的。`docker compose up -d --force-recreate`
> 或换机重拉镜像会把 `docker cp` 的改动冲掉 —— 所以每次改完必须**回写本目录**。

## 六、已知坑（都在真实环境踩过）

1. **容器是 bridge 网络 → THP 的 UDP 广播 / mDNS 出不了容器**，手机发现不了这台后端。
   所以 App 侧改成「读 prefs 里的后端地址直接连」，不依赖广播（4.81.64 起）。
   想让广播也生效：给 backend 加 `network_mode: host`（compose 里注释已备好）。
2. **证书是自签的**（`CN=ThirdHub`）。curl 要 `-k`；App 侧已在 4.81.60 放行私网自签证书。
3. **memos 挂载目录权限**：容器内跑 UID 10001，目录必须是 `775` 且属主对得上，
   否则报 `unable to open database file (14)`。
4. **stirling-pdf 启动要 60~90 秒**（Spring Boot），刚起就 `curl` 会得到 000，别误判失败。
5. **DSH 的 `.credentials.yaml` 必须 600**，挂载卷写入默认 755 → 已固化进 `scripts/dsh-start.sh`。
6. **DSH 插件依赖要自愈**：插件 import `@deepseek-ai/dsh-tools` 解析不到会被 cordis **静默跳过**
   （不报错、就是没工具）。`scripts/dsh-start.sh` 里有 5.4 段做软链。
7. `data/` 里的 `secret` 泄露等于把后端交出去 —— **本目录不含 secret**，由首次启动生成。

## 七、外网访问

两条路，可并存：

- **IPv6 直连**：NAS 有公网 IPv6（电信 `240e:` 段），但**路由器的 IPv6 防火墙默认拦入站**。
  要在光猫/路由里给 NAS 地址放行，否则外网连不上。
- **Tailscale**（不依赖路由器）：`compose/tailscale.yml`，首次 `docker logs tailscale` 取登录链接授权。
  授权后 `docker exec tailscale tailscale ip -4` 拿到 100.x 地址，写进地址清单即可。

地址清单由 `scripts/register_host.sh` 上报到 Supabase，App 探活时逐个试。

## 八、B 站下载（bilidown，★2026-11-14）

### 它是什么

上游 [`fredqin2006-X/bilidown-nas`](https://github.com/fredqin2006-X/bilidown-nas)
（基于 `iuroc/bilidown`，MIT + NOTICE），把 B 站视频连同音轨下载合并成 mp4，跑在 NAS 上。
扫码登录一次，之后所有人共用这一份登录态和任务列表。

### 三个要知道的点

1. **镜像不在 Docker Hub**。`compose/bilidown.yml` 里的 `bilidown-nas:2.1.1-nas.4`
   必须先 `docker load`（`restore.sh` 会自动从 Release 下 220MB 的 tar.gz）。
2. **网页 8098 没有密码**，所有访问者共用一份登录和队列 → 只绑内网，别做公网映射。
3. **App 不直连 8098**，走主后端 `/v1/bili/*`。原因：
   - App 只记一个后端地址，局域网/公网 IPv6/Tailscale 自动适应；
   - 上游 `createTask` 要客户端自己交 audio/video 的**签名直链**，
     选清晰度、挑 codecid（AVC→HEVC→AV1）、补 https、展开 b23 短链这些活放在服务端做一次；
   - B 站封面有 Referer 防盗链，必须由服务端补头再转出去。

### 接口（都在 9527 上）

```
GET  /v1/bili/status            登录态 + 下载目录
GET  /v1/bili/qr                登录二维码（base64 PNG，直接给 App 显示）
GET  /v1/bili/qr/status?key=    轮询扫码结果（login=true 表示已落库）
GET  /v1/bili/parse?url=        只解析：标题/封面/UP主/清晰度列表
POST /v1/bili/add {url,format}  解析 + 选流 + 建任务（一条龙）
GET  /v1/bili/tasks             任务列表（已把内存里的实时进度合并进来）
POST /v1/bili/del {id}          删除任务（连文件一起删）
GET  /v1/bili/play?id=          取文件，Range 原样透传（能拖动进度）
GET  /v1/bili/cover?u=          封面代理（补 Referer）
POST /v1/bili/logout            退出登录
```

### 文件落在哪

`/vol1/1000/Media/_下载/B站/<标题> <base64(id)>.mp4`（音频版是 `.m4a`）。
文件名里的那串编码是任务 ID 的 base64，**删改任务靠它定位**，别手动改名。

### 踩过的坑

- **挂载目录权限是 `d---------`（000）**：`chown` 不够，必须 `chmod -R 775`。
  `restore.sh` 已带这一步，手工部署时别忘。
- **短链**（`b23.tv/xxx`）必须先展开才知道 BV 号，展开失败就报错，
  不会静默失败 —— 表现为「粘了链接没反应」时看返回的 error。
- **番剧（ep/ss）暂时不支持**：单集 BV 号可以，番剧整季要多层解析，没做。
