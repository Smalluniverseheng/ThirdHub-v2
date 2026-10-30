# 官方源备份（ThirdHub）

本目录是**引擎内置源的独立备份与分类版**。上一次云端清理时，引擎仓里的
`assets/builtin-sources/comic-src` 被清成 0 字节，本目录是当时的恢复产物。

## 内容

| 路径 | 内容 | 条数 |
|---|---|---|
| `novel/sources-book-categorized.json` | 小说书源（Legado 格式），已按「类型 × 能力」分类 | 2664（启用） |
| `novel/_categories.json` | 分类统计 | 29 组 |
| `comic/js/*.js` | 漫画图源本体（venera 配置） | 33 |
| `comic/_manifest.json` | 图源清单与版本 | 33 |

## 分类口径

书源的 `bookSourceGroup` 按两个**用户真正关心**的维度打：

- **类型**：文本 / 听书 / 图片 / 文件（来自 `bookSourceType`）
- **能力**：可搜索 / 仅发现（`searchUrl` 为空就只能逛发现页）

认得出品牌的再加品牌前缀（起点系 / 晋江系 / 番茄系 …）。

分布（启用源）：

```
文本·可搜索 1486 | 文本·仅发现 460 | 接口型·文本 322 | TXT 站·文本 107
图片·可搜索 47  | 接口型·图片 37  | 晋江系·文本 30  | 阅文系·文本 27 …（共 29 组）
```

## 客户端怎么用

CDN（推荐，国内可达）：

```
https://cdn.jsdelivr.net/gh/Smalluniverseheng/ThirdHub-v2@main/sources/novel/sources-book-categorized.json
https://cdn.jsdelivr.net/gh/Smalluniverseheng/ThirdHub-v2@main/sources/comic/_manifest.json
```

## 维护

重新生成：见仓库外脚本 `_restore_sources.cjs`（拉 venera 图源 + 给书源打分类）。
**不要**用本目录覆盖引擎仓的内置包 —— 那是引擎运行时的格式，需引擎侧确认后再同步。
