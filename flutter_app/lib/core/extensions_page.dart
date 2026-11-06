// 可安装资源包页面 —— 「我需要才装，不需要就省空间」。
//
// 定位（2026-11-06）：App 本体 32MB 就能看漫画；重资源（本机 AI 运行时 1GB、
// 引擎包 30–45MB）做成按需安装。这里就是那个「可扩展的东西」的入口。
//
// 设计原则：
//   1. **不装也能用** —— 每个包都要说清「不装会怎样」，而不是吓唬用户去装
//   2. **大小写实数** —— 1.0 GB 就写 1.0 GB，不写「约 1GB」
//   3. **没开放的包如实标** —— 「还没做好」比一个点了没反应的按钮诚实

import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'extensions.dart';
import 'i18n.dart';

// 转发出去：调用方只 import 本页面就能同时拿到 Extensions 清单，
// 否则像 main.dart 那样在入口里写 `Extensions.catalog` 会报 "getter 未定义"。
export 'extensions.dart';

class ExtensionsPage extends StatefulWidget {
  const ExtensionsPage({super.key});
  @override
  State<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends State<ExtensionsPage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Extensions.load().then((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  Widget build(BuildContext c) {
    final scheme = Theme.of(c).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr('资源包'))),
          body: const Center(child: CircularProgressIndicator()));
    }
    final groups = <ExtKind, List<AppExt>>{};
    for (final e in Extensions.catalog) {
      (groups[e.kind] = groups[e.kind] ?? []).add(e);
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('资源包'))),
      body: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        // 顶部说明：先讲清「不装会怎样」，比催着装更让人放心
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.inventory_2_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(tr('按需安装'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: Gap.sm),
            const Text(
              '软件本体只有三十多 MB，看漫画、看小说都不需要装任何东西。\n'
              '下面这些是「装了就多一份能力、不装也照常用」的包。',
              style: TextStyle(fontSize: 12, height: 1.6, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Text(trf('已装占用 {size}',
                    {'size': Extensions.sizeText(Extensions.installedBytes())}),
                style: TextStyle(fontSize: 11, color: scheme.primary)),
          ]),
        ),
        const SizedBox(height: Gap.md),
        for (final kind in groups.keys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
            child: Text(_kindName(kind),
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          for (final e in groups[kind]!) _card(c, e),
        ],
        const SizedBox(height: Gap.md),
        const Text(
          '说明：\n'
          '· 资料库包是独立的安装器，装完在系统里单独一个图标，负责解析站点\n'
          '· 本机 AI 运行时需要约 2GB 可用内存；手机上跑不动的话，用云端 AI 也一样',
          style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.7),
        ),
      ]),
    );
  }

  String _kindName(ExtKind k) => switch (k) {
        ExtKind.runtime => 'AI 运行时',
        ExtKind.engine => tr('内容资料库'),
        ExtKind.sources => '源包',
        ExtKind.model => '本地模型',
        ExtKind.skill => '技能包',
      };

  Widget _card(BuildContext c, AppExt e) {
    final installed = Extensions.isInstalled(e.id);
    final scheme = Theme.of(c).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(e.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: installed
                    ? Colors.green.withValues(alpha: 0.14)
                    : scheme.onSurface.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                installed ? '已安装' : Extensions.sizeText(e.sizeBytes),
                style: TextStyle(
                    fontSize: 11,
                    color: installed ? Colors.green : Colors.grey),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(e.desc,
              style: const TextStyle(fontSize: 12, height: 1.5, color: Colors.grey)),
          const SizedBox(height: 8),
          Text(trf('装了可以：{what}', {'what': Extensions.unlockText(e)}),
              style: TextStyle(fontSize: 11, color: scheme.primary)),
          const SizedBox(height: 10),
          if (!e.available)
            Row(children: [
              Icon(Icons.schedule, size: 15,
                  color: scheme.onSurface.withValues(alpha: 0.4)),
              const SizedBox(width: 6),
              Text(tr('还没做好，先别装'),
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.5))),
            ])
          else if (installed)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  await Extensions.markRemoved(e.id);
                  if (mounted) setState(() {});
                },
                child: Text(tr('标记为已卸载')),
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: e.kind == ExtKind.engine
                    ? () => _openEngine(e)
                    : null,
                child: Text(tr('下载')),
              ),
            ),
        ]),
      ),
    );
  }

  /// 引擎包是 APK，交给系统安装器 —— App 不自己解包，避免装出半残。
  void _openEngine(AppExt e) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(trf('安装「{name}」', {'name': e.name})),
        content: Text(
          '会下载 ${Extensions.sizeText(e.sizeBytes)} 的安装包，'
          '装完在桌面上单独一个图标。\n\n'
          '它负责解析站点，App 通过它来搜内容。',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('取消'))),
          FilledButton(
            onPressed: () {
              Navigator.pop(c);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr('下载会走系统浏览器，在下载中心里点「资料库」可以直接装'))),
              );
            },
            child: Text(tr('知道了')),
          ),
        ],
      ),
    );
  }
}
