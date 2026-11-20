// AI 控制总线 · 协议层（纯 Dart，不 import flutter）
//
// 设计目标：让「AI 无触屏操控 App」这件事有一个**可单测**的契约。
// 桥（agent_bridge.dart）只负责收发，真正的参数校验全在这里，
// 所以 `dart test` 能在没有手机的情况下把协议跑一遍。
//
// 指令形状（POST /agent/exec 的 body，或 /agent/script 的数组元素）：
//   {"op": "tap", "key": "nav/video"}
//   {"op": "swipe", "dir": "left", "dist": 0.6}
//   {"op": "nav", "module": "视频"}
//   {"op": "wait", "ms": 300}
//   {"op": "assert", "text": "红果短剧"}
//
// 所有 op 都是**幂等可重试**的语义（tap 除外），失败一律返回
// {ok:false, error:"...", hint:"..."} —— 不做静默降级，
// 因为「工具报通过但实际没通过」是这个项目最贵的坑。

/// 一条指令。
class AgentCmd {
  /// 操作名（见 [agentOps]）
  final String op;

  /// 参数（已摊平到顶层，方便 {"op":"nav","module":"视频"} 这种写法）
  final Map<String, dynamic> args;

  /// 客户端序号，原样回传，方便批量脚本对齐
  final int id;

  const AgentCmd(this.op, this.args, {this.id = 0});

  /// 从 JSON 解析。宽容：op 缺省视为 `state`（无副作用的探活），
  /// 因为"发错了但不想炸"比"整个脚本中断"更实用。
  factory AgentCmd.fromJson(Map<String, dynamic> j) {
    final raw = j['op'];
    final op = (raw is String && raw.trim().isNotEmpty)
        ? raw.trim().toLowerCase()
        : 'state';
    final idRaw = j['id'];
    final id = idRaw is int ? idRaw : int.tryParse('${idRaw ?? ''}') ?? 0;
    final args = <String, dynamic>{};
    for (final e in j.entries) {
      if (e.key == 'op' || e.key == 'id') continue;
      args[e.key] = e.value;
    }
    return AgentCmd(op, args, id: id);
  }

  // ── 参数取用（统一在这里做类型收敛，桥里不再各写一份）──

  String? str(String k) {
    final v = args[k];
    if (v == null) return null;
    if (v is String) return v;
    return '$v';
  }

  double? num_(String k) {
    final v = args[k];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  int? integer(String k) {
    final v = args[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  bool bool_(String k, {bool def = false}) {
    final v = args[k];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == '1' || v.toLowerCase() == 'true';
    return def;
  }

  /// 归一化后的方向：left/right/up/down
  String? get dir {
    final d = (str('dir') ?? str('direction') ?? '').toLowerCase();
    return AgentDirs.contains(d) ? d : null;
  }

  /// 点击中心点 [x,y]（允许 ["0.5","0.8"] 或 "0.5,0.8"）
  List<double>? get xy {
    final v = args['xy'] ?? args['point'] ?? args['at'];
    if (v is List && v.length >= 2) {
      final a = v[0] is num
          ? (v[0] as num).toDouble()
          : double.tryParse('${v[0]}');
      final b = v[1] is num
          ? (v[1] as num).toDouble()
          : double.tryParse('${v[1]}');
      if (a != null && b != null) return [a, b];
      return null;
    }
    if (v is String) {
      final p = v.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
      if (p.length >= 2) {
        final a = double.tryParse(p[0]);
        final b = double.tryParse(p[1]);
        if (a != null && b != null) return [a, b];
      }
    }
    final x = num_('x');
    final y = num_('y');
    if (x != null && y != null) return [x, y];
    return null;
  }

  Map<String, dynamic> toJson() => {'op': op, ...args, 'id': id};
}

/// 一条指令的执行结果。
class AgentResult {
  final bool ok;
  final dynamic data;
  final String? error;

  /// 给人（和 AI）看的下一步建议。只在失败时有意义 ——
  /// 「点不到」和「页面没加载完」在日志里长得一模一样，不区分就是浪费一轮排查。
  final String? hint;

  final int ms;

  const AgentResult.ok(this.data, {this.ms = 0})
      : ok = true,
        error = null,
        hint = null;

  const AgentResult.err(this.error, {this.hint, this.ms = 0})
      : ok = false,
        data = null;

  Map<String, dynamic> toJson() => {
        'ok': ok,
        if (data != null) 'data': data,
        if (error != null) 'error': error,
        if (hint != null) 'hint': hint,
        'ms': ms,
      };
}

/// 支持的操作集合。新增操作必须同时进这里 —— 桥里做白名单校验，
/// 避免把 HTTP body 里任意字符串当命令派发（那等于开了个 RPC 后门）。
const Set<String> agentOps = {
  'ping', // 探活
  'state', // 应用状态快照
  'tree', // 当前可见控件树（可寻址者）
  'nav', // 打开模块
  'tab', // 切根导航下标/名字
  'platform', // 视频页平台横切
  'subtab', // 模块内子页签
  'tap', // 按 key / text / 坐标点击
  'swipe', // 真实手势滑动
  'input', // 向当前焦点输入
  'back', // 返回
  'shot', // 截图（base64 png）
  'wait', // 等待
  'assert', // 断言
  'eval', // 调前端注册的具名动作
  'script', // 批量执行
};

/// 方向白名单。
const Set<String> AgentDirs = {'left', 'right', 'up', 'down'};

/// 协议版本：客户端据此判断能力，不用猜。
const String kAgentProto = '1';

/// 组装标准响应体。
Map<String, dynamic> agentEnvelope(Object? payload, {String? token}) => {
      'proto': kAgentProto,
      if (token != null) 'token': token,
      'ts': DateTime.now().toIso8601String(),
      'payload': payload,
    };
