#!/usr/bin/env bash
# ============================================================
#  ThirdHub v4 后端 · 一键启动（Linux / macOS）
#  - 自动检查 node / 缺依赖自动装 / 起 :9527
#  - npm 源优先 npmmirror（官方源在国内常常超时）
#  用法：  ./start.sh          （前台）
#          nohup ./start.sh &  （后台，日志见 server.log）
# ============================================================
cd "$(dirname "$0")" || exit 1

NPM_REG="${TH_NPM_REG:-https://registry.npmmirror.com}"

# ── 1. Node 检查 ──
if ! command -v node >/dev/null 2>&1; then
  echo "[X] 未找到 node。请先安装 Node 20+："
  echo "    Debian/Ubuntu:  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash - && sudo apt-get install -y nodejs"
  echo "    macOS:          brew install node"
  exit 1
fi
echo "[*] Node $(node -v)"

# ── 2. P2P 内核 ──
if [ -x "vendor/aria2/aria2c" ]; then
  echo "[*] aria2c 已就位 —— BT/DHT/磁力下载可用"
else
  echo "[!] 未发现 vendor/aria2/aria2c —— 种子/磁力下载将被禁用"
  echo "    安装： sudo apt install -y aria2  然后  cp \"\$(command -v aria2c)\" vendor/aria2/"
fi

# ── 3. 依赖 ──
if [ ! -f "node_modules/cheerio/package.json" ]; then
  echo "[*] 首次运行，安装依赖…"
  if ! npm install --no-audit --no-fund --registry="$NPM_REG"; then
    echo "[X] 依赖安装失败。"
    echo "    若报错里出现类似 npm.mirrors.msh.team 的域名，说明 package-lock.json"
    echo "    被锁在一个不可达的内网镜像上。修复："
    echo "        mv package-lock.json package-lock.json.bak && npm install --registry=$NPM_REG"
    exit 2
  fi
fi

# ── 4. 启动 ──
echo "[*] 启动后端 https://0.0.0.0:9527 （首次会自签证书到 server/data/）"
exec node index.js
