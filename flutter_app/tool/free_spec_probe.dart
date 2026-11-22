// 源包探测器：拿一份源包 JSON，逐个源真实发请求，把结果打出来。
//
// 用法：
//   dart run tool/free_spec_probe.dart                       # doc 里的示例包
//   dart run tool/free_spec_probe.dart path/to/bundle.json
//   dart run tool/free_spec_probe.dart bundle.json 周杰伦    # 指定搜索词
//
// 为什么要有它：源包的错法大多是「路径写错」「字段名变了」，
// 这些只有真发一次请求才看得出来。写源的人（包括将来的我）需要一个
// 不启动 App 就能验证的办法 —— 否则只能装到手机上点一遍再猜。
import 'dart:io';

import '../lib/core/free/free_bundle.dart';
import '../lib/core/free/free_dynamic.dart';
import '../lib/core/free/free_models.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : '../docs/free-sources/starter.json';
  final q = args.length > 1 ? args[1] : '测试';

  final f = File(path);
  if (!f.existsSync()) {
    stderr.writeln('找不到源包：$path');
    exit(2);
  }

  final raw = f.readAsStringSync();
  final parsed = FreeSourceBundle.parse(raw);
  final b = parsed.bundle;
  if (b == null) {
    stderr.writeln('解析失败：${parsed.error}');
    exit(2);
  }

  stdout.writeln('源包：${b.name}  v${b.version}  ${b.count} 个源');
  if (parsed.warnings.isNotEmpty) {
    stdout.writeln('跳过 ${parsed.warnings.length} 条：');
    for (final w in parsed.warnings) {
      stdout.writeln('  · $w');
    }
  }
  stdout.writeln('搜索词：「$q」');
  stdout.writeln('');

  var ok = 0;
  var fail = 0;
  // 空结果单独计数：搜一个源站真没有的词（比如在英文漫画库搜「一拳超人」）
  // 不该和「路径写错」算在一起，否则每换一个关键词都得重新判断工具是否可信。
  var empty = 0;
  for (final s in b.sources) {
    final sw = Stopwatch()..start();
    try {
      final act = s.search;
      if (act == null) {
        stdout.writeln('[SKIP] ${s.name}：没有 search 动作');
        continue;
      }
      final items = await DynamicSource.run(s, act, {'q': q, 'page': '1'});
      sw.stop();
      if (items.isEmpty) {
        empty++;
        // 空结果有两种原因，不能一口咬定是路径错 —— 中文词在英文站
        // 就是真没有内容（PeerTube 各实例尤其明显）。
        stdout.writeln('[EMPTY] ${s.name}  ${sw.elapsedMilliseconds}ms  '
            '（请求成功但 0 条：这个关键词在源站可能真没有内容，也可能路径写错）');
        continue;
      }
      ok++;
      stdout.writeln('[OK]   ${s.name}  ${sw.elapsedMilliseconds}ms  '
          '${items.length} 条');
      for (final it in items.take(3)) {
        stdout.writeln('        · ${_cut(it.title, 40)}');
        if (it.subtitle.isNotEmpty) {
          stdout.writeln('          ${_cut(it.subtitle, 50)}');
        }
        if (it.playUrl.isNotEmpty) {
          stdout.writeln('          ▶ ${_cut(it.playUrl, 70)}');
        }
      }
      // 可播地址抽查：只探第一个，避免一次打出几十个请求。
      final playable = items.firstWhere((e) => e.playUrl.isNotEmpty,
          orElse: () => const FreeItem(
              id: '', source: '', kind: FreeKind.music, title: ''));
      if (playable.playUrl.isNotEmpty) {
        final r = await _probePlayable(playable.playUrl);
        stdout.writeln('        播放地址：$r');
      }

      // ★下钻验证：有 detail 动作的源（视频 / 播客单集）必须真跑一次。
      //   这是最容易被漏掉的一段 —— 搜索列表只有标题和封面，
      //   「能搜到但点进去没有播放地址」不真跑 detail 根本发现不了。
      //   容忍个别条目没有文件（直播 / 隐私 / 转码中），所以最多试 3 条。
      final det = s.detail;
      if (det != null) {
        var got = '';
        var tried = 0;
        for (final cand in items.take(3)) {
          if (cand.id.trim().isEmpty) continue;
          tried++;
          try {
            final d = await DynamicSource.run(
              s,
              det,
              {'id': cand.id, 'q': q, 'page': '1'},
              kindOverride: s.kind,
            );
            final hit = d.where((e) => e.playUrl.isNotEmpty);
            if (hit.isNotEmpty) {
              got = hit.first.playUrl;
              break;
            }
          } catch (_) {
            // 换下一条继续试，别让一条失败掩盖整源可用。
          }
        }
        if (got.isEmpty) {
          stdout.writeln('        ✗ 下钻：试了 $tried 条都没取到播放地址');
        } else {
          final r = await _probePlayable(got);
          stdout.writeln('        ▶ 下钻播放地址：${_cut(got, 70)}');
          stdout.writeln('           $r');
        }
      }
    } catch (e) {
      sw.stop();
      fail++;
      stdout.writeln('[FAIL] ${s.name}  ${sw.elapsedMilliseconds}ms  $e');
    }
  }

  stdout.writeln('');
  stdout.writeln('=== $ok 个可用 / $empty 个空结果 / $fail 个失败 ===');
  if (ok == 0 && empty > 0) {
    stdout.writeln('注意：全部源都是空结果 —— 换一个更通用的关键词再试一次'
        '（比如英文单词），仍全空才说明路径有问题。');
  }
  exit(fail == 0 ? 0 : 1);
}

/// 只读前 8KB 判断这个地址到底是不是媒体流。
Future<String> _probePlayable(String url) async {
  try {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final req = await c.openUrl('GET', Uri.parse(url));
    req.headers.set('Range', 'bytes=0-8192');
    // Referer 只在真的访问网易云时带上。
    // 之前这里无条件写死 music.163.com —— 拿去探 PeerTube / MangaDex 的地址
    // 会带一个完全无关的来源，某些站会直接 403，测出来是假故障。
    if (url.contains('163.com')) {
      req.headers.set('Referer', 'https://music.163.com');
    }
    final res = await req.close().timeout(const Duration(seconds: 15));
    final ct = res.headers.value('content-type') ?? '';
    var got = 0;
    await for (final chunk in res) {
      got += chunk.length;
      if (got > 8192) break;
    }
    c.close(force: true);
    if (ct.contains('audio') || ct.contains('video') ||
        ct.contains('octet-stream')) {
      return '可播（$ct，读到 $got 字节）';
    }
    if (ct.contains('html')) return '不可播（返回网页，多半无版权）';
    return '未知（$ct）';
  } catch (e) {
    return '探测失败：$e';
  }
}

String _cut(String s, int n) {
  final t = s.replaceAll('\n', ' ').trim();
  return t.length > n ? '${t.substring(0, n)}…' : t;
}
