// 稍后再看（4.81.104）
//
// 之前在视频页只能"加入稍后再看"，加完却没有地方看 —— 列表只存在 prefs 里，
// 用户点完就找不到了。这一页把那份本机清单读出来，点开就播。
//
// 刻意不做成"B站账号的稍后再看"：那个接口要会员态 + cookie 风控，
// 本机清单反而更稳（不登录也能用，和普通版的定位一致）。
import 'dart:async';

import 'package:flutter/material.dart';

import 'bili_actions.dart';
import 'bili_module_page.dart' show BiliCtx, biliCover, biliGet;
import 'bili_video_page.dart' show BiliVideoPage;
import 'design_tokens.dart';
import 'i18n.dart';

class BiliLaterPage extends StatefulWidget {
  const BiliLaterPage({super.key, required this.ctx});
  final BiliCtx ctx;

  @override
  State<BiliLaterPage> createState() => _BiliLaterPageState();
}

class _BiliLaterPageState extends State<BiliLaterPage> {
  bool _loading = true;
  String _err = '';
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bvids = await BiliActions.I.watchLater();
    if (!mounted) return;
    if (bvids.isEmpty) {
      setState(() {
        _loading = false;
        _items = const [];
        _err = '';
      });
      return;
    }
    final out = <Map<String, dynamic>>[];
    var failed = 0;
    for (final b in bvids) {
      final j = await biliGet(
          widget.ctx, '/v1/bili/view?bvid=${Uri.encodeQueryComponent(b)}',
          sec: 15);
      if (!mounted) return;
      if (j != null && j['ok'] == true) {
        out.add(j);
      } else if (j != null) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = out;
      _err = (out.isEmpty && failed > 0) ? tr('加载失败') : '';
    });
  }

  Future<void> _remove(String bvid) async {
    await BiliActions.I.removeWatchLater(bvid);
    if (!mounted) return;
    setState(() => _items =
        _items.where((e) => '${e['bvid'] ?? ''}' != bvid).toList());
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('清空')),
        content: Text(tr('清空后这个列表里的视频就都不在了，随时可以重新加。')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: Text(tr('取消'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: Text(tr('清空'))),
        ],
      ),
    );
    if (ok != true) return;
    for (final e in _items) {
      await BiliActions.I.removeWatchLater('${e['bvid'] ?? ''}');
    }
    if (!mounted) return;
    setState(() => _items = const []);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('稍后再看')),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              tooltip: tr('清空'),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clear,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.watch_later_outlined,
                            size: 44, color: cs.outline),
                        const SizedBox(height: 12),
                        Text(_err.isEmpty ? tr('还没有稍后再看的视频') : _err,
                            style: TextStyle(fontSize: 14, color: cs.outline)),
                        const SizedBox(height: 6),
                        Text(tr('在视频页点一下「稍后再看」，就会出现在这里。'),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: cs.outline)),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => Divider(
                        height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
                    itemBuilder: (c, i) {
                      final v = _items[i];
                      final bvid = '${v['bvid'] ?? ''}';
                      final owner = (v['owner'] as Map?) ?? const {};
                      return ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: Gap.md),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(Radii.sm),
                          child: SizedBox(
                            width: 96,
                            height: 58,
                            child: biliCover(context, widget.ctx,
                                '${v['pic'] ?? ''}',
                                radius: Radii.sm),
                          ),
                        ),
                        title: Text('${v['title'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, height: 1.3)),
                        subtitle: Text('${owner['name'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: cs.outline)),
                        trailing: IconButton(
                          tooltip: tr('移除'),
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => _remove(bvid),
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => BiliVideoPage(
                                  ctx: widget.ctx, item: Map.of(v))),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
