#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从主站 js/ai/ai-models.js 重新生成 lib/core/ai_snapshot.dart（启动兜底快照）。

用法:
    python tool/gen_ai_snapshot.py                 # 自动下载线上文件并重写快照
    python tool/gen_ai_snapshot.py --src <file>    # 用本地文件（离线/固定版本）
    python tool/gen_ai_snapshot.py --check         # 只比对，不写；有漂移则退出码 1

为什么要脚本而不是手改:
  ai-models.js 是 40+ 厂商 / 300+ 模型的 JS 字面量，手抄必然漏项。而且 models 里
  允许**混入对象**（如 {id:'xxx-free', tags:['free'], privacyLevel:'risk'}），
  Dart 侧 `List<String>.from(j['models'])` 遇到 Map 会直接抛
  "type 'Map' is not a subtype of type 'String'"，所以必须由脚本做结构转换：
    · models 中的对象 → 取 id 平铺进 models（保持 List<String>）
    · 该对象的其余字段(name/tags/privacyLevel/…) → 收进 modelMeta[id]，不再丢失
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DART_OUT = os.path.join(REPO, 'lib', 'core', 'ai_snapshot.dart')
DEFAULT_URL = 'https://thirdhub.pages.dev/js/ai/ai-models.js'

# ─────────────────────────── JS 字面量解析 ───────────────────────────
# 只覆盖 ai-models.js 实际用到的子集：对象/数组/字符串/数字/布尔/null。
# 出现函数调用、模板变量等无法静态求值的写法会明确抛错，而不是悄悄产出半截数据。


def strip_comments(s: str) -> str:
    out = []
    i, n, mode = 0, len(s), None
    while i < n:
        c = s[i]
        if mode is None:
            if c == '/' and i + 1 < n and s[i + 1] == '*':
                mode = 'block'; i += 2; continue
            if c == '/' and i + 1 < n and s[i + 1] == '/':
                mode = 'line'; i += 2; continue
            if c in "'\"`":
                q = c; out.append(c); i += 1
                while i < n:
                    out.append(s[i])
                    if s[i] == '\\':
                        i += 1
                        if i < n:
                            out.append(s[i]); i += 1
                        continue
                    if s[i] == q:
                        i += 1; break
                    i += 1
                continue
            out.append(c); i += 1
        elif mode == 'block':
            if c == '*' and i + 1 < n and s[i + 1] == '/':
                mode = None; i += 2; continue
            i += 1
        else:
            if c == '\n':
                mode = None
            i += 1
    return ''.join(out)


class JsParser:
    def __init__(self, s):
        self.s, self.i = s, 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in ' \t\r\n':
            self.i += 1

    def parse(self):
        self.ws()
        if self.i >= len(self.s):
            raise ValueError('意外结束')
        c = self.s[self.i]
        if c == '{':
            return self.obj()
        if c == '[':
            return self.arr()
        if c in "'\"`":
            return self.str_()
        return self.prim()

    def obj(self):
        self.i += 1
        d = {}
        while True:
            self.ws()
            if self.i >= len(self.s):
                raise ValueError('对象未闭合')
            if self.s[self.i] == '}':
                self.i += 1
                return d
            if self.s[self.i] == ',':
                self.i += 1; continue
            k = self.key()
            self.ws()
            if self.i >= len(self.s) or self.s[self.i] != ':':
                raise ValueError('键 %r 后缺少冒号 @%d: %r' % (k, self.i, self.s[self.i:self.i + 40]))
            self.i += 1
            d[k] = self.parse()

    def key(self):
        self.ws()
        c = self.s[self.i]
        if c in "'\"`":
            return self.str_()
        m = re.match(r'[A-Za-z_$][\w$]*', self.s[self.i:])
        if not m:
            raise ValueError('非法键 @%d: %r' % (self.i, self.s[self.i:self.i + 40]))
        self.i += m.end()
        return m.group(0)

    def arr(self):
        self.i += 1
        a = []
        while True:
            self.ws()
            if self.i >= len(self.s):
                raise ValueError('数组未闭合')
            if self.s[self.i] == ']':
                self.i += 1
                return a
            if self.s[self.i] == ',':
                self.i += 1; continue
            a.append(self.parse())

    def str_(self):
        q = self.s[self.i]; self.i += 1
        buf = []
        while True:
            if self.i >= len(self.s):
                raise ValueError('字符串未闭合')
            c = self.s[self.i]
            if c == '\\':
                nxt = self.s[self.i + 1]
                if nxt == 'u':
                    buf.append(chr(int(self.s[self.i + 2:self.i + 6], 16)))
                    self.i += 6; continue
                buf.append({'n': '\n', 't': '\t', 'r': '\r', 'b': '\b', 'f': '\f',
                            '\\': '\\', "'": "'", '"': '"', '`': '`', '0': '\0'}.get(nxt, nxt))
                self.i += 2; continue
            if c == q:
                self.i += 1
                return ''.join(buf)
            buf.append(c); self.i += 1

    def prim(self):
        m = re.match(r'[^,}\]]+', self.s[self.i:])
        if not m:
            raise ValueError('无法解析 @%d: %r' % (self.i, self.s[self.i:self.i + 40]))
        t = m.group(0).strip()
        self.i += m.end()
        if t in ('true', 'false'):
            return t == 'true'
        if t in ('null', 'undefined'):
            return None
        if re.fullmatch(r'-?\d+', t):
            return int(t)
        if re.fullmatch(r'-?\d*\.\d+([eE][-+]?\d+)?', t):
            return float(t)
        raise ValueError('非字面量（脚本不支持的表达式）: %r @%d' % (t[:60], self.i))


def extract_array(src: str, name: str):
    """取 `export const <name> = [ ... ];` 的数组，做括号配平。"""
    m = re.search(r'export\s+const\s+%s\s*=\s*\[' % re.escape(name), src)
    if not m:
        raise SystemExit('未找到 export const %s = [' % name)
    i = src.index('[', m.start())
    depth, j, n = 0, i, len(src)
    in_str, q = False, ''
    while j < n:
        c = src[j]
        if in_str:
            if c == '\\':
                j += 2; continue
            if c == q:
                in_str = False
            j += 1; continue
        if c in "'\"`":
            in_str, q = True, c; j += 1; continue
        if c == '[':
            depth += 1
        elif c == ']':
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
        j += 1
    raise SystemExit('数组未配平')


# ─────────────────────────── Dart 输出 ───────────────────────────

def dart_str(s: str) -> str:
    return "'" + (s.replace('\\', '\\\\').replace("'", "\\'")
                  .replace('$', '\\$').replace('\n', '\\n')
                  .replace('\r', '\\r').replace('\t', '\\t')) + "'"


def dart_val(v) -> str:
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return dart_str(v)
    if isinstance(v, list):
        return '[' + ', '.join(dart_val(x) for x in v) + ']'
    if isinstance(v, dict):
        return '<String, dynamic>{' + ', '.join(
            '%s: %s' % (dart_str(k), dart_val(val)) for k, val in v.items()) + '}'
    raise TypeError('不支持的节点类型 %r' % (type(v),))


KEY_ORDER = ['id', 'name', 'base', 'type', 'models', 'image', 'video', 'deprecated', 'modelMeta']


def build_snapshot(providers):
    out = []
    for p in providers:
        if not isinstance(p, dict) or 'id' not in p:
            continue
        flat, meta = [], {}
        for m in (p.get('models') or []):
            if isinstance(m, str):
                flat.append(m)
            elif isinstance(m, dict) and m.get('id'):
                flat.append(m['id'])                      # 保住 List<String>
                meta[m['id']] = {k: v for k, v in m.items() if k != 'id'}
            else:
                raise SystemExit('models 里出现无法处理的项: %r（厂商 %s）' % (m, p.get('id')))
        e = {}
        for k in KEY_ORDER:
            if k == 'models':
                if flat:
                    e['models'] = flat
            elif k == 'modelMeta':
                if meta:
                    e['modelMeta'] = meta
            else:
                v = p.get(k)
                if isinstance(v, list) and v:
                    e[k] = v
                elif isinstance(v, str) and v:
                    e[k] = v
        out.append(e)
    return out


def render(snaps, src_label: str) -> str:
    n_model = sum(len(s.get('models') or []) for s in snaps)
    n_extra = sum(len(s.get('image') or []) + len(s.get('video') or []) for s in snaps)
    today = datetime.date.today().isoformat()
    L = [
        '// AI 厂商/模型快照 —— 启动兜底, 运行后由 AiRegistry.refresh() 在线刷新。',
        '//',
        '// ★本文件由脚本生成，请勿手改：`python tool/gen_ai_snapshot.py`',
        '//   数据源: %s' % src_label,
        '//   生成时间: %s · %d 家厂商 / %d 个对话模型 / %d 个绘画+视频模型' % (today, len(snaps), n_model, n_extra),
        '//',
        '// 注意: models 必须是 List<String>（AiProvider.from 用 List<String>.from），',
        '//   ai-models.js 里形如 {id,tags,privacyLevel} 的"免费模型"对象由生成器取 id 平铺，',
        '//   其余字段收进 modelMeta 以免丢失。',
        'const kAiSnapshot = [',
    ]
    for s in snaps:
        L.append('  %s,' % dart_val(s))
    L.append('];')
    L.append('')
    return '\n'.join(L)


# ─────────────────────────── 主流程 ───────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', help='本地 ai-models.js 路径（默认自动下载）')
    ap.add_argument('--url', default=DEFAULT_URL)
    ap.add_argument('--check', action='store_true', help='只比对不写入')
    a = ap.parse_args()

    if a.src:
        raw = open(a.src, encoding='utf-8').read()
        label = a.src
    else:
        try:
            raw = subprocess.run(['curl', '-sSL', '--max-time', '60', a.url],
                                 capture_output=True, check=True).stdout.decode('utf-8')
        except Exception as e:                                  # noqa: BLE001
            raise SystemExit('下载失败: %s\n（可先用 --src 指定本地文件）' % e)
        label = a.url
    if 'PROVIDERS' not in raw:
        raise SystemExit('下载内容不含 PROVIDERS，可能被 CDN 拦截')

    arr = extract_array(strip_comments(raw), 'PROVIDERS')
    providers = JsParser(arr).parse()
    snaps = build_snapshot(providers)
    text = render(snaps, label)

    old = open(DART_OUT, encoding='utf-8').read() if os.path.exists(DART_OUT) else ''

    if a.check:
        if old == text:
            print('[OK] 快照与线上一致（%d 家厂商）' % len(snaps))
            return 0
        print('[DRIFT] 快照已过期，请运行: python tool/gen_ai_snapshot.py')
        return 1

    if old == text:
        print('[OK] 无变化（%d 家厂商 / %d 模型）' % (len(snaps), sum(len(s.get('models') or []) for s in snaps)))
        return 0
    with open(DART_OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print('[WROTE] %s' % DART_OUT)
    print('        %d 家厂商 / %d 个对话模型' % (len(snaps), sum(len(s.get('models') or []) for s in snaps)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
