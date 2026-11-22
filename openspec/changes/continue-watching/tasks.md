# 任务：继续观看

- [x] 1. 新建 `lib/core/continue_rail.dart`：`RecentEntry` 模型 + `ContinueRail` 横滑组件
- [x] 2. `main.dart` 增加 `openRecentEntry` 统一路由（视频/音乐/电台/回模块/未开启提示）
- [x] 3. `_RootNavState.jumpToModule` + 顶层 `thJumpToModule`（走 `_go`，保留模块 PIN 锁）
- [x] 4. 搜索页插入 `ContinueRail`（类型筛选之下、推荐带之上）
- [x] 5. 修「最近播放」列表缺 `onTap` 的缺陷，标题走 `tr()`
- [x] 6. 新增 4 个 i18n 键 × 6 语言（fr/ru/es/ar/en/ja）
- [x] 7. 新增 `test/continue_rail_test.dart`（6 项：解析、缺字段降级、hasTarget、caption 优先级、图标互异、未知类型兜底）
- [x] 8. 闸门：`flutter analyze` 0 error；`flutter test` 135 项全绿；
      i18n_selfcheck 29/29；hardcoded_scan 无新增；modules 202/202；module_registry 53/53；
      changelog 52/52；branding 13/13；agent_proto 191/191
- [ ] 9. 真机走查（需设备）：卡片点击四种分支、长按移除、断网时搜索页仍正常
- [ ] 10. 发版：五通道 + 更新日志（客户视角，写在「搜索」条目下，措辞为「打开就能接着上次看」）
