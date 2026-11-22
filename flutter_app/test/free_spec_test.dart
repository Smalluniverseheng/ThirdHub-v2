// 声明式源引擎的单元测试。
//
// 这里只测**纯函数与解析**，不打网络 —— 网络部分由
// `tool/free_spec_probe.dart` 在真实环境里跑（那里的结论更可信，
// 但也更慢、更依赖当天网络，不适合放进 CI）。
//
// 锁三件事：
//   1. 取值语法（json / html / rss）不能悄悄改坏 —— 改坏了所有导入源会同时失效；
//   2. 安全边界（协议白名单、Host 头、CRLF）不能松；
//   3. 源包的容错口径（坏源跳过、好源照用、schema 过高拒绝）。
import 'package:flutter_test/flutter_test.dart';
import 'package:thirdhub_app/core/free/free_bundle.dart';
import 'package:thirdhub_app/core/free/free_models.dart';
import 'package:thirdhub_app/core/free/free_policy.dart';
import 'package:thirdhub_app/core/free/free_spec.dart';

void main() {
  group('pickJson 取值语法', () {
    final data = {
      'result': {
        'songs': [
          {'name': 'A', 'id': 1, 'artists': [{'name': '张三'}, {'name': '李四'}]},
          {'name': 'B', 'id': 2, 'artists': [{'name': '王五'}]},
        ],
        'total': 2,
      },
      'title': '《论语》',
    };

    test('逐层取', () {
      expect(pickJson(data, 'title'), '《论语》');
      expect(pickJson(data, 'result.total'), '2');
    });

    test('下标', () {
      expect(pickJson(data, 'result.songs[0].name'), 'A');
      expect(pickJson(data, 'result.songs.1.name'), 'B');
    });

    test('遍历拼接', () {
      // 同一个数组里多个元素用 `、` 连起来：这是"多作者"最常见的展示需求
      expect(pickJson(data, 'result.songs[0].artists[].name'), '张三、李四');
    });

    test('在数组上直接取字段', () {
      expect(pickJson(data, 'result.songs[].name'), 'A、B');
    });

    test('取不到返回空串而不是抛异常', () {
      expect(pickJson(data, 'nope.at.all'), '');
      expect(pickJson(data, 'result.songs[9].name'), '');
      expect(pickJson(null, 'a.b'), '');
    });

    test('根节点', () {
      expect(pickJson('x', r'$'), 'x');
    });

    test('数值转字符串', () {
      expect(pickJson({'n': 42}, 'n'), '42');
    });
  });

  group('pickHtml 取值', () {
    const doc = '''
      <div class="item"><a class="t" href="/b/1">书名一</a>
        <p class="intro">简介<b>加粗</b></p></div>
      <div class="item"><a class="t" href="/b/2">书名二</a></div>
    ''';

    test('取文本', () {
      expect(pickHtml(doc, 'a.t'), '书名一');
    });

    test('取属性', () {
      expect(pickHtml(doc, 'a.t@href'), '/b/1');
    });

    test('取内层 HTML', () {
      expect(pickHtml(doc, 'p.intro@html'), contains('加粗'));
    });

    test('选择器写错不炸', () {
      expect(pickHtml(doc, '(((('), '');
      expect(pickHtml(doc, 'div.nope'), '');
    });
  });

  group('pickRss 取值', () {
    const item = '''
      <item>
        <title><![CDATA[第 1 期]]></title>
        <description>简介 &amp; 说明</description>
        <enclosure url="https://a.com/x.m4a?c=1&amp;d=2" type="audio/mp4" length="1"/>
        <itunes:image href="https://a.com/c.jpg"/>
      </item>
    ''';

    test('标签文本（剥 CDATA）', () {
      expect(pickRss(item, 'title'), '第 1 期');
    });

    test('属性取值', () {
      expect(pickRss(item, 'enclosure@url'), 'https://a.com/x.m4a?c=1&d=2');
    });

    test('带冒号的标签', () {
      expect(pickRss(item, 'itunes:image@href'), 'https://a.com/c.jpg');
    });

    test('不存在的标签返回空', () {
      expect(pickRss(item, 'nope'), '');
      expect(pickRss(item, 'enclosure@nope'), '');
    });
  });

  group('FieldSpec 模板', () {
    test('字符串简写等价于 path', () {
      final f = FieldSpec.parse('a.b')!;
      expect(f.path, 'a.b');
      expect(f.isTemplate, isFalse);
    });

    test('tpl 是模板而不是路径', () {
      final f = FieldSpec.parse({'tpl': 'https://x/{id}.mp3'})!;
      expect(f.isTemplate, isTrue);
      expect(f.tpl, 'https://x/{id}.mp3');
    });

    test('同时写 path 与 tpl 时以模板为准（模板会覆盖取到的新值）', () {
      final f = FieldSpec.parse({'path': 'a', 'tpl': 'b'})!;
      expect(f.isTemplate, isTrue);
    });

    test('修饰符', () {
      final f = FieldSpec.parse({'path': 'img', 'abs': true, 'strip': true})!;
      expect(f.abs, isTrue);
      expect(f.strip, isTrue);
    });
  });

  group('FreeSourceSpec 校验', () {
    FreeSourceSpec? parse(Map<String, dynamic> m) => FreeSourceSpec.parse(m);

    test('缺 license 时按最严处理', () {
      final s = parse({
        'id': 'x1',
        'name': 'X',
        'kind': 'music',
        'search': {'path': '/s'},
      })!;
      // 不能给默认放行 —— 写不出来源的授权就该按最严算
      expect(s.license, LicenseKind.thirdPartyRule);
      expect(s.license.mobileSafe, isFalse);
    });

    test('file:// 一律拒绝', () {
      final s = parse({
        'id': 'x2',
        'name': 'X',
        'kind': 'music',
        'base': 'file:///etc/passwd',
        'search': {'path': '/s'},
      })!;
      expect(s.validate().any((e) => e.contains('http')), isTrue);
    });

    test('禁止指定 Host 头（防请求走私）', () {
      final s = parse({
        'id': 'x3',
        'name': 'X',
        'kind': 'music',
        'base': 'https://a.com',
        'search': {
          'path': '/s',
          'headers': {'Host': 'b.com'},
        },
      })!;
      expect(s.validate().any((e) => e.contains('Host')), isTrue);
    });

    test('请求头不许含换行', () {
      final s = parse({
        'id': 'x4',
        'name': 'X',
        'kind': 'music',
        'base': 'https://a.com',
        'search': {
          'path': '/s',
          'headers': {'X-A': 'v\r\nX-B: v'},
        },
      })!;
      expect(s.validate().any((e) => e.contains('换行')), isTrue);
    });

    test('id 必须是小写字母数字下划线', () {
      final s = parse({
        'id': 'Bad-ID!',
        'name': 'X',
        'kind': 'music',
        'search': {'path': '/s'},
      })!;
      expect(s.validate().any((e) => e.contains('id')), isTrue);
    });

    test('非法 kind 直接解析失败', () {
      expect(
          parse({
            'id': 'x5',
            'name': 'X',
            'kind': 'nonsense',
            'search': {'path': '/s'},
          }),
          isNull);
    });

    test('相对地址按 base 补全', () {
      final s = parse({
        'id': 'x6',
        'name': 'X',
        'kind': 'music',
        'base': 'https://a.com',
        'search': {'path': '/s'},
      })!;
      expect(s.resolve('/v1/x'), 'https://a.com/v1/x');
      expect(s.resolve('v1/x'), 'https://a.com/v1/x');
      // 已经是完整地址就原样返回
      expect(s.resolve('https://b.com/y'), 'https://b.com/y');
    });
  });

  group('FreeSourceBundle 解析', () {
    const good = '''
    {"id":"ok1","name":"好源","kind":"music","license":"officialApi",
     "base":"https://a.com","search":{"path":"/s","map":{"title":"t"}}}
    ''';

    test('单个源可以直接当包导入', () {
      final r = FreeSourceBundle.parse(good);
      expect(r.ok, isTrue);
      expect(r.bundle!.count, 1);
      expect(r.bundle!.sources.first.id, 'ok1');
    });

    test('坏源被跳过、好源照用（不整包失败）', () {
      final raw = '''
      {"schema":1,"name":"混合","sources":[
        $good,
        {"id":"BAD ID","name":"坏","kind":"music","search":{"path":"/s"}},
        {"name":"没有 id","kind":"music","search":{"path":"/s"}}
      ]}''';
      final r = FreeSourceBundle.parse(raw);
      expect(r.ok, isTrue);
      expect(r.bundle!.count, 1);
      // 两条问题都要报出来，用户才知道自己少了什么
      expect(r.warnings.length, 2);
    });

    test('schema 比 App 支持的更新时拒绝', () {
      final r = FreeSourceBundle.parse('{"schema":99,"name":"x","sources":[$good]}');
      expect(r.ok, isFalse);
      expect(r.error, contains('99'));
    });

    test('不是 JSON 时给出人话错误', () {
      final r = FreeSourceBundle.parse('<html>404</html>');
      expect(r.ok, isFalse);
      expect(r.error, contains('JSON'));
    });

    test('id 重复只留一个', () {
      final raw = '''
      {"schema":1,"name":"重复","sources":[$good, $good]}''';
      final r = FreeSourceBundle.parse(raw);
      expect(r.bundle!.count, 1);
      expect(r.warnings.any((w) => w.contains('重复')), isTrue);
    });

    test('往返序列化保持等价', () {
      final r = FreeSourceBundle.parse(good);
      final again = FreeSourceBundle.parse(r.bundle!.encode());
      expect(again.bundle!.count, 1);
      expect(again.bundle!.sources.first.id, 'ok1');
      expect(again.bundle!.sources.first.license, LicenseKind.officialApi);
    });
  });

  group('FreePolicy 闸门', () {
    FreeSource mk(LicenseKind l) => FreeSource(
          id: 'x',
          name: 'X',
          note: '',
          kind: FreeKind.music,
          license: l,
        );

    test('合规四类可以进移动端', () {
      for (final l in [
        LicenseKind.publicDomain,
        LicenseKind.creativeCommons,
        LicenseKind.officialApi,
        LicenseKind.userOwned,
      ]) {
        expect(FreePolicy.allows(mk(l), as: Audience.mobile), isTrue,
            reason: '$l 应放行');
      }
    });

    test('后两类永远不能进移动端构建', () {
      for (final l in [LicenseKind.thirdPartyRule, LicenseKind.scraped]) {
        expect(FreePolicy.allows(mk(l), as: Audience.mobile), isFalse,
            reason: '$l 应挡');
        expect(FreePolicy.allows(mk(l), as: Audience.desktop), isTrue);
      }
    });

    test('内置源默认标记为 builtin', () {
      expect(mk(LicenseKind.officialApi).builtin, isTrue);
      expect(
          const FreeSource(
            id: 'y',
            name: 'Y',
            note: '',
            kind: FreeKind.music,
            license: LicenseKind.officialApi,
            origin: SourceOrigin.user,
          ).builtin,
          isFalse);
    });
  });

  group('splitEntries 拆条', () {
    test('json 按路径取数组', () {
      const body = '{"data":{"items":[{"a":1},{"a":2}]}}';
      final a = FreeAction.parse({'path': '/s', 'list': 'data.items'})!;
      final got = splitEntries(body, a);
      expect(got.length, 2);
    });

    test('json 顶层是数组且 list 为空', () {
      const body = '[{"a":1},{"a":2},{"a":3}]';
      final a = FreeAction.parse({'path': '/s'})!;
      expect(splitEntries(body, a).length, 3);
    });

    test('rss 按 item 拆', () {
      const body = '<rss><item><title>1</title></item>'
          '<item><title>2</title></item></rss>';
      final a = FreeAction.parse({'path': '/f', 'fetch': 'rss'})!;
      expect(splitEntries(body, a).length, 2);
    });

    test('html 按选择器拆', () {
      const body = '<div class="i">a</div><div class="i">b</div><div class="j">c</div>';
      final a =
          FreeAction.parse({'path': '/p', 'fetch': 'html', 'list': 'div.i'})!;
      expect(splitEntries(body, a).length, 2);
    });

    test('响应不是 JSON 时返回空而不是抛', () {
      final a = FreeAction.parse({'path': '/s', 'list': 'x'})!;
      expect(splitEntries('<html>404</html>', a), isEmpty);
    });
  });

  group('模板插值', () {
    test('fillTemplate 会 URL 编码', () {
      expect(fillTemplate('/s?q={q}', {'q': '周杰伦 & 音乐'}),
          '/s?q=%E5%91%A8%E6%9D%B0%E4%BC%A6+%26+%E9%9F%B3%E4%B9%90');
    });

    test('未知占位符原样保留', () {
      expect(fillTemplate('/s?q={q}&p={page}', {'q': 'a'}), '/s?q=a&p={page}');
    });
  });

  // 候选路径链：一条字段可以写多条路径，按序取第一个非空。
  //
  // 这不是为了好看 —— 真实接口里同一字段的位置会随记录而变：
  //   · MangaDex 的 cover_art 在 relationships，索引受 author/artist 有无影响；
  //   · PeerTube 老视频播放在 files，新视频在 streamingPlaylists[0].files。
  // 没有这条能力，同一份源就得拆成两个入口，用户看到重复项。
  group('候选路径链（||）', () {
    final node = {
      'a': {'x': ''},
      'b': {'y': '命中'},
      'rel': [
        {'attributes': {'name': '作者'}},
        {'attributes': {'fileName': 'cover.png'}},
      ],
    };

    test('第一条为空时自动退到下一条', () {
      expect(pickField(node, '', 'a.x||b.y'), '命中');
    });

    test('第一条非空就不再看后面（顺序优先）', () {
      expect(pickField({'p': '第一', 'q': '第二'}, '', 'p||q'), '第一');
    });

    test('全空时返回空串（交回调用方落 fallback）', () {
      expect(pickField(node, '', 'a.x||c.z||d.w'), '');
    });

    test('单路径写法行为不变（向后兼容旧包）', () {
      expect(pickField({'n': '旧包'}, '', 'n'), '旧包');
    });

    test('★ MangaDex 场景：跳过没有 fileName 的 author，拿到 cover', () {
      // relationships[0] 是 author（没有 attributes.fileName），
      // [1] 才是 cover_art。固定下标会取不到，候选链能自动跳过。
      expect(
          pickField(node, '', 'rel.0.attributes.fileName'
              '||rel.1.attributes.fileName'
              '||rel.2.attributes.fileName'),
          'cover.png');
    });
  });
}
