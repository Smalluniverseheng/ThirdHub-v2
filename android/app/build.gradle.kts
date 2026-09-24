// ThirdHub 后端 APK: 内嵌 node-arm64 + server代码, 首启解压, 前台Service常驻
import java.util.Properties
plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }

// ── 版本号单一来源 ───────────────────────────────────────────────────────────
// Node 侧自 0.8.4 起收归 server/package.json（见 docs/HANDOVER-AI.md 铁律 9）。
// 后端 APK 是 Node 侧交付物之一，**必须与后端 zip 同号** —— 此前这里的默认值是写死的
// "4.2.0"/42000，而 CI 的 backend-apk 作业又从不传 -PverName，于是无论后端发到哪个版本，
// 打出来的 APK 永远是 4.2.0（清单里也就永远停在 4.2.0）。现在改成直接读 server/package.json。
//
// versionCode 必须**单调不减**（Android 拒绝降级安装，用户装了 4.2.0 就再也装不上更小的号）：
// 沿用旧的 4.2.0 = 42000 作为基数，记为 42000 + minor*100 + patch。
//   0.8.6 → 42806   0.8.7 → 42807   0.9.0 → 42900   1.0.0 → 43000
// 仍可用 -PverName/-PverCode 显式覆盖（venera 变体就是这么用的）。
fun serverVersion(): String {
    val f = File(rootDir, "../server/package.json")
    if (!f.exists()) return "0.0.0"
    val m = Regex("\"version\"\\s*:\\s*\"([^\"]+)\"").find(f.readText())
    return m?.groupValues?.get(1) ?: "0.0.0"
}

fun serverVersionCode(v: String): Int {
    val p = v.substringBefore("-").split(".")
    val minor = p.getOrNull(1)?.toIntOrNull() ?: 0
    val patch = p.getOrNull(2)?.toIntOrNull() ?: 0
    return 42000 + minor * 100 + patch
}

android {
    namespace = "com.thirdhub.backend"
    compileSdk = 34
    defaultConfig {
        // 变体打包: gradle -PappId=... -PappLabel=... -PverName=... -PverCode=...
        applicationId = (findProperty("appId") as String?) ?: "com.thirdhub.backend"
        minSdk = 24; targetSdk = 34
        versionCode = ((findProperty("verCode") as String?) ?: serverVersionCode(serverVersion()).toString()).toInt()
        versionName = (findProperty("verName") as String?) ?: serverVersion()
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
    // node二进制与server代码放 assets(体积大, 由CI/local构建脚本注入, 不入库):
    //   app/src/main/assets/node/bin/node  ← node-v20.x-linux-arm64 静态二进制
    //   app/src/main/assets/server/        ← 本仓库 server/ 目录(工程脚本拷贝)
    // 由 server/scripts/fetch-node-android.sh 组装（排除清单与发布包一致：只排 data/ 与
    // node_modules.msh-partial —— **public/ 与 scripts/ 必须进包**，否则管理台(public/index.html)
    // 与自签证书(scripts/gencert.js)在手机上都不可用）。
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
