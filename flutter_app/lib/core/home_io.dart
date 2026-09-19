// ═══════════════════════════════════════════════════════════════════════════
// 智能家居 + 远程打印 —— 此前都是"框架已就位"的骨架页, 这里做成真能用的
//
// · 智能家居: 直连 Home Assistant 的 REST API。填 base + 长期访问令牌即可读出
//   全部实体、开关灯/插座、触发情景与脚本。米家/涂鸦等设备先接进 HA 再统一从这里控。
//   (这就是规划里写的"米家/HA 控制走引擎模式"的落地形态: 官方零内置, 能力全来自你自己那套 HA。)
// · 远程打印: 把文本/文件提交到你自己配置的打印服务(CUPS/自建 HTTP 打印服务),
//   带本地队列与提交记录。没有打印服务时队列仍然可用(会明确告诉你卡在哪)。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'lab_logic.dart';

// ═══════════════════════════════════════════════════════════════════════════
// A. 智能家居 (Home Assistant)
//
// 域映射(haDomain / haToggleable / haTriggerable / haTurnOnService /
// haTurnOffService / haIsOn / haDomainLabel)与 HaEntity 都在 lab_logic.dart 里,
// 这里是唯一实现, UI 只管取数展示 —— 这样纯 Dart 自检才能覆盖它们。
// ═══════════════════════════════════════════════════════════════════════════

class HaClient {
  static const String _kBase = 'ha_base';
  static const String _kToken = 'ha_token';
  static String base = '';
  static String token = '';
  static final List<HaEntity> entities = [];
  static String lastError = '';
  static bool loaded = false;

  static Future<void> load() async {
    if (loaded) return;
    loaded = true;
    final p = await SharedPreferences.getInstance();
    base = p.getString(_kBase) ?? '';
    token = p.getString(_kToken) ?? '';
  }

  static bool get configured => base.isNotEmpty && token.isNotEmpty;

  static Future<void> save(String b, String t) async {
    base = b.trim().replaceAll(RegExp(r'/+$'), '');
    token = t.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBase, base);
    await p.setString(_kToken, token);
  }

  static Map<String, String> get _h => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  /// 拉全部实体状态
  static Future<bool> refresh() async {
    if (!configured) { lastError = '还没配置 Home Assistant 地址与令牌'; return false; }
    try {
      final r = await http.get(Uri.parse('$base/api/states'), headers: _h)
        .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) { lastError = 'HTTP ${r.statusCode}: ${_brief(r.body)}'; return false; }
      final list = jsonDecode(r.body);
      entities
        ..clear()
        ..addAll([for (final e in (list as List)) HaEntity.from(Map<String, dynamic>.from(e as Map))]);
      lastError = '';
      return true;
    } catch (e) { lastError = _brief('$e'); return false; }
  }

  /// 调服务(开关灯/触发情景都走这里)
  static Future<bool> callService(String domain, String service, {String? entityId}) async {
    if (!configured) { lastError = '还没配置 Home Assistant'; return false; }
    try {
      final body = entityId == null ? '{}' : jsonEncode({'entity_id': entityId});
      final r = await http.post(Uri.parse('$base/api/services/$domain/$service'),
        headers: _h, body: body).timeout(const Duration(seconds: 10));
      if (r.statusCode >= 400) { lastError = 'HTTP ${r.statusCode}: ${_brief(r.body)}'; return false; }
      lastError = '';
      return true;
    } catch (e) { lastError = _brief('$e'); return false; }
  }

  /// 便捷切换: 按当前状态决定 turn_on / turn_off
  static Future<bool> toggle(HaEntity e) async {
    final d = haDomain(e.entityId);
    if (d == 'scene') return callService('scene', 'turn_on', entityId: e.entityId);
    if (haIsOn(e.state)) return callService(d, haTurnOffService(d), entityId: e.entityId);
    return callService(d, haTurnOnService(d), entityId: e.entityId);
  }

  static String _brief(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;
}

class SmartHomePage extends StatefulWidget {
  const SmartHomePage({super.key});
  @override State<SmartHomePage> createState() => _SmartHomeState();
}

class _SmartHomeState extends State<SmartHomePage> {
  bool _ready = false, _busy = false;
  String _filter = '';

  @override void initState() {
    super.initState();
    HaClient.load().then((_) async {
      if (HaClient.configured) { await HaClient.refresh(); }
      if (mounted) setState(() => _ready = true);
    });
  }

  @override Widget build(BuildContext c) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    if (!HaClient.configured) return _setup(c);

    final ctrl = <HaEntity>[];
    final sens = <HaEntity>[];
    for (final e in HaClient.entities) {
      if (haToggleable(e.entityId) || haTriggerable(e.entityId)) { ctrl.add(e); } else { sens.add(e); }
    }
    List<HaEntity> f(List<HaEntity> l) => _filter.isEmpty ? l
      : [for (final e in l) if (e.name.contains(_filter) || e.entityId.contains(_filter)) e];

    return RefreshIndicator(onRefresh: () async { await HaClient.refresh(); setState(() {}); },
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.home_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(HaClient.base, style: const TextStyle(fontSize: 12))),
            IconButton(onPressed: _busy ? null : () async {
              setState(() => _busy = true);
              await HaClient.refresh();
              if (mounted) setState(() => _busy = false);
            }, icon: const Icon(Icons.refresh, size: 18)),
            IconButton(onPressed: () => setState(() => _configure(c)), icon: const Icon(Icons.settings_outlined, size: 18)),
          ]),
          Text('共 ${HaClient.entities.length} 个实体 · 可控 ${ctrl.length} 个', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          if (HaClient.lastError.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6),
            child: Text(HaClient.lastError, style: const TextStyle(fontSize: 11, color: Colors.red))),
          const SizedBox(height: 8),
          TextField(onChanged: (v) => setState(() => _filter = v.trim()), style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '按名称筛选', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder())),
        ]))),
        if (ctrl.isEmpty && sens.isEmpty) Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 30),
          child: Center(child: Text(_busy ? '正在读取…' : '没有读到实体。点右上角刷新, 或检查地址与令牌。',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600))))),
        if (f(ctrl).isNotEmpty) ...[
          const Padding(padding: EdgeInsets.fromLTRB(4, 10, 4, 4), child: Text('可控设备', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          for (final e in f(ctrl)) _entityCard(c, e),
        ],
        if (f(sens).isNotEmpty) ...[
          const Padding(padding: EdgeInsets.fromLTRB(4, 10, 4, 4), child: Text('传感器', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          for (final e in f(sens).take(60)) Card(margin: const EdgeInsets.only(bottom: 6), child: ListTile(
            dense: true,
            leading: const Icon(Icons.sensors, size: 18),
            title: Text(e.name, style: const TextStyle(fontSize: 13)),
            subtitle: Text(haDomainLabel(haDomain(e.entityId)), style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            trailing: Text('${e.state}${e.unit}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          )),
          if (f(sens).length > 60) Padding(padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text('仅显示前 60 个传感器, 用上方筛选缩小范围', style: TextStyle(fontSize: 11, color: Colors.grey.shade600))),
        ],
      ]));
  }

  Widget _entityCard(BuildContext c, HaEntity e) {
    final on = haIsOn(e.state);
    final trigger = haDomain(e.entityId) == 'scene';
    return Card(margin: const EdgeInsets.only(bottom: 6), child: ListTile(
      leading: Icon(
        haDomain(e.entityId) == 'light' ? Icons.lightbulb_outline
          : haDomain(e.entityId) == 'switch' ? Icons.toggle_on_outlined
          : haDomain(e.entityId) == 'cover' ? Icons.window_outlined
          : haDomain(e.entityId) == 'lock' ? Icons.lock_outline
          : haDomain(e.entityId) == 'climate' ? Icons.thermostat
          : haDomain(e.entityId) == 'media_player' ? Icons.speaker_outlined
          : trigger ? Icons.movie_filter_outlined : Icons.devices_other,
        color: on ? Colors.amber.shade700 : Colors.grey, size: 22),
      title: Text(e.name, style: const TextStyle(fontSize: 13)),
      subtitle: Text('${haDomainLabel(haDomain(e.entityId))} · ${e.state}', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      trailing: trigger
        ? TextButton(onPressed: () => _act(() => HaClient.toggle(e), '已触发 ${e.name}'), child: const Text('触发'))
        : Switch(value: on, onChanged: (_) => _act(() => HaClient.toggle(e), '${e.name} → ${on ? '关' : '开'}')),
    ));
  }

  Future<void> _act(Future<bool> Function() f, String okMsg) async {
    setState(() => _busy = true);
    final ok = await f();
    if (ok) { await HaClient.refresh(); }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? okMsg : (HaClient.lastError.isEmpty ? '失败' : HaClient.lastError))));
  }

  Future<void> _configure(BuildContext c) async {
    final b = TextEditingController(text: HaClient.base);
    final t = TextEditingController(text: HaClient.token);
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(
      title: const Text('连接 Home Assistant'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: b, decoration: const InputDecoration(
          labelText: 'HA 地址', hintText: 'http://192.168.1.10:8123', isDense: true)),
        const SizedBox(height: 10),
        TextField(controller: t, decoration: const InputDecoration(
          labelText: '长期访问令牌', hintText: '在 HA 个人资料页生成', isDense: true)),
        const SizedBox(height: 8),
        const Align(alignment: Alignment.centerLeft, child: Text(
          '令牌只存在本机, 不上传任何服务器。米家/涂鸦等设备先在 HA 里接好, 这里就能看到。',
          style: TextStyle(fontSize: 11, color: Colors.grey))),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('保存并连接')),
      ]));
    final bb = b.text, tt = t.text;
    b.dispose(); t.dispose();
    if (ok != true) return;
    await HaClient.save(bb, tt);
    setState(() => _busy = true);
    await HaClient.refresh();
    if (mounted) setState(() => _busy = false);
  }

  Widget _setup(BuildContext c) {
    final accent = Theme.of(c).colorScheme.primary;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
        Container(width: 56, height: 56, decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
          child: Icon(Icons.home_outlined, color: accent, size: 28)),
        const SizedBox(height: 12),
        const Text('智能家居 · 接你的 Home Assistant', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('这个模块不自带任何设备协议, 而是直连你自己那套 Home Assistant:\n'
          '① 在 HA 里把米家/涂鸦/ESP 设备接好\n'
          '② 在 HA「个人资料 → 长期访问令牌」生成一个令牌\n'
          '③ 把地址和令牌填进来\n\n'
          '之后就能在这里看全部实体、开关灯与插座、触发情景。所有控制都走你家里的 HA, 不经过第三方。',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.7)),
        const SizedBox(height: 14),
        FilledButton.icon(onPressed: () => _configure(c), icon: const Icon(Icons.link), label: const Text('填写地址与令牌')),
      ]))),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// B. 远程打印
//
// PrintState / PrintJob / recoverPrintJobs 都在 lab_logic.dart(唯一实现)。
// 这里只补一个 UIKit 才需要的东西: 状态对应的颜色(用到 Colors, 进不了纯逻辑层)。
// ═══════════════════════════════════════════════════════════════════════════
extension PrintStateColorX on PrintState {
  Color get color => switch (this) {
    PrintState.waiting => Colors.blueGrey, PrintState.sending => Colors.blue,
    PrintState.sent => Colors.green, PrintState.failed => Colors.red,
  };
}

class PrintStore {
  static const String _kUrl = 'print_service_url';
  static const String _kJobs = 'print_jobs';
  static String serviceUrl = '';
  static final List<PrintJob> jobs = [];
  static bool loaded = false;
  static String lastError = '';

  static Future<void> load() async {
    if (loaded) return;
    loaded = true;
    final p = await SharedPreferences.getInstance();
    serviceUrl = p.getString(_kUrl) ?? '';
    try {
      jobs.addAll([for (final e in (jsonDecode(p.getString(_kJobs) ?? '[]') as List))
        PrintJob.from(Map<String, dynamic>.from(e))]);
    } catch (_) { jobs.clear(); }
    // 上次进程被杀时卡在"提交中"的, 退回待提交(避免显示成永远在发)
    recoverPrintJobs(jobs);
  }

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUrl, serviceUrl);
    await p.setString(_kJobs, jsonEncode([for (final j in jobs) j.toJson()]));
  }

  static Future<void> setUrl(String u) async { serviceUrl = u.trim(); await _save(); }

  static Future<PrintJob> enqueue({required String title, String content = '', String filePath = ''}) async {
    final j = PrintJob(id: 'pr-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      title: title, content: content, filePath: filePath, ts: DateTime.now().millisecondsSinceEpoch);
    jobs.insert(0, j);
    await _save();
    return j;
  }

  static Future<void> remove(String id) async { jobs.removeWhere((e) => e.id == id); await _save(); }
  static Future<void> retry(String id) async {
    for (final j in jobs) { if (j.id == id) { j.state = PrintState.waiting; j.message = ''; } }
    await _save();
  }

  /// 真提交: 有文件走 multipart 上传, 纯文本走 JSON
  static Future<bool> submit(PrintJob j) async {
    if (serviceUrl.isEmpty) { j.state = PrintState.failed; j.message = '还没配置打印服务地址'; await _save(); return false; }
    j.state = PrintState.sending; j.message = ''; await _save();
    try {
      final uri = Uri.parse(serviceUrl);
      http.Response r;
      if (j.filePath.isNotEmpty) {
        final f = File(j.filePath);
        if (!await f.exists()) { j.state = PrintState.failed; j.message = '文件不存在: ${j.filePath}'; await _save(); return false; }
        final req = http.MultipartRequest('POST', uri)
          ..fields['title'] = j.title
          ..files.add(await http.MultipartFile.fromPath('file', j.filePath));
        r = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 60)));
      } else {
        r = await http.post(uri, headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'title': j.title, 'content': j.content}))
          .timeout(const Duration(seconds: 30));
      }
      if (r.statusCode >= 400) {
        j.state = PrintState.failed; j.message = 'HTTP ${r.statusCode}: ${_brief(r.body)}';
      } else {
        j.state = PrintState.sent; j.message = 'HTTP ${r.statusCode}';
      }
    } catch (e) { j.state = PrintState.failed; j.message = _brief('$e'); }
    lastError = j.state == PrintState.failed ? j.message : '';
    await _save();
    return j.state == PrintState.sent;
  }

  /// 提交队列里所有"待提交"的
  static Future<int> submitAll() async {
    var n = 0;
    for (final j in jobs) {
      if (j.state == PrintState.waiting) { if (await submit(j)) n++; }
    }
    return n;
  }

  static String _brief(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;
}

class RemotePrintPage extends StatefulWidget {
  const RemotePrintPage({super.key});
  @override State<RemotePrintPage> createState() => _RemotePrintState();
}

class _RemotePrintState extends State<RemotePrintPage> {
  bool _ready = false, _busy = false;

  @override void initState() {
    super.initState();
    PrintStore.load().then((_) { if (mounted) setState(() => _ready = true); });
  }

  @override Widget build(BuildContext c) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final waiting = PrintStore.jobs.where((j) => j.state == PrintState.waiting).length;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.print_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(PrintStore.serviceUrl.isEmpty ? '未配置打印服务' : PrintStore.serviceUrl,
            style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
          IconButton(onPressed: () => _setup(c), icon: const Icon(Icons.settings_outlined, size: 18)),
        ]),
        Text('队列 $waiting 项待提交 · 记录 ${PrintStore.jobs.length} 条',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          ActionChip(avatar: const Icon(Icons.text_fields, size: 16), label: const Text('打印文本', style: TextStyle(fontSize: 12)),
            onPressed: () => _addText(c)),
          ActionChip(avatar: const Icon(Icons.insert_drive_file_outlined, size: 16), label: const Text('打印文件', style: TextStyle(fontSize: 12)),
            onPressed: () => _addFile(c)),
          ActionChip(avatar: const Icon(Icons.send, size: 16), label: const Text('提交队列', style: TextStyle(fontSize: 12)),
            onPressed: _busy ? null : () async {
              setState(() => _busy = true);
              final n = await PrintStore.submitAll();
              if (!mounted) return;
              setState(() => _busy = false);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n > 0 ? '已提交 $n 项' : '没有可提交的项, 或全部失败')));
            }),
          ActionChip(avatar: const Icon(Icons.cleaning_services_outlined, size: 16), label: const Text('清掉已提交', style: TextStyle(fontSize: 12)),
            onPressed: () async {
              PrintStore.jobs.removeWhere((j) => j.state == PrintState.sent);
              await PrintStore._save();
              if (mounted) setState(() {});
            }),
        ]),
      ]))),
      const SizedBox(height: 8),
      if (PrintStore.jobs.isEmpty) Card(child: Padding(padding: const EdgeInsets.symmetric(vertical: 30),
        child: Center(child: Text('队列是空的', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)))))
      else for (final j in PrintStore.jobs) Card(margin: const EdgeInsets.only(bottom: 6), child: Padding(
        padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(j.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: j.state.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(j.state.zh, style: TextStyle(fontSize: 10, color: j.state.color))),
          ]),
          if (j.content.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(j.content, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))),
          if (j.filePath.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
            child: SelectableText(j.filePath, style: const TextStyle(fontSize: 11))),
          if (j.message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(j.message, style: TextStyle(fontSize: 11, color: j.state == PrintState.failed ? Colors.red : Colors.grey.shade600))),
          Row(children: [
            if (j.state == PrintState.waiting || j.state == PrintState.failed) TextButton(
              onPressed: _busy ? null : () async {
                setState(() => _busy = true);
                await PrintStore.submit(j);
                if (mounted) setState(() => _busy = false);
              }, child: const Text('提交', style: TextStyle(fontSize: 12))),
            if (j.state == PrintState.failed) TextButton(
              onPressed: () async { await PrintStore.retry(j.id); if (mounted) setState(() {}); },
              child: const Text('重置', style: TextStyle(fontSize: 12))),
            const Spacer(),
            TextButton(onPressed: () async { await PrintStore.remove(j.id); if (mounted) setState(() {}); },
              child: const Text('移除', style: TextStyle(fontSize: 12, color: Colors.grey))),
          ]),
        ]))),
    ]);
  }

  Future<void> _setup(BuildContext c) async {
    final ctl = TextEditingController(text: PrintStore.serviceUrl);
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(
      title: const Text('打印服务地址'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctl, decoration: const InputDecoration(
          labelText: 'HTTP 接口', hintText: 'http://192.168.1.10:631/print', isDense: true)),
        const SizedBox(height: 10),
        const Align(alignment: Alignment.centerLeft, child: Text(
          '这是一个收件的 HTTP 接口: 纯文本会以 JSON {title, content} 提交; 文件会以 multipart(file, title) 提交。\n'
          '可以是你在局域网里跑的打印代理, 也可以是 NAS/CUPS 前置的一小段脚本。地址留空即关闭提交。',
          style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.6))),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('保存')),
      ]));
    final v = ctl.text;
    ctl.dispose();
    if (ok != true) return;
    await PrintStore.setUrl(v);
    if (mounted) setState(() {});
  }

  Future<void> _addText(BuildContext c) async {
    final t = TextEditingController();
    final b = TextEditingController();
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(
      title: const Text('打印文本'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: t, decoration: const InputDecoration(labelText: '标题', isDense: true)),
        const SizedBox(height: 8),
        TextField(controller: b, minLines: 4, maxLines: 10,
          decoration: const InputDecoration(labelText: '内容', isDense: true, border: OutlineInputBorder())),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('加进队列')),
      ]));
    final title = t.text.trim(), body = b.text;
    t.dispose(); b.dispose();
    if (ok != true) return;
    await PrintStore.enqueue(title: title.isEmpty ? '未命名文本' : title, content: body);
    if (mounted) setState(() {});
  }

  Future<void> _addFile(BuildContext c) async {
    final f = TextEditingController();
    final t = TextEditingController();
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(
      title: const Text('打印本机文件'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: f, decoration: const InputDecoration(
          labelText: '文件绝对路径', hintText: '/storage/emulated/0/Download/a.pdf', isDense: true)),
        const SizedBox(height: 8),
        TextField(controller: t, decoration: const InputDecoration(labelText: '标题(可留空)', isDense: true)),
        const SizedBox(height: 8),
        const Align(alignment: Alignment.centerLeft, child: Text(
          '提交时会把该文件原样上传到打印服务, 不在本机做任何转换。',
          style: TextStyle(fontSize: 11, color: Colors.grey))),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('加进队列')),
      ]));
    final path = f.text.trim(), title = t.text.trim();
    f.dispose(); t.dispose();
    if (ok != true || path.isEmpty) return;
    await PrintStore.enqueue(title: title.isEmpty ? path.split(Platform.pathSeparator).last : title, filePath: path);
    if (mounted) setState(() {});
  }
}

/// 供模块页直接引用的组合入口(工具箱里可当作一个"家庭/打印"入口)
class HomeIoPage extends StatelessWidget {
  const HomeIoPage({super.key});
  @override Widget build(BuildContext c) => DefaultTabController(length: 2, child: Column(children: [
    const TabBar(tabs: [Tab(text: '智能家居'), Tab(text: '远程打印')]),
    const Expanded(child: TabBarView(children: [SmartHomePage(), RemotePrintPage()])),
  ]));
}
