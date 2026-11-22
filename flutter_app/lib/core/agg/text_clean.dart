// 正文清洗 —— 让「从不同站点抓来的正文」看起来是同一本书的一部分。
//
// ── 为什么需要这一层 ──────────────────────────────────────────────────
//   同一个「书」板块里，正文来自三种完全不同的地方：
//     · 维基文库：MediaWiki 的 HTML，带着编辑链接、分类页、模板残留；
//     · 古登堡澳洲站：1990 年代的纯文本，带着大段版权声明样板；
//     · 用户导入源：作者自己写的解析规则，质量全靠他自己。
//
//   原先每个源各自随手 `stripHtml()`，结果同一个阅读页里：
//   有的段落糊成一坨、有的正文中间夹着「[编辑]」、有的整页是版权
//   声明还没到正文。用户的话是「获取的正文还是参差不齐，非常之垃圾」。
//
//   清洗放在**出口**而不是每个源内部，理由和聚合层一样：
//   加一个源、改一个解析规则，正文质量不用重新对齐一遍。
//
// ── 三条原则 ────────────────────────────────────────────────────────
//   ① 只做「无损规整」与「样板剥离」，不做改写 —— 不能把沈从文改成语文课本；
//   ② 宁可少删不多删：拿不准的行一律保留，删错一句比留一句广告更糟；
//   ③ 排版（缩进 / 行高 / 字距）归阅读页，不进文本 —— 文本要保持可复制、可搜索。
import 'dart:math' as math;

/// 正文来源类型，决定启用哪一组样板剥离规则。
enum TextSourceKind {
  /// 通用：只做物理规整。
  generic,

  /// 维基文库：MediaWiki 的页面导出。
  wikisource,

  /// Project Gutenberg 系：纯文本或早期 HTML，带样板头尾。
  gutenberg,
}

class TextClean {
  TextClean._();

  /// 正文清洗总入口。
  static String body(String raw, {TextSourceKind kind = TextSourceKind.generic}) {
    var s = raw;
    if (s.isEmpty) return '';

    // ① 物理规整（所有来源都做）。
    s = _lineEndings(s);
    s = _stripWeirdSpaces(s);

    // ② 按来源剥样板。
    switch (kind) {
      case TextSourceKind.gutenberg:
        s = _gutenbergBoilerplate(s);
        break;
      case TextSourceKind.wikisource:
        s = _wikisourceChrome(s);
        break;
      case TextSourceKind.generic:
        break;
    }

    // ③ 段落规整 + 中文标点空格。
    s = _normalizeParagraphs(s);
    s = _zhSpacing(s);

    return s.trim();
  }

  // ── ① 物理规整 ───────────────────────────────────────────────────

  /// \r\n / \r 统一成 \n。混用换行是"同一本书里段落间距忽大忽小"的头号原因。
  static String _lineEndings(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// 不可见/不规则空白统一。
  ///
  /// U+00A0（不换行空格）和 U+3000（全角空格）在正文里最常见：
  /// 从 HTML 抓出来的文本几乎每段都有，直接渲染会表现成"缩进忽宽忽窄"。
  static String _stripWeirdSpaces(String s) {
    var t = s
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u3000', ' ')
        .replaceAll('\u200B', '') // 零宽空格
        .replaceAll('\uFEFF', ''); // BOM
    // 行内多空格压缩，但保留行首缩进（最多 8 个，避免把原文的缩进也吃掉）。
    t = t.split('\n').map((line) {
      final indent = _leadingSpaces(line);
      final body = line.trimLeft().replaceAll(RegExp(r' {2,}'), ' ');
      return body.isEmpty ? '' : (' ' * math.min(indent, 8)) + body;
    }).join('\n');
    return t;
  }

  static int _leadingSpaces(String s) {
    var i = 0;
    while (i < s.length && s[i] == ' ') {
      i++;
    }
    return i;
  }

  // ── ②a 古登堡样板 ────────────────────────────────────────────────

  /// 剥掉 Project Gutenberg 的版权声明头尾。
  ///
  /// 这块文字占整本书的 3%~8%，而它在每个文件里都长得一样 ——
  /// 用户翻一页看到的是"THE PROJECT GUTENBERG EBOOK OF ..."，
  /// 结论只能是"这书是垃圾"。正文本身一个字都不动。
  static String _gutenbergBoilerplate(String s) {
    // 头部标记：`*** START OF THE PROJECT GUTENBERG EBOOK ... ***`
    // （有的写 START OF THIS PROJECT GUTENBERG，有的少个空格）
    final startRe = RegExp(
        r'\*\*\*?\s*START OF (?:THE |THIS )?PROJECT GUTENBERG[^*]*\*\*\*?',
        caseSensitive: false);
    // 尾部标记：`*** END OF THE PROJECT GUTENBERG EBOOK ... ***`
    final endRe = RegExp(
        r'\*\*\*?\s*END OF (?:THE |THIS )?PROJECT GUTENBERG[^*]*\*\*\*?',
        caseSensitive: false);

    var out = s;
    final m1 = startRe.firstMatch(out);
    if (m1 != null) out = out.substring(m1.end);
    final m2 = endRe.firstMatch(out);
    if (m2 != null) out = out.substring(0, m2.start);

    // 旧版文本文件用整行句子做边界，没有星号标记。
    final legacyStart = RegExp(
        r'^\s*Project Gutenberg[^.\n]{0,120}(Ebook|eBook|etext|EText|e-text)[^\n]*$',
        caseSensitive: false, multiLine: true);
    final lm = legacyStart.firstMatch(out);
    if (lm != null && lm.start < 8000) out = out.substring(lm.end);

    final legacyEnd = RegExp(
        r'^\s*End of (?:the )?Project Gutenberg[^\n]*$',
        caseSensitive: false, multiLine: true);
    final le = legacyEnd.firstMatch(out);
    if (le != null) out = out.substring(0, le.start);

    // 中间残留的样板段落（"This etext was produced by ..."之类）。
    out = out.replaceAll(RegExp(
        r'^\s*This e-?text (?:was|is) (?:produced|prepared) by[^\n]*$',
        caseSensitive: false, multiLine: true), '');
    return out;
  }

  // ── ②b 维基文库残留 ──────────────────────────────────────────────

  /// 剥掉 MediaWiki 页面导出里必然带、正文又不需要的东西。
  ///
  /// 只删**能逐行判定为界面残留**的行，不做上下文推断 ——
  /// 宁可留一句「分类:中国文学」，也不能误删正文里的一行诗。
  static String _wikisourceChrome(String s) {
    final drop = <RegExp>[
      // 编辑链接（不同语言版本都有）。
      RegExp(r'^\s*\[?(edit|編輯|编辑)\]?\s*$', caseSensitive: false),
      // 分类页尾：从「分类:」行起整段丢掉（它永远在页面最末）。
      RegExp(r'^\s*(分类|分類|Categories?|Category)\s*[:：]\s*$', caseSensitive: false),
      // 页面出处行。
      RegExp(r'^\s*取自\s*["“].*$', caseSensitive: false),
      RegExp(r'^\s*Retrieved from\s*["“].*$', caseSensitive: false),
      // 折叠表头。
      RegExp(r'^\s*(隐藏|顯示|显示|Show|hide)\s*$', caseSensitive: false),
      // 「本页面最后编辑于 …」
      RegExp(r'^\s*本页面最后编辑于.*$', caseSensitive: false),
      RegExp(r'^\s*This page was last edited.*$', caseSensitive: false),
    ];

    final lines = s.split('\n');
    final out = <String>[];
    var inCategoryTail = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (inCategoryTail) continue;
      // 「分类:」单独成行 → 之后全是分类列表，整段丢。
      if (RegExp(r'^\s*(分类|分類|Categories?|Category)\s*[:：]\s*$').hasMatch(line)) {
        inCategoryTail = true;
        continue;
      }
      if (drop.any((re) => re.hasMatch(line))) continue;
      out.add(line);
    }
    return out.join('\n');
  }

  // ── ③ 段落规整 ───────────────────────────────────────────────────

  /// 空行是段落的唯一分隔。压到最多两个连续换行，让整本书的段距一致。
  static String _normalizeParagraphs(String s) {
    var t = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // 行尾空格（多来自 HTML 折行）去掉，但保留行首缩进。
    t = t.split('\n').map((l) => l.trimRight()).join('\n');
    return t;
  }

  /// 中文标点后面不留空格；中文与全角标点之间的空格去掉。
  ///
  /// 从 HTML 剥出来时 `你 好 ， 世 界` 这种断裂到处都是，
  /// 它比错别字更影响阅读 —— 眼睛每句都要重新对焦。
  ///
  /// ★ 只动**空格与制表符**，绝不动换行：
  ///   段落分隔靠 `\n\n` 表达，用 `\s+` 会把换行也吞掉 ——
  ///   那样"第一段\n\n第二段"会粘成"第一段第二段"，整本书连段落都没了。
  static String _zhSpacing(String s) {
    // 中文标点后紧跟的空格删掉。
    const punct = '，。、；：！？）》」』】…·';
    var t = s;
    for (final ch in punct.split('')) {
      t = t.replaceAll('$ch ', ch).replaceAll('$ch\t', ch);
    }
    // 两个汉字之间的空格删掉（"沈 从 文" → "沈从文"）。
    // 用前后断言而不是捕获组：捕获组替换在相邻空格上会漏掉后一段
    // （"沈 从 文" 只能吃掉 "沈 从"，剩下 " 文" 就不管了）。
    t = t.replaceAll(
        RegExp(r'(?<=[\u4e00-\u9fa5])[ \t]+(?=[\u4e00-\u9fa5])'), '');
    // 汉字与中文标点之间残留的空格。
    t = t.replaceAll(
        RegExp(
            r'(?<=[\u4e00-\u9fa5，。、；：！？）》」』】])[ \t]+(?=[，。、；：！？）》」』】])'),
        '');
    return t;
  }

  /// 取正文长度的粗判：太短的一定是没抓到正文。
  ///
  /// 调用方在 throw 之前先过这一条，错误信息里会说"正文过短"而不是
  /// 让用户面对一屏空白。
  static bool looksLikeBody(String s, {int minLen = 60}) {
    final t = s.trim();
    if (t.length < minLen) return false;
    // 去掉空白和数字后剩下的字符太稀疏 = 不是正文（可能是一张时间表或一串编号）。
    final meaningful = t.replaceAll(RegExp(r'[\s0-9]'), '');
    return meaningful.length >= minLen ~/ 3;
  }
}
