// ═══════════════════════════════════════════════════════════════════════════
// apple_gate.dart —— Apple 过审架构的「平台门」（阶段6）
//
// 背景（outputs/ThirdHub-苹果过审可行性-实证评估-20261010.md）：
//   指南 4.7.2 明文禁止「把原生 API 暴露给未嵌入二进制的软件」——
//   我们「引擎承载受限能力」的路线在 iOS 上会被直接拦。
//   ⇒ iOS 版必须分叉：**引擎只当纯 HTTP 数据源，原生能力全在 App 里**。
//   另有 5.2.3（音视频下载/聚合）⇒ iOS 关闭批量下载与第三方影视聚合入口。
//
// 这个文件就是那条分叉的**唯一收口**：所有「iOS 上要不要做」的判定集中在这里，
// 不许散落到业务代码里各判各的（散落 = 判定口径漂移 = 某处漏判直接被拒审）。
//
// ★ 纯 Dart（仅 dart:io，零 flutter 依赖）—— AppleGate 本身不碰平台 API，
//   自检（tool/apple_gate_selfcheck.dart）用显式枚举构造做行为断言；
//   只有 currentGate() 这一个函数碰 Platform.isIOS。
// ═══════════════════════════════════════════════════════════════════════════
import 'dart:io' show Platform;

/// 平台形态。用显式枚举而不是让业务代码直调 `Platform.isIOS`：
/// ① 可测（不需要真 iOS 环境）；② 一处注入、处处生效。
enum ApplePlatform { ios, android, other }

/// 当前版本是否提供第三方/社交登录（微信、QQ、Google…）。决定 4.8 是否触发。
/// 目前只有邮箱密码登录（**第一方**账号体系）→ false；
/// 一旦接入任何社交登录，把它改成 true —— 登录页的 Apple 登录按钮（4.8 强制项）
/// 会随 `needsSignInWithApple` 自动出现，不留"忘了加被拒审"的缝。
const bool kHasThirdPartyLogin = false;

/// 引擎端点是否属于「纯数据」端点（搜索/目录/正文/发现/源清单）。
///
/// 4.7.2 禁的是"把原生能力暴露给外部未嵌入软件"，纯数据检索在安全边界内；
/// 其余一切（执行、文件、剪贴板、通知、安装……）在 iOS（data-source 角色）必须拒。
/// 判定口径收口在这里，engine_direct 的 _get() 只负责执行 ——
/// 散到业务代码里各判各的 = 某处漏判 = 拒审。
bool isEngineDataEndpoint(String path) {
  const dataOps = {
    'meta', 'search', 'chapters', 'content', 'discover', 'explore', 'sources', 'info',
  };
  final seg = path
      .split('?')
      .first
      .replaceAll(RegExp(r'/+$'), '')
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  // /thp/<op>（旧草稿端点）
  if (seg.length == 2 && seg[0] == 'thp' && dataOps.contains(seg[1])) return true;
  // /thp/m/<module>/<op>（THP 规范端点）
  if (seg.length == 4 && seg[0] == 'thp' && seg[1] == 'm' && dataOps.contains(seg[3])) {
    return true;
  }
  return false;
}

/// 按 §5.3 功能减配表逐项落闸。字段名即审查条目，注释对应指南编号。
class AppleGate {
  const AppleGate(this.platform);

  final ApplePlatform platform;

  bool get isIOS => platform == ApplePlatform.ios;

  // ── 5.2.3 音视频下载/聚合 ──────────────────────────────────────────
  /// 批量下载（下载全书/全本/批量章节到本机）。iOS 关闭——
  /// 5.2.3 点名 "download multimedia files from third-party sources"，
  /// 小说正文虽非多媒体，但"批量落盘第三方内容"是同一审查视角的扣分项。
  /// （单章缓存属于阅读器正常行为，不在关闭范围。）
  bool get allowBatchDownload => !isIOS;

  /// 第三方影视/直播聚合源入口。iOS 只留用户自有源——
  /// 5.2.3 的"授权证明"我们拿不出来，唯一安全的边界是"只连用户自己的东西"。
  bool get allowThirdPartyVideoSources => !isIOS;

  /// 可替换桌面（launcher）。iOS 系统不允许，此闸防止相关入口在 iOS 出现
  /// （出现但不可用 = 2.1 完整性问题，"敬请期待"式占位会被拒）。
  bool get allowReplaceLauncher => !isIOS;

  /// 模块级开关：iOS 上整个模块不开放的名单。
  /// 「直播」= drpy 第三方直播源聚合（§5.3 影视/直播 ⚠️ 行）——
  /// iOS 不开放第三方采集源入口，而直播模块没有"用户自有源"形态，整体收掉。
  /// 「视频」不在此表：它保留用户自有的片库/历史，只收掉发现/搜索（见下 allowThirdPartyVideoSources）。
  bool allowModule(String key) => !(isIOS && key == '直播');

  // ── 4.7.2 引擎角色 ────────────────────────────────────────────────
  /// 引擎的角色：iOS 上只能是 'data-source'（纯 HTTP 搜索/目录/正文），
  /// 不得承载任何原生能力（相机/剪贴板/文件/通知）。
  /// Android 不受 4.7 约束，可为 'full'。
  String get engineRole => isIOS ? 'data-source' : 'full';

  /// 该引擎端点在当前平台是否放行（engineRole 的运行时执行口）。
  /// iOS：只放行纯数据端点；Android：全放（4.7.2 不适用于非 iOS）。
  bool allowEngineEndpoint(String path) =>
      engineRole != 'data-source' || isEngineDataEndpoint(path);

  /// 引擎安装/装载入口（把引擎"装进"App 的能力）。iOS 一律不开放——
  /// 4.7.2 的核心禁区。iOS 引擎连接只走「用户自己的设备 + 纯 HTTP」。
  bool get allowEngineInstall => !isIOS;

  // ── 4.8 / 5.1.1 / 5.1.2(i) 账号与披露 ────────────────────────────
  /// 有第三方登录就必须有 Sign in with Apple（4.8）。
  /// 当前只有邮箱密码登录（**第一方**账号体系）→ 不触发；
  /// 一旦接入社交登录，`kHasThirdPartyLogin` 置 true，登录页的 Apple 登录
  /// 按钮（4.8 强制项）随之自动出现——不留"忘了加被拒审"的缝。
  bool get needsSignInWithApple => kHasThirdPartyLogin;

  /// 有账号体系就必须 App 内能删号（5.1.1），恒要求。
  bool get needsAccountDeletion => true;

  /// 第三方 AI 数据披露（5.1.2(i)，2025-11 新增），恒要求。
  bool get needsAiDisclosure => true;

  // ── 2.1 完整性 ────────────────────────────────────────────────────
  /// 「敬请期待」式占位一个都不许留。此闸供自检遍历 UI 找占位（文本级检查
  /// 在 forbidden-words / 无头渲染验收里做，这里只留判定口径）。
  bool get allowsPlaceholders => false;

  /// 汇总导出（诊断 / 自检用）：每条 = 审查条目 → 当前平台的结论。
  Map<String, Object?> toMap() => {
        'platform': platform.name,
        'allowBatchDownload': allowBatchDownload,
        'allowThirdPartyVideoSources': allowThirdPartyVideoSources,
        'allowReplaceLauncher': allowReplaceLauncher,
        'engineRole': engineRole,
        'allowEngineInstall': allowEngineInstall,
        'needsSignInWithApple': needsSignInWithApple,
        'needsAccountDeletion': needsAccountDeletion,
        'needsAiDisclosure': needsAiDisclosure,
        'allowsPlaceholders': allowsPlaceholders,
      };
}

/// 常用入口：当前进程的平台门。
/// 全文件唯一碰 `Platform.isIOS` 的地方；判定逻辑全在 AppleGate 里。
AppleGate currentGate() {
  bool ios = false;
  try {
    ios = Platform.isIOS;
  } catch (_) {
    ios = false;
  }
  return AppleGate(ios ? ApplePlatform.ios : ApplePlatform.other);
}
