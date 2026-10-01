// 已安装应用桥 —— 聊天里「发送应用」用（用户需求 2026-10-01：
// 「像 QQ 那样可以提取应用然后发送 APK」）。
//
// 为什么必须走原生：Dart 侧既拿不到本机已安装应用列表，也拿不到
// `ApplicationInfo.sourceDir`（安装包在磁盘上的真实路径）。
// 原生实现见 android/app/src/main/kotlin/com/thirdhub/app/MainActivity.kt
// 的 `thirdhub/apps` 通道（与 thirdhub/net、thirdhub/pip 等同一套注册方式）。
//
// ★ Android 11(30) 起，没有 QUERY_ALL_PACKAGES（或 <queries> 声明）时
//   getInstalledApplications 只返回「自己」—— 这是系统隐私限制，不是我们的 bug。
//   所以本桥在拿不到列表时**不抛异常**，而是返回空，由界面把原因说清楚，
//   免得用户以为"功能坏了、点了没反应"。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 一个已安装的应用。字段刻意只留"发送应用"真正用得上的那几个。
class InstalledApp {
  /// 显示名（如「微信」）
  final String name;

  /// 包名（如 com.tencent.mm）
  final String packageName;

  /// 安装包（APK）在磁盘上的真实路径 —— 发送的就是这个文件
  final String path;

  /// 系统应用（不可卸载的那类）。默认排在后面，避免淹没第三方应用。
  final bool system;

  /// 安装包字节数
  final int size;

  /// 版本名（可能为空）
  final String version;

  const InstalledApp({
    required this.name,
    required this.packageName,
    required this.path,
    this.system = false,
    this.size = 0,
    this.version = '',
  });

  factory InstalledApp.from(dynamic raw) {
    final m = raw is Map ? raw : const <String, dynamic>{};
    return InstalledApp(
      name: '${m['name'] ?? ''}'.trim().isEmpty
          ? '${m['package'] ?? '未知'}'
          : '${m['name']}',
      packageName: '${m['package'] ?? ''}',
      path: '${m['path'] ?? ''}',
      system: m['system'] == true,
      size: (m['size'] is int) ? m['size'] as int : 0,
      version: '${m['version'] ?? ''}',
    );
  }
}

class AppBridge {
  static const MethodChannel _ch = MethodChannel('thirdhub/apps');

  /// 桥是否可用（非安卓平台一律不可用）。
  static bool get supported => Platform.isAndroid;

  /// 列出本机已安装应用。失败一律返回空表，不抛 —— 由界面解释原因。
  static Future<List<InstalledApp>> list() async {
    if (!supported) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('list');
      final out = [
        for (final e in (raw ?? const [])) InstalledApp.from(e)
      ].where((a) => a.path.isNotEmpty).toList();
      // 第三方优先，其次按名字
      out.sort((a, b) {
        if (a.system != b.system) return a.system ? 1 : -1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return out;
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } catch (_) {
      return const [];
    }
  }
}

/// 格式化字节数（安装包大小显示用）。
String fmtAppSize(int b) {
  if (b <= 0) return '';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 应用选择页：搜索 + 列表，点一下即返回选中的应用。
///
/// 复用聊天的既有交互习惯（顶部搜索、点选即返回），不引入新范式。
class AppPickerPage extends StatefulWidget {
  const AppPickerPage({super.key});

  @override
  State<AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends State<AppPickerPage> {
  List<InstalledApp> _all = const [];
  List<InstalledApp> _view = const [];
  final _kw = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _kw.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final l = await AppBridge.list();
    if (!mounted) return;
    setState(() {
      _all = l;
      _view = l;
      _loading = false;
    });
  }

  void _filter(String q) {
    final s = q.trim().toLowerCase();
    setState(() {
      _view = s.isEmpty
          ? _all
          : _all
              .where((a) =>
                  a.name.toLowerCase().contains(s) ||
                  a.packageName.toLowerCase().contains(s))
              .toList();
    });
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择要发送的应用')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _kw,
            onChanged: _filter,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: '搜索应用名或包名',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        if (!AppBridge.supported)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('只有安卓端支持提取应用安装包。',
                style: TextStyle(fontSize: 13)),
          )
        else if (_loading)
          const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator())
        else if (_all.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '没有读到已安装应用。\n\n'
              '安卓 11 及以上出于隐私限制，应用需要声明"查询已安装应用"权限才能看到其它应用；'
              '若你的系统版本较低或被系统管家拦截，也会读不到。\n'
              '这不影响聊天里的文字、图片与文件发送。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _view.length,
              itemBuilder: (_, i) {
                final a = _view[i];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.android_outlined),
                  title: Text(a.name, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    [
                      a.packageName,
                      if (a.version.isNotEmpty) 'v${a.version}',
                      if (a.size > 0) fmtAppSize(a.size),
                      if (a.system) '系统',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop<InstalledApp>(c, a),
                );
              },
            ),
          ),
      ]),
    );
  }
}
