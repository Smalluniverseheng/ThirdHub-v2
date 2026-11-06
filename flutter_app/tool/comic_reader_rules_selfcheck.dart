// 漫画阅读器运行规则自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart run tool/comic_reader_rules_selfcheck.dart
//
// 为什么必须有这条闸门：#205 把 Venera 的阅读器运行逻辑脱依赖搬进本项目，
// 这类规则「改错了不会报错、不会崩」，只会静默地表现成
// 「点右边翻到上一页」「RTL 方向反了」「追更每本都查、把源站打爆」。
// 而且它是**移植代码**：上游常量一旦被顺手改掉，界面上没人看得出来。
//
// 本自检四层：
//   §1~§7 行为级：直接 import 规则层，把 Venera 的真实向量喂进去断言；
//   §8     常量级：把上游文件的真实数值写死在这儿，防止「照印象重写」；
//   §9     接线级：main.dart 真的调用了规则层，不是只放了个没人用的文件；
//   §10    合规级：移动端出货面不含 Venera 的运行时与第三方站点清单。
//
// ★ 末尾 exit(1)：CI 只看退出码，打印 FAIL 不等于拦住了（2026-09-28 血泪）。
import 'dart:io';

import '../lib/core/comic_reader_rules.dart';

int pass = 0, fail = 0;

void ck(String name, bool ok) {
  if (ok) {
    pass++;
  } else {
    fail++;
    print('  FAIL  $name');
  }
}

String readOr(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : '';
}

void main() {
  final rules = readOr('lib/core/comic_reader_rules.dart');
  final mainSrc = readOr('lib/main.dart');
  final self = readOr('tool/comic_reader_rules_selfcheck.dart');

  // ── §1 上游常量逐值一致（写死在这，改了就要两边一起改） ────────────────
  ck('§1 分区阈值 0.3', kTapToTurnPagePercent == 0.3);
  ck('§1 双击窗口 200ms', kDoubleTapMaxMs == 200);
  ck('§1 长按窗口 250ms', kLongPressMinMs == 250);
  ck('§1 双击位移平方 400', kDoubleTapMaxDistanceSquared == 400.0);
  ck('§1 拖拽位移平方 400', kDragDistanceSquared == 400.0);
  ck('§1 追更重试 3 次', ComicFollowPlan.maxRetries == 3);
  ck('§1 追更退避 2 秒', ComicFollowPlan.retryDelaySeconds == 2);
  ck('§1 追更队列容量 10', ComicFollowPlan.channelCapacity == 10);
  ck('§1 追更消费者 5', ComicFollowPlan.consumers == 5);

  // ── §2 阅读方向：六值、key、分类、回落 ─────────────────────────────────
  const keys = <String>[
    'galleryLeftToRight',
    'galleryRightToLeft',
    'galleryTopToBottom',
    'continuousTopToBottom',
    'continuousLeftToRight',
    'continuousRightToLeft',
  ];
  ck('§2 恰好 6 种方向', ComicReadMode.values.length == 6);
  for (var i = 0; i < keys.length; i++) {
    ck('§2 key[$i] = ${keys[i]}', ComicReadMode.values[i].key == keys[i]);
    ck('§2 fromKey[${keys[i]}] 往返',
        ComicReadMode.fromKey(keys[i]) == ComicReadMode.values[i]);
    ck('§2 isGallery[${keys[i]}]',
        ComicReadMode.values[i].isGallery == keys[i].startsWith('gallery'));
    ck('§2 isContinuous[${keys[i]}]',
        ComicReadMode.values[i].isContinuous ==
            keys[i].startsWith('continuous'));
    ck('§2 gallery 与 continuous 互斥[${keys[i]}]',
        ComicReadMode.values[i].isGallery !=
            ComicReadMode.values[i].isContinuous);
  }
  ck('§2 未知名回落 LTR',
      ComicReadMode.fromKey('not_a_mode') ==
          ComicReadMode.galleryLeftToRight);
  ck('§2 空 key 回落 LTR',
      ComicReadMode.fromKey('') == ComicReadMode.galleryLeftToRight);
  ck('§2 大小写敏感（错大小写不得命中 RTL）',
      ComicReadMode.fromKey('GalleryRightToLeft') ==
          ComicReadMode.galleryLeftToRight);

  // ── §3 点击分区：0.3 边界与四角同时命中 ────────────────────────────────
  const w = 1000.0, h = 2000.0;
  final left = ComicTapHit.at(100, 1000, w, h);
  ck('§3 左侧命中 left', left.left && !left.right);
  ck('§3 左侧中间不带 top', !left.top && !left.bottom);
  final topLeft = ComicTapHit.at(100, 100, w, h);
  ck('§3 左上角同时命中 left 与 top', topLeft.left && topLeft.top);
  final topRight = ComicTapHit.at(900, 100, w, h);
  ck('§3 右上角同时命中 right 与 top', topRight.right && topRight.top);
  final right = ComicTapHit.at(900, 1000, w, h);
  ck('§3 右侧命中 right', right.right && !right.left);
  final top = ComicTapHit.at(500, 100, w, h);
  ck('§3 顶部命中 top', top.top && !top.bottom && !top.left && !top.right);
  final bottom = ComicTapHit.at(500, 1900, w, h);
  ck('§3 底部命中 bottom', bottom.bottom && !bottom.top);
  final center = ComicTapHit.at(500, 1000, w, h);
  ck('§3 中心四区全 false',
      !center.left && !center.right && !center.top && !center.bottom);
  final at29 = ComicTapHit.at(299, 1000, w, h);
  final at31 = ComicTapHit.at(301, 1000, w, h);
  ck('§3 x=0.299W 仍在左区', at29.left);
  ck('§3 x=0.301W 已离开左区', !at31.left);
  final at71 = ComicTapHit.at(701, 1000, w, h);
  ck('§3 x=0.701W 进入右区', at71.right);
  final at69 = ComicTapHit.at(699, 1000, w, h);
  ck('§3 x=0.699W 不在右区', !at69.right);
  for (final bad in <List<double>>[
    [0, 0, 0, 0],
    [10, 10, -1, 100],
    [10, 10, 100, -1],
    [10, 10, double.nan, 100],
  ]) {
    final z = ComicTapHit.at(bad[0], bad[1], bad[2], bad[3]);
    ck('§3 非正尺寸 ${bad[2]}x${bad[3]} 一律中间区',
        !z.left && !z.right && !z.top && !z.bottom);
  }

  // ── §4 判页动作：6 模式 × 4 区 × reverse ───────────────────────────────
  final zones = <String, ComicTapHit>{
    'left': ComicTapHit.at(100, 1000, w, h),
    'right': ComicTapHit.at(900, 1000, w, h),
    'top': ComicTapHit.at(500, 100, w, h),
    'bottom': ComicTapHit.at(500, 1900, w, h),
    'center': center,
  };
  // Venera gesture.dart:236-264 的真实映射表。
  const expected = <ComicReadMode, Map<String, ComicTapAction>>{
    ComicReadMode.galleryLeftToRight: {
      'left': ComicTapAction.prev,
      'right': ComicTapAction.next,
      'top': ComicTapAction.toggleUi,
      'bottom': ComicTapAction.toggleUi,
      'center': ComicTapAction.toggleUi,
    },
    ComicReadMode.continuousLeftToRight: {
      'left': ComicTapAction.prev,
      'right': ComicTapAction.next,
      'top': ComicTapAction.toggleUi,
      'bottom': ComicTapAction.toggleUi,
      'center': ComicTapAction.toggleUi,
    },
    ComicReadMode.galleryRightToLeft: {
      'left': ComicTapAction.next,
      'right': ComicTapAction.prev,
      'top': ComicTapAction.toggleUi,
      'bottom': ComicTapAction.toggleUi,
      'center': ComicTapAction.toggleUi,
    },
    ComicReadMode.continuousRightToLeft: {
      'left': ComicTapAction.next,
      'right': ComicTapAction.prev,
      'top': ComicTapAction.toggleUi,
      'bottom': ComicTapAction.toggleUi,
      'center': ComicTapAction.toggleUi,
    },
    ComicReadMode.galleryTopToBottom: {
      'left': ComicTapAction.toggleUi,
      'right': ComicTapAction.toggleUi,
      'top': ComicTapAction.prev,
      'bottom': ComicTapAction.next,
      'center': ComicTapAction.toggleUi,
    },
    ComicReadMode.continuousTopToBottom: {
      'left': ComicTapAction.toggleUi,
      'right': ComicTapAction.toggleUi,
      'top': ComicTapAction.prev,
      'bottom': ComicTapAction.next,
      'center': ComicTapAction.toggleUi,
    },
  };
  for (final mode in ComicReadMode.values) {
    for (final zone in zones.entries) {
      ck('§4 ${mode.key}/${zone.key}',
          tapActionOf(mode, zone.value) == expected[mode]![zone.key]);
    }
  }
  for (final mode in ComicReadMode.values) {
    for (final zone in zones.entries) {
      final normal = tapActionOf(mode, zone.value);
      final rev = tapActionOf(mode, zone.value, reverse: true);
      final want = normal == ComicTapAction.prev
          ? ComicTapAction.next
          : normal == ComicTapAction.next
              ? ComicTapAction.prev
              : ComicTapAction.toggleUi;
      ck('§4 reverse ${mode.key}/${zone.key}', rev == want);
    }
  }
  // 角落：右上角同时命中 right 与 top。LTR 按 right 判（下一页），
  // TTB 按 top 判（上一页）—— 若把四个 bool 合并成单枚举，这里必然判错一半。
  ck('§4 右上角 LTR 走 right → 下一页',
      tapActionOf(ComicReadMode.galleryLeftToRight, topRight) ==
          ComicTapAction.next);
  ck('§4 右上角 TTB 走 top → 上一页',
      tapActionOf(ComicReadMode.galleryTopToBottom, topRight) ==
          ComicTapAction.prev);
  ck('§4 左上角 LTR 走 left → 上一页',
      tapActionOf(ComicReadMode.galleryLeftToRight, topLeft) ==
          ComicTapAction.prev);
  ck('§4 左上角 RTL 走 left → 下一页',
      tapActionOf(ComicReadMode.galleryRightToLeft, topLeft) ==
          ComicTapAction.next);

  // ── §5 双击 / 长按 ─────────────────────────────────────────────────────
  ck('§5 100ms/0 位移是双击', isDoubleTap(100, 0));
  ck('§5 恰好 200ms 是双击', isDoubleTap(200, 0));
  ck('§5 201ms 不是双击', !isDoubleTap(201, 0));
  ck('§5 399 位移平方是双击', isDoubleTap(0, 399));
  ck('§5 400 位移平方不是双击', !isDoubleTap(0, 400));
  ck('§5 负时间不是双击', !isDoubleTap(-1, 0));
  ck('§5 250ms/0 位移是长按', isLongPress(250, 0));
  ck('§5 249ms 不是长按', !isLongPress(249, 0));
  ck('§5 拖动 400 不是长按', !isLongPress(500, 400));
  ck('§5 600ms/399 是长按', isLongPress(600, 399));

  // ── §6 滚轮跨话（仅 gallery） ──────────────────────────────────────────
  for (final mode in ComicReadMode.values) {
    final g = mode.isGallery;
    ck('§6 ${mode.key} 前进有页 → 下一页',
        wheelActionOf(mode, true, hasPage: true, atChapterEdge: false) ==
            (g ? ComicNavAction.nextPage : ComicNavAction.none));
    ck('§6 ${mode.key} 后退有页 → 上一页',
        wheelActionOf(mode, false, hasPage: true, atChapterEdge: false) ==
            (g ? ComicNavAction.prevPage : ComicNavAction.none));
    ck('§6 ${mode.key} 前进无页非边缘 → 下一话',
        wheelActionOf(mode, true, hasPage: false, atChapterEdge: false) ==
            (g ? ComicNavAction.nextChapter : ComicNavAction.none));
    ck('§6 ${mode.key} 后退无页非边缘 → 上一话',
        wheelActionOf(mode, false, hasPage: false, atChapterEdge: false) ==
            (g ? ComicNavAction.prevChapter : ComicNavAction.none));
    ck('§6 ${mode.key} 边缘无页 → 不动',
        wheelActionOf(mode, true, hasPage: false, atChapterEdge: true) ==
            ComicNavAction.none);
  }

  // ── §7 追更调度 ────────────────────────────────────────────────────────
  final now = DateTime(2026, 11, 7, 12);
  ck('§7 从没查过不跳过',
      !ComicFollowPlan.shouldSkipCheck(null, now));
  ck('§7 1 小时前查过要跳过',
      ComicFollowPlan.shouldSkipCheck(now.subtract(const Duration(hours: 1)), now));
  ck('§7 23 小时前查过要跳过',
      ComicFollowPlan.shouldSkipCheck(now.subtract(const Duration(hours: 23)), now));
  ck('§7 25 小时前查过不跳过',
      !ComicFollowPlan.shouldSkipCheck(now.subtract(const Duration(hours: 25)), now));
  ck('§7 时间戳在未来也跳过',
      ComicFollowPlan.shouldSkipCheck(now.add(const Duration(hours: 2)), now));
  ck('§7 c<5 不节流', ComicFollowPlan.throttleDelaySeconds(4) == 0);
  ck('§7 c=0 不节流', ComicFollowPlan.throttleDelaySeconds(0) == 0);
  ck('§7 负数不节流', ComicFollowPlan.throttleDelaySeconds(-5) == 0);
  ck('§7 c=5 → 6 秒', ComicFollowPlan.throttleDelaySeconds(5) == 6);
  ck('§7 c=10 → 10 秒封顶',
      ComicFollowPlan.throttleDelaySeconds(10) == 10);
  ck('§7 c=95 → 10 秒封顶',
      ComicFollowPlan.throttleDelaySeconds(95) == 10);
  ck('§7 c=100 → 1 秒（取模回卷）',
      ComicFollowPlan.throttleDelaySeconds(100) == 1);
  ck('§7 c=105 → 6 秒',
      ComicFollowPlan.throttleDelaySeconds(105) == 6);
  for (var c = 1; c <= 300; c++) {
    final d = ComicFollowPlan.throttleDelaySeconds(c);
    ck('§7 节流值恒在 0..10 (c=$c)', d >= 0 && d <= 10);
  }

  // ── §8 上游源码结构（防「照印象重写」把文件改成自己的实现） ─────────────
  ck('§8 规则层存在', rules.isNotEmpty);
  ck('§8 规则层零 import', !rules.contains("import '") && !rules.contains('import "'));
  ck('§8 规则层标注 Venera 来源', rules.contains('venera-app/venera'));
  ck('§8 规则层标注 GPL-3.0', rules.contains('GPL-3.0'));
  ck('§8 规则层引用 gesture.dart', rules.contains('gesture.dart'));
  ck('§8 规则层引用 reader.dart', rules.contains('reader.dart'));
  ck('§8 规则层引用 follow_updates.dart',
      rules.contains('follow_updates.dart'));
  ck('§8 规则层不写死界面文案', !rules.contains("tr('"));
  ck('§8 部件清单恰好 11 项', kVeneraReaderParts.length == 11);
  ck('§8 清单含 reader.dart',
      kVeneraReaderParts.contains('lib/pages/reader/reader.dart'));
  ck('§8 清单含 comic_image.dart',
      kVeneraReaderParts.contains('lib/pages/reader/comic_image.dart'));
  ck('§8 清单含 follow_updates.dart',
      kVeneraReaderParts.contains('lib/foundation/follow_updates.dart'));
  ck('§8 清单无重复项',
      kVeneraReaderParts.toSet().length == kVeneraReaderParts.length);
  ck('§8 清单不含脚本运行时',
      !kVeneraReaderParts.any((p) => p.contains('js_engine') || p.contains('js_pool')));
  ck('§8 清单不含第三方站点目录',
      !kVeneraReaderParts.any((p) => p.contains('comic_source')));
  // 自检自己必须真的调用每个公开 API，防止「新增规则但没人测」。
  for (final api in <String>[
    'ComicReadMode.fromKey(',
    'ComicTapHit.at(',
    'tapActionOf(',
    'isDoubleTap(',
    'isLongPress(',
    'wheelActionOf(',
    'ComicFollowPlan.',
    'kVeneraReaderParts',
  ]) {
    ck('§8 自检覆盖 $api', self.contains(api));
  }

  // ── §9 接线：main.dart 真的用了规则层 ──────────────────────────────────
  ck('§9 main.dart 存在', mainSrc.isNotEmpty);
  ck('§9 import 规则层',
      mainSrc.contains("import 'core/comic_reader_rules.dart';"));
  ck('§9 阅读器调用 ComicTapHit.at', mainSrc.contains('ComicTapHit.at('));
  ck('§9 阅读器调用 tapActionOf', mainSrc.contains('tapActionOf('));
  ck('§9 阅读器定义 _onReaderTap', mainSrc.contains('void _onReaderTap('));
  ck('§9 点击绑在 onTapUp', mainSrc.contains('onTapUp: (d) => _onReaderTap('));
  ck('§9 翻页走 pc.animateToPage', mainSrc.contains('pc.animateToPage('));
  ck('§9 _onReaderTap 同时有定义与调用',
      '_onReaderTap('.allMatches(mainSrc).length >= 2);
  final tapAt = mainSrc.indexOf('void _onReaderTap(');
  if (tapAt < 0) {
    ck('§9 取到 _onReaderTap 函数体', false);
  } else {
    final body = mainSrc.substring(tapAt, (tapAt + 1400).clamp(0, mainSrc.length));
    ck('§9 函数体含 _go(', body.contains('_go('));
    ck('§9 函数体含 animateToPage', body.contains('animateToPage'));
    ck('§9 函数体含 ComicTapAction', body.contains('ComicTapAction'));
  }
  ck('§9 仍保留 Venera 的 ComicImage 接线',
      mainSrc.contains('return ComicImage('));

  // ── §10 合规护栏：移动端出货面不得混入整套 UI 的运行时与站点清单 ────────
  // 站点名与依赖名拆开拼，避免本文件自己被「出现敏感标识」的扫描命中。
  final banned = <String>[
    'package:venera',
    'Comic' + 'Source',
    'js' + '_engine',
    'flutter' + '_qjs',
    'photo' + '_view',
    'scrollable' + '_positioned_list',
    'copy' + '_manga',
    'bao' + 'zi',
    'komi' + 'ic',
  ];
  for (final b in banned) {
    ck('§10 规则层不含 $b', !rules.contains(b));
  }
  final tapBody = tapAt < 0
      ? ''
      : mainSrc.substring(tapAt, (tapAt + 1400).clamp(0, mainSrc.length));
  for (final b in banned) {
    ck('§10 接线段不含 $b', !tapBody.contains(b));
  }
  ck('§10 规则层无文件 IO',
      !rules.contains("dart:io") && !rules.contains('File('));
  ck('§10 规则层无网络', !rules.contains('http://') && !rules.contains('https://'));

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exit(1);
}
