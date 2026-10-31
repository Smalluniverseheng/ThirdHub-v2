// AI 设置页（2026-10-31 新增）
//
// 为什么新增：
//   用户指出抽屉里「AI模型」出现了两次 ——
//     ① 独立一行 ListTile（点进去只是切到同一个 models 页签，纯重复）
//     ② 页签行里的「AI模型」
//   要求：保留页签那个（它就是模型列表），把独立那行改成「AI 设置」，
//   而且必须是**AI 功能本身的设置**（对话风格 / 上下文 / 工具 / 语音 / 记忆），
//   不是"厂商与密钥"那种高级项——那些收进本页最底部的「高级」组。
//
// 设计口径对齐网页端的「对话设置 / 更多设置」两块，但每一项在本机都真的生效：
//   写的是 AI 页启动时读的那几个键（见 core/ai_page.dart 的 _boot）。
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_agent.dart';
import 'ai_providers_page.dart';
import 'api_keys_page.dart';
import 'asr_settings_page.dart';
import 'tts_settings_page.dart';
import 'i18n.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});
  @override
  State<AiSettingsPage> createState() => _AiSettings();
}

class _AiSettings extends State<AiSettingsPage> {
  bool web = false, mcp = true, fallback = true, confirmMcp = false;
  int ctxTurns = 0;
  String persona = 'default';
  String custom = '';
  int memCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    await AiInstruct.load();
    await AiMemory.load();
    if (!mounted) return;
    setState(() {
      web = p.getBool('ai_websearch_on') ?? false;
      mcp = p.getBool('ai_mcp_on') ?? true;
      fallback = p.getBool('ai_tool_fallback') ?? true;
      confirmMcp = p.getBool('ai_confirm_mcp') ?? false;
      ctxTurns = p.getInt('ai_ctx_turns') ?? 0;
      persona = AiInstruct.personaId;
      custom = AiInstruct.custom;
      memCount = AiMemory.entries.length;
    });
  }

  Future<void> _set(String key, Object v) async {
    final p = await SharedPreferences.getInstance();
    if (v is bool) await p.setBool(key, v);
    if (v is int) await p.setInt(key, v);
    setState(() {});
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 设置')),
      body: ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 40), children: [
        _group(c, '对话风格', [
          _tile('人格', value: AiInstruct.personas[persona]?.$1 ?? '默认',
              sub: '决定回复的语气与详略，影响每一次对话', onTap: () => _pickPersona(c)),
          _tile('全局指令', value: custom.isEmpty ? '未设置' : '${custom.length} 字',
              sub: '每次都追加到系统提示（写你的习惯与禁忌）', onTap: () => _editCustom(c)),
        ]),
        _group(c, '上下文', [
          _tile('携带历史', value: ctxTurns == 0 ? '不携带' : '最近 $ctxTurns 轮',
              sub: '轮数越多越"记得前面"，但更费 token', onTap: () => _pickCtx(c)),
          SwitchListTile(
            value: web, onChanged: (v) { setState(() => web = v); _set('ai_websearch_on', v); },
            title: const Text('联网搜索', style: TextStyle(fontSize: 14)),
            subtitle: const Text('回答前先检索，并把结果注入上下文', style: TextStyle(fontSize: 11.5)),
            contentPadding: EdgeInsets.zero, dense: true,
          ),
        ]),
        _group(c, '工具与执行', [
          SwitchListTile(
            value: mcp, onChanged: (v) { setState(() => mcp = v); _set('ai_mcp_on', v); },
            title: const Text('启用工具（MCP）', style: TextStyle(fontSize: 14)),
            subtitle: const Text('让模型能调用你配置的 MCP 服务与本机能力', style: TextStyle(fontSize: 11.5)),
            contentPadding: EdgeInsets.zero, dense: true,
          ),
          SwitchListTile(
            value: fallback, onChanged: (v) { setState(() => fallback = v); _set('ai_tool_fallback', v); },
            title: const Text('工具失败自动回退', style: TextStyle(fontSize: 14)),
            subtitle: const Text('模型不支持原生工具调用时，用文本协议兜底', style: TextStyle(fontSize: 11.5)),
            contentPadding: EdgeInsets.zero, dense: true,
          ),
          SwitchListTile(
            value: confirmMcp, onChanged: (v) { setState(() => confirmMcp = v); _set('ai_confirm_mcp', v); },
            title: const Text('调用工具前确认', style: TextStyle(fontSize: 14)),
            subtitle: const Text('涉及写文件 / 执行命令时先问你一句', style: TextStyle(fontSize: 11.5)),
            contentPadding: EdgeInsets.zero, dense: true,
          ),
        ]),
        _group(c, '语音', [
          _tile('语音朗读', value: '厂商 · 音色 · 试听',
              sub: 'AI 回复用什么声音念出来', onTap: () => _push(c, const TtsSettingsPage())),
          _tile('语音识别', value: '厂商 · Key · 试录',
              sub: '按住说话转成文字', onTap: () => _push(c, const AsrSettingsPage())),
        ]),
        _group(c, '长期记忆', [
          _tile('记忆条目', value: '$memCount 条',
              sub: '跨会话生效的事实，会装配进系统提示',
              onTap: () => _memorySheet(c)),
        ]),
        _group(c, '高级（厂商与密钥）', [
          _tile('AI 厂商与模型密钥', value: '端点 · Key · 模型清单',
              sub: '换厂商、填 Key、改自建地址都在这', onTap: () => _push(c, const AiProvidersPage())),
          _tile('统一密钥库', value: '一处填写 · 多模块共用',
              sub: 'AI 与语音共用同一把 Key', onTap: () => _push(c, const ApiKeysPage())),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('这些设置保存在本机，换设备不同步；密钥类走「统一密钥库」加密存储。',
              style: TextStyle(fontSize: 11.5, color: cs.onSurface.withValues(alpha: 0.5))),
        ),
      ]),
    );
  }

  Widget _group(BuildContext c, String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Text(title,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.6)))),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Column(children: children)),
          ),
        ]),
      );

  Widget _tile(String label, {required String value, String? sub, VoidCallback? onTap}) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 14)),
        subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11.5)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(value,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)))),
          if (onTap != null) const Icon(Icons.chevron_right, size: 18),
        ]),
        onTap: onTap,
      );

  void _push(BuildContext c, Widget page) =>
      Navigator.push(c, MaterialPageRoute(builder: (_) => page)).then((_) => _load());

  Future<void> _pickPersona(BuildContext c) async {
    final ids = AiInstruct.personas.keys.toList();
    final v = await showModalBottomSheet<String>(
        context: c,
        builder: (c2) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Padding(padding: EdgeInsets.all(14), child: Text('对话风格', style: TextStyle(fontWeight: FontWeight.w600))),
              for (final id in ids)
                ListTile(
                  dense: true,
                  title: Text(AiInstruct.personas[id]!.$1),
                  subtitle: Text(AiInstruct.personas[id]!.$2.isEmpty ? '不做额外约束' : AiInstruct.personas[id]!.$2,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                  trailing: id == persona ? const Icon(Icons.check, size: 18) : null,
                  onTap: () => Navigator.pop(c2, id),
                ),
            ])));
    if (v == null) return;
    await AiInstruct.setPersona(v);
    await _load();
  }

  Future<void> _editCustom(BuildContext c) async {
    final ctl = TextEditingController(text: custom);
    final v = await showDialog<String>(
        context: c,
        builder: (c2) => AlertDialog(
              title: const Text('全局指令', style: TextStyle(fontSize: 16)),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('每次对话都会追加到系统提示。写你的称呼、习惯、禁忌、常用格式。',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 10),
                TextField(controller: ctl, minLines: 5, maxLines: 12, decoration: const InputDecoration(hintText: '例如：叫我英莉；回答先给结论；代码用 Dart。')),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c2), child: Text(tr('取消'))),
                FilledButton(onPressed: () => Navigator.pop(c2, ctl.text), child: Text(tr('保存'))),
              ],
            ));
    if (v == null) return;
    await AiInstruct.setCustom(v);
    await _load();
  }

  Future<void> _pickCtx(BuildContext c) async {
    final v = await showModalBottomSheet<int>(
        context: c,
        builder: (c2) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final n in [0, 3, 6, 10, 20])
                ListTile(
                  dense: true,
                  title: Text(n == 0 ? '不携带历史' : '最近 $n 轮'),
                  trailing: n == ctxTurns ? const Icon(Icons.check, size: 18) : null,
                  onTap: () => Navigator.pop(c2, n),
                ),
            ])));
    if (v == null) return;
    setState(() => ctxTurns = v);
    await _set('ai_ctx_turns', v);
  }

  Future<void> _memorySheet(BuildContext c) async {
    await AiMemory.load();
    if (!mounted) return;
    await showModalBottomSheet<void>(
        context: c,
        builder: (c2) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                child: Row(children: [
                  Expanded(child: Text('长期记忆（${AiMemory.entries.length}）', style: const TextStyle(fontWeight: FontWeight.w600))),
                  if (AiMemory.entries.isNotEmpty)
                    TextButton(
                        onPressed: () async {
                          for (final e in [...AiMemory.entries]) {
                            await AiMemory.remove(e.id);
                          }
                          if (c2.mounted) Navigator.pop(c2);
                          await _load();
                        },
                        child: const Text('全部清空')),
                ]),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: AiMemory.entries.isEmpty
                    ? const Padding(padding: EdgeInsets.all(24), child: Text('还没有记忆。在对话里说「记住：…」即可添加。', style: TextStyle(fontSize: 12)))
                    : ListView(shrinkWrap: true, children: [
                        for (final e in AiMemory.entries)
                          ListTile(
                            dense: true,
                            title: Text(e.text, style: const TextStyle(fontSize: 13)),
                            subtitle: Text(DateTime.fromMillisecondsSinceEpoch(e.ts).toString().split('.').first,
                                style: const TextStyle(fontSize: 10)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () async {
                                await AiMemory.remove(e.id);
                                if (c2.mounted) Navigator.pop(c2);
                                await _load();
                              },
                            ),
                          ),
                      ]),
              ),
              const SizedBox(height: 8),
            ])));
    await _load();
  }
}
