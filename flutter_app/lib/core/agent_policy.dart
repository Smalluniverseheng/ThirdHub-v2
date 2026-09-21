// ═══════════════════════════════════════════════════════════════════════════
// THA/1 · 权限策略（Flutter 侧本地镜像）
//
// 与 server/agent-profiles.json 是**同一套规则的两份表达**：
//   · 服务端为权威 —— 真正执行工具前一律由 /agent/* 再判一次；
//   · 本地这份只用于两件事：① UI 提前把按钮画成「需确认/已禁用」，
//     让用户点之前就知道会拦；② 断网/无后端时自己先拦一道，
//     避免「后端不在就什么都放行」。
//
// 因此 [AgentPolicy.applyServerTable] 允许用服务端下发的表覆盖本地镜像；
// 覆盖后 [mirrorStale] 会告诉你本地默认值是否已经和服务端不一致。
//
// 零 Flutter 依赖，可纯 Dart 自检。
// ═══════════════════════════════════════════════════════════════════════════

/// 工具风险分级（与 server 侧 risk 的 key 逐字一致）
class AgentRisk {
  static const read = 'read';
  static const write = 'write';
  static const danger = 'danger';

  /// 名字没登记在任何一档 → 按高危处理（白名单制的必然推论）
  static const unknown = 'unknown';

  static const labelOf = <String, String>{
    read: '只读安全',
    write: '受控写入',
    danger: '高危',
    unknown: '未登记（按高危处理）',
  };
}

/// 判定结果
class AgentDecision {
  static const allow = 'allow';
  static const confirm = 'confirm';
  static const deny = 'deny';
}

class PolicyDecision {
  final String decision; // allow | confirm | deny
  final String risk; // read | write | danger | unknown
  final String reason;

  const PolicyDecision(this.decision, this.risk, this.reason);

  bool get allowed => decision == AgentDecision.allow;
  bool get needsConfirm => decision == AgentDecision.confirm;
  bool get denied => decision == AgentDecision.deny;

  @override
  String toString() => 'PolicyDecision($decision/$risk)';
}

/// 档位 id（与服务端一致；注意 full-access 用连字符）
class AgentProfileId {
  static const normal = 'default';
  static const acceptEdits = 'acceptEdits';
  static const fullAccess = 'full-access';
}

class AgentPolicy {
  /// 本地镜像的版本号。服务端 agent-profiles.json 改了而这里没改时，
  /// [mirrorStale] 会给出提示 —— 免得两份表悄悄漂移。
  static const mirrorVersion = 1;

  // ── 工具风险表（镜像自 agent-profiles.json 的 risk 段） ──
  static const Map<String, List<String>> riskTable = {
    AgentRisk.read: [
      'kb.search',
      'book.info',
      'file.readSelected',
      'clipboard.read',
      'text.diff',
      'device.info',
      'fs.list'
    ],
    AgentRisk.write: [
      'note.save',
      'download.export',
      'bookshelf.update',
      'reading.progress.write',
      'clipboard.write',
      'device.tts',
      'device.share',
      'fs.share'
    ],
    AgentRisk.danger: [
      'fs.write',
      'fs.delete',
      'shell.run',
      'package.install',
      'browser.open',
      'accessibility.tap'
    ],
  };

  /// 本机工具名 → 策略工具名的映射（镜像自 agent-profiles.json 的 bridge 段）。
  ///
  /// 为什么需要它：Flutter 的 LocalTools 用的是 `local_file_write` 这种名字，
  /// 而策略表用的是 `fs.write` 这种名字。两套名字必须显式对上，否则
  /// 「策略放行了，实际调的却是另一个名字」——这种错在 UI 上看不出来。
  static const Map<String, String> localBridge = {
    'get_device_info': 'device.info',
    'clipboard_read': 'clipboard.read',
    'clipboard_write': 'clipboard.write',
    'tts_speak': 'device.tts',
    'open_url': 'browser.open',
    'share_text': 'device.share',
    'file_write': 'fs.write',
    'file_read': 'file.readSelected',
    'file_list': 'fs.list',
    'file_delete': 'fs.delete',
    'file_share': 'fs.share',
    'run_python': 'shell.run',
    'web_search': 'kb.search',
  };

  /// 把 Flutter 本机工具名（可带 `local_` 前缀）翻成策略工具名。
  /// 没登记的**原样返回**，于是 riskOf 会判成 unknown → 任何档位都调不动
  /// （宁严勿宽：漏登记的表现是「用不了」，而不是「悄悄放行」）。
  static String policyName(String localOrPolicyName) {
    final n = localOrPolicyName.startsWith('local_')
        ? localOrPolicyName.substring(6)
        : localOrPolicyName;
    if (localBridge.containsKey(n)) return localBridge[n]!;
    // 已经是策略名的（含 . ）直接返回
    if (n.contains('.')) return n;
    return localOrPolicyName;
  }

  /// 本机工具的判定（先翻名再判）
  static PolicyDecision decideLocal(String profileId, String localToolName) =>
      decide(profileId, policyName(localToolName));

  /// 本机工具是否允许离线执行
  static bool allowOfflineLocal(String localToolName) => allowOffline(policyName(localToolName));

  /// 工具与档位定义（镜像自 agent-profiles.json 的 profiles 段）
  static const Map<String, Map<String, dynamic>> profiles = {
    AgentProfileId.normal: {
      'label': '默认',
      'desc': '只读 + 保存草稿 + 书架阅读类写入',
      'allowRisk': [AgentRisk.read],
      'allowTools': [
        'note.save',
        'bookshelf.update',
        'reading.progress.write',
        'download.export'
      ],
      'confirmTools': [
        'note.save',
        'bookshelf.update',
        'reading.progress.write',
        'download.export'
      ],
      'denyTools': <String>[],
      'denyFullAccess': true,
      'visibleToUser': true,
    },
    AgentProfileId.acceptEdits: {
      'label': '本次会话接受修改',
      'desc': '当前会话内明确确认过的写文件 / 改书架 / 保存笔记；高危工具仍需逐次确认',
      'allowRisk': [AgentRisk.read, AgentRisk.write],
      'allowTools': ['fs.write'],
      'confirmTools': ['fs.write'],
      'denyTools': ['shell.run', 'package.install', 'accessibility.tap'],
      'denyFullAccess': true,
      'visibleToUser': true,
    },
    AgentProfileId.fullAccess: {
      'label': '完全访问',
      'desc': '仅服务端管理侧使用，普通用户界面不展示。全部工具放行，仍逐条写审计。',
      'allowRisk': [AgentRisk.read, AgentRisk.write, AgentRisk.danger],
      'allowTools': ['*'],
      'confirmTools': <String>[],
      'denyTools': <String>[],
      'denyFullAccess': false,
      'visibleToUser': false,
    },
  };

  // ── 运行时（可被服务端表覆盖） ──
  static Map<String, List<String>> _risk = Map.fromEntries(riskTable.entries
      .map((e) => MapEntry(e.key, List<String>.from(e.value))));
  static Map<String, Map<String, dynamic>> _profiles = {
    for (final e in profiles.entries) e.key: Map<String, dynamic>.from(e.value)
  };
  static int _serverVersion = 0;
  static bool _fromServer = false;

  /// 是否已用服务端下发的表覆盖
  static bool get usingServerTable => _fromServer;

  /// 服务端表版本（/agent/profiles 的 meta.risk 里带的 version；没有则为 0）
  static int get serverVersion => _serverVersion;

  /// 本地镜像是否可能已与服务端不一致（UI 可据此提示「以服务端为准」）
  static bool get mirrorStale =>
      _fromServer && _serverVersion != 0 && _serverVersion != mirrorVersion;

  /// 用服务端下发的表覆盖本地镜像。
  /// [risk] 形如 {name, label, desc, tools: []}；[profileList] 是 /agent/profiles 的 data。
  static void applyServerTable(Object? risk, Object? profileList,
      {int version = 0}) {
    try {
      if (risk is Map) {
        final next = <String, List<String>>{};
        for (final e in risk.entries) {
          final v = e.value;
          final tools = v is Map ? v['tools'] : null;
          if (tools is List) next['${e.key}'] = [for (final t in tools) '$t'];
        }
        if (next.isNotEmpty) _risk = next;
      }
      if (profileList is List && profileList.isNotEmpty) {
        final next = <String, Map<String, dynamic>>{};
        for (final p in profileList) {
          if (p is! Map) continue;
          final m = Map<String, dynamic>.from(p);
          final id = '${m['id'] ?? ''}';
          if (id.isEmpty) continue;
          next[id] = {
            'label': '${m['label'] ?? id}',
            'desc': '${m['desc'] ?? ''}',
            'allowRisk': _strList(m['allowRisk']),
            'allowTools': _strList(m['allowTools']),
            'confirmTools': _strList(m['confirmTools']),
            'denyTools': _strList(m['denyTools']),
            'denyFullAccess': m['denyFullAccess'] != false,
            'visibleToUser': m['visibleToUser'] != false,
          };
        }
        if (next.isNotEmpty) _profiles = next;
      }
      _serverVersion = version;
      _fromServer = true;
    } catch (_) {/* 服务端表畸形时保持本地镜像，不因为解析失败而放宽权限 */}
  }

  static List<String> _strList(Object? v) =>
      v is List ? [for (final e in v) '$e'] : <String>[];

  /// 恢复本地镜像（测试/登出后端时用）
  static void reset() {
    _risk = Map.fromEntries(riskTable.entries
        .map((e) => MapEntry(e.key, List<String>.from(e.value))));
    _profiles = {
      for (final e in profiles.entries)
        e.key: Map<String, dynamic>.from(e.value)
    };
    _serverVersion = 0;
    _fromServer = false;
  }

  /// 工具 → 风险等级。未登记一律 danger（宁严勿宽）。
  static String riskOf(String tool) {
    final t = tool.trim();
    if (t.isEmpty) return AgentRisk.unknown;
    for (final e in _risk.entries) {
      if (e.value.contains(t)) return e.key;
    }
    // 命名空间兜底：fs.* / shell.* / accessibility.* 之类没登记也按高危
    if (t.startsWith('fs.') ||
        t.startsWith('shell.') ||
        t.startsWith('package.') ||
        t.startsWith('browser.') ||
        t.startsWith('accessibility.')) {
      return AgentRisk.danger;
    }
    return AgentRisk.unknown;
  }

  static String riskLabel(String risk) => AgentRisk.labelOf[risk] ?? risk;

  /// 档位是否存在（写错必须判 deny，不能静默当 default）
  static bool hasProfile(String id) => _profiles.containsKey(id);

  static Map<String, dynamic>? profileOf(String id) => _profiles[id];

  /// 可见档位（full-access 不给普通用户看）
  static List<Map<String, dynamic>> visibleProfiles() => [
        for (final e in _profiles.entries)
          if (e.value['visibleToUser'] != false) {'id': e.key, ...e.value},
      ];

  /// 核心判定。顺序：档位存在性 → denyTools → 风险是否被覆盖 → confirmTools → allow
  ///
  /// 与服务端 agent-dsh.js 的 decide() 保持同序，两端结果必须一致
  /// （tool/agent_proto_selfcheck.dart 里有对拍断言）。
  static PolicyDecision decide(String profileId, String tool) {
    final prof = _profiles[profileId];
    if (prof == null) {
      return PolicyDecision(
          AgentDecision.deny, riskOf(tool), '未知档位「$profileId」——已拒绝');
    }
    final risk = riskOf(tool);
    final allowRisk = _strList(prof['allowRisk']);
    final allowTools = _strList(prof['allowTools']);
    final confirmTools = _strList(prof['confirmTools']);
    final denyTools = _strList(prof['denyTools']);
    final label = '${prof['label'] ?? profileId}';

    if (denyTools.contains(tool) || denyTools.contains('*')) {
      return PolicyDecision(AgentDecision.deny, risk, '档位「$label」显式禁用了该工具');
    }
    final covered = allowRisk.contains(risk) || allowTools.contains('*');
    if (!covered && !allowTools.contains(tool)) {
      return PolicyDecision(
        AgentDecision.deny,
        risk,
        risk == AgentRisk.danger
            ? '高危工具默认禁用：需切到更高档位，并逐次确认'
            : '档位「$label」未授权该工具',
      );
    }
    if (confirmTools.contains(tool)) {
      return const PolicyDecision(
          AgentDecision.confirm, AgentRisk.write, '该工具会改动数据，需要一次明确确认');
    }
    if (prof['denyFullAccess'] != false && risk == AgentRisk.danger) {
      return PolicyDecision(AgentDecision.confirm, risk, '高危工具需逐次确认');
    }
    return PolicyDecision(AgentDecision.allow, risk, '档位「$label」已授权');
  }

  /// 便捷判断
  static bool isDenied(String profileId, String tool) =>
      decide(profileId, tool).denied;
  static bool needsConfirm(String profileId, String tool) =>
      decide(profileId, tool).needsConfirm;

  /// 断网兜底：没有后端时本地能跑的工具（只读 + 用户当场点的动作）
  ///
  /// 这与 §7 的「本地 fallback 只做聊天、轻工具、简单上下文」对应 ——
  /// 不假装有完整 Agent 能力。
  static const Set<String> fallbackWhitelist = {
    'kb.search',
    'book.info',
    'file.readSelected',
    'clipboard.read',
    'text.diff',
    'note.save',
    'download.export',
  };

  /// 无后端时是否允许本地执行（高危永远不允许）
  static bool allowOffline(String tool) {
    if (riskOf(tool) == AgentRisk.danger) return false;
    return fallbackWhitelist.contains(tool);
  }

  /// 给 UI 用的工具分组清单（含判定），与服务端 /agent/tools 的形状一致
  static List<Map<String, dynamic>> catalog(String profileId) {
    final out = <Map<String, dynamic>>[];
    for (final risk in [AgentRisk.read, AgentRisk.write, AgentRisk.danger]) {
      for (final t in (_risk[risk] ?? const <String>[])) {
        final d = decide(profileId, t);
        out.add({
          'name': t,
          'risk': risk,
          'riskLabel': riskLabel(risk),
          'decision': d.decision,
          'reason': d.reason,
        });
      }
    }
    return out;
  }

  /// 每个档位下「允许 / 需确认 / 拒绝」的条数（设置页做概览用）
  static Map<String, int> summary(String profileId) {
    var a = 0, c = 0, d = 0;
    for (final t in catalog(profileId)) {
      switch (t['decision']) {
        case AgentDecision.allow:
          a++;
          break;
        case AgentDecision.confirm:
          c++;
          break;
        default:
          d++;
      }
    }
    return {'allow': a, 'confirm': c, 'deny': d};
  }
}
