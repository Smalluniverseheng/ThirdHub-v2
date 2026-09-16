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
mkdir -p "$OUT/node/xz" "$OUT/server"
cp "$U/bin/xz" "$OUT/node/xz/xz"
cp -L "$U/lib/liblzma.so.5" "$OUT/node/xz/liblzma.so.5"
rm -f "$U"/bin/xz "$U"/lib/liblzma.so*
( cd "$U" && tar cf - bin lib | xz -9 -T0 > "$OUT/node/node.tar.xz" )
cp -r "$ROOT/server"/* "$OUT/server/"
rm -rf "$OUT/server/scripts" "$OUT/server/public" "$OUT/server/data" 2>/dev/null || true

echo "== 安装 server 依赖(node_modules 随包) =="
# 依赖已 vendored: server/vendor/node_modules.tar.gz(本地 npm install 后打包, 纯JS无原生模块)
# CI 网络对 npm registry 不稳定, 不再在 CI 里跑 npm install
tar xzf "$OUT/server/vendor/node_modules.tar.gz" -C "$OUT/server"
[ -d "$OUT/server/node_modules/cheerio" ] || { echo "cheerio 缺失"; exit 1; }
du -sh "$OUT/node/"* | sed 's/^/  /'
echo "== 完成 =="
