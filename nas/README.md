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
└──────────────────────────────────────────────┘
      │
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
| **8098** | bilidown | B 站下载（**内网 only，无登录**，别做公网映射） |
| 8097 | Jellyfin | 飞牛自带影视库 |
| 8384 | Syncthing | 文件同步 |
| 13378 | Audiobookshelf | 有声书 |

## 三、换机复刻（四步）

```bash
# 1) 把本目录拷到新 NAS（或 git clone 仓库后进 nas/）
cd nas

# 2) 改一下 IP / 路径（不填 IP 会自动探测默认路由的出口地址）
export TH_LAN_HOST=192.168.31.156        # 新 NAS 的局域网 IP（有线口）
export TH_ROOT=/vol1/docker              # 编排文件放哪
export TH_DATA=/vol1/1000/Media/_配置     # 数据/配置放哪（建议外接盘）

# 可选：填了之后后端会把自己上报到云端，App 换 NAS 也能自动找到
export SUPABASE2_URL=https://xxxx.supabase.co
export SUPABASE2_SERVICE_ROLE_KEY=eyJ...

# 3) 一键恢复
sudo -E bash restore.sh

# 4) 验证
curl -k https://$TH_LAN_HOST:9527/v1/meta      # 应返回 version
curl -k "https://$TH_LAN_HOST:9527/thp/meta"   # 版本必须是 1.99.0（补丁生效）
curl -k "https://$TH_LAN_HOST:9527/v1/bili/status"  # base 指向新 IP
```

`restore.sh` 会做：建目录 → 铺 compose → **铺补丁层** → 初始化数据（源清单/服务广场/B站地址）
→ 起容器 → 打印端口表 → 自检（THP 版本、B 站桥接、搜索试跑）。
**重复执行安全**（已存在的东西不覆盖）。

### 迁移后必须核对的 4 处（这次换机踩过的）

| 位置 | 症状 | 现在由谁兜住 |
|---|---|---|
| `compose` 里的 `TH_LAN_URL` | 后端上报的地址是旧的 | restore.sh 自动改写 |
| `data/services.json` 的 `baseUrl` | 封面/播放/搜索全空（后端在连一个不存在的地址） | restore.sh 自动改写 |
| `data/bili.json` | B 站下载「地址不可达」 | restore.sh 直接重写 |
| `bilidown` 端口绑定 | 容器 `Exited(255)` 起不来（绑到了不存在的 IP） | compose 里改成 `8098:8098`（不绑 IP） |

## 四、数据从哪来（关键）

| 文件 | 作用 | 缺失时 |
|---|---|---|
| `data/sources.json` | 书源全量（2091 条，含 254 个标「已探活」） | 用 `server/book-sources.json` 兜底（254 条，能直接搜） |
| `data/comic-sources.json` | 漫画源 | 漫画搜不到 |
| `data/music-sources.json` | 音源 | 音乐搜不到 |
| `data/drpy-sources.json` | 影视源（drpy） | 影视搜不到 |
| `data/secret` | 后端主密钥 | **首次启动自动生成**，别手工造 |
| `data/cert.pem` / `key.pem` | 自签证书 | 首次启动自动生成 |

> `server/book-sources.json` 是「实测能搜出结果」的 254 个源，去掉 `exploreUrl` 后只有 0.4MB。
> 新机器用它就能立刻搜到书；之后让后端自己跑扫描器补全更多源。

## 五、后端代码怎么上线（★ 补丁层，别再 docker cp）

镜像 `ghcr.io/.../thirdhub-backend:0.8.8` 里是**旧代码**：没有 `/thp/*`、没有 `/v1/bili/*`、
引擎没修过、`services/` 整个不存在。这些改动现在走**补丁层**：

```
/vol1/docker/thirdhub/patch/     ← 宿主机目录（restore.sh 从仓库 server/ 铺过来）
        ├─ index.js  routes-thp.js  routes-bili.js  engine*.js …
        └─ services/{gateway,registry}.js + adapters/
        ↓   compose 挂载成 /patch:ro，启动命令先覆盖再跑
docker  command: sh -c "cp -rf /patch/. /app/ && exec node index.js"
```

改代码的正确流程：

```bash
# ① 改仓库 server/ 下的文件（那是唯一真源），推到 GitHub
# ② NAS 上重新铺补丁 + 重建（补丁是挂载的，重建不会丢）
cd nas && sudo -E bash restore.sh          # 只想更新补丁时：
sudo cp server/index.js /vol1/docker/thirdhub/patch/index.js
cd /vol1/docker/thirdhub && sudo docker compose up -d --force-recreate
# ③ 验证 /thp/meta 版本与搜索试跑
```

> ⚠️ **血泪教训（2026-11-14）**：以前是 `docker cp` 进容器，`/app` 不是挂载卷，
> 换 NAS 时 `docker compose up -d` 一重建，THP、B 站桥、引擎修复、服务广场**全部消失**，
> 表现为 `/thp/meta` 变回 1.0.0、`/v1/bili/*` 变 401。补丁层就是为这件事加的。
> 以后新增改动也要回写 `server/` + 补丁清单（`restore.sh` 里的 `PATCH_FILES`）。

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
8. **端口不要绑具体 IP**（`192.168.31.200:8098:8098` 这种写法）。换 NAS 后宿主机没有这个地址，
   docker 绑不上，容器直接 `Exited(255)`，日志里只有一行 `listening on :8098` 看着像成功。
   统一写 `8098:8098`（0.0.0.0），有线无线两个网卡都能进。
9. **本机有两块网卡时**（有线 `enp5s0` + 无线 `wlp6s0`，两个 IP 都能连），
   一切配置统一用**默认路由出口**那个（`ip route get 1.1.1.1` 的 `src`），别用无线口 —— 
   无线会掉速、休眠断连，后端上报的地址会跟着抖。

## 七、外网访问

两条路，可并存：

- **IPv6 直连**：NAS 有公网 IPv6（电信 `240e:` 段），但**路由器的 IPv6 防火墙默认拦入站**。
  要在光猫/路由里给 NAS 地址放行，否则外网连不上。
- **Tailscale**（不依赖路由器）：`compose/tailscale.yml`，首次 `docker logs tailscale` 取登录链接授权。
  授权后 `docker exec tailscale tailscale ip -4` 拿到 100.x 地址，写进地址清单即可。

地址清单由 `scripts/register_host.sh` 上报到 Supabase，App 探活时逐个试。
