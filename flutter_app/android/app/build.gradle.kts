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
        versionCode = 40002
        versionName = "4.0.0-m2"
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
}

flutter { source = "../.." }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
