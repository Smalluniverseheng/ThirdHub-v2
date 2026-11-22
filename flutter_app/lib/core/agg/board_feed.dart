// 板块聚合层 —— 「分类」到底意味着什么。
//
// ── 这一层要解决的那个错 ───────────────────────────────────────────────
//   4.81.87 及之前，漫画 / 音乐 / 影视的搜索是一个三选一的分支：
//
//     if (引擎在线)         → 只问引擎
//     else if (后端有地址)  → 只问后端
//     else                 → 才去问包里那 31 个开放源
//
//   后果是：**只要后端在线，本机那些源一次都不会被调用**。用户在家里
//   连着 NAS，点漫画搜「火影」→ 后端没有漫画源 → 空白；而 MangaDex
//   就在安装包里，一个请求都没发出去。用户的原话是「点进去一看没一个
//   能用的」——不是源不能用，是压根没被用上。
//
//   正确的模型是**聚合**：三条通路并发，谁有内容就出谁，结果并集去重。
//   用户看到的只是「漫画」这个分类，不需要知道内容来自哪条通路。
//   这也正是用户从一开始说的：「我本来那些模块就是让你对应对应的内容」。
//
// ── 三条通路各管什么 ────────────────────────────────────────────────
//   · 资料库（后端）：家里 NAS 上的私有库。有完整元数据、可离线、可续播。
//   · 引擎（THP）：局域网里跑的抓取引擎，覆盖国内站点。
//   · 开放源（本机直连）：编译进包的公开站点接口。**不依赖任何服务器**，
//     手机有网就能出内容 —— 这是「后端只是保底，不是前提」的最后一段。
//
//   三者**互不阻塞**：任一条挂了只是少一份结果，不影响其它两条。
//   全部失败才算"真的没有"。
import 'dart:async';

import 'package:flutter/material.dart';

import '../free/free_board.dart';
import '../free/free_models.dart';
import '../free/free_open.dart';
import '../free/free_registry.dart';
import '../engine_direct.dart';
import '../i18n.dart';
import '../ui_cover.dart';
import 'source_health.dart';
import '../../main.dart' show Api;

/// 四个能"聚合"的板块。
///
/// 用枚举而不是字符串：调用点写错 `'commic'` 时编译期就红，
/// 而字符串会在运行时静默变成"这个板块永远没内容"。
enum BoardKind { novel, comic, video, music }

extension BoardKindX on BoardKind {
  /// 中文板块名（同时是引擎的 type 参数）。
  String get label => switch (this) {
        BoardKind.novel => '小说',
        BoardKind.comic => '漫画',
        BoardKind.video => '视频',
        BoardKind.music => '音乐',
      };

  /// 后端搜索路径。`q` 由调用方追加并编码。
  String get apiPath => '/v1/${name}/search?q=';

  /// 对应的开放源类型。
  ///
  /// 小说走 [FreeKind.book]：公版书（古登堡 / 维基文库 / 今日诗词）是
  /// 本机直连里唯一能"读整本"的东西，正好当小说的兜底。
  FreeKind get freeKind => switch (this) {
        BoardKind.novel => FreeKind.book,
        BoardKind.comic => FreeKind.comic,
        BoardKind.video => FreeKind.video,
        BoardKind.music => FreeKind.music,
      };
}

/// 一次聚合的结果。
///
/// [groups] 刻意保持**旧的 Map 形状**（`{ok, engine, sourceId, items}`），
/// 这样现有三个板块的渲染代码不需要重写 —— 只是换了数据来源。
class BoardFeedResult {
  final List<Map> groups;

  /// 各通路贡献条数（给空态文案与体检面板用）。
  final int fromBackend;
  final int fromEngine;
  final int fromLocal;

  /// 逐通路失败原因。**只给诊断用，不直接铺到界面上。**
  final List<String> errors;

  const BoardFeedResult(
    this.groups, {
    this.fromBackend = 0,
    this.fromEngine = 0,
    this.fromLocal = 0,
    this.errors = const [],
  });

  int get total => fromBackend + fromEngine + fromLocal;
  bool get isEmpty => total == 0;

  /// 至少有一条通路答复过（哪怕是空结果）。
  ///
  /// 与 [isEmpty] 的区别：「搜了但没有」和「根本没搜成」是两种语境，
  /// 空态文案要说不同的话。前者说"换个词试试"，后者说"网络不通"。
  bool get anyAnswered => errors.isEmpty;
}

class BoardFeed {
  BoardFeed._();

  /// 后端超时。内网 NAS 如果 8 秒还没回，基本就是没开或地址不对。
  static const Duration _backendTimeout = Duration(seconds: 8);

  /// 引擎与公网站点的超时。境外源慢是常态，但不能无限等。
  static const Duration _remoteTimeout = Duration(seconds: 20);

  /// 聚合搜索。[q] 为空表示"给我看看有什么"（推荐流）。
  ///
  /// 三条通路**同时发**，不做"前一条失败才试下一条"的串行兜底 ——
  /// 串行时后端一超时，本机源就要多等 8 秒才开始。用户等不起。
  static Future<BoardFeedResult> search(BoardKind b, String q) async {
    final groups = <Map>[];
    final errors = <String>[];
    var nBackend = 0, nEngine = 0, nLocal = 0;

    Future<void> backendJob() async {
      if (Api.base.trim().isEmpty) return;
      final sw = Stopwatch()..start();
      final key = 'backend:${b.name}';
      try {
        final r = await Api.get('${b.apiPath}${Uri.encodeComponent(q)}')
            .timeout(_backendTimeout);
        final list = List<Map>.from((r['data'] as List?) ?? const []);
        if (list.isNotEmpty) {
          groups.addAll(list);
          nBackend += list.length;
        }
        SourceHealth.reportOk(key, ms: sw.elapsedMilliseconds, count: list.length);
      } catch (e) {
        // 后端挂了是「少一路」，不是「错」。软失败：不冷却、不吓用户。
        SourceHealth.reportFail(key, '$e', soft: true);
        // 诊断串走 ASCII，不进 UI：品牌闸门禁止在用户可见文案里出现
        // 内部实现名，而这些串只在体检面板里给开发者看。
        errors.add('library: $e');
      }
    }

    Future<void> engineJob() async {
      if (!EngineDirect.connected) return;
      final sw = Stopwatch()..start();
      final key = 'engine:${b.name}';
      try {
        final items =
            await EngineDirect.search(b.name, q).timeout(_remoteTimeout);
        if (items.isNotEmpty) {
          groups.add({'ok': true, 'engine': true, 'items': items});
          nEngine += items.length;
        }
        SourceHealth.reportOk(key, ms: sw.elapsedMilliseconds, count: items.length);
      } catch (e) {
        SourceHealth.reportFail(key, '$e', soft: true);
        errors.add('engine: $e');
      }
    }

    Future<void> localJob() async {
      try {
        final r = await FreeRegistry.searchAll(b.freeKind, q)
            .timeout(_remoteTimeout);
        if (r.items.isNotEmpty) {
          groups.add(FreeBoard.group(r.items));
          nLocal += r.items.length;
        }
        errors.addAll(r.errors);
      } catch (e) {
        errors.add('free: $e');
      }
    }

    await Future.wait([backendJob(), engineJob(), localJob()]);

    return BoardFeedResult(
      groups,
      fromBackend: nBackend,
      fromEngine: nEngine,
      fromLocal: nLocal,
      errors: errors,
    );
  }

  /// 推荐流（无关键词）。板块首屏用这个，不是"先让你连服务器"。
  static Future<BoardFeedResult> discover(BoardKind b) => search(b, '');
}

/// 板块「发现」页 —— 不依赖任何服务器时的内容流。
///
/// ★ 为什么不是直接复用 `EngineDiscoverView`：
///   那个视图的骨架是"引擎的书源分类标签 + 分页"，源不在引擎上时它没有
///   任何可展示的东西。这里是「按板块出一批可以直接点开的内容」，
///   数据形状是 [FreeItem]，交互是 [FreeOpen.open]。两者不能混。
class BoardDiscoverView extends StatefulWidget {
  final BoardKind kind;

  /// 打开一条结果。默认走 [FreeOpen.open]；板块需要自定义时（比如视频
  /// 要进统一播放器）可以覆盖。
  final void Function(BuildContext, FreeItem)? onOpen;

  const BoardDiscoverView({super.key, required this.kind, this.onOpen});

  @override
  State<BoardDiscoverView> createState() => _BoardDiscoverViewState();
}

class _BoardDiscoverViewState extends State<BoardDiscoverView> {
  List<FreeItem> _items = const [];
  bool _loading = true;
  String _err = '';
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      final r = await FreeRegistry.searchAll(widget.kind.freeKind, '');
      if (!mounted || seq != _seq) return;
      setState(() {
        _items = r.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _err = '$e';
      });
    }
  }

  void _open(FreeItem it) {
    final f = widget.onOpen;
    if (f != null) {
      f(context, it);
    } else {
      FreeOpen.open(context, it);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _err.isEmpty ? tr('没有结果') : _err,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: OutlinedButton(
                  onPressed: _load, child: Text(tr('重试'))),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          childAspectRatio: 0.66,
          crossAxisSpacing: 10,
          mainAxisSpacing: 14,
        ),
        itemCount: _items.length,
        itemBuilder: (c, i) {
          final it = _items[i];
          return InkWell(
            onTap: () => _open(it),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: it.cover.isEmpty
                        ? Container(
                            color: Colors.grey.withValues(alpha: 0.12),
                            alignment: Alignment.center,
                            child: const Icon(Icons.image_outlined,
                                size: 28, color: Colors.grey),
                          )
                        : CoverThumb(it.cover, fallbackText: it.displayTitle),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  it.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.25),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
