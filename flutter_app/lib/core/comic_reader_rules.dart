// 上游: venera-app/venera@a0eba914f4c2 | 许可证: GPL-3.0 | 方式: 规则提取（不搬 widget / 状态层）
// 台账: vendor/MANIFEST.json → ported[id=comic_reader_rules]
// 漫画阅读器运行规则 —— 移植自 Venera（venera-app/venera，GPL-3.0，master，2026-11-07 核实）。
//
// 许可证与合规边界见 outputs/ThirdHub全盘升级计划-20261107.md：
// Venera 的整套界面骨架只在桌面端 / 自托管侧分发；移动端只保留能独立编译的
// 运行逻辑（判页 / 阅读方向 / 跨话导航 / 追更调度），不引入它的界面骨架、
// 脚本运行时、状态层与第三方站点清单。这与 4.81.42 移植 comic_image.dart 的
// 做法一致：照抄规则，只做脱依赖适配。
//
// 来源与逐常量核对（不是照印象重写）：
//   · lib/pages/reader/reader.dart:769-793   enum ReaderMode 六种方向与 fromKey 回落
//   · lib/pages/reader/gesture.dart:15-22    双击 / 长按 / 点击分区阈值
//   · lib/pages/reader/gesture.dart:136-151  滚轮跨话导航（仅 gallery）
//   · lib/pages/reader/gesture.dart:201-271  点击分区判页与反向翻页
//   · lib/foundation/follow_updates.dart:14-176  追更重试 / 并发 / 节流 / 免检窗口
//
// 本文件零 import、零 IO、零界面文案，可被纯 Dart 自检直接 import。

/// 阅读方向：Venera `enum ReaderMode` 六个值原样保留（含 fromKey 的未知名回落）。
enum ComicReadMode {
  galleryLeftToRight('galleryLeftToRight'),
  galleryRightToLeft('galleryRightToLeft'),
  galleryTopToBottom('galleryTopToBottom'),
  continuousTopToBottom('continuousTopToBottom'),
  continuousLeftToRight('continuousLeftToRight'),
  continuousRightToLeft('continuousRightToLeft');

  const ComicReadMode(this.key);

  final String key;

  bool get isGallery => key.startsWith('gallery');

  bool get isContinuous => key.startsWith('continuous');

  /// reader.dart:785-792。未知名一律回落到 galleryLeftToRight，不抛异常。
  static ComicReadMode fromKey(String key) {
    for (final m in values) {
      if (m.key == key) return m;
    }
    return galleryLeftToRight;
  }
}

/// gesture.dart:21 —— 屏幕左右 / 上下各 30% 是翻页区，中间 40% 是菜单区。
const double kTapToTurnPagePercent = 0.3;

/// gesture.dart:15 / 17 / 19 —— 双击窗口 200ms、长按 250ms、双击最大位移平方 20*20。
const int kDoubleTapMaxMs = 200;
const int kLongPressMinMs = 250;
const double kDoubleTapMaxDistanceSquared = 400.0;

/// gesture.dart:76 —— 位移超过 20*20 视为拖拽，不是长按。
const double kDragDistanceSquared = 400.0;

/// 一次点击落在哪些区。
///
/// Venera 原本用四个独立 bool（角落会同时命中两个轴），这里保持同样语义，
/// 不合并成单个枚举：合并后 RTL 与上下方向的角落点击会判错。
class ComicTapHit {
  const ComicTapHit({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });

  final bool left;
  final bool right;
  final bool top;
  final bool bottom;

  /// gesture.dart:213-227。宽或高非正时一律视为中间区，不翻页（防除零 / 越界）。
  factory ComicTapHit.at(double x, double y, double width, double height) {
    if (!(width > 0) || !(height > 0)) {
      return const ComicTapHit(
          left: false, right: false, top: false, bottom: false);
    }
    const p = kTapToTurnPagePercent;
    final isLeft = x < width * p;
    final isRight = !isLeft && x > width * (1 - p);
    final isTop = y < height * p;
    final isBottom = !isTop && y > height * (1 - p);
    return ComicTapHit(
        left: isLeft, right: isRight, top: isTop, bottom: isBottom);
  }
}

enum ComicTapAction { prev, next, toggleUi }

/// gesture.dart:229-269。
///
/// reverse 对应「反向点击翻页」设置：Venera 是把 prev / next 两个回调互换，
/// 这里照样互换动作而不改分区判定。未命中任何轴的落点返回 toggleUi
/// （Venera 在这里打开工具栏）。
ComicTapAction tapActionOf(ComicReadMode mode, ComicTapHit hit,
    {bool reverse = false}) {
  const prev = ComicTapAction.prev;
  const next = ComicTapAction.next;
  final p = reverse ? next : prev;
  final n = reverse ? prev : next;
  switch (mode) {
    case ComicReadMode.galleryLeftToRight:
    case ComicReadMode.continuousLeftToRight:
      if (hit.left) return p;
      if (hit.right) return n;
      return ComicTapAction.toggleUi;
    case ComicReadMode.galleryRightToLeft:
    case ComicReadMode.continuousRightToLeft:
      if (hit.left) return n;
      if (hit.right) return p;
      return ComicTapAction.toggleUi;
    case ComicReadMode.galleryTopToBottom:
    case ComicReadMode.continuousTopToBottom:
      if (hit.top) return p;
      if (hit.bottom) return n;
      return ComicTapAction.toggleUi;
  }
}

/// gesture.dart:181-198。两次点击的时间与位移都在窗口内才算双击。
bool isDoubleTap(int elapsedMs, double distanceSquared) =>
    elapsedMs >= 0 &&
    elapsedMs <= kDoubleTapMaxMs &&
    distanceSquared < kDoubleTapMaxDistanceSquared;

/// gesture.dart:74-86。按住超过 250ms 且没拖动算长按；拖动算手势。
bool isLongPress(int elapsedMs, double distanceSquared) =>
    elapsedMs >= kLongPressMinMs && distanceSquared < kDragDistanceSquared;

enum ComicNavAction { none, prevPage, nextPage, prevChapter, nextChapter }

/// gesture.dart:136-151（滚轮跨话）。
///
/// hasPage = 本方向还有页；atChapterEdge = 已经没有可切的上一话 / 下一话。
/// 非 gallery 模式 Venera 不处理滚轮，这里保留同样判据。
ComicNavAction wheelActionOf(ComicReadMode mode, bool forward,
    {required bool hasPage, required bool atChapterEdge}) {
  if (!mode.isGallery) return ComicNavAction.none;
  if (forward) {
    if (hasPage) return ComicNavAction.nextPage;
    return atChapterEdge
        ? ComicNavAction.none
        : ComicNavAction.nextChapter;
  }
  if (hasPage) return ComicNavAction.prevPage;
  return atChapterEdge ? ComicNavAction.none : ComicNavAction.prevChapter;
}

/// follow_updates.dart:14-176 —— 追更调度规则。
class ComicFollowPlan {
  const ComicFollowPlan._();

  /// 单本失败重试 3 次，每次间隔 2 秒（:16 / :66-70）。
  static const int maxRetries = 3;
  static const int retryDelaySeconds = 2;

  /// 队列容量 10、5 个消费者（:119 / :141）。
  static const int channelCapacity = 10;
  static const int consumers = 5;

  /// 24 小时内查过的跳过（:103-110，原版用 `inDays < 1`）。
  static bool shouldSkipCheck(DateTime? lastCheck, DateTime now) {
    if (lastCheck == null) return false;
    return now.difference(lastCheck).inDays < 1;
  }

  /// 每处理 5 本节流一次，delay = min(c % 100 + 1, 10) 秒（:124-135）。
  /// 非 5 的倍数返回 0 表示不等待。
  static int throttleDelaySeconds(int processed) {
    if (processed <= 0 || processed % 5 != 0) return 0;
    var d = processed % 100 + 1;
    if (d > 10) d = 10;
    return d;
  }
}

/// 整套移植的部件清单（许可留存记录，不参与移动端编译）。
///
/// reader 目录 8 个部件 + 运行逻辑层 3 个 foundation 部件；
/// 明确不含 js 运行时与第三方站点清单 —— 那些只留在桌面端 / 自托管侧。
const kVeneraReaderParts = <String>[
  'lib/pages/reader/reader.dart',
  'lib/pages/reader/scaffold.dart',
  'lib/pages/reader/images.dart',
  'lib/pages/reader/gesture.dart',
  'lib/pages/reader/comic_image.dart',
  'lib/pages/reader/loading.dart',
  'lib/pages/reader/chapters.dart',
  'lib/pages/reader/chapter_comments.dart',
  'lib/foundation/follow_updates.dart',
  'lib/foundation/history.dart',
  'lib/foundation/favorites.dart',
];
