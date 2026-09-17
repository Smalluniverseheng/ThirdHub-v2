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

        // 打开方式/分享: 捕获 VIEW / SEND 意图
        val intentCh = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thirdhub/intent")
        pendingIntentPayload = extractIntent(intent)
        intentCh.setMethodCallHandler { call, result ->
            when (call.method) {
                "consume" -> {
                    val p = pendingIntentPayload
                    pendingIntentPayload = null
                    result.success(p)
                }
                "readUri" -> {
                    // 把 content:// 拷到缓存文件, 返回本地路径与文件名
                    val uriStr = call.argument<String>("uri") ?: ""
                    try {
                        val uri = android.net.Uri.parse(uriStr)
                        var name = "shared_file"
                        contentResolver.query(uri, null, null, null, null)?.use { cur ->
                            val i = cur.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                            if (i >= 0 && cur.moveToFirst()) name = cur.getString(i) ?: name
                        }
                        if (uri.scheme == "file") {
                            result.success(mapOf("path" to uri.path, "name" to name))
                        } else {
                            val dir = java.io.File(cacheDir, "open_in").apply { mkdirs() }
                            val out = java.io.File(dir, "${System.currentTimeMillis()}_$name")
                            contentResolver.openInputStream(uri)?.use { inp ->
                                out.outputStream().use { inp.copyTo(it) }
                            } ?: throw java.io.IOException("无法读取")
                            result.success(mapOf("path" to out.absolutePath, "name" to name))
                        }
                    } catch (e: Exception) {
                        result.error("READ_ERR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private var pendingIntentPayload: Map<String, String?>? = null

    private fun extractIntent(i: Intent?): Map<String, String?>? {
        i ?: return null
        return when (i.action) {
            Intent.ACTION_VIEW -> {
                val uri = i.data ?: return null
                mapOf("type" to "view", "uri" to uri.toString(),
                    "mime" to (i.type ?: contentTypeOf(uri)))
            }
            Intent.ACTION_SEND -> {
                val uri = i.getParcelableExtra<android.net.Uri>(Intent.EXTRA_STREAM)
                val text = i.getStringExtra(Intent.EXTRA_TEXT)
                if (uri != null) mapOf("type" to "send", "uri" to uri.toString(),
                    "mime" to (i.type ?: contentTypeOf(uri)))
                else if (text != null) mapOf("type" to "sendText", "text" to text,
                    "mime" to "text/plain", "uri" to null)
                else null
            }
            else -> null
        }
    }

    private fun contentTypeOf(uri: android.net.Uri): String? =
        try { contentResolver.getType(uri) } catch (e: Exception) { null }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        extractIntent(intent)?.let {
            pendingIntentPayload = it
            io.flutter.plugin.common.MethodChannel(
                flutterEngine!!.dartExecutor.binaryMessenger, "thirdhub/intent"
            ).invokeMethod("incoming", it)
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
