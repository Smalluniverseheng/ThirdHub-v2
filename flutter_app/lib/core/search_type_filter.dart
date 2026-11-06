// 搜索类型选择器：按「当前连着的资料库真的能提供什么」过滤（任务 #195）。
//
// ★为什么要单独一层纯 Dart 规则：
//   `EngineDirect.supportsType()` 早在 4.81.39 就加了，但**界面没用它** ——
//   「全部 / 小说 / 漫画 / 视频 / 音乐」五个选项永远全显示。只连了一台漫画
//   资料库时，用户点「音乐」会拿到一个空页（后端闸门拦住了请求，但前端没解释
//   为什么），看起来就是「搜不了」。用户原话：「所有引擎都要按格式/能力过滤，
//   不要音乐区搜到漫画」。
//
//   把判定抽成纯函数是为了能自检：规则错了（比如把「全部」也砍掉、或老引擎
//   没声明能力时把界面砍空）在提交前就会被拦下。
//
// ★三条必须守住的原则：
//   ① **没连资料库时不过滤** —— 走的是资源库/后端聚合，它可能同时挂了四个引擎，
//      这时候按一台的能力砍类型是错的。
//   ② **一个模块都判不出来时不过滤** —— 老资料库不带 `m:` 能力标签、端口也
//      认不出时，我们其实不知道它能干什么。宁可多显示几个空选项，也不能让
//      整个类型行消失（那会被当成「功能坏了」）。
//   ③ 「全部」永远保留 —— 它表示「不限类型」，不是某个具体模块；砍掉它会
//      让用户失去一键搜所有的入口，且当前选中项会突然失效。
//
// 运行自检：`dart run tool/search_type_filter_selfcheck.dart`

/// 类型下标 → 发给资料库的 type 参数。顺序与 UI 的 chips 顺序一致，
/// 0 号是「全部」（type=all，不限模块）。
const List<String> kSearchTypeKeys = <String>[
  '',
  'novel',
  'comic',
  'video',
  'music',
];

/// 从 /thp/meta 的 caps 里读出资料库**自报**支持的模块。
///
/// 只认 `m:<mod>` 标签，其它能力（stream-search / search-mode / library）
/// 一律不算模块声明 —— 否则「支持流式搜索」会被误当成「支持某个内容类型」。
List<String> declaredModules(List<String> caps) {
  final out = <String>[];
  for (final c in caps) {
    if (!c.startsWith('m:')) continue;
    final m = c.substring(2);
    if (m.isEmpty || m == 'all' || !kSearchTypeKeys.contains(m)) continue;
    if (!out.contains(m)) out.add(m);
  }
  return out;
}

/// 这一轮可用的模块 = 主连接自报的能力 ∪ 多资料库路由表里的模块。
///
/// 路由表（`EngineDirect.moduleRoutes`）已经做过「caps 优先、端口兜底」，
/// 所以把它的 key 并进来，才能让「连着 A 漫画资料库、局域网里还有 B 小说
/// 资料库」这种场景同时显示两个类型。
List<String> availableModules(List<String> caps, List<String> routeModules) {
  final out = declaredModules(caps);
  for (final m in routeModules) {
    if (m.isEmpty || m == 'all' || !kSearchTypeKeys.contains(m)) continue;
    if (!out.contains(m)) out.add(m);
  }
  return out;
}

/// 当前应该显示哪些类型下标。
///
/// [platform] 平台放行的下标（iOS 因第三方影视采集收口，没有「全部/视频」）；
/// [engineConnected] 是否处于资料库直连模式；
/// [caps] 主连接的 /thp/meta caps；
/// [routeModules] 多资料库路由表的 key（模块名）。
List<int> visibleTypeIndexes({
  required List<int> platform,
  required bool engineConnected,
  required List<String> caps,
  required List<String> routeModules,
}) {
  if (!engineConnected) return List<int>.of(platform);
  final mods = availableModules(caps, routeModules);
  if (mods.isEmpty) return List<int>.of(platform);
  final out = <int>[];
  for (final i in platform) {
    if (i < 0 || i >= kSearchTypeKeys.length) continue;
    final k = kSearchTypeKeys[i];
    if (k.isEmpty || mods.contains(k)) out.add(i);
  }
  // 交集为空（例如 iOS 只放行小说/漫画/音乐，而资料库只提供视频）：
  // 退回平台列表，宁可给出空结果，也不能让用户连搜索框都没有类型可选。
  if (out.isEmpty) return List<int>.of(platform);
  return out;
}

/// 当前选中项被过滤掉时回落到第一项（通常是「全部」）。
///
/// ★不做这一步的话，chips 里没有选中态、hintText 却还按旧下标取译文，
///   用户看到的是「一个都没选中但搜索框写着搜音乐」。
int resolveTypeFilter(int current, List<int> visible) {
  if (visible.isEmpty) return 1;
  return visible.contains(current) ? current : visible.first;
}

/// 「全部」在**老资料库**（不支持分页/type=all）上要逐类并发搜索时，
/// 真正该发请求的模块列表。过滤后才不会向不支持该类型的资料库白发一发。
List<String> allSearchModules(List<int> visible) => <String>[
      for (final i in visible)
        if (i >= 0 &&
            i < kSearchTypeKeys.length &&
            kSearchTypeKeys[i].isNotEmpty)
          kSearchTypeKeys[i]
    ];
