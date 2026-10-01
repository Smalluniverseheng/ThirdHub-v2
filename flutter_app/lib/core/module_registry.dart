// 共享模块注册表 —— App（kModules 中文键）⇄ 网页端（BOARDS 英文 id）的唯一映射真相源。
//
// ★ 为什么需要这个文件（「两个产物、非常割裂」的机械成因）：
//   App 端模块注册表是 `main.dart` 的 kModules（约 60 个中文键），网页端是
//   `js/boards.js` 的 BOARDS（20 个英文 id）。两套 id 体系一个都对不上，
//   模块布局配置也各存各的（App `nav_modules` 仅本机 SharedPreferences；
//   网页 `nav:tabs-{watch|mobile|desktop}` 走 th_settings kv 云同步）——
//   于是「网页上改了导航，App 一点不变」，两端像两个产品。
//
// ★ 设计（并集注册表 + 各端投影）：
//   ① canonical id 以**网页 board id 为准**（英文短 id）；App 独有模块用英文短 id 自造。
//   ② 两端各渲染自己认识的 id 子集：网页 `loadEnabledTabs` 的
//      `.filter((id) => BOARDS.some(...))` 已天然丢弃不认识的 id（App 独有 id 无害）；
//      App 端 `applyNavIds` 同样只投影自己认识的（网页独有 id 无害）。
//   ③ **合并写**（mergeNavIds）：任何一端写布局时，把「本端不认识的 id」
//      按其在云端数组里的相对顺序保留在尾部 —— 不认识≠删除，这是两端
//      配置互不踩踏的关键。两端调用同一个算法（本文件与 js/module-registry.js 逐字钉住）。
//   ④ read 组多对一：网页端 v3.30.0 起小说/漫画/有声/音乐/视频已合并为
//      `read` 大板块（loadEnabledTabs 的 READ_GROUP 迁移），App 端仍是 5 个
//      独立模块。所以上行时这 5 个键压成一个 'read'（否则网页每启动一次就把
//      它们迁移掉，来回震荡）；下行 'read' 时按本机记忆的组内子集展开
//      （组开关语义：网页勾掉「阅读」= App 五个内容模块全隐藏）。
//
// 设计原则与 settings_bridge.dart 一致：宁缺勿错、纯 Dart 零依赖，
// 可被 tool/module_registry_selfcheck.dart 独立自检。

/// 注册表一行：canonical id ⇄ App 模块键集合 ⇄ 网页 board id。
class ModuleRegEntry {
  /// canonical id（网页 board id 为准；App 独有模块为自造英文短 id）
  final String id;

  /// App kModules 的中文键。read 组一行多个；网页独有模块为空。
  final List<String> appKeys;

  /// 网页 BOARDS 的 id。null = App 独有模块（网页端 filter 丢弃）。
  final String? webBoard;

  /// 显示名（两端通用的中文名，网页 boards.js 的 name 与 App kModules 的 name 同源）
  final String name;

  const ModuleRegEntry(this.id, this.name, this.appKeys, this.webBoard);
}

/// ★ REGISTRY-BEGIN —— 与 `D:/ai/deep seek/js/module-registry.js` 的 REGISTRY 逐字钉住。
/// 任一端增删行都必须同步另一端，`tools/check_module_registry.mjs` 会逐行比对。
const List<ModuleRegEntry> kModuleRegistry = <ModuleRegEntry>[
  // ── 双端共通（一一对应）──
  ModuleRegEntry('ai', 'AI', ['AI'], 'ai'),
  ModuleRegEntry('search', '搜索', ['搜索'], 'search'),
  ModuleRegEntry('novel', '小说', [], 'novel'),
  ModuleRegEntry('comic', '漫画', [], 'comic'),
  ModuleRegEntry('music', '音乐', [], 'music'),
  ModuleRegEntry('audio', '有声', [], 'audio'),
  ModuleRegEntry('video', '视频', [], 'video'),
  ModuleRegEntry('game', '游戏', ['游戏'], 'game'),
  ModuleRegEntry('community', '社区', ['社区'], 'community'),
  ModuleRegEntry('album', '相册', ['相册'], 'album'),
  ModuleRegEntry('toolbox', '工具', ['工具箱'], 'toolbox'),
  ModuleRegEntry('profile', '我的', ['我的'], 'profile'),
  // ── read 组（网页一个 read 大板块 ⇄ App 五个独立模块，多对一）──
  ModuleRegEntry('read', '阅读', ['小说', '漫画', '音乐', '视频', '有声书'], 'read'),
  // ── 网页独有板块（App 端 filter 丢弃，但 mergeNavIds 保序保留）──
  ModuleRegEntry('tavern', '酒馆', [], 'tavern'),
  ModuleRegEntry('storage', '存储', [], 'storage'),
  ModuleRegEntry('navstation', '导航', [], 'navstation'),
  ModuleRegEntry('compute', '后端', [], 'compute'),
  ModuleRegEntry('cloudphone', '云设备', [], 'cloudphone'),
  ModuleRegEntry('clouddrive', '云盘', [], 'clouddrive'),
  ModuleRegEntry('grade', '成绩', [], 'grade'),
  ModuleRegEntry('plugins', '插件', [], 'plugins'),
  // ── App 独有模块（网页端 filter 丢弃，但 mergeNavIds 保序保留）──
  ModuleRegEntry('peer', '端网', ['端网'], null),
  ModuleRegEntry('chat', '聊天', ['聊天'], null),
  ModuleRegEntry('forum', '论坛', ['论坛'], null),
  ModuleRegEntry('live', '直播', ['直播'], null),
  ModuleRegEntry('browser', '浏览器', ['浏览器'], null),
  ModuleRegEntry('files', '文件', ['文件'], null),
  ModuleRegEntry('jobs', '自动化任务', ['自动化任务'], null),
  ModuleRegEntry('notes', '笔记', ['笔记'], null),
  ModuleRegEntry('todo', '待办', ['待办'], null),
  ModuleRegEntry('recorder', '录音机', ['录音机'], null),
  ModuleRegEntry('calendar', '日历', ['日历'], null),
  ModuleRegEntry('reminders', '提醒中心', ['提醒中心'], null),
  ModuleRegEntry('diary', '日记', ['日记'], null),
  ModuleRegEntry('ledger', '记账', ['记账'], null),
  ModuleRegEntry('clipboard', '剪贴板', ['剪贴板'], null),
  ModuleRegEntry('bookmarks', '书签', ['书签'], null),
  ModuleRegEntry('snippets', '代码片段', ['代码片段'], null),
  ModuleRegEntry('markdown', 'Markdown', ['Markdown'], null),
  ModuleRegEntry('health', '健康记录', ['健康记录'], null),
  ModuleRegEntry('contacts', '通讯录备份', ['通讯录备份'], null),
  ModuleRegEntry('sms', '短信备份', ['短信备份'], null),
  ModuleRegEntry('podcast', '播客', ['播客'], null),
  // 「有声书」不单列 —— 它是 read 组五键之一（网页 audio（有声）同源）
  ModuleRegEntry('radio', '广播', ['广播'], null),
  ModuleRegEntry('shortplay', '短剧', ['短剧'], null),
  ModuleRegEntry('wallpaper', '壁纸', ['壁纸'], null),
  ModuleRegEntry('news', '资讯', ['资讯'], null),
  ModuleRegEntry('weather', '天气与快递', ['天气与快递'], null),
  ModuleRegEntry('recipe', '菜谱', ['菜谱'], null),
  ModuleRegEntry('flashcard', '记忆卡', ['记忆卡'], null),
  ModuleRegEntry('timetable', '课程表', ['课程表'], null),
  ModuleRegEntry('translate', '翻译', ['翻译'], null),
  ModuleRegEntry('scanner', '扫描仪', ['扫描仪'], null),
  ModuleRegEntry('qr', '二维码', ['二维码'], null),
  ModuleRegEntry('quicknote', '悬浮便签', ['悬浮便签'], null),
  ModuleRegEntry('calc', '计算器', ['计算器'], null),
  ModuleRegEntry('whiteboard', '白板', ['白板'], null),
  ModuleRegEntry('texttools', '文本工具箱', ['文本工具箱'], null),
  ModuleRegEntry('sensor', '传感器', ['传感器'], null),
  ModuleRegEntry('fileshare', '文件互传', ['文件互传'], null),
  ModuleRegEntry('print', '远程打印', ['远程打印'], null),
  ModuleRegEntry('sharedalbum', '共享相册', ['共享相册'], null),
  ModuleRegEntry('sharedlist', '共享清单', ['共享清单'], null),
  ModuleRegEntry('cinema', '家庭影院', ['家庭影院'], null),
  ModuleRegEntry('homemusic', '家庭音乐库', ['家庭音乐库'], null),
  ModuleRegEntry('camera', '摄像头', ['摄像头'], null),
  ModuleRegEntry('smarthome', '智能家居', ['智能家居'], null),
  ModuleRegEntry('devicelink', '设备互联', ['设备互联'], null),
  ModuleRegEntry('famcalendar', '家庭日历', ['家庭日历'], null),
  ModuleRegEntry('homehub', '家庭中心', ['家庭中心'], null),
  ModuleRegEntry('studyhub', '学习中心', ['学习中心'], null),
  ModuleRegEntry('audiohub', '音频中心', ['音频中心'], null),
  ModuleRegEntry('recordhub', '记录中心', ['记录中心'], null),
  ModuleRegEntry('backuphub', '备份迁移', ['备份迁移'], null),
];
// ★ REGISTRY-END

/// read 组的 App 模块键（网页端一个 'read' 板块 ⇄ App 五个独立模块）。
const List<String> kReadGroupAppKeys = <String>['小说', '漫画', '音乐', '视频', '有声书'];

// ═══ 模块改名映射(旧键 → 新键) ═══
// ★为什么必须有这张表：nav_modules 里存的是**模块键**。直接改键会让老用户
//   底部导航里那个模块被 `where(kModules.containsKey)` 过滤掉 —— 表现为
//   "升级后模块凭空消失"。所有键改名都必须在这里登记，读取时先迁移再校验。
// （第二十三轮从 main.dart 移入本文件：键迁移是模块键域的规范化职责，
//   云端 settingsUp 上行前也要走它，否则旧键查不到注册表映射会被静默丢弃。）
const Map<String, String> kModuleRenames = {
  '作业中心': '自动化任务',
  '学习工具': '记忆卡',
  '天气快递': '天气与快递',
};

// ═══ 聚合模块归属表 ═══
// ★用户诉求原话（2026-10-01）：「不是让你整合到某一个大模块，而是这些很多（的小模块）
//   其实是可以整理到（各自所属的）模块，就是整理到**多个**模块……这样而不是下落成
//   很多个模块。」「这些应该细分到，比如说影音的功能，你放在影音里面。」
//
// 这张表 = 「哪个小模块归到哪个大模块」的唯一真相源：
//   key   = 子模块的 kModules 键
//   value = 它所属聚合模块的 kModules 键
// **不在表里的键 = 本身就是顶层模块**（含 6 个聚合模块自己）。
//
// ★为什么放这里而不是 main.dart 的 ModuleDef 里：
//   表的唯一消费者是 `migrateModuleKeys`（模块键域规范化），而它被 nav_modules 的
//   **每一处读取**与**云端上行前**调用（saveNavModules / RootNav._load /
//   showNavSettings / ProBridge.setNavModules / Cloud 上行）。放 core/ 里纯 Dart
//   零依赖，才能被 tool/module_registry_selfcheck.dart 独立自检 —— 否则"归并表
//   某个 value 打错字"这种错只有把 App 装起来点进去才会发现。
const Map<String, String> kModuleHubOf = <String, String>{
  // ── 工具箱 ──
  '翻译': '工具箱',
  '扫描仪': '工具箱',
  '二维码': '工具箱',
  '悬浮便签': '工具箱', // 工具箱与记录中心都留着入口，但归属只登记一次
  '计算器': '工具箱',
  '白板': '工具箱',
  '文本工具箱': '工具箱',
  '传感器': '工具箱',
  '文件互传': '工具箱',
  '远程打印': '工具箱',
  // ── 家庭中心 ──
  '共享相册': '家庭中心',
  '共享清单': '家庭中心',
  '家庭影院': '家庭中心',
  '家庭音乐库': '家庭中心',
  '摄像头': '家庭中心',
  '智能家居': '家庭中心',
  '设备互联': '家庭中心',
  '家庭日历': '家庭中心',
  // ── 记录中心 ──
  '笔记': '记录中心',
  '日记': '记录中心',
  'Markdown': '记录中心',
  '代码片段': '记录中心',
  '书签': '记录中心',
  '剪贴板': '记录中心',
  // ── 音频中心 ──
  '播客': '音频中心',
  '有声书': '音频中心',
  '广播': '音频中心',
  // ── 学习中心 ──
  '记忆卡': '学习中心',
  '课程表': '学习中心',
  // ── 备份迁移 ──
  '通讯录备份': '备份迁移',
  '短信备份': '备份迁移',
};

/// 允许出现在归属表 value 侧（上层）的聚合模块键。只有这几个才配收纳别人。
const List<String> kHubModuleKeys = <String>[
  '工具箱',
  '家庭中心',
  '记录中心',
  '音频中心',
  '学习中心',
  '备份迁移',
];

/// 把持久化的模块键列表迁到当前形态：① 改过名的模块不会丢；② 小模块收进所属大模块。
List<String> migrateModuleKeys(Iterable<String> raw) {
  final renamed = <String>[];
  for (final k in raw) {
    final n = kModuleRenames[k] ?? k;
    if (!renamed.contains(n)) renamed.add(n);
  }
  // ★聚合归并：子模块 → 其所属聚合模块，占用原子模块的**位次**（保序）。
  //   为什么必须在「读」这一层做而不是只在显示层过滤：老用户的 nav_modules 里
  //   可能只有「翻译」而没有「工具箱」。若只把子模块从列表里过滤掉，结果是
  //   「翻译」消失、且「工具箱」也不出现 —— 功能凭空不见（最坏的升级体验）。
  //   归并后「工具箱」顶上「翻译」原来的位置，用户原来排的顺序感觉不变。
  final out = <String>[];
  for (final k in renamed) {
    final v = kModuleHubOf[k] ?? k;
    if (!out.contains(v)) out.add(v);
  }
  return out;
}

/// 顶层模块键（按传入的全量键顺序过滤）：不在归属表里的才算顶层。
/// ★显示层（首启引导的模块勾选 / 导航管理分类树 / 切换模块宫格）一律用它 ——
/// 这样"小模块收进大模块"才真的让**列表变短**，而不只是多摆一个聚合入口。
List<String> topModuleKeys(Iterable<String> allKeys) => [
      for (final k in allKeys)
        if (!kModuleHubOf.containsKey(k)) k
    ];

/// read 组的 canonical id（上行压缩目标、下行展开来源）。
const String kReadGroupId = 'read';

/// 网页端 READ_GROUP 迁移前的旧 id（loadEnabledTabs 会把它们并进 'read'）。
/// 下行遇到这些 id 一律按 'read' 组处理 —— 云端老布局（迁移前写入的
/// novel/comic/…）才不会在 App 端展开成空。
const List<String> kLegacyReadIds = <String>[
  'novel',
  'comic',
  'audio',
  'music',
  'video'
];

class ModuleRegistry {
  ModuleRegistry._();

  static final Map<String, ModuleRegEntry> _byId = {
    for (final e in kModuleRegistry) e.id: e,
  };
  static final Map<String, String> _appKeyToId = {
    for (final e in kModuleRegistry)
      for (final k in e.appKeys) k: e.id,
  };

  /// App 模块键 → canonical id（'小说'..'有声书' 全部 → 'read'）。不认识返回 null。
  static String? idOfAppKey(String appKey) {
    if (kReadGroupAppKeys.contains(appKey)) return kReadGroupId;
    return _appKeyToId[appKey];
  }

  /// canonical id → App 模块键列表（'read' → 五个键；网页独有 → 空）。
  static List<String> appKeysOfId(String id) =>
      _byId[id]?.appKeys ?? const <String>[];

  /// 该 id 网页端是否存在对应板块。
  static bool hasWebBoard(String id) => _byId[id]?.webBoard != null;

  /// 上行：App nav_modules（中文键，有序）→ canonical id 数组。
  /// read 组五个键压缩成一个 'read'（占首次出现位）；「我的」固定不占名额，剔除。
  static List<String> navIdsOf(List<String> appKeys) {
    final out = <String>[];
    for (final k in appKeys) {
      if (k == '我的') continue; // profile 两端都固定，不进布局数组
      final id = idOfAppKey(k);
      if (id == null || out.contains(id)) continue;
      out.add(id);
    }
    return out;
  }

  /// 下行：canonical id 数组 → App nav_modules（中文键，有序）。
  /// 只投影 App 认识的 id（网页独有 id 跳过——不认识≠删除，合并时会带回去）。
  /// [readGroup] 是本机记忆的 read 组内子集：null = 无记忆（默认五个全开）；
  /// **空列表 = 记忆为全关**（组开关语义）；'read' 在云端布局里 → 展开成子集，
  /// 不在 → 五个全隐。
  /// 「我的」不在输入里也会补到尾部（两端都固定保留）。
  static List<String> applyNavIds(List<String> ids, {List<String>? readGroup}) {
    final group = readGroup == null
        ? kReadGroupAppKeys
        : readGroup.where(kReadGroupAppKeys.contains).toList();
    final out = <String>[];
    for (final id in ids) {
      if (id == kReadGroupId || kLegacyReadIds.contains(id)) {
        for (final k in group) {
          if (!out.contains(k)) out.add(k);
        }
        continue;
      }
      for (final k in appKeysOfId(id)) {
        if (k == '我的') continue; // 统一到尾部补，保证恒在最后
        if (!out.contains(k)) out.add(k);
      }
    }
    if (!out.contains('我的')) out.add('我的');
    return out;
  }

  /// 合并写（两端同一算法）：本端认识的 id 按 [ownIds] 新顺序；云端数组里
  /// 本端不认识的 id 保持相对顺序追加在尾部。不认识≠删除。
  ///
  /// [knownIds] 是「本端认识的 id 集合」（App 端 = 有 App 键的 id ∪ profile）。
  static List<String> mergeNavIds(List<String> ownIds, List<String>? cloudArr,
      {required Set<String> knownIds}) {
    final out = <String>[];
    for (final id in ownIds) {
      if (knownIds.contains(id) && !out.contains(id)) out.add(id);
    }
    if (cloudArr != null) {
      for (final id in cloudArr) {
        if (!knownIds.contains(id) && !out.contains(id)) out.add(id);
      }
    }
    return out;
  }

  /// App 端「认识」的 id 集合 = 有 App 键的 id + profile（read 组算认识）。
  static Set<String> get appKnownIds => {
        for (final e in kModuleRegistry)
          if (e.appKeys.isNotEmpty) e.id,
      };

  /// 自检：表体完整性（id 唯一、App 键不重复、read 组一致、id 形状合法）。
  /// 返回问题清单（空 = 全绿）。给 tool/module_registry_selfcheck.dart 用。
  static List<String> selfcheck({required List<String> allAppKeys}) {
    final issues = <String>[];
    final seenIds = <String>{};
    final seenKeys = <String>{};
    for (final e in kModuleRegistry) {
      if (!seenIds.add(e.id)) issues.add('重复 id: ${e.id}');
      if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(e.id)) {
        issues.add('id 形状非法: ${e.id}');
      }
      if (e.id == kReadGroupId) {
        if (e.appKeys.join(',') != kReadGroupAppKeys.join(',')) {
          issues.add('read 组行与 kReadGroupAppKeys 不一致');
        }
      } else {
        for (final k in e.appKeys) {
          if (kReadGroupAppKeys.contains(k)) {
            issues.add('read 组键 $k 出现在非 read 行 ${e.id}');
          }
        }
      }
      for (final k in e.appKeys) {
        if (!seenKeys.add(k)) {
          issues.add('App 键重复登记: $k（${e.id}）');
        }
        if (!allAppKeys.contains(k)) {
          issues.add('App 键不在 kModules 里: $k（${e.id}）');
        }
      }
      if (e.id != kReadGroupId && e.appKeys.length > 1) {
        issues.add('${e.id} 有多于一个 App 键（只有 read 组允许）');
      }
    }
    // read 组的每个键都必须在注册表里通过 read 行登记过（防漏登）
    for (final k in kReadGroupAppKeys) {
      if (!seenKeys.contains(k)) issues.add('read 组键未登记: $k');
    }
    // ★聚合归属表校验：归属表打错一个 value，用户就会看到「聚合模块把某个模块
    //   吞了却不显示」或「子模块彻底消失」。这种错静态必须拦住（装 App 才发现的代价太高）。
    for (final e in kModuleHubOf.entries) {
      if (!kHubModuleKeys.contains(e.value)) {
        issues.add('归属表 ${e.key} → ${e.value}：${e.value} 不是聚合模块');
      }
      if (e.key == e.value) issues.add('归属表自指: ${e.key}');
      if (kHubModuleKeys.contains(e.key)) {
        issues.add('聚合模块 ${e.key} 不应有归属（它自己就是顶层）');
      }
      if (!allAppKeys.contains(e.key)) {
        issues.add('归属表里的子模块不在 kModules 里: ${e.key}');
      }
      if (!allAppKeys.contains(e.value)) {
        issues.add('归属表的聚合模块不在 kModules 里: ${e.value}');
      }
    }
    for (final h in kHubModuleKeys) {
      if (!kModuleHubOf.containsValue(h)) {
        issues.add('聚合模块 $h 没有收纳任何子模块（空壳入口）');
      }
      if (!allAppKeys.contains(h)) issues.add('聚合模块不在 kModules 里: $h');
    }
    // topModuleKeys 的语义：聚合模块恒存在、子模块恒不出现
    final top = topModuleKeys(allAppKeys);
    for (final h in kHubModuleKeys) {
      if (allAppKeys.contains(h) && !top.contains(h)) {
        issues.add('聚合模块 $h 被 topModuleKeys 排除了');
      }
    }
    for (final k in kModuleHubOf.keys) {
      if (top.contains(k)) issues.add('子模块 $k 仍出现在顶层列表里');
    }
    return issues;
  }
}
