// 上游: kodjodevf/mangayomi@91bda20a9235 | 许可证: Apache-2.0 | 方式: 文件移植（正文逐字）
// 台账: vendor/MANIFEST.json → ported[id=mangayomi_interactive_region]
// 上游路径: lib/modules/manga/reader/widgets/reader_interactive_region.dart
//
// 作用：把阅读器页内按钮（如图片失败态「重试」）登记为交互区，
// 全屏翻页手势命中这些区域时让位，避免点按钮顺带翻页。
// 本项目手势层是父级包裹而非 overlay 叠加，故用 containsPosition 守卫，
// 与上游 ReaderInteractiveHitTestBlocker 的 render-object 拦截语义等价；
// 该类原样保留，待 reader_view 整套搬入改为 Stack 结构时启用。
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Registry of interactive regions in the reader (e.g. Retry buttons on failed pages)
/// that should take priority over reader gesture overlay tap handlers.
class ReaderInteractiveRegions {
  static final Set<GlobalKey> _keys = {};

  static void register(GlobalKey key) => _keys.add(key);
  static void unregister(GlobalKey key) => _keys.remove(key);

  /// Checks whether [globalPosition] falls inside any currently active and mounted
  /// interactive region.
  static bool containsPosition(Offset globalPosition) {
    if (_keys.isEmpty) return false;
    for (final key in _keys) {
      final context = key.currentContext;
      if (context == null) continue;
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize && renderBox.attached) {
        final localPos = renderBox.globalToLocal(globalPosition);
        if (renderBox.paintBounds.contains(localPos)) {
          return true;
        }
      }
    }
    return false;
  }
}

/// A widget that registers its subtree as an interactive region that bypasses
/// the reader gesture overlays.
class ReaderInteractiveRegion extends StatefulWidget {
  final Widget child;
  const ReaderInteractiveRegion({super.key, required this.child});

  @override
  State<ReaderInteractiveRegion> createState() =>
      _ReaderInteractiveRegionState();
}

class _ReaderInteractiveRegionState extends State<ReaderInteractiveRegion> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    ReaderInteractiveRegions.register(_key);
  }

  @override
  void dispose() {
    ReaderInteractiveRegions.unregister(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

/// A widget that wraps reader overlays and prevents them from capturing hit tests
/// if the touch location falls inside a registered [ReaderInteractiveRegion].
class ReaderInteractiveHitTestBlocker extends SingleChildRenderObjectWidget {
  const ReaderInteractiveHitTestBlocker({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderReaderInteractiveHitTestBlocker();
  }
}

class _RenderReaderInteractiveHitTestBlocker extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final Offset globalPos = localToGlobal(position);
    if (ReaderInteractiveRegions.containsPosition(globalPos)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}
