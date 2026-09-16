// AI 厂商与 Key 统一管理页: 密钥管理 + 自动识别 + 中转站 + 自定义厂商
import 'package:flutter/material.dart';
import 'ai.dart';
import 'vendor_icons.dart';

class AiProvidersPage extends StatefulWidget { const AiProvidersPage({super.key}); @override State<AiProvidersPage> createState() => _AiProv(); }
class _AiProv extends State<AiProvidersPage> {
  String filter = ''; bool onlyKeyed = false; final Set<String> keyed = {};
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    keyed.clear();
    for (final p in AiRegistry.all) { if ((await AiRegistry.keyOf(p.id)).isNotEmpty) keyed.add(p.id); }
    if (mounted) setState(() {});
  }

  @override Widget build(BuildContext c) {
    var list = AiRegistry.all;
    if (onlyKeyed) list = list.where((p) => keyed.contains(p.id)).toList();
    if (filter.isNotEmpty) {
      final f = filter.toLowerCase();
      list = list.where((p) => p.name.toLowerCase().contains(f) || p.id.contains(f) ||
        p.models.any((m) => m.toLowerCase().contains(f))).toList();
    }
    return Scaffold(appBar: AppBar(title: const Text('厂商与密钥'), actions: [
        IconButton(icon: const Icon(Icons.refresh), tooltip: '从网站同步',
          onPressed: () async { final ok = await AiRegistry.refresh(); await _load();
            if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(ok ? '已同步 ${AiRegistry.providers.length} 家厂商' : '同步失败, 使用本地清单'))); }),
      ]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: TextField(
          decoration: const InputDecoration(hintText: '搜索厂商或模型…', prefixIcon: Icon(Icons.search), isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)))),
          onChanged: (v) => setState(() => filter = v))),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          Text('${AiRegistry.all.length} 家厂商 · ${AiRegistry.all.fold<int>(0, (a, b) => a + b.models.length)} 个模型 · 已配 ${keyed.length} 个Key',
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const Spacer(),
          FilterChip(label: const Text('只看已配Key', style: TextStyle(fontSize: 11)), selected: onlyKeyed,
            onSelected: (v) => setState(() => onlyKeyed = v), visualDensity: VisualDensity.compact),
        ])),
        // 统一入口: 自动识别 Key / 中转站 Key / 自定义厂商
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: _identifyDialog, icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('自动识别 Key', style: TextStyle(fontSize: 12)))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: _relayDialog, icon: const Icon(Icons.swap_calls, size: 16),
            label: const Text('中转站 Key', style: TextStyle(fontSize: 12)))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: () => _customDialog(null), icon: const Icon(Icons.add_business, size: 16),
            label: const Text('自定义厂商', style: TextStyle(fontSize: 12)))),
        ])),
        Expanded(child: ListView.builder(itemCount: list.length, itemBuilder: (_, i) {
          final p = list[i];
          final custom = AiRegistry.isCustom(p.id);
          return ExpansionTile(dense: true, leading: VendorIcon(p.id, size: 28),
            title: Row(children: [ Flexible(child: Text(p.name, style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis)),
              if (custom) Container(margin: const EdgeInsets.only(left: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: const Text('自定义', style: TextStyle(fontSize: 9, color: Colors.orange))) ]),
            subtitle: Text('${p.models.length} 个模型${keyed.contains(p.id) ? ' · 已配Key' : ''}',
              style: TextStyle(fontSize: 10, color: keyed.contains(p.id) ? Colors.green : Colors.grey)),
            children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
                Expanded(child: Text(p.base, style: const TextStyle(fontSize: 10, color: Colors.grey), overflow: TextOverflow.ellipsis)),
                if (custom) ...[
                  TextButton(onPressed: () => _customDialog(p), child: const Text('编辑', style: TextStyle(fontSize: 12))),
                  TextButton(onPressed: () async {
                    final ok = await showDialog<bool>(context: c, builder: (c3) => AlertDialog(title: Text('删除自定义厂商「${p.name}」?'),
                      actions: [TextButton(onPressed: () => Navigator.pop(c3, false), child: const Text('取消')),
                        FilledButton(onPressed: () => Navigator.pop(c3, true), child: const Text('删除'))]));
                    if (ok == true) { await AiRegistry.removeCustomProvider(p.id); await _load(); }
                  }, child: const Text('删除', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
                ],
                TextButton(onPressed: () => _keyDialog(p), child: Text(keyed.contains(p.id) ? '改Key' : '配Key', style: const TextStyle(fontSize: 12))),
              ])),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final m in p.models.take(60))
                  ActionChip(label: Text(m, style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact,
                    onPressed: () async { await AiRegistry.setLastModel(p.id, m);
                      if (c.mounted) Navigator.pop(c); }),
              ])),
            ]);
        })),
      ]));
  }

  // 配置/验证 Key(保存前真实对话验证, 失败时提示自动识别)
  Future<void> _keyDialog(AiProvider p) async {
    final ctrl = TextEditingController(text: await AiRegistry.keyOf(p.id));
    String? msg; bool testing = false;
    final ok = await showDialog<bool>(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: Text('${p.name} API Key', style: const TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctrl, obscureText: true, decoration: const InputDecoration(hintText: 'sk-...', isDense: true)),
        if (msg != null) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(msg!, style: TextStyle(fontSize: 11, color: msg!.startsWith('✓') ? Colors.green : Colors.redAccent))),
        if (testing) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        TextButton(onPressed: testing ? null : () async {
          setD(() { testing = true; msg = null; });
          final hit = await AiKeyDetect.testKey(p, ctrl.text.trim());
          setD(() { testing = false; msg = hit != null ? '✓ 验证通过' : '验证失败 · Key 可能不属于该厂商(可保存后用自动识别)'; });
        }, child: const Text('验证')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))]))));
    if (ok == true) { await AiRegistry.setKey(p.id, ctrl.text.trim()); await _load(); }
  }

  // 自动识别 Key: 前缀优先 + 并行批量验证(与网站一致)
  Future<void> _identifyDialog() async {
    final ctrl = TextEditingController();
    String status = ''; AiProvider? hit; bool busy = false;
    await showDialog(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: const Text('自动识别 Key', style: TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('粘贴任一厂商的 API Key, 自动识别它属于哪家厂商并保存', style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 8),
        TextField(controller: ctrl, obscureText: true, decoration: const InputDecoration(hintText: 'sk-...', isDense: true)),
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(status, style: TextStyle(fontSize: 11, color: hit != null ? Colors.green : Colors.grey))),
        if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
      ]),
      actions: [
        if (hit != null) TextButton(onPressed: () => Navigator.pop(c2), child: const Text('完成')),
        if (hit == null) TextButton(onPressed: () => Navigator.pop(c2), child: const Text('取消')),
        if (hit == null) FilledButton(onPressed: busy ? null : () async {
          final key = ctrl.text.trim(); if (key.isEmpty) return;
          setD(() { busy = true; status = ''; hit = null; });
          final r = await AiKeyDetect.identify(key, onProgress: (s) => setD(() => status = s));
          if (r != null) { await AiRegistry.setKey(r.id, key); await _load(); }
          setD(() { busy = false; hit = r; status = r != null ? '✓ 识别成功: 该 Key 属于「${r.name}」, 已保存' : '未识别到匹配厂商'; });
        }, child: const Text('开始识别')),
      ])));
  }

  // 中转站 Key: 探测≥2品牌判定为通用 Key, 一键填到所有未配置的厂商
  Future<void> _relayDialog() async {
    final ctrl = TextEditingController();
    String status = ''; bool busy = false; bool? isRelay;
    await showDialog(context: context, builder: (c2) => StatefulBuilder(builder: (c2, setD) => AlertDialog(
      title: const Text('中转站 Key', style: TextStyle(fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('第三方中转站(聚合API)的通用 Key: 自动探测, 确认后一键填到所有支持的厂商',
          style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 8),
        TextField(controller: ctrl, obscureText: true, decoration: const InputDecoration(hintText: 'sk-...', isDense: true)),
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(status, style: TextStyle(fontSize: 11, color: isRelay == true ? Colors.green : Colors.grey))),
        if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
        FilledButton(onPressed: busy ? null : () async {
          final key = ctrl.text.trim(); if (key.isEmpty) return;
          setD(() { busy = true; status = '正在探测(并行请求3个品牌)…'; });
          final relay = await AiKeyDetect.probeRelay(key);
          if (!relay) { setD(() { busy = false; isRelay = false; status = '该 Key 未通过中转站探测(可能不是通用 Key)'; }); return; }
          final n = await AiKeyDetect.saveRelayKey(key);
          await _load();
          setD(() { busy = false; isRelay = true; status = '✓ 已确认为中转站 Key · 已自动填到 $n 家厂商'; });
        }, child: const Text('探测并保存')),
      ])));
  }

  // 自定义厂商(中转站/自建): 名称+地址+Key+模型列表
  Future<void> _customDialog(AiProvider? exist) async {
    final nameC = TextEditingController(text: exist?.name ?? '');
    final baseC = TextEditingController(text: exist?.base ?? '');
    final keyC = TextEditingController(text: exist == null ? '' : await AiRegistry.keyOf(exist.id));
    final modelsC = TextEditingController(text: exist?.models.join(', ') ?? '');
    final ok = await showDialog<bool>(context: context, builder: (c2) => AlertDialog(
      title: Text(exist == null ? '添加自定义厂商' : '编辑自定义厂商', style: const TextStyle(fontSize: 16)),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('适合中转站 / 自建网关 / 网站未收录的 OpenAI 兼容服务', style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 8),
        TextField(controller: nameC, decoration: const InputDecoration(labelText: '名称', hintText: '我的中转站', isDense: true)),
        TextField(controller: baseC, decoration: const InputDecoration(labelText: '接口地址', hintText: 'https://api.example.com/v1', isDense: true)),
        TextField(controller: keyC, obscureText: true, decoration: const InputDecoration(labelText: 'API Key', hintText: 'sk-...', isDense: true)),
        TextField(controller: modelsC, maxLines: 2,
          decoration: const InputDecoration(labelText: '模型列表(逗号分隔)', hintText: 'gpt-4o, deepseek-chat, claude-opus-5', isDense: true)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('保存'))]));
    if (ok != true) return;
    final models = modelsC.text.split(RegExp(r'[,，\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (nameC.text.trim().isEmpty || baseC.text.trim().isEmpty || models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('名称 / 接口地址 / 模型列表 不能为空'))); return;
    }
    final id = exist?.id ?? 'custom-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await AiRegistry.saveCustomProvider(AiProvider(id, nameC.text.trim(), baseC.text.trim().replaceAll(RegExp(r'/$'), ''), 'openai', models, const [], const []));
    if (keyC.text.trim().isNotEmpty) await AiRegistry.setKey(id, keyC.text.trim());
    await _load();
  }
}
