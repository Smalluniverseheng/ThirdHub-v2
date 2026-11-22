// 板块端上直连的**真实联网**验证（默认跳过，手动跑）。
//
// 为什么默认跳过：CI 环境不保证能访问境外源站（MangaDex / PeerTube / Audius），
// 让它在 CI 里跑会把「网络不通」变成「构建失败」，属于假红。
// 手动验证命令：
//   flutter test test/board_direct_live_test.dart --run-skipped
//
// 这条测试要回答的问题只有一个：
//   **手机上既没连引擎、也没连后端时，漫画/音乐/影视三个板块到底能不能出内容？**
//   4.81.87 之前答案是不能（只有一句「还没连上内容来源」）。

import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/free/free_board.dart';
import 'package:thirdhub_app/core/free/free_models.dart';

const _skip = '需要联网真实请求源站，手动跑：--run-skipped';

void main() {
  group('本机直连：三个板块各自能出内容', () {
    test('漫画：搜「火影」能命中 MangaDex', () async {
      final items = await FreeBoard.search(FreeKind.comic, '火影');
      // ignore: avoid_print
      print('漫画 命中 ${items.length} 条'
          '${items.isEmpty ? '' : '，首条：${items.first.title} / ${items.first.source}'}');
      expect(items, isNotEmpty,
          reason: 'MangaDex 搜「火影」应有结果（靠 altTitles 里的中文译名）');
      // 必须带可下钻的标记，否则点进去没有章节列表
      expect(items.any((e) => e.drill), isTrue,
          reason: '漫画条目应可下钻到章节，否则点进去是空页');
    }, skip: _skip);

    test('视频：搜 music 能命中 PeerTube', () async {
      final items = await FreeBoard.search(FreeKind.video, 'music');
      // ignore: avoid_print
      print('视频 命中 ${items.length} 条'
          '${items.isEmpty ? '' : '，首条：${items.first.title} / ${items.first.source}'}');
      expect(items, isNotEmpty, reason: 'PeerTube 搜英文词应有结果');
    }, skip: _skip);

    test('音乐：搜「周杰伦」能命中 Audius', () async {
      final items = await FreeBoard.search(FreeKind.music, '周杰伦');
      // ignore: avoid_print
      print('音乐 命中 ${items.length} 条'
          '${items.isEmpty ? '' : '，首条：${items.first.title} / ${items.first.source}'}');
      // Audius 以英文内容为主，中文词可能真的没有 —— 这里只要求「不抛异常」。
      // 真正的断言放在下面的非空搜索里。
    }, skip: _skip);

    test('音乐：搜英文词能出可播结果', () async {
      final items = await FreeBoard.search(FreeKind.music, 'love');
      // ignore: avoid_print
      print('音乐(love) 命中 ${items.length} 条，'
          '其中 ${items.where((e) => e.playUrl.isNotEmpty).length} 条带播放地址');
      expect(items, isNotEmpty, reason: 'Audius 搜 love 应有结果');
      expect(items.any((e) => e.playUrl.isNotEmpty), isTrue,
          reason: '至少要有可直接播放的地址，否则列表点了放不出声');
    }, skip: _skip);
  });

  group('搜不到时不抛异常', () {
    test('没有内容的词返回空列表而不是报错', () async {
      // 这个词在任何源站都不该有结果。返回空 → 板块页显示「这一条没有命中」；
      // 抛异常 → 板块页会弹出红色错误条，那是完全不同的体验。
      final items = await FreeBoard.search(FreeKind.comic, 'zzzzz_no_such_thing_9182');
      expect(items, isEmpty);
    }, skip: _skip);
  });
}
