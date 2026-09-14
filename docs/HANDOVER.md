# ThirdHub v4 交接报告（给接手 AI）

> 生成: 2026-09-15 00:10 | 前一任: Kimi(会话执行) | 仓库: Smalluniverseheng/ThirdHub-v2
> 今天 70+ 次迭代推送, 41 文件, CI 趟雷 10 颗全部排掉。

## 一、项目一句话
全平台聚合站: Flutter 纯播放器前端 + Node.js 四引擎后端 + 开源引擎零改动对接(Legado 官方 Web 服务)。
架构六铁律见 ARCHITECTURE.md(前端零源规则/能力路由/引擎零改动/模块化/1MB配额/CF账号二期)。

## 二、交接时点状态
- ✅ 后端 APK: 已构建成功并交付(v4.0.0-m2, 42MB, debug 签名可装)
- 🔄 前端 APK: 构建中(run#34866265046, Actions页查)——绿了下载 artifacts 即是; 红了见第四节

## 三、接手第一件事(按序)
1. 查 run#34866265046 结果
2. 绿→下载 `thirdhub-flutter-apk` artifact(zip里即APK); 红→拉"Run cd flutter_app"步骤日志找 `error:`/`FAILURE` 行(大概率 Dart 编译错, 见第五节)
3. 两个 APK 到手→手机真机按 BUILD-M1.md 14 条验货(重点: 导书源搜书/四板块/后端控制台 :9527)
4. 验货 bug 按模块修(引擎类→engine*.js 的 IR 映射; UI类→main.dart)

## 四、CI 趟雷记录(全已修, 勿回退勿重踩)
1. workflow YAML: Windows路径 `\w` 非法转义 → 正斜杠
2. node二进制: tar strip 对成员名匹配无效 → 全解压再 mv
3. Flutter 缺 android 宿主目录 → 补 8 文件骨架(settings/build.gradle.kts/app/Manifest/MainActivity/styles/drawable)
4. settings.gradle.kts: Groovy 语法在 .kts 里非法 → Kotlin DSL 版
5. gradlew wrapper 缺失(二进制 jar 无法文本入仓) → CI 用系统 gradle 现场生成
6. google() 带 content 过滤误挡 androidx.databinding → 去过滤裸写
7. 图标 mipmap 缺失(二进制推不了) → drawable shape 占位
8. flutter 构建顺序: wrapper 在 pub get 前, settings 读不到 local.properties → pub get 在前
9. 后端 release 未签名不可装 → assembleDebug(debug 签名)
10. Flutter 版本门槛: Gradle≥8.14 + AGP 8.9.1 + Kotlin 2.1.0(此前 8.7/8.5.2 过低)

## 五、Dart 代码风险点(编译错高发区)
main.dart 65KB 单文件, 60+ 轮迭代+批量字符串替换。已知处理:
- 86 处 UI 词条 tr() 化(中文key, core/i18n.dart)
- 41 处 const+tr 非法组合已修(const 上下文禁调函数)
- tabs 已改 getter(static const 不能含 tr)
- 仍可能漏网: 编译报错按行号修, 模式固定(const Text(tr(...))→去const 或 tr 提为变量)
- 依赖: pubspec 含 http/shared_preferences/video_player/chewie/just_audio/photo_manager/webview_flutter/image

## 六、已知边界(占位/缺失, 非bug)
- Legado 对接按官方 api.md 校准(WS搜索:1235/正文index映射/无鉴权/端口动态)——真机首联调按 legado-patch/README.md 校准清单核对响应字段
- engine.js(书源)是兜底引擎(规则90%覆盖), 主路径=Legado 原版转发
- 分页阅读/后台音乐播放/后端错误消息双语/RTL = 占位或缺失
- fr/ru/es/ar 词典仅核心词(回落中文)
- docker-server CI job 失败=server/ 缺 Dockerfile(未写, 需要可补)
- 桌面端三件套 job 常被免费版并发限流 cancelled(正常, 重跑即可)
- 会员/卡密: 全功能免费, 会员代码冻结勿动

## 七、文档地图(先读这四份)
ARCHITECTURE.md(架构铁律) → docs/TASKS-ROADMAP.md(任务规划+P0-P3) → docs/FLUTTER-MIGRATION.md(69模块迁移表) → BUILD-M1.md(14条验货+迭代表)

## 八、代码地图
server/index.js(网关全端点) / engine.js(书源兜底) / engine-drpy|comic|music.js(三沙箱)
flutter_app/lib/main.dart(全部前端) / core/neu.dart(新拟物) / core/i18n.dart(多语言)
android/(后端壳) / legado-patch/README.md(引擎对接指南)

## 九、纪律(沿用)
每步: git push([模块]格式)→更新文档→evidence; 不自研轮子; 引擎沙箱隔离; 防封号六条;
引擎对接先拉官方 api.md 再写代码; 全部功能免费。
