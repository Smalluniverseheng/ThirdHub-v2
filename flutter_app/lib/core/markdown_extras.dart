// Markdown 富渲染扩展（2026-10-17）
//
// ★背景：对齐 Kimi 的对话渲染 —— 它有、我们此前没有的两个关键能力：
//   ① 代码块：语言标签 + 一键复制 + 超长折叠 + 横向滚动（长命令不换行错位）
//   ② 表格：宽表**横向滚动**（flutter_markdown 默认会把宽表压扁成一团）
//
// 实现方式：用 flutter_markdown 的 `builders` 钩子替换 `pre`/`table` 两种元素。
// 不 fork 上游、不改 MarkdownBody 内部 —— 上游升级也不受影响。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import 'haptic.dart';

/// 代码块：顶部一条「语言 + 复制」栏，代码本体横向滚动，超过 18 行折叠。
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder({this.accent});

  final Color? accent;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // `<pre><code class="language-dart">…</code></pre>`
    String lang = '';
    String code = element.textContent;
    if (element.children != null && element.children!.isNotEmpty) {
      final child = element.children!.first;
      if (child is md.Element) {
        final cls = child.attributes['class'] ?? '';
        if (cls.startsWith('language-')) lang = cls.substring(9);
        code = child.textContent;
      }
    }
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return _CodeBlock(lang: lang, code: code, accent: accent);
  }
}

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.lang, required this.code, this.accent});
  final String lang;
  final String code;
  final Color? accent;
  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _expanded = false;
  bool _copied = false;

  bool get _long => widget.code.split('\n').length > 18;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    Haptic.tap();
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final accent = widget.accent ?? cs.primary;
    final bg = dark ? const Color(0xFF12141C) : const Color(0xFFF7F6FA);
    final border = dark ? Colors.white10 : const Color(0xFFEBE8F2);
    final fg = dark ? const Color(0xFFE6E6EE) : const Color(0xE6000000);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ── 顶部栏：语言 + 复制 ──
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: border, width: 0.6)),
          ),
          child: Row(children: [
            Text(
              widget.lang.isEmpty ? '代码' : widget.lang.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: dark ? Colors.white38 : Colors.black38,
              ),
            ),
            const Spacer(),
            if (_long)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () {
                  Haptic.tap();
                  setState(() => _expanded = !_expanded);
                },
                child: Text(_expanded ? '收起' : '展开全部',
                    style: TextStyle(fontSize: 11, color: accent)),
              ),
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _copy,
              icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 13, color: _copied ? Colors.green : accent),
              label: Text(_copied ? '已复制' : '复制',
                  style: TextStyle(
                      fontSize: 11,
                      color: _copied ? Colors.green : accent)),
            ),
          ]),
        ),
        // ── 代码本体（横向滚动；长代码折叠）──
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: (_long && !_expanded) ? 320 : double.infinity),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: SelectableText(
              widget.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
                color: fg,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// 表格：宽表横向滚动（否则会被压成条状，中文列直接换行错位）。
///
/// 做法：把 md 的 thead/tbody 自己解析成 Flutter `Table`，外面套一层横向
/// `SingleChildScrollView`。列宽用 `IntrinsicColumnWidth`（按内容自适应，
/// 中文长文本不会被挤成竖排），最大列宽兜个 260 防止单列吃掉整屏。
class TableBuilder extends MarkdownElementBuilder {
  TableBuilder({this.accent});
  final Color? accent;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final rows = <List<String>>[];
    var hasHeader = false;
    for (final sec in element.children ?? const <md.Node>[]) {
      if (sec is! md.Element) continue;
      final isHead = sec.tag == 'thead';
      for (final tr in sec.children ?? const <md.Node>[]) {
        if (tr is! md.Element || tr.tag != 'tr') continue;
        final cells = <String>[];
        for (final c in tr.children ?? const <md.Node>[]) {
          if (c is md.Element && (c.tag == 'td' || c.tag == 'th')) {
            cells.add(c.textContent.trim());
          }
        }
        if (cells.isEmpty) continue;
        if (isHead) hasHeader = true;
        rows.add(cells);
      }
    }
    if (rows.isEmpty) return null;
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    if (cols == 0) return null;
    return _MdTable(rows: rows, cols: cols, hasHeader: hasHeader, accent: accent);
  }
}

class _MdTable extends StatelessWidget {
  const _MdTable({
    required this.rows,
    required this.cols,
    required this.hasHeader,
    this.accent,
  });
  final List<List<String>> rows;
  final int cols;
  final bool hasHeader;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final border = dark ? Colors.white24 : const Color(0xFFE4E0EE);
    final fg = dark ? const Color(0xFFE6E6EE) : const Color(0xE6000000);
    final headBg = dark
        ? Colors.white.withValues(alpha: 0.05)
        : const Color(0xFFF7F6FA);
    final headColor = accent ?? cs.primary;

    TableRow rowOf(List<String> r, {required bool head}) => TableRow(
          decoration: BoxDecoration(color: head ? headBg : null),
          children: [
            for (var i = 0; i < cols; i++)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Text(
                    i < r.length ? r[i] : '',
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.45,
                      fontWeight: head ? FontWeight.w700 : FontWeight.w400,
                      color: head ? headColor : fg,
                    ),
                  ),
                ),
              ),
          ],
        );

    final headRows = <TableRow>[];
    final bodyRows = <TableRow>[];
    for (var i = 0; i < rows.length; i++) {
      final head = hasHeader && i == 0;
      (head ? headRows : bodyRows).add(rowOf(rows[i], head: head));
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: 0.6),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 横向滚动提示：宽表时右下角有淡渐变，用户知道可以滑
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minWidth: MediaQuery.of(context).size.width * 0.6),
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: border, width: 0.6),
            children: [...headRows, ...bodyRows],
          ),
        ),
      ),
    );
  }
}
