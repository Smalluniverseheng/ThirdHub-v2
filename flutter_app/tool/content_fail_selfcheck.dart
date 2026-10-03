// 正文失败处理自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/content_fail_selfcheck.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// 为什么必须有这条闸门：
// 用户报的问题是「搜索结果有封面、简介，但点进去提示正文未加载 / 获取正文失败」。
// 取证结论（模拟器 10 本样本）分层如下：
//   · 目录全部正常，正文 5/10 为空；失败的 5 本**全来自同一个源**，可读的 5 本全来自
//     另一个源；用书名重搜后同名书在 7 个源里有 4 个能读出正文。
//   ⇒ 根因是**部分源的正文规则失效**（站点改版 / 需登录），不是链路坏。
//   ⇒ 但旧实现让用户「卡住 + 看不懂 + 没出口」，那是产品缺陷：
//       ① 阅读器 `catch (e) { text = '错误: $e'; }` —— 把异常当正文显示；
//       ② 引擎 `getBookContent` 「先空等 30 秒、再判 book==null」——必然空等满 30 秒。
//
// 本自检盯的就是这两类回归：它们都是**静默**的（不崩、不报错、功能"在"），
// 靠人眼看代码是看不出来的 —— 必须有能拦住它们的断言。
//
// 为什么用源码断言而不是行为断言：本仓的「行为」跨进程（引擎 App + Flutter App +
// 模拟器），纯 Dart VM 跑不起来。已有的做法是**用断言把关键源码形状钉死**，
// 真正的行为验证靠 `tool/engine_autopull_selfcheck.dart` 那类迷你模型 + 真机截图。
// ⚠ 本自检的定位是「防回归」，不是「证明功能可用」——别把它当成后者。
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

int pass = 0, fail = 0;
void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name${extra.isEmpty ? '' : '  → $extra'}');
  }
}

/// 取出 `anchor` 之后紧跟的那对花括号包起来的块原文（含 `{ }`）。
///
/// ★锚点必须**包含其上的注解/修饰符**，否则取到的是参数块而不是函数体
///   （本项目已踩过：`{bool restart = false}` 被当成函数体，断言静默假绿）。
String? blockAfter(String src, String anchor) {
  final i = src.indexOf(anchor);
  if (i < 0) return null;
  final b = src.indexOf('{', i);
  if (b < 0) return null;
  var depth = 0;
  for (var j = b; j < src.length; j++) {
    final ch = src[j];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return src.substring(b, j + 1);
    }
  }
  return null;
}

/// 去掉行注释与块注释。
///
/// ★为什么需要：本自检有多条断言是「某段**代码**已经不存在」型，
///   而文件里为了讲清改动原因，**注释里会引用旧代码原文**（如
///   `// 旧实现只有 text = '错误: $e'`）。不剥注释就会把"注释提到了旧写法"
///   误判成"旧写法还在"—— 这类假 FAIL 会让闸门被人当成噪音而放弃。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    if (src.startsWith('//', i)) {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (src.startsWith('/*', i)) {
      i += 2;
      while (i < src.length && !src.startsWith('*/', i)) {
        i++;
      }
      i += 2;
    } else {
      out.write(src[i]);
      i++;
    }
  }
  return out.toString();
}

void main() {
  final readerRaw = File('lib/core/novel_reader.dart').readAsStringSync();
  final mainRaw = File('lib/main.dart').readAsStringSync();
  // 「代码形状」类断言一律在**剥掉注释**的源码上做，理由见 stripComments。
  final reader = stripComments(readerRaw);
  final main = stripComments(mainRaw);
  final bcPath =
      'D:/ai/reading-engine/app/src/main/java/io/legado/app/api/controller/BookController.kt';
  final bc = File(bcPath).existsSync() ? stripComments(File(bcPath).readAsStringSync()) : '';

  // ── §1 阅读器不再把异常当正文 ──
  print('== 1. 阅读器：失败必须是结构化状态，不是正文 ==');
  // ★下面这条断言的字符串里含 `$e` —— 必须用 raw 字符串（r'...'），
  //   否则 Dart 会把它当插值变量、编译期就报 "Undefined name 'e'"。
  ck(r"旧的 `text = '错误: $e'` 已删除",
      !reader.contains(r"text = '错误: "), '仍把异常写进正文');
  ck('有结构化失败态 _failKind', reader.contains('String? _failKind;'));
  ck('有失败详情 _failMsg', reader.contains('String? _failMsg;'));
  ck('失败时正文被清空（不与提示语混排）',
      RegExp(r"text\s*=\s*'';\s*\n\s*_failKind\s*=").hasMatch(reader));
  ck('build() 对失败态早退成独立页面',
      RegExp(r'if\s*\(\s*_failKind\s*!=\s*null\s*\)\s*return\s+_failView').hasMatch(reader));
  ck('有独立的失败页 _failView', reader.contains('Widget _failView(BuildContext c)'));

  // ── §2 失败原因分类：认稳定标记，也兼容旧引擎 ──
  print('== 2. 失败分类：稳定标记 + 旧引擎兜底 ==');
  final cls = blockAfter(reader, 'static String _classifyFail(');
  ck('能定位 _classifyFail（解析没跑偏）', cls != null);
  if (cls != null) {
    ck('认引擎 1.13.0 的 [SOURCE_EMPTY] 标记', cls.contains('SOURCE_EMPTY'));
    ck('认 [NEED_REGISTRATION] 标记', cls.contains('NEED_REGISTRATION'));
    // 旧引擎只会吐异常名/文案，没有标记 —— 少了这两条，升级前的老引擎会全落进 unknown
    ck('兼容旧引擎：ContentEmptyException', cls.contains('ContentEmpty'));
    ck('兼容旧引擎：内容为空', cls.contains('内容为空'));
    ck('区分引擎不可达（别让用户去换源）', cls.contains('engine_down'));
  }
  ck('失败分类有 5 类标题（_failTitle 走 tr）',
      blockAfter(reader, 'static String _failTitle(')?.contains('tr(') ?? false);

  // ── §3 三个出口：换源重搜 / 重试 / 返回 ──
  print('== 3. 出口：换源重搜 + 重试 + 返回 ==');
  ck('NovelReaderPage 接收 onSwapSource', reader.contains('final Future<void> Function()? onSwapSource;'));
  ck('NovelReaderPage 接收 sourceName（要告诉用户是哪个源坏了）',
      reader.contains('final String sourceName;'));
  ck('失败页提供「换源重搜」', reader.contains("tr('换源重搜')"));
  ck('失败页提供「重试本章」', reader.contains("tr('重试本章')"));
  ck('失败页提供「返回」', reader.contains("tr('返回')"));
  ck('重试会清掉失败缓存（否则永远拿同一份坏数据）',
      RegExp(r'chapCache\.remove\(idx\);\s*load\(\)').hasMatch(reader));
  ck('换源时有进行中状态（防连点）', reader.contains('bool _swapping = false;'));

  // ── §4 换章后这些能力不能丢 ──
  print('== 4. 翻章要带走 sourceName / onSwapSource ==');
  // ★goChapter 是 `=>` 表达式体、**自身没有大括号**，不能用 blockAfter()
  //   （它取 anchor 之后的第一个 `{`，会一路找到不相干的远处块 —— 断言假失败）。
  //   所以直接在**整个文件**上断言那两行确实存在。
  ck('goChapter 传递 sourceName', reader.contains('sourceName: widget.sourceName'));
  ck('goChapter 传递 onSwapSource', reader.contains('onSwapSource: widget.onSwapSource'));

  // ── §5 源健康度：复用既有 R-2，不另造一套 ──
  print('== 5. 成败记账（复用 R-2 SourceHealth）==');
  ck('阅读器 import 了 pro_reading（SourceHealth）',
      RegExp(r"import\s+'pro_reading\.dart'").hasMatch(reader));
  final rec = blockAfter(reader, 'void _recordHealth(');
  ck('能定位 _recordHealth', rec != null);
  if (rec != null) {
    ck('记账走 SourceHealth.record（不新建统计）', rec.contains('SourceHealth.record'));
    // 「未知失败」多半是网络抖动，记进源健康度会把好源误判成坏源
    ck('unknown 不记账（网络抖动不该拉低源健康度）',
        rec.contains("_failKind == 'unknown'"));
  }
  final load = blockAfter(reader, 'Future<void> load() async');
  ck('能定位 load()', load != null);
  if (load != null) {
    // 记账的实际形态是 `_recordHealth(true/false, ms)` —— 成功与失败**都要**记：
    // 只记失败的话健康度是单向的，SourceHealth.best 排序会永远偏向"没被记录过"的源。
    ck('成功也记账（否则健康度只统计失败，排序永远偏）',
        load.contains('_recordHealth(true,'));
    ck('失败记 SourceHealth', load.contains('_recordHealth(false,'));
    ck('HTTP 200 但正文为空也算失败（旧实现只显示「本章无内容」，用户同样没出口）',
        RegExp(r"_failKind\s*=\s*'source_empty'").hasMatch(load));
  }

  // ── §6 换源重搜的实现：以书名重搜 → 换源 → 排序 → 进入 ──
  print('== 6. 换源重搜（main.dart _swapSourceAndRead）==');
  final swap = blockAfter(main, 'Future<void> _swapSourceAndRead() async');
  ck('能定位 _swapSourceAndRead', swap != null);
  if (swap != null) {
    ck('用书名重新搜索', swap.contains('EngineDirect.searchPage('));
    ck('传入的就是书名', RegExp(r"searchPage\('novel',\s*q").hasMatch(swap));
    // 先按书名完全一致筛，再排除同源 —— 顺序不能反：
    // 若先排除同源，会把「同名但坏源」和「不同名但好源」混在一起，可能跳到不相干的书。
    ck('先按书名完全一致筛', swap.contains('sameName'));
    ck('再排除同源（必须是"换"源）', swap.contains('other'));
    ck('按源健康度排序（复用 SourceHealth.best）', swap.contains('SourceHealth.best'));
    ck('用 pushReplacement 重开（不堆页面栈）', swap.contains('pushReplacement'));
    // 挑不到就明说，绝不硬跳一个不相干的书 —— 那是更糟的体验
    ck('挑不到时明确提示、不硬跳', swap.contains('没有搜到'));
  }
  ck('EngineItemPage 暴露 sourceName', main.contains('String get sourceName =>'));
  ck('EngineItemPage 打开阅读器时传了 sourceName', main.contains('sourceName: sourceName,'));
  ck('EngineItemPage 打开阅读器时传了 onSwapSource',
      main.contains('onSwapSource: _swapSourceAndRead,'));

  // ── §7 引擎侧：不该再空等，源失效要能识别 ──
  print('== 7. 引擎侧（BookController.getBookContent）==');
  if (bc.isEmpty) {
    print('  SKIP  未找到引擎源码 ' + bcPath);
  } else {
    final gc = blockAfter(bc, 'fun getBookContent(');
    ck('能定位 getBookContent', gc != null);
    if (gc != null) {
      // ★核心回归点：旧的「while(chapter==null && wait<30) delay(1000)」
      ck('不再有 30 次 1 秒空等（书不在库时必然等满 30 秒）',
          !RegExp(r'wait\s*<\s*30').hasMatch(gc),
          '仍有 wait<30 的空等循环');
      ck('书不在库立刻返回并说明', gc.contains('NEED_REGISTRATION'));
      ck('缺章节时先补建目录再取', gc.contains('refreshToc'));
      ck('ContentEmptyException 单独标记为 [SOURCE_EMPTY]', gc.contains('SOURCE_EMPTY'));
      ck('ContentEmptyException 有 import',
          bc.contains('import io.legado.app.exception.ContentEmptyException'));
    }
  }

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) {
    print('\n✅ 正文失败处理完好：说清哪个来源坏了 + 给「换源重搜」出口 + 不再空等 30 秒');
  }
  /* ★失败必须非零退出：CI 只看退出码，只打印 FAIL 而 return 0 的闸门形同虚设
     （2026-09-28 实测：本仓 10 个自检里 8 个从不 exit()，前九条闸门全是装饰）。 */
  if (fail > 0) exit(1);
}
