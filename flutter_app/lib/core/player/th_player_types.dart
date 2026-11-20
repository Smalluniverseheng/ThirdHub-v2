// 第三方聚合 · 播放器公共类型（4.81.81）
//
// 抽出来是为了主壳 th_player.dart 与面板 th_player_panels.dart 共用一份，
// 避免两边各写一套枚举导致"面板选了但壳子不认"。

import 'package:flutter/material.dart';

/// 画面铺满方式。对标 YouTube 的「缩放至屏幕 / 适应屏幕」、Infuse 的
/// 「适应 / 填充 / 原始 / 裁剪」。
enum ThFit {
  /// 完整显示，留黑边（默认，比例对得上时看不出来）
  contain,

  /// 裁掉超出的边把画面铺满（竖屏短剧、老 4:3 片源常用）
  cover,

  /// 拉伸铺满（会变形，但有人就爱看满屏）
  fill,

  /// 强制按 16:9 显示
  r16x9,

  /// 强制按 4:3 显示
  r4x3,
}

extension ThFitX on ThFit {
  double? get ratio => switch (this) {
        ThFit.r16x9 => 16 / 9,
        ThFit.r4x3 => 4 / 3,
        _ => null,
      };

  BoxFit get boxFit => switch (this) {
        ThFit.cover => BoxFit.cover,
        ThFit.fill => BoxFit.fill,
        _ => BoxFit.contain,
      };
}

/// 循环方式。
enum ThLoop { off, one, all }

/// 一档清晰度。
///
/// [tag] 是给上层用的黑盒标识：B 站放 qn（如 '80'），采集站放源给的档位名。
/// 上层根据它重新取流，播放器自己不关心具体含义。
class ThQuality {
  const ThQuality(this.label, {this.tag = ''});

  final String label;
  final String tag;

  @override
  bool operator ==(Object other) =>
      other is ThQuality && other.label == label && other.tag == tag;

  @override
  int get hashCode => Object.hash(label, tag);
}

/// 播放器里"更多"面板的附加项（下载、选集、投屏……由调用方塞进来）。
class ThMoreItem {
  const ThMoreItem({
    required this.icon,
    required this.label,
    this.sub = '',
    this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback? onTap;
  final bool selected;
}

/// 倍速档位。1.25 / 1.75 是"看网课"的人最常用的两档，别只给 0.5/1/1.5/2。
const List<double> kThSpeeds = [
  0.25,
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  1.75,
  2.0,
  2.5,
  3.0,
];

/// 秒表格式：1:23 / 1:02:03。
String thClock(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
  return '$m:${sec.toString().padLeft(2, '0')}';
}

/// 倍速文案：1x / 1.25x（不写成 1.0x，跟 YouTube 一致）。
String thSpeedLabel(double s) {
  final t = s == s.roundToDouble()
      ? s.toStringAsFixed(0)
      : s.toString().replaceAll(RegExp(r'0+$'), '');
  return '${t}x';
}

/// 快进/后退专用的圆角按钮图标：根据秒数选一个最接近的原生图标。
IconData thSeekIcon(int seconds, {required bool forward}) {
  if (seconds <= 5) {
    return forward ? Icons.forward_5 : Icons.replay_5;
  }
  if (seconds <= 10) {
    return forward ? Icons.forward_10 : Icons.replay_10;
  }
  if (seconds <= 30) {
    return forward ? Icons.forward_30 : Icons.replay_30;
  }
  // 超过 30 秒没有对应图标，用通用的
  return forward ? Icons.fast_forward : Icons.fast_rewind;
}
