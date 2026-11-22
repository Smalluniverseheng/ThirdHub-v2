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

/// 一个源是从哪来的。
///
/// ★ 为什么它是一等模型而不是备注：
///   合规审计要能一眼分清「随包发布的源」和「用户自己加的源」——
///   前者由我们负责，后者是用户的配置。审计口径完全不同。
enum SourceOrigin {
  /// 编译进安装包的少量合规源。不可删、不可改。
  builtin,

  /// 管理员账号同步下来的扩展源包。可在设置里关闭。
  admin,

  /// 用户自己导入的源。随时可删。
  user;

  String get i18nKey => switch (this) {
        SourceOrigin.builtin => '内置',
        SourceOrigin.admin => '管理员同步',
        SourceOrigin.user => '我导入的',
      };
}

/// 内容来源的授权性质。**从强到弱排列**，顺序即宽松程度。
enum LicenseKind {
  /// 公有领域：作者去世逾保护期，或明确放弃全部权利。全球可自由复制传播。
  publicDomain,

  /// 知识共享等开放许可：作者以 CC / ODbL / MIT 等条款明确许可使用。
  creativeCommons,

  /// 平台**官方公开 API**，且其使用条款允许第三方客户端读取。
  officialApi,

  /// 用户自有内容：自己购买/录制/扫描的文件，或用户自己部署的家庭服务。
  userOwned,

  /// 用户自行导入的第三方源规则。**版权状态不明**，且可能违反目标站点条款。
  /// 仅桌面端。
  thirdPartyRule,

  /// 程序主动爬取网页。**版权状态不明**，且通常违反目标站点条款。仅桌面端。
  scraped;

  /// 是否允许进入要上架的移动端构建。
  ///
  /// 这是整个文件唯一的判定口径，别在别处再写一份 if。
  bool get mobileSafe => switch (this) {
        LicenseKind.publicDomain => true,
        LicenseKind.creativeCommons => true,
        LicenseKind.officialApi => true,
        LicenseKind.userOwned => true,
        LicenseKind.thirdPartyRule => false,
        LicenseKind.scraped => false,
      };

  /// 唯一的 i18n 键。UI 不拼字符串，避免 6 语言漏翻。
  String get i18nKey => switch (this) {
        LicenseKind.publicDomain => '公有领域',
        LicenseKind.creativeCommons => '开放许可',
        LicenseKind.officialApi => '官方公开接口',
        LicenseKind.userOwned => '自有内容',
        LicenseKind.thirdPartyRule => '第三方规则',
        LicenseKind.scraped => '主动抓取',
      };

  /// 徽标底色用的语义分组：true = 完全合规，false = 需自担责任。
  bool get cleanBadge => mobileSafe;

  /// 排序权重：合规的排前面。
  int get rank => index;
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

  /// 内容授权性质。**必填，没有默认值** —— 写不出来源和授权就不该进库。
  ///
  /// 这个字段唯一的作用是喂给 [FreePolicy] 判断能否进移动端构建。
  final LicenseKind license;

  /// 权利人署名 / 内容出处。上架审核会看这一项，也是给用户的交代。
  final String attribution;

  /// 该源的使用条款或授权说明地址。空表示无（极少见）。
  final String termsUrl;

  /// 这个源从哪来：内置 / 管理员同步 / 用户导入。
  ///
  /// ★ 为什么它是一等字段而不是注释：
  ///   合规审计要能一眼分清「随包发布的源」和「用户自己加的源」。
  ///   前者我们要负责，后者是用户的配置。
  final SourceOrigin origin;

  /// 「这源从哪来」的人话说明（如「我的 NAS 同步」）。可空。
  final String originNote;

  const FreeSource({
    required this.id,
    required this.name,
    required this.note,
    required this.kind,
    required this.license,
    this.attribution = '',
    this.termsUrl = '',
    this.pingUrl = '',
    this.origin = SourceOrigin.builtin,
    this.originNote = '',
  });

  /// 是否随安装包发布。只有这种源会被算进「上架合规」范围。
  bool get builtin => origin == SourceOrigin.builtin;
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

/// 主板块名 → 开放源页该落在哪个 tab。
///
/// 用户从「小说/漫画/视频/音乐」的「未连接」空态点「用开放内容搜索」时，
/// 不能一律丢到默认的音乐 tab —— 搜漫画却进了音乐页是很糟的体验。
/// 这里集中映射，调用点与单测共用同一份规则。
FreeKind freeKindForBoard(String board) {
  switch (board) {
    case '小说':
    case '书籍':
    case 'novel':
    case 'book':
      return FreeKind.book;
    case '漫画':
    case 'comic':
      return FreeKind.comic;
    case '视频':
    case '影视':
    case 'video':
      return FreeKind.video;
    case '音乐':
    case 'music':
    case '播客':
      return FreeKind.music;
    default:
      // 总搜索页 / 未知板块：音乐 tab 里的源最全（含电台、播客），
      // 作为兜底最不容易出现「一个源都没有」的白页。
      return FreeKind.music;
  }
}
