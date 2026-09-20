// 小模块做实第八批: 扫描仪 / 有声书(本地) / 短剧(本地) / 文件互传(局域网HTTP共享)
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'play_tag.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';

// ═══ 扫描仪: 拍照/选图 → 灰度增强 → 保存 ═══
class ScannerPage extends StatefulWidget { const ScannerPage({super.key}); @override State<ScannerPage> createState() => _Scan(); }
class _Scan extends State<ScannerPage> {
  final List<String> pages = []; // 处理后的图片路径
  bool busy = false;
  final _picker = ImagePicker();

  Future<Directory> _dir() async {
    final ext = await getExternalStorageDirectory();
    final d = Directory('${ext!.path}/scans');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _capture(ImageSource src) async {
    try {
      final x = await _picker.pickImage(source: src, maxWidth: 2400);
      if (x == null) return;
      setState(() => busy = true);
      // 文档增强: 灰度 + 提高对比度
      final bytes = await x.readAsBytes();
      var im = img.decodeImage(bytes);
      if (im == null) throw Exception('图片解码失败');
      im = img.grayscale(im);
      im = img.contrast(im, contrast: 1.35);
      final d = await _dir();
      final f = File('${d.path}/scan-${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(img.encodePng(im));
      setState(() => pages.add(f.path));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败: $e')));
    }
    if (mounted) setState(() => busy = false);
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: Row(children: [
      Expanded(child: FilledButton.icon(icon: const Icon(Icons.camera_alt_outlined, size: 18),
        label: const Text('拍照扫描'), onPressed: busy ? null : () => _capture(ImageSource.camera))),
      const SizedBox(width: 8),
      Expanded(child: FilledButton.tonalIcon(icon: const Icon(Icons.photo_library_outlined, size: 18),
        label: const Text('从相册选'), onPressed: busy ? null : () => _capture(ImageSource.gallery))),
    ])),
    const Padding(padding: EdgeInsets.only(bottom: 6),
      child: Text('自动灰度+对比度增强(文档效果) · OCR 文字识别后续接入', style: TextStyle(fontSize: 10, color: Colors.grey))),
    Expanded(child: pages.isEmpty
      ? const Center(child: Text('还没有扫描件', style: TextStyle(color: Colors.grey)))
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
        padding: const EdgeInsets.all(10),
        itemCount: pages.length,
        itemBuilder: (_, i) => InkWell(
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.transparent),
            body: Center(child: InteractiveViewer(child: Image.file(File(pages[i]))))))),
          onLongPress: () => setState(() { try { File(pages[i]).deleteSync(); } catch (_) {} pages.removeAt(i); }),
          child: ClipRRect(borderRadius: BorderRadius.circular(6),
            child: Image.file(File(pages[i]), fit: BoxFit.cover))))),
  ]);
}

// ═══ 有声书: 选本地音频文件夹 → 分集连播 ═══
class AudiobookPage extends StatefulWidget { const AudiobookPage({super.key}); @override State<AudiobookPage> createState() => _Ab(); }
class _Ab extends State<AudiobookPage> {
  final _player = AudioPlayer();
  List<FileSystemEntity> files = [];
  String dirPath = '';
  String? playing;
  Duration pos = Duration.zero, dur = Duration.zero;

  @override void dispose() { _player.dispose(); super.dispose(); }

  Future<void> _pickDir() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    final list = Directory(d).listSync().where((f) =>
      f.path.toLowerCase().endsWith('.mp3') || f.path.toLowerCase().endsWith('.m4a') ||
      f.path.toLowerCase().endsWith('.flac') || f.path.toLowerCase().endsWith('.ogg') ||
      f.path.toLowerCase().endsWith('.wav')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    setState(() { dirPath = d; files = list; });
  }

  Future<void> _play(String path) async {
    if (playing == path) { await _player.stop(); setState(() => playing = null); return; }
    await _player.setAudioSource(tagFile(path, title: path.split('/').last, album: 'ThirdHub 音乐'));
    dur = await _player.durationFuture ?? Duration.zero;
    setState(() => playing = path);
    _player.positionStream.listen((p) { if (mounted) setState(() => pos = p); });
    await _player.play();
    _player.playerStateStream.firstWhere((s) => s.processingState == ProcessingState.completed).then((_) {
      // 自动连播下一集
      final i = files.indexWhere((f) => f.path == path);
      if (i >= 0 && i + 1 < files.length) _play(files[i + 1].path);
      else if (mounted) setState(() => playing = null);
    });
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.folder_open, size: 18),
        label: const Text('选择有声书文件夹(mp3/m4a/flac)'), onPressed: _pickDir))),
    if (dirPath.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Text(dirPath, style: const TextStyle(fontSize: 10, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis)),
    if (playing != null) Container(color: Theme.of(c).colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(playing!.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          SizedBox(height: 18, child: Slider(value: dur.inSeconds > 0 ? (pos.inSeconds / dur.inSeconds).clamp(0.0, 1.0) : 0,
            onChanged: (v) => _player.seek(Duration(seconds: (v * dur.inSeconds).round())))),
        ])),
        Text('${pos.inMinutes}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}/${dur.inMinutes}:${(dur.inSeconds % 60).toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 10)),
      ])),
    Expanded(child: files.isEmpty
      ? const Center(child: Text('选一个装有声书的文件夹\n里面的音频会按文件名排序连播', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: files.length, itemBuilder: (_, i) {
          final f = files[i];
          final on = playing == f.path;
          return ListTile(dense: true,
            leading: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            title: Text(f.path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: on ? Theme.of(c).colorScheme.primary : null)),
            trailing: Icon(on ? Icons.stop_circle : Icons.play_circle_outline, size: 22,
              color: on ? Theme.of(c).colorScheme.primary : null),
            onTap: () => _play(f.path));
        })),
  ]);
}

// ═══ 短剧: 选本地视频文件夹 → 竖屏连播 ═══
class ShortPlayPage extends StatefulWidget { const ShortPlayPage({super.key}); @override State<ShortPlayPage> createState() => _Sp(); }
class _Sp extends State<ShortPlayPage> {
  List<FileSystemEntity> files = [];
  String dirPath = '';

  Future<void> _pickDir() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    final list = Directory(d).listSync().where((f) =>
      f.path.toLowerCase().endsWith('.mp4') || f.path.toLowerCase().endsWith('.mkv') ||
      f.path.toLowerCase().endsWith('.webm')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    setState(() { dirPath = d; files = list; });
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.folder_open, size: 18),
        label: const Text('选择短剧文件夹(mp4)'), onPressed: _pickDir))),
    Expanded(child: files.isEmpty
      ? const Center(child: Text('选一个装短剧的文件夹\n按文件名排序, 点集数竖屏连播', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 1.4),
        padding: const EdgeInsets.all(10),
        itemCount: files.length,
        itemBuilder: (_, i) => InkWell(
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => _ShortPlayer(files: files, start: i))),
          child: Card(margin: EdgeInsets.zero, child: Center(child: Text('第 ${i + 1} 集', style: const TextStyle(fontSize: 13))))))),
  ]);
}

class _ShortPlayer extends StatefulWidget {
  final List<FileSystemEntity> files; final int start;
  const _ShortPlayer({required this.files, required this.start});
  @override State<_ShortPlayer> createState() => _ShortPlayerState();
}
class _ShortPlayerState extends State<_ShortPlayer> {
  late int idx = widget.start;
  VideoPlayerController? ctl;
  @override void initState() { super.initState(); _load(idx); }
  Future<void> _load(int i) async {
    await ctl?.dispose();
    final nc = VideoPlayerController.file(File(widget.files[i].path));
    await nc.initialize();
    await nc.play();
    nc.addListener(() {
      if (nc.value.position >= nc.value.duration && nc.value.duration > Duration.zero) {
        if (i + 1 < widget.files.length) { idx = i + 1; _load(idx); } // 自动下一集
      }
    });
    setState(() => ctl = nc);
  }
  @override void dispose() { ctl?.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) => Scaffold(backgroundColor: Colors.black,
    body: GestureDetector(onTap: () => setState(() { ctl!.value.isPlaying ? ctl!.pause() : ctl!.play(); }),
      child: Stack(children: [
        Center(child: ctl != null && ctl!.value.isInitialized
          ? AspectRatio(aspectRatio: ctl!.value.aspectRatio, child: VideoPlayer(ctl!))
          : const CircularProgressIndicator()),
        Positioned(top: 30, left: 8, child: SafeArea(child: Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(c)),
          Text('第 ${idx + 1} 集 / 共 ${widget.files.length} 集', style: const TextStyle(color: Colors.white, fontSize: 13)),
        ]))),
        Positioned(bottom: 20, left: 0, right: 0, child: ctl == null ? const SizedBox() : SafeArea(child:
          VideoProgressIndicator(ctl!, allowScrubbing: true, padding: const EdgeInsets.symmetric(horizontal: 16)))),
      ])));
}

// ═══ 文件互传: 起局域网 HTTP 服务, 扫码/链接即下载 ═══
class FileSharePage extends StatefulWidget { const FileSharePage({super.key}); @override State<FileSharePage> createState() => _Fs(); }
class _Fs extends State<FileSharePage> {
  HttpServer? server;
  String shareUrl = '';
  String fileName = '';
  int downloads = 0;

  @override void dispose() { server?.close(force: true); super.dispose(); }

  /// 挑一个对方真能连上来的本机地址，用于拼分享链接/二维码。
  ///
  /// ★旧实现只枚举 IPv4、失败就回退 127.0.0.1 —— 在 **IPv6 单栈网络**
  ///   （运营商 IPv6-only、部分 5G / 校园网 / 部分企业 WiFi）上，服务明明起来了，
  ///   二维码里却写着 127.0.0.1，对方**永远连不上而且界面不报任何错**。
  ///   现在：优先私有 IPv4（同局域网最稳）→ 次选全局 IPv6（带回方括号）→ 最后才回环。
  Future<String> _localIp() async {
    String? v4, v6;
    try {
      final ifaces = await NetworkInterface.list(
          includeLoopback: false, includeLinkLocal: false, type: InternetAddressType.any);
      for (final ni in ifaces) {
        for (final a in ni.addresses) {
          final s = a.address;
          if (a.type == InternetAddressType.IPv4) {
            if (s.startsWith('169.254')) continue;          // 链路本地，跨设备不可路由
            final p = s.split('.');
            final a0 = int.tryParse(p.isNotEmpty ? p[0] : '') ?? -1;
            final a1 = int.tryParse(p.length > 1 ? p[1] : '') ?? -1;
            final priv = a0 == 10 || (a0 == 192 && a1 == 168) || (a0 == 172 && a1 >= 16 && a1 <= 31);
            if (priv) { v4 = s; }                            // 私网地址优先，找到即可定
            v4 ??= s;
          } else if (a.type == InternetAddressType.IPv6) {
            if (s.startsWith('fe80')) continue;              // 链路本地，跨设备不可达
            v6 ??= '[$s]';                                    // URL 中的 IPv6 必须带方括号
          }
        }
      }
    } catch (_) {}
    return v4 ?? v6 ?? '127.0.0.1';
  }

  Future<void> _share() async {
    final res = await FilePicker.platform.pickFiles();
    if (res == null || res.files.isEmpty || res.files.first.path == null) return;
    final file = File(res.files.first.path!);
    await server?.close(force: true);
    final ip = await _localIp();
    // ★双栈绑定：IPv6 socket 开 v6Only:false 时也收 IPv4 映射连接，
    //   IPv4-only 与 IPv6-only 两种对方都能连；平台不支持双栈时退回纯 IPv4。
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv6, 18777, v6Only: false);
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 18777);
    }
    setState(() { fileName = res.files.first.name; downloads = 0; shareUrl = 'http://$ip:18777/$fileName'; });
    server!.listen((req) async {
      if (req.uri.path == '/' || req.uri.path == '/$fileName') {
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.add('Content-Disposition', 'attachment; filename="${Uri.encodeComponent(fileName)}"');
        req.response.headers.contentLength = await file.length();
        await req.response.addStream(file.openRead());
        await req.response.close();
        if (mounted) setState(() => downloads++);
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  }

  Future<void> _stop() async {
    await server?.close(force: true);
    setState(() { server = null; shareUrl = ''; });
  }

  @override Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(14), children: [
    const Card(child: Padding(padding: EdgeInsets.all(12),
      child: Text('手机↔电脑/另一台手机 同局域网秒传: 选文件 → 对方扫码或开链接即下载, 不过任何服务器。',
        style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.6)))),
    const SizedBox(height: 8),
    if (server == null)
      FilledButton.icon(icon: const Icon(Icons.share, size: 18), label: const Text('选择文件并开始共享'), onPressed: _share)
    else ...[
      Center(child: Card(color: Colors.white, child: Padding(padding: const EdgeInsets.all(14),
        child: QrImageView(data: shareUrl, size: 200)))),
      const SizedBox(height: 8),
      Card(child: ListTile(
        title: Text(fileName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        subtitle: Text(shareUrl, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        trailing: IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () {
          Clipboard.setData(ClipboardData(text: shareUrl));
          ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('链接已复制'))); }))),
      Padding(padding: const EdgeInsets.all(8),
        child: Text('已被下载 $downloads 次 · 共享中, 离开本页面前请先停止', textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.teal))),
      FilledButton.tonalIcon(icon: const Icon(Icons.stop, size: 18), label: const Text('停止共享'), onPressed: _stop),
    ],
  ]);
}
