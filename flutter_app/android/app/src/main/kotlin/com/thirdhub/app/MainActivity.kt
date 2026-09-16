package com.thirdhub.app

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
