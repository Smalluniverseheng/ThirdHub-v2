#!/bin/bash
# ThirdHub 后端 Linux 一键安装(Debian/Ubuntu; 其他发行版类比)
# curl -sSL https://raw.githubusercontent.com/Smalluniverseheng/ThirdHub-v2/main/deploy/install-linux.sh | bash
set -e
echo "== ThirdHub 后端安装 =="
NODE_VER=20

# 1. Node(无则装)
if ! command -v node &>/dev/null; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VER}.x" | bash -
  apt-get install -y nodejs
fi
echo "Node: $(node -v)"

# 2. 用户与目录
id thirdhub &>/dev/null || useradd -r -m -d /opt/thirdhub thirdhub
mkdir -p /opt/thirdhub
cd /opt/thirdhub
# 注：此步要求仓库可公开访问；若仓库为 private，请改为 rsync/scp 本地源码过来
curl -fsSL https://github.com/Smalluniverseheng/ThirdHub-v2/archive/main.tar.gz | tar xz --strip-components=1
cd server
# ★ 用 npmmirror：官方源在国内常超时；且仓库自带的 package-lock.json 可能把
#   tarball 地址锁在某个不可达的内网镜像上（resolved 字段优先级高于 --registry），
#   所以先删 lock 再装，否则会一直 ENOTFOUND。
rm -f package-lock.json
npm install --omit=dev --registry=https://registry.npmmirror.com

# 2b. P2P 内核（可选但推荐：种子/磁力下载依赖它）
if ! [ -x ./vendor/aria2/aria2c ]; then
  if apt-get install -y aria2 2>/dev/null; then
    mkdir -p ./vendor/aria2 && cp "$(command -v aria2c)" ./vendor/aria2/
    echo "aria2c 已装入 server/vendor/aria2/"
  else
    echo "警告: 未装 aria2，种子/磁力下载将不可用（apt install aria2 后复制到 server/vendor/aria2/）"
  fi
fi

# 3. systemd
cp deploy/thirdhub.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now thirdhub

# 4. 防火墙提示
echo ""
echo "== 安装完成 =="
systemctl status thirdhub --no-pager | head -6
IP=$(hostname -I | awk '{print $1}')
echo "访问: https://${IP}:9527"
echo "密钥: $(cat /opt/thirdhub/server/data/secret 2>/dev/null || echo '首次启动后生成')"
echo "指纹: openssl x509 -in /opt/thirdhub/server/data/cert.pem -noout -fingerprint -sha256"
