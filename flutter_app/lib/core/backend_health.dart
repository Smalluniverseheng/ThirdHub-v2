// 后端连通性状态（供全局 UI 订阅）——「在线/离线」是个**一等公民状态**，
// 不该每个页面各自 try/catch 猜。
//
// 背景（4.81.76）：断网或 NAS 关机时，旧版每个页面各自抛 `ClientException`，
// 用户看到的是「Failed host lookup: 'xxx'」这种原文，或者更糟 —— 一个空白列表，
// 看上去像「源里没内容」。离线模式之所以让人困惑，就是因为**界面从不说实话**。
//
// 约定：
//   · 只有 `Api` 层（main.dart 的 `get`/`post`/`postEncrypted`）写这里，页面只读；
//   · 失败不立刻判死：连续失败 2 次才翻成 offline —— 单次抖动（切 WiFi、
//     IPv6 短暂不通）不该让整屏变成「离线」；
//   · 任意一次成功立刻翻回 online。
library;

import 'package:flutter/foundation.dart';

enum BackendState {
  /// 还没发过请求，不知道。
  unknown,
  online,
  offline,
}

class BackendHealth {
  /// 连续失败次数达到这个阈值才判离线。
  static const int failThreshold = 2;

  static final ValueNotifier<BackendState> state =
      ValueNotifier<BackendState>(BackendState.unknown);

  static int _fails = 0;
  static String lastError = '';
  static DateTime? lastOk;
  static DateTime? lastFail;

  static bool get online => state.value == BackendState.online;
  static bool get knownOffline => state.value == BackendState.offline;

  /// 一句短的、能给用户看的现状说明。
  static String get label => switch (state.value) {
        BackendState.online => '后端在线',
        BackendState.offline => '后端不可达 · 离线模式',
        BackendState.unknown => '未连接后端',
      };

  /// 离线时给用户的下一步建议（不要只说「失败了」）。
  static String get advice =>
      '当前只能播放已下载到本机的内容。\n可在「我的 → 离线内容」里查看已下载的；\n需要联网内容时，确认 NAS 后端已启动且与本机同一网络。';

  @internal
  static void markOk() {
    _fails = 0;
    lastOk = DateTime.now();
    lastError = '';
    if (state.value != BackendState.online) state.value = BackendState.online;
  }

  @internal
  static void markFail(Object e) {
    _fails++;
    lastFail = DateTime.now();
    lastError = _humanize(e);
    if (_fails >= failThreshold && state.value != BackendState.offline) {
      state.value = BackendState.offline;
    }
  }

  /// 用户手动重连成功后强制刷新（`my_backend_page` 用）。
  static void reset() {
    _fails = 0;
    lastError = '';
    state.value = BackendState.unknown;
  }

  static String _humanize(Object e) {
    final s = '$e';
    if (s.contains('Failed host lookup')) return '解析不到后端主机名（DNS / 网段变了）';
    if (s.contains('Connection refused')) return '后端端口没开（服务没启动？）';
    if (s.contains('timed out') || s.contains('TimeoutException')) {
      return '后端响应超时（网络慢或服务卡住）';
    }
    if (s.contains('SocketException')) return '连不上后端（网络不通）';
    return s;
  }
}

/// 后端地址没配 / 连不上时抛这个 —— 文案已经写好，页面直接显示即可。
class ApiOfflineError implements Exception {
  final String message;
  const ApiOfflineError(this.message);
  @override
  String toString() => message;
}
