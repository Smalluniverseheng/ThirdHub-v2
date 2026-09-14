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
curl -fsSL https://github.com/Smalluniverseheng/ThirdHub-v2/archive/main.tar.gz | tar xz --strip-components=1
cd server && npm install --production

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
