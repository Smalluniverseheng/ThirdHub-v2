package com.thirdhub.backend

// 状态页: IP/指纹/密钥展示 + 启停 + 白名单引导
import android.os.*; import android.widget.*; import androidx.appcompat.app.AppCompatActivity
import java.net.*; import java.io.File

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(40, 60, 40, 40) }
        val tv = TextView(this).apply { textSize = 16f }
        val btn = Button(this).apply { text = "启动后端" }
        val btnStop = Button(this).apply { text = "停止" }
        btn.setOnClickListener {
            startForegroundService(Intent(this, BackendService::class.java))
            btn.text = "运行中…"
            tv.text = statusText()
        }
        btnStop.setOnClickListener { stopService(Intent(this, BackendService::class.java)); btn.text = "启动后端"; tv.text = "已停止" }
        root.addView(tv); root.addView(btn); root.addView(btnStop)
        setContentView(root)
        tv.text = statusText()
    }
    private fun statusText(): String {
        val home = File(filesDir, "runtime")
        val sec = File(home, "server/data/secret")
        val cert = File(home, "server/data/cert.pem")
        return buildString {
            appendLine("ThirdHub 后端 v4.0.0-m1")
            appendLine("局域网地址: https://${getIp()}:9527")
            if (sec.exists()) appendLine("访问密钥: ${sec.readText().trim()}")
            if (cert.exists()) {
                val fp = ProcessBuilder("sh","-c","openssl x509 -in ${cert.absolutePath} -noout -fingerprint -sha256").start().inputStream.bufferedReader().readText()
                appendLine(fp.trim())
            } else appendLine("首次启动后生成证书指纹")
            appendLine()
            appendLine("保活提示: 若通知栏服务被杀, 请对本应用关闭电池优化(设置→应用→ThirdHub后端→电池→不限制)")
        }
    }
    private fun getIp(): String = NetworkInterface.getNetworkInterfaces().toList()
        .flatMap { it.inetAddresses.toList() }
        .firstOrNull { it is Inet4Address && !it.isLoopbackAddress && it.hostAddress?.startsWith("192.168.") == true }
        ?.hostAddress ?: "127.0.0.1"
}
