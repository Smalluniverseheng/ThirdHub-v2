// TextClean 正文清洗的规则单测。
//
// 这些规则每一条都是为了修掉一个具体的"正文参差不齐"：
// 逐源手剥永远剥不干净，而且剥法互相不一致 —— 用测试把口径钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/agg/text_clean.dart';

void main() {
  group('物理规整', () {
    test('换行统一成 \\n，不再混用 \\r\\n', () {
      expect(TextClean.body('a\r\nb\rc'), 'a\nb\nc');
    });

    test('全角空格与不换行空格统一成半角', () {
      expect(TextClean.body('a\u3000b\u00A0c'), 'a b c');
    });

    test('零宽空格与 BOM 剥掉', () {
      expect(TextClean.body('\uFEFF正文\u200B完'), '正文完');
    });

    test('三个以上连续空行压成两个', () {
      final s = TextClean.body('第一段\n\n\n\n\n第二段');
      expect(s, contains('第一段\n\n第二段'));
      expect(s.contains('\n\n\n'), isFalse);
    });
  });

  group('古登堡样板', () {
    test('星号标记头尾被剥掉，正文保留', () {
      final raw = '''
THE PROJECT GUTENBERG EBOOK OF MOBY DICK

Copyright notices here.

*** START OF THE PROJECT GUTENBERG EBOOK MOBY DICK ***

Call me Ishmael.

*** END OF THE PROJECT GUTENBERG EBOOK MOBY DICK ***

Post-book license text.
''';
      final t = TextClean.body(raw, kind: TextSourceKind.gutenberg);
      expect(t, contains('Call me Ishmael.'));
      expect(t, isNot(contains('PROJECT GUTENBERG')));
      expect(t, isNot(contains('Copyright notices')));
      expect(t, isNot(contains('Post-book license')));
    });

    test('旧版行式标记也被剥掉', () {
      final raw = '''
Project Gutenberg EBook of A Tale of Two Cities, by Charles Dickens

It was the best of times.

End of the Project Gutenberg EBook of A Tale of Two Cities
''';
      final t = TextClean.body(raw, kind: TextSourceKind.gutenberg);
      expect(t, contains('It was the best of times.'));
      expect(t, isNot(contains('Project Gutenberg EBook')));
      expect(t, isNot(contains('End of the Project Gutenberg')));
    });

    test('没有样板时不误伤正文', () {
      const raw = '第一章\n\n风把门吹开了。';
      expect(TextClean.body(raw, kind: TextSourceKind.gutenberg), raw);
    });
  });

  group('维基文库残留', () {
    test('编辑链接整行删掉', () {
      final t = TextClean.body('正文一行\n\n[编辑]\n\n正文二行',
          kind: TextSourceKind.wikisource);
      expect(t, isNot(contains('编辑')));
      expect(t, contains('正文一行'));
      expect(t, contains('正文二行'));
    });

    test('分类页尾起整段丢掉', () {
      final t = TextClean.body('正文\n\n分类:\n中国文学\n古典小说',
          kind: TextSourceKind.wikisource);
      expect(t.trim(), '正文');
    });

    test('出处行与折叠表头删掉', () {
      final t = TextClean.body(
          '正文\n隐藏\n取自"https://zh.wikisource.org/wiki/x"\n本页面最后编辑于2020年1月1日',
          kind: TextSourceKind.wikisource);
      expect(t.trim(), '正文');
    });

    test('不误删正文里的方括号内容', () {
      const raw = '他喊了一声[谁呀]便走了。';
      expect(TextClean.body(raw, kind: TextSourceKind.wikisource), raw);
    });
  });

  group('中文标点与空格', () {
    test('标点后面的空格删掉', () {
      expect(TextClean.body('你好 ， 世界 。'), '你好，世界。');
    });

    test('两个汉字之间的空格合并', () {
      expect(TextClean.body('沈 从 文'), '沈从文');
    });
  });

  group('looksLikeBody', () {
    test('够长的正文通过', () {
      expect(
          TextClean.looksLikeBody('风把门吹开了，他走进去，屋子里坐着三个人，'
              '一言不发，只有窗外的雨声。他把手里的伞收起来，'
              '在门槛上磕了两下，才迈步进去，屋里很暗。'),
          isTrue);
    });

    test('太短的不算正文', () {
      expect(TextClean.looksLikeBody('目录'), isFalse);
    });

    test('纯数字与空白不算正文', () {
      expect(TextClean.looksLikeBody('123 456 789 012 345 678 901 234 567 890'),
          isFalse);
    });
  });
}
