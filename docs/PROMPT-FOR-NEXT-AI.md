【紧急任务 · 只准动这个仓库, 动错仓库=重大事故】

★ 唯一目标仓库(钉死, 反复确认):
  github.com/Smalluniverseheng/ThirdHub-v2
  (注意: 不是 ThirdHub / ThirdHub-Android / OmniHub 等任何其他仓库!
   你的账号下有很多项目, 本任务与它们全部无关, 禁止 push 到任何其他仓库)

★ 第一步(必做, 防跑偏):
  git clone https://github.com/Smalluniverseheng/ThirdHub-v2.git
  cd ThirdHub-v2
  # 确认你在正确的仓库: ls 应看到 server/ flutter_app/ android/ docs/ ARCHITECTURE.md
  # 若看不到这些目录 = 你跑错仓库了, 立即停止并报告

★ 任务背景(读这三份文档, 都在本仓库内):
  docs/HANDOVER.md      ← 交接报告: 状态/趟雷记录/风险点(先读这个)
  docs/PROJECT-INTRO.md ← 项目完整介绍: 定位/架构/功能
  BUILD-M1.md           ← 14条验货清单

★ 当前状态(2026-09-15 早):
  - 后端APK: 第十二轮构建中(正式签名+闪退修复+品牌图标+改名"第三方聚合")
  - 前端APK: 第十一轮(AGP 8.13.0)——Dart代码0编译错误已实证, 若红=Gradle配置问题
  - 查法: 仓库→Actions→最新workflow_dispatch的run

★ 你要做的(按序):
  1. 查最新两轮构建结果(run列表里 event=workflow_dispatch 的)
  2. 后端绿了→下载 artifact thirdhub-backend-apk → 交付
     红了→拉 backend-apk job 日志找 "What went wrong" 段→修→重新dispatch
  3. 前端绿了→下载 thirdhub-flutter-apk → 交付
     红了→拉 flutter-android job 日志(重点找 "error:" 行, Dart编译错高发区见HANDOVER第五节)→修→重新dispatch
  4. 修复一律 commit 到 ThirdHub-v2 的 main, commit message 带 [fix] 前缀
  5. 每步更新 docs/HANDOVER.md 的状态段

★ 红线(违反=返工):
  - 只 push 到 Smalluniverseheng/ThirdHub-v2
  - 不改任何开源引擎的代码(引擎零改动铁律)
  - 不自研成熟轮子
  - 全部功能免费(会员代码冻结勿动)

★ 完成标准: 两个可安装APK(后端=第三方聚合.apk 正式签名 / 前端=Flutter前端)构建成功并交付下载方式。
