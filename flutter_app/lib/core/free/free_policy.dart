// 内容授权与分发形态的**闸门**。
//
// 这个文件只做一件事：回答「这个东西允许出现在哪种形态的 App 里」。
//
// 为什么需要它
// ------------
// 同一个 App 会被打包成两种形态：
//   · 移动端（Android / iOS / 鸿蒙 / 小程序 / 网页）：**要上架、要过审**。
//     因此只允许「公版 / CC 授权 / 平台官方 API / 用户自有」这四类内容来源。
//   · 桌面端（Windows / macOS / Linux / NAS 容器）：**不上架，部署者自负**。
//     允许运行用户自行配置的抓取规则，把素材转成标准格式（EPUB / CBZ / MP3 / MP4），
//     再通过局域网交接到移动端 —— 移动端拿到的**只是一份本地文件**，不承担来源责任。
//
// 于是「合规」不是一句文案，而是一条**能在编译期和单测里被验证的边界**：
// 移动端构建里根本不存在抓取源的注册项，桌面端才注册。
//
// 铁律
// ----
// 1. 任何新源必须显式声明 [LicenseKind]，没有默认值。写不出来源和授权，就不该进库。
// 2. [LicenseKind.thirdPartyRule] 与 [LicenseKind.scraped] **永远**不得进 mobile。
// 3. 这条规则由 `test/free_policy_test.dart` 与 `tool/free_policy_selfcheck.dart` 双向锁死。
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'free_models.dart';

/// 运行形态。决定「允许哪些内容来源」。
///
/// 注意：判定的依据不是操作系统名字，而是**这份二进制要不要上架**。
/// 容器里的网页、NAS 上的桌面版，都算 [desktop]。
enum Audience {
  /// 要上架 / 要过审的形态。只允许合规来源。
  mobile,

  /// 自建、不上架的形态。允许用户自行承担责任的来源。
  desktop;

  bool get isMobile => this == Audience.mobile;
  bool get isDesktop => this == Audience.desktop;

  /// 人类可读名（用于法律说明与调试页）。
  String get label => this == Audience.mobile ? '移动端' : '桌面端';
}

/// 合规闸门。所有「这个源能不能显示」的判断都必须走这里。
class FreePolicy {
  FreePolicy._();

  /// 编译期覆盖：`--dart-define=TH_AUDIENCE=desktop`。
  ///
  /// 为什么需要编译期开关：桌面端与移动端可能**同一份源码**构建，
  /// 只靠 `Platform` 判断会让「在 Linux 上跑测试」意外拿到桌面端集合。
  static const String _forced =
      String.fromEnvironment('TH_AUDIENCE', defaultValue: '');

  /// 当前运行形态。
  ///
  /// 判定顺序：编译期覆盖 > 平台 > 兜底 desktop。
  /// 兜底给 desktop 的理由：拿不准的时候**少放行**比多放行安全 ——
  /// 桌面端下多露出一个源不会导致上架失败，移动端多露出一个会。
  static Audience get audience {
    switch (_forced.toLowerCase()) {
      case 'mobile':
        return Audience.mobile;
      case 'desktop':
        return Audience.desktop;
    }
    // 鸿蒙当前走 Android 兼容层，Platform.isAndroid 为真，天然落在 mobile。
    // Web 构建按 mobile 处理：它是公开形态，同样要过「合规」这一关。
    if (kIsWeb) return Audience.mobile;
    if (Platform.isAndroid || Platform.isIOS) return Audience.mobile;
    return Audience.desktop;
  }

  /// 单个源是否允许在当前形态出现。
  static bool allows(FreeSource s, {Audience? as}) =>
      (as ?? audience).isDesktop || s.license.mobileSafe;

  /// 过滤一批源。顺序保持入参顺序（各板块自己的展示顺序不能被这里打乱）。
  static List<FreeSource> filter(List<FreeSource> all, {Audience? as}) =>
      [for (final s in all) if (allows(s, as: as)) s];

  /// 被挡掉的源（用于「为什么我这里看不到 XX」的说明页，而不是静默消失）。
  static List<FreeSource> blocked(List<FreeSource> all, {Audience? as}) =>
      [for (final s in all) if (!allows(s, as: as)) s];

  /// 移动端纯净性自检：返回违反规则的源列表，空表示通过。
  ///
  /// 被 `tool/free_policy_selfcheck.dart` 与 CI 调用。
  static List<FreeSource> mobileViolations(List<FreeSource> all) =>
      [for (final s in all) if (!s.license.mobileSafe) s];

  /// 「为什么这个源在我的形态里看不到」的**文案模板**。
  ///
  /// 这里只给模板不给成品句子：成品要用 `trf()` 渲染，
  /// 否则 6 种语言下会突然冒出中文。占位符是 `{n}` = 源名、`{l}` = 授权性质。
  static const String blockReasonTpl =
      '「{n}」的内容来源为{l}，仅可在桌面端使用。'
      '移动端只接受公有领域、开放许可、官方公开接口与自有内容四类来源。';

  /// 当前形态下需要桌面端才能用的源（本板块）。
  static List<FreeSource> desktopOnly(List<FreeSource> all) =>
      [for (final s in all) if (!s.license.mobileSafe) s];
}
