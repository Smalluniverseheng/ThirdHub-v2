// 红果离线缓存管理闸门（4.81.108）—— 纯 Dart：`dart run tool/hg_cache_selfcheck.dart`
//
// 为什么需要它：这个页面最容易「看着有、其实不能用」的三件事都不会让 analyze 报错：
//   ① 缓存页自己调后端 → 断网时连管理页都打不开；
//   ② 离线列表点了还走取流接口 → 断网必然失败，用户以为下载白下了；
//   ③ 顺手把播放地址也写进缓存 → 地址有时效，过期后缓存的是死链。
// 本自检同时做「行为」（真写真删索引）和「接线」（源码文本）两类断言。
import 'dart:io';

import '../lib/core/hg_cache.dart';
import '../lib/core/kv.dart';

int _pass = 0;
final List<String> _fail = <String>[];

void ck(String name, bool ok, [String extra = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail.add('$name${extra.isEmpty ? '' : '  ($extra)'}');
  }
}

void eq(String name, Object? got, Object? want) =>
    ck(name, got == want, 'got=$got want=$want');

String _read(String rel) => File(rel).readAsStringSync();

/// 从 Dart 源码里抓 tr()/trf() 的中文 key（用于验证 6 语言补齐）。
Set<String> _trKeys(String src) {
  final out = <String>{};
  final re = RegExp(r'\btrf?\(\s*\x27([^\x27]+)\x27');
  for (final m in re.allMatches(src)) {
    final k = m.group(1)!;
    if (k.contains(RegExp(r'[\u4e00-\u9fa5]'))) out.add(k);
  }
  return out;
}

Future<void> main() async {
  resetAiStoreForTest();

  // ── 1. 真写真读：索引 + 分类 + 字节数 ────────────────────────────────
  await HgCache.write(HgCache.feedKey(), {'data': [1, 2, 3]});
  await HgCache.write(HgCache.searchKey('  总裁  '), {'data': [{'id': 'a'}]});
  await HgCache.write(HgCache.seriesKey('s1'), {'data': {'name': '剧'}});
  await HgCache.write(HgCache.episodesKey('s1'), {'data': [{'id': 'e1'}]});

  eq('key 归一：搜索词转小写并去空格', HgCache.searchKey('  总裁  '),
      'search:总裁');
  final entries = await HgCache.entries();
  eq('4 份资料缓存都进索引', entries.length, 4);
  ck('每份缓存都有实际字节数', entries.every((e) => e.bytes > 0));
  ck('feed 被识别为 feed 类',
      entries.any((e) => e.kind == 'feed' && e.arg.isEmpty));
  ck('搜索 key 的动态部分被单独拆出',
      entries.any((e) => e.kind == 'search' && e.arg == '总裁'));
  ck('剧集/分集 key 不混类',
      entries.any((e) => e.kind == 'series') &&
          entries.any((e) => e.kind == 'eps'));
  ck('总字节数等于逐条之和',
      await HgCache.totalBytes() ==
          entries.fold<int>(0, (n, e) => n + e.bytes));

  final cached = await HgCache.read(HgCache.seriesKey('s1'));
  ck('read 带出 __ageMs（页面据此标离线）', cached?['__ageMs'] is int);
  ck('长 TTL 判新鲜', HgCache.fresh(cached, const Duration(hours: 12)));
  ck('零 TTL 判过期', !HgCache.fresh(cached, Duration.zero));

  // ── 2. 单条删 / 清空 ────────────────────────────────────────────────
  await HgCache.clear(HgCache.feedKey());
  eq('单条删后剩 3 条', (await HgCache.entries()).length, 3);
  ck('单条删不会误删同剧的另一份',
      (await HgCache.read(HgCache.episodesKey('s1'))) != null);
  await HgCache.clearAll();
  eq('清空后索引为空', (await HgCache.entries()).length, 0);
  eq('清空后字节数归零', await HgCache.totalBytes(), 0);

  // 老版本没有索引时写的 feed 也要能被认领（兼容 4.81.98）
  resetAiStoreForTest();
  await HgCache.write('feed', {'data': []});
  eq('无索引老缓存也能列出来', (await HgCache.entries()).length, 1);

  // ── 3. 接线：播放地址不缓存、离线播放不联网 ───────────────────────────
  final hongguo = _read('lib/core/hongguo_page.dart');
  final start = hongguo.indexOf('Future<MediaSpec?> _specOf');
  final end = hongguo.indexOf('Future<void> _play', start);
  final specOf = start >= 0 && end > start
      ? hongguo.substring(start, end)
      : '';
  ck('取流方法确实存在（防止源码改名让断言失效）', specOf.isNotEmpty);
  ck('★取流路径不写资料缓存（播放地址不缓存）',
      !specOf.contains('HgCache'), specOf.substring(0, 120));
  ck('取流仍走 PlayResolver 本地优先',
      specOf.contains('PlayResolver.media'));

  final page = _read('lib/core/hg_cache_page.dart');
  ck('★缓存页不碰后端 API（断网也能打开）',
      !page.contains('Api.get') && !page.contains("import '../main.dart'"));
  ck('★点已下载条目只查本机文件',
      page.contains('PlayResolver.localFileOf'));
  ck('本地命中拼 file:// 交给统一播放器',
      page.contains("'file://") && page.contains('UnifiedPlayer.open'));
  ck('有单条删除与一键清空',
      page.contains('MediaOfflineStore.remove') &&
          page.contains('HgCache.clearAll'));
  ck('有容量显示', page.contains('MediaOfflinePlan.bytesLabel'));
  ck('离线列表只收红果视频',
      page.contains("m.sourceId == 'hongguo'") &&
          page.contains("m.kind == 'video'"));
  ck('红果页挂了缓存管理入口',
      hongguo.contains('HgCachePage') && hongguo.contains('缓存管理'));

  for (final bad in ['引擎', '换源', '书源', '图源', '影视源', '音乐源']) {
    ck('新页面无品牌禁词「$bad」', !page.contains(bad));
  }

  // ── 4. 6 语言补齐（zh 用原文，不需要字典） ────────────────────────────
  final i18n = _read('lib/core/i18n_extra.dart');
  final keys = _trKeys(page)..add('缓存管理');
  for (final lang in ['fr', 'ru', 'es', 'ar', 'en', 'ja']) {
    final marker = "'$lang': <String, String>{";
    final s = i18n.indexOf(marker);
    final e = s < 0 ? -1 : i18n.indexOf('\n  },', s);
    final block = s >= 0 && e > s ? i18n.substring(s, e) : '';
    final missing = keys.where((k) => !block.contains("'$k':")).toList();
    ck('$lang 文案补齐（${keys.length} 键）', missing.isEmpty,
        '缺：${missing.take(6).toList()}');
  }

  print('\n红果离线缓存自检：PASS $_pass / FAIL ${_fail.length}');
  for (final f in _fail) {
    print('  ✗ $f');
  }
  if (_fail.isNotEmpty) exit(1);
}
