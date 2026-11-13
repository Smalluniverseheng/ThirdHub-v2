#!/bin/sh
# DSH 服务端启动脚本（node:24-alpine，host 网络模式）
#
# 为什么用 host 网络：
#   NAS 上 Docker 的 bridge 网络**访问不了 github.com**（DNS 正常，但 https 握手超时；
#   实测 dsh / alist / navidrome 三个容器都一样，而宿主机 curl github 返回 200）。
#   插件安装必须走 git clone github，所以让 DSH 直接用宿主机网络。
#
# 为什么依赖装在这里而不是手动装：
#   容器一旦重建，容器内装的 git/pnpm/ssh 全丢。全部固化到启动脚本，重建即自愈。
set -u

DSH_VER="${DSH_VERSION:-0.2.2-rc.1}"
export DSH_HOME="${DSH_HOME:-/root/.dsh}"
mkdir -p "$DSH_HOME"

# ── 1. 系统依赖（git/ssh 是插件安装必需；curl 供排障）──
if ! command -v git >/dev/null 2>&1; then
  echo "[dsh] 安装系统依赖 git / openssh-client / curl …"
  apk add --no-cache git openssh-client curl tzdata 2>&1 | tail -3
fi

# ── 2. pnpm（dsh 的插件管理器用它）──
npm config set registry https://registry.npmmirror.com >/dev/null 2>&1
if ! command -v pnpm >/dev/null 2>&1; then
  echo "[dsh] 安装 pnpm …"
  npm i -g pnpm@9 2>&1 | tail -3
fi

# ── 3. git 强制走 https（容器没有 git 的 ssh key，走 ssh 必然失败）──
cat > /root/.gitconfig <<'EOF'
[url "https://github.com/"]
	insteadOf = git+ssh://git@github.com/
	insteadOf = git@github.com:
	insteadOf = ssh://git@github.com/
[user]
	name = ThirdHub NAS
	email = nas@thirdhub.local
EOF

# ── 4. 安装 dsh 本体（用版本文件判断，避免每次重启都重装）──
INSTALLED=""
[ -f /srv/.dsh-version ] && INSTALLED="$(cat /srv/.dsh-version 2>/dev/null)"
NEED_INSTALL=1
if [ "$INSTALLED" = "$DSH_VER" ] && command -v dsh >/dev/null 2>&1; then
  NEED_INSTALL=0
fi

if [ "$NEED_INSTALL" = "1" ]; then
  echo "[dsh] 安装 @deepseek-ai/dsh@${DSH_VER} …"
  npm i -g "@deepseek-ai/dsh@${DSH_VER}" 2>&1 | tail -5
  if command -v dsh >/dev/null 2>&1; then
    echo "$DSH_VER" > /srv/.dsh-version
  else
    echo "[dsh] 安装失败，容器保持存活以便排查"
    exec sleep infinity
  fi
fi

# ── 5. profile 的 pnpm 配置（否则插件装不上）──
PROFILE="$DSH_HOME/profiles/web"
if [ -d "$PROFILE" ]; then
  printf 'ignore-workspace-root-check=true\nregistry=https://registry.npmmirror.com\n' > "$PROFILE/.npmrc"
  if ! grep -q onlyBuiltDependencies "$PROFILE/pnpm-workspace.yaml" 2>/dev/null; then
    cat >> "$PROFILE/pnpm-workspace.yaml" <<'EOF'

# git-hosted 插件安装时跑 prepare 构建脚本，pnpm 默认拦着
onlyBuiltDependencies:
  - dsh-jmcomic
  - dsh-ytdlp
  - dsh-bili-summary
  - dsh-jmcomic-plugin
allowBuilds:
  - dsh-jmcomic
  - dsh-ytdlp
  - dsh-bili-summary
  - dsh-jmcomic-plugin
EOF
  fi
fi

# ── 5.4 本地插件依赖自愈 ──
# 插件放在 local-plugins（挂载卷，持久），它 import 的 @deepseek-ai/dsh-tools
# 在宿主安装目录里。不补这个软链，插件 import 就失败，cordis 会静默跳过（不报错）。
PLUG_DIR="$DSH_HOME/local-plugins"
if [ -d "$PLUG_DIR/dsh-ytdlp" ]; then
  for p in "$PLUG_DIR"/*/; do
    [ -d "$p" ] || continue
    if [ ! -e "$p/node_modules/@deepseek-ai/dsh-tools" ]; then
      mkdir -p "$p/node_modules/@deepseek-ai"
      ln -sfn /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tools \
        "$p/node_modules/@deepseek-ai/dsh-tools"
    fi
  done
fi

# ── 5.5 凭据文件权限必须是 600（dsh 强校验；挂载卷写入默认 755，重启就失效）──
chmod 700 "$DSH_HOME" 2>/dev/null
[ -f "$DSH_HOME/.credentials.yaml" ] && chmod 600 "$DSH_HOME/.credentials.yaml"

echo "[dsh] 版本: $(dsh -V 2>/dev/null)"

# ── 6. host 网络下监听宿主机 LAN IP（--host 不接受 0.0.0.0）──
HOSTIP="${DSH_HOST_IP:-}"
if [ -z "$HOSTIP" ]; then
  HOSTIP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
fi
[ -z "$HOSTIP" ] && HOSTIP="$(hostname -i 2>/dev/null | awk '{print $1}')"
[ -z "$HOSTIP" ] && HOSTIP="127.0.0.1"

PORT="${DSH_PORT:-3800}"
echo "[dsh] 监听 ${HOSTIP}:${PORT}（host 网络）"

if [ -n "${DSH_PUBLIC_URL:-}" ]; then
  exec dsh web --host "$HOSTIP" --port "$PORT" --no-open --public-url "$DSH_PUBLIC_URL"
else
  exec dsh web --host "$HOSTIP" --port "$PORT" --no-open
fi
