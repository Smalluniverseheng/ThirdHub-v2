// 设置互通桥自检（纯 Dart VM 可跑，零 Flutter 依赖）
//
//   dart.exe --disable-dart-dev --packages=.dart_tool/package_config.json \
//     tool/settings_bridge_selfcheck.dart
//
// 覆盖：云端键清单完整性 / 映射表健全性 / 各值转换双向 / 上行不伪造 / 下行不越界 /
//       覆盖率自洽，以及**一条反例回归**：证明"直接拿 38 个云端键读本机 prefs"必然全空
//       —— 这正是「设置同步点了没反应」的机械成因。
import '../lib/core/settings_bridge.dart';

int pass = 0, fail = 0;
void ck(String name, bool ok) {
  if (ok) { pass++; } else { fail++; print('  FAIL  $name'); }
}

/// 网页端 DEFAULT_SETTINGS 的键与顺序（照抄 js/store.js，用来钉住两端一致性）
const List<String> webDefaults = <String>[
  'theme', 'lang', 'readerFontSize', 'readerLineHeight', 'readerTheme', 'readerFlip',
  'comicMode', 'comicDir', 'proxyMode', 'proxyUrl', 'ttsRate',
  'ttsEngine', 'ttsCustomUrl', 'asrEngine', 'asrCustomUrl',
  'readerFont', 'readerFontWeight', 'readerPadding', 'readerParaGap', 'readerTextColor',
  'readerBgColor', 'readerBrightness', 'readerFullscreen', 'readerVolumeFlip', 'readerAutoScroll',
  'readerIllust', 'readerTapFlip', 'readerInfoBar',
  'comicLayout', 'comicFit', 'comicGap', 'comicBrightness', 'comicCropBorder', 'comicPreload',
  'navDesktop', 'navMobile', 'navWatch', 'aiDrawerSide',
];

/// 客户端 AppSettings 实际会写在 SharedPreferences 里的键（从 main.dart / novel_reader.dart 摘取）
const List<String> clientKeys = <String>[
  'locale', 'theme_mode', 'accent_color', 'splash_anim', 'nav_side', 'nav_style', 'orb_snap',
  'nav_autohide', 'auto_fs_sec', 'nav_swipe', 'fontSize', 'readerTheme', 'pageMode', 'reader_font',
  'reader_bg', 'reader_text', 'line_height', 'para_space', 'reader_margin', 'flip_mode', 'eye_care',
  'enc_mode', 'reader_brightness', 'vol_turn', 'reader_auto', 'reader_auto_sec', 'reader_landscape',
  'comic_mode', 'play_mode', 'music_quality', 'video_speed', 'ui_text_scale', 'content_filter',
];

void main() {
  // ── 1. 云端键清单必须与网页端逐字一致（含顺序）──
  print('== 1. 云端键清单 ==');
  ck('键数 = 38', SettingsBridge.cloudKeys.length == 38);
  ck('与 webDefaults 逐字且顺序一致',
      SettingsBridge.cloudKeys.length == webDefaults.length &&
      List.generate(webDefaults.length, (i) => SettingsBridge.cloudKeys[i] == webDefaults[i]).every((x) => x));
  ck('无重复键', SettingsBridge.cloudKeys.toSet().length == 38);

  // ── 2. 映射表健全性 ──
  print('== 2. 映射表 ==');
  ck('已接映射 13 条', SettingsBridge.bridges.length == 13);
  ck('每条映射的云端键都在 38 键内',
      SettingsBridge.bridges.every((b) => SettingsBridge.cloudKeys.contains(b.cloud)));
  ck('本机键不重复', SettingsBridge.bridges.map((b) => b.local).toSet().length == SettingsBridge.bridges.length);

  // ── 3. ★反例回归：直接读 38 个云端键 → 本机一个都命中不了 ──
  print('== 3. 反例回归（假同步的机械成因）==');
  final overlap = SettingsBridge.cloudKeys.where(clientKeys.contains).toList();
  // ★实测：全网只有一个同名键 —— `readerTheme`。但它是**同名不同型**：
  //   本机是 int(0夜/1日/2纸)，云端是字符串('night'/'day'/'paper'/…)。
  //   这种"看起来一样、其实不一样"的键比完全不同的键更危险：照名字直传会直接把
  //   int 塞进网页端（或反之），表现是主题莫名其妙被改。必须走映射层显式翻译。
  ck('38 键与本机键名的重叠恰好只有 readerTheme 一个（实得 ${overlap.length}: $overlap）',
      overlap.length == 1 && overlap.first == 'readerTheme');
  ck('同名键类型确实不同 ⇒ 名字直传必错（本机 int / 云端 String）',
      SettingsBridge.readerThemeToCloud(0) == 'night' && SettingsBridge.readerThemeFromCloud('night') == 0);
  // 于是"直接按云端键名读本机"的结果必然是空 → 上行静默不发
  final naive = <String, dynamic>{};
  for (final k in SettingsBridge.cloudKeys) { naive[k] = null; }
  naive.removeWhere((k, v) => v == null);
  ck('按云端键名直读本机 → 结果为空 Map（正是旧实现的 0 命中）', naive.isEmpty);
  // 而经映射层则能产出真值（见第 8 段）

  // ── 4. 主题 / 语言 ──
  print('== 4. 主题与语言 ==');
  ck('theme: system → auto', SettingsBridge.themeToCloud('system') == 'auto');
  ck('theme: dark 原样', SettingsBridge.themeToCloud('dark') == 'dark');
  ck('theme: auto → system', SettingsBridge.themeFromCloud('auto') == 'system');
  ck('theme 往返一致', SettingsBridge.themeFromCloud(SettingsBridge.themeToCloud('system')) == 'system');
  ck('lang: system → zh-CN', SettingsBridge.langToCloud('system') == 'zh-CN');
  ck('lang: 空 → zh-CN', SettingsBridge.langToCloud('') == 'zh-CN');
  ck('lang: zh-CN → system', SettingsBridge.langFromCloud('zh-CN') == 'system');
  ck('lang: en 保留', SettingsBridge.langFromCloud('en-US') == 'en-US');

  // ── 5. 阅读主题（本机 3 档 ↔ 云端 6 档，未知不下行）──
  print('== 5. 阅读主题 ==');
  ck('0 → night', SettingsBridge.readerThemeToCloud(0) == 'night');
  ck('1 → day', SettingsBridge.readerThemeToCloud(1) == 'day');
  ck('2 → paper', SettingsBridge.readerThemeToCloud(2) == 'paper');
  ck('越界 → null', SettingsBridge.readerThemeToCloud(9) == null);
  ck('night → 0', SettingsBridge.readerThemeFromCloud('night') == 0);
  ck('paper → 2', SettingsBridge.readerThemeFromCloud('paper') == 2);
  ck('云端 eye（本机无对应）→ null，不瞎猜', SettingsBridge.readerThemeFromCloud('eye') == null);
  ck('云端 blue → null', SettingsBridge.readerThemeFromCloud('blue') == null);

  // ── 6. 翻页（本机两键 ↔ 云端一键）──
  print('== 6. 翻页 ==');
  ck('pageMode=scroll → scroll', SettingsBridge.flipToCloud('slide', 'scroll') == 'scroll');
  ck('vertical → scroll', SettingsBridge.flipToCloud('vertical', 'paged') == 'scroll');
  ck('sim 保留', SettingsBridge.flipToCloud('sim', 'paged') == 'sim');
  ck('cover 保留', SettingsBridge.flipToCloud('cover', 'paged') == 'cover');
  ck('none 保留', SettingsBridge.flipToCloud('none', 'paged') == 'none');
  ck('未知值 → 兜底 slide', SettingsBridge.flipToCloud('wat', 'paged') == 'slide');

  // ── 7. 颜色 / 段间距 ──
  print('== 7. 颜色与间距 ==');
  ck('0（跟随主题）→ 空串', SettingsBridge.colorToCloud(0) == '');
  ck('0xFF4A3F30 → #4a3f30', SettingsBridge.colorToCloud(0xFF4A3F30) == '#4a3f30');
  ck('黑白补齐两位', SettingsBridge.colorToCloud(0xFF000102) == '#000102');
  ck('空串 → 0', SettingsBridge.colorFromCloud('') == 0);
  ck('#4a3f30 → 0xFF4A3F30', SettingsBridge.colorFromCloud('#4a3f30') == 0xFF4A3F30);
  ck('颜色往返一致', SettingsBridge.colorFromCloud(SettingsBridge.colorToCloud(0xFF4A3F30)!) == 0xFF4A3F30);
  ck('非法色长 → null', SettingsBridge.colorFromCloud('#abc') == null);
  ck('段间距 8px @17px → 0.47em', SettingsBridge.paraGapToCloud(8, 17) == 0.47);
  ck('段间距 0.47em @17px → 8.0px', SettingsBridge.paraGapFromCloud(0.47, 17) == 8.0);
  ck('字号为 0 不炸（返回 0）', SettingsBridge.paraGapToCloud(8, 0) == 0);

  // ── 8. 上行：真快照 → 云端（且不伪造未接键）──
  print('== 8. 上行 ==');
  final snap = <String, dynamic>{
    'theme_mode': 'dark',
    'locale': 'system',
    'fontSize': 20.0,
    'line_height': 1.9,
    'reader_font': 'default',
    'flip_mode': 'sim',
    'pageMode': 'paged',
    'readerTheme': 0,
    'reader_margin': 24.0,
    'para_space': 10.0,
    'reader_text': 0xFF4A3F30,
    'reader_brightness': 0.8,
    'vol_turn': true,
    'comic_mode': 'webtoon',
    // 以下本机有、但云端没有对应键 → 必须不上行
    'nav_swipe': true,
    'accent_color': 0xFF3B5BFD,
    'play_mode': 'rand',
  };
  final up = SettingsBridge.toCloud(snap);
  ck('上行产出非空（旧实现此处恒为空）', up.isNotEmpty);
  ck('上行键数 = 13（本快照 13 个可映射键都在）', up.length == 13);
  ck('theme = dark', up['theme'] == 'dark');
  ck('lang = zh-CN', up['lang'] == 'zh-CN');
  ck('readerFontSize = 20', up['readerFontSize'] == 20);
  ck('readerLineHeight = 1.9', up['readerLineHeight'] == 1.9);
  ck('readerFont: default → system', up['readerFont'] == 'system');
  ck('readerFlip = sim', up['readerFlip'] == 'sim');
  ck('readerTheme = night', up['readerTheme'] == 'night');
  ck('readerPadding = 24', up['readerPadding'] == 24);
  ck('readerParaGap = 0.5（10px / 20px 字号）', up['readerParaGap'] == 0.5);
  ck('readerTextColor = #4a3f30', up['readerTextColor'] == '#4a3f30');
  ck('readerBrightness = 0.8', up['readerBrightness'] == 0.8);
  ck('readerVolumeFlip = true', up['readerVolumeFlip'] == true);
  ck('comicLayout = webtoon', up['comicLayout'] == 'webtoon');
  ck('上行不含未映射的 accent_color/play_mode/nav_swipe',
      !up.containsKey('accent_color') && !up.containsKey('play_mode') && !up.containsKey('nav_swipe'));
  ck('上行不含本机没值的云端键（如 proxyMode）', !up.containsKey('proxyMode') && !up.containsKey('ttsRate'));
  ck('上行键全部属于 38 键', up.keys.every(SettingsBridge.cloudKeys.contains));
  // 空快照 → 空（绝不拿默认值去盖云端）
  ck('空快照 → 空 Map（不伪造）', SettingsBridge.toCloud(<String, dynamic>{}).isEmpty);

  // ── 9. 下行：云端 → 本机（含一键拆两键 / 忽略未接键）──
  print('== 9. 下行 ==');
  final down = SettingsBridge.fromCloud(<String, dynamic>{
    'theme': 'auto',
    'lang': 'zh-CN',
    'readerFontSize': 18,
    'readerLineHeight': 1.7,
    'readerFont': 'serif',
    'readerFlip': 'scroll',
    'readerTheme': 'night',
    'readerPadding': 20,
    'readerParaGap': 0.6,
    'readerTextColor': '',
    'readerBrightness': 1.0,
    'readerVolumeFlip': false,
    'comicLayout': 'paged',
    // 未接的云端键 → 必须被忽略
    'proxyMode': 'auto',
    'ttsRate': 1.0,
    'navWatch': 'bottom',
    'readerIllust': true,
  });
  Map<String, Object> asMap(List<MapEntry<String, Object>> l) => <String, Object>{for (final e in l) e.key: e.value};
  final dm = asMap(down);
  ck('滚动模式拆成两键（pageMode+flip_mode）', dm['pageMode'] == 'scroll' && dm['flip_mode'] == 'none');
  ck('theme auto → system', dm['theme_mode'] == 'system');
  ck('lang zh-CN → system', dm['locale'] == 'system');
  ck('readerFontSize 18 → fontSize 18.0', dm['fontSize'] == 18.0);
  ck('readerLineHeight → line_height', dm['line_height'] == 1.7);
  ck('readerFont serif → reader_font', dm['reader_font'] == 'serif');
  ck('readerTheme night → 0', dm['readerTheme'] == 0);
  ck('readerPadding → reader_margin', dm['reader_margin'] == 20.0);
  ck('readerParaGap 0.6em @18px → 10.8px', dm['para_space'] == 10.8);
  ck('readerTextColor 空 → reader_text 0', dm['reader_text'] == 0);
  ck('readerBrightness → reader_brightness', dm['reader_brightness'] == 1.0);
  ck('readerVolumeFlip false → vol_turn false', dm['vol_turn'] == false);
  ck('comicLayout paged → comic_mode paged', dm['comic_mode'] == 'paged');
  ck('未接云端键被忽略（proxyMode/ttsRate/navWatch/readerIllust）',
      !dm.containsKey('proxyMode') && !dm.containsKey('ttsRate') &&
      !dm.containsKey('navWatch') && !dm.containsKey('readerIllust'));
  ck('下行不含 null 值项', !down.any((e) => e.value == null));
  ck('非滚动时不下发 pageMode=scroll', () {
    final m = asMap(SettingsBridge.fromCloud(<String, dynamic>{'readerFlip': 'cover'}));
    return m['pageMode'] == 'paged' && m['flip_mode'] == 'cover';
  }());
  ck('云端给非法 readerFlip 值 → 不产生条目', SettingsBridge.fromCloud(<String, dynamic>{'readerFlip': 'zzz'}).isEmpty);

  // ── 10. 覆盖率自洽 ──
  print('== 10. 覆盖率 ==');
  final cov = SettingsBridge.coverage();
  ck('bridged + cloudOnly == 38',
      cov['bridged']!.length + cov['cloudOnly']!.length == 38);
  ck('bridged 与 cloudOnly 无交集',
      cov['bridged']!.toSet().intersection(cov['cloudOnly']!.toSet()).isEmpty);
  ck('cloudOnly 里确实没有已接通的键', !cov['cloudOnly']!.contains('theme'));
  ck('bridged 就是映射表的云端侧',
      cov['bridged']!.length == SettingsBridge.bridges.length);
  ck('localOnly 非空（如实列出只在手机上的设置）', cov['localOnly']!.isNotEmpty);

  // ── 11. 往返一致性（上行→下行应回到语义相同的值）──
  print('== 11. 往返 ==');
  final round = asMap(SettingsBridge.fromCloud(SettingsBridge.toCloud(snap)));
  ck('theme_mode 往返 = dark', round['theme_mode'] == 'dark');
  ck('fontSize 往返 = 20.0', round['fontSize'] == 20.0);
  ck('line_height 往返 = 1.9', round['line_height'] == 1.9);
  ck('readerTheme 往返 = 0', round['readerTheme'] == 0);
  ck('reader_font 往返（default→system）', round['reader_font'] == 'system');
  ck('flip_mode 往返 = sim', round['flip_mode'] == 'sim');
  ck('comic_mode 往返 = webtoon', round['comic_mode'] == 'webtoon');
  ck('color 往返 = 0xFF4A3F30', round['reader_text'] == 0xFF4A3F30);
  ck('locale 往返 = system', round['locale'] == 'system');
  ck('para_space 往返 = 10.0（px→em→px 不丢精度）', round['para_space'] == 10.0);
  ck('reader_margin 往返 = 24.0', round['reader_margin'] == 24.0);
  ck('reader_brightness 往返 = 0.8', round['reader_brightness'] == 0.8);
  ck('vol_turn 往返 = true', round['vol_turn'] == true);

  // ══════════════════════════════════════════════════════════════════════════
  // ── 12. th_settings 取行（一用户多行）──
  //
  // 为什么钉这里：`th_settings` 是「一用户多行」的通用键值表 —— 网页端
  // js/ai/ai-api.js 把各厂商 API Key 也写进同一张表（id = 'ai:key:<provider>'，
  // data 是**字符串**）。PostgREST 不保证顺序，所以读设置**必须按 id 挑行**。
  // 取错行有两个可观测后果，本段正面复现它们：
  //   ① settingsDown 读不到 settings → 写回 0 键 = 「点了同步没反应」
  //   ② settingsUp 合并基线变空 → 云端另 25 键 + kv 被抹掉（数据丢失）
  // 夹具用的是**真实云端抓下来的行形状**（账号 67fd9596…，2026-09-25 实测）。
  // ══════════════════════════════════════════════════════════════════════════
  print('== 12. th_settings 取行 ==');

  const String rpUid = '67fd9596-6843-4323-b732-78380aa8422e';
  // 真实形状：{ id, data: { settings: { s, kv }, updatedAt } }
  Map<String, dynamic> rpSettingsRow() => <String, dynamic>{
        'id': rpUid,
        'data': <String, dynamic>{
          'settings': <String, dynamic>{
            's': <String, dynamic>{for (final k in webDefaults) k: 'web-$k', 'theme': 'auto', 'lang': 'zh'},
            'kv': <String, dynamic>{'anchor:lastRead': 'book-42'},
          },
          'updatedAt': 1789137190113,
        },
      };
  // 真实形状：网页端 ai-api.js 写进来的 API Key 行 —— data 是**字符串**
  Map<String, dynamic> rpKeyRow() => <String, dynamic>{
        'id': 'ai:key:xiaomi',
        'data': 'sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      };
  // 客户端「读到一行之后」实际会取到几个键（与 cloud.dart 的读法一致）
  int rpKeyCount(Map<String, dynamic>? row) {
    final d = row == null ? null : row['data'];
    if (d is! Map) return 0;
    final st = d['settings'];
    if (st is! Map) return 0;
    final s = st['s'];
    if (s is! Map) return 0;
    return s.length;
  }

  final rpTrapFirst = <dynamic>[rpKeyRow(), rpSettingsRow()];
  final rpTrapLast = <dynamic>[rpSettingsRow(), rpKeyRow()];

  ck('空列表 → null', SettingsBridge.pickSettingsRow(<dynamic>[], rpUid) == null);
  ck('唯一行即设置行 → 取到它',
      SettingsBridge.pickSettingsRow(<dynamic>[rpSettingsRow()], rpUid)?['id'] == rpUid);
  ck('★ 陷阱行在前 → 仍取到设置行（旧写法 list.first 会取到陷阱行）',
      SettingsBridge.pickSettingsRow(rpTrapFirst, rpUid)?['id'] == rpUid);
  ck('★ 陷阱行在后 → 仍取到设置行',
      SettingsBridge.pickSettingsRow(rpTrapLast, rpUid)?['id'] == rpUid);
  ck('★ 两种顺序结果一致（与 PostgREST 返回顺序解耦）',
      SettingsBridge.pickSettingsRow(rpTrapFirst, rpUid)?['id'] ==
          SettingsBridge.pickSettingsRow(rpTrapLast, rpUid)?['id']);
  ck('三行（设置行 + key 行 + keys 列表行）也稳定取到设置行',
      SettingsBridge.pickSettingsRow(<dynamic>[
        rpKeyRow(),
        <String, dynamic>{'id': 'ai:keys:moonshot', 'data': <dynamic>['sk-1', 'sk-2']},
        rpSettingsRow(),
      ], rpUid)?['id'] == rpUid);
  ck('行里没有 id 字段 → 退回第一行（兼容历史数据）',
      SettingsBridge.pickSettingsRow(<dynamic>[
        <String, dynamic>{'data': 1}
      ], rpUid) != null);

  // 取错行的后果（正面复现，证明这条规则不是洁癖）
  final rpWrong = rpTrapFirst.first as Map<String, dynamic>;
  ck('陷阱行的 data 确实是字符串（不是 {settings:…}）', rpWrong['data'] is String);
  ck('★ 取错行 → settingsDown 读到 0 键（表现：点了同步没反应）', rpKeyCount(rpWrong) == 0);
  ck('★ 取对行 → 读到 38 键', rpKeyCount(SettingsBridge.pickSettingsRow(rpTrapFirst, rpUid)) == 38);

  // 合并语义：基线取错行会不会把云端另 25 键 + kv 抹掉
  Map<String, dynamic> rpMerge(Map<String, dynamic> row) {
    final d = row['data'];
    final Map<String, dynamic> cloudS =
        (d is Map && d['settings'] is Map && (d['settings'] as Map)['s'] is Map)
            ? Map<String, dynamic>.from(((d['settings'] as Map)['s']) as Map)
            : <String, dynamic>{};
    final Map<String, dynamic> cloudKv =
        (d is Map && d['settings'] is Map && (d['settings'] as Map)['kv'] is Map)
            ? Map<String, dynamic>.from(((d['settings'] as Map)['kv']) as Map)
            : <String, dynamic>{};
    for (final b in SettingsBridge.bridges) {
      cloudS[b.cloud] = 'mine-${b.cloud}';
    }
    return <String, dynamic>{'s': cloudS, 'kv': cloudKv};
  }

  final rpGood = rpMerge(SettingsBridge.pickSettingsRow(rpTrapFirst, rpUid)!);
  final rpBad = rpMerge(rpWrong);
  final rpCloudOnly = <String>[for (final b in SettingsBridge.bridges) b.cloud];
  ck('基线取对行：合并后仍 38 键', (rpGood['s'] as Map).length == 38);
  ck('基线取对行：云端独有 25 键全部保留',
      webDefaults.where((k) => !rpCloudOnly.contains(k)).every((k) => (rpGood['s'] as Map)[k] == 'web-$k'));
  ck('基线取对行：kv 保留', (rpGood['kv'] as Map)['anchor:lastRead'] == 'book-42');
  ck('★ 基线取错行：只剩 13 键（25 个云端键被抹掉）', (rpBad['s'] as Map).length == 13);
  ck('★ 基线取错行：kv 被清空（数据丢失）', (rpBad['kv'] as Map).isEmpty);
  ck('损失量 = 38 - 13 = 25，正好是「客户端不映射」的那批',
      (rpGood['s'] as Map).length - (rpBad['s'] as Map).length == 25);

  print('');
  print('PASS $pass   FAIL $fail');
  if (fail == 0) print('\n✅ 全部通过');
}
