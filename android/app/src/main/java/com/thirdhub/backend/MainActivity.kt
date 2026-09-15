package com.thirdhub.backend

// 状态页: IP/指纹/密钥展示 + 启停 + 白名单引导
// v4.0.1: 崩溃守护 + 启动即自动拉起服务 + 前台服务权限/异常处理
import android.os.*; import android.widget.*; import android.content.Intent; import androidx.appcompat.app.AppCompatActivity
import java.net.*; import java.io.File

class MainActivity : AppCompatActivity() {
    private lateinit var tv: TextView
    private lateinit var btn: Button
    override fun onCreate(savedInstanceState: Bundle?) {
        CrashGuard.install(applicationContext)
        super.onCreate(savedInstanceState)
        // Android 13+ 通知权限(不申请则状态通知不可见)
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(40, 60, 40, 40) }
        tv = TextView(this).apply { textSize = 16f }
        btn = Button(this).apply { text = "启动后端" }
        val btnStop = Button(this).apply { text = "停止" }
        btn.setOnClickListener { startBackend() }
        btnStop.setOnClickListener { stopService(Intent(this, BackendService::class.java)); btn.text = "启动后端"; tv.text = "已停止" }
        root.addView(tv); root.addView(btn); root.addView(btnStop)
        setContentView(root)
        // 上次崩溃日志(若有)显示出来, 便于排查
        val crash = CrashGuard.lastCrash(applicationContext)
        tv.text = if (crash != null) "上次崩溃日志:\n$crash\n\n${statusText()}" else statusText()
        // 进入即自动启动后端(无需手动点)
        btn.postDelayed({ startBackend() }, 600)
    }
    private fun startBackend() {
        try {
            startForegroundService(Intent(this, BackendService::class.java))
            btn.text = "运行中…"
            tv.text = statusText()
        } catch (e: Exception) {
            tv.text = "启动失败: ${e.javaClass.simpleName}: ${e.message}\n\n${statusText()}"
        }
    }
    private fun statusText(): String {
        val home = File(filesDir, "runtime")
        val sec = File(home, "server/data/secret")
        val cert = File(home, "server/data/cert.pem")
        return buildString {
            appendLine("第三方后端 v4.0.1")
            appendLine("局域网地址: https://${getIp()}:9527")
            if (sec.exists()) appendLine("访问密钥: ${sec.readText().trim()}")
            if (cert.exists()) appendLine("证书指纹: 浏览器访问 /v1/meta 查看")
            else appendLine("首次启动后生成证书指纹")
            appendLine()
            appendLine("保活提示: 若通知栏服务被杀, 请对本应用关闭电池优化(设置→应用→第三方后端→电池→不限制)")
        }
    }
    private fun getIp(): String = NetworkInterface.getNetworkInterfaces().toList()
        .flatMap { it.inetAddresses.toList() }
        .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
        ?.hostAddress ?: "127.0.0.1"
}
