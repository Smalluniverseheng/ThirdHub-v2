#!/usr/bin/env bash
# ThirdHub NAS 一键恢复脚本
#   用法： sudo -E bash restore.sh
#   可选环境变量：
#     TH_LAN_HOST  新 NAS 的局域网 IP（不填则自动探测默认路由的出口 IP）
#     TH_ROOT      编排文件根目录（默认 /vol1/docker）
#     TH_DATA      数据/配置根目录（默认 /vol1/1000/Media/_配置）
#     TH_SKIP_APPS 设为 1 则只起后端，不起那 9 个应用
#     TH_SKIP_BILI 设为 1 则不起 B 站下载
#     SUPABASE2_URL / SUPABASE2_SERVICE_ROLE_KEY
#                  填了就把「云端自注册」写进编排，后端会每 5 分钟
#                  上报自己的内网地址 + IPv6 → App 换 NAS 也能自动找到
#
# 设计原则：
#   · 可重复执行 —— 已存在的文件/目录不覆盖
#   · 不碰密钥 —— secret / 证书由后端首次启动自己生成
#   · 失败即停 —— set -euo pipefail，不要"看起来跑完了其实没起"
set -euo pipefail

# ★ 2026-11-14：原来默认写死 192.168.31.200，换 NAS 后忘了改就全线连不上。
#   现在没指定就自己探测（默认路由的源地址 = 有线口的地址）。
if [ -z "${TH_LAN_HOST:-}" ]; then
  TH_LAN_HOST=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
fi
HOST="${TH_LAN_HOST:?无法自动探测局域网 IP，请显式指定 TH_LAN_HOST}"
ROOT="${TH_ROOT:-/vol1/docker}"
DATA="${TH_DATA:-/vol1/1000/Media/_配置}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OLD_IPS="192.168.31.200 192.168.31.156 192.168.31.170"

say() { printf '\n\033[1;36m[restore]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[restore] 失败：\033[0m %s\n' "$*" >&2; exit 1; }

say "目标：host=$HOST root=$ROOT data=$DATA"

# ── 0. 前置检查 ──
command -v docker >/dev/null 2>&1 || die "没有 docker 命令。飞牛：应用中心安装 Docker 后再跑。"
docker compose version >/dev/null 2>&1 || die "docker compose 不可用（需要 v2 插件）。"

# ── 1. 目录 ──
say "建目录"
mkdir -p "$ROOT/thirdhub/data" "$ROOT/thirdhub/patch" "$ROOT/apps" "$ROOT/tailscale" "$ROOT/dsh" "$ROOT/bilidown"
mkdir -p "$DATA"/{sun-panel,stirling-pdf,stirling-pdf/configs,stirling-pdf/logs,syncthing,vaultwarden,memos,audiobookshelf,audiobookshelf/config,audiobookshelf/metadata,moviepilot,dsh,tailscale}
mkdir -p "$DATA/../_同步" "$DATA/../_下载/完成/video" "$DATA/../播客" 2>/dev/null || true

# ── 2. 编排 ──
say "铺 compose 文件"
cp -n "$HERE/compose/thirdhub.yml"   "$ROOT/thirdhub/docker-compose.yml" || true
cp -n "$HERE/compose/apps.yml"       "$ROOT/apps/docker-compose.yml"     || true
cp -n "$HERE/compose/tailscale.yml"  "$ROOT/tailscale/docker-compose.yml" || true
cp -n "$HERE/compose/dsh.yml"        "$ROOT/dsh/docker-compose.yml"      || true
cp -n "$HERE/compose/bilidown.yml"   "$ROOT/bilidown/docker-compose.yml" || true

# 把 compose 里的旧 IP 换成新 IP（只改地址，不动别的）
say "改写编排里的局域网地址 → $HOST"
for f in "$ROOT/thirdhub/docker-compose.yml" "$ROOT/dsh/docker-compose.yml" "$ROOT/bilidown/docker-compose.yml"; do
  [ -f "$f" ] || continue
  for ip in $OLD_IPS; do
    [ "$ip" = "$HOST" ] && continue
    sed -i "s#$ip#$HOST#g" "$f" || true
  done
done

# ── 2.5 补丁层（★ 换 NAS / 重建容器都不会丢的关键） ──
#   为什么必须有这一层：镜像 0.8.8 里是旧代码 —— 没有 THP 协议（/thp/*）、
#   没有 B 站桥（/v1/bili/*）、引擎也是没修过的版本、服务广场的 services/ 整个不存在。
#   这些东西以前是 docker cp 进容器的，**容器一重建就全没了**（2026-11-14 踩过）。
#   现在把它们铺成 patch/ 目录，编排里 mount 到 /patch，启动时覆盖 /app 再跑。
say "铺设补丁层 → $ROOT/thirdhub/patch"
SRV="$HERE/../server"
mkdir -p "$ROOT/thirdhub/patch/services/adapters"
PATCH_FILES="
index.js
routes-thp.js
routes-bili.js
routes-media.js
routes-search.js
routes-library.js
engine.js
engine-lx.js
engine-comic.js
engine-plugin.js
engine-drpy.js
engine-cms.js
source_scanner.js
self_register.js
invite_codes.js
"
miss=0
for f in $PATCH_FILES; do
  if [ -f "$SRV/$f" ]; then
    cp -f "$SRV/$f" "$ROOT/thirdhub/patch/$f"
  else
    echo "  ⚠ 缺 $SRV/$f（新 NAS 上该功能可能不可用）"
    miss=$((miss+1))
  fi
done
for f in services/gateway.js services/registry.js \
         services/adapters/jellyfin.js services/adapters/navidrome.js services/adapters/qbittorrent.js; do
  if [ -f "$SRV/$f" ]; then
    cp -f "$SRV/$f" "$ROOT/thirdhub/patch/$f"
  else
    echo "  ⚠ 缺 $SRV/$f（服务广场该适配器不可用）"
    miss=$((miss+1))
  fi
done
chmod -R a+r "$ROOT/thirdhub/patch" 2>/dev/null || true
echo "  补丁文件 $(find "$ROOT/thirdhub/patch" -type f | wc -l) 个，缺失 $miss 个"

# 校准编排：老版本 compose 没有 patch 挂载 → 补上（否则补丁不生效）
TC="$ROOT/thirdhub/docker-compose.yml"
if [ -f "$TC" ] && ! grep -q '/patch:ro' "$TC"; then
  say "编排缺少补丁挂载，自动补上"
  sed -i "s#      - ./data:/app/data#      - ./data:/app/data\n      - ./patch:/patch:ro#" "$TC"
  sed -i "s#^    environment:#    command: [\"sh\", \"-c\", \"cp -rf /patch/. /app/ \&\& exec node index.js\"]\n\n    environment:#" "$TC"
fi

# 云端自注册（可选）：把 SUPABASE2_* 写进编排，App 才能自动发现新地址
if [ -n "${SUPABASE2_URL:-}" ] && [ -n "${SUPABASE2_SERVICE_ROLE_KEY:-}" ]; then
  if ! grep -q 'SUPABASE2_URL' "$TC"; then
    say "写入云端自注册凭据"
    sed -i "s#      - TH_OWNER_EMAIL=#      - SUPABASE2_URL=$SUPABASE2_URL\n      - SUPABASE2_SERVICE_ROLE_KEY=$SUPABASE2_SERVICE_ROLE_KEY\n      - TH_OWNER_EMAIL=#" "$TC"
  fi
else
  echo "  ℹ 未提供 SUPABASE2_URL / SUPABASE2_SERVICE_ROLE_KEY —— App 只能靠手动输地址连接"
fi

# ── 3. 数据 ──
say "初始化数据（不覆盖已有）"
if [ ! -f "$ROOT/thirdhub/data/sources.json" ]; then
  if [ -f "$HERE/../server/book-sources.json" ]; then
    cp "$HERE/../server/book-sources.json" "$ROOT/thirdhub/data/sources.json"
    echo "  书源：用 254 个实测可用源打底"
  else
    echo '[]' > "$ROOT/thirdhub/data/sources.json"
    echo "  ⚠ 没有 server/book-sources.json，书源为空 —— 起来后到管理台导入"
  fi
fi
for f in comic-sources music-sources drpy-sources; do
  if [ ! -f "$ROOT/thirdhub/data/$f.json" ] && [ -f "$HERE/../server/$f.json" ]; then
    cp "$HERE/../server/$f.json" "$ROOT/thirdhub/data/$f.json"
    echo "  $f 已铺"
  fi
done
# memos 的 UID 是 10001，权限给足（踩过：000 权限导致 database file 打不开）
chmod -R 775 "$DATA/memos" 2>/dev/null || true

# ── 3.5 服务广场清单 + B 站下载地址 ──
#   这两个文件里写的是「后端直连的地址」，换 IP 后不校准，
#   表现就是封面/播放/搜索全空（后端在拿一个不存在的地址发请求）。
SU="$ROOT/thirdhub/data/services.json"
if [ ! -f "$SU" ] && [ -f "$HERE/data/services.json.tpl" ]; then
  say "铺服务广场清单（9 个服务）"
  sed "s#__LAN__#$HOST#g" "$HERE/data/services.json.tpl" > "$SU"
  echo "  凭证留空，需要取内容时在「服务广场」填一次密码"
elif [ -f "$SU" ]; then
  for ip in $OLD_IPS; do
    [ "$ip" = "$HOST" ] && continue
    sed -i "s#$ip#$HOST#g" "$SU" || true
  done
  echo "  服务广场清单已按新 IP 校准"
fi
echo "{\"url\":\"http://$HOST:8098\"}" > "$ROOT/thirdhub/data/bili.json"
echo "  B 站下载地址 → http://$HOST:8098"

# ── 4. 起服务 ──
say "启动后端"
( cd "$ROOT/thirdhub" && docker compose up -d )

if [ "${TH_SKIP_APPS:-0}" != "1" ]; then
  say "启动应用组（9 个）"
  ( cd "$ROOT/apps" && docker compose up -d ) || echo "  ⚠ 应用组部分失败，看 docker logs"
fi

if [ "${TH_SKIP_BILI:-0}" != "1" ]; then
  say "启动 B 站下载"
  if docker image inspect bilidown-nas:2.1.1-nas.4 >/dev/null 2>&1; then
    ( cd "$ROOT/bilidown" && docker compose up -d ) || echo "  ⚠ bilidown 起不来，看 docker logs bilidown"
  else
    echo "  ⚠ 没有 bilidown-nas 镜像。它只在 GitHub Release 里有 tar.gz："
    echo "    curl -L -o /tmp/bd.tar.gz <release asset>  &&  docker load -i /tmp/bd.tar.gz"
    echo "    然后重跑： sudo -E TH_SKIP_APPS=1 bash restore.sh"
  fi
fi

# ── 5. 等待后端就绪 ──
say "等待后端（最多 90 秒）"
ok=0
for i in $(seq 1 30); do
  if curl -sk --max-time 3 "https://127.0.0.1:9527/v1/meta" >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done
[ "$ok" = "1" ] || die "后端 90 秒内没起来：docker logs thirdhub-backend"

# ── 6. 自检 ──
say "自检"
V=$(curl -sk --max-time 5 "https://127.0.0.1:9527/v1/meta" | head -c 200)
echo "  /v1/meta  : $V"
# THP 打的是补丁层里的 routes-thp（版本 1.99.0）。若这里出现 1.0.0，
# 说明补丁没生效 —— 检查 /patch 挂载与 command 覆盖。
T=$(curl -sk --max-time 5 "https://127.0.0.1:9527/thp/meta" | head -c 200)
echo "  /thp/meta : $T"
case "$T" in
  *1.99.0*) echo "  ✓ THP 补丁已生效" ;;
  *) echo "  ✗ THP 补丁未生效（/thp/meta 版本不是 1.99.0，检查 patch 挂载）" ;;
esac
B=$(curl -sk --max-time 5 "https://127.0.0.1:9527/v1/bili/status" | head -c 200)
echo "   B站桥接  : $B"
Q=$(curl -sk --max-time 60 "https://127.0.0.1:9527/thp/search?type=novel&q=%E6%96%97%E7%BD%97&limit=3" | head -c 160)
echo "  搜索试跑  : $Q"

cat <<EOF

──────── 完成 ────────
局域网地址   https://$HOST:9527
App 侧要填   $HOST:9527（或在「我的后端」里扫码/输地址）
数据目录     $ROOT/thirdhub/data
应用组       $ROOT/apps（端口表见 README.md）
外网访问     cd $ROOT/tailscale && docker compose up -d && docker logs tailscale
EOF
