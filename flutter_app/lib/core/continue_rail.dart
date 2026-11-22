// 「继续上次」横滑带 —— 对标 Netflix 的 Continue Watching / B 站首页的「观看历史」位。
//
// ══ 为什么要有 ══
// 搜索页是这个 App 的默认落地页。以前进来看到的只有「一个空输入框 + 一条推荐带」，
// 想接着看上次没看完的那集，只能自己去 视频 → 历史 → 翻列表。这是大厂首页
// 一定会有的一格（Netflix/爱奇艺/B 站/网易云都是如此），而这里一直是空的。
//
// ══ 为什么做成「纯展示 + 回调」 ══
// 打开动作需要判断「这条记录能不能真续播」（本地视频进播放器、需要选目录的
// 有声书只能回模块）。这套判断依赖 main.dart 里的页面与导航，放进组件会把
// 组件和 18000 行的 main.dart 绑死、形成循环 import。所以：
//   数据 → 这里读（Recents）
//   点击 → 交给宿主（onOpen）
// 同一个组件因此能在搜索页、最近播放页复用。
//
// ══ 边界 ══
// · Recents 读失败一律当空，绝不抛到 UI；
// · 没有记录时返回 SizedBox.shrink()，不占位、不留白条；
// · 长按可移除单条（本地偏好数据，不涉及云端）。
import 'package:flutter/material.dart';

import 'i18n.dart';
import 'recents.dart';

/// 一条最近记录在 UI 上的稳定形态。
class RecentEntry {
  final String kind;
  final String title;
  final String sub;
  final String target;
  final String at;

  const RecentEntry({
    required this.kind,
    required this.title,
    required this.sub,
    required this.target,
    required this.at,
  });

  /// 从 Recents 的原始 Map 构造。字段缺失不报错，一律降级成空串。
  static RecentEntry fromMap(Map<String, String> m) => RecentEntry(
        kind: m['kind'] ?? '',
        title: (m['title'] ?? '').trim(),
        sub: (m['sub'] ?? '').trim(),
        target: (m['target'] ?? '').trim(),
        at: (m['at'] ?? '').trim(),
      );

  /// 有没有可以真正打开的目标。空 target 的记录只能回到模块，不能续播。
  bool get hasTarget => target.isNotEmpty;

  IconData get icon {
    switch (kind) {
      case 'music':
        return Icons.music_note;
      case 'video':
        return Icons.play_circle_outline;
      case 'audiobook':
        return Icons.headphones;
      case 'radio':
        return Icons.radio;
      default:
        return Icons.play_arrow;
    }
  }

  /// 板块名（用于「去哪个模块」与卡片角标）。
  String get kindLabel {
    switch (kind) {
      case 'music':
        return tr('音乐');
      case 'video':
        return tr('视频');
      case 'audiobook':
        return tr('有声书');
      case 'radio':
        return tr('广播');
      default:
        return kind;
    }
  }

  /// 卡片右下角那行字：优先显示副标题（艺人/专辑），没有就显示时间。
  String get caption => sub.isNotEmpty ? sub : at;
}

/// 搜索页/最近播放页共用的「继续上次」横滑带。
///
/// [onOpen] 点卡片时调用；[onAll] 是右上角「全部」入口（可不传）。
/// [max] 最多显示几条，默认 8（手机上约两屏半，横滑一眼能看到头）。
class ContinueRail extends StatefulWidget {
  /// 点击回调。返回 Future 是为了「从播放器回来之后刷新顺序」——
  /// 宿主 await 完自己的导航/播放入口，横滑带再重读一次最近记录，
  /// 否则刚看完的那一集还停在原位，看起来像没生效。
  final Future<void> Function(RecentEntry entry) onOpen;
  final VoidCallback? onAll;
  final int max;

  const ContinueRail({
    super.key,
    required this.onOpen,
    this.onAll,
    this.max = 8,
  });

  @override
  State<ContinueRail> createState() => _ContinueRailState();
}

class _ContinueRailState extends State<ContinueRail>
    with WidgetsBindingObserver {
  List<RecentEntry> _items = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从播放器返回前台时刷新 —— 否则用户刚看完一集，回到搜索页还是旧的顺序。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    List<RecentEntry> list;
    try {
      final raw = await Recents.list();
      list = raw
          .map(RecentEntry.fromMap)
          .where((e) => e.title.isNotEmpty)
          .take(widget.max)
          .toList();
    } catch (_) {
      // Recents 内部已经兜过一次，这里再兜一次是为了「横滑带坏了也不能拖垮搜索页」。
      list = const [];
    }
    if (!mounted) return;
    setState(() {
      _items = list;
      _loaded = true;
    });
  }

  Future<void> _remove(RecentEntry e) async {
    await Recents.remove(e.kind, e.target);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
        content: Text(tr('已移除')),
        duration: const Duration(milliseconds: 1200)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // 还没读完 or 确实没记录：都不占位。
    // （加载中直接 return 空，是为了避免「先闪一条空白横条再出现内容」。）
    if (!_loaded || _items.isEmpty) return const SizedBox.shrink();

    // 横屏手机/极矮窗口：搜索页上面已经叠了搜索行、推荐带、两排 chip，
    // 再塞 122dp 的横滑带会把结果区挤没（Column 固定子高之和溢出）。
    // 横屏是"已经在看"的场景，首页位在这里价值最低 —— 直接不画，不硬挤。
    if (MediaQuery.sizeOf(context).height < 520) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
        child: Row(children: [
          Icon(Icons.history, size: 15, color: cs.primary),
          const SizedBox(width: 6),
          Text(tr('继续上次'),
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
          const Spacer(),
          if (widget.onAll != null)
            TextButton(
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                onPressed: widget.onAll,
                child: Text(tr('全部'),
                    style: const TextStyle(fontSize: 12))),
        ]),
      ),
      SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: _items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (c, i) => _card(c, _items[i]),
        ),
      ),
    ]);
  }

  Widget _card(BuildContext c, RecentEntry e) {
    final cs = Theme.of(c).colorScheme;
    return Semantics(
      button: true,
      label: '${tr('继续上次')} ${e.title} ${e.kindLabel}',
      child: GestureDetector(
        onTap: () async {
          await widget.onOpen(e);
          // 从播放器/模块回来后重排：刚点过的那条现在应当在最前。
          await _load();
        },
        onLongPress: () => _remove(e),
        child: Container(
          width: 158,
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(e.icon, size: 13, color: cs.primary),
                const SizedBox(width: 4),
                Text(e.kindLabel,
                    style: TextStyle(
                        fontSize: 10,
                        color: cs.primary,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                // 能真续播的给一个「续」字角标；只能回模块的留空 ——
                // 不假装所有记录都能一键回到那一秒。
                if (e.hasTarget)
                  Icon(Icons.play_arrow_rounded, size: 13, color: cs.primary),
              ]),
              const SizedBox(height: 5),
              Expanded(
                child: Text(e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3)),
              ),
              if (e.caption.isNotEmpty)
                Text(e.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                        height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}
