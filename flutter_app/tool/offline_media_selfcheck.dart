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

  // ── 8. HLS（m3u8）解析：点播/直播/加密/多码率/fMP4（规划册 H1）──
  // 判定口径：含 #EXT-X-ENDLIST = 点播（可整存）；没有 = 直播（拒绝）。
  const vodM3u8 = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:9.009,
seg1.ts
#EXTINF:9.009,
http://cdn.example.com/dir/seg2.ts
#EXTINF:8.0,
../up/seg3.ts?token=1
#EXT-X-ENDLIST''';
  final h1 = HlsPlan.parse(vodM3u8, 'https://cdn.example.com/live/index.m3u8');
  ck('[hls] 点播识别（有 ENDLIST）', h1 != null && h1.isVod);
  ck('[hls] 分片计数（3 片）', h1!.segments.length == 3);
  ck('[hls] 相对路径还原为绝对',
      h1.segments[0] == 'https://cdn.example.com/live/seg1.ts');
  ck('[hls] 带域名分片保持',
      h1.segments[1] == 'http://cdn.example.com/dir/seg2.ts');
  ck('[hls] 上跳路径还原（并保留 query）',
      h1.segments[2] == 'https://cdn.example.com/up/seg3.ts?token=1');
  ck('[hls] 扩展名推断 ts', h1.mergedExt == 'ts');
  ck('[hls] 非加密', !h1.encrypted);
  ck('[hls] 非 master', !h1.isMaster);

  const liveM3u8 = '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
live1.ts
#EXTINF:4.0,
live2.ts''';
  final h2 = HlsPlan.parse(liveM3u8, 'https://x/a.m3u8');
  ck('[hls] 直播识别（无 ENDLIST → 不可整存）', h2 != null && !h2.isVod);

  const encM3u8 = '''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="k.key"
#EXTINF:5,
a.ts
#EXT-X-ENDLIST''';
  ck('[hls] 加密流识别', HlsPlan.parse(encM3u8, 'https://x/a.m3u8')!.encrypted);
  const keyNoneM3u8 = '''#EXTM3U
#EXT-X-KEY:METHOD=NONE
#EXTINF:5,
a.ts
#EXT-X-ENDLIST''';
  ck('[hls] METHOD=NONE 不算加密',
      !HlsPlan.parse(keyNoneM3u8, 'https://x/a.m3u8')!.encrypted);

  const masterM3u8 = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000
high.m3u8''';
  final h3 = HlsPlan.parse(masterM3u8, 'https://x/master.m3u8');
  ck('[hls] master 识别', h3 != null && h3.isMaster);
  ck('[hls] master 子清单计数', h3!.childPlaylists.length == 2);
  ck('[hls] master 子清单绝对化',
      h3.childPlaylists[0] == 'https://x/low.m3u8');
  ck('[hls] master 没有分片', h3.segments.isEmpty);

  const fmp4M3u8 = '''#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:5,
seg1.m4s
#EXTINF:5,
seg2.m4s
#EXT-X-ENDLIST''';
  final h4 = HlsPlan.parse(fmp4M3u8, 'https://x/a.m3u8');
  ck('[hls] fMP4 init 段单独抽', h4!.initSegment == 'https://x/init.mp4');
  ck('[hls] fMP4 分片不含 init', h4.segments.length == 2);
  ck('[hls] fMP4 合并扩展名 = mp4', h4.mergedExt == 'mp4');

  ck('[hls] 非 HLS 文本 parse = null',
      HlsPlan.parse('hello world', 'https://x/a') == null);
  ck('[hls] isHls 认 .m3u8 带 query',
      HlsPlan.isHls('http://a/x.m3u8?token=1'));
  ck('[hls] isHls 认 .m3u', HlsPlan.isHls('http://a/x.m3u'));
  ck('[hls] isHls 不认 .mp4', !HlsPlan.isHls('http://a/x.mp4'));

  // ── 9. 离线清理计划（M3 · 纯函数）──
  const items = [
    (key: 'a', bytes: 100, at: '2026-10-01 10:00'),
    (key: 'b', bytes: 200, at: '2026-10-02 10:00'),
    (key: 'c', bytes: 300, at: '2026-10-03 10:00'),
  ];
  ck('[cleanup] 不超限 → 空计划', OfflinePlan.planCleanup(items, 1000).isEmpty);
  ck('[cleanup] 0/负数 = 不限',
      OfflinePlan.planCleanup(items, 0).isEmpty &&
          OfflinePlan.planCleanup(items, -5).isEmpty);
  ck('[cleanup] 超限 → 最旧优先逐步删（a,b）',
      OfflinePlan.planCleanup(items, 450).join(',') == 'a,b');
  ck('[cleanup] 边界：删到刚好 ≤ 限（只删 a）',
      OfflinePlan.planCleanup(items, 500).join(',') == 'a');
  ck('[cleanup] 恰好等于限 → 不删',
      OfflinePlan.planCleanup(items, 600).isEmpty);

  print('');
  print(fails == 0
      ? 'offline_media_selfcheck: 全部通过'
      : 'offline_media_selfcheck: $fails 项失败');
  if (fails > 0) {
    throw Exception('offline_media_selfcheck 有 $fails 项失败');
  }
}
