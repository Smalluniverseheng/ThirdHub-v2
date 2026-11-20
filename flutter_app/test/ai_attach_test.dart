// 附件（图片/视频/文件）与厂商能力记忆的测试。
//
// 这两块以前根本没有，是最容易出现"看起来发了其实没发"的地方：
// content 组装错一个 key，厂商就静默忽略图片，回一句"我看不到图片"；
// 能力判断写错，用户就会遇到"明明能发却被灰掉"（用户明确禁止硬拦）。
// 所以全部用纯逻辑断言钉住，不上真机、不联网。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:thirdhub_app/core/ai_attach.dart';
import 'package:thirdhub_app/core/ai_caps.dart';

AiAttachment _img([String name = 'a.png']) => AiAttachment(
      kind: AiAttachKind.image,
      name: name,
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      mime: 'image/jpeg',
    );

void main() {
  group('OpenAI 兼容 content', () {
    test('没有附件时退化成纯字符串（部分中转站只吃字符串）', () {
      final c = AiAttach.contentFor(text: '你好', items: const []);
      expect(c, isA<String>());
      expect(c, '你好');
    });

    test('有图片时是 text + image_url 的数组，且是 data URI', () {
      final c = AiAttach.contentFor(text: '这是什么', items: [_img()]);
      expect(c, isA<List>());
      final parts = (c as List).cast<Map<String, dynamic>>();
      expect(parts.first['type'], 'text');
      expect(parts.first['text'], '这是什么');
      expect(parts[1]['type'], 'image_url');
      final url = (parts[1]['image_url'] as Map)['url'] as String;
      expect(url.startsWith('data:image/jpeg;base64,'), isTrue);
      expect(base64Decode(url.split(',').last), [1, 2, 3, 4]);
    });

    test('只发图不打字也要有一段文字占位（否则模型不知道怎么回）', () {
      final c = AiAttach.contentFor(text: '', items: [_img()]);
      final parts = (c as List).cast<Map<String, dynamic>>();
      expect(parts.first['type'], 'text');
      expect('${parts.first['text']}'.trim(), isNotEmpty);
    });

    test('视频在"不支持视频"时降级成说明文字，而不是硬拒', () {
      final v = AiAttachment(
        kind: AiAttachKind.video,
        name: 'v.mp4',
        bytes: Uint8List.fromList([9, 9]),
        mime: 'video/mp4',
      );
      final on = AiAttach.contentFor(text: '看这个', items: [v], video: true);
      expect((on as List).any((e) => e['type'] == 'video_url'), isTrue);

      final off = AiAttach.contentFor(text: '看这个', items: [v], video: false);
      expect((off as List).any((e) => e['type'] == 'video_url'), isFalse);
      final flat = off.map((e) => '${e['text'] ?? ''}').join();
      expect(flat.contains('v.mp4'), isTrue);
    });

    test('文本类附件直接铺成文字，不塞 base64', () {
      final f = AiAttachment(
        kind: AiAttachKind.file,
        name: 'log.txt',
        bytes: Uint8List(0),
        mime: 'text/plain',
        text: '第一行报错：TimeoutException',
      );
      final c = AiAttach.contentFor(text: '看看日志', items: [f]);
      final flat = (c as List).map((e) => '${e['text'] ?? ''}').join();
      expect(flat.contains('TimeoutException'), isTrue);
      expect(flat.contains('base64'), isFalse);
    });
  });

  group('Anthropic 形状', () {
    test('图片走 base64 source，文字在最后', () {
      final parts = AiAttach.anthropicContent(text: '看图', items: [_img()]);
      expect(parts.first['type'], 'image');
      final src = parts.first['source'] as Map;
      expect(src['type'], 'base64');
      expect(src['media_type'], 'image/jpeg');
      expect(parts.last, {'type': 'text', 'text': '看图'});
    });

    test('把存下来的 OpenAI 数组转成 Claude 能吃的块（切换模型不会 400）', () {
      final openai = AiAttach.contentFor(text: '看图', items: [_img()]);
      final blocks = AiAttach.openaiToAnthropic(openai);
      expect(blocks.length, 2);
      expect(blocks[0]['type'], 'text');
      expect(blocks[1]['type'], 'image');
      final src = blocks[1]['source'] as Map;
      // 关键：data URI 前缀必须被剥掉，media_type 要正确，否则 Claude 直接 400
      expect('${src['data']}'.contains('data:'), isFalse);
      expect(src['media_type'], 'image/jpeg');
      expect(base64Decode('${src['data']}'), [1, 2, 3, 4]);
    });

    test('视频在 Claude 上降级成一句话，不抛异常', () {
      final v = AiAttachment(
          kind: AiAttachKind.video, name: 'v.mp4', bytes: Uint8List.fromList([1]), mime: 'video/mp4');
      final blocks = AiAttach.anthropicContent(text: '看', items: [v]);
      expect(blocks.length, 2);
      // 视频不进 base64，而是留一句"发不进去"的说明（用户能看到、模型也知情）
      expect('${blocks.first['text']}'.contains('v.mp4'), isTrue);
      expect('${blocks.first['text']}'.contains('不支持'), isTrue);
    });
  });

  group('图片压缩', () {
    test('长边超限会被缩到 1568 以内，且仍然能解码', () {
      final big = img.Image(width: 3000, height: 1200);
      img.fill(big, color: img.ColorRgb8(120, 200, 255));
      final raw = Uint8List.fromList(img.encodePng(big));

      final out = AiAttach.compressImage(raw);
      final back = img.decodeImage(out);
      expect(back, isNotNull);
      expect(back!.width, AiAttach.maxSide);
      expect(back.height, lessThan(1200));
      // 不再断言"一定比原图小"：纯色 PNG 比 JPEG 小是正常的，
      // 真实手机照片（4~8MB）才会真的掉到几百 KB。这里只守尺寸与可解码。
      expect(out.length, lessThan(5 * 1024 * 1024));
    });

    test('本来就是小图就原样返回，不会越压越大', () {
      final small = img.Image(width: 32, height: 32);
      img.fill(small, color: img.ColorRgb8(0, 0, 0));
      final raw = Uint8List.fromList(img.encodePng(small));
      expect(AiAttach.compressImage(raw).length, lessThanOrEqualTo(raw.length));
    });

    test('不是图片的字节不会抛异常（宁可发不出去也不能崩）', () {
      final junk = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
      expect(AiAttach.compressImage(junk), junk);
    });
  });

  group('textOf', () {
    test('数组里只取 text 部分，不把 image_url 拼进去', () {
      final c = AiAttach.contentFor(text: '正文', items: [_img()]);
      expect(AiAttach.textOf(c), '正文');
    });
    test('字符串原样返回，null 给空串', () {
      expect(AiAttach.textOf('abc'), 'abc');
      expect(AiAttach.textOf(null), '');
    });
  });

  group('厂商能力判断（默认全开，失败才降级）', () {
    test('只有明确指向"输入形状不支持"的错误才算降级', () {
      expect(AiCaps.looksLikeUnsupported('HTTP 400: invalid content type image_url', 'vision'), isTrue);
      expect(AiCaps.looksLikeUnsupported('this model does not support vision', 'vision'), isTrue);
      expect(AiCaps.looksLikeUnsupported('模型不支持图片输入', 'vision'), isTrue);
    });

    test('网络/额度/鉴权错误绝不记成"不支持看图"', () {
      expect(AiCaps.looksLikeUnsupported('TimeoutException after 0:01:30', 'vision'), isFalse);
      expect(AiCaps.looksLikeUnsupported('HTTP 429 rate limit', 'vision'), isFalse);
      expect(AiCaps.looksLikeUnsupported('HTTP 401 unauthorized', 'vision'), isFalse);
      expect(AiCaps.looksLikeUnsupported('insufficient balance', 'vision'), isFalse);
    });
  });
}
