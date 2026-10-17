// 模块抽屉（2026-10-17）
//
// ★用户需求原话：
//   「AI 的页面像我们原来做的那一个网页版一样，左环能拉出上面的那个左上角……
//     这个是每个模块中左的用处，而不是左滑切换别的模块，你千万不要搞错了」
//   → 确认后：**每个模块**左上角按钮 / 边缘右滑 → 拉出**该模块自己的快捷面板**。
//     （模块间左右滑动切换在 4.52.0 已被用户明令禁用，本组件**不涉及**切模块。）
//
// 交互设计（与 AI 页的抽屉保持同一套手感，用户不必学两套）：
//   · 边缘 36px 内右滑 → 跟手拖出；速度 >350 快甩即开/关；慢拖按 40% 距离判定
//   · 松手 260ms easeOutCubic 收尾；开=中震、收=轻震（走 Haptic 层，受总开关控制）
//   · 点遮罩关闭；点左上角按钮打开；切模块时静默收起（不震动不动画）
//
// 视觉（对齐 Kimi 官网的克制风格）：
//   · 抽屉右侧大圆角 18；白/深色底 + 极淡投影；标题行带模块图标
//   · 快捷入口是**卡片**（图标 + 标题 + 副标题），不是纯文字行
//   · 设置区用分隔线分组，开关用紧凑样式
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'haptic.dart';

/// 一个快捷入口（书架/历史/发现/搜索…）。
class ModuleAction {
  const ModuleAction(this.icon, this.title, {this.sub = '', this.onTap});
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;
}

/// 模块抽屉宿主：包住模块主体，提供「左上角按钮 + 边缘右滑拉出」。
///
/// [child] 是模块原有内容；[actions] / [settings] 是抽屉里的内容。
/// [currentTab] + [tabCount] 用来高亮"当前在哪个页签"。
class ModuleDrawerHost extends StatefulWidget {
  const ModuleDrawerHost({
    super.key,
    required this.moduleTitle,
    required this.moduleIcon,
    required this.child,
    this.actions = const [],
    this.settings = const [],
    this.currentTab = 0,
    this.onTab,
    this.accent,
  });

  final String moduleTitle;
  final IconData moduleIcon;
  final Widget child;
  final List<ModuleAction> actions;
  final List<Widget> settings;
  final int currentTab;
  final ValueChanged<int>? onTab;
  final Color? accent;

  @override
  State<ModuleDrawerHost> createState() => ModuleDrawerHostState();
}

class ModuleDrawerHostState extends State<ModuleDrawerHost>
    with SingleTickerProviderStateMixin {
  double _p = 0; // 0=收起 1=全开
  bool _open = false;
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  double _w() => (MediaQuery.of(context).size.width * 0.78).clamp(0.0, 320.0);

  void _applyDrag(double dx) {
    final w = _w();
    final base = _open ? w : 0.0;
    setState(() => _p = ((base + dx) / w).clamp(0.0, 1.0));
  }

  void _settle(double dx, double vx) {
    _applyDrag(dx);
    final open = vx > 350 ? true : vx < -350 ? false : _p >= 0.4;
    animateTo(open);
  }

  void animateTo(bool open) {
    if (open && !_open) Haptic.medium();
    if (!open && _open) Haptic.light();
    _open = open;
    final from = _p;
    _ac.stop();
    _ac.removeListener(_tick);
    void tick() => setState(() => _p =
        from + ((open ? 1.0 : 0.0) - from) * Curves.easeOutCubic.transform(_ac.value));
    _tick = tick;
    _ac.addListener(tick);
    _ac.forward(from: 0);
  }

  VoidCallback _tick = () {};

  /// 切模块时调用：静默收起（不震动、不动画 —— 否则切模块会莫名震一下）。
  void closeSilent() {
    _ac.stop();
    if (_open || _p > 0) setState(() { _open = false; _p = 0; });
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = _w();
    final accent = widget.accent ?? cs.primary;
    return Stack(children: [
      widget.child,
      // 边缘手势层（只在左边缘 36px 内响应，避免与横向滚动/翻页冲突）
      Positioned(
        left: 0, top: 0, bottom: 0, width: 36,
        child: _p > 0
            ? const SizedBox.shrink()
            // ★统一口径：与 AI 抽屉同一个识别器（12px + 垂直 1.5 倍判定）
            : RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                gestures: {
                  EdgeSwipeRecognizer:
                      GestureRecognizerFactoryWithHandlers<EdgeSwipeRecognizer>(
                    () => EdgeSwipeRecognizer(),
                    (r) {
                      r.onUpdate = (dx) { if (dx > 0) _applyDrag(dx); };
                      r.onEnd = (dx, vx) { if (dx > 0) _settle(dx, vx); };
                    },
                  ),
                },
                child: const SizedBox.expand(),
              ),
      ),
      // 遮罩 + 抽屉
      if (_p > 0) ...[
        Positioned.fill(
          child: GestureDetector(
            onTap: () => animateTo(false),
            child: Container(
              color: Colors.black.withValues(alpha: 0.38 * _p),
            ),
          ),
        ),
        Positioned(
          left: -w * (1 - _p),
          top: 0,
          bottom: 0,
          width: w,
          child: GestureDetector(
            onHorizontalDragUpdate: (d) => _applyDrag(d.delta.dx),
            onHorizontalDragEnd: (d) =>
                _settle(0, d.velocity.pixelsPerSecond.dx),
            child: Material(
              color: cs.surface,
              elevation: 18,
              shadowColor: Colors.black45,
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
              ),
              clipBehavior: Clip.antiAlias,
              child: _content(context, cs, accent),
            ),
          ),
        ),
      ],
    ]);
  }

  double _cum = 0;

  Widget _content(BuildContext c, ColorScheme cs, Color accent) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ── 标题行 ──
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 10, 8),
        child: Row(children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(widget.moduleIcon, size: 19, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.moduleTitle,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              Text('快捷面板',
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45))),
            ]),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => animateTo(false),
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 20), children: [
          // ── 快捷入口（卡片）──
          if (widget.actions.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text('快速进入',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface.withValues(alpha: 0.5))),
            ),
            for (var i = 0; i < widget.actions.length; i++)
              _actionCard(c, cs, accent, widget.actions[i], i == widget.currentTab),
            const SizedBox(height: 14),
          ],
          // ── 设置区 ──
          if (widget.settings.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text('常用设置',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface.withValues(alpha: 0.5))),
            ),
            ...widget.settings,
          ],
        ]),
      ),
    ]);
  }

  Widget _actionCard(BuildContext c, ColorScheme cs, Color accent,
      ModuleAction a, bool active) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: active
            ? accent.withValues(alpha: 0.12)
            : cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () {
            Haptic.tap();
            a.onTap?.call();
            animateTo(false);          // 点完就收起，别挡着内容
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              Icon(a.icon,
                  size: 19,
                  color: active ? accent : cs.onSurface.withValues(alpha: 0.65)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.title,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
                  if (a.sub.isNotEmpty)
                    Text(a.sub,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: cs.onSurface.withValues(alpha: 0.45))),
                ]),
              ),
              if (active)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('当前',
                      style: TextStyle(
                          fontSize: 9.5, fontWeight: FontWeight.w700, color: accent)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 抽屉里用的紧凑开关行（各模块直接塞进 settings）。
class ModuleDrawerSwitch extends StatelessWidget {
  const ModuleDrawerSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.sub = '',
  });
  final String title;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      subtitle: sub.isEmpty
          ? null
          : Text(sub,
              style: TextStyle(
                  fontSize: 10.5, color: cs.onSurface.withValues(alpha: 0.45))),
      value: value,
      onChanged: (v) {
        Haptic.tap();
        onChanged(v);
      },
    );
  }
}

/// 横向滑动识别器（全 App 统一口径，2026-10-17）。
///
/// 判定：水平位移 > 12px 且 > 垂直位移的 1.5 倍才认领手势。
/// 竖向滚动、左滑、轻微斜划都会主动放弃 —— 这是「既不迟钝也不误触」的那条线。
///
/// 为什么不用标准 GestureDetector.onHorizontalDrag：它只要水平位移超过
/// 系统 touch slop 就认，不看垂直分量 —— 用户手指斜着划列表就会被误判成
/// 「要开抽屉」。这是「有的太灵敏」的来源（AI 页用严格判定、模块页用宽松判定，
/// 两处不一致，用户手感自然时好时坏）。
class EdgeSwipeRecognizer extends OneSequenceGestureRecognizer {
  double sx = 0;
  double sy = 0;
  bool active = false;
  bool claimed = false;
  final List<(int, double)> trail = []; // (毫秒, 累计 dx) 速度估计

  void Function(double dx)? onUpdate;
  void Function(double dx, double vx)? onEnd;

  @override
  String get debugDescription => 'horizontalSwipe';

  @override
  void addAllowedPointer(PointerDownEvent e) {
    sx = e.position.dx;
    sy = e.position.dy;
    active = true;
    claimed = false;
    trail.clear();
    startTrackingPointer(e.pointer);
  }

  @override
  void handleEvent(PointerEvent e) {
    if (!active) return;
    if (e is PointerMoveEvent) {
      final dx = e.position.dx - sx;
      final dy = e.position.dy - sy;
      if (!claimed) {
        if (dx > 12 && dx > dy.abs() * 1.5) {
          claimed = true;
          resolve(GestureDisposition.accepted);
        } else if (dy.abs() > 12 || dx < -8) {
          // 竖向滚动 或 左滑 → 放弃（绝不抢列表）
          active = false;
          stopTrackingPointer(e.pointer);
          return;
        } else {
          return;
        }
      }
      trail.add((e.timeStamp.inMilliseconds, dx));
      onUpdate?.call(dx); // ★传**总位移**（调用方按「起点 + 总位移」算进度）
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      final vx = _velocity();
      active = false;
      stopTrackingPointer(e.pointer);
      onEnd?.call(e.position.dx - sx, vx);
    }
  }

  /// 用最近 120ms 的轨迹估速度（px/s）。
  double _velocity() {
    if (trail.length < 2) return 0;
    final last = trail.last;
    var first = trail.first;
    for (final x in trail) {
      if (last.$1 - x.$1 <= 120) {
        first = x;
        break;
      }
    }
    final dt = (last.$1 - first.$1).toDouble();
    if (dt <= 0) return 0;
    return (last.$2 - first.$2) / dt * 1000;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
}
