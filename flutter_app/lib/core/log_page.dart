// 日志 / 诊断中心（2026-10-17 重做）
//
// ★用户原话：「不要让我老是让我自己来发现 bug，太累了」
//            「不管怎么样都把它的 UI 做得好看一点，功能做得真实并且有用一点」
//
// 所以这版不是"日志列表"，而是**体检台**：
//   ① 顶部健康卡（密钥 / 资料库 / 桌面端 / 日志占用）—— 一眼看出哪块不对劲
//   ② **一键自检**：真的去读密钥库、探资料库、探桌面端，把问题列出来
//   ③ **问题区置顶**：不用翻日志也能知道该修什么
//   ④ 日志区保留（模块筛选 + 搜索 + 错误高亮），作为"细节证据"
//
// 设计语言沿用从 Kimi 拿到的 token：圆角 12~14、留白足、一行一个信息。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'agent_dsh_client.dart';
import 'ai.dart';
import 'api_keys_store.dart';
import 'app_log.dart';
import 'engine_direct.dart';
import 'haptic.dart';

/// 一条体检结论。
class HealthItem {
  const HealthItem(this.icon, this.label, this.value, this.state, {this.detail});
  final IconData icon;
  final String label;
  final String value;
  final HealthState state;
  final String? detail;
}

enum HealthState { ok, warn, bad, unknown }

class LogCenterPage extends StatefulWidget {
  const LogCenterPage({super.key});
  @override
  State<LogCenterPage> createState() => _Lc();
}

class _Lc extends State<LogCenterPage> {
  List<Map<String, dynamic>> _all = [];
  List<Map<String, dynamic>> _shown = [];
  String _cat = 'all';
  String _q = '';
  bool _busy = false;
  List<HealthItem> _health = [];
  List<String> _issues = [];
  int _logBytes = 0;

  final _qCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _boot();
    AppLog.onChange.listen((_) => _load());
  }

  @override
  void dispose() {
    _qCtl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _load();
    await _probeHealth();
  }

  Future<void> _load() async {
    final l = await AppLog.all();
    int bytes = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final name in ['th_logs.jsonl', 'th_log.jsonl', 'logs.jsonl']) {
        final f = File('${dir.path}/$name');
        if (await f.exists()) {
          bytes = await f.length();
          break;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _all = l;
      _logBytes = bytes;
      _applyFilter();
    });
  }

  void _applyFilter() {
    var l = _all;
    if (_cat == 'error') {
      l = l.where((e) => e['lv'] == 'error' || e['cat'] == 'error').toList();
    } else if (_cat == 'warn') {
      l = l.where((e) => e['lv'] == 'warn').toList();
    } else if (_cat != 'all') {
      l = l.where((e) => e['cat'] == _cat).toList();
    }
    final q = _q.trim().toLowerCase();
    if (q.isNotEmpty) {
      l = l.where((e) => '${e['msg'] ?? ''}'.toLowerCase().contains(q)).toList();
    }
    _shown = l.reversed.toList(); // 新→旧
  }

  // ── 体检：真的去查四件事 ──
  Future<void> _probeHealth() async {
    final items = <HealthItem>[];
    final issues = <String>[];

    // ① 模型密钥
    try {
      final provs = AiRegistry.providers;
      var have = 0;
      final missing = <String>[];
      for (final p in provs) {
        final k = await ApiKeys.get(p.id);
        if (k.trim().isEmpty) {
          missing.add(p.name);
        } else {
          have++;
        }
      }
      final none = have == 0;
      items.add(HealthItem(
        Icons.vpn_key_outlined,
        '模型密钥',
        none ? '一个都没配' : '$have / ${provs.length} 已配',
        none ? HealthState.bad : (missing.isEmpty ? HealthState.ok : HealthState.warn),
        detail: missing.isEmpty
            ? null
            : '未配置：${missing.take(4).join('、')}${missing.length > 4 ? ' 等' : ''}',
      ));
      if (none) {
        issues.add('所有 AI 厂商的密钥都没配 —— AI 对话会直接失败。去「我的 → 模型与密钥」填一个。');
      } else if (missing.isNotEmpty) {
        issues.add('${missing.length} 个厂商还没配密钥（不影响已配的那些）。');
      }
    } catch (_) {
      items.add(const HealthItem(Icons.vpn_key_outlined, '模型密钥', '读取失败', HealthState.unknown));
    }

    // ② 资料库（引擎）
    try {
      final conn = EngineDirect.connected;
      items.add(HealthItem(
        Icons.dns_outlined,
        '资料库',
        conn ? '${EngineDirect.name} 在线' : '未连接',
        conn ? HealthState.ok : HealthState.bad,
        detail: conn ? 'v${EngineDirect.version}' : null,
      ));
      if (!conn) {
        issues.add('资料库（引擎应用）没连上 —— 搜索和发现页会没有内容。确认手机上资料库应用已打开。');
      }
    } catch (_) {
      items.add(const HealthItem(Icons.dns_outlined, '资料库', '状态未知', HealthState.unknown));
    }

    // ③ 桌面端
    try {
      final on = AgentDshClient.configured;
      items.add(HealthItem(
        Icons.computer_outlined,
        '桌面端',
        on ? '已绑定' : '未绑定',
        on ? HealthState.ok : HealthState.warn,
        detail: on ? AgentDshClient.base : '可选，不影响本地功能',
      ));
      if (!on) issues.add('桌面端未绑定（可选）：绑定后可用电脑上的 DSH 跑长任务、同步数据。');
    } catch (_) {
      items.add(const HealthItem(Icons.computer_outlined, '桌面端', '状态未知', HealthState.unknown));
    }

    // ④ 日志占用
    final mb = _logBytes / 1048576;
    items.add(HealthItem(
      Icons.storage_outlined,
      '日志占用',
      mb < 0.1 ? '${(_logBytes / 1024).toStringAsFixed(0)} KB' : '${mb.toStringAsFixed(1)} MB',
      mb > 8 ? HealthState.warn : HealthState.ok,
      detail: mb > 8 ? '偏大，可在下方调低保留条数' : null,
    ));
    if (mb > 8) issues.add('日志占用偏大（${mb.toStringAsFixed(1)}MB），建议调低保留上限或清理。');

    // ⑤ 近期错误计数
    final errN = _all.where((e) => e['lv'] == 'error').length;
    if (errN > 0) issues.add('日志里有 $errN 条错误 —— 下方「运行日志」可看原文（错误已置顶高亮）。');

    if (!mounted) return;
    setState(() {
      _health = items;
      _issues = issues;
      _busy = false;
    });
  }

  Future<void> _selfCheck() async {
    setState(() => _busy = true);
    Haptic.tap();
    await _load();
    await _probeHealth();
  }

  Future<void> _export() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      File? src;
      for (final name in ['th_logs.jsonl', 'th_log.jsonl', 'logs.jsonl']) {
        final f = File('${dir.path}/$name');
        if (await f.exists()) {
          src = f;
          break;
        }
      }
      if (src == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还没有日志文件')));
        }
        return;
      }
      // 导出带环境头 —— 排查时最有用的是"什么版本、什么平台、当时健康状态"
      final tmp = File('${dir.path}/th_diag_export.txt');
      final head = '# ThirdHub 诊断导出\n'
          '# 时间: ${DateTime.now()}\n'
          '# 平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
          '# 资料库: ${EngineDirect.connected ? "${EngineDirect.name} v${EngineDirect.version}" : "未连接"}\n'
          '# 桌面端: ${AgentDshClient.configured ? AgentDshClient.base : "未绑定"}\n'
          '# 体检: ${_health.map((h) => "${h.label}=${h.value}").join(" | ")}\n'
          '# 问题: ${_issues.isEmpty ? "无" : _issues.join(" / ")}\n\n';
      await tmp.writeAsString(head + await src.readAsString());
      await Share.shareXFiles([XFile(tmp.path)], text: 'ThirdHub 诊断日志');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  Color _stateColor(HealthState s, ColorScheme cs) => switch (s) {
        HealthState.ok => const Color(0xFF16A34A),
        HealthState.warn => const Color(0xFFF59E0B),
        HealthState.bad => const Color(0xFFDC2626),
        HealthState.unknown => cs.onSurface.withValues(alpha: 0.4),
      };

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    final dark = Theme.of(c).brightness == Brightness.dark;
    final errN = _all.where((e) => e['lv'] == 'error').length;
    final warnN = _all.where((e) => e['lv'] == 'warn').length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断中心'),
        actions: [
          IconButton(
            tooltip: '导出日志',
            icon: const Icon(Icons.ios_share, size: 20),
            onPressed: _export,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _selfCheck,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
          children: [
            // ══ ① 健康总览 ══
            _sectionTitle(cs, '体检结果',
                trailing: _busy
                    ? const SizedBox(
                        width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _selfCheck,
                        icon: const Icon(Icons.refresh, size: 15),
                        label: const Text('重新自检', style: TextStyle(fontSize: 12)),
                      )),
            if (_health.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF1B1E27) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: dark ? Colors.white10 : const Color(0xFFEBE8F2), width: 0.6),
                ),
                child: Column(children: [
                  for (var i = 0; i < _health.length; i++) ...[
                    if (i > 0)
                      Divider(height: 1, color: dark ? Colors.white10 : const Color(0xFFF0EDF6)),
                    _healthRow(cs, _health[i]),
                  ],
                ]),
              ),

            // ══ ② 问题区 ══
            if (_issues.isNotEmpty) ...[
              const SizedBox(height: 16),
              _sectionTitle(cs, '需要你注意（${_issues.length}）'),
              for (final s in _issues)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.25), width: 0.6),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.lightbulb_outline, size: 16, color: Color(0xFFB45309)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(s, style: const TextStyle(fontSize: 12.5, height: 1.55)),
                    ),
                  ]),
                ),
            ],

            // ══ ③ 日志筛选 ══
            const SizedBox(height: 14),
            _sectionTitle(cs, '运行日志',
                trailing: Text('${_all.length} 条 · 错误 $errN · 警告 $warnN',
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.45)))),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _qCtl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索日志内容…',
                  hintStyle:
                      TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.35)),
                  prefixIcon: const Icon(Icons.search, size: 17),
                  isDense: true,
                  filled: true,
                  fillColor:
                      dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF6F5FA),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(11), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onChanged: (v) => setState(() {
                  _q = v;
                  _applyFilter();
                }),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final e in <List<String>>[
                  ['all', '全部'],
                  ['error', '仅错误'],
                  ['warn', '仅警告'],
                  for (final x in AppLog.cats.entries) [x.key, x.value],
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(e[1], style: const TextStyle(fontSize: 11.5)),
                      selected: _cat == e[0],
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() {
                        _cat = e[0];
                        _applyFilter();
                      }),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),

            // ══ ④ 日志列表 ══
            if (_shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Column(children: [
                    Icon(Icons.check_circle_outline,
                        size: 34, color: cs.onSurface.withValues(alpha: 0.2)),
                    const SizedBox(height: 8),
                    Text(_all.isEmpty ? '还没有日志' : '当前筛选下没有记录',
                        style: TextStyle(
                            fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.5))),
                  ]),
                ),
              )
            else
              ..._shown.take(300).map((e) => _logTile(cs, dark, e)),

            // ══ ⑤ 保留策略 ══
            const SizedBox(height: 18),
            _sectionTitle(cs, '日志保留'),
            _limitRow(cs, dark),
          ],
        ),
      ),
    );
  }

  Widget _healthRow(ColorScheme cs, HealthItem h) {
    final col = _stateColor(h.state, cs);
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 11, 12, 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: col.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(h.icon, size: 16, color: col),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(h.label,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: col.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(h.value,
                    style: TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w700, color: col)),
              ),
            ]),
            if (h.detail != null && h.detail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(h.detail!,
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.5))),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _logTile(ColorScheme cs, bool dark, Map<String, dynamic> e) {
    final lv = '${e['lv'] ?? 'info'}';
    final col = lv == 'error'
        ? const Color(0xFFDC2626)
        : (lv == 'warn' ? const Color(0xFFF59E0B) : cs.onSurface.withValues(alpha: 0.55));
    final cat = '${e['cat'] ?? ''}';
    final catName = AppLog.cats[cat] ?? cat;
    final ts = '${e['t'] ?? ''}';
    final time = ts.length >= 19 ? ts.substring(11, 19) : ts;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: lv == 'error'
            ? const Color(0xFFDC2626).withValues(alpha: 0.05)
            : (dark ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFFAF9FC)),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: lv == 'error'
                ? const Color(0xFFDC2626).withValues(alpha: 0.2)
                : Colors.transparent,
            width: 0.6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(time, style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4))),
          const SizedBox(width: 6),
          if (catName.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(catName,
                  style: TextStyle(
                      fontSize: 9.5, color: cs.primary, fontWeight: FontWeight.w600)),
            ),
          const Spacer(),
          if (lv != 'info')
            Text(lv.toUpperCase(),
                style: TextStyle(fontSize: 9, color: col, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 3),
        Text('${e['msg'] ?? ''}',
            style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: lv == 'error' ? col : cs.onSurface.withValues(alpha: 0.85))),
      ]),
    );
  }

  Widget _sectionTitle(ColorScheme cs, String t, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8, left: 2),
        child: Row(children: [
          Text(t,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface.withValues(alpha: 0.6))),
          const Spacer(),
          if (trailing != null) trailing,
        ]),
      );

  Widget _limitRow(ColorScheme cs, bool dark) => FutureBuilder<int>(
        future: AppLog.limit(),
        builder: (c2, s) {
          final cur = (s.data ?? 1000);
          final val = [500, 1000, 2000, 5000].contains(cur) ? cur : 1000;
          return Container(
            padding: const EdgeInsets.fromLTRB(13, 4, 8, 4),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1B1E27) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: dark ? Colors.white10 : const Color(0xFFEBE8F2), width: 0.6),
            ),
            child: Row(children: [
              const Text('最多保留', style: TextStyle(fontSize: 13)),
              const Spacer(),
              DropdownButton<int>(
                value: val,
                underline: const SizedBox.shrink(),
                style: TextStyle(fontSize: 12.5, color: cs.onSurface),
                items: const [
                  DropdownMenuItem(value: 500, child: Text('500 条')),
                  DropdownMenuItem(value: 1000, child: Text('1000 条')),
                  DropdownMenuItem(value: 2000, child: Text('2000 条')),
                  DropdownMenuItem(value: 5000, child: Text('5000 条')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await AppLog.setLimit(v);
                  Haptic.tap();
                  if (mounted) setState(() {});
                },
              ),
            ]),
          );
        },
      );
}
