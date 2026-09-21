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
        versionCode = ((findProperty("verCode") as String?) ?: "42000").toInt()
        versionName = (findProperty("verName") as String?) ?: "4.2.0"
        manifestPlaceholders["appLabel"] = (findProperty("appLabel") as String?) ?: "第三方后端"
    }
    // 签名材料不再入库（android/keystore.properties 与 *.jks 已从仓库删除，见 .gitignore）。
    // 取值顺序：环境变量（CI 从 secrets 注入）→ 本地 keystore.properties（自建，不入库）。
    // 两者都没有时**不配置签名**：assembleRelease 照样能出未签名包，不会像旧写法那样
    // 在 configure 阶段就抛 FileNotFoundException 把整个构建打断。
    signingConfigs {
        val envStore = System.getenv("TH_STORE_FILE")
        val propFile = File(rootDir, "keystore.properties")
        if (!envStore.isNullOrBlank()) {
            create("release") {
                storeFile = File(envStore)
                storePassword = System.getenv("TH_STORE_PASSWORD") ?: ""
                keyAlias = System.getenv("TH_KEY_ALIAS") ?: "thirdhub"
                keyPassword = System.getenv("TH_KEY_PASSWORD") ?: ""
            }
        } else if (propFile.exists()) {
            create("release") {
                val p = Properties()
                propFile.inputStream().use { p.load(it) }
                storeFile = File(rootDir, p.getProperty("storeFile"))
                storePassword = p.getProperty("storePassword")
                keyAlias = p.getProperty("keyAlias")
                keyPassword = p.getProperty("keyPassword")
            }
        } else {
            logger.lifecycle("[ThirdHub] 未找到签名材料（TH_STORE_FILE 或 android/keystore.properties）——本次产出未签名 APK")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
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
