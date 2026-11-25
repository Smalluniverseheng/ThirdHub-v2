#!/usr/bin/env python3
"""把 Termux aarch64 ELF 改造成 Android APK 可加载的 nativeLibrary。

- DT_NEEDED / DT_SONAME 里的带版本号 .so 名换成合法 jniLibs 名（等长替换，零风险）
- DT_RUNPATH 从 Termux 私有路径改成 $ORIGIN（Android bionic linker 支持）
"""
import struct
import sys
from pathlib import Path

# 改名只在原字符串槽内进行：等长直接覆盖，变短用 \0 填满剩余字节——
# dynstr 里后一个字符串紧跟其后，所以"变短"是安全的，"变长"会踩到邻居，一律拒绝。
RENAME = {
    b"libz.so.1": b"libz_1.so",
    b"libcrypto.so.3": b"libcrypto_3.so",
    b"libssl.so.3": b"libssl_3.so",
    b"libicui18n.so.79": b"libicui18n_79.so",
    b"libicuuc.so.79": b"libicuuc_79.so",
    b"libicudata.so.79": b"libicudata_79.so",
    # termux proot：APK 只收 lib*.so，带版本号的名字 PMS 不会解压出来
    b"libtalloc.so.2": b"libtalloc.so",
    b"libandroid-shmem.so.0": b"libandroid-shmem.so",
}
OLD_RUNPATH = b"/data/data/com.termux/files/usr/lib"
NEW_RUNPATH = b"$ORIGIN"

DT_NEEDED, DT_STRTAB, DT_SONAME, DT_RPATH, DT_RUNPATH = 1, 5, 14, 15, 29


class Elf:
    def __init__(self, path: Path):
        self.path = path
        self.buf = bytearray(path.read_bytes())
        b = self.buf
        if b[:4] != b"\x7fELF" or b[4] != 2 or b[5] != 1:
            raise ValueError(f"not ELF64 LE: {path}")
        self.phoff = struct.unpack_from("<Q", b, 32)[0]
        self.phentsize = struct.unpack_from("<H", b, 54)[0]
        self.phnum = struct.unpack_from("<H", b, 56)[0]
        self.loads = []
        dyn = None
        for i in range(self.phnum):
            o = self.phoff + i * self.phentsize
            t = struct.unpack_from("<I", b, o)[0]
            foff, fva, _fpa, fsz, _msz, _al = struct.unpack_from("<QQQQQQ", b, o + 8)
            if t == 1:
                self.loads.append((fva, fva + fsz, foff))
            elif t == 2:
                dyn = (foff, fsz)
        if dyn is None:
            raise ValueError(f"no PT_DYNAMIC: {path}")
        self.dynoff, self.dynsize = dyn
        self.strva = None
        self.refs = []
        for i in range(0, self.dynsize, 16):
            tag, val = struct.unpack_from("<QQ", b, self.dynoff + i)
            if tag == 0:
                break
            if tag == DT_STRTAB:
                self.strva = val
            if tag in (DT_NEEDED, DT_SONAME, DT_RPATH, DT_RUNPATH):
                self.refs.append((tag, val))
        if self.strva is None:
            raise ValueError(f"no DT_STRTAB: {path}")
        self.stroff = self._va2off(self.strva)
        if self.stroff is None:
            raise ValueError(f"DT_STRTAB unmapped: {path}")

    def _va2off(self, va: int):
        for a, z, fo in self.loads:
            if a <= va < z:
                return fo + (va - a)
        return None

    def _cstr(self, idx: int) -> bytes:
        b = self.buf
        s = self.stroff + idx
        e = b.index(0, s)
        return bytes(b[s:e])

    def patch(self) -> list[str]:
        changes = []
        done = set()
        for tag, idx in self.refs:
            if idx in done:
                continue
            done.add(idx)
            old = self._cstr(idx)
            s = self.stroff + idx
            e = s + len(old) + 1  # 含 \0
            if tag in (DT_RPATH, DT_RUNPATH) and old.startswith(OLD_RUNPATH):
                self.buf[s:e] = NEW_RUNPATH + b"\0" * (len(old) - len(NEW_RUNPATH) + 1)
                changes.append(f"RUNPATH {old.decode()} -> $ORIGIN")
            elif old in RENAME:
                new = RENAME[old]
                assert len(new) <= len(old), (old, new)
                # 等长直接覆盖；变短则补 \0：dynstr 是连续字符串池，缩短不越界
                self.buf[s:e - 1] = new + b"\0" * (len(old) - len(new))
                changes.append(f"{old.decode()} -> {new.decode()}")
        return changes

    def dump(self) -> dict:
        out = {"needed": [], "soname": None, "runpath": None}
        for tag, idx in self.refs:
            v = self._cstr(idx).decode("utf-8", "replace")
            if tag == DT_NEEDED:
                out["needed"].append(v)
            elif tag == DT_SONAME:
                out["soname"] = v
            else:
                out["runpath"] = v
        return out

    def save(self, target: Path):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(self.buf)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: patch_termux_elf.py <src> <dst>")
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    elf = Elf(src)
    before = elf.dump()
    changes = elf.patch()
    after = elf.dump()
    elf.save(dst)
    print(f"{src.name} -> {dst.name}")
    print(f"  NEEDED: {', '.join(before['needed'])}")
    if changes:
        print(f"  PATCH: {'; '.join(changes)}")
    print(f"  AFTER: {after['needed']} SONAME={after['soname']} RUNPATH={after['runpath']}")


if __name__ == "__main__":
    main()
