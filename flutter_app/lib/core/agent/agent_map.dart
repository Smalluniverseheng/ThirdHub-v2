// AI 控制总线 · 模块地图（纯 Dart，不 import flutter）
//
// 解决的是用户原话里的这个痛点：
//   「给每一个模块写清楚是干什么的、能跳到哪个页面、页面里有什么内容，
//     AI 读了这些就不用再识别屏幕，直接就能跳转」。
//
// 为什么要有这张表：
//   · 截图识别又慢又贵，还会看错（模型把"加载中"读成"已打开"）。
//   · 本 App 的结构是**确定的**，没必要每一步都让模型去猜。
//     把它写成文字交给模型，模型就能一步 `app_open` 到位，省掉 3~5 步连点。
//
// 三条硬约束（不遵守这张表就会变成"AI 说跳了其实没跳"）：
//   1) 表里每条 deeplink 必须能被 AgentDeeplink 解析成非空步骤 —— 有单测盯着（agent_map_test.dart）。
//      改了模块名忘了改这里，CI 会红，不会静默漂移。
//   2) 只写**真实存在**的页面。不确定的宁可不写，让模型去 `tree` 现查。
//   3) 给模型的文本要短。这张表每个请求都会带一遍，写长了等于每步都多烧钱。

class AgentMapPage {
  /// 页面名（用户/模型都这么叫）
  final String name;

  /// 怎么到这一页（deeplink 或"点哪个按钮"）
  final String how;

  /// 这页上有什么（模型据此判断"是不是已经到地方了"）
  final String what;

  const AgentMapPage(this.name, this.how, this.what);
}

class AgentMapModule {
  /// 真实模块名，必须与 main.dart 的 kModules 键、AgentDeeplink.knownModules 三方一致
  final String key;

  /// 模块一句话说明
  final String what;

  /// 直达深链
  final String deeplink;

  /// 模块内部页面
  final List<AgentMapPage> pages;

  /// 这个模块能不能搜内容（决定要不要建议模型用 engine_search）
  final bool searchable;

  const AgentMapModule({
    required this.key,
    required this.what,
    required this.deeplink,
    this.pages = const [],
    this.searchable = false,
  });
}

class AgentMap {
  const AgentMap._();

  /// 五大板块 + 搜索 + AI + 我的：这几个占了真实使用的九成，写到页面级。
  /// 其余模块只给一行（`others`），免得提示词膨胀到没人看得完。
  static const List<AgentMapModule> modules = [
    AgentMapModule(
      key: '搜索',
      what: '全站统一搜索入口，可按类型过滤，结果来自后端聚合与直连两路',
      deeplink: 'thirdhub://search',
      searchable: true,
      pages: [
        AgentMapPage('搜索页', 'thirdhub://search?q=关键词&kind=novel', '顶部搜索框 + 类型筛选 chip（全部/小说/漫画/视频/音乐）+ 结果列表（逐条上屏）'),
        AgentMapPage('结果详情', '点结果卡片', '跳到对应板块的详情页（书=简介+目录；视频=选集；音乐=播放）'),
      ],
    ),
    AgentMapModule(
      key: '小说',
      what: '看书：搜索 → 详情（简介+目录）→ 阅读器（正文/翻章/字号/朗读）',
      deeplink: 'thirdhub://novel',
      searchable: true,
      pages: [
        AgentMapPage('书架', 'thirdhub://novel', '已收藏的书 + 阅读进度；点书进详情'),
        AgentMapPage('搜索结果', 'thirdhub://novel?q=斗破苍穹', '书名/作者/封面列表；点一本进详情'),
        AgentMapPage('详情', '点搜索结果', '简介、目录（可达数千章）、加入书架、开始阅读'),
        AgentMapPage('阅读器', '点目录某一章', '正文（分页/滚动）、上一章下一章、字号、背景、朗读、缓存'),
      ],
    ),
    AgentMapModule(
      key: '漫画',
      what: '看漫画：搜索 → 详情（章节）→ 图集阅读（左右翻页/竖滑长图）',
      deeplink: 'thirdhub://comic',
      searchable: true,
      pages: [
        AgentMapPage('书架', 'thirdhub://comic', '收藏的漫画 + 进度'),
        AgentMapPage('搜索结果', 'thirdhub://comic?q=关键词', '漫画封面列表'),
        AgentMapPage('详情/章节', '点搜索结果', '简介 + 章节列表'),
        AgentMapPage('阅读器', '点某一话', '整话图集，可缩放；按源可用性决定能不能加载'),
      ],
    ),
    AgentMapModule(
      key: '视频',
      what: '影视：横向多平台（红果短剧 / 哔哩哔哩 / 片库 / 历史 / 发现 / 搜索）',
      deeplink: 'thirdhub://video',
      searchable: true,
      pages: [
        AgentMapPage('红果短剧', 'thirdhub://video?platform=hongguo', '短剧列表（竖屏短视频流）'),
        AgentMapPage('哔哩哔哩', 'thirdhub://video?platform=bili', 'B 站客户端：七个栏目（推荐/热门/排行榜/分区/直播/番剧/搜索），栏目可自定义'),
        AgentMapPage('片库', 'thirdhub://video?platform=library', '本地/收藏的片源'),
        AgentMapPage('历史', 'thirdhub://video?platform=history', '最近看过的'),
        AgentMapPage('发现', 'thirdhub://video?platform=discover', '按源聚合的分类'),
        AgentMapPage('播放页', '点任意视频', '播放器（横屏/倍速/清晰度/弹幕/亮度音量手势）'),
      ],
    ),
    AgentMapModule(
      key: '音乐',
      what: '听歌：搜索 → 歌单/单曲 → 播放器（后台播放、歌词、定时停止）',
      deeplink: 'thirdhub://music',
      searchable: true,
      pages: [
        AgentMapPage('我的歌单', 'thirdhub://music', '本地歌单 + 收藏'),
        AgentMapPage('搜索结果', 'thirdhub://music?q=周杰伦', '单曲/专辑列表'),
        AgentMapPage('播放器', '点一首歌', '封面/进度条/上下一首/歌词/倍速'),
      ],
    ),
    AgentMapModule(
      key: '开放源',
      what: '不经过后端的公网源：音乐 / 电台 / 播客 / 漫画 / 视频 / 公版书（NAS 关机也能用）',
      deeplink: 'thirdhub://free',
      searchable: true,
      pages: [
        AgentMapPage('开放源首页', 'thirdhub://free', '六个板块入口横排'),
        AgentMapPage('板块列表', '点某个板块', '该板块的公网内容列表，可直接播/读'),
      ],
    ),
    AgentMapModule(
      key: 'AI',
      what: 'AI 助手：多厂商模型对话、工具调用、语音输入/朗读、自动操作 App',
      deeplink: 'thirdhub://ai',
      pages: [
        AgentMapPage('对话页', 'thirdhub://ai', '会话列表（抽屉）+ 消息流 + 输入框'),
        AgentMapPage('模型选择', '抽屉顶部或 + 面板 → 厂商与 Key 管理', '切厂商/模型、填 Key、看哪个模型支持看图'),
        AgentMapPage('自动操作', '+ 面板 → 让它自己操作 App', '输入目标，模型看截图一步步把 App 操作到目标状态'),
      ],
    ),
    AgentMapModule(
      key: '我的',
      what: '账号、后端连接、书架/历史/设置、离线内容、关于',
      deeplink: 'thirdhub://me',
      pages: [
        AgentMapPage('我的首页', 'thirdhub://me', '头像/登录、后端状态条、离线内容入口、设置分组'),
        AgentMapPage('后端设置', '我的 → 后端连接', '局域网/隧道地址、密钥、连通性自检'),
      ],
    ),
    AgentMapModule(
      key: '直播',
      what: '直播聚合（分类/房间/播放）',
      deeplink: 'thirdhub://live',
    ),
    AgentMapModule(
      key: '酒馆',
      what: '角色扮演对话（本地人设 + 模型）',
      deeplink: 'thirdhub://tavern',
    ),
    AgentMapModule(
      key: '笔记',
      what: '本地笔记（可被 AI 写入/读取）',
      deeplink: 'thirdhub://notes',
    ),
    AgentMapModule(
      key: '待办',
      what: '本地待办清单',
      deeplink: 'thirdhub://todo',
    ),
    AgentMapModule(
      key: '相册',
      what: '本地/NAS 相册浏览',
      deeplink: 'thirdhub://gallery',
    ),
    AgentMapModule(
      key: '文件',
      what: '本地与 NAS 文件浏览、下载、分享',
      deeplink: 'thirdhub://files',
    ),
    AgentMapModule(
      key: '端网',
      what: '把不同端（前端/后端/插件）连起来互相调用的控制台',
      deeplink: 'thirdhub://peer',
    ),
  ];

  /// 只报模块名的轻量清单（给"有哪些模块"这种问题用，别把整张表塞进去）
  static List<String> get keys => [for (final m in modules) m.key];

  static AgentMapModule? find(String term) {
    final t = term.trim().toLowerCase();
    if (t.isEmpty) return null;
    for (final m in modules) {
      if (m.key.toLowerCase() == t) return m;
      if (m.deeplink.toLowerCase() == t) return m;
    }
    for (final m in modules) {
      if (m.key.toLowerCase().contains(t)) return m;
    }
    return null;
  }

  /// 给对话模型看的完整版（注入 system 或由 app_map 工具返回）。
  ///
  /// [detailed] = false 时只列"模块 + 一句话 + 深链"，适合每步都带的场景。
  static String prompt({bool detailed = true}) {
    final sb = StringBuffer();
    sb.writeln('【本 App 的模块地图】跳转用 app_open（传 url 或 module），不需要看屏幕猜。');
    for (final m in modules) {
      sb.write('- ${m.key}  ${m.deeplink}  ${m.what}');
      if (m.searchable) sb.write('  〔可搜内容〕');
      sb.writeln();
      if (!detailed) continue;
      for (final p in m.pages) {
        sb.writeln('    · ${p.name}｜入口：${p.how}｜内容：${p.what}');
      }
    }
    sb.writeln('页面内找内容：先 engine_search(type, query) 拿 id，再 open_item(type, id, title) 直接打开；');
    sb.writeln('不要用连点去凑——能一步跳到的就别点三下。');
    return sb.toString().trimRight();
  }

  /// 给自驱动模型看的紧凑版（每步都要带，所以只留深链与页面名）
  static String compact() {
    final sb = StringBuffer();
    sb.writeln('【模块地图｜可直接 deeplink 跳转】');
    for (final m in modules) {
      final pages = m.pages.isEmpty ? '' : ' 页面：${m.pages.map((p) => p.name).join('/')}';
      sb.writeln('- ${m.key} = ${m.deeplink}$pages');
    }
    return sb.toString().trimRight();
  }
}
