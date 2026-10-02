// 语音引擎「一键自动配对」页面：贴一把 Key → 自动找出它是哪家的 → 存好。
//
// 判定规则在 `tts_autopair.dart`（纯 Dart，有自检），网络与存盘在
// `tts_autopair_run.dart`。本页只做交互，不自己判任何东西。
//
// ★ 交互上刻意做到的两点：
//   ① **过程可见**。逐家试到哪一家要显示出来 —— 配对要打真请求、有等待，
//      黑箱转圈会让用户以为卡死而中途退出（退出就把一次配对浪费了）。
//   ② **结论不糊**。命中就写"已配对：某某 · 某方案"，没命中就写清是被拒绝、
//      连不上、还是形态不符 —— 这三种情况用户该做的事完全不同。
library;

import 'package:flutter/material.dart';

import 'tts_autopair.dart';
import 'tts_autopair_run.dart';

class TtsAutoPairPage extends StatefulWidget {
  const TtsAutoPairPage({super.key});
  @override
  State<TtsAutoPairPage> createState() => _TtsAutoPairPageState();
}

class _TtsAutoPairPageState extends State<TtsAutoPairPage> {
  final _key = TextEditingController();
  bool _running = false;
  String _step = '';
  String _summary = '';
  List<TtsProbeResult> _results = const [];

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final k = _key.text.trim();
    if (k.isEmpty) {
      setState(() => _summary = '先把 Key 粘贴进来');
      return;
    }
    setState(() {
      _running = true;
      _step = '准备中…';
      _summary = '';
      _results = const [];
    });
    List<TtsProbeResult> rs;
    try {
      rs = await TtsAutoPair.probe(k, onStep: (i, n, label) {
        if (!mounted) return;
        setState(() => _step = '正在试 $i/$n：$label');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _summary = '配对过程出错：$e';
      });
      return;
    }
    final saved = await TtsAutoPair.saveHits(rs, k);
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = rs;
      _step = '';
      _summary = TtsAutoPairRules.summary(rs) +
          (saved > 0 ? '\n已保存到 API 密钥库与语音厂商配置，可以直接去试听。' : '');
    });
  }

  @override
  Widget build(BuildContext c) {
    final primary = Theme.of(c).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('一键配对语音引擎')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Text(
            '把申请到的 API Key 粘贴进来，会逐家发一个字的最小探测，找出它属于哪家厂商、'
            '该用哪套计费方式，然后自动存好。',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          obscureText: true,
          maxLines: 1,
          decoration: const InputDecoration(
            labelText: 'API Key',
            border: OutlineInputBorder(),
            helperText: '只在本机使用；探测会合成一个字，属于一次真实调用。',
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.wifi_tethering, size: 18),
          label: Text(_running ? '正在配对…' : '开始配对'),
          onPressed: _running ? null : _run,
        ),
        if (_step.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(children: [
            const SizedBox(
                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(_step,
                    style: const TextStyle(fontSize: 12, color: Colors.grey))),
          ]),
        ],
        if (_summary.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12)),
            child: Text(_summary, style: const TextStyle(fontSize: 13, height: 1.5)),
          ),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Text('逐家结果', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final r in _results) _row(r),
        ],
      ]),
    );
  }

  Widget _row(TtsProbeResult r) {
    final (icon, color, label) = switch (r.outcome) {
      TtsProbeOutcome.hit => (Icons.check_circle, Colors.green, '匹配'),
      TtsProbeOutcome.badKey => (Icons.cancel, Colors.redAccent, '不认这把 Key'),
      TtsProbeOutcome.wrongShape => (Icons.warning_amber, Colors.orange, '形态不符'),
      TtsProbeOutcome.unreachable => (Icons.cloud_off, Colors.grey, '连不上'),
      _ => (Icons.help_outline, Colors.grey, '看不出来'),
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: color, size: 20),
        title: Text(r.candidate.label, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
            [
              label,
              if (r.httpStatus > 0) 'HTTP ${r.httpStatus}',
              if (r.models.isNotEmpty) '模型 ${r.models.length} 个',
              if (r.detail.isNotEmpty) r.detail,
            ].join('　'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ),
    );
  }
}
