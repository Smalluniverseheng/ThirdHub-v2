// 端网 · 插件 · 密钥 —— 「前端/后端/插件/DSA 任意组合插线」的管理页。
//
// 这一页回答四个问题，按这个顺序从上到下排（用户最先要看到的是"现在通不通"）：
//   1. 现在通不通？        → 顶部状态条（PeerHubRuntime.status）
//   2. 有谁在？            → 端列表（在线/离线分组 + 能力与直连地址）
//   3. 这活谁干？          → 每端上的「调用」按钮（走 PeerHubClient.invoke）
//   4. 密钥统一了吗？      → 密钥同步区（PeerHubClient.syncSecrets + merge 报告）
//
// 关键设计：**没有后端这一页也必须能用**。
//   · 状态条会明确写"离线模式/无后端直连模式"，不装作已连接
//   · 端列表回落本地缓存（PeerHubClient.loadCache）
//   · 「调用」在后端不在时自动改走直连插件（PeerRouter 决定，本页不重复判定）
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'peer_hub.dart';

class PeerPage extends StatefulWidget {
  const PeerPage({super.key});
  @override
  State<PeerPage> createState() => _PeerPageState();
}

class _PeerPageState extends State<PeerPage> {
  StreamSubscription? _sub;
  PeerRegistry _reg = PeerRegistry.empty;
  bool _busy = false;
  String _diag = '';
  String _lastReport = '';
  final List<PeerMsg> _inbox = [];
  final TextEditingController _cast = TextEditingController();
  final TextEditingController _acc = TextEditingController();
  final TextEditingController _pwd = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reg = PeerHubRuntime.registry;
    _sub = PeerHubRuntime.changes.listen((r) {
      if (mounted) setState(() => _reg = r);
    });
    // 进页面即刷一次：用户点进来通常就是想看"现在通不通"，不该等 15s 心跳。
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cast.dispose();
    _acc.dispose();
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    await PeerHubRuntime.refresh();
    if (!mounted) return;
    setState(() {
      _reg = PeerHubRuntime.registry;
      _busy = false;
    });
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  // ── 接入端网 ──
  Future<void> _join() async {
    if (!PeerHubClient.configured) {
      _toast('先在「设置 → 后端地址」填上后端地址');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('接入端网'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('用账号口令登录后即可与其他端互通；也可以用已配对的后端密钥直接接入。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          TextField(controller: _acc, decoration: const InputDecoration(labelText: '账号', hintText: 'admin', isDense: true)),
          TextField(controller: _pwd, obscureText: true, decoration: const InputDecoration(labelText: '口令', isDense: true)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(
              onPressed: () {
                _acc.text = '';
                _pwd.text = '';
                Navigator.pop(c, true);
              },
              child: const Text('用后端密钥')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('登录并接入')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await PeerHubClient.join(
      kind: PeerHubClient.kindFront,
      name: '我的手机',
      account: _acc.text.trim(),
      password: _pwd.text,
    );
    _pwd.text = '';
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] == true) {
      _toast('已接入 · 当前 ${r['online'] ?? 0} 个端在线');
      await _refresh();
    } else {
      _toast('接入失败：${r['error'] ?? '未知原因'}');
    }
  }

  Future<void> _leave() async {
    setState(() => _busy = true);
    await PeerHubClient.clearIdentity();
    PeerHubRuntime.registry = PeerRegistry.empty;
    if (!mounted) return;
    setState(() {
      _reg = PeerRegistry.empty;
      _busy = false;
    });
    _toast('已断开（本地密钥副本保留，其他端仍持有同一份）');
  }

  // ── 跨端调用 ──
  Future<void> _invoke(PeerInfo p) async {
    final toolC = TextEditingController(text: p.tools.isNotEmpty ? p.tools.first : '');
    final argsC = TextEditingController(text: '{}');
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('调用 ${p.name.isEmpty ? p.iid : p.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (p.tools.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                children: p.tools
                    .take(8)
                    .map((t) => ActionChip(
                          label: Text(t, style: const TextStyle(fontSize: 11)),
                          onPressed: () => toolC.text = t,
                        ))
                    .toList(),
              ),
            ),
          TextField(controller: toolC, decoration: const InputDecoration(labelText: '工具名', isDense: true)),
          TextField(controller: argsC, decoration: const InputDecoration(labelText: '参数 JSON', isDense: true), maxLines: 3),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('调用')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    Map<String, dynamic> args;
    try {
      final j = jsonDecode(argsC.text.trim().isEmpty ? '{}' : argsC.text.trim());
      args = j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
    } catch (_) {
      _toast('参数不是合法 JSON');
      return;
    }
    final cap = toolC.text.trim();
    if (cap.isEmpty) {
      _toast('工具名不能为空');
      return;
    }
    setState(() => _busy = true);
    final r = await PeerHubClient.invoke(cap, tool: cap, args: args, preferIid: p.iid, registry: _reg);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      _toast('失败：${r.error}');
      return;
    }
    final body = r.result is String ? r.result as String : const JsonEncoder.withIndent('  ').convert(r.result);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(r.via == PeerVia.hub ? '结果（经后端转发）' : '结果（直连）'),
        content: SingleChildScrollView(
          child: SelectableText(
            body.length > 4000 ? '${body.substring(0, 4000)}\n…(已截断)' : body,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭'))],
      ),
    );
  }

  // ── 密钥同步 ──
  Future<void> _syncSecrets() async {
    setState(() => _busy = true);
    final rep = await PeerHubClient.syncSecrets();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastReport = rep.total == 0
          ? '本地与云端都没有密钥'
          : '拉取 ${rep.pull.length} · 推送 ${rep.push.length} · 冲突 ${rep.conflict.length} · 一致 ${rep.same.length}'
              '${rep.conflict.isEmpty ? "" : "\n冲突键（未自动覆盖，请手工处理）：${rep.conflict.join("、")}"}';
    });
    _toast(rep.conflict.isEmpty ? '密钥已统一到所有端' : '有 ${rep.conflict.length} 条冲突待处理');
  }

  Future<void> _addSecret() async {
    final nC = TextEditingController();
    final vC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新增/覆盖密钥'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nC, decoration: const InputDecoration(labelText: '键名', hintText: 'openai.key', isDense: true)),
          TextField(controller: vC, decoration: const InputDecoration(labelText: '值', isDense: true)),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('键名会自动归一：OpenAI_Key / openai-key 都写成 openai.key',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存并同步')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final n = nC.text.trim();
    final v = vC.text;
    nC.dispose();
    vC.dispose();
    if (n.isEmpty) {
      _toast('键名不能为空');
      return;
    }
    await PeerHubClient.putSecret(n, v);
    if (!mounted) return;
    await _syncSecrets();
  }

  Future<void> _showSecrets() async {
    final m = await PeerHubClient.localSecrets();
    if (!mounted) return;
    final keys = m.keys.toList()..sort();
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('本端密钥（${keys.length} 条）'),
        content: SizedBox(
          width: double.maxFinite,
          child: keys.isEmpty
              ? const Text('暂无。在任意一端保存密钥后，点「同步密钥」即可统一过来。')
              : ListView(
                  shrinkWrap: true,
                  children: keys
                      .map((k) {
                        final e = m[k];
                        final v = e is Map ? (e['value'] ?? '').toString() : e.toString();
                        final rev = e is Map ? (e['rev'] ?? 0).toString() : '0';
                        return ListTile(
                          dense: true,
                          title: Text(k, style: const TextStyle(fontSize: 13)),
                          subtitle: Text('${SecretMerge.mask(k, v)}  ·  rev $rev',
                              style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: '删除',
                            onPressed: () async {
                              await PeerHubClient.delSecret(k);
                              if (c.mounted) Navigator.pop(c);
                              await _showSecrets();
                            },
                          ),
                        );
                      })
                      .toList(),
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭'))],
      ),
    );
  }

  // ── 消息（一方输入，其他方都能用）──
  Future<void> _send() async {
    final t = _cast.text.trim();
    if (t.isEmpty) return;
    if (PeerHubClient.myToken.isEmpty) {
      _toast('先接入端网才能发消息');
      return;
    }
    final ok = await PeerHubClient.relay({'text': t}, topic: 'input');
    if (!mounted) return;
    if (ok) {
      _cast.clear();
      _toast('已广播给所有端');
    } else {
      _toast('发送失败（后端不在线）');
    }
  }

  Future<void> _pull() async {
    if (PeerHubClient.myToken.isEmpty) {
      _toast('先接入端网');
      return;
    }
    setState(() => _busy = true);
    final got = await PeerHubClient.inbox();
    if (!mounted) return;
    setState(() {
      _busy = false;
      final merged = PeerInbox.dedupe([..._inbox, ...got]);
      _inbox
        ..clear()
        ..addAll(merged.length > 100 ? merged.sublist(merged.length - 100) : merged);
    });
    _toast(got.isEmpty ? '没有新消息' : '收到 ${got.length} 条');
  }

  // ── 诊断 ──
  Future<void> _runDiag() async {
    setState(() => _busy = true);
    final s = await PeerHubClient.diagnose();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _diag = s;
    });
  }

  @override
  Widget build(BuildContext c) {
    final on = _reg.online;
    // ★ 三类必须分开显示：处理动作完全不同。
    //   在线   → 能直接派活
    //   待登录 → 局域网里已经看到它了，去插件侧填账号口令即可接入
    //   离线   → 什么都不用做，等它回来
    final pend = _reg.pendingLogins;
    final pendIds = pend.map((e) => e.iid).toSet();
    final off = _reg.offline.where((p) => !pendIds.contains(p.iid)).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('端网与插件'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: '刷新', onPressed: _busy ? null : _refresh),
          IconButton(icon: const Icon(Icons.monitor_heart_outlined), tooltip: '诊断', onPressed: _busy ? null : _runDiag),
        ],
      ),
      body: ListView(children: [
        // ① 现在通不通
        _statusCard(),
        // ② 有谁在
        _sectionTitle('端列表',
            '在线 ${on.length} · 待登录 ${pend.length} · 离线 ${off.length} · 中枢 ${_reg.hasHub ? "已连接" : "未连接"}'),
        if (on.isEmpty && pend.isEmpty && off.isEmpty)
          _hint('还没有任何端。'
              '① 在后端机器上跑一次后端（它自己是中枢）；'
              '② 装一个插件并让它登录账号接入；'
              '③ 手机上点上面的「接入端网」。'),
        ...on.map((p) => _peerTile(p, true)),
        if (pend.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('待登录（局域网里已经发现，还没接入）',
                style: TextStyle(fontSize: 12, color: Colors.orange)),
          ),
          ...pend.map((p) => _peerTile(p, false)),
        ],
        if (off.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('离线（曾登记过）', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          ...off.map((p) => _peerTile(p, false)),
        ],
        // ③ 跨端消息
        _sectionTitle('端间消息', '一方输入，其他端都能拉到（topic=input）'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _cast,
                decoration: const InputDecoration(hintText: '要广播给其他端的内容', isDense: true),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _busy ? null : _send, child: const Text('广播')),
            const SizedBox(width: 4),
            OutlinedButton(onPressed: _busy ? null : _pull, child: const Text('收取')),
          ]),
        ),
        if (_inbox.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _inbox.reversed
                  .take(10)
                  .map((m) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Icon(Icons.chat_bubble_outline, size: 14),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('${m.fromName.isEmpty ? m.from : m.fromName}（${m.topic}）：${m.text().isEmpty ? "(无正文)" : m.text()}',
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ]),
                      ))
                  .toList(),
            ),
          ),
        // ④ 密钥统一
        _sectionTitle('密钥统一', '任一端写入 → 其他所有端拉到同一份'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _syncSecrets,
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('同步密钥'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _showSecrets,
              icon: const Icon(Icons.key_outlined, size: 16),
              label: const Text('查看本端'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _addSecret,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增'),
            ),
          ]),
        ),
        if (_lastReport.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(_lastReport, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        if (_diag.isNotEmpty) ...[
          _sectionTitle('诊断', '把这段直接贴给需要排查的人'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(_diag, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ),
          ),
        ],
        const SizedBox(height: 28),
      ]),
    );
  }

  // ── 组件 ──
  Widget _statusCard() {
    final tok = PeerHubClient.myToken;
    final hubOn = _reg.hasHub;
    final color = hubOn ? Colors.blue : (tok.isNotEmpty ? Colors.orange : Colors.grey);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(hubOn ? Icons.hub : Icons.link_off, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(PeerHubRuntime.status.isEmpty ? '未连接' : PeerHubRuntime.status,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
            ),
            if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text(
            '本端 ${tok.isEmpty ? "未接入（仅本机能力）" : "已接入 · ${PeerHubClient.myIid.isEmpty ? "?" : PeerHubClient.myIid}"}'
            '${PeerHubClient.configured ? "" : " · 未配置后端地址"}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          if (PeerHubRuntime.lastError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(PeerHubRuntime.lastError, style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
            ),
          const SizedBox(height: 10),
          Row(children: [
            if (tok.isEmpty)
              FilledButton.icon(onPressed: _busy ? null : _join, icon: const Icon(Icons.login, size: 16), label: const Text('接入端网'))
            else
              OutlinedButton.icon(onPressed: _busy ? null : _leave, icon: const Icon(Icons.logout, size: 16), label: const Text('断开')),
            const SizedBox(width: 8),
            TextButton(onPressed: _busy ? null : _runDiag, child: const Text('为什么连不上？')),
          ]),
        ]),
      ),
    );
  }

  Widget _sectionTitle(String t, String sub) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          Text(sub, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      );

  Widget _hint(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Text(s, style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.6)),
      );

  Widget _peerTile(PeerInfo p, bool online) {
    final isHub = p.kind == PeerKind.back;
    final pending = p.pendingLogin;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(
          isHub
              ? Icons.dns
              : (p.kind == PeerKind.plug
                  ? Icons.extension
                  : (p.kind == PeerKind.dsa ? Icons.smart_toy_outlined : Icons.phone_android)),
          color: online ? Colors.blue : (pending ? Colors.orange : Colors.grey),
          size: 20,
        ),
        title: Row(children: [
          Flexible(child: Text(p.name.isEmpty ? p.iid : p.name, style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: (pending ? Colors.orange : Colors.grey).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(pending ? '待登录' : peerKindName(p.kind), style: const TextStyle(fontSize: 10)),
          ),
          if (p.vip)
            const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star, size: 12, color: Colors.amber)),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (p.caps.isNotEmpty || p.tools.isNotEmpty)
            Text(
              '${p.caps.isEmpty ? "" : "能力 ${p.caps.join("/")}"}'
              '${p.tools.isEmpty ? "" : "${p.caps.isEmpty ? "" : " · "}工具 ${p.tools.length} 个"}',
              style: const TextStyle(fontSize: 11),
            ),
          // 直连地址是"没有后端也能用"的关键信息，必须露出来 —— 一条都没有时
          // 要显式提示用户去插件侧补，否则他只会看到"连不上"。
          Text(
            p.routes.isEmpty
                ? (online ? '无直连地址（没有后端时连不上它）' : '（无地址）')
                : '直连：${p.routes.map(PeerUrl.hostOf).join(" / ")}',
            style: TextStyle(fontSize: 11, color: p.routes.isEmpty && online ? Colors.orange : Colors.grey),
          ),
          if (pending)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('在插件侧填入账号口令即可接入（UDP 只负责让它被看见，不负责授权）',
                  style: TextStyle(fontSize: 11, color: Colors.orange)),
            ),
        ]),
        trailing: online && !isHub
            ? IconButton(
                icon: const Icon(Icons.play_arrow, size: 20),
                tooltip: '调用它的工具',
                onPressed: _busy ? null : () => _invoke(p),
              )
            : null,
      ),
    );
  }
}
