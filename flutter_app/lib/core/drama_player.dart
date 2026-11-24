// 红果短剧播放器（4.81.94）——media_kit 播 CENC-AES-CTR 加密 MP4。
//
// 加密分集的播放地址是标准 MP4，但 sample 用 AES-128-CTR 加密（cenc-aes-ctr）。
// mpv（media_kit 底层）通过 demuxer-lavf-o 的 decryption_key 选项原生解密：
//   command(['set','demuxer-lavf-o','decryption_key=<32位hex>'])
// contentKey.key 就是 openhongguo SDK 从播放模型推导出的 16 字节 AES key。
// 非加密分集直接 Media(url) 播放。带独立音轨的（DASH 长片）用 audio-add 外挂。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'design_tokens.dart';
import 'i18n.dart';

class DramaPlayerPage extends StatefulWidget {
  const DramaPlayerPage({
    super.key,
    required this.url,
    this.audioUrl = '',
    this.decryptionKey = '',
    required this.title,
    this.onNext,
    this.onPrev,
  });

  final String url;
  final String audioUrl;
  final String decryptionKey; // 32 位 hex，空=未加密
  final String title;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;

  @override
  State<DramaPlayerPage> createState() => _DramaPlayerPageState();
}

class _DramaPlayerPageState extends State<DramaPlayerPage> {
  late final Player _player;
  late final VideoController _vc;
  StreamSubscription? _posSub;
  bool _ready = false;
  String _err = '';
  bool _ctrl = true;
  bool _fs = false;
  Timer? _hideTimer;
  double _pos = 0, _dur = 0;
  bool _playing = false;
  double _rate = 1.0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      MediaKit.ensureInitialized();
      _player = Player(
        configuration: PlayerConfiguration(
          title: widget.title,
          protocolWhitelist: const ['https', 'http', 'tcp', 'tls', 'data'],
        ),
      );
      _vc = VideoController(_player);
      _posSub = _player.stream.position.listen((p) {
        _pos = p.inMilliseconds / 1000.0;
        if (mounted) setState(() {});
      });
      _player.stream.duration
          .listen((d) => _dur = d.inMilliseconds / 1000.0);
      _player.stream.playing.listen((v) {
        _playing = v;
        if (mounted) setState(() {});
      });

      final plat = _player.platform;
      if (plat is NativePlayer && widget.decryptionKey.isNotEmpty) {
        // ★CENC 解密：mpv 的 mov demuxer 支持 decryption_key（AES-128-CTR）
        await plat.command([
          'set',
          'demuxer-lavf-o',
          'decryption_key=${widget.decryptionKey}'
        ]);
      }
      await _player.open(Media(widget.url), play: false);
      if (widget.audioUrl.isNotEmpty && plat is NativePlayer) {
        await plat.command(['audio-add', widget.audioUrl, 'external', 'hg-audio']);
      }
      if (!mounted) return;
      setState(() => _ready = true);
      await _player.play();
    } catch (e) {
      if (mounted) setState(() => _err = '${tr('播放失败')}：$e');
    }
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (!_ctrl || !_playing) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _ctrl = false);
    });
  }

  Future<void> _toggleFullscreen() async {
    final on = !_fs;
    setState(() => _fs = on);
    if (on) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _hideTimer?.cancel();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _err.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(_err, style: const TextStyle(color: Colors.white70)),
              ),
            )
          : !_ready
              ? const Center(child: CircularProgressIndicator())
              : GestureDetector(
                  onTap: () {
                    setState(() => _ctrl = !_ctrl);
                    _armHide();
                  },
                  onDoubleTap: () => _player.playOrPause(),
                  child: Stack(children: [
                    Positioned.fill(
                      child: Video(
                        controller: _vc,
                        fit: BoxFit.contain,
                        controls: (state) => const SizedBox.shrink(),
                      ),
                    ),
                    if (_ctrl) _topBar(),
                    if (_ctrl) _bottomBar(),
                  ]),
                ),
    );
  }

  Widget _topBar() => Positioned(
        top: 0, left: 0, right: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Colors.transparent],
            ),
          ),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
            if (widget.decryptionKey.isNotEmpty)
              const Icon(Icons.lock_outline, color: Colors.white70, size: 16),
          ]),
        ),
      );

  Widget _bottomBar() => Positioned(
        left: 0, right: 0, bottom: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xE6000000), Colors.transparent],
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(_fmt(_pos), style: const TextStyle(color: Colors.white70, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _dur > 0 ? _pos.clamp(0, _dur) : 0,
                  max: _dur > 0 ? _dur : 1,
                  onChanged: (v) => _player.seek(
                    Duration(milliseconds: (v * 1000).round()),
                  ),
                ),
              ),
              Text(_fmt(_dur), style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
            Row(children: [
              if (widget.onPrev != null)
                IconButton(
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                  onPressed: widget.onPrev,
                ),
              IconButton(
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
                onPressed: () => _player.playOrPause(),
              ),
              if (widget.onNext != null)
                IconButton(
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  onPressed: widget.onNext,
                ),
              TextButton(
                onPressed: () async {
                  final v = await showMenu<double>(
                    context: context,
                    position: RelativeRect.fromLTRB(80, 200, 200, 300),
                    items: [0.75, 1.0, 1.25, 1.5, 2.0]
                        .map((r) => PopupMenuItem<double>(value: r, child: Text('${r}x')))
                        .toList(),
                  );
                  if (v != null) {
                    setState(() => _rate = v);
                    await _player.setRate(v);
                  }
                },
                child: Text('${_rate}x', style: const TextStyle(color: Colors.white)),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.fullscreen, color: Colors.white),
                onPressed: _toggleFullscreen,
              ),
            ]),
          ]),
        ),
      );

  String _fmt(double s) {
    final t = s.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }
}
