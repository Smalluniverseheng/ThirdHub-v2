# 设计：继续观看

## 数据来源

`lib/core/recents.dart` 已有的 `Recents`（SharedPreferences 键 `recent_play`，
上限 60 条，按时间倒序）。写入侧四个点已在生产：

| kind | 写入位置 |
|---|---|
| `music` | `MusicPlayPage` 解析出直链后 |
| `video` | `LocalVideoPlayerPage.initState` |
| `audiobook` | `mini_modules8` 选目录连播时 |
| `radio` | `mini_modules4` 点电台播放时 |

不新增存储，不改写入侧 —— 避免「两套历史」再次分叉。

## 组件边界

```
ContinueRail (StatefulWidget, lib/core/continue_rail.dart)
  ├─ 读：Recents.list() → List<RecentEntry>
  ├─ 显示：横滑卡片（kind 图标 / 类型角标 / 标题 2 行 / 副标题或时间）
  ├─ 点击：widget.onOpen(entry)   ← 交给宿主
  └─ 长按：Recents.remove() + 提示
```

**为什么打开动作不写在组件里**：判断「这条能不能真续播」需要 `LocalVideoPlayerPage`、
`MusicPlayPage`、`RootNav` 三样东西，全在 `main.dart`。写进组件会让组件和 18,500 行的
`main.dart` 互相 import。用回调，组件能在搜索页与最近播放页复用，且可单测。

## 路由规则

`openRecentEntry(BuildContext, RecentEntry)`（`main.dart` 顶层函数）：

| 条件 | 动作 |
|---|---|
| `kind == video` 且 `target` 非空 | `LocalVideoPlayerPage(item: {name, path})` |
| `kind ∈ {music, radio}` 且 `target` 非空 | `MusicPlayPage(item: {name, url, artist})` |
| 其它 | `thJumpToModule(模块名)` |
| 跳转失败 | SnackBar：「{{m}}」不在底部导航里，请到「我的 → 功能管理」开启 |

跳模块走 `_RootNavState.jumpToModule` → `_go`，**模块 PIN 锁照常生效**
（不能因为从最近播放点进来就绕过用户自己设的锁）。

## 生命周期

- `initState` 读一次；`didChangeAppLifecycleState == resumed` 再读一次
  （否则刚看完一集回到搜索页，顺序还是旧的）。
- 读失败或空列表 → `SizedBox.shrink()`，不占位、不留白条、不报错。

## 为什么不做封面

`Recents` 只存 `kind/title/sub/target/at`。要封面得改四个写入点并在每处拿到封面 URL，
属于另一项改动（且会给历史数据做兼容）。当前用「类型图标 + 标题 + 副标题」表达，
信息量足够区分条目，视觉上也比灰块假封面诚实。

## 验收

1. `flutter analyze` 0 error。
2. `flutter test` 全绿（含新增 6 项）。
3. 有播放记录时，搜索页首屏出现横滑带；无记录时不出现任何空白条。
4. 点本地视频卡片 → 进播放器并从上次位置继续。
5. 长按卡片 → 该条消失且提示「已移除」。
6. 「最近播放」列表任一行可点，行为与卡片一致。
