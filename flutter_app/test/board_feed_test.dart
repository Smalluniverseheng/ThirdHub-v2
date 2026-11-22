// 板块聚合层的契约测试（4.81.88）
//
// 这里钉的是**架构决定**，不是某个函数返回值：
//   1. 板块 → 通路映射不能错（写错一个字母 = 那个板块永远空白）；
//   2. 搜索必须"三路并发"，不允许退回"引擎 → 后端 → 才轮到本机源"的
//      三选一分支 —— 那个分支正是"装着源却一个都用不上"的根因。
//
// 第 2 条用源码扫描而不是单元测试：它是调用点的形状，没有可注入的依赖，
// 而这恰恰是最容易被后来者改回去的地方（改回去编译能过、UI 也能跑，
// 只是本机源又静默失效了）。源码断言能把这种回归挡在 CI。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/agg/board_feed.dart';
import 'package:thirdhub_app/core/free/free_models.dart';

void main() {
  /// 取某个类的源码片段（到下一个顶层 `class ` 为止）。
  String _classBody(String src, String name) {
    final i = src.indexOf('class $name ');
    if (i < 0) return '';
    final j = src.indexOf('\nclass ', i + 10);
    return j < 0 ? src.substring(i) : src.substring(i, j);
  }

  group('板块 → 通路映射', () {
    test('后端路径与板块名一致', () {
      expect(BoardKind.comic.apiPath, '/v1/comic/search?q=');
      expect(BoardKind.music.apiPath, '/v1/music/search?q=');
      expect(BoardKind.video.apiPath, '/v1/video/search?q=');
      expect(BoardKind.novel.apiPath, '/v1/novel/search?q=');
    });

    test('开放源类型映射：小说走公版书', () {
      expect(BoardKind.comic.freeKind, FreeKind.comic);
      expect(BoardKind.music.freeKind, FreeKind.music);
      expect(BoardKind.video.freeKind, FreeKind.video);
      // 公版书是本机直连里唯一能"读整本"的内容，正好当小说兜底。
      expect(BoardKind.novel.freeKind, FreeKind.book);
    });

    test('中文板块名与引擎 type 同一口径', () {
      expect(BoardKind.comic.label, '漫画');
      expect(BoardKind.video.label, '视频');
      // 引擎的 type 参数直接复用它 —— 两边名字不一样就会"引擎搜不到东西"。
      expect(BoardKind.music.name, 'music');
    });
  });

  group('聚合结果计数', () {
    test('三路条数相加等于总数', () {
      const r = BoardFeedResult([], fromBackend: 3, fromEngine: 2, fromLocal: 5);
      expect(r.total, 10);
      expect(r.isEmpty, isFalse);
    });

    test('三路全空才算空', () {
      const r = BoardFeedResult([]);
      expect(r.isEmpty, isTrue);
    });

    test('只有本机源有内容也不算空', () {
      // 这是最关键的一条：后端和引擎都挂掉时，本机源兜住就还有内容。
      const r = BoardFeedResult([], fromLocal: 4);
      expect(r.isEmpty, isFalse);
    });

    test('有错误 ≠ 没答复，两者语义不同', () {
      const silent = BoardFeedResult([]);
      expect(silent.anyAnswered, isTrue);
      const errored = BoardFeedResult([], errors: ['free: timeout']);
      expect(errored.anyAnswered, isFalse);
    });
  });

  group('调用点形状（防回退）', () {
    final mainSrc = File('lib/main.dart').readAsStringSync();

    test('三个板块的搜索都调 BoardFeed.search', () {
      expect(mainSrc.contains('BoardFeed.search(BoardKind.comic'), isTrue);
      expect(mainSrc.contains('BoardFeed.search(BoardKind.music'), isTrue);
      expect(mainSrc.contains('BoardFeed.search(BoardKind.video'), isTrue);
    });

    test('不再有「后端在线就跳过本机源」的 else-if 链', () {
      // 旧形状是：
      //   if (EngineDirect.connected) { ... }
      //   else if (Api.base.isNotEmpty) { ... }
      //   else { 本机源 }
      // 只要这个组合还在，本机源就只在"既没引擎又没后端"时才可能被用到。
      //
      // 按类切片而不是扫全文件：直播页（LivePage）确实还要直连引擎的
      // 频道列表，那是另一种内容形态，不该被这条规则误伤。
      for (final cls in ['_CSR', '_MSR', '_VSR']) {
        final body = _classBody(mainSrc, cls);
        expect(body, isNotEmpty, reason: '找不到 $cls，类名改过了？');
        expect(
          body.contains('EngineDirect.search('),
          isFalse,
          reason: '$cls 仍在直接调引擎搜索 —— 应统一走 BoardFeed 聚合',
        );
        expect(
          body.contains('Api.get(\'/v1/'),
          isFalse,
          reason: '$cls 仍在直接调后端搜索 —— 本机源会被绕过',
        );
        expect(body.contains('BoardFeed.search('), isTrue,
            reason: '$cls 没有接上聚合层');
      }
    });
  });
}
