// 两种使用方式（4.81.104）
//
// 用户群体本来就分两类，之前代码里没有这个概念，导致**所有人都默认走「连后端」**
// 那条路：启动要花 6 秒去探测一个可能根本不存在的服务器，设置页到处是地址和密钥，
// 第一次打开的人自然以为「这软件要装服务器才能用」。
//
//   · lite（普通版）：只用手机。B站/红果/小说/漫画全部端上直连，不碰任何自建服务。
//   · pro （进阶版）：额外连接自己装在后端（NAS / 电脑 / 云主机），解锁离线下载、
//                     跨设备同步、远程访问。**后端始终是可选增强，不是前置条件。**
//
// 判据只存一个 prefs 键，不缓存到别处：模式是"用户意愿"，不是"运行状态"。
// 之前有没有连过后端（prefs 里的 base）用来给老用户做一次兜底判定，避免升级后
// 被重新问一遍 —— 已经在用后端的人显然是 pro。
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppMode {
  /// 只用手机，完全不连后端
  lite,

  /// 手机 + 自建后端（可选增强）
  pro,
}

class AppModeStore {
  AppModeStore._();

  static const String _kMode = 'th_mode';

  /// null = 还没做过选择（只有全新安装才会出现）
  static final ValueNotifier<AppMode?> mode = ValueNotifier<AppMode?>(null);

  /// 是否已明确选过。未选择时启动流程会走"轻量默认"，绝不当成 pro 去探测。
  static bool get decided => mode.value != null;

  static bool get isPro => mode.value == AppMode.pro;

  /// 启动时读一次。老用户（prefs 里已有后端地址）自动判定为 pro，
  /// 不再弹选择页 —— 他已经在用了，再问一遍等于把他刚配好的东西藏起来。
  static Future<AppMode?> load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_kMode);
    if (saved == 'lite') {
      mode.value = AppMode.lite;
      return mode.value;
    }
    if (saved == 'pro') {
      mode.value = AppMode.pro;
      return mode.value;
    }
    final base = (p.getString('base') ?? '').trim();
    if (base.isNotEmpty && !base.contains('supabase.co')) {
      mode.value = AppMode.pro;
      await p.setString(_kMode, 'pro');
      return mode.value;
    }
    mode.value = null;
    return null;
  }

  static Future<void> set(AppMode m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, m == AppMode.pro ? 'pro' : 'lite');
    mode.value = m;
  }

  /// 连接成功后由「我的后端」页调用：用户真的连上了，就切到进阶版。
  static Future<void> upgradeToPro() => set(AppMode.pro);

  /// 服务端地址被清掉/用户主动降级时回到普通版。
  /// 注意：只改模式，不清 base/token —— 用户随时可能再连回来。
  static Future<void> downgradeToLite() => set(AppMode.lite);
}
