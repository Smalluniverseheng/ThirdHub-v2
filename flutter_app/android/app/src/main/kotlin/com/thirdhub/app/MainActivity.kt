package com.thirdhub.app

import android.content.Intent
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var volumeKeys: MethodChannel? = null
    private var interceptVolume = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeKeys = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thirdhub/volume_keys")
        volumeKeys?.setMethodCallHandler { call, result ->
            if (call.method == "enable") {
                interceptVolume = call.arguments as? Boolean ?: false
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        // 悬浮便签全局悬浮窗
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thirdhub/overlay").setMethodCallHandler { call, result ->
            when (call.method) {
                "canDraw" -> result.success(android.provider.Settings.canDrawOverlays(this))
                "requestPermission" -> {
                    startActivity(Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        android.net.Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "show" -> {
                    val text = call.argument<String>("text") ?: ""
                    startService(Intent(this, OverlayService::class.java).putExtra("text", text))
                    result.success(null)
                }
                "hide" -> {
                    startService(Intent(this, OverlayService::class.java).setAction("hide"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // 短信读取(替代无人维护的 telephony 插件)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thirdhub/sms").setMethodCallHandler { call, result ->
            if (call.method == "inbox") {
                val limit = (call.arguments as? Int) ?: 2000
                val out = ArrayList<Map<String, Any>>()
                try {
                    val cur = contentResolver.query(
                        android.net.Uri.parse("content://sms/inbox"),
                        arrayOf("address", "body", "date"), null, null, "date DESC")
                    cur?.use {
                        var n = 0
                        while (it.moveToNext() && n < limit) {
                            out.add(mapOf(
                                "address" to (it.getString(0) ?: ""),
                                "body" to (it.getString(1) ?: ""),
                                "date" to it.getLong(2)))
                            n++
                        }
                    }
                    result.success(out)
                } catch (e: Exception) {
                    result.error("SMS_ERR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (interceptVolume && event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeKeys?.invokeMethod("press", "up")
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeKeys?.invokeMethod("press", "down")
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
