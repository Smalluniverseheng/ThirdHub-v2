# ThirdHub AI 开发总清单规范（MASTER Inventory）

> 定版：2026-09-24 · 配套：ARCHITECTURE.md / docs/THP.md / docs/TASKS.md
> 目的：任何AI/创作者接手时，**只读这一份清单就能知道每个模块有什么、设置什么、逻辑是什么、改到哪了**。

---

## 一、三层文档体系（谁是真相源）

| 层 | 文件 | 性质 | 谁维护 |
|----|------|------|--------|
| 机器层（唯一事实源） | `modules/{id}/manifest.yaml` | 模块声明：功能/设置schema/工具/数据集合 | **AI每次改动必须更新** |
| 索引层（人读） | `docs/MASTER.md` | 从 manifest 自动生成，禁止手写 | CI 生成，AI不直接改 |
| 变更层 | `docs/MASTER-CHANGELOG.md` | 每次变更一条：日期/模块/改了什么/为什么 | AI每次改动必须追加 |

**规则：AI改代码不改清单 = 任务未完成。** 新AI接手顺序：MASTER-CHANGELOG → MASTER.md → ARCHITECTURE.md → TASKS.md。

---

## 二、manifest.yaml 标准模板

```yaml
# modules/novel/manifest.yaml
id: novel                      # 全局唯一，禁止改名（改名=新模块）
name: 小说
icon: 📖
status: stable                 # planned | dev | stable | deprecated
version: 4.44                  # 模块自身版本

routes:                        # 前端路由声明（Web/Flutter按此生成入口）
  - { path: shelf, name: 书架 }
  - { path: reader, name: 阅读器 }

features:                      # 功能清单（AI逐项打勾，接手者一眼看懂完成度）
  - { id: shelf_sync, name: 书架同步, status: done, note: changes游标同步 }
  - { id: tts, name: 听书, status: planned }
  - { id: batch_cache, name: 全书缓存, status: dev, note: 依赖后端jobs }

settings_schema:               # 设置项schema——两端按此自动生成设置页
  - { key: font_size, type: number, default: 18, scope: backend, label: 字号 }
  - { key: page_turn, type: enum, options: [slide, curl, none], scope: backend }
  # scope: cloud=账号级(云) / backend=设备级(后端) / local=会话级(前端)

logic:                         # 业务逻辑要点（AI用文字写清特殊规则/边界）
  - 换源规则: 健康度权重自动选择，连续3次失败降权至degraded
  - 正文归一: 一律经 novel-ir，前端永不接触源格式
  - 边界: 单章正文>5MB时截断并提示

data_collections:              # 本模块的数据集合（同步管道自动覆盖）
  - { name: shelf, sync: cursor, owner: backend }
  - { name: reading_progress, sync: cursor, owner: cloud }   # 进度小，可入云

tools:                         # AI工具注册（THP §11）
  - { name: novel.open, level: T1, params: { bookId: string, chapterIndex?: int } }

dependencies:                  # 依赖关系
  modules: [note, download]
  protocol: [/v1/m/novel/search, /v1/jobs]

changelog:                     # 模块级变更（每次改必加一行）
  - { date: 2026-09-21, change: 换源接入动态权重, why: M2验收要求 }
```

## 三、AI 工作守则（每次任务）

1. 开工前：读 `docs/MASTER-CHANGELOG.md` 最近20条 + 本模块 manifest
2. 改动后：**必须**更新对应 manifest（features状态/settings_schema/logic/changelog）
3. **必须**追加 `docs/MASTER-CHANGELOG.md` 一条：`[日期] [模块] 改了什么 → 为什么 → 影响面`
4. 新模块 = 新建 `modules/{id}/manifest.yaml` + MASTER.md 自动收录
5. 设置项新增 = 只加 schema 字段，禁止手改两端设置页代码
6. 任务结束输出交接摘要（供写入 AI-WorkLog 仓库）：
   `完成项 / 未完成项 / 给下一个AI的三句话`

## 四、云端 10MB 配额分配表（数据分级唯一口径）

| 存哪 | 内容 | 上限建议 |
|------|------|----------|
| ☁️ 云（CF） | 昵称/签名 | 4KB |
| ☁️ 云 | 头像（服务端强制压缩） | 200KB |
| ☁️ 云 | 账号设置（主题/语言/主页/模块开关） | 16KB |
| ☁️ 云 | 设备节点清单（名称/公钥/caps/状态） | 32KB |
| ☁️ 云 | 同步锚点（各集合cursor） | 16KB |
| ☁️ 云 | L3公钥+授权记录 | 8KB |
| ☁️ 云(可选,默认关) | 笔记/待办/书签加密文本备份 | 占剩余配额 |
| ☁️ 云(可选) | 阅读/播放进度 | KB级，含在上面 |
| 🏠 用户后端 | 一切媒体文件(blob)、书架主体、连接器/书源、播放器细粒度设置、审计日志、AI记忆、作业历史 | 不限 |
| ❌ 永不 | 用户内容明文上云 | — |

超限处理：拒绝写入+提示清理；头像服务端校验尺寸。

## 五、多端冲突策略（预设，勿临时发挥）

- 默认 LWW：同条数据 `hash+ts` 最后写入胜出
- 笔记类额外保留 5 个历史版本（可回滚）
- 同步锚点（cursor）单调不回退

---

*MASTER Inventory · AI与创作者的共同契约*
