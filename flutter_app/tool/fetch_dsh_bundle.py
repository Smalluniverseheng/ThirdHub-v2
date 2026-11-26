"""把云端 DSH 完全体运行包（5 片，约 178MB）拉到 assets/dsh/rootfs.tar.gz。

用途：
  · CI（build-apk.yml）：在 gradle 打包前调用，让 178MB rootfs 真正**内置进 APK**，
    用户装完即用，不再等首启下载。
  · 本地：`python3 tool/fetch_dsh_bundle.py`，模拟 CI 产物做体积/功能验证。

为什么运行时不入库：Git API 对 >100MB 二进制不友好，且每次 rootfs 重建都要改包；
放云端分片 + CI 现场拉取，既能进 APK，又不污染仓库。

校验：逐片 sha256 + 合并后整包 sha256，全部对齐 latest-dsh.json 才落盘。
"""
from __future__ import annotations

import hashlib
import json
import sys
import urllib.request
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
DEST_DIR = APP / "assets" / "dsh"
DEST = DEST_DIR / "rootfs.tar.gz"
MANIFEST = (
    "https://onhmosehcwyrqgxadjvb.supabase.co/storage/v1/object/public/"
    "downloads/thirdhub/dsh/latest-dsh.json"
)

CHUNK = 1024 * 1024


def sha_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h.hexdigest()


def download(url: str, dest: Path, want_sha: str = "", want_size: int = 0) -> None:
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "ThirdHub-dsh-bundler/1"})
    with urllib.request.urlopen(req, timeout=600) as r, tmp.open("wb") as f:
        while True:
            b = r.read(CHUNK)
            if not b:
                break
            f.write(b)
    if want_size and tmp.stat().st_size != want_size:
        tmp.unlink(missing_ok=True)
        raise SystemExit(f"分片大小不符：{url} 期望 {want_size} 实际 {tmp.stat().st_size}")
    if want_sha and sha_file(tmp).lower() != want_sha.strip().lower():
        tmp.unlink(missing_ok=True)
        raise SystemExit(f"分片 sha256 不符：{url}")
    tmp.replace(dest)


def main() -> int:
    print(f"[dsh-bundle] manifest: {MANIFEST}")
    with urllib.request.urlopen(
        urllib.request.Request(MANIFEST, headers={"User-Agent": "ThirdHub-dsh-bundler/1"}),
        timeout=60,
    ) as r:
        j = json.load(r)
    if not isinstance(j, dict):
        raise SystemExit("清单格式不对")
    version = str(j.get("version", ""))
    want_sha = str(j.get("sha256", "")).strip().lower()
    want_size = int(j.get("size", 0) or 0)
    parts = j.get("parts")
    if not isinstance(parts, list) or not parts:
        raise SystemExit("清单里没有 parts（无法拉 178MB 大包）")

    DEST_DIR.mkdir(parents=True, exist_ok=True)
    if (
        DEST.exists()
        and DEST.stat().st_size == want_size
        and (not want_sha or sha_file(DEST) == want_sha)
    ):
        print(f"[dsh-bundle] 已就位：{DEST} ({DEST.stat().st_size} B, v{version})")
        return 0

    segs: list[Path] = []
    try:
        for i, p in enumerate(parts):
            if not isinstance(p, dict):
                raise SystemExit(f"第 {i+1} 段格式不对")
            url = str(p.get("url", ""))
            if not url:
                raise SystemExit(f"第 {i+1} 段没有地址")
            seg = DEST_DIR / f".seg{i}"
            print(f"[dsh-bundle] 下载 {i+1}/{len(parts)} …", flush=True)
            download(
                url,
                seg,
                str(p.get("sha256", "")),
                int(p.get("size", 0) or 0),
            )
            segs.append(seg)

        print("[dsh-bundle] 合并分片 …", flush=True)
        part_tmp = DEST.with_suffix(".gz.part")
        with part_tmp.open("wb") as out:
            for s in segs:
                with s.open("rb") as f:
                    for b in iter(lambda: f.read(CHUNK), b""):
                        out.write(b)
        if want_size and part_tmp.stat().st_size != want_size:
            raise SystemExit(
                f"整包大小不符：期望 {want_size} 实际 {part_tmp.stat().st_size}"
            )
        got = sha_file(part_tmp)
        if want_sha and got != want_sha:
            raise SystemExit(f"整包 sha256 不符：期望 {want_sha} 实际 {got}")
        part_tmp.replace(DEST)
    finally:
        for s in segs:
            s.unlink(missing_ok=True)

    print(f"[dsh-bundle] ✅ {DEST} {DEST.stat().st_size} B v{version} sha={got[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
