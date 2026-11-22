// 「桌面引擎」页：配对 + 取货。
//
// 这一页存在的意义，是把「合规边界」做成用户能看见、能操作的东西：
// 手机端只负责**收货**，抓取与转格式发生在桌面端。页面上把这句话写清楚，
// 比藏在服务条款第 N 条里更负责，也更符合上架审核对「内容来源可追溯」的要求。
import 'package:flutter/material.dart';

import '../i18n.dart';
import 'desktop_handoff.dart';

class DesktopEnginePage extends StatefulWidget {
  const DesktopEnginePage({super.key});

  @override
  State<DesktopEnginePage> createState() => _DesktopEnginePageState();
}

class _DesktopEnginePageState extends State<DesktopEnginePage> {
  final _url = TextEditingController();
  final _token = TextEditingController();

  bool _booting = true;
  bool _busy = false;
  String? _err;
  String _hint = '';
  Map<String, dynamic>? _health;
  List<Map<String, dynamic>> _lib = const [];
  List<Map<String, dynamic>> _tasks = const [];

  /// 正在接收的成品 id → 进度（0..1，未知总量时为 -1）。
  final Map<String, double> _rx = {};

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final u = await Handoff.url();
    final t = await Handoff.token();
    if (!mounted) return;
    setState(() {
      _url.text = u;
      _token.text = t;
      _booting = false;
    });
    if (u.isNotEmpty && t.isNotEmpty) await _refresh();
  }

  void _fail(Object e) {
    if (!mounted) return;
    if (e is HandoffException) {
      setState(() {
        _err = e.message;
        _hint = e.hint;
      });
    } else {
      setState(() {
        _err = '$e';
        _hint = '';
      });
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _err = null;
      _hint = '';
    });
    try {
      final h = await Handoff.health();
      final lib = await Handoff.lib();
      final tasks = await Handoff.tasks();
      if (!mounted) return;
      setState(() {
        _health = h;
        _lib = lib;
        _tasks = tasks;
      });
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pair() async {
    final rawUrl = _url.text.trim();
    if (rawUrl.isEmpty) {
      setState(() {
        _err = tr('请先填地址');
        _hint = tr('形如 192.168.1.10 或 http://192.168.1.10:8421');
      });
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
      _hint = '';
    });
    try {
      final h = await Handoff.health(
          urlText: rawUrl, tokenText: _token.text.trim());
      if (!mounted) return;
      setState(() {
        _health = h;
        _url.text = Handoff.normalizeUrl(rawUrl);
      });
      await _refresh();
    } catch (e) {
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receive(Map<String, dynamic> item) async {
    final id = '${item['id'] ?? ''}';
    if (id.isEmpty || _rx.containsKey(id)) return;
    setState(() => _rx[id] = -1);
    try {
      await Handoff.receive(item, onProgress: (got, total) {
        if (!mounted) return;
        setState(() => _rx[id] = total > 0 ? got / total : -1);
      });
      if (!mounted) return;
      setState(() => _rx.remove(id));
      _toast(trf('已存入本地库：{n}', {'n': '${item['title'] ?? ''}'}));
    } catch (e) {
      if (!mounted) return;
      setState(() => _rx.remove(id));
      _fail(e);
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final id = '${item['id'] ?? ''}';
    if (id.isEmpty) return;
    try {
      await Handoff.remove(id);
      await _refresh();
      _toast(tr('已从桌面端删除'));
    } catch (e) {
      _fail(e);
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 3)));
  }

  // ── UI ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('桌面引擎')),
        actions: [
          IconButton(
            tooltip: tr('刷新'),
            onPressed: _busy ? null : _refresh,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _booting
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(14, 10, 14, 28),
              children: [
                _boundaryCard(cs),
                const SizedBox(height: 12),
                _pairCard(cs),
                if (_err != null) ...[
                  const SizedBox(height: 12),
                  _errorCard(cs),
                ],
                if (_health != null) ...[
                  const SizedBox(height: 12),
                  _statusCard(cs),
                  const SizedBox(height: 12),
                  _libCard(cs),
                  if (_tasks.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _taskCard(cs),
                  ],
                ],
                const SizedBox(height: 18),
                _helpCard(cs),
              ],
            ),
    );
  }

  Widget _card({required Widget child, Color? bg, Color? border}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: border == null ? null : Border.all(color: border),
        ),
        child: child,
      );

  Widget _title(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      );

  /// 合规边界说明。放在最上面，因为它决定了下面每一个按钮能不能用。
  Widget _boundaryCard(ColorScheme cs) => _card(
        bg: cs.primary.withValues(alpha: 0.06),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.shield_outlined, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(tr('它是什么、不是什么'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            Text(
              tr('桌面端负责抓取与转格式，本机只负责接收成品。收到的文件会存成本地文件，'
                  '之后不连桌面端也能打开。'),
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 6),
            Text(
              tr('本机不含抓取代码，也不会上传你的任何文件。'),
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
            ),
          ],
        ),
      );

  Widget _pairCard(ColorScheme cs) => _card(
        border: cs.outlineVariant.withValues(alpha: 0.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(tr('连接桌面引擎')),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                isDense: true,
                labelText: tr('地址'),
                hintText: '192.168.1.10',
                prefixIcon: const Icon(Icons.lan_outlined, size: 18),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _token,
              autocorrect: false,
              obscureText: true,
              decoration: InputDecoration(
                isDense: true,
                labelText: tr('访问令牌'),
                hintText: tr('桌面端 data/token 里的那串'),
                prefixIcon: const Icon(Icons.key_outlined, size: 18),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _pair,
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(tr('连接并保存')),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  await Handoff.unpair();
                  if (!mounted) return;
                  setState(() {
                    _health = null;
                    _lib = const [];
                    _tasks = const [];
                    _err = null;
                  });
                  _toast(tr('已取消配对'));
                },
                child: Text(tr('取消配对')),
              ),
            ]),
          ],
        ),
      );

  Widget _errorCard(ColorScheme cs) => _card(
        bg: cs.errorContainer.withValues(alpha: 0.35),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_err ?? '', style: const TextStyle(fontSize: 12.5)),
                if (_hint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_hint,
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade700)),
                  ),
              ],
            ),
          ),
        ]),
      );

  Widget _statusCard(ColorScheme cs) {
    final h = _health ?? const {};
    final name = '${h['name'] ?? ''}';
    final ver = '${h['version'] ?? ''}';
    final libCount = h['libCount'] ?? 0;
    final q = h['queue'] ?? 0;
    final busy = h['busy'] == true;
    return _card(
      border: cs.outlineVariant.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.check_circle, size: 15, color: Colors.green.shade600),
            const SizedBox(width: 6),
            Expanded(
              child: Text('$name · v$ver',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _pill(trf('成品 {n}', {'n': libCount}), cs),
            _pill(busy ? trf('队列 {n} · 正在处理', {'n': q}) : tr('空闲'), cs),
            _pill('${h['formats'] is List ? (h['formats'] as List).join(' / ') : tr('标准格式')}',
                cs),
          ]),
        ],
      ),
    );
  }

  Widget _pill(String s, ColorScheme cs) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(s, style: const TextStyle(fontSize: 11)),
      );

  Widget _libCard(ColorScheme cs) => _card(
        border: cs.outlineVariant.withValues(alpha: 0.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(tr('成品库')),
            if (_lib.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  tr('还没有成品。在桌面端下单，转好之后会出现在这里。'),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            for (final it in _lib) _libRow(it, cs),
          ],
        ),
      );

  Widget _libRow(Map<String, dynamic> it, ColorScheme cs) {
    final id = '${it['id'] ?? ''}';
    final p = _rx[id];
    final receiving = p != null;
    final title = '${it['title'] ?? ''}';
    final fmt = '${it['format'] ?? ''}';
    final bytes = (it['bytes'] as num?)?.toInt() ?? 0;
    final kind = Handoff.localKind('${it['kind'] ?? ''}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(_kindIcon(kind), size: 18, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              Text('$fmt · ${Handoff.sizeText(bytes)}',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600)),
              if (receiving)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 8),
                  child: LinearProgressIndicator(
                    value: p >= 0 ? p : null,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: tr('接收'),
          onPressed: receiving ? null : () => _receive(it),
          icon: receiving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download_outlined, size: 20),
        ),
        IconButton(
          tooltip: tr('删除'),
          onPressed: receiving ? null : () => _delete(it),
          icon: Icon(Icons.delete_outline,
              size: 19, color: Colors.grey.shade500),
        ),
      ]),
    );
  }

  IconData _kindIcon(String localKind) {
    switch (localKind) {
      case 'comic':
        return Icons.auto_stories_outlined;
      case 'music':
        return Icons.music_note_outlined;
      case 'video':
        return Icons.play_circle_outline;
      default:
        return Icons.menu_book_outlined;
    }
  }

  Widget _taskCard(ColorScheme cs) => _card(
        border: cs.outlineVariant.withValues(alpha: 0.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(tr('任务进度')),
            for (final t in _tasks.take(8)) _taskRow(t, cs),
          ],
        ),
      );

  Widget _taskRow(Map<String, dynamic> t, ColorScheme cs) {
    final state = '${t['state'] ?? ''}';
    final done = (t['done'] as num?)?.toInt() ?? 0;
    final total = (t['total'] as num?)?.toInt() ?? 0;
    final failed = state == 'failed';
    final finished = state == 'done';
    final color = failed
        ? cs.error
        : finished
            ? Colors.green.shade600
            : cs.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
                failed
                    ? Icons.error_outline
                    : finished
                        ? Icons.task_alt
                        : Icons.downloading,
                size: 15,
                color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${t['title'] ?? ''}',
                  style: const TextStyle(fontSize: 12.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            Text(total > 0 ? '$done / $total' : state,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ]),
          if (failed && '${t['error'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 2),
              child: Text('${t['error']}',
                  style: TextStyle(fontSize: 11, color: cs.error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            )
          else if (!finished && total > 0)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 4, right: 4),
              child: LinearProgressIndicator(
                value: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }

  Widget _helpCard(ColorScheme cs) => _card(
        bg: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('怎么起一个桌面引擎'),
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SelectableText(
              'docker compose up -d\ncat ./data/token',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                fontFamily: 'monospace',
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tr('把上面两行跑一遍，令牌填到上面两个框里就行。桌面端建议只开在局域网，'
                  '跨网段请走 WireGuard 之类的内网穿透，不要直接把端口映射到公网。'),
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.55,
                  color: Colors.grey.shade700),
            ),
          ],
        ),
      );
}
