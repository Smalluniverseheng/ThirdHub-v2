#!/usr/bin/env python3
"""构建「本机 DSH 运行包」= Ubuntu base + 官方 Node + DSH 的 rootfs.tar.gz。

为什么要 rootfs 而不是往 APK 塞 node：
  Node 官方没有 android-arm64 产物。以前拿 Termux 的 bionic 包改 ELF 硬搬，
  真机成功率靠运气，且一个原生 addon 都用不了。正解是把 x86_64/arm64 的
  **Linux** 用户态整个搬进 app 私有目录，由 PRoot 提供 chroot + ptrace 翻译：
  Ubuntu 24.04 base + node-linux-arm64 + npm 装好的 DSH，原生扩展原样可用。

跨架构却不用跑外来代码：
  npm 的 --cpu/--os/--libc 让主机上的 npm 直接解析出目标平台的依赖树
  （含 sharp / koffi / node-pty 的 linux-arm64 二进制），--ignore-scripts
  保证不执行任何 postinstall，所以整条链在 x86_64 CI 上就能产出 arm64 包。

裁剪（体积从 1.1GB 压到 ~800MB，压完 ~175MB）：
  · libreoffice-kit-wasm（146MB，桌面 Office 预览，手机上没意义）
  · dsh-experimental-inspector（26MB，桌面调试面板）
  · sharp-wasm32（9MB，wasm 兜底，真机上走到它说明架构选错了）
  · **/*.map、**/*.d.ts（开发元数据）
  · node 的 include/ 与 share/（头文件与文档）

用法：
  python3 tool/build_dsh_rootfs.py --abi arm64-v8a --out build-out/dsh
  python3 tool/build_dsh_rootfs.py --abi x86_64 --out /tmp/dsh-x64   # 主机自测
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent

DSH_VERSION = "0.2.2-rc.1"
# 运行包自身的修订号：内容有任何变化（换平台包、加组件、改启动脚本）就 +1。
# 客户端就是靠清单里的 version 判断"要不要提示重新下载"的，忘了加会导致
# 新包传上去了、老用户永远拿不到。
ROOTFS_REV = 2
NODE_VERSION = "24.22.1"
UBUNTU_VERSION = "24.04.5"

UBUNTU_MIRROR = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release"
NODE_MIRROR = "https://npmmirror.com/mirrors/node"
NPM_REGISTRY = "https://registry.npmmirror.com"

ABI_MAP = {
    "arm64-v8a": ("arm64", "arm64"),
    "x86_64": ("amd64", "x64"),
}

# 相对 node_modules 的裁剪路径（不存在则忽略）
PRUNE = [
    "@deepseek-ai/libreoffice-kit-wasm",
    "@deepseek-ai/dsh-experimental-inspector",
    "@img/sharp-wasm32",
]
PRUNE_GLOBS = ["*.map", "*.d.ts", "*.d.mts", "*.d.cts"]

# ═══ 平台相关的二进制包（★ 这是 4.81.107 补的一个真坑）═══
# npm 的 `--cpu=arm64` 只影响 "os/cpu 字段过滤"，**不改变平台包的选择** ——
# 平台包名里直接写着 -x64 / -arm64，npm 按构建机的 process.arch 决定装哪一份。
# 于是在 x86_64 机器上装出来的树里，arm64 运行包躺的是 x64 的 .node。
# 后果很隐蔽：DSH 主流程照样能启动、能出 token（所以自检和冒烟都绿），
# 但真机上 sharp 转图、koffi 调 FFI、landlock 沙箱全部加载失败 —— 所谓
# "完全体"缺了最关键的几块。这里按目标架构重新拉同版本包并替换。
PLATFORM_PKGS = [
    "@deepseek-ai/node-addon-system-linux-{cpu}",
    "@img/sharp-linux-{cpu}",
    "@img/sharp-libvips-linux-{cpu}",
    "@koromix/koffi-linux-{cpu}",
    "node-addon-require-builtin-linux-{cpu}-gnu",
]


def log(msg):
    print(f"[rootfs] {msg}", flush=True)


def fetch(url: str, dst: Path):
    if dst.exists() and dst.stat().st_size > 0:
        return dst
    dst.parent.mkdir(parents=True, exist_ok=True)
    log(f"下载 {url.rsplit('/', 1)[-1]}")
    req = urllib.request.Request(url, headers={"User-Agent": "thirdhub-build/1"})
    tmp = dst.with_suffix(dst.suffix + ".part")
    with urllib.request.urlopen(req, timeout=600) as r, tmp.open("wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    tmp.replace(dst)
    return dst


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _extract(tf: tarfile.TarFile, dest: Path):
    """解压 ubuntu-base。

    filter 必须用 "tar" 而不是 "data"：base 镜像里 `etc/alternatives/awk` 之类
    是指向 `/usr/bin/mawk` 的**绝对**符号链接 —— 在 chroot 语境下完全正常，
    "data" 过滤器会把它们当越界直接抛 AbsoluteLinkError。
    "tar" 仍然会拒绝 `..` 逃逸与改写越界路径，够安全。
    """
    try:
        tf.extractall(dest, filter="tar")  # type: ignore[call-arg]
    except TypeError:  # 老 python 没有 filter 参数
        tf.extractall(dest)  # noqa: S202


def swap_platform_pkgs(nm: Path, target_cpu: str, work: Path):
    """把平台二进制包换成目标架构的同版本包，删掉构建机那一份。

    为什么不能靠 npm 的 --cpu 解决：包名里写死了架构（@img/sharp-linux-arm64），
    npm 用构建机的 process.arch 选包，--cpu 只过滤 os/cpu 字段。
    """
    host_cpu = "x64" if target_cpu == "arm64" else "arm64"
    if host_cpu == target_cpu:
        return
    tmp = work / "platform-pkgs"
    tmp.mkdir(parents=True, exist_ok=True)
    for pat in PLATFORM_PKGS:
        host_rel = pat.format(cpu=host_cpu)
        want_rel = pat.format(cpu=target_cpu)
        host_manifest = nm / host_rel / "package.json"
        if not host_manifest.exists():
            continue
        ver = json.loads(host_manifest.read_text())["version"]
        spec = f"{want_rel}@{ver}"
        log(f"  平台包 {host_rel} -> {want_rel}@{ver}")
        # npm pack 不做平台校验（npm install 会 EBADPLATFORM），正好用来取包
        out = subprocess.run(
            ["npm", "pack", spec, f"--registry={NPM_REGISTRY}", f"--pack-destination={tmp}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip().splitlines()[-1].strip()
        tgz = tmp / out
        if not tgz.exists():
            raise SystemExit(f"npm pack 没产出 {spec}: {out}")
        staging = tmp / "x"
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir()
        with tarfile.open(tgz, "r:gz") as tf:
            tf.extractall(staging)  # noqa: S202 —— 来自固定 registry 的字节
        dest = nm / want_rel
        if dest.exists():
            shutil.rmtree(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staging / "package", dest, symlinks=True)
        # 构建机那一份留着只会白占几十 MB，而且在真机上是错误架构
        shutil.rmtree(nm / host_rel, ignore_errors=True)
        shutil.rmtree(staging, ignore_errors=True)
        tgz.unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--abi", default="arm64-v8a", choices=sorted(ABI_MAP))
    ap.add_argument("--out", default=str(APP / "build-out" / "dsh"))
    ap.add_argument("--work", default=str(Path(tempfile.gettempdir()) / "thirdhub-dsh-rootfs"))
    ap.add_argument("--keep-rootfs", action="store_true", help="保留解开的 rootfs 目录（调试用）")
    ap.add_argument("--no-compress", action="store_true", help="只产出目录母版，不出 tar.gz")
    args = ap.parse_args()

    ubuntu_arch, npm_cpu = ABI_MAP[args.abi]
    work = Path(args.work)
    out = Path(args.out)
    cache = work / "cache"
    rootfs = work / "rootfs"
    out.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)

    # ① Ubuntu base
    base_name = f"ubuntu-base-{UBUNTU_VERSION}-base-{ubuntu_arch}.tar.gz"
    base = fetch(f"{UBUNTU_MIRROR}/{base_name}", cache / base_name)
    log(f"ubuntu-base {base.stat().st_size // 1048576}MB")

    # ② 官方 node（目标架构）
    node_name = f"node-v{NODE_VERSION}-linux-{npm_cpu}.tar.xz"
    node_pkg = fetch(f"{NODE_MIRROR}/v{NODE_VERSION}/{node_name}", cache / node_name)
    log(f"node {node_pkg.stat().st_size // 1048576}MB")

    # ③ DSH npm 树（跨平台解析，不执行任何脚本）
    npx = work / "npx"
    if not (npx / "node_modules" / "@deepseek-ai" / "dsh" / "package.json").exists():
        npx.mkdir(parents=True, exist_ok=True)
        empty_user = work / "empty-user-npmrc"
        empty_user.write_text("")
        log(f"npm install @deepseek-ai/dsh@{DSH_VERSION} (cpu={npm_cpu}, os=linux, libc=glibc)")
        subprocess.run(
            [
                "npm", "install", "--prefix", str(npx),
                f"--cpu={npm_cpu}", "--os=linux", "--libc=glibc",
                f"--registry={NPM_REGISTRY}", f"--userconfig={empty_user}",
                "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=warn",
                "--save-exact", f"@deepseek-ai/dsh@{DSH_VERSION}",
            ],
            check=True,
        )
    got = json.loads((npx / "node_modules/@deepseek-ai/dsh/package.json").read_text())["version"]
    if got != DSH_VERSION:
        raise SystemExit(f"装到的 dsh 版本 {got} != {DSH_VERSION}")

    # ④ 组装 rootfs
    rootfs.mkdir(parents=True, exist_ok=True)
    log("解开 ubuntu-base")
    with tarfile.open(base, "r:gz") as tf:
        _extract(tf, rootfs)
    log("解开 node（顺带滤掉头文件与文档，不落地就不用删）")
    node_dst = rootfs / "opt/node"
    node_dst.mkdir(parents=True, exist_ok=True)
    skipped = ("include/", "share/", "CHANGELOG.md", "README.md", "LICENSE")
    with tarfile.open(node_pkg, "r:xz") as tf:
        members = []
        for m in tf.getmembers():
            parts = m.name.split("/", 1)
            if len(parts) < 2 or not parts[1]:
                continue
            rel = parts[1]
            if rel.startswith(skipped):
                continue
            m.name = rel
            members.append(m)
        tf.extractall(node_dst, members=members)  # noqa: S202 —— 固定镜像站输入

    log("拷贝 DSH（拷贝时直接跳过要裁的目录与开发元数据）")
    dsh_dst = rootfs / "opt/dsh"
    dsh_dst.mkdir(parents=True, exist_ok=True)
    src_nm = npx / "node_modules"
    prune_set = set(PRUNE)

    def _ignore(dirpath, names):
        rel = Path(dirpath).relative_to(src_nm).as_posix()
        rel = "" if rel == "." else rel + "/"
        out = []
        for n in names:
            if (rel + n) in prune_set:
                out.append(n)
            elif n.endswith((".map", ".d.ts", ".d.mts", ".d.cts")):
                out.append(n)
        return out

    shutil.copytree(src_nm, dsh_dst / "node_modules", symlinks=True, ignore=_ignore)
    for f in ("package.json", "package-lock.json"):
        if (npx / f).exists():
            shutil.copy2(npx / f, dsh_dst / f)

    # ④.5 把平台二进制包换成目标架构（否则真机上 sharp/koffi/landlock 全废）
    log(f"替换平台二进制包 -> {npm_cpu}")
    swap_platform_pkgs(dsh_dst / "node_modules", npm_cpu, work)

    # ⑤ 运行期需要的目录与入口
    dsh_bin = rootfs / "usr/local/bin/dsh"
    dsh_bin.parent.mkdir(parents=True, exist_ok=True)
    dsh_bin.write_text(
        "#!/bin/sh\nexec /opt/node/bin/node "
        "/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js \"$@\"\n"
    )
    dsh_bin.chmod(0o755)
    for link, target in (("node", "/opt/node/bin/node"), ("npm", "/opt/node/bin/npm"),
                         ("npx", "/opt/node/bin/npx")):
        p = rootfs / "usr/local/bin" / link
        if p.exists() or p.is_symlink():
            p.unlink()
        p.symlink_to(target)
    for d in ("dev", "proc", "sys", "tmp", "root/.dsh", "root/.l2s",
              "var/lib/dsh-app/empty", "var/lib/dsh-app/shm"):
        (rootfs / d).mkdir(parents=True, exist_ok=True)
    (rootfs / "tmp").chmod(0o1777)
    # Android 没有 resolv.conf；启动时还会再写一次，这里先给一份能用的
    (rootfs / "etc/resolv.conf").write_text(
        "nameserver 223.5.5.5\nnameserver 119.29.29.29\noptions timeout:2 attempts:2\n"
    )
    # DSH 拒绝启动于「凭据文件别人也能读」
    cred = rootfs / "root/.dsh/.credentials.yaml"
    if not cred.exists():
        cred.write_text("version: 1\nrefs: {}\n")
    cred.chmod(0o600)

    total = sum(p.stat().st_size for p in rootfs.rglob("*") if p.is_file())
    files = sum(1 for p in rootfs.rglob("*") if p.is_file())
    log(f"rootfs: {total // 1048576}MB / {files} 个文件")

    if args.no_compress:
        log(f"目录母版 -> {rootfs}")
        return

    # ⑥ 打包（gzip：手机上 dart:io 的原生 zlib 能流式解，比 xz 快一个数量级）
    tgz = out / f"dsh-rootfs-{args.abi}.tar.gz"
    log(f"打包 {tgz.name}")
    with tarfile.open(tgz, "w:gz", compresslevel=6) as tf:
        for p in sorted(rootfs.iterdir()):
            tf.add(p, arcname=p.name, recursive=True)

    digest = sha256(tgz)
    manifest = {
        "version": f"{DSH_VERSION}+node{NODE_VERSION}+ubuntu{UBUNTU_VERSION}+r{ROOTFS_REV}",
        "rev": ROOTFS_REV,
        "abi": args.abi,
        "dshVersion": DSH_VERSION,
        "nodeVersion": NODE_VERSION,
        "ubuntuVersion": UBUNTU_VERSION,
        "size": tgz.stat().st_size,
        "unpackedBytes": total,
        "files": files,
        "sha256": digest,
    }
    (out / f"manifest-{args.abi}.json").write_text(json.dumps(manifest, indent=2))
    log(f"完成 {tgz}  {tgz.stat().st_size / 1048576:.1f}MB  sha256={digest[:16]}…")

    if not args.keep_rootfs:
        shutil.rmtree(rootfs, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
