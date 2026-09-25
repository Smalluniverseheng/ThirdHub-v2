plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.thirdhub.app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig {
        applicationId = "com.thirdhub.app"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    // 固定签名(CI注入): 覆盖安装保留数据的前提
    signingConfigs {
        val storeFileProp = System.getenv("TH_STORE_FILE") ?: ""
        if (storeFileProp.isNotEmpty()) {
            create("release") {
                storeFile = file(storeFileProp)
                storePassword = System.getenv("TH_STORE_PASSWORD")
                keyAlias = "thirdhub"
                keyPassword = System.getenv("TH_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            val storeFileProp = System.getenv("TH_STORE_FILE") ?: ""
            signingConfig = if (storeFileProp.isNotEmpty()) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
    kotlinOptions { jvmTarget = "17" }

    // ★ 按 target-platform 精确剔除未声明的 ABI 目录（2026-09-25 第十五轮新增）
    //
    // 实测缺陷（不是理论问题）：CI 长期只传 `-Ptarget-platform=android-arm64`，
    //   Flutter 引擎只给 arm64 出 libflutter.so / libapp.so；但插件仓库里的**预编译 jniLibs
    //   是全 ABI 的**，于是 APK 里仍然留着 `lib/armeabi-v7a/` 与 `lib/x86_64/` 两个目录，
    //   每个目录只有 2 个插件 .so、**没有 Flutter 引擎**。
    //   后果：32 位 arm 手机与 x86_64 模拟器**能装上、启动即崩**，报
    //   `UnsatisfiedLinkError: dlopen failed: ".../libflutter.so" is for EM_AARCH64 (183)
    //    instead of EM_X86_64 (62)`（4.52.0 包实测）。
    // 做法：target-platform 没声明的 ABI 一律不打进包 —— 宁可「装不上」（系统会明确说设备不兼容），
    //   也绝不允许「装上就崩」这种用户侧黑洞。
    // 安全阀：未传 target-platform（本地 `flutter build apk` 默认全 ABI）时不改任何行为。
    val abiByPlatform = mapOf(
        "android-arm" to "armeabi-v7a",
        "android-arm64" to "arm64-v8a",
        "android-x64" to "x86_64",
    )
    val declaredPlatforms = (project.findProperty("target-platform") as String? ?: "")
        .split(',').map { it.trim() }.filter { it.isNotEmpty() }
    val keepAbis = declaredPlatforms.mapNotNull { abiByPlatform[it] }
    if (keepAbis.isNotEmpty()) {
        val dropAbis = listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64").filterNot { keepAbis.contains(it) }
        packaging {
            jniLibs {
                excludes += dropAbis.map { "lib/$it/**" }
            }
        }
        logger.lifecycle("ThirdHub: target-platform=$declaredPlatforms → 保留 ABI $keepAbis，剔除 $dropAbis")
    }
}

flutter { source = "../.." }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
