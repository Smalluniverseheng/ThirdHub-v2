// 模型简介 —— 与网站 js/ai/model-intros.js 同源(手工同步, 勿手改条目文案)。
// 键为「厂商/模型」，支持同厂商前缀最长匹配；未收录的模型用通用文案。
// 用途: ① 空会话欢迎页「你好，我是 X」问候 ② 抽屉模型列表逐模型简介。

/// 模型简介表(精确键优先, 前缀键兜底)。
const Map<String, String> kModelIntros = {
  /* OpenAI */
  'openai/gpt-5': 'OpenAI 的旗舰模型，擅长复杂推理、编程与专业知识工作，是目前综合能力最强的模型之一。',
  'openai/gpt-5-mini': 'OpenAI 的轻量旗舰，保留大部分推理能力的同时更快、更省，适合日常对话与写作。',
  'openai/gpt-5-nano': 'OpenAI 的超轻量模型，响应极快、成本极低，适合简单问答与高并发任务。',
  'openai/gpt-4o': 'OpenAI 经典全能模型，文字、识图能力均衡，响应速度快。',
  'openai/gpt-4o-mini': 'OpenAI 的高性价比小模型，轻快好用，适合日常聊天与简单任务。',
  'openai/o3': 'OpenAI 的深度推理模型，遇难题会「思考更久」，数学、编程与科学问题表现突出。',
  'openai/o4-mini': 'OpenAI 的轻量推理模型，用更低的成本获得不错的思考能力。',
  /* Anthropic */
  'anthropic/claude-opus': 'Anthropic 的最强模型，深思熟虑、表达优雅，编程与长文写作尤为出色。',
  'anthropic/claude-sonnet': 'Anthropic 的主力模型，智能与速度平衡得最好，编码能力顶尖。',
  'anthropic/claude-haiku': 'Anthropic 的极速小模型，几乎即时响应，适合轻量任务。',
  /* Google */
  'google/gemini-3': 'Google 最新一代模型，多模态能力强，上下文超长，综合表现稳居第一梯队。',
  'google/gemini-2.5-pro': 'Google 的高性能模型，擅长长文档分析与复杂推理，支持百万级上下文。',
  'google/gemini-2.5-flash': 'Google 的快速模型，延迟低、成本低，同时保持不错的推理能力。',
  'google/gemini-2.0-flash': 'Google 的上一代快速模型，稳定可靠，适合日常任务。',
  /* xAI */
  'xai/grok': 'xAI 的模型，思维直率、反应快，实时信息与数学推理表现不俗。',
  /* DeepSeek */
  'deepseek/deepseek-chat': 'DeepSeek 的对话模型（V3 系列），中文能力强、性价比极高，写作与编程都很能打。',
  'deepseek/deepseek-reasoner': 'DeepSeek 的推理模型（R1 系列），会先展示思考过程再作答，数学与逻辑难题表现亮眼。',
  /* Kimi */
  'moonshot/kimi-k2': '月之暗面的旗舰模型，中文写作与代码能力出色，擅长长链路任务。',
  'moonshot/kimi-latest': '月之暗面的 Kimi 模型，支持超长上下文与识图，中文体验一流。',
  'moonshot/moonshot-v1': '月之暗面的经典 Kimi 模型，长文本处理是它的看家本领。',
  /* 阿里 */
  'aliyun/qwen3-max': '阿里通义的旗舰模型，中文理解与生成顶尖，知识面广。',
  'aliyun/qwen3-coder': '阿里通义的代码专用模型，写代码、改 Bug、讲原理样样精通。',
  'aliyun/qwen': '阿里通义千问模型，中文能力强，生态完善，稳定可靠。',
  /* 智谱 */
  'zhipu/glm': '智谱的 GLM 模型，中文对话自然流畅，工具调用与推理能力均衡。',
  /* 字节 */
  'bytedance/doubao': '字节的豆包模型，响应快、中文接地气，日常助手体验优秀。',
  'bytedance/deepseek': '火山引擎托管的 DeepSeek 模型，中文与推理能力强，企业级稳定性。',
  /* 腾讯 */
  'tencent/hunyuan': '腾讯混元模型，中文创作与知识问答表现稳定。',
  /* 百度 */
  'baidu/ernie': '百度文心模型，中文知识储备深厚，搜索与写作场景见长。',
  /* 小米 */
  'xiaomi/mimo': '小米的 MiMo 模型，轻量高效，推理能力在小参数模型中表现出众。',
  /* MiniMax */
  'minimax/': 'MiniMax 的模型，长上下文与性价比突出，对话体验轻快。',
  /* Mistral */
  'mistral/': '欧洲 Mistral 的模型，简洁高效，代码与多语言能力不错。',
  /* Perplexity */
  'perplexity/': 'Perplexity 的在线检索模型，回答自带联网信息，适合查资料。',
};

/// 取模型简介：精确 → 同厂商前缀最长匹配 → 通用文案（与网站 modelIntro() 一致）。
String modelIntro(String providerId, String model, [String providerName = '']) {
  final String key = '$providerId/$model';
  final String? exact = kModelIntros[key];
  if (exact != null) return exact;
  String? best;
  var bestLen = 0;
  for (final MapEntry<String, String> e in kModelIntros.entries) {
    final int slash = e.key.indexOf('/');
    if (slash < 0 || e.key.substring(0, slash) != providerId) continue;
    final String pm = e.key.substring(slash + 1);
    if (model.startsWith(pm) && pm.length > bestLen) { best = e.value; bestLen = pm.length; }
  }
  if (best != null) return best;
  final String pn = providerName.isNotEmpty ? providerName : providerId;
  return '由$pn提供的$model模型。你可以问我任何问题：写作、编程、学习、创意，随时开始。';
}
