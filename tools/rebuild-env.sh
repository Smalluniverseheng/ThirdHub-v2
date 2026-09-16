#!/bin/bash
# ThirdHub 构建环境一键重建（沙箱 /tmp 会丢，此脚本在 /mnt 持久化）
# 用法: bash tools/rebuild-env.sh  →  完成后 bash tools/do-build.sh
set -e
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

cd /tmp
# ── JDK 17（沙箱只有 JRE，javac 缺失）──
if [ ! -x /tmp/jdk-17.0.20.1+1/bin/javac ]; then
  echo "== JDK17 =="
  curl -sL -o jdk17.tar.gz "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_x64_linux_hotspot_17.0.20.1_1.tar.gz"
  tar xzf jdk17.tar.gz
fi
export JAVA_HOME=/tmp/jdk-17.0.20.1+1
export PATH=$JAVA_HOME/bin:$PATH

# ── Flutter SDK ──
if [ ! -x /tmp/flutter/bin/flutter ]; then
  echo "== Flutter =="
  curl -sL -o flutter.tar.xz "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.4-stable.tar.xz" \
    || curl -sL -o flutter.tar.xz "https://mirrors.tuna.tsinghua.edu.cn/flutter/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.4-stable.tar.xz"
  tar xf flutter.tar.xz
  git config --global --add safe.directory /tmp/flutter || true
fi
export PATH=/tmp/flutter/bin:$PATH

# ── Android SDK ──
if [ ! -d /tmp/android/platforms/android-35 ]; then
  echo "== Android SDK =="
  mkdir -p /tmp/android/cmdline-tools
  curl -sL -o cmdtools.zip "https://mirrors.cloud.tencent.com/AndroidSDK/commandlinetools-linux-11076708_latest.zip" \
    || curl -sL -o cmdtools.zip "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  unzip -q -o cmdtools.zip -d /tmp/android/cmdline-tools
  mv /tmp/android/cmdline-tools/cmdline-tools /tmp/android/cmdline-tools/latest 2>/dev/null || true
  export ANDROID_HOME=/tmp/android
  yes | /tmp/android/cmdline-tools/latest/bin/sdkmanager --sdk_root=/tmp/android \
    "platforms;android-35" "platforms;android-36" "build-tools;35.0.0" "ndk;28.2.13676358" || true
fi
export ANDROID_HOME=/tmp/android

# ── 构建副本 + 低内存 Gradle 配置（4GB 沙箱）──
echo "== build copy =="
rm -rf /tmp/build_app
cp -r /mnt/agents/work/th/flutter_app /tmp/build_app
cd /tmp/build_app
cat >> android/gradle.properties <<'EOF'

org.gradle.jvmargs=-Xmx2304m -XX:MaxMetaspaceSize=384m -Dfile.encoding=UTF-8
org.gradle.daemon=false
org.gradle.workers.max=1
org.gradle.parallel=false
kotlin.incremental=false
kotlin.compiler.execution.strategy=in-process
kotlin.daemon.useFallbackStrategy=false
android.enableBuildCache=false
EOF
# Gradle 镜像（腾讯云）
sed -i 's#distributionUrl=.*#distributionUrl=https\\://mirrors.cloud.tencent.com/gradle/gradle-8.14-all.zip#' android/gradle/wrapper/gradle-wrapper.properties || true
# 仓库镜像
cat > android/init.gradle <<'EOF'
settingsEvaluated { settings ->
  settings.pluginManagement.repositories {
    maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
    maven { url 'https://maven.aliyun.com/repository/google' }
    maven { url 'https://maven.aliyun.com/repository/public' }
    gradlePluginPortal(); google(); mavenCentral()
  }
}
allprojects {
  repositories {
    maven { url 'https://maven.aliyun.com/repository/google' }
    maven { url 'https://maven.aliyun.com/repository/public' }
    google(); mavenCentral()
  }
}
EOF
echo "== flutter pub get =="
flutter pub get
echo "ENV_READY"
