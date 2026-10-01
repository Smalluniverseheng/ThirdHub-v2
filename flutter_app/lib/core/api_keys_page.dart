// 通用 API 密钥库（UI）
//
// 用户诉求：「很多 AI 厂商的 TTS 模型和 API 密钥是通用的 …… 在 AI 模块输入的
// Key，TTS 模块也能用，不用重复输入。你也要弄好一点。」
//
// 这一页就是那句话的**可见证据**：列出这台设备上已经填过的所有厂商 Key，
// 标明它来自哪一层、能被哪些模块用，并允许在这里直接改。
//
// 先说清楚一件事（页头会写）：**它不是"又一个要填 Key 的地方"**。
// 用户仍然可以在 AI 模块或语音模块里随手填 —— 填进任何一个，
// 其余模块自动就能用。这一页是"查看与清理中心"，不是必经之路。

import 'package:flutter/material.dart';

import 'ai.dart';
import 'api_keys.dart';
import 'api_keys_store.dart';
import 'tts_vendors.dart';

class ApiKeysPage extends StatefulWidget {
  const ApiKeysPage({super.key});
  @override
  State<ApiKeysPage> createState() => _P();
}

class _P extends State<ApiKeysPage> {
  Map<String, KeyHit> _map = {};
  bool _loading = true;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await ApiKeys.dump();
    if (!mounted) return;
    setState(() {
      _map = m;
      _loading = false;
    });
  }

  /// 厂商显示名：先按语音模块的名字，再按 AI 模块的名字，都没有就用 id。
  String _nameOf(String id) {
    for (final v in kTtsVendors) {
      if (KeyVendor.same(v.id, id)) return v.name;
    }
    for (final p in AiRegistry.providers) {
      if (KeyVendor.same(p.id, id)) return p.name;
    }
    return id;
  }

  /// 这家厂商的 Key 能被哪些用途共用（用于卡片上那行小字）。
  String _useHint(String id) {
    if (!KeySharing.isShared(id)) {
      return '该厂商的对话与语音是两套凭证，不会自动带出';
    }
    return '对话与语音共用同一把';
  }

  Future<void> _edit(String id) async {
    final cur = _map[id];
    final ctl = TextEditingController(text: cur?.key ?? '');
    final k = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${_nameOf(id)} 的 Key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctl,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(
              hintText: '粘贴 API Key（留空 = 删除）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(_useHint(id),
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, ctl.text), child: const Text('保存')),
        ],
      ),
    );
    if (k == null) return;
    await ApiKeys.set(id, k);
    await _load();
    if (!mounted) return;
    setState(() => _msg = k.trim().isEmpty ? '已删除该厂商的 Key' : '已保存');
  }

  Future<void> _merge() async {
    final n = await ApiKeys.migrate();
    await _load();
    if (!mounted) return;
    setState(() => _msg = n == 0 ? '没有需要并入的旧 Key' : '已并入 $n 条历史 Key');
  }

  @override
  Widget build(BuildContext c) {
    final entries = _map.entries.toList()
      ..sort((a, b) => _nameOf(a.key).compareTo(_nameOf(b.key)));
    return Scaffold(
      appBar: AppBar(title: const Text('API 密钥库'), actions: [
        IconButton(
            tooltip: '并入历史 Key',
            icon: const Icon(Icons.merge_type),
            onPressed: _merge),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.key_outlined,
                              size: 20,
                              color: Theme.of(c).colorScheme.primary),
                          const SizedBox(width: 8),
                          const Text('一处填写，处处可用',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                        ]),
                        const SizedBox(height: 8),
                        const Text(
                          '同一个厂商的 Key 只需填一次 —— 在 AI 模块填过的，'
                          '语音朗读会自动带上；反过来也一样。\n'
                          '这一页是查看与修改的地方，不是必须经过的步骤。',
                          style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.6),
                        ),
                        if (_msg.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(_msg,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(c).colorScheme.primary)),
                        ],
                      ]),
                ),
              ),
              const SizedBox(height: 8),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    '还没有填过任何 Key。\n\n'
                    '你可以去「AI 助手 → 设置」或「语音朗读」里填，\n'
                    '填完这里就会出现，并自动被两个模块共用。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, height: 1.8, fontSize: 12),
                  ),
                )
              else
                for (final e in entries)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(
                          e.value.fromKeychain
                              ? Icons.lock_outline
                              : Icons.history,
                          color: e.value.fromKeychain
                              ? Theme.of(c).colorScheme.primary
                              : Colors.grey),
                      title: Text(_nameOf(e.key),
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 2),
                            Text(maskKey(e.value.key),
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: Colors.grey)),
                            const SizedBox(height: 2),
                            Text('${e.value.sourceLabel} · ${_useHint(e.key)}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                          ]),
                      isThreeLine: true,
                      trailing: IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => _edit(e.key)),
                      onTap: () => _edit(e.key),
                    ),
                  ),
              const SizedBox(height: 12),
              const Text(
                '说明：Key 只保存在这台设备上，不会上传到任何服务器；'
                '本页只显示掩码，不显示明文。',
                style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.6),
              ),
            ]),
    );
  }
}
