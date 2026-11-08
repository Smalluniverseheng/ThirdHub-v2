// 上游: kodjodevf/mangayomi@91bda20a9235 | 许可证: Apache-2.0 | 方式: 文件移植（原样搬，逻辑一行未改）
// 台账: vendor/MANIFEST.json → ported[id=mangayomi_value_indicator_shape]
// 上游路径: lib/modules/manga/reader/widgets/custom_value_indicator_shape.dart
//
// 这是 Mangayomi 阅读器底部页码滑杆的气泡指示器：把 Flutter 默认的
// PaddleSliderValueIndicatorShape 按阅读方向做水平镜像（tranform=true 时用于从右往左翻页），
// 形状与文字都不自己画，交给上游形状类绘制。本项目在 _Ecr 的翻页模式底部滑杆里
// 通过 SliderTheme.valueIndicatorShape 调用它。
import 'package:flutter/material.dart';

class CustomValueIndicatorShape extends SliderComponentShape {
  final _indicatorShape = const PaddleSliderValueIndicatorShape();
  final bool tranform;
  const CustomValueIndicatorShape({this.tranform = false});
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(40, 40);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final textSpan = TextSpan(
      text: labelPainter.text?.toPlainText(),
      style: sliderTheme.valueIndicatorTextStyle,
    );

    final textPainter = TextPainter(
      text: textSpan,
      textAlign: labelPainter.textAlign,
      textDirection: textDirection,
    );

    textPainter.layout();

    context.canvas.save();
    context.canvas.translate(center.dx, center.dy);
    context.canvas.scale(tranform ? -1.0 : 1.0, 1.0);
    context.canvas.translate(-center.dx, -center.dy);

    _indicatorShape.paint(
      context,
      center,
      activationAnimation: activationAnimation,
      enableAnimation: enableAnimation,
      labelPainter: textPainter,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      value: value,
      textScaleFactor: textScaleFactor,
      sizeWithOverflow: sizeWithOverflow,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
    );

    context.canvas.restore();
  }
}
