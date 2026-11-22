// 「我的源」管理页 —— 用户自己导入源包的地方。
//
// ── 这一页解决什么 ────────────────────────────────────────────
// 安装包里的内置源只覆盖「公有领域 / 开放许可 / 官方公开接口」四类，
// 想再加内容就得让用户自己加源。这一页就是那个入口：
//   · 从文件导入（.json）
//   · 从粘贴板导入（贴一段 JSON）
//   · 从管理员账号同步（家里几台设备拉同一份）
//
// ── 为什么源不打包进 APK ──────────────────────────────────────
// 三个理由，按重要性排：
//   1. 合规：上架的二进制里只能有合规源，用户自己的配置不算我们的分发内容；
//   2. 可运营：加一个源不用重新发版，用户也不用重装；
//   3. 可回滚：源坏了删掉就行，不影响 App 本身。
//
// ── 「自担责任」开关为什么要用户自己点 ────────────────────────
// 授权不明的源（第三方规则、主动抓取）默认不参与搜索。
// 开关文案必须把后果说清楚：这是**你的配置**，不是应用提供的功能。
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n.dart';
import 'free_bundle.dart';
import 'free_models.dart';
import 'free_policy.dart';
import 'free_registry.dart';

class FreeSourceManagePage extends StatefulWidget {
  const FreeSourceManagePage({super.key, this.backendBase = '', this.backendToken = ''});

  /// 家庭后端地址与令牌。为空时「从后端同步」按钮置灰并说明原因。
  final String backendBase;
  final String backendToken;

  @override
  State<FreeSourceManagePage> createState() => _FreeSourceManagePageState();
}

class _FreeSourceManagePageState extends State<FreeSourceManagePage> {
  bool _busy = false;
  String _msg = '';
  bool _msgBad = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await FreeRegistry.ensureLoaded();
    if (mounted) setState(() {});
    // 进页面顺手同步一次（管理员 + 有后端 + 超过 12h 才会真发）。
    final added = await FreeRegistry.autoSyncIfNeeded();
    if (added > 0 && mounted) {
      setState(() {});
      _toast(trf('已同步 {n} 个源', {'n': added}));
    }
  }

  void _toast(String s, {bool bad = false}) {
    if (!mounted) return;
    setState(() {
      _msg = s;
      _msgBad = bad;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s)));
  }

  // ── 导入 ────────────────────────────────────────────────
  Future<void> _importFromFile() async {
    setState(() => _busy = true);
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
        withData: true,
      );
      if (r == null || r.files.isEmpty) return;
      final f = r.files.first;
      final bytes = f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) {
        _toast(tr('读不到这个文件'), bad: true);
        return;
      }
      await _installText(utf8.decode(bytes, allowMalformed: true),
          from: f.name);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFromClipboard() async {
    setState(() => _busy = true);
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final t = d?.text ?? '';
      if (t.trim().isEmpty) {
        _toast(tr('粘贴板里没有内容'), bad: true);
        return;
      }
      await _installText(t, from: tr('粘贴板'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installText(String raw, {required String from}) async {
    final r = FreeSourceBundle.parse(raw, origin: SourceOrigin.user);
    final b = r.bundle;
    if (b == null) {
      _toast('${tr('导入失败')}：${r.error}', bad: true);
      return;
    }
    await FreeRegistry.install(b);
    if (!mounted) return;
    setState(() {});
    final warn = r.warnings.isEmpty
        ? ''
        : '（${tr('跳过')} ${r.warnings.length} ${tr('条')}）';
    _toast('${tr('已导入')} ${b.count} ${tr('个源')}$warn');
  }

  // ── 同步 ────────────────────────────────────────────────
  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      final (n, err) = await FreeRegistry.syncFromBackend(
        base: widget.backendBase,
        token: widget.backendToken,
      );
      if (!mounted) return;
      setState(() {});
      if (err.isNotEmpty) {
        _toast('${tr('同步失败')}：$err', bad: true);
      } else {
        _toast('${tr('已同步')} $n ${tr('个源')}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 导出 ────────────────────────────────────────────────
  Future<void> _export() async {
    final all = FreeRegistry.allExternal;
    if (all.isEmpty) {
      _toast(tr('还没有导入任何源'), bad: true);
      return;
    }
    final bundle = FreeSourceBundle(
      name: tr('导出源包'),
      version: DateTime.now().toIso8601String().split('T').first,
      sources: [
        for (final s in all)
          if (FreeRegistry.specOf(s.id) != null) FreeRegistry.specOf(s.id)!
      ],
    );
    final text = bundle.encode();
    await Clipboard.setData(ClipboardData(text: text));
    _toast('${tr('源包已复制到粘贴板')}（${bundle.count} ${tr('个源')}）');
  }

  Future<void> _remove(FreeSource s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('删除这个源？')),
        content: Text(s.name),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: Text(tr('取消'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: Text(tr('删除'))),
        ],
      ),
    );
    if (ok != true) return;
    await FreeRegistry.removeSource(s.id);
    if (!mounted) return;
    setState(() {});
    _toast(tr('已删除'));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mine = FreePolicy.desktopOnly(
        [for (final s in FreeRegistry.allExternal) if (s.origin == SourceOrigin.user) s]);
    final mineAll = [for (final s in FreeRegistry.allExternal) if (s.origin == SourceOrigin.user) s];
    final adm = [for (final s in FreeRegistry.allExternal) if (s.origin == SourceOrigin.admin) s];
    final builtin = FreeRegistry.allBuiltin;
    final atMobile = FreePolicy.audience.isMobile;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('我的源')),
        actions: [
          IconButton(
            tooltip: tr('导出'),
            icon: const Icon(Icons.ios_share),
            onPressed: _busy ? null : _export,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── 说明 ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.inventory_2_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(tr('源清单不装在安装包里'),
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface)),
                ]),
                const SizedBox(height: 8),
                Text(
                  tr('内置源随安装包发布，只有公有领域、开放许可与官方公开接口三类。'
                      '其余源以数据形式独立存放：你导入的只在你本机生效，'
                      '管理员同步的只有登录管理员账号才会下发。'),
                  style: TextStyle(
                      fontSize: 12, height: 1.6, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── 统计 ──
          Row(children: [
            _stat(cs, '${builtin.length}', tr('内置')),
            const SizedBox(width: 8),
            _stat(cs, '${adm.length}', tr('已同步')),
            const SizedBox(width: 8),
            _stat(cs, '${mineAll.length}', tr('我导入的')),
          ]),
          const SizedBox(height: 16),

          // ── 操作 ──
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: _busy ? null : _importFromFile,
              icon: const Icon(Icons.file_open_outlined, size: 18),
              label: Text(tr('从文件导入')),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _importFromClipboard,
              icon: const Icon(Icons.content_paste, size: 18),
              label: Text(tr('从粘贴板导入')),
            ),
            OutlinedButton.icon(
              onPressed: (widget.backendBase.trim().isEmpty || _busy)
                  ? null
                  : _sync,
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: Text(tr('从后端同步')),
            ),
          ]),
          if (widget.backendBase.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr('还没连接家庭后端，同步不可用（导入随时可用）'),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),

          if (_msg.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_msg,
                style: TextStyle(
                    fontSize: 12,
                    color: _msgBad ? cs.error : cs.primary,
                    height: 1.5)),
          ],

          // ── 自担责任开关 ──
          if (atMobile) ...[
            const SizedBox(height: 20),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: FreeRegistry.selfResponsibility,
              title: Text(tr('允许运行我导入的、授权不明的源'),
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                tr('这些源的内容来源与授权由你自行确认。打开后它们才会出现在搜索里；'
                    '应用不为这些源的内容负责，也不会随安装包分发。'),
                style: TextStyle(
                    fontSize: 11, height: 1.5, color: cs.onSurfaceVariant),
              ),
              onChanged: (v) async {
                await FreeRegistry.setSelfResponsibility(v);
                if (mounted) setState(() {});
              },
            ),
          ],

          // ── 列表 ──
          if (mineAll.isNotEmpty) ...[
            _groupTitle(cs, tr('我导入的'), mineAll.length),
            ...mineAll.map((s) => _row(s, canDelete: true)),
            if (mine.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  tr('其中 {n} 个源授权不明，需打开上面的开关才会生效')
                      .replaceAll('{n}', '${mine.length}'),
                  style: TextStyle(fontSize: 11, color: cs.tertiary),
                ),
              ),
          ],
          if (adm.isNotEmpty) ...[
            _groupTitle(cs, tr('管理员同步'), adm.length),
            ...adm.map((s) => _row(s, canDelete: true)),
          ],
          _groupTitle(cs, tr('内置（随安装包）'), builtin.length),
          ...builtin.map((s) => _row(s, canDelete: false)),
        ],
      ),
    );
  }

  Widget _stat(ColorScheme cs, String n, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(children: [
            Text(n,
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: cs.primary)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ]),
        ),
      );

  Widget _groupTitle(ColorScheme cs, String t, int n) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Row(children: [
          Text(t,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant)),
          const SizedBox(width: 6),
          Text('$n', style: TextStyle(fontSize: 12, color: cs.primary)),
        ]),
      );

  Widget _row(FreeSource s, {required bool canDelete}) {
    final cs = Theme.of(context).colorScheme;
    final clean = s.license.mobileSafe;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Row(children: [
        Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: (clean ? cs.primary : cs.tertiary).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(tr(s.license.i18nKey),
              style: TextStyle(
                  fontSize: 10,
                  color: clean ? cs.primary : cs.tertiary)),
        ),
      ]),
      subtitle: Text(
        s.note.isEmpty ? s.id : '${s.id} · ${s.note}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
      trailing: canDelete
          ? IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => _remove(s),
            )
          : Icon(Icons.lock_outline, size: 16, color: cs.outline),
    );
  }
}
