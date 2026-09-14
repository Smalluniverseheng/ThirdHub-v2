# ThirdHub v4 家庭后端（零原生依赖，Node 22 即跑）
FROM node:22-alpine

WORKDIR /app
COPY package.json ./
# 无第三方依赖，跳过 npm install（保持镜像最小）
COPY index.js engine.js engine-drpy.js engine-comic.js engine-music.js ./
COPY vendor ./vendor
COPY public ./public
COPY scripts ./scripts
COPY sources-preset ./sources-preset

ENV TH_PORT=9527 \
    TH_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 9527

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:9527/v1/meta || exit 1

CMD ["node", "index.js"]
