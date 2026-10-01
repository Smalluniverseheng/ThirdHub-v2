// 开源 TTS 引擎引导页（D-C3）。
//
// 这一页要回答用户三个问题，顺序不能反：
//   ① 我该装哪个？（清单 + 各自代价：离线否 / 许可 / 吃不吃显卡）
//   ② 去哪装？（打开项目主页；**App 不分发模型**）
//   ③ 装完怎么确认真的能用？（填入地址 → 自检 → **听到声音**）
//
// ★ 为什么第 ③ 步必须走到"听到声音"：
//   `/health` 通过只证明 HTTP 活着、声明像 TTS/1；真正坏的是合成那一段
//   （模型没加载、显存不足、音色名写错）。本项目在"测试通过、实际用不了"
//   上吃过不止一次亏，所以这里给自检两步：先连上，再**真合成一句并播放**。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_log.dart';
import 'pro_kit.dart';
import 'tts_direct.dart';
import 'tts_engines_logic.dart';
import 'ui_icons.dart';

class TtsEnginesPage extends StatefulWidget {
  const TtsEnginesPage({super.key});
  @override
  State<TtsEnginesPage> createState() => _TtsEnginesPageState();
}

class _TtsEnginesPageState extends State<TtsEnginesPage> {
  final _url = TextEditingController();
  TtsProbeResult? _probe;
  bool _busy = false;
  String _synthMsg = '';
  String _synthPath = '';
  AudioPlayer? _player;

  static const _kUrl = 'tts_os_url';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kUrl) ?? '';
    if (!mounted) return;
    setState(() => _url.text = v);
  }

  @override
  void dispose() {
    _url.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _openHome(TtsEngineProject p) async {
    final ok = await launchUrl(Uri.parse(p.home),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      // 打不开浏览器要说出来，并给出可复制的地址（静默失败 = 用户点了一动不动）
      ProUI.toast(context, '打不开浏览器。地址已复制，可手动粘贴：${p.home}');
    }
    await Clipboard.setData(ClipboardData(text: p.home));
  }

  Future<void> _fill(TtsEngineProject p) async {
    final v = 'http://127.0.0.1:${p.defaultPort}';
    setState(() => _url.text = v);
    ProUI.toast(context, '已填入 ${p.name} 常见端口 ${p.defaultPort}，请改成引擎所在设备的 IP');
  }

  Future<void> _copyHint(TtsEngineProject p) async {
    await Clipboard.setData(ClipboardData(text: p.hint));
    if (mounted) ProUI.toast(context, '启动命令已复制');
  }

  Future<void> _check() async {
    final raw = _url.text.trim();
    if (raw.isEmpty) {
      ProUI.toast(context, '请先填写引擎地址');
      return;
    }
    setState(() {
      _busy = true;
      _probe = null;
      _synthMsg = '';
      _synthPath = '';
    });
    final r = await TtsDirect.probe(raw);
    await TtsDirect.logProbe(raw, r);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUrl, raw);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _probe = r;
    });
    if (r.ok) {
      // 连上了才继续第二步（合成）。第一步就失败时不再合成 ——
      // 那只会多花 60 秒并报出第二个更难懂的错。
      await _synthVerify(raw, r);
    }
  }

  Future<void> _synthVerify(String url, TtsProbeResult caps) async {
    setState(() => _synthMsg = '正在合成一句试听…');
    final r = await TtsDirect.verifySynth(url, caps);
    if (!mounted) return;
    setState(() {
      _synthMsg = r.ok ? '合成成功，正在播放…' : '合成失败：${r.detail}';
      _synthPath = r.path;
    });
    if (!r.ok) {
      await AppLog.warn('engine', '开源 TTS 引擎合成失败', d: {'url': url, 'detail': r.detail});
      return;
    }
    await _play(r.path);
  }

  Future<void> _play(String path) async {
    try {
      _player ??= AudioPlayer();
      await _player!.setAudioSource(AudioFileSource(File(path), tag: null));
      await _player!.play();
    } catch (e) {
      if (!mounted) return;
      setState(() => _synthMsg = '音频已合成，但播放失败：$e');
    }
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('开源 TTS 引擎'),
        actions: [
          IconButton(
            tooltip: '接入协议说明',
            icon: const Icon(Icons.description_outlined),
            onPressed: () => _showProtocol(c),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          ProUI.note(
              '这里连接的是**你自己跑的开源语音合成引擎**（电脑 / 旧手机 / NAS 上都行）。'
              '本应用不内置、不分发任何语音模型，只负责"连上去"并帮你确认真的能用。'),
          const SizedBox(height: 12),
          _sectionTitle(c, '第 1 步 · 选一个引擎'),
          for (final p in kTtsEngineProjects) _projectCard(c, p),
          const SizedBox(height: 8),
          _sectionTitle(c, '第 2 步 · 填入引擎地址并自检'),
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '引擎地址',
                        hintText: 'http://192.168.1.5:5100',
                        helperText: '缺端口时会按 5100 补齐；同一局域网才能连上',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _check,
                        icon: const Icon(Icons.cable_outlined, size: 18),
                        label: Text(_busy ? '自检中…' : '连接自检'),
                      ),
                      const SizedBox(width: 10),
                      if (_synthPath.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () => _play(_synthPath),
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('重放'),
                        ),
                    ]),
                    if (_probe != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _probe!.ok
                              ? cs.primary.withValues(alpha: 0.10)
                              : cs.error.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(children: [
                          Icon(
                              _probe!.ok
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline,
                              size: 18,
                              color: _probe!.ok ? cs.primary : cs.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(describeProbe(_probe!),
                                style: const TextStyle(fontSize: 12.5)),
                          ),
                        ]),
                      ),
                    ],
                    if (_synthMsg.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(_synthMsg,
                          style: TextStyle(
                              fontSize: 12,
                              color: _synthMsg.startsWith('合成成功')
                                  ? cs.primary
                                  : cs.error)),
                    ],
                  ]),
            ),
          ),
          const SizedBox(height: 8),
          _sectionTitle(c, '协议与边界'),
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('客户端只要求服务端实现两个端点：',
                        style: TextStyle(fontSize: 12.5)),
                    const SizedBox(height: 6),
                    const SelectableText(
                      'GET  /health      → {"ok":true,"protocol":"tts/1","engine":"piper","voices":[…]}\n'
                      'POST /synthesize  ← {"text":"…","voice":"…","format":"wav"}  → 音频字节',
                      style: TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '· protocol 必须是字面量 tts/1 —— 只看 ok:true 会把任何 REST 服务都当成引擎；\n'
                      '· 不内置模型、不分发模型、不硬编码下载直链（上游一改版本就会 404）；\n'
                      '· 不做流式、不做鉴权（局域网自用；要上公网请在反代加 Token 并写进 URL）。',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                  ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext c, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(t,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Theme.of(c).colorScheme.primary)),
      );

  Widget _projectCard(BuildContext c, TtsEngineProject p) {
    final cs = Theme.of(c).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(p.offline ? Icons.wifi_off : Icons.cloud_outlined,
                size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10)),
              child: Text(p.license, style: const TextStyle(fontSize: 10)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(p.note,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            ActionChip(
              avatar: const Icon(Icons.open_in_new, size: 15),
              label: const Text('打开项目主页', style: TextStyle(fontSize: 11.5)),
              onPressed: () => _openHome(p),
            ),
            ActionChip(
              avatar: uiIcon('pin', size: 15),
              label: Text('填入 :${p.defaultPort}',
                  style: const TextStyle(fontSize: 11.5)),
              onPressed: () => _fill(p),
            ),
            ActionChip(
              avatar: const Icon(Icons.terminal, size: 15),
              label: const Text('复制启动命令', style: TextStyle(fontSize: 11.5)),
              onPressed: () => _copyHint(p),
            ),
          ]),
          const SizedBox(height: 4),
          SelectableText(p.hint,
              style: TextStyle(
                  fontSize: 10.5, fontFamily: 'monospace', color: cs.outline)),
        ]),
      ),
    );
  }

  void _showProtocol(BuildContext c) {
    showDialog<void>(
      context: c,
      builder: (c2) => AlertDialog(
        title: const Text('TTS/1 接入协议'),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('服务端只需两个端点：', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            const SelectableText(
              'GET /health\n'
              '  → {"ok":true,"protocol":"tts/1","engine":"piper",\n'
              '     "sample_rate":22050,"voices":["zh_CN-huayan-medium"],\n'
              '     "default_voice":"zh_CN-huayan-medium","formats":["wav","mp3"]}\n\n'
              'POST /synthesize   Content-Type: application/json\n'
              '  ← {"text":"要合成的文本","voice":"可选","format":"可选"}\n'
              '  → 200 + 音频字节（Content-Type 如实标注 audio/wav 等）\n\n'
              '失败：非 200 + {"ok":false,"error":{"code":"…","message":"…"}}',
              style: TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 10),
            const Text(
              '判定顺序（客户端逐字照做）：\n'
              '1. 地址能解析并能连上\n'
              '2. /health 返回 200 且是 JSON 对象\n'
              '3. ok == true            —— 否则"服务在但不健康"\n'
              '4. protocol == "tts/1"   —— 否则"不是 TTS/1 引擎"\n'
              '5. 记下音色/采样率/格式，才算已连接\n\n'
              '第 3 步与第 4 步必须分开报：前者通常是模型没加载完，'
              '后者通常是你把其它服务的端口填进来了（比如引擎 :1234 或资源库 :9527）。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            const Text('完整协议见仓库 docs/TTS-PROTOCOL.md',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c2), child: const Text('关闭')),
        ],
      ),
    );
  }
}
