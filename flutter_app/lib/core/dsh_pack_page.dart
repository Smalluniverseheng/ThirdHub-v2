// 「AI 完全体数据包」管理页（4.81.97）
//
// 一句话给用户：AI 有两种跑法，连家里的服务（省手机资源），或把完全体装到
// 手机上（断网也能用，随时可以拆）。这一页就是那个开关 + 数据包的家。
import 'package:flutter/material.dart';

import 'dsh_keepalive.dart';
import 'dsh_pack.dart';
import 'i18n.dart';

class DshPackPage extends StatefulWidget {
  const DshPackPage({super.key});

  @override
  State<DshPackPage> createState() => _DshPackPageState();
}

class _DshPackPageState extends State<DshPackPage> {
  DshPackInfo? _remote;
  bool _busy = false;
  /// 是否已在系统电池优化白名单里（国产 ROM 上这个比前台服务还关键）
  bool _exempt = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await DshPack.I.load();
    final r = await DshPack.I.remote();
    final ex = await DshKeepAlive.batteryExempt();
    if (!mounted) return;
    setState(() {
      _remote = r;
      _exempt = ex;
    });
  }

  String get _sizeText {
    final b = DshPack.I.installedBytes > 0
        ? DshPack.I.installedBytes
        : (_remote?.size ?? 0);
    if (b <= 0) return '';
    return '${(b / 1048576).toStringAsFixed(1)} MB';
  }

  Future<void> _install() async {
    // 首次下载是 170MB 量级，先让用户知道自己在下载什么、会占多少地方
    if (DshPack.I.state == DshPackState.none) {
      final size = _sizeText;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('下载数据包')),
          content: Text(
            '${size.isEmpty ? '' : '$size\n'}${tr('装到手机后断网也能用，随时可以拆掉。')}',
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('取消'))),
            TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('下载数据包'))),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    setState(() => _busy = true);
    final ok = await DshPack.I.install(onTick: () {
      if (mounted) setState(() {});
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(DshPack.I.message.isEmpty ? tr('失败') : DshPack.I.message)),
      );
    }
  }

  Future<void> _remove() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(tr('拆除后要重新下载才能用本机运行，确定拆除？')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('取消'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('拆除数据包'))),
        ],
      ),
    );
    if (yes != true) return;
    await DshPack.I.remove();
    if (mounted) setState(() {});
  }

  Future<void> _toggleLocal(bool v) async {
    await DshPack.I.setEnabled(v);
    if (!mounted) return;
    setState(() {});
    if (v) {
      final ok = await DshPack.I.start();
      if (!mounted) return;
      setState(() {});
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(DshPack.I.message)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = DshPack.I;
    final st = p.state;
    final ready = st == DshPackState.ready;
    final noRt = st == DshPackState.noRuntime;
    final has = ready || noRt;

    final (String title, String desc, IconData icon, Color color) = switch (st) {
      DshPackState.ready => (
          tr('已装好，可以本机运行'),
          tr('断网也能用，AI 完全跑在这台手机上'),
          Icons.check_circle_outline,
          Colors.green,
        ),
      DshPackState.noRuntime => (
          tr('已装好数据包'),
          '这版安装包还没带本机运行组件，暂时请继续用家里服务。',
          Icons.info_outline,
          Colors.orange,
        ),
      DshPackState.downloading || DshPackState.unpacking => (
          st == DshPackState.downloading ? tr('正在下载') : tr('正在解压'),
          p.progressText,
          Icons.downloading,
          cs.primary,
        ),
      DshPackState.error => (tr('失败'), p.message, Icons.error_outline, cs.error),
      DshPackState.none => (
          tr('数据包未安装'),
          tr('装到手机后断网也能用，随时可以拆掉。'),
          Icons.cloud_download_outlined,
          cs.outline,
        ),
    };

    return Scaffold(
      appBar: AppBar(title: Text(tr('AI 完全体数据包'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 20, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    if (has && _sizeText.isNotEmpty)
                      Text(_sizeText,
                          style: TextStyle(fontSize: 12, color: cs.outline)),
                  ],
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(desc,
                      style: TextStyle(fontSize: 12, color: cs.outline, height: 1.5)),
                ],
                if (st == DshPackState.downloading ||
                    st == DshPackState.unpacking) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: st == DshPackState.unpacking ? null : p.progress,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 运行位置
          if (ready)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: p.enabled,
              onChanged: _toggleLocal,
              title: Text(tr('本机运行')),
              subtitle: Text(
                '${tr('关掉就回到连家里服务，数据包留在手机上不占额外流量')}',
                style: const TextStyle(fontSize: 11),
              ),
            ),

          // 后台保活：用户切出去以后系统会冻结/回收进程，本机运行会断。
          // 前台服务已经常驻了；这一条是国产 ROM 的那层「省电策略」，不引导用户
          // 加白就还是会被杀（MIUI/EMUI/ColorOS 都不认官方前台服务语义）。
          if (ready && p.enabled && !_exempt)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.battery_saver, size: 20),
              title: Text(tr('允许后台运行'), style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                tr('系统省电会杀掉本机运行，允许后切出去才不会断'),
                style: const TextStyle(fontSize: 11),
              ),
              trailing: FilledButton.tonal(
                onPressed: () async {
                  await DshKeepAlive.requestBatteryExempt();
                  // 系统对话框是异步的，回来重新查一次真实状态
                  final ex = await DshKeepAlive.batteryExempt();
                  if (mounted) setState(() => _exempt = ex);
                },
                child: Text(tr('去允许')),
              ),
            ),

          const SizedBox(height: 8),
          Row(
            children: [
              if (!has)
                FilledButton.icon(
                  onPressed: _busy || _remote == null ? null : _install,
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(_remote == null ? tr('暂无数据包') : tr('下载数据包')),
                ),
              if (has) ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _install,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(tr('重新下载')),
                ),
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: _busy ? null : _remove,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(tr('拆除数据包')),
                ),
              ],
            ],
          ),

          const SizedBox(height: 24),
          Text(tr('说明'),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.outline)),
          const SizedBox(height: 8),
          Text(tr('连家里服务：手机只当屏幕，算力在家里那台机器上，最省手机资源，速度也最快。'),
              style: TextStyle(fontSize: 12, color: cs.outline, height: 1.7)),
          const SizedBox(height: 6),
          Text(tr('本机运行：完全体装在这台手机里，不连家里也能用，拆掉数据包就恢复成连服务。'),
              style: TextStyle(fontSize: 12, color: cs.outline, height: 1.7)),
          const SizedBox(height: 6),
          Text(tr('数据包与软件本体分开存，软件更新不会把数据包弄丢。'),
              style: TextStyle(fontSize: 12, color: cs.outline, height: 1.7)),
        ],
      ),
    );
  }
}
