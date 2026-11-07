// 上游: kodjodevf/mangayomi@91bda20a9235 | 许可证: Apache-2.0 | 方式: 文件移植（原样搬，未改逻辑）
// 台账: vendor/MANIFEST.json → ported[id=mangayomi_auto_scroll]
// 上游路径: lib/modules/reader_common/mixins/reader_auto_scroll.dart
//
// 这是 Mangayomi 的帧驱动自动滚动 mixin：按 autoScrollSpeed×10 px/s 推进，
// 用户拖动时让出，滚到尾部自动关闭。原本同时服务漫画与小说阅读器。
// 我们只用它解决「条漫连续阅读要一直用手划」的问题；逻辑一行未改。
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Frame-driven auto-scroll shared by the manga and novel readers.
///
/// Scrolls [autoScrollController] at [autoScrollSpeed] × 10 px/s while
/// [autoScrollEnabled] is on and [canAutoScroll] holds, pauses while the user
/// drags, and turns itself off at the end of the content.
mixin ReaderAutoScroll<T extends StatefulWidget> on State<T>, TickerProvider {
  ValueNotifier<bool> get autoScrollEnabled;
  ValueNotifier<double> get autoScrollSpeed;
  ScrollController get autoScrollController;

  /// Auto-scroll only runs in continuous reading modes.
  bool get canAutoScroll;

  /// Set while a finger or pointer drags the content, so the ticker yields.
  bool isUserDragging = false;

  Ticker? _autoScrollTicker;
  Duration _lastAutoScrollTick = Duration.zero;

  void onAutoScrollChanged() {
    if (autoScrollEnabled.value && canAutoScroll) {
      startAutoScroll();
    } else {
      stopAutoScroll();
    }
  }

  void startAutoScroll() {
    _autoScrollTicker ??= createTicker(_onAutoScrollTick);
    _lastAutoScrollTick = Duration.zero;
    if (!_autoScrollTicker!.isActive) {
      _autoScrollTicker!.start();
    }
  }

  void stopAutoScroll() {
    if (_autoScrollTicker != null && _autoScrollTicker!.isActive) {
      _autoScrollTicker!.stop();
    }
    _lastAutoScrollTick = Duration.zero;
  }

  void disposeAutoScroll() => _autoScrollTicker?.dispose();

  void _onAutoScrollTick(Duration elapsed) {
    if (!mounted || !autoScrollEnabled.value || !canAutoScroll) {
      stopAutoScroll();
      return;
    }
    if (isUserDragging) {
      _lastAutoScrollTick = elapsed;
      return;
    }
    if (_lastAutoScrollTick == Duration.zero) {
      _lastAutoScrollTick = elapsed;
      return;
    }
    final double dt =
        (elapsed - _lastAutoScrollTick).inMicroseconds / 1000000.0;
    _lastAutoScrollTick = elapsed;

    if (dt <= 0 || dt > 0.1) return;

    final controller = autoScrollController;
    if (controller.hasClients) {
      final position = controller.position;
      final double pixelsPerSecond = autoScrollSpeed.value * 10.0;
      final double delta = pixelsPerSecond * dt;
      final double currentOffset = position.pixels;
      final double maxScroll = position.maxScrollExtent;
      final double minScroll = position.minScrollExtent;

      if (currentOffset >= maxScroll && delta > 0) {
        autoScrollEnabled.value = false;
        stopAutoScroll();
        return;
      }

      final double newOffset = (currentOffset + delta).clamp(
        minScroll,
        maxScroll,
      );
      if (newOffset != currentOffset) {
        controller.jumpTo(newOffset);
      }
    }
  }
}
