// 分模块更新公告 —— 零依赖内核（不 import flutter，可纯 Dart 自检）。
//
// 为什么需要它：历史更新公告是**一条全局流水账**（按版本从新到旧），
// 用户在"小说"模块里想知道"这个模块最近改了什么"，就得逐条读几百行、自己挑。
// 这个文件把流水账按模块重新切一刀，让每个模块都能给出自己那一份。
//
// 设计取舍：**不做人工标注**。四代累计的更新记录有几百条，逐条手工打模块标签
// 既不现实、也一定会腐烂（新版本没人回头补标）。所以走关键词归类：
//   · 每个模块名（'小说' / '端网' / 'AI' …）本身就是最强关键词；
//   · 只给少数歧义模块补同义词（'插件' → 端网、'智能体' → AI）；
//   · 命中多个模块就归多个模块 —— 一条改动确实可能同时动两个模块，不该强行二选一。
//
// 归不上类的不丢弃：`uncovered()` 把它们单独列出来，方便发现"关键词表该补了"。
//
// ★ 模块名清单必须与 `lib/main.dart` 的模块注册表一致。
//   `tool/changelog_selfcheck.dart` 会**读 main.dart 源码文本**逐名核对，
//   任何一边改了名字而另一边没跟上，自检立刻红 —— 两表漂移是这类映射表最常见的死法。

/// 一条更新记录的最小形状（与 `changelog.dart` 的 `ClogEntry` 对齐）。
class ClogRow {
  final String v;
  final String date;
  final List<String> items;
  const ClogRow({required this.v, this.date = '', this.items = const []});
}

/// 一个模块的更新摘要。
class ModClog {
  final String module;
  final List<ClogRow> rows;
  final int itemCount;
  const ModClog(this.module, this.rows, this.itemCount);

  bool get empty => rows.isEmpty;
  String get latestVersion => rows.isEmpty ? '' : rows.first.v;
}

class ClogModules {
  ClogModules._();

  /// 兜底专题名：不属于任何具体模块的改动（版本号、签名、发版通道、协议总纲…）。
  static const String global = '全局';

  /// 模块名清单。**顺序即 UI 展示顺序**（按分类排）。
  static const List<String> all = <String>[
    // 核心
    '搜索', 'AI', '端网', '浏览器', '文件', '相册', '我的',
    // 内容
    '小说', '漫画', '视频', '音乐', '直播', '播客', '有声书', '广播', '短剧', '壁纸', '资讯',
    // 生活
    '笔记', '待办', '录音机', '日历', '提醒中心', '日记', '记账', '剪贴板', '书签',
    '代码片段', 'Markdown', '健康记录', '通讯录备份', '短信备份', '天气与快递', '菜谱',
    '记忆卡', '课程表',
    // 效率
    '自动化任务', '工具箱', '翻译', '扫描仪', '二维码', '计算器', '白板', '文本工具箱',
    '传感器', '文件互传', '远程打印', '悬浮便签',
    // 家庭
    '家庭中心', '共享相册', '共享清单', '家庭影院', '家庭音乐库', '摄像头', '智能家居',
    '设备互联', '家庭日历',
    // 实验室
    '聊天', '社区', '论坛', '游戏',
    // 聚合入口（本身也是可进入的模块，同样要有自己的公告）
    '音频中心', '学习中心', '记录中心', '备份迁移',
  ];

  /// 这些模块名**不当作关键词用** —— 名字本身就是高频口语，拿它匹配等于全命中。
  /// `我的` 是最典型的：中文里"我的文件""我的账号"到处都是，用它匹配会把
  /// 半本流水账都归到"我的"模块。这类模块只能靠 [synonym] 里的具体词命中。
  static const Set<String> noNameMatch = <String>{'我的'};

  /// 某些模块名会被**技术语境**里同形的词顶掉，命中前先做排除。
  /// `广播`（网络电台模块）与"UDP 广播 / 局域网广播"（网络术语）是同一个词 ——
  /// 自检里就是靠这条抓到"局域网广播优化"被误判进广播模块的。
  static const Map<String, List<String>> avoid = <String, List<String>>{
    '广播': <String>['局域网广播', 'UDP 广播', 'UDP广播', '定向广播', '双向广播', '广播域', '数据广播', 'udp 广播'],
    '笔记': <String>['笔记本电脑', '笔记本电', '笔记本'],
    '文件': <String>['文件夹名'],
  };

  /// 强关键词：命中就归到这个模块（模块名自动入表，无需重复写）。
  /// 只补"字面上不出现模块名、但一定指这个模块"的词。
  static const Map<String, List<String>> synonym = <String, List<String>>{
    // 名字太短或太通用的，必须补同义词，否则什么都归不上
    'AI': <String>['智能体', '大模型', '模型', 'Prompt', 'prompt', 'token', '上下文', 'Agent', '对话补全', 'function-calling', '工具调用'],
    '端网': <String>['插件', '端间', '端到端', 'PH/1', 'peer', 'Peer', '中枢', '跨端', '接入端', 'execToken'],
    '搜索': <String>['搜源', '引擎', '书源', '资源源', '聚合搜'],
    '我的': <String>['个人资料', '头像', '账号', '登录', '注册'],
    '文件': <String>['文件管理', '目录', '保存路径'],
    '相册': <String>['照片', '图片墙', '图库'],
    '视频': <String>['播放器', '影院'],
    '音乐': <String>['播放列表', '歌词', '音质'],
    '笔记': <String>['便签'],
    '日历': <String>['日程'],
    '记账': <String>['账本', '收支'],
    '聊天': <String>['消息', '会话', 'IM'],
    '工具箱': <String>['进阶'],
    '文件互传': <String>['互传', '局域网传'],
    '设备互联': <String>['配对', '同网设备'],
  };

  /// 弱关键词：命中只算"可能相关"，用于强关键词全都没命中时的兜底。
  static const Map<String, List<String>> weak = <String, List<String>>{
    '文件': <String>['导入', '导出'],
    '相册': <String>['拍照', '截图'],
    '视频': <String>['字幕', '画中画', 'PiP'],
    '音乐': <String>['音频'],
    '端网': <String>['局域网', 'UDP', '发现'],
    '我的': <String>['设置', '备份'],
    '自动化任务': <String>['定时', '任务'],
    '浏览器': <String>['网页', '标签页'],
    '小说': <String>['阅读', '书架'],
    '漫画': <String>['图源'],
  };

  /// ASCII 关键词要按"词边界"匹配，否则 `AI` 会在 `MAIN` / `REPAIR` 里误命中。
  static bool _hit(String text, String kw) {
    if (kw.isEmpty) return false;
    final t = text.toLowerCase();
    final k = kw.toLowerCase();
    // 纯 ASCII 关键词（含数字/连字符）才需要边界；中日韩词直接子串匹配
    final ascii = kw.codeUnits.every((c) => c < 0x80);
    if (!ascii) return t.contains(k);
    int i = t.indexOf(k);
    while (i >= 0) {
      final before = i == 0 ? '' : t[i - 1];
      final after = i + k.length >= t.length ? '' : t[i + k.length];
      final okBefore = before.isEmpty || !_isWordChar(before);
      final okAfter = after.isEmpty || !_isWordChar(after);
      if (okBefore && okAfter) return true;
      i = t.indexOf(k, i + 1);
    }
    return false;
  }

  static bool _isWordChar(String ch) {
    final c = ch.codeUnitAt(0);
    final isDigit = c >= 0x30 && c <= 0x39;
    final isLower = c >= 0x61 && c <= 0x7a;
    final isUpper = c >= 0x41 && c <= 0x5a;
    return isDigit || isLower || isUpper;
  }

  /// 这一条改动涉及哪些模块。空集合 = 归不上任何模块（由 UI 放进「全局」）。
  ///
  /// 判定分两轮，**不要合并**：
  ///   ① 强关键词（模块名 + 同义词）—— 有一处命中就以此为准，不看弱词。
  ///      理由：`文件` 的弱词是「导入/导出」，而"小说导入"这种条目几乎全是小说模块的事，
  ///      每一条"导入"都顺带喂给文件模块，只会让文件模块的公告被噪音淹没。
  ///   ② 弱关键词 —— 只在**强关键词一个都没命中**时才兜底。
  static Set<String> modulesOf(String item) {
    final out = <String>{};
    for (final m in all) {
      if (noNameMatch.contains(m)) continue;
      if (_avoided(item, m)) continue;
      if (_hit(item, m)) out.add(m);
    }
    for (final e in synonym.entries) {
      if (_avoided(item, e.key)) continue;
      for (final kw in e.value) {
        if (_hit(item, kw)) { out.add(e.key); break; }
      }
    }
    if (out.isNotEmpty) return out;
    for (final e in weak.entries) {
      if (_avoided(item, e.key)) continue;
      for (final kw in e.value) {
        if (_hit(item, kw)) { out.add(e.key); break; }
      }
    }
    return out;
  }

  static bool _avoided(String item, String module) {
    final List<String>? bad = avoid[module];
    if (bad == null || bad.isEmpty) return false;
    for (final String b in bad) {
      if (_hit(item, b)) return true;
    }
    return false;
  }

  /// 一条改动是否算"全局"（哪个模块都归不上）。
  static bool isGlobal(String item) => modulesOf(item).isEmpty;

  /// 取出某个模块的更新历史。
  /// [limit] 限制版本条数（0 = 不限），避免超长模块把页面拉爆。
  static ModClog pick(List<ClogRow> rows, String module, {int limit = 0}) {
    final hit = <ClogRow>[];
    var n = 0;
    for (final r in rows) {
      final items = <String>[
        for (final it in r.items)
          if (module == global ? isGlobal(it) : modulesOf(it).contains(module)) it,
      ];
      if (items.isEmpty) continue;
      hit.add(ClogRow(v: r.v, date: r.date, items: items));
      n += items.length;
      if (limit > 0 && hit.length >= limit) break;
    }
    return ModClog(module, hit, n);
  }

  /// 全局那一份（哪个模块都归不上的改动）。
  static ModClog globals(List<ClogRow> rows, {int limit = 0}) =>
      pick(rows, global, limit: limit);

  /// 有哪些模块真有更新记录（用于只列出"有内容的模块"，不列空壳）。
  static List<String> present(List<ClogRow> rows) => <String>[
        for (final m in all) if (pick(rows, m, limit: 1).rows.isNotEmpty) m,
        if (globals(rows, limit: 1).rows.isNotEmpty) global,
      ];

  /// 某个模块最近一次更新的一句话摘要（列表页/入口上用）。
  static String brief(List<ClogRow> rows, String module, {int maxItems = 2}) {
    final mc = pick(rows, module, limit: 1);
    if (mc.empty) return '';
    final head = mc.rows.first.items.take(maxItems).join('；');
    final more = mc.rows.first.items.length > maxItems ? ' 等' : '';
    return 'v${mc.rows.first.v}：$head$more';
  }

  /// 某一版本里某模块的条目文本（给"本模块更新"弹窗用）。
  static List<String> itemsOf(List<ClogRow> rows, String module) {
    final mc = pick(rows, module);
    return <String>[for (final r in mc.rows) for (final it in r.items) it];
  }
}
