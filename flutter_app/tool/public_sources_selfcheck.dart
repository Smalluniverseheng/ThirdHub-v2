// 「移动端厂商公开 / 免费开放数据源」注册表自检（全盘升级任务 #208）
//
// 覆盖四件事：
//   ① 每条注册项都能说清官网 / 官方文档 / 免费额度，且 id 唯一；
//   ② 准入闸门真的会挡住脏数据（非 https、非公开、含第三方内容源词）；
//   ③ 接线：清单页真的被入口引用，i18n 第 15 批真的被装载、6 语言补齐；
//   ④ 移动端源码里不出现第三方内容源清单（敏感源只允许在桌面端管理后台）。

import 'dart:io';

import 'package:thirdhub_app/core/i18n_ui_words.dart';
import 'package:thirdhub_app/core/public_data_sources.dart';

int pass = 0, fail = 0;
void ok(bool cond, String what) {
  if (cond) {
    pass++;
  } else {
    fail++;
    print('FAIL  $what');
  }
}

PublicDataSource src({
  String id = 'x',
  String name = 'X',
  String category = SourceCategory.metadata,
  String home = 'https://x.example',
  String doc = 'https://x.example/docs',
  bool needsKey = false,
  String quota = 'Free tier',
  bool commercialOk = true,
}) =>
    PublicDataSource(
      id: id,
      name: name,
      category: category,
      homeUrl: home,
      docUrl: doc,
      needsKey: needsKey,
      freeQuota: quota,
      commercialOk: commercialOk,
    );

void main() {
  print('== 1. 注册表完整性 ==');
  ok(kPublicDataSources.length >= 15, '注册表条目足够覆盖主要类别');
  final ids = <String>{};
  for (final s in kPublicDataSources) ids.add(s.id);
  ok(ids.length == kPublicDataSources.length, 'id 无重复');
  for (final s in kPublicDataSources) {
    ok(s.id.isNotEmpty && s.name.isNotEmpty, '${s.id} 有 id/名称');
    ok(s.homeUrl.startsWith('https://') && s.docUrl.startsWith('https://'),
        '${s.id} 官网/文档都是 https 官方地址');
    ok(SourceCategory.all.contains(s.category), '${s.id} 类别合法');
    ok(s.freeQuota.isNotEmpty, '${s.id} 写清了免费额度');
    ok(s.commercialOk, '${s.id} 允许面向大众分发');
    ok(isMobilePublicSourceAllowed(s), '${s.id} 通过移动端准入闸门');
  }
  for (final cat in SourceCategory.all) {
    ok(publicSources(cat).isNotEmpty, '类别 $cat 至少有一条');
  }
  ok(publicSourceById('open_meteo')?.name == 'Open-Meteo', '按 id 查得到');
  ok(publicSourceById('not_exist') == null, '查不到返回 null 而不是抛错');
  ok(sourcesNeedingKey().length < kPublicDataSources.length &&
      sourcesNeedingKey().isNotEmpty, '有免密钥项也有需密钥项');
  ok(mobileVisibleSources().length == kPublicDataSources.length,
      '当前表里没有需要被拦掉的脏条目');

  print('== 2. 准入闸门真的会拦 ==');
  ok(!isMobilePublicSourceAllowed(src(home: 'http://x.example')), '非 https 官网被拦');
  ok(!isMobilePublicSourceAllowed(src(doc: 'http://x.example/docs')), '非 https 文档被拦');
  ok(!isMobilePublicSourceAllowed(src(quota: '')), '没写免费额度被拦');
  ok(!isMobilePublicSourceAllowed(src(commercialOk: false)), '非公开可分发被拦');
  ok(!isMobilePublicSourceAllowed(src(category: 'pirate')), '未知类别被拦');
  ok(!isMobilePublicSourceAllowed(src(id: 'copy_manga')), '第三方漫画源 id 被拦');
  ok(!isMobilePublicSourceAllowed(src(name: 'baozi mirror')), '第三方镜像名被拦');
  ok(!isMobilePublicSourceAllowed(src(id: '', name: '')), '空 id/名称被拦');
  ok(!isMobilePublicSourceAllowed(src(quota: 'cracked 破解 采集 图源')),
      '含采集/破解类词的条目被拦');

  print('== 3. 接线（防「只写了一半」） ==');
  final mainSrc = File('lib/main.dart').readAsStringSync();
  final page = File('lib/core/public_sources_page.dart').readAsStringSync();
  final i18n = File('lib/core/i18n.dart').readAsStringSync();
  ok(mainSrc.contains("import 'core/public_data_sources.dart';") &&
      mainSrc.contains("import 'core/public_sources_page.dart';"),
      'main.dart 引入了规则层与清单页');
  ok(mainSrc.contains('const PublicSourcesPage()'), '「我的」里有真实入口');
  ok(mainSrc.contains("tr('公开数据源')"), '入口标题走 tr() 不是写死中文');
  ok(page.contains('mobileVisibleSources()'), '清单页只渲染准入放行的条目');
  ok(page.contains('const ApiKeysPage()'), '填密钥复用统一密钥库，不另造一套');
  ok(page.contains('launchUrl('), '官方文档/官网可点开');
  ok(i18n.contains('i18nUiWords15.forEach'), '第 15 批译文真的被装载');
  const keys = [
    '公开数据源',
    '厂商官方开放接口',
    '只列厂商官方公开、免费开放的接口；密钥由你自己申请填写。第三方内容源不在移动端，它们在桌面端管理后台。',
    '无需密钥',
    '需要密钥',
    '填写密钥',
    '官方文档',
    '官网',
    '共 {n} 项',
    '公开接口清单',
  ];
  const locales = ['en', 'ja', 'fr', 'ru', 'es', 'ar'];
  ok(i18nUiWords15.length == 6, '第十五批覆盖 6 种语言');
  for (final loc in locales) {
    final t = i18nUiWords15[loc];
    ok(t != null, '$loc 有字典块');
    for (final k in keys) {
      final v = t?[k];
      ok(v != null && v!.trim().isNotEmpty, '$loc 有译文：${k.length > 8 ? k.substring(0, 8) : k}');
      if (v != null) {
        ok(!v.contains('{n}') || k.contains('{n}'), '$loc 占位符没多也没少：${k.length > 8 ? k.substring(0, 8) : k}');
      }
    }
  }

  print('== 4. 移动端不出现第三方内容源 ==');
  final rule = File('lib/core/public_data_sources.dart').readAsStringSync();
  // 规则层里以「禁用词表」形式出现是允许的（那是闸门本体），所以查的是
  // 是否把它们当成可用配置，而不是字面出现。
  ok(!page.contains('copy_manga') && !page.contains('baozi'),
      '清单页不含任何第三方漫画源');
  ok(kMobileBannedTerms.contains('书源') &&
      kMobileBannedTerms.contains('图源') &&
      kMobileBannedTerms.contains('换源'),
      '禁用词表覆盖书源/图源/换源');
  ok(rule.contains('桌面端 / NAS 管理后台'), '规则层注明敏感源归桌面端管理后台');
  ok((i18nUiWords15['en']?[keys[2]] ?? '').contains('desktop admin console'),
      '给用户的说明也讲清「移动端没有、桌面端管理后台才有」');

  print('\n$pass 通过 / $fail 失败');
  if (fail > 0) exit(1);
}
