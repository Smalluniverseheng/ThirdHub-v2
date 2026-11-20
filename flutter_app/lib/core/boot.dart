// 启动轨迹与安全模式（2026-11-20 / 4.81.78）
//
// ══ 为什么要有这个文件 ══
// 用户反馈「装了新版本，打开就黑屏」。排查下来黑屏不是一个 bug，而是**一类**：
// 旧的 main() 是「先把所有初始化 await 完，再 runApp 主界面」，中间任何一步
// hang 住或抛异常，用户就永远停在开屏页（深色模式下开屏底色 #0E1016，
// 看上去就是"黑屏"），而且**没有任何痕迹可查** —— 用户说不清、我们也猜不到。
//
// 这个文件解决两件事：
//   ① **可诊断**：把启动拆成命名步骤，每步成败都落盘。下次再出问题，
//      「我的 → 日志 → 上次启动」能直接看到卡在第几步、报了什么错。
//   ② **可自愈**：连续 3 次没走到「启动完成」→ 自动进安全模式，
//      只清**界面类**配置（导航布局 / 皮肤 / 主题 / 动效），
//      账号、书架、阅读进度、服务器地址一律不动。
//
// 设计约束（别改成别的样子）：
//   · 所有写盘都吞异常 —— 诊断设施自己不能成为新的崩溃源。
//   · trace 只在内存里累积，落盘用 unawaited，绝不阻塞启动。
//   · 键名统一 boot_ 前缀，避免和业务键撞。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动轨迹一步。
class BootStep {
  const BootStep(this.name, {this.ok = true, this.error});

  final String name;
  final bool ok;
  final String? error;

  String encode() => ok ? name : '$name ✗ ${error ?? ''}'.trim();

  @override
  String toString() => encode();
}

class Boot {
  Boot._();

  static const _traceKey = 'boot_trace';
  static const _attemptKey = 'boot_attempt';
  static const _safeKey = 'boot_safe_mode';
  static const _versionKey = 'boot_version';

  /// 连续未完成启动达到这个次数就进安全模式。
  ///
  /// 为什么是 3 而不是 2：偶发的权限弹窗/系统杀后台也会让一次启动走不完，
  /// 直接跳安全模式会把用户辛苦配的导航栏清掉 —— 宁可多给一次机会。
  static const int safeThreshold = 3;

  static final List<BootStep> _mem = <BootStep>[];
  static SharedPreferences? _p;
  static bool _safe = false;

  /// 内存里的本次轨迹（给当前会话的日志页直接读，不用等落盘）。
  static List<BootStep> get current => List.unmodifiable(_mem);

  /// 本次是否处于安全模式。
  static bool get safeMode => _safe;

  /// 上次启动的轨迹（已落盘）。给「我的 → 日志」展示。
  static Future<List<String>> lastTrace() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getStringList(_traceKey) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  /// 启动最早期调用一次。
  ///
  /// 返回 true 表示本次进安全模式。**必须在 runApp 之前**调用，
  /// 且调用方要给它加超时（见 main()），它自己不做超时。
  static Future<bool> begin(String version) async {
    try {
      _p = await SharedPreferences.getInstance();
      final last = _p!.getString(_versionKey) ?? '';
      var n = _p!.getInt(_attemptKey) ?? 0;
      // 换了版本号就重置计数：新版本可能已经修好了，不该带着旧账进安全模式。
      if (last != version) {
        n = 0;
        unawaited(_p!.setString(_versionKey, version));
      }
      n += 1;
      unawaited(_p!.setInt(_attemptKey, n));
      _safe = n >= safeThreshold || (_p!.getBool(_safeKey) ?? false);
      if (_safe) unawaited(_p!.setBool(_safeKey, true));
      _mem.clear();
      _mem.add(BootStep('开始 v$version（第 $n 次尝试）'));
      unawaited(_flush());
      return _safe;
    } catch (_) {
      // 连 prefs 都拿不到 —— 不做诊断，也不要因此卡死启动。
      _safe = false;
      return false;
    }
  }

  /// 记一步。成功/失败都记；失败不抛。
  static void step(String name, {Object? error}) {
    _mem.add(BootStep(name, ok: error == null, error: '$error'));
    // 只保留最近 60 条，避免无限增长（正常一次启动 20 步以内）
    if (_mem.length > 60) _mem.removeRange(0, _mem.length - 60);
    unawaited(_flush());
  }

  /// 包一步：自动记时、自动兜异常，**失败不阻断后续步骤**。
  ///
  /// 这是整个启动加固的核心：每一步都是「尽力而为」，
  /// 没有哪一步配得上让用户看到黑屏。
  static Future<T?> guard<T>(String name, Future<T> Function() run,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final sw = Stopwatch()..start();
    try {
      final v = await run().timeout(timeout);
      step('$name ${sw.elapsedMilliseconds}ms');
      return v;
    } on TimeoutException {
      step(name, error: '超时 ${timeout.inSeconds}s');
      return null;
    } catch (e) {
      step(name, error: e);
      return null;
    }
  }

  /// 走到主界面了 —— 清掉失败计数。
  static Future<void> done() async {
    try {
      _mem.add(const BootStep('启动完成'));
      await _p?.setInt(_attemptKey, 0);
      await _p?.setBool(_safeKey, false);
      await _flush();
    } catch (_) {}
  }

  /// 上次启动是否处于安全模式（日志中心展示用）。
  static Future<bool> lastSafeFlag() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(_safeKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 手动退出安全模式（用户点了「恢复正常启动」）。
  static Future<void> exitSafeMode() async {
    _safe = false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_safeKey, false);
      await p.setInt(_attemptKey, 0);
    } catch (_) {}
  }

  /// 安全模式下的自愈：只清**界面类**配置。
  ///
  /// 明确**不动**：cloud_*（账号）、base/token（服务器）、书架/历史/进度、
  /// app_pin（应用锁）、任何内容缓存。用户丢的只是"长什么样"，
  /// 不丢"有什么"—— 这两者的区别决定了这个功能是救命还是添乱。
  static Future<List<String>> heal() async {
    final cleared = <String>[];
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in const <String>[
        'nav_modules',
        '_modsTrimmed',
        '_freeSrcMigrated',
        'nav_style',
        'nav_collapsed',
        'skin_id',
        'theme_mode',
        'accent_color',
        'splash_anim',
        'ui_text_scale',
        'nav_autohide',
        'nav_swipe',
      ]) {
        if (p.containsKey(k)) {
          await p.remove(k);
          cleared.add(k);
        }
      }
    } catch (_) {}
    return cleared;
  }

  static Future<void> _flush() async {
    try {
      await _p?.setStringList(_traceKey, _mem.map((e) => e.encode()).toList());
    } catch (_) {}
  }
}

/// 连 shared_preferences 都打不开时显示的说明页。
///
/// 这种情况重试也没用（设备层面的异常），所以**不假装能修**：
/// 把真实原因、上次启动轨迹、以及"清界面配置"这一个可行动作给出来。
/// 比黑屏强一万倍 —— 用户能截图，我们下一次就能定位。
class BootFailedApp extends StatefulWidget {
  const BootFailedApp({super.key});

  @override
  State<BootFailedApp> createState() => _Bfa();
}

class _Bfa extends State<BootFailedApp> {
  List<String> _trace = const [];
  bool _healing = false;
  String _note = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await Boot.lastTrace();
    if (mounted) setState(() => _trace = t);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0E1016),
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF5B8DEF), brightness: Brightness.dark)),
      home: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 44, color: Color(0xFFFF9F43)),
              const SizedBox(height: 16),
              const Text('应用没能启动',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFE8EAEF))),
              const SizedBox(height: 10),
              Text(
                '读取本地设置失败。这不是内容问题，通常重启一次就能恢复。\n'
                '如果反复出现，请把下面这段轨迹截图反馈。',
                style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: Colors.white.withValues(alpha: 0.72)),
              ),
              const SizedBox(height: 22),
              if (_trace.isNotEmpty) ...[
                const Text('上次启动轨迹',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final l in _trace)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(l,
                              style: TextStyle(
                                  fontSize: 11,
                                  height: 1.5,
                                  fontFamily: 'monospace',
                                  color: Colors.white.withValues(alpha: 0.62))),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
              ],
              FilledButton.icon(
                onPressed: _healing
                    ? null
                    : () async {
                        setState(() => _healing = true);
                        final c = await Boot.heal();
                        if (!mounted) return;
                        setState(() {
                          _healing = false;
                          _note = '已重置 ${c.length} 项界面配置，请重新打开应用。';
                        });
                      },
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: Text(_healing ? '处理中…' : '重置界面配置（不删内容）'),
              ),
              if (_note.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(_note,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF7BC47F))),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// release 下替代 Flutter 灰色错误块的兜底 widget。
///
/// 默认的 ErrorWidget 在 release 里是一块灰色方砖，用户看到只会说"坏了"。
/// 这里给一句人话 + 实际错误摘要，用户截图发过来就能定位。
///
/// 硬约束：**不能依赖 Theme / Localizations / MediaQuery 之外的任何 InheritedWidget**
/// —— 它可能在树的任何位置被替换进来，包括 MaterialApp 之上。
class BootErrorCard extends StatelessWidget {
  const BootErrorCard(this.details, {super.key, this.label});

  final FlutterErrorDetails details;
  final String? label;

  @override
  Widget build(BuildContext context) {
    // 从 MediaQuery 拿字号；拿不到就用默认（不能在 build 里抛）。
    double scale = 1.0;
    try {
      scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    } catch (_) {}
    final msg = '${details.exception}'.split('\n').first;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF1A1C22),
        padding: const EdgeInsets.all(16),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.report_gmailerrorred_rounded,
                color: Color(0xFFFF9F43), size: 28),
            const SizedBox(height: 10),
            Text(
              label ?? 'This part failed to draw',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: const Color(0xFFE8EAEF),
                  fontSize: 13 * scale,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              msg.length > 160 ? '${msg.substring(0, 160)}…' : msg,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: const Color(0xFF9AA1AE), fontSize: 11 * scale, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
