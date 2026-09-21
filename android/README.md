# ThirdHub 后端 APK 构建说明

## 前置(一次性, 手动)
1. 下载 Node arm64 静态二进制:
   https://nodejs.org/dist/v20.17.0/node-v20.17.0-linux-arm64.tar.xz
   解压, 取 `bin/node` 放到 `app/src/main/assets/node/bin/node`
2. 拷贝后端代码: `cp -r ../../server app/src/main/assets/server`
   (或 CI 里做: 见 .github/workflows/build-android.yml)

## 签名材料（不入库）
仓库里**不再保存** keystore 与口令（2026-09-21 起移出并加入 .gitignore）。三种来源，按优先级：
1. 环境变量（CI 从 secrets 注入）：`TH_STORE_FILE` / `TH_STORE_PASSWORD` / `TH_KEY_PASSWORD` / `TH_KEY_ALIAS`
2. 本地自建 `android/keystore.properties`（已被 .gitignore 排除）+ 同目录放好 `.jks`：
   `storeFile=thirdhub.jks` / `storePassword=…` / `keyAlias=thirdhub` / `keyPassword=…`
3. 两者都没有 → 仍可构建，但产出**未签名** APK（不能覆盖安装正式版）

> 提示：该密钥曾出现在公开仓库，按安全惯例**应当轮换**（重新生成 keystore 并同步更新 secrets）。

## 构建
./gradlew assembleRelease
产物: app/build/outputs/apk/release/app-release.apk

## CI(参考步骤)
- actions/checkout + setup-java(17)
- 下载node二进制解压到assets路径
- cp server → assets
- setup-android + gradle build
- 上传 APK 到 Release
