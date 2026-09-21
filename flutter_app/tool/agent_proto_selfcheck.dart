// ═══════════════════════════════════════════════════════════════════════════
// THA/1 控制面自检（纯 Dart，不需要 flutter_tester）
//
// 用法: dart run tool/agent_proto_selfcheck.dart
//
// 为什么必须有它：agent_models.dart / agent_policy.dart 刻意零 Flutter 依赖，
// 所以本机 flutter_tester 起不来时也能完整验证协议解析与权限判定。
//
// 最有价值的一组断言是「对拍」：直接读 server/agent-profiles.json，
// 逐条比对 Dart 侧镜像的判定结果。两份表一旦漂移（比如服务端把某个工具
// 从 write 调成 danger，而 Dart 没跟着改），这里立刻红 ——
// 这类漂移的表现是「UI 显示可以点，服务端却拒绝」，不测就发现不了。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:io';

import 'package:thirdhub_app/core/agent_models.dart';
import 'package:thirdhub_app/core/agent_policy.dart';

int _pass = 0;
int _fail = 0;
final List<String> _fails = [];

void _ok(bool cond, String name, [String extra = '']) {
  if (cond) {
    _pass++;
    print('  \u2713 $name');
  } else {
    _fail++;
    _fails.add(name);
    print('  \u2717 $name${extra.isEmpty ? '' : '  -> $extra'}');
  }
}

void _eq(Object? a, Object? b, String name) =>
    _ok('$a' == '$b', name, '实际=$a 期望=$b');

void _section(String s) => print('\n== $s ==');

AgentEvent _evt(String type, Map<String, dynamic> payload, {String id = 'evt_1', int seq = 1}) =>
    AgentEvent(id: id, sessionId: 's1', seq: seq, ts: 1, type: type, payload: payload);

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  _section('1. 事件解析');
  final e1 = AgentEvent.from({
    'id': 'evt_a', 'sessionId': 'sess_1', 'seq': 7, 'ts': 1720000000000,
    'type': 'tool_call', 'payload': {'tool': 'kb.search', 'arguments': {'q': 'x'}},
  });
  _eq(e1.id, 'evt_a', 'id 解析');
  _eq(e1.seq, 7, 'seq 解析');
  _eq(e1.type, AgentEventType.toolCall, 'type 解析');
  _ok(e1.isKnownType, 'tool_call 是已知类型');

  // 缺字段要能容忍（服务端加字段/掉字段都不该让客户端崩）
  final e2 = AgentEvent.from({'type': 'assistant_delta'});
  _eq(e2.id, '', '缺 id 时为空格字符串');
  _eq(e2.seq, 0, '缺 seq 时为 0');
  _ok(e2.payload.isEmpty, '缺 payload 时为空表');
  _ok(!e2.isKnownType == false, 'assistant_delta 是已知类型');
  final e3 = AgentEvent.from({'type': '完全没见过的类型'});
  _ok(!e3.isKnownType, '未见过的类型 isKnownType=false');

  _eq(_evt(AgentEventType.assistantDelta, {'text': '你好'}).deltaText, '你好', 'deltaText');
  _eq(_evt(AgentEventType.assistantDelta, {}).deltaText, '', 'deltaText 缺字段为空');
  _ok(_evt(AgentEventType.done, {}).isTerminal, 'done 是终态');
  _ok(_evt(AgentEventType.error, {}).isTerminal, 'error 是终态');
  _ok(!_evt(AgentEventType.toolCall, {}).isTerminal, 'tool_call 不是终态');
  _eq(_evt(AgentEventType.confirmRequest, {}, id: 'evt_c').confirmId, 'evt_c', 'confirm_request 的 confirmId 取自身 id');
  _eq(_evt(AgentEventType.confirmResult, {'confirmId': 'evt_c'}).confirmId, 'evt_c', 'confirm_result 的 confirmId 取 payload');
  _ok(_evt('x', {}).toJson()['type'] == 'x', 'toJson 可往返');

  // ─────────────────────────────────────────────────────────────────────────
  _section('2. 工具调用与产物');
  final tc = AgentToolCall.from({'tool': 'note.save', 'arguments': {'path': 'a.md'}, 'argsDigest': 'sha256:ab', 'risk': 'write'});
  _eq(tc.tool, 'note.save', 'tool 解析');
  _eq(tc.arguments['path'], 'a.md', 'arguments 解析');
  _eq(tc.risk, AgentRisk.write, 'risk 解析');
  _ok(tc.prettyArgs.contains('a.md'), 'prettyArgs 含参数内容');
  _eq(AgentToolCall.from({}).prettyArgs, '（无参数）', '空参数的可读文案');
  // 兼容服务端可能用 name/args 两种写法
  _eq(AgentToolCall.from({'name': 'x', 'args': {'a': 1}}).tool, 'x', '兼容 name 写法');
  _eq(AgentToolCall.from({'name': 'x', 'args': {'a': 1}}).arguments['a'], 1, '兼容 args 写法');

  final art = AgentArtifact.from({'kind': 'diff', 'uri': 'server://artifacts/1', 'summary': '改了 2 行'});
  _eq(art.kind, 'diff', 'artifact kind');
  _ok(art.requiresConfirm, 'artifact 默认需要确认');
  _ok(!AgentArtifact.from({'kind': 'log', 'uri': 'u', 'requiresConfirm': false}).requiresConfirm, 'requiresConfirm=false 生效');

  // ── artifact 文本两态（4.43.0：内联预览 / 落盘回取）──
  final aInline = AgentArtifact.from({
    'kind': 'diff', 'uri': '', 'summary': 's',
    'text': '+a\n-b\n', 'textTruncated': false, 'bytes': 6,
  });
  _ok(aInline.hasText, '有内联文本 -> hasText');
  _ok(aInline.isDiff, 'kind=diff -> isDiff');
  _ok(!aInline.textTruncated, 'textTruncated=false');
  _eq(aInline.bytes, 6, 'bytes 解析');
  _ok(!aInline.canFetchFull, '无 id 时不能回取');

  final aBig = AgentArtifact.from({
    'kind': 'patch', 'uri': 'server://artifacts/art_1_0001', 'summary': 's',
    'text': '@@ -1 +1 @@\n-a\n+b', 'textTruncated': true, 'bytes': 4096,
  });
  _ok(aBig.isDiff, 'kind=patch -> isDiff');
  _ok(aBig.textTruncated, 'textTruncated=true');
  _eq(aBig.storeId, 'art_1_0001', '从 uri 反解 storeId');
  _ok(aBig.canFetchFull, '有 id 时可回取');
  _eq(AgentArtifact.from({'kind': 'file', 'storedId': 'art_9', 'uri': ''}).storeId, 'art_9',
      'storedId 字段可直接用');
  _eq(AgentArtifact.from({'kind': 'file', 'uri': 'server://artifacts/../../x'}).storeId, '',
      '★形状可疑的 id 一律拒绝（不发目录穿越给服务端）');
  _ok(!AgentArtifact.from({'kind': 'file', 'uri': 'u'}).hasText, '无文本 hasText=false');
  _ok(!AgentArtifact.from({'kind': 'log', 'uri': 'u'}).isDiff, 'kind=log 不是 diff');

  _section('2b. diff 逐行解析（AgentDiff）');
  final diffText = 'diff --git a/x.txt b/x.txt\n'
      'Index: x.txt\n'
      '--- a/x.txt\n'
      '+++ b/x.txt\n'
      '@@ -1,3 +1,3 @@\n'
      ' keep\n'
      '-old\n'
      '+new\n'
      ' tail\n';
  final dp = AgentDiff.parse(diffText);
  _ok(dp.isDiff, '有 hunk 头 -> isDiff');
  _eq(dp.hunks, 1, 'hunk 数');
  _eq(dp.added, 1, '新增行数');
  _eq(dp.removed, 1, '删除行数');
  _eq(dp.lines.length, 9, '行数不丢不吞');
  _eq(dp.lines[0].kind, AgentDiffKind.file, 'diff --git 认成文件头');
  _eq(dp.lines[2].kind, AgentDiffKind.file, '--- 认成文件头');
  _eq(dp.lines[4].kind, AgentDiffKind.hunk, '@@ 认成 hunk');
  _eq(dp.lines[5].kind, AgentDiffKind.context, '上下文行');
  _eq(dp.lines[6].kind, AgentDiffKind.del, '删除行');
  _eq(dp.lines[6].text, 'old', '删除行去掉前缀');
  _eq(dp.lines[7].kind, AgentDiffKind.add, '新增行');
  _eq(dp.lines[7].text, 'new', '新增行去掉前缀');
  _eq(dp.lines[5].aLine, 1, 'context 老行号从 hunk 头起算');
  _eq(dp.lines[5].bLine, 1, 'context 新行号从 hunk 头起算');
  _eq(dp.lines[6].aLine, 2, '删除行占老行号 2');
  _eq(dp.lines[7].bLine, 2, '新增行占新行号 2');
  _eq(dp.lines[8].aLine, 3, '尾行老行号 3');
  _eq(dp.lines[8].bLine, 3, '尾行新行号 3');

  // ★最容易出的误判：Markdown 列表 / 引用不能因为以 - + 开头就被染色
  final md = AgentDiff.parse('- 第一项\n- 第二项\n+ 这不是新增\n');
  _ok(!md.isDiff, '★无 hunk 头不按 diff 解析（Markdown 列表安全）');
  _eq(md.added, 0, '无 hunk 时不统计新增');
  _eq(md.removed, 0, '无 hunk 时不统计删除');
  _ok(md.lines.every((l) => l.kind == AgentDiffKind.plain), '全部按普通文本');
  _eq(AgentDiff.parse('- x\n', assumeDiff: true).removed, 0, '★assumeDiff 也不把 - 行当删除');
  _eq(AgentDiff.parse('--- a/f\n+++ b/f\n', assumeDiff: true).lines[0].kind, AgentDiffKind.file,
      'assumeDiff 只把文件头认出来');

  // ★hunk 内以 +++ 开头的新增内容，不能被误判成文件头
  final tricky = AgentDiff.parse('@@ -1 +1 @@\n+++ abc\n');
  _eq(tricky.lines[1].kind, AgentDiffKind.add, '★hunk 内 "+++ abc" 是新增一行 "++ abc"');
  _eq(tricky.lines[1].text, '++ abc', 'hunk 内 +++ 行只去掉一个 +');
  _eq(tricky.added, 1, 'tricky 统计新增 1');

  // 边界：空串 / 末尾换行 / CRLF / 多 hunk 行号重置
  _ok(!AgentDiff.parse('').isDiff, '空串不是 diff');
  _eq(AgentDiff.parse('').lines.length, 0, '空串 0 行');
  _eq(AgentDiff.parse('a\nb\n').lines.length, 2, '末尾换行不多出空行');
  final crlf = AgentDiff.parse('@@ -1 +1 @@\r\n-a\r\n+b\r\n');
  _eq(crlf.lines.length, 3, 'CRLF 不产生多余空行');
  _eq(crlf.lines[1].text, 'a', 'CRLF 行不含回车符');
  _eq(crlf.added, 1, 'CRLF 下统计仍正确');
  _eq(AgentDiff.parse('@@ -1 +1 @@\n\\ No newline at end of file\n').lines[1].kind,
      AgentDiffKind.meta, '反斜杠行认成 meta');
  final two = AgentDiff.parse('@@ -1 +1 @@\n-a\n+b\n@@ -10 +10 @@\n-c\n+d\n');
  _eq(two.hunks, 2, '两个 hunk');
  _eq(two.added, 2, '两个 hunk 的新增合计');
  _eq(two.lines[5].bLine, 10, '★第二个 hunk 的行号重置为 10');

  // ─────────────────────────────────────────────────────────────────────────
  _section('3. 事件流折叠（AgentTimeline）');
  final tl = AgentTimeline([
    _evt(AgentEventType.userMessage, {'text': '帮我整理'}, seq: 1),
    _evt(AgentEventType.assistantDelta, {'text': '好的'}, seq: 2),
    _evt(AgentEventType.assistantDelta, {'text': '，正在做'}, seq: 3),
    _evt(AgentEventType.toolCall, {'tool': 'kb.search'}, seq: 4),
    _evt(AgentEventType.toolResult, {'tool': 'kb.search', 'summary': '3 条'}, seq: 5),
  ]);
  _eq(tl.streamingText, '好的，正在做', 'delta 拼接');
  _eq(tl.toolCalls.length, 1, '工具调用 1 条');
  _ok(!tl.finished, '没有 done 时未结束');
  _ok(!tl.blockedByConfirm, '无确认时不阻塞');

  final tl2 = AgentTimeline([
    _evt(AgentEventType.confirmRequest, {'tool': 'note.save'}, id: 'evt_c1', seq: 1),
    _evt(AgentEventType.confirmRequest, {'tool': 'fs.write'}, id: 'evt_c2', seq: 2),
  ]);
  _eq(tl2.openConfirms.length, 2, '两条都还没答复');
  _ok(tl2.blockedByConfirm, '存在未答复确认 -> 阻塞');

  final tl3 = AgentTimeline([
    _evt(AgentEventType.confirmRequest, {'tool': 'note.save'}, id: 'evt_c1', seq: 1),
    _evt(AgentEventType.confirmResult, {'confirmId': 'evt_c1', 'allow': true}, seq: 2),
  ]);
  _eq(tl3.openConfirms.length, 0, '答复后不再挂起');
  _ok(!tl3.blockedByConfirm, '答复后不再阻塞');
  // 幂等：同一个 confirmId 答复两次也不该复活
  final tl4 = AgentTimeline([
    _evt(AgentEventType.confirmRequest, {'tool': 'a'}, id: 'evt_x', seq: 1),
    _evt(AgentEventType.confirmResult, {'confirmId': 'evt_x'}, seq: 2),
    _evt(AgentEventType.confirmResult, {'confirmId': 'evt_x'}, seq: 3),
  ]);
  _eq(tl4.openConfirms.length, 0, '重复答复仍是 0 条挂起');

  final tl5 = AgentTimeline([
    _evt(AgentEventType.toolCall, {'tool': 'a'}, seq: 1),
    _evt(AgentEventType.artifact, {'kind': 'patch', 'uri': 'u1'}, seq: 2),
    _evt(AgentEventType.error, {'code': 'X'}, seq: 3),
    _evt(AgentEventType.done, {'tokens': 1200, 'cost': 0.03, 'taskStatus': 'ok'}, seq: 4),
  ]);
  _eq(tl5.artifacts.length, 1, 'artifact 计数');
  _eq(tl5.errors.length, 1, 'error 计数');
  _ok(tl5.finished, '有 done 时 finished');
  _eq(tl5.lastStat!.tokens, 1200, 'done 里的 tokens');
  _eq(tl5.lastStat!.cost, 0.03, 'done 里的 cost');
  _ok(AgentTimeline(const []).lastStat == null, '空事件流无统计');

  // ─────────────────────────────────────────────────────────────────────────
  _section('4. 权限判定：本地镜像三档');
  // default：读放行 / 写需确认 / 高危拒绝
  _ok(AgentPolicy.decide(AgentProfileId.normal, 'kb.search').allowed, 'default: kb.search 放行');
  _ok(AgentPolicy.decide(AgentProfileId.normal, 'file.readSelected').allowed, 'default: file.readSelected 放行');
  _ok(AgentPolicy.decide(AgentProfileId.normal, 'note.save').needsConfirm, 'default: note.save 需确认');
  _ok(AgentPolicy.decide(AgentProfileId.normal, 'reading.progress.write').needsConfirm, 'default: reading.progress.write 需确认');
  _ok(AgentPolicy.decide(AgentProfileId.normal, 'fs.write').denied, 'default: fs.write 拒绝');
  _ok(AgentPolicy.decide(AgentProfileId.normal, 'shell.run').denied, 'default: shell.run 拒绝');
  _ok(AgentPolicy.decide(AgentProfileId.normal, 'accessibility.tap').denied, 'default: accessibility.tap 拒绝');

  // acceptEdits：写文件转确认，shell 仍拒
  _ok(AgentPolicy.decide(AgentProfileId.acceptEdits, 'fs.write').needsConfirm, 'acceptEdits: fs.write 需确认');
  _ok(AgentPolicy.decide(AgentProfileId.acceptEdits, 'shell.run').denied, 'acceptEdits: shell.run 仍拒绝');
  _ok(!AgentPolicy.decide(AgentProfileId.acceptEdits, 'note.save').denied, 'acceptEdits: note.save 不再被拒');

  // full-access：全放行
  _ok(AgentPolicy.decide(AgentProfileId.fullAccess, 'fs.write').allowed, 'full-access: fs.write 放行');
  _ok(AgentPolicy.decide(AgentProfileId.fullAccess, 'shell.run').allowed, 'full-access: shell.run 放行');
  _ok(AgentPolicy.decide(AgentProfileId.fullAccess, 'accessibility.tap').allowed, 'full-access: accessibility.tap 放行');

  // 档位名写错 -> 一律拒绝（静默放宽权限是最危险的失败模式）
  _ok(AgentPolicy.decide('full_acess', 'kb.search').denied, '档位名写错 -> 连只读也拒绝');
  _ok(AgentPolicy.decide('', 'kb.search').denied, '空档位名 -> 拒绝');
  _ok(!AgentPolicy.hasProfile('full_acess'), 'hasProfile 对错名返回 false');

  // ─────────────────────────────────────────────────────────────────────────
  _section('5. 风险分级：未登记工具按高危');
  _eq(AgentPolicy.riskOf('kb.search'), AgentRisk.read, 'kb.search 风险=read');
  _eq(AgentPolicy.riskOf('note.save'), AgentRisk.write, 'note.save 风险=write');
  _eq(AgentPolicy.riskOf('shell.run'), AgentRisk.danger, 'shell.run 风险=danger');
  _eq(AgentPolicy.riskOf('完全没登记的工具'), AgentRisk.unknown, '未登记 -> unknown');
  _ok(AgentPolicy.decide(AgentProfileId.normal, '完全没登记的工具').denied, '未登记工具在 default 下被拒');
  _eq(AgentPolicy.riskOf('fs.writeSomethingNew'), AgentRisk.danger, 'fs.* 前缀兜底为 danger');
  _eq(AgentPolicy.riskOf('shell.exec'), AgentRisk.danger, 'shell.* 前缀兜底为 danger');
  _eq(AgentPolicy.riskOf(''), AgentRisk.unknown, '空名 -> unknown');

  // ─────────────────────────────────────────────────────────────────────────
  _section('6. 可见档位与目录概览');
  final vis = AgentPolicy.visibleProfiles();
  _eq(vis.length, 2, '普通用户只看到 2 档');
  _ok(!vis.any((p) => p['id'] == AgentProfileId.fullAccess), 'full-access 不出现在可见列表');
  final s = AgentPolicy.summary(AgentProfileId.normal);
  _eq(s['allow'], 7, 'default 放行 7 项（只读 7）');
  _eq(s['confirm'], 4, 'default 需确认 4 项（受控写里点名的 4 项）');
  _eq(s['deny'], 10, 'default 拒绝 10 项（未点名的写 4 + 高危 6）');
  _eq(AgentPolicy.summary(AgentProfileId.normal).length, 3, 'summary 三个键');
  final cat = AgentPolicy.catalog(AgentProfileId.normal);
  _eq(cat.length, 21, '目录共 21 个工具');
  // 三种判定必须覆盖全部工具（防止 summary 少算/漏算）
  _eq(s['allow']! + s['confirm']! + s['deny']!, cat.length, '三种判定之和 = 工具总数');
  final sa = AgentPolicy.summary(AgentProfileId.acceptEdits);
  _eq(sa['allow'], 15, 'acceptEdits 放行 15 项（只读 7 + 受控写 8）');
  _eq(sa['confirm'], 1, 'acceptEdits 只需确认 1 项（只解锁 fs.write）');
  _eq(sa['deny'], 5, 'acceptEdits 拒 5 项（shell/装包/无障碍 + fs.delete/browser.open）');
  // 关键语义：acceptEdits 并**不**解锁全部高危 —— 只放行它在 allowTools 里点名的那一个
  _ok(AgentPolicy.decide(AgentProfileId.acceptEdits, 'fs.write').needsConfirm, 'acceptEdits 解锁 fs.write（需确认）');
  _ok(AgentPolicy.decide(AgentProfileId.acceptEdits, 'fs.delete').denied, 'acceptEdits 仍拒 fs.delete');
  _eq(AgentPolicy.summary(AgentProfileId.fullAccess)['allow'], 21, 'full-access 全放行 21 项');
  // catalog 的 decision 必须与 decide() 一致（同一件事不能有两个答案）
  var mismatch = 0;
  for (final t in AgentPolicy.catalog(AgentProfileId.acceptEdits)) {
    if ('${t['decision']}' != AgentPolicy.decide(AgentProfileId.acceptEdits, '${t['name']}').decision) mismatch++;
  }
  _eq(mismatch, 0, 'catalog 与 decide 结论一致');

  // ─────────────────────────────────────────────────────────────────────────
  _section('7. 断网兜底白名单');
  _ok(AgentPolicy.allowOffline('kb.search'), '离线允许 kb.search');
  _ok(AgentPolicy.allowOffline('note.save'), '离线允许 note.save');
  _ok(!AgentPolicy.allowOffline('fs.write'), '离线不允许 fs.write');
  _ok(!AgentPolicy.allowOffline('shell.run'), '离线不允许 shell.run');
  _ok(!AgentPolicy.allowOffline('完全没登记的工具'), '离线不允许未登记工具');
  // 白名单里的每一项都必须是本地镜像认识的工具（防止白名单本身写错名字）
  var ghost = 0;
  for (final t in AgentPolicy.fallbackWhitelist) {
    if (AgentPolicy.riskOf(t) == AgentRisk.unknown) ghost++;
  }
  _eq(ghost, 0, '兜底白名单无幽灵工具名');

  // ─────────────────────────────────────────────────────────────────────────
  _section('7.5 本机工具名 ↔ 策略工具名 桥接');
  _eq(AgentPolicy.policyName('local_file_write'), 'fs.write', 'local_file_write -> fs.write');
  _eq(AgentPolicy.policyName('file_write'), 'fs.write', '不带前缀也能翻');
  _eq(AgentPolicy.policyName('web_search'), 'kb.search', 'web_search -> kb.search');
  _eq(AgentPolicy.policyName('run_python'), 'shell.run', 'run_python -> shell.run（后端执行代码＝高危）');
  _eq(AgentPolicy.policyName('fs.write'), 'fs.write', '已经是策略名的原样返回');
  _eq(AgentPolicy.policyName('local_没登记的工具'), 'local_没登记的工具', '没登记的原样返回（随后会被判 unknown）');
  _ok(AgentPolicy.decideLocal(AgentProfileId.normal, 'local_file_write').denied,
      'default 下 local_file_write 被拒');
  _ok(AgentPolicy.decideLocal(AgentProfileId.acceptEdits, 'local_file_write').needsConfirm,
      'acceptEdits 下 local_file_write 需确认');
  _ok(AgentPolicy.decideLocal(AgentProfileId.fullAccess, 'local_file_write').allowed,
      'full-access 下 local_file_write 放行');
  _ok(AgentPolicy.decideLocal(AgentProfileId.normal, 'local_clipboard_read').allowed,
      'default 下 local_clipboard_read 放行');
  _ok(!AgentPolicy.allowOfflineLocal('local_file_write'), '离线不允许 local_file_write');
  _ok(AgentPolicy.allowOfflineLocal('local_web_search'), '离线允许 local_web_search');
  // 桥接表里每个目标名都必须是策略表认识的工具，否则「放行了一个不存在的名字」
  var bridgeGhost = 0;
  for (final v in AgentPolicy.localBridge.values) {
    if (AgentPolicy.riskOf(v) == AgentRisk.unknown) {
      bridgeGhost++;
      print('      桥接目标未登记: $v');
    }
  }
  _eq(bridgeGhost, 0, '桥接表 ${AgentPolicy.localBridge.length} 项全部指向已登记工具');

  // ─────────────────────────────────────────────────────────────────────────
  _section('8. 服务端表覆盖本地镜像');
  _ok(!AgentPolicy.usingServerTable, '默认使用本地镜像');
  AgentPolicy.applyServerTable(
    {
      'read': {'label': '只读安全', 'tools': ['kb.search']},
      'write': {'label': '受控写入', 'tools': ['note.save']},
      'danger': {'label': '高危', 'tools': ['fs.write']},
    },
    [
      {'id': 'default', 'label': '服务端改过的默认档', 'allowRisk': ['read'], 'allowTools': [], 'confirmTools': [], 'denyTools': []},
    ],
    version: 99,
  );
  _ok(AgentPolicy.usingServerTable, '覆盖后 usingServerTable=true');
  _eq(AgentPolicy.serverVersion, 99, '服务端版本号记录');
  _ok(AgentPolicy.mirrorStale, '版本不一致 -> mirrorStale=true');
  _eq(AgentPolicy.decide('default', 'note.save').decision, AgentDecision.deny, '服务端表里 note.save 不在 write 档 -> 拒绝');
  _eq(AgentPolicy.riskOf('fs.write'), AgentRisk.danger, '覆盖后 fs.write 仍是 danger');
  // bookshelf.update 在本地镜像里是 write，但没出现在上面那张覆盖表里 → 应回落为 unknown
  _eq(AgentPolicy.riskOf('bookshelf.update'), AgentRisk.unknown, '覆盖后未登记的工具回落 unknown');

  // 畸形服务端数据不许放宽权限
  AgentPolicy.applyServerTable('这不是 map', 42, version: 1);
  _eq(AgentPolicy.riskOf('fs.write'), AgentRisk.danger, '畸形表不破坏已有风险表');

  AgentPolicy.reset();
  _ok(!AgentPolicy.usingServerTable, 'reset 后回到本地镜像');
  _eq(AgentPolicy.riskOf('note.save'), AgentRisk.write, 'reset 后 note.save 恢复为 write');
  _eq(AgentPolicy.mirrorStale, false, 'reset 后 mirrorStale=false');

  // ─────────────────────────────────────────────────────────────────────────
  _section('9. ★对拍：Dart 镜像 vs server/agent-profiles.json');
  final f = File('../server/agent-profiles.json');
  if (!f.existsSync()) {
    _ok(false, '读得到服务端 agent-profiles.json', f.absolute.path);
  } else {
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    _ok(true, '读得到服务端 agent-profiles.json');

    // ① 风险表逐个工具比对
    final serverRisk = j['risk'] as Map<String, dynamic>;
    var toolMismatch = 0;
    final List<String> serverTools = [];
    for (final entry in serverRisk.entries) {
      final tools = (entry.value as Map)['tools'] as List;
      for (final t in tools) {
        serverTools.add('$t');
        final mine = AgentPolicy.riskOf('$t');
        if (mine != '${entry.key}') {
          toolMismatch++;
          print('      漂移: $t 服务端=${entry.key} 本地=$mine');
        }
      }
    }
    _eq(toolMismatch, 0, '风险表逐工具一致（${serverTools.length} 个工具）');

    // ② 本地多出来的工具也要报（本地写了服务端没有的 = 幽灵授权）
    final serverSet = serverTools.toSet();
    final localSet = <String>{};
    for (final v in AgentPolicy.riskTable.values) {
      localSet.addAll(v);
    }
    final ghosts = localSet.difference(serverSet);
    _eq(ghosts.length, 0, '本地没有服务端不认识的工具${ghosts.isEmpty ? '' : " (幽灵: ${ghosts.join(",")})"}');

    // ③ 三档判定逐工具对拍（这才是真正防漂移的那一步）
    final serverProfiles = j['profiles'] as Map<String, dynamic>;
    var decMismatch = 0;
    var compared = 0;
    for (final pid in ['default', 'acceptEdits', 'full-access']) {
      final sp = serverProfiles[pid] as Map<String, dynamic>?;
      if (sp == null) { _ok(false, '服务端存在档位 $pid'); continue; }
      for (final t in serverTools) {
        compared++;
        final allowTools = (sp['allowTools'] as List? ?? []).map((x) => '$x').toList();
        final confirmTools = (sp['confirmTools'] as List? ?? []).map((x) => '$x').toList();
        final denyTools = (sp['denyTools'] as List? ?? []).map((x) => '$x').toList();
        final allowRisk = (sp['allowRisk'] as List? ?? []).map((x) => '$x').toList();
        final risk = AgentPolicy.riskOf(t);
        String want;
        if (denyTools.contains(t) || denyTools.contains('*')) {
          want = AgentDecision.deny;
        } else if (!allowRisk.contains(risk) && !allowTools.contains('*') && !allowTools.contains(t)) {
          want = AgentDecision.deny;
        } else if (confirmTools.contains(t)) {
          want = AgentDecision.confirm;
        } else if (sp['denyFullAccess'] != false && risk == AgentRisk.danger) {
          want = AgentDecision.confirm;
        } else {
          want = AgentDecision.allow;
        }
        final got = AgentPolicy.decide(pid, t).decision;
        if (want != got) {
          decMismatch++;
          print('      漂移: [$pid] $t 服务端=$want 本地=$got');
        }
      }
    }
    _eq(decMismatch, 0, '三档判定逐工具对拍一致（$compared 组）');

    // ④ 档位可见性与 denyFullAccess 也要一致
    var visMismatch = 0;
    for (final pid in serverProfiles.keys) {
      final sp = serverProfiles[pid] as Map<String, dynamic>;
      final mine = AgentPolicy.profileOf(pid);
      if (mine == null) { visMismatch++; continue; }
      if ((sp['visibleToUser'] != false) != (mine['visibleToUser'] != false)) visMismatch++;
      if ((sp['denyFullAccess'] != false) != (mine['denyFullAccess'] != false)) visMismatch++;
    }
    _eq(visMismatch, 0, '档位可见性/权限标志与远端一致');

    // ⑤ 桥接表对拍：本机工具名 → 策略名，一个字都不能差
    final bridge = (j['bridge'] as Map<String, dynamic>?)?['map'] as Map<String, dynamic>?;
    _ok(bridge != null, '服务端有 bridge.map');
    if (bridge != null) {
      var bMismatch = 0;
      final mine = AgentPolicy.localBridge;
      for (final e in bridge.entries) {
        if (mine['${e.key}'] != '${e.value}') {
          bMismatch++;
          print('      桥接漂移: ${e.key} 服务端=${e.value} 本地=${mine['${e.key}']}');
        }
      }
      for (final k in mine.keys) {
        if (!bridge.containsKey(k)) {
          bMismatch++;
          print('      本地多出桥接项: $k');
        }
      }
      _eq(bMismatch, 0, '桥接表与远端逐项一致（${bridge.length} 项）');
      // 桥接覆盖度：LocalTools 现有的 13 个工具都必须能翻
      const localTools = [
        'get_device_info', 'clipboard_read', 'clipboard_write', 'tts_speak', 'open_url',
        'share_text', 'file_write', 'file_read', 'file_list', 'file_delete', 'file_share',
        'run_python', 'web_search',
      ];
      final missing = [for (final t in localTools) if (!mine.containsKey(t)) t];
      _eq(missing.length, 0, 'LocalTools 的 13 个工具都在桥接表里${missing.isEmpty ? '' : " (缺: ${missing.join(",")})"}');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  _section('10. 健康快照');
  final h = AgentHealth.from({
    'mode': 'fallback', 'protocolVersion': 'THA/1', 'fullAgentAvailable': false,
    'dsh': {'detected': false, 'kind': 'none', 'running': false, 'error': '本机未安装 DSH'},
    'capabilities': {'eventLog': true, 'policy': true, 'audit': true, 'sandbox': false},
    'profiles': [{'id': 'default', 'label': '默认', 'visibleToUser': true}],
    'plugins': [{'id': 'core-context', 'license': 'MIT'}],
  });
  _eq(h.mode, AgentMode.fallback, 'mode 解析');
  _ok(!h.isFull, 'fallback 时 isFull=false');
  _ok(!h.dshDetected, 'dsh.detected=false');
  _eq(h.capabilities['eventLog'], true, 'capabilities.eventLog');
  _eq(h.capabilities['sandbox'], false, 'capabilities.sandbox=false（未装 DSH 时不假装有沙箱）');
  _eq(h.profiles.length, 1, 'profiles 解析');
  _eq(h.plugins.length, 1, 'plugins 解析');
  _ok(h.summary.contains('本机未安装 DSH'), '降级原因出现在 summary 里', h.summary);
  _ok(AgentHealth.from({}).summary.isNotEmpty, '空快照也有可读 summary');

  final h2 = AgentHealth.from({
    'mode': 'full', 'fullAgentAvailable': true,
    'dsh': {'detected': true, 'kind': 'http', 'running': true, 'version': '1.2.3'},
  });
  _ok(h2.isFull, 'full 模式 isFull=true');
  _ok(h2.summary.contains('1.2.3'), 'summary 带 DSH 版本');

  // ─────────────────────────────────────────────────────────────────────────
  _section('11. 审计与引用');
  final ar = AgentAuditRecord.from({
    'ts': 1720000000000, 'sessionId': 's1', 'userId': 'u1', 'profile': 'default',
    'tool': 'fs.write', 'argsDigest': 'sha256:abcd1234', 'decision': 'deny',
    'result': 'blocked', 'plugin': 'core-sandbox', 'mcpServer': '',
  });
  _ok(ar.isDenied, 'deny 识别');
  _ok(!ar.isConfirm, 'deny 不是 confirm');
  _ok(ar.line.contains('fs.write') && ar.line.contains('拒绝'), '审计可读文案', ar.line);
  _eq(AgentAuditRecord.from({}).decision, '', '空审计容错');

  final cr = AgentContextRef.from({'type': 'book', 'ref': 'shelf:b1', 'preview': '书名'});
  _eq(cr.type, 'book', 'contextRef type');
  _eq(cr.toJson()['ref'], 'shelf:b1', 'contextRef 可序列化');

  // ─────────────────────────────────────────────────────────────────────────
  _section('12. 会话与统计');
  final se = AgentSession.from({'id': 'sess_1', 'title': '整理书架', 'profile': 'default', 'eventCount': 12});
  _eq(se.title, '整理书架', '会话标题');
  _eq(se.eventCount, 12, '会话事件数');
  _eq(AgentSession.from({}).profile, 'default', '缺 profile 时回落到 default');
  final st = AgentTurnStat.from({'tokens': 100, 'cost': 0.01, 'taskStatus': 'ok'});
  _eq(st.taskStatus, 'ok', '任务状态');

  // ─────────────────────────────────────────────────────────────────────────
  print('');
  print(_fail == 0 ? '全部通过 $_pass/$_pass' : '$_fail/${_pass + _fail} 项失败');
  if (_fails.isNotEmpty) {
    print('失败项:');
    for (final n in _fails) {
      print('  - $n');
    }
  }
  exit(_fail == 0 ? 0 : 1);
}
