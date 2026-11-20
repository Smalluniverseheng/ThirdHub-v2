// AI 控制总线 · 目标注册表 + 输入注入
//
// 这一层的职责只有一个：把「抽象指令」翻译成「这个 App 里真正会发生的事」。
// 具体分三块：
//   1) 语义入口注册（打开模块 / 切根页签 / 切视频平台 / 播放器控制）
//      —— main.dart 在启动时把内部回调注进来，所以本文件**不 import main.dart**，
//         避免 17k 行的 main 和 core 互相 import。
//   2) 控件定位（按 key / 按文字找到屏幕坐标）
//   3) 真实手势注入（PointerEvent 序列，走命中测试，等价于手指）
//
// 为什么手势要"真注入"而不是直接调 onTap 回调：
//   直接调回调只能测"逻辑"，测不到「按钮被别的层盖住」「元素在屏幕外」这类
//   真实 UI 缺陷 —— 而那恰恰是用户看得见、我们看不见的东西。

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 一个可被 AI 寻址的目标（从 Element 树实时扫出来）。
class AgentNode {
  final String kind; // text / key / button
  final String label; // 展示文字或 key 名
  final Rect rect; // 全局矩形
  final bool enabled;

  const AgentNode(this.kind, this.label, this.rect, {this.enabled = true});

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'label': label,
        'rect': [rect.left, rect.top, rect.right, rect.bottom],
        if (!enabled) 'enabled': false,
      };
}

class AgentTargets {
  AgentTargets._();

  // ── 1. 语义入口（由 main.dart 注入）──

  static GlobalKey<NavigatorState>? navigatorKey;

  /// 打开某个模块（走 RootNav 的 proOpenModule 通道：未启用会自动加进导航栏）
  static Future<bool> Function(String module)? openModule;

  /// 切根导航到第 i 项（或按名字）
  static Future<bool> Function(String module)? switchModule;

  /// 视频页横向切平台：index 或名字
  static Future<bool> Function(String platform)? switchVideoPlatform;

  /// 模块内子页签（B 站七栏目、漫画源等）：{page, index|name}
  static Future<bool> Function(String page, String tab)? switchSubTab;

  /// 应用状态快照（当前模块、平台、路由深度、播放器等）
  static Map<String, dynamic> Function()? stateProvider;

  /// 前端自己注册的具名动作：{"name": (args) async => ...}
  /// 用途：某个功能没有 UI 入口（比如"用第 3 个源搜索某本书"），
  /// 也能被测试直接驱动，不必为测试硬加按钮。
  static final Map<String, Future<dynamic> Function(Map<String, dynamic>)> actions =
      {};

  /// 根 RepaintBoundary（截图用），由 AgentOrbHost 挂上
  static final GlobalKey rootBoundaryKey = GlobalKey();

  /// 最近一次状态里报告的屏幕尺寸（逻辑像素）
  static Size screenSize = Size.zero;

  // ── 2. 控件定位 ──

  /// 按文字找第一个**可见且在屏幕内**的匹配控件。
  ///
  /// 为什么不用 WidgetTester：那不是 release 包里的能力。这里直接走 Element 树，
  /// 语义等价于「用户眼睛看到这行字，然后去点它」。
  static AgentNode? findByText(String text, {bool exact = false}) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    AgentNode? hit;
    void visit(Element e) {
      if (hit != null) return;
      final w = e.widget;
      String? label;
      if (w is Text && w.data != null) {
        label = w.data;
      } else if (w is RichText) {
        label = w.text.toPlainText();
      } else if (w is EditableText) {
        label = w.controller.text;
      } else if (w is Tooltip) {
        label = w.message;
      } else if (w is Semantics) {
        label = w.properties.label;
      }
      if (label != null && label.isNotEmpty) {
        final want = text.trim();
        final got = label.trim();
        final match = exact ? got == want : got.contains(want);
        if (match) {
          final r = rectOf(e);
          if (r != null && _onScreen(r)) {
            hit = AgentNode('text', got, r);
            return;
          }
        }
      }
      e.visitChildren(visit);
    }

    visit(root);
    return hit;
  }

  /// 按 GlobalKey 注册名找控件。注册表见 [registerKey]。
  static AgentNode? findByKey(String name) {
    final k = _keys[name];
    final ctx = k?.currentContext;
    if (ctx == null) return null;
    final r = rectOf(ctx);
    if (r == null) return null;
    return AgentNode('key', name, r);
  }

  static final Map<String, GlobalKey> _keys = {};

  /// 页面把关键控件登记为可寻址目标：`key: AgentTargets.registerKey('nav/video')`
  static GlobalKey registerKey(String name) =>
      _keys.putIfAbsent(name, () => GlobalKey(debugLabel: 'agent:$name'));

  /// 当前屏幕内所有可寻址文本 + 已注册 key —— 给 AI 一份"看得见什么"的清单。
  static List<AgentNode> visibleTree({int limit = 220}) {
    final out = <AgentNode>[];
    for (final e in _keys.entries) {
      final ctx = e.value.currentContext;
      if (ctx == null) continue;
      final r = rectOf(ctx);
      if (r != null && _onScreen(r)) out.add(AgentNode('key', e.key, r));
    }
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return out;
    void visit(Element e) {
      if (out.length >= limit) return;
      final w = e.widget;
      String? label;
      if (w is Text && w.data != null) {
        label = w.data;
      } else if (w is RichText) {
        label = w.text.toPlainText();
      }
      if (label != null && label.trim().isNotEmpty && label.trim().length <= 80) {
        final r = rectOf(e);
        if (r != null && _onScreen(r) && r.width > 8 && r.height > 8) {
          out.add(AgentNode('text', label.trim(), r));
        }
      }
      e.visitChildren(visit);
    }

    visit(root);
    return out;
  }

  static Rect? rectOf(BuildContext ctx) {
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    if (ro.size.width <= 0 || ro.size.height <= 0) return null;
    try {
      final o = ro.localToGlobal(Offset.zero);
      return o & ro.size;
    } catch (_) {
      return null;
    }
  }

  /// 判断是否真的在屏幕可见区域内（外层的 ListView 里滚出屏幕的元素也 attached，
  /// 但用户点不到 —— 直接点会打到别的东西，这种必须判掉）。
  static bool _onScreen(Rect r) {
    final s = screenSize;
    if (s == Size.zero) return true;
    final c = r.center;
    return c.dx >= 0 && c.dy >= 0 && c.dx <= s.width && c.dy <= s.height;
  }

  // ── 3. 手势注入 ──

  static int _pid = 7331;

  /// 归一化坐标（0~1）→ 逻辑像素
  static Offset px(List<double> xy) {
    final s = screenSize == Size.zero
        ? MediaQueryData.fromView(ui.PlatformDispatcher.instance.views.first).size
        : screenSize;
    double fx = xy[0], fy = xy[1];
    if (fx <= 1.0 && fy <= 1.0) {
      return Offset(fx * s.width, fy * s.height);
    }
    return Offset(fx, fy);
  }

  /// 真实点击：PointerDown → (短间隔) → PointerUp
  static Future<void> tap(Offset p) async {
    final g = GestureBinding.instance;
    final id = _pid++;
    final t0 = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch % 100000);
    g.handlePointerEvent(PointerDownEvent(
        pointer: id, position: p, timeStamp: t0, kind: PointerDeviceKind.touch));
    await Future<void>.delayed(const Duration(milliseconds: 24));
    g.handlePointerEvent(PointerUpEvent(
        pointer: id,
        position: p,
        timeStamp: t0 + const Duration(milliseconds: 24),
        kind: PointerDeviceKind.touch));
  }

  /// 真实滑动：分步 move，超过 kTouchSlop 才会被识别成 drag。
  /// [steps] 决定平滑度：PageView 翻页用 8~12 步足够，太快会被当成 fling 而不是翻页。
  static Future<void> swipe(Offset from, Offset to,
      {int steps = 10, int ms = 220}) async {
    final g = GestureBinding.instance;
    final id = _pid++;
    var t = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch % 100000);
    final gap = Duration(milliseconds: math.max(8, ms ~/ steps));
    g.handlePointerEvent(PointerDownEvent(
        pointer: id, position: from, timeStamp: t, kind: PointerDeviceKind.touch));
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(gap);
      t += gap;
      final p = Offset.lerp(from, to, i / steps)!;
      g.handlePointerEvent(PointerMoveEvent(
          pointer: id, position: p, timeStamp: t, kind: PointerDeviceKind.touch));
    }
    await Future<void>.delayed(gap);
    g.handlePointerEvent(PointerUpEvent(
        pointer: id,
        position: to,
        timeStamp: t + gap,
        kind: PointerDeviceKind.touch));
  }

  /// 指针事件需要"下一个微任务里 Flutter 才处理完"，这里统一等一帧 + 一小段，
  /// 否则脚本里 tap 之后立刻 assert 会读到动画开始前的旧树。
  static Future<void> settle([int ms = 260]) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    final done = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => done.complete());
    WidgetsBinding.instance.scheduleFrame();
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  // ── 4. 截图 ──

  /// 抓根 RepaintBoundary → PNG。pixelRatio 默认 1.0（手机 1080p 下约 1MB，
  /// 够 AI 看清文字；再高只会拖慢传输，没有额外信息量）。
  static Future<Uint8List?> shoot({double pixelRatio = 1.0}) async {
    final ctx = rootBoundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    try {
      final img = await ro.toImage(pixelRatio: pixelRatio);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return bd?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
