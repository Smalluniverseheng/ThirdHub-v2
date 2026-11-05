// DSH 遥控（清单第 6 项）自检 —— 纯 Dart，`dart run tool/dsh_remote_selfcheck.dart`
//
// 为什么需要它：
//   `normalizeBase()` / `consoleUrl()` 这类逻辑一旦走偏，用户侧看到的是
//   「填了地址点测试，永远转圈」或「打开控制台 404」，而**编译与 analyze 都不会报**。
//   这一页又只有两条通路（测试连接 / 打开控制台），出错时用户没有任何线索。
//   所以把「地址怎么归一」「粘贴串怎么拆」「URL 怎么拼」全部钉成断言。
//
// 断言分五类：
//   ① 规则：normalizeBase / parsePasted / consoleUrl / adminUrl / maskToken
//   ② 存取：save → load 往返（内存 kv，不碰 SharedPreferences）
//   ③ 文案：8 条失败原因的人话互不相同，且在 6 种语言里都有译文
//   ④ 接线：页面真的调了 probe / consoleUrl / adminUrl / WebView
//   ⑤ 入口：main.dart 的「我的」里真有这一行
//
// 反证（2026-11-06 本机跑过）：把 normalizeBase 的默认端口 8787 改成 80 → 3 条 FAIL；
// 删掉 main.dart 那条 entry(...DSH 遥控...) → 入口断言 FAIL。不是恒绿闸门。
import 'dart:io';

import '../lib/core/dsh_remote.dart';
import '../lib/core/kv.dart';

int _pass = 0;
final List<String> _fail = [];

void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail.add('$name${extra.isEmpty ? '' : '  ($extra)'}');
  }
}

void eq(String name, Object? got, Object? want) =>
    ck(name, got == want, 'got=$got want=$want');

Future<void> main() async {
  // ── 1. 地址归一化 ─────────────────────────────────────────────────────
  eq('裸 IP 补 scheme 与默认端口', DshRemote.normalizeBase('192.168.1.5'),
      'http://192.168.1.5:8787');
  eq('IP:端口', DshRemote.normalizeBase('192.168.1.5:8787'),
      'http://192.168.1.5:8787');
  eq('带 scheme 与尾斜杠', DshRemote.normalizeBase('http://192.168.1.5:8787/'),
      'http://192.168.1.5:8787');
  eq('带查询串要去掉（否则 URL 里两个 token）',
      DshRemote.normalizeBase('http://192.168.1.5:8787/?token=abc'),
      'http://192.168.1.5:8787');
  eq('带片段要去掉', DshRemote.normalizeBase('http://192.168.1.5:8787#x'),
      'http://192.168.1.5:8787');
  eq('前后空格与换行', DshRemote.normalizeBase('  http://192.168.1.5:8787\n'),
      'http://192.168.1.5:8787');
  eq('自定义端口要保留', DshRemote.normalizeBase('192.168.1.5:9000'),
      'http://192.168.1.5:9000');
  eq('IPv6 要加方括号', DshRemote.normalizeBase('[fe80::1]:8787'),
      'http://[fe80::1]:8787');
  eq('空串', DshRemote.normalizeBase('   '), '');
  eq('非 http(s) 协议拒绝', DshRemote.normalizeBase('ftp://192.168.1.5:8787'), '');

  // ── 2. 粘贴串拆分 ─────────────────────────────────────────────────────
  final p1 = DshRemote.parsePasted('http://192.168.1.5:8787/?token=AbC123xyz');
  eq('整条连接串 → 地址', p1.base, 'http://192.168.1.5:8787');
  eq('整条连接串 → 令牌', p1.token, 'AbC123xyz');

  final p2 = DshRemote.parsePasted('http://192.168.1.5:8787?token=a%2Bb');
  eq('令牌要做 percent 解码', p2.token, 'a+b');

  final p3 = DshRemote.parsePasted('192.168.1.5:8787');
  eq('只有地址时令牌为空', p3.token, '');
  eq('只有地址时地址照样归一', p3.base, 'http://192.168.1.5:8787');

  // 令牌是 base64url：无点无冒号无斜杠、长度 >= 16
  final p4 = DshRemote.parsePasted('vT3rQ9xLmK2pS8dF1aB4cD6eG0hJ5kL7');
  eq('只贴令牌 → 地址留空', p4.base, '');
  eq('只贴令牌 → 认出令牌', p4.token, 'vT3rQ9xLmK2pS8dF1aB4cD6eG0hJ5kL7');

  final p5 = DshRemote.parsePasted('');
  eq('空串不崩', '${p5.base}|${p5.token}', '|');

  // ── 3. 两个入口 URL ───────────────────────────────────────────────────
  eq('控制台带 token', DshRemote.consoleUrl(at: '192.168.1.5', tok: 'abc'),
      'http://192.168.1.5:8787/?token=abc');
  eq('控制台无 token 时不带参数',
      DshRemote.consoleUrl(at: '192.168.1.5', tok: ''),
      'http://192.168.1.5:8787/');
  eq('管理页带 token', DshRemote.adminUrl(at: '192.168.1.5:8787', tok: 'a+b'),
      'http://192.168.1.5:8787/admin?token=a%2Bb');
  eq('空地址 → 空 URL', DshRemote.consoleUrl(at: '', tok: 'x'), '');

  // 令牌里的特殊字符必须编码，否则 ? & # 会把 URL 截断
  final hostile = DshRemote.consoleUrl(at: '10.0.0.2', tok: 'a&b=c#d');
  ck('令牌特殊字符编码后不再出现裸 & 或尾随 #',
      !hostile.contains('a&b') && !hostile.endsWith('#d'), hostile);

  // ── 4. 令牌显示掩码 ───────────────────────────────────────────────────
  eq('长令牌只露后 4 位', DshRemote.maskToken('0123456789abcdef'), '****cdef');
  eq('空令牌掩码为空', DshRemote.maskToken(''), '');
  ck('掩码不泄露前段',
      !DshRemote.maskToken('0123456789abcdef').contains('012345'));

  // ── 5. 存取往返（内存 kv） ────────────────────────────────────────────
  resetAiStoreForTest();
  await DshRemote.save(at: '192.168.1.5', tok: 'tok123456');
  DshRemote.base = '';
  DshRemote.token = '';
  await DshRemote.load();
  eq('存取往返：地址落盘时已归一', DshRemote.base, 'http://192.168.1.5:8787');
  eq('存取往返：令牌', DshRemote.token, 'tok123456');
  ck('存过之后 configured 为真', DshRemote.configured);
  await DshRemote.clear();
  await DshRemote.load();
  eq('清空后地址为空', DshRemote.base, '');
  eq('清空后令牌为空', DshRemote.token, '');
  ck('清空后 configured 为假', !DshRemote.configured);

  // ── 6. 失败码人话齐全且互不相同 ───────────────────────────────────────
  const codes = [
    DshErr.addrEmpty,
    DshErr.addrBad,
    DshErr.tokenEmpty,
    DshErr.unreachable,
    DshErr.notGateway,
    DshErr.badToken,
    DshErr.timeout,
    DshErr.unknown,
  ];
  final zhTexts = <String>{};
  for (final c in codes) {
    final t = DshErr.text(c);
    ck('失败码 $c 有人话', t.isNotEmpty && t.length > 4, t);
    zhTexts.add(t);
  }
  ck('8 个码的人话互不相同（否则用户分不清原因）', zhTexts.length == codes.length,
      '${zhTexts.length}/${codes.length}');

  // ── 7. 六语言字典：这 8 句必须是 i18n key ────────────────────────────
  //   为什么单独查：i18n_selfcheck 只认 `tr('字面量')`，而这 8 句是
  //   `tr(DshErr.text(code))` 进去的 —— 静态扫描看不见，漏翻它也不会红。
  final dictPath = 'lib/core/i18n_ui_words.dart';
  final dict = File(dictPath).existsSync() ? File(dictPath).readAsStringSync() : '';
  ck('字典文件可读', dict.isNotEmpty, dictPath);
  for (final t in zhTexts) {
    final n = "'$t':".allMatches(dict).length;
    eq('六语言齐备：$t', n, 6);
  }

  // ── 8. 接线：页面真的调用了规则层 ─────────────────────────────────────
  final pagePath = 'lib/core/dsh_remote_page.dart';
  final page = File(pagePath).existsSync() ? File(pagePath).readAsStringSync() : '';
  ck('配置页存在', page.isNotEmpty, pagePath);
  ck('页面调用 DshRemote.probe（测试连接真的会探）', page.contains('DshRemote.probe('));
  ck('页面调用 consoleUrl（控制台地址由规则层拼）',
      page.contains('DshRemote.consoleUrl('));
  ck('页面调用 adminUrl（管理页入口在）', page.contains('DshRemote.adminUrl('));
  ck('页面用 WebViewWidget 内嵌控制台', page.contains('WebViewWidget(controller:'));
  ck('页面读了剪贴板（一键粘贴入口在）', page.contains('Clipboard.getData('));

  // ── 9. 入口：main.dart 的「我的」里真有这一行 ─────────────────────────
  final mainPath = 'lib/main.dart';
  final mainSrc =
      File(mainPath).existsSync() ? File(mainPath).readAsStringSync() : '';
  ck('入口挂在设置页', mainSrc.contains("entry(Icons.desktop_windows_outlined, tr('DSH 遥控')"));
  ck('入口指向 DshRemotePage', mainSrc.contains('page: const DshRemotePage()'));
  ck('main.dart 导入了页面',
      mainSrc.contains("import 'core/dsh_remote_page.dart';"));

  // ── 10. 结果 ─────────────────────────────────────────────────────────
  print('== dsh_remote 自检 ==');
  print('PASS $_pass / FAIL ${_fail.length}');
  if (_fail.isNotEmpty) {
    for (final f in _fail) {
      print('  ❌ $f');
    }
    exit(1);
  }
  print('✅ DSH 遥控契约与接线全部通过');
}
