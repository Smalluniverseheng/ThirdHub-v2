// 播放设置页（2026-10-12）—— 把散落各处的播放器行为开关**收拢到一处**。
//
// 为什么要有它：续播 / 自动连播 / 长按 2x 这些是 4.71.0 新加的能力，
// 此前只能"用或不用"，没有关掉的入口。有人看剧就是要"每次从头"、
// 有人连播会吵到家人 —— 设置项本身就是产品的一部分。
//
// 键口径（SharedPreferences，与播放器读取处一一对应）：
//   play_resume         在线视频续播（默认 true）
//   play_autonext       在线视频播完自动下一集（默认 true）
//   play_longpress_2x   画面长按 2x 快放（默认 true）
//   play_seek_step      双击快进/快退秒数（默认 10）
//   play_resume_local   本地视频续播（默认 true）
//   video_speed         默认倍速（既有键，0.5~3.0）
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_widgets.dart';

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key});
  @override
  State<PlaybackSettingsPage> createState() => _PbState();
}

class _PbState extends State<PlaybackSettingsPage> {
  late SharedPreferences _p;
  bool _loaded = false;

  bool _resume = true;
  bool _autoNext = true;
  bool _longPress = true;
  bool _resumeLocal = true;
  int _seekStep = 10;
  String _speed = '1.0';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _resume = _p.getBool('play_resume') ?? true;
      _autoNext = _p.getBool('play_autonext') ?? true;
      _longPress = _p.getBool('play_longpress_2x') ?? true;
      _resumeLocal = _p.getBool('play_resume_local') ?? true;
      _seekStep = _p.getInt('play_seek_step') ?? 10;
      _speed = _p.getString('video_speed') ?? '1.0';
      _loaded = true;
    });
  }

  Future<void> _setBool(String k, bool v) async {
    await _p.setBool(k, v);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext c) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
        appBar: AppBar(title: const Text('播放设置')),
        body: ListView(children: [
          const _Section('在线视频'),
          SwitchListTile(
              title: const Text('续播'),
              subtitle: const Text('上次看到哪，这次从哪继续（播完自动清位）'),
              value: _resume,
              onChanged: (v) => _setBool('play_resume', v)),
          SwitchListTile(
              title: const Text('播完自动连播下一集'),
              subtitle: const Text('一集放完自动进下一集；关掉则停在片尾'),
              value: _autoNext,
              onChanged: (v) => _setBool('play_autonext', v)),
          SwitchListTile(
              title: const Text('长按 2x 快放'),
              subtitle: const Text('按住画面快放 2 倍速，松开还原（与倍速菜单不冲突）'),
              value: _longPress,
              onChanged: (v) => _setBool('play_longpress_2x', v)),
          ListTile(
              title: const Text('双击快进 / 快退步长'),
              subtitle: Text('当前：$_seekStep 秒（双击画面左 / 右半边）'),
              trailing: Text('$_seekStep 秒',
                  style: const TextStyle(color: Colors.grey)),
              onTap: () async {
                final v = await _pickInt('双击步长', [5, 10, 15, 30], _seekStep);
                if (v != null) {
                  await _p.setInt('play_seek_step', v);
                  if (mounted) setState(() => _seekStep = v);
                }
              }),
          const Divider(height: 1),
          const _Section('本地视频'),
          SwitchListTile(
              title: const Text('续播'),
              subtitle: const Text('本地播放记住上次位置（同目录重看会接着放）'),
              value: _resumeLocal,
              onChanged: (v) => _setBool('play_resume_local', v)),
          const Divider(height: 1),
          const _Section('倍速'),
          ListTile(
              title: const Text('默认播放速度'),
              subtitle: const Text('播放中仍可随时在播放器里改'),
              trailing: Text('${_speed}x',
                  style: const TextStyle(color: Colors.grey)),
              onTap: () async {
                final v = await _pickStr('默认倍速',
                    ['0.5', '0.75', '1.0', '1.25', '1.5', '2.0', '3.0'], _speed);
                if (v != null) {
                  await _p.setString('video_speed', v);
                  if (mounted) setState(() => _speed = v);
                }
              }),
          const SizedBox(height: 24),
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                  '提示：倍速菜单与长按 2x 互不影响 —— 菜单设的倍速会被记成默认值，长按只是临时快放。',
                  style: TextStyle(fontSize: 11, color: Colors.grey))),
        ]));
  }

  Future<int?> _pickInt(String title, List<int> opts, int cur) async {
    return showDialog<int>(
        context: context,
        builder: (c2) => SimpleDialog(
                title: Text(title),
                children: [
                  for (final o in opts)
                    RadioListTile<int>(
                        value: o,
                        groupValue: cur,
                        title: Text('$o 秒'),
                        onChanged: (v) => Navigator.pop(c2, v)),
                ]));
  }

  Future<String?> _pickStr(String title, List<String> opts, String cur) async {
    return showDialog<String>(
        context: context,
        builder: (c2) => SimpleDialog(
                title: Text(title),
                children: [
                  for (final o in opts)
                    RadioListTile<String>(
                        value: o,
                        groupValue: cur,
                        title: Text('$o x'),
                        onChanged: (v) => Navigator.pop(c2, v)),
                ]));
  }
}

class _Section extends StatelessWidget {
  final String t;
  const _Section(this.t);
  @override
  Widget build(BuildContext c) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(t,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(c).colorScheme.primary)));
}
