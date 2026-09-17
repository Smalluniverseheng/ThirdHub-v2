package com.thirdhub.app

import android.app.Service
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.TextView

// 悬浮便签: 全局悬浮窗服务(SYSTEM_ALERT_WINDOW), 显示置顶便签内容, 可拖动
class OverlayService : Service() {
    private var wm: WindowManager? = null
    private var view: TextView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: ""
        if (intent?.action == "hide") { hide(); return START_NOT_STICKY }
        show(text)
        return START_STICKY
    }

    private fun show(text: String) {
        if (view != null) { view?.text = text; return }
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else WindowManager.LayoutParams.TYPE_PHONE
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT)
        lp.gravity = Gravity.TOP or Gravity.END
        lp.x = 24; lp.y = 200
        val tv = TextView(this)
        tv.text = text
        tv.textSize = 12f
        tv.setTextColor(0xFFFFFFFF.toInt())
        tv.setBackgroundColor(0xCC222831.toInt())
        tv.setPadding(28, 20, 28, 20)
        tv.maxWidth = 640
        // 拖动
        var downX = 0f; var downY = 0f; var startX = 0; var startY = 0
        tv.setOnTouchListener { _, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> { downX = ev.rawX; downY = ev.rawY; startX = lp.x; startY = lp.y; true }
                MotionEvent.ACTION_MOVE -> {
                    lp.x = startX - (ev.rawX - downX).toInt()
                    lp.y = startY + (ev.rawY - downY).toInt()
                    wm?.updateViewLayout(tv, lp); true
                }
                else -> false
            }
        }
        wm?.addView(tv, lp)
        view = tv
    }

    private fun hide() {
        view?.let { wm?.removeView(it) }
        view = null
        stopSelf()
    }

    override fun onDestroy() { hide(); super.onDestroy() }
}
