plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.thirdhub.app"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.thirdhub.app"
        minSdk = 24
        targetSdk = 34
        versionCode = 40002
        versionName = "4.0.0-m2"
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")  // M2: 调试签名,正式签名二期
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

flutter { source = "../.." }
