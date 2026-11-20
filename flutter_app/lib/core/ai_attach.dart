// AI 对话 · 附件（图片 / 视频 / 文件）
//
// 用户原话：「不能够发送视频图片照片这些东西你都没有做」。以前 `+` 面板里
// 那五个图标点了只弹一句「准备开放」—— 摆样子。这一层把它做实。
//
// 三条设计约束：
//   1) **不硬拦**。各家厂商支持度参差（DeepSeek 不支持看图、GLM-4V 支持、
//      Qwen-VL 还能吃视频）。默认全按"支持"处理，发失败了才记录降级，
//      下次再发只提醒一句、仍然放行 —— 这是用户明确要求的行为。
//   2) **体积可控**。手机直出的照片 4~8MB，base64 之后还要 +33%。
//      统一缩到长边 1568px、JPEG q82（这是 OpenAI 官方建议的视觉输入上限）。
//   3) 纯组装逻辑与 UI 分离，`contentBlocks` 这些能单测，不用起真机。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// 附件类型
class AiAttachKind {
  static const image = 'image';
  static const video = 'video';
  static const file = 'file';
}

/// 一个待发送的附件。
class AiAttachment {
  final String kind;
  final String name;

  /// 字节（图片已压缩后的 JPEG；视频/文件为原始字节）
  final Uint8List bytes;
  final String mime;

  /// 文本类文件的内容（读出来直接当文字发，比 base64 划算得多）
  final String? text;

  const AiAttachment({
    required this.kind,
    required this.name,
    required this.bytes,
    required this.mime,
    this.text,
  });

  int get size => bytes.length;

  bool get isImage => kind == AiAttachKind.image;

  String get dataUri => 'data:$mime;base64,${base64Encode(bytes)}';

  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'name': name,
        'mime': mime,
        'size': size,
      };
}

class AiAttach {
  const AiAttach._();

  /// 单张图片压缩后的长边上限（OpenAI 视觉输入的建议值，超了也白给）
  static const int maxSide = 1568;

  /// JPEG 质量
  static const int quality = 82;

  /// 视频上限：base64 之后约 +33%，再大就把请求体撑爆或直接被网关拒。
  static const int videoMaxBytes = 12 * 1024 * 1024;

  /// 文本类文件上限（超过就当附件名处理，不塞进上下文）
  static const int textMaxChars = 30000;

  /// 把任意图片字节压到可发送的尺寸。失败就原样返回（宁可大一点也要能发）。
  static Uint8List compressImage(Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) return raw;
      var out = decoded;
      final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
      if (longest > maxSide) {
        out = decoded.width >= decoded.height
            ? img.copyResize(decoded, width: maxSide, interpolation: img.Interpolation.average)
            : img.copyResize(decoded, height: maxSide, interpolation: img.Interpolation.average);
      }
      final jpg = img.encodeJpg(out, quality: quality);
      // 只要发生过缩放就**必须**用压缩结果 —— 否则一张纯色大 PNG 会因为
      // "JPEG 反而更大"被原样返回，长边 3000 的图照旧发给视觉接口：
      // 白花 token，个别网关还会因为体积直接 413。
      if (longest > maxSide) return Uint8List.fromList(jpg);
      // 没缩放：本来就是小图，JPEG 反而更大（纯色 PNG 很常见）就保留原图
      return jpg.length <= raw.length ? Uint8List.fromList(jpg) : raw;
    } catch (_) {
      return raw;
    }
  }

  static String _mimeOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.mov')) return 'video/quicktime';
    if (n.endsWith('.txt') || n.endsWith('.md') || n.endsWith('.log')) return 'text/plain';
    if (n.endsWith('.json')) return 'application/json';
    return 'application/octet-stream';
  }

  static bool _isImageName(String n) {
    final l = n.toLowerCase();
    return l.endsWith('.png') ||
        l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.webp') ||
        l.endsWith('.gif');
  }

  static bool _isTextName(String n) {
    final l = n.toLowerCase();
    return l.endsWith('.txt') || l.endsWith('.md') || l.endsWith('.json') || l.endsWith('.log') || l.endsWith('.csv');
  }

  /// 从相册选图（可多选）
  static Future<List<AiAttachment>> pickImages({int limit = 4}) async {
    final picker = ImagePicker();
    final xs = await picker.pickMultiImage();
    final out = <AiAttachment>[];
    for (final x in xs.take(limit)) {
      final raw = await x.readAsBytes();
      out.add(AiAttachment(
        kind: AiAttachKind.image,
        name: x.name,
        bytes: compressImage(raw),
        mime: 'image/jpeg',
      ));
    }
    return out;
  }

  /// 拍照
  static Future<AiAttachment?> pickCamera() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera);
    if (x == null) return null;
    return AiAttachment(
      kind: AiAttachKind.image,
      name: x.name,
      bytes: compressImage(await x.readAsBytes()),
      mime: 'image/jpeg',
    );
  }

  /// 选任意文件：图片走压缩、文本直接读、视频按体积守门
  static Future<AiAttachment?> pickFile({bool videoOnly = false}) async {
    final r = await FilePicker.platform.pickFiles(
      type: videoOnly ? FileType.video : FileType.any,
      withData: true,
    );
    final f = r?.files.firstOrNull;
    if (f == null) return null;
    final raw = f.bytes ?? (f.path == null ? null : await File(f.path!).readAsBytes());
    if (raw == null) return null;

    final name = f.name;
    if (_isImageName(name)) {
      return AiAttachment(
        kind: AiAttachKind.image,
        name: name,
        bytes: compressImage(raw),
        mime: 'image/jpeg',
      );
    }
    final mime = _mimeOf(name);
    if (mime.startsWith('video/')) {
      return AiAttachment(
        kind: AiAttachKind.video,
        name: name,
        // 视频不转码（手机端转码等于把电量烧光），只守体积
        bytes: raw.length > videoMaxBytes ? Uint8List(0) : raw,
        mime: mime,
        text: raw.length > videoMaxBytes ? '视频过大（${(raw.length / 1024 / 1024).toStringAsFixed(1)} MB），未上传' : null,
      );
    }
    if (_isTextName(name)) {
      final txt = utf8.decode(raw, allowMalformed: true);
      return AiAttachment(
        kind: AiAttachKind.file,
        name: name,
        bytes: Uint8List(0),
        mime: mime,
        text: txt.length > textMaxChars ? '${txt.substring(0, textMaxChars)}\n…（已截断）' : txt,
      );
    }
    return AiAttachment(
      kind: AiAttachKind.file,
      name: name,
      bytes: raw,
      mime: mime,
    );
  }

  /// 组装 OpenAI 兼容的 user content。
  ///
  /// 返回 String（纯文本，不带附件）或 List（多模态）。为什么要能退化成
  /// String：部分厂商/中转站只吃字符串 content，给数组会直接 400。
  ///
  /// [vision] / [video] 是"上次失败过"的降级标记，**只影响提醒与降级写法**，
  /// 不在这里硬拒 —— 真正该不该发由用户决定（用户明确要求"不要强制不允许"）。
  static Object contentFor({
    required String text,
    required List<AiAttachment> items,
    bool vision = true,
    bool video = true,
  }) {
    if (items.isEmpty) return text;
    final parts = <Map<String, dynamic>>[];
    if (text.trim().isNotEmpty) {
      parts.add({'type': 'text', 'text': text});
    } else {
      parts.add({'type': 'text', 'text': '（用户发来了附件，请看图/看文件后回答）'});
    }
    for (final a in items) {
      if (a.isImage) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': a.dataUri, 'detail': 'auto'},
        });
      } else if (a.kind == AiAttachKind.video && video && a.bytes.isNotEmpty) {
        parts.add({
          'type': 'video_url',
          'video_url': {'url': a.dataUri},
        });
      } else {
        // 文本类附件：直接铺成文字；其它二进制只报个名字，别把乱码塞给模型
        final body = a.text ??
            '（附件 ${a.name}，${a.sizeLabel}，${a.mime}；当前接口无法传二进制内容）';
        parts.add({'type': 'text', 'text': '【附件 ${a.name}】\n$body'});
      }
    }
    return parts;
  }

  /// Anthropic 形状：image 走 base64 source，文本走 text 块。
  /// 视频 Anthropic 不吃 —— 降级成一句说明（不报错，不硬拦）。
  static List<Map<String, dynamic>> anthropicContent({
    required String text,
    required List<AiAttachment> items,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final a in items) {
      if (a.isImage) {
        out.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': a.mime,
            'data': base64Encode(a.bytes),
          },
        });
      } else {
        out.add({
          'type': 'text',
          'text': '【附件 ${a.name}】${a.text ?? '（${a.mime}，${a.sizeLabel}，该接口不支持此类附件）'}',
        });
      }
    }
    out.add({'type': 'text', 'text': text.isEmpty ? '（见附件）' : text});
    return out;
  }

  /// 把 OpenAI 形状的 content（可能是数组）转成 Anthropic 形状。
  /// 之所以要转：会话里存的是 OpenAI 形状（安卓端唯一真相），切模型时现算。
  static List<Map<String, dynamic>> openaiToAnthropic(Object content) {
    if (content is String) {
      return [
        {'type': 'text', 'text': content}
      ];
    }
    final out = <Map<String, dynamic>>[];
    if (content is List) {
      for (final p in content) {
        if (p is! Map) continue;
        final type = '${p['type']}';
        if (type == 'text') {
          out.add({'type': 'text', 'text': '${p['text'] ?? ''}'});
        } else if (type == 'image_url') {
          final url = '${(p['image_url'] as Map?)?['url'] ?? ''}';
          final comma = url.indexOf(',');
          if (url.startsWith('data:') && comma > 0) {
            final head = url.substring(5, comma); // e.g. image/jpeg;base64
            final semi = head.indexOf(';');
            final mime = semi > 0 ? head.substring(0, semi) : 'image/jpeg';
            out.add({
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': mime,
                'data': url.substring(comma + 1),
              },
            });
          } else if (url.isNotEmpty) {
            // 远程 URL：Anthropic 支持 url source
            out.add({
              'type': 'image',
              'source': {'type': 'url', 'url': url},
            });
          }
        } else if (type == 'video_url') {
          out.add({
            'type': 'text',
            'text': '（用户发了一段视频，当前接口不支持视频输入）'
          });
        }
      }
    }
    if (out.isEmpty) out.add({'type': 'text', 'text': ''});
    return out;
  }

  /// 会话里存的消息可能带 content 数组，取纯文字用于列表预览/复制。
  static String textOf(Object? content) {
    if (content == null) return '';
    if (content is String) return content;
    if (content is List) {
      final sb = StringBuffer();
      for (final p in content) {
        if (p is Map && '${p['type']}' == 'text') sb.write(p['text'] ?? '');
      }
      return sb.toString();
    }
    return '$content';
  }
}
