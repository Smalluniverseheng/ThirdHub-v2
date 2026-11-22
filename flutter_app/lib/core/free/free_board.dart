// 板块端上直连（4.81.87）
//
// ── 解决什么 ───────────────────────────────────────────────────────────
//   漫画 / 音乐 / 影视三个板块的搜索页原来只有两条路：
//     ① 连上了局域网引擎（THP）→ 走引擎
//     ② 连上了家里后端 → 走 /v1/{comic,music,video}/search
//   两条都不满足时直接显示「未连接本地资料库」。
//
//   但包里本来就带着能直连的公网源（MangaDex / PeerTube / Audius …），
//   手机开流量就能访问 —— 用户却一个都看不到。这是「后端是保底，不是前提」
//   最后一段没兑现的地方。
//
//   本文件给三个板块补上第三条路：**不连任何服务器，直接向源站请求**。
//
// ── 和「开放源」页的区别 ───────────────────────────────────────────────
//   开放源页是「按源浏览」；这里是「按板块搜索」。同一个源、同一份结果，
//   只是入口不同。所以底层用的是同一个 [FreeRegistry.searchAll]，
//   点开条目也走同一个 [FreeOpen.open] —— 不写第二套实现。

import 'package:flutter/material.dart';

import '../agg/playable.dart';
import '../i18n.dart';
import '../ui_cover.dart';
import 'free_models.dart';
import 'free_open.dart';
import 'free_registry.dart';

/// 板块搜索的第三条路：本机直连开放源。
class FreeBoard {
  FreeBoard._();

  /// 没引擎也没后端时的搜索。
  ///
  /// 返回空列表表示「开放源也拿不到东西」，调用方按「未连接」处理即可；
  /// 这里不抛异常 —— 板块页的 catch 会把异常显示成红色错误条，
  /// 而「搜不到内容」不该长得像程序出错。
  static Future<List<FreeItem>> search(FreeKind kind, String q) async {
    try {
      final r = await FreeRegistry.searchAll(kind, q);
      return r.items;
    } catch (_) {
      return const [];
    }
  }

  /// 板块页里代表「这条结果来自本机直连」的 group 标记。
  ///
  /// 渲染层看到它就去画 [FreeItemTile]，而不是去解后端的 Map 结构 ——
  /// 两种数据形状完全不同，混在一起渲染会直接抛类型错误。
  static Map<String, dynamic> group(List<FreeItem> items) =>
      {'ok': true, 'free': true, 'items': items};

  /// 这个 group 是不是本机直连来的。
  static bool isFree(Map g) => g['free'] == true;
}

/// 板块列表里的一条开放源结果。
///
/// 抽成公共 widget 的原因：漫画/音乐/影视三个板块的列表长得不一样，
/// 但「点开这条」的行为必须完全一致，否则会变成最难查的那类 bug ——
/// 同一部漫画从音乐板块点进去能播、从漫画板块点进去空白。
class FreeItemTile extends StatelessWidget {
  final FreeItem item;

  /// 覆盖副标题（比如视频板块想显示时长而不是简介）。
  final String? subtitleOverride;

  const FreeItemTile({
    super.key,
    required this.item,
    this.subtitleOverride,
  });

  @override
  Widget build(BuildContext c) {
    final sub = subtitleOverride ?? item.displaySubtitle;
    // ★4.81.90 死链明示：后台探活探出来的失效条目灰掉 + 打上标，
    //   不用点进去才知道打不开。没探过的不标（未知≠失效）。
    //   听 Playable.tick 自刷新 —— 探活是后台回来的，不该要求每个列表页
    //   记得 setState（漏一处就是"标永远不出来"）。
    return ValueListenableBuilder<int>(
      valueListenable: Playable.tick,
      builder: (c, _, __) {
        final dead = Playable.isDead(item);
        return Opacity(
          opacity: dead ? 0.55 : 1,
          child: ListTile(
            leading: item.cover.isEmpty
                ? const SizedBox(width: 48, height: 48)
                : CoverThumb(item.cover, fallbackText: item.displayTitle),
            title: Text(item.displayTitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: sub.isEmpty
                ? null
                : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
            // 用源名做尾部标记：用户能一眼看出这条来自哪个来源，
            // 出了问题也知道该去「我的源」里关哪个。死了的换成失效标。
            trailing: dead
                ? Text(tr('已失效'),
                    style: Theme.of(c)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Theme.of(c).colorScheme.error))
                : Text(item.source,
                    style: Theme.of(c).textTheme.labelSmall?.copyWith(
                          color: Theme.of(c).colorScheme.onSurfaceVariant,
                        )),
            onTap: () => FreeOpen.open(c, item),
          ),
        );
      },
    );
  }
}
