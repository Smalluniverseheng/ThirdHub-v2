# 第三方组件清单（server/vendor/）

> 目的：把 `vendor/` 下**随仓库分发**的二进制/第三方代码列清来源与许可证。
> 只登记实际情况；没能核实的**如实标注「待确认」**，不猜。
>
> 最后更新：2026-09-21

本仓自身许可见根目录 `LICENSE`（MIT）。以下组件各自适用其原许可证。

---

## 1. aria2 —— 下载引擎（含 BT / 磁力）

| 项 | 值 |
|---|---|
| 文件 | `vendor/aria2/aria2c.exe`（5.6 MB）+ `vendor/aria2/COPYING`（18 KB） |
| 版本 | 1.37.0（按构建记录） |
| 许可证 | **GPL-2.0**（`vendor/aria2/COPYING` 即 GPL-2.0 全文，随文件一并分发） |
| 上游 | https://github.com/aria2/aria2 |
| 用途 | 后端 `/v1/dl/*` 的磁力 / BT 种子 / 直链下载；由 `server/index.js` 以**独立子进程**方式调用（`spawn`），不做链接、不改其源码 |

**GPL-2.0 的影响，说清楚：**

- aria2 与本项目是**两个独立程序**，通过命令行/子进程交互，属于「聚合分发」
  而非「衍生作品」；因此本项目的 MIT 授权不受传染。
- 但**分发时仍必须**：① 附上它的许可证（已随 `COPYING` 分发）；
  ② 提供对应源码的获取方式（即上面的上游地址，本项目未修改它）。
- 若将来本仓要改为**闭源分发**，aria2 这部分需单独复核 —— 它是本目录里唯一
  的非宽松许可证组件。
- 注意：本仓 `server/agent-plugins.json` 的插件策略把 GPL 列入 *deny*。
  那条规则约束的是 **DSH 插件**（它们会与进程内代码相互链接），
  与这里「独立可执行文件」的情形不同，两者不矛盾。

---

## 2. drpy —— 源规则运行时脚本

| 文件 | 许可证 | 说明 |
|---|---|---|
| `vendor/drpy/crypto-js.js` | **MIT** | CryptoJS（UMD 构建，标准 MIT） |
| `vendor/drpy/gbk2.js` | **MIT** | 文件头已声明：`gbk.js v0.3.0`，https://github.com/cnwhy/GBK.js |
| `vendor/drpy/drpy2.min.js` | **待确认** | 见下 |

**关于 `drpy2.min.js` 的诚实说明**：该文件是 drpy 项目的压缩产物，**文件内没有
附带许可证声明**，我在本次核对中也未能从可靠来源确认其确证许可证。
引用它的来源应为 drpy（`hjdhnx/dr_py` 系列）。在确认之前：

- 视为**许可证未明**，不对外声称它是 MIT；
- 若要用于闭源分发或商业分发，**必须先向上游确认**；
- 已知它运行时依赖 `cheerio` / `jsencrypt` / 本仓的 `crypto-js.js` 等。

---

## 3. Node 依赖（由 npm 安装，不随仓库分发）

`server/package.json` 声明：`cheerio`、`selfsigned`、`bonjour-service`。
这些通过 `npm install` 获取，各自的许可证随包分发，不在本仓内。
`server/node_modules/` 已在 `.gitignore` 中，不入库。

---

## 4. 维护约定

新增 `vendor/` 下的任何二进制或第三方脚本时，**必须同时**：

1. 在本文件登记「文件 / 版本 / 许可证 / 上游 / 用途」；
2. 把许可证原文一并放进对应子目录（能拿到就拿）；
3. 拿不到许可证的，按上面 `drpy2.min.js` 的方式**明确标注待确认**，
   不得含糊写成「开源」了事；
4. 若是 GPL / AGPL / SSPL 类，必须在本文件写清传染性影响与合规前提。
