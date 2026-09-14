# ThirdHub v4.0.0

> 版本: **4.0.0-draft** | 架构: 局域网设备编排 | 状态: 设计冻结，M1冲刺中

## 这是什么

ThirdHub 的架构大版本跃迁——从"单体聚合站"进化为**局域网设备编排平台**:
开源应用(Legado/Komga/Audiobookshelf)以官方原版运行在用户局域网内,
家庭后端通过官方API发现/编排; 无API的开源项目(drpy/Venera/MusicFree)
以"规则+内置引擎"收编; 一切能力归一为IR, 前后端严格分离。

## 与 ThirdHub(3.x) 的关系

| 仓库 | 定位 | 版本 |
|---|---|---|
| **ThirdHub-v2(本仓)** | v4.0.0 新架构实施主场 | 4.0.0 起 |
| ThirdHub(原仓) | 3.x 维护线, 现有线上产品继续服务 | 3.x |

3.x 用户不受影响; 4.0.0 成熟后提供迁移工具(书源/进度/设置)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 架构总纲(设计哲学/架构图/路由/路线图/五组分工) |
| [docs/M1-SPRINT.md](docs/M1-SPRINT.md) | **今晚冲刺单**(加密/Linux运行器/Legado闭环/验收脚本) |
| [docs/TASKS.md](docs/TASKS.md) | 五组任务看板 M1-M5 |

(协议细则/路由细则/前端矩阵/双前端/内置引擎/资产处置等配套文档
正从 ThirdHub 仓迁移, 迁入后更新本索引)

## 快速开始(今晚验收)
1. 装官方 Legado → 设置→Web服务→启动(:1122)
2. 设备跑 install-android.sh (Termux) 或 install-windows.ps1 (WSL2)
3. 浏览器开 https://后端地址:9527 → 确认指纹 → 搜书看书
