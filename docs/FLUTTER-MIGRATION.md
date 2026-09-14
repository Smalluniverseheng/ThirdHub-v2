# Flutter 前端迁移总表（从 ThirdHub 3.x 网页版 69 模块）

> 策略: 分批迁移, 双轨运行(3.x 网页版继续服务, v4 Flutter 逐批接班)。
> 每批完成即在 Flutter 启用该模块, 用户无感切换。

## 批次 P0: 核心增强（1-2 天）——让 v4 独立可用
| 3.x 模块 | Flutter 现状 | 动作 |
|---|---|---|
| bookshelf/search/detail/shelf-view | ✅ 已有(小说) | — |
| board-media(影视) | ✅ 已有(视频) | — |
| board-album(相册) | ✅ 已完成(iter6/7: 选照片上传+已同步网格+长按删) | — |
| live(直播) | ✅ 已完成(iter1: 频道搜索+网格+热词+直接播放) | — |
| download(下载管理) | ✅ 已完成(iter4/5: aria2任务3s轮询+进度条+添加链接) | — |
| board-clouddrive(网盘) | ✅ 已完成(iter9: WebView内嵌Cloudreve全功能) | — |
| register-page/onboarding/welcome | ✅ 已完成(iter8: 三页滑屏引导) | — |
| applock(应用锁) | ✅ 已完成(iter2/3: PIN启动锁+设置入口) | — |

## 批次 P1: AI 系（3-5 天, 12 模块）——DSH 解封后
| 模块 | 大小 | 说明 |
|---|---|---|
| ai-chat | 194KB | 主力对话(dsh 引擎/多会话/流式) |
| ai-settings | 65KB | 模型/密钥/参数配置 |
| dsh-console | 48KB | dsh 控制台(已冻结待官方) |
| dsh-remote | 27KB | 手机遥控 dsh(社区版已有) |
| tavern | 27KB | 角色卡 |
| ai-workspace/ai-workrail/ai-cron/ai-inspire/ai-float/agent-studio/dsh-chat | 8-14KB各 | 工作区/定时任务/灵感/悬浮会话/Agent工作室 |

## 批次 P2: 系统与管理（2-3 天）
| 模块 | 说明 |
|---|---|
| profile(71KB) | 个人中心/头像/账号 |
| server/server-panel/backend-center | 服务器管理(部分已被 v4 控制台覆盖) |
| storage/board-storage/keyvault | 存储用量/密钥库 |
| proxy-settings | 分流代理配置 |
| settings-sync | 多端设置同步 |
| feedback/devlog | 反馈/更新日志 |
| recycle-bin | 回收站 |
| community/nav-station/site-actions | 社区/导航站/站点操作 |

## 批次 P3: 已冻结/不迁移
| 模块 | 原因 |
|---|---|
| vip/pay | 会员冻结期不迁, 代码保留 |
| compute/devices/board-cloudphone/board-game | 二期评估 |
| pwa-install/shell-updater | 平台机制不同, 由 Capacitor/Electron 自管 |

## 执行纪律
- 每模块独立 commit, 完成后在本文档勾选
- UI 基准: 3.x 网页版交互(悬浮球已对齐), 视觉走 v4 暗色体系
- 数据源: 一律走后端 IR, 前端零解析铁律不破
