// 语音识别设置页：选厂商 → 填 Key → 试录。
//
// 与「语音朗读」同一套路（tts_settings_page.dart）：
//   · 一家一张卡：名称 + 说明 + Key 输入 + 就绪状态；
//   · Key 走统一密钥库的回落链 —— 在 AI / 语音朗读里填过同一家的，
//     这里直接可用（卡片上会写明"已从密钥库带出"）；
//   · 底部一个「试录 3 秒」按钮，录完立刻识别并把结果、耗时、走的哪家印出来。
//
// 照 STYLE_GUIDE：不用 emoji；卡片圆角 12；失败信息三段式（现象/原因/怎么办）。
import 'dart:async';

import 'package:flutter/material.dart';

import 'asr_service.dart';
import 'asr_vendors.dart';
import 'voice_msg.dart';

class AsrSettingsPage extends StatefulWidget {
  const AsrSettingsPage({super.key});

  @override
  State<AsrSettingsPage> createState() => _AsrSettingsPageState();
}

class _AsrSettingsPageState extends State<AsrSettingsPage> {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, bool> _ready = {};
  final Map<String, bool> _fromLib = {};
  String _engine = 'xiaomi';

  // 试录状态
  final VoiceRec _rec = VoiceRec();
  bool _recording = false;
  bool _recognizing = false;
  String _result = '';
  String _status = '';

  @override
  void initState() {
    super.initState();
    for (final v in AsrVendors.all) {
      _ctrls[v.id] = TextEditingController();
    }
    _refreshAll();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshAll() async {
    for (final v in AsrVendors.all) {
      final own = await AsrService.keyOf(v);
      final ready = await AsrService.readyFor(v);
      // 判断是否"来自统一密钥库"（自己没填但能读到）
      final self = _ctrls[v.id]?.text.trim() ?? '';
      if (mounted) {
        setState(() {
          _ready[v.id] = ready;
          _fromLib[v.id] = self.isEmpty && ready && v.group != '自托管';
        });
      }
    }
  }

  Future<void> _saveKey(AsrVendor v) async {
    await AsrService.setKey(v, _ctrls[v.id]?.text ?? '');
    await _refreshAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存「${v.name}」的 Key')),
    );
  }

  /// 试录 3 秒 → 识别。
  Future<void> _tryRecord() async {
    final v = AsrVendors.byId(_engine);
    if (v == null) return;

    if (!_recording) {
      // 开始录
      final ok = await _rec.start();
      if (!ok) {
        setState(() => _status = '拿不到麦克风权限。到系统设置里给本应用开「麦克风」权限后重试。');
        return;
      }
      setState(() {
        _recording = true;
        _result = '';
        _status = '录音中…（3 秒后自动停）';
      });
      // 3 秒自动停
      Timer(const Duration(seconds: 3), () async {
        if (mounted && _recording) await _stopAndRecognize();
      });
      return;
    }
    await _stopAndRecognize();
  }

  Future<void> _stopAndRecognize() async {
    final v = AsrVendors.byId(_engine);
    if (v == null) return;
    final (path, secs) = await _rec.stop();
    setState(() {
      _recording = false;
      if (path == null) {
        _status = '没录到声音（${secs}s）。靠近麦克风再说一次。';
        return;
      }
      _recognizing = true;
      _status = '识别中…（约 ${secs}s 的录音，走的 ${v.name}）';
    });
    if (path == null) return;

    final t0 = DateTime.now();
    try {
      final text = await AsrService.transcribe(v, AsrRequest(filePath: path, language: 'zh'));
      final ms = DateTime.now().difference(t0).inMilliseconds;
      setState(() {
        _recognizing = false;
        _result = text;
        _status = '成功 · ${v.name} · ${(ms / 1000).toStringAsFixed(1)}s';
      });
    } catch (e) {
      setState(() {
        _recognizing = false;
        _status = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = AsrVendors.byId(_engine);
    return Scaffold(
      appBar: AppBar(title: const Text('语音识别')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ── 说明 ──
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('把语音转成文字，走你自己选的厂商',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  SizedBox(height: 6),
                  Text(
                    '在下面选一家、填它的 Key，就能把「说话」变成文字。\n'
                    '在「AI」或「语音朗读」里填过同一家的 Key，这里会直接从密钥库带出，不用重填。\n'
                    '录音只在你点「试录」时才进行，且只发给所选厂商用于识别。',
                    style: TextStyle(fontSize: 12.5, height: 1.7, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── 厂商选择 ──
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 6),
            child: Text('识别引擎', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                for (final v in AsrVendors.all)
                  RadioListTile<String>(
                    value: v.id,
                    groupValue: _engine,
                    onChanged: (x) => setState(() => _engine = x ?? _engine),
                    title: Row(
                      children: [
                        Expanded(child: Text(v.name, style: const TextStyle(fontSize: 14))),
                        if (_ready[v.id] == true)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('就绪',
                                style: TextStyle(fontSize: 11, color: Colors.green)),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      v.note.isEmpty ? v.group : '${v.group} · ${v.note}',
                      style: const TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                    dense: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 当前引擎的 Key ──
          if (cur != null) ...[
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${cur.name} · Key',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                    if (_fromLib[cur.id] == true)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('已从密钥库带出（AI / 语音朗读里填过）—— 不用重填',
                            style: TextStyle(fontSize: 11.5, color: Colors.teal)),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _ctrls[cur.id],
                      obscureText: true,
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        hintText: cur.group == '自托管'
                            ? '自托管无需 Key（地址见下）'
                            : '粘贴厂商控制台里的 Key',
                      ),
                    ),
                    if (cur.group == '自托管')
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('服务地址：${cur.url}',
                            style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: () => _saveKey(cur),
                          child: const Text('保存'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () async {
                            final r = await AsrService.probe(cur);
                            if (!mounted) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text(r)));
                          },
                          child: const Text('测连通'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── 试录 ──
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('试录（3 秒）',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                    const SizedBox(height: 4),
                    const Text('点下面的按钮开始说话，3 秒自动停，然后立刻识别。',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _recognizing ? null : _tryRecord,
                      icon: Icon(_recording ? Icons.stop : Icons.mic),
                      label: Text(_recording
                          ? '点击停止'
                          : (_recognizing ? '识别中…' : '开始录音')),
                    ),
                    if (_status.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_status,
                            style: const TextStyle(fontSize: 12.5, height: 1.6)),
                      ),
                    if (_result.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.blueGrey.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(_result,
                            style: const TextStyle(fontSize: 14, height: 1.6)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}