package com.thirdhub.backend

// 全局崩溃守护: 任何未捕获异常写入 crash.log, 下次启动展示, 不再无声闪退
import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

object CrashGuard {
    fun install(ctx: Context) {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                val sw = StringWriter()
                e.printStackTrace(PrintWriter(sw))
                File(ctx.filesDir, "crash.log").writeText(
                    "时间: ${java.util.Date()}\n线程: ${t.name}\n$sw")
            } catch (_: Exception) {}
            prev?.uncaughtException(t, e) ?: android.os.Process.killProcess(android.os.Process.myPid())
        }
    }
    fun lastCrash(ctx: Context): String? {
        val f = File(ctx.filesDir, "crash.log")
        if (!f.exists()) return null
        val txt = f.readText()
        f.delete()
        return txt.take(800)
    }
}
