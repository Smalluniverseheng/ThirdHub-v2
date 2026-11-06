// 移动端「厂商公开 / 免费开放数据源」注册表（全盘升级任务 #208）
//
// ★ 为什么单独有一张表（用户 2026-11-07 的要求）：
//   「移动端是准备上架苹果、面向大众的」→ 移动端只能接**厂商自己公开**、
//   **有免费开放额度**的官方 API，由用户自己填自己的密钥；
//   第三方内容源（采集规则、抓取脚本、非官方镜像）一律不进移动端，
//   也不下发给公开网页端 —— 它们归桌面端 / NAS 管理后台，仅管理员或
//   管理员授权账号可见可用（见 server 侧 admin-only 端点）。
//
//   已存在的 `api_keys.dart` / `api_keys_store.dart` 负责「一把 Key 全模块复用」，
//   本表只负责「哪些服务是官方公开且允许在移动端出现」，两者正交，不重复造。
//
// ★ 本文件是纯 Dart 零依赖规则层，可被 tool/public_sources_selfcheck.dart 逐条断言。
//   表内文案一律英文/中性：中文硬编码会被 i18n_hardcoded 棘轮闸门拦下，
//   界面文案全部走 tr()。

/// 数据源类别。
class SourceCategory {
  const SourceCategory._();
  static const String ai = 'ai';
  static const String tts = 'tts';
  static const String translate = 'translate';
  static const String metadata = 'metadata';
  static const String weather = 'weather';
  static const String geo = 'geo';
  static const String search = 'search';

  static const List<String> all = [
    ai, tts, translate, metadata, weather, geo, search
  ];
}

/// 一条官方公开数据源。
class PublicDataSource {
  const PublicDataSource({
    required this.id,
    required this.name,
    required this.category,
    required this.homeUrl,
    required this.docUrl,
    required this.needsKey,
    required this.freeQuota,
    this.keyVendor = '',
    this.commercialOk = true,
  });

  /// 规范 id（与 ApiKeyKeys 的厂商 id 解耦，避免和密钥库互相绑死）。
  final String id;

  /// 官方品牌名（英文，避免中文硬编码）。
  final String name;

  /// [SourceCategory] 之一。
  final String category;

  final String homeUrl;
  final String docUrl;

  /// 是否要用户自己填官方密钥。false = 匿名即可调用。
  final bool needsKey;

  /// 免费额度 / 使用条件（英文，官方公开可查的口径）。
  final String freeQuota;

  /// 若该服务复用统一密钥库里的厂商 id，填在这里；否则留空。
  final String keyVendor;

  /// 是否允许在面向大众、可上架的客户端里出现。注册表里只允许 true。
  final bool commercialOk;
}

/// ★ 唯一白名单。新增条目必须能说清「官网 + 官方文档 + 免费开放口径」。
const List<PublicDataSource> kPublicDataSources = <PublicDataSource>[
  // ── 无需密钥、官方公开 ──
  PublicDataSource(
    id: 'open_meteo',
    name: 'Open-Meteo',
    category: SourceCategory.weather,
    homeUrl: 'https://open-meteo.com',
    docUrl: 'https://open-meteo.com/en/docs',
    needsKey: false,
    freeQuota: 'Free for non-commercial use, no key required',
  ),
  PublicDataSource(
    id: 'nominatim',
    name: 'OpenStreetMap Nominatim',
    category: SourceCategory.geo,
    homeUrl: 'https://nominatim.openstreetmap.org',
    docUrl: 'https://nominatim.org/release-docs/latest/api/Overview/',
    needsKey: false,
    freeQuota: 'Public, max 1 request/second, attribution required',
  ),
  PublicDataSource(
    id: 'open_library',
    name: 'Open Library',
    category: SourceCategory.metadata,
    homeUrl: 'https://openlibrary.org',
    docUrl: 'https://openlibrary.org/developers/api',
    needsKey: false,
    freeQuota: 'Public REST API, no key required',
  ),
  PublicDataSource(
    id: 'google_books',
    name: 'Google Books API',
    category: SourceCategory.metadata,
    homeUrl: 'https://books.google.com',
    docUrl: 'https://developers.google.com/books/docs/v1/using',
    needsKey: false,
    freeQuota: 'Public read access; key optional for higher quota',
  ),
  PublicDataSource(
    id: 'musicbrainz',
    name: 'MusicBrainz',
    category: SourceCategory.metadata,
    homeUrl: 'https://musicbrainz.org',
    docUrl: 'https://musicbrainz.org/doc/MusicBrainz_API',
    needsKey: false,
    freeQuota: 'Public, max 1 request/second, CC0 data',
  ),
  PublicDataSource(
    id: 'wikidata',
    name: 'Wikidata / Wikipedia',
    category: SourceCategory.search,
    homeUrl: 'https://www.wikidata.org',
    docUrl: 'https://www.wikidata.org/wiki/Wikidata:SPARQL_query_service',
    needsKey: false,
    freeQuota: 'Public, no key required, CC0 / CC BY-SA',
  ),
  PublicDataSource(
    id: 'github_rest',
    name: 'GitHub REST API',
    category: SourceCategory.search,
    homeUrl: 'https://docs.github.com',
    docUrl: 'https://docs.github.com/en/rest',
    needsKey: false,
    freeQuota: '60 requests/hour unauthenticated; more with a free token',
    keyVendor: 'github',
  ),
  PublicDataSource(
    id: 'anilist',
    name: 'AniList GraphQL',
    category: SourceCategory.metadata,
    homeUrl: 'https://anilist.co',
    docUrl: 'https://docs.anilist.co',
    needsKey: false,
    freeQuota: 'Public GraphQL, 90 requests/minute',
  ),

  // ── 官方免费密钥（用户填自己的）──
  PublicDataSource(
    id: 'aliyun_tts',
    name: 'Alibaba Cloud Speech',
    category: SourceCategory.tts,
    homeUrl: 'https://www.aliyun.com/product/nls',
    docUrl: 'https://help.aliyun.com/zh/nls/',
    needsKey: true,
    freeQuota: 'Official free quota; user supplies own key',
    keyVendor: 'aliyun',
  ),
  PublicDataSource(
    id: 'volc_tts',
    name: 'Volcengine Speech',
    category: SourceCategory.tts,
    homeUrl: 'https://www.volcengine.com/product/tts',
    docUrl: 'https://www.volcengine.com/docs/6561',
    needsKey: true,
    freeQuota: 'Official free quota; user supplies own key',
    keyVendor: 'bytedance',
  ),
  PublicDataSource(
    id: 'azure_speech_free',
    name: 'Azure Speech (F0)',
    category: SourceCategory.tts,
    homeUrl: 'https://azure.microsoft.com/products/ai-services/speech',
    docUrl: 'https://learn.microsoft.com/azure/ai-services/speech-service/',
    needsKey: true,
    freeQuota: 'Free tier: 5 audio hours/month',
  ),
  PublicDataSource(
    id: 'tmdb',
    name: 'TMDB',
    category: SourceCategory.metadata,
    homeUrl: 'https://www.themoviedb.org',
    docUrl: 'https://developer.themoviedb.org/docs/getting-started',
    needsKey: true,
    freeQuota: 'Free API key for non-commercial use, attribution required',
  ),
  PublicDataSource(
    id: 'omdb',
    name: 'OMDb API',
    category: SourceCategory.metadata,
    homeUrl: 'https://www.omdbapi.com',
    docUrl: 'https://www.omdbapi.com/#apikey',
    needsKey: true,
    freeQuota: 'Free key: 1,000 requests/day',
  ),
  PublicDataSource(
    id: 'lastfm',
    name: 'Last.fm',
    category: SourceCategory.metadata,
    homeUrl: 'https://www.last.fm/api',
    docUrl: 'https://www.last.fm/api',
    needsKey: true,
    freeQuota: 'Free API account, rate-limited',
  ),
  PublicDataSource(
    id: 'deepl_free',
    name: 'DeepL API Free',
    category: SourceCategory.translate,
    homeUrl: 'https://www.deepl.com',
    docUrl: 'https://developers.deepl.com/docs/getting-started',
    needsKey: true,
    freeQuota: 'Free tier: 500,000 characters/month',
    keyVendor: 'deepl',
  ),
  PublicDataSource(
    id: 'aliyun_bailian',
    name: 'Alibaba Cloud Bailian',
    category: SourceCategory.ai,
    homeUrl: 'https://bailian.console.aliyun.com',
    docUrl: 'https://help.aliyun.com/zh/model-studio/',
    needsKey: true,
    freeQuota: 'Official free quota per model; user supplies own key',
    keyVendor: 'aliyun',
  ),
  PublicDataSource(
    id: 'volc_doubao',
    name: 'Volcengine Doubao',
    category: SourceCategory.ai,
    homeUrl: 'https://www.volcengine.com',
    docUrl: 'https://www.volcengine.com/docs/82379',
    needsKey: true,
    freeQuota: 'Official free token quota; user supplies own key',
    keyVendor: 'bytedance',
  ),
  PublicDataSource(
    id: 'zhipu_glm',
    name: 'Zhipu GLM',
    category: SourceCategory.ai,
    homeUrl: 'https://open.bigmodel.cn',
    docUrl: 'https://docs.bigmodel.cn',
    needsKey: true,
    freeQuota: 'Official free tier; user supplies own key',
    keyVendor: 'zhipu',
  ),
  PublicDataSource(
    id: 'moonshot_kimi',
    name: 'Moonshot Kimi',
    category: SourceCategory.ai,
    homeUrl: 'https://platform.moonshot.cn',
    docUrl: 'https://platform.moonshot.cn/docs',
    needsKey: true,
    freeQuota: 'Official free tier; user supplies own key',
    keyVendor: 'moonshot',
  ),
  PublicDataSource(
    id: 'xiaomi_mimo',
    name: 'Xiaomi MiMo',
    category: SourceCategory.ai,
    homeUrl: 'https://mimo.ai.xiaomi.com',
    docUrl: 'https://mimo.ai.xiaomi.com/docs',
    needsKey: true,
    freeQuota: 'Official free tier; user supplies own key',
    keyVendor: 'xiaomi',
  ),
  PublicDataSource(
    id: 'tencent_hunyuan',
    name: 'Tencent Hunyuan',
    category: SourceCategory.ai,
    homeUrl: 'https://cloud.tencent.com/product/hunyuan',
    docUrl: 'https://cloud.tencent.com/document/product/1729',
    needsKey: true,
    freeQuota: 'Official free tier; user supplies own key',
    keyVendor: 'tencent',
  ),
];

/// 禁止出现在移动端注册表里的词（内容源 / 采集 / 盗版相关）。
const List<String> kMobileBannedTerms = <String>[
  '书源',
  '图源',
  '换源',
  '采集',
  '破解',
  '盗版',
  'copy_manga',
  'baozi',
  'komiic',
];

/// 按类别查（空类别 = 全部）。
List<PublicDataSource> publicSources([String category = '']) => <PublicDataSource>[
      for (final s in kPublicDataSources)
        if (category.isEmpty || s.category == category) s
    ];

/// 按 id 查；找不到返回 null（调用方自己决定降级，不抛错）。
PublicDataSource? publicSourceById(String id) {
  for (final s in kPublicDataSources) {
    if (s.id == id) return s;
  }
  return null;
}

/// 需要用户填官方密钥的那些。
List<PublicDataSource> sourcesNeedingKey() => <PublicDataSource>[
      for (final s in kPublicDataSources)
        if (s.needsKey) s
    ];

/// ★ 移动端准入闸门：任何一条不满足就不许下发到移动端。
/// 服务端也调用同规则的 Node 版（server/public-sources.js），两侧契约自检对齐。
bool isMobilePublicSourceAllowed(PublicDataSource s) {
  if (!s.commercialOk) return false;
  if (s.id.isEmpty || s.name.isEmpty || s.category.isEmpty) return false;
  if (!SourceCategory.all.contains(s.category)) return false;
  if (!s.homeUrl.startsWith('https://') || !s.docUrl.startsWith('https://')) {
    return false;
  }
  if (s.freeQuota.isEmpty) return false;
  final blob = '${s.id}|${s.name}|${s.homeUrl}|${s.docUrl}|${s.freeQuota}'
      .toLowerCase();
  for (final t in kMobileBannedTerms) {
    if (blob.contains(t.toLowerCase())) return false;
  }
  return true;
}

/// 移动端实际可见的清单（防御性收口：即使表里混进脏条目也不会下发）。
List<PublicDataSource> mobileVisibleSources() => <PublicDataSource>[
      for (final s in kPublicDataSources)
        if (isMobilePublicSourceAllowed(s)) s
    ];
