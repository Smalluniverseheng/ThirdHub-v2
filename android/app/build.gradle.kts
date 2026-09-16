// ThirdHub 后端 APK: 内嵌 node-arm64 + server代码, 首启解压, 前台Service常驻
import java.util.Properties
plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }

android {
    namespace = "com.thirdhub.backend"
    compileSdk = 34
    defaultConfig {
        // 变体打包: gradle -PappId=... -PappLabel=... -PverName=... -PverCode=...
        applicationId = (findProperty("appId") as String?) ?: "com.thirdhub.backend"
        minSdk = 24; targetSdk = 34
        versionCode = ((findProperty("verCode") as String?) ?: "41001").toInt()
        versionName = (findProperty("verName") as String?) ?: "4.1.1"
        manifestPlaceholders["appLabel"] = (findProperty("appLabel") as String?) ?: "第三方后端"
    }
    signingConfigs {
        create("release") {
            val p = Properties()
            p.load(File(rootDir, "keystore.properties").inputStream())
            storeFile = File(rootDir, p.getProperty("storeFile"))
            storePassword = p.getProperty("storePassword")
            keyAlias = p.getProperty("keyAlias")
            keyPassword = p.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    // node二进制与server代码放 assets(体积大, 由CI注入):
    //   app/src/main/assets/node/bin/node  ← node-v20.x-linux-arm64 静态二进制
    //   app/src/main/assets/server/        ← 本仓库 server/ 目录(工程脚本拷贝)
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
