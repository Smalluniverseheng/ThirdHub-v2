// AI 控制总线 · 模型决策层
//
// 这一层解决的是「App 自己长眼睛」：把当前截图 + 状态 + 可点控件交给
// 用户自己配的视觉模型（填自己的 API Key），让它输出**下一条指令**。
//
// 为什么不用现成的对话模块（core/ai.dart 的 AiChat）：
//   那个是纯文本流式对话，messages 里只能放字符串。看截图必须走多模态
//   content 数组（image_url / base64），是两套 body 形状，混在一起改会
//   把聊天链路也带坏。所以这里单独写一份，只做一件事：一进一出。
//
// 支持的接口形状（都是用户自备 Key 的常见厂商）：
//   · openai     → POST {base}/chat/completions     （OpenAI、DeepSeek、智谱、
//                    Moonshot、Qwen(dashscope兼容)、各类中转站）
//   · anthropic  → POST {base}/messages             （Claude 原生）
//
// 不 import flutter：这样 `dart test` 能直接跑解析与请求体组装。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'agent_protocol.dart';

/// 模型的一次决策。
class AgentDecision {
  /// 模型的自述思考（不展示给用户，写日志用）
  final String thought;

  /// 给用户看的一句话（悬浮球/步骤卡片上显示）
  final String say;

  /// 下一步要执行的指令；终止时（done/fail）为 null
  final AgentCmd? cmd;

  /// 是否宣告完成
  final bool done;

  /// 做不下去的原因（done=false 且 cmd=null 时有效）
  final String? fail;

  /// 模型原始输出（解析失败时便于排查，不要丢）
  final String raw;

  const AgentDecision({
    this.thought = '',
    this.say = '',
    this.cmd,
    this.done = false,
    this.fail,
    this.raw = '',
  });

  bool get isTerminal => done || fail != null || cmd == null;

  /// 从模型输出里抠出 JSON 决策。
  ///
  /// 必须宽容：现实中模型会包 ```json 代码块、前后加解释、或者只给裸 JSON。
  /// 但**不能猜得太狠** —— 猜错一条指令等于让 AI 乱点用户手机，
  /// 所以解析不出结构就返回带 fail 的决策（让循环停下来报错），而不是瞎凑。
  static AgentDecision parse(String text) {
    final raw = text;
    final body = _extractJson(text);
    if (body == null) {
      return AgentDecision(
        raw: raw,
        fail: '模型没有按约定输出 JSON',
        say: '模型回复格式不对，已停止',
      );
    }
    Map<String, dynamic> j;
    try {
      final v = jsonDecode(body);
      if (v is! Map) {
        return AgentDecision(
            raw: raw, fail: '模型输出的不是 JSON 对象', say: '模型回复格式不对，已停止');
      }
      j = Map<String, dynamic>.from(v);
    } catch (e) {
      return AgentDecision(
          raw: raw, fail: 'JSON 解析失败：$e', say: '模型回复格式不对，已停止');
    }

    final thought = '${j['thought'] ?? j['reason'] ?? ''}'.trim();
    final say = '${j['say'] ?? j['message'] ?? ''}'.trim();

    // 三种等价写法都接受：{"action":{...}} / {"cmd":{...}} / 顶层直接给 op
    Map<String, dynamic>? act;
    final a = j['action'] ?? j['cmd'] ?? j['next'];
    if (a is Map) {
      act = Map<String, dynamic>.from(a);
    } else if (a is String && a.trim().isNotEmpty) {
      // {"action":"done"} 这种简写
      act = {'op': a.trim()};
    } else if (j['op'] is String) {
      act = Map<String, dynamic>.from(j)..remove('thought')..remove('say');
    }

    if (act == null) {
      if (j['done'] == true) {
        return AgentDecision(thought: thought, say: say, done: true, raw: raw);
      }
      return AgentDecision(
          raw: raw, thought: thought, say: say, fail: '没有给出 action');
    }

    final op = '${act['op'] ?? act['action'] ?? act['type'] ?? ''}'
        .trim()
        .toLowerCase();
    if (op == 'done' || op == 'finish' || op == 'complete') {
      return AgentDecision(thought: thought, say: say, done: true, raw: raw);
    }
    if (op == 'fail' || op == 'give_up' || op == 'stuck') {
      final why = '${act['reason'] ?? act['why'] ?? say}'.trim();
      return AgentDecision(
        raw: raw,
        thought: thought,
        say: say.isEmpty ? why : say,
        fail: why.isEmpty ? '模型放弃' : why,
      );
    }
    if (!agentOps.contains(op)) {
      // 白名单外的 op 一律拒绝 —— 否则模型一句 {"op":"shell"} 就成了后门
      return AgentDecision(
        raw: raw,
        thought: thought,
        say: say,
        fail: '模型给了不支持的指令 "$op"',
      );
    }
    final clean = Map<String, dynamic>.from(act)
      ..remove('action')
      ..remove('type')
      ..['op'] = op;
    return AgentDecision(
      thought: thought,
      say: say,
      cmd: AgentCmd.fromJson(clean),
      raw: raw,
    );
  }

  /// 从一段文本里取出第一个**括号平衡**的 JSON 对象。
  static String? _extractJson(String text) {
    var s = text.trim();
    if (s.isEmpty) return null;
    // 去掉 ```json … ``` 围栏
    final fence = RegExp(r'```(?:json|JSON)?\s*([\s\S]*?)```').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    final start = s.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < s.length; i++) {
      final ch = s[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == r'\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return s.substring(start, i + 1);
      }
    }
    return null;
  }
}

/// 模型连接配置。
class AgentLlm {
  final String providerId;
  final String model;
  final String base;
  final String apiKey;

  /// openai | anthropic
  final String kind;

  AgentLlm({
    required this.providerId,
    required this.model,
    required this.base,
    required this.apiKey,
    this.kind = 'openai',
  });

  bool get ready => model.trim().isNotEmpty && base.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  static const Duration _timeout = Duration(seconds: 75);

  /// 让模型看一张截图，返回下一步。
  ///
  /// [trace] 是已经做过的事（纯文本，不含历史截图）：只带当前这一张图，
  /// 一是省 token，二是避免模型拿几张旧图"回忆"出一个已经不存在的界面。
  Future<AgentDecision> decide({
    required String goal,
    required String trace,
    required Uint8List? png,
    required Map<String, dynamic> state,
    required List<Map<String, dynamic>> nodes,
  }) async {
    final sys = buildSystemPrompt();
    final user = _buildUserText(goal: goal, trace: trace, state: state, nodes: nodes);
    try {
      final text = kind == 'anthropic'
          ? await _anthropic(sys, user, png)
          : await _openai(sys, user, png);
      return AgentDecision.parse(text);
    } on TimeoutException {
      return const AgentDecision(fail: '模型响应超时', say: '模型没在 75 秒内回复');
    } catch (e) {
      return AgentDecision(fail: '请求失败：$e', say: '连不上模型');
    }
  }

  // ── 请求体组装（拆成方法，便于单测里检查形状）──

  static Map<String, dynamic> openaiBody({
    required String model,
    required String sys,
    required String user,
    required Uint8List? png,
  }) =>
      {
        'model': model,
        'temperature': 0.2,
        'stream': false,
        'max_tokens': 900,
        'messages': [
          {'role': 'system', 'content': sys},
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': user},
              if (png != null)
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/png;base64,${base64Encode(png)}',
                    'detail': 'high',
                  }
                },
            ],
          }
        ],
      };

  static Map<String, dynamic> anthropicBody({
    required String model,
    required String sys,
    required String user,
    required Uint8List? png,
  }) =>
      {
        'model': model,
        'max_tokens': 900,
        'system': sys,
        'messages': [
          {
            'role': 'user',
            'content': [
              if (png != null)
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': 'image/png',
                    'data': base64Encode(png),
                  }
                },
              {'type': 'text', 'text': user},
            ],
          }
        ],
      };

  Future<String> _openai(String sys, String user, Uint8List? png) async {
    final url = _join(base, '/chat/completions');
    final r = await http
        .post(
          Uri.parse(url),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(openaiBody(model: model, sys: sys, user: user, png: png)),
        )
        .timeout(_timeout);
    return _readOpenai(r);
  }

  Future<String> _anthropic(String sys, String user, Uint8List? png) async {
    final url = _join(base, '/messages');
    final r = await http
        .post(
          Uri.parse(url),
          headers: {
            'content-type': 'application/json',
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
          body:
              jsonEncode(anthropicBody(model: model, sys: sys, user: user, png: png)),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw 'HTTP ${r.statusCode} ${_snippet(r.body)}';
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final blocks = (j is Map ? j['content'] : null) as List?;
    final sb = StringBuffer();
    for (final b in blocks ?? const []) {
      if (b is Map && b['type'] == 'text') sb.write(b['text'] ?? '');
    }
    return sb.toString();
  }

  /// 从 OpenAI 兼容响应里取正文字符串。
  ///
  /// 兼容三种真实回包：content 是字符串 / content 是分段数组 /
  /// 只给了 reasoning_content（部分推理模型会在 max_tokens 用尽时这样）。
  static String _readOpenai(http.Response r) {
    if (r.statusCode != 200) {
      throw 'HTTP ${r.statusCode} ${_snippet(r.body)}';
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) throw '响应不是 JSON 对象';
    final err = j['error'];
    if (err != null) {
      final msg = err is Map ? (err['message'] ?? err) : err;
      throw '$msg';
    }
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) throw '响应里没有 choices';
    final msg = (choices.first is Map) ? (choices.first as Map)['message'] : null;
    if (msg is! Map) throw '响应里没有 message';
    final c = msg['content'];
    if (c is String && c.trim().isNotEmpty) return c;
    if (c is List) {
      final sb = StringBuffer();
      for (final part in c) {
        if (part is Map && part['text'] != null) sb.write(part['text']);
      }
      if (sb.toString().trim().isNotEmpty) return sb.toString();
    }
    final rc = msg['reasoning_content'];
    if (rc is String && rc.trim().isNotEmpty) return rc;
    throw '响应正文为空（模型可能不支持看图，或 max_tokens 太小）';
  }

  static String _snippet(String s) =>
      s.length > 240 ? '${s.substring(0, 240)}…' : s;

  /// 拼 base + path，容忍用户填的 base 带不带尾斜杠、带不带 /v1。
  static String _join(String base, String path) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return '$b$path';
  }

  // ── 提示词 ──

  /// 系统提示词。改它等于改模型的行为边界，谨慎。
  static String buildSystemPrompt() => '''
你是「ThirdHub」这款手机 App 的自动测试操作员。你的任务：看着 App 的截图，一步一步把它操作到用户要求的目标状态，并如实报告结果。

## 你能做的事（每次只给一个动作）
- {"op":"nav","module":"视频"}                     打开模块（小说/漫画/视频/音乐/搜索/我的/AI/直播…）
- {"op":"platform","name":"红果"}                  视频页横向切平台（红果 / 哔哩哔哩 / 片库 / 历史 / 发现 / 搜索）
- {"op":"subtab","page":"视频","tab":"番剧"}        模块内子页签（B 站七栏目等）
- {"op":"tap","text":"红果短剧"}                    点屏幕上写着这行字的控件（首选，稳）
- {"op":"tap","xy":[0.5,0.8]}                      按坐标点，取值 0~1（文字找不到时才用）
- {"op":"swipe","dir":"left","dist":0.6}           滑动，dir=left/right/up/down
- {"op":"input","text":"斗破苍穹"}                  往当前输入框打字
- {"op":"back"}                                    返回上一层
- {"op":"wait","ms":1200}                          等界面加载
- {"op":"deeplink","url":"thirdhub://video?platform=hongguo"}  用固定深链直达（优先于连点）
- {"op":"shot"} / {"op":"state"} / {"op":"tree"}   重新取截图 / 状态 / 控件清单
- {"op":"done"}                                    目标已达成
- {"op":"fail","reason":"…"}                       确实做不到，说清原因

## 输出格式（只输出一个 JSON 对象，不要任何解释文字、不要代码块围栏）
{"thought":"我看到的和我的判断","say":"给用户看的一句话","action":{"op":"…"}}

终止时同样格式：{"thought":"…","say":"…","action":{"op":"done"}}

## 铁律
1. 一次只给一个动作。多动作会被拒绝。
2. 先看截图再决定。截图和你以为的不一样时，相信截图。
3. 不要重复同一个动作超过两次。没反应就换方法（换文字、换坐标、先 wait、或改用 deeplink）。
4. 只用上面列出的 op。别的 op 会被拒绝。
5. 判定"能不能用"时以截图为准：空白页、转圈、"加载失败"都是**失败**，不要说成功。
6. 目标做不到就 {"op":"fail"}，并写清卡在哪一步、屏幕上显示了什么。不要编造成功。
7. 安全：不要点广告、不要进支付、不要授权敏感权限；遇到就记下来并 fail。
''';

  /// 每步的用户消息正文（不含图片，图片单独塞 content 数组）。
  static String _buildUserText({
    required String goal,
    required String trace,
    required Map<String, dynamic> state,
    required List<Map<String, dynamic>> nodes,
  }) {
    final sb = StringBuffer();
    sb.writeln('## 用户目标');
    sb.writeln(goal.trim().isEmpty ? '（未指定，做一次全面可用性检查）' : goal.trim());
    sb.writeln();
    sb.writeln('## 当前状态');
    final keys = ['app', 'module', 'moduleIndex', 'platform', 'routeDepth', 'locale'];
    for (final k in keys) {
      if (state[k] != null) sb.writeln('- $k: ${state[k]}');
    }
    sb.writeln();
    sb.writeln('## 屏幕上可点的东西（label @ 归一化坐标中心）');
    var n = 0;
    final seen = <String>{};
    for (final e in nodes) {
      final label = '${e['label'] ?? ''}'.trim();
      if (label.isEmpty || !seen.add(label)) continue;
      final r = e['rect'];
      String at = '';
      if (r is List && r.length == 4) {
        try {
          final x = ((r[0] as num) + (r[2] as num)) / 2;
          final y = ((r[1] as num) + (r[3] as num)) / 2;
          at = '@${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}';
        } catch (_) {}
      }
      sb.writeln('- $label $at');
      if (++n >= 45) break;
    }
    if (n == 0) sb.writeln('（没抓到文字控件，可能是纯图界面 —— 用坐标点或先 wait）');
    sb.writeln();
    sb.writeln('## 已经做过的动作（最近 12 步）');
    sb.writeln(trace.trim().isEmpty ? '（还没有动作）' : trace.trim());
    sb.writeln();
    sb.writeln('现在给出下一个动作。');
    return sb.toString();
  }
}
