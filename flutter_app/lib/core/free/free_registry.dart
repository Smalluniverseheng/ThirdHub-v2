// 源注册表：把「内置源」「管理员同步的源」「用户导入的源」合成一份可用的清单。
//
// ── 三条数据从哪来 ────────────────────────────────────────────
//   · 内置：编译进安装包的 `*Source.source` 常量。离线保底，**不可删**。
//   · 管理员同步：登录管理员账号后从家庭后端拉的源包，缓存在本机。
//   · 用户导入：用户自己从文件/粘贴板导入的源包，缓存在本机。
//
// 后两者都**不进安装包** —— 这是「数据与二进制分离」的落点：
// 安装包只承诺「跑得起来、有保底内容」，真正的源清单是外部数据。
//
// ── 为什么用同步 API ──────────────────────────────────────────
// UI 里到处是 `sourcesOf(kind)` 这种同步调用（渲染源说明条、探活）。
// 全部改成 Future 会污染几十个调用点，且每次渲染都要 await 一次。
// 因此这里做成「启动时 ensureLoaded() 预热内存，之后同步读」。
// 缓存未预热时**只返回内置源** —— 少几个源不会崩，只是少见几个入口。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../agent_dsh_client.dart' show AgentDshClient;
import '../changelog.dart' show ChangelogStore;
import 'free_bundle.dart';
import 'free_dynamic.dart';
import 'free_http.dart';
import 'free_models.dart';
import 'free_policy.dart';
import 'free_sources_media.dart';
import 'free_sources_read.dart';
import 'free_spec.dart';

/// 一个源的执行体。内置源走 Dart 实现，导入源走声明式引擎。
class SourceEntry {
  final FreeSource source;

  /// 内置源的规格（为空表示走 Dart 硬编码实现）。
  final FreeSourceSpec? spec;

  const SourceEntry(this.source, {this.spec});
}

class FreeRegistry {
  FreeRegistry._();

  static const String _kUserBundles = 'free_bundles_user_v1';
  static const String _kAdminBundles = 'free_bundles_admin_v1';
  static const String _kLastSync = 'free_last_sync_v1';

  /// id → 外部源（导入 + 同步）。内置源不在这里，进 [_builtinByKind]。
  static final Map<String, SourceEntry> _external = {};

  /// 已经加载过本地缓存。
  static bool _loaded = false;

  /// 用户是否开启了「允许运行需要自担责任的源」。
  ///
  /// ★ 默认关闭。这是移动端合规的最后一道闸：
  ///   内置源永远合规（编译期可审计）；
  ///   外部源只有在用户**明确点开这个开关**之后才会参与搜索。
  static bool selfResponsibility = false;

  static const String _kSelfResp = 'free_self_responsibility_v1';

  /// 上次从管理员后端同步的时间。
  static DateTime? lastSyncAt;

  // ══════════════════════════════════════════════════════════
  // 内置源
  // ══════════════════════════════════════════════════════════

  /// 每个板块随包发布的内置源。
  ///
  /// ★ 这里出现的每一项都必须 `license.mobileSafe == true`。
  ///   `tool/free_policy_selfcheck.dart` 会逐项断言。
  static List<FreeSource> builtinOf(FreeKind k) => switch (k) {
        FreeKind.music => [AudiusSource.source],
        FreeKind.radio => [RadioSource.source, SomaFmSource.source],
        FreeKind.podcast => [PodcastSource.source],
        FreeKind.comic => [MangaDexSource.source],
        FreeKind.video => [PeerTubeSource.source],
        FreeKind.book => [...poemSources, ...bookSources],
        FreeKind.poem => [...poemSources],
      };

  /// 内置源全集（用于合规审计与设置页统计）。
  static List<FreeSource> get allBuiltin => [
        for (final k in FreeKind.values) ...builtinOf(k),
      ];

  // ══════════════════════════════════════════════════════════
  // 清单
  // ══════════════════════════════════════════════════════════

  /// 当前形态下真正可用的源（内置 + 外部，均已过闸门）。
  ///
  /// ★ 注意这里用的是 `_gateAllows` 而不是 `FreePolicy.filter`：
  ///   后者只认「授权是否合规」，不知道「用户是否已明确开启自担责任」。
  ///   两者必须合成一个判据，否则会出现「开关打开了但仍然看不到」。
  static List<FreeSource> sourcesOf(FreeKind k) => [
        for (final s in allOf(k))
          if (_gateAllows(s)) s
      ];

  /// 未过闸门的全量（给「为什么我这里看不到 XX」的说明页用）。
  static List<FreeSource> allOf(FreeKind k) => [
        ...builtinOf(k),
        for (final e in _external.values)
          if (e.source.kind == k) e.source,
      ];

  /// 取某个源对应的规格。非空表示它是声明式源（搜索要走向量引擎）。
  static FreeSourceSpec? specOf(String id) => _external[id]?.spec;

  /// 入口是否走声明式引擎。
  static bool isDynamic(String sourceId) => _external.containsKey(sourceId);

  static SourceEntry? entryOf(String id) => _external[id];

  static List<FreeSource> get allExternal =>
      [for (final e in _external.values) e.source];

  // ══════════════════════════════════════════════════════════
  // 加载与持久化
  // ══════════════════════════════════════════════════════════

  /// 预热缓存。App 启动与进「开放源」页时各调一次（幂等）。
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    selfResponsibility = p.getBool(_kSelfResp) ?? false;
    final ts = p.getInt(_kLastSync);
    if (ts != null && ts > 0) {
      lastSyncAt = DateTime.fromMillisecondsSinceEpoch(ts);
    }
    _loadRaw(p.getString(_kUserBundles), SourceOrigin.user);
    _loadRaw(p.getString(_kAdminBundles), SourceOrigin.admin);
    _loaded = true;
  }

  static void _loadRaw(String? raw, SourceOrigin origin) {
    if (raw == null || raw.isEmpty) return;
    final r = FreeSourceBundle.parse(raw, origin: origin);
    final b = r.bundle;
    if (b == null) return;
    for (final s in b.sources) {
      _external[s.id] = SourceEntry(s.asSource, spec: s);
    }
  }

  static Future<void> setSelfResponsibility(bool on) async {
    selfResponsibility = on;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSelfResp, on);
  }

  /// 安装一个源包。[origin] 决定存到哪一栏（用户栏 / 管理员栏）。
  ///
  /// 同 id 的源会被**覆盖**（后装的赢），这样「更新源包」不需要先卸载。
  static Future<BundleParse> install(FreeSourceBundle b) async {
    for (final s in b.sources) {
      _external[s.id] = SourceEntry(s.asSource, spec: s);
    }
    await _persist(b.origin == SourceOrigin.admin
        ? SourceOrigin.admin
        : SourceOrigin.user);
    return BundleParse(b, const []);
  }

  static Future<void> removeSource(String id) async {
    final e = _external.remove(id);
    if (e == null) return;
    await _persist(e.source.origin == SourceOrigin.admin
        ? SourceOrigin.admin
        : SourceOrigin.user);
  }

  /// 清空某一栏（内置源不受影响）。
  static Future<void> clear(SourceOrigin origin) async {
    if (origin == SourceOrigin.builtin) return;
    _external.removeWhere((_, e) => e.source.origin == origin);
    await _persist(origin);
  }

  /// 把某一栏写回本地。按 origin 分文件存，互不干扰。
  static Future<void> _persist(SourceOrigin origin) async {
    final list = [
      for (final e in _external.values)
        if (e.source.origin == origin && e.spec != null) e.spec!
    ];
    final bundle = FreeSourceBundle(
      name: origin == SourceOrigin.admin ? '管理员同步' : '我导入的',
      sources: list,
      origin: origin,
    );
    final p = await SharedPreferences.getInstance();
    final key =
        origin == SourceOrigin.admin ? _kAdminBundles : _kUserBundles;
    if (list.isEmpty) {
      await p.remove(key);
    } else {
      await p.setString(key, jsonEncode(bundle.toJson()));
    }
  }

  // ══════════════════════════════════════════════════════════
  // 管理员同步
  // ══════════════════════════════════════════════════════════

  /// 从家庭后端拉源包。返回 (新增/更新数量, 错误说明)。
  ///
  /// ★ 为什么要有这一条路，而不是让用户每次都手动导入文件：
  ///   一个人维护几十个源，家里几台设备都要用 —— 手动导三遍不现实。
  ///   管理员账号一登录，所有设备自动拿到同一份清单。
  ///
  /// ★ 失败一律静默降级：同步失败不该让「开放源」用不了，
  ///   本机已有的源（内置 + 上次同步的）照常工作。
  static Future<(int, String)> syncFromBackend({
    required String base,
    required String token,
  }) async {
    final b = base.trim();
    if (b.isEmpty) return (0, '还没连接家庭后端');
    final uri = Uri.tryParse('$b/v1/free/sources');
    if (uri == null) return (0, '后端地址不成立');

    try {
      final raw = await FreeHttp.send(
        uri.toString(),
        headers: {if (token.trim().isNotEmpty) 'x-th-token': token.trim()},
        timeout: const Duration(seconds: 20),
        maxBytes: 4 * 1024 * 1024,
      );
      final text = utf8.decode(raw, allowMalformed: true);
      if (text.trim().isEmpty) return (0, '后端返回空内容');
      final r = FreeSourceBundle.parse(text, origin: SourceOrigin.admin);
      final bundle = r.bundle;
      if (bundle == null) return (0, r.error);

      for (final s in bundle.sources) {
        _external[s.id] = SourceEntry(s.asSource, spec: s);
      }
      await _persist(SourceOrigin.admin);
      lastSyncAt = DateTime.now();
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kLastSync, lastSyncAt!.millisecondsSinceEpoch);
      return (bundle.count, '');
    } on FreeNetException catch (e) {
      return (0, e.message);
    } catch (e) {
      return (0, '同步失败：$e');
    }
  }

  /// 是否该自动同步：有后端 + 是管理员 + 距上次超过 [minGap]。
  static bool shouldAutoSync({Duration minGap = const Duration(hours: 12)}) {
    if (!ChangelogStore.isAdmin) return false;
    final t = lastSyncAt;
    if (t == null) return true;
    return DateTime.now().difference(t) > minGap;
  }

  // ══════════════════════════════════════════════════════════
  // 执行：搜索 / 下钻
  // ══════════════════════════════════════════════════════════

  /// 跑所有可用的声明式源，把结果拼起来。
  ///
  /// 单个源失败不影响其它源 —— 用户导入的源质量参差，
  /// 「有一个源挂了」不应该表现成「整个板块空着」。
  static Future<ExternalSearchResult> searchDynamic(
    FreeKind kind,
    String q, {
    int page = 1,
  }) async {
    final specs = [
      for (final e in _external.values)
        if (e.source.kind == kind &&
            e.spec != null &&
            e.spec!.search != null &&
            _gateAllows(e.source))
          e.spec!
    ];
    if (specs.isEmpty) return const ExternalSearchResult([], []);

    final items = <FreeItem>[];
    final errs = <String>[];
    final vars = {'q': q, 'page': '$page'};

    await Future.wait(specs.map((s) async {
      try {
        final got = await DynamicSource.run(s, s.search!, vars);
        items.addAll(got);
      } on FreeNetException catch (e) {
        errs.add('${s.name}：${e.message}');
      } catch (e) {
        errs.add('${s.name}：$e');
      }
    }));

    return ExternalSearchResult(items, errs);
  }

  /// 内置源 + 已同步/已导入源的统一搜索 —— 板块页与开放源页共用这一处。
  ///
  /// ★ 为什么必须抬到注册表里（4.81.87）：
  ///   4.81.86 之前这段逻辑是 `free_center_page` 的私有方法，结果是
  ///   漫画/音乐/影视三个板块在「既没连引擎、也没连后端」时只能显示
  ///   「未连接本地资料库」—— 而手机本来就能直连的开放源就在包里躺着，
  ///   用户却进不去。这正是「后端只是保底」没兑现的那一段。
  ///   现在板块页直接调这里，不连任何服务器都能出内容。
  ///
  /// 顺序仍是「内置在前、外部在后」，且**内置失败不阻塞外部**：
  /// 用户导入源就是为了补内置源没有的东西，不能因为 MangaDex 挂了
  /// 就连导入源一起不显示。
  ///
  /// [bookBucket] 只在 book 板块且 [q] 为空时用到（公版书按首字母分区浏览）。
  static Future<ExternalSearchResult> searchAll(
    FreeKind kind,
    String q, {
    int page = 1,
    String bookBucket = 'A–M',
  }) async {
    final items = <FreeItem>[];
    final errs = <String>[];
    FreeNetException? builtinErr;

    try {
      items.addAll(await _builtinSearch(kind, q, bookBucket: bookBucket));
    } on FreeNetException catch (e) {
      builtinErr = e;
    } catch (e) {
      // 内置源抛出非网络异常也要收敛：不能让它把外部源一起带下水。
      builtinErr = FreeNetException('$e');
    }

    final hasExternal = _external.values
        .any((e) => e.source.kind == kind && _gateAllows(e.source));
    if (hasExternal) {
      final ext = await searchDynamic(kind, q, page: page);
      items.addAll(ext.items);
      errs.addAll(ext.errors);
    }

    final merged = _dedupe(items);
    // 内置真的挂了、外部也没兜住 —— 把内置的原因如实报出去（离线/超时），
    // 而不是显示一个「什么都没搜到」的白页让人以为内容不存在。
    if (merged.isEmpty && builtinErr != null) throw builtinErr;
    return ExternalSearchResult(merged, errs);
  }

  /// 内置源的取数（编译进包的那几个）。
  ///
  /// 与 4.81.85 的行为完全一致，只是从页面里搬了出来。
  static Future<List<FreeItem>> _builtinSearch(
    FreeKind kind,
    String q, {
    String bookBucket = 'A–M',
  }) async {
    switch (kind) {
      case FreeKind.music:
        return q.isEmpty ? AudiusSource.trending() : AudiusSource.search(q);
      case FreeKind.radio:
        return _radioAll(q);
      case FreeKind.podcast:
        // iTunes 必须有词，空搜索给一个能出结果的中性词。
        return PodcastSource.search(q.isEmpty ? '故事' : q);
      case FreeKind.comic:
        return q.isEmpty
            ? MangaDexSource.popularZh()
            : MangaDexSource.search(q);
      case FreeKind.video:
        return q.isEmpty ? PeerTubeSource.latest() : PeerTubeSource.search(q);
      case FreeKind.book:
        if (q.isNotEmpty) return WikisourceSource.search(q);
        return GutenbergAuSource.browse(bucket: bookBucket);
      default:
        return const [];
    }
  }

  /// 电台：radio-browser 与 SomaFM 并发。
  ///
  /// ★ 必须并发而不是串行兜底：两个源都在境外，串行时一个超时
  ///   就把首屏拖到 15 秒以上。并发下最坏也是 15 秒，最好 2 秒。
  static Future<List<FreeItem>> _radioAll(String q) async {
    final out = <FreeItem>[];
    final errs = <String>[];
    await Future.wait([
      () async {
        try {
          final got =
              q.isEmpty ? await RadioSource.top() : await RadioSource.search(q);
          out.addAll(got);
        } on FreeNetException catch (e) {
          errs.add('网络电台：${e.message}');
        }
      }(),
      () async {
        try {
          final got = q.isEmpty
              ? await SomaFmSource.top()
              : await SomaFmSource.search(q);
          out.addAll(got);
        } on FreeNetException catch (e) {
          errs.add('SomaFM：${e.message}');
        }
      }(),
    ]);
    if (out.isEmpty && errs.isNotEmpty) {
      throw FreeNetException(errs.join('；'), offline: true);
    }
    return out;
  }

  /// 去重：同标题 + 同播放地址视为同一条。
  ///
  /// 按「标题+地址」而不是 id：不同源的 id 体系完全不兼容，
  /// 而同一内容被两个源返回时这两项通常一样。
  static List<FreeItem> _dedupe(List<FreeItem> src) {
    final seen = <String>{};
    final out = <FreeItem>[];
    for (final it in src) {
      final k = '${it.title.trim().toLowerCase()}|${it.playUrl}';
      if (!seen.add(k)) continue;
      out.add(it);
    }
    return out;
  }

  /// 下钻：取子列表（章节 / 单集 / 剧集）。
  static Future<List<FreeItem>> drill(FreeItem parent) async {
    final e = _external[parent.source];
    final spec = e?.spec;
    final act = spec?.detail;
    if (spec == null || act == null) return const [];

    final id = '${parent.raw['id'] ?? parent.id}';
    final got = await DynamicSource.run(
      spec,
      act,
      {'id': id, 'q': id, 'page': '1'},
      kindOverride: parent.kind,
    );
    return got;
  }

  /// 闸门：外部源要不要放行。
  ///
  /// 三层判定，任一层不过就不放行：
  ///   1. 桌面端 → 一律放行（部署者自负）；
  ///   2. 移动端 + 授权合规 → 放行；
  ///   3. 移动端 + 不合规 → 只有用户打开「自担责任」开关才放行。
  ///
  /// ★ 第 3 条正是用户要的「即使不合规也能在 App 端用」——
  ///   但必须是他自己点的开关，不是我们默认开的。
  static bool _gateAllows(FreeSource s) {
    if (FreePolicy.audience.isDesktop) return true;
    if (s.license.mobileSafe) return true;
    return selfResponsibility;
  }

  /// 该同步就同步一次，返回本次拿到的源数（0 表示没动作）。
  ///
  /// 触发条件三条全满足才会真发请求：
  ///   1. 已登录且是管理员（`ChangelogStore.isAdmin`）；
  ///   2. 已经连上家庭后端（`AgentDshClient.base` 非空）；
  ///   3. 距上次同步超过 12 小时，或从没同步过。
  ///
  /// ★ 为什么放在「进页面时」而不是「App 启动时」：
  ///   启动阶段本来就有十来个并发请求（后端正测、更新检查、日志上报…），
  ///   再塞一个 16KB 的拉取会让冷启动更慢，而用户看不到任何即时反馈。
  ///   放在「开放源 / 我的源」页，是用户正要看源清单的时刻 ——
  ///   同步完立刻反映在列表里，快慢他都感知得到。
  ///
  /// ★ 失败一律静默：同步失败不该弹窗打断用户，本机已有的源照常用。
  static Future<int> autoSyncIfNeeded() async {
    if (!shouldAutoSync()) return 0;
    final base = AgentDshClient.base;
    if (base.trim().isEmpty) return 0;
    final (n, err) = await syncFromBackend(
      base: base,
      token: AgentDshClient.token,
    );
    return err.isEmpty ? n : 0;
  }
}

/// 声明式源的搜索结果。[errors] 是逐源失败原因，UI 可以折叠显示。
class ExternalSearchResult {
  final List<FreeItem> items;
  final List<String> errors;

  const ExternalSearchResult(this.items, this.errors);

  bool get hasError => errors.isNotEmpty;
}
