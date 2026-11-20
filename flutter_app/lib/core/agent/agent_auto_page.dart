// 应用内 AI 自动驾驶页
//
// 「软件里填自己买的 API Key，让模型看着本机画面一步步操作这个 App」——
// 这件事的开关和观察窗口都在这一页。
//
// 和 4.81.81 那条局域网通道的区别（两条都要，别混）：
//   · 局域网通道：电脑上的脚本/我这边驱动，适合跑回归用例、批量截图。
//   · 本页：手机自己跑，模型就在手机上，断网前配好就能用；
//     不需要电脑、不需要同一 WiFi，出门在外也能让 AI 自己走一遍功能。
//
// 为什么每步都留截图：模型说"已完成"是最不可信的一句话。
// 图摆在眼前，人一眼就知道它是真看到了还是瞎猜。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai.dart';
import '../api_keys_store.dart';
import '../i18n.dart';
import 'agent_llm.dart';
import 'agent_runner.dart';

class AgentAutoPage extends StatefulWidget {
  const AgentAutoPage({super.key});

  @override
  State<AgentAutoPage> createState() => _Aap();
}

class _Aap extends State<AgentAutoPage> {
  // 连接配置
  String _providerId = '';
  String _model = '';
  String _base = '';
  String _kind = 'openai';
  final _keyCtl = TextEditingController();
  final _baseCtl = TextEditingController();
  final _modelCtl = TextEditingController();
  final _goalCtl = TextEditingController();

  bool _showKey = false;
  bool _saving = false;
  String _keyHint = '';

  // 运行状态
  final _runner = AgentRunner();
  bool _running = false;
  final List<AgentStepView> _steps = [];
  String _summary = '';
  bool _ok = false;
  bool _hasResult = false;

  static const _presets = <String>[
    '把视频页从红果一路滑到最后，每个平台都停一下，报告哪个平台是空白页',
    '依次打开小说、漫画、视频、音乐、B站，报告每个板块首页能不能正常显示内容',
    '打开视频 → 哔哩哔哩，进直播间列表，报告有没有能看的直播',
    '搜一本书并打开第一章，报告正文有没有正常显示',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _runner.stop();
    _keyCtl.dispose();
    _baseCtl.dispose();
    _modelCtl.dispose();
    _goalCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final pid = p.getString('agent_llm_provider') ?? '';
    final model = p.getString('agent_llm_model') ?? '';
    final base = p.getString('agent_llm_base') ?? '';
    final kind = p.getString('agent_llm_kind') ?? 'openai';
    final goal = p.getString('agent_llm_goal') ?? '';

    String key = '';
    if (pid.isNotEmpty) key = await ApiKeys.get(pid);
    if (key.isEmpty && model.isEmpty) {
      // 没配过就用「最近用过的模型」，让用户少填一步
      final (lp, lm) = await AiRegistry.lastModel();
      final prov = AiRegistry.byId(lp);
      if (prov != null) {
        key = await ApiKeys.get(lp);
      }
      if (!mounted) return;
      setState(() {
        _providerId = prov?.id ?? '';
        _model = lm;
        _base = prov?.base ?? '';
        _kind = prov?.type ?? 'openai';
        _keyCtl.text = key;
        _baseCtl.text = _base;
        _modelCtl.text = _model;
        _goalCtl.text = goal;
        _keyHint = key.isEmpty ? tr('这个厂商还没填密钥') : tr('已保存的密钥');
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _providerId = pid;
      _model = model;
      _base = base;
      _kind = kind;
      _keyCtl.text = key;
      _baseCtl.text = base;
      _modelCtl.text = model;
      _goalCtl.text = goal;
      _keyHint = key.isEmpty ? tr('未填写') : tr('已保存的密钥');
    });
  }

  void _pickProvider(AiProvider p) {
    setState(() {
      _providerId = p.id;
      _base = p.base;
      _kind = p.type;
      _baseCtl.text = p.base;
      if (p.models.isNotEmpty && !p.models.contains(_model)) {
        _model = p.models.first;
        _modelCtl.text = _model;
      }
    });
    ApiKeys.get(p.id).then((v) {
      if (!mounted) return;
      setState(() {
        _keyCtl.text = v;
        _keyHint = v.isEmpty ? tr('这个厂商还没填密钥') : tr('已保存的密钥');
      });
    });
  }

  Future<void> _save() async {
    final key = _keyCtl.text.trim();
    final base = _baseCtl.text.trim();
    final model = _modelCtl.text.trim();
    if (model.isEmpty || base.isEmpty) {
      setState(() => _keyHint = tr('地址和模型名都要填'));
      return;
    }
    setState(() => _saving = true);
    final p = await SharedPreferences.getInstance();
    final pid = _providerId.isEmpty ? 'agent_auto' : _providerId;
    await p.setString('agent_llm_provider', pid);
    await p.setString('agent_llm_model', model);
    await p.setString('agent_llm_base', base);
    await p.setString('agent_llm_kind', _kind);
    await p.setString('agent_llm_goal', _goalCtl.text.trim());
    if (key.isNotEmpty) await ApiKeys.set(pid, key);
    if (!mounted) return;
    setState(() {
      _providerId = pid;
      _model = model;
      _base = base;
      _saving = false;
      _keyHint = key.isEmpty ? tr('未填写密钥，保存了也用不了') : tr('已保存');
    });
  }

  AgentLlm? _client() {
    final key = _keyCtl.text.trim();
    if (key.isEmpty) return null;
    return AgentLlm(
      providerId: _providerId,
      model: _modelCtl.text.trim(),
      base: _baseCtl.text.trim(),
      apiKey: key,
      kind: _kind,
    );
  }

  Future<void> _run() async {
    final llm = _client();
    if (llm == null) {
      setState(() => _keyHint = tr('先填 API 密钥'));
      return;
    }
    await _save();
    if (!mounted) return;
    setState(() {
      _running = true;
      _steps.clear();
      _summary = '';
      _hasResult = false;
    });
    final r = await _runner.run(
      llm: llm,
      goal: _goalCtl.text.trim(),
      maxSteps: 12,
      onStep: (v) {
        if (!mounted) return;
        setState(() => _steps.add(v));
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _ok = r.ok;
      _summary = r.summary;
      _hasResult = true;
    });
  }

  String _export() {
    final sb = StringBuffer()
      ..writeln('ThirdHub AI 自动测试')
      ..writeln('目标：${_goalCtl.text.trim()}')
      ..writeln('模型：$_providerId / ${_modelCtl.text.trim()}')
      ..writeln('结果：${_ok ? '完成' : '未完成'} — $_summary')
      ..writeln();
    for (final s in _steps) {
      sb.writeln('#${s.index} ${s.say}');
      sb.writeln('   动作：${jsonEncode(s.action)}');
      sb.writeln('   结果：${s.ok ? 'ok' : 'ERR ${s.error}'}（${s.ms}ms）');
      if (s.thought.isNotEmpty) sb.writeln('   思考：${s.thought}');
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final providers = AiRegistry.all;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('AI 自动测试')),
        actions: [
          IconButton(
            tooltip: tr('复制结果'),
            icon: const Icon(Icons.copy_all_outlined, size: 20),
            onPressed: _steps.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _export()));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr('已复制，可直接发给我'))));
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Text(
            tr('让手机里的 AI 自己看着画面操作这个 App。你在下面填自己的 API 密钥，它每步截图、自己判断、自己点，做完给你看图和结论。'),
            style: TextStyle(fontSize: 12.5, height: 1.6, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 14),

          // ── 模型配置 ──
          _card(cs, tr('模型'), [
            DropdownButtonFormField<String>(
              initialValue: providers.any((p) => p.id == _providerId)
                  ? _providerId
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: tr('厂商'), isDense: true, border: const OutlineInputBorder()),
              items: [
                for (final p in providers)
                  DropdownMenuItem(
                      value: p.id,
                      child: Text('${p.name}  ·  ${p.id}',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) {
                if (v == null) return;
                final p = AiRegistry.byId(v);
                if (p != null) _pickProvider(p);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _modelCtl,
              decoration: InputDecoration(
                labelText: tr('模型名（要支持看图）'),
                hintText: 'gpt-4o / glm-4v / qwen-vl-max / claude-3.5-sonnet',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => _model = v.trim(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _baseCtl,
              decoration: InputDecoration(
                labelText: tr('接口地址'),
                hintText: 'https://api.openai.com/v1',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => _base = v.trim(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _keyCtl,
              obscureText: !_showKey,
              decoration: InputDecoration(
                labelText: tr('API 密钥'),
                helperText: _keyHint,
                helperMaxLines: 2,
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _showKey ? Icons.visibility_off : Icons.visibility_outlined,
                      size: 18),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'openai', label: Text(tr('OpenAI 兼容'))),
                  ButtonSegment(value: 'anthropic', label: Text('Claude')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton.tonal(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? tr('保存中') : tr('保存配置')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('密钥只存在本机，随「清除数据」一起消失；不会进日志。'),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            ]),
          ]),
          const SizedBox(height: 12),

          // ── 目标 ──
          _card(cs, tr('要它做什么'), [
            TextField(
              controller: _goalCtl,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: tr('例如：把视频页每个平台都点一遍，报告哪个是空白页'),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final p in _presets)
                  ActionChip(
                    label: Text(p, style: const TextStyle(fontSize: 11)),
                    onPressed: _running ? null : () => setState(() => _goalCtl.text = p),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: Icon(_running ? Icons.hourglass_top : Icons.play_arrow, size: 18),
                label: Text(_running ? tr('运行中') : tr('开始')),
              ),
              const SizedBox(width: 10),
              if (_running)
                OutlinedButton.icon(
                  onPressed: () {
                    _runner.stop();
                    setState(() => _summary = tr('正在停止…'));
                  },
                  icon: const Icon(Icons.stop, size: 18),
                  label: Text(tr('停止')),
                ),
            ]),
          ]),

          // ── 结论 ──
          if (_hasResult) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _ok
                    ? cs.primaryContainer.withValues(alpha: 0.5)
                    : cs.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 18,
                    color: _ok ? cs.primary : cs.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_summary,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: _ok ? cs.onPrimaryContainer : cs.onErrorContainer)),
                ),
              ]),
            ),
          ],

          // ── 步骤 ──
          if (_steps.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(tr('过程'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            for (final s in _steps) _stepCard(cs, s),
          ],
        ],
      ),
    );
  }

  Widget _card(ColorScheme cs, String title, List<Widget> kids) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            ...kids,
          ],
        ),
      );

  Widget _stepCard(ColorScheme cs, AgentStepView s) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: (s.ok ? cs.outlineVariant : cs.error).withValues(alpha: 0.5)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (s.shot != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(s.shot!,
                  width: 54, height: 96, fit: BoxFit.cover),
            )
          else
            Container(
              width: 54,
              height: 96,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.image_not_supported_outlined,
                  size: 16, color: cs.onSurfaceVariant),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('#${s.index}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurfaceVariant)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.say.isEmpty ? tr('（没有说明）') : s.say,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                '${_opText(s.action)}  ·  ${s.ok ? tr('成功') : tr('失败')}  ·  ${s.ms}ms',
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: s.ok ? cs.onSurfaceVariant : cs.error),
              ),
              if (!s.ok && s.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(s.error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cs.error)),
                ),
            ]),
          ),
        ]),
      );

  static String _opText(Map<String, dynamic>? a) {
    if (a == null) return '—';
    final op = '${a['op'] ?? '?'}';
    final extra = <String>[];
    for (final k in ['module', 'name', 'text', 'dir', 'url', 'q', 'xy']) {
      final v = a[k];
      if (v != null) extra.add('$k=$v');
    }
    return extra.isEmpty ? op : '$op(${extra.join(',')})';
  }
}

/// 给外面用的小工具：当前是否配置好了模型（「我的」页显示状态用）。
class AgentAutoStatus {
  const AgentAutoStatus._();

  static Future<String> summary() async {
    final p = await SharedPreferences.getInstance();
    final pid = p.getString('agent_llm_provider') ?? '';
    final model = p.getString('agent_llm_model') ?? '';
    if (pid.isEmpty || model.isEmpty) return '';
    final key = await ApiKeys.get(pid);
    if (key.isEmpty) return '';
    return '$model';
  }
}
