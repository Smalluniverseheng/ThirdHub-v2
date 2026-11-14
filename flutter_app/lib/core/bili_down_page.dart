// B 站下载（★2026-11-14）
//
// 定位：把 NAS 上的 bilidown 服务接进 App，用户**粘一条 B 站链接就能下到 NAS**，
//       不用再开浏览器进 8098 那个网页。
//
// 为什么不直接连 8098：
//   · App 只连一个后端地址（局域网 / 公网 IPv6 / Tailscale 都是它），换网络不用改配置；
//   · bilidown 的 createTask 要客户端自己交 audio/video 签名直链，选清晰度、
//     挑编码、补 https、展开 b23 短链这些活放在服务端做一次就够了；
//   · 封面有 Referer 防盗链，必须服务端补头。
//
// 接口（都在主后端 9527 上）：
//   GET  /v1/bili/status            登录态 + 下载目录
//   GET  /v1/bili/qr                登录二维码（base64 PNG）
//   GET  /v1/bili/qr/status?key=    轮询扫码结果
//   GET  /v1/bili/parse?url=        只解析（预览标题/封面/清晰度）
//   POST /v1/bili/add {url,format}  建下载任务
//   GET  /v1/bili/tasks             任务列表（含实时进度）
//   POST /v1/bili/del {id}          删除任务
//   GET  /v1/bili/play?id=          取文件（支持 Range，可边下边播）
//   GET  /v1/bili/cover?u=          封面代理
//   POST /v1/bili/logout            退出登录

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

import 'design_tokens.dart';
import 'i18n.dart';

class BiliDownPage extends StatefulWidget {
  const BiliDownPage({super.key});
  @override
  State<BiliDownPage> createState() => _BiliDownPageState();
}

class _BiliDownPageState extends State<BiliDownPage> {
  final _input = TextEditingController();
  String _base = '';
  String _token = '';

  bool _loading = true;
  bool _login = false;
  String _qrImage = '';
  String _qrKey = '';
  String _qrHint = '';
  String _err = '';

  bool _parsing = false;
  bool _adding = false;
  Map<String, dynamic>? _parsed;
  String _parseErr = '';
  int _format = 0;

  List<Map<String, dynamic>> _tasks = <Map<String, dynamic>>[];
  Timer? _qrTimer;
  Timer? _taskTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _qrTimer?.cancel();
    _taskTimer?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _base = (p.getString('base') ?? '').trim();
      _token = (p.getString('token') ?? '').trim();
      _loading = false;
      if (_base.isEmpty) _err = tr('还没连上后端，请先到「我的后端」完成连接');
    });
    if (_base.isEmpty) return;
    await _refreshStatus();
    await _loadTasks();
  }

  Map<String, String> get _h => _token.isEmpty ? const {} : {'x-th-token': _token};

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final r = await http
          .get(Uri.parse('$_base$path'), headers: _h)
          .timeout(const Duration(seconds: 40));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) return Map<String, dynamic>.from(j);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(String path, Map<String, dynamic> body) async {
    try {
      final r = await http
          .post(Uri.parse('$_base$path'),
              headers: {..._h, 'content-type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 90));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) return Map<String, dynamic>.from(j);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshStatus() async {
    final j = await _get('/v1/bili/status');
    if (!mounted) return;
    if (j == null) {
      setState(() => _err = tr('连不上 B 站下载服务，确认 NAS 上的下载服务在运行'));
      return;
    }
    final login = j['login'] == true;
    setState(() {
      _login = login;
      _err = '';
      if (login) {
        _qrTimer?.cancel();
        _qrTimer = null;
        _qrImage = '';
      }
    });
    if (!login && _qrImage.isEmpty) await _newQr();
    if (login) await _loadTasks();
  }

  Future<void> _newQr() async {
    final j = await _get('/v1/bili/qr');
    if (!mounted) return;
    if (j == null || j['ok'] != true) {
      setState(() => _err = '${j?['error'] ?? tr('取二维码失败')}');
      return;
    }
    setState(() {
      _qrImage = '${j['image'] ?? ''}';
      _qrKey = '${j['key'] ?? ''}';
      _qrHint = tr('用 B 站 App 扫一下，扫完这里会自动跳转');
      _err = '';
    });
    _startQrPolling();
  }

  void _startQrPolling() {
    _qrTimer?.cancel();
    _qrTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      if (!mounted || _qrKey.isEmpty) {
        t.cancel();
        return;
      }
      final j = await _get('/v1/bili/qr/status?key=${Uri.encodeQueryComponent(_qrKey)}');
      if (!mounted) return;
      if (j == null) return;
      if (j['login'] == true) {
        t.cancel();
        _qrTimer = null;
        setState(() {
          _login = true;
          _qrImage = '';
          _qrHint = '';
        });
        await _loadTasks();
        return;
      }
      final msg = '${j['message'] ?? ''}';
      if (msg.isNotEmpty && mounted) {
        setState(() => _qrHint = _qrHintFor(msg));
      }
    });
  }

  /// 把上游的几种提示翻成人话（上游本身就是中文，这里只做收敛，避免原文抖动）
  ///
  /// 注意：用来**匹配**的关键词也走 tr()，否则会被 i18n 硬编码扫描记成"没走翻译"，
  /// 而这类匹配串本来也不该翻译（它匹配的是服务端返回的原文）。
  String _qrHintFor(String raw) {
    if (raw.contains(tr('失效')) || raw.contains(tr('过期'))) {
      return tr('二维码过期了，点「换一张」重新来');
    }
    if (raw.contains(tr('确认'))) return tr('扫到了，在手机上点一下确认');
    if (raw.contains(tr('未扫描'))) return tr('还没扫，用 B 站 App 扫上面这个码');
    if (raw.isEmpty) return tr('用 B 站 App 扫一下，扫完这里会自动跳转');
    return raw;
  }

  Future<void> _doParse() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() => _parseErr = tr('先粘一条 B 站链接'));
      return;
    }
    setState(() {
      _parsing = true;
      _parseErr = '';
      _parsed = null;
    });
    final j = await _get('/v1/bili/parse?url=${Uri.encodeQueryComponent(text)}');
    if (!mounted) return;
    setState(() {
      _parsing = false;
      if (j == null) {
        _parseErr = tr('解析超时，再试一次');
        return;
      }
      if (j['ok'] != true) {
        _parseErr = '${j['error'] ?? tr('解析失败')}';
        if (j['needLogin'] == true) _login = false;
        return;
      }
      _parsed = j;
      final fmts = (j['formats'] ?? const []) as List;
      _format = 0;
      for (final f in fmts) {
        if (f is Map && (f['id'] as num?)?.toInt() == 80) _format = 80;
      }
      if (_format == 0 && fmts.isNotEmpty && fmts.first is Map) {
        _format = ((fmts.first as Map)['id'] as num?)?.toInt() ?? 0;
      }
    });
    if (_parsed != null && _parsed!['needLogin'] == true) _login = false;
  }

  Future<void> _doAdd() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _adding = true);
    final j = await _post('/v1/bili/add', {'url': text, 'format': _format});
    if (!mounted) return;
    setState(() => _adding = false);
    if (j == null) {
      _toast(tr('提交失败：连不上后端'));
      return;
    }
    if (j['ok'] != true) {
      final msg = '${j['error'] ?? tr('提交失败')}';
      if (j['needLogin'] == true) {
        setState(() => _login = false);
        _toast(tr('还没登录 B 站，先扫码'));
      } else {
        _toast(msg);
      }
      return;
    }
    _toast('${tr('已加到下载队列')}：${j['title'] ?? ''}');
    setState(() {
      _parsed = null;
      _input.clear();
    });
    await _loadTasks();
    _startTaskPolling();
  }

  Future<void> _loadTasks() async {
    final j = await _get('/v1/bili/tasks');
    if (!mounted || j == null) return;
    final arr = (j['items'] ?? const []) as List;
    final list = <Map<String, dynamic>>[];
    for (final t in arr) {
      if (t is Map) list.add(Map<String, dynamic>.from(t));
    }
    setState(() => _tasks = list);
    final hasActive = list.any((t) =>
        t['status'] == 'running' || t['status'] == 'waiting');
    if (hasActive) {
      _startTaskPolling();
    } else {
      _taskTimer?.cancel();
      _taskTimer = null;
    }
  }

  void _startTaskPolling() {
    if (_taskTimer != null) return;
    _taskTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      final j = await _get('/v1/bili/tasks');
      if (!mounted || j == null) return;
      final arr = (j['items'] ?? const []) as List;
      final list = <Map<String, dynamic>>[];
      for (final tt in arr) {
        if (tt is Map) list.add(Map<String, dynamic>.from(tt));
      }
      setState(() => _tasks = list);
      final hasActive = list.any((x) =>
          x['status'] == 'running' || x['status'] == 'waiting');
      if (!hasActive) {
        t.cancel();
        _taskTimer = null;
      }
    });
  }

  Future<void> _del(Map<String, dynamic> t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('删除这个任务')),
        content: Text(tr('同时会把 NAS 上已下载的文件一起删掉')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('取消'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('删除'))),
        ],
      ),
    );
    if (ok != true) return;
    await _post('/v1/bili/del', {'id': t['id']});
    await _loadTasks();
  }

  Future<void> _logout() async {
    await _post('/v1/bili/logout', const {});
    setState(() {
      _login = false;
      _qrImage = '';
      _tasks = <Map<String, dynamic>>[];
    });
    await _newQr();
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  void _play(Map<String, dynamic> t) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _BiliPlayerPage(
        title: '${t['title'] ?? ''}',
        url: '$_base/v1/bili/play?id=${t['id']}',
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('B 站下载')),
        actions: [
          IconButton(
            tooltip: tr('刷新'),
            onPressed: () async {
              await _refreshStatus();
              await _loadTasks();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await _refreshStatus();
                await _loadTasks();
              },
              child: ListView(
                padding: const EdgeInsets.all(Gap.md),
                children: [
                  if (_base.isEmpty)
                    _warn(cs, tr('还没连上后端，请先到「我的后端」完成连接'))
                  else if (_err.isNotEmpty) _warn(cs, _err),
                  if (_base.isNotEmpty) ...[
                    _loginCard(cs),
                    const SizedBox(height: Gap.md),
                    if (_login) ...[
                      _inputCard(cs),
                      if (_parseErr.isNotEmpty) ...[
                        const SizedBox(height: Gap.sm),
                        _warn(cs, _parseErr),
                      ],
                      if (_parsed != null) ...[
                        const SizedBox(height: Gap.md),
                        _parsedCard(cs, _parsed!),
                      ],
                      const SizedBox(height: Gap.lg),
                      Row(children: [
                        Text(tr('下载任务'),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Text('${_tasks.length}',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant)),
                      ]),
                      const SizedBox(height: Gap.sm),
                      if (_tasks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(tr('还没有任务，上面粘一条链接试试'),
                                style: TextStyle(
                                    fontSize: 12, color: cs.onSurfaceVariant)),
                          ),
                        )
                      else
                        ..._tasks.map((t) => _taskCard(cs, t)),
                    ],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _warn(ColorScheme cs, String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.md),
        margin: const EdgeInsets.only(bottom: Gap.sm),
        decoration: BoxDecoration(
          color: cs.errorContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: TextStyle(fontSize: 12, color: cs.onErrorContainer)),
      );

  Widget _card(ColorScheme cs, List<Widget> children) => Card(
        elevation: 0,
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(padding: const EdgeInsets.all(Gap.md), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        )),
      );

  Widget _loginCard(ColorScheme cs) {
    if (_login) {
      return _card(cs, [
        Row(children: [
          Icon(Icons.verified_user, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(tr('已登录 B 站，可以下载了'),
                style: const TextStyle(fontSize: 13)),
          ),
          TextButton(onPressed: _logout, child: Text(tr('退出'))),
        ]),
      ]);
    }
    return _card(cs, [
      Row(children: [
        Icon(Icons.login, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(tr('第一步：扫码登录 B 站'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        TextButton(onPressed: _newQr, child: Text(tr('换一张'))),
      ]),
      const SizedBox(height: Gap.sm),
      if (_qrImage.isNotEmpty)
        Center(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Image.memory(
              _decodeQr(_qrImage),
              width: 200,
              height: 200,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => SizedBox(
                width: 200,
                height: 200,
                child: Center(child: Text(tr('二维码显示失败，点「换一张」'))),
              ),
            ),
          ),
        ),
      if (_qrHint.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Center(
          child: Text(_qrHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ),
      ],
    ]);
  }

  // Image.memory 要的是 Uint8List，不能给 List<int>（base64Decode 本身就返回 Uint8List）
  static final Uint8List _emptyBytes = Uint8List(0);
  Uint8List _decodeQr(String dataUrl) {
    try {
      final i = dataUrl.indexOf(',');
      if (i < 0) return _emptyBytes;
      return base64Decode(dataUrl.substring(i + 1));
    } catch (_) {
      return _emptyBytes;
    }
  }

  Widget _inputCard(ColorScheme cs) {
    return _card(cs, [
      Text(tr('第二步：粘贴 B 站链接'),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: Gap.sm),
      TextField(
        controller: _input,
        minLines: 2,
        maxLines: 4,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: tr('链接、分享出来的文字、或者 BV 号都行'),
          hintStyle: const TextStyle(fontSize: 12),
          filled: true,
          fillColor: cs.surface.withValues(alpha: 0.6),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          isDense: true,
        ),
      ),
      const SizedBox(height: Gap.sm),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _parsing ? null : _doParse,
            child: Text(_parsing ? tr('解析中') : tr('先看看是什么')),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: FilledButton(
            onPressed: _adding ? null : _doAdd,
            child: Text(_adding ? tr('提交中') : tr('下到 NAS')),
          ),
        ),
      ]),
    ]);
  }

  Widget _parsedCard(ColorScheme cs, Map<String, dynamic> p) {
    final cover = '${p['cover'] ?? ''}';
    final fmts = (p['formats'] ?? const []) as List;
    final dur = (p['duration'] as num?)?.toInt() ?? 0;
    final pages = (p['pages'] as List?) ?? const [];
    final meta = <String>[
      '${p['owner'] ?? ''}'.trim(),
      _fmtDur(dur),
      if (pages.length > 1) '${tr('共')} ${pages.length} ${tr('P')}',
    ].where((s) => s.isNotEmpty).join('  ·  ');
    return _card(cs, [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 96,
            height: 60,
            child: cover.isEmpty
                ? Container(color: cs.surfaceContainerHighest)
                : Image.network(
                    '$_base/v1/bili/cover?u=${Uri.encodeQueryComponent(cover)}',
                    headers: _h,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        Container(color: cs.surfaceContainerHighest),
                  ),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['title'] ?? ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(meta,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ]),
        ),
      ]),
      if (fmts.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Text(tr('清晰度'),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: fmts.map<Widget>((f) {
            if (f is! Map) return const SizedBox.shrink();
            final id = (f['id'] as num?)?.toInt() ?? 0;
            final label = '${f['label'] ?? id}';
            final sel = id == _format;
            return ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: 11)),
              selected: sel,
              onSelected: (_) => setState(() => _format = id),
            );
          }).toList(),
        ),
      ],
    ]);
  }

  Widget _taskCard(ColorScheme cs, Map<String, dynamic> t) {
    final status = '${t['status'] ?? ''}';
    final done = status == 'done';
    final running = status == 'running';
    final waiting = status == 'waiting';
    final err = status == 'error';
    final cover = '${t['cover'] ?? ''}';

    double prog = 0;
    if (running) {
      final a = (t['audioProgress'] as num?)?.toDouble() ?? 0;
      final v = (t['videoProgress'] as num?)?.toDouble() ?? 0;
      final m = (t['mergeProgress'] as num?)?.toDouble() ?? 0;
      if (m > 0) {
        prog = (a + v + m) / 3;
      } else if (v > 0 || a > 0) {
        prog = (v + a) / 2;
      }
    } else if (done) {
      prog = 1;
    }

    final statusText = done
        ? tr('已完成')
        : running
            ? '${tr('下载中')} ${(prog * 100).toStringAsFixed(0)}%'
            : waiting
                ? tr('排队中')
                : err
                    ? tr('失败')
                    : status;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: Gap.sm),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 88,
              height: 56,
              child: cover.isEmpty
                  ? Container(color: cs.surfaceContainerHighest)
                  : Image.network(
                      '$_base/v1/bili/cover?u=${Uri.encodeQueryComponent(cover)}',
                      headers: _h,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: cs.surfaceContainerHighest),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${t['title'] ?? ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: (done ? cs.primary : (err ? cs.error : cs.tertiary))
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(statusText,
                      style: TextStyle(
                          fontSize: 10,
                          color: done
                              ? cs.primary
                              : (err ? cs.error : cs.tertiary))),
                ),
                const SizedBox(width: 6),
                if ((t['format'] as num?) != null)
                  Text(_fmtLabel((t['format'] as num).toInt()),
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
              ]),
              if (running || waiting) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: running && prog > 0
                        ? prog.clamp(0.0, 1.0).toDouble()
                        : null,
                    minHeight: 4,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(children: [
                if (done)
                  TextButton.icon(
                    onPressed: () => _play(t),
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: Text(tr('播放'), style: const TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30)),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: tr('删除'),
                  onPressed: () => _del(t),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  String _fmtDur(int sec) {
    if (sec <= 0) return '';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 清晰度码 → 人话（与后端 FORMAT_LABEL 一致；后端已经给了 label，
  /// 这里只是任务列表里没有 label 字段时兜底）
  String _fmtLabel(int id) {
    const map = <int, String>{
      6: '240P', 16: '360P', 32: '480P', 64: '720P', 74: '720P60',
      80: '1080P', 112: '1080P+', 116: '1080P60', 120: '4K',
      125: 'HDR', 126: 'Dolby', 127: '8K',
    };
    return map[id] ?? '$id';
  }
}

/// 播放已下载的文件（后端 `/v1/bili/play?id=` 支持 Range，所以能拖动）
class _BiliPlayerPage extends StatefulWidget {
  final String title;
  final String url;
  const _BiliPlayerPage({required this.title, required this.url});
  @override
  State<_BiliPlayerPage> createState() => _BiliPlayerPageState();
}

class _BiliPlayerPageState extends State<_BiliPlayerPage> {
  VideoPlayerController? _vp;
  ChewieController? _chewie;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final tok = (p.getString('token') ?? '').trim();
      _vp = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
        httpHeaders: tok.isEmpty ? const {} : {'x-th-token': tok},
      );
      await _vp!.initialize();
      _chewie = ChewieController(
        videoPlayerController: _vp!,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: Theme.of(context).colorScheme.primary,
          handleColor: Theme.of(context).colorScheme.primary,
        ),
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('播放失败')}: $e');
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _vp?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      backgroundColor: Colors.black,
      body: Center(
        child: _err.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_err, style: const TextStyle(color: Colors.white70)),
              )
            : (_chewie == null
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio: _vp!.value.aspectRatio == 0
                        ? 16 / 9
                        : _vp!.value.aspectRatio,
                    child: Chewie(controller: _chewie!),
                  )),
      ),
    );
  }
}
