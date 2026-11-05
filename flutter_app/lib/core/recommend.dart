// 推荐服务（书城 / 音乐 / 影视）+ 激活码。
//
// 定位（2026-11-05 用户要求）：
//   内容推荐**由站长自己提供额度**，服务跑在站长的 NAS 上。
//   App 出厂**完全不内置任何源、任何推荐**——默认就是「服务未开通」。
//   用户必须拿到激活码、在 App 里填写激活，才会去拉推荐数据。
//
// 为什么这么设计（而不是内置一堆公开源）：
//   1. 推荐质量由服务端统一维护，改推荐不用发新版 App；
//   2. 服务端可以按激活码统计额度（谁的用量、什么时候到期），这是站长要的能力；
//   3. 出厂不带任何第三方源，合规面最小。
//
// 协议（极简 HTTP，服务端任何语言都能实现）：
//   GET  {base}/v1/recommend?type=book|music|video&limit=20
//        Header: X-TH-License: <激活码>
//        200 → { "items": [ { "title","subtitle","cover","url","tag" } ] }
//        401 → 激活码无效/过期
//    POST {base}/v1/activate   body: { "code": "XXXX-XXXX" }
//        200 → { "ok": true, "expiresAt": 1799999999000, "quota": 1000 }
//        401 → 无效
//    GET  {base}/v1/health  → { "ok": true, "name": "..." }
//
// 刻意不做的事：
//   · 不做客户端自带的「兜底推荐」——兜底等于变相内置源，违背设计初衷
//   · 不把激活码写进日志（避免日志上报时泄露）

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_tokens.dart';
import 'i18n.dart';

/// 推荐条目。字段刻意保持最小：服务端只给必要信息，点击用 url 交给外层处理
/// （书 → 引擎搜索，影/音 → 播放器），避免 App 与具体内容源耦合。
class RecommendItem {
  const RecommendItem({
    required this.title,
    this.subtitle = '',
    this.cover = '',
    this.url = '',
    this.tag = '',
  });

  final String title;
  final String subtitle;
  final String cover;
  final String url;
  final String tag;

  static RecommendItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = '${j['title'] ?? ''}'.trim();
    if (t.isEmpty) return null;
    return RecommendItem(
      title: t,
      subtitle: '${j['subtitle'] ?? ''}',
      cover: '${j['cover'] ?? ''}',
      url: '${j['url'] ?? ''}',
      tag: '${j['tag'] ?? ''}',
    );
  }
}

/// 激活状态。
class LicenseState {
  const LicenseState({
    this.code = '',
    this.expiresAt = 0,
    this.quota = 0,
    this.base = '',
  });

  final String code;

  /// epoch ms；0 表示未知/永久
  final int expiresAt;
  final int quota;

  /// 服务基址（站长 NAS 地址）。与激活码分开存，换地址不用重新激活。
  final String base;

  bool get activated => code.isNotEmpty;
  bool get expired =>
      expiresAt > 0 && DateTime.now().millisecondsSinceEpoch > expiresAt;

  /// ★2026-11-06（4.81.28）：这段文案直接显示在设置页，必须走 tr()/trf()。
  ///   4.81.27 首版写死中文 → 切到英/日/法/俄/西/阿，设置页仍满屏中文。
  String get expiresText {
    if (!activated) return tr('未激活');
    if (expiresAt <= 0) return tr('长期有效');
    final d = DateTime.fromMillisecondsSinceEpoch(expiresAt);
    final left = d.difference(DateTime.now()).inDays;
    final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    if (left >= 0) {
      return trf('{date} 到期（剩 {n} 天）', {'date': date, 'n': left});
    }
    return trf('{date} 已过期', {'date': date});
  }
}

class RecommendService {
  static const _kCode = 'rec_license_code';
  static const _kExp = 'rec_license_exp';
  static const _kQuota = 'rec_license_quota';
  static const _kBase = 'rec_service_base';

  static LicenseState _state = const LicenseState();
  static LicenseState get state => _state;

  static Future<LicenseState> load() async {
    final p = await SharedPreferences.getInstance();
    _state = LicenseState(
      code: p.getString(_kCode) ?? '',
      expiresAt: p.getInt(_kExp) ?? 0,
      quota: p.getInt(_kQuota) ?? 0,
      base: p.getString(_kBase) ?? '',
    );
    return _state;
  }

  static Future<void> setBase(String base) async {
    final p = await SharedPreferences.getInstance();
    final b = base.trim().replaceAll(RegExp(r'/+$'), '');
    await p.setString(_kBase, b);
    _state = LicenseState(
        code: _state.code, expiresAt: _state.expiresAt, quota: _state.quota, base: b);
  }

  static Future<void> _save(String code, int exp, int quota) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCode, code);
    await p.setInt(_kExp, exp);
    await p.setInt(_kQuota, quota);
    _state = LicenseState(
        code: code, expiresAt: exp, quota: quota, base: _state.base);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kCode, _kExp, _kQuota]) {
      await p.remove(k);
    }
    _state = LicenseState(base: _state.base);
  }

  /// 发请求。`path` 不含基址。超时 12 秒——推荐是"顺手看看"的东西，
  /// 卡太久不如直接告诉用户服务不通。
  static Future<({int status, Object? json})> _req(
      String path, String method, Map<String, dynamic>? body) async {
    final base = _state.base;
    if (base.isEmpty) return (status: -1, json: null);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client
          .openUrl(method, Uri.parse('$base$path'))
          .timeout(const Duration(seconds: 12));
      req.headers.set('Accept', 'application/json');
      if (_state.code.isNotEmpty) {
        req.headers.set('X-TH-License', _state.code);
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final txt = await resp.transform(utf8.decoder).join();
      Object? j;
      try {
        j = txt.isEmpty ? null : jsonDecode(txt);
      } catch (_) {
        j = null;
      }
      return (status: resp.statusCode, json: j);
    } catch (_) {
      return (status: -1, json: null);
    } finally {
      client.close();
    }
  }

  /// 校验激活码。成功返回 null，失败返回给用户看的原因。
  static Future<String?> activate(String base, String code) async {
    await setBase(base);
    final c = code.trim();
    if (c.isEmpty) return tr('请填写激活码');
    if (_state.base.isEmpty) return tr('请填写服务地址');
    final r = await _req('/v1/activate', 'POST', {'code': c});
    if (r.status == -1) return tr('连不上服务，请检查地址或网络');
    if (r.status == 401) return tr('激活码无效或已过期');
    if (r.status != 200) {
      return trf('激活失败（HTTP {code}）', {'code': r.status});
    }
    final j = r.json;
    if (j is! Map) return tr('服务返回格式不对');
    // 服务端回传的 message 是**服务方自定义文案**，原样显示；缺失才用本地兜底。
    if (j['ok'] != true) return '${j['message'] ?? tr('激活码无效')}';
    final exp = (j['expiresAt'] as num?)?.toInt() ?? 0;
    final quota = (j['quota'] as num?)?.toInt() ?? 0;
    await _save(c, exp, quota);
    return null;
  }

  /// 拉推荐。返回 (items, error)。
  static Future<({List<RecommendItem> items, String? error})> fetch(
      String type, {int limit = 24}) async {
    if (!_state.activated) return (items: const <RecommendItem>[], error: 'not-activated');
    final r = await _req('/v1/recommend?type=$type&limit=$limit', 'GET', null);
    if (r.status == 401) return (items: const <RecommendItem>[], error: 'expired');
    if (r.status == -1) return (items: const <RecommendItem>[], error: 'offline');
    if (r.status != 200) return (items: const <RecommendItem>[], error: 'HTTP ${r.status}');
    final j = r.json;
    final list = (j is Map ? j['items'] : null) as List?;
    final items = (list ?? const [])
        .map(RecommendItem.fromJson)
        .whereType<RecommendItem>()
        .toList();
    return (items: items, error: null);
  }

  /// 服务是否可达（用于设置页的「测试连接」）。
  static Future<String?> ping() async {
    final r = await _req('/v1/health', 'GET', null);
    if (r.status == -1) return tr('连不上');
    if (r.status != 200) return 'HTTP ${r.status}';
    return null;
  }
}

// ─────────────────────────── 页面 ───────────────────────────

/// 推荐模块：书 / 音乐 / 影视 三个板块。
/// 未激活时整个页面就是一张引导卡——这是**设计意图**，不是降级：
/// 出厂不带任何推荐，用户必须先拿到激活码。
class RecommendPage extends StatefulWidget {
  const RecommendPage({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  State<RecommendPage> createState() => _RecommendPageState();
}

class _RecommendPageState extends State<RecommendPage>
    with SingleTickerProviderStateMixin {
  /// ★2026-11-06（4.81.28）：不能是 `const` —— 要按当前语言取词。
  ///   一个 getter 换 3 次 Map 查找，代价可忽略，换来「切语言立即生效」。
  List<(String, String)> get _tabs => [
        (tr('书城推荐'), 'book'),
        (tr('音乐推荐'), 'music'),
        (tr('影视推荐'), 'video'),
      ];

  late TabController _tc;
  LicenseState _lic = const LicenseState();
  final Map<String, List<RecommendItem>> _cache = {};
  final Map<String, String?> _errors = {};
  final Map<String, bool> _loading = {};

  @override
  void initState() {
    super.initState();
    _tc = TabController(
        length: _tabs.length, vsync: this, initialIndex: widget.initialTab);
    RecommendService.load().then((s) {
      if (!mounted) return;
      setState(() => _lic = s);
      if (s.activated) _load(_tabs[_tc.index].$2);
    });
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _load(String type, {bool force = false}) async {
    if (_loading[type] == true) return;
    if (!force && _cache.containsKey(type)) return;
    setState(() {
      _loading[type] = true;
      _errors.remove(type);
    });
    final r = await RecommendService.fetch(type);
    if (!mounted) return;
    setState(() {
      _loading[type] = false;
      _cache[type] = r.items;
      _errors[type] = r.error;
    });
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('推荐')),
        actions: [
          IconButton(
            tooltip: tr('服务设置'),
            onPressed: _openSettings,
            icon: const Icon(Icons.tune, size: 20),
          ),
        ],
        bottom: _lic.activated
            ? TabBar(
                controller: _tc,
                onTap: (i) => _load(_tabs[i].$2),
                tabs: [for (final t in _tabs) Tab(text: t.$1)],
              )
            : null,
      ),
      body: _lic.activated
          ? TabBarView(
              controller: _tc,
              children: [for (final t in _tabs) _tabBody(t.$2)],
            )
          : _notActivated(c),
    );
  }

  /// 未激活引导：说明为什么什么都看不到，以及下一步该干什么。
  Widget _notActivated(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.workspace_premium_outlined,
                size: 30, color: scheme.primary),
          ),
          const SizedBox(height: Gap.md),
          Text(tr('推荐服务未开通'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.sm),
          Text(
            tr('本应用出厂不内置任何内容源与推荐。\n书城 / 音乐 / 影视的推荐由服务方提供，需要激活码才能开通。'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, height: 1.6, color: Colors.grey),
          ),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            onPressed: _openSettings,
            icon: const Icon(Icons.key_outlined, size: 18),
            label: Text(tr('填写激活码')),
          ),
          if (_lic.base.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(trf('当前服务：{base}', {'base': _lic.base}),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ]),
      ),
    );
  }

  Widget _tabBody(String type) {
    final err = _errors[type];
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined,
                size: 40, color: Colors.grey.withValues(alpha: 0.5)),
            const SizedBox(height: Gap.md),
            Text(_errText(err),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: Gap.md),
            OutlinedButton(
              onPressed: () => _load(type, force: true),
              child: Text(tr('重试')),
            ),
          ]),
        ),
      );
    }
    if (_loading[type] == true && !_cache.containsKey(type)) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _cache[type] ?? const <RecommendItem>[];
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(type, force: true),
        child: ListView(children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.28),
          Center(
              child: Text(tr('服务端暂时没有推荐内容'),
                  style: const TextStyle(fontSize: 13, color: Colors.grey))),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(type, force: true),
      child: GridView.builder(
        padding: const EdgeInsets.all(Gap.md),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: Gap.md,
          crossAxisSpacing: Gap.sm,
          childAspectRatio: 0.58,
        ),
        itemCount: items.length,
        itemBuilder: (c, i) => _card(items[i]),
      ),
    );
  }

  String _errText(String e) => switch (e) {
        'not-activated' => tr('服务未开通'),
        'expired' => tr('激活码已过期，请重新填写'),
        'offline' => tr('连不上服务。\n检查网络，或到「服务设置」确认地址'),
        _ => trf('加载失败：{e}', {'e': e}),
      };

  Widget _card(RecommendItem it) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (it.url.isEmpty) return;
        // 交给外层处理：书 → 引擎搜索；影/音 → 播放器。
        // 这里只给个提示，真正的跳转由宿主模块接（模块间不互相 import）。
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 2),
            content:
                Text(trf('「{title}」→ {url}', {'title': it.title, 'url': it.url}))));
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: it.cover.isEmpty
                ? Container(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.06),
                    alignment: Alignment.center,
                    child: Text(it.title.characters.take(2).toString(),
                        style: const TextStyle(fontSize: 16)),
                  )
                : Image.network(it.cover,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorBuilder: (_, __, ___) => Container(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.06),
                        )),
          ),
        ),
        const SizedBox(height: 6),
        Text(it.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 1.3)),
        if (it.subtitle.isNotEmpty)
          Text(it.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ]),
    );
  }

  Future<void> _openSettings() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const RecommendSettingsPage()),
    );
    if (saved == true) {
      final s = await RecommendService.load();
      if (!mounted) return;
      setState(() {
        _lic = s;
        _cache.clear();
        _errors.clear();
      });
      if (s.activated) _load(_tabs[_tc.index].$2, force: true);
    }
  }
}

/// 服务设置：地址 + 激活码 + 状态 + 测试连接。
class RecommendSettingsPage extends StatefulWidget {
  const RecommendSettingsPage({super.key});
  @override
  State<RecommendSettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<RecommendSettingsPage> {
  late final TextEditingController _base;
  late final TextEditingController _code;
  LicenseState _lic = const LicenseState();
  bool _busy = false;

  /// ★2026-11-06：成功/失败**不能靠比较提示文案**判断 —— 文案本地化后
  ///   中英日法都不一样，比较永远为假（颜色会一直是红的）。用一个 bool 记账。
  bool _ok = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _base = TextEditingController();
    _code = TextEditingController();
    RecommendService.load().then((s) {
      if (!mounted) return;
      setState(() {
        _lic = s;
        _base.text = s.base;
        _code.text = s.code;
      });
    });
  }

  @override
  void dispose() {
    _base.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _doActivate() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final err = await RecommendService.activate(_base.text, _code.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = err == null;
      _msg = err ?? tr('激活成功');
      _lic = RecommendService.state;
    });
    if (err == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('激活成功'))));
    }
  }

  Future<void> _doPing() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    await RecommendService.setBase(_base.text);
    final err = await RecommendService.ping();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = err == null;
      _msg = err == null ? tr('服务可达') : trf('连接失败：{e}', {'e': err});
    });
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('推荐服务设置'))),
      body: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        Text(tr('服务地址'),
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        TextField(
          controller: _base,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: tr('https://你的服务地址（例如 NAS 上的域名）'),
            hintStyle: const TextStyle(fontSize: 11),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(tr('激活码'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        TextField(
          controller: _code,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: tr('由服务方提供'),
            hintStyle: const TextStyle(fontSize: 11),
          ),
        ),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : _doPing,
              child: Text(tr('测试连接')),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : _doActivate,
              child: Text(_busy ? tr('处理中…') : tr('激活')),
            ),
          ),
        ]),
        if (_msg != null) ...[
          const SizedBox(height: Gap.md),
          Text(_msg!,
              style: TextStyle(
                  fontSize: 12,
                  color: _ok ? Colors.green : Colors.redAccent)),
        ],
        const SizedBox(height: Gap.lg),
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(trf('状态：{s}', {'s': _lic.expiresText}),
                style: const TextStyle(fontSize: 12)),
            if (_lic.quota > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(trf('额度：{n}', {'n': _lic.quota}),
                    style: const TextStyle(fontSize: 12)),
              ),
            if (_lic.activated) ...[
              const SizedBox(height: Gap.sm),
              TextButton(
                onPressed: () async {
                  await RecommendService.clear();
                  if (!mounted) return;
                  setState(() {
                    _lic = RecommendService.state;
                    _code.text = '';
                    _ok = true;
                    _msg = tr('已清除激活信息');
                  });
                },
                child: Text(tr('清除激活信息')),
              ),
            ],
          ]),
        ),
        const SizedBox(height: Gap.md),
        Text(
          tr('说明：本应用不内置任何内容源。推荐内容由服务方统一维护，激活码用于识别额度与有效期。服务地址与激活码只存在本机。'),
          style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.6),
        ),
      ]),
    );
  }
}

/// 横向推荐带 —— 嵌在**已有模块的首页**里用（当前挂在搜索页顶部），
/// 不占一个独立模块位。未激活时只占一行，说清为什么没有内容 + 给个入口。
class RecommendStrip extends StatefulWidget {
  const RecommendStrip({super.key, this.type = 'book', this.title = ''});
  final String type;
  final String title;
  @override
  State<RecommendStrip> createState() => _StripState();
}

class _StripState extends State<RecommendStrip> {
  List<RecommendItem> _items = const [];
  String? _err;
  bool _loading = true;
  LicenseState _lic = const LicenseState();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final s = await RecommendService.load();
    if (mounted) setState(() => _lic = s);
    if (!s.activated) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final r = await RecommendService.fetch(widget.type, limit: 12);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = r.items;
      _err = r.error;
    });
  }

  @override
  Widget build(BuildContext c) {
    // 未激活：一行提示，不占地方、不报错、不诱导
    if (!_lic.activated) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            await Navigator.push(context,
                MaterialPageRoute(builder: (_) => const RecommendSettingsPage()));
            if (mounted) _boot();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(Icons.workspace_premium_outlined,
                  size: 16,
                  color: Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.45)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr('推荐服务未开通 · 填激活码后显示'),
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
              const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
            ]),
          ),
        ),
      );
    }
    if (_loading) {
      return const SizedBox(
          height: 44, child: Center(child: LinearProgressIndicator(minHeight: 2)));
    }
    if (_err != null || _items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
        child: Text(widget.title.isEmpty ? tr('书城推荐') : widget.title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      SizedBox(
        height: 150,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: _items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (c, i) {
            final it = _items[i];
            return SizedBox(
              width: 88,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: it.cover.isEmpty
                      ? Container(
                          height: 112,
                          width: 88,
                          color: Theme.of(c)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.06),
                          alignment: Alignment.center,
                          child: Text(it.title.isEmpty ? '?' : it.title.substring(0, 1),
                              style: const TextStyle(fontSize: 20)),
                        )
                      : Image.network(it.cover,
                          height: 112,
                          width: 88,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                                height: 112,
                                width: 88,
                                color: Theme.of(c)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.06),
                              )),
                ),
                const SizedBox(height: 4),
                Text(it.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, height: 1.25)),
              ]),
            );
          },
        ),
      ),
      const SizedBox(height: 6),
    ]);
  }
}
