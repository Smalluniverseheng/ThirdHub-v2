// 逐条可播（4.81.90）—— 搜得到 ≠ 播得了
//
// ── 为什么需要它 ─────────────────────────────────────────────────────────
//   4.81.89 把「分类即内容」做通了：点进漫画真的有漫画。但用户点进去发现
//   **一批结果里大半打不开** —— 公网源的死链是常态（下架、换地址、地区限制），
//   而搜索接口只保证「拿回来长得像结果」，不保证「每条都活着」。
//
//   对策是三层，全部围着一条原则：**别让用户拿时间换教训**。
//     1. 搜到就后台探活（[sweep]），死链标出来 —— 不用点进去才知道；
//     2. 点死链直接拦（[isDead]），不给开；
//     3. 有备选地址的自动换下一条（[liveCandidate]）——
//        声明式源写 `||` 候选链就是为这一刻准备的。
//
// ── 为什么探活结果按 URL 记而不是按条目记 ────────────────────────────────
//   同一个直链可能出现在多条结果里（同一首歌、同一期播客），按 URL 记一次
//   探活就够。条目级的「已失效」= 它的**所有**候选地址都死。
//
// ── 判定口径 ─────────────────────────────────────────────────────────────
//   只有「确定死」才拦（所有候选都探过且全死）。没探过 = 未知，**放行** ——
//   宁可让用户多点一次，也不做「还没测就禁用」的自作聪明（4.81.89 的
//   「当前不可达」横幅就是前车之鉴：判定和取数脱钩，吓人且不准）。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../free/free_http.dart';
import '../free/free_models.dart';

class Playable {
  Playable._();

  /// url → 探活结果（true=活，false=死）。未知的键不存在。
  static final Map<String, bool> _url = {};

  /// 条目级强制失效（播放时实锤打不开就记一笔，比探活更准）。
  static final Set<String> _itemDead = {};

  /// 结果变化信号。列表页用 `ValueListenableBuilder` 听它刷徽标。
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  /// 探活实现（测试注入用）。默认 GET 头部字节，6 秒超时。
  ///
  /// 不用 HEAD：不少媒体站/CDN 对 HEAD 返回 405/403，但 GET 是通的 ——
  /// 把「不支持 HEAD」判成「死链」就是 4.81.89 那种假红。
  static Future<bool> Function(String url) probeImpl = _probe;

  static Future<bool> _probe(String url) =>
      FreeHttp.ping(url, timeout: const Duration(seconds: 6));

  // ── 候选地址 ────────────────────────────────────────────────────────────

  /// 一条结果的候选播放地址：主地址 + 声明式源 `||` 链留下的备选，去重保序。
  static List<String> candidatesOf(FreeItem it) {
    final out = <String>[it.playUrl];
    final alts = it.raw['playAlts'];
    if (alts is List) {
      for (final a in alts) {
        final s = '$a'.trim();
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out.toSet().toList()..removeWhere((s) => s.isEmpty);
  }

  static bool? urlStatus(String url) => _url[url];

  /// 这条是不是实锤/推定失效：条目被标记过，或所有候选地址都探明已死。
  static bool isDead(FreeItem it) {
    if (_itemDead.contains(_key(it))) return true;
    final cs = candidatesOf(it);
    return cs.isNotEmpty && cs.every((u) => _url[u] == false);
  }

  /// 有没有已知活着的地址。
  static bool isOk(FreeItem it) => candidatesOf(it).any((u) => _url[u] == true);

  /// 优先给一条没被探死的地址（已知活的排最前），全死返回 null。
  static String? liveCandidate(FreeItem it) {
    final cs = candidatesOf(it);
    for (final u in cs) {
      if (_url[u] == true) return u;
    }
    for (final u in cs) {
      if (_url[u] != false) return u;
    }
    return null;
  }

  // ── 记账 ────────────────────────────────────────────────────────────────

  static String _key(FreeItem it) => '${it.source}:${it.id}';

  static void markUrl(String url, bool ok) {
    if (url.isEmpty) return;
    _url[url] = ok;
    tick.value++;
  }

  /// 播放时实锤打不开（比探活更可信）。
  static void markDead(FreeItem it) {
    _itemDead.add(_key(it));
    tick.value++;
  }

  // ── 后台扫 ──────────────────────────────────────────────────────────────

  /// 值得探活：有候选地址且是能播的形态（书/漫画/诗词没有直链，探无可探）。
  static bool probeable(FreeItem it) =>
      it.kind.playable && candidatesOf(it).isNotEmpty;

  /// 后台扫一批条目（每条按候选链探到第一个活口为止）。
  ///
  /// [limit] 条数上限 —— 一屏列表十来条，全表扫是流量浪费；
  /// [concurrency] 并发上限 4 —— 手机网络下更高并发只会互相抢。
  /// 每条出结果调一次 [onUpdate]（调用方拿它 setState 徽标）。
  static Future<void> sweep(
    List<FreeItem> items, {
    int limit = 12,
    int concurrency = 4,
    void Function()? onUpdate,
  }) async {
    final todo = <FreeItem>[
      for (final it in items)
        if (probeable(it) && !isDead(it) && !isOk(it)) it
    ].take(limit).toList();
    if (todo.isEmpty) return;

    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= todo.length) return;
        final it = todo[i];
        for (final u in candidatesOf(it)) {
          if (_url[u] != null) continue;
          final ok = await probeImpl(u);
          markUrl(u, ok);
          onUpdate?.call();
          if (ok) break; // 有一个活口就够，不再探备选
        }
      }
    }

    await Future.wait([for (var k = 0; k < concurrency; k++) worker()]);
  }

  /// 测试用：清空全部状态。
  static void reset() {
    _url.clear();
    _itemDead.clear();
    tick.value = 0;
  }
}
