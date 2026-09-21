// 下载物的「扫码 + 分享图」组件。
//
// 需求背景：下载页原来只有一串直链按钮 —— 用户在电脑上打开还好，但想把 App
// 装到另一台手机上时，"把链接发过去"是个真实的麻烦（微信会拦、手打太长）。
// 所以下载页要能**当场生成二维码**（另一台手机扫一下就装）和**一张分享图**
// （带产品名/版本/二维码的图，可以直接发到群里）。
//
// 实现取舍：分享图用**纯 Canvas 合成**，不用 RepaintBoundary。
//   · RepaintBoundary 方案要求"海报 widget 已经完成布局"，实际得把它塞进
//     屏幕外坐标里等一帧，截图时经常拿到空白或半成品（而且失败是静默的）。
//   · Canvas 方案是确定性的：先拿到二维码位图，再把二维码、文字依次画进一张
//     新图。没有布局时序，没有"截到一半"。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

class ShareCard {
  ShareCard._();

  /// 二维码/分享图的落地目录。放在外部存储的独立子目录，方便用户去文件管理器找。
  static Future<Directory> _dir() async {
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final Directory d = Directory('${base.path}/thirdhub-share');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _stamp() => DateTime.now().millisecondsSinceEpoch.toString();

  /// 画一张**白底黑码**的二维码位图。
  ///
  /// 为什么不用 `QrPainter` 的 `color` / `emptyColor`：
  ///   · 这两个形参在 qr_flutter 4.1.0 已标 `@Deprecated`；
  ///   · 更实际的问题是 `emptyColor` 的语义是"宿主**容器**的背景色"——
  ///     直接 `toImage()` 时根本没有容器，导出的 PNG 是**透明底**。
  ///     把透明底二维码贴进暗色聊天窗口，扫码成功率会明显下降。
  /// 所以这里 `toPicture()` 拿到矢量二维码，自己包一层白底重新合成，结果确定。
  ///
  /// ★ 释放时序：`dispose()` 必须放在 `toImage()` **之后**。`toImage()` 才是
  ///   真正光栅化的时刻，在它之前释放 Picture，native 侧会拿到已回收的画布
  ///   （表现为整块空白，且不抛异常）。
  static Future<ui.Image> _qrImage(String url, double size) async {
    final ui.Picture qr = QrPainter(
      data: url,
      version: QrVersions.auto,
      gapless: true,
    ).toPicture(size);
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas cv = Canvas(rec, Rect.fromLTWH(0, 0, size, size));
    cv.drawRect(Rect.fromLTWH(0, 0, size, size), Paint()..color = const Color(0xFFFFFFFF));
    cv.drawPicture(qr);
    final ui.Picture composed = rec.endRecording();
    final ui.Image out = await composed.toImage(size.toInt(), size.toInt());
    composed.dispose();
    qr.dispose();
    return out;
  }

  /// 存二维码 PNG。返回文件路径。
  static Future<String> saveQr({required String url, int size = 720}) async {
    final ui.Image img = await _qrImage(url, size.toDouble());
    try {
      final ByteData? bd = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) throw Exception('二维码生成失败');
      final File f = File('${(await _dir()).path}/qr-${_stamp()}.png');
      await f.writeAsBytes(bd.buffer.asUint8List());
      return f.path;
    } finally {
      img.dispose();
    }
  }

  /// 生成一张分享图：产品名 + 副标题 + 版本 + 二维码 + 一行说明。
  ///
  /// 尺寸 1080×1440（3:4），微信/QQ 里不会被裁成奇怪的比例。
  static Future<String> savePoster({
    required String name,
    required String sub,
    required String url,
    String version = '',
    String hint = '扫码下载 · 覆盖安装数据保留',
  }) async {
    const double w = 1080, h = 1440;
    const double qrSize = 560;

    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas cv = Canvas(rec, Rect.fromLTWH(0, 0, w, h));

    // ① 背景：深色渐变（与 App 主色调一致），底部略微收暗
    cv.drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF16213A), Color(0xFF0C1120)],
        ).createShader(const Rect.fromLTWH(0, 0, w, h)),
    );

    // ② 顶部标题区
    double y = 130;
    _text(cv, name, y, w, 64, const Color(0xFFFFFFFF), FontWeight.w700);
    y += 92;
    if (version.isNotEmpty) {
      _text(cv, version, y, w, 38, const Color(0xFF7FB4FF), FontWeight.w600);
      y += 66;
    }
    _text(cv, sub, y, w, 30, const Color(0xFF9AA6BF), FontWeight.w400, maxWidth: 880);

    // ③ 二维码卡片（白底圆角 + 内边距，保证静区足够，扫得动）
    final double qrTop = y + 96;
    final RRect plate = RRect.fromRectAndRadius(
      Rect.fromLTWH((w - qrSize) / 2 - 48, qrTop - 48, qrSize + 96, qrSize + 96),
      const Radius.circular(36),
    );
    cv.drawRRect(plate, Paint()..color = const Color(0xFFFFFFFF));

    // 白板已经铺好了，二维码再叠一层白底只是把静区补足，结果仍是白底黑码。
    final ui.Image qrImg = await _qrImage(url, qrSize);
    cv.drawImageRect(
      qrImg,
      Rect.fromLTWH(0, 0, qrImg.width.toDouble(), qrImg.height.toDouble()),
      Rect.fromLTWH((w - qrSize) / 2, qrTop, qrSize, qrSize),
      Paint()..filterQuality = FilterQuality.none,
    );

    // ④ 底部说明 + 链接原文（链接很长就缩小字号并截断到两行）
    double by = qrTop + qrSize + 120;
    _text(cv, hint, by, w, 34, const Color(0xFFCFD8EA), FontWeight.w500);
    by += 78;
    _text(cv, url, by, w, 22, const Color(0xFF6C7A96), FontWeight.w400, maxWidth: 940, maxLines: 2);

    final ui.Picture pic = rec.endRecording();
    final ui.Image out = await pic.toImage(w.toInt(), h.toInt());
    pic.dispose();
    qrImg.dispose();
    try {
      final ByteData? bd = await out.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) throw Exception('分享图生成失败');
      final File f = File('${(await _dir()).path}/share-${_stamp()}.png');
      await f.writeAsBytes(bd.buffer.asUint8List());
      return f.path;
    } finally {
      out.dispose();
    }
  }

  /// 在画布上**水平居中**画一段文字。
  static void _text(
    Canvas cv,
    String s,
    double top,
    double w,
    double size,
    Color color,
    FontWeight weight, {
    double maxWidth = 1000,
    int maxLines = 3,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size, fontWeight: weight, height: 1.35),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    tp.paint(cv, Offset((w - tp.width) / 2, top));
  }

  /// 调起系统分享（文件形式）。
  static Future<void> share(String path, {String? text}) async {
    await Share.shareXFiles(<XFile>[XFile(path)], text: text);
  }
}

/// 下载页里的一条「扫码 / 分享」区块。
///
/// 放在产品详情页与下载页顶部各一处：前者是"我要装这个产品"，
/// 后者是"我要把这个 App 发给别人"。
class DownloadShareBlock extends StatefulWidget {
  const DownloadShareBlock({
    super.key,
    required this.name,
    required this.url,
    this.sub = '',
    this.version = '',
    this.compact = false,
  });

  final String name;
  final String url;
  final String sub;
  final String version;

  /// 紧凑模式：不显示二维码，只留一排按钮（下载页顶部用它省地方）。
  final bool compact;

  @override
  State<DownloadShareBlock> createState() => _DownloadShareBlockState();
}

class _DownloadShareBlockState extends State<DownloadShareBlock> {
  bool _busy = false;

  String get _sub => widget.sub.isEmpty ? widget.url : widget.sub;

  Future<void> _run(Future<String> Function() job, String what) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState? m = ScaffoldMessenger.maybeOf(context);
    try {
      final String p = await job();
      m?.showSnackBar(SnackBar(content: Text('$what已保存\n$p')));
    } catch (e) {
      m?.showSnackBar(SnackBar(content: Text('$what失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sharePoster() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState? m = ScaffoldMessenger.maybeOf(context);
    try {
      final String p = await ShareCard.savePoster(
        name: widget.name,
        sub: _sub,
        url: widget.url,
        version: widget.version,
      );
      await ShareCard.share(p, text: '${widget.name} ${widget.version}'.trim());
    } catch (e) {
      m?.showSnackBar(SnackBar(content: Text('分享失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    final bool isLink = widget.url.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!widget.compact && isLink)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Card(
                // 二维码必须白底黑码，否则暗色主题下扫不出来
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: QrImageView(
                    data: widget.url,
                    size: 180,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square, color: Color(0xFF000000)),
                    dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square, color: Color(0xFF000000)),
                  ),
                ),
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (isLink)
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_2, size: 18),
                label: const Text('保存二维码'),
                onPressed: _busy ? null : () => _run(() => ShareCard.saveQr(url: widget.url), '二维码'),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('保存分享图'),
              onPressed: _busy
                  ? null
                  : () => _run(
                        () => ShareCard.savePoster(
                          name: widget.name,
                          sub: _sub,
                          url: widget.url,
                          version: widget.version,
                        ),
                        '分享图',
                      ),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('分享'),
              onPressed: _busy ? null : _sharePoster,
            ),
          ],
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: <Widget>[
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text('正在生成…', style: TextStyle(fontSize: 11, color: t.colorScheme.primary)),
            ]),
          ),
      ],
    );
  }
}
