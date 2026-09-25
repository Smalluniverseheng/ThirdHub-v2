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
//   · `flutter_app/pubspec.yaml` 的 `version: x.y.z+code`（Flutter 要求，引用不到常量）
//   · 仓库根 `README.md` 里写死的当前版本号（文档面，仅影响可读性）
//   Node 侧（`server/`）**不需要**再跟着改了：0.8.4 起后端版本号已收归
//   `server/package.json` 单一来源，`routes-data.js`(ping/MCP serverInfo) 与
//   `mcp-registry.js`(clientInfo) 全部改为运行时 `require` 读取。此前它们各自
//   硬编码，跟着客户端版本手工同步 —— 于是同一个后端从 /v1/meta 问是一个数、
//   从 /v1/ping 问是另一个数。凡"要手工同步的常量"迟早会漏，故彻底取消。
// 且改完必须**重新出包** —— 这是 Dart 代码改动，不重新编译就不会生效。
const String kAppVersion = '4.50.0';

/// 安卓 versionCode。语义：4.50.0 → 50537（与 pubspec 的 `+50537` 必须一致）。
/// 只增不减；`Updater` 用它与云端清单的 versionCode 比对来判断"有没有新版"。
const int kAppCode = 50537;
