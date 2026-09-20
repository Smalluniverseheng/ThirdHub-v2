// 后端管理面板(App 内): 前端直接管理已连接后端的各种功能
// 数据全部走 /v1/*(X-TH-Token 鉴权), 未连接后端时给连接指引。
// 覆盖: 运行状态 · 引擎总览 · 下载任务(aria2 磁力/直链 增/停/删) · 存储位置 · TTS 能力 · 反馈
import 'dart:convert';
import 'package:flutter/material.dart';
import '../main.dart' show Api;

class BackendAdminPage extends StatefulWidget { const BackendAdminPage({super.key}); @override State<BackendAdminPage> createState() => _Ba(); }

class _Ba extends State<BackendAdminPage> {
  bool loading = true; String err = '';
  Map<String, dynamic> meta = {};
  Map<String, dynamic> storage = {};
  Map<String, dynamic> engines = {};
  Map<String, dynamic> dl = {};
  Map<String, dynamic> ttsCap = {};
  List<dynamic> feedback = [];

  @override void initState() { super.initState(); _load(); }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await Api.client().post(Uri.parse('${Api.base}$path'),
      headers: {'X-TH-Token': Api.token, 'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(body));
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> _load() async {
    if (Api.base.isEmpty) { setState(() { loading = false; err = '未连接后端'; }); return; }
    setState(() { loading = true; err = ''; });
    try {
      // 逐个拿, 单点失败不拖垮整页
      try { meta = (await Api.get('/v1/meta'))['data'] as Map<String, dynamic>? ?? {}; } catch (_) {}
      try { storage = (await Api.get('/v1/storage/status'))['data'] as Map<String, dynamic>? ?? {}; } catch (_) {}
      try { engines = (await Api.get('/v1/engines'))['data'] as Map<String, dynamic>? ?? {}; } catch (_) {}
      try { dl = (await Api.get('/v1/dl/list'))['data'] as Map<String, dynamic>? ?? {}; } catch (_) {}
      try { ttsCap = (await Api.get('/v1/tts/cap'))['data'] as Map<String, dynamic>? ?? {}; } catch (_) {}
      try {
        final fb = await Api.get('/v1/feedback');
        final d = fb['data'];
        feedback = d is List ? d : (d is Map ? (d['items'] as List? ?? []) : []);
      } catch (_) {}
    } catch (e) { err = '$e'; }
    if (mounted) setState(() => loading = false);
  }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('后端管理'), actions: [
      IconButton(icon: const Icon(Icons.refresh), tooltip: '刷新', onPressed: _load)]),
    body: Api.base.isEmpty
      ? Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.dns_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('还没有连接后端', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          const Text('登录账号后自动发现并连接你的后端设备;\n也可在「设备互联」里手动配对。',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.6)),
        ])))
      : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(12), children: [
        _statusCard(),
        _enginesCard(),
        _dlCard(),
        _storageCard(),
        _miscCard(),
        const SizedBox(height: 12),
      ])));

  Widget _card(String title, IconData icon, List<Widget> kids) => Card(margin: const EdgeInsets.only(bottom: 10),
    child: Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(icon, size: 16, color: Colors.grey), const SizedBox(width: 6),
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))]),
      const Divider(height: 14),
      ...kids,
    ])));

  Widget _kv(String k, String v) => Padding(padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [Text(k, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      const Spacer(), Flexible(child: Text(v, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))]));

  Widget _statusCard() {
    final name = '${meta['name'] ?? meta['version'] ?? '后端'}';
    return _card('运行状态', Icons.monitor_heart_outlined, [
      _kv('地址', Api.base),
      _kv('实例', name),
      _kv('aria2 下载', '${storage['aria2'] ?? '未知'}'),
      _kv('网盘(Cloudreve)', '${storage['cloudreve'] ?? '未知'}'),
      if ('${storage['hint'] ?? ''}'.isNotEmpty && storage['cloudreve'] != 'running')
        Padding(padding: const EdgeInsets.only(top: 4),
          child: Text('${storage['hint']}', style: const TextStyle(fontSize: 10, color: Colors.grey))),
    ]);
  }

  Widget _enginesCard() {
    final builtin = (engines['builtin'] as List?) ?? [];
    final network = (engines['network'] as List?) ?? [];
    return _card('引擎总览', Icons.memory, [
      for (final e in builtin)
        Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
          Icon(e['status'] == 'online' ? Icons.check_circle : e['status'] == 'standby' ? Icons.pause_circle_outline : Icons.error_outline,
            size: 14, color: e['status'] == 'online' ? Colors.green : e['status'] == 'standby' ? Colors.orange : Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(child: Text('${e['name']}', style: const TextStyle(fontSize: 12))),
          Text('${e['sources'] ?? '-'} 源', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ])),
      if (network.isNotEmpty) const Divider(height: 12),
      for (final e in network)
        Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
          Icon(Icons.link, size: 14, color: e['status'] == 'online' ? Colors.green : Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Text('${e['name']}', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
          Text(e['status'] == 'online' ? '在线' : '离线', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ])),
      if (builtin.isEmpty && network.isEmpty)
        const Text('暂无引擎数据', style: TextStyle(fontSize: 12, color: Colors.grey)),
    ]);
  }

  Widget _dlCard() {
    final active = (dl['active'] as List?) ?? [];
    final waiting = (dl['waiting'] as List?) ?? [];
    final stopped = (dl['stopped'] as List?) ?? [];
    String fmtSpd(int b) => b > 1048576 ? '${(b / 1048576).toStringAsFixed(1)} MB/s' : '${(b / 1024).toStringAsFixed(0)} KB/s';
    String fmtSize(int b) => b > 1073741824 ? '${(b / 1073741824).toStringAsFixed(1)} GB' : '${(b / 1048576).toStringAsFixed(0)} MB';
    Widget taskTile(Map t) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('${t['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
        Text('${t['status']}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ]),
      const SizedBox(height: 3),
      LinearProgressIndicator(value: (t['progress'] as num) / 100, minHeight: 3),
      const SizedBox(height: 3),
      Row(children: [
        Text('${t['progress']}% · ${fmtSize((t['size'] as num).toInt())} · ${fmtSpd((t['speed'] as num).toInt())}${(t['seeders'] as num) > 0 || (t['peers'] as num) > 0 ? ' · ${t['seeders']}种/${t['peers']}点' : ''}',
          style: const TextStyle(fontSize: 10, color: Colors.grey)),
        const Spacer(),
        if (t['status'] == 'active')
          _actBtn('暂停', () => _dlAction('pause', '${t['gid']}'))
        else if (t['status'] == 'paused' || t['status'] == 'waiting')
          _actBtn('继续', () => _dlAction('unpause', '${t['gid']}')),
        _actBtn('删除', () => _dlAction('remove', '${t['gid']}'), red: true),
      ]),
    ]));
    return _card('下载任务 (aria2)', Icons.download_outlined, [
      Row(children: [
        Text('进行中 ${active.length} · 排队 ${waiting.length} · 已结束 ${stopped.length}',
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const Spacer(),
        TextButton.icon(onPressed: _addTask, icon: const Icon(Icons.add_link, size: 15),
          label: const Text('添加', style: TextStyle(fontSize: 12))),
      ]),
      for (final t in [...active, ...waiting, ...stopped.take(5)]) taskTile(Map<String, dynamic>.from(t as Map)),
      if (active.isEmpty && waiting.isEmpty && stopped.isEmpty)
        const Text('暂无任务', style: TextStyle(fontSize: 12, color: Colors.grey)),
    ]);
  }

  Widget _actBtn(String label, VoidCallback onTap, {bool red = false}) => Padding(padding: const EdgeInsets.only(left: 4),
    child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(label, style: TextStyle(fontSize: 11, color: red ? Colors.redAccent : Colors.blueAccent)))));

  Future<void> _dlAction(String act, String gid) async {
    try {
      await _post('/v1/dl/action?act=$act&gid=$gid', {});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已执行: $act')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败: $e')));
    }
    _load();
  }

  Future<void> _addTask() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: const Text('添加下载任务'),
      content: TextField(controller: ctrl, autofocus: true, maxLines: 3,
        decoration: const InputDecoration(hintText: '磁力链接 magnet: 或 直链 https://', isDense: true, border: OutlineInputBorder())),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('开始下载'))]));
    final u = ctrl.text.trim();
    if (ok != true || u.isEmpty) return;
    try {
      await _post('/v1/dl/task', {'url': u});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('任务已发布')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发布失败: $e')));
    }
    _load();
  }

  Widget _storageCard() {
    final dirs = storage['dirs'];
    return _card('存储位置', Icons.folder_outlined, [
      _kv('当前下载根', '${storage['downloadsDir'] ?? storage['dir'] ?? '默认'}'),
      if (dirs is List && dirs.isNotEmpty)
        for (final d in dirs.take(4))
          _kv('目录', '$d'),
      const Padding(padding: EdgeInsets.only(top: 4),
        child: Text('改下载目录在「资源库 → 设置」里操作(按内容类型分目录)', style: TextStyle(fontSize: 10, color: Colors.grey))),
    ]);
  }

  Widget _miscCard() {
    final voices = (ttsCap['voices'] as List?)?.length ?? 0;
    return _card('能力 & 反馈', Icons.miscellaneous_services_outlined, [
      _kv('TTS 离线引擎(piper)', ttsCap['piper'] == true ? '已装' : '未装'),
      _kv('TTS 在线(edge-tts)', ttsCap['edge'] == true ? '已装($voices 声音)' : '未装'),
      _kv('Python 执行', '可用(/v1/py, 供 AI 工具 run_python 调用)'),
      _kv('用户反馈', '${feedback.length} 条'),
      if (feedback.isNotEmpty)
        for (final f in feedback.take(3))
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('· ${f['text'] ?? ''}',
            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey))),
    ]);
  }
}
