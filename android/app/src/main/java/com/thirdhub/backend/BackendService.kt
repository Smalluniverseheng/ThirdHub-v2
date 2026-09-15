package com.thirdhub.backend

// 后端核心服务: 首启解压 assets(node.tar.xz + xz解压器 + server代码) → exec node 常驻
// node 为 Termux aarch64(bionic) 构建, 依赖库经 LD_LIBRARY_PATH 加载
import android.app.*; import android.content.*; import android.content.pm.ServiceInfo; import android.content.res.AssetManager; import android.os.*; import androidx.core.app.NotificationCompat; import androidx.core.app.ServiceCompat
import java.io.*

class BackendService : Service() {
    private var proc: java.lang.Process? = null
    private val CH = "th-backend"

    // 诊断日志: 启动每步落盘, 界面可查
    private fun log(msg: String) {
        try {
            val f = File(filesDir, "runtime/service.log")
            f.parentFile?.mkdirs()
            val old = if (f.exists()) f.readLines().takeLast(49) else emptyList()
            f.writeText((old + "[${java.text.SimpleDateFormat("HH:mm:ss").format(java.util.Date())}] $msg").joinToString("\n"))
        } catch (_: Exception) {}
    }
    override fun onBind(i: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(CH, "后端服务", NotificationManager.IMPORTANCE_LOW).apply {
            description = "第三方后端运行状态"
        })
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        CrashGuard.install(applicationContext)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                ServiceCompat.startForeground(this, 1, notif("启动中…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else startForeground(1, notif("启动中…"))
        } catch (e: Exception) {
            // 权限/类型异常时降级为普通通知, 不再闪退
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(2, notif("前台服务启动失败: ${e.message}"))
        }
        Thread {
            try {
                val home = File(filesDir, "runtime").apply { mkdirs() }
                log("服务启动")
                if (!File(home, ".unpacked").exists()) {
                    updateNotif("首次解压运行时…")
                    log("首次解压运行时")
                    unpackAssets(assets, home)
                    extractRuntime(home)
                    File(home, ".unpacked").createNewFile()
                }
                val nodeDir = File(home, "node")
                val node = File(nodeDir, "bin/node")
                node.setExecutable(true)
                log("node就绪: ${node.absolutePath} 存在=${node.exists()}")
                val serverDir = File(home, "server")
                val env = HashMap(System.getenv())
                env["HOME"] = home.absolutePath
                env["LD_LIBRARY_PATH"] = File(nodeDir, "lib").absolutePath
                env["PATH"] = File(nodeDir, "bin").absolutePath + ":" + (System.getenv("PATH") ?: "")
                val pb = ProcessBuilder(node.absolutePath, "index.js")
                    .directory(serverDir)
                    .redirectErrorStream(true)
                pb.environment().putAll(env)
                proc = pb.start()
                log("node进程已启动")
                BufferedReader(InputStreamReader(proc!!.inputStream)).useLines { lines ->
                    lines.forEach { line ->
                        log("node: " + line.take(120))
                        if (line.contains("后端就绪") || line.contains("本机:") || line.contains("指纹")) {
                            updateNotif(line)
                        }
                    }
                }
                proc?.waitFor()
            } catch (e: Exception) { log("异常: ${e.javaClass.simpleName}: ${e.message}"); updateNotif("异常: ${e.message}") }
            try { startForeground(1, notif("已停止, 点按重启")) } catch (_: Exception) {}
        }.start()
        return START_STICKY
    }
    private fun notif(t: String) = NotificationCompat.Builder(this, CH)
        .setContentTitle("第三方后端 :9527").setContentText(t)
        .setSmallIcon(android.R.drawable.stat_sys_download_done)
        .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
        .build()
    private fun updateNotif(t: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(1, notif(t))
    }
    override fun onDestroy() { proc?.destroy(); super.onDestroy() }

    // 用打包内的 xz(自带 liblzma) 解压 node.tar.xz, 再走系统 tar
    private fun extractRuntime(home: File) {
        val xzDir = File(home, "node/xz")
        val xz = File(xzDir, "xz")
        xz.setExecutable(true)
        File(xzDir, "liblzma.so.5").setReadable(true)
        val pkg = File(home, "node/node.tar.xz")
        val cmd = "LD_LIBRARY_PATH=${xzDir.absolutePath} ${xz.absolutePath} -dc ${pkg.absolutePath} | tar x -C ${File(home, "node").absolutePath}"
        val p = ProcessBuilder("sh", "-c", cmd).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        if (p.waitFor() != 0) throw IOException("运行时解压失败: $out")
        pkg.delete()
        File(home, "node/bin/node").setExecutable(true)
    }

    private fun unpackAssets(am: AssetManager, out: File) {
        fun copy(path: String) {
            val list = am.list(path) ?: return
            if (list.isEmpty()) {
                val dest = File(out, path); dest.parentFile?.mkdirs()
                am.open(path).use { inp -> FileOutputStream(dest).use { it.write(inp.readBytes()) } }
                if (path.contains("/bin/") || path.endsWith("/xz")) dest.setExecutable(true)
            } else list.forEach { child -> copy(if (path.isEmpty()) child else path + "/" + child) }
        }
        copy("")
    }
}
