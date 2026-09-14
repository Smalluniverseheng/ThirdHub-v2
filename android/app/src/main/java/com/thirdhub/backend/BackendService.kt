package com.thirdhub.backend

// 后端核心服务: 首启解压 assets(node二进制+server代码) → exec node 常驻
import android.app.*; import android.content.*; import android.os.*; import androidx.core.app.NotificationCompat
import java.io.*

class BackendService : Service() {
    private var proc: Process? = null
    private val CH = "th-backend"
    override fun onBind(i: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        // Android 8+ 必须创建渠道, 否则通知不显示
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(CH, "后端服务", NotificationManager.IMPORTANCE_LOW).apply {
            description = "ThirdHub 后端运行状态"
        })
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1, notif("启动中…"))
        Thread {
            try {
                val home = File(filesDir, "runtime").apply { mkdirs() }
                if (!File(home, ".unpacked").exists()) { unpackAssets(assets, home); File(home, ".unpacked").createNewFile() }
                val node = File(home, "node/bin/node").absolutePath
                File(node).setExecutable(true)
                chmod777(File(home, "node/bin"))
                val serverDir = File(home, "server")
                proc = ProcessBuilder(node, "index.js")
                    .directory(serverDir)
                    .redirectErrorStream(true)
                    .environment().apply { put("HOME", home.absolutePath); put("PATH", File(home,"node/bin").absolutePath + ":" + System.getenv("PATH")) }
                    .start()
                // 读输出更新通知
                BufferedReader(InputStreamReader(proc!!.inputStream)).useLines { lines ->
                    lines.forEach { line ->
                        if (line.contains("后端就绪") || line.contains("本机:") || line.contains("指纹")) {
                            updateNotif(line)
                        }
                    }
                }
                proc?.waitFor()
            } catch (e: Exception) { updateNotif("异常: ${e.message}") }
            startForeground(1, notif("已停止, 点按重启"))
        }.start()
        return START_STICKY
    }
    private fun notif(t: String) = NotificationCompat.Builder(this, CH)
        .setContentTitle("ThirdHub 后端 :9527").setContentText(t)
        .setSmallIcon(android.R.drawable.stat_sys_download_done)
        .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
        .build()
    private fun updateNotif(t: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(1, notif(t))
    }
    override fun onDestroy() { proc?.destroy(); super.onDestroy() }
    private fun chmod777(f: File) { f.setExecutable(true, false); f.setReadable(true, false); f.setWritable(true, false) }
    private fun unpackAssets(am: AssetManager, out: File) {
        fun copy(path: String) {
            val list = am.list(path) ?: return
            if (list.isEmpty()) {
                val dest = File(out, path); dest.parentFile?.mkdirs()
                am.open(path).use { inp -> FileOutputStream(dest).use { it.write(inp.readBytes()) } }
                if (path.contains("/bin/")) dest.setExecutable(true)
            } else list.forEach { copy(if (path.isEmpty()) it else "$path/$it") }
        }
        copy("")
    }
}
