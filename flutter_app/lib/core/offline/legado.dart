// Legado（阅读 App）书源规则解析子集 —— 端上直连用，4.81.84 新建
//
// ── 为什么要在端上重写一遍 ─────────────────────────────────────────────
//   用户的原话是「脱离后端就没法用，非常之垃圾」。后端尽管有 2400+ 源，
//   但一个源都跑不通的时候（NAS 关机、断网、后端挂了）App 就只剩壳子。
//   源池本来就是 12MB 的 JSON，打进安装包（用户明确说包大点没关系），
//   端上用同一套规则直连源站，后端就退回「保底/兜底」的角色。
//
// ── 支持到什么程度 ───────────────────────────────────────────────────
//   覆盖「纯选择器」类规则（源池里 995/2664 属于这类，占可用源的绝大多数）：
//     · 选择器：class.xxx（多 class 空格分隔）/ tag.div / id.xx / .x / #x / [attr=v]
//     · 取值：@text @textNodes @ownText @html @href @src @content @title @alt @value
//     · 下标：`!0`、`tag.li.0`、`p.1`
//     · 正则：`##pattern##replacement`（支持 $1..$9），多段依次执行
//     · 合并：`&&`（拼起来）、`||`（取第一个非空）
//     · JSON 源：`$.data.list[*]`、`$.a.b[0].c`（简单路径）
//   不支持（这类源在打包时已被剔除）：`@js:`、`<js>`、`{{...}}` 表达式、webView。
//   —— 不做「假装支持」：解析不了就返回空，让上层换下一个源，不会给出错内容。
//
// ── 与后端的关系 ─────────────────────────────────────────────────────
//   端上失败（源站全挂）→ 上层再走后端。两者**同构**（返回同样的 JSON），
//   所以 UI 层完全不需要知道内容是从哪儿来的。

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;

/// 取值类后缀：出现在规则链末尾时表示「取这个属性/文本」，不再往下钻。
const _kValueKeys = {
  'text',
  'textNodes',
  'ownText',
  'html',
  'all',
  'href',
  'src',
  'content',
  'title',
  'alt',
  'value',
  'abs',
  'data-src',
  'data-original',
};

class Lg {
  // ══════════════════════════ URL 模板 ══════════════════════════

  /// `{{key}}` / `{{page}}` 替换。Legado 里还有 `{{...}}` 表达式，那种源已排除。
  static String fill(String tpl, {required String key, int page = 1}) {
    var s = tpl.replaceAll('{{key}}', Uri.encodeComponent(key));
    s = s.replaceAll('{{page}}', '$page');
    // UMD 老写法：{{key}} 有时写成 %s
    return s.trim();
  }

  /// 绝对化：`/search?x` → `https://host/search?x`
  static String abs(String url, String base) {
    final u = url.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('//')) {
      final scheme = Uri.tryParse(base)?.scheme ?? 'https';
      return '$scheme:$u';
    }
    final b = Uri.tryParse(base);
    if (b == null) return u;
    if (u.startsWith('/')) return '${b.scheme}://${b.authority}$u';
    // 相对路径：去掉 base 的最后一段
    final segs = b.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segs.isNotEmpty) segs.removeLast();
    return '${b.scheme}://${b.authority}/${[...segs, u].join('/')}';
  }

  // ══════════════════════════ 解析入口 ══════════════════════════

  /// 把响应体解析成文档。JSON 源返回 null（dom），JSON 数据放 [json]。
  static String? _jsonOf(String body) {
    final t = body.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) return t;
    return null;
  }

  /// 在 HTML 文档里按规则取**列表**（bookList / chapterList 用）。
  static List<dom.Element> list(dom.Document doc, String rule) {
    var r = rule.trim();
    if (r.isEmpty) return const [];
    // `||` 用于合并多个列表（如两个版式），`&&` 在列表场景不常见
    if (r.contains('||')) {
      final out = <dom.Element>[];
      for (final alt in r.split('||')) {
        out.addAll(list(doc, alt));
      }
      return out;
    }
    var idx = -1;
    final bang = RegExp(r'!(\d+)$').firstMatch(r);
    if (bang != null) {
      idx = int.parse(bang.group(1)!);
      r = r.substring(0, bang.start);
    }

    // ★必须有这一步：列表规则常写成 `class.txt-list@tag.li`（先定容器，再取容器里的 li）。
    //   只当一条 CSS 处理的话，匹配到的是**容器本身**，搜出来只有 1 条 —— 这正是
    //   「能搜到但每个源只有一本书」的形状。
    List<dom.Element> els;
    final at = r.indexOf('@');
    if (at > 0) {
      final bases = list(doc, r.substring(0, at));
      final innerCss = _css(r.substring(at + 1));
      els = <dom.Element>[];
      if (innerCss.isEmpty) {
        els = bases;
      } else {
        for (final b in bases) {
          els.addAll(b.querySelectorAll(innerCss));
        }
      }
    } else {
      final css = _css(r);
      els = css.isEmpty ? const <dom.Element>[] : doc.querySelectorAll(css);
    }
    if (idx >= 0) return idx < els.length ? [els[idx]] : const [];
    return els;
  }

  /// 在元素里按规则取**值**。
  ///
  /// [base] 用于把 `@href` 的相对路径补全成绝对地址。
  static String pick(dom.Element? root, String rule, {String base = ''}) {
    if (root == null) return '';
    final r0 = rule.trim();
    if (r0.isEmpty) return '';

    // `||` 取第一个非空
    if (r0.contains('||')) {
      for (final alt in r0.split('||')) {
        final v = pick(root, alt, base: base);
        if (v.trim().isNotEmpty) return v;
      }
      return '';
    }
    // `&&` 逐条求值后拼接（多字段拼成一段）
    if (r0.contains('&&')) {
      final parts = r0
          .split('&&')
          .map((e) => pick(root, e, base: base).trim())
          .where((e) => e.isNotEmpty)
          .toList();
      return parts.join('\n');
    }

    // `##正则` 放到最后做：先取值，再清洗
    // ★4.81.84 修：这里原来写成 `var rule = r0;`，而方法参数也叫 `rule` ——
    //   同一作用域重复声明，analyze 直接报 referenced_before_declaration。
    //   改名为 body，语义也更准（它此时是「去掉清洗段之后的选择器主体」）。
    var body = r0;
    var rxPat = '';
    var rxRep = '';
    final hi = body.indexOf('##');
    if (hi >= 0) {
      final tail = body.substring(hi + 2);
      body = body.substring(0, hi);
      final segs = tail.split('##');
      rxPat = segs.isNotEmpty ? segs[0] : '';
      rxRep = segs.length > 1 ? segs[1] : '';
    }

    var el = root;
    var out = '';
    final chain = body.split('@');
    for (var i = 0; i < chain.length; i++) {
      final seg = chain[i].trim();
      if (seg.isEmpty) continue;
      final low = seg.toLowerCase();
      if (_kValueKeys.contains(low)) {
        out = _value(el, low, base);
        continue;
      }
      final next = _select(el, seg);
      if (next == null) return '';
      el = next;
      if (i == chain.length - 1) out = _value(el, 'text', base);
    }
    if (out.isEmpty && el != null) out = _value(el, 'text', base);

    if (rxPat.isNotEmpty) out = rx(out, rxPat, rxRep);
    return out.trim();
  }

  // ══════════════════════════ 选择器 ══════════════════════════

  /// Legado 选择器 → CSS。
  static String _css(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    // 切片 tm:2 / p.0:3 —— 只取前半段
    final colon = s.indexOf(':');
    if (colon > 0 && !s.startsWith('[')) s = s.substring(0, colon);
    s = s.replaceAll(RegExp(r'!(\d+)$'), '');

    final m = RegExp(r'^(class|tag|id)\.(.+)$').firstMatch(s);
    if (m != null) {
      final kind = m.group(1)!;
      var rest = m.group(2)!.trim();
      // tag.li.0 / tag.li.!0 之类：末尾的数字当下标
      rest = rest.replaceAll(RegExp(r'\.(\d+)$'), '');
      if (kind == 'class') {
        // `class.a b` 表示同时具备 a 与 b
        final cls = rest.split(RegExp(r'\s+')).where((e) => e.isNotEmpty);
        return cls.map((e) => '.${e.trim()}').join();
      }
      if (kind == 'id') return '#$rest';
      return rest; // tag.div → div
    }
    // `p.1` / `a.0`：tag + 下标
    final t = RegExp(r'^([A-Za-z][\w-]*)\.(\d+)$').firstMatch(s);
    if (t != null) return t.group(1)!;
    return s;
  }

  /// 单步选择：把 [seg] 当作「在当前元素下找子元素」的选择器。
  static dom.Element? _select(dom.Element root, String seg) {
    var s = seg.trim();
    if (s.isEmpty) return root;
    var idx = 0;
    var hasIdx = false;

    final bang = RegExp(r'!(\d+)$').firstMatch(s);
    if (bang != null) {
      idx = int.parse(bang.group(1)!);
      hasIdx = true;
      s = s.substring(0, bang.start);
    }
    final dotNum = RegExp(r'^(?:[A-Za-z][\w-]*|class\.[\w\s-]+|tag\.[\w-]+)\.(\d+)$')
        .firstMatch(s);
    if (!hasIdx && dotNum != null) {
      idx = int.parse(dotNum.group(1)!);
      hasIdx = true;
      s = s.substring(0, dotNum.start + dotNum.group(0)!.lastIndexOf('.'))
          .replaceAll(RegExp(r'\.$'), '');
    }
    final css = _css(s);
    if (css.isEmpty) return root;
    final els = root.querySelectorAll(css);
    if (els.isEmpty) return null;
    return els[hasIdx && idx < els.length ? idx : 0];
  }

  /// 取值。
  static String _value(dom.Element? el, String kind, String base) {
    if (el == null) return '';
    switch (kind) {
      case 'text':
      case 'all':
        return el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      case 'textNodes':
        // 直接文本节点，不含子元素文本
        return el.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join(' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      case 'ownText':
        return el.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join('')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      case 'html':
        return el.innerHtml.trim();
      case 'href':
        return abs(el.attributes['href'] ?? '', base);
      case 'src':
        return abs(el.attributes['src'] ?? '', base);
      case 'data-src':
        return abs(el.attributes['data-src'] ?? el.attributes['src'] ?? '', base);
      case 'data-original':
        return abs(el.attributes['data-original'] ??
            el.attributes['data-src'] ??
            el.attributes['src'] ??
            '', base);
      case 'content':
        return (el.attributes['content'] ?? '').trim();
      case 'title':
        return (el.attributes['title'] ?? '').trim();
      case 'alt':
        return (el.attributes['alt'] ?? '').trim();
      case 'value':
        return (el.attributes['value'] ?? '').trim();
      case 'abs':
        return el.text.trim();
      default:
        return (el.attributes[kind] ?? '').trim();
    }
  }

  // ══════════════════════════ 正则清洗 ══════════════════════════

  /// `##pattern##replacement`。Dart 的 replaceAll 不认 `$1`，手动展开。
  static String rx(String s, String pat, String rep) {
    if (pat.isEmpty) return s;
    try {
      final re = RegExp(pat, multiLine: true);
      return s.replaceAllMapped(re, (m) {
        var out = rep;
        for (var i = m.groupCount; i >= 0; i--) {
          out = out.replaceAll('\$$i', m.group(i) ?? '');
        }
        return out;
      });
    } catch (_) {
      return s;
    }
  }

  // ══════════════════════════ JSON 源 ══════════════════════════

  /// 极简 JSONPath：`$.data.list[*]`、`$.a.b[0].c`。
  /// 返回命中的节点列表（Map / List / 标量）。
  static List<dynamic> jsonPath(dynamic root, String path) {
    var p = path.trim();
    if (p.startsWith(r'$')) p = p.substring(1);
    var cur = <dynamic>[root];
    for (final rawSeg in p.split('.')) {
      final seg = rawSeg.trim();
      if (seg.isEmpty) continue;
      final m = RegExp(r'^([\w-]*)((?:\[\d+\]|\[\*\])*)$').firstMatch(seg);
      if (m == null) return const [];
      final name = m.group(1) ?? '';
      final idxs = RegExp(r'\[(\d+|\*)\]').allMatches(m.group(2) ?? '');
      final next = <dynamic>[];
      for (final c in cur) {
        dynamic v = c;
        if (name.isNotEmpty) {
          if (v is Map) {
            v = v[name];
          } else {
            continue;
          }
        }
        if (idxs.isEmpty) {
          next.add(v);
          continue;
        }
        for (final im in idxs) {
          final key = im.group(1)!;
          if (v is List) {
            if (key == '*') {
              next.addAll(v);
            } else {
              final i = int.parse(key);
              if (i >= 0 && i < v.length) next.add(v[i]);
            }
          }
          v = next.isEmpty ? null : next.last;
        }
      }
      cur = next;
    }
    return cur.where((e) => e != null).toList();
  }

  /// JSON 源取字符串值（`$.name` 这类）。
  static String jsonPick(dynamic root, String rule) {
    final p = jsonPath(root, rule);
    if (p.isEmpty) return '';
    final v = p.first;
    if (v is String) return v.trim();
    if (v is num || v is bool) return '$v';
    return '';
  }

  static dom.Document parse(String body) => hp.parse(body);
  static dynamic parseJson(String body) => jsonDecode(body);
}
