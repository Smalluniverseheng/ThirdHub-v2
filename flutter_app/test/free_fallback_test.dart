// 开放内容兜底：主板块空态「用开放内容搜索」的映射规则。
//
// 为什么单测而不是 widget 测试：真正要保证的是「搜漫画进漫画 tab」这类
// 路由规则，widget 测试要挂真实网络探测（FreeReach.probeAll）会拖死 CI。
// 这里只测纯函数，把可回归的逻辑钉死。

import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/free/free_models.dart';

void main() {
  group('freeKindForBoard 板块映射', () {
    test('中文板块名映射到对应 tab', () {
      expect(freeKindForBoard('小说'), FreeKind.book);
      expect(freeKindForBoard('漫画'), FreeKind.comic);
      expect(freeKindForBoard('视频'), FreeKind.video);
      expect(freeKindForBoard('音乐'), FreeKind.music);
    });

    test('英文/别名也能映射（CLI、深链、AI 工具可能传英文）', () {
      expect(freeKindForBoard('novel'), FreeKind.book);
      expect(freeKindForBoard('comic'), FreeKind.comic);
      expect(freeKindForBoard('video'), FreeKind.video);
      expect(freeKindForBoard('music'), FreeKind.music);
      expect(freeKindForBoard('影视'), FreeKind.video);
    });

    test('未知板块/总搜索兜底到音乐 tab（源最全，不会白页）', () {
      expect(freeKindForBoard('全部'), FreeKind.music);
      expect(freeKindForBoard(''), FreeKind.music);
      expect(freeKindForBoard('某个没见过的板块'), FreeKind.music);
    });
  });
}
