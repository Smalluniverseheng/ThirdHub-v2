package com.thirdhub.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import io.flutter.plugin.common.MethodChannel

/**
 * 本机 AI 的保活服务。
 *
 * 为什么必须有它：本机运行靠 PRoot 拉起一个 node 进程（在 App 进程里），
 * Android 一旦把 App 判为「后台空闲」就会冻结甚至回收整个进程 —— 表现为
 * 「切出去回个消息，回来 AI 就断开/白屏，要重新等一分钟展开」。前台服务是
 * 系统唯一认可的「我还在干活」的声明，配合 PARTIAL_WAKE_LOCK 防止 CPU 休眠
 * 把 node 的定时器/网络回调一起冻住。
 *
 * 三个刻意的选择：
 *  1) 渠道重要性用 LOW、不震动不出声 —— 它只是「还在跑」的状态显示，不是提醒。
 *  2) START_NOT_STICKY —— 服务被系统杀掉再拉起来时，PRoot 里的 node 已经没了，
 *     Dart 侧也不在了（同进程）。这时硬顶着一条「运行中」的通知等于撒谎；
 *     交给用户回到 App 时由 Dart 侧重启，状态与事实一致。
 *  3) 唤醒锁用 PARTIAL（只保 CPU 不保屏幕），并在 onDestroy 里一定释放 ——
 *     漏释放会让电池统计里出现一条永不消失的持锁记录。
 */
class DshKeepAliveService : Service() {
    companion object {
        private const val CH_ID = "thirdhub_dsh_local"
        private const val NOTI_ID = 0x4453 // 'DS'
        const val ACTION_STOP = "com.thirdhub.app.DSH_STOP"

        /** MainActivity 在 configureFlutterEngine 里挂上，用来把「用户点了停止」回传 Dart */
        @JvmStatic
        var channel: MethodChannel? = null

        /** 服务是否正在运行（Dart 侧据此判断要不要重新起） */
        @JvmStatic
        @Volatile
        var running: Boolean = false
            private set

        fun start(ctx: Context, title: String, text: String) {
            val i = Intent(ctx, DshKeepAliveService::class.java)
                .putExtra("title", title)
                .putExtra("text", text)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(i)
                } else {
                    ctx.startService(i)
                }
            } catch (_: Exception) {
                // Android 12+ 在极少数后台状态下会抛 ForegroundServiceStartNotAllowed。
                // 保活是「更好」，不是「必须」：起不来也照样能本机跑，只是没那么抗杀。
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.stopService(Intent(ctx, DshKeepAliveService::class.java))
            } catch (_: Exception) {
            }
        }
    }

    private var lock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Android 15(35)+ 对 `dataSync` 类型的前台服务有 6 小时累计上限。
     * 到点系统会回调这里；不主动收尾就会被判成「服务超时」直接干掉。
     * 收尾动作：释放唤醒锁 + 撤掉通知 —— 状态与事实一致，剩下的交给
     * Dart 侧「回到前台自愈」重新拉起（那时会重新计时）。
     */
    override fun onTimeout(startId: Int) {
        release()
        running = false
        try {
            stopSelf(startId)
        } catch (_: Exception) {
        }
        // 刻意不调 super.onTimeout：它只在 API 35+ 存在，显式引用会让
        // lintVitalRelease 判 NewApi（fatal）从而打断出包。
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // 用户在通知栏主动喊停：先通知 Dart 拆掉 PRoot，再收掉自己
            channel?.invokeMethod("stop", null)
            release()
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra("title")?.takeIf { it.isNotBlank() }
            ?: "本机 AI 运行中"
        val text = intent?.getStringExtra("text")?.takeIf { it.isNotBlank() }
            ?: "断网也能用，点这里回到对话"
        startForegroundCompat(title, text)
        acquire()
        running = true
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(title: String, text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(CH_ID) == null) {
                val ch = NotificationChannel(CH_ID, "本机 AI", NotificationManager.IMPORTANCE_LOW)
                ch.setShowBadge(false)
                ch.enableVibration(false)
                ch.setSound(null, null)
                nm.createNotificationChannel(ch)
            }
        }
        // 点通知回到 App（不是新开一个任务）
        val open = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val piOpen = PendingIntent.getActivity(this, 0, open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val piStop = PendingIntent.getService(this, 1,
            Intent(this, DshKeepAliveService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CH_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        b.setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(piOpen)
            .setOngoing(true)
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", piStop)
        val n = b.build()
        try {
            startForeground(NOTI_ID, n)
        } catch (_: Exception) {
            // targetSdk 34+ 若清单没声明对应的类型会抛，这里静默降级为普通通知
            try {
                nm.notify(NOTI_ID, n)
            } catch (_: Exception) {
            }
        }
    }

    private fun acquire() {
        if (lock?.isHeld == true) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "thirdhub:dsh-local")
            lock?.setReferenceCounted(false)
            lock?.acquire()
        } catch (_: Exception) {
        }
    }

    private fun release() {
        try {
            val l = lock
            if (l != null && l.isHeld) l.release()
        } catch (_: Exception) {
        }
        lock = null
    }

    override fun onDestroy() {
        release()
        running = false
        try {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTI_ID)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
