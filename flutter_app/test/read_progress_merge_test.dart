// 阅读进度多端合并（4.81.90）的口径。
//
// 真实事故：手机读到 20 章，平板随手翻到 6 章并带上"此刻"时间戳上云 ——
// 按"谁后写谁赢"20 章就没了。所以口径是：**读得远的胜，进度只进不退**；
// 同章取时间新者；本机正在重读前几章时，云端更深的旧记录也不许打回。
import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/sync_contract.dart';

Map<String, dynamic> _row(int ci, int ts) =>
    <String, dynamic>{'chapterIndex': ci, 'ts': ts};

void main() {
  group('progressRowMerge（写云端前的合并）', () {
    test('读得远的胜，哪怕时间更旧 —— 进度只进不退', () {
      // 平板 ch6/此刻 vs 云端 ch20/昨天 → 20 章活下来
      final m = progressRowMerge(_row(6, 200), _row(20, 100));
      expect(m['chapterIndex'], 20);
      expect(m['ts'], 100);
    });

    test('反方向同理：本机读得远就推本机的', () {
      final m = progressRowMerge(_row(21, 100), _row(20, 200));
      expect(m['chapterIndex'], 21);
      expect(m['ts'], 100);
    });

    test('同一章取时间新者', () {
      final m = progressRowMerge(_row(7, 100), _row(7, 200));
      expect(m['chapterIndex'], 7);
      expect(m['ts'], 200);
    });

    test('负数章节归零，不把脏数据推上去', () {
      final m = progressRowMerge(_row(-3, 200), _row(0, 100));
      expect(m['chapterIndex'], 0);
      expect(m['ts'], 200); // 同为 0 章 → 时间新者胜
    });

    test('输出是归一化副本，不动输入', () {
      final a = _row(3, 50);
      final b = {'chapterIndex': '9', 'ts': '60'}; // 字符串数字也要认
      final m = progressRowMerge(a, b);
      expect(m['chapterIndex'], 9);
      expect(m['ts'], 60);
      expect(a['chapterIndex'], 3); // a 原样
    });
  });

  group('progressPullApplies（云端要不要落进本机）', () {
    test('本机没读过 → 云端说什么都收', () {
      expect(
          progressPullApplies(
              cloudCi: 5, cloudTs: 100, localCi: -1, localTs: 0),
          isTrue);
    });

    test('换设备续读：云端更深且不旧 → 落', () {
      expect(
          progressPullApplies(
              cloudCi: 20, cloudTs: 200, localCi: 5, localTs: 100),
          isTrue);
    });

    test('云端更浅 → 不退本机', () {
      expect(
          progressPullApplies(
              cloudCi: 6, cloudTs: 300, localCi: 20, localTs: 100),
          isFalse);
    });

    test('重读保护：云端更深但本机是新动作 → 不打回', () {
      // 用户正在重读前几章（本机 ch3/此刻），云端 ch20/昨天不许劫持
      expect(
          progressPullApplies(
              cloudCi: 20, cloudTs: 100, localCi: 3, localTs: 200),
          isFalse);
    });

    test('同章只在云端时间更新时对表', () {
      expect(
          progressPullApplies(
              cloudCi: 9, cloudTs: 200, localCi: 9, localTs: 100),
          isTrue);
      expect(
          progressPullApplies(
              cloudCi: 9, cloudTs: 100, localCi: 9, localTs: 100),
          isFalse);
    });
  });
}
