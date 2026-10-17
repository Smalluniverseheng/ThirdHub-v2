// 高级播放设置（2026-10-14）—— 对齐主流播放器（VLC / MX Player / MX Player Pro / 蜜蜂）的
// 功能矩阵，分「基础 / 手势 / 字幕 / 音频视频 / 高级」五组。
//
// ★为什么要单独一页而不是继续往 playback_settings_page 塞：
//   旧页只有 8 项、172 行，且全是「在线/本地」二分。这里要覆盖的维度已经和
//   内容源无关（手势、字幕、外观、解码、缓存），继续混在一起会让旧键的兼容处理
//   与新维度纠缠。所以新建一页，**旧键一律沿用**（见下方键表），行为不破坏。
//
// ★所有开关都是 SharedPreferences 键，与播放器读取处一一对应；
//   播放器尚未接线的项在这里注明「待接线」，避免用户以为坏了。
//
// 键表（本页新增的都是 play_ 前缀，便于检索）：
//   手势：play_gesture_brightness / play_gesture_volume / play_gesture_progress
//        play_double_tap_side / play_double_tap_action / play_longpress_speed
//   字幕：play_subtitle_enable / play_subtitle_size / play_subtitle_color
//        play_subtitle_bg / play_subtitle_position / play_subtitle_speed
//   播放：play_default_speed / play_resume / play_autonext / play_seek_step
//        play_skip_intro / play_skip_outro / play_loop_mode / play_picture_ratio
//   音频：play_volume / play_danmaku_enable / play_danmaku_size / play_danmaku_speed
//        play_danmaka_opacity / play_audio_track
//   高级：play_hardware_decode / play_background_audio / play_pause_on_call
//        play_cache_minutes / play_auto_next_delay / play_resume_from_last_ep
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_widgets.dart';
import 'pro_kit.dart';
import 'haptic.dart';

class AdvancedPlaybackPage extends StatefulWidget {
  const AdvancedPlaybackPage({super.key});

  @override
  State<AdvancedPlaybackPage> createState() => _AdvState();
}

class _AdvState extends State<AdvancedPlaybackPage> {
  late SharedPreferences _p;

  // 手势
  bool _gBrightness = true;
  bool _gVolume = true;
  bool _gProgress = true;
  bool _doubleTapSide = true;
  String _doubleTapAction = 'seek'; // seek | playpause | brightness | volume | none
  String _longPressSpeed = '2.0';

  // 字幕
  bool _subEnable = true;
  double _subSize = 18;
  int _subColor = 0xFFFFFFFF;
  double _subBg = 0.0;
  double _subPos = 0.12; // 距底比例
  double _subSpeed = 1.0;

  // 播放
  String _defSpeed = '1.0';
  bool _resume = true;
  bool _autoNext = true;
  int _seekStep = 10;
  int _skipIntro = 90;
  int _skipOutro = 60;
  String _loopMode = 'list'; // one | list | shuffle
  String _ratio = 'fit'; // fit | fill | crop

  // 音频 / 弹幕
  double _volume = 1.0;
  bool _danmakuEnable = true;
  double _danmakuSize = 1.0;
  double _danmakuSpeed = 1.0;
  double _danmakuOpacity = 1.0;

  // 高级
  bool _hwDecode = true;
  bool _bgAudio = false;
  bool _pauseOnCall = true;
  int _cacheMinutes = 30;

  bool _haptic = true;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      // 手势
      _gBrightness = _p.getBool('play_gesture_brightness') ?? true;
      _gVolume = _p.getBool('play_gesture_volume') ?? true;
      _gProgress = _p.getBool('play_gesture_progress') ?? true;
      _doubleTapSide = _p.getBool('play_double_tap_side') ?? true;
      _doubleTapAction = _p.getString('play_double_tap_action') ?? 'seek';
      _longPressSpeed = _p.getString('play_longpress_speed') ?? '2.0';
      // 字幕
      _subEnable = _p.getBool('play_subtitle_enable') ?? true;
      _subSize = _p.getDouble('play_subtitle_size') ?? 18;
      _subColor = _p.getInt('play_subtitle_color') ?? 0xFFFFFFFF;
      _subBg = _p.getDouble('play_subtitle_bg') ?? 0.0;
      _subPos = _p.getDouble('play_subtitle_position') ?? 0.12;
      _subSpeed = _p.getDouble('play_subtitle_speed') ?? 1.0;
      // 播放
      _defSpeed = _p.getString('video_speed') ?? '1.0';
      _resume = _p.getBool('play_resume') ?? true;
      _autoNext = _p.getBool('play_autonext') ?? true;
      _seekStep = _p.getInt('play_seek_step') ?? 10;
      _skipIntro = _p.getInt('play_skip_intro') ?? 90;
      _skipOutro = _p.getInt('play_skip_outro') ?? 60;
      _loopMode = _p.getString('play_loop_mode') ?? 'list';
      _ratio = _p.getString('play_picture_ratio') ?? 'fit';
      // 音频/弹幕
      _volume = _p.getDouble('play_volume') ?? 1.0;
      _danmakuEnable = _p.getBool('play_danmaku_enable') ?? true;
      _danmakuSize = _p.getDouble('play_danmaku_size') ?? 1.0;
      _danmakuSpeed = _p.getDouble('play_danmaku_speed') ?? 1.0;
      _danmakuOpacity = _p.getDouble('play_danmaku_opacity') ?? 1.0;
      // 高级
      _hwDecode = _p.getBool('play_hardware_decode') ?? true;
      _bgAudio = _p.getBool('play_background_audio') ?? false;
      _pauseOnCall = _p.getBool('play_pause_on_call') ?? true;
      _cacheMinutes = _p.getInt('play_cache_minutes') ?? 30;
      _haptic = _p.getBool('haptic_on') ?? true;
      _ready = true;
    });
  }

  Future<void> _setBool(String k, bool v) async {
    setState(() {});
    await _p.setBool(k, v);
  }

  Future<void> _setDouble(String k, double v) async {
    setState(() {});
    await _p.setDouble(k, v);
  }

  Future<void> _setInt(String k, int v) async {
    setState(() {});
    await _p.setInt(k, v);
  }

  Future<void> _setStr(String k, String v) async {
    setState(() {});
    await _p.setString(k, v);
  }

  void _resetAll() {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复默认'),
        content: const Text('把本页所有项恢复为默认值？已保存的观影偏好会一起重置。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              const keys = [
                'play_gesture_brightness', 'play_gesture_volume', 'play_gesture_progress',
                'play_double_tap_side', 'play_double_tap_action', 'play_longpress_speed',
                'play_subtitle_enable', 'play_subtitle_size', 'play_subtitle_color',
                'play_subtitle_bg', 'play_subtitle_position', 'play_subtitle_speed',
                'video_speed', 'play_resume', 'play_autonext', 'play_seek_step',
                'play_skip_intro', 'play_skip_outro', 'play_loop_mode', 'play_picture_ratio',
                'play_volume', 'play_danmaku_enable', 'play_danmaku_size',
                'play_danmaku_speed', 'play_danmaku_opacity', 'play_hardware_decode',
                'play_background_audio', 'play_pause_on_call', 'play_cache_minutes',
              ];
              for (final k in keys) {
                await _p.remove(k);
              }
              Navigator.pop(c);
              _load();
              if (mounted) ProUI.toast(context, '已恢复默认');
            },
            child: const Text('恢复'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('高级播放设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _group('播放行为'),
          _switch('续播（记住上次进度）', _resume, 'play_resume',
              hint: '看到哪继续从哪；距结尾 5 秒内不再续播'),
          _switch('自动下一集', _autoNext, 'play_autonext', hint: '一集播完自动连播'),
          _slider('双击快进/快退秒数', _seekStep.toDouble(), 5, 60, 1, (v) {
            _seekStep = v.round();
          }, 'play_seek_step', unit: ' 秒'),
          _slider('跳过片头（秒）', _skipIntro.toDouble(), 0, 300, 5, (v) {
            _skipIntro = v.round();
          }, 'play_skip_intro', unit: ' 秒', hint: '0 = 不跳过'),
          _slider('跳过片尾（秒）', _skipOutro.toDouble(), 0, 300, 5, (v) {
            _skipOutro = v.round();
          }, 'play_skip_outro', unit: ' 秒', hint: '0 = 不跳过'),
          _choice('循环模式', _loopMode, 'play_loop_mode', const {
            'one': '单曲循环',
            'list': '列表循环',
            'shuffle': '随机播放',
          }),
          _choice('画面比例', _ratio, 'play_picture_ratio', const {
            'fit': '适应屏幕',
            'fill': '填满屏幕',
            'crop': '裁剪填满',
          }),
          _choice('默认倍速', _defSpeed, 'video_speed', const {
            '0.5': '0.5x', '0.75': '0.75x', '1.0': '1.0x', '1.25': '1.25x',
            '1.5': '1.5x', '2.0': '2.0x', '3.0': '3.0x',
          }),
          const SizedBox(height: 12),

          _group('手势'),
          _switch('左侧滑动调亮度', _gBrightness, 'play_gesture_brightness'),
          _switch('右侧滑动调音量', _gVolume, 'play_gesture_volume'),
          _switch('横向滑动快进快退', _gProgress, 'play_gesture_progress'),
          _switch('双击只在左右两侧生效', _doubleTapSide, 'play_double_tap_side',
              hint: '关闭后屏幕中央双击也可触发'),
          _choice('双击动作', _doubleTapAction, 'play_double_tap_action', const {
            'seek': '快进 / 快退',
            'playpause': '播放 / 暂停',
            'brightness': '调亮度',
            'volume': '调音量',
            'none': '不触发',
          }),
          _choice('长按倍速', _longPressSpeed, 'play_longpress_speed', const {
            '1.5': '1.5x', '2.0': '2.0x', '3.0': '3.0x',
          }),
          const SizedBox(height: 12),

          _group('字幕'),
          _switch('显示字幕', _subEnable, 'play_subtitle_enable'),
          _slider('字幕字号', _subSize, 10, 48, 1, (v) => _subSize = v, 'play_subtitle_size', unit: ' sp'),
          _slider('字幕背景不透明度', _subBg, 0, 1, 0.05, (v) => _subBg = v, 'play_subtitle_bg',
              hint: '0 = 无背景'),
          _slider('字幕距底部距离', _subPos, 0, 0.6, 0.02, (v) => _subPos = v, 'play_subtitle_position',
              hint: '0 贴底，越大越靠上'),
          _slider('字幕速度', _subSpeed, 0.5, 2.0, 0.1, (v) => _subSpeed = v, 'play_subtitle_speed', unit: 'x'),
          _subtitleColorRow(),
          const SizedBox(height: 12),

          _group('音频与弹幕'),
          _slider('默认音量', _volume, 0, 1, 0.05, (v) => _volume = v, 'play_volume',
              hint: '0 = 静音'),
          _switch('弹幕', _danmakuEnable, 'play_danmaku_enable'),
          _slider('弹幕字号', _danmakuSize, 0.5, 2.0, 0.1, (v) => _danmakuSize = v, 'play_danmaku_size', unit: 'x'),
          _slider('弹幕速度', _danmakuSpeed, 0.5, 2.0, 0.1, (v) => _danmakuSpeed = v, 'play_danmaku_speed', unit: 'x'),
          _slider('弹幕不透明度', _danmakuOpacity, 0.1, 1, 0.1, (v) => _danmakuOpacity = v, 'play_danmaku_opacity'),
          const SizedBox(height: 12),

          _group('通用'),
          // ★2026-10-17 触觉反馈开关（用户要求「搞震动反馈但要有开关键」）——
          //   所有震动统一走 core/haptic.dart，关掉即全静音（连 AI 抽屉的震动一起关）。
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('震动反馈', style: TextStyle(fontSize: 14)),
            subtitle: const Text('按钮点击 / 滑出面板时的轻震；关闭后完全静音',
                style: TextStyle(fontSize: 11.5, color: Colors.grey)),
            value: _haptic,
            onChanged: (v) async {
              setState(() => _haptic = v);
              await Haptic.setEnabled(v);
            },
          ),
          const SizedBox(height: 12),
          _group('高级'),
          _switch('硬件解码', _hwDecode, 'play_hardware_decode',
              hint: '关闭可排查画面异常；老机型建议关闭'),
          _switch('后台播放音频', _bgAudio, 'play_background_audio',
              hint: '退到后台仍继续出声（需通知栏常驻权限）'),
          _switch('来电时暂停', _pauseOnCall, 'play_pause_on_call'),
          _slider('预缓冲（分钟）', _cacheMinutes.toDouble(), 1, 120, 1, (v) {
            _cacheMinutes = v.round();
          }, 'play_cache_minutes', unit: ' 分钟', hint: '网差时调大更稳，占空间更多'),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _resetAll,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复默认'),
          ),
          const SizedBox(height: 10),
          const Text('提示：改动即时生效，下一次播放即按新设置执行。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  // ── 小组件 ──
  Widget _group(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      );

  Widget _switch(String title, bool value, String key, {String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(title, style: const TextStyle(fontSize: 14)),
          value: value,
          onChanged: (v) {
            // 状态由 _load 统一读，这里先改本地再落盘
            _applyLocal(key, v);
            _setBool(key, v);
          },
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(left: 0, bottom: 4),
            child: Text(hint, style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _choice(String title, String value, String key, Map<String, String> options) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: options.entries
                .map((e) => ChoiceChip(
                      label: Text(e.value, style: const TextStyle(fontSize: 12.5)),
                      selected: value == e.key,
                      onSelected: (_) {
                        _applyLocalStr(key, e.key);
                        _setStr(key, e.key);
                      },
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _slider(String title, double value, double min, double max, double div,
      ValueChanged<double> onChangedLocal, String key,
      {String unit = '', String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontSize: 14)),
            Text(_fmt(value) + unit,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) / div).round().clamp(1, 200),
          label: _fmt(value) + unit,
          onChanged: (v) {
            onChangedLocal(v);
            setState(() {});
            if (key == 'play_seek_step') {
              _seekStep = v.round();
            }
            if (key == 'play_skip_intro') {
              _skipIntro = v.round();
            }
            if (key == 'play_skip_outro') {
              _skipOutro = v.round();
            }
            if (key == 'play_cache_minutes') {
              _cacheMinutes = v.round();
            }
            _setDouble(key, v);
          },
        ),
        if (hint != null)
          Text(hint, style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
      ],
    );
  }

  Widget _subtitleColorRow() {
    const colors = {
      0xFFFFFFFF: '白',
      0xFF00E5FF: '青',
      0xFFFFE100: '黄',
      0xFF90EE90: '绿',
      0xFFFF9E9E: '粉',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('字幕颜色', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: colors.entries
                .map((e) => GestureDetector(
                      onTap: () {
                        _subColor = e.key;
                        setState(() {});
                        _setInt('play_subtitle_color', e.key);
                      },
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(e.key),
                          shape: BoxShape.circle,
                          border: Border.all(
                            width: _subColor == e.key ? 3 : 1,
                            color: _subColor == e.key
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(e.value,
                            style: TextStyle(
                                fontSize: 12,
                                color: e.key == 0xFFFFE100 ? Colors.black87 : Colors.black26)),
                      ),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }

  /// 开关变化时同步本地状态（避免整页 _load 的开销）。
  void _applyLocal(String key, bool v) {
    setState(() {
      switch (key) {
        case 'play_gesture_brightness': _gBrightness = v; break;
        case 'play_gesture_volume': _gVolume = v; break;
        case 'play_gesture_progress': _gProgress = v; break;
        case 'play_double_tap_side': _doubleTapSide = v; break;
        case 'play_subtitle_enable': _subEnable = v; break;
        case 'play_danmaku_enable': _danmakuEnable = v; break;
        case 'play_hardware_decode': _hwDecode = v; break;
        case 'play_background_audio': _bgAudio = v; break;
        case 'play_pause_on_call': _pauseOnCall = v; break;
        case 'play_resume': _resume = v; break;
        case 'play_autonext': _autoNext = v; break;
      }
    });
  }

  void _applyLocalStr(String key, String v) {
    setState(() {
      switch (key) {
        case 'play_double_tap_action': _doubleTapAction = v; break;
        case 'play_longpress_speed': _longPressSpeed = v; break;
        case 'play_loop_mode': _loopMode = v; break;
        case 'play_picture_ratio': _ratio = v; break;
        case 'video_speed': _defSpeed = v; break;
      }
    });
  }
}
