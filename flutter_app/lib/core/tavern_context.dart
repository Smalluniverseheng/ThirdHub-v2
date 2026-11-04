// 酒馆对话上下文 —— 纯 Dart（**不 import flutter / 不碰 SharedPreferences**），
// 目的是能被 `tool/tavern_context_selfcheck.dart` 直接 import 做断言。
//
// 为什么要单独抽出来：
//   4.81.21 修过一个"聊到十几轮突然整轮 400"的真缺陷 —— 上下文截到最近 24 条后，
//   首条可能是 assistant，而 Anthropic / Gemini 要求首条非 system 消息必须是 user。
//   那段逻辑当时写在 State 里，**要真机上聊够轮数才触发**，任何自检都碰不到。
//   抽成纯函数以后，「截断 → 对齐 → 挂 system」这三步可以被逐条断言。
//
// 4.81.25 新增「重新生成」：删掉最后一条（或尾部连续几条）回复，用同一段上下文重发。
//   这里只提供判定（该从哪里截、能不能重生成），**不持有消息列表** ——
//   列表是 UI 手里的可变对象，纯函数去改它就成了隐形副作用。

/// 一轮消息的最小投影：只要角色和文本，不依赖 [TavernMsg]（那在 tavern.dart 里，
/// import 它会连带把 flutter 拖进来自检就跑不起来了）。
class TavernTurn {
  const TavernTurn(this.role, this.text);

  /// `user` / `assistant`。别的值一律按 assistant 处理（下游只看「是不是 user」）。
  final String role;
  final String text;

  bool get isUser => role == 'user';

  @override
  String toString() => '$role(${text.length})';
}

class TavernContext {
  const TavernContext._();

  /// 只带最近多少条。24 是权衡：太短角色记不住设定，太长费用和首字延迟都涨。
  static const int defaultWindow = 24;

  /// 把会话压成给模型看的 messages：`[{role:'system'}, 最近 window 条…]`。
  ///
  /// 两个必须做的事（都不做的话症状是"偶发整轮失败"，而不是界面报错）：
  ///   1. **只取最近 [window] 条** —— 否则上下文无限膨胀，费用与延迟线性上涨；
  ///   2. **首条非 system 必须是 user** —— 截断点很可能落在一问一答中间，
  ///      于是首条成了 assistant。Anthropic / Gemini 直接 400，OpenAI 系则
  ///      静默容忍 → 换模型才暴露。所以从截断点往后跳到第一条 user 为止。
  ///
  /// 不修改 [turns]（自检里有"调用前后长度不变"的断言）。
  ///
  /// [window] ≤ 0 视为**不带上文**（只发 system）。不这么定义的话，"0" 会被
  /// `length - 0` 解读成"全都带上"，正好反过来 —— 而调用方传 0 的本意一定是"不要历史"。
  static List<Map<String, String>> build({
    required String system,
    required List<TavernTurn> turns,
    int window = defaultWindow,
  }) {
    final start = window <= 0
        ? turns.length
        : (turns.length > window ? turns.length - window : 0);
    var from = start;
    while (from < turns.length && !turns[from].isUser) {
      from++;
    }
    return <Map<String, String>>[
      <String, String>{'role': 'system', 'content': system},
      for (var i = from; i < turns.length; i++)
        <String, String>{'role': turns[i].role, 'content': turns[i].text},
    ];
  }

  /// 「重新生成」该从哪里截：返回**保留条数**，把 [cut, length) 这段删掉再重发。
  /// 返回 -1 表示这条会话**没有可重新生成的东西**，调用方应静默返回。
  ///
  /// 判定三件事：
  ///   1. 尾部必须有 assistant（消息）；一条都没有 → 没有"上一次回复"可重做；
  ///   2. 尾部的**连续**多条 assistant 一起删 —— 用户点「停止生成」再重发过几次时，
  ///      会话尾巴会堆出好几条半截回复，只删最后一条会把"半截"留在上下文里；
  ///   3. 删完前面必须还剩至少一条 user —— 只剩开场白时没有用户输入，
  ///      重发就是一个只有 system 的请求，OpenAI 报"messages 不能为空"、
  ///      Anthropic 报"至少一条 user"，用户看到的是"点重新生成就报错"。
  static int regenerateCutoff(List<TavernTurn> turns) {
    var cut = turns.length;
    while (cut > 0 && !turns[cut - 1].isUser) {
      cut--;
    }
    // 末条本来就是 user（还没生成回复）→ 没有东西可重做
    if (cut == turns.length) return -1;
    // 整段都是 assistant（只有开场白）→ 没有用户输入可重发
    if (cut == 0) return -1;
    return cut;
  }
}
