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
