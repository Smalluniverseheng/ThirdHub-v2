// 小模块做实第十一批: 共享相册(本地相册浏览) / 摄像头(网络摄像机) / 设备互联(局域网扫描)
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

// ═══ 共享相册: 选照片文件夹 → 网格浏览 + 幻灯片 (云端共享待资源库接口) ═══
class SharedAlbumPage extends StatefulWidget { const SharedAlbumPage({super.key}); @override State<SharedAlbumPage> createState() => _Sa(); }
class _Sa extends State<SharedAlbumPage> {
  List<FileSystemEntity> photos = [];
  bool scanning = false;

  Future<void> _pickDir() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    setState(() => scanning = true);
    await Future.delayed(const Duration(milliseconds: 50));
    final out = <FileSystemEntity>[];
    void walk(Directory dir, int depth) {
      if (depth > 3) return;
      try {
        for (final f in dir.listSync()) {
          final p = f.path.toLowerCase();
          if (f is File && (p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.png') || p.endsWith('.webp'))) out.add(f);
          if (f is Directory && !f.path.split('/').last.startsWith('.')) walk(f, depth + 1);
        }
      } catch (_) {}
    }
    walk(Directory(d), 0);
    out.sort((a, b) => b.path.compareTo(a.path)); // 新文件在前(按路径时间戳习惯)
    setState(() { photos = out; scanning = false; });
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.folder_open, size: 18),
        label: Text(photos.isEmpty ? '选择照片文件夹(自动递归扫描)' : '重新选择 (已找到 ${photos.length} 张)'),
        onPressed: scanning ? null : _pickDir))),
    if (scanning) const LinearProgressIndicator(),
    Expanded(child: photos.isEmpty
      ? Center(child: Text(scanning ? '扫描中…' : '选一个照片文件夹\n长按缩略图可删除 · 云端家庭共享待资源库接口开放',
          textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)))
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 3, crossAxisSpacing: 3),
        padding: const EdgeInsets.all(8),
        itemCount: photos.length,
        itemBuilder: (_, i) => InkWell(
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => _AlbumViewer(photos: photos, start: i))),
          onLongPress: () => setState(() { try { File(photos[i].path).deleteSync(); } catch (_) {} photos.removeAt(i); }),
          child: Image.file(File(photos[i].path), fit: BoxFit.cover,
            cacheWidth: 300, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined))))),
  ]);
}

class _AlbumViewer extends StatefulWidget {
  final List<FileSystemEntity> photos; final int start;
  const _AlbumViewer({required this.photos, required this.start});
  @override State<_AlbumViewer> createState() => _AlbumViewerState();
}
class _AlbumViewerState extends State<_AlbumViewer> {
  late final PageController pc = PageController(initialPage: widget.start);
  late int idx = widget.start;
  bool playing = false;

  Future<void> _slideshow() async {
    setState(() => playing = true);
    while (playing && mounted) {
      await Future.delayed(const Duration(seconds: 3));
      if (!playing || !mounted) break;
      final next = (idx + 1) % widget.photos.length;
      pc.animateToPage(next, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
  }

  @override void dispose() { playing = false; pc.dispose(); super.dispose(); }

  @override Widget build(BuildContext c) => Scaffold(backgroundColor: Colors.black,
    appBar: AppBar(backgroundColor: Colors.transparent,
      title: Text('${idx + 1} / ${widget.photos.length}', style: const TextStyle(fontSize: 13)),
      actions: [IconButton(icon: Icon(playing ? Icons.stop : Icons.slideshow, size: 20),
        onPressed: () => playing ? setState(() => playing = false) : _slideshow())]),
    body: PageView.builder(controller: pc, itemCount: widget.photos.length,
      onPageChanged: (i) => setState(() => idx = i),
      itemBuilder: (_, i) => InteractiveViewer(
        child: Center(child: Image.file(File(widget.photos[i].path),
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.grey))))));
}

// ═══ 摄像头: 添加网络摄像机地址(http/rtsp) → 点击看实时画面 ═══
class CameraPage extends StatefulWidget { const CameraPage({super.key}); @override State<CameraPage> createState() => _Cam(); }
class _Cam extends State<CameraPage> {
  static const _key = 'ip_cameras';
  List<Map<String, String>> cams = [];

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw != null) setState(() => cams = [for (final e in jsonDecode(raw)) Map<String, String>.from(e)]);
  }
  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(cams));
  }

  void _add() {
    final nc = TextEditingController();
    final uc = TextEditingController();
    showDialog(context: context, builder: (d) => AlertDialog(
      title: const Text('添加摄像头', style: TextStyle(fontSize: 15)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nc, autofocus: true, decoration: const InputDecoration(hintText: '名字, 如: 客厅', isDense: true)),
        const SizedBox(height: 8),
        TextField(controller: uc, decoration: const InputDecoration(
          hintText: '流地址 http(s)://… 或 rtsp://…', isDense: true)),
        const Padding(padding: EdgeInsets.only(top: 8),
          child: Text('常见格式: http://摄像头IP/视频流地址\n(rtsp 需播放器内核支持, 推荐 http/mjpeg)',
            style: TextStyle(fontSize: 10, color: Colors.grey))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        FilledButton(onPressed: () {
          if (nc.text.trim().isNotEmpty && uc.text.trim().isNotEmpty) {
            setState(() => cams.add({'name': nc.text.trim(), 'url': uc.text.trim()}));
            _save();
          }
          Navigator.pop(d);
        }, child: const Text('添加')),
      ])).then((_) { nc.dispose(); uc.dispose(); });
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.add_a_photo_outlined, size: 18),
        label: const Text('添加网络摄像头'), onPressed: _add))),
    Expanded(child: cams.isEmpty
      ? const Center(child: Text('添加家里网络摄像头的流地址\n(同一局域网内的 http/mjpeg 摄像头)',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : GridView.builder(gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, childAspectRatio: 1.5, mainAxisSpacing: 6, crossAxisSpacing: 6),
        padding: const EdgeInsets.all(10),
        itemCount: cams.length,
        itemBuilder: (_, i) => InkWell(
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => _CamView(cam: cams[i]))),
          onLongPress: () => setState(() { cams.removeAt(i); _save(); }),
          child: Card(margin: EdgeInsets.zero, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.videocam_outlined, size: 28),
            const SizedBox(height: 6),
            Text(cams[i]['name']!, style: const TextStyle(fontSize: 12)),
            Text(cams[i]['url']!, style: const TextStyle(fontSize: 9, color: Colors.grey),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ]))))),
  ]);
}

class _CamView extends StatefulWidget {
  final Map<String, String> cam;
  const _CamView({required this.cam});
  @override State<_CamView> createState() => _CamViewState();
}
class _CamViewState extends State<_CamView> {
  VideoPlayerController? ctl;
  String err = '';
  @override void initState() {
    super.initState();
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.cam['url']!));
    c.initialize().then((_) { c.play(); c.setLooping(true); if (mounted) setState(() => ctl = c); })
      .catchError((e) { if (mounted) setState(() => err = '打不开这个流地址: $e'); });
  }
  @override void dispose() { ctl?.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) => Scaffold(backgroundColor: Colors.black,
    appBar: AppBar(backgroundColor: Colors.transparent, title: Text(widget.cam['name']!, style: const TextStyle(fontSize: 14))),
    body: Center(child: err.isNotEmpty
      ? Padding(padding: const EdgeInsets.all(24),
          child: Text(err, style: const TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center))
      : ctl != null && ctl!.value.isInitialized
        ? AspectRatio(aspectRatio: ctl!.value.aspectRatio, child: VideoPlayer(ctl!))
        : const Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('连接中…', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ])));
}

// ═══ 设备互联: 扫描局域网在线设备 ═══
class DeviceLinkPage extends StatefulWidget { const DeviceLinkPage({super.key}); @override State<DeviceLinkPage> createState() => _Dl(); }
class _Dl extends State<DeviceLinkPage> {
  List<String> found = [];
  bool scanning = false;
  int progress = 0;

  Future<void> _scan() async {
    setState(() { scanning = true; found = []; progress = 0; });
    String prefix = '192.168.1';
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          if (!a.isLoopback && !a.address.startsWith('169.254')) {
            final parts = a.address.split('.');
            prefix = parts.take(3).join('.');
          }
        }
      }
    } catch (_) {}
    // 254 个地址, 每批 40 并发, 探测常见端口
    const ports = [80, 443, 445, 22, 8080, 18777];
    for (var base = 1; base < 255; base += 40) {
      if (!scanning) break;
      final futures = <Future<void>>[];
      for (var i = base; i < base + 40 && i < 255; i++) {
        final ip = '$prefix.$i';
        futures.add(Future(() async {
          for (final port in ports) {
            try {
              final s = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 400));
              s.destroy();
              found.add('$ip:$port');
              break;
            } catch (_) {}
          }
        }));
      }
      await Future.wait(futures);
      if (mounted) setState(() => progress = (base + 39).clamp(0, 254));
    }
    if (mounted) setState(() => scanning = false);
  }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.radar, size: 18),
        label: Text(scanning ? '扫描中 $progress/254…' : '扫描局域网设备'),
        onPressed: scanning ? () => setState(() => scanning = false) : _scan))),
    if (scanning) LinearProgressIndicator(value: progress / 254),
    Expanded(child: found.isEmpty
      ? Center(child: Text(scanning ? '正在探测常见端口(80/443/445/22/8080)…' : '点上方扫描同一 Wi-Fi 下的在线设备\n找到的设备可以直接互传文件/看摄像头',
          textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: found.length, itemBuilder: (_, i) {
          final dev = found[i];
          final ip = dev.split(':')[0];
          final port = dev.split(':')[1];
          final kind = {'80': '网页服务', '443': '网页服务', '445': 'Windows 共享', '22': 'Linux/SSH', '8080': 'Web 服务', '18777': 'ThirdHub 互传'}[port] ?? '设备';
          return ListTile(dense: true,
            leading: const Icon(Icons.devices_outlined, size: 20),
            title: Text(ip, style: const TextStyle(fontSize: 13)),
            subtitle: Text('$kind (端口 $port)', style: const TextStyle(fontSize: 10, color: Colors.grey)),
            trailing: port == '80' || port == '8080'
              ? IconButton(icon: const Icon(Icons.open_in_new, size: 16), onPressed: () {})
              : null);
        })),
  ]);
}
