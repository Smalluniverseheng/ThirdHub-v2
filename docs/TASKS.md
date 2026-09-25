# v2 总任务看板

> 五组并行, 各组只依赖协议文档。完成一项勾一项, 附 evidence。
> 顺序: P1先通(局域网书源链路), 其余并行跟上。

## 组A: 设备协议骨架(后端)
- [ ] THP-Device 发现服务(mDNS监听+手动添加UI)
- [ ] 握手/capabilities 注册 + devices 表
- [ ] 心跳状态机(30s/3次失败/degraded)
- [ ] SSRF 防护(仅内网/Tailscale网段)
依赖: DEVICE-PROTOCOL.md

## 组B: Legado 适配器
- [ ] ADAPTER-LEGADO.md 第1节 8项API验证清单逐项打勾
- [ ] fixtures 真实响应样本入库
- [ ] mapping.ts 方言→IR 映射 + 对拍测试
- [ ] 用户接入引导弹窗(首次连接+图文)
依赖: DEVICE-PROTOCOL.md §1/§2

## 组C: 能力路由
- [ ] routes 表 + 并行 fan-out + IR 合并去重
- [ ] 动态权重(健康度) + 自动禁用/恢复
- [ ] 短缓存 + 观测日志(request_log)
- [ ] 管理面板"源健康"页
依赖: CAPABILITY-ROUTER.md

## 组D: 双前端(网页+Flutter 并行, 见 FRONTEND-DUAL.md)
D1 网页轨道:
- [ ] build:web 基线 + Chrome74 语法门禁接入CI
- [ ] Electron 三平台(托盘/自启/验证窗)
- [ ] Capacitor Android+iOS(返回键/扫码/保活引导)
- [ ] tag 触发并行出包
D2 Flutter 轨道(纯IR渲染器, 不碰引擎):
- [ ] core 设施对接 v2 后端(ApiClient/WS/信封对齐THP) — 部分: Api/AES-256-GCM/THP 信封已通, **缺 WS 长连接**(现走 HTTP 轮询)
- [x] 模块对等表逐项: 书架→阅读器→搜索→播放器→AI chat→相册→work区 (2026-09-25 对等页全齐, 见总清单 D2)
- [x] 悬浮球 Dart 实现(对齐网页版行为基准) (FsExitOrb main.dart:13071 + NavOrb 模块面板, 位置持久化/吸边/拖排序)
- [x] 低端机模式 (main.dart:470-501 liteMode: 动画时长/分帧步长/图片缓存, 开关 UI 实测可切, 2026-09-26)
- [x] 7语言·核心链路 (i18n_extra 6 语言各 ~260 键 + tr() 三级回落 + i18n_selfcheck 锁 123 tr() 键 × 6 语言零回退; 引导页/停止弹窗/搜索页/个性化 2026-09-26 全过 tr)
- [ ] 7语言·存量清扫: main.dart 仍有 **482 处裸中文字面量**不过 tr() (回收站/下载弹窗/隐私协议/锁屏/设备发现等), 逐处清单见 docs/i18n-裸字面量存量清单.md
- [x] CI 出包(并入 tag 触发矩阵) (build-m1.yml v4*/v5* + build-apk.yml 支持 abis/publish 测试包入参)
依赖: FRONTEND-MATRIX.md + FRONTEND-DUAL.md

## 组E: 内置引擎
- [x] EnginePlugin 统一接口落地 ✅ 2026-09-25：`server/engine-plugin.js`（`:59` EnginePlugin / `:206` registry），四引擎注册表适配，`routes-media.js` 9 处 `registry.run`；`test_engine_plugin.cjs` pass=21 fail=0
- [ ] drpy QuickJS 沙箱跑通(真实源点播)
- [ ] venera/musicfree 沙箱兼容
- [ ] sources 数据包首启导入 + sync 脚本
依赖: BUILTIN-ENGINES.md

## 里程碑
- M1: 组B全勾 → 局域网Legado接入, 前端搜书看书 ✅验收
- M2: 组A+C完成 → 多源并联搜索+自动降级
- M3: 组E完成 → 影视/漫画/音源内置引擎全通
- M4: 组D完成 → 五端安装包全量发布
- M5: 多节点互联+BYOC(二期)

## 纪律
- 每完成一项: commit([组x] 任务名) + evidence + 勾选本看板
- 跨组接口争议: 以 DEVICE-PROTOCOL.md / IR 契约为准, 文档未覆盖的先补文档再实现
- 本看板是唯一进度真相源, HANDOFF 每日同步
