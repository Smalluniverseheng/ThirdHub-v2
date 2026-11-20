// 更新公告页（4.81.72）
//
// 为什么单独做一页：以前公告只在模块里弹一次，用户想看找不到。
// 现在从「我的 → 更新公告」随时可看，且和「检查更新」放在一起。
//
// 数据：Supabase th_announce（active=true，倒序）。
// 带「注册 / 重建账号 / 账号」字样的公告，卡片底部给一个直达按钮（去登录注册页）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'cloud.dart';
import 'design_tokens.dart';
import 'i18n.dart';

class AnnouncePage extends StatefulWidget {
  /// 账号/登录页的构造器（由 main.dart 注入，避免循环 import）
  final Widget Function(BuildContext)? accountBuilder;
  const AnnouncePage({super.key, this.accountBuilder});

  @override
  State<AnnouncePage> createState() => _AnnouncePageState();
}

class _AnnouncePageState extends State<AnnouncePage> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    try {
      final url = Cloud.base +
          '/rest/v1/th_announce?select=id,title,body,kind,created_at' +
          '&active=eq.true&order=created_at.desc&limit=40';
      final r = await http.get(Uri.parse(url), headers: {
        'apikey': Cloud.anonKey,
        'Authorization': 'Bearer ${Cloud.anonKey}',
      }).timeout(const Duration(seconds: 15));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final list = (j is List) ? j : const [];
      if (!mounted) return;
      setState(() {
        _items = list
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('更新公告'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 120),
                    Center(
                        child: Text(_err.isEmpty ? tr('暂无公告') : _err,
                            style: TextStyle(fontSize: 13, color: cs.outline))),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(Gap.md),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                    itemBuilder: (c, i) => _AnnounceCard(
        item: _items[i], accountBuilder: widget.accountBuilder),
                  ),
      ),
    );
  }
}

class _AnnounceCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final Widget Function(BuildContext)? accountBuilder;

  const _AnnounceCard({required this.item, this.accountBuilder});

  @override
  State<_AnnounceCard> createState() => _AnnounceCardState();
}

class _AnnounceCardState extends State<_AnnounceCard> {
  bool _open = false;

  String _when(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      final mm = d.month.toString().padLeft(2, '0');
      final dd = d.day.toString().padLeft(2, '0');
      final hh = d.hour.toString().padLeft(2, '0');
      final mi = d.minute.toString().padLeft(2, '0');
      return '${d.year}-$mm-$dd $hh:$mi';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = '${widget.item['title'] ?? ''}';
    final body = '${widget.item['body'] ?? ''}';
    final needsAccount =
        body.contains('注册') || body.contains('重建账号') || body.contains('账号');
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
              Text(_when('${widget.item['created_at'] ?? ''}'),
                  style: TextStyle(fontSize: 10.5, color: cs.outline)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            maxLines: _open ? null : 3,
            overflow: _open ? null : TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.55),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _open = !_open),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero),
                child: Text(_open ? tr('收起') : tr('展开全文'),
                    style: const TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              if (needsAccount)
                FilledButton.tonal(
                  onPressed: () {
                    final b = widget.accountBuilder;
                    if (b != null) {
                      Navigator.of(context)
                          .push(MaterialPageRoute(builder: (c) => b(c)));
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                  style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20))),
                  child: Text(tr('去登录 / 注册'),
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
