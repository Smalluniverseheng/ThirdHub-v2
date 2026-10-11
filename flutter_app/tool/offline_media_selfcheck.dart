// 媒体离线规则层自检（纯 Dart，不依赖 Flutter）。
// 跑法：
//   dart --disable-dart-dev --packages=.dart_tool/package_config.json tool/offline_media_selfcheck.dart
// 断言不过 = exit(1)。形状断言不算数，全部都是行为断言。

import '../lib/core/offline_media_plan.dart';
import '../lib/core/offline_plan.dart';

int fails = 0;
void ck(String what, bool ok) {
  if (ok) {
    print('OK   $what');
  } else {
    fails++;
    print('FAIL $what');
  }
}

void main() {
  // ── 1. 扩展名推断 ──
  ck('[ext] mp4 直链', MediaOfflinePlan.extOf('http://a/x.mp4') == 'mp4');
  ck('[ext] 带查询串不吃进扩展名',
      MediaOfflinePlan.extOf('http://a/x.MP3?token=abc.def') == 'mp3');
  ck('[ext] 带锚点不吃进扩展名',
      MediaOfflinePlan.extOf('http://a/x.flac#t=1') == 'flac');
  ck('[ext] 白名单外的扩展走 fallback',
      MediaOfflinePlan.extOf('http://a/x.html', fallback: 'mp4') == 'mp4');
  ck('[ext] 无后缀走 fallback',
      MediaOfflinePlan.extOf('http://a/play/12345', fallback: 'mp3') == 'mp3');
  ck('[ext] 以点结尾不是扩展名',
      MediaOfflinePlan.extOf('http://a/x.', fallback: 'jpg') == 'jpg');
  ck('[ext] jpg 图片', MediaOfflinePlan.extOf('http://a/1.jpg') == 'jpg');

  // ── 2. 文件命名 ──
  ck('[name] 单文件名', MediaOfflinePlan.mediaFileName('mp4') == 'media.mp4');
  ck('[name] 扩展名清洗（大写/脏字符）',
      MediaOfflinePlan.mediaFileName('M P3!') == 'media.mp3');
  ck('[name] 页名补零', MediaOfflinePlan.pageFileName(7, 'jpg') == 'p_00007.jpg');
  ck('[name] 页名 123 位', MediaOfflinePlan.pageFileName(123, 'webp') == 'p_00123.webp');
  ck('[name] 页下标还原', MediaOfflinePlan.pageIndexOf('p_00007.jpg') == 7);
  ck('[name] 页下标还原 0', MediaOfflinePlan.pageIndexOf('p_00000.png') == 0);
  ck('[反例] 小说章节名不是页名', MediaOfflinePlan.pageIndexOf('c_00001.txt') == null);
  ck('[反例] 乱名不是页名', MediaOfflinePlan.pageIndexOf('readme.txt') == null);

  // ── 3. 直播/HLS 判定（判定口径唯一收口在这）──
  ck('[hls] .m3u8 是流', MediaOfflinePlan.isStreamOnly('http://a/live.m3u8'));
  ck('[hls] 带查询串也是流',
      MediaOfflinePlan.isStreamOnly('http://a/live.m3u8?auth=x'));
  ck('[hls] 大小写不敏感', MediaOfflinePlan.isStreamOnly('http://a/LIVE.M3U8'));
  ck('[hls] .m3u 旧扩展也是流', MediaOfflinePlan.isStreamOnly('http://a/x.m3u'));
  ck('[反例] mp4 不是流', !MediaOfflinePlan.isStreamOnly('http://a/x.mp4'));
  ck('[反例] 路径里带 m3u8 字样不是流',
      !MediaOfflinePlan.isStreamOnly('http://a/m3u8player/play.mp4'));
  ck('[反例] 空地址不是流', !MediaOfflinePlan.isStreamOnly(''));

  // ── 4. 字节数文案 ──
  ck('[bytes] 0', MediaOfflinePlan.bytesLabel(0) == '0 B');
  ck('[bytes] KB', MediaOfflinePlan.bytesLabel(2048) == '2.0 KB');
  ck('[bytes] MB', MediaOfflinePlan.bytesLabel(12 * 1024 * 1024) == '12.0 MB');
  ck('[bytes] GB', MediaOfflinePlan.bytesLabel(3 * 1024 * 1024 * 1024) == '3.0 GB');

  // ── 5. 清单 roundtrip（含脏数据容错）──
  const m0 = MediaOfflineMeta(
    key: 'http://a/ep1',
    kind: 'video',
    title: '测试剧 第1集',
    subtitle: '测试剧',
    coverUrl: 'http://a/c.jpg',
    status: 'done',
    at: '2026-10-11 10:00',
    total: 1,
    done: 1,
    failed: 0,
    bytes: 12345,
    files: ['media.mp4'],
  );
  final back = MediaOfflineMeta.fromJson(m0.toJson());
  ck('[meta] roundtrip key', back.key == m0.key);
  ck('[meta] roundtrip title', back.title == m0.title);
  ck('[meta] roundtrip files', back.files.length == 1 && back.files.first == 'media.mp4');
  ck('[meta] roundtrip bytes', back.bytes == 12345);
  ck('[meta] 字符串数字容错',
      MediaOfflineMeta.fromJson({'total': '3', 'done': '2', 'bytes': 'x'}).total == 3);
  ck('[meta] 字符串数字容错 done',
      MediaOfflineMeta.fromJson({'total': '3', 'done': '2'}).done == 2);
  ck('[meta] 缺字段不炸', MediaOfflineMeta.fromJson(const {}).status == 'error');
  ck('[meta] copyWith 不动身份',
      m0.copyWith(status: 'partial').key == m0.key &&
          m0.copyWith(status: 'partial').kind == 'video');
  ck('[meta] copyWith 只改给的',
      m0.copyWith(done: 9).done == 9 && m0.copyWith(done: 9).total == 1);

  // ── 6. 状态与描述（用户能看懂的话）──
  ck('[status] 全好 = done', MediaOfflinePlan.statusOf(10, 10, 0) == 'done');
  ck('[status] 缺页 = partial', MediaOfflinePlan.statusOf(10, 8, 1) == 'partial');
  const comic10 = MediaOfflineMeta(
    key: 'http://a/c1',
    kind: 'comic',
    title: '测试漫画 第1话',
    status: 'partial',
    at: '2026-10-11 10:00',
    total: 10,
    done: 8,
    failed: 1,
    bytes: 2048,
  );
  ck('[describe] 漫画带页数', MediaOfflinePlan.describe(comic10).contains('8/10 页'));
  ck('[describe] 单文件带大小',
      MediaOfflinePlan.describe(m0).contains('12.1 KB'));
  ck('[describe] 下载中', MediaOfflinePlan.describe(m0.copyWith(status: 'running'))
      == '正在下载…');

  // ── 7. 目录键与小说层同源（复用 OfflinePlan 的哈希口径）──
  ck('[key] hash 与 OfflinePlan 同源',
      MediaOfflinePlan.hashOf('http://a/b') == OfflinePlan.hashOf('http://a/b'));
  ck('[key] slug 与 OfflinePlan 同源',
      MediaOfflinePlan.slugOf('http://a/b', name: '标题') ==
          OfflinePlan.slugOf('http://a/b', name: '标题'));
  ck('[key] 同 key 同 slug（稳定键）',
      MediaOfflinePlan.slugOf('http://a/b', name: 'X') ==
          MediaOfflinePlan.slugOf('http://a/b', name: 'X'));

  print('');
  print(fails == 0
      ? 'offline_media_selfcheck: 全部通过'
      : 'offline_media_selfcheck: $fails 项失败');
  if (fails > 0) {
    throw Exception('offline_media_selfcheck 有 $fails 项失败');
  }
}
