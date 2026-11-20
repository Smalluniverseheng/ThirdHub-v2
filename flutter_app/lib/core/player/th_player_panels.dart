// 第三方聚合 · 播放器弹出面板（4.81.81）
//
// 面板只管展示和选择；状态归 th_player.dart 管。点选**立即**回调，
// 不搞"选完再按确定"——用户点「裁剪铺满」就该当场看到画面变化。

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../haptic.dart';
import '../i18n.dart';
import 'th_player_types.dart';

/// 底部弹层的统一外壳：圆角、安全区、可滚动、标题。
Widget _sheetShell(
  BuildContext c, {
  required String title,
  String? subtitle,
  required Widget child,
  double maxH = 0.78,
}) {
  final cs = Theme.of(c).colorScheme;
  final h = MediaQuery.of(c).size.height;
  return SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: h * maxH),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Center(
              child: Container(
                width: 34,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                if (subtitle != null && subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle,
                        style: TextStyle(
                            fontSize: 11.5, color: cs.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          Flexible(child: child),
          const SizedBox(height: Gap.sm),
        ],
      ),
    ),
  );
}

Future<T?> _openSheet<T>(BuildContext c, Widget child) {
  return showModalBottomSheet<T>(
    context: c,
    backgroundColor: Theme.of(c).colorScheme.surface,
    isScrollControlled: true,
    showDragHandle: false,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
    ),
    builder: (_) => child,
  );
}

/// 倍速。横排 chips 一屏点完 —— 比 YouTube 那种点三层齿轮顺手。
Future<double?> showThSpeedSheet(BuildContext c, double current) {
  return _openSheet<double>(
    c,
    _sheetShell(
      c,
      title: tr('播放速度'),
      subtitle: tr('长按画面也能临时加速，松手恢复'),
      maxH: 0.5,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          children: kThSpeeds.map((s) {
            final on = (s - current).abs() < 0.001;
            return ChoiceChip(
              label:
                  Text(thSpeedLabel(s), style: const TextStyle(fontSize: 13)),
              selected: on,
              onSelected: (_) {
                Haptic.tap();
                Navigator.pop(c, s);
              },
            );
          }).toList(),
        ),
      ),
    ),
  );
}

/// 清晰度。列出来源真正给的档位；只有一档时也照实说，不做假菜单。
Future<int?> showThQualitySheet(
  BuildContext c,
  List<ThQuality> list,
  int index,
) {
  return _openSheet<int>(
    c,
    _sheetShell(
      c,
      title: tr('清晰度'),
      subtitle: list.length <= 1
          ? tr('这一集只提供一档清晰度')
          : tr('切换会重新取流，进度保留'),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: list.length,
        itemBuilder: (_, i) {
          final q = list[i];
          final on = i == index;
          return ListTile(
            dense: true,
            leading: Icon(
              on ? Icons.check_circle : Icons.circle_outlined,
              size: 18,
              color:
                  on ? Theme.of(c).colorScheme.primary : Theme.of(c).disabledColor,
            ),
            title: Text(q.label,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
            onTap: on
                ? null
                : () {
                    Haptic.tap();
                    Navigator.pop(c, i);
                  },
          );
        },
      ),
    ),
  );
}

/// 定时关闭。返回分钟数：0 = 取消定时，null = 没操作。
Future<int?> showThSleepSheet(BuildContext c, DateTime? endAt) {
  const opts = <int>[0, 15, 30, 45, 60, 90, 120];
  return _openSheet<int>(
    c,
    _sheetShell(
      c,
      title: tr('定时关闭'),
      subtitle: endAt == null
          ? tr('到点自动暂停，正在下载的不会中断')
          : trf('已设定，{t} 自动暂停', {'t': thClock(Duration(hours: endAt.hour, minutes: endAt.minute))}),
      maxH: 0.6,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final m in opts)
            ListTile(
              dense: true,
              title: Text(m == 0 ? tr('关闭定时') : trf('{n} 分钟后', {'n': m}),
                  style: const TextStyle(fontSize: 13.5)),
              onTap: () {
                Haptic.tap();
                Navigator.pop(c, m);
              },
            ),
        ],
      ),
    ),
  );
}

/// "更多"面板的状态载体。
class ThMoreConfig {
  const ThMoreConfig({
    this.fit = ThFit.contain,
    this.loop = ThLoop.off,
    this.seekStep = 10,
    this.autoNext = true,
    this.danmaku = true,
    this.subtitleOn = true,
  });

  final ThFit fit;
  final ThLoop loop;
  final int seekStep;
  final bool autoNext;
  final bool danmaku;
  final bool subtitleOn;

  ThMoreConfig copyWith({
    ThFit? fit,
    ThLoop? loop,
    int? seekStep,
    bool? autoNext,
    bool? danmaku,
    bool? subtitleOn,
  }) =>
      ThMoreConfig(
        fit: fit ?? this.fit,
        loop: loop ?? this.loop,
        seekStep: seekStep ?? this.seekStep,
        autoNext: autoNext ?? this.autoNext,
        danmaku: danmaku ?? this.danmaku,
        subtitleOn: subtitleOn ?? this.subtitleOn,
      );
}

/// "更多"面板：画面比例、循环、双击步长、自动连播、弹幕/字幕开关，
/// 外加调用方塞进来的附加项（下载本集、选集、投屏……）。
///
/// [onChanged] 点一下就回调，不等"确定"。
Future<void> showThMoreSheet(
  BuildContext c, {
  required ThMoreConfig cur,
  required ValueChanged<ThMoreConfig> onChanged,
  List<ThMoreItem> extras = const [],
  bool hasDanmaku = false,
  bool hasSubtitle = false,
}) {
  // ★必须在 builder 外面：StatefulBuilder 每次重建都会重跑 builder，
  //   写在里面会被重置成 cur，表现为"点了没反应"。
  var v = cur;

  return _openSheet<void>(
    c,
    StatefulBuilder(
      builder: (c, setSheet) {
        final cs = Theme.of(c).colorScheme;

        Widget seg<T>(
          String title,
          List<(T, String)> opts,
          T now,
          void Function(T) pick, {
          String sub = '',
        }) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                if (sub.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(sub,
                        style:
                            TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
                const SizedBox(height: Gap.sm),
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: opts
                      .map((o) => ChoiceChip(
                            label:
                                Text(o.$2, style: const TextStyle(fontSize: 12.5)),
                            selected: o.$1 == now,
                            onSelected: (_) {
                              Haptic.tap();
                              setSheet(() => pick(o.$1));
                            },
                          ))
                      .toList(),
                ),
              ],
            ),
          );
        }

        return _sheetShell(
          c,
          title: tr('播放设置'),
          subtitle: tr('这些只影响本机播放，不改视频本身'),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              if (extras.isNotEmpty) ...[
                for (final e in extras)
                  ListTile(
                    dense: true,
                    leading: Icon(e.icon, size: 20),
                    title:
                        Text(e.label, style: const TextStyle(fontSize: 13.5)),
                    subtitle: e.sub.isEmpty
                        ? null
                        : Text(e.sub, style: const TextStyle(fontSize: 11)),
                    trailing: e.selected
                        ? Icon(Icons.check, size: 16, color: cs.primary)
                        : null,
                    onTap: e.onTap == null
                        ? null
                        : () {
                            Navigator.pop(c);
                            e.onTap!();
                          },
                  ),
                const Divider(height: 1),
              ],
              seg<ThFit>(
                tr('画面比例'),
                [
                  (ThFit.contain, tr('适应')),
                  (ThFit.cover, tr('裁剪铺满')),
                  (ThFit.fill, tr('拉伸')),
                  (ThFit.r16x9, '16:9'),
                  (ThFit.r4x3, '4:3'),
                ],
                v.fit,
                (x) {
                  v = v.copyWith(fit: x);
                  onChanged(v);
                },
                sub: tr('竖屏短剧选「裁剪铺满」，上下黑边就没了'),
              ),
              seg<ThLoop>(
                tr('循环'),
                [
                  (ThLoop.off, tr('不循环')),
                  (ThLoop.one, tr('单集循环')),
                  (ThLoop.all, tr('列表循环')),
                ],
                v.loop,
                (x) {
                  v = v.copyWith(loop: x);
                  onChanged(v);
                },
              ),
              seg<int>(
                tr('双击快进'),
                [(5, '5 秒'), (10, '10 秒'), (15, '15 秒'), (30, '30 秒')],
                v.seekStep,
                (x) {
                  v = v.copyWith(seekStep: x);
                  onChanged(v);
                },
                sub: tr('双击画面左半边后退、右半边前进'),
              ),
              if (hasDanmaku || hasSubtitle) const Divider(height: 1),
              if (hasDanmaku)
                SwitchListTile(
                  dense: true,
                  value: v.danmaku,
                  title: Text(tr('显示弹幕'),
                      style: const TextStyle(fontSize: 13.5)),
                  onChanged: (x) {
                    Haptic.tap();
                    setSheet(() {
                      v = v.copyWith(danmaku: x);
                      onChanged(v);
                    });
                  },
                ),
              if (hasSubtitle)
                SwitchListTile(
                  dense: true,
                  value: v.subtitleOn,
                  title: Text(tr('显示字幕'),
                      style: const TextStyle(fontSize: 13.5)),
                  onChanged: (x) {
                    Haptic.tap();
                    setSheet(() {
                      v = v.copyWith(subtitleOn: x);
                      onChanged(v);
                    });
                  },
                ),
              SwitchListTile(
                dense: true,
                value: v.autoNext,
                title: Text(tr('播完自动下一集'),
                    style: const TextStyle(fontSize: 13.5)),
                onChanged: (x) {
                  Haptic.tap();
                  setSheet(() {
                    v = v.copyWith(autoNext: x);
                    onChanged(v);
                  });
                },
              ),
              const SizedBox(height: Gap.md),
            ],
          ),
        );
      },
    ),
  );
}
