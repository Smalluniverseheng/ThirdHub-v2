// ThirdHub v4.40.0 · AI 体系深化(PLAN-v3 §5)
//   AI-1 模块工具全注册 · AI-2 Chat/Work 双运行时(会话云端续跑) · AI-3 T3 确认队列
//   AI-4 声明式 UI 指令 · AI-5 语义树兜底 · AI-6 悬浮球四态+角标
//   AI-7 MCP 双向桥 · AI-8 AI 审计日志 · AI-9 定时 Agent
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'ai.dart';
import 'pro_kit.dart';
import 'pro_media.dart';
import 'pro_system.dart';

// ══════════════════════════════════════════════════════════════
// AI-8 审计日志: 每一次模型调用与工具执行都留痕(本地 + 可选上报后端)
// ══════════════════════════════════════════════════════════════
class AiAudit {
  static const mk = 'ai_audit_v1';

  static Future<void> log(String kind, String name,
      {String detail = '', bool ok = true}) async {
    await ProKit.push(mk, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'kind': kind,
      'name': name,
      'detail': detail.length > 800 ? detail.substring(0, 800) : detail,
      'ok': ok ? '1' : '0',
      'at': ProKit.now(),
    }, max: 1000);
  }

  static Future<List<Map<String, String>>> all() => ProKit.listOf(mk);

  static Future<void> clear() async {
    final p = await ProKit.prefs();
    await p.remove(mk);
  }

  static Future<int> pushUp() async {
    final l = await all();
    if (l.isEmpty) return 0;
    final r = await ProKit.postJson('/v1/audit', {'list': l});
    return r['ok'] == true ? l.length : 0;
  }
}

// ══════════════════════════════════════════════════════════════
// AI-1 模块工具全注册: 每个模块把自己"能干什么"登记成工具
// ══════════════════════════════════════════════════════════════
class AiToolSpec {
  final String name;
  final String desc;
  final Map<String, dynamic> schema;
  final Future<String> Function(Map<String, dynamic> args) run;
  const AiToolSpec(
      {required this.name,
      required this.desc,
      required this.schema,
      required this.run});
}

class LocalToolbox {
  /// 全部本机工具(注册表即真相; AI 面板与 MCP 桥都读这里)
  static List<AiToolSpec> all() => [
        AiToolSpec(
          name: 'open_module',
          desc: '打开应用里的某个模块页面(如 小说/漫画/视频/音乐/相册/文件)',
          schema: {
            'type': 'object',
            'properties': {
              'module': {'type': 'string', 'description': '模块名'}
            },
            'required': ['module']
          },
          run: (a) async {
            final m = '${a['module'] ?? ''}';
            if (m.isEmpty) return '缺少 module';
            ProBridge.openModule?.call(m);
            await AiAudit.log('tool', 'open_module', detail: m);
            return '已请求打开模块: $m';
          },
        ),
        AiToolSpec(
          name: 'web_search',
          desc: '联网搜索关键词并返回前几条结果(需在 AI 设置里配置搜索服务)',
          schema: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'}
            },
            'required': ['query']
          },
          run: (a) async {
            final q = '${a['query'] ?? ''}';
            final rs = await WebSearch.search(q, limit: 5);
            await AiAudit.log('tool', 'web_search', detail: q);
            if (rs.isEmpty) return '没有结果(或未配置搜索服务)';
            return rs
                .map((e) => '- ${e['title']}: ${e['url']}')
                .join('\n');
          },
        ),
        AiToolSpec(
          name: 'add_todo',
          desc: '把一件事记进待办清单',
          schema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'}
            },
            'required': ['text']
          },
          run: (a) async {
            final t = '${a['text'] ?? ''}'.trim();
            if (t.isEmpty) return '内容为空';
            await ProKit.push('ai_todos_v1', {
              'id': DateTime.now().microsecondsSinceEpoch.toString(),
              'title': t,
              'done': '0',
              'at': ProKit.now(),
            });
            await AiAudit.log('tool', 'add_todo', detail: t);
            return '已加入待办: $t';
          },
        ),
        AiToolSpec(
          name: 'add_note',
          desc: '把一段内容存成笔记',
          schema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'body': {'type': 'string'}
            },
            'required': ['body']
          },
          run: (a) async {
            final b = '${a['body'] ?? ''}'.trim();
            if (b.isEmpty) return '内容为空';
            await ProKit.push('ai_notes_v1', {
              'id': DateTime.now().microsecondsSinceEpoch.toString(),
              'title': '${a['title'] ?? 'AI 笔记'}',
              'body': b,
              'at': ProKit.now(),
            });
            await AiAudit.log('tool', 'add_note', detail: b.length > 60 ? b.substring(0, 60) : b);
            return '已存成笔记';
          },
        ),
        AiToolSpec(
          name: 'start_download',
          desc: '把直链/磁力加入下载中心',
          schema: {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'name': {'type': 'string'}
            },
            'required': ['url']
          },
          run: (a) async {
            final u = '${a['url'] ?? ''}'.trim();
            if (u.isEmpty) return '地址为空';
            await DownloadHub.add(title: '${a['name'] ?? ''}', url: u);
            await AiAudit.log('tool', 'start_download', detail: u);
            return '已加入下载中心';
          },
        ),
        AiToolSpec(
          name: 'set_reminder',
          desc: '设置一条提醒(本机)',
          schema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
              'at': {'type': 'string', 'description': 'YYYY-MM-DD HH:MM'}
            },
            'required': ['text']
          },
          run: (a) async {
            final t = '${a['text'] ?? ''}'.trim();
            if (t.isEmpty) return '内容为空';
            await ProKit.push('ai_reminders_v1', {
              'id': DateTime.now().microsecondsSinceEpoch.toString(),
              'text': t,
              'at': '${a['at'] ?? ProKit.now()}',
            });
            await AiAudit.log('tool', 'set_reminder', detail: t);
            return '已记录提醒: $t';
          },
        ),
        AiToolSpec(
          name: 'summarize',
          desc: '把一段长文本压缩成要点',
          schema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'}
            },
            'required': ['text']
          },
          run: (a) async {
            final t = '${a['text'] ?? ''}';
            if (t.length < 20) return '文本太短';
            try {
              final r = await ProAi.ask('用 5 条以内的要点总结下面内容:\n\n$t',
                  system: '你是摘要引擎, 只输出要点。');
              await AiAudit.log('tool', 'summarize', detail: '${t.length} 字');
              return r;
            } catch (e) {
              await AiAudit.log('tool', 'summarize', detail: '$e', ok: false);
              return '摘要失败: $e';
            }
          },
        ),
        AiToolSpec(
          name: 'hand_to_reader',
          desc: '把一段纯文本交给小说阅读器(可听书/有进度记忆)',
          schema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'text': {'type': 'string'}
            },
            'required': ['text']
          },
          run: (a) async {
            final t = '${a['text'] ?? ''}';
            if (t.length < 20) return '文本太短';
            await ProBridge.openReader?.call('${a['title'] ?? 'AI 文本'}', t);
            await AiAudit.log('tool', 'hand_to_reader', detail: '${t.length} 字');
            return '已交给阅读器';
          },
        ),
      ];

  /// AI-7: 导出为 MCP/OpenAI 兼容的工具表
  static List<Map<String, dynamic>> asMcpTools() => [
        for (final t in all())
          {'name': t.name, 'description': t.desc, 'inputSchema': t.schema}
      ];

  static AiToolSpec? byName(String n) {
    for (final t in all()) {
      if (t.name == n) return t;
    }
    return null;
  }

  /// 手动试跑(工作台里用)
  static Future<String> invoke(String name, Map<String, dynamic> args) async {
    final t = byName(name);
    if (t == null) return '没有这个工具: $name';
    try {
      return await t.run(args);
    } catch (e) {
      return '执行出错: $e';
    }
  }
}

// ══════════════════════════════════════════════════════════════
// AI-3 T3 确认队列: 高风险动作先挂起, 人来批
// ══════════════════════════════════════════════════════════════
class ConfirmQueue {
  static const mk = 'ai_confirm_queue_v1';
  static const group = ConfirmQueueGroup();

  static Future<List<Map<String, String>>> all() => ProKit.listOf(mk);

  static Future<void> add(String tool, String args, {String reason = ''}) async {
    await ProKit.push(mk, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'tool': tool,
      'args': args,
      'reason': reason,
      'state': 'pending',
      'at': ProKit.now(),
    }, max: 200);
    AiOrb.waiting();
  }

  static Future<void> decide(String id, bool approve) async {
    final l = await all();
    String tool = '', args = '';
    for (final e in l) {
      if (e['id'] == id) {
        e['state'] = approve ? 'approved' : 'rejected';
        tool = e['tool'] ?? '';
        args = e['args'] ?? '';
      }
    }
    await ProKit.saveList(mk, l);
    if (approve) {
      Map<String, dynamic> parsed = {};
      try {
        parsed = Map<String, dynamic>.from(jsonDecode(args) as Map);
      } catch (_) {}
      await LocalToolbox.invoke(tool, parsed);
    }
    await AiAudit.log('confirm', tool, detail: approve ? '批准' : '拒绝');
  }

  static Future<void> clearDone() async {
    final l = await all();
    l.removeWhere((e) => e['state'] != 'pending');
    await ProKit.saveList(mk, l);
  }
}

/// 让 ConfirmQueue 能直接读静态成员(避免实例状态与存储不一致)
class ConfirmQueueGroup {
  const ConfirmQueueGroup();
}

// ══════════════════════════════════════════════════════════════
// AI-6 悬浮球四态 + 角标(全局状态, 供 AI 页与悬浮球读取)
// ══════════════════════════════════════════════════════════════
class AiOrb {
  static final ValueNotifier<String> state = ValueNotifier<String>('idle');
  static final ValueNotifier<int> badge = ValueNotifier<int>(0);

  static void idle() => state.value = 'idle';
  static void thinking() => state.value = 'thinking';
  static void acting() => state.value = 'acting';
  static void waiting() {
    state.value = 'waiting-confirm';
    badge.value = badge.value + 1;
  }

  static void clearBadge() => badge.value = 0;

  static String label(String s) => switch (s) {
        'thinking' => '思考中',
        'acting' => '执行中',
        'waiting-confirm' => '等待确认',
        _ => '空闲',
      };
}

// ══════════════════════════════════════════════════════════════
// AI-4 声明式 UI 指令: AI 返回的 JSON 由前端执行(不执行任意代码)
// ══════════════════════════════════════════════════════════════
class UiCommand {
  final String op;
  final Map<String, dynamic> args;
  const UiCommand(this.op, this.args);

  /// 支持: navigate / toast / dialog / highlight / open_module / copy
  static List<UiCommand> parse(String raw) {
    final out = <UiCommand>[];
    try {
      var s = raw.trim();
      final start = s.indexOf('[');
      final end = s.lastIndexOf(']');
      if (start >= 0 && end > start) s = s.substring(start, end + 1);
      final list = jsonDecode(s) as List;
      for (final e in list) {
        if (e is Map && e['op'] != null) {
          out.add(UiCommand('${e['op']}',
              Map<String, dynamic>.from((e['args'] as Map?) ?? {})));
        }
      }
    } catch (_) {}
    return out;
  }

  static Future<String> exec(BuildContext c, UiCommand cmd) async {
    switch (cmd.op) {
      case 'toast':
        ProUI.toast(c, '${cmd.args['text'] ?? ''}');
        return 'toast';
      case 'dialog':
        await showDialog<void>(
          context: c,
          builder: (c2) => AlertDialog(
            title: Text('${cmd.args['title'] ?? '提示'}'),
            content: Text('${cmd.args['body'] ?? ''}',
                style: const TextStyle(fontSize: 13, height: 1.5)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c2), child: const Text('知道了')),
            ],
          ),
        );
        return 'dialog';
      case 'open_module':
        ProBridge.openModule?.call('${cmd.args['module'] ?? ''}');
        return 'open_module';
      case 'navigate':
        ProBridge.openModule?.call('${cmd.args['module'] ?? ''}');
        return 'navigate';
      case 'highlight':
        ProUI.toast(c, '已定位: ${cmd.args['target'] ?? ''}');
        return 'highlight';
      default:
        return '未支持的指令: ${cmd.op}';
    }
  }

  static Future<List<String>> execAll(BuildContext c, String raw) async {
    final out = <String>[];
    for (final cmd in parse(raw)) {
      out.add(await exec(c, cmd));
    }
    return out;
  }
}

// ══════════════════════════════════════════════════════════════
// AI-5 语义树兜底: 未注册模块也能"读屏"——把当前界面可读元素导成清单
// ══════════════════════════════════════════════════════════════
class SemanticsDump {
  static Future<List<String>> snapshot() async {
    final out = <String>[];
    try {
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) return out;
      void walk(Element e) {
        if (out.length > 120) return;
        final w = e.widget;
        if (w is Text && (w.data ?? '').trim().isNotEmpty) {
          out.add('文本: ${w.data}');
        } else if (w is Tooltip && (w.message ?? '').isNotEmpty) {
          out.add('提示: ${w.message}');
        } else if (w is IconButton) {
          out.add('按钮(图标)');
        } else if (w is ListTile) {
          final t = w.title;
          if (t is Text && (t.data ?? '').isNotEmpty) out.add('列表项: ${t.data}');
        } else if (w is ElevatedButton || w is TextButton || w is FilledButton) {
          final ch = w is ElevatedButton
              ? w.child
              : (w is TextButton ? w.child : (w as FilledButton).child);
          if (ch is Text) out.add('按钮: ${ch.data}');
        }
        e.visitChildren(walk);
      }

      walk(root);
    } catch (_) {}
    return out;
  }

  /// 供 AI 使用的紧凑文本
  static Future<String> asPrompt() async {
    final l = await snapshot();
    if (l.isEmpty) return '(当前界面没有可读元素)';
    return l.take(80).join('\n');
  }
}

// ══════════════════════════════════════════════════════════════
// AI-2 会话双运行时: 会话状态可上传后端 → 换设备续跑
// ══════════════════════════════════════════════════════════════
class AiSessions {
  static const mk = 'ai_sessions_v1';

  static Future<List<Map<String, String>>> local() => ProKit.listOf(mk);

  static Future<void> save(String id, String title, String json) async {
    await ProKit.push(mk, {
      'id': id,
      'title': title,
      'json': json,
      'at': ProKit.now(),
    }, max: 100);
  }

  static Future<int> pushUp() async {
    final l = await local();
    if (l.isEmpty) return 0;
    final r = await ProKit.postJson('/v1/sessions', {'list': l});
    return r['ok'] == true ? l.length : 0;
  }

  static Future<int> pullDown() async {
    final r = await ProKit.getJson('/v1/sessions');
    final d = r['data'];
    final raw = (d is Map) ? d['list'] : d;
    if (raw is! List) return 0;
    final l = [for (final e in raw) Map<String, String>.from(e as Map)];
    if (l.isEmpty) return 0;
    await ProKit.saveList(mk, l);
    return l.length;
  }
}

// ══════════════════════════════════════════════════════════════
// AI-9 定时 Agent: "每天 7 点摘要新闻" —— 到点由本机执行(打开 App 时补跑)
// ══════════════════════════════════════════════════════════════
class CronAgents {
  static const mk = 'ai_cron_v1';

  static Future<List<Map<String, String>>> all() => ProKit.listOf(mk);

  static Future<void> add(String prompt, {String time = '07:00'}) async {
    await ProKit.push(mk, {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'prompt': prompt,
      'time': time,
      'enabled': '1',
      'lastRun': '',
      'lastResult': '',
      'at': ProKit.now(),
    }, max: 50);
  }

  static Future<void> toggle(String id, bool on) async {
    final l = await all();
    for (final e in l) {
      if (e['id'] == id) e['enabled'] = on ? '1' : '0';
    }
    await ProKit.saveList(mk, l);
  }

  static Future<void> remove(String id) async {
    final l = await all();
    l.removeWhere((e) => e['id'] == id);
    await ProKit.saveList(mk, l);
  }

  static String _todayAt(String hhmm) {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} $hhmm';
  }

  /// 补跑到期任务: 条件 = 启用 且 今天该时刻已过 且 今天没跑过
  static Future<int> runDue() async {
    final l = await all();
    var ran = 0;
    final now = DateTime.now();
    final out = <Map<String, String>>[];
    for (final e in l) {
      if (e['enabled'] != '1') {
        out.add(e);
        continue;
      }
      final at = e['time'] ?? '07:00';
      final parts = at.split(':');
      final hh = int.tryParse(parts.isNotEmpty ? parts[0] : '7') ?? 7;
      final mm = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
      final due = DateTime(now.year, now.month, now.day, hh, mm);
      final today = _todayAt(at);
      if (now.isAfter(due) && (e['lastRun'] ?? '') != today) {
        try {
          final r = await ProAi.ask('${e['prompt']}',
              system: '你是定时助手, 输出简短结论, 便于在手机上快速阅读。');
          e['lastResult'] = r.length > 600 ? r.substring(0, 600) : r;
          e['lastRun'] = today;
          ran++;
          await AiAudit.log('cron', e['prompt'] ?? '', detail: '已执行');
        } catch (err) {
          e['lastResult'] = '执行失败: $err';
          e['lastRun'] = today;
          await AiAudit.log('cron', e['prompt'] ?? '', detail: '$err', ok: false);
        }
      }
      out.add(e);
    }
    await ProKit.saveList(mk, out);
    return ran;
  }
}

// ══════════════════════════════════════════════════════════════
// AI-7 MCP 双向桥: 后端暴露 MCP(HTTP/JSON-RPC) → 外部 Agent 可调本机能力
// ══════════════════════════════════════════════════════════════
class McpBridge {
  static Future<Map<String, dynamic>> info() => ProKit.getJson('/mcp/info');

  /// 外部(如桌面 Agent)用它列工具
  static Future<Map<String, dynamic>> tools() => ProKit.postJson(
      '/mcp', {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});

  /// 外部调用某个工具(走本机注册表执行)
  static Future<Map<String, dynamic>> call(String name,
      Map<String, dynamic> args) async {
    final r = await ProKit.postJson('/mcp', {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args}
    });
    if (r['ok'] == true && r['result'] != null) return r;
    // 后端不可用 → 本机直接执行(离线兜底)
    final out = await LocalToolbox.invoke(name, args);
    return {'ok': true, 'result': out, 'local': true};
  }
}

// ══════════════════════════════════════════════════════════════
// AI 工作台 UI
// ══════════════════════════════════════════════════════════════
class AiWorkbenchPage extends ProPage {
  const AiWorkbenchPage({super.key});
  @override
  State<AiWorkbenchPage> createState() => _AiW();
}

class _AiW extends ProPageState<AiWorkbenchPage> {
  List<Map<String, String>> queue = [];
  List<Map<String, String>> audit = [];
  List<Map<String, String>> crons = [];
  List<String> sem = [];
  String mcpState = '未探测';

  @override
  String get titleText => 'AI 工作台';

  @override
  Future<void> load() async {
    queue = await ConfirmQueue.all();
    audit = await AiAudit.all();
    crons = await CronAgents.all();
    sem = await SemanticsDump.snapshot();
  }

  @override
  List<Widget> buildBody(BuildContext c) {
    final pending = queue.where((e) => e['state'] == 'pending').toList();
    return [
      // AI-6 悬浮球四态
      ProUI.card('AI-6 悬浮球状态', [
        ValueListenableBuilder<String>(
          valueListenable: AiOrb.state,
          builder: (_, s, __) => ProUI.row(Icons.radio_button_checked, '当前状态',
              value: AiOrb.label(s),
              sub: 'idle / thinking / acting / waiting-confirm 四态'),
        ),
        ValueListenableBuilder<int>(
          valueListenable: AiOrb.badge,
          builder: (_, n, __) => ProUI.row(Icons.badge_outlined, '待确认角标',
              value: '$n',
              trailing: TextButton(
                  onPressed: () {
                    AiOrb.clearBadge();
                  },
                  child: const Text('清零', style: TextStyle(fontSize: 12)))),
        ),
        ProUI.row(Icons.bolt_outlined, '模拟一次调用(测试四态)', onTap: () async {
          AiOrb.thinking();
          await Future<void>.delayed(const Duration(milliseconds: 600));
          AiOrb.acting();
          await Future<void>.delayed(const Duration(milliseconds: 600));
          AiOrb.waiting();
          if (mounted) touch();
          AiOrb.idle();
        }),
      ]),

      // AI-1 工具注册表
      ProUI.card('AI-1 模块工具全注册', [
        for (final t in LocalToolbox.all())
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: const Icon(Icons.extension_outlined, size: 18),
            title: Text(t.name,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
            subtitle: Text(t.desc,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            trailing: TextButton(
                onPressed: () => _tryTool(c, t),
                child: const Text('试跑', style: TextStyle(fontSize: 11))),
          ),
      ], sub: '共 ${LocalToolbox.all().length} 个本机工具; AI 与 MCP 桥共用这张表'),

      // AI-3 确认队列
      ProUI.card('AI-3 T3 确认队列', [
        ProUI.row(Icons.pending_actions, '待确认',
            value: '${pending.length} 项',
            sub: '高风险动作挂起, 你点头才执行',
            trailing: pending.isEmpty
                ? null
                : TextButton(
                    onPressed: () async {
                      await ConfirmQueue.clearDone();
                      await refresh();
                    },
                    child: const Text('清理', style: TextStyle(fontSize: 12)))),
        for (final e in pending)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: const Icon(Icons.warning_amber_outlined, size: 18),
            title: Text('${e['tool']}', style: const TextStyle(fontSize: 13)),
            subtitle: Text('${e['args']}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                  onPressed: () async {
                    await ConfirmQueue.decide(e['id'] ?? '', true);
                    await refresh();
                  },
                  child: const Text('批准', style: TextStyle(fontSize: 11))),
              TextButton(
                  onPressed: () async {
                    await ConfirmQueue.decide(e['id'] ?? '', false);
                    await refresh();
                  },
                  child: const Text('拒绝', style: TextStyle(fontSize: 11))),
            ]),
          ),
        ProUI.row(Icons.add_task, '往队列里放一条示例', onTap: () async {
          await ConfirmQueue.add('add_todo', jsonEncode({'text': 'AI 提议的待办(示例)'}),
              reason: '演示确认队列');
          await refresh();
        }),
      ]),

      // AI-4 声明式 UI
      ProUI.card('AI-4 声明式 UI 指令', [
        ProUI.row(Icons.auto_fix_high, '执行一段指令 JSON',
            sub: 'navigate / toast / dialog / open_module / highlight',
            onTap: () => _runUiCmds(c)),
      ], sub: 'AI 只能指挥界面, 不能执行任意代码'),

      // AI-5 语义树
      ProUI.card('AI-5 语义树兜底', [
        ProUI.row(Icons.account_tree_outlined, '当前界面可读元素',
            value: '${sem.length} 个',
            sub: '未注册模块也能被 AI 读到',
            onTap: () => _showSem(c)),
      ]),

      // AI-7 MCP 桥
      ProUI.card('AI-7 MCP 双向桥', [
        ProUI.row(Icons.cable, '后端 MCP 端点',
            value: mcpState,
            sub: '外部 Agent 通过 /mcp 调本机工具; 后端不在时本机兜底执行',
            onTap: () async {
              final r = await McpBridge.tools();
              touch(() => mcpState = r['ok'] == true ? '可用' : '后端未连接');
              if (!mounted) return;
              if (r['ok'] != true) {
                ProUI.toast(c, '后端未连接, 将走本机兜底执行');
              }
            }),
        ProUI.row(Icons.content_copy, '复制工具表(给外部 Agent)',
            onTap: () => _showMcpTools(c)),
      ]),

      // AI-8 审计
      ProUI.card('AI-8 AI 审计日志', [
        ProUI.row(Icons.receipt_long, '共 ${audit.length} 条',
            sub: '模型调用与工具执行全部留痕',
            trailing: TextButton(
                onPressed: () async {
                  await AiAudit.pushUp();
                  await refresh();
                  if (mounted) ProUI.toast(c, '已尝试上报后端');
                },
                child: const Text('上报', style: TextStyle(fontSize: 12)))),
        for (final e in audit.take(25))
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(
                e['ok'] == '1' ? Icons.check_circle_outline : Icons.error_outline,
                size: 17,
                color: e['ok'] == '1' ? Colors.green : Colors.red),
            title: Text('${e['kind']} · ${e['name']}',
                style: const TextStyle(fontSize: 12.5)),
            subtitle: Text('${e['at']}  ${e['detail']}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ProUI.row(Icons.delete_outline, '清空日志', onTap: () async {
          await AiAudit.clear();
          await refresh();
        }),
      ]),

      // AI-9 定时 Agent
      ProUI.card('AI-9 定时 Agent', [
        ProUI.row(Icons.schedule, '新建定时任务',
            sub: '例如: 每天 07:00 摘要今日要闻',
            onTap: () => _addCron(c)),
        ProUI.row(Icons.play_circle_outline, '立即补跑到期任务',
            sub: '打开应用时自动检查一次', onTap: () async {
          ProUI.toast(c, '执行中…');
          final n = await CronAgents.runDue();
          await refresh();
          ProUI.toast(c, n > 0 ? '已执行 $n 个任务' : '没有到期任务');
        }),
        for (final e in crons)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            title: Text('${e['time']}  ${e['prompt']}',
                style: const TextStyle(fontSize: 12.5),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            subtitle: Text(
                (e['lastResult'] ?? '').isEmpty
                    ? '还没跑过'
                    : '上次(${e['lastRun']}): ${e['lastResult']}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(
                  value: e['enabled'] == '1',
                  onChanged: (v) async {
                    await CronAgents.toggle(e['id'] ?? '', v);
                    await refresh();
                  }),
              IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () async {
                    await CronAgents.remove(e['id'] ?? '');
                    await refresh();
                  }),
            ]),
          ),
        if (crons.isEmpty) ProUI.note('还没有定时任务。'),
      ]),

      // AI-2 会话续跑
      ProUI.card('AI-2 会话无缝续跑', [
        ProUI.row(Icons.cloud_upload_outlined, '把会话备份到后端',
            onTap: () async {
          final n = await AiSessions.pushUp();
          ProUI.toast(c, n > 0 ? '已上传 $n 个会话' : '没有可上传的会话或后端未连接');
        }),
        ProUI.row(Icons.cloud_download_outlined, '从后端拉回会话', onTap: () async {
          final n = await AiSessions.pullDown();
          await refresh();
          ProUI.toast(c, n > 0 ? '已拉回 $n 个会话' : '后端没有会话或未连接');
        }),
      ], sub: '换设备登录同一后端即可接着聊'),
    ];
  }

  Future<void> _tryTool(BuildContext c, AiToolSpec t) async {
    String argsRaw = '{}';
    final keys = ((t.schema['properties'] as Map?)?.keys ?? []).map((e) => '$e');
    if (keys.isNotEmpty) {
      final input = await ProKit.prompt(c, '参数(JSON)',
          hint: '{${keys.map((k) => '"$k":""').join(', ')}}', init: '{${keys.map((k) => '"$k":""').join(', ')}}');
      if (input == null) return;
      argsRaw = input;
    }
    Map<String, dynamic> args = {};
    try {
      args = Map<String, dynamic>.from(jsonDecode(argsRaw) as Map);
    } catch (_) {
      ProUI.toast(c, '参数不是合法 JSON');
      return;
    }
    ProUI.toast(c, '执行中…');
    final out = await LocalToolbox.invoke(t.name, args);
    await refresh();
    if (!mounted) return;
    await showDialog<void>(
      context: c,
      builder: (c2) => AlertDialog(
        title: Text('${t.name} 返回'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: SelectableText(out,
                    style: const TextStyle(fontSize: 12, height: 1.5)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _runUiCmds(BuildContext c) async {
    const sample =
        '[{"op":"toast","args":{"text":"来自 AI 的提示"}},{"op":"dialog","args":{"title":"AI 指令","body":"这条弹窗由 AI 的 JSON 指令触发。"}}]';
    final raw = await ProKit.prompt(c, 'AI 指令 JSON', init: sample, lines: 4);
    if (raw == null) return;
    final done = await UiCommand.execAll(c, raw);
    if (!mounted) return;
    ProUI.toast(c, done.isEmpty ? '没有解析出可用指令' : '已执行: ${done.join(', ')}');
  }

  Future<void> _showSem(BuildContext c) async {
    final txt = await SemanticsDump.asPrompt();
    if (!mounted) return;
    await showDialog<void>(
      context: c,
      builder: (c2) => AlertDialog(
        title: const Text('语义树快照'),
        content: SizedBox(
            width: 440,
            height: 360,
            child: SingleChildScrollView(
                child: SelectableText(txt,
                    style: const TextStyle(fontSize: 11.5, height: 1.5)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _showMcpTools(BuildContext c) async {
    final txt = const JsonEncoder.withIndent('  ')
        .convert(LocalToolbox.asMcpTools());
    if (!mounted) return;
    await showDialog<void>(
      context: c,
      builder: (c2) => AlertDialog(
        title: const Text('MCP tools/list 结果'),
        content: SizedBox(
            width: 440,
            height: 380,
            child: SingleChildScrollView(
                child: SelectableText(txt,
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace', height: 1.4)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _addCron(BuildContext c) async {
    final p = await ProKit.prompt(c, '任务内容',
        hint: '例如: 摘要今天的科技新闻要点', init: '');
    if (p == null) return;
    final t = await ProKit.prompt(c, '每天几点执行', init: '07:00');
    await CronAgents.add(p, time: t ?? '07:00');
    await refresh();
  }
}
