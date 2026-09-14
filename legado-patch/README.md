# Legado 对接（零改动路线 · 2026-09-14 定稿）

> ★ 路线变更：此前的"三自动补丁"（改 Legado 源码）方案**作废**——
> 架构铁律：**不改任何开源引擎的代码**。引擎官方原样运行,
> 后端通过它的官方 Web 服务调用, 结果转 IR 回前端。

## 开启即用（用户唯一动作：开一次 Web 服务）

```
1. 应用商店装【官方开源阅读 Legado】
2. Legado 设置 → Web服务 → 启动 (默认端口1122, 记下随机token)
   ※ Legado 设置里可勾"自动启动", 之后永久后台, 永不重复操作
3. 完成。ThirdHub 后端自动接管:
   - 自动发现/配对 (/v1/pair, 后端主动探测局域网1122)
   - 搜索/详情/目录/正文 全部转发给 Legado 官方引擎解析 (零适配)
   - 前端"后端"板块显示 Legado 在线状态+能力
```

## 用户不需要做的（后端全包）
- 不需要导入书源到 ThirdHub（书源在 Legado 里照常管理, 用户唯一手动项）
- 不需要改任何设置/规则（Legado 官方引擎=100%规则兼容, 跟官方更新）
- 不需要保持 Legado 界面打开（Web 服务后台常驻）

## 后端对接现状（server/index.js）
- search: /searchBook 转发 ✅ (Legado设备优先, 内置引擎兜底)
- detail: /getBookInfo 转发 ✅
- toc: /getChapterList 转发 ✅
- content: /getBookContent 转发 ✅
- sourceId 格式: legado:http://设备IP:1122, 前端无感

## 首次联调校准清单
- [ ] 实测 searchBook 响应字段名 (name/author/coverUrl/bookUrl 映射)
- [ ] 实测 getBookContent 正文格式 (纯文本/数组/带HTML)
- [ ] 鉴权头格式 (Authorization: token / 参数token)
- 实测结果更新本文件+微调 index.js 字段映射
