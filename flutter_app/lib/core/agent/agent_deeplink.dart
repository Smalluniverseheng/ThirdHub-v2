// 深链 → 指令序列（纯 Dart，不 import flutter，可 `dart test`）
//
// 存在的理由：用户要的是「一条指令跳到对应功能」，而不是「AI 自己猜着点」。
// 猜测路径每次都可能点错；深链是确定的 —— 同一个字符串永远落到同一个页面。
//
// 所以这里只做一件事：把 `thirdhub://…` 翻译成控制总线能执行的步骤数组。
// 三个消费方共用同一份翻译，避免三处各写一套：
//   ① 外部意图（浏览器/别的 App 点链接 → IntentRouter）
//   ② AI 控制总线的 `deeplink` op
//   ③ 应用内 AI 自动驾驶（模型可以直接下 `deeplink` 指令，比连点三下更稳）
//
// 支持的写法（大小写无关，中英文宿主名都认）：
//   thirdhub://video                      打开视频
//   thirdhub://video?platform=hongguo     视频 + 切到红果
//   thirdhub://bili                       视频 + B 站（等价 platform=bili）
//   thirdhub://video/hongguo              同上，平台写在路径里
//   thirdhub://novel?q=斗破苍穹            小说 + 搜索
//   thirdhub://search?q=周杰伦&kind=music  搜索 + 限定音乐类型
//   thirdhub://open?module=漫画            指定模块
//   thirdhub://do?action=name&k=v          调前端具名动作（eval）
//
// 解析失败一律返回空数组（而不是抛异常）：深链来自外部不可信输入，
// 「不认识就当没发生」比「崩一次」合理。

class AgentDeeplink {
  const AgentDeeplink._();

  /// 唯一协议名。改这里等于换协议，native 清单也要同步改。
  static const String scheme = 'thirdhub';

  /// 模块别名 → kModules 的真实键名。
  ///
  /// 为什么要有别名：英文/拼音/口语说法都得能用（b站 / bili / 哔哩 …），
  /// 否则「AI 说得出但跳不过去」就会变成又一轮"它说做了其实没做"。
  static const Map<String, String> moduleAlias = {
    // 五大板块
    'novel': '小说', 'book': '小说', 'novels': '小说', '小说': '小说',
    'comic': '漫画', 'manga': '漫画', 'comics': '漫画', '漫画': '漫画',
    'video': '视频', 'movie': '视频', 'videos': '视频', '视频': '视频',
    'music': '音乐', 'audio': '音乐', 'song': '音乐', '音乐': '音乐',
    // B 站 / 红果不是独立模块，是视频里的平台 —— 这里标出来，
    // 解析时补一条 platform 步骤（少了它只会停在视频首页，等于没跳）。
    'bili': '#bili', 'bilibili': '#bili', 'b站': '#bili', '哔哩哔哩': '#bili',
    'hongguo': '#hongguo', 'redfruit': '#hongguo', '红果': '#hongguo',
    '红果短剧': '#hongguo', '短剧': '#hongguo',
    // 其它常跳的
    'search': '搜索', '搜索': '搜索',
    'me': '我的', 'profile': '我的', '我的': '我的',
    'ai': 'AI',
    'free': '开放源', '开放源': '开放源',
    'live': '直播', '直播': '直播',
    'chat': '聊天', '聊天': '聊天',
    'notes': '笔记', '笔记': '笔记',
    'todo': '待办', '待办': '待办',
    'gallery': '相册', '相册': '相册',
    'files': '文件', '文件': '文件',
    'browser': '浏览器', '浏览器': '浏览器',
    'calendar': '日历', '日历': '日历',
    // ★4.81.83 补登：agent_map.dart 里的模块地图会把这些深链直接交给模型，
    //   这里缺一个别名，模型给出的链接就会解析成空 → "说跳了其实没跳"。
    //   单测 test/agent_map_test.dart 会逐条校验，别再漏。
    'tavern': '酒馆', '酒馆': '酒馆',
    'peer': '端网', '端网': '端网',
    'community': '社区', '社区': '社区',
    'forum': '论坛', '论坛': '论坛',
    'game': '游戏', 'games': '游戏', '游戏': '游戏',
    'jobs': '自动化任务', 'auto': '自动化任务', '自动化任务': '自动化任务',
    'recorder': '录音机', '录音机': '录音机',
    'diary': '日记', '日记': '日记',
    'ledger': '记账', '记账': '记账',
    'bookmarks': '书签', '书签': '书签',
    'reminders': '提醒中心', '提醒中心': '提醒中心',
    'podcast': '播客', '播客': '播客',
    'audiobook': '有声书', '有声书': '有声书',
  };

  /// 真实存在的模块名（与 main.dart 的 kModules 对齐）。
  ///
  /// 校验它的意义：深链来自外部/IPC，一个手写的 `thirdhub://abc` 如果被
  /// 原样下发成 nav，会静默跳到"找不到模块"，用户只会看到什么都没发生。
  /// 宁可在解析阶段就返回空，让调用方知道这条链接不认识。
  static const Set<String> knownModules = {
    '搜索', '开放源', '小说', '漫画', '视频', '音乐', 'AI', '端网', '聊天', '游戏',
    '社区', '酒馆', '论坛', '直播', '浏览器', '相册', '文件', '我的', '自动化任务',
    '笔记', '待办', '录音机', '日历', '提醒中心', '日记', '记账', '剪贴板', '书签',
    '代码片段', 'Markdown', '健康记录', '通讯录备份', '短信备份', '播客', '有声书',
    '广播', '壁纸', '资讯', '天气与快递', '菜谱', '记忆卡', '课程表', '翻译', '扫描仪',
    '二维码', '悬浮便签', '计算器', '白板', '文本工具箱', '传感器', '文件互传',
    '远程打印', '共享相册', '共享清单', '家庭影院', '家庭音乐库', '摄像头',
  };

  /// 平台别名 → 视频页平台逻辑名（与 main.dart 的 _agentPlatformAlias 对齐）。
  static const Map<String, String> platformAlias = {
    'hongguo': '红果', '红果': '红果', '短剧': '红果', 'redfruit': '红果',
    'bili': '哔哩哔哩', 'bilibili': '哔哩哔哩', 'b站': '哔哩哔哩',
    '哔哩哔哩': '哔哩哔哩', '哔哩': '哔哩哔哩',
    'library': '片库', '片库': '片库', 'shelf': '片库', '收藏': '片库',
    'history': '历史', '历史': '历史', 'recent': '历史',
    'discover': '发现', '发现': '发现',
    'search': '搜索',
  };

  /// 搜索类型别名 → 搜索页的 typeFilter 语义名（由 search 动作自己解释）。
  static const Map<String, String> kindAlias = {
    'novel': 'novel', 'book': 'novel', '小说': 'novel',
    'comic': 'comic', 'manga': 'comic', '漫画': 'comic',
    'video': 'video', 'movie': 'video', '视频': 'video',
    'music': 'music', 'audio': 'music', '音乐': 'music',
    'all': 'all', '全部': 'all',
  };

  /// 这是不是一条本 App 的深链（外部意图先问一句，免得把 http 也当深链）。
  static bool looksLike(String raw) {
    final s = raw.trim().toLowerCase();
    return s.startsWith('$scheme://');
  }

  /// 解析成步骤数组。空数组 = 不认识，调用方原样忽略即可。
  static List<Map<String, dynamic>> parse(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null) return [];
    if (u.scheme.toLowerCase() != scheme) return [];
    final host = u.host.toLowerCase();
    final segs = u.pathSegments.where((e) => e.isNotEmpty).toList();
    final q = u.queryParameters;

    // ── ① 显式动作类：open / nav / do / play / search ──
    if (host == 'open' || host == 'nav' || host == 'go') {
      final mod = segs.isNotEmpty ? segs.first : (q['module'] ?? q['to'] ?? '');
      return _forModule(mod, q, extraPlatform: q['platform']);
    }
    if (host == 'do' || host == 'call') {
      final name = q['action'] ?? (segs.isNotEmpty ? segs.first : '');
      if (name.isEmpty) return [];
      final args = <String, dynamic>{};
      q.forEach((k, v) {
        if (k != 'action') args[k] = v;
      });
      return [
        {'op': 'eval', 'name': name, ...args}
      ];
    }
    if (host == 'search') {
      // kind 是「搜索类型过滤」，不是模块名 —— 别把它当成"要跳到音乐"。
      return _forModule('search', q);
    }

    // ── ② 模块名 / 模块别名直接当宿主：thirdhub://video?platform=… ──
    final steps = _forModule(host, q,
        extraPlatform: segs.isNotEmpty ? segs.first : null);
    if (steps.isEmpty) return [];

    // 路径第二段还能是子页签：thirdhub://bili/bangumi
    if (segs.length >= 2 && host != 'video') {
      // 只有视频页有"子页签"语义（B 站七栏目），其余忽略第二段
    }
    return steps;
  }

  /// 生成「打开模块（+ 平台 / 子页签 / 搜索）」的步骤。
  static List<Map<String, dynamic>> _forModule(
    String rawModule,
    Map<String, String> q, {
    String? extraPlatform,
    bool forceSearch = false,
  }) {
    final raw = rawModule.trim();
    if (raw.isEmpty) return [];
    final key = raw.toLowerCase();
    // 口语里 platform 比 module 更常被当入口：卡在 #bili 这种伪模块上
    final mapped = moduleAlias[key] ?? raw;
    final steps = <Map<String, dynamic>>[];

    var platform = q['platform'] ?? extraPlatform;
    String module;
    if (mapped == '#bili') {
      module = '视频';
      platform ??= '哔哩哔哩';
    } else if (mapped == '#hongguo') {
      module = '视频';
      platform ??= '红果';
    } else if (mapped == 'search') {
      // search 不是"模块"而是行为：落到搜索页
      module = '搜索';
    } else {
      module = mapped;
    }

    if (!knownModules.contains(module)) return [];

    steps.add({'op': 'nav', 'module': module});

    if (platform != null && platform.trim().isNotEmpty) {
      final p = platformAlias[platform.trim().toLowerCase()] ?? platform.trim();
      steps.add({'op': 'platform', 'name': p});
    }
    final sub = q['sub'] ?? q['tab'] ?? q['subtab'];
    if (sub != null && sub.trim().isNotEmpty) {
      steps.add({'op': 'subtab', 'page': module, 'tab': sub.trim()});
    }

    final term = (q['q'] ?? q['keyword'] ?? q['query'] ?? '').trim();
    if (term.isNotEmpty) {
      final kindRaw = (q['kind'] ?? '').trim().toLowerCase();
      final kind = kindAlias[kindRaw] ?? '';
      steps.add({
        'op': 'eval',
        'name': 'search',
        'q': term,
        if (kind.isNotEmpty) 'kind': kind,
      });
    } else if (forceSearch && module != '搜索') {
      // thirdhub://search?kind=comic 没给关键词 —— 只跳搜索页，不猜内容
    }
    return steps;
  }
}
