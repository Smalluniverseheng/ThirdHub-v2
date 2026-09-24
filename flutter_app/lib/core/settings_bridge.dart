// 设置互通桥 —— 本机 SharedPreferences 键 ⇄ 网页端 38 键的映射与格式转换。
//
// ★ 为什么需要这个文件（这才是「跟网站的同步」的真正难点）：
//   网页端（js/store.js 的 DEFAULT_SETTINGS）用一套 camelCase 键名：
//     theme / lang / readerFontSize / readerLineHeight / readerTheme('night') / readerFlip / …
//   而 Flutter 客户端（main.dart 的 AppSettings）用另一套完全不同的键名与类型：
//     theme_mode / locale / fontSize / line_height / readerTheme(0|1|2) / flip_mode / …
//   **两套键名一个都不重名**。所以「直接把 38 个键名拿来读本机 prefs」必然是全部取空
//   → 上行时 s.isEmpty → 静默不发 → 表现为「设置同步点了没反应」，且不报任何错。
//   这正是「假同步」的机械成因，必须先有映射层，再谈上传下载。
//
// 设计原则（宁缺勿错）：
//   ① 只映射**语义确实对应**的键。单位/取值域不同的（如 web readerAutoScroll 是 px/s、
//      本机 reader_auto_sec 是翻页间隔秒数）一律**不映射**，并在 coverage() 里如实列出。
//   ② 一个云端键可能对应本机两个键（readerFlip='scroll' → pageMode+flip_mode），
//      所以下行返回的是「本机写入项列表」而不是 1:1 的 Map。
//   ③ 本文件**零依赖**（不 import flutter），可被 tool/settings_bridge_selfcheck.dart 纯 Dart 自检。

/// 单向/双向转换的一对。
class Bridge {
  /// 云端 settings.s 的键名（与网页端 DEFAULT_SETTINGS 逐字一致）
  final String cloud;

  /// 本机 prefs 的键名
  final String local;

  const Bridge(this.cloud, this.local);
}

class SettingsBridge {
  SettingsBridge._();

  /// 网页端 38 个键的权威清单（与 `D:/ai/deep seek/js/store.js` 的 DEFAULT_SETTINGS 逐字一致）。
  /// 顺序也照抄，方便两端肉眼比对。★任一端增删键都必须同步这里，否则 coverage() 会说谎。
  static const List<String> cloudKeys = <String>[
    'theme', 'lang', 'readerFontSize', 'readerLineHeight', 'readerTheme', 'readerFlip',
    'comicMode', 'comicDir', 'proxyMode', 'proxyUrl', 'ttsRate',
    'ttsEngine', 'ttsCustomUrl', 'asrEngine', 'asrCustomUrl',
    'readerFont', 'readerFontWeight', 'readerPadding', 'readerParaGap', 'readerTextColor',
    'readerBgColor', 'readerBrightness', 'readerFullscreen', 'readerVolumeFlip', 'readerAutoScroll',
    'readerIllust', 'readerTapFlip', 'readerInfoBar',
    'comicLayout', 'comicFit', 'comicGap', 'comicBrightness', 'comicCropBorder', 'comicPreload',
    'navDesktop', 'navMobile', 'navWatch', 'aiDrawerSide',
  ];

  /// 已接通的映射（★这张表就是「两端能共享哪些设置」的全部事实来源）
  static const List<Bridge> bridges = <Bridge>[
    Bridge('theme', 'theme_mode'),
    Bridge('lang', 'locale'),
    Bridge('readerFontSize', 'fontSize'),
    Bridge('readerLineHeight', 'line_height'),
    Bridge('readerFont', 'reader_font'),
    Bridge('readerFlip', 'flip_mode'),
    Bridge('readerTheme', 'readerTheme'),
    Bridge('readerPadding', 'reader_margin'),
    Bridge('readerParaGap', 'para_space'),
    Bridge('readerTextColor', 'reader_text'),
    Bridge('readerBrightness', 'reader_brightness'),
    Bridge('readerVolumeFlip', 'vol_turn'),
    Bridge('comicLayout', 'comic_mode'),
  ];

  // ── 值转换小工具 ──

  /// 主题：本机 `system` ⇄ 网页端 `auto`（语义相同、写法不同）
  static String themeToCloud(String v) => v == 'system' ? 'auto' : v;
  static String themeFromCloud(String v) => v == 'auto' ? 'system' : v;

  /// 语言：本机 `system`（跟随系统）⇄ 网页端具体语言码。跟随系统在网页端等价于中文。
  static String langToCloud(String v) => (v.isEmpty || v == 'system') ? 'zh-CN' : v;
  static String langFromCloud(String v) => v == 'zh-CN' ? 'system' : v;

  /// 阅读主题：本机 int(0夜 1日 2纸) ⇄ 网页端字符串(6 种)。
  /// 网页端 eye/blue/green 本机没有对应 → 不下行（返回 null 由调用方跳过）。
  static const List<String> _readerThemeOrder = <String>['night', 'day', 'paper'];
  static String? readerThemeToCloud(int i) =>
      (i >= 0 && i < _readerThemeOrder.length) ? _readerThemeOrder[i] : null;
  static int? readerThemeFromCloud(String v) {
    final i = _readerThemeOrder.indexOf(v);
    return i < 0 ? null : i;
  }

  /// 翻页：本机 flip_mode(sim/cover/slide/vertical/none) → 网页端 readerFlip(slide/cover/sim/none/scroll)
  static String flipToCloud(String flip, String pageMode) {
    if (pageMode == 'scroll') return 'scroll';
    if (flip == 'vertical') return 'scroll';
    const ok = <String>['slide', 'cover', 'sim', 'none'];
    return ok.contains(flip) ? flip : 'slide';
  }

  /// 字体：本机 'default' 是历史值，等价网页端 'system'
  static String fontToCloud(String v) => v == 'default' ? 'system' : v;
  static String fontFromCloud(String v) => v;

  /// 颜色：本机 int(ARGB) ⇄ 网页端 '#rrggbb'。本机 0 = 跟随主题（网页端用空串表示同一意思）。
  static String? colorToCloud(int argb) {
    if (argb == 0) return '';
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  static int? colorFromCloud(String v) {
    if (v.isEmpty) return 0;
    final h = v.startsWith('#') ? v.substring(1) : v;
    if (h.length != 6) return null;
    final n = int.tryParse(h, radix: 16);
    return n == null ? null : (0xFF000000 | n);
  }

  /// 段间距：本机是像素、网页端是 em。按字号换算，保证物理视觉接近。
  static double paraGapToCloud(double px, double fontPx) =>
      fontPx <= 0 ? 0 : double.parse((px / fontPx).toStringAsFixed(2));
  static double paraGapFromCloud(double em, double fontPx) =>
      double.parse((em * (fontPx <= 0 ? 17 : fontPx)).toStringAsFixed(1));

  /// 漫画布局：本机 comic_mode(webtoon|paged) ⇄ 网页端 comicLayout(paged|webtoon|double)。
  /// 网页端 double 本机没有 → 不下行。
  static String? comicLayoutToCloud(String v) {
    if (v == 'webtoon' || v == 'paged') return v;
    return null;
  }

  static String? comicLayoutFromCloud(String v) {
    if (v == 'webtoon' || v == 'paged') return v;
    return null;
  }

  // ── 上行：本机 prefs 快照 → 云端 settings.s ──

  /// [local] 是**本机 prefs 的原始键值快照**（`SharedPreferences.getKeys()` 逐键取值）。
  /// 只放「本机真的有这个值」的键 —— 本机没有就别写，避免用默认值把云端已有的设置盖掉。
  static Map<String, dynamic> toCloud(Map<String, dynamic> local) {
    final out = <String, dynamic>{};

    void put(String k, dynamic v) { if (v != null) out[k] = v; }

    for (final b in bridges) {
      if (!local.containsKey(b.local)) continue;
      final v = local[b.local];
      switch (b.cloud) {
        case 'theme':
          if (v is String) put('theme', themeToCloud(v));
          break;
        case 'lang':
          if (v is String) put('lang', langToCloud(v));
          break;
        case 'readerFontSize':
          if (v is num) put('readerFontSize', v.toInt());
          break;
        case 'readerLineHeight':
          if (v is num) put('readerLineHeight', double.parse(v.toStringAsFixed(2)));
          break;
        case 'readerFont':
          if (v is String) put('readerFont', fontToCloud(v));
          break;
        case 'readerFlip':
          // 本机是两个键合起来表达网页端一个键
          final flip = (local['flip_mode'] ?? 'slide').toString();
          final pageMode = (local['pageMode'] ?? 'paged').toString();
          put('readerFlip', flipToCloud(flip, pageMode));
          break;
        case 'readerTheme':
          if (v is int) put('readerTheme', readerThemeToCloud(v));
          break;
        case 'readerPadding':
          if (v is num) put('readerPadding', v.round());
          break;
        case 'readerParaGap':
          if (v is num) {
            final fs = (local['fontSize'] as num?)?.toDouble() ?? 17;
            put('readerParaGap', paraGapToCloud(v.toDouble(), fs));
          }
          break;
        case 'readerTextColor':
          if (v is int) put('readerTextColor', colorToCloud(v));
          break;
        case 'readerBrightness':
          if (v is num) put('readerBrightness', v.toDouble());
          break;
        case 'readerVolumeFlip':
          if (v is bool) put('readerVolumeFlip', v);
          break;
        case 'comicLayout':
          if (v is String) put('comicLayout', comicLayoutToCloud(v));
          break;
      }
    }
    out.removeWhere((k, v) => v == null);
    return out;
  }

  // ── 下行：云端 settings.s → 本机写入项 ──

  /// 返回 [本机键, 本机值] 列表。云端多出来的键、或本机没有对应的键，**一律忽略**。
  static List<MapEntry<String, Object>> fromCloud(Map<String, dynamic> cloud) {
    final out = <MapEntry<String, Object>>[];
    final fontPx = (cloud['readerFontSize'] as num?)?.toDouble() ?? 17;

    void add(String k, Object? v) { if (v != null) out.add(MapEntry(k, v)); }
    bool has(String k) => cloud.containsKey(k);

    if (has('theme') && cloud['theme'] is String) add('theme_mode', themeFromCloud(cloud['theme'] as String));
    if (has('lang') && cloud['lang'] is String) add('locale', langFromCloud(cloud['lang'] as String));
    if (has('readerFontSize') && cloud['readerFontSize'] is num) add('fontSize', (cloud['readerFontSize'] as num).toDouble());
    if (has('readerLineHeight') && cloud['readerLineHeight'] is num) add('line_height', (cloud['readerLineHeight'] as num).toDouble());
    if (has('readerFont') && cloud['readerFont'] is String) add('reader_font', fontFromCloud(cloud['readerFont'] as String));

    // readerFlip='scroll' 拆成「页面滚动模式」，否则写回 flip_mode
    if (has('readerFlip') && cloud['readerFlip'] is String) {
      final f = cloud['readerFlip'] as String;
      if (f == 'scroll') { add('pageMode', 'scroll'); add('flip_mode', 'none'); }
      else if (f == 'slide' || f == 'cover' || f == 'sim' || f == 'none') { add('pageMode', 'paged'); add('flip_mode', f); }
    }

    if (has('readerTheme') && cloud['readerTheme'] is String) add('readerTheme', readerThemeFromCloud(cloud['readerTheme'] as String));
    if (has('readerPadding') && cloud['readerPadding'] is num) add('reader_margin', (cloud['readerPadding'] as num).toDouble());
    if (has('readerParaGap') && cloud['readerParaGap'] is num) add('para_space', paraGapFromCloud((cloud['readerParaGap'] as num).toDouble(), fontPx));
    if (has('readerTextColor') && cloud['readerTextColor'] is String) add('reader_text', colorFromCloud(cloud['readerTextColor'] as String));
    if (has('readerBrightness') && cloud['readerBrightness'] is num) add('reader_brightness', (cloud['readerBrightness'] as num).toDouble());
    if (has('readerVolumeFlip') && cloud['readerVolumeFlip'] is bool) add('vol_turn', cloud['readerVolumeFlip'] as bool);
    if (has('comicLayout') && cloud['comicLayout'] is String) add('comic_mode', comicLayoutFromCloud(cloud['comicLayout'] as String));

    return out;
  }

  /// 诚实清单 —— 给「同步范围说明」弹窗用，也防止以后有人以为「全同步了」。
  /// 返回 { 'bridged': [...], 'cloudOnly': [...], 'localOnly': [...] }
  static Map<String, List<String>> coverage() {
    final bridged = <String>[for (final b in bridges) b.cloud];
    final cloudOnly = <String>[for (final k in cloudKeys) if (!bridged.contains(k)) k];
    const localOnly = <String>[
      'nav_style', 'nav_side', 'nav_swipe', 'nav_autohide', 'orb_snap', 'auto_fs_sec',
      'accent_color', 'splash_anim', 'ui_text_scale', 'content_filter', 'eye_care',
      'reader_bg', 'reader_auto', 'reader_auto_sec', 'reader_landscape', 'enc_mode',
      'play_mode', 'music_quality', 'video_speed',
    ];
    return <String, List<String>>{'bridged': bridged, 'cloudOnly': cloudOnly, 'localOnly': localOnly};
  }

  /// 从一批 `th_settings` 行里挑出「设置行」。
  ///
  /// ★ 必须**挑**，不能取第一个 —— 这张表是「一用户多行」的通用键值表：
  ///   网页端 `js/ai/ai-api.js` 会把各厂商的 API Key / Key 列表也写进来，id 是
  ///   `ai:key:<provider>` / `ai:keys:<provider>`，而它们的 `data` 是**字符串或数组**，
  ///   不是 `{settings:{…}}`。实测真实账号 `67fd9596…` 就同时有两行
  ///   （`id=<uid>` 与 `id=ai:key:xiaomi`）。PostgREST **不保证返回顺序**，取 first
  ///   有概率取到那种行：
  ///     · `settingsDown()` 读不到 `settings` → 写回 0 个键 → 表现就是「点了同步没反应」；
  ///     · `settingsUp()` 的合并基线变空 → 只把认识的 13 键写回 `id=<uid>` 行
  ///       → 云端另外 25 个键连同 `kv` 一起被抹掉（这正是「整体覆盖」那类数据丢失）。
  ///   网页端 `js/modules/settings-sync.js` 的 `rows.find((r) => r.id === u.id) || rows[0]`
  ///   就是正确写法，这里与它**对齐**（找不到同名行时退回第一行，兼容历史数据）。
  ///
  /// 放在本文件（而非 `cloud.dart`）是因为：本文件是**零 Flutter 依赖**的纯 Dart，
  /// 能进 `_probe/run_checks.sh` 的 VM 自检 —— 本机 `dart analyze` 已废（管道池耗尽），
  /// 纯 Dart 自检是唯一能本地跑起来的类型/逻辑闸门。
  static Map<String, dynamic>? pickSettingsRow(List<dynamic> rows, String uid) {
    if (rows.isEmpty) return null;
    for (final e in rows) {
      final m = Map<String, dynamic>.from(e as Map);
      if (m['id'] == uid) return m;
    }
    return Map<String, dynamic>.from(rows.first as Map);
  }
}
