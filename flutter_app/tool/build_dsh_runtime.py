#!/usr/bin/env python3
"""CI 步骤：构建 DSH 本机运行所需的 arm64 Node 运行时到 jniLibs。

为什么不在仓库里提交这 95MB：
  GitHub Git Blob API 对大二进制返回 422，且会把仓库历史拖垮。改为 CI 现场
  从 Termux 镜像拉预编译包 + ELF 改造，产物不入库，只进 APK。

为什么是 Termux：
  Node 官方不提供 android-arm64 产物；Termux 的 aarch64 包是 bionic/linker64
  原生编译，可经 ELF 改名后由 Android 从 nativeLibraryDir 直接 exec。

运行位置：flutter_app 目录（脚本自定位）。
"""
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
OUT = APP / "android/app/src/main/jniLibs/arm64-v8a"
WORK = HERE / ".dsh-runtime-build"
BASE = "https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main/pool/main"

# (deb 相对路径, 包内相对路径, 输出文件名)
FILES = [
    ("n/nodejs/nodejs_26.13.1_aarch64.deb", "data/data/com.termux/files/usr/bin/node", "libnode-bin.so"),
    ("c/c-ares/c-ares_1.34.9_aarch64.deb", "usr/lib/libcares.so", "libcares.so"),
    ("libc/libc++/libc++_30_aarch64.deb", "usr/lib/libc++_shared.so", "libc++_shared.so"),
    ("libf/libffi/libffi_3.8.1_aarch64.deb", "usr/lib/libffi.so", "libffi.so"),
    ("libi/libicu/libicu_79.1_aarch64.deb", "usr/lib/libicui18n.so.79.1", "libicui18n_79.so"),
    ("libi/libicu/libicu_79.1_aarch64.deb", "usr/lib/libicuuc.so.79.1", "libicuuc_79.so"),
    ("libi/libicu/libicu_79.1_aarch64.deb", "usr/lib/libicudata.so.79.1", "libicudata_79.so"),
    ("libs/libsqlite/libsqlite_3.54.1-1_aarch64.deb", "usr/lib/libsqlite3.so.3.54.1", "libsqlite3.so"),
    ("o/openssl/openssl_1:3.6.5_aarch64.deb", "usr/lib/libcrypto.so.3", "libcrypto_3.so"),
    ("o/openssl/openssl_1:3.6.5_aarch64.deb", "usr/lib/libssl.so.3", "libssl_3.so"),
    ("z/zlib/zlib_1.4_aarch64.deb", "usr/lib/libz.so.1.4", "libz_1.so"),
]


def download(url: str, dst: Path):
    if dst.exists() and dst.stat().st_size > 0:
        return
    print(f"  download {url.rsplit('/', 1)[-1]}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "thirdhub-ci/1"})
    with urllib.request.urlopen(req, timeout=300) as r, dst.open("wb") as f:
        shutil.copyfileobj(r, f)


def main():
    sys.path.insert(0, str(HERE))
    from patch_termux_elf import Elf  # noqa: E402

    WORK.mkdir(parents=True, exist_ok=True)
    extract = WORK / "x"
    extract.mkdir(exist_ok=True)
    debs: dict[str, Path] = {}

    for rel, _inner, _out in FILES:
        name = rel.rsplit("/", 1)[-1]
        if name in debs:
            continue
        url = f"{BASE}/{rel}"
        dst = WORK / name
        for attempt in range(3):
            try:
                download(url, dst)
                break
            except Exception as e:
                if attempt == 2:
                    raise
                print(f"    retry {attempt + 1}: {e}", flush=True)
                dst.unlink(missing_ok=True)
        debs[name] = dst
        subprocess.run(["dpkg-deb", "-x", str(dst), str(extract)], check=True)

    OUT.mkdir(parents=True, exist_ok=True)
    for rel, inner, out_name in FILES:
        # Termux 包的根是 ./data/data/com.termux/files/，解包后 usr/lib 落在该前缀下
        candidates = list(extract.rglob(inner))
        if not candidates:
            raise SystemExit(f"包内没找到 {inner} (from {rel})")
        src = candidates[0]
        dst = OUT / out_name
        elf = Elf(src)
        elf.patch()
        elf.save(dst)
        print(f"  runtime {out_name} <- {src.stat().st_size}B", flush=True)

    got = sorted(p.name for p in OUT.glob("*.so"))
    want = sorted({out for _, _, out in FILES})
    if got != want:
        raise SystemExit(f"jniLibs 不完整: {got} != {want}")
    print(f"OK: {len(got)} native libs -> {OUT}", flush=True)


if __name__ == "__main__":
    main()
