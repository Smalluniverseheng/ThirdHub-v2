// 版本号的**唯一来源**（Dart 侧）。
//
// 为什么要有这个文件：版本号此前散在 5 个 Dart 文件里各写一遍
// （`main.dart` 的 Updater、`pro_kit.dart` 的批次号、`pro_system.dart` 上报的
// 系统信息、`ai.dart` 的 MCP clientInfo、`pubspec.yaml`）。它们不会一起失败，
// 只会**各自变陈旧**，而且很难发现：
//   · 4.40.0 那次漏改 `Updater.currentVersion/currentCode` → 装了新版仍被判成
//     旧版，反复弹升级提示（用户侧可见的怪象，排查半天）；
//   · `ai.dart` 的 MCP clientInfo 停在 `4.8.0` 整整几代没人注意，等于每次和
//     MCP 服务端握手都在谎报客户端版本。
// 所以 Dart 侧收敛到这里，改版本只改这一处 + `pubspec.yaml`（Flutter 要求版本
// 也写在 pubspec 里，无法引用 Dart 常量）。
//
// ★ 发版改这里时，必须同步改：
//   · `flutter_app/pubspec.yaml` 的 `version: x.y.z+code`
//   · `server/mcp-registry.js` / `server/routes-data.js` 里上报给外部的 version
//     字符串（Node 侧读不到 Dart 常量）
// 且改完必须**重新出包** —— 这是 Dart 代码改动，不重新编译就不会生效。
const String kAppVersion = '4.46.0';

/// 安卓 versionCode。语义：4.46.0 → 50533（与 pubspec 的 `+50533` 必须一致）。
/// 只增不减；`Updater` 用它与云端清单的 versionCode 比对来判断"有没有新版"。
const int kAppCode = 50533;
