// B 站独立模块（4.81.67 / 栏目可配置 4.81.79）
//
// 定位：影视模块里的一个完整 B 站客户端。栏目不再是写死的五个 ——
//       推荐 / 热门 / 排行榜 / 分区 / **直播** / **番剧** / 搜索 七个里
//       用户自己勾选、自己拖动排序（偏好存 bili_tabs），默认全开。
//       视频详情里可以逐集播放、逐集下载、一键整季下载，
//       下载走 NAS 上的 bilidown（落盘 /vol1/1000/Media/影视/B站），
//       管理入口在右上角（跳 bili_down_page.dart）。
//
// 为什么不复用 bili_feed_page.dart：那个页面是 4.81.66 的「热门+搜索」最小版，
//       本页是它的完整替代（多栏目 + 分页 + 下载），保留旧页只为不碰坏我的后端入口。
//
// 接口全部走 NAS 主后端 /v1/bili/*（App 不直连 B 站，与 bili_feed_page 同一约定）：
//   GET  /v1/bili/feed?type=popular|recommend&ps=&pn=   热门/推荐
//   GET  /v1/bili/rank?rid=                            排行榜（partitions 取频道表）
//   GET  /v1/bili/region?rid=&ps=&pn=                  分区最新（B 站 newlist）
//   GET  /v1/bili/partitions                           频道常量表
//   GET  /v1/bili/search?q=&pn=                        搜索
//   GET  /v1/bili/pages?bvid=                          分P
//   GET  /v1/bili/playurl?bvid=&cid=&qn=               播放直链（qn 可选清晰度）
//   GET  /v1/bili/parse?url=                           解析（拿可选清晰度）
//   GET  /v1/bili/live?page=&ps=                       直播推荐流（4.81.79 新增）
//   GET  /v1/bili/live/play?room_id=                   直播拉流（4.81.79 新增）
//   GET  /v1/bili/bangumi?before=&after=               番剧时间表（4.81.79 新增）
//   POST /v1/bili/add        {url, format}             单集下载（url 里带 ?p=N）
//   POST /v1/bili/addall     {bvid, format}            整季/全 P 批量下载
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_delegate.dart';
import 'bili_auth.dart' show BiliAuth;
import 'bili_auth_page.dart';
import 'bili_down_page.dart';
import 'bili_player.dart';
import 'bili_swipe_page.dart';
import 'bili_direct.dart';
import 'bili_live_page.dart';
import 'bili_space_page.dart';
import 'bili_later_page.dart' show BiliLaterPage;
import 'ui/app_skeleton.dart';
import 'design_tokens.dart';
import 'i18n.dart';

/// 模块内共享的后端连接（base/token），各栏目 Tab 只读。
class BiliCtx {
  BiliCtx(this.base, this.token);

  final String base;
  final String token;

  Map<String, String> get h =>
      token.isEmpty ? const {} : {'x-th-token': token};
}

class BiliModulePage extends StatefulWidget {
  const BiliModulePage({super.key, this.embedded = false});

  /// true = 被嵌进视频板块的平台横切页：不画自己的 Scaffold/AppBar，
  /// 只交出一行工具按钮 + TabBar + 内容，外层负责标题与平台切换条。
  /// 这样"B 站"就不再是一个要点进去的二级页，而是视频页里可以左右滑到的一栏。
  final bool embedded;

  @override
  State<BiliModulePage> createState() => _BiliModulePageState();
}

/// B 站模块里一个可配置的栏目。
///
/// 为什么做成「可配置」：原来 5 个栏目是写死在 TabBar 里的 —— 不看排行的人
/// 每次都得划过它才够到搜索，新加的直播/番剧更是永远挤不进来。用户说的
/// 「想自由选择都没办法选择」就是这个。现在栏目顺序与显隐都归用户。
class BiliTabDef {
  const BiliTabDef(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;
}

const List<BiliTabDef> kBiliTabDefs = [
  BiliTabDef('recommend', '推荐', Icons.explore_outlined),
  BiliTabDef('popular', '热门', Icons.local_fire_department_outlined),
  BiliTabDef('rank', '排行榜', Icons.leaderboard_outlined),
  BiliTabDef('region', '分区', Icons.grid_view_outlined),
  BiliTabDef('live', '直播', Icons.live_tv_outlined),
  BiliTabDef('bangumi', '番剧', Icons.movie_filter_outlined),
  BiliTabDef('search', '搜索', Icons.search),
];

const List<String> kBiliTabDefault = [
  'recommend',
  'popular',
  'rank',
  'region',
  'live',
  'bangumi',
  'search',
];

BiliTabDef? biliTabDefOf(String id) {
  for (final d in kBiliTabDefs) {
    if (d.id == id) return d;
  }
  return null;
}

/// 让外部直接切栏目（AI 控制总线的 subtab），不用去模拟点 TabBar。
///
/// 为什么必须有个显式钩子：TabBar 的 tab 是**懒加载**的，AI 若靠坐标点，
/// 一旦用户改过栏目顺序/隐藏了某个栏目，坐标就全错 —— 表现是"点了没反应"，
/// 而日志里一切正常。走 id 映射才与顺序无关。
///
/// 只有当前挂载的 B 站页会注册自己；没打开时 [jump] 返回 false，
/// 让调用方知道"得先跳过去"，而不是以为切成功了。
class BiliNav {
  const BiliNav._();
  static bool Function(String tab)? _sink;

  static void attach(bool Function(String tab) f) => _sink = f;

  static void detach(bool Function(String tab) f) {
    // 用 == 而不是 identical：方法 tear-off 在同一实例上是相等的（语言规范保证）
    if (_sink == f) _sink = null;
  }

  static bool get available => _sink != null;

  static bool jump(String tab) => _sink?.call(tab) ?? false;
}

class _BiliModulePageState extends State<BiliModulePage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<String> _tabIds = kBiliTabDefault;
  String _base = '';
  String _token = '';
  bool _ready = false;
  // B站登录态是纯本机的：普通版用户没有 NAS 也能扫码登录。
  bool _biliLogged = false;
  String _biliName = '';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: kBiliTabDefault.length, vsync: this);
    BiliNav.attach(_jumpTab);
    _boot();
  }

  @override
  void dispose() {
    BiliNav.detach(_jumpTab);
    _tab.dispose();
    super.dispose();
  }

  /// AI 控制总线切栏目的落地实现：id / 中文名 / 序号三种写法都认。
  /// 认不出就返回 false —— 不要"猜一个最像的"，猜错的代价是用户看着屏幕发愣。
  bool _jumpTab(String tab) {
    final ids = _tabIds.isEmpty ? kBiliTabDefault : _tabIds;
    if (ids.isEmpty) return false;
    final raw = tab.trim();
    if (raw.isEmpty) return false;
    var i = -1;
    final n = int.tryParse(raw);
    if (n != null && n >= 0 && n < ids.length) i = n;
    if (i < 0) {
      final key = raw.toLowerCase();
      i = ids.indexWhere((id) => id == key);
    }
    if (i < 0) {
      i = ids.indexWhere((id) => (biliTabDefOf(id)?.label ?? '') == raw);
    }
    if (i < 0) {
      i = ids.indexWhere((id) => tr(biliTabDefOf(id)?.label ?? '') == raw);
    }
    if (i < 0) {
      i = ids.indexWhere((id) =>
          (biliTabDefOf(id)?.label ?? '').contains(raw) ||
          raw.contains(biliTabDefOf(id)?.label ?? '###'));
    }
    if (i < 0) return false;
    _tab.animateTo(i);
    return true;
  }

  Future<void> _boot() async {
    // ★4.81.101：以前只在账号中心/播放页才 load，冷启动直接进 B站时
    // cookie 还是空的，收藏夹被判未登录、互动全失效。这里先恢复本机登录态，
    // 与后端是否连接完全无关。
    await BiliAuth.I.load();
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    // 只保留认识的 id，顺序按用户存的来；一个都不剩就回落默认
    final saved = p.getStringList('bili_tabs') ?? const <String>[];
    final ids = saved.where((e) => biliTabDefOf(e) != null).toList();
    final use = ids.isEmpty ? kBiliTabDefault : ids;
    final old = _tab;
    setState(() {
      _base = (p.getString('base') ?? '').trim();
      _token = (p.getString('token') ?? '').trim();
      _biliLogged = BiliAuth.I.loggedIn;
      _biliName = BiliAuth.I.name;
      _tabIds = List<String>.from(use);
      _tab = TabController(length: use.length, vsync: this);
      _ready = true;
    });
    // 旧 controller 等这一帧过去再销毁：它可能刚被 TabBar 引用过
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  /// 应用新的栏目顺序/显隐（会重建 TabController —— 长度变了，旧的不能复用）
  Future<void> _applyTabIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final old = _tab;
    setState(() {
      _tabIds = List<String>.from(ids);
      _tab = TabController(length: ids.length, vsync: this);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    final p = await SharedPreferences.getInstance();
    await p.setStringList('bili_tabs', _tabIds);
  }

  /// 栏目本体。id 与 kBiliTabDefs 对应，未知 id 给个说明页而不是崩。
  Widget _tabBody(String id, BiliCtx ctx) {
    switch (id) {
      case 'recommend':
        return _BiliGridTab(
          ctx: ctx,
          pathBuilder: (pn) => '/v1/bili/feed?type=recommend&ps=20&pn=$pn',
        );
      case 'popular':
        return _BiliGridTab(
          ctx: ctx,
          pathBuilder: (pn) => '/v1/bili/feed?type=popular&ps=20&pn=$pn',
        );
      case 'rank':
        return _BiliChipsTab(
          ctx: ctx,
          chipsPath: '/v1/bili/partitions',
          pathBuilder: (rid, pn) => '/v1/bili/rank?rid=$rid',
          rankBadge: true,
        );
      case 'region':
        return _BiliChipsTab(
          ctx: ctx,
          chipsPath: '/v1/bili/partitions',
          pathBuilder: (rid, pn) => '/v1/bili/region?rid=$rid&ps=20&pn=$pn',
        );
      case 'live':
        return BiliLiveTab(ctx: ctx);
      case 'bangumi':
        return BiliBangumiTab(ctx: ctx);
      case 'search':
        return _BiliSearchTab(ctx: ctx);
      default:
        return Center(child: Text(tr('这个栏目暂不可用')));
    }
  }

  /// 栏目设置：拖动排序 + 开关显隐
  void _openTabSheet() {
    final draft = List<String>.from(_tabIds);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg))),
      builder: (c) => StatefulBuilder(builder: (c, setSheet) {
        // 必须在这里算：外层算的不会随 setSheet 重建而更新，
        // 结果就是「移掉的栏目不会出现在未显示区」。
        final hidden = kBiliTabDefs
            .map((e) => e.id)
            .where((id) => !draft.contains(id))
            .toList();

        void commit(List<String> ids) {
          setSheet(() {
            draft
              ..clear()
              ..addAll(ids);
          });
          unawaited(_applyTabIds(ids));
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                Gap.md, Gap.sm, Gap.md, Gap.md + MediaQuery.of(c).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Text(tr('栏目'),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => commit(List<String>.from(kBiliTabDefault)),
                    child: Text(tr('恢复默认')),
                  ),
                ]),
                Text(
                  tr('拖动可以调顺序，关掉就不显示。至少留一个。'),
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: Theme.of(c).hintColor),
                ),
                const SizedBox(height: Gap.sm),
                // 固定高度：bottom sheet 里 Column 的高度约束是无界的，
                // Flexible + shrinkWrap 会报 "non-zero flex but unbounded height"
                SizedBox(
                  height: 320,
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const ClampingScrollPhysics(),
                    buildDefaultDragHandles: true,
                    itemCount: draft.length,
                    onReorder: (from, to) {
                      final ids = List<String>.from(draft);
                      if (to > from) to -= 1;
                      final moved = ids.removeAt(from);
                      ids.insert(to, moved);
                      commit(ids);
                    },
                    itemBuilder: (c, i) {
                      final d = biliTabDefOf(draft[i])!;
                      return ListTile(
                        key: ValueKey(d.id),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(d.icon, size: 18),
                        title: Text(tr(d.label),
                            style: const TextStyle(fontSize: 13.5)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (draft.length > 1)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: tr('不显示'),
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () {
                                final ids = List<String>.from(draft)
                                  ..remove(d.id);
                                commit(ids);
                              },
                            ),
                          const Icon(Icons.drag_handle, size: 18),
                        ]),
                      );
                    },
                  ),
                ),
                if (hidden.isNotEmpty) ...[
                  const Divider(height: Gap.lg),
                  Text(tr('未显示'),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(c).hintColor)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 6, children: [
                    for (final id in hidden)
                      ActionChip(
                        avatar: Icon(biliTabDefOf(id)!.icon, size: 14),
                        label: Text(tr(biliTabDefOf(id)!.label),
                            style: const TextStyle(fontSize: 11.5)),
                        onPressed: () => commit([...draft, id]),
                      ),
                  ]),
                ],
              ],
            ),
          ),
        );
      }),
    );
  }

  /// 下载到 NAS 才需要后端；普通版的在线播放完全不需要。
  void _openDownload(BuildContext context, BiliCtx ctx) {
    if (ctx.base.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('在线看不用后端'))));
      return;
    }
    openBiliLinkSheet(context, ctx, '');
  }

  /// 常驻的 B站登录状态条：扫码登录完全在本机完成，不需要 NAS。
  /// 放在栏目上方，避免用户把「要登录」误读成「要连接后端」。
  Widget _biliBanner(BuildContext context, ColorScheme cs) {
    if (_biliLogged) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 4),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        child: Row(children: [
          Icon(Icons.verified_user, size: 15, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${tr('B站已登录')}${_biliName.isEmpty ? '' : ' · $_biliName'}',
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: tr('退出登录'),
            icon: const Icon(Icons.logout, size: 15),
            onPressed: () async {
              await AuthDelegate.revokeFromPrefs();
              await BiliAuth.I.logout();
              if (!mounted) return;
              setState(() {
                _biliLogged = false;
                _biliName = '';
              });
            },
          ),
        ]),
      );
    }
    return InkWell(
      onTap: () async {
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BiliAuthPage()));
        if (!mounted) return;
        await BiliAuth.I.load();
        if (!mounted) return;
        setState(() {
          _biliLogged = BiliAuth.I.loggedIn;
          _biliName = BiliAuth.I.name;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
        color: cs.primaryContainer.withValues(alpha: 0.35),
        child: Row(children: [
          Icon(Icons.qr_code_2, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('扫码登录解锁高清与收藏'),
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600)),
                Text(tr('不需要后端，登录态只存本机'),
                    style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: cs.primary),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return _shell(const Center(child: AppLoading()));
    }
    // 没配后端也要能看：biliGet 在无 base 时自动走端上直连，
    // 不能因为「我的后端」没连就把整页挡成一句提示（4.81.100 修正）。
    final ctx = BiliCtx(_base, _token);
    final cs = Theme.of(context).colorScheme;
    // 栏目顺序与显隐来自用户偏好（_tabIds），不再写死 5 个
    final ids = _tabIds.isEmpty ? kBiliTabDefault : _tabIds;
    final tabs = TabBar(
      controller: _tab,
      isScrollable: true,
      tabs: [
        for (final id in ids) Tab(text: tr(biliTabDefOf(id)?.label ?? id)),
      ],
    );
    final view = TabBarView(
      controller: _tab,
      children: [for (final id in ids) _tabBody(id, ctx)],
    );
    if (widget.embedded) {
      return Column(children: [
        _biliBanner(context, cs),
        // 独立页时这几个入口在 AppBar 的 actions 里；嵌进来以后没有 AppBar 了，
        // 但「栏目」「链接下载」「下载管理」不能因此消失 —— 挪成 tab 右侧的小按钮。
        Row(children: [
          Expanded(child: tabs),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: tr('更多'),
            icon: const Icon(Icons.more_vert, size: 20),
            onPressed: () async {
              final box = context.findRenderObject() as RenderBox?;
              final at = box == null
                  ? Offset(MediaQuery.sizeOf(context).width - 12, 90)
                  : box.localToGlobal(Offset(box.size.width - 12, 46));
              final v = await _openMoreMenu(context, at);
              if (v != null && mounted) await _onMore(v, context, ctx);
            },
          ),
        ]),
        Expanded(child: view),
      ]);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('哔哩哔哩')),
        actions: [
          IconButton(
            tooltip: tr('更多'),
            icon: const Icon(Icons.more_vert),
            onPressed: () async {
              final box = context.findRenderObject() as RenderBox?;
              final at = box == null
                  ? Offset(MediaQuery.sizeOf(context).width - 12, 12)
                  : box.localToGlobal(Offset(box.size.width - 12, 56));
              final v = await _openMoreMenu(context, at);
              if (v != null && mounted) await _onMore(v, context, ctx);
            },
          ),
        ],
        bottom: tabs,
      ),
      body: Column(children: [_biliBanner(context, cs), Expanded(child: view)]),
    );
  }

  /// 统一外壳：独立页给 Scaffold，嵌入态直接交 body。
  /// 右上角「更多」菜单（4.81.120）。
  ///
  /// 原来嵌在模块页时把「栏目/收藏/稍后再看/登录/链接下载/下载管理」六个按钮
  /// 全塞在 TabBar 右侧 —— 用户截图里就是一堆图标挤成一团、一个都看不清。
  /// 现在统一收进一个 ⋮，点开才展开，两种形态（嵌入式 / 独立页）口径一致。
  Future<String?> _openMoreMenu(BuildContext c, Offset at) async {
    return showMenu<String>(
      context: c,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(value: 'tabs', child: Text(tr('栏目'))),
        PopupMenuItem(value: 'fav', child: Text(tr('收藏夹'))),
        PopupMenuItem(value: 'later', child: Text(tr('稍后再看'))),
        PopupMenuItem(
            value: 'login',
            child: Text(_biliLogged ? _biliName : tr('B站登录'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'link', child: Text(tr('链接下载'))),
        PopupMenuItem(value: 'down', child: Text(tr('下载管理'))),
      ],
    );
  }

  Future<void> _onMore(String v, BuildContext c, BiliCtx ctx) async {
    switch (v) {
      case 'tabs':
        _openTabSheet();
        break;
      case 'fav':
        await Navigator.of(c)
            .push(MaterialPageRoute(builder: (_) => BiliFavPage(ctx: ctx)));
        break;
      case 'later':
        await Navigator.of(c)
            .push(MaterialPageRoute(builder: (_) => BiliLaterPage(ctx: ctx)));
        break;
      case 'login':
        await Navigator.of(c)
            .push(MaterialPageRoute(builder: (_) => const BiliAuthPage()));
        if (!mounted) return;
        await BiliAuth.I.load();
        if (!mounted) return;
        setState(() {
          _biliLogged = BiliAuth.I.loggedIn;
          _biliName = BiliAuth.I.name;
        });
        break;
      case 'link':
        _openDownload(c, ctx);
        break;
      case 'down':
        await Navigator.of(c)
            .push(MaterialPageRoute(builder: (_) => const BiliDownPage()));
        break;
    }
  }

  Widget _shell(Widget body) => widget.embedded
      ? body
      : Scaffold(appBar: AppBar(title: Text(tr('哔哩哔哩'))), body: body);
}

// ───────────────────────── 通用请求 ─────────────────────────

/// 会话内后端失败计数：普通版误填了后端地址时，不能每次都等 30 秒超时
/// 才回落到直连。连续两次失败就本会话内直接走端上，换地址后自动重试。
String _lastBackend = '';
int _backendFails = 0;

/// 通用 GET：**先走后端，后端不可达（或明确失败）就直连 B 站**。
/// 这样 NAS 关机/断网时，浏览、搜索、详情、评论、弹幕全都还能用（下载除外）。
Future<Map<String, dynamic>?> biliGet(BiliCtx ctx, String path,
    {int sec = 30}) async {
  if (ctx.base != _lastBackend) {
    _lastBackend = ctx.base;
    _backendFails = 0;
  }
  if (ctx.base.isNotEmpty && _backendFails < 2) {
    try {
      final r = await http
          .get(Uri.parse('${ctx.base}$path'), headers: ctx.h)
          .timeout(Duration(seconds: sec));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) {
        final m = Map<String, dynamic>.from(j);
        if (m['ok'] == true) {
          _backendFails = 0;
          return m;
        }
      }
      _backendFails++;
    } catch (_) {
      _backendFails++;
    }
  }
  return biliDirect(path);
}

/// 播放地址**双通道竞速**（4.81.97）。
///
/// 为什么不是「先后端、失败再直连」：那条路最坏要等后端超时（12~30 秒）才切，
/// 用户感知就是「点了半天不出画面」。本质上前端要的只是一个能播的 URL，
/// 谁先给出来就用谁 —— 家里那台要转码/取流，慢；直连 B站 CDN，快；
/// 但直连被风控时只有家里那台能用。两边同时问，谁先到用谁。
Future<Map<String, dynamic>?> biliPlayRace(BiliCtx ctx, String path) async {
  final attempts = <Future<Map<String, dynamic>?>>[];

  Future<Map<String, dynamic>?> soft(Future<Map<String, dynamic>?> f) async {
    try {
      return await f;
    } catch (_) {
      return null;
    }
  }

  if (ctx.base.isNotEmpty) {
    attempts.add(soft(() async {
      try {
        final r = await http
            .get(Uri.parse('${ctx.base}$path'), headers: ctx.h)
            .timeout(const Duration(seconds: 10));
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['ok'] == true && '${j['url'] ?? ''}'.isNotEmpty) {
          return Map<String, dynamic>.from(j);
        }
      } catch (_) {}
      return null;
    }()));
  }
  attempts.add(soft(biliDirect(path)));

  final c = Completer<Map<String, dynamic>?>();
  for (final a in attempts) {
    a.then((v) {
      if (v != null && !c.isCompleted) c.complete(v);
    });
  }
  final all = await soft(Future.wait(attempts).then((list) =>
      list.firstWhere((e) => e != null, orElse: () => null)));
  if (!c.isCompleted) c.complete(all);
  return c.future;
}

/// 播放/图片请求统一头：B 站 CDN 与图床都校验 Referer
Map<String, String> biliHeaders(BiliCtx ctx) => <String, String>{
      ...ctx.h,
      'referer': biliReferer,
      'user-agent': biliUA,
    };

Future<Map<String, dynamic>?> biliPost(
    BiliCtx ctx, String path, Map<String, dynamic> body,
    {int sec = 30}) async {
  try {
    final r = await http
        .post(
          Uri.parse('${ctx.base}$path'),
          headers: {...ctx.h, 'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(Duration(seconds: sec));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map) return Map<String, dynamic>.from(j);
  } catch (_) {}
  return null;
}

String biliDur(num? s) {
  final t = (s ?? 0).toInt();
  if (t <= 0) return '';
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final sec = t % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

String biliPlays(num? n) {
  final v = (n ?? 0).toInt();
  if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}w';
  return '$v';
}

List<Map<String, dynamic>> biliItems(Map<String, dynamic> j) =>
    ((j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);

/// 封面：B 站图床有防盗链，走后端 /v1/bili/cover 代理
/// 从「后端代理地址」里解出真实图床地址。
/// 为什么这么做：Image.network 走 9527 时，自签证书 + 自定义 header 容易失败，
/// 表现为「所有封面都是破图」。B 站图床直连不需要任何 header（实测 200），
/// 所以优先直连，失败再由 errorBuilder 回落到后端代理。
String biliRealCover(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  if (s.contains('/v1/bili/cover?u=')) {
    try {
      final i = s.indexOf('u=');
      s = Uri.decodeComponent(s.substring(i + 2));
    } catch (_) {}
  }
  if (s.startsWith('http://')) s = s.replaceFirst('http://', 'https://');
  return s;
}

Widget biliCover(BuildContext context, BiliCtx ctx, String raw,
    {required double radius}) {
  final u = biliRealCover(raw);
  if (u.isEmpty) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest),
    );
  }
  final full = u.startsWith('http')
      ? u
      : '${ctx.base}/v1/bili/cover?u=${Uri.encodeQueryComponent(u)}';
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: Image.network(
      full,
      headers: full.startsWith('http') && !full.contains('/v1/bili/cover')
          ? const <String, String>{}
          : biliHeaders(ctx),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) {
        // 普通版（没有后端）时，`/v1/bili/cover` 这个回退根本没有接收方，
        // 再请求一次只会多一个失败日志 + 一张破图。直接用占位块。
        Widget placeholder() => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(Icons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.outline),
            );
        if (ctx.base.isEmpty) return placeholder();
        return Image.network(
          '${ctx.base}/v1/bili/cover?u=${Uri.encodeQueryComponent(u)}',
          headers: biliHeaders(ctx),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => placeholder(),
        );
      },
    ),
  );
}

/// 选择下载位置（媒体库目标：影视 / 音乐）。返回目标 id，取消返回 null。
Future<String?> pickBiliTarget(BuildContext context, BiliCtx ctx) async {
  final j = await biliGet(ctx, '/v1/bili/folders');
  final targets = ((j == null ? null : j['targets'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
  if (!context.mounted) return null;
  if (targets.isEmpty) return 'video';
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
            child: Text(tr('选择下载位置'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          for (final tg in targets)
            ListTile(
              leading: Icon('${tg['id']}' == 'music'
                  ? Icons.music_note_outlined
                  : Icons.movie_outlined),
              // ★4.81.76：不能把插值包进 tr 的**字符串字面量**里（tr 后跟一对单引号
              //   再插值）—— 那不是「翻译这个名字」，而是把插值结果当成一个字面 key
              //   去查表：永远查不到，还会把半截字符串喂进 i18n 自检的 key 集合，
              //   长期污染统计。要翻译的是运行时的值本身，所以直接传值。
              title: Text(tr(tg['name'].toString())),
              subtitle: Text('${tg['id']}' == 'music'
                  ? tr('放进去之后在「音乐」里能听')
                  : tr('放进去之后在「影视」里能看')),
              onTap: () => Navigator.of(c).pop('${tg['id']}'),
            ),
        ],
      ),
    ),
  );
}

// ───────────────────────── 网格 Tab（推荐/热门/搜索复用） ─────────────────────────

typedef BiliPathBuilder = String Function(int pn);

class _BiliGridTab extends StatefulWidget {
  final BiliCtx ctx;
  final BiliPathBuilder pathBuilder;

  /// 排行榜模式：封面左上角显示名次
  final bool rankBadge;

  const _BiliGridTab(
      {super.key, required this.ctx, required this.pathBuilder, this.rankBadge = false});

  @override
  State<_BiliGridTab> createState() => _BiliGridTabState();
}

class _BiliGridTabState extends State<_BiliGridTab>
    with AutomaticKeepAliveClientMixin {
  final _sc = ScrollController();
  final List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  int _pn = 0;
  bool _loading = false;
  bool _nomore = false;
  String _err = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
    _refresh();
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_sc.hasClients || _loading || _nomore || _err.isNotEmpty) return;
    if (_sc.position.pixels > _sc.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _err = '';
      _nomore = false;
    });
    final j = await biliGet(widget.ctx, widget.pathBuilder(1));
    if (!mounted) return;
    if (j == null) {
      setState(() => _err = tr('失败'));
      return;
    }
    if (j['ok'] != true) {
      setState(() => _err =
          '${j['message'] ?? ''}'.trim().isEmpty ? tr('失败') : '${j['message']}');
      return;
    }
    final list = biliItems(j);
    setState(() {
      _items
        ..clear()
        ..addAll(list);
      _pn = 1;
      _nomore = list.length < 20;
    });
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    _loading = true;
    final j = await biliGet(widget.ctx, widget.pathBuilder(_pn + 1));
    _loading = false;
    if (!mounted || j == null || j['ok'] != true) return;
    final list = biliItems(j);
    setState(() {
      if (list.isEmpty) {
        _nomore = true;
      } else {
        _items.addAll(list);
        _pn++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    if (_err.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_err, style: TextStyle(color: cs.error)),
            const SizedBox(height: Gap.sm),
            OutlinedButton(onPressed: _refresh, child: Text(tr('重试'))),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text(tr('没搜到，换个词试试')));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: GridView.builder(
        controller: _sc,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(Gap.md),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: Gap.md,
          crossAxisSpacing: Gap.md,
          childAspectRatio: 0.78,
        ),
        itemCount: _items.length + (_nomore ? 0 : 1),
        itemBuilder: (c, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(
                child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            );
          }
          final it = _items[i];
          final title = '${it['title'] ?? ''}';
          final owner = '${it['owner'] ?? ''}';
          final dur = biliDur(it['duration'] is num ? it['duration'] as num : null);
          final play = biliPlays(it['play'] is num ? it['play'] as num : null);
          return InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => BiliSwipePage(
                      ctx: widget.ctx,
                      items: List<Map<String, dynamic>>.from(_items),
                      initialIndex: i),
                )),
            onLongPress: () => openBiliVideo(context, widget.ctx, it),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      biliCover(c, widget.ctx,
                          '${it['coverRaw'] ?? it['cover'] ?? ''}',
                          radius: Radii.md),
                      if (widget.rankBadge)
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: i < 3 ? cs.primary : Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('${i + 1}',
                                style: TextStyle(
                                    color: i < 3 ? cs.onPrimary : Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ),
                      if (dur.isNotEmpty)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(dur,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11)),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.25),
                ),
                const SizedBox(height: 2),
                Text(
                  play.isEmpty ? owner : '$owner · $play',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────── 频道 Tab（排行榜/分区共用：横向频道条 + 网格） ─────────────────────────

typedef BiliRidPathBuilder = String Function(int rid, int pn);

class _BiliChipsTab extends StatefulWidget {
  final BiliCtx ctx;
  final String chipsPath;
  final BiliRidPathBuilder pathBuilder;
  final bool rankBadge;

  const _BiliChipsTab({
    super.key,
    required this.ctx,
    required this.chipsPath,
    required this.pathBuilder,
    this.rankBadge = false,
  });

  @override
  State<_BiliChipsTab> createState() => _BiliChipsTabState();
}

class _BiliChipsTabState extends State<_BiliChipsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _parts = const [];
  int _rid = 0;
  bool _loaded = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadParts();
  }

  Future<void> _loadParts() async {
    final j = await biliGet(widget.ctx, widget.chipsPath);
    if (!mounted || j == null || j['ok'] != true) return;
    final list = ((j['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    setState(() {
      _parts = list;
      _rid = list.isEmpty ? 0 : (list.first['rid'] is num ? (list.first['rid'] as num).toInt() : 0);
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_parts.isEmpty) return Center(child: Text(tr('失败')));
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            itemCount: _parts.length,
            itemBuilder: (c, i) {
              final p = _parts[i];
              final rid = p['rid'] is num ? (p['rid'] as num).toInt() : 0;
              final name = '${p['name'] ?? ''}';
              return Padding(
                padding: const EdgeInsets.only(right: Gap.sm),
                child: ChoiceChip(
                  label: Text(name),
                  selected: rid == _rid,
                  onSelected: (_) => setState(() => _rid = rid),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: _BiliGridTab(
            key: ValueKey('rid-$_rid'),
            ctx: widget.ctx,
            pathBuilder: (pn) => widget.pathBuilder(_rid, pn),
            rankBadge: widget.rankBadge,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── 搜索 Tab ─────────────────────────

class _BiliSearchTab extends StatefulWidget {
  final BiliCtx ctx;
  const _BiliSearchTab({super.key, required this.ctx});

  @override
  State<_BiliSearchTab> createState() => _BiliSearchTabState();
}

class _BiliSearchTabState extends State<_BiliSearchTab>
    with AutomaticKeepAliveClientMixin {
  final _q = TextEditingController();
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
          child: TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: tr('搜索'),
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md)),
            ),
            onSubmitted: (v) {
              final s = v.trim();
              if (s.isEmpty) return;
              if (RegExp(r'(bilibili\.com|b23\.tv|BV1[a-zA-Z0-9]{9,})').hasMatch(s)) {
                openBiliLinkSheet(context, widget.ctx, s);
                return;
              }
              setState(() => _query = s);
            },
          ),
        ),
        Expanded(
          child: _query.isEmpty
              ? Center(child: Text(tr('搜索')))
              : _BiliGridTab(
                  key: ValueKey('q-$_query'),
                  ctx: widget.ctx,
                  pathBuilder: (pn) =>
                      '/v1/bili/search?q=${Uri.encodeQueryComponent(_query)}&pn=$pn',
                ),
        ),
      ],
    );
  }
}

// ───────────────────────── 视频详情 + 下载 ─────────────────────────

/// 点开一个视频：底部弹详情 —— 逐集播放 / 逐集下载 / 一键整季下载。
Future<void> openBiliVideo(
    BuildContext context, BiliCtx ctx, Map<String, dynamic> it) async {
  final bvid = '${it['bvid'] ?? ''}';
  if (bvid.isEmpty) return;
  final title = '${it['title'] ?? ''}';
  final messenger = ScaffoldMessenger.of(context);

  final j = await biliGet(ctx, '/v1/bili/pages?bvid=${Uri.encodeQueryComponent(bvid)}');
  if (j == null || j['ok'] != true) {
    messenger.showSnackBar(SnackBar(content: Text(tr('失败'))));
    return;
  }
  final pages = ((j['pages'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
  if (pages.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(tr('失败'))));
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _BiliDetailSheet(
      ctx: ctx,
      bvid: bvid,
      title: title,
      owner: '${it['owner'] ?? ''}',
      coverRaw: '${it['coverRaw'] ?? it['cover'] ?? ''}',
      pages: pages,
    ),
  );
}

class _BiliDetailSheet extends StatefulWidget {
  final BiliCtx ctx;
  final String bvid;
  final String title;
  final String owner;
  final String coverRaw;
  final List<Map<String, dynamic>> pages;

  const _BiliDetailSheet({
    required this.ctx,
    required this.bvid,
    required this.title,
    required this.owner,
    required this.coverRaw,
    required this.pages,
  });

  @override
  State<_BiliDetailSheet> createState() => _BiliDetailSheetState();
}

class _BiliDetailSheetState extends State<_BiliDetailSheet> {
  bool _busy = false;

  Future<void> _play(Map<String, dynamic> p) async {
    final nav = Navigator.of(context);
    final cid = '${p['cid'] ?? ''}';
    final j = await biliGet(
        widget.ctx,
        '/v1/bili/playurl?bvid=${Uri.encodeQueryComponent(widget.bvid)}'
        '&cid=${Uri.encodeQueryComponent(cid)}');
    if (!mounted) return;
    final url = (j == null) ? '' : '${j['url'] ?? ''}';
    if (url.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('播放失败'))));
      return;
    }
    // ★4.81.74：换用 core/bili_player.dart 的新播放器（常驻弹幕 + 清晰度面板）。
    //   带上 cid，播放页才能按 cid 拉弹幕。
    await nav.push(MaterialPageRoute(
      builder: (_) => BiliPlayerPage(
        title: widget.title,
        url: url,
        apiBase: widget.ctx.base,
        token: widget.ctx.token,
        bvid: widget.bvid,
        cid: cid,
        quality: (j?['quality'] as num?)?.toInt() ?? 0,
        acceptQuality: ((j?['acceptQuality'] as List?) ?? const [])
            .whereType<num>()
            .map((e) => e.toInt())
            .toList(),
      ),
    ));
  }

  /// 单集下载：走 /v1/bili/add，url 里带 ?p=N，默认 1080P（后端自动回退）
  Future<void> _downloadOne(int index) async {
    if (_busy) return;
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null) return;
    setState(() => _busy = true);
    final j = await biliPost(widget.ctx, '/v1/bili/add', {
      'url': 'https://www.bilibili.com/video/${widget.bvid}/?p=${index + 1}',
      'folder': target,
    });
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = j != null && j['ok'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? tr('已加入下载队列')
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
  }

  /// 整季下载：先取清晰度列表（用第一P解析），让用户挑，然后 addall 一次提交
  Future<void> _downloadAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    final parse = await biliGet(
        widget.ctx,
        '/v1/bili/parse?url=${Uri.encodeQueryComponent('https://www.bilibili.com/video/${widget.bvid}/')}');
    if (!mounted) return;
    setState(() => _busy = false);
    final formats = ((parse == null) ? null : (parse['formats'] as List?)) ?? const [];
    final opts = formats
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    int fmt = 0;
    if (opts.isNotEmpty) {
      if (!context.mounted) return;
      final picked = await showDialog<int>(
        context: context,
        builder: (c) => SimpleDialog(
          title: Text(tr('选择清晰度')),
          children: [
            for (final o in opts)
              SimpleDialogOption(
                onPressed: () => Navigator.of(c).pop(o['id'] is num ? (o['id'] as num).toInt() : 0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${o['label'] ?? o['id']}'),
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(0),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(tr('自动')),
              ),
            ),
          ],
        ),
      );
      if (picked == null || !context.mounted) return;
      fmt = picked;
    }
    setState(() => _busy = true);
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null || !context.mounted) return;
    final j = await biliPost(
        widget.ctx,
        '/v1/bili/addall',
        {'bvid': widget.bvid, 'format': fmt, 'folder': target},
        sec: 240);
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = j != null && j['ok'] == true;
    final added = (j == null || j['added'] is! num) ? 0 : (j['added'] as num).toInt();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? trf('共{n}个任务加入下载', {'n': added})
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pages = widget.pages;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    height: 60,
                    child: biliCover(context, widget.ctx, widget.coverRaw,
                        radius: Radii.sm),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        if (widget.owner.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(widget.owner,
                                style: TextStyle(
                                    fontSize: 12, color: cs.outline)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Row(
                children: [
                  if (pages.length > 1)
                    FilledButton.icon(
                      onPressed: _busy ? null : _downloadAll,
                      icon: const Icon(Icons.download_for_offline_outlined,
                          size: 18),
                      label: Text('${tr('全部下载')} (${pages.length})'),
                    ),
                  if (pages.length > 1) const SizedBox(width: Gap.sm),
                  if (_busy)
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
            const SizedBox(height: Gap.sm),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: pages.length,
                itemBuilder: (c, i) {
                  final p = pages[i];
                  final part = '${p['part'] ?? ''}';
                  final dur = biliDur(
                      p['duration'] is num ? p['duration'] as num : null);
                  return ListTile(
                    dense: true,
                    leading: IconButton(
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: _busy ? null : () => _play(p),
                    ),
                    title: Text(
                      trf('第{n}集', {'n': (p['page'] is num) ? (p['page'] as num).toInt() : i + 1}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: part.isEmpty
                        ? (dur.isEmpty ? null : Text(dur))
                        : Text(
                            dur.isEmpty ? part : '$part · $dur',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: IconButton(
                      tooltip: tr('下载本集'),
                      icon: const Icon(Icons.download_outlined),
                      onPressed: _busy ? null : () => _downloadOne(i),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 链接下载（粘贴即下，不用跳页面） ─────────────────────────

/// 粘贴 B 站链接 / BV 号直接下载。initial 为空时弹输入框。
Future<void> openBiliLinkSheet(BuildContext context, BiliCtx ctx,
    [String initial = '']) async {
  final input = initial.trim().isEmpty
      ? await showDialog<String>(
          context: context,
          builder: (c) {
            final ctrl = TextEditingController();
            return AlertDialog(
              title: Text(tr('链接下载')),
              content: TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: tr('粘贴 B 站链接或 BV 号'),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md)),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(c).pop(),
                    child: Text(tr('取消'))),
                FilledButton(
                    onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
                    child: Text(tr('解析'))),
              ],
            );
          },
        )
      : initial;
  if (input == null || input.trim().isEmpty || !context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _BiliLinkSheet(ctx: ctx, input: input.trim()),
  );
}

class _BiliLinkSheet extends StatefulWidget {
  final BiliCtx ctx;
  final String input;
  const _BiliLinkSheet({required this.ctx, required this.input});

  @override
  State<_BiliLinkSheet> createState() => _BiliLinkSheetState();
}

class _BiliLinkSheetState extends State<_BiliLinkSheet> {
  Map<String, dynamic>? _info;
  String _err = '';
  bool _busy = true;
  bool _doing = false;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  Future<void> _parse() async {
    setState(() {
      _busy = true;
      _err = '';
    });
    final j = await biliGet(widget.ctx,
        '/v1/bili/parse?url=${Uri.encodeQueryComponent(widget.input)}');
    if (!mounted) return;
    if (j == null || j['ok'] != true) {
      setState(() {
        _busy = false;
        _err = (j == null || '${j['error'] ?? ''}'.trim().isEmpty)
            ? tr('失败')
            : '${j['error']}';
      });
      return;
    }
    setState(() {
      _info = j;
      _busy = false;
    });
  }

  Future<void> _download({required bool all}) async {
    final info = _info;
    if (info == null || _doing) return;
    final target = await pickBiliTarget(context, widget.ctx);
    if (target == null || !mounted) return;
    setState(() => _doing = true);
    final pages = (info['pages'] as List?)?.length ?? 1;
    final Map<String, dynamic>? j = all && pages > 1
        ? await biliPost(widget.ctx, '/v1/bili/addall',
            {'bvid': '${info['bvid']}', 'folder': target},
            sec: 240)
        : await biliPost(widget.ctx, '/v1/bili/add', {
            'url': widget.input,
            'folder': target,
          });
    if (!mounted) return;
    setState(() => _doing = false);
    final ok = j != null && j['ok'] == true;
    final added = all && pages > 1
        ? ((j == null || j['added'] is! num) ? 0 : (j['added'] as num).toInt())
        : 1;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? (all && pages > 1
                ? trf('共{n}个任务加入下载', {'n': added})
                : tr('已加入下载队列'))
            : ((j == null || '${j['error'] ?? j['message'] ?? ''}'.trim().isEmpty)
                ? tr('失败')
                : '${j['error'] ?? j['message']}'))));
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = _info;
    final pages = (info == null ? null : info['pages'] as List?) ?? const [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.md),
                child: Text(_err, style: TextStyle(color: cs.error)),
              ),
            if (info != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    height: 60,
                    child: biliCover(
                        context, widget.ctx, '${info['cover'] ?? ''}',
                        radius: Radii.sm),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${info['title'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if ('${info['owner'] ?? ''}'.isNotEmpty)
                              '${info['owner']}',
                            if (pages.length > 1)
                              trf('共{n}集', {'n': pages.length}),
                          ].join(' · '),
                          style: TextStyle(fontSize: 12, color: cs.outline),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.md),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _doing ? null : () => _download(all: false),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(pages.length > 1
                          ? tr('下载本集')
                          : tr('下载')),
                    ),
                  ),
                  if (pages.length > 1) ...[
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _doing ? null : () => _download(all: true),
                        icon: const Icon(Icons.download_for_offline_outlined,
                            size: 18),
                        label: Text(tr('整季下载')),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }
}
