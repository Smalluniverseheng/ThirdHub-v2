# vendor —— 开源对标与移植台账

这个目录只有一个用途：让「我们抄了哪个项目、抄了什么、为什么有的抄不了」变成**可核查的事实**，而不是聊天记录里的说法。

## 怎么读

- `MANIFEST.json`：机器可读的台账。`upstreams` 是上游项目的锁定版本（repo + commit + 许可证），`ported` 是已经落进 App 的文件及改编说明，`planned` 是排期中的，`blocked` 是被许可证挡住的。
- `_upstream/<name>/`：上游原始文件镜像（含 LICENSE、COMMIT.txt、依赖评估表）。**不参与编译**，也不是我们的代码。
- `flutter_app/tool/vendor_manifest_selfcheck.dart`：闸门。台账与实物不一致就非零退出。

## 三条硬规矩

1. **搬不动的就说搬不动。** 每个上游文件都要统计 import / `part of`；「没有 import」不等于「没有依赖」——Venera 的 7 个 reader 文件全是 `part of 'reader.dart'`，共享同一作用域。
2. **许可证按三档分层**：宽松（MIT/Apache/BSD/ISC）可直接搬进移动端；传染（GPL/AGPL）只在桌面端/自托管侧；EULA/未声明视为保留所有权利，**不搬代码**。
3. **`ported` 里的每个本地文件，头部必须写明上游 repo@commit 与许可证**，否则闸门报错。

## 当前结论（2026-11-07）

| 模块 | 上游 | 许可证 | 结论 |
|---|---|---|---|
| 漫画阅读器 | **kodjodevf/mangayomi** | **Apache-2.0** | **主对标，可搬可上架**；`reader_view.dart` 1372 行 / 54 imports，按依赖闭包分 2~3 轮 |
| 漫画运行规则 | venera-app/venera | GPL-3.0 | 已提取规则（`comic_reader_rules.dart`）；整套 UI 只走桌面端 |
| 音乐播放器 | anandnet/Harmony-Music | GPL-3.0 | 真正开源但传染；先定许可策略再动代码 |
| 音乐播放器 | namidaco/namida | **EULA（非开源）** | **不可搬**，此前判断错误，已纠正 |
| 影视 | dart_simple_live / Kazumi | GPL-3.0 | 待许可决策 |
