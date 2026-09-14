# Legado 改造：ThirdHub 三自动补丁

> 底仓: legado-thirdhub (包名已改 com.thirdhub.legado)
> 目标: 用户零操作, 装上即是"即插即用插件"
> ⚠️ 注入点需对照底仓实际源码核对行号（MD3分支结构可能与下文假设略有出入）

## 三个自动

### ① 启动自动开启 Web 服务(:1122)
**注入点**: `com.thirdhub.legado.App`（Application 子类）的 `onCreate()` 尾部。
**逻辑**:
```kotlin
// 延迟5秒(等首启向导完成), 启动 Web 服务
CoroutineScope(Dispatchers.Default).launch {
    delay(5000)
    if (WebService.isRun == false) {
        // 读取/写入默认端口1122, 随机token存私有目录
        putPrefInt("web_port", 1122)
        val token = getPrefString("web_token") ?: randomToken(16).also { putPrefString("web_token", it) }
        startService<WebService>()   // Legado 原生服务, 带token鉴权(需确认其鉴权参数)
    }
}
```
**核对项**: MD3 分支 WebService 的包路径与启动方式（startService vs ContextCompat.startForegroundService）。

### ② mDNS 广播自己
**注入点**: 同 onCreate，①之后。
**新增文件**: `com.thirdhub.legado.thirdhub.NsdAnnouncer`
```kotlin
object NsdAnnouncer {
    fun start(ctx: Context, port: Int) {
        val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
        val info = NsdServiceInfo().apply {
            serviceName = "legado-${android.os.Build.MODEL.hashCode()}"
            serviceType = "_thirdhub-dev._tcp."
            setPort(port)
            setAttribute("type", "legado"); setAttribute("version", "4.0"); setAttribute("caps", "novel")
        }
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, null)
    }
}
```
Android 14+ 需要 `android.permission.INTERNET` + `CHANGE_WIFI_MULTICAST_STATE`。

### ③ 发现后端自动握手配对（零输入）
**新增文件**: `com.thirdhub.legado.thirdhub.AutoPairer`
- 监听 `_thirdhub-dev._tcp.` 中 type=backend 的实例
- 发现后 POST `http://后端:9527/v1/pair` {device_type:"legado", device_url:"http://127.0.0.1:1122", token, caps:[...]}
  （后端需实现 /v1/pair 接收设备注册——见 server 侧任务）
- 后端回 200 → 配对完成；失败静默（不打扰阅读，每 10 分钟重试一次）

## 后端配套（server/index.js 需加 /v1/pair）
```javascript
if (p === '/v1/pair' && req.method === 'POST') {
  const d = JSON.parse(body || '{}');
  if (!d.device_url) return send(400, {...});
  devices.push({ ...d, paired_at: Date.now() }); saveDevices();
  return send(200, { object:'meta', data:{ paired: true }});
}
// 另加 GET /v1/devices 列表, 路由层可按设备合并搜索(网络插件组任务)
```

## 零配对声明（本补丁的灵魂）
用户**不需要打开 Legado**、不需要进设置、不需要记任何地址口令。
装上 Legado → 它在后台自动开服务 → 后端自动发现 → 前端书源列表
自动出现"Legado(局域网)"。用户对 Legado 的感知=零（它是纯后台插件）。

## 验收
1. 干净手机装改造版 Legado → **不需要打开它**（挂在后台即可）
2. 后端日志出现 `已配对设备 legado@...`
3. 前端书源列表出现 "Legado(局域网)" 且搜索出结果
