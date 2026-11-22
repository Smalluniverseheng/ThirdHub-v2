// 源状态面板 —— 用户唯一需要看"源到底怎么了"的地方。
//
// ── 为什么单独一页 ──────────────────────────────────────────────────
//   源的健康判定以前是**贴在内容页顶部的一条横幅**：「今日诗词、一言、
//   维基文库、古登堡（澳洲站）当前不可达」—— 用户正在看内容，却被塞了
//   一份诊断报告，而且那份报告跟下面的内容互相打脸。
//
//   正确的分工是：
//     · 内容页只管出内容，坏源静默跳过（core/agg/source_health.dart）；
//     · 想知道"哪个源不通、为什么"，来这一页。
//
//   这一页是**按需查看**的，不是每个人都会进来 —— 所以它可以诚实、详细，
//   包括失败原因和冷却剩余时间。
import 'package:flutter/material.dart';

import '../../core/free/free_center_page.dart' show freeKindName;
import '../free/free_models.dart';
import '../free/free_registry.dart';
import '../i18n.dart';
import 'source_health.dart';

class SourceHealthPage extends StatefulWidget {
  const SourceHealthPage({super.key});

  @override
  State<SourceHealthPage> createState() => _SourceHealthPageState();
}

class _SourceHealthPageState extends State<SourceHealthPage> {
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await FreeRegistry.ensureLoaded();
    if (!mounted) return;
    setState(() => _rows = SourceHealth.snapshot());
  }

  /// 把一个健康记录 id 翻译成用户能认的名字。
  ///
  /// 三类 id 的形态：
  ///   `builtin:comic` —— 包里编进去的源，按板块名显示；
  ///   `backend:comic` / `engine:comic` —— 两条服务器通路；
  ///   其余 —— 用户导入/同步的源，直接显示源名。
  String _labelOf(String id) {
    if (id.startsWith('builtin:')) {
      final k = id.substring(8);
      for (final kind in FreeKind.values) {
        if (kind.name == k) return '${freeKindName(kind)} · ${tr('内置')}';
      }
      return id;
    }
    if (id.startsWith('backend:')) return tr('本地资料库');
    if (id.startsWith('engine:')) return 'THP';
    for (final s in FreeRegistry.allExternal) {
      if (s.id == id) return s.name;
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('源状态')),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(tr('全部重检')),
            onPressed: () async {
              await SourceHealth.reset();
              await _boot();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _boot,
        child: _rows.isEmpty
            ? ListView(children: [
                const SizedBox(height: 100),
                Icon(Icons.checklist_rtl, size: 40, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    tr('还没有搜索过，用一次就会出来'),
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ),
              ])
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
                itemBuilder: (c, i) {
                  final r = _rows[i];
                  final id = '${r['id']}';
                  final cooling = r['cooling'] == true;
                  final fails = (r['fails'] as num?)?.toInt() ?? 0;
                  final count = (r['lastCount'] as num?)?.toInt() ?? 0;
                  final ms = (r['lastMs'] as num?)?.toInt() ?? 0;
                  final reason = '${r['reason'] ?? ''}';

                  // 三种状态，只用一个圆点表达：绿=刚刚成功，橙=冷却中，灰=没记录。
                  final ok = !cooling && fails == 0 && r['lastOk'] != null;
                  final dot = ok
                      ? const Color(0xFF2E9E5B)
                      : cooling
                          ? const Color(0xFFE08A00)
                          : Colors.grey;

                  final sub = cooling
                      ? trf('连续失败，先休息 {n} 分钟',
                          {'n': '${r['cooldownMin'] ?? 0}'})
                      : reason.isNotEmpty
                          ? reason
                          : count > 0
                              ? trf('{n} 条 · {ms} ms', {'n': '$count', 'ms': '$ms'})
                              : tr('应答为空');

                  return ListTile(
                    leading: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                    ),
                    title: Text(_labelOf(id), style: const TextStyle(fontSize: 14)),
                    subtitle: Text(
                      sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                    ),
                    trailing: cooling
                        ? TextButton(
                            onPressed: () async {
                              await SourceHealth.reset(id);
                              await _boot();
                            },
                            child: Text(tr('重试')),
                          )
                        : null,
                  );
                },
              ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: Text(
          tr('连续失败的源会被自动跳过一段时间，不会拖慢搜索；到期会自动放行'),
          style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, height: 1.5),
        ),
      ),
    );
  }
}
