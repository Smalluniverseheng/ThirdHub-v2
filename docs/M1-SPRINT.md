# M1 今晚冲刺单（2026-09-14）

> 目标: 今晚开发者在手机上完成"搜书→阅读"全流程。
> 范围刻意收窄: 只有4件事, 全部做完才许睡觉。其余一切任务暂停。

## 1. 加密通信（前后端）

今晚落地两层:
- **一层 TLS**: 后端启动自动生成自签证书(局域网IP SAN), 前端首次连接
  弹指纹确认(TOFU), 此后固定。HTTP 明文端口仅 127.0.0.1 监听。
- **二层信封加密**: THP sealbox-v1 协议保留(设计已在 envelope.ts),
  今晚先实现"共享密钥模式"——首启向导生成 thsec_ 密钥对,
  前后端用 HKDF 派生通道密钥, 信封体 X25519+ChaCha20-Poly1305。
  完整 sealbox 密钥交换模式排二期。
- WS/SSE 同走加密通道; 局域网明文裸奔=验收不通过。

## 2. Linux 运行器（安卓+Windows）

今晚交付两个一键脚本:
- `install-android.sh`: Termux 内执行 → pkg 装 proot-distro →
  Ubuntu 内 curl 拉后端 → systemd 不行就 nohup 守护 → 打印访问地址+指纹。
  全程用户只复制粘贴一条命令。
- `install-windows.ps1`: 检测/启用 WSL2 → 拉镜像 → 注册自启 → 桌面快捷方式。
- 两脚本进 installer/ 目录, README 三步图文(初中水平可照做)。

## 3. Legado 最小闭环（组B 砍掉一切非必要）

只做4个端点桥接(其余 caps 全部 postpone):
`search / detail / catalog / content` → THP novel-IR。
- 先按 ADAPTER-LEGADO.md 第1节验证清单跑通 1122 API(逐项打勾+fixtures)
- 后端 /v1/novel/* 默认走内置书源引擎(legado-adapter, 已有实现),
  有 Legado 设备时结果合并; 无设备零安装可用
- TVBox能力=内置drpy引擎+JVM跑JAR, 同样不装TVBox App
- 前端: 现有网页版搜索/阅读页对接(不改 UI, 只换数据源)

## 4. 今晚验收脚本（开发者照做，零安装优先）

★默认路径=内置引擎，全程不装任何额外App:
1. 安卓手机: Termux 跑 install-android.sh → 看到"后端就绪 https://192.168.x.x:9527 指纹xxxx"
2. 浏览器开该地址 → 首次连接确认指纹 → 内置书源引擎已带预置书源包
3. 搜一本书 → 点开 → 翻三章 → ★今晚通关★

可选增强路径(有余力再做):
4. 装官方 Legado → 开Web服务(:1122) → 后端自动发现 →
   书源列表出现"Legado(局域网)"且结果合并 → 双通道验收
任一环节卡住=对应环节打回返工, 不许跳步。

## 纪律
- 今晚 commit 全部带 [m1-sprint] 前缀
- 每完成一项在本文档勾选 + evidence 截图
- 23:59 前完不成: 在 HANDOFF 如实登记卡点和明日第一个动作, 禁止虚报完成
