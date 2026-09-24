#!/usr/bin/env bash
# 组装 Android(bionic) 版 Node 运行时到 android/app/src/main/assets/node/
# 来源: Termux aarch64 官方仓库(清华镜像), 含 node 及全部依赖 .so
# 产物: assets/node/node.tar.xz (运行时, 首启解压) + assets/node/xz/ (解压器)
set -euo pipefail
BASE="https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
WORK=$(mktemp -d)
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
OUT="$ROOT/android/app/src/main/assets"

echo "== 解析最新包版本 =="
curl -sL "$BASE/dists/stable/main/binary-aarch64/Packages" -o "$WORK/Packages"
python3 - "$WORK/Packages" > "$WORK/list" <<'PY'
import sys
want = {'nodejs','openssl','c-ares','sqlite','libicu','libffi','libc++','zlib','xz-utils','liblzma'}
cur = {}
for line in open(sys.argv[1], encoding='utf-8', errors='ignore'):
    line = line.strip()
    if line.startswith('Package: '): cur['p'] = line[9:]
    elif line.startswith('Filename: '): cur['f'] = line[10:]
    elif line == '' and cur:
        if cur.get('p') in want: print(cur['f'])
        cur = {}
PY
cat "$WORK/list"

echo "== 下载并解包 =="
mkdir -p "$WORK/x"
while read -r f; do
  enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$f")
  echo "  $f"
  curl -sL --retry 3 "$BASE/$enc" -o "$WORK/p.deb"
  (cd "$WORK/x" && ar x "$WORK/p.deb" data.tar.xz && tar xf data.tar.xz && rm -f data.tar.xz)
done < "$WORK/list"

U="$WORK/x/data/data/com.termux/files/usr"
echo "== 精简(去 npm/头文件/文档) =="
rm -rf "$U/lib/node_modules" "$U/share" "$U/include" "$U/lib/cmake" "$U/lib/icu" "$U/lib/engines-3" "$U/lib/pkgconfig"
rm -f "$U"/bin/npm "$U"/bin/npx "$U"/bin/corepack "$U"/bin/sqlite3
rm -f "$U"/lib/libicutest* "$U"/lib/libicuio* "$U"/lib/libicutu* "$U"/lib/libiculx*

echo "== 组装 assets =="
# 先清掉上一轮的残留：stale assets 会让「包里有旧文件」这种问题极难发现
[ -n "$ROOT" ] && [ -d "$ROOT/android" ] || { echo "❌ ROOT 解析异常: $ROOT"; exit 1; }
rm -rf "$OUT/node" "$OUT/server"
mkdir -p "$OUT/node/xz" "$OUT/server"
cp "$U/bin/xz" "$OUT/node/xz/xz"
cp -L "$U/lib/liblzma.so.5" "$OUT/node/xz/liblzma.so.5"
rm -f "$U"/bin/xz "$U"/lib/liblzma.so*
( cd "$U" && tar cf - bin lib | xz -9 -T0 > "$OUT/node/node.tar.xz" )
cp -r "$ROOT/server"/* "$OUT/server/"
# 排除清单必须与发布包 _pack_backend.mjs 保持一致：**只排 data/ 与 node_modules.msh-partial**。
# ★ 以前这里把 scripts/ 与 public/ 一起删了 —— 后果是手机上「管理台」打不开（控制台就是
#   public/index.html，server/index.js:334 的 PUB 指向它）且自签证书生成失败
#   （index.js:80 execSync 调 scripts/gencert.js）。public/ 与 scripts/ 必须进包。
rm -rf "$OUT/server/data" "$OUT/server/node_modules.msh-partial" 2>/dev/null || true
[ -f "$OUT/server/public/index.html" ] || { echo "❌ public/index.html 缺失（手机上的管理台会打不开）"; exit 1; }
[ -f "$OUT/server/scripts/gencert.js" ] || { echo "❌ scripts/gencert.js 缺失（自签证书会生成失败）"; exit 1; }
[ -f "$OUT/server/index.js" ] || { echo "❌ index.js 缺失"; exit 1; }
[ -f "$OUT/server/package.json" ] || { echo "❌ package.json 缺失"; exit 1; }

echo "== 安装 server 依赖(node_modules 随包) =="
# 依赖已 vendored: server/vendor/node_modules.tar.gz(本地 npm install 后打包, 纯JS无原生模块)
# CI 网络对 npm registry 不稳定, 不再在 CI 里跑 npm install
tar xzf "$OUT/server/vendor/node_modules.tar.gz" -C "$OUT/server"
[ -d "$OUT/server/node_modules/cheerio" ] || { echo "cheerio 缺失"; exit 1; }
echo "== 版本自检 =="
node -e "const p=require('$OUT/server/package.json'),a=require('$ROOT/server/package.json');if(p.version!==a.version){console.error('❌ 进包版本 '+p.version+' ≠ 源 '+a.version);process.exit(1)}console.log('  进包 server 版本 = '+p.version)"
du -sh "$OUT/node/"* | sed 's/^/  /'
echo "== 完成 =="
