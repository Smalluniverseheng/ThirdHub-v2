# ThirdHub v4 今晚构建指南（M1）

> 目标: 安卓手机"搜书→阅读"全流程。
> 三个交付物已就位: 后端(server/) + 安卓壳(android/) + Flutter前端(flutter_app/)

## 1. 构建后端 APK（在电脑上）

```bash
# 准备 node-arm64 静态二进制(放android壳assets):
#   从 https://nodejs.org/dist/v20.x/node-v20.x-linux-arm64.tar.xz 解压,
#   取 bin/node → android/app/src/main/assets/node/bin/node
# 拷贝后端代码:
cp -r server android/app/src/main/assets/server
cd android && ./gradlew assembleRelease
# 产物: app/build/outputs/apk/release/app-release.apk
```

## 2. 构建 Flutter 前端

```bash
cd flutter_app
# 改 lib/main.dart 顶部 Api.base 为你的后端IP(首启引导二期)
flutter build apk --release
```

## 3. 使用（用户三步）

1. 装【ThirdHub 后端.apk】→ 打开 → 点"启动后端" → 通知栏看到地址和密钥
2. 装【ThirdHub 前端.apk】→ 打开 →（M1 改代码里的IP/密钥常量; 引导页二期）
3. 搜索 → 点开书 → 目录 → 阅读 ★通关★

## 4. 导入书源

前端二期做导入页; 今晚用 curl 导:
```bash
curl -k -X POST https://IP:9527/v1/sources -H "X-TH-Token: 密钥" \
  -H "Content-Type: application/json" -d @书源.json
# 或从 aoaostar 合集拉几条测试
```


## 4.5 导入书源(新方法, 告别curl)

```bash
cd server && npm install
node scripts/import-sources.js /path/to/书源合集.json   # 本地文件
node scripts/import-sources.js https://example.com/s.json # 或URL
node scripts/import-sources.js --demo                     # 演示源冒烟
```

## 4.6 Legado 改造版(可选增强, 三自动)

见 legado-patch/README.md: ①自动Web服务 ②mDNS广播 ③自动配对。
后端 /v1/pair 已就绪, 配对此处实现后设备自动接入。

## 已知M1边界（如实告知）
- Flutter证书校验暂全信任(TOFU引导二期)——仅局域网使用无风险
- 书源引擎支持 Legado 链式规则+XPath子集; 复杂@js规则尽力而为
- 悬浮球/相册/work区/网络插件 不在 M1 范围(见 docs/TASKS.md)

## 明早验收脚本
同 docs/M1-SPRINT.md 第4节。

---

## M1 迭代记录（iter1-16）

| 迭代 | 内容 |
|---|---|
| iter1 | 引擎修复(统一resolveList)+自动导源脚本 |
| iter2 | Flutter首启引导页(指纹TOFU)+pubspec补全 |
| iter3 | 引擎XPath规则支持+CORS+状态+书源启停 |
| iter4 | 安卓壳构建链补全(根gradle文件) |
| iter5 | Legado三自动补丁(AutoPairer+注入指南) |
| iter6 | 后端/v1/pair设备自注册+/v1/devices |
| iter7 | 搜索全源并行+书源自定义header |
| iter8 | CI: tag v4* 自动构建双APK发Release |
| iter9 | 图片章节(images数组)+/v1/img图片代理 |
| iter10 | Flutter图片章节Gallery渲染 |
| iter11 | 翻章导航条(上一章/下一章/进度)+加入书架+书架持久化 |
| iter12 | 正文净化(script/广告过滤)+跨源搜索去重 |
| iter13 | 抓取重试+TOC缓存10分钟+书源健康分 |
| iter14 | 阅读进度记忆(续读横幅) |
| iter15 | 安卓通知渠道修复(Android8+)+13+权限申请 |
| iter16 | 首启自动导入预置书源包 |

## 验货清单（装完对照）
- [ ] 后端APK装后通知栏出现"就绪"+地址+指纹
- [ ] 前端APK首启引导页连接成功+指纹确认对话框
- [ ] 搜索"诡秘之主"出现多源结果(带延迟ms显示)
- [ ] 点书名→目录页→点章→正文显示(无脚本残留)
- [ ] 底部"下一章"连翻3章
- [ ] 目录页右上角加入书架→书架页可见
- [ ] 杀掉前端重进→书架还在→进书显示"继续阅读"
- [ ] 目录页有书源延迟统计; /v1/status 有健康分

| iter17 | 预置演示书源(首启导入链路可验证) |
| iter18 | 目录分页 nextTocUrl(大书全目录) |
| iter19 | 正文翻页 nextContentUrl(修半章) |
| iter20 | POST搜索+JSON接口书源($.规则) |
| iter21 | Flutter悬浮球MVP(拖动/吸附/扇形菜单/遮罩) |
| iter22 | 搜索历史(10条+chips) |
| iter23 | Linux运行器(systemd+一键脚本)+书源导出端点 |

# M2 功能清单与验货（视频/漫画引擎已通）

## 三板块数据源一键导入
```bash
cd server && npm install
# 书源(小说): 从合集文件/URL
node scripts/import-sources.js /path/to/书源.json
# 影视源(drpy): 从dr_py仓库
node scripts/import-drpy.js --list          # 看清单
node scripts/import-drpy.js 剧              # 按关键词导(默认前50个)
# 漫画图源(Venera): 从venera-configs仓库
node scripts/import-comic.js --list
node scripts/import-comic.js                # 默认前30个
```

## M2 验货清单(在M1八条基础上追加)
- [ ] 视频板块: 搜索→选集→播放出画面(真实drpy源)
- [ ] 漫画板块: 搜索→章节→图片画廊加载(真实Venera图源)
- [ ] 首页聚合: 一次搜索出 书+漫+影 三组结果
- [ ] 图片二次加载秒开(X-TH-Cache: hit 头)
- [ ] 后端启动日志有自检横幅, 无 fail 项

## M2 迭代表
| iter | 内容 |
|---|---|
| iter3 | 视频前端真实链路(搜索/选集/播放) |
| iter4 | 修bug: sourceId缺失+线路flag丢失 |
| iter5 | 漫画前端真实链路(搜索/章节/画廊) |
| iter6 | import-comic.js+Venera生态+图片磁盘缓存 |
| iter7 | 聚合搜索/v1/search/all+首页板块 |
| iter8 | 启动自检横幅 |

## 音乐板块验货（追加）
- [ ] 音乐板块: 搜索→点击→播放页出声(真实音源)
- [ ] 播放过的歌自动入歌单(杀进程重进仍在)
- [ ] 首页聚合: 一次搜索出 书+漫+影+音 四组
- [ ] 后端启动自检横幅: 四元源数全显示, 无fail

## M2 迭代表（续）
| iter | 内容 |
|---|---|
| iter10 | MusicFree音源引擎+端点 |
| iter11 | 音乐板块前端(搜索/歌单/播放页just_audio+歌词) |
| iter12 | 聚合搜索四元(书漫影音) |
| iter13 | import-music.js+正文缓存30分钟 |

| iter14 | 搜索限流并发池(max3防封IP)+detail缓存5分钟 |
| iter15 | 源管理页(四类板块"源"选项卡: 列表/启停/删除/粘贴导入) |
| iter16 | 搜索历史补回(m2重构丢失修复) |

| iter17 | Web管理控制台(浏览器直开后端管四类源) |
| iter18 | 视频播放页选集联动(横向chips+上下集) |
| iter19 | 聚合搜索缓存60s+漫画预加载翻话 |
| iter20 | 控制台搜索测试页+小说翻章预加载 |

## 控制台使用(电脑浏览器)
后端启动后浏览器开 `https://后端IP:9527` → 输入密钥 →
五页签: 书源/影视源/图源/音源 管理(启停/删除/粘贴导入) + 搜索测试(四元同搜)。
不装前端APK也能管理全部。
