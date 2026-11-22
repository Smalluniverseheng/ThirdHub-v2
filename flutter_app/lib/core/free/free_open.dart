// 开放源「打开一条结果」的统一入口（4.81.87）
//
// ── 为什么单独抽出来 ───────────────────────────────────────────────────
//   4.81.86 之前，这段分派是 `free_center_page` 的私有方法。结果就是
//   漫画/音乐/影视三个板块在「既没连引擎、也没连后端」时只能显示
//   「未连接本地资料库」—— 包里明明躺着能直连的公网源，用户点不进去。
//
//   现在板块页要把开放源结果直接显示在自己的列表里，点击行为和开放源页
//   必须一模一样（不然同一部漫画从两个入口进去表现不同，是最难查的 bug）。
//   所以把分派抬成不依赖任何页面状态的静态入口，两处共用。
//
// ── 分派规则（与 4.81.86 完全一致，只是换了位置）────────────────────
//   导入/同步来的声明式源：有 detail 动作就下钻，否则直接播/读；
//   内置源：漫画走章节→图片，书籍走目录→正文，播客走单集，其余直接播。

import 'package:flutter/material.dart';

import '../agg/playable.dart';
import '../i18n.dart';
import '../player/media_spec.dart';
import '../player/unified_player.dart';
import 'free_center_page.dart'
    show
        FreeBookTocPage,
        FreeChapterListPage,
        FreeComicReadPage,
        FreeDrillPage,
        FreeEpisodePage,
        FreeTextReadPage,
        freeKindName;
import 'free_http.dart';
import 'free_models.dart';
import 'free_registry.dart';
import 'free_sources_media.dart';
import 'free_sources_read.dart';

class FreeOpen {
  FreeOpen._();

  /// 打开一条开放源结果。所有导航都从 [c] 出发。
  static Future<void> open(BuildContext c, FreeItem it) async {
    // ★4.81.90 已探明失效的条目直接拦：列表里已经标了「已失效」，
    //   点进去只会有转圈和报错 —— 不拿用户的时间换教训。
    if (Playable.isDead(it)) {
      _toast(c, tr('这条打不开了，已标记为失效'));
      return;
    }
    // ★ 导入/同步来的源：没有专属 Dart 实现，能下钻就下钻（声明式
    //   detail 动作），不能下钻就直接播/读。
    if (FreeRegistry.isDynamic(it.source)) {
      final spec = FreeRegistry.specOf(it.source);
      if (spec?.detail != null && it.drill) {
        await _push(c, FreeDrillPage(parent: it));
        return;
      }
      await play(c, it);
      return;
    }

    if (it.kind == FreeKind.comic) {
      if (it.drill) {
        await _push(c, FreeChapterListPage(manga: it));
      } else {
        await _push(c, FreeComicReadPage(chapter: it));
      }
      return;
    }
    if (it.kind == FreeKind.book) {
      if (it.drill) {
        await _push(c, FreeBookTocPage(book: it));
      } else {
        await _push(
          c,
          FreeTextReadPage(
            title: it.displayTitle,
            loader: () async {
              if (it.source == WikisourceSource.id) {
                return WikisourceSource.read('${it.raw['pageTitle'] ?? it.id}');
              }
              return GutenbergAuSource.read('${it.raw['url'] ?? it.id}');
            },
          ),
        );
      }
      return;
    }
    if (it.kind == FreeKind.podcast && it.drill) {
      await _push(c, FreeEpisodePage(show: it));
      return;
    }
    await play(c, it);
  }

  /// 直接播放一条结果（有 playUrl 就直接放，视频缺地址就现取）。
  ///
  /// 与开放源页原来的 `_play` 一致：视频的直链必须现取 ——
  /// PeerTube 的列表接口不返回 files 字段。
  static Future<void> play(BuildContext c, FreeItem it) async {
    // ★4.81.90 候选回退：主地址死了换 `||` 链的下一条（Playable 按 URL 记死活）。
    //   没探过的地址照常放行 —— 未知≠失效，先给播，打不开再记账。
    var url = Playable.liveCandidate(it) ?? '';
    if (url.isEmpty && it.kind == FreeKind.video) {
      final host = '${it.raw['host'] ?? ''}';
      try {
        url = await PeerTubeSource.playUrl(it.id,
            host: host.isEmpty ? null : host);
      } on FreeNetException catch (e) {
        Playable.markDead(it); // 实锤：连地址都解析不出来
        if (c.mounted) _toast(c, e.message);
        return;
      } catch (e) {
        Playable.markDead(it);
        if (c.mounted) _toast(c, '$e');
        return;
      }
    }
    if (url.isEmpty) {
      if (c.mounted) _toast(c, tr('这一条没有可播地址'));
      return;
    }
    if (!c.mounted) return;
    final kind = it.kind == FreeKind.video ? MediaKind.video : MediaKind.audio;
    await _push(
      c,
      UnifiedPlayerPage(
        spec: MediaSpec(
          url: url,
          title: it.displayTitle,
          cover: it.cover.isEmpty ? null : it.cover,
          artist: it.subtitle,
          kindOverride: kind,
          sourceTag: freeKindName(it.kind),
          allowAudioMode: it.kind != FreeKind.radio,
        ),
      ),
    );
  }

  static Future<void> _push(BuildContext c, Widget page) async {
    if (!c.mounted) return;
    await Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  static void _toast(BuildContext c, String msg) {
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));
  }
}
