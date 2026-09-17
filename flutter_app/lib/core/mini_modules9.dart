// 小模块做实第九批: 家庭影院(本地视频库) / 家庭音乐库(本地音乐库)
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';

const _vidExts = ['.mp4', '.mkv', '.webm', '.avi', '.mov', '.flv', '.ts'];
const _audExts = ['.mp3', '.m4a', '.flac', '.ogg', '.wav', '.aac'];

List<FileSystemEntity> _scanMedia(String dir, List<String> exts) {
  final out = <FileSystemEntity>[];
  void walk(Directory d, int depth) {
    if (depth > 3) return;
    try {
      for (final f in d.listSync()) {
        if (f is File && exts.any((e) => f.path.toLowerCase().endsWith(e))) out.add(f);
        if (f is Directory && !f.path.split('/').last.startsWith('.')) walk(f, depth + 1);
      }
    } catch (_) {}
  }
  walk(Directory(dir), 0);
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

// ═══ 家庭影院 ═══
class HomeCinemaPage extends StatefulWidget { const HomeCinemaPage({super.key}); @override State<HomeCinemaPage> createState() => _Hc(); }
class _Hc extends State<HomeCinemaPage> {
  List<FileSystemEntity> videos = [];
  String dirPath = '';
  bool scanning = false;

  Future<void> _pickDir() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    setState(() { scanning = true; dirPath = d; });
    await Future.delayed(const Duration(milliseconds: 50));
    final list = _scanMedia(d, _vidExts);
    setState(() { videos = list; scanning = false; });
  }

  String _size(File f) { try { final mb = f.lengthSync() / 1048576; return mb > 1024 ? '${(mb / 1024).toStringAsFixed(1)}GB' : '${mb.toStringAsFixed(0)}MB'; } catch (_) { return ''; } }

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.folder_open, size: 18),
        label: Text(videos.isEmpty ? '选择影片文件夹(自动递归扫描)' : '重新选择 (已找到 ${videos.length} 部)'),
        onPressed: scanning ? null : _pickDir))),
    if (scanning) const LinearProgressIndicator(),
    Expanded(child: videos.isEmpty
      ? Center(child: Text(scanning ? '扫描中…' : '选一个装电影的文件夹\n会自动往下翻 3 层子目录', textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: videos.length, itemBuilder: (_, i) {
          final f = videos[i];
          final name = f.path.split('/').last;
          return ListTile(dense: true,
            leading: const Icon(Icons.movie_outlined, size: 20),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Text(_size(File(f.path)), style: const TextStyle(fontSize: 10, color: Colors.grey)),
            trailing: const Icon(Icons.play_circle_outline, size: 20),
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => _CinemaPlayer(files: videos, start: i))));
        })),
  ]);
}

class _CinemaPlayer extends StatefulWidget {
  final List<FileSystemEntity> files; final int start;
  const _CinemaPlayer({required this.files, required this.start});
  @override State<_CinemaPlayer> createState() => _CinemaPlayerState();
}
class _CinemaPlayerState extends State<_CinemaPlayer> {
  late int idx = widget.start;
  VideoPlayerController? ctl;
  bool showUi = true;
  @override void initState() { super.initState(); _load(idx); }
  Future<void> _load(int i) async {
    await ctl?.dispose();
    final nc = VideoPlayerController.file(File(widget.files[i].path));
    await nc.initialize();
    await nc.play();
    nc.addListener(() {
      if (nc.value.position >= nc.value.duration && nc.value.duration > Duration.zero && i + 1 < widget.files.length) {
        idx = i + 1; _load(idx);
      }
      if (mounted) setState(() {});
    });
    setState(() => ctl = nc);
  }
  @override void dispose() { ctl?.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) => Scaffold(backgroundColor: Colors.black,
    body: GestureDetector(onTap: () {
      if (!showUi) { setState(() => showUi = true); return; }
      ctl!.value.isPlaying ? ctl!.pause() : ctl!.play();
    }, child: Stack(children: [
      Center(child: ctl != null && ctl!.value.isInitialized
        ? AspectRatio(aspectRatio: ctl!.value.aspectRatio, child: VideoPlayer(ctl!))
        : const CircularProgressIndicator()),
      if (showUi) Positioned(top: 30, left: 8, right: 8, child: SafeArea(child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(c)),
        Expanded(child: Text(widget.files[idx].path.split('/').last,
          style: const TextStyle(color: Colors.white, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(icon: const Icon(Icons.skip_next, color: Colors.white),
          onPressed: idx + 1 < widget.files.length ? () { idx++; _load(idx); } : null),
      ]))),
      Positioned(bottom: 16, left: 0, right: 0, child: ctl == null ? const SizedBox() : SafeArea(child:
        VideoProgressIndicator(ctl!, allowScrubbing: true, padding: const EdgeInsets.symmetric(horizontal: 16)))),
    ])));
}

// ═══ 家庭音乐库 ═══
class HomeMusicPage extends StatefulWidget { const HomeMusicPage({super.key}); @override State<HomeMusicPage> createState() => _Hm(); }
class _Hm extends State<HomeMusicPage> {
  final _player = AudioPlayer();
  List<FileSystemEntity> songs = [];
  String? playing;
  int playIdx = -1;
  Duration pos = Duration.zero, dur = Duration.zero;
  bool shuffle = false;
  final _rng = Random();

  @override void dispose() { _player.dispose(); super.dispose(); }

  Future<void> _pickDir() async {
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    setState(() => songs = _scanMedia(d, _audExts));
  }

  Future<void> _play(int i) async {
    if (i < 0 || i >= songs.length) return;
    playIdx = i;
    final path = songs[i].path;
    await _player.setFilePath(path);
    dur = await _player.durationFuture ?? Duration.zero;
    setState(() => playing = path);
    _player.positionStream.listen((p) { if (mounted) setState(() => pos = p); });
    await _player.play();
    _player.playerStateStream.firstWhere((s) => s.processingState == ProcessingState.completed).then((_) => _next());
  }

  void _next() {
    if (songs.isEmpty) return;
    _play(shuffle ? _rng.nextInt(songs.length) : (playIdx + 1) % songs.length);
  }
  void _prev() => _play(playIdx > 0 ? playIdx - 1 : songs.length - 1);

  @override Widget build(BuildContext c) => Column(children: [
    Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
      child: FilledButton.icon(icon: const Icon(Icons.folder_open, size: 18),
        label: Text(songs.isEmpty ? '选择音乐文件夹(自动递归扫描)' : '重新选择 (已找到 ${songs.length} 首)'),
        onPressed: _pickDir))),
    if (playing != null) Container(color: Theme.of(c).colorScheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Column(children: [
        Text(playing!.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        SizedBox(height: 18, child: Slider(value: dur.inSeconds > 0 ? (pos.inSeconds / dur.inSeconds).clamp(0.0, 1.0) : 0,
          onChanged: (v) => _player.seek(Duration(seconds: (v * dur.inSeconds).round())))),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(icon: Icon(Icons.shuffle, size: 20, color: shuffle ? Theme.of(c).colorScheme.primary : Colors.grey),
            onPressed: () => setState(() => shuffle = !shuffle)),
          IconButton(icon: const Icon(Icons.skip_previous, size: 26), onPressed: _prev),
          IconButton(icon: Icon(_player.playing ? Icons.pause_circle : Icons.play_circle, size: 36),
            onPressed: () => _player.playing ? _player.pause() : _player.play()),
          IconButton(icon: const Icon(Icons.skip_next, size: 26), onPressed: _next),
          IconButton(icon: const Icon(Icons.stop, size: 20, color: Colors.grey), onPressed: () async {
            await _player.stop(); setState(() => playing = null); }),
        ]),
      ])),
    Expanded(child: songs.isEmpty
      ? const Center(child: Text('选一个装音乐的文件夹\n支持 mp3/flac/m4a 等, 自动扫描子目录', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
      : ListView.builder(itemCount: songs.length, itemBuilder: (_, i) {
          final f = songs[i];
          final on = playing == f.path;
          return ListTile(dense: true,
            leading: Icon(Icons.music_note, size: 18, color: on ? Theme.of(c).colorScheme.primary : Colors.grey),
            title: Text(f.path.split('/').last.replaceAll(RegExp(r'\.(mp3|m4a|flac|ogg|wav|aac)$', caseSensitive: false), ''),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: on ? Theme.of(c).colorScheme.primary : null)),
            subtitle: Text(f.path.split('/').reversed.elementAt(1), style: const TextStyle(fontSize: 10, color: Colors.grey)),
            onTap: () => _play(i));
        })),
  ]);
}
