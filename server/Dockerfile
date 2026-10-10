# ThirdHub v4 家庭后端 —— Linux / NAS(Docker) 版
# ============================================================
#   ★ 2026-10-10 修：原 Dockerfile 有三处致命错误，镜像根本起不来：
#      ① 写「无第三方依赖，跳过 npm install」——但 index.js L83 顶层
#         `require('bonjour-service')`，且 preflight 里 cheerio/bonjour-service
#         是**硬必需**，缺则 process.exit(2)。⇒ 镜像必崩。
#      ② COPY 只列了 5 个 js 文件 —— 实际 index.js 还 require
#         ./channels ./thp1 ./peer-hub ./preset-sync ./request-log
#         ./routes*.js ./engine-tvbox ./engine-lx ⇒ 缺模块必崩。
#      ③ HEALTHCHECK 用 `wget http://...` —— 但服务是 **HTTPS-only**
#         (https.createServer) ⇒ 健康检查永远失败，容器被判 unhealthy。
#  本版全部修正，并补 docker-compose.yml。
# ============================================================
FROM node:22-alpine

# 【关键】两个运行依赖：cheerio(解析源返回的 HTML) + bonjour-service(mDNS 发现)
# 不用 --production=false：本服务没有 devDependencies，装全部即可
WORKDIR /app

# ── 依赖层（单独一层，改代码不触发重装）──
# 有 lock 用 c i （可复现）；没有则退回 install
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then \
      npm ci --omit=dev --no-audit --no-fund --registry=https://registry.npmmirror.com; \
    else \
      npm install --omit=dev --no-audit --no-fund --registry=https://registry.npmmirror.com; \
    fi \
 && npm cache clean --force

# ── 代码层：整目录 COPY（本地模块太多，逐个列必漏）──
# .dockerignore 已排除 node_modules / data / *.log
COPY . .

# 运行时数据（证书 / 密钥 / 下载 / 会话…）全部落这里，挂卷持久化
ENV TH_PORT=9527 \
    TH_DATA_DIR=/data \
    NODE_ENV=production \
    NO_PROXY=localhost,127.0.0.1,::1

VOLUME ["/data"]
EXPOSE 9527

# ★ HTTPS-only：健康检查必须走 https + -k（自签证书）
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- --no-check-certificate https://127.0.0.1:9527/v1/meta >/dev/null 2>&1 || exit 1

CMD ["node", "index.js"]
