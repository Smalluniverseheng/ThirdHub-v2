#!/usr/bin/env bash
# ThirdHub NAS 一键恢复脚本
#   用法： sudo -E bash restore.sh
#   可选环境变量：
#     TH_LAN_HOST  新 NAS 的局域网 IP（默认沿用 192.168.31.200）
#     TH_ROOT      编排文件根目录（默认 /vol1/docker）
#     TH_DATA      数据/配置根目录（默认 /vol1/1000/Media/_配置）
#     TH_SKIP_APPS 设为 1 则只起后端，不起那 9 个应用
#     TH_SKIP_BILI 设为 1 则跳过 B 站下载服务（不想下 B 站视频时可以省 220MB 镜像）
#
# 设计原则：
#   · 可重复执行 —— 已存在的文件/目录不覆盖
#   · 不碰密钥 —— secret / 证书由后端首次启动自己生成
#   · 失败即停 —— set -euo pipefail，不要"看起来跑完了其实没起"
set -euo pipefail

HOST="${TH_LAN_HOST:-192.168.31.200}"
ROOT="${TH_ROOT:-/vol1/docker}"
DATA="${TH_DATA:-/vol1/1000/Media/_配置}"
HERE="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\n\033[1;36m[restore]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[restore] 失败：\033[0m %s\n' "$*" >&2; exit 1; }

say "目标：host=$HOST root=$ROOT data=$DATA"

# ── 0. 前置检查 ──
command -v docker >/dev/null 2>&1 || die "没有 docker 命令。飞牛：应用中心安装 Docker 后再跑。"
docker compose version >/dev/null 2>&1 || die "docker compose 不可用（需要 v2 插件）。"

# ── 1. 目录 ──
say "建目录"
mkdir -p "$ROOT/thirdhub/data" "$ROOT/apps" "$ROOT/tailscale" "$ROOT/dsh" "$ROOT/bilidown"
mkdir -p "$DATA"/{sun-panel,stirling-pdf,stirling-pdf/configs,stirling-pdf/logs,syncthing,vaultwarden,memos,audiobookshelf,audiobookshelf/config,audiobookshelf/metadata,moviepilot,dsh,tailscale,bilidown,bilidown/data}
mkdir -p "$DATA/../_同步" "$DATA/../_下载/完成/video" "$DATA/../_下载/B站" "$DATA/../播客" 2>/dev/null || true

# ── 2. 编排 ──
say "铺 compose 文件"
cp -n "$HERE/compose/thirdhub.yml"   "$ROOT/thirdhub/docker-compose.yml" || true
cp -n "$HERE/compose/apps.yml"       "$ROOT/apps/docker-compose.yml"     || true
cp -n "$HERE/compose/tailscale.yml"  "$ROOT/tailscale/docker-compose.yml" || true
cp -n "$HERE/compose/dsh.yml"        "$ROOT/dsh/docker-compose.yml"      || true
cp -n "$HERE/compose/bilidown.yml"   "$ROOT/bilidown/docker-compose.yml" || true

# 把 compose 里的旧 IP 换成新 IP（只改 TH_LAN_URL / 注释里的地址，不动别的）
if [ "$HOST" != "192.168.31.200" ]; then
  say "改写 compose 里的局域网地址 → $HOST"
  for f in "$ROOT/thirdhub/docker-compose.yml" "$ROOT/bilidown/docker-compose.yml"; do
    [ -f "$f" ] && sed -i "s#192\.168\.31\.200#$HOST#g" "$f" || true
  done
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
# BiliDown 用 1000:1000 跑，目录是 NAS 上新建的，默认会是 000 权限
chmod -R 775 "$DATA/bilidown" "$DATA/../_下载/B站" 2>/dev/null || true

# 告诉主后端「B 站下载服务在哪」。换 NAS 时只改这一处。
if [ ! -f "$ROOT/thirdhub/data/bili.json" ]; then
  printf '{"url":"http://%s:8098"}\n' "$HOST" > "$ROOT/thirdhub/data/bili.json"
  echo "  bili.json 已写：http://$HOST:8098"
fi

# ── 4. 起服务 ──
say "启动后端"
( cd "$ROOT/thirdhub" && docker compose up -d )

if [ "${TH_SKIP_APPS:-0}" != "1" ]; then
  say "启动应用组（9 个）"
  ( cd "$ROOT/apps" && docker compose up -d ) || echo "  ⚠ 应用组部分失败，看 docker logs"
fi

# ── 4.5 B 站下载（BiliDown）──
# 镜像不在 Docker Hub，只能从 Release 下 tar.gz 再 load；已 load 过就跳过。
if [ "${TH_SKIP_BILI:-0}" != "1" ]; then
  if ! docker image inspect bilidown-nas:2.1.1-nas.4 >/dev/null 2>&1; then
    say "拉取 BiliDown 镜像（约 220MB，首次较慢）"
    TAR="$ROOT/bilidown/bilidown-nas.tar.gz"
    if [ ! -s "$TAR" ]; then
      curl -sL --max-time 900 -o "$TAR" \
        "https://github.com/fredqin2006-X/bilidown-nas/releases/download/v2.1.1-nas.4/bilidown-nas-2.1.1-nas.4.tar.gz" \
        || die "镜像下载失败，可手动下载后放到 $TAR 再重跑"
    fi
    docker load -i "$TAR" || die "docker load 失败（文件损坏？重新下载）"
  fi
  say "启动 B 站下载"
  ( cd "$ROOT/bilidown" && docker compose up -d --no-build ) || echo "  ⚠ BiliDown 启动失败，看 docker logs bilidown"
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
T=$(curl -sk --max-time 5 "https://127.0.0.1:9527/thp/meta" | head -c 200)
echo "  /thp/meta : $T"
Q=$(curl -sk --max-time 60 "https://127.0.0.1:9527/thp/search?type=novel&q=%E6%96%97%E7%BD%97&limit=3" | head -c 160)
echo "  搜索试跑  : $Q"
BI=$(curl -sk --max-time 15 -H "x-th-token: $(cat "$ROOT/thirdhub/data/secret" 2>/dev/null)" "https://127.0.0.1:9527/v1/bili/status" | head -c 160)
echo "  B 站下载  : $BI"

cat <<EOF

──────── 完成 ────────
局域网地址   https://$HOST:9527
App 侧要填   $HOST:9527（或在「我的后端」里扫码/输地址）
数据目录     $ROOT/thirdhub/data
应用组       $ROOT/apps（端口表见 README.md）
B 站下载     网页 http://$HOST:8098 ／ App 里「我的后端 → B 站下载」
             首次要在 App 里扫码登录 B 站（网页端扫也行，登录态共用）
             文件落在 $DATA/../_下载/B站
外网访问     cd $ROOT/tailscale && docker compose up -d && docker logs tailscale
EOF
