package com.thirdhub.legado.thirdhub

// ThirdHub 自动配对器: 发现后端 → 自动握手 → 零输入配对
// 由 App.onCreate 调 AutoPairer.start(this)
import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.*

object AutoPairer {
    private var started = false
    fun start(ctx: Context) = CoroutineScope(Dispatchers.IO).launch {
        if (started) return@launch; started = true
        val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                val attrs = if (Build.VERSION.SDK_INT >= 34) info.attributes else emptyMap()
                val type = attrs["type"]?.toString()
                if (type != "backend") return
                val host = info.host?.hostAddress ?: return
                val port = info.port
                pair(ctx, "http://$host:$port")
            }
            override fun onDiscoveryStarted(s: String) {}
            override fun onDiscoveryStopped(s: String) {}
            override fun onServiceLost(i: NsdServiceInfo) {}
            override fun onStartDiscoveryFailed(s: String, e: Int) {}
            override fun onStopDiscoveryFailed(s: String, e: Int) {}
        }
        while (isActive) {
            try { nsd.discoverServices("_thirdhub-dev._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) } catch (e: Exception) {}
            delay(10 * 60 * 1000) // 发现失败每10分钟重试
        }
    }

    private suspend fun pair(ctx: Context, backend: String) {
        try {
            val prefs = ctx.getSharedPreferences("thirdhub", Context.MODE_PRIVATE)
            if (prefs.getBoolean("paired_$backend", false)) return
            val port = 1122
            val token = prefs.getString("web_token", "") ?: ""
            val body = """{"device_type":"legado","device_url":"http://127.0.0.1:$port","token":"$token","caps":["novel"]}"""
            val conn = java.net.URL("$backend/v1/pair").openConnection() as java.net.HttpURLConnection
            conn.requestMethod = "POST"; conn.connectTimeout = 5000
            conn.setRequestProperty("Content-Type", "application/json")
            conn.doOutput = true; conn.outputStream.write(body.toByteArray())
            if (conn.responseCode in 200..299) prefs.edit().putBoolean("paired_$backend", true).apply()
        } catch (e: Exception) { /* 静默 */ }
    }
}
