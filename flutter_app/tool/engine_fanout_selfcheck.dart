// 「多资料库并行搜索」（任务 #193）的纯 Dart 自检。
//
// 覆盖三件事：
//   ① `engine_fanout.dart` 的规则层 —— 谁能并行、怎么归一、怎么去重合并；
//   ② 接线 —— `EngineDirect.searchPage` 是不是真的走了并行路径（防"只写了一半"）；
//   ③ 文案 —— 新开关的 3 个键在 6 种语言里都有，且不含内容来源类禁用词。
//
// 为什么去重要单独测：合并两个列表看起来是"拼接去重"，实际有三处容易写错 ——
//   · 按**返回顺序**合并（并行返回顺序不定 → 列表每次刷新都跳）；
//   · 只看标题就判重（同标题不同作者是两本书，会被并掉）；
//   · 只看「标题+作者」精确相等（一台有作者一台没有时，同一本书会重复出现两条）。
// 这三条都在下面有断言，改错了立刻红。
//
// 运行：`dart run tool/engine_fanout_selfcheck.dart`（退出码非 0 = 有断言失败）

import 'dart:io';

import 'package:thirdhub_app/core/engine_fanout.dart';
import 'package:thirdhub_app/core/i18n_ui_words.dart';

int pass = 0, fail = 0;
void ok(bool cond, String what) {
  if (cond) {
    pass++;
  } else {
    fail++;
    print('FAIL  $what');
  }
}

EngineNode node(String url,
        {int port = 0, List<String> caps = const [], String name = ''}) =>
    EngineNode(url: url, name: name, caps: caps, port: port);

Map<String, dynamic> item(String title, [String author = '']) =>
    <String, dynamic>{'title': title, 'author': author};

void main() {
  print('== 1. 地址归一化 ==');
  ok(normalizeUrl('http://192.168.1.5:1235/') == 'http://192.168.1.5:1235',
      '结尾斜杠被去掉');
  ok(normalizeUrl('HTTP://Box.LAN:1235') == 'http://box.lan:1235',
      'scheme 与 host 转小写、端口保留');
  ok(normalizeUrl('http://box.lan:1235/Thp/M/X') == 'http://box.lan:1235/Thp/M/X',
      '路径大小写必须保留');
  ok(normalizeUrl('  http://a:1  ') == 'http://a:1', '首尾空白被裁掉');
  ok(normalizeUrl('') == '', '空串仍为空串');
  ok(normalizeUrl('http://[240e::1]:1235/') == 'http://[240e::1]:1235',
      'IPv6 字面量不被破坏、尾部斜杠去掉');
  ok(normalizeUrl('192.168.1.5:1235') == '192.168.1.5:1235',
      '不带 scheme 的写法原样小写');
  ok(node('http://A:1235/').key == node('http://a:1235').key,
      '同一台资料库的不同写法 → 同一个去重键');

  print('== 2. 模块判定（能力标签优先，端口只兜底） ==');
  ok(node('u1', port: 1235, caps: ['m:comic']).supports('comic'),
      'm:comic 认漫画');
  ok(!node('u1', port: 1235, caps: ['m:comic']).supports('music'),
      'm:comic 不认音乐');
  // ★这条是「漫画页搜出音乐」那个老 bug 的复现闸：标签存在时端口不得翻盘。
  ok(!node('u1', port: 1234, caps: ['m:comic']).supports('novel'),
      '有 m: 标签时端口兜底不得翻盘（漫画资料库跑在 1234 端口仍是漫画）');
  ok(node('u2', port: 1235).supports('comic'), '无标签时按端口兜底认漫画');
  ok(!node('u2', port: 9999).supports('comic'), '无标签且端口未知 → 不认任何模块');
  ok(node('u3', caps: ['m:novel', 'stream-search']).modules.length == 1,
      '只有 m: 前缀算模块声明');
  ok(node('u3', caps: ['m:novel', 'stream-search']).modules.first == 'novel',
      '模块名解析正确');
  ok(!node('u4', port: 9527, caps: ['library']).supports('novel'),
      '资源库不提供内容（不参与并行）');
  ok(!node('u4', port: 9527, caps: ['library']).supports('all'),
      '资源库连 all 也不认');
  ok(node('u5', port: 1234, caps: ['m:novel']).supports('all'),
      'all = 不限类型，内容资料库都算');
  ok(node('  ', port: 1234).isValid == false, '空地址不算有效实例');

  print('== 3. 挑并行目标 ==');
  final all = <EngineNode>[
    node('http://a:1234', port: 1234, caps: ['m:novel'], name: 'A'),
    node('http://b:9527', port: 9527, caps: ['library'], name: 'L'),
    node('http://c:1235', port: 1235, caps: ['m:comic'], name: 'C'),
    node('http://c:1235/', port: 1235, caps: ['m:comic'], name: 'C2'),
    node('http://d:1236', port: 1236, name: 'D'),
    node('', port: 1234, caps: ['m:novel'], name: 'BAD'),
  ];
  final comics = pickEngines('comic', all);
  ok(comics.length == 1 && comics.first.url == 'http://c:1235',
      '同地址不同写法只留一台');
  ok(comics.first.name == 'C', '同地址保留先出现的那台（顺序稳定）');
  ok(pickEngines('novel', all).length == 1,
      '空地址被丢弃、资源库被剔除（只剩 a）');
  final musics = pickEngines('music', all);
  ok(musics.length == 1 && musics.first.url == 'http://d:1236',
      '无标签的老资料库按端口被认出来');
  ok(pickEngines('video', all).isEmpty, '没有影视资料库时返回空表');
  ok(pickEngines('comic', <EngineNode>[]).isEmpty, '空输入不炸');

  print('== 4. 标题/作者归一 ==');
  ok(normalizeText('斗破 苍穹！') == '斗破苍穹', '空格与标点被吃掉');
  ok(normalizeText('ＡＢＣ') == 'abc', '全角字母折半角并小写');
  ok(normalizeText('《三体》') == '三体', '书名号被吃掉');
  ok(normalizeText('   ') == '', '全空白归一成空串');
  ok(dedupeKey(item('三体', '刘慈欣')) == '三体|刘慈欣', '键 = 标题|作者');
  ok(dedupeKey(item('', '某人')) == '', '标题为空 → 空键（不参与判重）');
  ok(dedupeKey(item('三体', '刘慈欣')) != dedupeKey(item('三体', '别的作者')),
      '同标题不同作者是两本书');

  print('== 5. 合并去重 ==');
  // ① 两台各自返回，其中一本重复（标点/空格不同）→ 只留一条
  final m1 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('三体', '刘慈欣'), item('球状闪电', '刘慈欣')]),
    FanoutPage(url: 'http://b', items: [item('三体 ', '刘慈欣'), item('活着', '余华')]),
  ]);
  ok(m1.items.length == 3, '重复条目被合并（3 条）');
  ok(m1.dropped == 1, '重复计数为 1');
  ok(m1.items.first['title'] == '三体', '保留先出现的那条（第一台的）');
  ok(m1.items[2]['title'] == '活着', '第二台的新条目追加在后面');
  ok(m1.okCount == 2, '两台都算取到结果');

  // ② 顺序按输入页顺序，不按"谁先返回"
  final m2 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('A1'), item('A2')]),
    FanoutPage(url: 'http://b', items: [item('B1')]),
  ]);
  ok(m2.items.map((e) => e['title']).join(',') == 'A1,A2,B1',
      '合并顺序 = 目标顺序（并行返回顺序不稳定，不能按完成顺序铺）');

  // ③ 一台有作者、一台没有 → 同一本书（只留一条）
  final m3 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('三体', '刘慈欣')]),
    FanoutPage(url: 'http://b', items: [item('三体')]),
  ]);
  ok(m3.items.length == 1, '一台缺作者时仍判为同一本（不会重复出现两条）');

  // ④ 反过来：先来的缺作者、后来的有作者
  final m4 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('三体')]),
    FanoutPage(url: 'http://b', items: [item('三体', '刘慈欣')]),
  ]);
  ok(m4.items.length == 1, '先缺作者后有作者也判重');

  // ⑤ 同标题不同作者 → 两条都留
  final m5 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('同名书', '甲')]),
    FanoutPage(url: 'http://b', items: [item('同名书', '乙')]),
  ]);
  ok(m5.items.length == 2, '同标题不同作者都保留');

  // ⑥ 空标题不参与判重（宁可多一条，也别把不同的东西并掉）
  final m6 = mergeFanout([
    FanoutPage(url: 'http://a', items: [
      <String, dynamic>{'title': ''},
      <String, dynamic>{'title': ''},
    ]),
  ]);
  ok(m6.items.length == 2, '没标题的条目一律保留');

  // ⑦ 一台挂掉：结果照样出来，失败被记下来
  final m7 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('三体', '刘慈欣')], total: 10, hasMore: true),
    FanoutPage.failed('http://b', Exception('超时')),
  ]);
  ok(m7.items.length == 1, '一台失败不影响另一台的结果');
  ok(m7.okCount == 1, '成功台数为 1');
  ok(m7.failures.length == 1 && m7.failures['http://b']!.contains('超时'),
      '失败原因被记录下来');
  ok(m7.hasMore == true, 'hasMore 取或（还有一台说还有）');

  // ⑧ 全挂：okCount 0，错误文案取第一台的真实原因
  final m8 = mergeFanout([
    FanoutPage.failed('http://a', Exception('连接被拒绝')),
    FanoutPage.failed('http://b', Exception('超时')),
  ]);
  ok(m8.okCount == 0, '全挂时 okCount 为 0');
  ok(m8.errorText.contains('连接被拒绝'), '错误文案带真实原因，不是"都失败了"');
  ok(m8.items.isEmpty, '全挂时没有条目');

  // ⑨ total 扣掉重复、且不小于条目数
  final m9 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('三体', '刘慈欣')], total: 30),
    FanoutPage(url: 'http://b', items: [item('三体', '刘慈欣')], total: 20),
  ]);
  ok(m9.total == 49, '总数 = 两台之和 - 重复数（50-1）');
  ok(m9.total >= m9.items.length, '总数不会小于实际条目数');
  final m10 = mergeFanout([
    FanoutPage(url: 'http://a', items: [item('x'), item('y')], total: 1),
  ]);
  ok(m10.total == 2, '引擎报的 total 偏小时按实际条目数兜底');

  // ⑩ truncated 取或
  final m11 = mergeFanout([
    const FanoutPage(url: 'http://a', truncated: true),
    const FanoutPage(url: 'http://b'),
  ]);
  ok(m11.truncated == true, 'truncated 取或');

  print('== 6. 接线（防"只写了一半"） ==');
  final ed = File('lib/core/engine_direct.dart').readAsStringSync();
  final edp = File('lib/core/engine_direct_page.dart').readAsStringSync();
  ok(ed.contains("import 'engine_fanout.dart';"), 'EngineDirect 已引入并行规则层');
  ok(ed.contains('static List<String> fanoutTargets('), '并行目标表存在');
  ok(ed.contains('mergeFanout(pages)'), 'searchPage 真的调用了合并去重');
  ok(ed.contains('Future.wait(['), '并行是真的并发（Future.wait），不是逐个串行');
  ok(ed.contains('static Future<SearchPage> _searchPageAt('),
      '单台请求被抽成 _searchPageAt');
  ok(ed.contains('_get(path, false, _searchTimeoutSec, base)'),
      '每台资料库各自带 base 发请求');
  ok(ed.contains('String? base]) async {'), '_get 支持指定目标资料库');
  ok(ed.contains('if (retried || base != null || !_isNetErr(e)) rethrow;'),
      '并行里某台网络错误不触发换地址（不动主连接）');
  ok(ed.contains('_moduleEngines'), '多台路由表存在');
  ok(ed.contains('for (final mod in kContentModules)'),
      '刷新路由时按模块收齐所有资料库');
  ok(ed.contains('static bool _fanout = true;'), '并行开关默认开');
  ok(ed.contains("p.getBool('engine_fanout')"), '开关状态会被读回');
  ok(edp.contains('EngineDirect.setFanout('), '连接页能改开关');
  ok(edp.contains('EngineDirect.fanoutCount('), '连接页显示能并行几个模块');

  print('== 7. 新文案（6 语言 + 禁用词） ==');
  const keys = [
    '多资料库并行',
    '同一模块发现 2 台以上资料库后自动生效',
    '已有 {n} 个模块可并行搜索',
  ];
  const locales = ['en', 'ja', 'fr', 'ru', 'es', 'ar'];
  ok(i18nUiWords13.length == 6, '第十三批覆盖 6 种语言');
  for (final loc in locales) {
    final t = i18nUiWords13[loc];
    ok(t != null, '$loc 有字典块');
    for (final k in keys) {
      final v = t?[k];
      ok(v != null && v.trim().isNotEmpty, '$loc 有译文：$k');
      if (v != null) {
        ok(!v.contains('{n}') || k.contains('{n}'),
            '$loc 无多余占位符：$k');
      }
    }
  }
  final allText = [
    for (final t in i18nUiWords13.values) ...t.values, ...keys
  ].join('|');
  for (final banned in ['引擎', '书源', '图源', '换源']) {
    ok(!allText.contains(banned), '新文案不含禁用词「$banned」');
  }

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exitCode = 1;
}
