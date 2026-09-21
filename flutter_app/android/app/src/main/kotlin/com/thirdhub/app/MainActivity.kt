package com.thirdhub.app

import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 画中画里那颗播放/暂停按钮发回来的动作。 */
private const val PIP_ACTION_TOGGLE = "com.thirdhub.app.PIP_TOGGLE"

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


        // 均衡器: 挂到 just_audio 的音频会话
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thirdhub/eq").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "attach" -> {
                        val sid = call.argument<Int>("sessionId") ?: 0
                        equalizer?.release()
                        equalizer = null
                        if (sid > 0) {
                            val eq = android.media.audiofx.Equalizer(0, sid)
                            eq.enabled = true
                            equalizer = eq
                            val bands = eq.numberOfBands.toInt()
                            val range = eq.bandLevelRange
                            result.success(mapOf(
                                "bands" to bands,
                                "min" to range[0].toInt(),
                                "max" to range[1].toInt(),
                                "freqs" to (0 until bands).map { eq.getCenterFreq(it.toShort()) / 1000 },
                                "levels" to (0 until bands).map { eq.getBandLevel(it.toShort()).toInt() },
                                "presets" to (0 until eq.numberOfPresets).map { eq.getPresetName(it.toShort()) }
                            ))
                        } else result.success(null)
                    }
                    "setBand" -> {
                        val eq = equalizer
                        if (eq == null) { result.success(false); return@setMethodCallHandler }
                        eq.setBandLevel((call.argument<Int>("band") ?: 0).toShort(),
                            (call.argument<Int>("level") ?: 0).toShort())
                        result.success(true)
                    }
                    "preset" -> {
                        val eq = equalizer
                        if (eq == null) { result.success(false); return@setMethodCallHandler }
                        val idx = call.argument<Int>("index") ?: 0
                        eq.usePreset(idx.toShort())
                        val bands = eq.numberOfBands.toInt()
                        result.success((0 until bands).map { eq.getBandLevel(it.toShort()).toInt() })
                    }
                    "off" -> { equalizer?.enabled = false; result.success(true) }
                    "on" -> { equalizer?.enabled = true; result.success(true) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("EQ_ERR", e.message, null)
            }
        }

        // ═══ 网络发现支撑（thirdhub/net）═══
        // 两件事 Dart 侧做不到，必须借系统 API：
        //  1) MulticastLock —— 不持有它，Android WiFi 省电模式会静默丢弃入站广播/组播，
        //     表现为"引擎时有时无、锁屏后消失"；
        //  2) 真实子网掩码 / 网关 / 是否 VPN —— Dart 的 NetworkInterface 不暴露前缀长度，
        //     只能假设 /24；路由器发 /16 时就扫不到同网段其它 /24 的引擎。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thirdhub/net").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "multicastLock" -> {
                        val want = call.argument<Boolean>("enable") ?: false
                        result.success(setMulticastLock(want))
                    }
                    "networkInfo" -> result.success(networkInfo())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("NET_ERR", e.message, null) }
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

        // ═══ 画中画（thirdhub/pip）═══
        // PiP 必须在原生侧做：它缩的是整个 Activity 窗口（不是某个 View），
        // Flutter 层没有对应的 API。
        // 两个平台差异要注意：
        //  1) autoEnterEnabled 只有 Android 12(31) 起才有 —— 更早的版本回落用
        //     onUserLeaveHint（按 Home 键那一刻）自己判断要不要进，见下面重写；
        //  2) setActions 要 Android 8(26) 起，7.x 只能进一个不带按钮的小窗。
        pipCh = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "thirdhub/pip")
        pipCh?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isSupported" -> result.success(hasPip())
                    "setAuto" -> {
                        // Dart 在进入/离开视频页时调用：只有「正在放视频」时才允许按键自动进画中画
                        pipAuto = call.argument<Boolean>("enable") ?: false
                        pipAspect = (call.argument<Double>("aspect") ?: (16.0 / 9.0)).toFloat()
                        pipPlaying = call.argument<Boolean>("playing") ?: false
                        if (android.os.Build.VERSION.SDK_INT >= 26) {
                            try { setPictureInPictureParams(buildPipParams()) } catch (_: Exception) {}
                        }
                        result.success(true)
                    }
                    "enter" -> {
                        pipAspect = (call.argument<Double>("aspect") ?: pipAspect.toDouble()).toFloat()
                        pipPlaying = call.argument<Boolean>("playing") ?: pipPlaying
                        result.success(enterPip())
                    }
                    "update" -> {
                        // 播放/暂停状态变了，刷新画中画里的那颗按钮图标
                        pipPlaying = call.argument<Boolean>("playing") ?: pipPlaying
                        if (android.os.Build.VERSION.SDK_INT >= 26) {
                            try { setPictureInPictureParams(buildPipParams()) } catch (_: Exception) {}
                        }
                        result.success(true)
                    }
                    "inPip" -> result.success(android.os.Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("PIP_ERR", e.message, null) }
        }
    }

    // ── 画中画状态 ──
    private var pipCh: MethodChannel? = null
    private var pipAuto = false                 // 按键离开时是否自动进画中画
    private var pipAspect = 16f / 9f            // 当前视频宽高比
    private var pipPlaying = false              // 供 PiP 里的播放/暂停按钮选图标
    private var pipReceiver: android.content.BroadcastReceiver? = null

    private fun hasPip(): Boolean = packageManager.hasSystemFeature(
        android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /**
     * 组装画中画参数。
     * 宽高比必须落在 [1/2.39, 2.39] 内，带子式的超宽片源会算出 0.4 之类的值，
     * 直接传给系统会抛 IllegalArgumentException —— 这里先夹住再传。
     *
     * 标 @TargetApi(26)：内部用的 PictureInPictureParams.Builder / RemoteAction 都是
     * 8.0 才有的 API。三个调用点都已经用 SDK_INT>=26 包住，但 lint 的 NewApi 检查
     * 会把它当 fatal，从而在 lintVitalRelease 阶段打断出包 —— 必须显式声明。
     */
    @android.annotation.TargetApi(android.os.Build.VERSION_CODES.O)
    private fun buildPipParams(): android.app.PictureInPictureParams {
        val r = pipAspect.coerceIn(1f / 2.39f, 2.39f)
        val b = android.app.PictureInPictureParams.Builder()
            .setAspectRatio(android.util.Rational((r * 1000f).toInt(), 1000))
        if (android.os.Build.VERSION.SDK_INT >= 31) b.setAutoEnterEnabled(pipAuto)
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            // 播放/暂停按钮：图标直接用系统自带的，不用额外打包资源
            val icon = android.graphics.drawable.Icon.createWithResource(this,
                if (pipPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
            val label = if (pipPlaying) "暂停" else "播放"
            val pi = android.app.PendingIntent.getBroadcast(this, 0,
                Intent(PIP_ACTION_TOGGLE).setPackage(packageName),
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
            b.setActions(listOf(android.app.RemoteAction(icon, label, label, pi)))
        }
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            try { b.setSeamlessResizeEnabled(true) } catch (_: Exception) {}
        }
        return b.build()
    }

    private fun enterPip(): Boolean {
        if (!hasPip()) return false
        return try {
            if (android.os.Build.VERSION.SDK_INT >= 26) enterPictureInPictureMode(buildPipParams())
            else enterPipLegacy()
        } catch (e: Exception) {
            // 已经在画中画里、或当前处于不支持的窗口状态（如系统对话框压着），都不是错误
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun enterPipLegacy(): Boolean = enterPictureInPictureMode()

    /**
     * Android 12 以下没有 autoEnterEnabled，只能在这里自己判断：
     * 用户按 Home/最近任务要离开 App 的那一刻会被回调，此时若正在放视频就缩成小窗。
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipAuto && android.os.Build.VERSION.SDK_INT < 31) enterPip()
    }

    @android.annotation.TargetApi(android.os.Build.VERSION_CODES.O)
    override fun onPictureInPictureModeChanged(
        inPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration
    ) {
        super.onPictureInPictureModeChanged(inPictureInPictureMode, newConfig)
        // 通知 Dart 切布局：画中画里只该留视频画面，不能把整个 App 的界面缩进去
        pipCh?.invokeMethod("changed", mapOf("inPip" to inPictureInPictureMode))
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // 画中画里那颗播放/暂停按钮的落点。用动态注册，不必往清单里加 receiver。
        // 注意：这里必须先落到局部变量再注册——pipReceiver 是可空的 var，
        // Kotlin 不对可变属性做智能转换，直接用会报类型不匹配。
        val r = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                if (i?.action == PIP_ACTION_TOGGLE) pipCh?.invokeMethod("toggle", null)
            }
        }
        pipReceiver = r
        val filter = android.content.IntentFilter(PIP_ACTION_TOGGLE)
        try {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(r, filter)
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        pipReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        pipReceiver = null
        super.onDestroy()
    }

    private var pendingIntentPayload: Map<String, String?>? = null
    private var equalizer: android.media.audiofx.Equalizer? = null
    private var mcastLock: android.net.wifi.WifiManager.MulticastLock? = null

    /** 持有/释放 WiFi 多播锁。返回当前是否持有。 */
    private fun setMulticastLock(enable: Boolean): Boolean {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager
            ?: return false
        if (enable) {
            if (mcastLock == null) {
                mcastLock = wm.createMulticastLock("thirdhub_disc").apply { setReferenceCounted(false) }
            }
            if (mcastLock?.isHeld != true) mcastLock?.acquire()
        } else {
            mcastLock?.let { if (it.isHeld) it.release() }
        }
        return mcastLock?.isHeld ?: false
    }

    /**
     * 回报每个可用网络链路的 {ip, 前缀长度} 与传输类型（WiFi/蜂窝/VPN）。
     * VPN 一定要单独标出来：前端扫描要跳过它，否则会把 Clash/Tailscale 的假网段
     * 当成局域网去扫（10.x / 172.x），白白拖慢真网段。
     */
    private fun networkInfo(): Map<String, Any?> {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val nets = ArrayList<Map<String, Any?>>()
        val active = cm.activeNetwork
        var activeType = "none"
        for (n in cm.allNetworks) {
            val lp = cm.getLinkProperties(n) ?: continue
            val cap = cm.getNetworkCapabilities(n) ?: continue
            val isWifi = cap.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)
            val isVpn = cap.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)
            val isCell = cap.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR)
            val isEth = cap.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)
            val type = when {
                isVpn -> "vpn"; isWifi -> "wifi"; isEth -> "ethernet"; isCell -> "cellular"; else -> "other"
            }
            if (n == active) activeType = type
            val addrs = ArrayList<Map<String, Any?>>()
            for (la in lp.linkAddresses) {
                addrs.add(mapOf(
                    "ip" to la.address.hostAddress,
                    "prefix" to la.prefixLength,
                    "v6" to (la.address is java.net.Inet6Address)
                ))
            }
            var gw: String? = null
            for (r in lp.routes) { if (r.isDefaultRoute) { gw = r.gateway?.hostAddress; break } }
            nets.add(mapOf(
                "type" to type, "active" to (n == active),
                "addresses" to addrs, "gateway" to gw,
                "dns" to lp.dnsServers.map { it.hostAddress }
            ))
        }
        return mapOf("activeType" to activeType, "networks" to nets)
    }

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
