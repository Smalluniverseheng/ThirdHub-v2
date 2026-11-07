// 飞牛 NAS（fnOS）工具封装 —— 调官方 fnos-cli 管理 EVO4
//
// ── 这是什么 ────────────────────────────────────────────────────────────
// 飞牛官方出了 `@fnnas-labs/fnos-cli`（MIT，广州 TR 智能制造），把 NAS 的
// 文件/照片/下载/应用/存储/系统/Docker/百度网盘 全部暴露成 CLI。
// 我们不自己造 NAS 管理代码 —— 直接调它的 CLI，把结果喂给 AI。
//
// ── 为什么走 CLI 而不是自己写 HTTP ───────────────────────────────────────
//   ① 它是官方 API 的稳定封装，参数/分页/错误码都处理好了；
//   ② 许可 MIT，可以进我们的仓库，不用怕传染；
//   ③ 一套 CLI 同时服务 DSH、Codex、我们 —— 用户在不同工具间是同一个账号体系。
//
// ── 授权 ────────────────────────────────────────────────────────────────
// OAuth 走官方流程（`login --authorize-only` → 用户浏览器授权 → `login --code`），
// 不需要 NAS 账号密码。令牌存在 CLI 自己的受控存储里，我们不碰。
// 只读命令直接跑；写操作由上层（Agent 的审批闸）决定要不要问用户。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// fnos-cli 调用封装。
class FnosCli {
  /// 可执行文件路径。优先用本机配置，其次几个常见位置。
  static String exePath = '';

  static String host = '192.168.31.200';
  static int port = 5667;
  static String profile = 'home';

  /// fnOS 用自签证书，CLI 默认会拒 → 必须跳过校验（局域网内可接受）。
  static bool tlsInsecure = true;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final exe = p.getString('fnos_exe');
    if (exe != null && exe.trim().isNotEmpty && File(exe.trim()).existsSync()) {
      exePath = exe.trim();
      return;
    }
    exePath = _probe();
  }

  static String _probe() {
    final cands = <String>[
      'D:/ai/_fnos/fnos-cli.exe',
      '${Directory.current.path}/fnos-cli.exe',
      'fnos-cli.exe',
    ];
    for (final c in cands) {
      if (File(c).existsSync()) return c;
    }
    return 'fnos-cli.exe'; // 交给 PATH
  }

  static bool get ready => exePath.trim().isNotEmpty;

  /// 执行一条 fnos-cli 命令，返回 stdout（JSON 或文本）。
  /// 失败不抛异常 —— 返回带错误说明的文本，让 AI 自己判断下一步。
  static Future<String> run(List<String> args, {Duration timeout = const Duration(seconds: 30)}) async {
    if (!ready) return 'fnos-cli 未安装。请先把 fnos-cli.exe 放到 D:/ai/_fnos/ 下，或在设置里指定路径。';
    final full = <String>[
      '--host', host,
      '--port', '$port',
      '--profile', profile,
      if (tlsInsecure) '--tls-insecure',
      ...args,
    ];
    try {
      final r = await Process.run(exePath, full)
          .timeout(timeout + const Duration(seconds: 3));
      final out = (r.stdout ?? '').toString().trim();
      final err = (r.stderr ?? '').toString().trim();
      if (r.exitCode == 0) return out.isEmpty ? '（无输出）' : out;
      return '命令失败（退出码 ${r.exitCode}）：${err.isEmpty ? out : err}';
    } on TimeoutException {
      return '命令超时（${timeout.inSeconds} 秒）';
    } catch (e) {
      return '执行失败: $e';
    }
  }

  /// 只读命令（这些不需要人工确认）。
  static Future<String> systemInfo() => run(['system', 'info']);
  static Future<String> storageInfo() => run(['storage', 'info']);
  static Future<String> monitor() => run(['monitor', 'status']);
  static Future<String> listDir(String path) => run(['file', 'ls', if (path.trim().isNotEmpty) path.trim()]);
  static Future<String> searchFiles(String key, {String? path}) =>
      run(['file', 'search', key, if (path != null && path.trim().isNotEmpty) path.trim()]);
  static Future<String> photoFolders() => run(['photos', 'folders']);
  static Future<String> photoSearch(String key) => run(['photos', 'search', key]);
  static Future<String> dockerList() => run(['docker', 'ps']);
  static Future<String> downloadList() => run(['download', 'list']);
  static Future<String> userList() => run(['user', 'list']);
  static Future<String> netStatus() => run(['network', 'status']);

  /// media 是**独立授权**的（不在主 OAuth scope 里），未授权会 403。
  /// 这里如实报错，不假装能用。
  static Future<String> mediaLibraries() => run(['media', 'libraries']);
  static Future<String> mediaSearch(String key) => run(['media', 'search', key]);
}
