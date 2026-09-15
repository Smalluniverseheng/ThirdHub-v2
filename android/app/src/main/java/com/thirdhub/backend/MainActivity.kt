package com.thirdhub.backend

// 状态页: 账号登录 + IP/指纹/密钥展示 + 启停 + 自动注册到配对表
// v4.1.0: ThirdHub 账号体系接入 —— 登录后前后端免地址自动互连
import android.os.*; import android.widget.*; import android.content.Intent; import androidx.appcompat.app.AppCompatActivity
import android.app.AlertDialog; import android.text.InputType; import android.graphics.Color
import java.net.*; import java.io.File

class MainActivity : AppCompatActivity() {
    private lateinit var tv: TextView
    private lateinit var btn: Button
    private lateinit var btnAccount: Button
    private var registered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        CrashGuard.install(applicationContext)
        super.onCreate(savedInstanceState)
        CloudAuth.restore(applicationContext)
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(40, 60, 40, 40) }
        tv = TextView(this).apply { textSize = 15f }
        btnAccount = Button(this).apply {
            text = if (CloudAuth.loggedIn) "账号: ${CloudAuth.email}(点按退出)" else "登录 ThirdHub 账号(前后端自动互连)"
            setOnClickListener { if (CloudAuth.loggedIn) { CloudAuth.signOut(applicationContext); refresh() } else showLogin() }
        }
        btn = Button(this).apply { text = "启动后端"; setOnClickListener { startBackend() } }
        val btnStop = Button(this).apply { text = "停止"; setOnClickListener {
            stopService(Intent(this@MainActivity, BackendService::class.java)); btn.text = "启动后端"; refresh() } }
        root.addView(btnAccount); root.addView(tv); root.addView(btn); root.addView(btnStop)
        setContentView(root)
        val crash = CrashGuard.lastCrash(applicationContext)
        if (crash != null) tv.text = "上次崩溃日志:\n$crash\n"
        refresh()
        btn.postDelayed({ startBackend() }, 600)
        // 每30秒尝试注册设备(等 node 生成密钥后自动完成)
        val h = Handler(Looper.getMainLooper())
        h.postDelayed(object : Runnable { override fun run() { tryRegister(); h.postDelayed(this, 30000) } }, 5000)
    }

    private fun showLogin() {
        val mail = EditText(this).apply { hint = "邮箱"; inputType = InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS }
        val pass = EditText(this).apply { hint = "密码(至少6位)"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        val box = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(50, 20, 50, 0); addView(mail); addView(pass) }
        AlertDialog.Builder(this).setTitle("登录 / 注册 ThirdHub 账号").setView(box)
            .setPositiveButton("登录") { _, _ -> doAuth(mail.text.toString().trim(), pass.text.toString(), false) }
            .setNeutralButton("注册") { _, _ -> doAuth(mail.text.toString().trim(), pass.text.toString(), true) }
            .setNegativeButton("取消", null).show()
    }

    private fun doAuth(mail: String, pass: String, isReg: Boolean) {
        if (mail.isEmpty() || pass.length < 6) { toast("邮箱或密码不合法"); return }
        toast(if (isReg) "注册中…" else "登录中…")
        Thread {
            val err = if (isReg) CloudAuth.signUp(mail, pass) else CloudAuth.signIn(mail, pass)
            runOnUiThread {
                if (err == null) { toast("已登录 ${CloudAuth.email}"); registered = false; tryRegister() }
                else toast(err)
                refresh()
            }
        }.start()
    }

    // 密钥就绪 + 已登录 → 注册设备到配对表
    private fun tryRegister() {
        if (registered || !CloudAuth.loggedIn) return
        val home = File(filesDir, "runtime")
        val sec = File(home, "server/data/secret")
        if (!sec.exists()) return
        Thread {
            val secret = sec.readText().trim()
            val cert = File(home, "server/data/cert.pem")
            val fp = if (cert.exists()) CloudAuth.certFingerprint(cert) else ""
            val err = CloudAuth.registerDevice(applicationContext, "https://${getIp()}:9527", secret, fp)
            runOnUiThread {
                if (err == null) { registered = true; toast("已注册到账号, 前端可自动连接") }
                refresh()
            }
        }.start()
    }

    private fun startBackend() {
        try {
            startForegroundService(Intent(this, BackendService::class.java))
            btn.text = "运行中…"
            refresh()
        } catch (e: Exception) {
            tv.text = "启动失败: ${e.javaClass.simpleName}: ${e.message}\n\n${statusText()}"
        }
    }

    private fun refresh() {
        btnAccount.text = if (CloudAuth.loggedIn) "账号: ${CloudAuth.email}(点按退出)" else "登录 ThirdHub 账号(前后端自动互连)"
        tv.text = statusText()
    }

    private fun statusText(): String {
        val home = File(filesDir, "runtime")
        val sec = File(home, "server/data/secret")
        val cert = File(home, "server/data/cert.pem")
        return buildString {
            appendLine("第三方后端 v4.1.0")
            appendLine("局域网地址: https://${getIp()}:9527")
            if (sec.exists()) appendLine("访问密钥: ${sec.readText().trim()}")
            if (cert.exists()) appendLine("证书指纹: ${CloudAuth.certFingerprint(cert).take(23)}…")
            appendLine(if (registered) "设备状态: 已注册到账号 ✓" else "设备状态: 待注册(登录账号+服务启动后自动完成)")
            appendLine()
            appendLine("保活提示: 若通知栏服务被杀, 请对本应用关闭电池优化")
        }
    }

    private fun toast(t: String) = Toast.makeText(this, t, Toast.LENGTH_SHORT).show()

    private fun getIp(): String = NetworkInterface.getNetworkInterfaces().toList()
        .flatMap { it.inetAddresses.toList() }
        .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
        ?.hostAddress ?: "127.0.0.1"
}
