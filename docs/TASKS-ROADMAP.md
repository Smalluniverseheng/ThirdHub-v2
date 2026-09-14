# ThirdHub v4 任务总规划（AI 接手文档）

> 最后更新: 2026-09-14 深夜 | 今天已完成 45+ 次迭代推送
> 接手流程: 读本文件 → 看 docs/FLUTTER-MIGRATION.md(模块迁移表) → BUILD-M1.md(验货清单)

## 〇、架构定位（2026-09-14 定稿）

```
前端 = Flutter  →  一套代码, 五端出包 (iOS/Android/Windows/macOS/Linux)
后端 = 同一份 Node.js 零原生依赖代码, 三种形态:
  ① Linux 服务器原生(systemd)  ← 主力
  ② Windows/macOS 原生(计划任务/launchd)
  ③ 安卓 APK 内嵌(node-arm64)  ← 旧手机变服务器
不是转译: Node 天然跨平台, server/ 一份代码三端跑
桌面端三件套构建: CI flutter-desktop job (自用未签名)
```

## 一、架构定稿（不可违背）
1. 前端=纯播放器, 零源规则零解析(法律边界) — ARCHITECTURE.md
2. 搜索路由=能力制: /v1/search?type=xx → 引擎按广播caps派发
3. 引擎=插件(改造开源软件), 局域网广播能力, 零配对自动接入
4. 前端模块化无首页; "我的"=统一设置中心(AppSettings)
5. 云端配额: 1MB/用户(头像<0.5MB, 设置共享其余); 进度存用户自己的后端
6. CF账号前后端都要登录(二期开关, 目前本地+后端SQLite)
7. ★ 引擎零改动铁律(2026-09-14): 不改任何开源引擎代码, 后端走官方Web服务调用+结果转IR; legado-patch补丁路线作废

## 二、已完成全景
| 层 | 状态 |
|---|---|
| 后端四引擎 | ✅ 书源(legado规则全格式)/影视(drpy沙箱)/漫画(Venera沙箱)/音源(MusicFree沙箱) |
| 后端服务 | ✅ TLS自签+密钥+mDNS+健康分+限流+三级缓存+图片代理+存储(cloudreve/aria2)+密钥库+设置/进度端点+Web控制台+自检 |
| 前端板块 | ✅ 搜索(类型路由)/小说/漫画/视频/音乐/直播/后端管理台/资源库(网盘+下载+相册+密钥库) |
| 前端系统 | ✅ 悬浮球七菜单/设置中心(AppSettings)/应用锁/首启引导/个人中心 |
| 生态导入 | ✅ 4脚本(import-sources/drpy/comic/music) |
| 插件 | ✅ Legado三自动补丁(legado-patch/) |
| CI | ✅ tag v4* 双APK自动构建 |
| 安卓壳 | ✅ 内嵌node后端APK(通知渠道/权限修复) |

## 三、待办清单（按优先级）
### P0 收尾
- [ ] 打tag v4.0.0-m2 → CI出包 → BUILD-M1.md 14条验货 → 修反馈bug
- [ ] 网盘完整浏览(现WebView嵌Cloudreve已够用, 原生浏览二期)
- [ ] 阅读器"分页模式"真实现(现占位scroll)

### P1 AI系（冻结中, 等DSH官方完善）
- [ ] ai-chat(194KB参考)/dsh-console/酒馆 等12模块迁移 (FLUTTER-MIGRATION.md)
- [ ] thirdhub-dsh-plugin 发布dsh生态
### P2 系统系剩余
- [ ] proxy-settings分流代理(后端出站代理)
- [ ] feedback/devlog/社区/导航站 等
- [ ] 头像/账号云端自动上传(框架已好, 接CF账号后启用AppSettings.sync())
### P3 二期评估
- [ ] CF账号登录(前后端)
- [ ] BYOC(用户绑自己CF)
- [ ] 多节点互联/家庭版分线(family-server重构)
- [ ] 云手机/游戏板块

## 四、已知边界（验货时重点看）
- 引擎覆盖: legado规则主流写法OK, 复杂@js/XPath高级语法尽力而为
- drpy: 模板.js依赖的源会报错跳过; jsencrypt源同
- Venera: Html代理层覆盖常用API, 边缘方法或缺
- 分页阅读: 占位
- 音乐后台播放: 无audio_service(切后台可能停)

## 五、工作纪律（沿用）
- 每步: git push([模块]格式) → 更新本文档/BUILD → evidence
- 文档未覆盖的问题: 先补文档再实现
- 不自研成熟轮子; 引擎沙箱隔离; 防封号六条
