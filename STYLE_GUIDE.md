# ThirdHub v4 前端总纲（STYLE GUIDE）

> 适用于 `flutter_app/`（Flutter 前端）与 `server/`（家庭后端）的全部 UI 与对外文案。
> 每次改 UI 前必读。**本文件是强约束，不是建议。**

---

## 第 1 条 · 禁用 emoji（2026-09-19 起，用户拍板）

**UI 里一律不用 emoji 表情符号。** emoji 在不同平台/字体下渲染不一致（有的彩色、有的黑白、有的豆腐块），显得廉价且不专业。

**规则：**
- UI 图标一律用**矢量图标**：优先 `Icons.*`（Material），现有约定是 **Phosphor / Morphicons** 风格的细线图标语言。
- **禁止**在 `Text()` 里塞 emoji 当图标（如 `Text('📖')`）。
- 跨端下发的"图标"字段一律传**图标键**（字符串如 `book`/`movie`/`music`/`cloud`），由前端映射成矢量图标，**不传 emoji 字符**（已在 `routes-admin.js` ↔ `_engineIcon()` 落地）。
- 状态表达用 **色点 + 文字**（`Icon(Icons.circle, size: 8, color: …)`），不用 `●/☁/⚡` 这类符号字符。
- 允许例外：**代码注释**里的 `★`（重点标记）可以保留——它不进 UI。用户聊天输入框里的 emoji 是用户自己的内容，不管。

**清理方法（字节级扫描，Dart/JS 通用）：**
```powershell
# emoji 的 UTF-8 前缀：F0 9F（U+1F300+ 扩展平面）/ E2 98-99（BMP ☀☂ 等）
$b = [System.IO.File]::ReadAllBytes($f)
for ($i=0; $i -lt $b.Length-1; $i++) { if ($b[$i] -eq 0xF0 -and $b[$i+1] -eq 0x9F) { ... } }
```
注意：.NET/正则的 `\u{...}` 只覆盖 BMP，**扩展平面 emoji 必须用字节或代理对匹配**，否则会漏扫报"0 个"。

---

## 第 2 条 · 错误反馈三段式

所有用户可见的失败都带 `现象 / 原因 / 怎么办` 三段。绝不静默吞异常（`catch (_) {}` 后不给任何提示是禁止的）。

## 第 3 条 · 一致性

- 圆角：卡片 12，按钮 10-23（见各页既有值）；间距基准 8 的倍数。
- 主题色走 `Theme.of(c).colorScheme`，不硬编码品牌色（个别既有硬编码逐步收敛）。
- 新页面先复用既有模式：`ModuleHubPage`（聚合入口）、`NeuInset`/`NeuBtn`（拟态）、`statusRow` 等。
