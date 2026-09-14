# ThirdHub 后端 APK 构建说明

## 前置(一次性, 手动)
1. 下载 Node arm64 静态二进制:
   https://nodejs.org/dist/v20.17.0/node-v20.17.0-linux-arm64.tar.xz
   解压, 取 `bin/node` 放到 `app/src/main/assets/node/bin/node`
2. 拷贝后端代码: `cp -r ../../server app/src/main/assets/server`
   (或 CI 里做: 见 .github/workflows/build-android.yml)

## 构建
./gradlew assembleRelease
产物: app/build/outputs/apk/release/app-release.apk

## CI(参考步骤)
- actions/checkout + setup-java(17)
- 下载node二进制解压到assets路径
- cp server → assets
- setup-android + gradle build
- 上传 APK 到 Release
