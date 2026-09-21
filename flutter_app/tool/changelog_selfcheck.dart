// 分模块更新公告内核的自检（纯 Dart VM，零依赖）。
//
// 跑法（在 flutter_app/ 目录下）：
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json tool/changelog_selfcheck.dart
//
// ★ 本文件最要紧的一条是**跨文件一致性**：`ClogModules.all` 是从
//   `lib/main.dart` 的模块注册表抄过来的，两边一旦漂移，用户在"某个模块"里
//   就永远看不到自己的公告（而且不报错、只是静默为空）。
//   所以这里直接**读 main.dart 源码文本**逐名核对 —— 不 import（main.dart 依赖
//   flutter，VM 跑不起来），只做文本比对，这也正是当初 agent_proto 自检的做法。
import 'dart:io';

import 'package:thirdhub_app/core/changelog_logic.dart';

int _pass = 0, _fail = 0;
final List<String> _fails = <String>[];

void _ok(bool c, String m) {
  if (c) { _pass++; } else { _fail++; _fails.add(m); print('  ✗ $m'); }
}

void _eq(Object? a, Object? b, String m) =>
    _ok(a == b, m + '（期望 ${b is String ? '"$b"' : b}，实际 ${a is String ? '"$a"' : a}）');

ClogRow _row(String v, List<String> items, [String date = '2026-01-01']) =>
    ClogRow(v: v, date: date, items: items);

void main() {
  print('== 1. 模块名清单与 main.dart 注册表一致（跨文件防漂移）==');
  final File mainDart = File('lib/main.dart');
  if (!mainDart.existsSync()) {
    print('  ! 找不到 lib/main.dart —— 必须在 flutter_app/ 目录下运行本自检');
    _fail++;
    _fails.add('lib/main.dart 不可读');
  } else {
    final String src = mainDart.readAsStringSync();
    final List<String> missing = <String>[];
    for (final String m in ClogModules.all) {
      // main.dart 的注册表长这样：  '端网': const ModuleDef('端网', …
      // 用"键名 + 引号"双重锚定，避免子串误命中（'日历' ⊂ '家庭日历'）
      if (!src.contains("'$m': ModuleDef") && !src.contains("'$m': const ModuleDef")) {
        missing.add(m);
      }
    }
    _ok(missing.isEmpty, 'ClogModules.all 里每个模块名都能在 main.dart 找到注册项；缺：$missing');
    // 反向：main.dart 里注册了、但我们表里没有的模块（会让那个模块永远没有公告）
    final RegExp re = RegExp(r"'([^']{1,12})':\s*(?:const\s+)?ModuleDef\(");
    final Set<String> declared = <String>{};
    for (final Match m in re.allMatches(src)) {
      declared.add(m.group(1)!);
    }
    final List<String> notCovered = <String>[
      for (final String d in declared)
        if (!ClogModules.all.contains(d)) d,
    ]..sort();
    _ok(notCovered.isEmpty, 'main.dart 里注册的模块都进过 ClogModules.all；漏：$notCovered');
    print('  · main.dart 注册模块 ${declared.length} 个 / 本表 ${ClogModules.all.length} 个');
  }
  _ok(!ClogModules.all.contains(ClogModules.global), '兜底专题名「全局」不混在模块清单里');

  print('\n== 2. 模块名自身就是最强关键词 ==');
  _ok(ClogModules.modulesOf('小说模块加了书架批量管理').contains('小说'), '中文模块名子串命中');
  _ok(ClogModules.modulesOf('漫画自动识别修复').contains('漫画'), '漫画命中');
  _ok(ClogModules.modulesOf('新增 端网 模块，端间互通').contains('端网'), '端网命中');
  _ok(vOf('AI', 'AI 助手改用真智能体').contains('AI'), 'AI 命中');

  print('\n== 3. ★ASCII 关键词要按词边界匹配（防 AI 命中 MAIN/REPAIR）==');
  _ok(vOf('AI', 'AI 图标本地化').contains('AI'), '独立出现的 AI 命中');
  _ok(!vOf('AI', 'MAIN 函数重构').contains('AI'), '★MAIN 里的 AI 不算命中');
  _ok(!vOf('AI', 'REPAIR 逻辑调整').contains('AI'), '★REPAIR 里的 AI 不算命中');
  _ok(vOf('AI', 'ai 小写单独出现').contains('AI'), '★大小写不敏感：小写 ai 也算');
  _ok(!vOf('AI', 'container 容器').contains('AI'), '★container 里的 ai 不算');
  _ok(!vOf('AI', 'PDFAIX 测试').contains('AI'), '★PDFAIX 里的 AI 不算（右侧也要求边界）');

  print('\n== 3b. ★同名歧义：模块名本身在技术语境里是另一个词 ==');
  // 「广播」是内容模块，但"局域网广播 / UDP 广播"是网络术语 —— 必须不误判
  _ok(!vOf('广播', '局域网广播优化').contains('广播'), '★局域网广播 ≠ 广播模块');
  _ok(!vOf('广播', 'UDP 广播逐网卡定向').contains('广播'), '★UDP 广播 ≠ 广播模块');
  _ok(vOf('端网', '局域网广播优化').contains('端网'), '★反而应归到端网（弱词兜底）');
  _ok(vOf('广播', '广播模块新增电台分类').contains('广播'), '真的讲广播模块时仍然命中');
  _ok(!vOf('笔记', '笔记本电脑端适配').contains('笔记'), '★笔记本电脑 ≠ 笔记模块');
  // 「我的」是高频口语词，刻意不参与"模块名当关键词"这一轮
  _ok(!vOf('我的', '加载我的数据时卡住').contains('我的'), '★"我的"不作关键词（否则全命中）');
  _ok(vOf('我的', '个人资料页未登录放登录卡').contains('我的'), '但「个人资料」「登录」仍能归到我的');

  print('\n== 4. 同义词能把"字面不含模块名"的改动归对 ==');
  _ok(vOf('端网', '插件登录账号后即可接入').contains('端网'), '「插件」→ 端网');
  _ok(vOf('AI', '大模型列表逐家更新').contains('AI'), '「大模型」→ AI');
  _ok(vOf('AI', '智能体工具调用循环').contains('AI'), '「智能体」「工具调用」→ AI');
  _ok(vOf('搜索', '书源导入转换器').contains('搜索'), '「书源」→ 搜索');
  _ok(vOf('我的', '头像同步字段错位修复').contains('我的'), '「头像」→ 我的');

  print('\n== 5. 强关键词命中时就不再看弱词（防噪音淹没）==');
  // 「导入」是 文件 的弱关键词，但 '小说导入自动识别' 已强命中 小说 ⇒ 不该再喂给文件
  final Set<String> mixed = ClogModules.modulesOf('小说导入自动识别');
  _ok(mixed.contains('小说'), '强命中 小说');
  _ok(!mixed.contains('文件'), '★强命中后不再叠加弱词（否则每条"导入"都污染文件模块）');
  // 纯弱词命中：一条强关键词都不沾时才兜底
  _ok(ClogModules.modulesOf('局域网广播优化').contains('端网'), '纯弱词「局域网」兜底');
  // 一条也归不上 → 空集合（交给「全局」）
  _eq(ClogModules.modulesOf('LICENSE 换成 MIT').isEmpty, true, '★哪条模块都不沾 → 空集合');
  _ok(ClogModules.isGlobal('重写发版四通道脚本'), '「发版通道」算全局');
  _ok(ClogModules.isGlobal('签名密钥轮换流程'), '「签名密钥」算全局');

  print('\n== 6. 多模块归属（不强行二选一）==');
  final Set<String> both = ClogModules.modulesOf('AI 助手支持调用插件');
  _ok(both.contains('AI') && both.contains('端网'), '★一条同时动 AI 与端网的改动，两个模块都要能看到它');

  print('\n== 7. pick：按模块切流水账 ==');
  final List<ClogRow> rows = <ClogRow>[
    _row('4.44.0', <String>['端网模块新增插件体系', 'AI 支持指挥插件', 'LICENSE 换成 MIT', '小说书架批量管理']),
    _row('4.43.0', <String>['Agent 协议清账', '漫画自动识别']),
    _row('4.42.0', <String>['书源导入提速']),
  ];
  final ModClog peer = ClogModules.pick(rows, '端网');
  _eq(peer.rows.length, 1, '端网只出现在 4.44.0 一条版本里');
  // 「端网模块新增插件体系」+「AI 支持指挥插件」——两条都提到插件，都该进端网
  _eq(peer.itemCount, 2, '端网条目数 2（一条改动可被多个模块同时看到）');
  _eq(peer.latestVersion, '4.44.0', '最新版本号');
  _ok(!peer.empty, '非空');
  final ModClog novel = ClogModules.pick(rows, '小说');
  _eq(novel.rows.length, 1, '小说 1 条');
  _eq(ClogModules.pick(rows, '相册').empty, true, '★没有记录的模块 → 空（UI 就不该给它入口）');
  _eq(ClogModules.pick(rows, '端网', limit: 1).rows.length, 1, 'limit 生效');
  _eq(ClogModules.pick(rows, '搜索').rows.length, 1, '搜索命中 4.42.0 的书源条目');
  final ModClog ai = ClogModules.pick(rows, 'AI');
  _eq(ai.itemCount, 2, 'AI 命中 4.44.0 的"AI 支持指挥插件"与 4.43.0 的 Agent 协议');

  print('\n== 8. 全局兜底不丢账 ==');
  final ModClog g = ClogModules.globals(rows);
  _ok(g.itemCount >= 1, '「LICENSE 换成 MIT」进了全局（实际 ${g.itemCount} 条）');
  _ok(g.rows.every((ClogRow r) => r.items.isNotEmpty), '★全局里不留空版本条目');
  _ok(g.rows.first.items.contains('LICENSE 换成 MIT'), '全局条目内容正确');

  print('\n== 9. present：只列真有记录的模块 ==');
  final List<String> p = ClogModules.present(rows);
  _ok(p.contains('端网') && p.contains('小说') && p.contains('漫画'), '有记录的都在');
  _ok(!p.contains('相册'), '★无记录的不在（避免 60 个空壳模块）');
  _ok(p.last == ClogModules.global, '全局排在最后');

  print('\n== 10. brief / itemsOf ==');
  final String b = ClogModules.brief(rows, '端网');
  _ok(b.startsWith('v4.44.0'), 'brief 带版本号');
  _ok(b.contains('端网模块'), 'brief 带首条内容');
  _eq(ClogModules.brief(rows, '相册'), '', '★无记录时 brief 返回空串（不是 "v："）');
  final List<String> its = ClogModules.itemsOf(rows, '端网');
  _eq(its.length, 2, 'itemsOf 条目数');

  print('\n== 11. 一条都不漏：每个条目至少能落到某个桶里 ==');
  var accounted = 0, total = 0;
  for (final ClogRow r in rows) {
    for (final String it in r.items) {
      total++;
      final Set<String> mods = ClogModules.modulesOf(it);
      if (mods.isNotEmpty || ClogModules.isGlobal(it)) accounted++;
    }
  }
  _eq(accounted, total, '★所有条目要么归模块、要么进全局（不存在"消失的条目"）');

  print('\n────────────────────────────────────────');
  print('PASS $_pass   FAIL $_fail');
  if (_fail > 0) {
    print('\n失败项:');
    for (final String f in _fails) { print('  · $f'); }
    exit(1);
  }
  print('\n✅ 全部通过');
}

/// 小助手：某条文本归到哪些模块。
Set<String> vOf(String _ignored, String text) => ClogModules.modulesOf(text);
