# ThirdHub 项目约束（OpenSpec 宪法）

> 任何 spec / 变更提案都必须服从本文。与 `docs/FRAMEWORK.md`、`docs/BENCHMARK.md` 冲突时，
> 以那两份为准，并回头修正本文。

## 1. 产品形态

- 一个产品 **ThirdHub**，不存在「v2 版 / v4 版」。版本号只是发布序号。
- 划分只有**两面**（前端 / 后端）与**两端形态**（移动端 / 桌面端）。
- 移动端形态：Android、iOS、鸿蒙、微信小程序、网页/PWA。
  桌面端形态：Windows、macOS、Linux、容器内浏览器。

## 2. 前端约束

- 前端**只做呈现与交互**：零源规则、零解析、零抓取逻辑。
- 业务代码中**禁止** `Platform.isAndroid/isIOS` 分支；平台差异只能出现在壳层与输入适配层。
- 所有界面文案必须走 `tr()` / `trf()`，新增键**当轮**补齐 6 种语言（fr/ru/es/ar/en/ja）。
- 文案 key **不得含换行**；多行拆多个 `Text`。
- UI **禁止 emoji** 当功能图标。
- 新增模块必须同时修改：`kModules` + `_coreMods` + `module_registry.dart`（webBoard=null）
  + 一次性迁移 + `changelog_logic.dart` 的 `ClogModules.all`。

## 3. 后端约束

- 后端是**能力面**，且**可以缺席**。每个板块必须回答「后端不在时剩下什么」。
- 改动走补丁层（`patch/` 目录 + 容器重启），不 `docker cp`。
- 媒体/内容接口的查询参数是 `q`，不是 `key`。
- 除 `/v1/meta|dl|auth|changelog|log/batch` 外，所有接口必须校验 `x-th-token`。

## 4. 质量闸门（合并前必须全绿）

| 闸门 | 命令 | 通过标准 |
|---|---|---|
| 静态分析 | `flutter analyze` | **0 error**（warning 不许新增） |
| 单元测试 | `flutter test` | 全绿 |
| i18n 完整 | `dart run tool/i18n_selfcheck.dart` | FAIL 0 |
| 硬编码文案 | `dart run tool/i18n_hardcoded_scan.dart` | 无新增 |
| 模块一致性 | `dart run tool/modules_selfcheck.dart`、`module_registry_selfcheck.dart` | 全 PASS |
| 更新日志 | `dart run tool/changelog_selfcheck.dart` | PASS |
| 品牌口径 | `dart run tool/branding_selfcheck.dart` | PASS |
| 代理协议 | `dart run tool/agent_proto_selfcheck.dart` | 全通过 |

## 5. 交付纪律

- 改前备份，`sha256` 一致再写。
- 提交只推真正改过的文件，禁 `-A`。
- 发版五通道：Release / 版本化包 / 别名包 / `latest-app.json` / 数据库 `th_changelog`，
  发完独立回读防 CDN 假红。
- **编译走 CI，不在本地出包。**
- 更新日志**面向使用者**：只说这版带来什么，禁止对话口吻、内部实现细节与机密。

## 6. 成熟度（对标大厂的验收尺）

R0 占位 → R1 可用 → R2 对齐 → R3 健壮 → R4 精致（定义见 `docs/BENCHMARK.md`）。
**更新日志只允许把 R≥2 的模块写成「新能力」。**

## 7. 每个变更提案必须写清

1. 它把哪个模块从哪一级推到哪一级；
2. 后端不在时它的行为；
3. 空态 / 错误态 / 弱网三种情况分别发生什么；
4. 新增的 i18n 键（如有）与 6 语言是否齐全；
5. 验收方式（可执行的检查，不是"看起来正常"）。
