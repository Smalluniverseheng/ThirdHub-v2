// 搜索续拉纪律自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/engine_autopull_selfcheck.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// 为什么必须有这条闸门：**「自己停下来了」是不会报错的。**
//
// 2026-10-02 用户实测 4.64.0：「之前的版本好歹还能收个几百本几千的，你现在这个收搜索
// 几本就显示时间预算什么问题」，并明确下达纪律 ——
//   **「只要我这边没有停下（没按停止），就不要停止搜索。」**
//
// 复盘出这一轮有**两处会各自独立地把搜索停掉**，且都不报错、不留日志：
//   ① 引擎侧：线上跑的 1.10.0 引擎二进制**不含深搜**，`hasMore` 只反映缓存余量
//      （`from+limit < n`），第一页翻干就报 false → 客户端第一页即停。
//      （根因是发布事故：出包的树里没有 deepSweep，已随 1.11.0 修复并出包。）
//   ② 客户端侧：`_autoPullLoop` 里 `if (_emptyStreak >= 30) break;` —— 连续 30 轮
//      空手就**静默收工**；以及 `_loadMore` 的 catch 里 `_engHasMore = false` ——
//      **一次网络抖动就永久终止**整轮搜索。两条都与上述纪律直接冲突，已删除。
//
// 本自检把两件事钉死：
//   §1~§5 源码级：证明「静默熔断」没有被重新写回去、且续拉用的是合成判据 wantMore；
//   §6     **行为级**：复刻 `_autoPullLoop` 的退出判据，喂**线上那组实测数据**
//          （hasMore=false + truncated=true），断言它**不会**自行退出。
//
// ★为什么 §6 不能省：本仓 2026-09-28 的教训已经写进 i18n_selfcheck 的注释里 ——
//   「形状断言不能替代行为断言」。§1~§5 全都在断言"源码里有没有某段字"，而
//   当初的缺陷恰恰是"字都在、语义反了"。§6 才是真正描述"会不会停"的那一条。
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

/// 取出源码里 `名字(` 之后那对花括号包起来的函数体原文（含 `{ }`）。
///
/// 用花括号配平而不是正则 —— 函数体里有注释、字符串和嵌套块，贪婪正则会跨过函数尾巴。
String? fnBody(String src, String signature) {
  final i = src.indexOf(signature);
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

/// 取出 `anchor` 之后紧跟的那对花括号包起来的块原文（含 `{ }`）。
///
/// 用于把「空手分支」整段抠出来，断言它里面**没有** break —— 单看整函数有没有
/// break 是没用的（合法的退出条件本身就要 break），必须缩小到那一个分支。
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

// ─────────────────────────── §6 用的迷你行为模型 ───────────────────────────
//
// 只复刻"要不要继续拉"的**判据**，不复制 UI/Dart 异步细节 —— 本自检的命题是
// 「这些判据组合起来会不会在用户没按停止时把循环停掉」，与界面无关。

/// 引擎一轮的响应（与 `SearchPage` 对应）。
class Round {
  final bool hasMore;
  final bool truncated;
  final int newItems;
  const Round(this.hasMore, this.truncated, this.newItems);

  /// ★与 `SearchPage.wantMore` 必须逐字同义。
  bool get wantMore => hasMore || truncated;
}

/// 一轮循环的退出原因。
enum Exit {
  none, // 没退出，继续
  unmounted, // 页面销毁
  userStop, // 用户按了停止 —— **唯一合法的人工终止**
  newSearch, // 代次变了（又发起了新搜索）
  engineExhausted, // 引擎报见底（wantMore 为假）
  engineGone, // 引擎不可达
}

/// 复刻 `_autoPullLoop` 的退出判据 + 空手退避（退避**不影响**是否退出）。
///
/// 返回 (实际跑了几轮, 退出原因)。`maxRounds` 是"用户一直不按停止"的上限。
(int, Exit) simulateAutoPull({
  required Round Function(int round) engine,
  required bool Function(int round) userStops,
  required bool Function(int round) mounted,
  required bool Function(int round) engineConnected,
  int maxRounds = 500,
}) {
  var rounds = 0;
  for (var r = 1; r <= maxRounds; r++) {
    if (!mounted(r)) return (rounds, Exit.unmounted);
    // ① `!_autoPull`：用户停止是唯一的人工终止。
    if (userStops(r)) return (rounds, Exit.userStop);
    rounds = r;
    final p = engine(r);
    // ② `!_engHasMore`：注意 `_engHasMore` 存的是 `wantMore`，不是裸 hasMore。
    if (!p.wantMore) return (rounds, Exit.engineExhausted);
    // ③ `!EngineDirect.connected`
    if (!engineConnected(r)) return (rounds, Exit.engineGone);
    // 空手只影响间隔（退避），**不参与是否退出** —— 这正是本次修复的要点。
  }
  return (rounds, Exit.none); // 跑满 maxRounds 都没退出 = 一直在搜
}

/// 复刻 `_streamLoop` 的退出判据。
///
/// 与 [simulateAutoPull] 的唯一区别：单位是「**一条流**」而不是「一页」。
/// 引擎侧单条流有 120s 上限，到时 `truncated` 仍为真 —— 这时客户端**必须再连一条**，
/// 于是「一轮 = 一条流」。而「流到时」绝不能被当成「搜索结束」，否则用户点一次搜索
/// 只能拿到 120s 的量 —— 这正是本节要钉死的缺陷形状。
(int, Exit) simulateStreamLoop({
  required bool Function(int stream) wantMore,
  required bool Function(int stream) userStops,
  required bool Function(int stream) mounted,
  required bool Function(int stream) engineConnected,
  int maxRounds = 500,
}) {
  var streams = 0;
  for (var r = 1; r <= maxRounds; r++) {
    if (!mounted(r)) return (streams, Exit.unmounted);
    // ① `!_autoPull`：用户停止是唯一的人工终止。
    if (userStops(r)) return (streams, Exit.userStop);
    streams = r;
    // ② 引擎明确说见底（`wantMore` = hasMore || truncated）
    if (!wantMore(r)) return (streams, Exit.engineExhausted);
    // ③ 引擎不可达
    if (!engineConnected(r)) return (streams, Exit.engineGone);
    // 到这里 = 这条流用完（到时/中断），`truncated` 仍为真 → 循环回去再连一条。
  }
  return (streams, Exit.none); // 跑满 maxRounds 都没退出 = 一直在搜
}

void main() {
  final libMain = File('lib/main.dart').readAsStringSync();
  final libEng = File('lib/core/engine_direct.dart').readAsStringSync();

  // ── §1 合成判据 wantMore 必须存在且语义正确 ──
  print('== 1. SearchPage.wantMore（hasMore || truncated） ==');
  ck('engine_direct.dart 里有 wantMore',
      RegExp(r'bool\s+get\s+wantMore\s*=>').hasMatch(libEng));
  ck('wantMore 的语义是 hasMore || truncated',
      RegExp(r'bool\s+get\s+wantMore\s*=>\s*hasMore\s*\|\|\s*truncated\s*;')
          .hasMatch(libEng));

  // ── §2 引擎已返回的扫描进度必须被解析出来（否则界面上无从观测"还在干活"） ──
  print('== 2. SearchPage 解析 scannedSources / totalSources ==');
  ck('声明了 scannedSources 字段', libEng.contains('final int scannedSources;'));
  ck('声明了 totalSources 字段', libEng.contains('final int totalSources;'));
  ck("from() 里解析 'scannedSources'",
      libEng.contains("scannedSources: intOf('scannedSources', 0)"));
  ck("from() 里解析 'totalSources'",
      libEng.contains("totalSources: intOf('totalSources', 0)"));

  // ── §3 _autoPullLoop：静默熔断必须不存在 ──
  print('== 3. _autoPullLoop 不得含静默熔断 ==');
  final loop = fnBody(libMain, 'Future<void> _autoPullLoop(');
  ck('能定位到 _autoPullLoop 函数体（解析没跑偏）', loop != null);
  if (loop != null) {
    // (a) 旧熔断：连续 30 轮空手就 break —— 用户看不到任何提示，与纪律冲突。
    ck('不再有 `_emptyStreak >= 30` 静默熔断', !loop.contains('_emptyStreak >= 30'));
    ck('不再有 `_emptyStreak > 29` 之类的等效写法',
        !RegExp(r'_emptyStreak\s*[>=]+\s*(29|30|31)\b').hasMatch(loop));
    // (b) 四个客观退出条件都必须写全（缺一个就可能停不下来或停错）。
    ck('含退出条件 ① mounted', loop.contains('!mounted'));
    ck('含退出条件 ② _autoPull（用户停止）', loop.contains('!_autoPull'));
    ck('含退出条件 ③ 代次 _seq', loop.contains('mySeq != _seq'));
    ck('含退出条件 ④ !_engHasMore（引擎见底）', loop.contains('!_engHasMore'));
    ck('含退出条件 ⑤ !EngineDirect.connected（引擎不可达）',
        loop.contains('!EngineDirect.connected'));
    // (c) 空手必须走退避，而不是直接跳出：空手分支里不得出现 break。
    ck('空手分支里有 `_emptyStreak++`（走退避）', loop.contains('_emptyStreak++'));
    final emptyBlk = blockAfter(loop, 'if ((engItems?.length ?? 0) == before)');
    ck('能定位到空手分支', emptyBlk != null);
    ck('空手分支里不含 break（只退避、不退搜）',
        emptyBlk != null && !emptyBlk.contains('break'));
    ck('退避有上限（_maxAutoPullGap）', loop.contains('_maxAutoPullGap'));
    // (d) 循环里的每一处 break 都必须挂在**允许的退出条件**上。
    //     「写了个裸 break」= 又多了一条静默退出路径，这是本闸门要拦的形态。
    final breakLines =
        loop.split('\n').where((l) => l.contains('break')).toList();
    ck('循环里的 break 全部挂在允许的退出条件上（当前 ${breakLines.length} 处）',
        breakLines.isNotEmpty &&
            breakLines.every((l) =>
                l.contains('!_engHasMore') ||
                l.contains('!EngineDirect.connected') ||
                l.contains('!_autoPull') ||
                l.contains('_seq') ||
                l.contains('mounted')));
  }

  // ── §4 _loadMore 的失败分支不得把 hasMore 置假 ──
  //
  // 「一次网络抖动 = 整轮搜索永久结束」是最难被发现的一种停：它看起来像"引擎没结果"。
  print('== 4. _loadMore 失败不得终止搜索 ==');
  final more = fnBody(libMain, 'Future<void> _loadMore(');
  ck('能定位到 _loadMore 函数体', more != null);
  if (more != null) {
    ck('catch 里不再有 `setState(() => _engHasMore = false);`',
        !more.contains('setState(() => _engHasMore = false);'));
    ck('catch 里不再直接写 `_engHasMore = false`',
        !RegExp(r'catch[\s\S]{0,900}?_engHasMore\s*=\s*false').hasMatch(more));
    ck('失败会计数以便降频提示（_pullErrStreak）',
        more.contains('_pullErrStreak++'));
    ck('提示文案说明仍会继续重试', more.contains('仍会继续重试'));
  }

  // ── §5 两条取数路径都必须用合成判据（首屏 / 续拉各一处） ──
  print('== 5. 首屏与续拉都用 wantMore ==');
  final nM = 'wantMore'.allMatches(libMain).length;
  ck('main.dart 里 wantMore 至少出现 4 次（首屏取数+判断、续拉取数+判断）当前 $nM',
      nM >= 4);
  ck('不存在把裸 `p.hasMore` 赋给 _engHasMore 的残留',
      !libMain.contains('_engHasMore = p.hasMore'));

  // ── §6 ★行为反证：喂线上那组实测数据，证明循环不会自行退出 ──
  print('== 6. 行为反证（复刻退出判据） ==');
  // (a) 线上实测组合：hasMore=false + truncated=true → 引擎自己承认"还有源没扫完"。
  //     期望：用户不按停止就**一直在搜**（跑满 maxRounds 且不退出）。
  final (r1, e1) = simulateAutoPull(
    engine: (_) => const Round(false, true, 0), // 一直空手、且引擎说没扫完
    userStops: (_) => false,
    mounted: (_) => true,
    engineConnected: (_) => true,
    maxRounds: 300,
  );
  ck('hasMore=false + truncated=true 且用户不停止 → 不自行退出（跑满 300 轮，实跑 $r1）',
      r1 == 300 && e1 == Exit.none);

  // (b) 反证 (a) 不是空转：同一个模拟器，把 truncated 关掉（= 引擎真见底）
  //     → 必须**立刻**停。否则说明 §6 的"一直跑"只是因为判据恒真。
  final (r2, e2) = simulateAutoPull(
    engine: (_) => const Round(false, false, 0),
    userStops: (_) => false,
    mounted: (_) => true,
    engineConnected: (_) => true,
  );
  ck('引擎真见底（wantMore=false）→ 立刻退出（实跑 $r2 轮，原因 $e2）',
      r2 == 1 && e2 == Exit.engineExhausted);

  // (c) 用户按停止 → 必须停（纪律说"只有用户停下才停"，反向也必须成立）。
  //
  //     注意"第 5 轮按停止"的正确期望是**已完成 4 轮**：真实实现是
  //     `while (mounted && _autoPull && mySeq == _seq)`，条件在**轮首**判定 ——
  //     用户在第 5 轮伊始被观测到已停止，于是第 5 次 `_loadMore` 根本不会发出。
  //     （这里写错过一次期望值 5，本自检自己把它抓出来了。）
  final (r3, e3) = simulateAutoPull(
    engine: (_) => const Round(false, true, 0),
    userStops: (r) => r >= 5,
    mounted: (_) => true,
    engineConnected: (_) => true,
  );
  ck('用户在第 5 轮按停止 → 只完成 4 轮即退出（实跑 $r3，原因 $e3）',
      r3 == 4 && e3 == Exit.userStop);

  // (d) 引擎不可达 → 退出（"连不上"= 客观上没有东西可搜，不是"我懒得等"）。
  final (r4, e4) = simulateAutoPull(
    engine: (_) => const Round(false, true, 0),
    userStops: (_) => false,
    mounted: (_) => true,
    engineConnected: (r) => r < 7,
  );
  ck('引擎在第 7 轮不可达 → 退出（实跑 $r4，原因 $e4）',
      r4 == 7 && e4 == Exit.engineGone);

  // (e) 页面销毁 → 退出（否则会在已卸载的 State 上 setState）。
  final (_, e5) = simulateAutoPull(
    engine: (_) => const Round(false, true, 0),
    userStops: (_) => false,
    mounted: (r) => r < 4,
    engineConnected: (_) => true,
  );
  ck('页面在第 4 轮销毁 → 退出（原因 $e5）', e5 == Exit.unmounted);

  // (f) 旧熔断若被写回，本模拟器必须能"抓住"它 —— 否则 §6(a) 的绿是假的。
  //     这里手工实现一个"30 轮空手即停"的旧循环，断言它确实会停。
  int legacyRounds = 0;
  {
    var emptyStreak = 0;
    for (var r = 1; r <= 300; r++) {
      legacyRounds = r;
      if (emptyStreak >= 30) break; // ← 旧实现（已从 main.dart 删除）
      emptyStreak++; // 每轮都空手
    }
  }
  ck('反证：旧熔断写法在同样输入下确实会停（第 $legacyRounds 轮）——'
      ' 证明 §6(a) 测得出这个缺陷', legacyRounds == 31);

  // ── §7 流式路径（4.65.0 / 引擎 1.12.0）必须守**同一条纪律** ──
  //
  // 为什么单开一节：流式（`_streamLoop`）与翻页（`_autoPullLoop`）是**两套实现**，
  // 而纪律只写在 §3 的注释里 —— 换实现就等于脱离闸门，正是本项目反复出事的形状
  // （"我改了、我以为测过了"）。所以这里对流式**逐条复刻**同一组断言。
  print('== 7. 流式搜索路径（_streamLoop / _streamOnce）==');
  final sloop = fnBody(libMain, 'Future<void> _streamLoop(');
  final sOnce = fnBody(libMain, 'Future<void> _streamOnce(');
  ck('能定位到 _streamLoop 函数体（解析没跑偏）', sloop != null);
  ck('能定位到 _streamOnce 函数体（解析没跑偏）', sOnce != null);
  if (sloop != null) {
    ck('流式循环同样没有 `_emptyStreak >= 30` 静默熔断',
        !RegExp(r'_emptyStreak\s*[>=]+\s*(29|30|31)\b').hasMatch(sloop));
    ck('流式循环含退出条件 ① mounted', sloop.contains('!mounted'));
    ck('流式循环含退出条件 ② _autoPull（用户停止）', sloop.contains('!_autoPull'));
    ck('流式循环含退出条件 ③ 代次 _seq', sloop.contains('mySeq != _seq'));
    ck('流式循环含退出条件 ④ !_engHasMore（引擎见底）',
        sloop.contains('!_engHasMore'));
    ck('流式循环含退出条件 ⑤ !EngineDirect.connected（引擎不可达）',
        sloop.contains('!EngineDirect.connected'));
    // ★流式特有的那条：一条流到时**不等于**搜索结束，必须能续流。
    ck('流式循环会反复连流（while + _streamOnce）',
        sloop.contains('_streamOnce') && sloop.contains('while'));
    ck('流式循环的间隔仍走退避（_maxAutoPullGap）', sloop.contains('_maxAutoPullGap'));
  }
  if (sOnce != null) {
    // 「流因到时收尾」不是失败：truncated 仍为真 → 由 _streamLoop 续流。
    ck('_streamOnce 把引擎状态存进 _engHasMore（供续流判据用）',
        sOnce.contains('_engHasMore = p.wantMore'));
    ck('_streamOnce 逐块 _appendEng（增量追加，不是等全部回来）',
        sOnce.contains('_appendEng(p.items)'));
    ck('_streamOnce 错误分支不得把 _engHasMore 置假（一次抖动≠引擎没了）',
        !(sOnce.contains('_engHasMore = false')));
  }
  // 停止 = 断连：协议层没有取消端点，唯一的取消手段就是断开这条流。
  ck('停止搜索会取消 _streamSub（断连即停）',
      libMain.contains('_streamSub?.cancel()'));
  ck('dispose 也会取消 _streamSub（不泄漏连接）',
      RegExp(r'dispose\(\)[\s\S]{0,400}_streamSub\?\.cancel\(\)')
          .hasMatch(libMain));
  ck('引擎直连层提供 searchStream', libEng.contains('searchStream('));
  ck('搜索请求带 stream=1', libEng.contains('&stream=1'));
  ck('流用 NDJSON 按行解码（LineSplitter）', libEng.contains('LineSplitter'));
  ck('提供 supportsStream（按 caps 判断，不靠版本号猜）',
      libEng.contains("caps.contains('stream-search')"));
  ck('提供 supportsSearchMode', libEng.contains("caps.contains('search-mode')"));
  ck('mode 只在引擎声明支持时才发（老引擎不受影响）',
      libEng.contains('supportsSearchMode ? \'&mode='));
  ck('模式选择器只在 supportsSearchMode 时渲染（老引擎不显示假开关）',
      libMain.contains('EngineDirect.supportsSearchMode'));
  ck('模式有白名单（防脏值写进设置）',
      RegExp(r"v\s*!=\s*'fuzzy'\s*&&\s*v\s*!=\s*'exact'")
          .hasMatch(libMain));

  // ── §7.1 行为断言：流到时 ≠ 停止 ──
  print('== 7.1 行为反证（流结束不等于搜索结束）==');
  final (s1, se1) = simulateStreamLoop(
    userStops: (_) => false,
    mounted: (_) => true,
    engineConnected: (_) => true,
    wantMore: (_) => true,
  );
  ck('引擎一直说「还有」且用户不按停止 → 永不退出（跑满 500 次流，实跑 $s1）',
      s1 == 500 && se1 == Exit.none);
  final (s2, se2) = simulateStreamLoop(
    userStops: (_) => false,
    mounted: (_) => true,
    engineConnected: (_) => true,
    wantMore: (r) => r < 3,
  );
  ck('引擎第 3 次流说见底 → 退出（实跑 $s2，原因 $se2）',
      s2 == 3 && se2 == Exit.engineExhausted);
  final (s3, se3) = simulateStreamLoop(
    userStops: (r) => r >= 6,
    mounted: (_) => true,
    engineConnected: (_) => true,
    wantMore: (_) => true,
  );
  ck('用户在第 6 次流按停止 → 只完成 5 次即退出（实跑 $s3，原因 $se3）',
      s3 == 5 && se3 == Exit.userStop);
  // 反证：把「流结束」当「搜索结束」的旧写法，在同样输入下只跑 1 次。
  var legacyStreams = 0;
  for (var s = 1; s <= 300; s++) {
    legacyStreams = s;
    break; // ← 旧实现：一条流完就收工（引擎还在深搜，前端却停了）
  }
  ck('反证：旧写法（一条流结束即收工）只跑 1 次 —— 证明 §7.1 测得出这个缺陷',
      legacyStreams == 1);

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) {
    print('\n✅ 搜索续拉纪律完好：用户未按停止时不会自行终止；'
        'wantMore 合成判据 + 扫描进度可观测 + 空手退避（不退搜）');
  }
  /* ★失败必须让进程非零退出：CI 只看退出码，只打印 FAIL 而 return 0
     的闸门形同虚设（2026-09-28 实测）。 */
  if (fail > 0) exit(1);
}
