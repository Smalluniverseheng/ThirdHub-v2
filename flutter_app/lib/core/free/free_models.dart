// 开放内容源的统一模型。
//
// 目标很朴素：让「漫画/音乐/播客/电台/视频/书」这些来自**公网正规站**的内容，
// 能以同一套结构喂给同一套 UI 与同一个播放器，从而真正脱离后端可用。
//
// 与 main.dart 里 `Api` 那套「源 → 引擎 → 播放」不同：
// 这里没有源脚本、没有后端、没有 token，只有一个 URL 和一份 JSON。
import 'free_http.dart';

/// 内容板块。UI 的 tab 与播放形态都按它分派。
enum FreeKind {
  music,
  podcast,
  radio,
  video,
  comic,
  book,
  poem;

  /// 能否直接交给统一播放器（有可播地址）。
  bool get playable =>
      this == FreeKind.music ||
      this == FreeKind.podcast ||
      this == FreeKind.radio ||
      this == FreeKind.video;
}

/// 一个可下钻的多级列表（漫画的章、播客的期）在 UI 里表现一致：
/// 「点条目 → 出子列表 → 点子条目 → 播/读」。用 [FreeItem.drill] 标记。
class FreeItem {
  /// 源内唯一 id（MangaDex 是 uuid，Audius 是 track id…）。
  final String id;

  /// 源标识，见各 `xxxSource.id`。
  final String source;

  final FreeKind kind;

  final String title;

  /// 副标题：作者 / 艺人 / 电台国家 / 集数。
  final String subtitle;

  /// 封面图。可能为空（部分源不给）。
  final String cover;

  /// 简介 / 描述。列表里最多显示两行。
  final String desc;

  /// 可直接播放的地址（音乐/电台/视频/播客单集）。
  /// 为空表示需要先解析（播客要先拉 RSS、漫画要拉章节列表）。
  final String playUrl;

  /// 是否需要/可以下钻。
  final bool drill;

  /// 原始数据，供下钻时取参（如 feedUrl、chapterId）。
  final Map<String, dynamic> raw;

  const FreeItem({
    required this.id,
    required this.source,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.cover = '',
    this.desc = '',
    this.playUrl = '',
    this.drill = false,
    this.raw = const {},
  });

  /// 展示用：标题为空时不要显示成空白行。
  String get displayTitle => title.trim().isEmpty ? '(无标题)' : title.trim();

  String get displaySubtitle {
    final s = subtitle.trim();
    if (s.isNotEmpty) return s;
    final d = desc.trim();
    if (d.isEmpty) return '';
    return d.length > 60 ? '${d.substring(0, 60)}…' : d;
  }
}

/// 一个源的静态描述 + 可用性状态。
///
/// ★ 「可达性」是一等公民：这些源都在公网，国内网络下随时可能连不上
///   （实测 wikisource 就是间歇性的）。UI 必须能把「这源现在不通」
///   跟「这源没内容」区分开 —— 否则用户会以为软件坏了。
class FreeSource {
  final String id;
  final String name;

  /// 一句话说明它是什么、内容从哪来、是否合法。
  final String note;

  final FreeKind kind;

  /// 探活地址。为空表示不做探测（总是尝试）。
  final String pingUrl;

  const FreeSource({
    required this.id,
    required this.name,
    required this.note,
    required this.kind,
    this.pingUrl = '',
  });
}

/// 可达性探测结果缓存。
///
/// 单次探活 8 秒、几十个源串起来就是几十秒 —— 所以：
/// ① 每个源只探测一次，结果缓存 [ttl]；
/// ② **并发探测**，总耗时 ≈ 最慢那个；
/// ③ 探测失败不清空列表，只标记状态（用户点「重试」再探）。
class FreeReach {
  FreeReach._();

  static final Map<String, _ReachEntry> _cache = {};

  /// 缓存有效期。太短会让每次进页面都等，太长会让「网好了还是灰的」。
  static const Duration ttl = Duration(minutes: 3);

  /// 并发探测一批源，返回 id → 是否可达。
  static Future<Map<String, bool>> probeAll(List<FreeSource> sources,
      {bool force = false}) async {
    final out = <String, bool>{};
    final todo = <FreeSource>[];
    for (final s in sources) {
      final e = _cache[s.id];
      if (!force && e != null && DateTime.now().difference(e.at) < ttl) {
        out[s.id] = e.ok;
      } else if (s.pingUrl.isEmpty) {
        // 没有探活地址的源按「可用」处理，真失败时由具体请求报错。
        out[s.id] = true;
      } else {
        todo.add(s);
      }
    }
    if (todo.isNotEmpty) {
      final results = await Future.wait(todo.map((s) async {
        final ok = await FreeHttp.ping(s.pingUrl,
            timeout: const Duration(seconds: 8));
        _cache[s.id] = _ReachEntry(ok, DateTime.now());
        return MapEntry(s.id, ok);
      }));
      for (final r in results) {
        out[r.key] = r.value;
      }
    }
    return out;
  }

  static bool? cached(String id) => _cache[id]?.ok;

  static void mark(String id, bool ok) =>
      _cache[id] = _ReachEntry(ok, DateTime.now());

  static void clear() => _cache.clear();
}

class _ReachEntry {
  final bool ok;
  final DateTime at;
  const _ReachEntry(this.ok, this.at);
}
