#!/usr/bin/env python3
"""CI 步骤：把 Termux proot 的 4 个原生库取到 jniLibs（本机 DSH 的启动器）。

为什么不自己写启动器：
  在 Android 上跑「x86_64 编译的 Linux 用户态」（也就是 DSH 的 Ubuntu rootfs）
  唯一成熟的路子就是 PRoot —— Termux 用了十年的同一套二进制。它的价值全在
  这些补丁里：--link2symlink / --kill-on-exit / --sysvipc，缺一个就会出现
  "node 起不来 / 退出后 node 变孤儿 / pnpm 装包失败"。

为什么要改名：
  APK 只把 `lib*.so` 从 jniLibs 解压到 nativeLibraryDir；带版本号的
  `libtalloc.so.2` 不会被解压，proot 就 DT_NEEDED 找不到。所以
  DT_NEEDED / DT_SONAME 里的 `libtalloc.so.2` 等长缩成 `libtalloc.so`。
  （同一招在 4.81.99 的 Termux node 上已经用过。）

产物只有 ~330KB，全部落 jniLibs，随 APK 走，不进 Git 历史。

运行位置：flutter_app 目录（脚本自定位）。
"""
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
OUT = APP / "android/app/src/main/jniLibs/arm64-v8a"
WORK = HERE / ".dsh-proot-build"
BASE = "https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main/pool/main"

PROOT_VERSION = "5.1.107.102"
TALLOC_VERSION = "2.5.0"
SHMEM_VERSION = "0.7"

# (deb 相对路径, deb 内相对路径, jniLibs 文件名, 期望 sha256？这里只校验大小下限)
SRC = [
    (f"p/proot/proot_{PROOT_VERSION}_aarch64.deb",
     f"data/data/com.termux/files/usr/bin/proot", "libproot.so"),
    (f"p/proot/proot_{PROOT_VERSION}_aarch64.deb",
     f"data/data/com.termux/files/usr/libexec/proot/loader", "libproot-loader.so"),
    (f"libt/libtalloc/libtalloc_{TALLOC_VERSION}_aarch64.deb",
     f"data/data/com.termux/files/usr/lib/libtalloc.so.{TALLOC_VERSION}", "libtalloc.so"),
    (f"liba/libandroid-shmem/libandroid-shmem_{SHMEM_VERSION}_aarch64.deb",
     f"data/data/com.termux/files/usr/lib/libandroid-shmem.so", "libandroid-shmem.so"),
]


def download(url: str, dst: Path):
    if dst.exists() and dst.stat().st_size > 0:
        return
    print(f"  download {url.rsplit('/', 1)[-1]}", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "thirdhub-ci/1"})
    with urllib.request.urlopen(req, timeout=300) as r, dst.open("wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)


def main():
    sys.path.insert(0, str(HERE))
    from patch_termux_elf import Elf  # noqa: E402

    WORK.mkdir(parents=True, exist_ok=True)
    extract = WORK / "x"
    debs: dict[str, Path] = {}

    for rel, _inner, _out in SRC:
        name = rel.rsplit("/", 1)[-1]
        if name in debs:
            continue
        dst = WORK / name
        for attempt in range(3):
            try:
                download(f"{BASE}/{rel}", dst)
                break
            except Exception as e:  # noqa: BLE001
                if attempt == 2:
                    raise
                print(f"    retry {attempt + 1}: {e}", flush=True)
                dst.unlink(missing_ok=True)
        debs[name] = dst
        subprocess.run(["dpkg-deb", "-x", str(dst), str(extract)], check=True)

    OUT.mkdir(parents=True, exist_ok=True)
    for rel, inner, out_name in SRC:
        hits = list(extract.rglob(inner))
        if not hits:
            raise SystemExit(f"包内没找到 {inner} (from {rel})")
        src = hits[0]
        dst = OUT / out_name
        if out_name == "libproot-loader.so":
            # 静态可执行，没有 PT_DYNAMIC，不需要改 dynstr
            dst.write_bytes(src.read_bytes())
        else:
            elf = Elf(src)
            changes = elf.patch()
            elf.save(dst)
            print(f"  {out_name}: {'; '.join(changes) or '无改动'}", flush=True)
        dst.chmod(0o755)
        if dst.stat().st_size < 4096:
            raise SystemExit(f"{out_name} 体积异常: {dst.stat().st_size}B")
        print(f"  runtime {out_name} <- {src.stat().st_size}B", flush=True)

    got = sorted(p.name for p in OUT.glob("*.so"))
    print(f"OK: jniLibs 共 {len(got)} 个: {', '.join(got)}", flush=True)


if __name__ == "__main__":
    main()
