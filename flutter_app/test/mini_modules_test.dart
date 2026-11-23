// mini_modules 里提升为纯函数的两块业务逻辑单测：
//   todoNextDue —— 周期待办的下一次到期推算（月末钳制 / 落后追上）
//   ledgerCsv   —— 记账导出 CSV 的字段转义（逗号/引号/换行）
import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/mini_modules.dart';

void main() {
  group('todoNextDue', () {
    final now = DateTime(2026, 11, 24, 12).millisecondsSinceEpoch;

    test('每天：+1 天', () {
      final due = DateTime(2026, 11, 24, 9).millisecondsSinceEpoch;
      final next = todoNextDue(due, 'day', now: now);
      expect(DateTime.fromMillisecondsSinceEpoch(next),
          DateTime(2026, 11, 25, 9));
    });

    test('每周：+7 天', () {
      final due = DateTime(2026, 11, 24, 9).millisecondsSinceEpoch;
      final next = todoNextDue(due, 'week', now: now);
      expect(DateTime.fromMillisecondsSinceEpoch(next),
          DateTime(2026, 12, 1, 9));
    });

    test('每月：1月31日钳制到2月末，不许溢出到3月3日', () {
      final due = DateTime(2026, 1, 31).millisecondsSinceEpoch;
      final next = todoNextDue(due, 'month',
          now: DateTime(2026, 2, 1).millisecondsSinceEpoch);
      expect(DateTime.fromMillisecondsSinceEpoch(next),
          DateTime(2026, 2, 28));
    });

    test('闰年 2月29日 +1月钳制到3月29日之后的自然日', () {
      final due = DateTime(2024, 1, 31).millisecondsSinceEpoch;
      final next = todoNextDue(due, 'month',
          now: DateTime(2024, 2, 1).millisecondsSinceEpoch);
      expect(DateTime.fromMillisecondsSinceEpoch(next),
          DateTime(2024, 2, 29)); // 2024 是闰年
    });

    test('到期时间已落后于现在：一路滚到未来', () {
      final due = DateTime(2026, 11, 1).millisecondsSinceEpoch;
      final next = todoNextDue(due, 'day', now: now);
      expect(next, greaterThan(now));
    });

    test('到期时间还在未来：原样返回不推进', () {
      final due = DateTime(2026, 12, 25, 9).millisecondsSinceEpoch;
      final next = todoNextDue(due, 'day', now: now);
      expect(next, due);
    });
  });

  group('ledgerCsv', () {
    test('普通行输出五列', () {
      final csv = ledgerCsv([
        {
          'amount': 12.5,
          'cat': '餐饮',
          'note': '午饭',
          'income': false,
          'ts': DateTime(2026, 11, 24, 12, 30).millisecondsSinceEpoch
        }
      ]);
      final lines = csv.trim().split('\n');
      expect(lines.first, '日期,分类,备注,类型,金额');
      expect(lines.last.split(','), hasLength(5));
      expect(lines.last, contains('餐饮'));
      expect(lines.last, contains('-12.50'));
    });

    test('备注含逗号/引号/换行时按 RFC4180 转义', () {
      final csv = ledgerCsv([
        {
          'amount': 1,
          'cat': '其他',
          'note': 'a,b "c"\nd',
          'income': true,
          'ts': DateTime(2026, 11, 24).millisecondsSinceEpoch
        }
      ]);
      // 引号内换行会跨物理行，必须查全串而不是 split('\n')
      expect(csv, contains('"a,b ""c""\nd"'));
      expect(csv, contains('+1.00'));
    });

    test('空列表只有表头', () {
      expect(ledgerCsv([]).trim().split('\n'), hasLength(1));
    });
  });
}
