// 语音朗读设置页：选引擎 + 按厂商填 Key + 试听。
//
// 为什么要单独一页：此前"在线 TTS"的入口藏在小说阅读器的一个底部弹窗里，
// 而真正要填的 Key 又放在「AI 模块」的厂商配置里 —— 用的人和配的人不在同一处。
// 这一页把「选哪家 → 填什么 → 能不能响」收在一条线上。
//
// 照 STYLE_GUIDE：不用 emoji；卡片圆角 12；失败信息三段式（现象/原因/怎么办）。
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'play_tag.dart';
import 'tts.dart';
import 'tts_engines_page.dart';
import 'tts_online.dart';
import 'tts_vendors.dart';

class TtsSettingsPage extends StatefulWidget {
  const TtsSettingsPage({super.key});
  @override
  State<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<TtsSettingsPage> {
  final _player = AudioPlayer();
  List<TtsVendor> _all = const [];
  List<TtsVendor> _custom = const [];
  final Map<String, TtsConfig> _cfg = {};
  String _cur = 'system';
  bool _loading = true;
  String _busy = ''; // 正在试听的厂商 id

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await TtsOnline.allVendors();
    final custom = await TtsOnline.customVendors();
    final cur = await TtsManager.engine();
    _cfg.clear();
    for (final v in all) {
      _cfg[v.id] = await TtsOnline.configOf(v.id);
    }
    if (!mounted) return;
    setState(() {
      _all = all;
      _custom = custom;
      _cur = cur;
      _loading = false;
    });
  }

  Future<void> _pick(String id) async {
    await TtsManager.setEngine(id);
    if (!mounted) return;
    setState(() => _cur = id);
  }

  Future<void> _preview(TtsVendor v) async {
    setState(() => _busy = v.id);
    try {
      final f = await TtsOnline.preview(v);
      await _player.setAudioSource(
          tagFile(f, title: '试听 · ${v.name}', album: 'ThirdHub 语音朗读'));
      await _player.play();
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('试听「${v.name}」失败'),
            content: SingleChildScrollView(
                child: Text('$e', style: const TextStyle(fontSize: 13))),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c), child: const Text('知道了')),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  String get _curLabel {
    switch (_cur) {
      case 'system':
        return '系统离线朗读';
      case 'backend':
        return '家庭后端合成';
      case 'opensource':
        return '开源引擎直连';
    }
    for (final v in _all) {
      if (v.id == _cur) return v.name;
    }
    return '未选择';
  }

  Widget _vTile(TtsVendor v) {
    final cfg = _cfg[v.id] ?? const TtsConfig();
    final ready = cfg.readyFor(v);
    final selected = _cur == v.id;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: selected
              ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.4)
              : BorderSide.none),
      child: ListTile(
        title: Row(children: [
          Expanded(
              child: Text(v.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600))),
          if (ready)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(8)),
              child: const Text('已配置',
                  style: TextStyle(fontSize: 10, color: Colors.green)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(8)),
              child:
                  const Text('未配置', style: TextStyle(fontSize: 10, color: Colors.grey)),
            ),
        ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(v.note, style: const TextStyle(fontSize: 11)),
        ),
        trailing: IconButton(
          tooltip: '试听',
          icon: _busy == v.id
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_circle_outline, size: 22),
          onPressed: _busy.isEmpty ? () => _preview(v) : null,
        ),
        onTap: () async {
          await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => TtsVendorPage(vendor: v, config: cfg)));
          await _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
          appBar: null, body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('语音朗读')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('当前朗读引擎',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Text(_curLabel,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  ChoiceChip(
                      label: const Text('系统离线'),
                      selected: _cur == 'system',
                      onSelected: (_) => _pick('system')),
                  if (TtsBackend.available)
                    ChoiceChip(
                        label: const Text('家庭后端'),
                        selected: _cur == 'backend',
                        onSelected: (_) => _pick('backend')),
                  ChoiceChip(
                      label: const Text('开源引擎直连'),
                      selected: _cur == 'opensource',
                      onSelected: (_) => _pick('opensource')),
                ]),
                const SizedBox(height: 6),
                const Text(
                    '系统离线零配置零费用、音质一般；下面的在线厂商音质更好，需要各自申请 Key。',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.memory, size: 16),
                  label: const Text('开源引擎接入指引（自己跑 piper 等）'),
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const TtsEnginesPage())),
                ),
              ]),
            ),
          ),
          for (final g in ['国内', '海外', '自托管'])
            ..._group(g),
          if (_custom.isNotEmpty)
            _sectionTitle('自定义', '你手动添加的接口'),
          for (final v in _custom) _vTile(v),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加自定义 TTS 接口'),
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const TtsVendorPage(vendor: null, config: null)));
                await _load();
              },
            ),
          ),
          _pendingSection(),
        ],
      ),
    );
  }

  List<Widget> _group(String g) {
    final vs = [for (final v in _all) if (v.group == g) v];
    if (vs.isEmpty) return const [];
    final hint = switch (g) {
      '国内' => '国内可直连 · 用支付宝/微信即可充值',
      '海外' => '多数需要能访问外网',
      '自托管' => '自己跑的开源引擎 · 填服务地址即可，不需要 Key',
      _ => '',
    };
    return [_sectionTitle(g, hint), for (final v in vs) _vTile(v)];
  }

  Widget _sectionTitle(String t, String hint) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          if (hint.isNotEmpty)
            Flexible(
                child: Text(hint,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    overflow: TextOverflow.ellipsis)),
        ]),
      );

  Widget _pendingSection() => Card(
        margin: const EdgeInsets.fromLTRB(12, 16, 12, 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            title: const Text('暂未适配的厂商（${kTtsPendingVendors.length} 家）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: const Text('这些厂商要客户端算签名或走 WebSocket，当前版本还接不了',
                style: TextStyle(fontSize: 11)),
            children: [
              for (final m in kTtsPendingVendors)
                ListTile(
                  dense: true,
                  title: Text(m['name'] ?? '', style: const TextStyle(fontSize: 13)),
                  subtitle: Text('${m['why']}　${m['url']}',
                      style: const TextStyle(fontSize: 10)),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('如果你的厂商不在上面任何一处，可以用「添加自定义 TTS 接口」把它的地址、鉴权头和请求体模板填进来 —— 只要它是 HTTP 接口就能用。',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            ],
          ),
        ),
      );
}

/// 单个厂商的配置页。`vendor == null` 表示新建自定义接口。
class TtsVendorPage extends StatefulWidget {
  final TtsVendor? vendor;
  final TtsConfig? config;
  const TtsVendorPage({super.key, required this.vendor, required this.config});
  @override
  State<TtsVendorPage> createState() => _TtsVendorPageState();
}

class _TtsVendorPageState extends State<TtsVendorPage> {
  final _player = AudioPlayer();
  late TextEditingController _key, _host, _region, _voice, _model, _format;
  late TextEditingController _name, _url, _bodyTpl, _authHeader, _authValue, _audioPath;
  String _testResult = '';
  bool _busy = false;

  bool get _isCustom => widget.vendor == null;

  @override
  void initState() {
    super.initState();
    final v = widget.vendor;
    final c = widget.config;
    _key = TextEditingController(text: c?.key ?? '');
    _host = TextEditingController(text: c?.host ?? '');
    _region = TextEditingController(text: (c?.region ?? '').isEmpty ? 'eastasia' : c!.region);
    _voice = TextEditingController(text: (c?.voice ?? '').isEmpty ? (v?.voice ?? '') : c!.voice);
    _model = TextEditingController(text: (c?.model ?? '').isEmpty ? (v?.model ?? '') : c!.model);
    _format = TextEditingController(text: (c?.format ?? '').isEmpty ? (v?.format ?? 'mp3') : c!.format);
    _name = TextEditingController(text: v?.name ?? '');
    _url = TextEditingController(text: v?.url ?? '');
    _bodyTpl = TextEditingController(text: v?.bodyTpl ?? '');
    _authHeader = TextEditingController(text: v?.authHeader ?? 'Authorization');
    _authValue = TextEditingController(text: v?.authValue ?? 'Bearer {key}');
    _audioPath = TextEditingController(text: v?.audioPath ?? '');
  }

  @override
  void dispose() {
    for (final c in [
      _key, _host, _region, _voice, _model, _format,
      _name, _url, _bodyTpl, _authHeader, _authValue, _audioPath,
    ]) {
      c.dispose();
    }
    _player.dispose();
    super.dispose();
  }

  /// 当前表单对应的厂商对象（自定义时按表单现建）。
  TtsVendor _effective() {
    if (!_isCustom) {
      final v = widget.vendor!;
      return TtsVendor(
        id: v.id, name: v.name, group: v.group, note: v.note, tier: v.tier,
        url: v.needHost ? _withHost(v.url) : v.url,
        method: v.method, auth: v.auth, authHeader: v.authHeader,
        authValue: v.authValue, extraHeaders: v.extraHeaders, body: v.body,
        bodyTpl: v.bodyTpl, resp: v.resp, audioPath: v.audioPath,
        encoding: v.encoding, voices: v.voices, models: v.models,
        voice: v.voice, model: v.model, format: v.format,
        needRegion: v.needRegion, needHost: v.needHost, docUrl: v.docUrl,
      );
    }
    return buildCustomVendor(
      name: _name.text.trim(),
      url: _url.text.trim(),
      authHeader: _authHeader.text.trim(),
      authValue: _authValue.text.trim(),
      bodyTpl: _bodyTpl.text.trim(),
      audioPath: _audioPath.text.trim(),
      voice: _voice.text.trim(),
      model: _model.text.trim(),
      format: _format.text.trim().isEmpty ? 'mp3' : _format.text.trim(),
      resp: widget.vendor?.resp ?? TtsResp.binary,
    );
  }

  /// 自托管：把用户填的 host 塞进 `http://{host}/...`。
  String _withHost(String url) {
    final h = _host.text.trim();
    if (h.isEmpty) return url;
    final clean = h.replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
    return url.replaceAll('{host}', clean);
  }

  Future<void> _save() async {
    final v = _effective();
    if (_isCustom) {
      if (_name.text.trim().isEmpty || _url.text.trim().isEmpty || _bodyTpl.text.trim().isEmpty) {
        setState(() => _testResult = '自定义接口至少要填：名称、请求地址、请求体模板。');
        return;
      }
      final list = [...await TtsOnline.customVendors()];
      list.removeWhere((e) => e.id == v.id);
      list.add(v);
      await TtsOnline.setCustomVendors(list);
    }
    await TtsOnline.saveConfig(v.id,
        key: _key.text.trim(),
        voice: _voice.text.trim(),
        model: _model.text.trim(),
        format: _format.text.trim(),
        region: _region.text.trim(),
        host: _host.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已保存「${v.name}」')));
  }

  Future<void> _preview() async {
    final v = _effective();
    setState(() {
      _busy = true;
      _testResult = '';
    });
    try {
      final f = await TtsOnline.preview(v);
      await _player.setAudioSource(
          tagFile(f, title: '试听 · ${v.name}', album: 'ThirdHub 语音朗读'));
      await _player.play();
      if (mounted) setState(() => _testResult = '合成成功，正在播放。');
    } catch (e) {
      if (mounted) setState(() => _testResult = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final v = widget.vendor;
    if (v == null) return;
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('删除这个自定义接口？'),
              content: Text('「${v.name}」的地址与模板会一并删除，已保存的 Key 也会清掉。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
              ],
            ));
    if (ok != true) return;
    final list = [...await TtsOnline.customVendors()]..removeWhere((e) => e.id == v.id);
    await TtsOnline.setCustomVendors(list);
    if (mounted) Navigator.pop(context);
  }

  Widget _field(String label, TextEditingController c,
      {String? hint, bool obscure = false, int lines = 1, String? helper}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        obscureText: obscure,
        maxLines: lines,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 2,
          isDense: true,
          border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(10))),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vendor;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isCustom ? '自定义 TTS 接口' : (v?.name ?? '')),
        actions: [
          if (_isCustom && v != null)
            IconButton(
                tooltip: '删除', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [
          if (!_isCustom && v != null) ...[
            Text(v.note, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            SelectableText(
              v.needHost ? v.url : v.url,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            if (v.docUrl.isNotEmpty)
              Text('文档：${v.docUrl}',
                  style: const TextStyle(fontSize: 11, color: Colors.blue)),
            const SizedBox(height: 12),
          ] else ...[
            _field('名称', _name, hint: '例如 我的自建 TTS'),
            _field('请求地址', _url,
                hint: 'https://… 或 http://192.168.1.5:8000/v1/audio/speech',
                helper: '可用占位符：{text} {voice} {model} {format} {key} {host}'),
          ],
          if (v?.needHost == true)
            _field('服务地址', _host,
                hint: '192.168.1.5:8880',
                helper: '只填主机与端口，不用带 http://'),
          if (v?.needRegion == true)
            _field('区域 region', _region, hint: 'eastasia',
                helper: 'Azure 的区域拼在域名里，填错会连不上'),
          if (v?.auth != TtsAuth.none && v?.auth != TtsAuth.baidu)
            _field('API Key', _key,
                hint: '粘贴厂商控制台里的 Key', obscure: true),
          if (v?.auth == TtsAuth.baidu)
            _field('APIKey|SecretKey', _key,
                hint: '两段用一根竖线隔开', obscure: true,
                helper: '百度要先用这两个值换 access_token'),
          if (_isCustom) ...[
            _field('鉴权头名', _authHeader, hint: 'Authorization',
                helper: '常见：Authorization / xi-api-key / api-key / Ocp-Apim-Subscription-Key'),
            _field('鉴权值模板', _authValue, hint: 'Bearer {key}',
                helper: '用 {key} 代表上面那个 Key。不需要鉴权就留空'),
            _field('请求体模板', _bodyTpl, lines: 4,
                hint: '{"model":"{model}","input":"{text}","voice":"{voice}"}',
                helper: '文本用 {text}；不同厂商字段名不同（input/text/transcript/data）'),
            _field('响应音频路径', _audioPath, hint: 'data.audio',
                helper: '响应是音频文件就留空；是 JSON 就填取值路径，如 output.audio.url'),
          ],
          const SizedBox(height: 4),
          if (!_isCustom && v != null && v.voices.isNotEmpty) ...[
            const Text('常用音色（可直接选，也可自己填）',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final x in v.voices.take(12))
                ActionChip(
                  label: Text(x, style: const TextStyle(fontSize: 11)),
                  onPressed: () => setState(() => _voice.text = x),
                ),
            ]),
            const SizedBox(height: 10),
          ],
          _field('音色 voice', _voice),
          if (!_isCustom && v != null && v.models.isNotEmpty) ...[
            const SizedBox(height: 2),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final x in v.models.take(8))
                ActionChip(
                  label: Text(x, style: const TextStyle(fontSize: 11)),
                  onPressed: () => setState(() => _model.text = x),
                ),
            ]),
            const SizedBox(height: 10),
          ],
          _field('模型 model', _model),
          _field('输出格式 format', _format, hint: 'mp3 / wav'),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                icon: _busy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow, size: 18),
                label: const Text('试听'),
                onPressed: _busy ? null : _preview,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存'),
                onPressed: _busy ? null : _save,
              ),
            ),
          ]),
          if (_testResult.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(_testResult,
                    style: const TextStyle(fontSize: 12, height: 1.5)),
              ),
            ),
          const SizedBox(height: 16),
          Text(
            _isCustom
                ? '只要是 HTTP 接口就能接：把厂商文档里的地址、鉴权头、请求体粘进来，'
                    '用 {text} 代表要朗读的文字即可。'
                : '填好 Key 后点「试听」。失败时这里会写明是哪一步、以及厂商返回的原话。',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
