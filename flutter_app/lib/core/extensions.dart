// 可安装的资源包（扩展）管理。
//
// 用户需求（2026-11-06）：
//   「不是所有人都需要整个包装进来，有些人只是拿来看漫画。
//     可以注册一个软件内的、可扩展的东西。」
//
// ★ 先说清一个技术边界，它决定了这个文件能做什么、不能做什么：
//
//   **Flutter 不能运行时加载代码。** Dart 编译进 APK，AOT 之后没有任何动态加载通道。
//   所以「只看漫画的人不装 AI」不可能靠「不下载 AI 的代码」实现 —— 代码始终在包里。
//
//   能按需下载的是**资源**，而资源才是占空间的大头：
//     · DSH 的 Linux 运行时（rootfs）  约 1GB  ← 最大的那块
//     · 引擎包 / 源包                  30–45MB
//     · 本地模型                        数百 MB
//
//   所以这里的定位是：**App 本体保持轻（32MB 能看漫画），重资源做成按需安装的包**。
//   用户不装 AI 运行时 → 依然能用云端 AI（联网）；装了 → 断网也能跑。
//
// 与 DSH Go 的 `plugins/` 的区别：它的插件是**在引擎内部**跑的 TypeScript 模块（Cordis），
// 我们这边只能管「装不装这个资源」，管不到「引擎里加载哪些插件」—— 那部分由引擎自己负责。

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 资源包的类别。
enum ExtKind {
  /// 引擎运行时（DSH 的 Linux 环境）—— 最重，按需装
  runtime,

  /// 内容引擎（小说/漫画/音乐/视频的本地引擎）
  engine,

  /// 源包（一批站点配置）
  sources,

  /// 本地模型
  model,

  /// 技能包（提示词 + 工具清单的组合）
  skill,
}

/// 一个可安装的资源包。
class AppExt {
  const AppExt({
    required this.id,
    required this.name,
    required this.desc,
    required this.kind,
    this.sizeBytes = 0,
    this.url = '',
    this.version = '',
    this.requires = const [],
  });

  final String id;
  final String name;
  final String desc;
  final ExtKind kind;

  /// 下载体积（字节）。0 = 未知
  final int sizeBytes;

  /// 下载地址（空 = 暂未开放，例如本机运行时的 rootfs 还在做）
  final String url;
  final String version;

  /// 依赖的其他包 id
  final List<String> requires;

  bool get available => url.trim().isNotEmpty;
}

/// 安装状态。
enum ExtState { notInstalled, installing, installed, failed }

class Extensions {
  static const _kInstalled = 'ext_installed_v1';

  /// 内置清单。加新包就在这里加一条，UI 自动出现。
  ///
  /// ★ 大小写实数，不要写"约"。用户看到 1.0 GB 才知道要不要装。
  static const List<AppExt> catalog = <AppExt>[
    AppExt(
      id: 'dsh-runtime',
      name: '本机 AI 运行时',
      desc: '把 Linux 环境装在手机上，断网也能让 AI 跑任务。不装也能用云端 AI。',
      kind: ExtKind.runtime,
      sizeBytes: 1073741824, // 1.0 GB
      version: '',
      // url 留空 = 暂未开放。等原生层（PRoot）做好再填，
      // 现在挂上去点了会下载失败，不如明确说"还没做"。
      url: '',
      requires: [],
    ),
    AppExt(
      id: 'engine-novel',
      name: '小说资料库',
      desc: '本地搜书、解析站点、离线缓存',
      kind: ExtKind.engine,
      sizeBytes: 26214400,
      version: '1.13.3',
      url:
          'https://onhmosehcwyrqgxadjvb.supabase.co/storage/v1/object/public/downloads/thirdhub/engine/thirdhub-engine-novel-1.13.3.apk',
    ),
    AppExt(
      id: 'engine-comic',
      name: '漫画资料库',
      desc: '漫画站点解析、图片直连、批量下载',
      kind: ExtKind.engine,
      sizeBytes: 46875000,
      version: '1.10.11',
      url:
          'https://onhmosehcwyrqgxadjvb.supabase.co/storage/v1/object/public/downloads/thirdhub/engine/thirdhub-engine-comic-1.10.11.apk',
    ),
    AppExt(
      id: 'engine-video',
      name: '影视资料库',
      desc: '影视站点聚合、播放地址解析',
      kind: ExtKind.engine,
      sizeBytes: 33340000,
      version: '1.3.7',
      url:
          'https://onhmosehcwyrqgxadjvb.supabase.co/storage/v1/object/public/downloads/thirdhub/engine/thirdhub-engine-video-1.3.7.apk',
    ),
    AppExt(
      id: 'engine-music',
      name: '音乐资料库',
      desc: '音乐搜索与播放',
      kind: ExtKind.engine,
      sizeBytes: 28940000,
      version: '1.9.6',
      url:
          'https://onhmosehcwyrqgxadjvb.supabase.co/storage/v1/object/public/downloads/thirdhub/engine/thirdhub-engine-music-1.9.6.apk',
    ),
  ];

  static Set<String> _installed = {};

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _installed = (p.getStringList(_kInstalled) ?? const []).toSet();
  }

  static bool isInstalled(String id) => _installed.contains(id);

  static Future<void> markInstalled(String id) async {
    _installed.add(id);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kInstalled, _installed.toList());
  }

  static Future<void> markRemoved(String id) async {
    _installed.remove(id);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kInstalled, _installed.toList());
  }

  /// 安装后能解锁什么（给 UI 显示"装了会多出什么"）。
  static String unlockText(AppExt e) => switch (e.kind) {
        ExtKind.runtime => '断网也能让 AI 跑任务；任务可在手机上继续，不必回电脑',
        ExtKind.engine =>
          '「${e.name.replaceAll('引擎', '')}」模块能搜到内容、能离线缓存',
        ExtKind.sources => '多一批可选站点',
        ExtKind.model => '本地推理，不消耗云端额度',
        ExtKind.skill => 'AI 多一批预设能力（提示词 + 工具组合）',
      };

  /// 格式化体积。刻意不用「约」——用户要看到准确的量级。
  static String sizeText(int bytes) {
    if (bytes <= 0) return '未知';
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1048576) return '${(bytes / 1048576).round()} MB';
    return '${(bytes / 1024).round()} KB';
  }

  /// 已装的总占用。
  static int installedBytes() {
    var n = 0;
    for (final e in catalog) {
      if (_installed.contains(e.id)) n += e.sizeBytes;
    }
    return n;
  }

  /// 下载到 App 文档目录并校验大小。
  ///
  /// 只做「下载 + 落盘」，不做安装（引擎包是 APK，装它要走系统安装器；
  /// rootfs 要解压 —— 那部分等原生层做好再补）。
  static Future<String?> download(
    AppExt e, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!e.available) return '这个包还没开放下载';
    HttpClient? client;
    try {
      final dir = await Directory.systemTemp.createTemp('th_ext');
      final out = File('${dir.path}/${e.id}.bin');
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(e.url));
      final resp = await req.close();
      if (resp.statusCode != 200) return '下载失败 HTTP ${resp.statusCode}';
      final total = resp.contentLength;
      var got = 0;
      final sink = out.openWrite();
      await for (final chunk in resp) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.close();
      // 大小对不上就判失败 —— 半截包比没下载更麻烦
      if (total > 0 && got != total) {
        return '下载不完整（$got / $total 字节）';
      }
      return null;
    } catch (err) {
      return '下载出错：$err';
    } finally {
      client?.close();
    }
  }
}
