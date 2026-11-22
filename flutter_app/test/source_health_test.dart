// SourceHealth 源健康判定的单测。
//
// 这层的每条规则都对应用户的一个具体抱怨：
// 「结果我点进去一看没一个能用的」——因为坏源没有被摘掉，只是被列在横幅上。
// 「自动检测这些源能不能用」——检测必须变成行为（跳过请求），而不是文案。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thirdhub_app/core/agg/source_health.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SourceHealth.ensureLoaded();
    await SourceHealth.reset();
  });

  group('判定口径', () {
    test('没记录过的源默认可用', () {
      expect(SourceHealth.isUsable('mangadex'), isTrue);
    });

    test('单次抖动不冷却 —— 一次失败仍可用', () {
      SourceHealth.reportFail('mangadex', '超时');
      expect(SourceHealth.isUsable('mangadex'), isTrue);
    });

    test('连续两次失败进冷却', () {
      SourceHealth.reportFail('mangadex', '超时');
      SourceHealth.reportFail('mangadex', '超时');
      expect(SourceHealth.isUsable('mangadex'), isFalse);
      expect(SourceHealth.cooldownLeft('mangadex'), isNotNull);
    });

    test('冷却只影响该源，不连坐', () {
      SourceHealth.reportFail('a', 'x');
      SourceHealth.reportFail('a', 'x');
      expect(SourceHealth.isUsable('a'), isFalse);
      expect(SourceHealth.isUsable('b'), isTrue);
    });

    test('成功一次立刻清零恢复', () {
      SourceHealth.reportFail('a', 'x');
      SourceHealth.reportFail('a', 'x');
      expect(SourceHealth.isUsable('a'), isFalse);
      SourceHealth.reportOk('a', ms: 120, count: 5);
      expect(SourceHealth.isUsable('a'), isTrue);
      expect(SourceHealth.failsOf('a'), 0);
    });

    test('返回 0 条是正常答复，不算失败', () {
      // 「火影」在 MangaDex 是「狐忍」，搜不到不代表源坏了 ——
      // 这一条是判据里最容易写错、后果最伤的一条。
      SourceHealth.reportOk('a', ms: 300, count: 0);
      expect(SourceHealth.failsOf('a'), 0);
      expect(SourceHealth.isUsable('a'), isTrue);
    });

    test('软失败（格式问题）只记原因，不进冷却', () {
      for (var i = 0; i < 5; i++) {
        SourceHealth.reportFail('a', '解析不到字段', soft: true);
      }
      expect(SourceHealth.isUsable('a'), isTrue);
      expect(SourceHealth.failsOf('a'), 0);
    });
  });

  group('体检快照', () {
    test('快照含成败与冷却信息', () {
      SourceHealth.reportFail('mangadex', '网络不通');
      SourceHealth.reportFail('mangadex', '网络不通');
      SourceHealth.reportOk('audius', ms: 80, count: 12);

      final rows = SourceHealth.snapshot();
      expect(rows.length, 2);

      final a = rows.firstWhere((r) => r['id'] == 'mangadex');
      expect(a['cooling'], isTrue);
      expect(a['reason'], '网络不通');

      final b = rows.firstWhere((r) => r['id'] == 'audius');
      expect(b['cooling'], isFalse);
      expect(b['lastCount'], 12);
      expect(b['lastMs'], 80);
    });

    test('冷却中的源计数准确', () {
      SourceHealth.reportFail('a', 'x');
      SourceHealth.reportFail('a', 'x');
      expect(SourceHealth.coolingCount, 1);
    });
  });

  group('重检', () {
    test('reset 清掉单源账单', () async {
      SourceHealth.reportFail('a', 'x');
      SourceHealth.reportFail('a', 'x');
      await SourceHealth.reset('a');
      expect(SourceHealth.isUsable('a'), isTrue);
    });

    test('reset 全清后所有源可用', () async {
      SourceHealth.reportFail('a', 'x');
      SourceHealth.reportFail('a', 'x');
      SourceHealth.reportFail('b', 'x');
      SourceHealth.reportFail('b', 'x');
      await SourceHealth.reset();
      expect(SourceHealth.coolingCount, 0);
    });
  });
}
