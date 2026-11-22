// 板块端上直连（FreeBoard）的行为钉死。
//
// 为什么这几条值得单测：漫画/音乐/影视三个板块的列表原来只认两种数据形状
// （后端 Map / 引擎 Map）。4.81.87 加了第三种（FreeItem 对象）。
// 一旦某处把 FreeItem 当成 Map 去 `b['coverUrl']`，运行时就抛
// "type 'FreeItem' is not a subtype of type 'Map'" —— 而这类错误
// 只有在真机上点到那条结果时才会暴露，静态分析查不出来。
// 所以这里把「形状标记」和「互斥判定」都锁住。

import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/free/free_board.dart';
import 'package:thirdhub_app/core/free/free_models.dart';

FreeItem _item(String title) => FreeItem(
      id: 'x1',
      source: 'test_source',
      kind: FreeKind.comic,
      title: title,
    );

void main() {
  group('FreeBoard.group 形状', () {
    test('标记 ok 与 free，items 原样放进 List', () {
      final items = [_item('A'), _item('B')];
      final g = FreeBoard.group(items);
      expect(g['ok'], true);
      expect(g['free'], true);
      expect(g['items'], isA<List<FreeItem>>());
      expect((g['items'] as List).length, 2);
    });

    test('元素仍是 FreeItem，不被转成 Map', () {
      final g = FreeBoard.group([_item('A')]);
      expect((g['items'] as List).first, isA<FreeItem>());
    });
  });

  group('FreeBoard.isFree 判定', () {
    test('本机直连的分组为真', () {
      expect(FreeBoard.isFree(FreeBoard.group([_item('A')])), isTrue);
    });

    test('后端/引擎分组为假（它们没有 free 标记）', () {
      expect(FreeBoard.isFree({'ok': true, 'items': <Map>[]}), isFalse);
      expect(FreeBoard.isFree({'ok': true, 'engine': true, 'items': []}),
          isFalse);
    });

    test('free 必须严格等于 true，字符串 "true" 不算', () {
      expect(FreeBoard.isFree({'free': 'true'}), isFalse);
      expect(FreeBoard.isFree({'free': false}), isFalse);
    });

    test('空分组不抛', () {
      expect(FreeBoard.isFree(<String, dynamic>{}), isFalse);
    });
  });

  group('数据形状互斥', () {
    test('本机直连分组不会被后端分支同时接走', () {
      final g = FreeBoard.group([_item('A')]);
      // 渲染层用的是这个组合条件：后端分支必须排除 free 分组，
      // 否则同一条结果会被画两次、并且后端分支还会抛类型错。
      final backendBranch =
          !FreeBoard.isFree(g) && g['ok'] == true && (g['items'] as List).isNotEmpty;
      expect(backendBranch, isFalse);
    });

    test('后端分组仍走后端分支', () {
      final g = {'ok': true, 'items': [{'name': 'x'}]};
      final backendBranch =
          !FreeBoard.isFree(g) && g['ok'] == true && (g['items'] as List).isNotEmpty;
      expect(backendBranch, isTrue);
    });
  });
}
