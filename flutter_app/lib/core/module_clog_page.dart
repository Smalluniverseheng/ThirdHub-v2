// 分模块更新公告页。
//
// 为什么要有它：更新历史原本是**一条按版本倒序的全局流水账**。用户在「小说」里
// 想知道"这个模块最近改了什么"，得逐条读、自己挑 —— 上百条记录里挑十几条。
// 这一页把同一份流水账按模块切一刀，只显示与本模块有关的条目。
//
// 两个设计要点：
//  * **不新增数据源**。切分是纯函数做的（`changelog_logic.dart`），数据还是
//    `ChangelogStore` 那一份（同一个云端表、同一份本地缓存）。多开一套"分模块
//    公告"数据只会带来两者不一致。
//  * **不列空壳模块**。只把"真有记录"的模块做成可切换的 chip，否则 65 个模块里
//    大半是空的，用户点进去只会看到"暂无"，反而像是在骗他点。
//
// 入口：模块菜单（各模块页 ⋯ → 「本模块更新公告」）。一处覆盖全部模块，
// 不需要给 65 个模块各改一次 UI —— 那正是这类需求最容易腐烂的做法。

import 'package:flutter/material.dart';

import 'changelog.dart';

class ModuleClogPage extends StatefulWidget {
  const ModuleClogPage({super.key, required this.module, this.initialAdmin = false});

  /// 模块名。必须与 `ClogModules.all` / main.dart 注册表同名。
  final String module;

  /// 是否按管理员档拉取（多一段更早的历史）。实际权限在服务端 RLS。
  final bool initialAdmin;

  @override
  State<ModuleClogPage> createState() => _ModuleClogPageState();
}

class _ModuleClogPageState extends State<ModuleClogPage> {
  late String _module = widget.module;
  bool _admin = false;
  bool _loading = true;
  bool _refreshing = false;
  String _err = '';
  ModClog _mc = const ModClog('', <ClogRow>[], 0);

  /// 有记录的模块（含「全局」）。为空时退化成"只有当前模块"。
  List<String> _present = const <String>[];

  @override
  void initState() {
    super.initState();
    _admin = widget.initialAdmin || ChangelogStore.isAdmin;
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (mounted) setState(() { _loading = _mc.empty; _refreshing = !_mc.empty; });
    try {
      _present = await ChangelogStore.modulesWithClog(admin: _admin);
    } catch (_) {}
    final ModClog mc = await ChangelogStore.forModule(_module, admin: _admin, force: force);
    if (!mounted) return;
    setState(() {
      _mc = mc;
      _loading = false;
      _refreshing = false;
      _err = '';
    });
    // 拉失败时给一句人话，而不是静静显示"暂无更新"
    if (mc.empty && _present.isEmpty) {
      final ClogResult r = await ChangelogStore.load(admin: _admin);
      if (mounted) setState(() => _err = r.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    final Color accent = t.colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text('$_module · 更新公告'),
        actions: <Widget>[
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: () => _load(force: true),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: <Widget>[
                  if (_present.length > 1) _modulePicker(accent),
                  if (_mc.empty) _emptyCard(t) else ...<Widget>[
                    _headCard(t, accent),
                    const SizedBox(height: 10),
                    for (final ClogRow r in _mc.rows) _versionCard(t, r),
                  ],
                  const SizedBox(height: 16),
                  _footerHint(t),
                ],
              ),
      ),
    );
  }

  // ── 顶部：模块切换（只列真有记录的） ──
  Widget _modulePicker(Color accent) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final String m in _present)
            ChoiceChip(
              label: Text(m == ClogModules.global ? '全局' : m, style: const TextStyle(fontSize: 12)),
              selected: m == _module,
              onSelected: (_) {
                setState(() { _module = m; _mc = const ModClog('', <ClogRow>[], 0); });
                _load();
              },
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _headCard(ThemeData t, Color accent) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(Icons.campaign_outlined, size: 20, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _module == ClogModules.global ? '全局更新（不属于任何单一模块）' : '$_module 模块共 ${_mc.itemCount} 条更新',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '最新 v${_mc.latestVersion} · 涉及 ${_mc.rows.length} 个版本',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionCard(ThemeData t, ClogRow r) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('v${r.v}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                if (r.date.isNotEmpty)
                  Text(r.date, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                const Spacer(),
                Text('${r.items.length} 条', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
            const SizedBox(height: 6),
            for (final String it in r.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Icon(Icons.circle, size: 5, color: t.colorScheme.primary.withValues(alpha: 0.7)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(it, style: const TextStyle(fontSize: 12.5, height: 1.45))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard(ThemeData t) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.info_outline, size: 18, color: Colors.grey.shade500),
                const SizedBox(width: 8),
                Text('$_module 暂无单独的更新记录', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '这只说明历次更新公告里没有提到「$_module」这个名字，'
              '不代表这个模块没被改过。可以到「我的 → 更新历史」看按版本排列的完整流水账。'
              '${_err.isEmpty ? "" : "\n\n（拉取提示：$_err）"}',
              style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footerHint(ThemeData t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '说明：这里按关键词把历次更新公告归到各模块。一条改动可能同时涉及多个模块，'
        '因此会在各自的公告里都出现；归属不上的会进「全局」。'
        '完整历史见「我的 → 更新历史」。',
        style: TextStyle(fontSize: 11, height: 1.5, color: Colors.grey.shade600),
      ),
    );
  }
}
