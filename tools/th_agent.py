#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""th_agent —— 从电脑驱动 ThirdHub App（AI 控制总线客户端）

App 里打开「我的 → AI 控制」（或点智能助手悬浮球 → 开关），
面板会显示 `http://<手机IP>:9777` 和 token。本脚本就用这两个东西
通过局域网直接操控 App：切模块、左右滑、点控件、读界面、截图、跑用例。

不需要 adb、不需要数据线、不需要 root —— 因为控制通道是 App 自己开的。

用法：
    export TH_AGENT_HOST=192.168.31.50
    export TH_AGENT_TOKEN=xxxx        # 面板里复制，或 th_agent.py pair

    th_agent.py health                       # 探活
    th_agent.py state                        # 当前模块/页签/路由深度
    th_agent.py tree                         # 屏幕上能点什么（AI 的"眼睛"）
    th_agent.py shot -o a.png                # 截图
    th_agent.py nav 视频                     # 打开模块（别名：b站/影视/video 都行）
    th_agent.py tab 3                        # 切底部导航第 3 项
    th_agent.py platform bilibili            # 视频页横向切平台
    th_agent.py swipe left                   # 真实手势左滑
    th_agent.py tap --text 红果短剧           # 按屏幕文字点
    th_agent.py tap --key nav/video          # 按注册 key 点
    th_agent.py input 三体                    # 往当前输入框打字
    th_agent.py back
    th_agent.py run tools/scenarios/video_switch.json   # 跑一个用例

退出码：0 全绿；1 有断言失败；2 连不上。
"""
import argparse
import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

DEFAULT_PORT = 9777
CFG = pathlib.Path.home() / ".th_agent.json"


# ── 连接 ────────────────────────────────────────────────────────────────


class Client:
    def __init__(self, host, port=DEFAULT_PORT, token="", timeout=12):
        self.host = host.rstrip("/")
        if self.host.startswith("http://") or self.host.startswith("https://"):
            self.base = self.host
        else:
            self.base = f"http://{self.host}:{port}"
        self.token = token
        self.timeout = timeout

    def _headers(self):
        h = {"content-type": "application/json"}
        if self.token:
            h["x-agent-token"] = self.token
        return h

    def get(self, path, **q):
        url = self.base + path
        if q:
            from urllib.parse import urlencode

            url += "?" + urlencode(q)
        req = urllib.request.Request(url, headers=self._headers())
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.status, r.read(), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers or {})

    def post(self, path, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        req = urllib.request.Request(
            self.base + path, data=data, headers=self._headers(), method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def health(self):
        st, body, _ = self.get("/agent/health")
        try:
            j = json.loads(body)
        except Exception:
            j = {"raw": body[:200].decode("utf-8", "replace")}
        j["_status"] = st
        return j

    def exec(self, cmd):
        if "op" not in cmd:
            raise SystemExit("指令缺少 op")
        st, body = self.post("/agent/exec", cmd)
        try:
            j = json.loads(body)
        except Exception:
            return {"ok": False, "error": f"HTTP {st}: {body[:200]!r}"}
        if st == 401:
            return {
                "ok": False,
                "error": "token 不对",
                "hint": "重新从悬浮球面板复制，或改 TH_AGENT_TOKEN",
            }
        return j


# ── 配置 ────────────────────────────────────────────────────────────────


def load_cfg():
    if CFG.exists():
        try:
            return json.loads(CFG.read_text("utf-8"))
        except Exception:
            return {}
    return {}


def save_cfg(d):
    CFG.write_text(json.dumps(d, indent=2), "utf-8")


def make_client(args):
    cfg = load_cfg()
    host = args.host or os.environ.get("TH_AGENT_HOST") or cfg.get("host")
    if not host:
        sys.exit(
            "缺少地址。\n"
            "  1) App 里打开智能助手悬浮球 → 开启 → 复制连接串\n"
            "  2) export TH_AGENT_HOST=192.168.x.x  TH_AGENT_TOKEN=xxxx\n"
            "  3) 或者 th_agent.py pair http://192.168.x.x:9777 <token>（会记住）"
        )
    token = (
        args.token
        or os.environ.get("TH_AGENT_TOKEN")
        or cfg.get("token")
        or ""
    )
    port = args.port or cfg.get("port") or DEFAULT_PORT
    return Client(host, port=port, token=token)


# ── 输出 ────────────────────────────────────────────────────────────────


def pj(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def nonzero(r):
    if r.get("ok"):
        return 0
    print(f"✗ {r.get('error')}", file=sys.stderr)
    if r.get("hint"):
        print(f"  hint: {r['hint']}", file=sys.stderr)
    return 1


# ── 子命令 ──────────────────────────────────────────────────────────────


def cmd_health(c, args):
    h = c.health()
    if h.get("_status") != 200:
        print(f"✗ 连不上 {c.base}（HTTP {h.get('_status')}）", file=sys.stderr)
        print("  · 手机和电脑在同一 WiFi？", file=sys.stderr)
        print("  · 悬浮球开关是不是绿的？", file=sys.stderr)
        print("  · 端口被占用时面板会显示原因", file=sys.stderr)
        return 2
    p = h.get("payload") or {}
    print(f"✓ {c.base}  app={p.get('app')} build={p.get('build')} ops={len(p.get('ops') or [])}")
    if p.get("needToken") and not c.token:
        print("! 这个 App 要求 token，加 --token 或 TH_AGENT_TOKEN")
    return 0


def cmd_state(c, args):
    r = c.exec({"op": "state"})
    if not r.get("ok"):
        return nonzero(r)
    d = r.get("data") or {}
    if args.as_json:
        pj(d)
        return 0
    print(
        f"模块 {d.get('module')}（第 {d.get('moduleIndex')} 个）"
        f"  路由深度 {d.get('routeDepth')}  语言 {d.get('locale')}"
    )
    tabs = d.get("tabs") or []
    if tabs:
        print("  导航：" + " · ".join(tabs))
    acts = d.get("actions") or []
    if acts:
        print("  可调动作：" + ", ".join(acts))
    return 0


def cmd_tree(c, args):
    r = c.exec({"op": "tree", "limit": args.limit})
    if not r.get("ok"):
        return nonzero(r)
    nodes = (r.get("data") or {}).get("nodes") or []
    if args.as_json:
        pj(nodes)
        return 0
    print(f"{len(nodes)} 个可寻址目标：")
    for n in nodes:
        r_ = [round(v) for v in n.get("rect") or []]
        print(f"  [{n['kind']:5}] {n['label'][:48]:<50} {r_}")
    return 0


def cmd_shot(c, args):
    st, body, hdr = c.get("/agent/shot", pr=args.pr)
    if st != 200:
        print(f"✗ 截图失败 HTTP {st}: {body[:120]!r}", file=sys.stderr)
        return 1
    out = pathlib.Path(args.out or f"shot-{int(time.time())}.png")
    out.write_bytes(body)
    print(f"✓ {out}  {len(body)} B")
    return 0


def cmd_do(c, args):
    try:
        cmd = json.loads(args.json)
    except Exception as e:
        sys.exit(f"不是合法 JSON：{e}")
    r = c.exec(cmd)
    pj(r)
    return nonzero(r)


def cmd_nav(c, args):
    r = c.exec({"op": "nav", "module": " ".join(args.module)})
    pj(r)
    return nonzero(r)


def cmd_link(c, args):
    """按 thirdhub:// 深链直达。比连续 nav+tap 更稳：解析在 App 内只有一份。"""
    url = " ".join(args.url)
    r = c.exec({"op": "deeplink", "url": url})
    pj(r)
    return nonzero(r)


def cmd_tab(c, args):
    arg = args.index[0] if args.index else ""
    cmd = {"op": "tab"}
    if arg.isdigit():
        cmd["index"] = int(arg)
    else:
        cmd["name"] = arg
    r = c.exec(cmd)
    pj(r)
    return nonzero(r)


def cmd_platform(c, args):
    arg = " ".join(args.name)
    cmd = {"op": "platform"}
    if arg.isdigit():
        cmd["index"] = int(arg)
    else:
        cmd["name"] = arg
    r = c.exec(cmd)
    pj(r)
    return nonzero(r)


def cmd_swipe(c, args):
    cmd = {"op": "swipe", "dir": args.dir}
    if args.dist:
        cmd["dist"] = args.dist
    r = c.exec(cmd)
    pj(r)
    return nonzero(r)


def cmd_tap(c, args):
    cmd = {"op": "tap"}
    if args.text:
        cmd["text"] = args.text
    elif args.key:
        cmd["key"] = args.key
    elif args.xy:
        cmd["xy"] = [float(v) for v in args.xy.replace(",", " ").split()]
    else:
        sys.exit("需要 --text / --key / --xy 之一")
    r = c.exec(cmd)
    pj(r)
    return nonzero(r)


def cmd_input(c, args):
    r = c.exec({"op": "input", "text": " ".join(args.text)})
    pj(r)
    return nonzero(r)


def cmd_back(c, args):
    r = c.exec({"op": "back"})
    pj(r)
    return nonzero(r)


def cmd_run(c, args):
    """跑一个用例文件：{"name":..., "steps":[...]}

    每一步都会打印结果；默认失败即停（--keep-going 可继续）。
    带 --shots 时每步截一张图，出问题能直接看当时的画面。
    这是"AI 自己验功能"的主力命令。
    """
    path = pathlib.Path(args.file)
    if not path.exists():
        sys.exit(f"找不到用例：{path}")
    spec = json.loads(path.read_text("utf-8"))
    if isinstance(spec, dict):
        steps = spec.get("steps") or []
        name = spec.get("name") or path.stem
    elif isinstance(spec, list):
        steps = spec
        name = path.stem
    else:
        sys.exit("用例必须是 {name, steps:[…]} 或直接一个指令数组")
    print(f"▶ {name}（{len(steps)} 步）")
    shot_dir = pathlib.Path(args.shots) if args.shots else None
    if shot_dir:
        shot_dir.mkdir(parents=True, exist_ok=True)
    fails = 0
    t0 = time.time()
    for i, s in enumerate(steps, 1):
        desc = s.get("note") or s.get("op")
        r = c.exec(s)
        mark = "✓" if r.get("ok") else "✗"
        print(f"  {mark} {i:02d}. {desc}  ({r.get('ms', 0)}ms)")
        if not r.get("ok"):
            fails += 1
            print(f"        {r.get('error')}")
            if r.get("hint"):
                print(f"        hint: {r['hint']}")
        if shot_dir:
            st, body, _ = c.get("/agent/shot")
            if st == 200:
                (shot_dir / f"{i:02d}-{'ok' if r.get('ok') else 'fail'}.png").write_bytes(body)
        if not r.get("ok") and not args.keep_going:
            break
    dt = time.time() - t0
    if fails:
        print(f"✗ {fails} 步失败，用时 {dt:.1f}s")
        return 1
    print(f"✓ 全部通过，用时 {dt:.1f}s")
    return 0


def cmd_pair(c, args):
    cfg = {"host": args.host, "token": args.token, "port": args.port}
    if c:
        h = c.health()
        if h.get("_status") != 200:
            print(f"! 记下了，但现在连不上（HTTP {h.get('_status')}）")
    save_cfg({k: v for k, v in cfg.items() if v})
    print(f"✓ 已保存到 {CFG}")
    return 0


def cmd_macros(c, args):
    """列出所有能用一句话驱动的动作（省得每次拼 JSON）。"""
    rows = [
        ("nav <模块>", "打开模块，别名表见 agentModuleAlias"),
        ("tab <下标|名字>", "切底部导航"),
        ("platform <平台>", "视频页横向切平台"),
        ("swipe <left|right|up|down>", "真实手势滑动"),
        ("tap --text/--key/--xy", "点击"),
        ("input <文本>", "往当前输入框写入"),
        ("back", "返回一层"),
        ("state / tree / shot", "读状态 / 读界面 / 截图"),
        ("run <用例.json>", "跑回归用例"),
    ]
    for a, b in rows:
        print(f"  {a:<30} {b}")
    return 0


# ── 入口 ────────────────────────────────────────────────────────────────


def main():
    ap = argparse.ArgumentParser(
        prog="th_agent", description="从电脑驱动 ThirdHub App（AI 控制总线）"
    )
    ap.add_argument("--host", help="手机 IP 或完整 URL")
    ap.add_argument("--port", type=int, help=f"默认 {DEFAULT_PORT}")
    ap.add_argument("--token", help="悬浮球面板里的 token")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("health")
    p_state = sub.add_parser("state")
    p_state.add_argument("--json", dest="as_json", action="store_true")
    sub.add_parser("macros")

    p = sub.add_parser("tree")
    p.add_argument("--limit", type=int, default=220)
    p.add_argument("--json", dest="as_json", action="store_true")

    p = sub.add_parser("shot")
    p.add_argument("-o", "--out")
    p.add_argument("--pr", type=float, default=1.0)

    p = sub.add_parser("do")
    p.add_argument("json")

    p = sub.add_parser("nav")
    p.add_argument("module", nargs="+")

    p = sub.add_parser("tab")
    p.add_argument("index", nargs="?")

    p = sub.add_parser("link")
    p.add_argument("url", nargs="+", help="thirdhub://video?platform=hongguo 这类深链")

    p = sub.add_parser("platform")
    p.add_argument("name", nargs="+")

    p = sub.add_parser("swipe")
    p.add_argument("dir", choices=["left", "right", "up", "down"])
    p.add_argument("--dist", type=float)

    p = sub.add_parser("tap")
    p.add_argument("--text")
    p.add_argument("--key")
    p.add_argument("--xy")

    p = sub.add_parser("input")
    p.add_argument("text", nargs="+")

    sub.add_parser("back")

    p = sub.add_parser("run")
    p.add_argument("file")
    p.add_argument("--shots", help="每步截图存到这个目录")
    p.add_argument("--keep-going", action="store_true")

    p = sub.add_parser("pair")
    p.add_argument("host")
    p.add_argument("token")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)

    args = ap.parse_args()
    if not args.cmd:
        ap.print_help()
        return 0

    # pair 是"写配置"，不需要已有配置
    if args.cmd == "pair":
        c = None
        try:
            c = Client(args.host, port=args.port, token=args.token, timeout=4)
        except Exception:
            pass
        return cmd_pair(c, args)

    c = make_client(args)
    table = {
        "health": cmd_health,
        "state": cmd_state,
        "tree": cmd_tree,
        "shot": cmd_shot,
        "do": cmd_do,
        "nav": cmd_nav,
        "tab": cmd_tab,
        "platform": cmd_platform,
        "swipe": cmd_swipe,
        "tap": cmd_tap,
        "input": cmd_input,
        "back": cmd_back,
        "run": cmd_run,
        "macros": cmd_macros,
    }
    fn = table.get(args.cmd)
    if not fn:
        ap.print_help()
        return 2
    return fn(c, args)


if __name__ == "__main__":
    sys.exit(main())
