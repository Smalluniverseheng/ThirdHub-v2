// 「厂商公开 / 免费开放数据源」清单页（全盘升级任务 #208）
//
// 移动端面向大众、准备上架苹果 → 这一页只展示 kPublicDataSources 里
// isMobilePublicSourceAllowed() 放行的条目；第三方内容源不在这里，
// 也不允许通过任何入口下发到移动端。
//
// 密钥不在这里重复实现：点「填写密钥」直接进已有的统一密钥库页面，
// 沿用 api_keys.dart 的厂商归一化（一把 Key 全模块复用）。

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_keys_page.dart';
import 'i18n.dart';
import 'public_data_sources.dart';

/// 类别标签用技术名词（多语言里这些词本来就通用），避免又新增一批待译文案。
const Map<String, String> kSourceCategoryLabels = <String, String>{
  SourceCategory.ai: 'AI',
  SourceCategory.tts: 'TTS',
  SourceCategory.translate: 'Translate',
  SourceCategory.metadata: 'Metadata',
  SourceCategory.weather: 'Weather',
  SourceCategory.geo: 'Geo',
  SourceCategory.search: 'Search',
};

class PublicSourcesPage extends StatelessWidget {
  const PublicSourcesPage({super.key});

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 打不开就让系统自己报错，不额外弹一层；避免把异常吞成"点了没反应"。
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = mobileVisibleSources();
    final groups = <String, List<PublicDataSource>>{};
    for (final s in list) {
      groups.putIfAbsent(s.category, () => <PublicDataSource>[]).add(s);
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('公开数据源'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(tr('厂商官方开放接口'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 8),
          Text(tr('只列厂商官方公开、免费开放的接口；密钥由你自己申请填写。第三方内容源不在移动端，它们在桌面端管理后台。'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5)),
          const SizedBox(height: 8),
          Text(tr('共 {n} 项').replaceAll('{n}', '${list.length}'),
              style: TextStyle(fontSize: 12, color: cs.primary)),
          const SizedBox(height: 16),
          for (final cat in SourceCategory.all)
            if (groups[cat] != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                child: Text(kSourceCategoryLabels[cat] ?? cat,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.secondary))),
              for (final s in groups[cat]!)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                                child: Text(s.name,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600))),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: s.needsKey
                                    ? cs.tertiaryContainer
                                    : cs.secondaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                  s.needsKey ? tr('需要密钥') : tr('无需密钥'),
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: s.needsKey
                                          ? cs.onTertiaryContainer
                                          : cs.onSecondaryContainer)),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          Text(s.freeQuota,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                  height: 1.4)),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, children: [
                            TextButton(
                                onPressed: () => _open(context, s.docUrl),
                                child: Text(tr('官方文档'),
                                    style: const TextStyle(fontSize: 12))),
                            TextButton(
                                onPressed: () => _open(context, s.homeUrl),
                                child: Text(tr('官网'),
                                    style: const TextStyle(fontSize: 12))),
                            if (s.needsKey)
                              TextButton(
                                  onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => const ApiKeysPage())),
                                  child: Text(tr('填写密钥'),
                                      style: const TextStyle(fontSize: 12))),
                          ]),
                        ]),
                  ),
                ),
            ],
        ],
      ),
    );
  }
}
