import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import 'i18n.dart';

/// 漫画页图组件 —— 移植自 Venera（venera-app/venera，**GPL-3.0**，2026-11-07 核实）。
/// 许可证边界见 outputs/ThirdHub全盘升级计划-20261107.md：桌面端/自托管侧分发，
/// 移动端只保留尺寸计算算法，不整套分发其 UI。
///
/// 解决的正是「每张图只出来一半」这个问题：
///
/// Flutter 自带的 `Image.network` 在图片解码出真实尺寸之前**不知道高宽比**，
/// 所以调用方只能给一个猜的占位高度（我们之前猜的是 3:4）。
/// 条漫实际是 1:1.4 甚至更长，于是占位框比图片矮 —— 图片被裁，看起来只出一半；
/// 等解码完成容器突然变高，列表还会「跳一下」。
///
/// 这个组件的做法：
/// 1. 图片解码完成的那一刻，把**真实像素宽高**记进静态缓存（按 provider 的 hashCode）
/// 2. 高度 = 宽度 × 真实高 / 真实宽 —— 从第一帧起就是对的
/// 3. 同一张图滚动回来（或者翻页回来）时，缓存已经在了，**不需要等解码就能给出正确高度**
/// 4. 加载中只画一个小进度圈（带真实百分比），不占假高度
///
/// 移植时有四处改动（原版依赖它自己的工程）：
/// · `part of 'reader.dart'` → 独立文件（这就是为什么原版 0 个 import：全靠 part 共享）
/// · `"Retry".tl` → `tr('重试')`（接到本项目的 i18n，6 语言都有译文）
/// · `GlobalState.find<...>().ignoreNextTap()` → 删掉（我们没有那套手势协调）
/// · `context.colorScheme.surfaceContainer` → `Theme.of(context)...`
class ComicImage extends StatefulWidget {
  /// Modified from flutter Image (Venera 原作者注释：从 Flutter 的 Image 改写)
  ComicImage({
    required ImageProvider image,
    super.key,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.isAntiAlias = false,
    int? cacheWidth,
    int? cacheHeight,
    this.onInit,
    this.onDispose,
    this.placeholder,
  })  : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image),
        assert(cacheWidth == null || cacheWidth > 0),
        assert(cacheHeight == null || cacheHeight > 0);

  final ImageProvider image;

  final String? semanticLabel;

  final bool excludeFromSemantics;

  final double? width;

  final double? height;

  final bool gaplessPlayback;

  final bool matchTextDirection;

  final Rect? centerSlice;

  final ImageRepeat repeat;

  final AlignmentGeometry alignment;

  final BoxFit? fit;

  final BlendMode? colorBlendMode;

  final FilterQuality filterQuality;

  final Animation<double>? opacity;

  final Color? color;

  final bool isAntiAlias;

  final void Function(State<ComicImage> state)? onInit;

  final void Function(State<ComicImage> state)? onDispose;

  /// 原版没有这个参数：它连不上时只显示一行红字。
  /// 我们加一个「还没开始加载时」的占位（比如骨架块），观感更连续。
  final Widget? placeholder;

  /// 清空宽高比缓存。内存吃紧时（比如退出阅读器）调用一次。
  static void clear() => _ComicImageState.clear();

  @override
  State<ComicImage> createState() => _ComicImageState();
}

class _ComicImageState extends State<ComicImage> with WidgetsBindingObserver {
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  ImageChunkEvent? _loadingProgress;
  bool _isListeningToStream = false;
  late bool _invertColors;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<ComicImage>> _scrollAwareContext;
  Object? _lastException;
  ImageStreamCompleterHandle? _completerHandle;

  /// provider.hashCode → 真实像素尺寸。
  /// ★ 这是整个组件的核心：有了它，滚动回来时第一帧就能算出正确高度。
  static final Map<int, Size> _cache = {};

  static void clear() => _cache.clear();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<ComicImage>>(this);
    widget.onInit?.call(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    _replaceImage(info: null);
    widget.onDispose?.call(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    _resolveImage();

    if (TickerMode.of(context)) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(ComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolveImage();
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void reassemble() {
    _resolveImage(); // 热重载时图片缓存被刷掉的情况
    super.reassemble();
  }

  void _updateInvertColors() {
    _invertColors = MediaQuery.maybeInvertColorsOf(context) ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _resolveImage() {
    final ScrollAwareImageProvider<Object> provider = ScrollAwareImageProvider(
      context: _scrollAwareContext,
      imageProvider: widget.image,
    );
    final ImageStream newStream = provider.resolve(createLocalImageConfiguration(
      context,
      size: widget.width != null && widget.height != null
          ? Size(widget.width!, widget.height!)
          : null,
    ));
    _updateSourceStream(newStream);
  }

  ImageStreamListener? _imageStreamListener;

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      _imageStreamListener = ImageStreamListener(
        _handleImageFrame,
        onChunk: _handleImageChunk,
        onError: (Object error, StackTrace? stackTrace) {
          if (!mounted) return;
          setState(() {
            _lastException = error;
          });
        },
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    if (!mounted) return;
    setState(() {
      _replaceImage(info: imageInfo);
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
  }

  void _handleImageChunk(ImageChunkEvent event) {
    if (!mounted) return;
    setState(() {
      _loadingProgress = event;
      _lastException = null;
    });
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    SchedulerBinding.instance
        .addPostFrameCallback((_) => oldImageInfo?.dispose());
    _imageInfo = info;
  }

  void _updateSourceStream(ImageStream newStream) {
    if (_imageStream?.key == newStream.key) {
      return;
    }

    if (_isListeningToStream) {
      _imageStream!.removeListener(_getListener());
    }

    if (!widget.gaplessPlayback) {
      setState(() {
        _replaceImage(info: null);
      });
    }

    setState(() {
      _loadingProgress = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
    });

    _imageStream = newStream;
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }

  void _listenToStream() {
    if (_isListeningToStream) return;
    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;
    _isListeningToStream = true;
  }

  void _stopListeningToStream({bool keepStreamAlive = false}) {
    if (!_isListeningToStream) return;
    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }
    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_lastException != null) {
      // 失败态：给一个明确的「重试」，而不是一块破图图标
      return SizedBox(
        height: widget.height == null ? 300 : null,
        width: widget.width == null ? 300 : null,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  '这一页没加载出来\n$_lastException',
                  maxLines: 3,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  setState(() {
                    _loadingProgress = null;
                    _lastException = null;
                  });
                  _resolveImage();
                },
                child: Text(tr('重试'),
                    style: const TextStyle(fontSize: 12)),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      var width = widget.width;
      var height = widget.height;

      if (_imageInfo != null) {
        // ★ 解码完成：把真实像素尺寸记进缓存
        _cache[widget.image.hashCode] = Size(
          _imageInfo!.image.width.toDouble(),
          _imageInfo!.image.height.toDouble(),
        );
      }

      final Size? cacheSize = _cache[widget.image.hashCode];
      if (cacheSize != null) {
        // ★ 有比例：按比例算，高度从第一帧就是准的
        if (width == double.infinity) {
          width = constraints.maxWidth;
          if (cacheSize.width > 0) {
            height = width * cacheSize.height / cacheSize.width;
          }
        } else if (height == double.infinity) {
          height = constraints.maxHeight;
          if (cacheSize.height > 0) {
            width = height * cacheSize.width / cacheSize.height;
          }
        }
      } else {
        // 第一次见这张图，还不知道比例：给一个保守占位，别把布局撑爆
        if (width == double.infinity) {
          width = constraints.maxWidth;
          height = 300;
        } else if (height == double.infinity) {
          height = constraints.maxHeight;
          width = 300;
        }
      }

      if (_imageInfo != null) {
        Widget result = RawImage(
          image: _imageInfo?.image,
          debugImageLabel: _imageInfo?.debugLabel,
          width: width,
          height: height,
          scale: _imageInfo?.scale ?? 1.0,
          color: widget.color,
          opacity: widget.opacity,
          colorBlendMode: widget.colorBlendMode,
          fit: widget.fit,
          alignment: widget.alignment,
          repeat: widget.repeat,
          centerSlice: widget.centerSlice,
          matchTextDirection: widget.matchTextDirection,
          invertColors: _invertColors,
          isAntiAlias: widget.isAntiAlias,
          filterQuality: widget.filterQuality,
        );

        if (!widget.excludeFromSemantics) {
          result = Semantics(
            container: widget.semanticLabel != null,
            image: true,
            label: widget.semanticLabel ?? '',
            child: result,
          );
        }
        return SizedBox(width: width, height: height, child: result);
      }

      // 加载中：小进度圈 + 真实百分比，不画假高度的假图片
      final total = _loadingProgress?.expectedTotalBytes;
      final loaded = _loadingProgress?.cumulativeBytesLoaded;
      final ratio = (total != null && total > 0 && loaded != null)
          ? loaded / total
          : null;
      return SizedBox(
        width: width,
        height: height,
        child: Center(
          child: widget.placeholder ??
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  backgroundColor: cs.surfaceContainerHighest,
                  value: ratio,
                ),
              ),
        ),
      );
    });
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder description) {
    super.debugFillProperties(description);
    description.add(DiagnosticsProperty<ImageStream>('stream', _imageStream));
    description.add(DiagnosticsProperty<ImageInfo>('pixels', _imageInfo));
    description
        .add(DiagnosticsProperty<ImageChunkEvent>('chunk', _loadingProgress));
  }
}
