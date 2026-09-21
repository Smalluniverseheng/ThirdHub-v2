// 画中画（Picture-in-Picture）桥。
//
// 为什么必须在原生做：PiP 缩的是整个 Activity 窗口，不是某个 Widget —— Flutter 层
// 没有对应 API，只能通过 MethodChannel 让 MainActivity 调 enterPictureInPictureMode()。
//
// 三个容易踩的点（都已在原生侧处理，这里只记下来）：
//  1) 宽高比超出 [1/2.39, 2.39] 会被系统直接抛异常 —— 带子式的超宽片源就会踩到；
//  2) Android 12 以下没有 autoEnterEnabled，靠 onUserLeaveHint 自己判断；
//  3) 进 PiP 后 Dart 必须切成「只有视频画面」的布局，否则整个 App 界面会被缩成小窗。
//
// 用法（视频页）：
//   await Pip.setAuto(enable: true, aspect: ctrl.value.aspectRatio, playing: ctrl.value.isPlaying);
//   Pip.onToggle = () { ... 切换播放/暂停 ... };   // 响应 PiP 窗里的那颗按钮
//   ... 离开页面时 await Pip.setAuto(enable: false);
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class Pip {
  Pip._();

  static const MethodChannel _ch = MethodChannel('thirdhub/pip');

  /// 画中画是否处于开启状态。视频页据此切布局（只留视频画面）。
  static final ValueNotifier<bool> inPip = ValueNotifier<bool>(false);

  /// PiP 窗里那颗播放/暂停按钮被按下时的回调，由当前视频页挂上。
  static VoidCallback? onToggle;

  static bool _wired = false;

  /// 自动进画中画的「代」。每次有新页面声明就 +1，用于丢弃上一页迟到的释放。
  static int _gen = 0;

  /// 接上原生回调。幂等，随便调用。
  static void wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'changed':
          final m = call.arguments;
          inPip.value = (m is Map && m['inPip'] == true);
          break;
        case 'toggle':
          onToggle?.call();
          break;
      }
      return null;
    });
  }

  /// 系统有没有画中画能力。非 Android 设备、以及极少数阉割了该 feature 的 ROM 返回 false。
  static Future<bool> supported() async {
    if (!Platform.isAndroid) return false;
    wire();
    try {
      return await _ch.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false; // 旧包没有这条通道，别炸
    } catch (_) {
      return false;
    }
  }

  /// 声明「现在正在放视频」。
  ///
  /// 返回本次声明对应的「代」（generation）。离开页面时把它交给 [releaseAuto]。
  /// 为什么要代这一层：切集走的是 pushReplacement —— 新页面 initState 会立刻
  /// 声明 enable:true，而旧页面的 dispose 稍后才发 enable:false，两者在通道上是
  /// 即发即走的，不挡一下就会出现「切一集之后再也进不了画中画」。
  ///
  /// Android 12+ 走系统的 autoEnterEnabled；更早的版本由原生侧在
  /// onUserLeaveHint（按 Home 那一刻）自己判断。两种情况都要 [playing] 为真。
  static Future<int> claimAuto({double? aspect, bool playing = false}) async {
    final int gen = ++_gen;
    if (!Platform.isAndroid) return gen;
    wire();
    try {
      await _ch.invokeMethod('setAuto', {
        'enable': true,
        'aspect': aspect,
        'playing': playing,
      });
    } catch (_) {}
    return gen;
  }

  /// 收回自动进画中画。[gen] 是 [claimAuto] 给的那一代；
  /// 若期间已有更新的页面声明过，这次释放会被忽略（不关掉后来者的声明）。
  static Future<void> releaseAuto(int gen) async {
    if (gen != _gen) return;
    if (!Platform.isAndroid) return;
    wire();
    try {
      await _ch.invokeMethod('setAuto', {
        'enable': false,
        'aspect': null,
        'playing': false,
      });
    } catch (_) {}
  }

  /// 立刻进画中画。返回是否真的进去了（系统可能因当前窗口状态拒绝）。
  static Future<bool> enter({double? aspect, bool playing = false}) async {
    if (!Platform.isAndroid) return false;
    wire();
    try {
      return await _ch.invokeMethod<bool>('enter', {
            'aspect': aspect,
            'playing': playing,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 播放/暂停变了，刷新 PiP 窗里那颗按钮的图标。
  static Future<void> updatePlaying(bool playing) async {
    if (!Platform.isAndroid) return;
    wire();
    try {
      await _ch.invokeMethod('update', {'playing': playing});
    } catch (_) {}
  }

  /// 当前是否已在画中画里（有些 ROM 不回调 changed，可用它兜底轮询）。
  static Future<bool> isInPip() async {
    if (!Platform.isAndroid) return false;
    wire();
    try {
      return await _ch.invokeMethod<bool>('inPip') ?? false;
    } catch (_) {
      return false;
    }
  }
}
