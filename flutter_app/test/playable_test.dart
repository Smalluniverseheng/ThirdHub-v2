// 逐条可播的判定口径（4.81.90）。
//
// 锁死三件事：
//   1. 候选链收集正确（主地址 + playAlts，去重保序）；
//   2. 「已失效」= 所有候选都探明已死 / 被实锤标记；**未知不算失效**；
//   3. 打开时优先给活口（liveCandidate），全死给 null。
import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/agg/playable.dart';
import 'package:thirdhub_app/core/free/free_models.dart';

FreeItem _item(String id, String playUrl, {List<String> alts = const []}) =>
    FreeItem(
      id: id,
      source: 'test',
      kind: FreeKind.music,
      title: 't$id',
      playUrl: playUrl,
      raw: {if (alts.isNotEmpty) 'playAlts': alts},
    );

void main() {
  setUp(Playable.reset);

  group('候选地址', () {
    test('主地址 + 备选，去重保序', () {
      final it = _item('1', 'https://a/1.mp3', alts: [
        'https://b/2.mp3',
        'https://a/1.mp3', // 与主地址重复 → 只留一份
        'https://c/3.mp3',
      ]);
      expect(Playable.candidatesOf(it),
          ['https://a/1.mp3', 'https://b/2.mp3', 'https://c/3.mp3']);
    });

    test('空地址不进候选', () {
      final it = _item('2', '');
      expect(Playable.candidatesOf(it), isEmpty);
    });
  });

  group('死活判定', () {
    test('没探过 = 未知，不拦', () {
      final it = _item('1', 'https://a/x.mp3');
      expect(Playable.isDead(it), isFalse);
      expect(Playable.isOk(it), isFalse);
      expect(Playable.liveCandidate(it), 'https://a/x.mp3');
    });

    test('唯一地址探死 = 整条失效', () {
      final it = _item('1', 'https://a/x.mp3');
      Playable.markUrl('https://a/x.mp3', false);
      expect(Playable.isDead(it), isTrue);
      expect(Playable.liveCandidate(it), isNull);
    });

    test('有活口就不算失效，优先返回活口', () {
      final it = _item('1', 'https://a/x.mp3',
          alts: ['https://b/y.mp3', 'https://c/z.mp3']);
      Playable.markUrl('https://a/x.mp3', false);
      Playable.markUrl('https://b/y.mp3', false);
      Playable.markUrl('https://c/z.mp3', true);
      expect(Playable.isDead(it), isFalse);
      expect(Playable.isOk(it), isTrue);
      expect(Playable.liveCandidate(it), 'https://c/z.mp3');
    });

    test('主地址死了但备选没探过 → 给备选（不误杀）', () {
      final it = _item('1', 'https://a/x.mp3', alts: ['https://b/y.mp3']);
      Playable.markUrl('https://a/x.mp3', false);
      expect(Playable.isDead(it), isFalse);
      expect(Playable.liveCandidate(it), 'https://b/y.mp3');
    });

    test('实锤标记（播放失败）直接失效', () {
      final it = _item('1', 'https://a/x.mp3');
      Playable.markDead(it);
      expect(Playable.isDead(it), isTrue);
    });
  });

  group('后台扫', () {
    test('探到第一个活口就停，不再探备选', () async {
      final probed = <String>[];
      Playable.probeImpl = (url) async {
        probed.add(url);
        return url.contains('b');
      };
      final it = _item('1', 'https://a/x.mp3',
          alts: ['https://b/y.mp3', 'https://c/z.mp3']);
      await Playable.sweep([it]);
      expect(probed, ['https://a/x.mp3', 'https://b/y.mp3']);
      expect(Playable.isOk(it), isTrue);
    });

    test('没有直链的形态（书/漫画）不探', () async {
      var calls = 0;
      Playable.probeImpl = (_) async {
        calls++;
        return true;
      };
      final book = const FreeItem(
          id: 'b1', source: 'gutenberg', kind: FreeKind.book, title: '书');
      await Playable.sweep([book]);
      expect(calls, 0);
    });

    test('limit 限制探活条数', () async {
      var calls = 0;
      Playable.probeImpl = (_) async {
        calls++;
        return false;
      };
      final items = [
        for (var i = 0; i < 5; i++) _item('$i', 'https://a/$i.mp3')
      ];
      await Playable.sweep(items, limit: 2);
      expect(calls, 2);
    });

    test('每条出结果回调一次（列表徽标靠它实时亮）', () async {
      Playable.probeImpl = (_) async => false;
      var updates = 0;
      await Playable.sweep(
        [_item('1', 'https://a/1.mp3'), _item('2', 'https://a/2.mp3')],
        onUpdate: () => updates++,
      );
      expect(updates, 2);
    });
  });
}
