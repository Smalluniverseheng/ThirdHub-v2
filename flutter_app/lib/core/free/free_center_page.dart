// 「开放源」聚合页 —— 完全直连公网站点，**不需要后端在线**。
//
// 为什么要有这个页面而不把源塞进现有五个板块：
//   现有板块的搜索/详情/播放全都挂在 `Api.base`（自家后端）上，后端一断就整片空白。
//   这里是一条独立的、与后端无关的内容通路。按用户的话：「既能用后端，也能脱离后端」。
//
// 页面结构：一个 tab 切板块，一个搜索框，一个列表；点条目按内容类型分派到
// 统一播放器 / 漫画阅读 / 文本阅读。源不可达时在顶部直说，不伪装成"没内容"。
import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../agg/playable.dart';
import '../agg/source_health.dart';
import '../player/media_spec.dart';
import '../player/unified_player.dart';
import 'free_http.dart';
import 'free_models.dart';
import 'free_open.dart';
import 'free_policy.dart';
import 'free_registry.dart';
import 'free_source_manage_page.dart';
import 'free_sources_media.dart';
import 'free_sources_read.dart';

/// 板块 → (中文名, 图标, 对应源)
const List<FreeKind> kFreeTabs = [
  FreeKind.music,
  FreeKind.radio,
  FreeKind.podcast,
  FreeKind.comic,
  FreeKind.video,
  FreeKind.book,
];

String freeKindName(FreeKind k) {
  switch (k) {
    case FreeKind.music:
      return '音乐';
    case FreeKind.radio:
      return '电台';
    case FreeKind.podcast:
      return '播客';
    case FreeKind.comic:
      return '漫画';
    case FreeKind.video:
      return '视频';
    case FreeKind.book:
      return '书';
    default:
      return '开放源';
  }
}

IconData freeKindIcon(FreeKind k) {
  switch (k) {
    case FreeKind.music:
      return Icons.music_note_outlined;
    case FreeKind.radio:
      return Icons.radio_outlined;
    case FreeKind.podcast:
      return Icons.podcasts_outlined;
    case FreeKind.comic:
      return Icons.auto_stories_outlined;
    case FreeKind.video:
      return Icons.play_circle_outline;
    case FreeKind.book:
      return Icons.menu_book_outlined;
    default:
      return Icons.public;
  }
}

/// 板块对应的源列表 —— **已按当前运行形态过滤过**。
///
/// 搜索与探活都走这里：移动端构建里根本拿不到需要自担责任的源，
/// 所以「移动端全合规」不是一句文案，而是这条函数返回值的属性。
///
/// ★ 4.81.86 起清单不再只有内置源：管理员同步的、用户导入的也在里面。
///   具体从哪来由 [FreeRegistry] 管，这里只是转发（保持旧调用点不动）。
List<FreeSource> sourcesOf(FreeKind k) => FreeRegistry.sourcesOf(k);

/// 未过滤的完整清单。只在「合规说明」页与桌面端调试时用。
///
/// ★ 禁止在业务代码里直接调它 —— 那等于绕过闸门。自检脚本会盯这一条。
List<FreeSource> allSourcesOf(FreeKind k) => FreeRegistry.allOf(k);

class FreeSourcePage extends StatefulWidget {
  const FreeSourcePage({
    super.key,
    this.initialKind = FreeKind.music,
    this.initialQuery = '',
  });

  final FreeKind initialKind;

  /// 从别的板块「未连接」空态带过来的搜索词：进去即自动搜，不用再输一遍。
  final String initialQuery;

  @override
  State<FreeSourcePage> createState() => _FreeSourcePageState();
}

class _FreeSourcePageState extends State<FreeSourcePage> {
  late FreeKind _kind = widget.initialKind;
  final TextEditingController _q = TextEditingController();

  bool _loading = false;
  String _err = '';
  List<FreeItem> _items = const [];

  /// 外部源（导入/同步）本次的失败原因。UI 折叠显示，不挡内容。
  List<String> _extErrors = const [];

  /// 古登堡的字母桶。
  String _bucket = 'A–M';

  /// 今日诗词（书板块顶部）。
  Map<String, String> _poem = const {};

  int _req = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) _q.text = widget.initialQuery;
    _boot();
    if (_kind == FreeKind.book) _loadPoem();
  }

  /// 先把「外部源」缓存预热，再取数。
  ///
  /// ★ 预热是必要的：导入源存在 SharedPreferences 里，读盘是异步的，
  ///   而 `sourcesOf()` 是同步的（几十个调用点靠它渲染）。
  ///   不预热的话第一次进页面会「只看到内置源」，用户会以为导入失败。
  Future<void> _boot() async {
    try {
      await FreeRegistry.ensureLoaded();
      // 管理员同账号的多台设备，靠这一句拿到同一份源清单。
      // 不是管理员 / 没连后端 / 12 小时内同步过 → 直接返回 0，不发请求。
      final added = await FreeRegistry.autoSyncIfNeeded();
      if (added > 0 && mounted) _toast(trf('已同步 {n} 个源', {'n': added}));
    } catch (_) {
      // 读缓存或同步失败就当没有外部源，内置源照常用。
    }
    if (!mounted) return;
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /// 强制重检。
  ///
  /// ★4.81.88：这里不再"探一遍然后画横幅"。探活的结论现在直接变成行为
  ///   ——`core/agg/source_health.dart` 记录每个源的成败，连续失败的源
  ///   进入冷却期，搜索时直接跳过。所以「重检」只做一件事：把账单清空，
  ///   让下一次取数重新试一遍所有源。用户点它，就是想要这个。
  Future<void> _probe() async {
    await SourceHealth.reset();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadPoem() async {
    try {
      final p = await PoemSource.one();
      if (mounted) setState(() => _poem = p);
    } catch (_) {
      // 诗词是锦上添花，失败了不打扰用户。
    }
  }

  Future<void> _load() async {
    final gen = ++_req;
    setState(() {
      _loading = true;
      _err = '';
      _items = const [];
    });
    try {
      final list = await _fetch();
      if (!mounted || gen != _req) return;
      setState(() {
        _items = list;
        _loading = false;
      });
      // ★4.81.90 后台探活：死链标「已失效」，每条出结果刷一次列表徽标。
      unawaited(Playable.sweep(list, onUpdate: () {
        if (mounted) setState(() {});
      }));
    } on FreeNetException catch (e) {
      if (!mounted || gen != _req) return;
      // ★4.81.88：原来这里把「该板块第一个源」标记为不可达 —— 但失败可能
      //   来自任何一个源，甚至来自导入源。无差别记账会让一个正常的源被
      //   冤枉。现在每个源自己记账（FreeRegistry.searchDynamic 里逐源记），
      //   这里只负责把原因显示出来。
      setState(() {
        _loading = false;
        _err = e.message;
      });
    } catch (e) {
      if (!mounted || gen != _req) return;
      setState(() {
        _loading = false;
        _err = '加载失败：$e';
      });
    }
  }

  /// 取数：内置源 + 已同步/已导入源，合并去重。
  ///
  /// ★4.81.87：具体逻辑已下沉到 [FreeRegistry.searchAll] —— 漫画/音乐/影视
  ///   三个板块在没连引擎也没连后端时也要用同一套源，不能只服务这一个页面。
  ///   这里只保留「把失败原因带给 UI」这一层页面职责。
  Future<List<FreeItem>> _fetch() async {
    final ext = await FreeRegistry.searchAll(
      _kind,
      _q.text.trim(),
      bookBucket: _bucket,
    );
    _extErrors = ext.errors;
    return ext.items;
  }

  void _switchKind(FreeKind k) {
    if (k == _kind) return;
    setState(() {
      _kind = k;
      _items = const [];
      _err = '';
    });
    _load();
    if (k == FreeKind.book && _poem.isEmpty) _loadPoem();
  }

  // ── 点击分派 ──────────────────────────────────────────────
  /// 打开一条结果 —— 分派逻辑在 [FreeOpen]，与板块页共用同一份，
  /// 保证同一部漫画从「开放源」和从「漫画板块」点进去表现一致。
  Future<void> _open(FreeItem it) => FreeOpen.open(context, it);

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── UI ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('开放源')),
        actions: [
          IconButton(
            tooltip: tr('重新探测'),
            icon: const Icon(Icons.wifi_tethering),
            onPressed: () async {
              await _probe();
              if (mounted) setState(() {});
              _load();
            },
          ),
          IconButton(
            tooltip: tr('我的源'),
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const FreeSourceManagePage(),
              ));
              // 回来后清单可能变了（导入/删除/开关），要重新取数。
              await FreeRegistry.ensureLoaded();
              if (!mounted) return;
              setState(() {});
              _probe();
              _load();
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final k in kFreeTabs)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          selected: _kind == k,
                          avatar: Icon(freeKindIcon(k), size: 16),
                          label: Text(tr(freeKindName(k))),
                          onSelected: (_) => _switchKind(k),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _q,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('搜索（留空看推荐）'),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _q.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _q.clear();
                              _load();
                            },
                          ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // ★4.81.88：删掉「{n} 当前不可达」横幅。
          //   那句话把四个源名堆成一行，看起来像"这里全废了"；而下面明明
          //   有诗词和古登堡的内容 —— 判定和取数脱钩，判定只用来吓人。
          //   现在坏源由 core/agg/source_health.dart 静默淘汰（冷却期不再
          //   发请求），界面只在**真的一条都没有**时说一句人话。
          _offlineNote(),
          _sourceStrip(),
          if (_extErrors.isNotEmpty && _items.isEmpty) _extErrorNote(),
          if (_kind == FreeKind.book && _items.isNotEmpty && _poem.isNotEmpty)
            _poemCard(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _offlineNote() => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Text(
          tr('这些源直连公网站点，不需要你的服务器在线'),
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      );

  /// 导入源本次的失败原因。
  ///
  /// 为什么单独一条而不是并进 `_err`：内置源正常、只有一两个导入源挂了时，
  /// 整页不该显示成「加载失败」—— 用户导入的源参差是常态，
  /// 遮住能用的内容比不显示错误更糟。
  Widget _extErrorNote() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 6),
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(
          trf('{n} 个导入源本次没取到内容', {'n': _extErrors.length}),
          style: TextStyle(fontSize: 11, color: cs.tertiary),
        ),
        children: [
          for (final e in _extErrors)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(e,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  // ── 来源与授权 ───────────────────────────────────────────
  // 为什么要有这一条：开放源的内容来自第三方站点，用户有权知道
  // 「这是谁的、按什么条款授权、能不能商用」。上架审核也认这一项。
  Widget _sourceStrip() {
    final shown = sourcesOf(_kind);
    final hidden = FreePolicy.desktopOnly(allSourcesOf(_kind));
    if (shown.isEmpty && hidden.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        children: [
          for (final s in shown)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: Icon(Icons.verified_outlined,
                    size: 14, color: Colors.green.shade600),
                label: Text('${s.name} · ${tr(s.license.i18nKey)}',
                    style: const TextStyle(fontSize: 11)),
                onPressed: () => _showSourceSheet(s),
              ),
            ),
          if (hidden.isNotEmpty)
            ActionChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              avatar: const Icon(Icons.desktop_windows_outlined, size: 14),
              label: Text(
                  trf('{n} 个来源需桌面端', {'n': hidden.length}),
                  style: const TextStyle(fontSize: 11)),
              onPressed: () => _showDesktopOnlySheet(hidden),
            ),
        ],
      ),
    );
  }

  /// 单个来源的授权详情。信息全部来自源代码里的常量，不是运行时猜的。
  void _showSourceSheet(FreeSource s) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (bc) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(freeKindIcon(s.kind), size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(s.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: 10),
              Text(s.note, style: const TextStyle(fontSize: 13, height: 1.5)),
              const SizedBox(height: 12),
              _kv(tr('授权性质'), tr(s.license.i18nKey)),
              if (s.attribution.isNotEmpty) _kv(tr('内容出处'), s.attribution),
              if (s.termsUrl.isNotEmpty)
                _kv(tr('使用条款'), s.termsUrl, selectable: true),
              const SizedBox(height: 10),
              Text(
                tr(s.license.mobileSafe
                    ? '该来源可在移动端直接使用'
                    : '该来源仅桌面端可用'),
                style: TextStyle(
                    fontSize: 11,
                    color: s.license.mobileSafe
                        ? Colors.green.shade700
                        : Colors.orange.shade800),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「我这儿为什么看不到这几个源」—— 明说，不静默消失。
  void _showDesktopOnlySheet(List<FreeSource> hidden) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (bc) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.desktop_windows_outlined, size: 18),
                const SizedBox(width: 8),
                Text(tr('此来源需桌面端'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 10),
              for (final s in hidden)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    trf(FreePolicy.blockReasonTpl,
                        {'n': s.name, 'l': tr(s.license.i18nKey)}),
                    style: const TextStyle(fontSize: 12.5, height: 1.5),
                  ),
                ),
              const Divider(height: 20),
              Text(
                tr('桌面端才能运行这类来源；成品转成标准格式后交接到本机。'),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 12),
              // 4.81.86：移动端不再只有「不行」一个答案。
              // 用户自己写的源、自己承担授权责任，是他自己的选择 ——
              // 但要让他在知道后果的前提下自己开口。
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(tr('去「我的源」里自行决定')),
                  onPressed: () async {
                    Navigator.pop(bc);
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const FreeSourceManagePage(),
                    ));
                    await FreeRegistry.ensureLoaded();
                    if (!mounted) return;
                    setState(() {});
                    _probe();
                    _load();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v, {bool selectable = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 68,
                child: Text(k,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600))),
            Expanded(
              child: selectable
                  ? SelectableText(v,
                      style: const TextStyle(fontSize: 12, height: 1.4))
                  : Text(v,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
            ),
          ],
        ),
      );

  /// 「菩萨蛮 · 温庭筠」这种来源行，两段都可能为空。
  String _poemLine() =>
      [_poem['origin'] ?? '', _poem['author'] ?? '']
          .where((s) => s.isNotEmpty)
          .join(' · ');

  /// 是否需要显示字母桶切换条（只有古登堡的「浏览」状态需要）。
  int _showBucketBar() =>
      (_kind == FreeKind.book && _q.text.trim().isEmpty) ? 1 : 0;

  Widget _poemCard() => Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.02),
          ]),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_poem['content'] ?? '',
                style: const TextStyle(fontSize: 15, height: 1.5)),
            const SizedBox(height: 4),
            Text(
              _poemLine(),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      );

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_err.isNotEmpty && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_err, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: Text(tr('重试'))),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text(tr('没有结果')));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        // 字母桶只对「古登堡浏览」有意义；维基文库是搜索结果，不该出现切换条。
        itemCount: _items.length + _showBucketBar(),
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (c, i) {
          if (i == _items.length) {
            return _bucketSwitch();
          }
          return _tile(_items[i]);
        },
      ),
    );
  }

  /// 古登堡只有两个索引页，用一个切换条把 N–Z 也放出来。
  Widget _bucketSwitch() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final b in GutenbergAuSource.buckets.keys)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: OutlinedButton(
                  onPressed: _bucket == b
                      ? null
                      : () {
                          setState(() => _bucket = b);
                          _load();
                        },
                  child: Text(b),
                ),
              ),
          ],
        ),
      );

  Widget _tile(FreeItem it) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(it),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(it),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(it.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    if (it.displaySubtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(it.displaySubtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ],
                ),
              ),
              Icon(
                it.kind == FreeKind.comic || it.kind == FreeKind.book
                    ? (it.drill ? Icons.chevron_right : Icons.menu_book)
                    : Icons.play_arrow,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(FreeItem it) {
    final w = it.kind == FreeKind.comic ? 52.0 : 48.0;
    final h = it.kind == FreeKind.comic ? 70.0 : 48.0;
    final r = BorderRadius.circular(it.kind == FreeKind.comic ? 6 : 24);
    if (it.cover.isEmpty) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: r,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Icon(freeKindIcon(it.kind), size: 20, color: Colors.grey),
      );
    }
    return ClipRRect(
      borderRadius: r,
      child: Image.network(
        it.cover,
        width: w,
        height: h,
        fit: BoxFit.cover,
        headers: const {'User-Agent': FreeHttp.userAgent},
        errorBuilder: (_, __, ___) => Container(
          width: w,
          height: h,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(freeKindIcon(it.kind), size: 18, color: Colors.grey),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 播客单集
// ─────────────────────────────────────────────────────────────
class FreeEpisodePage extends StatefulWidget {
  const FreeEpisodePage({required this.show});
  final FreeItem show;

  @override
  State<FreeEpisodePage> createState() => FreeEpisodePageState();
}

class FreeEpisodePageState extends State<FreeEpisodePage> {
  bool _loading = true;
  String _err = '';
  List<FreeItem> _list = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final l = await PodcastSource.episodes(widget.show);
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.show.displayTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(child: Text(_err))
              : ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final e = _list[i];
                    return ListTile(
                      dense: true,
                      title: Text(e.displayTitle, maxLines: 2),
                      subtitle: Text(e.displaySubtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.play_circle_outline),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => UnifiedPlayerPage(
                              spec: MediaSpec(
                                url: e.playUrl,
                                title: e.displayTitle,
                                cover: e.cover.isEmpty ? null : e.cover,
                                kindOverride: MediaKind.audio,
                                sourceTag: '播客',
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 漫画章节
// ─────────────────────────────────────────────────────────────
class FreeChapterListPage extends StatefulWidget {
  const FreeChapterListPage({required this.manga});
  final FreeItem manga;

  @override
  State<FreeChapterListPage> createState() => FreeChapterListPageState();
}

class FreeChapterListPageState extends State<FreeChapterListPage> {
  bool _loading = true;
  String _err = '';
  List<FreeItem> _list = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final l = await MangaDexSource.chapters(widget.manga);
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.manga.displayTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(child: Text(_err))
              : _list.isEmpty
                  ? Center(child: Text(tr('这本还没有可看的章节')))
                  : ListView.builder(
                      itemCount: _list.length,
                      itemBuilder: (c, i) {
                        final ch = _list[i];
                        return ListTile(
                          dense: true,
                          title: Text(ch.displayTitle),
                          subtitle: Text(ch.displaySubtitle),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => FreeComicReadPage(chapter: ch),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 漫画阅读（纵向滚动 + 双指缩放）
// ─────────────────────────────────────────────────────────────
class FreeComicReadPage extends StatefulWidget {
  const FreeComicReadPage({super.key, required this.chapter});
  final FreeItem chapter;

  @override
  State<FreeComicReadPage> createState() => _FreeComicReadPageState();
}

class _FreeComicReadPageState extends State<FreeComicReadPage> {
  bool _loading = true;
  String _err = '';
  List<String> _pages = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final p = await MangaDexSource.pages(widget.chapter.id);
      if (!mounted) return;
      setState(() {
        _pages = p;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chapter.displayTitle,
            style: const TextStyle(fontSize: 15)),
        actions: [
          if (_pages.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(trf('{n} 页', {'n': _pages.length}),
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_err, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                            onPressed: _run, child: Text(tr('重试'))),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _pages.length,
                  itemBuilder: (c, i) {
                    return InteractiveViewer(
                      maxScale: 4,
                      child: Image.network(
                        _pages[i],
                        fit: BoxFit.fitWidth,
                        width: double.infinity,
                        headers: const {'User-Agent': FreeHttp.userAgent},
                        loadingBuilder: (c2, child, prog) {
                          if (prog == null) return child;
                          return SizedBox(
                            height: 240,
                            child: Center(
                              child: CircularProgressIndicator(
                                value: prog.expectedTotalBytes == null
                                    ? null
                                    : prog.cumulativeBytesLoaded /
                                        prog.expectedTotalBytes!,
                              ),
                            ),
                          );
                        },
                        errorBuilder: (_, __, ___) => Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(trf('第 {n} 页加载失败', {'n': i + 1}),
                              style: const TextStyle(color: Colors.grey)),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 书籍目录
// ─────────────────────────────────────────────────────────────
class FreeBookTocPage extends StatefulWidget {
  const FreeBookTocPage({required this.book});
  final FreeItem book;

  @override
  State<FreeBookTocPage> createState() => FreeBookTocPageState();
}

class FreeBookTocPageState extends State<FreeBookTocPage> {
  bool _loading = true;
  String _err = '';
  List<FreeItem> _list = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final l = await WikisourceSource.toc('${widget.book.raw['pageTitle'] ?? widget.book.id}');
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.book.displayTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(child: Text(_err))
              : ListView.builder(
                  itemCount: _list.length,
                  itemBuilder: (c, i) {
                    final ch = _list[i];
                    return ListTile(
                      dense: true,
                      title: Text(ch.displayTitle),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FreeTextReadPage(
                            title: ch.displayTitle,
                            loader: () => WikisourceSource.read(
                                '${ch.raw['pageTitle'] ?? ch.id}'),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 文本阅读（公版书正文；可调字号、护眼底色）
// ─────────────────────────────────────────────────────────────
class FreeTextReadPage extends StatefulWidget {
  const FreeTextReadPage({
    super.key,
    required this.title,
    required this.loader,
  });

  final String title;
  final Future<String> Function() loader;

  @override
  State<FreeTextReadPage> createState() => _FreeTextReadPageState();
}

class _FreeTextReadPageState extends State<FreeTextReadPage> {
  bool _loading = true;
  String _err = '';
  String _text = '';
  double _size = 17;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final t = await widget.loader();
      if (!mounted) return;
      setState(() {
        _text = t;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: const Icon(Icons.text_decrease),
            onPressed: _size <= 13
                ? null
                : () => setState(() => _size -= 1),
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            onPressed: _size >= 28
                ? null
                : () => setState(() => _size += 1),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_err, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                            onPressed: _run, child: Text(tr('重试'))),
                      ],
                    ),
                  ),
                )
              : Scrollbar(
                  // ★4.81.88 排版：整篇一个 SelectableText 的渲染是
                  //   "所有段落糊成一堵墙"。按段落拆开、给中文习惯的首行
                  //   缩进，再用 ListView 让整本书不会一次性渲染到卡死。
                  //   用 SelectionArea 包住，跨段选择复制仍然可用。
                  child: SelectionArea(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 48),
                      itemCount: _paras.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 7),
                      itemBuilder: (c, i) {
                        final p = _paras[i];
                        // 首行缩进两格（中文排版惯例）；段首本来就有
                        // 缩进的不重复加。
                        final indented = p.startsWith('\u3000') ||
                                p.startsWith('  ')
                            ? p
                            : '\u3000\u3000$p';
                        return Text(
                          indented,
                          textAlign: TextAlign.justify,
                          style: TextStyle(fontSize: _size, height: 1.85),
                        );
                      },
                    ),
                  ),
                ),
    );
  }

  /// 段落切分：双空行是分段首选；原文用单换行分段时退化到逐行。
  ///
  /// 为什么放在渲染层切而不在 TextClean 里切死：
  /// 不同来源的分段习惯不一样（古登堡是 `\n\n`，维基 HTML 剥完是 `\n`），
  /// 读进来的原文要保持"复制出来还是原文"，排版是展示的事。
  List<String> get _paras {
    var parts = _text.split(RegExp(r'\n\s*\n+'));
    if (parts.length <= 1) parts = _text.split('\n');
    return [
      for (final p in parts)
        if (p.trim().isNotEmpty) p.trim()
    ];
  }
}

// ══════════════════════════════════════════════════════════════
// 导入源的通用下钻页
// ══════════════════════════════════════════════════════════════
//
// 内置源各自有专属的下钻页（漫画章节、书籍目录、播客单集），
// 因为它们的结构差异大。导入源没有专属实现，只有一组声明式的
// `detail` 动作 —— 所以这里只需要一个「拿到子项列表 → 点开能播」的通用页。
//
// 刻意不做的事：
//   · 不猜「这一项是章节还是单集」—— 声明式源自己用 kind 声明板块，照办即可；
//   · 不在子项上再下钻（源包最多两层），避免用户写出一条无限递归的源把 App 拖死。
class FreeDrillPage extends StatefulWidget {
  const FreeDrillPage({required this.parent});

  final FreeItem parent;

  @override
  State<FreeDrillPage> createState() => FreeDrillPageState();
}

class FreeDrillPageState extends State<FreeDrillPage> {
  bool _loading = true;
  String _err = '';
  List<FreeItem> _list = const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final l = await FreeRegistry.drill(widget.parent);
      if (!mounted) return;
      setState(() {
        _list = l;
        _loading = false;
      });
    } on FreeNetException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '加载失败：$e';
        _loading = false;
      });
    }
  }

  void _play(FreeItem e) {
    if (e.playUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('这一条没有可播地址'))));
      return;
    }
    final video = e.kind == FreeKind.video;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => UnifiedPlayerPage(
        spec: MediaSpec(
          url: e.playUrl,
          title: e.displayTitle,
          cover: e.cover.isEmpty ? null : e.cover,
          artist: e.subtitle.isEmpty ? null : e.subtitle,
          kindOverride: video ? MediaKind.video : MediaKind.audio,
          sourceTag: widget.parent.title,
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.parent.displayTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_err, textAlign: TextAlign.center),
                  ),
                )
              : _list.isEmpty
                  ? Center(child: Text(tr('这个源没有返回更多内容')))
                  : ListView.separated(
                      padding: const EdgeInsets.all(8),
                      itemCount: _list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final e = _list[i];
                        return ListTile(
                          dense: true,
                          leading: e.cover.isEmpty
                              ? const Icon(Icons.play_circle_outline)
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.network(
                                    e.cover,
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.play_circle_outline),
                                  ),
                                ),
                          title: Text(e.displayTitle, maxLines: 2),
                          subtitle: Text(e.displaySubtitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.play_arrow),
                          onTap: () => _play(e),
                        );
                      },
                    ),
    );
  }
}
